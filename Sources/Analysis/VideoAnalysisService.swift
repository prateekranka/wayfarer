import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MontageCore
import UniformTypeIdentifiers
import Vision

/// Performs bounded, on-device video analysis. The actor owns all decoder and
/// Vision work so that a caller cannot concurrently mutate an analysis run.
public actor VideoAnalysisService: VideoAnalyzing {
    private struct FrameObservation {
        let time: Double
        let thumbnailData: Data?
        let features: MomentFeatures
        let semanticTags: [String]
        let subject: SubjectAnchor?
        let vector: [Float]
        let temporalDifference: Double
    }

    private struct PixelSummary {
        let meanRed: Double
        let meanGreen: Double
        let meanBlue: Double
        let meanLuminance: Double
        let contrast: Double
        let laplacianVariance: Double
        let spatialLuminance: [Double]
        let spatialSaturation: [Double]
        let vector: [Float]
    }

    private struct CandidateWindow {
        let start: Double
        let end: Double
        let observationIndex: Int
    }

    public init() {}

    public func analyze(asset: SourceAsset, directory: URL) async throws -> [CandidateMoment] {
        try Task.checkCancellation()

        let sourceURL = directory.appendingPathComponent(asset.fileName, isDirectory: false)
        let source = AVURLAsset(url: sourceURL)
        let durationTime: CMTime
        let tracks: [AVAssetTrack]
        do {
            (durationTime, tracks) = try await source.load(.duration, .tracks)
        } catch {
            throw MontageError.invalidMedia("This video cannot be read on this device.")
        }

        let duration = durationTime.seconds
        guard duration.isFinite, duration > 0 else {
            throw MontageError.invalidMedia("This video has no usable duration.")
        }
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw MontageError.invalidMedia("This file does not contain a video track.")
        }

        let generator = AVAssetImageGenerator(asset: source)
        generator.appliesPreferredTrackTransform = true // Decode in display orientation.
        generator.maximumSize = CGSize(width: 384, height: 384)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)

        let sampleCount = sampleCount(for: duration)
        let sampleInterval = duration / Double(sampleCount)
        var observations: [FrameObservation] = []
        observations.reserveCapacity(sampleCount)
        var previousVector: [Float]?

        for index in 0..<sampleCount {
            try Task.checkCancellation()
            let time = min(duration, (Double(index) + 0.5) * sampleInterval)
            let frame: CGImage
            do {
                (frame, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            } catch {
                // A damaged or unsupported sample does not invalidate otherwise usable footage.
                continue
            }

            let analysis = autoreleasepool { analyzeFrame(frame) }
            let difference = temporalDifference(analysis.vector, previousVector)
            var features = analysis.features
            features.motion = difference
            // Temporal pixel differences are only a camera-shake/motion proxy. They are not optical flow.
            features.stability = clamp(1.0 - difference * 1.15)
            features.interest = clamp(
                features.quality * 0.34
                    + features.composition * 0.18
                    + features.faces * 0.16
                    + features.scenery * 0.12
                    + features.food * 0.08
                    + features.motion * 0.08
            )
            features.novelty = clamp(min(1.0, difference * 2.2 + 0.22))
            observations.append(
                FrameObservation(
                    time: time,
                    thumbnailData: thumbnailData(frame),
                    features: features,
                    semanticTags: analysis.semanticTags,
                    subject: analysis.subject,
                    vector: analysis.vector,
                    temporalDifference: difference
                )
            )
            previousVector = analysis.vector
        }

        guard !observations.isEmpty else {
            throw MontageError.invalidMedia("This video has no decodable frames.")
        }

        let windows = makeCandidateWindows(observations: observations, duration: duration)
        var moments: [CandidateMoment] = []
        moments.reserveCapacity(windows.count)
        for (candidateIndex, window) in windows.enumerated() {
            try Task.checkCancellation()
            let representative = observations[window.observationIndex]
            let members = observations.filter { $0.time >= window.start && $0.time <= window.end }
            let aggregate = aggregateFeatures(members: members, representative: representative)
            let tags = Array(Set(members.flatMap(\.semanticTags))).sorted()
            let confidence = clamp(aggregate.interest * 0.68 + aggregate.quality * 0.22 + aggregate.composition * 0.10)
            let stableID = stableUUID(seed: "\(asset.id.uuidString)|\(window.start.rounded(toPlaces: 3))|\(window.end.rounded(toPlaces: 3))")
            let thumbnailFileName = writeThumbnail(
                representative.thumbnailData,
                directory: directory,
                name: "\(asset.id.uuidString)-moment-\(candidateIndex)-\(stableID.uuidString).jpg"
            )
            moments.append(
                CandidateMoment(
                    id: stableID,
                    sourceAssetID: asset.id,
                    sourceStartTime: window.start,
                    sourceEndTime: window.end,
                    features: aggregate,
                    semanticTags: tags,
                    timestamp: asset.timestamp?.addingTimeInterval(window.start),
                    confidence: confidence,
                    featureVector: representative.vector,
                    clusterID: -1,
                    subject: representative.subject,
                    thumbnailFileName: thumbnailFileName,
                    peakTime: representative.time
                )
            )
        }
        try Task.checkCancellation()
        let sounds = await ClipSignalAnalyzer.sounds(in: sourceURL)
        let times = moments.map { $0.peakTime ?? ($0.sourceStartTime + $0.sourceEndTime) / 2 }
        let motion = await ClipSignalAnalyzer.motion(in: sourceURL, at: times)
        for index in moments.indices {
            let moment = moments[index]
            let heard = Set(sounds.filter { $0.start < moment.sourceEndTime && $0.end > moment.sourceStartTime }.map(\.label))
            let measured = motion.first { $0.time == times[index] }
            let signals = MomentSignals(sounds: heard.sorted(), speed: measured?.speed,
                                        direction: measured?.direction, agreement: measured?.agreement)
            moments[index].signals = signals
            if let score = signals.motionScore { moments[index].features.motion = score }
        }
        return moments.sorted { $0.sourceStartTime < $1.sourceStartTime }
    }

    private func sampleCount(for duration: Double) -> Int {
        // Two samples/second for short clips, with a bounded 600-frame budget for long clips.
        let requested = min(600.0, max(2.0, ceil(duration * 2.0)))
        return max(2, Int(requested))
    }

    private func analyzeFrame(_ image: CGImage) -> (features: MomentFeatures, semanticTags: [String], subject: SubjectAnchor?, vector: [Float]) {
        let summary = pixelSummary(for: image)
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = false
        let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
        let classifyRequest = VNClassifyImageRequest()
        let aestheticsRequest = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try? handler.perform([faceRequest, humanRequest, saliencyRequest, classifyRequest, aestheticsRequest])

        let faces = faceRequest.results ?? []
        let humans = humanRequest.results ?? []
        let classification = classifyRequest.results ?? []
        let saliency = saliencyRequest.results?.first?.salientObjects?.first
        let subjectRect = saliency?.boundingBox ?? faces.first?.boundingBox ?? humans.first?.boundingBox
        let subject = subjectRect.map(subjectAnchor)
        let tags = semanticTags(for: classification, faceCount: faces.count, humanCount: humans.count)
        let scenery = tags.contains("landscape") || tags.contains("outdoor") ? 0.85 : tags.contains("architecture") ? 0.55 : 0.0
        let food = tags.contains("food") ? 0.9 : 0.0
        let faceScore = min(1.0, Double(faces.count) / 3.0)
        let peopleScore = min(1.0, Double(max(humans.count, faces.count)) / 3.0)
        let exposure = clamp(1.0 - abs(summary.meanLuminance - 0.5) * 2.0)
        let blur = clamp(1.0 - summary.laplacianVariance / 0.025)
        let aestheticScore = aestheticsRequest.results?.first.map { clamp((Double($0.overallScore) + 1.0) / 2.0) } ?? 0.5
        let composition = compositionScore(subject: subject, width: Double(image.width), height: Double(image.height))
        let quality = clamp(
            exposure * 0.25
                + (1.0 - blur) * 0.20
                + summary.contrast * 0.20
                + composition * 0.15
                + aestheticScore * 0.20
        )
        var features = MomentFeatures()
        features.quality = quality
        features.composition = composition
        features.exposure = exposure
        features.blur = blur
        features.faces = faceScore
        features.people = peopleScore
        features.scenery = scenery
        features.food = food
        return (features, tags, subject, summary.vector)
    }

    private func pixelSummary(for image: CGImage) -> PixelSummary {
        let sourceWidth = max(1, image.width)
        let sourceHeight = max(1, image.height)
        let scale = min(1.0, 384.0 / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int(Double(sourceWidth) * scale))
        let height = max(1, Int(Double(sourceHeight) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var sumL = 0.0
        var sumL2 = 0.0
        var tileL = [Double](repeating: 0, count: 4)
        var tileS = [Double](repeating: 0, count: 4)
        var tileCounts = [Int](repeating: 0, count: 4)
        var luminance = [Double](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let red = Double(pixels[pixelIndex]) / 255.0
                let green = Double(pixels[pixelIndex + 1]) / 255.0
                let blue = Double(pixels[pixelIndex + 2]) / 255.0
                let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
                let saturation = max(red, max(green, blue)) - min(red, min(green, blue))
                sumR += red; sumG += green; sumB += blue; sumL += luma; sumL2 += luma * luma
                luminance[y * width + x] = luma
                let tileX = x >= width / 2 ? 1 : 0
                let tileY = y >= height / 2 ? 1 : 0
                let tile = tileY * 2 + tileX
                tileL[tile] += luma
                tileS[tile] += saturation
                tileCounts[tile] += 1
            }
        }
        let count = Double(max(1, width * height))
        let meanL = sumL / count
        let variance = max(0.0, sumL2 / count - meanL * meanL)
        let contrast = clamp(sqrt(variance) * 3.2)
        let laplacianVariance = laplacianVariance(of: luminance, width: width, height: height)
        for index in tileL.indices {
            let tileCount = Double(max(1, tileCounts[index]))
            tileL[index] /= tileCount
            tileS[index] /= tileCount
        }
        let vector = ([(sumR / count), (sumG / count), (sumB / count), meanL, contrast] + tileL + tileS).map { Float($0) }
        return PixelSummary(
            meanRed: sumR / count,
            meanGreen: sumG / count,
            meanBlue: sumB / count,
            meanLuminance: meanL,
            contrast: contrast,
            laplacianVariance: laplacianVariance,
            spatialLuminance: tileL,
            spatialSaturation: tileS,
            vector: vector
        )
    }

    private func laplacianVariance(of luminance: [Double], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3 else { return 0 }
        var values: [Double] = []
        values.reserveCapacity((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = luminance[y * width + x]
                let laplacian = luminance[(y - 1) * width + x]
                    + luminance[(y + 1) * width + x]
                    + luminance[y * width + x - 1]
                    + luminance[y * width + x + 1]
                    - 4.0 * center
                values.append(laplacian)
            }
        }
        let mean = values.reduce(0, +) / Double(max(1, values.count))
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, values.count))
    }

    private func semanticTags(for classifications: [VNClassificationObservation], faceCount: Int, humanCount: Int) -> [String] {
        var tags = Set<String>()
        for result in classifications where result.confidence >= 0.25 {
            let label = result.identifier.lowercased()
            if labelMatches(label, words: ["landscape", "mountain", "beach", "coast", "lake", "waterfall", "sky", "sunset", "forest", "desert", "park", "garden"]) { tags.insert("landscape") }
            if labelMatches(label, words: ["sunset", "sunrise", "dusk"]) { tags.insert("sunset") }
            if labelMatches(label, words: ["food", "dish", "meal", "cuisine", "dessert", "fruit", "vegetable", "pizza", "sushi", "cake", "bread"]) { tags.insert("food") }
            if labelMatches(label, words: ["building", "architecture", "house", "tower", "bridge", "church", "temple", "monument", "skyscraper"]) { tags.insert("architecture") }
            if labelMatches(label, words: ["street", "road", "avenue", "sidewalk", "city", "urban", "traffic"]) { tags.insert("street") }
            if labelMatches(label, words: ["car", "vehicle", "bus", "train", "airplane", "boat", "bicycle", "motorcycle"]) { tags.insert("vehicle") }
            if labelMatches(label, words: ["indoor", "room", "kitchen", "office", "interior", "living room"]) { tags.insert("indoor") }
            if labelMatches(label, words: ["outdoor", "outside", "nature", "wilderness"]) { tags.insert("outdoor") }
            if labelMatches(label, words: ["person", "people", "crowd", "human", "portrait"]) { tags.insert("people") }
        }
        if faceCount > 0 || humanCount > 0 { tags.insert("people") }
        return tags.sorted()
    }

    private func labelMatches(_ label: String, words: [String]) -> Bool {
        words.contains { label == $0 || label.contains($0) }
    }

    private func subjectAnchor(_ rect: CGRect) -> SubjectAnchor {
        // Vision uses a bottom-left origin. Candidate subjects use a top-left origin.
        SubjectAnchor(x: Double(rect.origin.x), y: Double(1.0 - rect.maxY), width: Double(rect.width), height: Double(rect.height))
    }

    private func compositionScore(subject: SubjectAnchor?, width: Double, height: Double) -> Double {
        guard let subject else { return 0.5 }
        let centerX = subject.x + subject.width / 2.0
        let centerY = subject.y + subject.height / 2.0
        let thirdsX = [1.0 / 3.0, 2.0 / 3.0]
        let thirdsY = [1.0 / 3.0, 2.0 / 3.0]
        let nearestX = thirdsX.map { abs(centerX - $0) }.min() ?? 0.5
        let nearestY = thirdsY.map { abs(centerY - $0) }.min() ?? 0.5
        let thirdsScore = 1.0 - min(1.0, (nearestX + nearestY) * 1.8)
        let centerScore = 1.0 - min(1.0, hypot(centerX - 0.5, centerY - 0.5) * 1.2)
        _ = width; _ = height
        return clamp(thirdsScore * 0.65 + centerScore * 0.35)
    }

    private func temporalDifference(_ current: [Float], _ previous: [Float]?) -> Double {
        guard let previous, previous.count == current.count, !current.isEmpty else { return 0 }
        let sum = zip(current, previous).reduce(0.0) { result, pair in
            result + abs(Double(pair.0) - Double(pair.1))
        }
        return clamp(sum / Double(current.count) * 2.5)
    }

    private func makeCandidateWindows(observations: [FrameObservation], duration: Double) -> [CandidateWindow] {
        guard !observations.isEmpty else { return [] }
        let interval = observations.count > 1 ? observations[1].time - observations[0].time : duration
        let threshold = max(0.28, observations.map(\.temporalDifference).reduce(0, +) / Double(observations.count) * 2)
        var boundaries = [0.0]
        for index in observations.indices.dropFirst() where observations[index].temporalDifference >= threshold {
            let time = max(0, observations[index].time - interval / 2)
            if time - (boundaries.last ?? 0) >= 0.5 { boundaries.append(time) }
        }
        boundaries.append(duration)
        var windows: [CandidateWindow] = []
        for scene in 0..<(boundaries.count - 1) {
            let start = boundaries[scene], end = boundaries[scene + 1]
            guard end - start >= 0.5 else { continue }
            // Analysis sampling resolution must not set the maximum shot length.
            // Scene regions retain room for a cinematic shot, while peakTime tells
            // the planner where to center a shorter rhythmic insert.
            let count = max(1, Int(ceil((end - start) / 3.5)))
            let size = (end - start) / Double(count)
            for block in 0..<count where windows.count < 120 {
                let lower = start + Double(block) * size + (block == 0 && start == 0 ? 0.12 : 0.025)
                let upper = min(end, start + Double(block + 1) * size) - 0.025
                guard upper - lower >= 0.5 else { continue }
                let indices = observations.indices.filter { observations[$0].time >= lower && observations[$0].time <= upper }
                guard let best = indices.max(by: { observations[$0].features.interest < observations[$1].features.interest }) else { continue }
                windows.append(CandidateWindow(start: lower, end: upper, observationIndex: best))
            }
        }
        return windows
    }

    private func aggregateFeatures(members: [FrameObservation], representative: FrameObservation) -> MomentFeatures {
        guard !members.isEmpty else { return representative.features }
        var result = MomentFeatures()
        let count = Double(members.count)
        result.quality = members.map(\.features.quality).reduce(0, +) / count
        result.interest = members.map(\.features.interest).max() ?? representative.features.interest
        result.motion = members.map(\.features.motion).reduce(0, +) / count
        result.stability = members.map(\.features.stability).reduce(0, +) / count
        result.faces = members.map(\.features.faces).max() ?? representative.features.faces
        result.people = members.map(\.features.people).max() ?? representative.features.people
        result.scenery = members.map(\.features.scenery).max() ?? representative.features.scenery
        result.food = members.map(\.features.food).max() ?? representative.features.food
        result.novelty = members.map(\.features.novelty).max() ?? representative.features.novelty
        result.composition = members.map(\.features.composition).max() ?? representative.features.composition
        result.exposure = members.map(\.features.exposure).reduce(0, +) / count
        result.blur = members.map(\.features.blur).reduce(0, +) / count
        return result
    }

    private func thumbnailData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func writeThumbnail(_ data: Data?, directory: URL, name: String) -> String? {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard let data else { return nil }
        do { try data.write(to: url, options: .atomic); return name }
        catch { return nil }
    }

    private func stableUUID(seed: String) -> UUID {
        var hash0: UInt64 = 0xcbf29ce484222325
        var hash1: UInt64 = 0x9e3779b185ebca87
        for byte in seed.utf8 {
            hash0 ^= UInt64(byte); hash0 &*= 0x100000001b3
            hash1 ^= UInt64(byte); hash1 &*= 0x100000001b3
            hash1 = (hash1 << 7) | (hash1 >> 57)
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8((hash0 >> UInt64(index * 8)) & 0xff) }
        for index in 0..<8 { bytes[index + 8] = UInt8((hash1 >> UInt64(index * 8)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1.0, max(0.0, value))
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
