import Foundation

/// A digital camera move inside one shot. Raw values are the edit spec's IDs.
public enum ZoomKind: String, Codable, Sendable, CaseIterable {
    case punchIn = "Z1", pulse = "Z2", pushIn = "Z4", pullOut = "Z5"
}

/// One entry in an edit's decision list. It describes the edit, never pixels.
public struct PlannedEdit: Codable, Equatable, Sendable {
    public var kind: ZoomKind
    /// The cut-free shot this edit belongs to.
    public var segmentID: UUID
    /// Start and end in edit time, in seconds.
    public var start: Double
    public var end: Double
    /// The largest scale. 1.12 means 112% of the frame.
    public var peakScale: Double

    /// The scale at a time in the edit. Times outside the edit return 1.
    public func scale(at time: Double) -> Double {
        guard time >= start, time < end, end > start else { return 1 }
        let elapsed = time - start
        switch kind {
        case .punchIn:
            return peakScale
        case .pushIn:
            return 1 + (peakScale - 1) * (elapsed / (end - start))
        case .pullOut:
            return peakScale - (peakScale - 1) * (elapsed / (end - start))
        case .pulse:
            let attack = EditPlanner.pulseAttack
            if elapsed < attack { return 1 + (peakScale - 1) * (elapsed / attack) }
            let t = min(1, (elapsed - attack) / max(0.001, end - start - attack))
            return 1 + (peakScale - 1) * (1 - t) * (1 - t)
        }
    }
}

/// Writes the zooms for an edit. Pure and deterministic, so the same plan always
/// gives the same list, and a changed shot can never leave a stale zoom behind.
public enum EditPlanner {
    /// Change this when edit choices change, so cached previews render again.
    public static let version = 2
    static let frame = 1.0 / 30
    /// 2 frames up and 10 frames down, from the edit spec's Z2 defaults.
    static let pulseAttack = 2 * frame
    static let pulseLength = 12 * frame
    /// A slow move needs time to read as a move.
    static let shortestSlowMove = 1.5
    /// Keep a punch-in away from the cut, or it looks like a mistake.
    static let cutMargin = 0.3
    static let punchInSpacing = 8.0
    /// The most a source smaller than the output may be scaled.
    public static let lowResolutionLimit = 1.2
    /// A quiet stretch before the payoff, from the spec's "moments of rest".
    static let restBeats = 2.0

    /// - Parameter scaleLimits: The largest scale for each segment, in order.
    public static func edits(for plan: MontagePlan, music: MusicAnalysis?,
                             recipe: StyleRecipe, scaleLimits: [Double] = []) -> [PlannedEdit] {
        let intensity = min(1, max(0, recipe.zoomIntensity))
        let beat = music?.bpm.flatMap { $0.isFinite && $0 > 0 ? 60 / $0 : nil }
        let peak = music.flatMap { RecipePacing.peakTime(in: $0, musicStart: plan.musicStartTime, duration: plan.duration) }
        let rest = (peak ?? 0) - restBeats * (beat ?? 0.5)
        let accents = (music?.events ?? [])
            .filter { [.strongBeat, .beat, .downbeat, .drop].contains($0.kind) }
            // The start of a bar and a bass hit carry a zoom best.
            .map { event -> (time: Double, strength: Double) in
                let weight = (event.kind == .downbeat ? 0.3 : 0) + (event.band == .low ? 0.1 : 0)
                return (event.time - plan.musicStartTime, event.strength + weight)
            }
            .filter { $0.time >= 0 && $0.time < plan.duration }
            .sorted { $0.time < $1.time }

        var result: [PlannedEdit] = []
        var start = 0.0
        var nextSlowMove = ZoomKind.pushIn
        var lastPunchIn = -Double.infinity
        for (index, segment) in plan.segments.enumerated() {
            defer { start += segment.duration }
            let end = start + segment.duration
            let limit = index < scaleLimits.count ? scaleLimits[index] : .infinity
            func capped(_ scale: Double) -> Double { min(scale, limit) }
            // Leave the build-up clean, so the payoff lands harder.
            func isResting(_ time: Double) -> Bool { peak.map { time >= rest && time < $0 } ?? false }
            let inShot = accents.filter { $0.time >= start && $0.time < end }

            // The payoff always gets its punch-in. Others keep clear of it.
            let holdsPeak = peak.map { $0 >= start && $0 < end } ?? false
            let nearPeak = peak.map { $0 > start && $0 - start < punchInSpacing } ?? false
            if recipe.zooms.contains(.punchIn), holdsPeak || (start - lastPunchIn >= punchInSpacing && !nearPeak) {
                let usable = inShot.filter { $0.time >= start + cutMargin && $0.time <= end - cutMargin && !isResting($0.time) }
                // Prefer the payoff itself, then the strongest beat in the shot.
                let anchor = peak.flatMap { value in usable.min { abs($0.time - value) < abs($1.time - value) }.flatMap { abs($0.time - value) < 0.5 ? $0 : nil } }
                    ?? usable.max { $0.strength < $1.strength }
                if let anchor {
                    result.append(PlannedEdit(kind: .punchIn, segmentID: segment.id, start: anchor.time, end: end,
                                              peakScale: capped(1.15 + 0.15 * intensity)))
                    lastPunchIn = start
                    continue
                }
            }
            let slowMoves: [ZoomKind] = [nextSlowMove, nextSlowMove == .pushIn ? .pullOut : .pushIn]
            let isLast = index == plan.segments.count - 1
            if segment.duration >= shortestSlowMove, !isResting(start),
               let move = isLast && recipe.zooms.contains(.pullOut) ? .pullOut : slowMoves.first(where: recipe.zooms.contains) {
                let scale = move == .pushIn ? 1.05 + 0.05 * intensity : 1.07 + 0.05 * intensity
                result.append(PlannedEdit(kind: move, segmentID: segment.id, start: start, end: end, peakScale: capped(scale)))
                nextSlowMove = move == .pushIn ? .pullOut : .pushIn
                continue
            }
            if recipe.zooms.contains(.pulse), let beat, segment.duration >= 2 * beat {
                var last = -Double.infinity
                for accent in inShot where accent.time - last >= 2 * beat
                    && accent.time + pulseLength <= end && !isResting(accent.time) {
                    result.append(PlannedEdit(kind: .pulse, segmentID: segment.id, start: accent.time,
                                              end: accent.time + pulseLength, peakScale: capped(1.05 + 0.10 * intensity)))
                    last = accent.time
                }
            }
        }
        return result
    }
}
