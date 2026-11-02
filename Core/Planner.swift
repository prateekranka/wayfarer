import Foundation

/// A small, deterministic score for one analysed video moment.
///
/// The planner uses these helpers for both candidate ranking and explanations. The
/// functions are public so analysis and debug tools can show the same values as
/// the planner without coupling to its private search state.
public enum MomentScorer {
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    public static func qualityScore(_ moment: CandidateMoment) -> Double {
        let f = moment.features
        let value = 0.30 * f.quality
            + 0.15 * f.interest
            + 0.10 * f.stability
            + 0.10 * f.composition
            + 0.08 * f.exposure
            + 0.10 * f.novelty
            + 0.12 * moment.confidence
            + 0.05 * f.motion
            - 0.20 * f.blur
        return clamp(value)
    }

    /// Sounds of people enjoying themselves, which suit any edit.
    static let peopleSounds: Set<String> = ["laughter", "giggling", "belly_laugh", "chuckle_chortle", "snicker",
        "cheering", "applause", "clapping", "crowd", "children_shouting", "singing", "choir_singing", "baby_laughter", "yell"]
    /// Sounds that say where you are, which suit edits about the journey.
    static let placeSounds: Set<String> = ["ocean", "sea_waves", "water", "stream_burbling", "waterfall", "rain", "thunder",
        "bird", "bird_chirp_tweet", "bird_squawk", "church_bell", "bell", "train", "rail_transport", "subway_metro",
        "airplane", "aircraft", "boat_water_vehicle", "traffic_noise", "car_horn", "glass_clink", "cutlery_silverware", "whistling"]

    /// A bonus for moments whose sound adds something. Clips with no sound
    /// results lose nothing, because the model cannot run everywhere.
    public static func soundScore(_ moment: CandidateMoment, intent: EditIntent) -> Double {
        guard let sounds = moment.signals?.sounds, !sounds.isEmpty else { return 0 }
        let hasPeople = sounds.contains(where: peopleSounds.contains)
        let hasPlace = sounds.contains(where: placeSounds.contains)
        var value = 0.0
        switch intent {
        case .people, .story: value += hasPeople ? 0.14 : 0
        default: value += hasPeople ? 0.08 : 0
        }
        switch intent {
        case .travel, .places, .story: value += hasPlace ? 0.08 : 0
        default: break
        }
        return value
    }

    public static func semanticScore(_ moment: CandidateMoment, intent: EditIntent) -> Double {
        let f = moment.features
        switch intent {
        case .beatSync: return clamp(0.45 * f.motion + 0.30 * f.interest + 0.25 * f.quality)
        case .story: return clamp(0.45 * f.interest + 0.30 * f.quality + 0.25 * f.stability)
        case .cinematic: return clamp(0.35 * f.quality + 0.25 * f.stability + 0.20 * f.scenery + 0.20 * f.composition)
        case .highlights: return clamp(0.45 * f.quality + 0.35 * f.interest + 0.20 * f.novelty)
        case .people: return clamp(0.55 * f.people + 0.25 * f.faces + 0.20 * f.quality)
        case .places: return clamp(0.50 * f.scenery + 0.25 * f.composition + 0.25 * f.quality)
        case .travel: return clamp(0.35 * f.scenery + 0.30 * f.interest + 0.20 * f.quality + 0.15 * f.motion)
        }
    }

    public static func score(_ moment: CandidateMoment,
                             intent: EditIntent,
                             parameters: CreativeParameters = CreativeParameters()) -> Double {
        let base = 0.58 * qualityScore(moment) + 0.42 * semanticScore(moment, intent: intent)
        let f = moment.features
        let sliderEffect = parameters.highlights * 0.08 * f.interest
            + parameters.energy * 0.08 * f.motion
            + parameters.fastCuts * 0.04 * f.interest
        // Cinematic wants calm shots. This only applies to measured motion.
        let calm = intent == .cinematic ? (moment.signals?.motionScore ?? 0) * 0.20 : 0
        return clamp(base + sliderEffect + soundScore(moment, intent: intent) - calm + Double(moment.userPreference) * 0.025)
    }

    public static func score(_ moment: CandidateMoment,
                             intent: EditIntent,
                             parameters: CreativeParameters,
                             profile: Int) -> Double {
        let f = moment.features
        var value = score(moment, intent: intent, parameters: parameters)
        switch profile {
        case 1:
            value += 0.12 * f.novelty + 0.08 * f.scenery - 0.04 * f.faces
        case 2:
            value += 0.14 * f.motion + 0.08 * f.interest - 0.05 * f.blur
        default:
            break
        }
        return clamp(value)
    }

    public static func semanticSimilarity(_ lhs: CandidateMoment, _ rhs: CandidateMoment) -> Double {
        if lhs.id == rhs.id { return 1 }
        let left = Set(lhs.semanticTags.map { $0.lowercased() })
        let right = Set(rhs.semanticTags.map { $0.lowercased() })
        let union = left.union(right)
        let jaccard: Double = union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
        let featureDistance = zip(lhs.featureVector, rhs.featureVector).reduce(0.0) { result, pair in
            result + Double(pair.0 - pair.1) * Double(pair.0 - pair.1)
        }
        let vectorSimilarity = lhs.featureVector.isEmpty || rhs.featureVector.isEmpty
            ? 0
            : 1 / (1 + sqrt(featureDistance / Double(min(lhs.featureVector.count, rhs.featureVector.count))))
        let sameCluster = lhs.clusterID >= 0 && lhs.clusterID == rhs.clusterID ? 0.35 : 0
        return clamp(0.45 * jaccard + 0.35 * vectorSimilarity + sameCluster)
    }
}

