import AVFoundation
import AVFAudio
import CoreMedia
import CryptoKit
import Foundation
import MontageCore

/// Creates deterministic, local media that exercises the import and montage paths.
///
/// Clips are real H.264 movies with six seconds of video at 12 fps. They use
/// original illustrated fixtures instead of copyrighted sample footage, so the
/// demo works offline and remains reproducible. Movies are bundled fixtures;
/// analysis and montage rendering still use the real native media pipeline.
public actor DemoMediaService {

    public init() {}

    /// Creates `count` differentiated demo movies and returns their actual metadata.
    public func create(directory: URL, count: Int = 12,
                       progress: @escaping @Sendable (Int) async -> Void = { _ in }) async throws -> [SourceAsset] {
        guard (1...85).contains(count) else {
            throw MontageError.invalidMedia("Choose the 12-clip or 85-clip sample trip.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var assets: [SourceAsset] = []
        assets.reserveCapacity(count)

        for index in 0..<count {
            try Task.checkCancellation()
            let fileName = "wayfarer-demo-\(padded(index + 1)).mp4"
            let url = directory.appendingPathComponent(fileName)
            removeOwnedFile(url)
            let resourceName = "wayfarer-demo-" + padded(index + 1)
            guard let bundled = Bundle.main.url(forResource: resourceName, withExtension: "mp4", subdirectory: "SampleTrip")
                ?? Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
                throw MontageError.invalidMedia("The sample footage is missing from this build.")
            }
            try FileManager.default.copyItem(at: bundled, to: url)

            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else {
                throw MontageError.invalidMedia("The generated demo movie has no video track.")
            }
            let naturalSize = try await track.load(.naturalSize)
            let timestamp = Date(timeIntervalSince1970: 1_704_067_200 + Double(index) * 3_600)
            assets.append(SourceAsset(
                id: deterministicID(index: index),
                fileName: fileName,
                duration: CMTimeGetSeconds(duration),
                width: naturalSize.width,
                height: naturalSize.height,
                timestamp: timestamp,
                fingerprint: try fingerprint(of: url)
            ))
            await progress(index + 1)
        }
        return assets
    }

    /// Writes a 72-second WAV with a 120 BPM pulse, melody, and section changes.
    public func createMusic(directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wayfarer-demo-music.wav")
        removeOwnedFile(url)

        let sampleRate = 44_100.0
        let channels: AVAudioChannelCount = 1
        let duration = 72.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) else {
            throw MontageError.invalidMedia("The demo audio format is unavailable.")
        }
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = Int(duration * sampleRate)
        let chunkFrames = Int(sampleRate / 4)
        var frame = 0
        while frame < totalFrames {
            try Task.checkCancellation()
            let count = min(chunkFrames, totalFrames - frame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let samples = buffer.floatChannelData?.pointee else {
                throw MontageError.invalidMedia("The demo audio buffer could not be allocated.")
            }
            buffer.frameLength = AVAudioFrameCount(count)
            for offset in 0..<count {
                let time = Double(frame + offset) / sampleRate
                samples[offset] = musicSample(at: time)
            }
            try audioFile.write(from: buffer)
            frame += count
        }
        return url
    }

    private func musicSample(at time: Double) -> Float {
        let beat = time * 2
        let beatPhase = beat - floor(beat)
        let pulse = exp(-beatPhase * 18)
        let section = Int(time / 18) % 4
        let root: Double = [110, 98, 123, 130][section]
        let melody = sin(2 * .pi * root * time) * 0.16
            + sin(2 * .pi * root * 1.5 * time) * 0.07
        let pad = sin(2 * .pi * (root / 2) * time) * (0.04 + 0.02 * Double(section))
        let sample = pulse * 0.22 + melody + pad
        return Float(max(-0.85, min(0.85, sample)))
    }

    private func padded(_ value: Int) -> String {
        String(value).leftPadded(toLength: 3, with: "0")
    }

    private func deterministicID(index: Int) -> UUID {
        let digest = Array(SHA256.hash(data: Data("wayfarer-demo-\(index)".utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
            (digest[6] & 0x0f) | 0x40, digest[7],
            (digest[8] & 0x3f) | 0x80, digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func removeOwnedFile(_ url: URL) {
        guard url.lastPathComponent.hasPrefix("wayfarer-demo-") else {
            if url.lastPathComponent == "wayfarer-demo-music.wav" {
                try? FileManager.default.removeItem(at: url)
            }
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}

private extension String {
    func leftPadded(toLength length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}
