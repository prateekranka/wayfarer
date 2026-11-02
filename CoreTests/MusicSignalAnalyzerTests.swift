import Foundation
import Testing
@testable import MontageCore

// Songs built from known events, so each result can be scored against the truth.
private let rate = MusicSignalAnalyzer.sampleRate

private struct Song {
    var samples: [Float]
    init(seconds: Double) { samples = [Float](repeating: 0, count: Int(seconds * rate)) }
    var seconds: Double { Double(samples.count) / rate }

    mutating func kick(at time: Double, level: Float = 0.8) {
        let start = Int(time * rate), length = Int(0.12 * rate)
        for index in 0..<length where start + index < samples.count {
            let t = Double(index) / rate
            samples[start + index] += level * Float(exp(-t * 35) * sin(2 * .pi * 70 * t))
        }
    }
    mutating func hat(at time: Double, level: Float = 0.25) {
        var generator = SeededNoise(seed: UInt64(time * 10_000) + 1)
        let start = Int(time * rate), length = Int(0.04 * rate)
        var previous: Float = 0
        for index in 0..<length where start + index < samples.count {
            let noise = generator.next()
            samples[start + index] += level * Float(exp(-Double(index) / rate * 120)) * (noise - previous)
            previous = noise
        }
    }
    mutating func tone(from start: Double, to end: Double, hertz: [Double], level: (Double) -> Double) {
        for index in Int(start * rate)..<min(samples.count, Int(end * rate)) {
            let t = Double(index) / rate
            let value = hertz.reduce(0.0) { $0 + sin(2 * .pi * $1 * t) } / Double(hertz.count)
            samples[index] += Float(value * level(t))
        }
    }
    mutating func noise(from start: Double, to end: Double, level: (Double) -> Double) {
        var generator = SeededNoise(seed: 7)
        for index in Int(start * rate)..<min(samples.count, Int(end * rate)) {
            samples[index] += generator.next() * Float(level(Double(index) / rate))
        }
    }
    func analyzed() throws -> MusicAnalysis {
        let analyzer = try #require(MusicSignalAnalyzer())
        var offset = 0
        // Uneven chunks, as a real audio file delivers them.
        while offset < samples.count {
            let end = min(samples.count, offset + 8_192 + offset % 1_000)
            analyzer.process(Array(samples[offset..<end]))
            offset = end
        }
        return analyzer.finish(duration: seconds)
    }
}

private struct SeededNoise {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(state % 20_001) / 10_000 - 1
    }
}

private func times(_ music: MusicAnalysis, _ kinds: Set<MusicEventKind>) -> [Double] {
    music.events.filter { kinds.contains($0.kind) }.map(\.time)
}
private let allBeats: Set<MusicEventKind> = [.beat, .strongBeat, .downbeat]

/// The share of `truth` with a detected time close by.
private func recall(_ truth: [Double], in found: [Double], within tolerance: Double = 0.05) -> Double {
    let matched = truth.filter { time in found.contains { abs($0 - time) <= tolerance } }.count
    return Double(matched) / Double(max(1, truth.count))
}

/// Kick on beats 1 and 3, a snare-like hit on 2 and 4, hats between, and a bass
/// note that changes every bar.
private func groove(bpm: Double, bars: Int) -> (song: Song, beats: [Double], downbeats: [Double]) {
    let beatLength = 60 / bpm
    var song = Song(seconds: Double(bars * 4) * beatLength + 1)
    var beats: [Double] = [], downbeats: [Double] = []
    let notes: [[Double]] = [[110, 220, 277], [98, 196, 247], [131, 262, 330], [87, 175, 220]]
    for bar in 0..<bars {
        let start = 0.5 + Double(bar * 4) * beatLength
        downbeats.append(start)
        song.tone(from: start, to: start + 4 * beatLength, hertz: notes[bar % 4]) { _ in 0.18 }
        for beat in 0..<4 {
            let time = start + Double(beat) * beatLength
            beats.append(time)
            if beat % 2 == 0 { song.kick(at: time, level: beat == 0 ? 1 : 0.7) } else { song.hat(at: time, level: 0.6) }
            song.hat(at: time + beatLength / 2)
        }
    }
    return (song, beats, downbeats)
}

