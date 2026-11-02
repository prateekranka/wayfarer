import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import MontageCore
import os

private final class CompositionValidationReporter: NSObject, AVVideoCompositionValidationHandling, @unchecked Sendable {
    private let messages = OSAllocatedUnfairLock(initialState: [String]())
    var issues: [String] { messages.withLock { $0 } }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool {
        messages.withLock { $0.append("Invalid value: " + key) }; return true
    }
    func videoComposition(_ videoComposition: AVVideoComposition,
                          shouldContinueValidatingAfterFindingEmptyTimeRange timeRange: CMTimeRange) -> Bool {
        messages.withLock { $0.append("Empty range: \(timeRange.start.seconds)–\(timeRange.end.seconds)") }; return true
    }
}

/// The immutable AVFoundation objects that make one montage playable.
///
/// `AVFoundation` objects are reference types and do not conform to Swift's
/// `Sendable` protocol. This wrapper is safe to pass between the rendering
/// actor and the UI because the composition is complete before the wrapper is
/// returned. The UI must treat all contained objects as read-only.
public struct CompositionBuildResult: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix?
    public let duration: CMTime

    /// Creates a player item with the video and audio instructions attached.
    @MainActor public var playerItem: AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.forwardPlaybackEndTime = duration
        return item
    }

    public init(composition: AVComposition, videoComposition: AVVideoComposition,
                audioMix: AVAudioMix?, duration: CMTime) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
    }
}

