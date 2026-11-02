import Foundation
import Testing
@testable import MontageCore

private func song(bpm: Double?, loudFirst: Bool = true) -> MusicAnalysis {
    let energy = stride(from: 0.0, through: 60.0, by: 1.0).map {
        EnergySample(time: $0, value: ($0 < 30) == loudFirst ? 0.9 : 0.2)
    }
    return MusicAnalysis(duration: 60, bpm: bpm, confidence: 1, events: [], sections: [], energy: energy)
}

@Test func everyStyleHasASensibleRecipe() {
    for intent in EditIntent.allCases {
        let recipe = StyleRecipe.recipe(for: intent)
        #expect(recipe != .open, "No recipe for \(intent)")
        #expect(recipe.shortestShot < recipe.longestShot)
        #expect(recipe.beatsWhenLoud <= recipe.beatsWhenQuiet)
        #expect(recipe.mostMomentsPerClip >= 1)
    }
}

@Test func beatSyncCutsFasterInLoudParts() throws {
    let pacing = RecipePacing(recipe: .recipe(for: .beatSync), music: song(bpm: 120), musicStart: 0)
    #expect(try #require(pacing.targetDuration(at: 5)) == 0.5)
    #expect(try #require(pacing.targetDuration(at: 40)) == 1.0)
}

@Test func cinematicStaysInsideItsLimitsAtAnyTempo() throws {
    for bpm in [60.0, 120, 180] {
        let pacing = RecipePacing(recipe: .recipe(for: .cinematic), music: song(bpm: bpm), musicStart: 0)
        for elapsed in [5.0, 40.0] {
            let target = try #require(pacing.targetDuration(at: elapsed))
            #expect((2.5...4.5).contains(target))
        }
    }
}

@Test func pacingUsesThePlaceInTheSongNotTheEdit() throws {
    let pacing = RecipePacing(recipe: .recipe(for: .beatSync), music: song(bpm: 120), musicStart: 35)
    #expect(try #require(pacing.targetDuration(at: 0)) == 1.0)
}

@Test func songWithoutATempoSkipsOnlyThePaceRule() {
    let pacing = RecipePacing(recipe: .recipe(for: .beatSync), music: song(bpm: nil), musicStart: 0)
    #expect(pacing.targetDuration(at: 5) == nil)
    #expect(pacing.score(duration: 1, elapsed: 5, momentsFromClip: 0) == 0)
    #expect(pacing.score(duration: 3, elapsed: 5, momentsFromClip: 0) < 0)
}

@Test func scoreOnlyPenalizesAndRespectsTheClipLimit() {
    let pacing = RecipePacing(recipe: .recipe(for: .story), music: song(bpm: 120), musicStart: 0)
    #expect(pacing.score(duration: 1.2, elapsed: 5, momentsFromClip: 0) == 0)
    #expect(pacing.score(duration: 1.2, elapsed: 5, momentsFromClip: 2) < pacing.score(duration: 1.2, elapsed: 5, momentsFromClip: 1))
    #expect(pacing.score(duration: 8, elapsed: 5, momentsFromClip: 0) < 0)
}

private func moment(faces: Double = 0, people: Double = 0, motion: Double = 0.5, scenery: Double = 0,
                    tags: [String] = [], subject: SubjectAnchor? = nil) -> CandidateMoment {
    var features = MomentFeatures()
    features.faces = faces; features.people = people; features.scenery = scenery
    features.motion = motion; features.quality = 0.7
    return CandidateMoment(sourceAssetID: UUID(), sourceStartTime: 0, sourceEndTime: 4, features: features,
                           semanticTags: tags, subject: subject)
}

@Test func shotScaleUsesFacesSubjectSizeAndScenery() {
    let pacing = RecipePacing(recipe: .recipe(for: .places), music: song(bpm: 120), musicStart: 0)
    #expect(pacing.scale(of: moment(scenery: 0.85)) == .wide)
    #expect(pacing.scale(of: moment(faces: 0.33, scenery: 0.85)) == .close)
    #expect(pacing.scale(of: moment(subject: SubjectAnchor(x: 0.05, y: 0.05, width: 0.9, height: 0.9))) == .close)
    #expect(pacing.scale(of: moment()) == .medium)
}

@Test func openingsAndEndingsRewardTheRightShots() {
    let story = RecipePacing(recipe: .recipe(for: .story), music: song(bpm: 120), musicStart: 0)
    #expect(story.placementScore(moment(scenery: 0.85), isFirst: true, isLast: false, elapsed: 50, duration: 2)
        > story.placementScore(moment(), isFirst: true, isLast: false, elapsed: 50, duration: 2))
    #expect(story.placementScore(moment(tags: ["sunset"]), isFirst: false, isLast: true, elapsed: 50, duration: 2)
        > story.placementScore(moment(), isFirst: false, isLast: true, elapsed: 50, duration: 2))
    #expect(story.placementScore(moment(people: 0.33), isFirst: false, isLast: true, elapsed: 50, duration: 2)
        > story.placementScore(moment(), isFirst: false, isLast: true, elapsed: 50, duration: 2))
}

@Test func theStrongestShotIsRewardedAtTheSongsPeak() {
    let music = MusicAnalysis(duration: 60, bpm: 120, confidence: 1,
                              events: [MusicEvent(time: 20, kind: .build, strength: 0.9)], sections: [], energy: [])
    let pacing = RecipePacing(recipe: .recipe(for: .beatSync), music: music, musicStart: 10, targetDuration: 30)
    #expect(pacing.placementScore(moment(), isFirst: false, isLast: false, elapsed: 9, duration: 2) > 0)
    #expect(pacing.placementScore(moment(), isFirst: false, isLast: false, elapsed: 2, duration: 2) == 0)
}

@Test func neighboringShotsAreNotAllowedToFeelTheSame() {
    let still = moment(motion: 0.1), moving = moment(motion: 0.9)
    let pacing = RecipePacing(recipe: .recipe(for: .story), music: song(bpm: 120), musicStart: 0, moments: [still, moving])
    #expect(pacing.varietyScore(moment(faces: 0.33), after: moment(faces: 0.33))
        < pacing.varietyScore(moment(faces: 0.33), after: moment(scenery: 0.85)))
    #expect(pacing.varietyScore(still, after: still) < pacing.varietyScore(moving, after: still))
    #expect(pacing.varietyScore(moment(motion: 0.9, scenery: 0.85), after: moment(faces: 0.33, motion: 0.9)) == 0)
}

@Test func shotsGetShorterAsABuildRises() throws {
    var music = song(bpm: 120)
    music.builds = [MusicBuild(start: 20, end: 30, rise: 8)]
    let pacing = RecipePacing(recipe: .recipe(for: .travel), music: music, musicStart: 0)
    let early = try #require(pacing.targetDuration(at: 21))
    let late = try #require(pacing.targetDuration(at: 29))
    #expect(late < early)
    let calm = RecipePacing(recipe: .recipe(for: .cinematic), music: music, musicStart: 0)
    #expect(calm.targetDuration(at: 21) == calm.targetDuration(at: 29))
}

@Test func aDropIsThePeakOfTheSong() {
    let music = MusicAnalysis(duration: 60, events: [MusicEvent(time: 20, kind: .build, strength: 1),
                                                     MusicEvent(time: 24, kind: .drop, strength: 0.5)])
    #expect(RecipePacing.peakTime(in: music, musicStart: 10, duration: 30) == 14)
}
