import Accelerate
import CoreML
import Foundation

/// Finds where bars start with Beat This!, a small trained beat model from the
/// Institute of Computational Perception, JKU Linz. It ships under the MIT
/// license in `Models/BeatThis-LICENSE.txt` and runs on the device.
///
/// The model reads a log mel spectrogram at 50 frames a second, made exactly as
/// the original Python code makes it, and scores every frame as a beat and as a
/// bar start. Like `MusicSignalAnalyzer`, samples arrive in chunks.
public final class BarTracker {
    public static let sampleRate = 22_050.0
    static let framesPerSecond = 50.0
    static let bands = 128
    static let chunkFrames = 1_500
    /// Frames at each chunk edge that the model was not trained to score.
    static let border = 6
    private static let fftSize = 1_024
    private static let hop = 441

    private let setup: FFTSetup
    private let window: [Float]
    /// Mel filters, one row of `bands` weights for each FFT bin.
    private let filters: [Float]
    private var pending: [Float] = []
    private var tail: [Float] = []
    private var started = false
    private var spectrogram: [Float] = []
    private(set) var frameCount = 0

    public init?() {
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                             count: Self.fftSize, isHalfWindow: false)
        filters = Self.melFilters()
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Adds mono samples at `sampleRate`.
    public func process(_ samples: [Float]) {
        let clean = samples.map { $0.isFinite ? $0 : 0 }
        let half = Self.fftSize / 2
        tail.append(contentsOf: clean.suffix(half + 1))
        if tail.count > half + 1 { tail.removeFirst(tail.count - half - 1) }
        pending.append(contentsOf: clean)
        if !started {
            guard pending.count > half else { return }
            // Frames are centered, so the song starts with a mirror of its first samples.
            pending.insert(contentsOf: pending[1...half].reversed(), at: 0)
            started = true
        }
        analyzeFrames()
    }

    /// Runs the model and returns the times where bars start, or nil when the
    /// model cannot run or the audio is too short.
    public func barStarts() -> [Double]? {
        guard finishSpectrogram(), let model = Self.loadModel() else { return nil }
        let logits = try? Self.logits(spectrogram: spectrogram, frames: frameCount) { chunk in
            try Self.predict(model, chunk)
        }
        guard let logits else { return nil }
        return Self.peaks(beat: logits.beat, downbeat: logits.downbeat).downbeats
    }

    // MARK: Spectrogram

    private func finishSpectrogram() -> Bool {
        guard started else { return false }
        // The end is mirrored too, without repeating the last sample.
        pending.append(contentsOf: tail.dropLast().reversed())
        tail = []
        analyzeFrames()
        return frameCount > 0
    }

