import Foundation
import Testing
@testable import MontageCore

@Test func encodedSampleAnalysisProducesThreeThirtySecondEdits() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/illustrated-trip.json")
    let project = try JSONDecoder().decode(MontageProject.self, from: Data(contentsOf: fixture))
    let music = try #require(project.music)
    let request = PlanningRequest(moments: project.moments, music: music.analysis, targetDuration: 30,
                                  intent: .beatSync, parameters: project.parameters, seed: 1)
    let plans = try MontagePlanner().generate(request)
    #expect(plans.count == 3)
    for plan in plans {
        try PlanValidator.validate(plan, target: 30, assets: project.assets, musicDuration: music.analysis.duration)
        #expect(plan.metrics.beatAlignment > 0.3)
    }
}

@Test func locksStayNearTheirOriginalOpeningAndKeepTheirExactRanges() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/illustrated-trip.json")
    let project = try JSONDecoder().decode(MontageProject.self, from: Data(contentsOf: fixture))
    let music = try #require(project.music)
    var request = PlanningRequest(moments: project.moments, music: music.analysis, targetDuration: 15, intent: .beatSync, seed: 1)
    let original = try #require(try MontagePlanner().generate(request).first)
    var first = try #require(original.segments.first)
    first.isLocked = true; first.preferredTimelineStart = 0
    var second = try #require(original.segments.dropFirst().first)
    second.isLocked = true; second.preferredTimelineStart = first.duration
    request.lockedSegments = [first, second]; request.priorPlans = [original]; request.seed = 18
    for plan in try MontagePlanner().generate(request) {
        #expect(plan.segments.first == first)
        #expect(plan.segments.dropFirst().first == second)
        #expect(abs(plan.duration - 15) < 1.0 / 600)
    }
}
