import Foundation

public enum EditIntent: String, Codable, CaseIterable, Identifiable, Sendable {
    case beatSync, story, cinematic, highlights, people, places
    public var id: Self { self }
    public var title: String {
        switch self {
        case .beatSync: "Beat Sync"
        case .story: "Story"
        case .cinematic: "Cinematic"
        case .highlights: "Highlights"
        case .people: "People"
        case .places: "Places"
        }
    }
    public var subtitle: String {
        switch self {
        case .beatSync: "Let the rhythm lead."
        case .story: "Relive the journey."
        case .cinematic: "Give beautiful moments room."
        case .highlights: "All the unforgettable parts."
        case .people: "The people who made the trip."
        case .places: "A sense of somewhere."
        }
    }
    public var symbol: String {
        switch self {
        case .beatSync: "waveform"
        case .story: "book.closed"
        case .cinematic: "film"
        case .highlights: "sparkles"
        case .people: "person.2"
        case .places: "mountain.2"
        }
    }
}

public struct CreativeParameters: Codable, Equatable, Sendable {
    public var highlights: Double = 0.5
    public var energy: Double = 0.5
    public var fastCuts: Double = 0.5
    public init(highlights: Double = 0.5, energy: Double = 0.5, fastCuts: Double = 0.5) {
        self.highlights = highlights; self.energy = energy; self.fastCuts = fastCuts
    }
}

public enum OutputRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case vertical = "9:16", square = "1:1", portrait = "4:5", landscape = "16:9"
    public var id: Self { self }
    public var width: Int { self == .landscape ? 1920 : 1080 }
    public var height: Int {
        switch self { case .vertical: 1920; case .square: 1080; case .portrait: 1350; case .landscape: 1080 }
    }
}

public struct SourceAsset: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var fileName: String
    public var photoIdentifier: String?
    public var duration: Double
    public var width: Double
    public var height: Double
    public var timestamp: Date?
    public var fingerprint: String
    public var thumbnailFileName: String?
    public init(id: UUID = UUID(), fileName: String, photoIdentifier: String? = nil, duration: Double,
                width: Double, height: Double, timestamp: Date? = nil, fingerprint: String,
                thumbnailFileName: String? = nil) {
        self.id = id; self.fileName = fileName; self.photoIdentifier = photoIdentifier; self.duration = duration
        self.width = width; self.height = height; self.timestamp = timestamp; self.fingerprint = fingerprint
        self.thumbnailFileName = thumbnailFileName
    }
}

public struct MomentFeatures: Codable, Sendable, Equatable {
    public var quality: Double = 0.5
    public var interest: Double = 0.5
    public var motion: Double = 0
    public var stability: Double = 0.5
    public var faces: Double = 0
    public var people: Double = 0
    public var scenery: Double = 0
    public var food: Double = 0
    public var novelty: Double = 0.5
    public var composition: Double = 0.5
    public var exposure: Double = 0.5
    public var blur: Double = 0
    public init() {}
}

public struct SubjectAnchor: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double = 0.2, height: Double = 0.2) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct CandidateMoment: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var sourceAssetID: UUID
    public var sourceStartTime: Double
    public var sourceEndTime: Double
    public var duration: Double { sourceEndTime - sourceStartTime }
    public var features: MomentFeatures
    public var semanticTags: [String]
    public var timestamp: Date?
    public var confidence: Double
    public var featureVector: [Float]
    public var clusterID: Int
    public var subject: SubjectAnchor?
    public var thumbnailFileName: String?
    public var userPreference: Int = 0
    public var peakTime: Double?
    public var importOrder: Int?
    public init(id: UUID = UUID(), sourceAssetID: UUID, sourceStartTime: Double, sourceEndTime: Double,
                features: MomentFeatures, semanticTags: [String] = [], timestamp: Date? = nil,
                confidence: Double = 0.5, featureVector: [Float] = [], clusterID: Int = -1,
                subject: SubjectAnchor? = nil, thumbnailFileName: String? = nil, peakTime: Double? = nil) {
        self.id = id; self.sourceAssetID = sourceAssetID; self.sourceStartTime = sourceStartTime
        self.sourceEndTime = sourceEndTime; self.features = features; self.semanticTags = semanticTags
        self.timestamp = timestamp; self.confidence = confidence; self.featureVector = featureVector
        self.clusterID = clusterID; self.subject = subject; self.thumbnailFileName = thumbnailFileName
        self.peakTime = peakTime
    }
    public func preferredStart(for duration: Double) -> Double {
        let center = peakTime ?? (sourceStartTime + sourceEndTime) / 2
        return max(sourceStartTime, min(sourceEndTime - duration, center - duration / 2))
    }
}

