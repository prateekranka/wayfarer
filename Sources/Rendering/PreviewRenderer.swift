import AVFoundation
import CryptoKit
import Foundation
import MontageCore

/// Uses a live composition first, with cached low-resolution files as a
/// fallback when the platform cannot play a composition-backed item.
actor PreviewRenderer {
    private let builder = CompositionBuilder()
    private let exporter = ExportService()

    private struct SourceRange: Encodable {
        let assetID: UUID
        let start: Double
        let duration: Double
        let subject: SubjectAnchor?
    }
    private struct CacheKey: Encodable {
        let version = 9
        let ranges: [SourceRange]
        /// The style look, its strength, and its math version. Shot correction
        /// depends only on the source ranges, which are already part of the key.
        let look: String
        let lookStrength: Double
        let lookVersion = ColorLook.version
        let musicStart: Double
        let ratio: OutputRatio
        let originalSound: Double
        let musicFile: String?
    }

    func playerItem(project: MontageProject, plan: MontagePlan, directory: URL,
                    useProxy: Bool) async throws -> AVPlayerItem {
        let ranges = plan.segments.map {
            SourceRange(assetID: $0.sourceAssetID, start: $0.sourceStartTime, duration: $0.duration, subject: $0.subject)
        }
        let look = ColorLook.style(for: plan.intent).adjusted(by: project.look)
        let key = CacheKey(ranges: ranges, look: look.id, lookStrength: look.strength,
                           musicStart: plan.musicStartTime, ratio: project.outputRatio,
                           originalSound: project.originalSound, musicFile: project.music?.fileName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
        let cache = directory.appending(path: "Previews", directoryHint: .isDirectory)
        let destination = cache.appending(path: digest + ".mp4")
        if FileManager.default.fileExists(atPath: destination.path) {
            return await fileItem(destination)
        }
        let assembly = try await builder.build(project: project, plan: plan, directory: directory, preview: true)
        guard useProxy else { return await assembly.playerItem }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let capacity = try cache.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = capacity.volumeAvailableCapacityForImportantUsage, available < 128 * 1024 * 1024 {
            throw MontageError.invalidMedia("There isn’t enough storage to prepare this preview.")
        }
        _ = try await exporter.render(assembly: assembly, duration: project.targetDuration, requiresAudio: project.music != nil,
                                      destination: destination, progress: { _ in })
        try Task.checkCancellation()
        prune(cache: cache, keeping: destination)
        return await fileItem(destination)
    }

    @MainActor private func fileItem(_ url: URL) -> AVPlayerItem { AVPlayerItem(url: url) }

    private func prune(cache: URL, keeping destination: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = files.filter { $0 != destination && $0.pathExtension == "mp4" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for file in old.dropFirst(3) { try? FileManager.default.removeItem(at: file) }
    }
}