/// A seeded, bounded planner for edit decision lists.
public struct MontagePlanner: MontagePlanning, Sendable {
    private static let ticksPerSecond = 600.0
    private static let minimumTicks = 90
    private static let beamWidth = 16

    public init() {}

    public func generate(_ request: PlanningRequest) throws -> [MontagePlan] {
        try Task.checkCancellation()
        try validateRequest(request)
        let targetTicks = Self.ticks(request.targetDuration)
        guard request.music.duration.isFinite,
              request.music.duration + 1.0 / Self.ticksPerSecond >= request.targetDuration else {
            throw MontageError.shortMusic
        }

        let candidates = usableMoments(from: request)
        let locks = try normaliseLocks(request.lockedSegments, in: candidates, request: request)
        let lockedIDs = Set(locks.map(\.momentID))
        let lockedTicks = locks.reduce(0) { $0 + Self.ticks($1.duration) }
        guard lockedTicks <= targetTicks else {
            throw MontageError.invalidPlan("Locked moments are longer than the requested edit.")
        }
        guard lockedTicks < targetTicks else {
            throw MontageError.invalidPlan("Every moment is locked. Unlock a moment to try another edit.")
        }

        let unlocked = candidates.filter { !lockedIDs.contains($0.id) }
        let usedLockIntervals = locks.map { SourceInterval(assetID: $0.sourceAssetID,
                                                            start: $0.sourceStartTime,
                                                            end: $0.sourceStartTime + $0.duration) }
        let capacity = availableCapacity(unlocked, excluding: usedLockIntervals)
        guard capacity >= targetTicks - lockedTicks else {
            throw MontageError.insufficientFootage
        }

        var plans: [MontagePlan] = []
        for variant in 0..<3 {
            let musicStart = chooseMusicStart(request.music, target: request.targetDuration,
                                              intent: request.intent, parameters: request.parameters,
                                              seed: request.seed, variant: variant)
            let beam = try search(candidates: unlocked, locks: locks, targetTicks: targetTicks,
                              request: request, variant: variant, musicStart: musicStart,
                              existing: request.priorPlans + plans)
            guard !beam.isEmpty else { throw MontageError.insufficientFootage }
            var selected: MontagePlan?
            for state in beam {
                var plan = makePlan(best: state, locks: locks, request: request,
                                    musicStart: musicStart, variant: variant, allCandidates: candidates)
                fitShotLimits(&plan, request: request, candidates: candidates)
                alignBoundaries(&plan, request: request, candidates: candidates)
                plan.metrics = metrics(for: plan.segments, candidates: candidates, music: request.music, musicStart: musicStart)
                if plans.allSatisfy({ isDistinct(plan, from: $0) }) { selected = plan; break }
            }
            guard let selected else { throw MontageError.insufficientDiversity }
            plans.append(selected)
        }
        return plans
    }

    private struct SourceInterval: Sendable {
        var assetID: UUID
        var start: Double
        var end: Double
    }

    private struct Chosen: Sendable {
        var moment: CandidateMoment
        var ticks: Int
        var score: Double
    }

    private struct State: Sendable {
        var chosen: [Chosen]
        var score: Double
        var usedIDs: Set<UUID>
        var intervals: [SourceInterval]
        var last: CandidateMoment?
        var lastTimestamp: Date?
    }

    private func validateRequest(_ request: PlanningRequest) throws {
        guard request.targetDuration.isFinite, request.targetDuration > 0 else {
            throw MontageError.invalidMedia("The requested montage length is invalid.")
        }
        guard Self.ticks(request.targetDuration) >= Self.minimumTicks else {
            throw MontageError.invalidPlan("The requested montage length is shorter than one usable moment.")
        }
        guard request.music.duration.isFinite, request.music.duration >= 0 else {
            throw MontageError.invalidMedia("The music duration is invalid.")
        }
    }

