import Foundation
import Testing
@testable import MontageCore

@Test(arguments: [100, 1_500, 1_488, 3_000, 4_321])
func everyFrameIsScoredByTheFirstChunkThatCoversIt(frames: Int) throws {
    let spectrogram = (0..<frames).flatMap { frame in [Float](repeating: Float(frame), count: BarTracker.bands) }
    var calls = 0
    let logits = BarTracker.logits(spectrogram: spectrogram, frames: frames) { chunk in
        calls += 1
        // Each output is the frame number it was given, and the chunk number.
        let frame = (0..<BarTracker.chunkFrames).map { chunk[$0 * BarTracker.bands] }
        return (frame, [Float](repeating: Float(calls), count: BarTracker.chunkFrames))
    }
    #expect(logits.beat.count == frames)
    // Zero padding reads as frame 0, so only real frames are checked by value.
    #expect(logits.beat.enumerated().dropFirst().allSatisfy { Int($0.element) == $0.offset })
    #expect(logits.downbeat.allSatisfy { $0 > 0 })
    // Chunks run last to first, so the first chunk's scores win where they overlap.
    #expect(Int(logits.downbeat[0]) == calls)
}

@Test func peaksMergeNeighborsAndBarsSitOnBeats() {
    var beat = [Float](repeating: -5, count: 200)
    var downbeat = beat
    for frame in [10, 35, 60, 85, 110] { beat[frame] = 3 }
    beat[136] = 2; beat[137] = 2
    downbeat[12] = 1; downbeat[110] = 4
    let peaks = BarTracker.peaks(beat: beat, downbeat: downbeat)
    #expect(peaks.beats == [0.2, 0.7, 1.2, 1.7, 2.2, 2.73])
    #expect(peaks.downbeats == [0.2, 2.2])
}

@Test func melFiltersCoverTheModelsRange() {
    let filters = BarTracker.melFilters()
    let bins = 513, bands = BarTracker.bands
    #expect(filters.count == bins * bands)
    // 30 Hz to 11 kHz: the lowest and top bins carry no weight.
    #expect((0..<bands).allSatisfy { filters[$0] == 0 && filters[(bins - 1) * bands + $0] == 0 })
    // Every band has some weight, and triangles peak at no more than 1.
    #expect((0..<bands).allSatisfy { band in (0..<bins).contains { filters[$0 * bands + band] > 0 } })
    #expect(filters.allSatisfy { $0 >= 0 && $0 <= 1 })
}

@Test func tooLittleAudioGivesNoBars() throws {
    let tracker = try #require(BarTracker())
    tracker.process([Float](repeating: 0.1, count: 300))
    #expect(tracker.barStarts() == nil)
}
