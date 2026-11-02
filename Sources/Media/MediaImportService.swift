import AVFoundation
import CoreTransferable
import CryptoKit
import Foundation
import MontageCore
import Photos
import UniformTypeIdentifiers

struct ImportedMovie: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let root = URL.applicationSupportDirectory.appending(path: "Wayfarer/Incoming", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excludedRoot = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excludedRoot.setResourceValues(values)
            let destination = root.appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}

actor MediaImportService {
    func importVideo(url: URL, photoIdentifier: String?, directory: URL,
                     knownFingerprints: Set<String>) async throws -> SourceAsset? {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent) else {
            throw MontageError.invalidMedia("Protected video cannot be used. Choose an unprotected video file.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.5,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MontageError.invalidMedia("A selected clip has no readable video. Choose another clip.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let dimensions = size.applying(transform)
        let fingerprint = try hash(url: url)
        guard !knownFingerprints.contains(fingerprint) else { return nil }
        try checkCapacity(directory: directory, file: url)
        let id = UUID()
        let fileName = id.uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let destination = directory.appending(path: fileName)
        try FileManager.default.copyItem(at: url, to: destination)
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        try Task.checkCancellation()
        var timestamp: Date?
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if let photoIdentifier, authorization == .authorized || authorization == .limited {
            timestamp = PHAsset.fetchAssets(withLocalIdentifiers: [photoIdentifier], options: nil).firstObject?.creationDate
        }
        if timestamp == nil {
            let metadata = (try? await asset.load(.commonMetadata)) ?? []
            if let entry = metadata.first(where: { $0.commonKey == .commonKeyCreationDate }),
               let value = try? await entry.load(.dateValue) { timestamp = value }
        }
        try Task.checkCancellation()
        committed = true
        return SourceAsset(id: id, fileName: fileName, photoIdentifier: photoIdentifier, duration: duration,
                           width: abs(dimensions.width), height: abs(dimensions.height), timestamp: timestamp,
                           fingerprint: fingerprint)
    }

    func importAudio(url: URL, directory: URL) throws -> URL {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try checkCapacity(directory: directory, file: url)
        let fileName = "music-" + UUID().uuidString + "." + url.pathExtension
        let destination = directory.appending(path: fileName)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func hash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func checkCapacity(directory: URL, file: URL) throws {
        let resources = try file.resourceValues(forKeys: [.fileSizeKey])
        let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = capacity.volumeAvailableCapacityForImportantUsage,
           available < Int64(resources.fileSize ?? 0) + 150_000_000 {
            throw MontageError.invalidMedia("There isn’t enough storage to import this media. Free some space and try again.")
        }
    }
}
