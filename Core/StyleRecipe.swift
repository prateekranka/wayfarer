import Foundation

/// The editing rules for one style, loaded from `Recipes/recipes.json`.
///
/// Rules are soft. They change sequence scores, but they never make an edit
/// impossible, so small trips and locked moments still produce a plan.
public struct StyleRecipe: Codable, Equatable, Sendable {
    /// Shortest and longest shot, in seconds.
    public var shortestShot: Double
    public var longestShot: Double
    /// Beats per shot in the loud and quiet parts of the song.
    public var beatsWhenLoud: Double
    public var beatsWhenQuiet: Double
    public var mostMomentsPerClip: Int
    /// How far a cut may move, in seconds, to land on a musical event.
    public var cutTolerance: Double
    public var opening: Opening
    public var ending: Ending
    /// Which zooms this style may use, and how strong they are, from 0 to 1.
    public var zooms: [ZoomKind]
    public var zoomIntensity: Double
    /// Whether shots get shorter as a build rises toward its payoff.
    public var acceleratesIntoBuilds: Bool
    /// How the style shows its title. Optional so a recipe without one still loads.
    public var text: TextLook?

    public enum Opening: String, Codable, Sendable { case wide, people, strongest }
    public enum Ending: String, Codable, Sendable { case peopleOrSunset, calm }

    public init(shortestShot: Double, longestShot: Double, beatsWhenLoud: Double,
                beatsWhenQuiet: Double, mostMomentsPerClip: Int, cutTolerance: Double,
                opening: Opening, ending: Ending, zooms: [ZoomKind] = [], zoomIntensity: Double = 0,
                acceleratesIntoBuilds: Bool = false, text: TextLook? = nil) {
        self.shortestShot = shortestShot; self.longestShot = longestShot
        self.beatsWhenLoud = beatsWhenLoud; self.beatsWhenQuiet = beatsWhenQuiet
        self.mostMomentsPerClip = mostMomentsPerClip; self.cutTolerance = cutTolerance
        self.opening = opening; self.ending = ending
        self.zooms = zooms; self.zoomIntensity = zoomIntensity
        self.acceleratesIntoBuilds = acceleratesIntoBuilds
        self.text = text
    }

    private static let recipes: [String: StyleRecipe] = {
        guard let url = Bundle.module.url(forResource: "recipes", withExtension: "json", subdirectory: "Recipes"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: StyleRecipe].self, from: data) else { return [:] }
        return decoded
    }()

    /// A recipe with no opinion, used only if the bundled file cannot be read.
    static let open = StyleRecipe(shortestShot: 0.15, longestShot: .infinity, beatsWhenLoud: 0,
                                  beatsWhenQuiet: 0, mostMomentsPerClip: .max, cutTolerance: 0.12,
                                  opening: .strongest, ending: .calm)

    public static func recipe(for intent: EditIntent) -> StyleRecipe {
        recipes[intent.rawValue] ?? open
    }
}

/// Turns a recipe into scores for one edit, using its place in the song.
struct RecipePacing: Sendable {
    /// Penalty per full shot length outside the shortest or longest limit.
    private static let limitWeight = 0.90
    /// Largest penalty for missing the beat-based target.
    private static let paceWeight = 0.12
    private static let clipWeight = 0.35
    private static let openingWeight = 0.50
    private static let endingWeight = 0.30
    private static let repeatedFacesWeight = 0.20
    private static let repeatedStillWeight = 0.08
    private static let repeatedScaleWeight = 0.06
    private static let reversedMotionWeight = 0.12
    /// Slower or more mixed movement than this has no clear direction.
    private static let clearSpeed = 0.1
    private static let clearAgreement = 0.6
    private static let buildWeight = 0.30
    /// A subject covering this much of the frame reads as a close shot.
    private static let closeSubjectArea = 0.60

    let recipe: StyleRecipe
    private let beatLength: Double?
    private let energy: [EnergySample]
    private let builds: [MusicBuild]
    private let meanEnergy: Double
    private let musicStart: Double
    /// When the song's biggest moment arrives, in edit time.
    private let peakTime: Double?
    /// Motion below this counts as a still shot. It is relative to the trip,
    /// because handheld clips and tripod clips have very different ranges.
    private let stillMotion: Double

    init(recipe: StyleRecipe, music: MusicAnalysis, musicStart: Double,
         targetDuration: Double = .infinity, moments: [CandidateMoment] = []) {
        self.recipe = recipe
        self.musicStart = musicStart
        let motions = moments.map(\.features.motion).sorted()
        self.stillMotion = motions.isEmpty ? 0 : motions[motions.count / 2]
        self.peakTime = Self.peakTime(in: music, musicStart: musicStart, duration: targetDuration)
        self.beatLength = music.bpm.flatMap { $0.isFinite && $0 > 0 ? 60 / $0 : nil }
        self.energy = music.energy.sorted { $0.time < $1.time }
        self.builds = music.builds ?? []
        self.meanEnergy = energy.isEmpty ? 0 : energy.reduce(0) { $0 + $1.value } / Double(energy.count)
    }

    /// When the song's biggest moment arrives in the edit, if it falls inside it.
    static func peakTime(in music: MusicAnalysis, musicStart: Double, duration: Double) -> Double? {
        let inEdit = { (time: Double) in time >= musicStart && time <= musicStart + duration }
        let peak = music.events.filter { $0.kind == .drop && inEdit($0.time) }.max { $0.strength < $1.strength }?.time
            ?? music.events.filter { $0.kind == .build && inEdit($0.time) }.max { $0.strength < $1.strength }?.time
            ?? music.energy.filter { inEdit($0.time) }.max { $0.value < $1.value }?.time
        return peak.map { $0 - musicStart }
    }

