import Foundation
import Testing
@testable import MontageCore

private func fixtureMoment(_ index: Int, quality: Double = 0.55) -> CandidateMoment {
    var features = MomentFeatures()
    features.quality = min(1, quality + Double(index % 5) * 0.05)
    features.interest = 0.45 + Double(index % 4) * 0.12
    features.motion = Double((index * 3) % 10) / 10
    features.stability = 0.45 + Double(index % 3) * 0.18
    features.scenery = index.isMultiple(of: 3) ? 0.85 : 0.25
    features.people = index.isMultiple(of: 4) ? 0.85 : 0.20
    features.faces = features.people
    let source = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index / 2))!
    let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!
    let start = Double(index % 2) * 3
    return CandidateMoment(id: id, sourceAssetID: source, sourceStartTime: start,
                           sourceEndTime: start + 2.6, features: features,
                           semanticTags: index.isMultiple(of: 3) ? ["scenery"] : ["people"],
                           timestamp: Date(timeIntervalSince1970: Double(index) * 60),
                           confidence: 0.8, clusterID: index / 2)
}

private func fixtureRequest(target: Double = 15, intent: EditIntent = .highlights) -> PlanningRequest {
    let moments = (0..<85).map { fixtureMoment($0) }
    let events = stride(from: 0.0, through: 90.0, by: 0.5).map {
        MusicEvent(time: $0, kind: $0.truncatingRemainder(dividingBy: 2) == 0 ? .strongBeat : .beat, strength: 0.8)
    }
    let energy = stride(from: 0.0, through: 90.0, by: 1.0).map { EnergySample(time: $0, value: 0.4 + 0.4 * sin($0 / 5)) }
    return PlanningRequest(moments: moments, music: MusicAnalysis(duration: 90, bpm: 120, confidence: 1,
                                                                    events: events, sections: [MusicSection(start: 0, end: 90, energy: 0.7)], energy: energy),
                            targetDuration: target, intent: intent,
                            parameters: CreativeParameters(highlights: 0.7, energy: 0.6, fastCuts: 0.35), seed: 44)
}

@Test func plannerGeneratesDeterministicDistinctVariants() throws {
    let request = fixtureRequest()
    let first = try MontagePlanner().generate(request)
    let second = try MontagePlanner().generate(request)
    #expect(first.count == 3)
    #expect(first == second)
    #expect(Set(first.map { $0.segments.map(\.momentID) }).count == 3)
    for plan in first {
        #expect(abs(plan.duration - request.targetDuration) <= 1.0 / 600.0)
        #expect(plan.segments.allSatisfy { $0.duration >= 0.15 })
    }
}

@Test func plannerHonoursLockAndRejection() throws {
    let base = fixtureRequest()
    let lockedMoment = base.moments[0]
    let locked = MontageSegment(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                               momentID: lockedMoment.id, sourceAssetID: lockedMoment.sourceAssetID,
                               sourceStartTime: lockedMoment.sourceStartTime, duration: 0.6, isLocked: true)
    let rejected = base.moments[1]
    var request = base
    request.lockedSegments = [locked]
    request.rejectedMomentIDs = [rejected.id]
    let plans = try MontagePlanner().generate(request)
    for plan in plans {
        #expect(plan.segments.contains { $0.momentID == lockedMoment.id && $0.isLocked })
        #expect(!plan.segments.contains { $0.momentID == rejected.id })
    }
}

@Test func plannerReportsInfeasibleMedia() {
    var request = fixtureRequest(target: 15)
    request.music = MusicAnalysis(duration: 10)
    #expect(throws: MontageError.self) { try MontagePlanner().generate(request) }
}

@Test func creativeEnergyChoosesAnAppropriateMusicSection() throws {
    var calm = fixtureRequest(target: 15, intent: .cinematic)
    calm.music = MusicAnalysis(duration: 60, bpm: 120, confidence: 1,
                              events: stride(from: 0.0, through: 60.0, by: 0.5).map {
                                  MusicEvent(time: $0, kind: .strongBeat, strength: 0.8)
                              },
                              sections: [MusicSection(start: 0, end: 30, energy: 0.2),
                                         MusicSection(start: 30, end: 60, energy: 0.9)],
                              energy: (0..<60).map { EnergySample(time: Double($0), value: $0 < 30 ? 0.2 : 0.9) })
    calm.parameters.energy = 0
    var energetic = calm
    energetic.intent = .beatSync; energetic.parameters.energy = 1
    let calmPlan = try #require(try MontagePlanner().generate(calm).first)
    let energeticPlan = try #require(try MontagePlanner().generate(energetic).first)
    #expect(calmPlan.musicStartTime + 15 <= 30)
    #expect(energeticPlan.musicStartTime >= 30)
}

@Test func plannerPrefersStrongMoments() throws {
    var request = fixtureRequest(target: 3, intent: .highlights)
    var strong = fixtureMoment(84, quality: 0.98)
    strong.features.interest = 0.98
    strong.features.motion = 0.95
    strong.features.stability = 0.98
    strong.features.composition = 0.98
    strong.features.exposure = 0.98
    strong.features.novelty = 0.98
    strong.confidence = 0.99
    request.moments = [strong] + request.moments.filter { $0.id != strong.id }
    let plan = try #require(try MontagePlanner().generate(request).first)
    #expect(plan.segments.contains { $0.momentID == strong.id })
    #expect(plan.metrics.meanQuality > 0.7)
}

