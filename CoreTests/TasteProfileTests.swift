import Foundation
import Testing
@testable import MontageCore

private func tasteMoment(_ id: Int, motion: Double, scenery: Double = 0.5,
                         duration: Double = 2) -> CandidateMoment {
    var features = MomentFeatures()
    features.motion = motion
    features.scenery = scenery
    features.novelty = scenery
    features.people = 1 - scenery
    features.faces = features.people
    return CandidateMoment(id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", id))!,
                           sourceAssetID: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", id))!,
                           sourceStartTime: 0, sourceEndTime: duration, features: features)
}

@Test func neutralProfileKeepsPlannerOutputStable() throws {
    let moments = (0..<20).map { tasteMoment($0, motion: Double($0 % 5) / 4) }
    let music = MusicAnalysis(duration: 30, events: [MusicEvent(time: 1, kind: .strongBeat, strength: 1)])
    let base = PlanningRequest(moments: moments, music: music, targetDuration: 6, intent: .highlights, seed: 3)
    let neutral = PlanningRequest(moments: moments, music: music, targetDuration: 6, intent: .highlights,
                                  seed: 3, tasteProfile: TasteProfile())
    let first = try MontagePlanner().generate(base)
    let second = try MontagePlanner().generate(neutral)
    #expect(first.map(\.segments) == second.map(\.segments))
    #expect(first.map(\.metrics) == second.map(\.metrics))
}

@Test func preferencesStayIsolatedByIntent() {
    var profile = TasteProfile()
    profile.set(.motion, value: 1, for: .beatSync)
    #expect(profile.preferences(for: .beatSync)[.motion] == 1)
    #expect(profile.preferences(for: .story)[.motion] == 0)
}

@Test func learningIsBoundedAndDuplicateFeedbackIsIgnored() {
    let preferred = tasteMoment(1, motion: 1)
    let over = tasteMoment(2, motion: 0)
    var profile = TasteProfile()
    let first = profile.learn(preferred: preferred, over: over, intent: .beatSync)
    let duplicate = profile.learn(preferred: preferred, over: over, intent: .beatSync)
    #expect(first)
    #expect(!duplicate)
    #expect(profile.feedbackCount == 1)
    #expect(abs(profile.preferences(for: .beatSync)[.motion]) <= 0.16)
}

@Test func oppositeFeedbackReplacesTheEarlierVote() {
    let preferred = tasteMoment(1, motion: 1)
    let over = tasteMoment(2, motion: 0)
    var profile = TasteProfile()
    let first = profile.learn(preferred: preferred, over: over, intent: .beatSync)
    let reversed = profile.learn(preferred: over, over: preferred, intent: .beatSync)
    #expect(first)
    #expect(reversed)
    #expect(profile.preferences(for: .beatSync)[.motion] < 0)
}

@Test func profileAndLegacyPlanRoundTrip() throws {
    let preferred = tasteMoment(1, motion: 1)
    let over = tasteMoment(2, motion: 0)
    var profile = TasteProfile()
    _ = profile.learn(preferred: preferred, over: over, intent: .beatSync)
    let profileData = try JSONEncoder().encode(profile)
    #expect(try JSONDecoder().decode(TasteProfile.self, from: profileData) == profile)

    let plan = MontagePlan(name: "Legacy", summary: "", intent: .beatSync, seed: 1,
                           musicStartTime: 0, segments: [])
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
    object.removeValue(forKey: "tasteProfile")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(MontagePlan.self, from: legacyData).tasteProfile == nil)
}

@Test func planLearningUsesMeanFeaturesWithoutSaturatingTheSum() {
    let high = (1...4).map { tasteMoment($0, motion: 0.8) }
    let low = (5...8).map { tasteMoment($0, motion: 0.4) }
    func plan(_ moments: [CandidateMoment]) -> MontagePlan {
        MontagePlan(name: "Comparison", summary: "", intent: .beatSync, seed: 1, musicStartTime: 0,
            segments: moments.map { MontageSegment(momentID: $0.id, sourceAssetID: $0.sourceAssetID, sourceStartTime: 0, duration: 2) })
    }
    var profile = TasteProfile()
    let learned = profile.learn(preferred: plan(high), over: plan(low), moments: high + low, reason: .moments)
    #expect(learned)
    #expect(profile.preferences(for: .beatSync)[.motion] > 0.05)
    #expect(profile.preferences(for: .beatSync)[.pacing] == 0)
}

@Test func quickerPacingShortensTargetAndMomentWindowsDoNotTeachPacing() {
    var profile = TasteProfile()
    profile.set(.pacing, value: 1, for: .beatSync)
    #expect(profile.durationMultiplier(for: .beatSync) == 0.85)
    profile.reset()
    _ = profile.learn(preferred: tasteMoment(1, motion: 1, duration: 4),
                      over: tasteMoment(2, motion: 0, duration: 1), intent: .beatSync)
    #expect(profile.preferences(for: .beatSync)[.pacing] == 0)
}

@Test func personalizedPlansKeepExactDurationLocksAndRejections() throws {
    let moments = (0..<24).map { tasteMoment($0, motion: Double($0 % 5) / 4, duration: 4) }
    let assets = moments.map { SourceAsset(id: $0.sourceAssetID, fileName: "test.mov", duration: 4, width: 100, height: 100, fingerprint: $0.id.uuidString) }
    let lock = MontageSegment(momentID: moments[0].id, sourceAssetID: moments[0].sourceAssetID,
                              sourceStartTime: 0.5, duration: 1, isLocked: true, preferredTimelineStart: 0)
    var profile = TasteProfile()
    profile.set(.motion, value: 1, for: .beatSync)
    profile.set(.pacing, value: 1, for: .beatSync)
    let request = PlanningRequest(moments: moments, music: MusicAnalysis(duration: 30), targetDuration: 6,
        intent: .beatSync, lockedSegments: [lock], rejectedSourceIDs: [moments[1].sourceAssetID],
        rejectedMomentIDs: [moments[2].id], seed: 17, tasteProfile: profile)
    let plans = try MontagePlanner().generate(request)
    for plan in plans {
        try PlanValidator.validate(plan, target: 6, assets: assets, musicDuration: 30,
                                   rejectedSources: request.rejectedSourceIDs, rejectedMoments: request.rejectedMomentIDs)
        #expect(plan.segments.contains { $0.momentID == lock.momentID && $0.sourceStartTime == 0.5 && $0.duration == 1 && $0.isLocked })
        #expect(plan.tasteProfile == profile)
    }
}
