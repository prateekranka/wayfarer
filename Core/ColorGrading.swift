import Foundation

// Color math for automatic shot correction and per-style looks.
//
// Everything in this file is pure and deterministic, so it can be tested
// without media. `Sources/Rendering` turns these values into Core Image
// filters. The same values drive preview and export.

/// A red, green, blue triple. Use it for colors and for small color offsets.
public struct GradeRGB: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    public static let zero = GradeRGB(0, 0, 0)

    /// Rec. 709 luma weights on the stored values.
    public var luma: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    func map(_ transform: (Double) -> Double) -> GradeRGB {
        GradeRGB(transform(r), transform(g), transform(b))
    }

    var clamped: GradeRGB { map { ColorMath.clamp($0) } }

    static func + (lhs: GradeRGB, rhs: GradeRGB) -> GradeRGB { GradeRGB(lhs.r + rhs.r, lhs.g + rhs.g, lhs.b + rhs.b) }
    static func - (lhs: GradeRGB, rhs: GradeRGB) -> GradeRGB { GradeRGB(lhs.r - rhs.r, lhs.g - rhs.g, lhs.b - rhs.b) }
    static func * (lhs: GradeRGB, rhs: Double) -> GradeRGB { GradeRGB(lhs.r * rhs, lhs.g * rhs, lhs.b * rhs) }
}