@Test(arguments: [(90.0, 16), (120.0, 16), (128.0, 18), (174.0, 22)])
func steadyTemposAreFound(bpm: Double, bars: Int) throws {
    let track = groove(bpm: bpm, bars: bars)
    let music = try track.song.analyzed()
    let found = try #require(music.bpm)
    #expect(abs(found - bpm) / bpm < 0.03 || abs(found - bpm / 2) / bpm < 0.03, "Found \(found) for \(bpm)")
    if abs(found - bpm) / bpm < 0.03 {
        #expect(recall(track.beats, in: times(music, allBeats)) >= 0.9)
    }
}

@Test func beatsFollowASongThatSpeedsUp() throws {
    var song = Song(seconds: 40)
    var truth: [Double] = []
    var time = 0.5, bpm = 100.0
    while time < 39 {
        truth.append(time)
        song.kick(at: time)
        song.hat(at: time + 30 / bpm)
        time += 60 / bpm
        bpm = min(135, bpm + 0.6)
    }
    #expect(recall(truth, in: times(try song.analyzed(), allBeats), within: 0.07) >= 0.85)
}

@Test func barsAreFoundFromBassAndChordChanges() throws {
    let track = groove(bpm: 120, bars: 16)
    let music = try track.song.analyzed()
    #expect(music.beatsPerBar == 4)
    #expect(recall(track.downbeats, in: times(music, [.downbeat])) >= 0.85)
}

@Test func aSteadyHitWithNoBarsDoesNotInventDownbeats() throws {
    var song = Song(seconds: 20)
    for index in 0..<36 { song.kick(at: 0.5 + Double(index) * 0.5) }
    #expect(times(try song.analyzed(), [.downbeat]).isEmpty)
}

@Test func bassAndHighsAreToldApart() throws {
    var song = Song(seconds: 12)
    for index in 0..<10 {
        song.kick(at: 1 + Double(index))
        song.hat(at: 1.5 + Double(index), level: 0.7)
    }
    let events = try song.analyzed().events.filter { $0.band != nil }
    let onKicks = events.filter { abs(($0.time - 1).truncatingRemainder(dividingBy: 1)) < 0.05 }
    let onHats = events.filter { abs(($0.time - 1.5).truncatingRemainder(dividingBy: 1)) < 0.05 }
    #expect(!onKicks.isEmpty && !onHats.isEmpty)
    #expect(Double(onKicks.filter { $0.band == .low }.count) / Double(onKicks.count) >= 0.8)
    #expect(Double(onHats.filter { $0.band == .high }.count) / Double(onHats.count) >= 0.8)
}

@Test func aSlowCrescendoIsFound() throws {
    var song = Song(seconds: 30)
    song.tone(from: 0, to: 30, hertz: [220, 330, 440]) { time in
        time < 10 ? 0.05 : time < 20 ? 0.05 + 0.45 * (time - 10) / 10 : 0.5
    }
    let builds = try #require(try song.analyzed().builds)
    #expect(builds.count == 1)
    let build = try #require(builds.first)
    #expect(abs(build.start - 10) < 2.5)
    #expect(abs(build.end - 20) < 2.5)
}

@Test func aDropAndThePauseBeforeItAreFound() throws {
    var song = Song(seconds: 30)
    song.noise(from: 0, to: 14.75) { _ in 0.03 }
    for index in 0..<28 { song.kick(at: 1 + Double(index) * 0.5, level: 0.15) }
    song.noise(from: 15, to: 30) { _ in 0.25 }
    for index in 0..<30 { song.kick(at: 15 + Double(index) * 0.5, level: 1) }
    let music = try song.analyzed()
    let drops = times(music, [.drop])
    #expect(drops.count == 1)
    #expect(abs((drops.first ?? 0) - 15) < 0.2)
    #expect(times(music, [.silence]).contains { abs($0 - 14.75) < 0.15 })
}

