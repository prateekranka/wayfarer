import Foundation
import Testing
@testable import MontageCore

private let skin = GradeRGB(0.85, 0.62, 0.50)
private let sky = GradeRGB(0.35, 0.55, 0.85)

private func uniformPixels(_ red: UInt8, _ green: UInt8, _ blue: UInt8, count: Int = 64) -> [UInt8] {
    (0..<count).flatMap { _ in [red, green, blue, 255] }
}

private func linearLuma(_ shot: ShotMeasurement, _ correction: ShotCorrection) -> (before: Double, after: Double) {
    let red = pow(shot.meanRed, 2.2), green = pow(shot.meanGreen, 2.2), blue = pow(shot.meanBlue, 2.2)
    let before = 0.2126 * red + 0.7152 * green + 0.0722 * blue
    let after = 0.2126 * red * correction.redGain + 0.7152 * green * correction.greenGain
        + 0.0722 * blue * correction.blueGain
    return (before, after)
}

@Test func neutralLookChangesNothing() {
    for color in [GradeRGB(0, 0, 0), GradeRGB(1, 1, 1), skin, sky, GradeRGB(0.2, 0.7, 0.1)] {
        #expect(ColorLook.neutral.apply(color) == color)
    }
}

@Test func everyStyleLookKeepsGraysOrderedAndInRange() {
    for intent in EditIntent.allCases {
        let look = ColorLook.style(for: intent)
        var previous = -1.0
        for step in 0...40 {
            let value = Double(step) / 40
            let output = look.apply(GradeRGB(value, value, value))
            for channel in [output.r, output.g, output.b] {
                #expect(channel >= 0 && channel <= 1, "\(look.id) left the 0...1 range at \(value)")
            }
            #expect(output.luma >= previous - 0.000001, "\(look.id) reversed brightness at \(value)")
            previous = output.luma
        }
    }
}

@Test func styleLooksAreDistinctAndNamed() {
    let looks = EditIntent.allCases.map(ColorLook.style(for:))
    #expect(Set(looks.map(\.id)).count == EditIntent.allCases.count)
    #expect(looks.allSatisfy { !$0.name.isEmpty && $0.strength > 0 })
}

@Test func cubeDataUsesRedFastestLayout() {
    let look = ColorLook.style(for: .cinematic)
    let data = look.cubeData(dimension: 3)
    #expect(data.count == 3 * 3 * 3 * 4)
    // Entry 1 is red = 0.5, green = 0, blue = 0.
    let expected = look.apply(GradeRGB(0.5, 0, 0))
    #expect(abs(Double(data[4]) - expected.r) < 0.0001)
    #expect(abs(Double(data[5]) - expected.g) < 0.0001)
    #expect(abs(Double(data[6]) - expected.b) < 0.0001)
    #expect(data[7] == 1)
    // Entry 9 is red = 0, green = 0, blue = 0.5.
    let blue = look.apply(GradeRGB(0, 0, 0.5))
    #expect(abs(Double(data[9 * 4 + 2]) - blue.b) < 0.0001)
}

@Test func skinWeightFindsSkinOnly() {
    #expect(ColorLook.skinWeight(skin) > 0.5)
    #expect(ColorLook.skinWeight(sky) == 0)
    #expect(ColorLook.skinWeight(GradeRGB(0.5, 0.5, 0.5)) == 0)
}

@Test func skinProtectionKeepsSkinCloserToOriginal() {
    var unprotected = ColorLook.style(for: .people)
    unprotected.skinProtection = 0
    let protected = ColorLook.style(for: .people)
    func change(_ look: ColorLook) -> Double {
        let output = look.apply(skin)
        return abs(output.r - skin.r) + abs(output.g - skin.g) + abs(output.b - skin.b)
    }
    #expect(change(protected) < change(unprotected) * 0.6)
}

@Test func filmLookCoolsShadowsAndWarmsHighlights() {
    let look = ColorLook.style(for: .cinematic)
    let shadow = look.apply(GradeRGB(0.15, 0.15, 0.15))
    let highlight = look.apply(GradeRGB(0.85, 0.85, 0.85))
    #expect(shadow.b > shadow.r)
    #expect(highlight.r > highlight.b)
}

@Test func lookSettingsScaleColorGrainAndVignette() {
    let look = ColorLook.style(for: .cinematic)
    let half = look.adjusted(by: LookSettings(strength: 0.5))
    #expect(half.strength == 0.5)
    #expect(half.grain == look.grain * 0.5)
    #expect(half.vignette == look.vignette * 0.5)
    #expect(look.adjusted(by: LookSettings()) == look)
    #expect(look.adjusted(by: LookSettings(isEnabled: false)) == .neutral)
    #expect(look.adjusted(by: LookSettings(strength: 0)) == .neutral)
}

@Test func lookSettingsSurviveSavingAndOlderProjectsStillOpen() throws {
    var project = MontageProject(name: "Trip")
    project.look = LookSettings(isEnabled: true, strength: 0.4)
    let saved = try JSONEncoder().encode(project)
    #expect(try JSONDecoder().decode(MontageProject.self, from: saved).look.strength == 0.4)

    var older = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    older.removeValue(forKey: "lookSettings")
    let reopened = try JSONDecoder().decode(MontageProject.self, from: JSONSerialization.data(withJSONObject: older))
    #expect(reopened.lookSettings == nil)
    #expect(reopened.look == LookSettings())
}