    private func usableMoments(from request: PlanningRequest) -> [CandidateMoment] {
        var seen = Set<UUID>()
        return request.moments
            .filter { moment in
                guard !request.rejectedMomentIDs.contains(moment.id),
                      !request.rejectedSourceIDs.contains(moment.sourceAssetID),
                      !seen.contains(moment.id),
                      moment.sourceStartTime.isFinite,
                      moment.sourceEndTime.isFinite,
                      moment.sourceStartTime >= 0,
                      moment.sourceEndTime > moment.sourceStartTime,
                      moment.duration >= 0.15, moment.features.quality >= 0.15,
                      MomentScorer.qualityScore(moment) >= 0.18 else { return false }
                seen.insert(moment.id)
                return true
            }
            .sorted { lhs, rhs in
                if lhs.id.uuidString != rhs.id.uuidString { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.sourceStartTime < rhs.sourceStartTime
            }
    }

    private func normaliseLocks(_ locks: [MontageSegment], in candidates: [CandidateMoment], request: PlanningRequest) throws -> [MontageSegment] {
        var seen = Set<UUID>()
        var intervals: [SourceInterval] = []
        var result: [MontageSegment] = []
        for lock in locks.sorted(by: { ($0.preferredTimelineStart ?? 0) < ($1.preferredTimelineStart ?? 0) }) {
            guard !request.rejectedMomentIDs.contains(lock.momentID),
                  !request.rejectedSourceIDs.contains(lock.sourceAssetID),
                  lock.duration.isFinite, lock.duration >= 0.15,
                  lock.sourceStartTime.isFinite, lock.sourceStartTime >= 0,
                  !seen.contains(lock.momentID),
                  let moment = candidates.first(where: { $0.id == lock.momentID && $0.sourceAssetID == lock.sourceAssetID }),
                  lock.sourceStartTime + lock.duration <= moment.sourceEndTime + 1.0 / Self.ticksPerSecond,
                  lock.sourceStartTime >= moment.sourceStartTime - 1.0 / Self.ticksPerSecond else {
                throw MontageError.invalidPlan("A locked moment is unavailable or outside its source range.")
            }
            let interval = SourceInterval(assetID: lock.sourceAssetID,
                                          start: lock.sourceStartTime,
                                          end: lock.sourceStartTime + lock.duration)
            guard !intervals.contains(where: { overlaps($0, interval) }) else {
                throw MontageError.invalidPlan("Locked moments overlap in the same source clip.")
            }
            seen.insert(lock.momentID)
            intervals.append(interval)
            var copy = lock
            copy.isLocked = true
            result.append(copy)
        }
        return result
    }

    private func availableCapacity(_ candidates: [CandidateMoment], excluding intervals: [SourceInterval]) -> Int {
        candidates.filter { moment in
            !intervals.contains(where: { overlaps($0, SourceInterval(assetID: moment.sourceAssetID,
                                                                      start: moment.sourceStartTime,
                                                                      end: moment.sourceEndTime)) })
        }.reduce(0) { $0 + max(0, Self.ticks($1.duration)) }
    }

    private func search(candidates: [CandidateMoment], locks: [MontageSegment], targetTicks: Int,
                        request: PlanningRequest, variant: Int, musicStart: Double,
                        existing: [MontagePlan]) throws -> [State] {
        let recipe = StyleRecipe.recipe(for: request.intent)
        let pacing = RecipePacing(recipe: recipe, music: request.music, musicStart: musicStart,
                                  targetDuration: request.targetDuration, moments: candidates)
        let shortestTicks = max(Self.minimumTicks, Self.ticks(recipe.shortestShot))
        let lockedTicks = locks.reduce(0) { $0 + Self.ticks($1.duration) }
        let lockIntervals = locks.map { SourceInterval(assetID: $0.sourceAssetID, start: $0.sourceStartTime,
                                                        end: $0.sourceStartTime + $0.duration) }
        var states = [State(chosen: [], score: 0, usedIDs: Set(locks.map(\.momentID)),
                            intervals: lockIntervals, last: nil, lastTimestamp: nil)]
        var completed: [State] = []
        let meanTicks = candidates.isEmpty ? Double(Self.minimumTicks) : candidates.reduce(0.0) { total, moment in
            total + Double(min(Self.ticks(moment.duration), desiredTicks(for: moment, intent: request.intent,
                                                                       parameters: request.parameters, profile: variant,
                                                                       tasteProfile: request.tasteProfile)))
        } / Double(candidates.count)
        let preferredCount = max(1, min(candidates.count, Int(ceil(Double(targetTicks - lockedTicks) / max(1, meanTicks)))))
        let maxIterations = max(4, min(160, preferredCount + max(5, preferredCount / 3)))

        for iteration in 0..<maxIterations {
            try Task.checkCancellation()
            var next: [State] = []
            for state in states {
                let spent = lockedTicks + state.chosen.reduce(0) { $0 + $1.ticks }
                let remaining = targetTicks - spent
                if remaining == 0 {
                    completed.append(state)
                    continue
                }
                guard remaining >= Self.minimumTicks else { continue }
                let available = candidates.filter { candidate in
                    !state.usedIDs.contains(candidate.id)
                        && !state.intervals.contains(where: { interval in
                            overlaps(interval, SourceInterval(assetID: candidate.sourceAssetID,
                                                               start: candidate.sourceStartTime,
                                                               end: candidate.sourceEndTime))
                        })
                }
                let capacity = available.reduce(0) { $0 + Self.ticks($1.duration) }
                guard capacity >= remaining else { continue }
                let ranked = available.map { candidate in
                    // Count the opening here too, or the shortlist below can
                    // drop every shot the recipe wants to open on.
                    let opening = state.chosen.isEmpty
                        ? pacing.placementScore(candidate, isFirst: true, isLast: false, elapsed: -1, duration: 0) : 0
                    return (candidate, opening + candidateScore(candidate, state: state, request: request, variant: variant,
                                                                remaining: remaining, existing: existing))
                }.sorted { lhs, rhs in
                    if abs(lhs.1 - rhs.1) > 0.000001 { return lhs.1 > rhs.1 }
                    return lhs.0.id.uuidString < rhs.0.id.uuidString
                }.prefix(12)

                for (candidate, _) in ranked {
                    let maximum = min(Self.ticks(candidate.duration), remaining)
                    guard maximum >= Self.minimumTicks else { continue }
                    let desired = desiredTicks(for: candidate, intent: request.intent,
                                               parameters: request.parameters, profile: variant,
                                               tasteProfile: request.tasteProfile)
                    var options = Set([max(Self.minimumTicks, min(maximum, desired)), maximum])
                    if remaining <= maximum { options.insert(remaining) }
                    // Leave enough time for one last shot within the recipe's limit.
                    if remaining - shortestTicks <= maximum, remaining - shortestTicks >= shortestTicks {
                        options.insert(remaining - shortestTicks)
                    }
                    if maximum - Self.minimumTicks > 180 { options.insert(max(Self.minimumTicks, maximum / 2)) }
                    for duration in options.sorted() {
                        let after = remaining - duration
                        guard after == 0 || after >= Self.minimumTicks else { continue }
                        if after > 0 {
                            let rest = available.filter { $0.id != candidate.id }
                                .reduce(0) { $0 + Self.ticks($1.duration) }
                            guard rest >= after else { continue }
                        }
                        var nextState = state
                        let increment = sequenceScore(candidate, duration: duration, ending: after == 0,
                                                      state: state, request: request, variant: variant,
                                                      pacing: pacing, existing: existing)
                        nextState.chosen.append(Chosen(moment: candidate, ticks: duration, score: increment))
                        nextState.score += increment
                        nextState.usedIDs.insert(candidate.id)
                        let sourceStart = candidate.preferredStart(for: Double(duration) / Self.ticksPerSecond)
                        nextState.intervals.append(SourceInterval(assetID: candidate.sourceAssetID,
                                                                  start: sourceStart,
                                                                  end: sourceStart + Double(duration) / Self.ticksPerSecond))
                        nextState.last = candidate
                        nextState.lastTimestamp = candidate.timestamp
                        if after == 0 {
                            completed.append(nextState)
                        } else {
                            next.append(nextState)
                        }
                    }
                }
            }
            if next.isEmpty { break }
            // Once the beam has several complete paths, further expansion only
            // adds equivalent low-value paths. Keep generation bounded for
            // large camera rolls while retaining a choice for tie-breaking.
            if completed.count >= 12 && iteration >= preferredCount + 1 { break }
            states = Array(next.sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.000001 { return lhs.score > rhs.score }
                return signature(lhs) < signature(rhs)
            }.prefix(Self.beamWidth))
            // Retain one path that makes the most duration progress. Editorial
            // scores can otherwise prune every feasible completion on collections
            // dominated by short, similar moments. This lane still uses scored,
            // non-overlapping candidates and the same source and lock constraints.
            if let capacityPath = next.max(by: { lhs, rhs in
                let left = lhs.chosen.reduce(0) { $0 + $1.ticks }
                let right = rhs.chosen.reduce(0) { $0 + $1.ticks }
                return left == right ? lhs.score < rhs.score : left < right
            }), !states.contains(where: { signature($0) == signature(capacityPath) }) {
                if states.count >= Self.beamWidth { states.removeLast() }
                states.append(capacityPath)
            }
        }
        return completed.sorted { lhs, rhs in
            let left = lhs.score / Double(max(1, lhs.chosen.count))
                - 0.65 * abs(Double(lhs.chosen.count - preferredCount)) / Double(preferredCount)
            let right = rhs.score / Double(max(1, rhs.chosen.count))
                - 0.65 * abs(Double(rhs.chosen.count - preferredCount)) / Double(preferredCount)
            if abs(left - right) > 0.000001 { return left > right }
            return signature(lhs) < signature(rhs)
        }
    }