enum ColorMath {
    static func clamp(_ value: Double, _ low: Double = 0, _ high: Double = 1) -> Double {
        guard value.isFinite else { return low }
        return min(high, max(low, value))
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        guard edge1 > edge0 else { return value < edge0 ? 0 : 1 }
        let t = clamp((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    /// Approximate sRGB decoding. Precise enough for averages and gains.
    static func linear(_ value: Double) -> Double { pow(clamp(value), 2.2) }
}

// MARK: - Measuring a shot

/// Simple color statistics for one shot, measured from a few small frames.
///
/// Values use gamma-encoded sRGB in 0...1, as stored in an 8-bit image.
public struct ShotMeasurement: Codable, Equatable, Sendable {
    public var meanRed: Double
    public var meanGreen: Double
    public var meanBlue: Double
    public var meanLuma: Double
    /// The 95th percentile luma. A high value means bright highlights that a
    /// brighter exposure would clip.
    public var brightLuma: Double
    public var sampleCount: Int

    public init(meanRed: Double, meanGreen: Double, meanBlue: Double,
                meanLuma: Double, brightLuma: Double, sampleCount: Int) {
        self.meanRed = meanRed; self.meanGreen = meanGreen; self.meanBlue = meanBlue
        self.meanLuma = meanLuma; self.brightLuma = brightLuma; self.sampleCount = sampleCount
    }

    /// Measures 8-bit RGBA pixels in sRGB. Alpha is ignored.
    /// Returns nil when there are no pixels.
    public init?(rgba: [UInt8]) {
        let count = rgba.count / 4
        guard count > 0 else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        var red = 0.0, green = 0.0, blue = 0.0, luma = 0.0
        for index in 0..<count {
            let r = Double(rgba[index * 4]) / 255
            let g = Double(rgba[index * 4 + 1]) / 255
            let b = Double(rgba[index * 4 + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            red += r; green += g; blue += b; luma += y
            histogram[min(255, max(0, Int((y * 255).rounded())))] += 1
        }
        let threshold = Int((Double(count) * 0.95).rounded(.up))
        var cumulative = 0
        var bright = 255
        for (bin, value) in histogram.enumerated() {
            cumulative += value
            if cumulative >= threshold { bright = bin; break }
        }
        let total = Double(count)
        self.init(meanRed: red / total, meanGreen: green / total, meanBlue: blue / total,
                  meanLuma: luma / total, brightLuma: Double(bright) / 255, sampleCount: count)
    }

    /// Combines frame measurements from the same shot. Means are weighted by
    /// pixel count. The brightest highlight value is kept, to stay safe.
    public static func combine(_ items: [ShotMeasurement]) -> ShotMeasurement? {
        let total = items.reduce(0) { $0 + max(0, $1.sampleCount) }
        guard total > 0 else { return nil }
        func mean(_ value: KeyPath<ShotMeasurement, Double>) -> Double {
            items.reduce(0) { $0 + $1[keyPath: value] * Double(max(0, $1.sampleCount)) } / Double(total)
        }
        return ShotMeasurement(meanRed: mean(\.meanRed), meanGreen: mean(\.meanGreen),
                               meanBlue: mean(\.meanBlue), meanLuma: mean(\.meanLuma),
                               brightLuma: items.map(\.brightLuma).max() ?? 1, sampleCount: total)
    }
}

// MARK: - Correcting a shot

/// A gentle fix for one shot: an exposure change and white-balance gains.
///
/// The goal is to make shots from different clips look like they belong
/// together. It is not meant to fully neutralize a scene. Sunsets, forests,
/// and night scenes keep most of their mood.
public struct ShotCorrection: Codable, Equatable, Sendable {
    /// Exposure change in stops. Applied in linear light.
    public var exposureEV: Double
    /// Linear-light channel multipliers. They keep overall brightness the same.
    public var redGain: Double
    public var greenGain: Double
    public var blueGain: Double

    public init(exposureEV: Double = 0, redGain: Double = 1, greenGain: Double = 1, blueGain: Double = 1) {
        self.exposureEV = exposureEV; self.redGain = redGain
        self.greenGain = greenGain; self.blueGain = blueGain
    }

    public static let identity = ShotCorrection()

    public var isIdentity: Bool {
        exposureEV == 0 && redGain == 1 && greenGain == 1 && blueGain == 1
    }

    /// The brightness a well-exposed travel shot usually has.
    public static let standardLuma = 0.46
    /// How much of the exposure difference to fix. Less than 1 keeps some mood.
    static let exposureStrength = 0.7
    /// The largest white-balance fix for a small, unwanted color cast.
    static let whiteBalanceStrength = 0.6
    static let gainRange = 0.88...1.12

    /// Returns one correction per shot, matched across the whole edit.
    ///
    /// The target brightness is halfway between a standard exposure and the
    /// edit's median shot. A dark, moody trip stays a little darker, but one
    /// very dark or very bright shot moves toward its neighbours.
    /// A shot without a measurement gets no correction.
    public static func matched(_ measurements: [ShotMeasurement?]) -> [ShotCorrection] {
        let lumas = measurements.compactMap { $0?.meanLuma }.filter(\.isFinite).sorted()
        guard !lumas.isEmpty else { return measurements.map { _ in .identity } }
        let middle = lumas.count / 2
        let median = lumas.count.isMultiple(of: 2) ? (lumas[middle - 1] + lumas[middle]) / 2 : lumas[middle]
        let target = ColorMath.clamp(0.5 * standardLuma + 0.5 * median, 0.30, 0.55)
        return measurements.map { measurement in
            measurement.map { correction(for: $0, targetLuma: target) } ?? .identity
        }
    }

    /// The correction for one shot toward a target brightness.
    public static func correction(for shot: ShotMeasurement, targetLuma: Double) -> ShotCorrection {
        // Exposure. Work in linear light, then fix only part of the difference.
        let current = max(0.02, ColorMath.clamp(shot.meanLuma))
        var exposure = log2(ColorMath.linear(targetLuma) / ColorMath.linear(current)) * exposureStrength
        var upper = 0.8
        // Night shots get noisy when brightened a lot.
        if shot.meanLuma < 0.15 { upper = 0.4 }
        // Do not push already bright highlights into clipping.
        if shot.brightLuma > 0.92 { upper = min(upper, 0.15) }
        exposure = ColorMath.clamp(exposure, -0.6, upper)
        if abs(exposure) < 0.05 || !exposure.isFinite { exposure = 0 }
        exposure = (exposure * 1000).rounded() / 1000

        // White balance. A gray-world estimate, used only partly.
        let red = ColorMath.linear(shot.meanRed)
        let green = ColorMath.linear(shot.meanGreen)
        let blue = ColorMath.linear(shot.meanBlue)
        guard red > 0.0005, green > 0.0005, blue > 0.0005 else {
            return ShotCorrection(exposureEV: exposure)
        }
        let gray = (red + green + blue) / 3
        var gains = GradeRGB(gray / red, gray / green, gray / blue)
        // A strong cast is usually the scene itself (sunset, forest, neon).
        // Fix weak casts more and strong casts less.
        let cast = max(abs(gains.r - 1), abs(gains.g - 1), abs(gains.b - 1))
        let strength = whiteBalanceStrength * (1 - ColorMath.smoothstep(0.15, 0.45, cast))
        gains = gains.map { 1 + ($0 - 1) * strength }
            .map { ColorMath.clamp($0, gainRange.lowerBound, gainRange.upperBound) }
        // Keep the shot's brightness. Exposure handles brightness separately.
        let before = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let after = 0.2126 * red * gains.r + 0.7152 * green * gains.g + 0.0722 * blue * gains.b
        if after > 0 { gains = gains * (before / after) }
        gains = gains.map { ($0 * 1000).rounded() / 1000 }
        return ShotCorrection(exposureEV: exposure, redGain: gains.r, greenGain: gains.g, blueGain: gains.b)
    }
}

// MARK: - Style looks

/// The user's choice for how much of the style look to use.
/// Shot correction is not affected, so clips still match when the look is off.
public struct LookSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// 0 is no look. 1 is the full look.
    public var strength: Double

    public init(isEnabled: Bool = true, strength: Double = 1) {
        self.isEnabled = isEnabled; self.strength = strength
    }
}

/// A creative color look for one edit style.
///
/// Rendering bakes `apply(_:)` into a 3D lookup table (LUT), then adds grain
/// and a vignette. All color values are gamma-encoded sRGB in 0...1.
public struct ColorLook: Codable, Hashable, Sendable, Identifiable {
    /// Change this when the look math or presets change, so cached previews
    /// are rendered again.
    public static let version = 2

    public var id: String
    public var name: String
    /// How much of the look to use. 0 is the corrected shot, 1 is the full look.
    public var strength: Double
    /// Warm (positive) or cool (negative) shift. About -1...1.
    public var warmth: Double
    /// Green (positive) or magenta (negative) shift. About -1...1.
    public var tint: Double
    /// S-curve contrast. 0 is none, 1 is strong.
    public var contrast: Double
    /// 1 keeps saturation. Above 1 is more colorful.
    public var saturation: Double
    /// Extra saturation for muted colors only. 0...1.
    public var vibrance: Double
    /// Lifts pure black to this value for a soft, film-like base. 0...0.1.
    public var blackLift: Double
    /// Softens the brightest parts so they do not look harsh. 0...1.
    public var highlightRollOff: Double
    /// Color added to dark areas.
    public var shadowTint: GradeRGB
    /// Color added to bright areas.
    public var highlightTint: GradeRGB
    /// How much skin tones are kept close to the original. 0...1.
    public var skinProtection: Double
    /// Film grain amount. 0...0.05. Applied by the renderer.
    public var grain: Double
    /// Darkened edges. 0...1. Applied by the renderer.
    public var vignette: Double

    public init(id: String, name: String, strength: Double = 1, warmth: Double = 0, tint: Double = 0,
                contrast: Double = 0, saturation: Double = 1, vibrance: Double = 0, blackLift: Double = 0,
                highlightRollOff: Double = 0, shadowTint: GradeRGB = .zero, highlightTint: GradeRGB = .zero,
                skinProtection: Double = 0, grain: Double = 0, vignette: Double = 0) {
        self.id = id; self.name = name; self.strength = strength; self.warmth = warmth; self.tint = tint
        self.contrast = contrast; self.saturation = saturation; self.vibrance = vibrance
        self.blackLift = blackLift; self.highlightRollOff = highlightRollOff
        self.shadowTint = shadowTint; self.highlightTint = highlightTint
        self.skinProtection = skinProtection; self.grain = grain; self.vignette = vignette
    }

    /// A look that changes nothing.
    public static let neutral = ColorLook(id: "neutral", name: "Natural", strength: 0)

    /// The automatic look for each edit style.
    public static func style(for intent: EditIntent) -> ColorLook {
        switch intent {
        case .beatSync:
            ColorLook(id: "punchy", name: "Punchy", strength: 0.7, contrast: 0.35, saturation: 1.12, vibrance: 0.2,
                      highlightRollOff: 0.1, shadowTint: GradeRGB(-0.01, 0, 0.02),
                      highlightTint: GradeRGB(0.015, 0.005, -0.01), skinProtection: 0.3, vignette: 0.25)
        case .story:
            ColorLook(id: "warm-memory", name: "Warm memory", strength: 0.6, warmth: 0.35, contrast: 0.15, saturation: 0.95,
                      vibrance: 0.1, blackLift: 0.035, highlightRollOff: 0.25,
                      shadowTint: GradeRGB(0.02, 0.01, -0.01), highlightTint: GradeRGB(0.02, 0.01, 0),
                      skinProtection: 0.5, grain: 0.02, vignette: 0.2)
        case .cinematic:
            ColorLook(id: "film", name: "Film", strength: 0.55, warmth: 0.05, contrast: 0.3, saturation: 0.9, vibrance: 0.05,
                      blackLift: 0.03, highlightRollOff: 0.3, shadowTint: GradeRGB(-0.035, 0.01, 0.03),
                      highlightTint: GradeRGB(0.035, 0.012, -0.025), skinProtection: 0.6,
                      grain: 0.025, vignette: 0.35)
        case .highlights:
            ColorLook(id: "clean-pop", name: "Clean pop", strength: 0.65, warmth: 0.05, contrast: 0.2, saturation: 1.06,
                      vibrance: 0.25, highlightRollOff: 0.15, skinProtection: 0.3, vignette: 0.1)
        case .people:
            ColorLook(id: "soft-skin", name: "Soft skin", strength: 0.5, warmth: 0.15, contrast: 0.1, saturation: 0.97,
                      vibrance: 0.15, blackLift: 0.015, highlightRollOff: 0.25,
                      highlightTint: GradeRGB(0.01, 0.005, 0), skinProtection: 0.9, grain: 0.01, vignette: 0.15)
        case .places:
            ColorLook(id: "rich-color", name: "Rich color", strength: 0.7, contrast: 0.22, saturation: 1.05, vibrance: 0.4,
                      highlightRollOff: 0.2, shadowTint: GradeRGB(-0.01, 0, 0.015),
                      skinProtection: 0.4, vignette: 0.2)
        case .travel:
            ColorLook(id: "journey", name: "Journey", strength: 0.6, warmth: 0.15, contrast: 0.2, saturation: 1.03,
                      vibrance: 0.25, blackLift: 0.01, highlightRollOff: 0.2, skinProtection: 0.5,
                      grain: 0.012, vignette: 0.12)
        }
    }

    /// This look scaled by the user's settings. Strength also scales grain and
    /// the vignette, because they are not part of the LUT.
    public func adjusted(by settings: LookSettings) -> ColorLook {
        let amount = settings.isEnabled ? ColorMath.clamp(settings.strength) : 0
        guard amount > 0 else { return .neutral }
        var result = self
        result.strength = ColorMath.clamp(strength) * amount
        result.grain = grain * amount
        result.vignette = vignette * amount
        return result
    }

    /// Applies the color part of the look to one gamma-encoded sRGB color.
    /// Grain and vignette are not included; they depend on pixel position.
    public func apply(_ input: GradeRGB) -> GradeRGB {
        let source = input.clamped
        let amount = ColorMath.clamp(strength)
        guard amount > 0 else { return source }
        var color = source

        // 1. Warm or cool, and green or magenta. Small, simple channel scales.
        color.r *= 1 + warmth * 0.10
        color.b *= 1 - warmth * 0.10
        color.g *= 1 + tint * 0.06
        color = color.clamped

        // 2. Contrast with a smooth S-curve around the middle.
        let curve = ColorMath.clamp(contrast)
        color = color.map { value in value + curve * (value * value * (3 - 2 * value) - value) }

        // 3. Saturation and vibrance. Vibrance lifts muted colors more.
        let luma = color.luma
        let chroma = max(color.r, color.g, color.b) - min(color.r, color.g, color.b)
        let factor = max(0, saturation) * (1 + ColorMath.clamp(vibrance) * (1 - ColorMath.clamp(chroma / 0.6)))
        color = color.map { luma + ($0 - luma) * factor }

        // 4. Split toning: one color in the shadows, another in the highlights.
        let level = ColorMath.clamp(color.luma)
        color = color + shadowTint * ((1 - level) * (1 - level)) + highlightTint * (level * level)

        // 5. Soft highlights, then a lifted black.
        let rollOff = ColorMath.clamp(highlightRollOff)
        let lift = ColorMath.clamp(blackLift, 0, 0.2)
        color = color.clamped.map { value in
            var result = value
            let knee = 0.7
            if result > knee {
                let t = (result - knee) / (1 - knee)
                result = knee + (1 - knee) * (t - rollOff * 0.5 * t * t)
            }
            return lift + result * (1 - lift)
        }
        color = color.clamped

        // 6. Keep skin close to the original.
        let protection = ColorMath.clamp(skinProtection) * Self.skinWeight(source)
        if protection > 0 {
            color = color + (source - color) * (protection * 0.7)
        }

        // 7. Mix with the original by the look strength.
        return (source + (color - source) * amount).clamped
    }

    /// Returns RGBA float data for a cube LUT, red changing fastest, then
    /// green, then blue. This is the layout `CIColorCubeWithColorSpace` reads.
    public func cubeData(dimension: Int = 33) -> [Float] {
        let size = max(2, dimension)
        var data = [Float]()
        data.reserveCapacity(size * size * size * 4)
        let scale = 1 / Double(size - 1)
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let output = apply(GradeRGB(Double(red) * scale, Double(green) * scale, Double(blue) * scale))
                    data.append(Float(output.r)); data.append(Float(output.g))
                    data.append(Float(output.b)); data.append(1)
                }
            }
        }
        return data
    }

    /// How much a color looks like skin, from 0 to 1.
    /// Skin across many tones sits in a narrow orange hue range with medium
    /// saturation. This is a rough guide, not a skin detector.
    static func skinWeight(_ color: GradeRGB) -> Double {
        let high = max(color.r, color.g, color.b)
        let low = min(color.r, color.g, color.b)
        let delta = high - low
        guard high > 0, delta > 0 else { return 0 }
        let saturation = delta / high
        var hue: Double
        if high == color.r {
            hue = 60 * ((color.g - color.b) / delta)
        } else if high == color.g {
            hue = 60 * ((color.b - color.r) / delta + 2)
        } else {
            hue = 60 * ((color.r - color.g) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        let hueWeight = ColorMath.smoothstep(2, 12, hue) * (1 - ColorMath.smoothstep(40, 55, hue))
        let saturationWeight = ColorMath.smoothstep(0.10, 0.20, saturation)
            * (1 - ColorMath.smoothstep(0.60, 0.75, saturation))
        let brightnessWeight = ColorMath.smoothstep(0.15, 0.30, high)
        return hueWeight * saturationWeight * brightnessWeight
    }
}
