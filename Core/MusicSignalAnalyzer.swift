import Accelerate
import Foundation

/// Turns mono audio samples into a structured song timeline.
///
/// Samples arrive in chunks, so a long song is never held in memory. Each short
/// frame is split into bass, mids, and highs. Sudden changes in those bands find
/// hits. Beats come from a search across the song that follows tempo changes.
/// Bars, builds, drops, pauses, and sections are then read from those results.
/// This is signal analysis, not a trained model, so results are estimates.
public final class MusicSignalAnalyzer {
    public static let sampleRate = 22_050.0
    private static let fftSize = 1_024
    private static let hop = 256
    private static let frameTime = Double(hop) / sampleRate
    /// FFT bin edges for bass (under 150 Hz), mids, and highs (over 2 kHz).
    private static let lowBins = 1..<8
    private static let midBins = 8..<93
    private static let highBins = 93..<512
    private static let chromaStep = 4

    private let setup: FFTSetup
    private let log2Size = vDSP_Length(10)
    private var window: [Float]
    private var pitchClass: [Int]
    private var pending: [Float] = []
    private var previousSpectrum: [Float]

    private var lowFlux: [Float] = []
    private var midFlux: [Float] = []
    private var highFlux: [Float] = []
    private var lowPower: [Float] = []
    private var midPower: [Float] = []
    private var highPower: [Float] = []
    private var chroma: [Float] = []
    private var frameCount = 0