    private func candidateScore(_ candidate: CandidateMoment, state: State, request: PlanningRequest,
                                variant: Int, remaining: Int, existing: [MontagePlan]) -> Double {
        var value = MomentScorer.score(candidate, intent: request.intent,
                                       parameters: request.parameters, profile: variant)
        if let tasteProfile = request.tasteProfile {
            value += tasteProfile.scoreAdjustment(for: candidate, intent: request.intent)
        }
        let interval = SourceInterval(assetID: candidate.sourceAssetID, start: candidate.sourceStartTime,
                                      end: candidate.sourceEndTime)
        if state.intervals.contains(where: { $0.assetID == interval.assetID }) { value -= 0.13 }
        if candidate.clusterID >= 0 {
            let sameClusterCount = state.chosen.filter { $0.moment.clusterID == candidate.clusterID }.count
            if sameClusterCount > 0 { value -= 0.14 * Double(sameClusterCount) }
            if sameClusterCount > 1 { value -= 0.18 * Double(sameClusterCount - 1) }
        }
        if let previous = state.last {
            let similarity = MomentScorer.semanticSimilarity(previous, candidate)
            value -= 0.23 * similarity
            if previous.clusterID >= 0 && previous.clusterID == candidate.clusterID { value -= 0.18 }
            if previous.sourceAssetID == candidate.sourceAssetID { value -= 0.09 }
        }
        if request.intent == .story, let previousDate = state.lastTimestamp, let date = candidate.timestamp {
            if date < previousDate { value -= 0.22 }
            else { value += 0.08 }
        }
        if request.intent == .story, candidate.timestamp == nil || state.lastTimestamp == nil,
           let previous = state.last?.importOrder, let current = candidate.importOrder {
            value += current >= previous ? 0.08 : -0.22
        }
        let maxTicks = Self.ticks(candidate.duration)
        value += 0.04 * min(1, Double(maxTicks) / Double(max(1, remaining)))
        for plan in existing where plan.segments.contains(where: { $0.momentID == candidate.id }) {
            value -= 0.17
        }
        value += deterministicNoise(candidate.id, seed: request.seed, variant: variant) * 0.045
        return value
    }

