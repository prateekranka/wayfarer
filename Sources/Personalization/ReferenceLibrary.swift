import AVFoundation
import MontageCore
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A timestamped teaching note attached to a finished reference reel.
public struct ReferenceNote: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let time: Double
    public let text: String

    public init(id: UUID = UUID(), time: Double, text: String) {
        self.id = id
        self.time = time
        self.text = text
    }

    public init(time: Double, text: String) {
        self.init(id: UUID(), time: time, text: text)
    }
}

/// A local finished reel used as an explicit teaching reference.
///
/// `cutTimes` and `analysisConfidence` are estimates from a small visual
/// heuristic. They do not represent semantic understanding or model training.
public struct ReelReference: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public let fileName: String
    public let duration: Double
    public let createdAt: Date
    public var notes: [ReferenceNote]
    public var cutTimes: [Double]
    public let analysisConfidence: Double
    public let thumbnailFileName: String?

    public init(
        id: UUID = UUID(),
        title: String,
        fileName: String,
        duration: Double,
        createdAt: Date = Date(),
        notes: [ReferenceNote] = [],
        cutTimes: [Double] = [],
        analysisConfidence: Double,
        thumbnailFileName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.duration = duration
        self.createdAt = createdAt
        self.notes = notes
        self.cutTimes = cutTimes
        self.analysisConfidence = analysisConfidence
        self.thumbnailFileName = thumbnailFileName
    }

    /// The mean duration of the shots implied by the estimated cuts.
    public var estimatedAverageShotDuration: Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        let cuts = cutTimes.filter { $0.isFinite && $0 > 0 && $0 < duration }.sorted()
        guard !cuts.isEmpty else { return nil }
        let boundaries = [0] + cuts + [duration]
        let spans = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.filter { $0 >= 0.001 }
        guard !spans.isEmpty else { return nil }
        return spans.reduce(0, +) / Double(spans.count)
    }
}