public enum MusicEventKind: String, Codable, Sendable { case beat, strongBeat, onset, build, transition }
public struct MusicEvent: Codable, Sendable, Equatable {
    public var time: Double
    public var kind: MusicEventKind
    public var strength: Double
    public init(time: Double, kind: MusicEventKind, strength: Double) {
        self.time = time; self.kind = kind; self.strength = strength
    }
}
public struct MusicSection: Codable, Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var energy: Double
    public init(start: Double, end: Double, energy: Double) { self.start = start; self.end = end; self.energy = energy }
}
public struct EnergySample: Codable, Sendable, Equatable {
    public var time: Double
    public var value: Double
    public init(time: Double, value: Double) { self.time = time; self.value = value }
}
public struct MusicAnalysis: Codable, Sendable, Equatable {
    public var duration: Double
    public var bpm: Double?
    public var confidence: Double
    public var events: [MusicEvent]
    public var sections: [MusicSection]
    public var energy: [EnergySample]
    public init(duration: Double, bpm: Double? = nil, confidence: Double = 0,
                events: [MusicEvent] = [], sections: [MusicSection] = [], energy: [EnergySample] = []) {
        self.duration = duration; self.bpm = bpm; self.confidence = confidence
        self.events = events; self.sections = sections; self.energy = energy
    }
}
public struct MusicSource: Codable, Sendable, Equatable {
    public var fileName: String
    public var title: String
    public var analysis: MusicAnalysis
    public init(fileName: String, title: String, analysis: MusicAnalysis) {
        self.fileName = fileName; self.title = title; self.analysis = analysis
    }
}
public struct TimedLyric: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var semanticTags: [String]
    public init(start: Double, end: Double, text: String, semanticTags: [String] = []) {
        self.start = start; self.end = end; self.text = text; self.semanticTags = semanticTags
    }
}

public struct MontageSegment: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var momentID: UUID
    public var sourceAssetID: UUID
    public var sourceStartTime: Double
    public var duration: Double
    public var isLocked: Bool
    public var preferredTimelineStart: Double?
    public var reasons: [String]
    public var alternativeIDs: [UUID]
    public var subject: SubjectAnchor?
    public init(id: UUID = UUID(), momentID: UUID, sourceAssetID: UUID, sourceStartTime: Double,
                duration: Double, isLocked: Bool = false, preferredTimelineStart: Double? = nil, reasons: [String] = [],
                alternativeIDs: [UUID] = [], subject: SubjectAnchor? = nil) {
        self.id = id; self.momentID = momentID; self.sourceAssetID = sourceAssetID
        self.sourceStartTime = sourceStartTime; self.duration = duration; self.isLocked = isLocked
        self.preferredTimelineStart = preferredTimelineStart
        self.reasons = reasons; self.alternativeIDs = alternativeIDs; self.subject = subject
    }
}
public struct MontageMetrics: Codable, Sendable, Equatable {
    public var usedSources: Int = 0
    public var averageDuration: Double = 0
    public var beatAlignment: Double = 0
    public var chronologicalConsistency: Double = 0
    public var semanticDiversity: Int = 0
    public var meanQuality: Double = 0
    public var meanMotion: Double = 0
    public init() {}
}
public struct MontagePlan: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var summary: String
    public var intent: EditIntent
    public var seed: UInt64
    public var musicStartTime: Double
    public var segments: [MontageSegment]
    public var metrics: MontageMetrics
    /// The exact taste state used when this plan was generated.
    /// A nil value preserves plans created before local taste learning existed.
    public var tasteProfile: TasteProfile?
    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
    public init(id: UUID = UUID(), name: String, summary: String, intent: EditIntent, seed: UInt64,
                musicStartTime: Double, segments: [MontageSegment], metrics: MontageMetrics = MontageMetrics(),
                tasteProfile: TasteProfile? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.intent = intent; self.seed = seed
        self.musicStartTime = musicStartTime; self.segments = segments; self.metrics = metrics
        self.tasteProfile = tasteProfile
    }
}
public struct PlanningRequest: Sendable {
    public var moments: [CandidateMoment]
    public var music: MusicAnalysis
    public var targetDuration: Double
    public var intent: EditIntent
    public var parameters: CreativeParameters
    public var lockedSegments: [MontageSegment]
    public var rejectedSourceIDs: Set<UUID>
    public var rejectedMomentIDs: Set<UUID>
    public var priorPlans: [MontagePlan]
    public var seed: UInt64
    public var tasteProfile: TasteProfile?
    public init(moments: [CandidateMoment], music: MusicAnalysis, targetDuration: Double,
                intent: EditIntent, parameters: CreativeParameters = CreativeParameters(),
                lockedSegments: [MontageSegment] = [], rejectedSourceIDs: Set<UUID> = [],
                rejectedMomentIDs: Set<UUID> = [], priorPlans: [MontagePlan] = [], seed: UInt64 = 1,
                tasteProfile: TasteProfile? = nil) {
        self.moments = moments; self.music = music; self.targetDuration = targetDuration
        self.intent = intent; self.parameters = parameters; self.lockedSegments = lockedSegments
        self.rejectedSourceIDs = rejectedSourceIDs; self.rejectedMomentIDs = rejectedMomentIDs
        self.priorPlans = priorPlans; self.seed = seed; self.tasteProfile = tasteProfile
    }
}
public enum MontageError: LocalizedError, Sendable {
    case invalidMedia(String), insufficientFootage, shortMusic, invalidPlan(String), insufficientDiversity
    public var errorDescription: String? {
        switch self {
        case .invalidMedia(let message), .invalidPlan(let message): message
        case .insufficientFootage: "There isn’t enough usable footage for this length. Add more clips or choose a shorter montage."
        case .shortMusic: "This song is shorter than your montage. Choose a longer song or a shorter montage."
        case .insufficientDiversity: "There aren’t enough different moments for three edits. Add more clips or choose a shorter montage."
        }
    }
}