    private func analyzeFrames() {
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
        var magnitude = [Float](repeating: 0, count: n / 2 + 1)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                // The real FFT doubles every value and packs the top bin into
                // the first imaginary value. The model also divides by sqrt(n).
                let scale = 1 / (2 * Float(n).squareRoot())
                magnitude[0] = abs(split.realp[0]) * scale
                magnitude[n / 2] = abs(split.imagp[0]) * scale
                for bin in 1..<(n / 2) {
                    magnitude[bin] = hypotf(split.realp[bin], split.imagp[bin]) * scale
                }
            }
        }
        var mel = [Float](repeating: 0, count: Self.bands)
        vDSP_mmul(magnitude, 1, filters, 1, &mel, 1, 1, vDSP_Length(Self.bands), vDSP_Length(n / 2 + 1))
        spectrogram.append(contentsOf: mel.map { log1pf(1_000 * $0) })
        frameCount += 1
    }

    /// Triangular filters on the Slaney mel scale from 30 Hz to 11 kHz, without
    /// area scaling, as torchaudio builds them.
    static func melFilters() -> [Float] {
        let bins = fftSize / 2 + 1
        func mel(_ hertz: Double) -> Double {
            hertz < 1_000 ? hertz * 3 / 200 : 15 + log(hertz / 1_000) / (log(6.4) / 27)
        }
        func hertz(_ mel: Double) -> Double {
            mel < 15 ? mel * 200 / 3 : 1_000 * exp(log(6.4) / 27 * (mel - 15))
        }
        let low = mel(30), high = mel(11_000)
        let edges = (0..<(bands + 2)).map { hertz(low + (high - low) * Double($0) / Double(bands + 1)) }
        var weights = [Float](repeating: 0, count: bins * bands)
        for bin in 0..<bins {
            let frequency = sampleRate / 2 * Double(bin) / Double(bins - 1)
            for band in 0..<bands {
                let rising = (frequency - edges[band]) / (edges[band + 1] - edges[band])
                let falling = (edges[band + 2] - frequency) / (edges[band + 2] - edges[band + 1])
                weights[bin * bands + band] = Float(max(0, min(rising, falling)))
            }
        }
        return weights
    }

    // MARK: Model

    private static func loadModel() -> MLModel? {
        guard let url = Bundle.module.url(forResource: "BeatThisSmall", withExtension: "mlmodelc",
                                          subdirectory: "Models") else { return nil }
        let configuration = MLModelConfiguration()
        // The Neural Engine cannot compile this model, and only full precision
        // gives correct results on the GPU.
        configuration.computeUnits = .cpuAndGPU
        return try? MLModel(contentsOf: url, configuration: configuration)
    }

    private static func predict(_ model: MLModel, _ chunk: [Float]) throws -> (beat: [Float], downbeat: [Float]) {
        let input = try MLMultiArray(shape: [1, NSNumber(value: chunkFrames), NSNumber(value: bands)], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, strides in
            for frame in 0..<chunkFrames {
                for band in 0..<bands {
                    pointer[frame * strides[1] + band * strides[2]] = chunk[frame * bands + band]
                }
            }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["spect": input]))
        func values(_ name: String) throws -> [Float] {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
            return array.withUnsafeBufferPointer(ofType: Float.self) { pointer in
                let step = array.strides[1].intValue
                return (0..<chunkFrames).map { pointer[$0 * step] }
            }
        }
        return (try values("beat"), try values("downbeat"))
    }

    /// Scores a whole song in overlapping chunks, as the original code does,
    /// and keeps each frame's score from the first chunk that covers it.
    static func logits(spectrogram: [Float], frames: Int,
                       predict: ([Float]) throws -> (beat: [Float], downbeat: [Float])) rethrows -> (beat: [Float], downbeat: [Float]) {
        let step = chunkFrames - 2 * border
        var starts = Array(stride(from: -border, to: frames - border, by: step))
        if frames > step, !starts.isEmpty { starts[starts.count - 1] = frames - (chunkFrames - border) }
        var beat = [Float](repeating: -1_000, count: frames)
        var downbeat = beat
        for start in starts.reversed() {
            var chunk = [Float](repeating: 0, count: chunkFrames * bands)
            for frame in max(0, start)..<min(frames, start + chunkFrames) {
                let row = (frame - start) * bands
                chunk.replaceSubrange(row..<(row + bands), with: spectrogram[(frame * bands)..<((frame + 1) * bands)])
            }
            let scores = try predict(chunk)
            for index in border..<(chunkFrames - border) {
                let frame = start + index
                guard frame >= 0, frame < frames else { continue }
                beat[frame] = scores.beat[index]
                downbeat[frame] = scores.downbeat[index]
            }
        }
        return (beat, downbeat)
    }

    /// Picks positive local peaks, merges peaks on neighboring frames, and moves
    /// each bar start onto its nearest beat.
    static func peaks(beat: [Float], downbeat: [Float]) -> (beats: [Double], downbeats: [Double]) {
        func pick(_ scores: [Float]) -> [Double] {
            var frames: [Int] = []
            for index in scores.indices where scores[index] > 0 {
                let low = max(0, index - 3), high = min(scores.count - 1, index + 3)
                if scores[index] >= scores[low...high].max() ?? 0 { frames.append(index) }
            }
            var merged: [Double] = []
            var group: [Int] = []
            for frame in frames {
                if let last = group.last, frame - last > 1 {
                    merged.append(Double(group.reduce(0, +)) / Double(group.count))
                    group = []
                }
                group.append(frame)
            }
            if !group.isEmpty { merged.append(Double(group.reduce(0, +)) / Double(group.count)) }
            return merged.map { $0 / framesPerSecond }
        }
        let beats = pick(beat)
        guard !beats.isEmpty else { return ([], []) }
        let downbeats = pick(downbeat).map { time in beats.min { abs($0 - time) < abs($1 - time) }! }
        return (beats, Array(Set(downbeats)).sorted())
    }
}
