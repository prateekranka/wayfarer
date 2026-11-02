import Foundation

/// Small, bounded edits to an existing decision list.
///
/// Refinement keeps the plan duration and rejects changes that would move a
/// source range outside the supplied candidate moment. Pass `moments` when the
/// caller has the analysis catalogue; the convenience overloads use the ranges
/// already present in the plan.
public enum PlanRefiner {
    private static let tick = 1.0 / 600.0
    private static let minimum = 0.15

    public static func replace(plan: MontagePlan, segmentID: UUID, with moment: CandidateMoment,
                               moments: [CandidateMoment] = []) throws -> MontagePlan {
        guard let index = plan.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw MontageError.invalidPlan("The selected segment is not in this edit.")
        }
        let old = plan.segments[index]
        guard !old.isLocked else { throw MontageError.invalidPlan("Locked moments cannot be replaced.") }
        let duration = old.duration
        let sourceStart = moment.preferredStart(for: duration)
        guard moment.duration >= old.duration - tick,
              !plan.segments.contains(where: { $0.id != old.id && $0.sourceAssetID == moment.sourceAssetID &&
                  rangesOverlap($0.sourceStartTime, $0.duration, sourceStart, duration) }) else {
            throw MontageError.invalidPlan("The replacement moment overlaps another segment.")
        }
        guard sourceStart >= 0, sourceStart + duration <= moment.sourceEndTime + tick else {
            throw MontageError.invalidPlan("The replacement moment is shorter than the selected segment.")
        }
        var result = plan
        result.segments[index] = MontageSegment(id: old.id, momentID: moment.id, sourceAssetID: moment.sourceAssetID,
                                                sourceStartTime: sourceStart, duration: duration, isLocked: false,
                                                reasons: ["replaced by the selected moment"], alternativeIDs: old.alternativeIDs,
                                                subject: moment.subject)
        try validate(result, moments: moments)
        return result
    }

    public static func resize(plan: MontagePlan, segmentID: UUID, to duration: Double,
                              moments: [CandidateMoment] = []) throws -> MontagePlan {
        guard duration.isFinite, duration >= minimum else {
            throw MontageError.invalidPlan("A segment must be at least 0.15 seconds long.")
        }
        guard let index = plan.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw MontageError.invalidPlan("The selected segment is not in this edit.")
        }
        guard !plan.segments[index].isLocked else {
            throw MontageError.invalidPlan("Locked moments cannot be resized.")
        }
        let oldDuration = plan.segments[index].duration
        let targetTicks = ticks(plan.duration)
        var result = plan
        result.segments[index].duration = quantize(duration)
        if let moment = moments.first(where: { $0.id == result.segments[index].momentID }) {
            result.segments[index].sourceStartTime = max(moment.sourceStartTime,
                min(result.segments[index].sourceStartTime, moment.sourceEndTime - result.segments[index].duration))
        }
        let delta = ticks(result.segments[index].duration) - ticks(oldDuration)
        if delta != 0 {
            try redistribute(&result, ticks: -delta, excluding: index, moments: moments)
        }
        try validate(result, moments: moments)
        guard ticks(result.duration) == targetTicks else {
            throw MontageError.invalidPlan("The edit length changed during resize.")
        }
        return result
    }

    public static func resize(plan: MontagePlan, segmentID: UUID, duration: Double,
                              moments: [CandidateMoment] = []) throws -> MontagePlan {
        try resize(plan: plan, segmentID: segmentID, to: duration, moments: moments)
    }

    public static func move(plan: MontagePlan, segmentID: UUID, by offset: Int) throws -> MontagePlan {
        guard let from = plan.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw MontageError.invalidPlan("The selected segment is not in this edit.")
        }
        let to = min(max(0, from + offset), plan.segments.count - 1)
        return try move(plan: plan, segmentID: segmentID, to: to)
    }

    public static func move(plan: MontagePlan, segmentID: UUID, offset: Int) throws -> MontagePlan {
        try move(plan: plan, segmentID: segmentID, by: offset)
    }

    public static func move(plan: MontagePlan, segmentID: UUID, to index: Int) throws -> MontagePlan {
        guard let from = plan.segments.firstIndex(where: { $0.id == segmentID }),
              index >= 0, index < plan.segments.count else {
            throw MontageError.invalidPlan("The selected segment position is invalid.")
        }
        guard !plan.segments[from].isLocked else {
            throw MontageError.invalidPlan("Locked moments cannot be moved.")
        }
        if plan.segments.enumerated().contains(where: { $0.element.isLocked && $0.offset != from &&
            ((from < $0.offset && index >= $0.offset) || (from > $0.offset && index <= $0.offset)) }) {
            throw MontageError.invalidPlan("A move cannot cross a locked moment.")
        }
        var result = plan
        let item = result.segments.remove(at: from)
        result.segments.insert(item, at: min(index, result.segments.count))
        return result
    }

    public static func remove(plan: MontagePlan, segmentID: UUID,
                              moments: [CandidateMoment] = []) throws -> MontagePlan {
        guard let index = plan.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw MontageError.invalidPlan("The selected segment is not in this edit.")
        }
        guard !plan.segments[index].isLocked else {
            throw MontageError.invalidPlan("Locked moments cannot be removed.")
        }
        let released = ticks(plan.segments[index].duration)
        var result = plan
        result.segments.remove(at: index)
        guard !result.segments.isEmpty else {
            throw MontageError.insufficientFootage
        }
        try redistribute(&result, ticks: released, excluding: nil, moments: moments)
        try validate(result, moments: moments)
        guard ticks(result.duration) == ticks(plan.duration) else {
            throw MontageError.invalidPlan("The edit length changed during removal.")
        }
        return result
    }

    private static func redistribute(_ plan: inout MontagePlan, ticks amount: Int,
                                     excluding: Int?, moments: [CandidateMoment]) throws {
        guard amount != 0 else { return }
        let lookup = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        var remaining = abs(amount)
        let direction = amount > 0 ? 1 : -1
        let indices = plan.segments.indices.filter { index in
            guard index != excluding, !plan.segments[index].isLocked else { return false }
            if direction < 0 { return ticks(plan.segments[index].duration) - remainingMinimum(plan.segments[index]) > 0 }
            guard let moment = lookup[plan.segments[index].momentID] else { return moments.isEmpty }
            return ticks(moment.duration) > ticks(plan.segments[index].duration)
        }
        for index in indices {
            guard remaining > 0 else { break }
            let current = ticks(plan.segments[index].duration)
            let capacity: Int
            if direction > 0 {
                capacity = lookup[plan.segments[index].momentID].map { max(0, ticks($0.duration) - current) } ?? remaining
            } else {
                capacity = max(0, current - Int((minimum * 600).rounded()))
            }
            let change = min(remaining, capacity)
            plan.segments[index].duration = Double(current + direction * change) / 600.0
            if let moment = lookup[plan.segments[index].momentID] {
                plan.segments[index].sourceStartTime = max(moment.sourceStartTime,
                    min(plan.segments[index].sourceStartTime, moment.sourceEndTime - plan.segments[index].duration))
            }
            remaining -= change
        }
        guard remaining == 0 else {
            throw MontageError.insufficientFootage
        }
    }

    private static func validate(_ plan: MontagePlan, moments: [CandidateMoment]) throws {
        guard plan.segments.allSatisfy({ $0.duration.isFinite && $0.duration >= minimum }) else {
            throw MontageError.invalidPlan("A segment is shorter than the minimum usable duration.")
        }
        let lookup = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        for segment in plan.segments {
            if let moment = lookup[segment.momentID] {
                guard segment.sourceAssetID == moment.sourceAssetID,
                      segment.sourceStartTime >= moment.sourceStartTime - tick,
                      segment.sourceStartTime + segment.duration <= moment.sourceEndTime + tick else {
                    throw MontageError.invalidPlan("A refined segment exceeds its source moment.")
                }
            }
        }
        for lhsIndex in plan.segments.indices {
            for rhsIndex in plan.segments.indices where rhsIndex > lhsIndex {
                let lhs = plan.segments[lhsIndex], rhs = plan.segments[rhsIndex]
                if lhs.sourceAssetID == rhs.sourceAssetID,
                   rangesOverlap(lhs.sourceStartTime, lhs.duration, rhs.sourceStartTime, rhs.duration) {
                    throw MontageError.invalidPlan("Refined segments overlap in the same source clip.")
                }
            }
        }
    }

    private static func rangesOverlap(_ lhsStart: Double, _ lhsDuration: Double,
                                      _ rhsStart: Double, _ rhsDuration: Double) -> Bool {
        min(lhsStart + lhsDuration, rhsStart + rhsDuration) - max(lhsStart, rhsStart) > tick
    }

    private static func ticks(_ value: Double) -> Int { Int((value * 600).rounded()) }
    private static func quantize(_ value: Double) -> Double { Double(ticks(value)) / 600.0 }
    private static func remainingMinimum(_ segment: MontageSegment) -> Int { Int((minimum * 600).rounded()) }
}
