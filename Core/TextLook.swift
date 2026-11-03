import Foundation

/// How one style shows its title: the type, where it sits, and how it moves.
/// Each style's look lives in its recipe in `Recipes/recipes.json`.
public struct TextLook: Codable, Equatable, Sendable {
    /// Bump when the timing or drawing of text changes, so cached previews refresh.
    public static let version = 1

    public enum Design: String, Codable, Sendable { case sans, serif, rounded, mono }
    public enum Weight: String, Codable, Sendable { case light, regular, medium, semibold, bold, heavy, black }
    public enum Placement: String, Codable, Sendable, CaseIterable { case upper, center, lower }
    public enum Entrance: String, Codable, Sendable { case fade, rise, pop, typewriter }
    public enum Exit: String, Codable, Sendable { case fade, cut }

    /// A short name people see next to the title switch.
    public var name: String
    public var design: Design
    public var weight: Weight
    public var uppercase: Bool
    /// Extra space between letters, as a share of the font size.
    public var tracking: Double
    /// Title size as a share of the frame's width. Subtitles are smaller.
    public var size: Double
    public var placement: Placement
    public var entrance: Entrance
    public var exit: Exit
    /// Seconds the title aims to stay fully on screen.
    public var hold: Double

    public init(name: String, design: Design, weight: Weight, uppercase: Bool, tracking: Double, size: Double,
                placement: Placement, entrance: Entrance, exit: Exit, hold: Double) {
        self.name = name; self.design = design; self.weight = weight; self.uppercase = uppercase
        self.tracking = tracking; self.size = size; self.placement = placement
        self.entrance = entrance; self.exit = exit; self.hold = hold
    }

    /// Used only if a recipe has no text look.
    public static let plain = TextLook(name: "Simple", design: .sans, weight: .semibold, uppercase: false,
                                       tracking: 0, size: 0.08, placement: .lower, entrance: .fade, exit: .fade, hold: 2.5)

    public static func style(for intent: EditIntent) -> TextLook {
        StyleRecipe.recipe(for: intent).text ?? .plain
    }
}

/// The words on the edit, and whether they show.
public struct TextSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    /// Nil uses the project's name. Empty shows no title.
    public var title: String?
    /// Nil uses the trip's dates. Empty shows no subtitle.
    public var subtitle: String?

    public init(isEnabled: Bool = true, title: String? = nil, subtitle: String? = nil) {
        self.isEnabled = isEnabled; self.title = title; self.subtitle = subtitle
    }

    /// The months a trip covers, such as "June 2026" or "May – June 2026".
    public static func dateLine(for dates: [Date], locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String? {
        guard let first = dates.min(), let last = dates.max() else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func format(_ date: Date, year: Bool) -> String {
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
                .month(.wide)
            if year { style = style.year() }
            return date.formatted(style)
        }
        let start = calendar.dateComponents([.year, .month], from: first)
        let end = calendar.dateComponents([.year, .month], from: last)
        if start == end { return format(first, year: true) }
        if start.year == end.year { return format(first, year: false) + " – " + format(last, year: true) }
        return format(first, year: true) + " – " + format(last, year: true)
    }
}

/// One line of text and when it shows, in seconds from the start of the edit.
public struct TextCue: Equatable, Sendable {
    public enum Role: String, Sendable { case title, subtitle }
    public var role: Role
    public var text: String
    public var start: Double
    public var end: Double
    /// Seconds the entrance and the exit take.
    public var entrance: Double
    public var exit: Double
}

/// Decides when the title shows, so it lands on the music and leaves on a cut.
public enum TextPlanner {
    /// Edits shorter than this get no title; it would cover most of the edit.
    static let shortestEdit = 4.0
    /// The title stays at least this long, so it can be read.
    static let readable = 2.0
    /// How far the entrance and exit may move to reach a bar or a cut.
    static let reach = 0.6