    /// The song's energy nearest a time. Samples can span a very long song.
    private func energy(at time: Double) -> Double? {
        guard !energy.isEmpty else { return nil }
        var low = 0, high = energy.count - 1
        while low < high {
            let middle = (low + high) / 2
            if energy[middle].time < time { low = middle + 1 } else { high = middle }
        }
        return energy[low].value
    }

    /// The shot length the recipe wants at this point in the edit, or nil
    /// when the song has no usable tempo or energy.
    func targetDuration(at elapsed: Double) -> Double? {
        guard let beatLength, let level = energy(at: musicStart + elapsed) else { return nil }
        let beats = level >= meanEnergy ? recipe.beatsWhenLoud : recipe.beatsWhenQuiet
        guard beats > 0 else { return nil }
        let wanted = beats * buildPace(at: musicStart + elapsed) * beatLength
        return min(recipe.longestShot, max(recipe.shortestShot, wanted))
    }

    /// Shots halve as a build nears its top, like the spec's accelerating cuts.
    private func buildPace(at time: Double) -> Double {
        guard recipe.acceleratesIntoBuilds, recipe.beatsWhenLoud > 0,
              let build = builds.first(where: { time >= $0.start && time < $0.end }) else { return 1 }
        let progress = (time - build.start) / (build.end - build.start)
        // Measured from the loud pace, so a quiet start still speeds up.
        let loudShare = recipe.beatsWhenLoud / max(recipe.beatsWhenQuiet, recipe.beatsWhenLoud)
        let level = energy(at: time) ?? 0
        let base = level >= meanEnergy ? 1 : loudShare
        return base * (progress < 0.5 ? 1 : progress < 0.8 ? 0.5 : 0.25)
    }

    /// A score change for placing a shot. Zero or below.
    func score(duration: Double, elapsed: Double, momentsFromClip: Int) -> Double {
        var value = 0.0
        if duration < recipe.shortestShot {
            value -= Self.limitWeight * (recipe.shortestShot - duration) / recipe.shortestShot
        } else if duration > recipe.longestShot {
            value -= Self.limitWeight * (duration - recipe.longestShot) / recipe.longestShot
        }
        if let target = targetDuration(at: elapsed) {
            value -= Self.paceWeight * min(1, abs(duration - target) / target)
        }
        if momentsFromClip >= recipe.mostMomentsPerClip { value -= Self.clipWeight }
        return value
    }

    enum Scale { case wide, medium, close }

    /// A rough shot size from Vision's subject and scene results. A smaller
    /// subject in a scenic frame is wide. A large subject or a face is close.
    func scale(of moment: CandidateMoment) -> Scale {
        let area = moment.subject.map { $0.width * $0.height } ?? 0
        if area >= Self.closeSubjectArea || moment.features.faces > 0 { return .close }
        return moment.features.scenery >= 0.5 ? .wide : .medium
    }

    private func isWarmEnding(_ moment: CandidateMoment) -> Bool {
        moment.semanticTags.contains("sunset") || moment.features.people > 0
    }

    /// Rewards a shot for suiting the opening, the ending, or the song's peak.
    func placementScore(_ moment: CandidateMoment, isFirst: Bool, isLast: Bool,
                        elapsed: Double, duration: Double) -> Double {
        let f = moment.features
        var value = 0.0
        if isFirst {
            switch recipe.opening {
            case .wide: value += scale(of: moment) == .wide ? Self.openingWeight : 0
            case .people: value += f.people > 0 ? Self.openingWeight : 0
            case .strongest: value += Self.openingWeight * MomentScorer.qualityScore(moment)
            }
        }
        if isLast {
            switch recipe.ending {
            case .peopleOrSunset: value += isWarmEnding(moment) ? Self.endingWeight : 0
            case .calm: value += Self.endingWeight * f.stability * (scale(of: moment) == .close ? 0.5 : 1)
            }
        }
        if let peakTime, elapsed <= peakTime, peakTime < elapsed + duration {
            value += Self.buildWeight * MomentScorer.qualityScore(moment)
        }
        return value
    }

    /// Penalizes two neighboring shots that feel the same. Zero or below.
    func varietyScore(_ moment: CandidateMoment, after previous: CandidateMoment) -> Double {
        var value = 0.0
        if moment.features.faces > 0, previous.features.faces > 0 { value -= Self.repeatedFacesWeight }
        if moment.features.motion < stillMotion, previous.features.motion < stillMotion {
            value -= Self.repeatedStillWeight
        }
        if scale(of: moment) == scale(of: previous) { value -= Self.repeatedScaleWeight }
        if movesAgainst(previous, moment) { value -= Self.reversedMotionWeight }
        return value
    }

    /// True when both shots move clearly and one heads back against the other,
    /// which reads as a jolt at the cut.
    func movesAgainst(_ first: CandidateMoment, _ second: CandidateMoment) -> Bool {
        guard let a = first.signals, let b = second.signals,
              let speedA = a.speed, let speedB = b.speed, let turnA = a.direction, let turnB = b.direction,
              let agreeA = a.agreement, let agreeB = b.agreement,
              speedA >= Self.clearSpeed, speedB >= Self.clearSpeed,
              agreeA >= Self.clearAgreement, agreeB >= Self.clearAgreement else { return false }
        return cos(turnA - turnB) < -0.5
    }
}