    private func sequenceScore(_ candidate: CandidateMoment, duration: Int, ending: Bool, state: State,
                               request: PlanningRequest, variant: Int, pacing: RecipePacing,
                               existing: [MontagePlan]) -> Double {
        var value = candidateScore(candidate, state: state, request: request, variant: variant,
                                   remaining: max(duration, Self.minimumTicks), existing: existing)
        let features = candidate.features
        let elapsed = state.chosen.reduce(0) { $0 + $1.ticks }
        value += pacing.score(duration: Double(duration) / Self.ticksPerSecond,
                              elapsed: Double(elapsed) / Self.ticksPerSecond,
                              momentsFromClip: state.chosen.filter { $0.moment.sourceAssetID == candidate.sourceAssetID }.count)
        value += pacing.placementScore(candidate, isFirst: state.chosen.isEmpty, isLast: ending,
                                       elapsed: Double(elapsed) / Self.ticksPerSecond,
                                       duration: Double(duration) / Self.ticksPerSecond)
        if let previous = state.last { value += pacing.varietyScore(candidate, after: previous) }
        if state.chosen.isEmpty {
            // Open on a legible, high-confidence image. A clear place or face
            // gives the edit an immediate subject instead of a weak setup frame.
            value += 0.10 * (features.quality + features.novelty)
                + 0.06 * max(features.scenery, features.people)
        }
        if ending {
            // The last shot carries the close. Stability and quality make the
            // ending feel intentional when the remaining duration is short.
            value += 0.04 * (features.stability + features.quality)
        }
        if let timestamp = candidate.timestamp, let previous = state.lastTimestamp {
            let delta = timestamp.timeIntervalSince(previous)
            if request.intent == .story { value += delta >= 0 ? 0.06 : -0.20 }
        }
        if request.intent == .beatSync {
            let desired = desiredTicks(for: candidate, intent: request.intent,
                                       parameters: request.parameters, profile: variant,
                                       tasteProfile: request.tasteProfile)
            value -= 0.10 * min(1, abs(Double(duration - desired)) / Double(max(1, desired)))
        }
        return value
    }

    private func makePlan(best: State, locks: [MontageSegment], request: PlanningRequest,
                          musicStart: Double, variant: Int, allCandidates: [CandidateMoment]) -> MontagePlan {
        let chosen = best.chosen
        let ordered: [Chosen]
        ordered = chosen
        let selectedIDs = Set(ordered.map { $0.moment.id } + locks.map { $0.momentID })
        var segments: [MontageSegment] = []
        for (index, selected) in ordered.enumerated() {
            let moment = selected.moment
            let alternatives = allCandidates
                .filter { !selectedIDs.contains($0.id) && $0.sourceAssetID != moment.sourceAssetID }
                .sorted {
                    let left = MomentScorer.semanticSimilarity(moment, $0)
                    let right = MomentScorer.semanticSimilarity(moment, $1)
                    if abs(left - right) > 0.000001 { return left > right }
                    return $0.id.uuidString < $1.id.uuidString
                }
                .prefix(5).map(\.id)
            segments.append(MontageSegment(id: deterministicUUID(seed: request.seed, variant: variant,
                                                                  index: index, momentID: moment.id),
                                           momentID: moment.id, sourceAssetID: moment.sourceAssetID,
                                           sourceStartTime: moment.preferredStart(for: Double(selected.ticks) / Self.ticksPerSecond),
                                           duration: Double(selected.ticks) / Self.ticksPerSecond,
                                           isLocked: false,
                                           reasons: reasons(for: moment, request: request, duration: selected.ticks),
                                           alternativeIDs: alternatives, subject: moment.subject))
        }
        for lock in locks {
            if let index = segments.firstIndex(where: { $0.momentID == lock.momentID }) {
                segments[index] = lock
            } else {
                let desired = lock.preferredTimelineStart ?? 0
                var elapsed = 0.0
                var insertion = segments.count
                for (index, segment) in segments.enumerated() {
                    if elapsed + segment.duration / 2 >= desired { insertion = index; break }
                    elapsed += segment.duration
                }
                segments.insert(lock, at: insertion)
            }
        }
        let metrics = metrics(for: segments, candidates: allCandidates, music: request.music, musicStart: musicStart)
        let signature = segments.map { $0.momentID.uuidString }.joined(separator: ",")
        let id = deterministicUUID(seed: request.seed ^ (UInt64(variant + 1) &* 0x9E3779B97F4A7C15),
                                   variant: variant, index: segments.count, momentID: deterministicUUID(for: signature))
        let names: [EditIntent: [String]] = [
            .beatSync: ["Beat Sync · Balanced", "Beat Sync · Scenic", "Beat Sync · Motion"],
            .story: ["Story", "Story · Journey", "Story · Chapters"],
            .cinematic: ["Cinematic", "Cinematic · Wide", "Cinematic · Quiet"],
            .highlights: ["Highlights", "Highlights · Spark", "Highlights · Best Of"],
            .people: ["People", "People · Together", "People · Faces"],
            .places: ["Places", "Places · Postcards", "Places · Details"],
            .travel: ["Travel", "Travel · On the Move", "Travel · Slow Days"]
        ]
        return MontagePlan(id: id, name: names[request.intent]?[variant] ?? request.intent.title,
                           summary: summary(for: request.intent, variant: variant), intent: request.intent,
                           seed: request.seed, musicStartTime: musicStart, segments: segments, metrics: metrics,
                           tasteProfile: request.tasteProfile)
    }

