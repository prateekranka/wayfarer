import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import MontageCore

/// Everything the compositor needs to draw one shot of the edit.
///
/// Each instruction covers one segment and names one source track. The
/// transform is the same placement transform the layer instructions used
/// before, in AVFoundation's top-left coordinate space.
final class LookInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    // Grain changes on every frame, so frames are never reused.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let correction: ShotCorrection
    let look: ColorLook
    let zooms: [PlannedEdit]
    /// The point zooms center on, in the output frame with a top-left origin.
    let focus: CGPoint
    /// Titles drawn over the finished frame. Every shot carries all of them,
    /// because a title can stay on screen across cuts.
    let texts: [TextLayer]

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform,
         correction: ShotCorrection, look: ColorLook, zooms: [PlannedEdit], focus: CGPoint, texts: [TextLayer]) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.transform = transform
        self.correction = correction
        self.look = look
        self.zooms = zooms
        self.focus = focus
        self.texts = texts
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        super.init()
    }
}

enum LookCompositorError: LocalizedError {
    case unexpectedInstruction
    case noOutputBuffer

    var errorDescription: String? {
        switch self {
        case .unexpectedInstruction: "This edit could not be drawn. Try preparing it again."
        case .noOutputBuffer: "There isn’t enough memory to draw this edit right now."
        }
    }
}

