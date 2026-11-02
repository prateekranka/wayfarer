import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import MontageCore

/// Extracts timing and energy from local audio with bounded PCM buffering.
public actor MusicAnalysisService: MusicAnalyzing {
    private let sampleRate = 22_050.0
    private let envelopeHop = 1_102 // 50 ms at 22.05 kHz
    private let fftSize = 1_024
    private let fftHop = 512

    public init() {}

    public func analyze(url: URL) async throws -> MusicAnalysis {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let durationTime: CMTime
        let tracks: [AVAssetTrack]
        let protected: Bool
        let readable: Bool
        do {
            (durationTime, tracks, protected, readable) = try await asset.load(.duration, .tracks, .hasProtectedContent, .isReadable)
        } catch {
            throw MontageError.invalidMedia("This audio file cannot be read on this device.")
        }
        guard !protected else {
            throw MontageError.invalidMedia("This audio file is protected and cannot be analyzed.")
        }
        guard readable else {
            throw MontageError.invalidMedia("This audio file is not readable on this device.")
        }
        let duration = durationTime.seconds
        guard duration.isFinite, duration > 0 else {
            throw MontageError.invalidMedia("This audio file has no usable duration.")
        }
        guard duration <= 30.0 * 60.0 else {
            throw MontageError.invalidMedia("Music longer than 30 minutes is not supported.")
        }
        guard let track = tracks.first(where: { $0.mediaType == .audio }) else {
            throw MontageError.invalidMedia("This file does not contain an audio track.")
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MontageError.invalidMedia("This audio file cannot be decoded on this device.")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw MontageError.invalidMedia("This audio file cannot be decoded on this device.")
        }

        var energyValues: [EnergySample] = []
        energyValues.reserveCapacity(Int(duration / 0.05) + 1)
        var energyWindow = [Float]()
        energyWindow.reserveCapacity(envelopeHop)
        var fftWindow = [Float]()
        fftWindow.reserveCapacity(fftSize)
        var spectralFlux: [(time: Double, value: Double)] = []
        spectralFlux.reserveCapacity(Int(duration / 0.025) + 1)
        var previousSpectrum: [Float]?
        var totalFrames = 0

        while let readySample = try await provider.next() {
            try Task.checkCancellation()
            readySample.withUnsafeSampleBuffer { sampleBuffer in
                let values = self.monoFloatSamples(from: sampleBuffer)
                guard !values.isEmpty else { return }
                for value in values {
                    let finiteValue = value.isFinite ? value : 0
                    energyWindow.append(finiteValue)
                    fftWindow.append(finiteValue)
                    totalFrames += 1

                    if energyWindow.count >= self.envelopeHop {
                        let rms = self.rms(energyWindow)
                        let time = Double(totalFrames - energyWindow.count / 2) / self.sampleRate
                        energyValues.append(EnergySample(time: min(duration, max(0, time)), value: Double(rms)))
                        energyWindow.removeAll(keepingCapacity: true)
                    }
                    if fftWindow.count >= self.fftSize {
                        let spectrum = self.powerSpectrum(fftWindow)
                        let flux: Double
                        if let previousSpectrum, previousSpectrum.count == spectrum.count {
                            let positiveDifference = zip(spectrum, previousSpectrum).reduce(Float.zero) { partial, pair in
                                partial + max(0, pair.0 - pair.1)
                            }
                            flux = Double(positiveDifference) / Double(max(1, spectrum.count))
                        } else {
                            flux = 0
                        }
                        let time = Double(totalFrames - fftWindow.count / 2) / self.sampleRate
                        spectralFlux.append((min(duration, max(0, time)), flux))
                        previousSpectrum = spectrum
                        fftWindow = Array(fftWindow.suffix(self.fftSize - self.fftHop))
                    }
                }
            }
        }
        guard reader.status != .failed else {
            throw MontageError.invalidMedia("This audio file cannot be decoded on this device.")
        }
        if !energyWindow.isEmpty {
            let rms = rms(energyWindow)
            let time = Double(totalFrames - energyWindow.count / 2) / sampleRate
            energyValues.append(EnergySample(time: min(duration, max(0, time)), value: Double(rms)))
        }

        guard !energyValues.isEmpty else {
            throw MontageError.invalidMedia("This audio file contains no decodable PCM samples.")
        }
        let normalizedEnergy = normalize(energyValues, duration: duration)
        let onsetEnvelope = makeOnsetEnvelope(energy: normalizedEnergy, spectralFlux: spectralFlux, duration: duration)
        let onsetEvents = detectOnsets(onsetEnvelope: onsetEnvelope)
        let bpmResult = estimateBPM(onsetEnvelope: onsetEnvelope)
        let sections = makeSections(energy: normalizedEnergy, duration: duration)
        let events = makeEvents(
            onsets: onsetEvents,
            bpmResult: bpmResult,
            duration: duration,
            envelope: onsetEnvelope,
            energy: normalizedEnergy,
            sections: sections
        )
        let confidence = analysisConfidence(bpmConfidence: bpmResult?.confidence ?? 0, onsetCount: onsetEvents.count, duration: duration)
        return MusicAnalysis(
            duration: duration,
            bpm: bpmResult?.bpm,
            confidence: confidence,
            events: events,
            sections: sections,
            energy: normalizedEnergy
        )
    }

    private func monoFloatSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        let pointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        pointer.initialize(to: AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        ))
        defer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: pointer,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return [] }
        let buffers = UnsafeMutableAudioBufferListPointer(pointer)
        guard !buffers.isEmpty else { return [] }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return [] }

        var channelArrays: [[Float]] = []
        channelArrays.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }
            let pointer = data.assumingMemoryBound(to: Float.self)
            channelArrays.append(Array(UnsafeBufferPointer(start: pointer, count: sampleCount)))
        }
        guard !channelArrays.isEmpty else { return [] }
        if channelArrays.count == 1 {
            let values = channelArrays[0]
            let channels = max(1, Int(buffers[0].mNumberChannels))
            if channels == 1 { return Array(values.prefix(frameCount)) }
            return stride(from: 0, to: min(frameCount * channels, values.count), by: channels).map { index in
                let end = min(index + channels, values.count)
                return values[index..<end].reduce(0, +) / Float(max(1, end - index))
            }
        }
        let count = min(frameCount, channelArrays.map(\.count).min() ?? 0)
        return (0..<count).map { index in
            channelArrays.reduce(Float.zero) { $0 + $1[index] } / Float(channelArrays.count)
        }
    }

    private func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var result: Float = 0
        values.withUnsafeBufferPointer { buffer in
            vDSP_rmsqv(buffer.baseAddress!, 1, &result, vDSP_Length(values.count))
        }
        return result
    }

    private func powerSpectrum(_ values: [Float]) -> [Float] {
        let n = fftSize
        var input = Array(values.prefix(n))
        if input.count < n { input += Array(repeating: 0, count: n - input.count) }
        let realPointer = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        let imaginaryPointer = UnsafeMutablePointer<Float>.allocate(capacity: n / 2)
        defer { realPointer.deallocate(); imaginaryPointer.deallocate() }
        var magnitudes = [Float](repeating: 0, count: n / 2)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2)) else { return magnitudes }
        defer { vDSP_destroy_fftsetup(setup) }
        var split = DSPSplitComplex(realp: realPointer, imagp: imaginaryPointer)
        input.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
            }
        }
        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
        magnitudes.withUnsafeMutableBufferPointer { result in
            vDSP_zvmags(&split, 1, result.baseAddress!, 1, vDSP_Length(n / 2))
        }
        return magnitudes
    }

    private func normalize(_ values: [EnergySample], duration: Double) -> [EnergySample] {
        let maximum = values.map(\.value).max() ?? 0
        guard maximum > 0 else { return values.map { EnergySample(time: min(duration, $0.time), value: 0) } }
        return values.map { EnergySample(time: min(duration, max(0, $0.time)), value: min(1.0, $0.value / maximum)) }
    }

    private func makeOnsetEnvelope(energy: [EnergySample], spectralFlux: [(time: Double, value: Double)], duration: Double) -> [EnergySample] {
        guard !energy.isEmpty else { return [] }
        var values = energy.map(\.value)
        for index in values.indices {
            let previous = index > values.startIndex ? values[index - 1] : values[index]
            values[index] = max(0, values[index] - previous)
        }
        if !spectralFlux.isEmpty {
            let fluxMaximum = spectralFlux.map(\.value).max() ?? 0
            if fluxMaximum > 0 {
                for sample in spectralFlux {
                    let index = Int((sample.time / max(0.001, duration)) * Double(values.count - 1))
                    guard values.indices.contains(index) else { continue }
                    values[index] = max(values[index], sample.value / fluxMaximum)
                }
            }
        }
        return zip(energy, values).map { EnergySample(time: $0.0.time, value: min(1.0, $0.1)) }
    }

    private func detectOnsets(onsetEnvelope: [EnergySample]) -> [(time: Double, strength: Double)] {
        guard onsetEnvelope.count >= 3 else { return [] }
        let values = onsetEnvelope.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let threshold = max(0.12, mean + sqrt(variance) * 1.15)
        let minimumGap = 0.12
        var result: [(time: Double, strength: Double)] = []
        for index in 1..<(onsetEnvelope.count - 1) {
            let value = values[index]
            guard value >= threshold, value >= values[index - 1], value >= values[index + 1] else { continue }
            if let previous = result.last, onsetEnvelope[index].time - previous.time < minimumGap {
                if value > previous.strength { result[result.count - 1] = (onsetEnvelope[index].time, value) }
            } else {
                result.append((onsetEnvelope[index].time, value))
            }
        }
        return result
    }

    private func estimateBPM(onsetEnvelope: [EnergySample]) -> (bpm: Double, confidence: Double)? {
        guard onsetEnvelope.count >= 20 else { return nil }
        let values = onsetEnvelope.map(\.value)
        let hop = medianTimeStep(onsetEnvelope)
        guard hop > 0 else { return nil }
        let minLag = max(1, Int((60.0 / 220.0 / hop).rounded()))
        let maxLag = min(values.count / 2, Int((60.0 / 40.0 / hop).rounded()))
        guard minLag <= maxLag else { return nil }
        var scores: [(lag: Int, value: Double)] = []
        for lag in minLag...maxLag {
            let count = values.count - lag
            guard count > 2 else { continue }
            var score = 0.0
            var normA = 0.0
            var normB = 0.0
            for index in 0..<count {
                let a = values[index]
                let b = values[index + lag]
                score += a * b
                normA += a * a
                normB += b * b
            }
            let normalized = score / max(0.0001, sqrt(normA * normB))
            scores.append((lag, normalized))
        }
        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 0.14 else { return nil }
        let sorted = scores.sorted { $0.value > $1.value }
        let second = sorted.dropFirst().first?.value ?? 0
        let confidence = min(1.0, max(0.0, best.value * 0.65 + (best.value - second) * 1.8))
        return (60.0 / (Double(best.lag) * hop), confidence)
    }

    private func makeEvents(
        onsets: [(time: Double, strength: Double)],
        bpmResult: (bpm: Double, confidence: Double)?,
        duration: Double,
        envelope: [EnergySample],
        energy: [EnergySample],
        sections: [MusicSection]
    ) -> [MusicEvent] {
        var events = onsets.map {
            let strength = min(1.0, $0.strength)
            let kind: MusicEventKind = strength >= 0.65 ? .strongBeat : .onset
            return MusicEvent(time: $0.time, kind: kind, strength: strength)
        }
        if let bpmResult {
            let interval = 60.0 / bpmResult.bpm
            if interval.isFinite, interval > 0 {
                let firstOnset = onsets.first?.time ?? 0
                var time = firstOnset
                while time < duration {
                    let support = nearestEnvelopeValue(envelope, time: time)
                    if support >= 0.12 {
                        let kind: MusicEventKind = support >= 0.55 ? .strongBeat : .beat
                        events.append(MusicEvent(time: time, kind: kind, strength: support * bpmResult.confidence))
                    }
                    time += interval
                }
            }
        }

        // A build is emitted only after a measured, sustained energy rise.
        let hop = medianTimeStep(energy)
        if hop > 0, energy.count >= 8 {
            let window = max(1, Int((1.0 / hop).rounded()))
            if energy.count > window * 2 {
                var lastBuildTime = -Double.infinity
                for index in window..<(energy.count - window) {
                    let previous = energy[(index - window)..<index].map(\.value).reduce(0, +) / Double(window)
                    let current = energy[index..<(index + window)].map(\.value).reduce(0, +) / Double(window)
                    let rise = current - previous
                    if rise >= 0.16, energy[index].time - lastBuildTime >= 2.0 {
                        events.append(MusicEvent(time: energy[index].time, kind: .build, strength: min(1.0, rise * 2.2)))
                        lastBuildTime = energy[index].time
                    }
                }
            }
        }
        // Section boundaries with a measured energy change mark transitions.
        for index in 1..<sections.count {
            let previous = sections[index - 1]
            let current = sections[index]
            let difference = abs(current.energy - previous.energy)
            if difference >= 0.14 {
                events.append(MusicEvent(time: current.start, kind: .transition, strength: min(1.0, difference * 1.8)))
            }
        }
        return deduplicateEvents(events).sorted { $0.time < $1.time }
    }

    private func makeSections(energy: [EnergySample], duration: Double) -> [MusicSection] {
        guard !energy.isEmpty else { return [] }
        let chunkSize = max(1, Int((4.0 / max(0.001, medianTimeStep(energy))).rounded()))
        var chunkMeans: [Double] = []
        var chunkTimes: [Double] = [0]
        var index = 0
        while index < energy.count {
            let end = min(energy.count, index + chunkSize)
            let mean = energy[index..<end].map(\.value).reduce(0, +) / Double(max(1, end - index))
            chunkMeans.append(mean)
            if end < energy.count { chunkTimes.append(energy[end].time) }
            index = end
        }
        let mean = chunkMeans.reduce(0, +) / Double(max(1, chunkMeans.count))
        let variance = chunkMeans.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, chunkMeans.count))
        let threshold = max(0.14, sqrt(variance) * 1.15)
        var boundaries = [0.0]
        for i in 1..<chunkMeans.count where abs(chunkMeans[i] - chunkMeans[i - 1]) >= threshold {
            boundaries.append(chunkTimes[min(i, chunkTimes.count - 1)])
        }
        boundaries.append(duration)
        boundaries = boundaries.filter { $0 >= 0 && $0 <= duration }.sorted()
        boundaries = boundaries.enumerated().filter { index, value in index == 0 || value - boundaries[index - 1] >= 2.0 || index == boundaries.count - 1 }.map(\.element)
        var sections: [MusicSection] = []
        for index in 0..<(max(1, boundaries.count - 1)) {
            let start = boundaries[min(index, boundaries.count - 1)]
            let end = boundaries[min(index + 1, boundaries.count - 1)]
            guard end > start else { continue }
            let values = energy.filter { $0.time >= start && $0.time < end }.map(\.value)
            let sectionEnergy = values.isEmpty ? nearestEnergyValue(energy, time: start) : values.reduce(0, +) / Double(values.count)
            sections.append(MusicSection(start: start, end: end, energy: sectionEnergy))
        }
        return sections
    }

    private func analysisConfidence(bpmConfidence: Double, onsetCount: Int, duration: Double) -> Double {
        let eventCoverage = min(1.0, Double(onsetCount) / max(4.0, duration * 0.8))
        return min(1.0, bpmConfidence * 0.7 + eventCoverage * 0.3)
    }

    private func nearestEnvelopeValue(_ envelope: [EnergySample], time: Double) -> Double {
        envelope.min(by: { abs($0.time - time) < abs($1.time - time) })?.value ?? 0
    }

    private func nearestEnergyValue(_ energy: [EnergySample], time: Double) -> Double {
        nearestEnvelopeValue(energy, time: time)
    }

    private func medianTimeStep(_ values: [EnergySample]) -> Double {
        guard values.count > 1 else { return 0 }
        let steps = zip(values.dropFirst(), values).map { max(0, $0.0.time - $0.1.time) }.sorted()
        return steps[steps.count / 2]
    }

    private func deduplicateEvents(_ events: [MusicEvent]) -> [MusicEvent] {
        var result: [MusicEvent] = []
        for event in events.sorted(by: { $0.time < $1.time }) {
            if let index = result.lastIndex(where: { abs($0.time - event.time) < 0.025 }) {
                if event.strength > result[index].strength { result[index] = event }
            } else {
                result.append(event)
            }
        }
        return result
    }
}