    /// Lengthens shots below the recipe's shortest length, taking the time from
    /// the longest unlocked shots. Each shot stays inside its own moment, and the
    /// edit keeps its exact length. Shots stay short if nothing can give time.
    private func fitShotLimits(_ plan: inout MontagePlan, request: PlanningRequest, candidates: [CandidateMoment]) {
        let shortest = StyleRecipe.recipe(for: request.intent).shortestShot
        let lookup = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        for index in plan.segments.indices where !plan.segments[index].isLocked && plan.segments[index].duration < shortest {
            guard let moment = lookup[plan.segments[index].momentID] else { continue }
            var needed = min(shortest, moment.duration) - plan.segments[index].duration
            let donors = plan.segments.indices.filter { !plan.segments[$0].isLocked && plan.segments[$0].duration > shortest }
                .sorted { plan.segments[$0].duration > plan.segments[$1].duration }
            for donor in donors where needed > 0 {
                guard let source = lookup[plan.segments[donor].momentID] else { continue }
                let taken = roundToTick(min(needed, plan.segments[donor].duration - shortest))
                guard taken > 0 else { continue }
                plan.segments[donor].duration -= taken
                plan.segments[donor].sourceStartTime = source.preferredStart(for: plan.segments[donor].duration)
                plan.segments[index].duration += taken
                needed -= taken
            }
            plan.segments[index].sourceStartTime = moment.preferredStart(for: plan.segments[index].duration)
        }
    }

    /// Adjust neighboring unlocked shots together, so every musical cut keeps
    /// the requested length. Locks retain their exact source ranges and duration.
    private func alignBoundaries(_ plan: inout MontagePlan, request: PlanningRequest, candidates: [CandidateMoment]) {
        guard plan.segments.count > 1 else { return }
        let lookup = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let events = request.music.events.filter {
            [.strongBeat, .beat, .downbeat, .drop, .transition].contains($0.kind)
        }
        // Prefer the strongest places to cut: a drop, then the start of a bar.
        func pull(_ event: MusicEvent) -> Double {
            event.strength * 0.035 + (event.kind == .drop ? 0.20 : event.kind == .downbeat ? 0.08 : 0)
        }
        let recipe = StyleRecipe.recipe(for: request.intent)
        let shortest = max(0.5, recipe.shortestShot)
        var elapsed = 0.0
        for index in 0..<(plan.segments.count - 1) {
            elapsed += plan.segments[index].duration
            guard !plan.segments[index].isLocked, !plan.segments[index + 1].isLocked,
                  let left = lookup[plan.segments[index].momentID],
                  let right = lookup[plan.segments[index + 1].momentID] else { continue }
            let desired = plan.musicStartTime + elapsed
            let tolerance = recipe.cutTolerance
            let eligible = events.filter { abs($0.time - desired) <= tolerance }
            guard let event = eligible.min(by: {
                abs($0.time - desired) - pull($0) < abs($1.time - desired) - pull($1)
            }) else { continue }
            let shift = roundToTick(event.time - desired)
            let leftDuration = plan.segments[index].duration + shift
            let rightDuration = plan.segments[index + 1].duration - shift
            guard leftDuration >= shortest, rightDuration >= shortest,
                  leftDuration <= left.duration, rightDuration <= right.duration else { continue }
            plan.segments[index].duration = leftDuration
            plan.segments[index + 1].duration = rightDuration
            plan.segments[index].sourceStartTime = min(plan.segments[index].sourceStartTime, left.sourceEndTime - leftDuration)
            plan.segments[index + 1].sourceStartTime = min(plan.segments[index + 1].sourceStartTime, right.sourceEndTime - rightDuration)
            plan.segments[index].reasons.append(event.kind == .drop ? "cut aligned with the drop"
                : event.kind == .downbeat ? "cut aligned with the start of a bar"
                : event.kind == .strongBeat ? "cut aligned with a strong beat" : "cut aligned with the music")
            elapsed += shift
        }
    }

    private func isDistinct(_ plan: MontagePlan, from prior: MontagePlan) -> Bool {
        let left = plan.segments.filter { !$0.isLocked }.map(\.momentID)
        let right = prior.segments.filter { !$0.isLocked }.map(\.momentID)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let lhs = Set(left), rhs = Set(right)
        let union = lhs.union(rhs)
        let overlap = Double(lhs.intersection(rhs).count) / Double(max(1, union.count))
        let samePositions = zip(left, right).filter { $0 == $1 }.count
        let orderDifference = 1 - Double(samePositions) / Double(max(left.count, right.count))
        return overlap <= 0.85 || (left.first != right.first && orderDifference >= 0.35)
    }

    private func reasons(for moment: CandidateMoment, request: PlanningRequest, duration: Int) -> [String] {
        let f = moment.features
        var result: [String] = []
        if MomentScorer.qualityScore(moment) >= 0.7 { result.append("high visual quality") }
        if f.motion >= 0.65 { result.append("adds movement") }
        if f.scenery >= 0.65 { result.append("adds scenery") }
        if f.people >= 0.65 || f.faces >= 0.65 { result.append("keeps people present") }
        if request.intent == .story, moment.timestamp != nil { result.append("supports the journey order") }
        if request.intent == .beatSync, request.music.events.contains(where: { abs($0.time - Double(duration) / Self.ticksPerSecond) < 0.15 }) {
            result.append("fits the musical pulse")
        }
        if let tasteProfile = request.tasteProfile,
           abs(tasteProfile.durationMultiplier(for: request.intent) - 1) > TasteProfile.epsilon
                || abs(tasteProfile.scoreAdjustment(for: moment, intent: request.intent)) > TasteProfile.epsilon {
            result.append("personalized to your taste")
        }
        if let sounds = moment.signals?.sounds {
            if sounds.contains(where: MomentScorer.peopleSounds.contains) { result.append("has the sound of people") }
            if sounds.contains(where: MomentScorer.placeSounds.contains) { result.append("has the sound of the place") }
        }
        if result.isEmpty { result.append("balanced for the selected intent") }
        return result
    }