/// Draws each frame with Core Image: place and crop the shot, correct it,
/// apply the style look, add grain and a vignette, then draw any title.
///
/// Preview and export both use this compositor, so they look the same.
/// HDR sources arrive as SDR frames because `supportsHDRSourceFrames` is
/// false; AVFoundation converts them before `startRequest` is called.
final class LookCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let cubeDimension = 33
    private static let maxCachedCubes = 8

    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Wayfarer look"])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    private let cubeColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var cubes: [ColorLook: Data] = [:]

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Each request carries its own render context. Nothing is cached per size.
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        // Core Image renders on the GPU. Drawing inline keeps the request on
        // the queue AVFoundation chose and avoids sharing it across threads.
        do {
            let frame = try render(request)
            request.finish(withComposedVideoFrame: frame)
        } catch {
            request.finish(with: error)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // Requests finish inside `startRequest`, so none are pending here.
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws -> CVPixelBuffer {
        guard let instruction = request.videoCompositionInstruction as? LookInstruction else {
            throw LookCompositorError.unexpectedInstruction
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            throw LookCompositorError.noOutputBuffer
        }
        let size = request.renderContext.size
        let frameRect = CGRect(origin: .zero, size: size)
        var frame = CIImage(color: .black).cropped(to: frameRect)

        if let source = request.sourceFrame(byTrackID: instruction.trackID) {
            var shot = CIImage(cvPixelBuffer: source)
            // Core Image uses a bottom-left origin. The placement transform
            // uses a top-left origin, so flip in and out around it.
            let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
            shot = shot
                .transformed(by: Self.flip(height: sourceHeight))
                .transformed(by: instruction.transform)
                .transformed(by: Self.flip(height: size.height))
                .cropped(to: frameRect)
            // Core Image can run the LUT after compositing, which tints the
            // bars even when the graded shot is cropped. Grading a clamped
            // image and then cropping keeps letterbox bars pure black.
            let picture = shot.extent
            shot = correct(zoom(shot, with: instruction, time: request.compositionTime, frameHeight: size.height).clampedToExtent(),
                           with: instruction.correction)
            shot = grade(shot, with: instruction.look)
            shot = addGrain(to: shot, amount: instruction.look.grain,
                            time: request.compositionTime, in: frameRect)
            frame = shot.cropped(to: picture).composited(over: frame)
        }

        frame = addVignette(to: frame, amount: instruction.look.vignette, in: frameRect)
        // Text goes on last, so the look never tints it.
        frame = drawText(over: frame, layers: instruction.texts, time: request.compositionTime.seconds)
        context.render(frame, to: output, bounds: frameRect, colorSpace: outputColorSpace)
        return output
    }

    /// Scales the picture around the subject, and stays inside the picture, so
    /// a zoom never spreads into letterbox bars. Only ever zooms in.
    private func zoom(_ image: CIImage, with instruction: LookInstruction, time: CMTime, frameHeight: CGFloat) -> CIImage {
        let scale = instruction.zooms.map { $0.scale(at: time.seconds) }.max() ?? 1
        guard scale > 1 else { return image }
        let center = CGPoint(x: instruction.focus.x, y: frameHeight - instruction.focus.y)
        let transform = CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        return image.transformed(by: transform).cropped(to: image.extent)
    }

    private static func flip(height: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
    }

    // MARK: Shot correction

    /// Exposure and white balance. Core Image's working space is linear, which
    /// is the space `ShotCorrection` values are calculated for.
    private func correct(_ image: CIImage, with correction: ShotCorrection) -> CIImage {
        guard !correction.isIdentity else { return image }
        var result = image
        if correction.exposureEV != 0 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = result
            exposure.ev = Float(correction.exposureEV)
            result = exposure.outputImage ?? result
        }
        if correction.redGain != 1 || correction.greenGain != 1 || correction.blueGain != 1 {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = result
            matrix.rVector = CIVector(x: CGFloat(correction.redGain), y: 0, z: 0, w: 0)
            matrix.gVector = CIVector(x: 0, y: CGFloat(correction.greenGain), z: 0, w: 0)
            matrix.bVector = CIVector(x: 0, y: 0, z: CGFloat(correction.blueGain), w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            result = matrix.outputImage ?? result
        }
        return result
    }

    // MARK: Style look

    /// Applies the look's color through a 3D LUT. The LUT works on sRGB
    /// values, which is the space `ColorLook.apply` is written for.
    private func grade(_ image: CIImage, with look: ColorLook) -> CIImage {
        guard look.strength > 0 else { return image }
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(Self.cubeDimension)
        cube.cubeData = cubeData(for: look)
        cube.colorSpace = cubeColorSpace
        return cube.outputImage ?? image
    }

    private func cubeData(for look: ColorLook) -> Data {
        if let cached = lock.withLock({ cubes[look] }) { return cached }
        let values = look.cubeData(dimension: Self.cubeDimension)
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.withLock {
            if cubes.count >= Self.maxCachedCubes { cubes.removeAll(keepingCapacity: true) }
            cubes[look] = data
        }
        return data
    }

    // MARK: Grain and vignette

    /// Fine monochrome grain that changes every frame. Soft light blending
    /// with a 0.5 gray leaves the picture unchanged, so only the noise shows.
    private func addGrain(to image: CIImage, amount: Double, time: CMTime, in rect: CGRect) -> CIImage {
        guard amount > 0, let noise = CIFilter.randomGenerator().outputImage else { return image }
        let frameIndex = Int64((max(0, time.seconds) * 30).rounded())
        let offsetX = CGFloat((frameIndex &* 7_919) % 2_048)
        let offsetY = CGFloat((frameIndex &* 104_729) % 2_048)
        let spread = CGFloat(min(0.5, amount * 8))
        let gray = CIFilter.colorMatrix()
        gray.inputImage = noise.transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
        // Use the red noise channel for all three, so grain has no color.
        gray.rVector = CIVector(x: spread, y: 0, z: 0, w: 0)
        gray.gVector = CIVector(x: spread, y: 0, z: 0, w: 0)
        gray.bVector = CIVector(x: spread, y: 0, z: 0, w: 0)
        gray.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let base = 0.5 - spread * 0.5
        gray.biasVector = CIVector(x: base, y: base, z: base, w: 1)
        guard let grain = gray.outputImage?.cropped(to: image.extent.intersection(rect)) else { return image }
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = grain
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: image.extent) ?? image
    }

    private func addVignette(to image: CIImage, amount: Double, in rect: CGRect) -> CIImage {
        guard amount > 0 else { return image }
        let vignette = CIFilter.vignetteEffect()
        vignette.inputImage = image
        vignette.center = CGPoint(x: rect.midX, y: rect.midY)
        vignette.radius = Float(hypot(rect.width, rect.height) * 0.32)
        vignette.intensity = Float(min(1, amount))
        return vignette.outputImage?.cropped(to: rect) ?? image
    }

    // MARK: Text

    /// Moves, scales, and fades each line that is on screen at `time`.
    private func drawText(over frame: CIImage, layers: [TextLayer], time: Double) -> CIImage {
        var result = frame
        for layer in layers where time >= layer.cue.start && time < layer.cue.end {
            let progress = min(1, max(0, (time - layer.cue.start) / max(0.001, layer.cue.entrance)))
            let eased = 1 - pow(1 - progress, 3)
            var image = layer.image
            var opacity = 1.0, scale = 1.0, lift = 0.0
            switch layer.entrance {
            case .fade:
                opacity = eased
            case .rise:
                opacity = eased
                lift = -(1 - eased) * image.extent.height * 0.4
            case .pop:
                opacity = min(1, progress * 3)
                scale = 0.7 + 0.3 * Self.overshoot(progress)
            case .typewriter:
                // Reveal whole characters, left to right, without moving the line.
                let count = min(layer.characterEdges.count, Int((progress * Double(layer.characterEdges.count)).rounded(.up)))
                guard count > 0 else { continue }
                image = image.cropped(to: CGRect(x: 0, y: 0, width: layer.characterEdges[count - 1],
                                                 height: image.extent.height))
            }
            if layer.exit == .fade, layer.cue.exit > 0 {
                opacity *= min(1, max(0, (layer.cue.end - time) / layer.cue.exit))
            }
            guard opacity > 0.001 else { continue }
            let size = layer.image.extent.size
            let placed = image.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: layer.center.x, y: layer.center.y + lift)))
            result = Self.faded(placed, by: opacity).composited(over: result)
        }
        return result
    }

    /// Eases out past 1 and settles back, for a small bounce.
    private static func overshoot(_ progress: Double) -> Double {
        let back = 1.70158, shifted = progress - 1
        return 1 + (back + 1) * pow(shifted, 3) + back * pow(shifted, 2)
    }

    /// Scales every channel, because the text image has premultiplied alpha.
    private static func faded(_ image: CIImage, by opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        let value = CGFloat(opacity)
        matrix.rVector = CIVector(x: value, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: value, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: value, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: value)
        matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return matrix.outputImage ?? image
    }
}