@Test func lookStrengthBlendsTowardOriginal() {
    var half = ColorLook.style(for: .beatSync)
    half.strength = 0.5
    let full = ColorLook.style(for: .beatSync).apply(sky)
    let mixed = half.apply(sky)
    #expect(abs(mixed.r - (sky.r + full.r) / 2) < 0.0001)
    #expect(abs(mixed.b - (sky.b + full.b) / 2) < 0.0001)
}

@Test func measurementReadsMeansAndHighlights() throws {
    let shot = try #require(ShotMeasurement(rgba: uniformPixels(255, 128, 0)))
    #expect(abs(shot.meanRed - 1) < 0.0001)
    #expect(abs(shot.meanGreen - 128.0 / 255) < 0.0001)
    #expect(shot.meanBlue == 0)
    #expect(abs(shot.brightLuma - shot.meanLuma) < 1.0 / 255)
    #expect(shot.sampleCount == 64)
    #expect(ShotMeasurement(rgba: []) == nil)
}

@Test func measurementHighlightUsesNinetyFifthPercentile() throws {
    // 90 dark pixels and 10 white pixels. The 95th percentile is white.
    let pixels = uniformPixels(20, 20, 20, count: 90) + uniformPixels(255, 255, 255, count: 10)
    let shot = try #require(ShotMeasurement(rgba: pixels))
    #expect(shot.brightLuma == 1)
    #expect(shot.meanLuma < 0.3)
}

@Test func combineWeightsByPixelCount() throws {
    let dark = try #require(ShotMeasurement(rgba: uniformPixels(0, 0, 0, count: 30)))
    let bright = try #require(ShotMeasurement(rgba: uniformPixels(255, 255, 255, count: 10)))
    let combined = try #require(ShotMeasurement.combine([dark, bright]))
    #expect(abs(combined.meanLuma - 0.25) < 0.0001)
    #expect(combined.brightLuma == 1)
    #expect(combined.sampleCount == 40)
    #expect(ShotMeasurement.combine([]) == nil)
}

@Test func darkShotBrightensAndBrightShotDarkens() throws {
    let dark = try #require(ShotMeasurement(rgba: uniformPixels(70, 70, 70)))
    let bright = try #require(ShotMeasurement(rgba: uniformPixels(200, 200, 200)))
    #expect(ShotCorrection.correction(for: dark, targetLuma: 0.46).exposureEV > 0.3)
    #expect(ShotCorrection.correction(for: bright, targetLuma: 0.46).exposureEV < -0.3)
    let good = try #require(ShotMeasurement(rgba: uniformPixels(117, 117, 117)))
    #expect(ShotCorrection.correction(for: good, targetLuma: 0.46).exposureEV == 0)
}

@Test func nightAndClippedShotsAreBrightenedLess() throws {
    let night = try #require(ShotMeasurement(rgba: uniformPixels(20, 20, 20)))
    #expect(ShotCorrection.correction(for: night, targetLuma: 0.46).exposureEV <= 0.4)
    // Mostly dark with bright lights. Brightening would clip the lights.
    let pixels = uniformPixels(60, 60, 60, count: 90) + uniformPixels(250, 250, 250, count: 10)
    let lights = try #require(ShotMeasurement(rgba: pixels))
    #expect(ShotCorrection.correction(for: lights, targetLuma: 0.46).exposureEV <= 0.15)
}

@Test func weakColorCastIsFixedMoreThanSunset() throws {
    let blueCast = try #require(ShotMeasurement(rgba: uniformPixels(115, 122, 143)))
    let sunset = try #require(ShotMeasurement(rgba: uniformPixels(217, 128, 64)))
    let castFix = ShotCorrection.correction(for: blueCast, targetLuma: 0.46)
    let sunsetFix = ShotCorrection.correction(for: sunset, targetLuma: 0.46)
    #expect(castFix.blueGain < castFix.redGain)
    let castChange = abs(castFix.blueGain - castFix.redGain)
    let sunsetChange = abs(sunsetFix.blueGain - sunsetFix.redGain)
    #expect(sunsetChange < castChange)
    for gain in [castFix.redGain, castFix.greenGain, castFix.blueGain,
                 sunsetFix.redGain, sunsetFix.greenGain, sunsetFix.blueGain] {
        #expect(gain >= 0.85 && gain <= 1.15)
    }
}

@Test func whiteBalanceKeepsBrightness() throws {
    let shot = try #require(ShotMeasurement(rgba: uniformPixels(115, 122, 143)))
    let correction = ShotCorrection.correction(for: shot, targetLuma: 0.46)
    let luma = linearLuma(shot, correction)
    #expect(abs(luma.after - luma.before) / luma.before < 0.01)
}

@Test func matchedCorrectionsFollowTheEdit() throws {
    let dark = try #require(ShotMeasurement(rgba: uniformPixels(75, 75, 75)))
    let matched = ShotCorrection.matched([dark, dark, dark, nil])
    let standard = ShotCorrection.correction(for: dark, targetLuma: ShotCorrection.standardLuma)
    #expect(matched.count == 4)
    #expect(matched[3] == .identity)
    // The target sits between the trip and a standard exposure.
    #expect(matched[0].exposureEV > 0)
    #expect(matched[0].exposureEV < standard.exposureEV)
    #expect(ShotCorrection.matched([nil, nil]) == [.identity, .identity])
}
