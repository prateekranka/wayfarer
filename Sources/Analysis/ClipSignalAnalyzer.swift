import AVFoundation
import CoreVideo
import Foundation
import SoundAnalysis
import Vision

/// One sound heard in a clip.
public struct ClipSound: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var label: String
    public var confidence: Double
}

/// Real motion between two nearby frames of a clip.
public struct ClipMotion: Sendable, Equatable {
    public var time: Double
    /// Average movement per second, as a share of the frame's width.
    public var speed: Double
    /// Direction of the average movement in radians. 0 is right, and positive
    /// is down, in the frame's top-left coordinates.
    public var direction: Double
    /// How much of the movement agrees on one direction, from 0 to 1. Low
    /// values mean things moved in different directions.
    public var agreement: Double
}

/// Listens to a clip and measures its motion with Apple's on-device models.
///
/// Every failure returns empty results, so a clip is never lost over a signal
/// that is only a bonus. These models do not run in the iOS Simulator.
public enum ClipSignalAnalyzer {
    private final class SoundCollector: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var sounds: [ClipSound] = []
        let minimumConfidence: Double
        init(minimumConfidence: Double) { self.minimumConfidence = minimumConfidence }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let start = result.timeRange.start.seconds
            let end = start + result.timeRange.duration.seconds
            let heard = result.classifications.filter { Double($0.confidence) >= minimumConfidence }
                .map { ClipSound(start: start, end: end, label: $0.identifier, confidence: Double($0.confidence)) }
            lock.withLock { sounds.append(contentsOf: heard) }
        }

        var results: [ClipSound] { lock.withLock { sounds } }
    }

    /// Finds sounds in a clip's audio. Clips with no sound return nothing.
    public static func sounds(in url: URL, minimumConfidence: Double = 0.3) async -> [ClipSound] {
        do {
            // Create the request first, so nothing is copied if the model cannot run.
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let audioURL = try await audioFile(for: url)
            defer { if audioURL != url { try? FileManager.default.removeItem(at: audioURL) } }
            let analyzer = try SNAudioFileAnalyzer(url: audioURL)
            let collector = SoundCollector(minimumConfidence: minimumConfidence)
            try analyzer.add(request, withObserver: collector)
            _ = await analyzer.analyze()
            return collector.results
        } catch {
            return []
        }
    }

    /// The labels the sound model can report.
    public static func knownSounds() -> [String] {
        (try? SNClassifySoundRequest(classifierIdentifier: .version1))?.knownClassifications ?? []
    }

    /// Sound analysis reads audio files, so video audio is copied out first.
    private static func audioFile(for url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        guard hasVideo else { return url }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadUnknown)
        }
        let output = FileManager.default.temporaryDirectory
            .appending(path: "wayfarer-sound-\(UUID().uuidString).m4a")
        try await export.export(to: output, as: .m4a)
        return output
    }

    /// Measures optical flow across a short gap at each time.
    public static func motion(in url: URL, at times: [Double], gap: Double = 0.1) async -> [ClipMotion] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 256, height: 256)
        let tolerance = CMTime(seconds: 0.01, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var result: [ClipMotion] = []
        for time in times {
            if Task.isCancelled { break }
            guard let first = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image,
                  let second = try? await generator.image(at: CMTime(seconds: time + gap, preferredTimescale: 600)).image else { continue }
            // If the model cannot run here, it will not run for the next frame either.
            guard let flow = flow(from: first, to: second) else { break }
            result.append(ClipMotion(time: time, speed: flow.distance / gap, direction: flow.direction, agreement: flow.agreement))
        }
        return result
    }

    private static func flow(from first: CGImage, to second: CGImage) -> (distance: Double, direction: Double, agreement: Double)? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: second)
        request.computationAccuracy = .medium
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        do {
            try VNImageRequestHandler(cgImage: first, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var sumX = 0.0, sumY = 0.0, sumLength = 0.0, count = 0.0
        for y in stride(from: 0, to: height, by: 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in stride(from: 0, to: width, by: 2) {
                let dx = Double(row[x * 2]), dy = Double(row[x * 2 + 1])
                guard dx.isFinite, dy.isFinite else { continue }
                sumX += dx; sumY += dy; sumLength += (dx * dx + dy * dy).squareRoot(); count += 1
            }
        }
        guard count > 0, sumLength > 0 else { return nil }
        let meanX = sumX / count, meanY = sumY / count
        let agreement = (meanX * meanX + meanY * meanY).squareRoot() / (sumLength / count)
        return (sumLength / count / Double(width), atan2(meanY, meanX), agreement)
    }
}