    private func summary(for intent: EditIntent, variant: Int) -> String {
        switch intent {
        case .beatSync: return ["Balanced follows strong musical points.", "Scenic favors scenery and novelty with shorter target shots.", "Motion favors movement and interest with longer holds."][variant]
        case .story: return ["A chronological version of the journey.", "A chaptered journey with gentle variation.", "A reflective story with a softer arc."][variant]
        case .cinematic: return ["Beautiful moments have room to breathe.", "Wide scenes and measured movement.", "A quiet, spacious memory film."][variant]
        case .highlights: return ["The strongest moments, assembled with pace.", "A bright selection of standout scenes.", "A varied best-of cut."][variant]
        case .people: return ["The people who made the trip.", "A warm sequence of shared moments.", "Faces and connections lead the edit."][variant]
        case .places: return ["A sense of somewhere, from wide to close.", "A postcard-like path through the places.", "Details and landmarks shape the journey."][variant]
        case .travel: return ["A moving diary of the trip.", "Quicker shots that keep the trip moving.", "A gentler pace through the days."][variant]
        }
    }

    private func metrics(for segments: [MontageSegment], candidates: [CandidateMoment], music: MusicAnalysis, musicStart: Double) -> MontageMetrics {
        let lookup = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let moments = segments.compactMap { lookup[$0.momentID] }
        var result = MontageMetrics()
        result.usedSources = Set(segments.map(\.sourceAssetID)).count
        result.averageDuration = segments.isEmpty ? 0 : segments.reduce(0) { $0 + $1.duration } / Double(segments.count)
        if !segments.isEmpty, !music.events.isEmpty {
            var cursor = musicStart
            var aligned = 0
            for segment in segments {
                cursor += segment.duration
                // Hits between beats are common in real songs, so they do not count.
                let closest = music.events.filter { $0.kind != .onset && $0.kind != .silence }
                    .map { abs($0.time - cursor) }.min() ?? .infinity
                if closest <= 0.16 { aligned += 1 }
            }
            result.beatAlignment = Double(aligned) / Double(segments.count)
        }
        if moments.count > 1 {
            let pairs = zip(moments, moments.dropFirst())
            let ordered = pairs.filter { lhs, rhs in
                guard let l = lhs.timestamp, let r = rhs.timestamp else { return true }
                return l <= r
            }.count
            result.chronologicalConsistency = Double(ordered) / Double(moments.count - 1)
        } else {
            result.chronologicalConsistency = 1
        }
        result.semanticDiversity = Set(moments.flatMap(\.semanticTags).map { $0.lowercased() }).count
        result.meanQuality = moments.isEmpty ? 0 : moments.reduce(0) { $0 + MomentScorer.qualityScore($1) } / Double(moments.count)
        result.meanMotion = moments.isEmpty ? 0 : moments.reduce(0) { $0 + MomentScorer.clamp($1.features.motion) } / Double(moments.count)
        return result
    }

