import AVFoundation
import CoreMedia
import Foundation
import MontageCore

/// Decodes local audio and streams it through `MusicSignalAnalyzer`.
public actor MusicAnalysisService: MusicAnalyzing {
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
            AVSampleRateKey: MusicSignalAnalyzer.sampleRate,
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

        guard let analyzer = MusicSignalAnalyzer() else {
            throw MontageError.invalidMedia("This audio file cannot be analyzed on this device.")
        }
        // Bars come from a trained model when it can run; otherwise the analyzer guesses them.
        let bars = BarTracker()
        var hasSamples = false
        while let readySample = try await provider.next() {
            try Task.checkCancellation()
            let values = readySample.withUnsafeSampleBuffer { monoFloatSamples(from: $0) }
            guard !values.isEmpty else { continue }
            hasSamples = true
            analyzer.process(values)
            bars?.process(values)
        }
        guard reader.status != .failed else {
            throw MontageError.invalidMedia("This audio file cannot be decoded on this device.")
        }
        guard hasSamples else {
            throw MontageError.invalidMedia("This audio file contains no decodable PCM samples.")
        }
        try Task.checkCancellation()
        return analyzer.finish(duration: duration, barStarts: bars?.barStarts())
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
}
