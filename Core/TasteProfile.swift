import Foundation

public enum TasteDimension: String, Codable, CaseIterable, Identifiable, Sendable {
    case motion, scenery, people, novelty, pacing

    public var id: Self { self }

    public var title: String {
        switch self {
        case .motion: "Motion"
        case .scenery: "Scenery"
        case .people: "People"
        case .novelty: "Novelty"
        case .pacing: "Pacing"
        }
    }
}

public enum TasteFeedbackReason: String, Codable, CaseIterable, Identifiable, Sendable {
    case overall, moments, pacing

    public var id: Self { self }

    public var title: String {
        switch self {
        case .overall: "Overall"
        case .moments: "Moments"
        case .pacing: "Pacing"
        }
    }
}

public struct TastePreferences: Codable, Equatable, Sendable {
    public var motion: Double { didSet { motion = Self.sanitize(motion) } }
    public var scenery: Double { didSet { scenery = Self.sanitize(scenery) } }
    public var people: Double { didSet { people = Self.sanitize(people) } }
    public var novelty: Double { didSet { novelty = Self.sanitize(novelty) } }
    public var pacing: Double { didSet { pacing = Self.sanitize(pacing) } }

    public init(motion: Double = 0, scenery: Double = 0, people: Double = 0,
                novelty: Double = 0, pacing: Double = 0) {
        self.motion = Self.sanitize(motion)
        self.scenery = Self.sanitize(scenery)
        self.people = Self.sanitize(people)
        self.novelty = Self.sanitize(novelty)
        self.pacing = Self.sanitize(pacing)
    }

    private enum CodingKeys: String, CodingKey { case motion, scenery, people, novelty, pacing }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(motion: try container.decodeIfPresent(Double.self, forKey: .motion) ?? 0,
                  scenery: try container.decodeIfPresent(Double.self, forKey: .scenery) ?? 0,
                  people: try container.decodeIfPresent(Double.self, forKey: .people) ?? 0,
                  novelty: try container.decodeIfPresent(Double.self, forKey: .novelty) ?? 0,
                  pacing: try container.decodeIfPresent(Double.self, forKey: .pacing) ?? 0)
    }

    public subscript(_ dimension: TasteDimension) -> Double {
        get {
            switch dimension {
            case .motion: motion
            case .scenery: scenery
            case .people: people
            case .novelty: novelty
            case .pacing: pacing
            }
        }
        set {
            let value = Self.sanitize(newValue)
            switch dimension {
            case .motion: motion = value
            case .scenery: scenery = value
            case .people: people = value
            case .novelty: novelty = value
            case .pacing: pacing = value
            }
        }
    }

    fileprivate mutating func add(_ delta: TastePreferences) {
        for dimension in TasteDimension.allCases {
            self[dimension] = self[dimension] + delta[dimension]
        }
    }

    fileprivate var isNeutral: Bool {
        TasteDimension.allCases.allSatisfy { abs(self[$0]) <= TasteProfile.epsilon }
    }

    fileprivate static func sanitize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }

    fileprivate static func difference(_ lhs: TastePreferences, _ rhs: TastePreferences) -> TastePreferences {
        TastePreferences(motion: lhs.motion - rhs.motion,
                         scenery: lhs.scenery - rhs.scenery,
                         people: lhs.people - rhs.people,
                         novelty: lhs.novelty - rhs.novelty,
                         pacing: lhs.pacing - rhs.pacing)
    }

    fileprivate static func scaled(_ value: TastePreferences, by scale: Double) -> TastePreferences {
        TastePreferences(motion: value.motion * scale,
                         scenery: value.scenery * scale,
                         people: value.people * scale,
                         novelty: value.novelty * scale,
                         pacing: value.pacing * scale)
    }
}