@Test func plannerSuppressesRepeatedClusters() throws {
    var request = fixtureRequest(target: 8, intent: .highlights)
    request.moments = request.moments.enumerated().map { index, moment in
        var value = moment
        value.clusterID = index < 8 ? 1 : index
        return value
    }
    let plan = try #require(try MontagePlanner().generate(request).first)
    let counts = Dictionary(grouping: plan.segments.compactMap { segment in
        request.moments.first(where: { $0.id == segment.momentID })?.clusterID
    }, by: { $0 }).mapValues(\.count)
    #expect((counts[1] ?? 0) <= 2)
}

@Test func storyModeKeepsCaptureOrderAsAsoftConstraint() throws {
    let request = fixtureRequest(target: 15, intent: .story)
    let plan = try #require(try MontagePlanner().generate(request).first)
    let lookup = Dictionary(uniqueKeysWithValues: request.moments.compactMap { moment in
        moment.timestamp.map { (moment.id, $0) }
    })
    let dates = plan.segments.compactMap { lookup[$0.momentID] }
    let pairs = Array(zip(dates, dates.dropFirst()))
    #expect(Double(pairs.filter { $0 <= $1 }.count) / Double(max(1, pairs.count)) >= 0.7)
}

@Test func cinematicShotsAverageLongerThanBeatSync() throws {
    let cinematic = try #require(try MontagePlanner().generate(fixtureRequest(target: 30, intent: .cinematic)).first)
    let beat = try #require(try MontagePlanner().generate(fixtureRequest(target: 30, intent: .beatSync)).first)
    #expect(cinematic.metrics.averageDuration > beat.metrics.averageDuration)
}

@Test func plannerFitsCommonDurationsOnTheTickGrid() throws {
    for length in [15.0, 30.0, 45.0, 60.0] {
        let plans = try MontagePlanner().generate(fixtureRequest(target: length, intent: .highlights))
        #expect(plans.count == 3)
        for plan in plans {
            #expect(abs(plan.duration - length) <= 1.0 / 600.0)
            #expect(abs((plan.duration * 600).rounded() - plan.duration * 600) < 0.0001)
        }
    }
}

@Test func refinerKeepsTargetDuration() throws {
    let plan = try #require(try MontagePlanner().generate(fixtureRequest()).first)
    let editable = try #require(plan.segments.first(where: { !$0.isLocked }))
    let resized = try PlanRefiner.resize(plan: plan, segmentID: editable.id, to: editable.duration + 0.3,
                                         moments: fixtureRequest().moments)
    #expect(abs(resized.duration - plan.duration) <= 1.0 / 600.0)
    let moved = try PlanRefiner.move(plan: resized, segmentID: editable.id, by: 1)
    #expect(moved.duration == resized.duration)
}

@Test func replacementChecksTheSelectedPeakWindowForOverlap() throws {
    let source = UUID()
    let candidate = CandidateMoment(sourceAssetID: source, sourceStartTime: 0, sourceEndTime: 6,
                                    features: MomentFeatures(), semanticTags: [], confidence: 1, peakTime: 5)
    let old = MontageSegment(momentID: UUID(), sourceAssetID: UUID(), sourceStartTime: 0, duration: 1)
    var used = MontageSegment(momentID: UUID(), sourceAssetID: source, sourceStartTime: 0.5, duration: 1)
    let plan = MontagePlan(name: "Peak window", summary: "", intent: .highlights, seed: 1,
                           musicStartTime: 0, segments: [old, used])
    let replaced = try PlanRefiner.replace(plan: plan, segmentID: old.id, with: candidate, moments: [candidate])
    #expect(replaced.segments[0].sourceStartTime == 4.5)
    #expect(replaced.duration == plan.duration)
    used.sourceStartTime = 4.7
    var overlapping = plan; overlapping.segments[1] = used
    #expect(throws: MontageError.self) {
        try PlanRefiner.replace(plan: overlapping, segmentID: old.id, with: candidate, moments: [candidate])
    }
}

@Test func creativeChangesRequireNewEditsAndSurvivePersistence() throws {
    var project = MontageProject(name: "Trip")
    project.plans = [MontagePlan(name: "Edit", summary: "", intent: .beatSync, seed: 1, musicStartTime: 0,
                                segments: [MontageSegment(momentID: UUID(), sourceAssetID: UUID(), sourceStartTime: 0, duration: 30)])]
    project.plannedSettings = project.planningSettings
    #expect(!project.needsGeneration)
    project.targetDuration = 45
    #expect(project.needsGeneration)
    let reopened = try JSONDecoder().decode(MontageProject.self, from: JSONEncoder().encode(project))
    #expect(reopened.needsGeneration)
    project.targetDuration = 30
    #expect(!project.needsGeneration)
    project.parameters.energy = 0.9
    #expect(project.needsGeneration)
    #expect(project.plans[0].duration == 30)
    project.parameters = try #require(project.plannedSettings).parameters
    project.rejectedMomentIDs = [project.plans[0].segments[0].momentID]
    #expect(project.needsGeneration)
}