/// Stores user-selected finished reels and bounded visual timing estimates.
///
/// The library stores only local copies and user notes. It does not modify a
/// profile automatically and it does not make a model-training claim.
public actor ReferenceLibrary {
    public static let maximumDuration: Double = 180
    public static let maximumFileSize: Int64 = 1_000_000_000

    private static let thumbnailReserve: Int64 = 2_000_000
    private static let minimumCutGap: Double = 0.3
    private static let manifestExtension = "json"

    private nonisolated let storageURL: URL
    private let fileManager: FileManager
    public private(set) var unreadableCount = 0

    public init() {
        self.storageURL = URL.applicationSupportDirectory.appending(
            path: "Wayfarer/Style/References",
            directoryHint: .isDirectory
        )
        self.fileManager = .default
    }

    /// Loads all valid manifests in deterministic creation order.
    public func load() throws -> [ReelReference] {
        try ensureStorageDirectory()
        let manifestURLs: [URL]
        do {
            manifestURLs = try fileManager.contentsOfDirectory(
                at: storageURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == Self.manifestExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw MontageError.invalidMedia("The reference library could not be read.")
        }

        var references: [ReelReference] = []
        unreadableCount = 0
        references.reserveCapacity(manifestURLs.count)
        for manifestURL in manifestURLs {
            try Task.checkCancellation()
            do {
                guard isRegularNonSymlink(manifestURL),
                      let manifestID = UUID(uuidString: manifestURL.deletingPathExtension().lastPathComponent) else {
                    throw MontageError.invalidMedia("A saved reference manifest is invalid.")
                }
                let reference = try readManifest(at: manifestURL)
                guard reference.id == manifestID else {
                    throw MontageError.invalidMedia("A saved reference manifest is inconsistent.")
                }
                try validate(reference: reference, requireMedia: true)
                references.append(reference)
            } catch {
                // Preserve unreadable files, and keep the rest of the library usable.
                unreadableCount += 1
            }
        }

        return references.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Imports one user-selected movie into the library.
    public func importVideo(at url: URL) async throws -> ReelReference {
        try Task.checkCancellation()
        let securityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if securityScoped { url.stopAccessingSecurityScopedResource() }
        }

        try ensureStorageDirectory()
        guard isRegularNonSymlink(url, requireContained: false) else {
            throw MontageError.invalidMedia("Choose a readable local video file.")
        }
        let sourceValues: URLResourceValues
        do {
            sourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            throw MontageError.invalidMedia("The selected video could not be inspected.")
        }
        let sourceSize = Int64(sourceValues.fileSize ?? 0)
        guard sourceSize > 0, sourceSize <= Self.maximumFileSize else {
            throw MontageError.invalidMedia("Reference videos must be 1 GB or smaller.")
        }
        try checkCapacity(forBytes: sourceSize + Self.thumbnailReserve)

        let sourceAsset = AVURLAsset(url: url)
        let duration: Double
        do {
            let loaded = try await sourceAsset.load(.duration, .tracks, .hasProtectedContent, .isReadable)
            guard !loaded.2 else {
                throw MontageError.invalidMedia("Protected video cannot be used as a reference.")
            }
            guard loaded.3 else {
                throw MontageError.invalidMedia("The selected video cannot be read on this device.")
            }
            duration = loaded.0.seconds
            guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
                throw MontageError.invalidMedia("Reference videos must be 180 seconds or shorter.")
            }
            guard loaded.1.contains(where: { $0.mediaType == .video }) else {
                throw MontageError.invalidMedia("The selected file does not contain a video track.")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MontageError {
            throw error
        } catch {
            throw MontageError.invalidMedia("The selected video cannot be read on this device.")
        }

        let id = UUID()
        let extensionName = Self.safeExtension(url.pathExtension) ?? "mov"
        let fileName = "\(id.uuidString).\(extensionName)"
        let destinationURL = storageURL.appendingPathComponent(fileName, isDirectory: false)
        let stagingURL = storageURL.appendingPathComponent(".staging-\(id.uuidString)", isDirectory: false)
        let manifestURL = manifestURL(for: id)
        var thumbnailURL: URL?
        var stagingCreated = false
        var destinationCreated = false
        var manifestCreated = false
        var committed = false
        guard !fileManager.fileExists(atPath: destinationURL.path),
              !fileManager.fileExists(atPath: stagingURL.path),
              !fileManager.fileExists(atPath: manifestURL.path) else {
            throw MontageError.invalidMedia("The reference library could not create a unique local file.")
        }
        defer {
            if !committed {
                if stagingCreated { try? fileManager.removeItem(at: stagingURL) }
                if destinationCreated { try? fileManager.removeItem(at: destinationURL) }
                if let thumbnailURL { try? fileManager.removeItem(at: thumbnailURL) }
                if manifestCreated { try? fileManager.removeItem(at: manifestURL) }
            }
        }

        do {
            stagingCreated = true
            try fileManager.copyItem(at: url, to: stagingURL)
            try Task.checkCancellation()
            destinationCreated = true
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            stagingCreated = false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MontageError.invalidMedia("The selected video could not be copied into the reference library.")
        }

        let analysis = await analyzeReferenceVideo(at: destinationURL, duration: duration)
        try Task.checkCancellation()
        if let thumbnailData = analysis.thumbnailData {
            let name = "\(id.uuidString)-thumbnail.jpg"
            let candidate = storageURL.appendingPathComponent(name, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                thumbnailURL = candidate
                do {
                    try thumbnailData.write(to: candidate, options: .atomic)
                } catch {
                    // A thumbnail is optional. Keep the usable video and manifest.
                    try? fileManager.removeItem(at: candidate)
                    thumbnailURL = nil
                }
            }
        }

        let title = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = ReelReference(
            id: id,
            title: title.isEmpty ? "Reference reel" : title,
            fileName: fileName,
            duration: duration,
            createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            notes: [],
            cutTimes: analysis.cutTimes,
            analysisConfidence: analysis.confidence,
            thumbnailFileName: thumbnailURL?.lastPathComponent
        )
        try validate(reference: reference, requireMedia: true)
        try Task.checkCancellation()
        try writeManifest(reference)
        manifestCreated = true
        try Task.checkCancellation()
        committed = true
        return reference
    }

    /// Updates title, timestamp notes, and user-adjusted cut annotations.
    public func update(_ ref: ReelReference) throws {
        try ensureStorageDirectory()
        let existingURL = manifestURL(for: ref.id)
        guard fileManager.fileExists(atPath: existingURL.path) else {
            throw MontageError.invalidMedia("This reference is no longer in the library.")
        }
        let existing = try readManifest(at: existingURL)
        guard existing.id == ref.id,
              existing.fileName == ref.fileName,
              existing.duration == ref.duration,
              existing.createdAt == ref.createdAt,
              existing.thumbnailFileName == ref.thumbnailFileName else {
            throw MontageError.invalidMedia("A reference file cannot be changed after import.")
        }
        try validate(reference: ref, requireMedia: true)
        try writeManifest(ref)
    }

    /// Removes a reference and its files. Only files named by the reference are touched.
    public func remove(_ ref: ReelReference) throws {
        try ensureStorageDirectory()
        try validate(reference: ref, requireMedia: false)
        let manifest = manifestURL(for: ref.id)
        guard fileManager.fileExists(atPath: manifest.path) else {
            throw MontageError.invalidMedia("This reference is no longer in the library.")
        }
        let existing = try readManifest(at: manifest)
        guard existing.id == ref.id,
              existing.fileName == ref.fileName,
              existing.thumbnailFileName == ref.thumbnailFileName else {
            throw MontageError.invalidMedia("A reference file cannot be changed during removal.")
        }

        var firstError: Error?
        for fileURL in [mediaURL(for: ref), thumbnailURL(for: ref), manifest].compactMap({ $0 }) {
            guard isContained(fileURL), fileManager.fileExists(atPath: fileURL.path) else { continue }
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                firstError = firstError ?? error
            }
        }
        if firstError != nil {
            throw MontageError.invalidMedia("The reference could not be fully removed.")
        }
    }

    public nonisolated func mediaURL(for ref: ReelReference) -> URL {
        guard Self.isSafeFilename(ref.fileName) else {
            return storageURL.appendingPathComponent(".invalid-reference", isDirectory: false)
        }
        return storageURL.appendingPathComponent(ref.fileName, isDirectory: false)
    }

    public nonisolated func thumbnailURL(for ref: ReelReference) -> URL? {
        guard let fileName = ref.thumbnailFileName, Self.isSafeFilename(fileName) else { return nil }
        return storageURL.appendingPathComponent(fileName, isDirectory: false)
    }

    private struct ReferenceAnalysis: Sendable {
        let cutTimes: [Double]
        let confidence: Double
        let thumbnailData: Data?
    }

    private struct FrameSignature: Sendable {
        let time: Double
        let histogram: [Double]
        let meanLuminance: Double
        let variance: Double
    }

    private func analyzeReferenceVideo(at url: URL, duration: Double) async -> ReferenceAnalysis {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let sampleCount = min(240, max(8, Int(ceil(duration * 1.5))))
        let interval = duration / Double(sampleCount)
        var signatures: [FrameSignature] = []
        signatures.reserveCapacity(sampleCount)
        var thumbnailData: Data?

        for index in 0..<sampleCount {
            do {
                try Task.checkCancellation()
            } catch {
                return ReferenceAnalysis(cutTimes: [], confidence: 0.1, thumbnailData: thumbnailData)
            }
            let time = min(duration, (Double(index) + 0.5) * interval)
            do {
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                let result = autoreleasepool {
                    (signature(for: image, time: time), thumbnailData ?? jpegData(for: image))
                }
                signatures.append(result.0)
                if thumbnailData == nil { thumbnailData = result.1 }
            } catch is CancellationError {
                return ReferenceAnalysis(cutTimes: [], confidence: 0.1, thumbnailData: thumbnailData)
            } catch {
                // A failed sample does not invalidate an otherwise usable reel.
            }
        }

        guard signatures.count >= 2 else {
            return ReferenceAnalysis(cutTimes: [], confidence: 0.15, thumbnailData: thumbnailData)
        }

        var differences: [Double] = []
        differences.reserveCapacity(signatures.count - 1)
        for pair in zip(signatures, signatures.dropFirst()) {
            let histogramDistance = zip(pair.0.histogram, pair.1.histogram)
                .reduce(0) { $0 + abs($1.0 - $1.1) } * 0.5
            let luminanceDistance = abs(pair.0.meanLuminance - pair.1.meanLuminance)
            let varianceDistance = abs(pair.0.variance - pair.1.variance).squareRoot()
            differences.append(min(1, histogramDistance * 1.2 + luminanceDistance * 0.8 + varianceDistance * 0.15))
        }

        let sorted = differences.sorted()
        let median = sorted[sorted.count / 2]
        let mean = differences.reduce(0, +) / Double(differences.count)
        let standardDeviation = (differences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(differences.count)).squareRoot()
        let threshold = max(
            0.32,
            max(median + max(0.10, standardDeviation * 1.35), mean + standardDeviation * 0.65)
        )
        var cutTimes: [Double] = []
        for index in differences.indices where differences[index] >= threshold {
            let previous = index > 0 ? differences[index - 1] : -Double.infinity
            let next = index + 1 < differences.count ? differences[index + 1] : -Double.infinity
            guard differences[index] >= previous, differences[index] >= next else { continue }
            let cutTime = signatures[index + 1].time
            guard cutTime > 0, cutTime < duration,
                  cutTimes.last.map({ cutTime - $0 >= Self.minimumCutGap }) ?? true else { continue }
            cutTimes.append(cutTime)
        }

        let strongest = differences.max() ?? 0
        let signal = max(0, min(1, (strongest - median) / 0.65))
        let coverage = min(1, Double(signatures.count) / 32)
        let confidence = max(0.15, min(0.78, 0.2 + coverage * 0.28 + signal * 0.25 + min(0.15, Double(cutTimes.count) / 20)))
        return ReferenceAnalysis(cutTimes: cutTimes, confidence: confidence, thumbnailData: thumbnailData)
    }

    private func signature(for image: CGImage, time: Double) -> FrameSignature {
        let width = 32
        let height = 32
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context, let data = context.data else {
            return FrameSignature(time: time, histogram: [Double](repeating: 0, count: 16), meanLuminance: 0, variance: 0)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var histogram = [Double](repeating: 0, count: 16)
        var values: [Double] = []
        values.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            let luminance = (0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])) / 255
            histogram[min(15, Int(luminance * 16))] += 1
            values.append(luminance)
        }
        let count = Double(values.count)
        histogram = histogram.map { $0 / count }
        let mean = values.reduce(0, +) / count
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / count
        return FrameSignature(time: time, histogram: histogram, meanLuminance: mean, variance: variance)
    }

    private func jpegData(for image: CGImage) -> Data? {
        if let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.78) {
            return data
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func ensureStorageDirectory() throws {
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = storageURL
            try? directory.setResourceValues(values)
        } catch {
            throw MontageError.invalidMedia("The reference library could not be opened.")
        }
    }

    private func readManifest(at url: URL) throws -> ReelReference {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ReelReference.self, from: Data(contentsOf: url))
        } catch {
            throw MontageError.invalidMedia("A saved reference could not be read.")
        }
    }

    private func writeManifest(_ reference: ReelReference) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(reference)
            try data.write(to: manifestURL(for: reference.id), options: .atomic)
        } catch {
            throw MontageError.invalidMedia("The reference could not be saved.")
        }
    }

    private func validate(reference: ReelReference, requireMedia: Bool) throws {
        guard !reference.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MontageError.invalidMedia("A reference needs a title.")
        }
        guard reference.duration.isFinite, reference.duration > 0, reference.duration <= Self.maximumDuration else {
            throw MontageError.invalidMedia("A reference has an invalid duration.")
        }
        guard reference.analysisConfidence.isFinite, (0...1).contains(reference.analysisConfidence) else {
            throw MontageError.invalidMedia("A reference has invalid analysis confidence.")
        }
        guard Self.isSafeFilename(reference.fileName) else {
            throw MontageError.invalidMedia("A reference has an invalid video file name.")
        }
        if let thumbnailFileName = reference.thumbnailFileName {
            guard Self.isSafeFilename(thumbnailFileName) else {
                throw MontageError.invalidMedia("A reference has an invalid thumbnail file name.")
            }
        }
        guard reference.cutTimes.allSatisfy({ $0.isFinite && $0 > 0 && $0 < reference.duration }) else {
            throw MontageError.invalidMedia("A reference has invalid cut times.")
        }
        let cuts = reference.cutTimes.sorted()
        guard zip(cuts, cuts.dropFirst()).allSatisfy({ $1 - $0 >= Self.minimumCutGap }) else {
            throw MontageError.invalidMedia("A reference has cut times that are too close together.")
        }
        guard reference.notes.allSatisfy({ note in
            note.time.isFinite && note.time >= 0 && note.time <= reference.duration
                && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MontageError.invalidMedia("A reference has an invalid teaching note.")
        }
        if requireMedia {
            let media = mediaURL(for: reference)
            guard isContained(media), isRegularNonSymlink(media),
                  let mediaValues = try? media.resourceValues(forKeys: [.fileSizeKey]),
                  let mediaSize = mediaValues.fileSize,
                  mediaSize > 0, mediaSize <= Self.maximumFileSize else {
                throw MontageError.invalidMedia("A saved reference video is missing.")
            }
            if let thumbnail = thumbnailURL(for: reference), !isRegularNonSymlink(thumbnail) {
                throw MontageError.invalidMedia("A saved reference thumbnail is missing.")
            }
        }
    }

    private func checkCapacity(forBytes bytes: Int64) throws {
        let values: URLResourceValues
        do {
            values = try storageURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        } catch {
            throw MontageError.invalidMedia("Available storage could not be checked.")
        }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init)
        if let available, available < bytes {
            throw MontageError.invalidMedia("There isn’t enough storage for this reference. Free some space and try again.")
        }
    }

    private func manifestURL(for id: UUID) -> URL {
        storageURL.appendingPathComponent("\(id.uuidString).\(Self.manifestExtension)", isDirectory: false)
    }

    private func isRegularNonSymlink(_ url: URL, requireContained: Bool = true) -> Bool {
        guard !requireContained || isContained(url) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isContained(_ url: URL) -> Bool {
        let root = storageURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    private static func isSafeFilename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255, name != ".", name != "..", !name.hasPrefix("/") else { return false }
        guard !name.contains("/") && !name.contains("\\") else { return false }
        return URL(fileURLWithPath: name).lastPathComponent == name
    }

    private static func safeExtension(_ ext: String) -> String? {
        let lowercased = ext.lowercased()
        guard !lowercased.isEmpty, lowercased.count <= 12,
              lowercased.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return lowercased
    }
}