@Test func aSteadySongHasNoBuildsDropsOrPauses() throws {
    let music = try groove(bpm: 120, bars: 20).song.analyzed()
    #expect(music.builds?.isEmpty == true)
    #expect(times(music, [.drop, .silence]).isEmpty)
}

@Test func sectionsSplitWhereTheSoundChanges() throws {
    var track = groove(bpm: 120, bars: 24)
    track.song.noise(from: track.downbeats[12], to: track.song.seconds) { _ in 0.08 }
    let music = try track.song.analyzed()
    #expect(music.sections.count >= 2)
    #expect(music.sections.dropFirst().contains { abs($0.start - track.downbeats[12]) < 2.1 })
}

@Test func silenceAndVeryShortAudioAreSafe() throws {
    let empty = try Song(seconds: 0.01).analyzed()
    #expect(empty.bpm == nil)
    let quiet = try Song(seconds: 10).analyzed()
    #expect(quiet.events.isEmpty)
}

@Test func oldSavedSongsStillDecode() throws {
    let saved = try JSONEncoder().encode(MusicAnalysis(duration: 30))
    var object = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    object.removeValue(forKey: "builds"); object.removeValue(forKey: "beatsPerBar")
    let music = try JSONDecoder().decode(MusicAnalysis.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(music.builds == nil)
}

@Test func aRisingVerseIsNotADrop() throws {
    var song = Song(seconds: 60)
    // Small level changes every few seconds, as verses and choruses make.
    for index in 0..<12 {
        let start = Double(index) * 5
        song.tone(from: start, to: start + 5, hertz: [110, 220, 330]) { _ in index.isMultiple(of: 2) ? 0.2 : 0.32 }
    }
    for index in 0..<110 { song.kick(at: 1 + Double(index) * 0.5, level: 0.5) }
    #expect(times(try song.analyzed(), [.drop]).isEmpty)
}

@Test func onlyASongsBiggestJumpsCountAsDrops() throws {
    var song = Song(seconds: 180)
    for index in 0..<12 {
        let start = Double(index) * 15
        let loud = index.isMultiple(of: 2)
        song.noise(from: start, to: start + 15) { _ in loud ? 0.02 : 0.25 }
        for hit in 0..<30 { song.kick(at: start + Double(hit) * 0.5, level: loud ? 0.1 : 1) }
    }
    let drops = times(try song.analyzed(), [.drop])
    #expect(!drops.isEmpty)
    #expect(drops.count <= 4)
}

@Test func aFadeInIsNotABuild() throws {
    var song = Song(seconds: 20)
    song.tone(from: 0, to: 20, hertz: [220, 440]) { time in min(0.4, 0.4 * time * time / 64) }
    // Only the part with real sound can count, not the rise out of silence.
    #expect(try song.analyzed().builds?.allSatisfy { $0.rise <= 26 } == true)
}

@Test func barsSurviveASkippedBeat() throws {
    var track = groove(bpm: 120, bars: 12)
    let second = groove(bpm: 120, bars: 12)
    // A half-second gap moves every later bar by one beat.
    let gap = [Float](repeating: 0, count: Int(0.5 * rate))
    let joined = Array(track.song.samples.dropLast(Int(0.5 * rate))) + gap + second.song.samples
    track.song.samples = joined
    let offset = track.song.seconds - second.song.seconds
    let truth = track.downbeats + second.downbeats.map { $0 + offset }
    #expect(recall(truth, in: times(try track.song.analyzed(), [.downbeat]), within: 0.08) >= 0.8)
}