/// Builds a validated AVComposition for preview playback and export.
///
/// The same assembly path serves previews and exports. A preview uses a lower
/// render size but keeps the source ranges, transforms, crop anchors, audio
/// mix, color, and timing identical to the export path. Source URLs are resolved from
/// `directory` and the file names stored in `MontageProject.assets` and
/// `MontageProject.music`; missing files fail with `MontageError.invalidMedia`.
///
/// Frames are drawn by `LookCompositor`. Each shot gets a gentle exposure and
/// white-balance fix so clips match, then the color look for the edit style.
public actor CompositionBuilder {
    public init() {}

    private struct VideoTrackSlot {
        let formats: [CMFormatDescription]
        let track: AVMutableCompositionTrack
    }

    private struct PlacedShot {
        let timeRange: CMTimeRange
        let trackID: CMPersistentTrackID
        let transform: CGAffineTransform
        let focus: CGPoint
    }

    /// Shot measurements by source file and range. Building the same edit
    /// again, for example for export after preview, does not decode frames again.
    private var measurementCache: [String: ShotMeasurement] = [:]
    private static let maxCachedMeasurements = 600

    /// Builds a composition and its video/audio instructions.
    ///
    /// Set `preview` to `true` for a 576-pixel-wide render. Set it to `false`
    /// for the project's exact output dimensions, such as 1080x1920 vertical.
    public func build(project: MontageProject, plan: MontagePlan, directory: URL,
                      preview: Bool = true) async throws -> CompositionBuildResult {
        try validate(project: project, plan: plan)

        let assetByID = Dictionary(uniqueKeysWithValues: project.assets.map { ($0.id, $0) })
        let composition = AVMutableComposition()
        let renderSize = renderSize(for: project.outputRatio, preview: preview)
        var placedShots: [PlacedShot] = []
        var measurements: [ShotMeasurement?] = []
        var scaleLimits: [Double] = []
        var audioParameters: [AVAudioMixInputParameters] = []
        var timeline = CMTime.zero
        var plannedEnd = 0.0
        var hasAudio = false
        var videoLanes: [[VideoTrackSlot]] = [[], []]

        for (index, segment) in plan.segments.enumerated() {
            try Task.checkCancellation()
            guard let source = assetByID[segment.sourceAssetID] else {
                throw MontageError.invalidMedia("The selected source is missing from this project.")
            }
            let sourceURL = directory.appendingPathComponent(source.fileName)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw MontageError.invalidMedia("The source file \(source.fileName) is unavailable.")
            }

            let asset = AVURLAsset(url: sourceURL)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = videoTracks.first else {
                throw MontageError.invalidMedia("The source file \(source.fileName) has no video track.")
            }
            // Alternate tracks so consecutive cuts do not share a decoder lane.
            // Reuse exact format descriptions within each lane.
            let formats = try await sourceVideoTrack.load(.formatDescriptions)
            let lane = index % 2
            let compositionVideoTrack: AVMutableCompositionTrack
            if let slot = videoLanes[lane].first(where: { slot in
                slot.formats.count == formats.count && zip(slot.formats, formats).allSatisfy { CFEqual($0, $1) }
            }) {
                compositionVideoTrack = slot.track
            } else {
                guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MontageError.invalidMedia("The video composition track could not be created.")
                }
                compositionVideoTrack = track
                videoLanes[lane].append(VideoTrackSlot(formats: formats, track: track))
            }
            compositionVideoTrack.naturalTimeScale = 600
            let sourceDuration = try await asset.load(.duration)
            let sourceStart = cmTime(segment.sourceStartTime)
            // Quantize shared boundaries, rather than independently truncating
            // each duration. Every instruction ends where the next one starts.
            plannedEnd += segment.duration
            let timelineEnd = cmTime(index == plan.segments.count - 1 ? project.targetDuration : plannedEnd)
            let duration = timelineEnd - timeline
            let sourceRange = CMTimeRange(start: sourceStart, duration: duration)
            guard sourceStart >= .zero, CMTimeRangeGetEnd(sourceRange) <= sourceDuration else {
                throw MontageError.invalidMedia("The selected range is outside \(source.fileName).")
            }

            // Retain decoder context beyond an interior final cut. Export and
            // playback still end at the exact requested time; no extra footage plays.
            var videoDuration = duration
            if index == plan.segments.count - 1 {
                // A complete reference-frame interval can exceed two display
                // frames in H.264/HEVC. Retain a bounded two-second tail.
                let context = cmTime(2)
                let available = sourceDuration - sourceRange.end
                if available > .zero { videoDuration = duration + min(context, available) }
            }
            let videoRange = CMTimeRange(start: sourceStart, duration: videoDuration)
            try compositionVideoTrack.insertTimeRange(videoRange, of: sourceVideoTrack, at: timeline)

            let naturalSize = try await sourceVideoTrack.load(.naturalSize)
            let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
            let placement = placementTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                subject: segment.subject,
                renderSize: renderSize
            )
            placedShots.append(PlacedShot(timeRange: CMTimeRange(start: timeline, duration: videoDuration),
                                          trackID: compositionVideoTrack.trackID,
                                          transform: placement.transform, focus: placement.focus))
            // Judge resolution against final export size, so preview and export match.
            let shortSide = min(abs(naturalSize.width), abs(naturalSize.height))
            let outputShortSide = Double(min(project.outputRatio.width, project.outputRatio.height))
            scaleLimits.append(Double(shortSide) < outputShortSide ? EditPlanner.lowResolutionLimit : .infinity)
            measurements.append(await measurement(for: asset, start: segment.sourceStartTime,
                                                  duration: segment.duration))

            let sourceAudioTracks = try await asset.loadTracks(withMediaType: .audio)
            if project.originalSound > 0, let sourceAudioTrack = sourceAudioTracks.first {
                let compositionAudioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
                if let compositionAudioTrack {
                    try compositionAudioTrack.insertTimeRange(sourceRange, of: sourceAudioTrack, at: timeline)
                    let parameters = AVMutableAudioMixInputParameters(track: compositionAudioTrack)
                    let volume = Float(max(0, min(1, project.originalSound)))
                    applyFade(to: parameters, volume: volume, at: timeline, duration: duration)
                    audioParameters.append(parameters)
                    hasAudio = true
                }
            }

            timeline = timelineEnd
        }

        if let music = project.music {
            let musicURL = directory.appendingPathComponent(music.fileName)
            guard FileManager.default.fileExists(atPath: musicURL.path) else {
                throw MontageError.invalidMedia("The music file \(music.fileName) is unavailable.")
            }
            let musicAsset = AVURLAsset(url: musicURL)
            let musicTracks = try await musicAsset.loadTracks(withMediaType: .audio)
            guard let musicTrack = musicTracks.first else {
                throw MontageError.invalidMedia("The music file \(music.fileName) has no audio track.")
            }
            let musicStart = cmTime(plan.musicStartTime)
            let musicRange = CMTimeRange(start: musicStart, duration: timeline)
            let musicAssetDuration = try await musicAsset.load(.duration)
            guard CMTimeRangeGetEnd(musicRange) <= musicAssetDuration else {
                throw MontageError.shortMusic
            }
            let compositionMusicTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            guard let compositionMusicTrack else {
                throw MontageError.invalidMedia("The music composition track could not be created.")
            }
            try compositionMusicTrack.insertTimeRange(musicRange, of: musicTrack, at: .zero)
            let parameters = AVMutableAudioMixInputParameters(track: compositionMusicTrack)
            applyFade(to: parameters, volume: 1, at: .zero, duration: timeline)
            audioParameters.append(parameters)
            hasAudio = true
        }

        // Match shots across the whole edit, then apply the style's look.
        let corrections = ShotCorrection.matched(measurements)
        let look = ColorLook.style(for: plan.intent).adjusted(by: project.look)
        let edits = EditPlanner.edits(for: plan, music: project.music?.analysis,
                                      recipe: .recipe(for: plan.intent), scaleLimits: scaleLimits)
        let videoInstructions: [any AVVideoCompositionInstructionProtocol] = placedShots.enumerated().map { index, shot -> any AVVideoCompositionInstructionProtocol in
            LookInstruction(timeRange: shot.timeRange, trackID: shot.trackID, transform: shot.transform,
                            correction: corrections[index], look: look,
                            zooms: edits.filter { $0.segmentID == plan.segments[index].id }, focus: shot.focus)
        }

        guard let snapshot = composition.copy() as? AVComposition else {
            throw MontageError.invalidPlan("This edit could not be prepared for playback.")
        }
        // Derive format and color defaults from the completed asset. The
        // immutable snapshot also prevents playback from observing mutations.
        var videoConfiguration = try await AVVideoComposition.Configuration(for: snapshot)
        videoConfiguration.frameDuration = CMTime(value: 1, timescale: 30)
        videoConfiguration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        videoConfiguration.instructions = videoInstructions
        videoConfiguration.renderScale = 1
        videoConfiguration.renderSize = renderSize
        videoConfiguration.customVideoCompositorClass = LookCompositor.self
        // The compositor draws SDR frames. Tag the output to match, even when a
        // source clip is HDR.
        videoConfiguration.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoConfiguration.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoConfiguration.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        let videoComposition = AVVideoComposition(configuration: videoConfiguration)
        let (tracks, assetDuration) = try await snapshot.load(.tracks, .duration)
        let validation = CompositionValidationReporter()
        guard videoComposition.isValid(for: tracks, assetDuration: assetDuration,
                                       timeRange: CMTimeRange(start: .zero, duration: assetDuration), validationDelegate: validation) else {
            let report: [String: Any] = [
                "issues": validation.issues,
                "duration": assetDuration.seconds,
                "frameDuration": videoComposition.frameDuration.seconds,
                "renderWidth": videoComposition.renderSize.width,
                "renderHeight": videoComposition.renderSize.height,
                "tracks": tracks.map { $0.trackID },
                "instructions": videoInstructions.map { instruction -> [String: Any] in
                    ["start": instruction.timeRange.start.seconds, "duration": instruction.timeRange.duration.seconds,
                     "requiredTracks": instruction.requiredSourceTrackIDs ?? []]
                }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appending(path: "composition-diagnostic.json"), options: [.atomic])
            }
            throw MontageError.invalidPlan("This preview could not be assembled. Try another edit.")
        }

        let audioMix: AVAudioMix?
        if hasAudio {
            let mutableMix = AVMutableAudioMix()
            mutableMix.inputParameters = audioParameters
            audioMix = mutableMix
        } else {
            audioMix = nil
        }

        return CompositionBuildResult(
            composition: snapshot,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: timeline
        )
    }

    /// Convenience API for callers that only need a playable item.
    public func playerItem(project: MontageProject, plan: MontagePlan,
                           directory: URL) async throws -> AVPlayerItem {
        let assembly = try await build(project: project, plan: plan, directory: directory, preview: true)
        return await assembly.playerItem
    }

    private func validate(project: MontageProject, plan: MontagePlan) throws {
        let musicDuration = project.music?.analysis.duration ?? (plan.musicStartTime + plan.duration)
        try PlanValidator.validate(
            plan,
            target: project.targetDuration,
            assets: project.assets,
            musicDuration: musicDuration,
            rejectedSources: project.rejectedSourceIDs,
            rejectedMoments: project.rejectedMomentIDs
        )
    }

    /// Measures the average color and brightness of one shot from three small
    /// frames. Returns nil when no frame can be read; that shot is not corrected.
    private func measurement(for asset: AVURLAsset, start: Double, duration: Double) async -> ShotMeasurement? {
        let key = "\(asset.url.path)|\(Int((start * 600).rounded()))|\(Int((duration * 600).rounded()))"
        if let cached = measurementCache[key] { return cached }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        // Exact frames are not needed. A tolerance lets the decoder use nearby frames.
        let tolerance = cmTime(min(0.25, duration * 0.2))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [ShotMeasurement] = []
        for fraction in [0.2, 0.5, 0.8] {
            if Task.isCancelled { return nil }
            do {
                let (image, _) = try await generator.image(at: cmTime(start + duration * fraction))
                if let frame = Self.measure(image) { frames.append(frame) }
            } catch {
                // One unreadable frame does not block the edit.
            }
        }
        guard let result = ShotMeasurement.combine(frames) else { return nil }
        if measurementCache.count >= Self.maxCachedMeasurements { measurementCache.removeAll(keepingCapacity: true) }
        measurementCache[key] = result
        return result
    }

    private static func measure(_ image: CGImage) -> ShotMeasurement? {
        let width = 32
        let height = 32
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ShotMeasurement(rgba: pixels) : nil
    }

    private func renderSize(for ratio: OutputRatio, preview: Bool) -> CGSize {
        // 576 produces even, exact dimensions for every supported ratio.
        // H.264 encoders require even dimensions for 4:2:0 video.
        let width = CGFloat(preview ? 576 : ratio.width)
        let height = width * CGFloat(ratio.height) / CGFloat(ratio.width)
        return CGSize(width: width.rounded(.down), height: height.rounded(.down))
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(value: Int64((seconds * 600).rounded()), timescale: 600)
    }

    private func applyFade(to parameters: AVMutableAudioMixInputParameters, volume: Float,
                           at start: CMTime, duration: CMTime) {
        let fade = min(CMTimeGetSeconds(duration) * 0.5, 0.20)
        guard fade > 0 else {
            parameters.setVolume(volume, at: start)
            return
        }
        let fadeTime = CMTime(seconds: fade, preferredTimescale: 600)
        let end = start + duration
        parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                 timeRange: CMTimeRange(start: start, duration: fadeTime))
        parameters.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                 timeRange: CMTimeRange(start: end - fadeTime, duration: fadeTime))
    }

    private func placementTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform,
                                   subject: SubjectAnchor?, renderSize: CGSize) -> (transform: CGAffineTransform, focus: CGPoint) {
        let sourceRect = CGRect(origin: .zero, size: naturalSize)
        let transformedRect = sourceRect.applying(preferredTransform)
        let orientedSize = transformedRect.standardized.size
        let orient = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        )
        guard orientedSize.width > 0, orientedSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else {
            return (orient, CGPoint(x: renderSize.width / 2, y: renderSize.height / 2))
        }

        let sourceAspect = orientedSize.width / orientedSize.height
        let outputAspect = renderSize.width / renderSize.height
        let fillScale = max(renderSize.width / orientedSize.width,
                            renderSize.height / orientedSize.height)
        let visibleWidth = renderSize.width / fillScale / orientedSize.width
        let visibleHeight = renderSize.height / fillScale / orientedSize.height
        let anchor = subject.map { CGPoint(x: $0.x + $0.width * 0.5,
                                            y: $0.y + $0.height * 0.5) }
            ?? CGPoint(x: 0.5, y: 0.5)
        let sourceAnchor = CGPoint(x: anchor.x * orientedSize.width, y: anchor.y * orientedSize.height)
        func focus(_ placement: CGAffineTransform) -> CGPoint {
            let point = sourceAnchor.applying(placement)
            return CGPoint(x: min(renderSize.width, max(0, point.x)), y: min(renderSize.height, max(0, point.y)))
        }
        let subjectWidth = subject?.width ?? 0
        let needsLetterbox = sourceAspect > outputAspect &&
            (subject == nil || subjectWidth > visibleWidth || (subject?.height ?? 0) > visibleHeight)

        if needsLetterbox {
            let fitScale = min(renderSize.width / orientedSize.width,
                               renderSize.height / orientedSize.height)
            let fitSize = CGSize(width: orientedSize.width * fitScale,
                                 height: orientedSize.height * fitScale)
            let translate = CGAffineTransform(translationX: (renderSize.width - fitSize.width) * 0.5,
                                               y: (renderSize.height - fitSize.height) * 0.5)
            let placement = CGAffineTransform(scaleX: fitScale, y: fitScale).concatenating(translate)
            return (orient.concatenating(placement), focus(placement))
        }

        let cropWidth = renderSize.width / fillScale
        let cropHeight = renderSize.height / fillScale
        let cropX = min(max(anchor.x * orientedSize.width - cropWidth * 0.5, 0),
                        orientedSize.width - cropWidth)
        let cropY = min(max(anchor.y * orientedSize.height - cropHeight * 0.5, 0),
                        orientedSize.height - cropHeight)
        let translate = CGAffineTransform(translationX: -cropX * fillScale,
                                           y: -cropY * fillScale)
        let placement = CGAffineTransform(scaleX: fillScale, y: fillScale).concatenating(translate)
        return (orient.concatenating(placement), focus(placement))
    }
}