    public static func cues(title: String, subtitle: String?, look: TextLook, plan: MontagePlan,
                            music: MusicAnalysis?) -> [TextCue] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, plan.duration >= shortestEdit else { return [] }
        let events = (music?.events ?? []).map { (kind: $0.kind, time: $0.time - plan.musicStartTime) }
            .filter { $0.time > 0 && $0.time < plan.duration }
        func first(_ kinds: Set<MusicEventKind>, in range: ClosedRange<Double>) -> Double? {
            events.filter { kinds.contains($0.kind) && range.contains($0.time) }.map(\.time).min()
        }
        // Enter on the first bar start, or the first strong beat, near the opening.
        let opening = 0.25...1.5
        let start = first([.downbeat], in: opening) ?? first([.strongBeat, .beat], in: opening) ?? 0.4
        let entrance = entranceDuration(look.entrance, characters: title.count)
        let exit = look.exit == .fade ? 0.4 : 0

        // Leave on the nearest cut, or the nearest bar start, after the hold.
        let target = start + entrance + look.hold
        var cuts: [Double] = []
        var elapsed = 0.0
        for segment in plan.segments.dropLast() { elapsed += segment.duration; cuts.append(elapsed) }
        let bars = events.filter { $0.kind == .downbeat }.map(\.time)
        func nearest(_ times: [Double]) -> Double? {
            times.filter { abs($0 - target) <= reach }.min { abs($0 - target) < abs($1 - target) }
        }
        let latest = plan.duration - 0.3
        let shortest = start + entrance + readable
        var end = (look.exit == .cut ? nearest(cuts) ?? nearest(bars) : nearest(bars) ?? nearest(cuts)) ?? target
        end = min(latest, max(shortest, end))
        guard end > start + entrance else { return [] }

        var cues = [TextCue(role: .title, text: title, start: start, end: end, entrance: entrance, exit: exit)]
        if let subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            // The subtitle follows once the title is mostly in.
            let delay = look.entrance == .typewriter ? entrance : min(0.3, entrance * 0.6)
            let subtitleEntrance = min(entranceDuration(look.entrance, characters: subtitle.count), 0.6)
            if end - (start + delay) > subtitleEntrance + 1 {
                cues.append(TextCue(role: .subtitle, text: subtitle, start: start + delay, end: end,
                                    entrance: subtitleEntrance, exit: exit))
            }
        }
        return cues
    }

    static func entranceDuration(_ entrance: TextLook.Entrance, characters: Int) -> Double {
        switch entrance {
        case .fade: 0.6
        case .rise: 0.35
        // Six frames at 30 fps.
        case .pop: 0.2
        case .typewriter: min(1.2, max(0.3, Double(characters) * 0.05))
        }
    }

    /// Where the title block sits, as a span of the frame's height from the top.
    public static func span(of placement: TextLook.Placement) -> ClosedRange<Double> {
        switch placement {
        // Platform buttons and captions cover the top and bottom edges.
        case .upper: 0.14...0.36
        case .center: 0.40...0.60
        case .lower: 0.62...0.82
        }
    }

    /// Keeps the style's placement unless it would cover a subject, then
    /// moves to the free area that covers the least. `subjects` are vertical
    /// spans of the frame, from the top, for every shot under the title.
    public static func placement(_ preferred: TextLook.Placement,
                                 avoiding subjects: [ClosedRange<Double>]) -> TextLook.Placement {
        func overlap(_ placement: TextLook.Placement) -> Double {
            let zone = span(of: placement)
            return subjects.reduce(0) { total, subject in
                total + max(0, min(zone.upperBound, subject.upperBound) - max(zone.lowerBound, subject.lowerBound))
            }
        }
        let order: [TextLook.Placement] = switch preferred {
        case .upper: [.upper, .lower, .center]
        case .center: [.center, .lower, .upper]
        case .lower: [.lower, .upper, .center]
        }
        if let free = order.first(where: { overlap($0) == 0 }) { return free }
        return order.min { overlap($0) < overlap($1) } ?? preferred
    }
}
