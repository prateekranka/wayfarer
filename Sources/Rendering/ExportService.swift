import AVFoundation
import Foundation
import MontageCore

/// Exports a montage through AVFoundation's current async exporter.
public actor ExportService {
    private let compositionBuilder: CompositionBuilder

    public init(compositionBuilder: CompositionBuilder = CompositionBuilder()) {
        self.compositionBuilder = compositionBuilder
    }

    /// Exports a high-quality H.264 MP4 and reports exporter progress.
    ///
    /// The exporter writes to a task-owned temporary file first. On success,
    /// it atomically moves that file to the project's final output name. A
    /// cancelled or failed export removes only its temporary file. The async
    /// `AVAssetExportSession.export(to:as:)` API owns cancellation and calls
    /// `cancelExport()` internally when its task is cancelled.
    public func export(project: MontageProject, plan: MontagePlan, directory: URL,
                       progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkDiskCapacity(at: directory)

        let assembly = try await compositionBuilder.build(
            project: project,
            plan: plan,
            directory: directory,
            preview: false
        )
        let finalURL = directory.appendingPathComponent(outputFileName(for: project))
        return try await render(assembly: assembly, duration: project.targetDuration, requiresAudio: project.music != nil,
                                destination: finalURL, progress: progress)
    }

    func render(assembly: CompositionBuildResult, duration: Double, requiresAudio: Bool, destination: URL,
                progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        var endCorrection = 0.0
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard let session = AVAssetExportSession(asset: assembly.composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw MontageError.invalidMedia("This montage cannot be exported on this device.")
            }
            session.videoComposition = assembly.videoComposition
            session.audioMix = assembly.audioMix
            session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration + endCorrection, preferredTimescale: 600))
            session.shouldOptimizeForNetworkUse = true
            let partialURL = destination.deletingLastPathComponent().appendingPathComponent(".wayfarer-export-\(UUID().uuidString).mp4")
            let states = session.states(updateInterval: 0.20)
            let progressTask = Task { [states] in
                for await state in states {
                    if case .exporting(let value) = state {
                        let base = attempt == 0 ? 0.0 : 0.9
                        let span = attempt == 0 ? 0.9 : 0.09
                        await progress(base + Double(value.fractionCompleted) * span)
                    }
                }
            }
            do {
                try await session.export(to: partialURL, as: .mp4)
                progressTask.cancel()
                try Task.checkCancellation()
                // Recover a short native export once, then trim encoded context
                // without another encode. Accept only a validated final file.
                if attempt == 0, let correction = try await shortfall(at: partialURL, duration: duration) {
                    endCorrection = correction
                    removeTaskOwnedFile(partialURL)
                    continue
                }
                let completedURL: URL
                if attempt == 1 {
                    completedURL = try await trimEncodedFile(at: partialURL, duration: duration)
                    removeTaskOwnedFile(partialURL)
                } else { completedURL = partialURL }
                defer { removeTaskOwnedFile(completedURL) }
                try await validateOutput(at: completedURL, duration: duration, requiresAudio: requiresAudio)
                try Task.checkCancellation()
                try commit(partialURL: completedURL, finalURL: destination)
                await progress(1)
                return destination
            } catch {
                progressTask.cancel()
                removeTaskOwnedFile(partialURL)
                throw error
            }
        }
        throw MontageError.invalidMedia("The finished video could not be completed. Try another edit and export again.")
    }

    private func trimEncodedFile(at url: URL, duration: Double) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MontageError.invalidMedia("This video could not be finalized. Export again.")
        }
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        session.shouldOptimizeForNetworkUse = true
        let destination = url.deletingLastPathComponent().appendingPathComponent(".wayfarer-export-\(UUID().uuidString).mp4")
        do {
            try await session.export(to: destination, as: .mp4)
            try Task.checkCancellation()
            return destination
        } catch {
            removeTaskOwnedFile(destination)
            throw error
        }
    }

    private func shortfall(at url: URL, duration: Double) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let range = try await video.load(.timeRange)
        let deficit = duration - range.end.seconds
        guard abs(range.start.seconds) < 1.0 / 600.0,
              deficit > 1.0 / 30.0 + 1.0 / 600.0, deficit <= 0.1 else { return nil }
        return deficit
    }

    private func validateOutput(at url: URL, duration: Double, requiresAudio: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else {
            throw MontageError.invalidMedia("The finished video is incomplete. Try another edit and export again.")
        }
        let videoRange = try await video.load(.timeRange)
        let tolerance = 1.0 / 30.0 + 1.0 / 600.0
        let timing: [String: Double] = ["requestedDuration": duration, "videoStart": videoRange.start.seconds,
                                        "videoEnd": videoRange.end.seconds, "tolerance": tolerance]
        if let data = try? JSONSerialization.data(withJSONObject: timing, options: [.sortedKeys]) {
            try? data.write(to: url.deletingLastPathComponent().appending(path: "export-diagnostic.json"), options: [.atomic])
        }
        guard abs(videoRange.start.seconds) < tolerance,
              abs(videoRange.end.seconds - duration) <= tolerance else {
            throw MontageError.invalidMedia("The finished video has incomplete timing. Try another edit and export again.")
        }
        if requiresAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audio = audioTracks.first else {
                throw MontageError.invalidMedia("The finished video has no soundtrack. Export again.")
            }
            let audioRange = try await audio.load(.timeRange)
            guard abs(audioRange.start.seconds) < tolerance,
                  abs(audioRange.end.seconds - duration) <= tolerance else {
                throw MontageError.invalidMedia("The finished soundtrack has incomplete timing. Export again.")
            }
        }
    }

    private func checkDiskCapacity(at directory: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey,
                                          .volumeAvailableCapacityKey]
        let values = try directory.resourceValues(forKeys: keys)
        let capacity: Int64 = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        // A high-quality export can need several times the final file size.
        // Refuse a clearly unsafe volume before AVFoundation starts writing.
        guard capacity >= 256 * 1024 * 1024 else {
            throw MontageError.invalidMedia("There is not enough free space to export this montage.")
        }
    }

    private func outputFileName(for project: MontageProject) -> String {
        let requested = project.exportFileName ?? "\(project.name)-montage.mp4"
        let base = URL(fileURLWithPath: requested).deletingPathExtension().lastPathComponent
        let safe = base.unicodeScalars.map { scalar in
            let value = scalar.value
            let isASCIIAlphaNumeric = (value >= 48 && value <= 57) ||
                (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
            let allowed = isASCIIAlphaNumeric || value == 45 || value == 95
            return allowed ? Character(scalar) : Character("-")
        }
        let name = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (name.isEmpty ? "wayfarer-montage" : name) + ".mp4"
    }

    private func commit(partialURL: URL, finalURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            _ = try fileManager.replaceItemAt(finalURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: finalURL)
        }
    }

    private func removeTaskOwnedFile(_ url: URL) {
        guard url.lastPathComponent.hasPrefix(".wayfarer-export-") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