    private func chooseMusicStart(_ music: MusicAnalysis, target: Double, intent: EditIntent,
                                  parameters: CreativeParameters, seed: UInt64, variant: Int) -> Double {
        let latest = max(0, music.duration - target)
        var starts = [0.0, latest]
        starts.append(contentsOf: music.sections.map(\.start).filter { $0 >= 0 && $0 <= latest })
        starts.append(contentsOf: music.events.filter { $0.kind == .strongBeat || $0.kind == .build }
            .map { max(0, min(latest, $0.time - min(1.0, target / 8))) })
        // Start early enough that a drop lands about two-thirds into the edit.
        let drops = music.events.filter { $0.kind == .drop }
        starts.append(contentsOf: drops.map { max(0, min(latest, $0.time - target * 2 / 3)) })
        let unique = Array(Set(starts.map { min(latest, max(0, $0)) })).sorted()
        guard !unique.isEmpty else { return 0 }
        let energy = MomentScorer.clamp(parameters.energy)
        let desiredEnergy: Double
        switch intent {
        case .beatSync, .highlights: desiredEnergy = 0.40 + 0.55 * energy
        case .cinematic: desiredEnergy = 0.20 + 0.50 * energy
        case .story, .people, .places, .travel: desiredEnergy = 0.30 + 0.50 * energy
        }
        // Calculate each window once. Sorting must not repeatedly scan long audio timelines.
        var ranked: [(start: Double, score: Double)] = []
        for start in unique {
            let match: Double = 1 - abs(averageEnergy(music, start: start, duration: target) - desiredEnergy)
            let atSectionStart = music.sections.contains(where: { abs($0.start - start) < 0.25 })
            let sectionBonus: Double = atSectionStart ? 0.06 : 0.0
            let holdsPayoff = drops.contains { $0.time >= start + target * 0.4 && $0.time <= start + target * 0.9 }
            let payoffBonus: Double = holdsPayoff ? 0.20 : 0
            let noiseID = UInt64(max(0, Int(start * 600)))
            let noise = deterministicNoise(noiseID, seed: seed, variant: variant) * 0.04
            let score = match + sectionBonus + payoffBonus + noise
            ranked.append((start: start, score: score))
        }
        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.start < rhs.start }
            return lhs.score > rhs.score
        }
        return roundToTick(ranked[min(variant, ranked.count - 1)].start)
    }

    private func averageEnergy(_ music: MusicAnalysis, start: Double, duration: Double) -> Double {
        let values = music.energy.filter { $0.time >= start && $0.time <= start + duration }.map(\.value)
        if !values.isEmpty { return values.reduce(0, +) / Double(values.count) }
        let sections = music.sections.filter { $0.end > start && $0.start < start + duration }.map(\.energy)
        return sections.isEmpty ? 0 : sections.reduce(0, +) / Double(sections.count)
    }

    private func desiredTicks(for moment: CandidateMoment, intent: EditIntent, parameters: CreativeParameters,
                              profile: Int, tasteProfile: TasteProfile? = nil) -> Int {
        let f = moment.features
        let highlights = MomentScorer.clamp(parameters.highlights)
        let energy = MomentScorer.clamp(parameters.energy)
        let fastCuts = MomentScorer.clamp(parameters.fastCuts)
        let stability = f.stability.isFinite ? MomentScorer.clamp(f.stability) : 0.5
        let quality = f.quality.isFinite ? MomentScorer.clamp(f.quality) : 0.5
        let average: Double
        switch intent {
        case .beatSync: average = 0.75 + 0.75 * (1 - fastCuts) + 0.25 * (1 - energy)
        case .story: average = 1.8 + 0.8 * highlights
        case .cinematic: average = 3.0 + 1.6 * (1 - fastCuts) + 0.5 * stability
        case .highlights: average = 1.4 + 0.7 * (1 - fastCuts)
        case .people, .places: average = 1.8 + 0.7 * (1 - fastCuts)
        case .travel: average = 1.2 + 0.8 * (1 - fastCuts)
        }
        let profileAdjustment: Double = profile == 1 ? 0.75 : profile == 2 ? 1.20 : 1.0
        let tasteMultiplier = tasteProfile?.durationMultiplier(for: intent) ?? 1
        let value = average * profileAdjustment * tasteMultiplier * (0.75 + 0.35 * quality)
        return max(Self.minimumTicks, Int((value * Self.ticksPerSecond).rounded()))
    }

    private func overlaps(_ lhs: SourceInterval, _ rhs: SourceInterval) -> Bool {
        lhs.assetID == rhs.assetID && min(lhs.end, rhs.end) - max(lhs.start, rhs.start) > 1.0 / Self.ticksPerSecond
    }

    private func signature(_ state: State) -> String {
        state.chosen.map { "\($0.moment.id.uuidString):\($0.ticks)" }.joined(separator: "|")
    }

    private static func ticks(_ seconds: Double) -> Int { max(0, Int((seconds * ticksPerSecond).rounded())) }
    private func roundToTick(_ seconds: Double) -> Double { (seconds * Self.ticksPerSecond).rounded() / Self.ticksPerSecond }

    private func deterministicNoise(_ id: UUID, seed: UInt64, variant: Int) -> Double {
        let bytes = id.uuidString.utf8.reduce(seed ^ (UInt64(variant + 1) &* 0x9E3779B97F4A7C15)) { hash, byte in
            var value = hash ^ UInt64(byte)
            value &*= 1099511628211
            return value
        }
        return Double(bytes % 10_000) / 10_000
    }

    private func deterministicNoise(_ value: UInt64, seed: UInt64, variant: Int) -> Double {
        var hash = seed ^ value ^ (UInt64(variant + 1) &* 0x9E3779B97F4A7C15)
        hash ^= hash >> 30; hash &*= 0xBF58476D1CE4E5B9
        hash ^= hash >> 27; hash &*= 0x94D049BB133111EB
        hash ^= hash >> 31
        return Double(hash % 10_000) / 10_000
    }

    private func deterministicUUID(for string: String) -> UUID {
        var a: UInt64 = 1469598103934665603
        var b: UInt64 = 1099511628211
        for byte in string.utf8 {
            a ^= UInt64(byte); a &*= 1099511628211
            b ^= UInt64(byte); b &*= 14029467366897019727
        }
        return uuid(from: a, b)
    }

    private func deterministicUUID(seed: UInt64, variant: Int, index: Int, momentID: UUID) -> UUID {
        var value = seed ^ UInt64(bitPattern: Int64(variant)) &* 0x9E3779B97F4A7C15 ^ UInt64(index)
        for byte in momentID.uuidString.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
        return uuid(from: value, value ^ 0xD6E8FEB86659FD93)
    }

    private func uuid(from first: UInt64, _ second: UInt64) -> UUID {
        let bytes: [UInt8] = [
            UInt8((first >> 56) & 0xff), UInt8((first >> 48) & 0xff), UInt8((first >> 40) & 0xff), UInt8((first >> 32) & 0xff),
            UInt8((first >> 24) & 0xff), UInt8((first >> 16) & 0xff), UInt8((first >> 8) & 0xff), UInt8(first & 0xff),
            UInt8((second >> 56) & 0xff), UInt8((second >> 48) & 0xff), UInt8((second >> 40) & 0xff), UInt8((second >> 32) & 0xff),
            UInt8((second >> 24) & 0xff), UInt8((second >> 16) & 0xff), UInt8((second >> 8) & 0xff), UInt8(second & 0xff)
        ]
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