    public init?() {
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.fftSize, isHalfWindow: false)
        previousSpectrum = [Float](repeating: 0, count: Self.fftSize / 2)
        pitchClass = (0..<(Self.fftSize / 2)).map { bin in
            guard bin > 0 else { return -1 }
            let frequency = Double(bin) * Self.sampleRate / Double(Self.fftSize)
            guard frequency >= 80, frequency <= 2_000 else { return -1 }
            return Int((12 * log2(frequency / 440)).rounded() + 1_200) % 12
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Adds mono samples at `sampleRate`.
    public func process(_ samples: [Float]) {
        pending.append(contentsOf: samples.map { $0.isFinite ? $0 : 0 })
        var offset = 0
        while pending.count - offset >= Self.fftSize {
            analyzeFrame(at: offset)
            offset += Self.hop
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    private func analyzeFrame(at offset: Int) {
        let n = Self.fftSize
        var windowed = [Float](repeating: 0, count: n)
        pending.withUnsafeBufferPointer { buffer in
            vDSP_vmul(buffer.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(n))
        }
        var real = [Float](repeating: 0, count: n / 2)
        var imaginary = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                // The real FFT packs the top bin into the first imaginary value.
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        let scale = 1 / Float(n * n)
        var spectrum = [Float](repeating: 0, count: n / 2)
        var band: [Float] = [0, 0, 0]
        var flux: [Float] = [0, 0, 0]
        var pitch = [Float](repeating: 0, count: 12)
        let takesChroma = frameCount % Self.chromaStep == 0
        for bin in 1..<(n / 2) {
            let value = power[bin] * scale
            // Log compression, so quiet hats count as well as loud kicks.
            let compressed = log1pf(1_000 * sqrtf(value))
            spectrum[bin] = compressed
            let rise = max(0, compressed - previousSpectrum[bin])
            let index = bin < Self.midBins.lowerBound ? 0 : bin < Self.highBins.lowerBound ? 1 : 2
            band[index] += value
            flux[index] += rise
            if takesChroma, pitchClass[bin] >= 0 { pitch[pitchClass[bin]] += compressed }
        }
        previousSpectrum = spectrum
        lowFlux.append(flux[0] / Float(Self.lowBins.count))
        midFlux.append(flux[1] / Float(Self.midBins.count))
        highFlux.append(flux[2] / Float(Self.highBins.count))
        lowPower.append(band[0]); midPower.append(band[1]); highPower.append(band[2])
        if takesChroma { chroma.append(contentsOf: pitch) }
        frameCount += 1
    }

    private func time(_ frame: Int) -> Double {
        (Double(frame) + 0.5) * Self.frameTime + Double(Self.fftSize - Self.hop) / 2 / Self.sampleRate
    }

    private func frame(at time: Double) -> Int {
        max(0, min(frameCount - 1, Int(((time - Double(Self.fftSize - Self.hop) / 2 / Self.sampleRate) / Self.frameTime).rounded())))
    }

    /// Finishes the song and returns its timeline.
    public func finish(duration: Double) -> MusicAnalysis {
        guard frameCount > 8 else { return MusicAnalysis(duration: duration, energy: [EnergySample(time: 0, value: 0)]) }
        let loudness = zip(zip(lowPower, midPower), highPower).map { pair, high in
            10 * log10f(pair.0 + pair.1 + high + 1e-10)
        }
        let reference = percentile(loudness, 0.95)
        let energy = energyCurve()
        let envelope = onsetEnvelope()
        let hits = detectHits(envelope)
        let tempo = estimateTempo(envelope)
        let beats = tempo.map { trackBeats(envelope, periods: $0.periods) } ?? []
        let bpm = medianBPM(beats)
        let meter = findDownbeats(beats)
        let silences = detectSilences(loudness, reference: reference)
        let builds = detectBuilds(loudness)
        let drops = detectDrops(loudness, reference: reference, hits: hits)
        let sections = detectSections(beats: beats, meter: meter, energy: energy, duration: duration)

        var events: [MusicEvent] = []
        let beatFrames = Set(beats.flatMap { [$0 - 3, $0 - 2, $0 - 1, $0, $0 + 1, $0 + 2, $0 + 3] })
        for (index, beat) in beats.enumerated() {
            let strength = Double(max(envelope[beat], 0.2))
            let isDownbeat = meter.map { index % $0.beatsPerBar == $0.phase } ?? false
            let kind: MusicEventKind = isDownbeat ? .downbeat : strength >= 0.55 ? .strongBeat : .beat
            events.append(MusicEvent(time: time(beat), kind: kind, strength: min(1, strength), band: strongestBand(at: beat)))
        }
        for hit in hits where !beatFrames.contains(hit) {
            events.append(MusicEvent(time: time(hit), kind: .onset, strength: Double(envelope[hit]), band: strongestBand(at: hit)))
        }
        events += builds.map { MusicEvent(time: $0.end, kind: .build, strength: min(1, $0.rise / 15)) }
        events += drops.map { MusicEvent(time: $0.time, kind: .drop, strength: $0.strength) }
        events += silences.map { MusicEvent(time: $0.time, kind: .silence, strength: $0.strength) }
        for section in sections.dropFirst() {
            events.append(MusicEvent(time: section.start, kind: .transition, strength: 0.7))
        }
        let spread = beats.count > 8 ? beatSteadiness(beats) : 0
        let confidence = min(1, 0.6 * (tempo?.confidence ?? 0) + 0.4 * spread)
        var result = MusicAnalysis(duration: duration, bpm: bpm, confidence: confidence,
                                   events: events.sorted { $0.time < $1.time }, sections: sections, energy: energy)
        result.beatsPerBar = meter?.beatsPerBar
        result.builds = builds
        return result
    }

    // MARK: Shared helpers

    private func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    private func movingAverage(_ values: [Float], radius: Int) -> [Float] {
        var totals = [Float](repeating: 0, count: values.count + 1)
        for index in values.indices { totals[index + 1] = totals[index] + values[index] }
        return values.indices.map { index in
            let low = max(0, index - radius), high = min(values.count, index + radius + 1)
            return (totals[high] - totals[low]) / Float(high - low)
        }
    }

    /// Loudness for the planner, about every 46 ms and scaled to the song's peak.
    private func energyCurve() -> [EnergySample] {
        let step = 4
        var samples: [EnergySample] = []
        var index = 0
        while index < frameCount {
            let end = min(frameCount, index + step)
            var total: Float = 0
            for frame in index..<end { total += lowPower[frame] + midPower[frame] + highPower[frame] }
            samples.append(EnergySample(time: time(index), value: Double(sqrtf(total / Float(end - index)))))
            index = end
        }
        let peak = samples.map(\.value).max() ?? 0
        return peak > 0 ? samples.map { EnergySample(time: $0.time, value: $0.value / peak) } : samples
    }

    /// Hit strength per frame, from 0 to 1, with slow changes removed.
    private func onsetEnvelope() -> [Float] {
        let raw = (0..<frameCount).map { lowFlux[$0] + midFlux[$0] + highFlux[$0] }
        let background = movingAverage(raw, radius: 17)
        let cleaned = zip(raw, background).map { max(0, $0 - $1) }
        let top = max(0.0001, percentile(cleaned, 0.99))
        return cleaned.map { min(1, $0 / top) }
    }

    private func detectHits(_ envelope: [Float]) -> [Int] {
        let local = movingAverage(envelope, radius: 43)
        var hits: [Int] = []
        let gap = Int(0.08 / Self.frameTime)
        for index in 3..<max(3, envelope.count - 3) {
            let value = envelope[index]
            guard value >= 0.2, value > local[index] * 1.5,
                  value >= envelope[(index - 3)...(index + 3)].max() ?? 0 else { continue }
            if let last = hits.last, index - last < gap { continue }
            hits.append(index)
        }
        return hits
    }

    private func strongestBand(at frame: Int) -> MusicBand {
        let low = max(0, frame - 1), high = min(frameCount - 1, frame + 1)
        // Bass bins are few and hit hard, so highs need less to count.
        let bass = lowFlux[low...high].reduce(0, +) * 0.5
        let mids = midFlux[low...high].reduce(0, +)
        let highs = highFlux[low...high].reduce(0, +)
        if bass >= mids && bass >= highs { return .low }
        return highs >= mids ? .high : .mid
    }

    // MARK: Tempo and beats

    /// Beats per minute between 40 and 220 are searched. Periods are in frames.
    private func tempoScores(_ values: UnsafeBufferPointer<Float>, lags: ClosedRange<Int>) -> [Float] {
        lags.map { lag in
            guard values.count > lag else { return 0 }
            var score: Float = 0
            vDSP_dotpr(values.baseAddress!, 1, values.baseAddress! + lag, 1, &score, vDSP_Length(values.count - lag))
            return score / Float(values.count - lag)
        }
    }

    /// Finds the beat period through the song, every two seconds.
    private func estimateTempo(_ envelope: [Float]) -> (periods: [Int], confidence: Double)? {
        let lags = Int(60 / 220 / Self.frameTime)...Int(60 / 40 / Self.frameTime)
        guard envelope.count > lags.upperBound * 2 else { return nil }
        // Most songs feel near 120 BPM, which settles half and double tempo.
        let prior: [Float] = lags.map { lag in
            let bpm = 60 / (Double(lag) * Self.frameTime)
            let octaves = log2(bpm / 120)
            return Float(exp(-octaves * octaves / (2 * 0.9 * 0.9)))
        }
        let overall = envelope.withUnsafeBufferPointer { tempoScores($0, lags: lags) }
        guard let bestOverall = zip(overall, prior).map({ $0 * $1 }).enumerated().max(by: { $0.element < $1.element }),
              bestOverall.element > 0 else { return nil }
        var zeroLag: Float = 0
        vDSP_dotpr(envelope, 1, envelope, 1, &zeroLag, vDSP_Length(envelope.count))
        zeroLag /= Float(envelope.count)
        let confidence = Double(min(1, overall[bestOverall.offset] / max(0.0001, zeroLag) * 1.5))

        let span = Int(8 / Self.frameTime), step = Int(2 / Self.frameTime)
        var current = lags.lowerBound + bestOverall.offset
        var blocks: [Int] = []
        var start = 0
        while start < envelope.count {
            let end = min(envelope.count, start + span)
            if end - start > lags.upperBound * 2 {
                let scores = envelope[start..<end].withUnsafeBufferPointer { tempoScores($0, lags: lags) }
                // Tempo moves smoothly, so stay close to the last estimate.
                let previous = Double(current)
                let weighted = scores.enumerated().map { index, score -> Float in
                    let change = log2(Double(lags.lowerBound + index) / previous)
                    return score * Float(exp(-change * change / (2 * 0.12 * 0.12)))
                }
                if let best = weighted.enumerated().max(by: { $0.element < $1.element }), best.element > 0 {
                    current = lags.lowerBound + best.offset
                }
            }
            blocks.append(current)
            start += step
        }
        let periods = (0..<envelope.count).map { blocks[min(blocks.count - 1, $0 / step)] }
        return (periods, confidence)
    }

    /// Searches for the path of beats that lands on the strongest hits while
    /// keeping an even pace. It allows drift, so tempo changes are followed.
    private func trackBeats(_ envelope: [Float], periods: [Int]) -> [Int] {
        let count = envelope.count
        let mean = envelope.reduce(0, +) / Float(count)
        let deviation = sqrtf(envelope.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(count))
        guard deviation > 0 else { return [] }
        let strength = envelope.map { $0 / deviation }
        var best = strength
        var backlink = [Int](repeating: -1, count: count)
        let tightness: Float = 60
        for index in 0..<count {
            let period = periods[index]
            let low = max(0, index - period * 2), high = index - period / 2
            guard high >= low, high >= 0 else { continue }
            var bestScore = -Float.infinity, bestFrame = -1
            for previous in low...high {
                let ratio = logf(Float(index - previous) / Float(period))
                let score = best[previous] - tightness * ratio * ratio
                if score > bestScore { bestScore = score; bestFrame = previous }
            }
            if bestScore > 0 { best[index] = strength[index] + bestScore; backlink[index] = bestFrame }
        }
        let tailStart = max(0, count - (periods.last ?? 1) * 2)
        guard var frame = (tailStart..<count).max(by: { best[$0] < best[$1] }) else { return [] }
        var beats: [Int] = []
        while frame >= 0 { beats.append(frame); frame = backlink[frame] }
        return beats.reversed().filter { envelope[$0] > 0.02 }
    }

    private func medianBPM(_ beats: [Int]) -> Double? {
        guard beats.count > 3 else { return nil }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        return 60 / (Double(gaps[gaps.count / 2]) * Self.frameTime)
    }

    private func beatSteadiness(_ beats: [Int]) -> Double {
        let gaps = zip(beats.dropFirst(), beats).map { Double($0 - $1) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        let variance = gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)
        return max(0, 1 - sqrt(variance) / max(1, mean))
    }

    // MARK: Bars

    /// Bars usually start with a bass hit and a chord change. Tries 4 and 3 beats
    /// per bar. Returns nil when no position stands out, rather than guessing.
    private func findDownbeats(_ beats: [Int]) -> (beatsPerBar: Int, phase: Int)? {
        guard beats.count >= 12 else { return nil }
        var scores = [Float](repeating: 0, count: beats.count)
        let lowLevels = beats.map { beat in
            let end = min(frameCount, beat + 6)
            return log10f(lowPower[beat..<end].reduce(0, +) + 1e-8)
        }
        for index in 1..<(beats.count - 1) {
            let before = meanChroma(from: beats[index - 1], to: beats[index])
            let after = meanChroma(from: beats[index], to: beats[index + 1])
            var distance: Float = 0
            for pitch in 0..<12 { distance += abs(after[pitch] - before[pitch]) }
            scores[index] = distance
        }
        // The floor stops differences too small to hear from looking like a pattern.
        func standardized(_ values: [Float], floor: Float) -> [Float] {
            let mean = values.reduce(0, +) / Float(values.count)
            let deviation = max(floor, sqrtf(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)))
            return values.map { ($0 - mean) / deviation }
        }
        // The first and last beats have no neighbor, so give them the average.
        let typical = scores[1..<(scores.count - 1)].reduce(0, +) / Float(scores.count - 2)
        scores[0] = typical; scores[scores.count - 1] = typical
        let combined = zip(standardized(scores, floor: 0.05), standardized(lowLevels, floor: 0.05)).map { $0 + $1 }
        var best: (beatsPerBar: Int, phase: Int, contrast: Float)?
        for size in [4, 3] {
            for phase in 0..<size {
                var inside: Float = 0, outside: Float = 0, insideCount: Float = 0, outsideCount: Float = 0
                for (index, value) in combined.enumerated() where index >= 2 && index < combined.count - 2 {
                    if index % size == phase { inside += value; insideCount += 1 }
                    else { outside += value; outsideCount += 1 }
                }
                let contrast = inside / max(1, insideCount) - outside / max(1, outsideCount)
                // Four beats is far more common, so three must clearly win.
                let adjusted = size == 3 ? contrast * 0.75 : contrast
                if adjusted > (best?.contrast ?? 0) { best = (size, phase, adjusted) }
            }
        }
        guard let best, best.contrast >= 1.5 else { return nil }
        return (best.beatsPerBar, best.phase)
    }

    private func meanChroma(from start: Int, to end: Int) -> [Float] {
        var result = [Float](repeating: 0, count: 12)
        let first = start / Self.chromaStep, last = max(first + 1, end / Self.chromaStep)
        let available = chroma.count / 12
        guard first < available else { return result }
        for block in first..<min(last, available) {
            for pitch in 0..<12 { result[pitch] += chroma[block * 12 + pitch] }
        }
        let total = result.reduce(0, +)
        return total > 0 ? result.map { $0 / total } : result
    }

    // MARK: Song shape

    /// Short gaps in the sound, such as a pause just before a drop.
    private func detectSilences(_ loudness: [Float], reference: Float) -> [(time: Double, strength: Double)] {
        let shortest = Int(0.12 / Self.frameTime)
        var result: [(time: Double, strength: Double)] = []
        var start: Int?
        for index in loudness.indices {
            if loudness[index] < reference - 30 {
                if start == nil { start = index }
            } else if let begin = start {
                // A quiet intro is not a pause.
                if index - begin >= shortest, begin > 0 {
                    result.append((time(begin), min(1, Double(index - begin) * Self.frameTime / 0.5)))
                }
                start = nil
            }
        }
        return result
    }

    /// Loudness, with a little weight on highs, four times a second. Risers and
    /// filter sweeps get brighter even when they do not get much louder.
    private func shapeCurve(_ loudness: [Float]) -> (values: [Float], step: Int) {
        let step = Int(0.25 / Self.frameTime)
        let radius = Int(0.5 / Self.frameTime)
        let bright = highPower.map { 10 * log10f($0 + 1e-10) }
        let smoothLoud = movingAverage(loudness, radius: radius)
        let smoothBright = movingAverage(bright, radius: radius)
        return (stride(from: 0, to: frameCount, by: step).map { 0.7 * smoothLoud[$0] + 0.3 * smoothBright[$0] }, step)
    }

    /// A build is a rise that keeps going for at least three seconds.
    private func detectBuilds(_ loudness: [Float]) -> [MusicBuild] {
        let (curve, step) = shapeCurve(loudness)
        let shortest = 12, minimumRise: Float = 4, slip: Float = 0.8
        var result: [MusicBuild] = []
        var index = 0
        while index + 1 < curve.count {
            var peak = curve[index], peakIndex = index
            var cursor = index + 1
            while cursor < curve.count, curve[cursor] >= peak - slip, cursor - peakIndex <= 6 {
                if curve[cursor] > peak { peak = curve[cursor]; peakIndex = cursor }
                cursor += 1
            }
            if peakIndex - index >= shortest, peak - curve[index] >= minimumRise {
                result.append(MusicBuild(start: time(index * step), end: time(peakIndex * step), rise: Double(peak - curve[index])))
                index = peakIndex
            }
            index += 1
        }
        return result
    }

    /// A drop is a sudden jump in level that the song then holds.
    private func detectDrops(_ loudness: [Float], reference: Float, hits: [Int]) -> [(time: Double, strength: Double)] {
        let radius = Int(1 / Self.frameTime), step = Int(0.05 / Self.frameTime)
        var totals = [Float](repeating: 0, count: frameCount + 1)
        for index in loudness.indices { totals[index + 1] = totals[index] + loudness[index] }
        var candidates: [(frame: Int, jump: Float)] = []
        for frame in stride(from: radius * 2, to: frameCount - radius, by: step) {
            let before = (totals[frame] - totals[frame - radius]) / Float(radius)
            let after = (totals[frame + radius] - totals[frame]) / Float(radius)
            if after - before >= 6, after >= reference - 12 { candidates.append((frame, after - before)) }
        }
        var result: [(time: Double, strength: Double)] = []
        var index = 0
        let spacing = Int(4 / Self.frameTime)
        while index < candidates.count {
            var last = index
            while last + 1 < candidates.count, candidates[last + 1].frame - candidates[last].frame <= step * 2 { last += 1 }
            guard let best = candidates[index...last].max(by: { $0.jump < $1.jump }) else { break }
            // The jump's center can sit before the hit. Land on the first hit after it starts.
            let reach = Int(0.35 / Self.frameTime)
            let frame = hits.filter { abs($0 - best.frame) <= reach }.min { abs($0 - best.frame) < abs($1 - best.frame) } ?? best.frame
            if let previous = result.last, Int((time(frame) - previous.time) / Self.frameTime) < spacing {} else {
                result.append((time(frame), min(1, Double(best.jump) / 15)))
            }
            index = last + 1
        }
        return result
    }

    /// Splits the song where its sound changes, comparing the four bars before
    /// each bar with the four bars after it.
    private func detectSections(beats: [Int], meter: (beatsPerBar: Int, phase: Int)?, energy: [EnergySample],
                                duration: Double) -> [MusicSection] {
        var marks: [Int]
        if let meter {
            marks = beats.enumerated().filter { $0.offset % meter.beatsPerBar == meter.phase }.map(\.element)
        } else if beats.count >= 8 {
            marks = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        } else {
            marks = Array(stride(from: 0, to: frameCount, by: Int(2 / Self.frameTime)))
        }
        marks.append(frameCount - 1)
        var features: [[Float]] = []
        for (start, end) in zip(marks, marks.dropFirst()) where end > start {
            var low: Float = 0, mid: Float = 0, high: Float = 0
            for frame in start..<end { low += lowPower[frame]; mid += midPower[frame]; high += highPower[frame] }
            let scale = 1 / Float(end - start)
            let levels = [low, mid, high].map { (10 * log10f($0 * scale + 1e-10) + 100) / 20 }
            features.append(levels + meanChroma(from: start, to: end).map { $0 * 3 })
        }
        let span = 4
        var novelty = [Float](repeating: 0, count: features.count)
        if features.count > span * 2 {
            for index in span..<(features.count - span + 1) {
                var distance: Float = 0
                for dimension in features[0].indices {
                    let before = features[(index - span)..<index].reduce(0) { $0 + $1[dimension] } / Float(span)
                    let after = features[index..<(index + span)].reduce(0) { $0 + $1[dimension] } / Float(span)
                    distance += abs(after - before)
                }
                novelty[index] = distance
            }
        }
        let mean = novelty.reduce(0, +) / Float(max(1, novelty.count))
        let deviation = sqrtf(novelty.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(max(1, novelty.count)))
        let threshold = max(0.6, mean + deviation)
        var boundaries: [Double] = []
        var lastBoundary = -span
        for index in novelty.indices where novelty[index] >= threshold && index - lastBoundary >= span {
            let low = max(0, index - 2), high = min(novelty.count - 1, index + 2)
            guard novelty[index] >= (novelty[low...high].max() ?? 0) else { continue }
            boundaries.append(time(marks[index]))
            lastBoundary = index
        }
        let edges = [0] + boundaries + [duration]
        return zip(edges, edges.dropFirst()).compactMap { start, end in
            guard end > start else { return nil }
            let values = energy.filter { $0.time >= start && $0.time < end }.map(\.value)
            return MusicSection(start: start, end: end, energy: values.reduce(0, +) / Double(max(1, values.count)))
        }
    }
}