public enum ProjectStage: String, Codable, Sendable { case importing, analyzing, setup, ready, exported }
public struct PlanningSettings: Codable, Sendable, Equatable {
    public var duration: Double
    public var intent: EditIntent
    public var parameters: CreativeParameters
    public var musicFile: String?
    public var sourceIDs: [UUID]
    public var rejectedSourceIDs: Set<UUID> = []
    public var rejectedMomentIDs: Set<UUID> = []
}
public struct MontageProject: Codable, Identifiable, Sendable, Equatable {
    public var schemaVersion = 1
    public var analysisVersion = 2
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var assets: [SourceAsset] = []
    public var moments: [CandidateMoment] = []
    public var analyzedAssetIDs: Set<UUID> = []
    public var music: MusicSource?
    public var targetDuration: Double = 30
    public var intent: EditIntent = .beatSync
    public var parameters = CreativeParameters()
    public var outputRatio: OutputRatio = .vertical
    public var originalSound: Double = 0
    public var plans: [MontagePlan] = []
    public var plannedSettings: PlanningSettings?
    public var selectedPlanID: UUID?
    public var rejectedSourceIDs: Set<UUID> = []
    public var rejectedMomentIDs: Set<UUID> = []
    public var seed: UInt64 = 1
    public var stage: ProjectStage = .importing
    public var exportFileName: String?
    public var warnings: [String] = []
    /// Optional so projects saved before this setting existed still decode.
    public var lookSettings: LookSettings?
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
    public var look: LookSettings {
        get { lookSettings ?? LookSettings() }
        set { lookSettings = newValue }
    }
    public var planningSettings: PlanningSettings {
        PlanningSettings(duration: targetDuration, intent: intent, parameters: parameters,
                         musicFile: music?.fileName, sourceIDs: assets.map(\.id),
                         rejectedSourceIDs: rejectedSourceIDs, rejectedMomentIDs: rejectedMomentIDs)
    }
    public var needsGeneration: Bool {
        !plans.isEmpty && plannedSettings.map { $0 != planningSettings } == true
    }
}

public protocol VideoAnalyzing: Sendable {
    func analyze(asset: SourceAsset, directory: URL) async throws -> [CandidateMoment]
}
public protocol MusicAnalyzing: Sendable {
    func analyze(url: URL) async throws -> MusicAnalysis
}
public protocol MontagePlanning: Sendable {
    func generate(_ request: PlanningRequest) throws -> [MontagePlan]
}

public enum PlanValidator {
    public static func validate(_ plan: MontagePlan, target: Double, assets: [SourceAsset],
                                musicDuration: Double, rejectedSources: Set<UUID> = [], rejectedMoments: Set<UUID> = []) throws {
        guard target.isFinite, target > 0, !plan.segments.isEmpty,
              abs(plan.duration - target) <= 1.0 / 600 else {
            throw MontageError.invalidPlan("The edit does not fit the requested length.")
        }
        guard plan.musicStartTime >= 0, plan.musicStartTime + target <= musicDuration + 1.0 / 600 else {
            throw MontageError.shortMusic
        }
        guard Set(assets.map(\.id)).count == assets.count else {
            throw MontageError.invalidPlan("The project contains conflicting source references.")
        }
        let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for segment in plan.segments {
            guard let asset = lookup[segment.sourceAssetID], !rejectedSources.contains(asset.id),
                  !rejectedMoments.contains(segment.momentID),
                  segment.duration.isFinite, segment.duration >= 0.15,
                  segment.sourceStartTime.isFinite, segment.sourceStartTime >= 0,
                  segment.sourceStartTime + segment.duration <= asset.duration + 1.0 / 600 else {
                throw MontageError.invalidPlan("A selected moment is unavailable or outside its source clip.")
            }
        }
        for index in plan.segments.indices {
            let left = plan.segments[index]
            for right in plan.segments.dropFirst(index + 1) where left.sourceAssetID == right.sourceAssetID {
                if min(left.sourceStartTime + left.duration, right.sourceStartTime + right.duration)
                    - max(left.sourceStartTime, right.sourceStartTime) > 1.0 / 600 {
                    throw MontageError.invalidPlan("Two moments use the same part of a source clip. Choose another moment.")
                }
            }
        }
    }
}
