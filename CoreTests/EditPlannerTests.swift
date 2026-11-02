import Foundation
import Testing
@testable import MontageCore

private func recipe(_ zooms: [ZoomKind], intensity: Double = 0.5) -> StyleRecipe {
    StyleRecipe(shortestShot: 1, longestShot: 5, beatsWhenLoud: 2, beatsWhenQuiet: 4, mostMomentsPerClip: 2,
                cutTolerance: 0.2, opening: .wide, ending: .calm, zooms: zooms, zoomIntensity: intensity)
}

private func plan(_ durations: [Double]) -> MontagePlan {
    MontagePlan(name: "Edit", summary: "", intent: .story, seed: 1, musicStartTime: 0,
                segments: durations.map { MontageSegment(momentID: UUID(), sourceAssetID: UUID(), sourceStartTime: 0, duration: $0) })
}

private func music(peak: Double? = nil, bpm: Double? = 120) -> MusicAnalysis {
    var events = stride(from: 0.0, through: 60.0, by: 0.5).map { MusicEvent(time: $0, kind: .strongBeat, strength: 0.6) }
    if let peak { events.append(MusicEvent(time: peak, kind: .build, strength: 1)) }
    return MusicAnalysis(duration: 60, bpm: bpm, confidence: 1, events: events, sections: [], energy: [])
}

@Test func zoomCurvesFollowTheSpec() {
    let id = UUID()
    let punch = PlannedEdit(kind: .punchIn, segmentID: id, start: 1, end: 2, peakScale: 1.2)
    #expect(punch.scale(at: 0.9) == 1)
    #expect(punch.scale(at: 1) == 1.2)
    let push = PlannedEdit(kind: .pushIn, segmentID: id, start: 0, end: 2, peakScale: 1.1)
    #expect(abs(push.scale(at: 1) - 1.05) < 0.0001)
    let pull = PlannedEdit(kind: .pullOut, segmentID: id, start: 0, end: 2, peakScale: 1.1)
    #expect(abs(pull.scale(at: 0) - 1.1) < 0.0001)
    #expect(abs(pull.scale(at: 1) - 1.05) < 0.0001)
    let pulse = PlannedEdit(kind: .pulse, segmentID: id, start: 0, end: EditPlanner.pulseLength, peakScale: 1.1)
    #expect(abs(pulse.scale(at: EditPlanner.pulseAttack) - 1.1) < 0.0001)
    #expect(pulse.scale(at: EditPlanner.pulseLength - 0.001) < 1.01)
}

@Test func editsAreRepeatableAndStayInsideTheirShots() {
    let edit = plan([2, 3, 1.2, 4, 2.5, 3])
    let first = EditPlanner.edits(for: edit, music: music(peak: 9), recipe: recipe(ZoomKind.allCases))
    #expect(first == EditPlanner.edits(for: edit, music: music(peak: 9), recipe: recipe(ZoomKind.allCases)))
    #expect(!first.isEmpty)
    var start = 0.0
    for segment in edit.segments {
        for zoom in first where zoom.segmentID == segment.id {
            #expect(zoom.start >= start && zoom.end <= start + segment.duration + 0.0001)
        }
        start += segment.duration
    }
}

@Test func aShotHasOneKindOfZoom() {
    let edit = plan([4, 4, 4, 4])
    let zooms = EditPlanner.edits(for: edit, music: music(), recipe: recipe(ZoomKind.allCases))
    for segment in edit.segments {
        #expect(Set(zooms.filter { $0.segmentID == segment.id }.map(\.kind)).count <= 1)
    }
}

@Test func onlyTheRecipesZoomsAreUsed() {
    let zooms = EditPlanner.edits(for: plan([3, 3, 3, 3]), music: music(), recipe: recipe([.pushIn]))
    #expect(!zooms.isEmpty)
    #expect(zooms.allSatisfy { $0.kind == .pushIn })
    #expect(EditPlanner.edits(for: plan([3, 3]), music: music(), recipe: recipe([])).isEmpty)
}

@Test func slowMovesAlternateAndAvoidShortShots() {
    let edit = plan([3, 3, 1, 3])
    let zooms = EditPlanner.edits(for: edit, music: music(), recipe: recipe([.pushIn, .pullOut]))
    #expect(zooms.map(\.kind) == [.pushIn, .pullOut, .pullOut])
    #expect(!zooms.contains { $0.segmentID == edit.segments[2].id })
}

@Test func theLastShotPullsOutWhenTheRecipeAllowsIt() throws {
    let edit = plan([3, 3, 3])
    let zooms = EditPlanner.edits(for: edit, music: music(), recipe: recipe([.pushIn, .pullOut]))
    #expect(try #require(zooms.last).kind == .pullOut)
    #expect(try #require(zooms.last).segmentID == edit.segments[2].id)
}

@Test func theBuildUpStaysQuietBeforeThePayoff() {
    let edit = plan([20])
    let zooms = EditPlanner.edits(for: edit, music: music(peak: 12), recipe: recipe([.pulse]))
    #expect(!zooms.isEmpty)
    #expect(!zooms.contains { $0.start >= 11 && $0.start < 12 })
}

@Test func aPunchInLandsOnThePayoffAndIsRationed() throws {
    let edit = plan([3, 3, 3, 3, 3, 3, 3, 3])
    let zooms = EditPlanner.edits(for: edit, music: music(peak: 13), recipe: recipe([.punchIn]))
    #expect(zooms.contains { $0.start == 13 })
    let starts = zooms.map(\.start)
    for (earlier, later) in zip(starts, starts.dropFirst()) { #expect(later - earlier >= 5) }
}

@Test func beatPulsesNeedATempoAndKeepTwoBeatsApart() {
    #expect(EditPlanner.edits(for: plan([4]), music: music(bpm: nil), recipe: recipe([.pulse])).isEmpty)
    let zooms = EditPlanner.edits(for: plan([6]), music: music(), recipe: recipe([.pulse]))
    #expect(zooms.count > 1)
    for (earlier, later) in zip(zooms, zooms.dropFirst()) { #expect(later.start - earlier.start >= 1 - 0.0001) }
}

@Test func lowResolutionClipsAreCapped() {
    let zooms = EditPlanner.edits(for: plan([3, 3, 3, 3]), music: music(peak: 4), recipe: recipe([.punchIn], intensity: 1),
                                  scaleLimits: [1.2, 1.2, 1.2, 1.2])
    #expect(!zooms.isEmpty)
    #expect(zooms.allSatisfy { $0.peakScale <= EditPlanner.lowResolutionLimit })
}

@Test func everyStyleLookStaysInTheSpecsStrengthRange() {
    for intent in EditIntent.allCases {
        #expect((0.4...0.7).contains(ColorLook.style(for: intent).strength))
    }
}

@Test func cinematicAvoidsBeatPulses() {
    #expect(!StyleRecipe.recipe(for: .cinematic).zooms.contains(.pulse))
    #expect(StyleRecipe.recipe(for: .travel).zooms.contains(.pushIn))
}
