import Foundation
import Testing
@testable import MontageCore

private func plan(_ durations: [Double], musicStart: Double = 0) -> MontagePlan {
    MontagePlan(name: "Edit", summary: "", intent: .story, seed: 1, musicStartTime: musicStart,
                segments: durations.map { MontageSegment(momentID: UUID(), sourceAssetID: UUID(), sourceStartTime: 0, duration: $0) })
}

/// Beats every half second, with a bar start every two seconds from `firstBar`.
private func song(firstBar: Double = 0.75) -> MusicAnalysis {
    let events = stride(from: 0.25, through: 60, by: 0.5).map { time in
        let isBar = time >= firstBar && (time - firstBar).truncatingRemainder(dividingBy: 2) == 0
        return MusicEvent(time: time, kind: isBar ? .downbeat : .strongBeat, strength: 0.6)
    }
    return MusicAnalysis(duration: 60, bpm: 120, confidence: 1, events: events, sections: [], energy: [])
}

private func look(entrance: TextLook.Entrance = .pop, exit: TextLook.Exit = .cut, hold: Double = 2) -> TextLook {
    TextLook(name: "Test", design: .sans, weight: .bold, uppercase: false, tracking: 0, size: 0.1,
             placement: .center, entrance: entrance, exit: exit, hold: hold)
}

@Test func everyStyleHasItsOwnTextLook() {
    let looks = EditIntent.allCases.map { StyleRecipe.recipe(for: $0).text }
    #expect(looks.allSatisfy { $0 != nil })
    #expect(Set(looks.compactMap { $0?.name }).count == EditIntent.allCases.count)
    #expect(looks.compactMap { $0 }.allSatisfy { $0.size > 0.03 && $0.size < 0.15 && $0.hold >= 1.5 })
}

@Test func theTitleLandsOnTheFirstBar() throws {
    let cues = TextPlanner.cues(title: "Lisbon", subtitle: nil, look: look(), plan: plan([3, 3, 3, 3]), music: song())
    #expect(try #require(cues.first).start == 0.75)
}

@Test func theTitleUsesTheSongsPlaceNotTheEdits() throws {
    // The edit starts 10 seconds into the song, so the first bar in the edit is at 0.75.
    let cues = TextPlanner.cues(title: "Lisbon", subtitle: nil, look: look(), plan: plan([3, 3, 3, 3], musicStart: 10),
                                music: song(firstBar: 0.75))
    #expect(try #require(cues.first).start == 0.75)
}

@Test func aCutStyleLeavesOnTheNearestCut() throws {
    // Enters at 0.75 and pops in over 0.2 seconds, so it aims to leave at 2.95.
    let cues = TextPlanner.cues(title: "Lisbon", subtitle: nil, look: look(), plan: plan([3.2, 3, 3]), music: song())
    #expect(try #require(cues.first).end == 3.2)
}

@Test func aFadeStyleLeavesOnTheNearestBar() throws {
    // Enters at 0.75 and fades in over 0.6 seconds, so it aims to leave at 4.35.
    let cues = TextPlanner.cues(title: "Lisbon", subtitle: nil, look: look(entrance: .fade, exit: .fade, hold: 3),
                                plan: plan([3.2, 3, 3]), music: song())
    let title = try #require(cues.first)
    #expect(title.end == 4.75)
    #expect(title.exit > 0)
}

@Test func theTitleStaysLongEnoughToRead() throws {
    let cues = TextPlanner.cues(title: "Lisbon", subtitle: nil, look: look(hold: 0.2), plan: plan([3, 3, 3]), music: nil)
    let title = try #require(cues.first)
    #expect(title.end - title.start - title.entrance >= TextPlanner.readable)
}

@Test func shortEditsAndEmptyTitlesShowNothing() {
    #expect(TextPlanner.cues(title: "Lisbon", subtitle: nil, look: look(), plan: plan([1.5, 1.5]), music: song()).isEmpty)
    #expect(TextPlanner.cues(title: "  ", subtitle: "June", look: look(), plan: plan([3, 3, 3]), music: song()).isEmpty)
}

@Test func theSubtitleFollowsTheTitle() throws {
    let cues = TextPlanner.cues(title: "Lisbon", subtitle: "June 2026", look: look(entrance: .typewriter),
                                plan: plan([3, 3, 3]), music: song())
    #expect(cues.map(\.role) == [.title, .subtitle])
    let title = cues[0], subtitle = cues[1]
    // A typed title finishes before the subtitle starts.
    #expect(subtitle.start == title.start + title.entrance)
    #expect(subtitle.end == title.end)
}

@Test func textMovesAwayFromASubject() {
    #expect(TextPlanner.placement(.center, avoiding: []) == .center)
    #expect(TextPlanner.placement(.center, avoiding: [0.3...0.55]) == .lower)
    #expect(TextPlanner.placement(.lower, avoiding: [0.5...0.9]) == .upper)
    // Nowhere is free, so it takes the place it covers least.
    #expect(TextPlanner.placement(.upper, avoiding: [0.1...0.9, 0.55...0.65]) == .upper)
    #expect(TextPlanner.placement(.lower, avoiding: [0.1...0.9, 0.6...0.8]) == .center)
}

@Test func datesReadAsMonths() throws {
    let locale = Locale(identifier: "en_US"), zone = try #require(TimeZone(identifier: "UTC"))
    func date(_ text: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: text + "T12:00:00Z")) }
    #expect(TextSettings.dateLine(for: [], locale: locale, timeZone: zone) == nil)
    #expect(TextSettings.dateLine(for: [try date("2026-06-03"), try date("2026-06-20")], locale: locale, timeZone: zone) == "June 2026")
    #expect(TextSettings.dateLine(for: [try date("2026-06-20"), try date("2026-05-28")], locale: locale, timeZone: zone) == "May – June 2026")
    #expect(TextSettings.dateLine(for: [try date("2025-12-30"), try date("2026-01-02")], locale: locale, timeZone: zone) == "December 2025 – January 2026")
}

@Test func newProjectsHaveTitlesAndOldOnesDoNot() throws {
    var project = MontageProject(name: "A little escape")
    #expect(project.titleText == "A little escape")
    project.text.title = ""
    #expect(project.titleText == nil)

    var saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(MontageProject(name: "Old"))) as? [String: Any])
    saved.removeValue(forKey: "textSettings")
    let old = try JSONDecoder().decode(MontageProject.self, from: JSONSerialization.data(withJSONObject: saved))
    #expect(old.titleText == nil)
}