public struct TasteProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    static let epsilon = 0.000001
    private static let maximumFeedbackEvents = 128
    private static let learningRate = 0.16

    public var schemaVersion: Int
    public var revision: Int
    public var isEnabled: Bool
    public var feedbackCount: Int

    private var preferencesByIntent: [EditIntent: TastePreferences]
    private var feedbackEvents: [FeedbackEvent]

    private struct FeedbackEvent: Codable, Equatable, Sendable {
        var key: String
        var preferredSignature: String
        var overSignature: String
        var intent: EditIntent
        var delta: TastePreferences
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, isEnabled, feedbackCount
        case preferencesByIntent, preferences
        case feedbackEvents
    }

    public init() {
        schemaVersion = Self.currentSchemaVersion
        revision = 0
        isEnabled = true
        feedbackCount = 0
        preferencesByIntent = [:]
        feedbackEvents = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = max(1, try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion)
        revision = max(0, try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        feedbackCount = max(0, try container.decodeIfPresent(Int.self, forKey: .feedbackCount) ?? 0)
        preferencesByIntent = try container.decodeIfPresent([EditIntent: TastePreferences].self,
                                                             forKey: .preferencesByIntent)
            ?? (try container.decodeIfPresent([EditIntent: TastePreferences].self, forKey: .preferences) ?? [:])
        feedbackEvents = Array((try container.decodeIfPresent([FeedbackEvent].self, forKey: .feedbackEvents) ?? []).suffix(Self.maximumFeedbackEvents))
        sanitizeStoredValues()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(max(0, revision), forKey: .revision)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(max(0, feedbackCount), forKey: .feedbackCount)
        try container.encode(preferencesByIntent, forKey: .preferencesByIntent)
        try container.encode(Array(feedbackEvents.suffix(Self.maximumFeedbackEvents)), forKey: .feedbackEvents)
    }

    public func preferences(for intent: EditIntent) -> TastePreferences {
        preferencesByIntent[intent] ?? TastePreferences()
    }

    public mutating func set(_ dimension: TasteDimension, value: Double, for intent: EditIntent) {
        var preferences = preferences(for: intent)
        let old = preferences[dimension]
        preferences[dimension] = value
        guard abs(old - preferences[dimension]) > Self.epsilon else { return }
        preferencesByIntent[intent] = preferences
        revision &+= 1
    }

    public mutating func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        revision &+= 1
    }

    /// Learns from two complete plans. The comparison uses only analysed moments
    /// and average shot duration, so it does not change source ranges or locks.
    @discardableResult
    public mutating func learn(preferred: MontagePlan, over: MontagePlan,
                               moments: [CandidateMoment], reason: TasteFeedbackReason) -> Bool {
        guard preferred.intent == over.intent,
              let preferredEvidence = evidence(for: preferred, moments: moments),
              let overEvidence = evidence(for: over, moments: moments),
              !preferredEvidence.signature.isEmpty,
              !overEvidence.signature.isEmpty,
              preferredEvidence.signature != overEvidence.signature else { return false }

        var delta = TastePreferences.difference(preferredEvidence.visual, overEvidence.visual)
        let pacingDifference = normalizedDurationDifference(preferredEvidence.averageDuration,
                                                             overEvidence.averageDuration)
        delta.pacing = pacingDifference
        switch reason {
        case .overall:
            break
        case .moments:
            delta.pacing = 0
        case .pacing:
            delta = TastePreferences(pacing: pacingDifference)
        }
        return record(delta: delta, preferredSignature: preferredEvidence.signature,
                      overSignature: overEvidence.signature, intent: preferred.intent,
                      reason: reason)
    }

    /// Learns from a direct moment comparison for one edit intent.
    @discardableResult
    public mutating func learn(preferred: CandidateMoment, over: CandidateMoment,
                               intent: EditIntent) -> Bool {
        guard preferred.id != over.id,
              validMoment(preferred), validMoment(over) else { return false }
        let preferredVisual = visualPreferences(for: preferred)
        let overVisual = visualPreferences(for: over)
        var delta = TastePreferences.difference(preferredVisual, overVisual)
        // Candidate duration is an available source window, not an editing choice.
        // A replacement fits the same timeline slot, so it teaches visual taste only.
        delta.pacing = 0
        return record(delta: delta, preferredSignature: compactSignature(preferred.id.uuidString),
                      overSignature: compactSignature(over.id.uuidString), intent: intent, reason: .overall)
    }

    public mutating func reset() {
        guard revision != 0 || feedbackCount != 0 || !preferencesByIntent.isEmpty
                || !feedbackEvents.isEmpty || !isEnabled else { return }
        schemaVersion = Self.currentSchemaVersion
        revision = 0
        isEnabled = true
        feedbackCount = 0
        preferencesByIntent.removeAll(keepingCapacity: true)
        feedbackEvents.removeAll(keepingCapacity: true)
    }

    /// Returns a bounded ranking adjustment without changing the planner's quality floor.
    public func scoreAdjustment(for moment: CandidateMoment, intent: EditIntent) -> Double {
        guard isEnabled, validMoment(moment), MomentScorer.qualityScore(moment) >= 0.18 else { return 0 }
        let preferences = preferences(for: intent)
        let f = moment.features
        let signals: [TasteDimension: Double] = [
            .motion: centered(f.motion),
            .scenery: centered(f.scenery),
            .people: centered(max(f.people, f.faces)),
            .novelty: centered(f.novelty)
        ]
        let value = TasteDimension.allCases.reduce(0) { $0 + preferences[$1] * (signals[$1] ?? 0) * 0.024 }
        return min(0.12, max(-0.12, value))
    }

    public func durationMultiplier(for intent: EditIntent) -> Double {
        guard isEnabled else { return 1 }
        return min(1.15, max(0.85, 1 - 0.15 * preferences(for: intent)[.pacing]))
    }

    private mutating func record(delta: TastePreferences, preferredSignature: String,
                        overSignature: String, intent: EditIntent,
                        reason: TasteFeedbackReason) -> Bool {
        guard !delta.isNeutral else { return false }
        let boundedDelta = TastePreferences.scaled(delta, by: Self.learningRate)
        let key = pairKey(preferredSignature, overSignature, intent: intent, reason: reason)
        if let index = feedbackEvents.firstIndex(where: { $0.key == key }) {
            let previous = feedbackEvents[index]
            if previous.preferredSignature == preferredSignature,
               previous.overSignature == overSignature { return false }
            // A reversed vote replaces the prior vote. This keeps one pair from
            // accumulating contradictory evidence over repeated edits.
            apply(previous.delta, for: intent, sign: -1)
            feedbackEvents.remove(at: index)
        }
        let before = preferences(for: intent)
        apply(boundedDelta, for: intent, sign: 1)
        let appliedDelta = TastePreferences.difference(preferences(for: intent), before)
        feedbackEvents.append(FeedbackEvent(key: key, preferredSignature: preferredSignature,
                                             overSignature: overSignature, intent: intent, delta: appliedDelta))
        if feedbackEvents.count > Self.maximumFeedbackEvents {
            feedbackEvents.removeFirst(feedbackEvents.count - Self.maximumFeedbackEvents)
        }
        feedbackCount &+= 1
        revision &+= 1
        return true
    }

    private mutating func apply(_ delta: TastePreferences, for intent: EditIntent, sign: Double) {
        var preferences = preferences(for: intent)
        preferences.add(TastePreferences.scaled(delta, by: sign))
        preferencesByIntent[intent] = preferences
    }

    private func pairKey(_ preferred: String, _ over: String, intent: EditIntent,
                         reason: TasteFeedbackReason) -> String {
        let pair = [preferred, over].sorted().joined(separator: "|")
        return "\(intent.rawValue)|\(reason.rawValue)|\(pair)"
    }

    private struct PlanEvidence {
        var signature: String
        var visual: TastePreferences
        var averageDuration: Double
    }

    private func evidence(for plan: MontagePlan, moments: [CandidateMoment]) -> PlanEvidence? {
        guard !plan.segments.isEmpty, Set(moments.map(\.id)).count == moments.count else { return nil }
        let lookup = Dictionary(uniqueKeysWithValues: moments.map { ($0.id, $0) })
        let selected = plan.segments.compactMap { segment -> (CandidateMoment, Double)? in
            guard let moment = lookup[segment.momentID], validMoment(moment),
                  segment.sourceAssetID == moment.sourceAssetID,
                  segment.sourceStartTime.isFinite,
                  segment.sourceStartTime >= moment.sourceStartTime - 1.0 / 600,
                  segment.sourceStartTime + segment.duration <= moment.sourceEndTime + 1.0 / 600,
                  segment.duration.isFinite, segment.duration >= 0.15 else { return nil }
            return (moment, segment.duration)
        }
        guard selected.count == plan.segments.count else { return nil }
        let count = Double(selected.count)
        let visual = selected.map { visualPreferences(for: $0.0) }.reduce(TastePreferences()) { partial, value in
            TastePreferences(motion: partial.motion + value.motion / count,
                             scenery: partial.scenery + value.scenery / count,
                             people: partial.people + value.people / count,
                             novelty: partial.novelty + value.novelty / count)
        }
        let average = selected.reduce(0) { $0 + $1.1 } / count
        let rawSignature = plan.segments.map { "\($0.momentID.uuidString):\($0.sourceStartTime):\($0.duration)" }.joined(separator: ",")
        return PlanEvidence(signature: compactSignature(rawSignature), visual: visual, averageDuration: average)
    }

    private func visualPreferences(for moment: CandidateMoment) -> TastePreferences {
        TastePreferences(motion: normalizedFeature(moment.features.motion),
                         scenery: normalizedFeature(moment.features.scenery),
                         people: normalizedFeature(max(moment.features.people, moment.features.faces)),
                         novelty: normalizedFeature(moment.features.novelty))
    }

    private func validMoment(_ moment: CandidateMoment) -> Bool {
        moment.sourceStartTime.isFinite && moment.sourceEndTime.isFinite
            && moment.duration.isFinite && moment.duration >= 0.15
            && moment.features.motion.isFinite
            && moment.features.scenery.isFinite
            && moment.features.people.isFinite
            && moment.features.faces.isFinite
            && moment.features.novelty.isFinite
    }

    private func normalizedFeature(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    private func centered(_ value: Double) -> Double { normalizedFeature(value) * 2 - 1 }

    private func normalizedDurationDifference(_ preferred: Double, _ over: Double) -> Double {
        guard preferred.isFinite, over.isFinite else { return 0 }
        return min(1, max(-1, (over - preferred) / max(1, max(preferred, over))))
    }

    private func compactSignature(_ value: String) -> String {
        var first: UInt64 = 1469598103934665603
        var second: UInt64 = 1099511628211
        for byte in value.utf8 {
            first ^= UInt64(byte)
            first &*= 1099511628211
            second ^= UInt64(byte)
            second &*= 14029467366897019727
        }
        return "\(first)-\(second)"
    }

    private mutating func sanitizeStoredValues() {
        schemaVersion = Self.currentSchemaVersion
        revision = max(0, revision)
        feedbackCount = max(0, feedbackCount)
        for intent in EditIntent.allCases {
            if var preferences = preferencesByIntent[intent] {
                for dimension in TasteDimension.allCases { preferences[dimension] = preferences[dimension] }
                if preferences.isNeutral { preferencesByIntent.removeValue(forKey: intent) }
                else { preferencesByIntent[intent] = preferences }
            }
        }
        feedbackEvents = Array(feedbackEvents.suffix(Self.maximumFeedbackEvents))
    }
}
