import AVFoundation
import Observation

@MainActor @Observable
final class PlaybackMonitor {
    var seconds: Double = 0
    var isReady = false
    var failure: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeToken: Any?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    func attach(_ player: AVPlayer, diagnosticURL: URL? = nil) {
        detach()
        self.player = player; seconds = 0; isReady = false; failure = nil
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in if seconds.isFinite { self?.seconds = seconds } }
        }
        observation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isReady = self.player?.currentItem?.status == .readyToPlay
                if self.player?.currentItem?.status == .failed {
                    self.failure = "This preview could not play. Try opening the project again."
                    if let error = self.player?.currentItem?.error as NSError?, let diagnosticURL {
                        var codes: [[String: Any]] = []
                        var current: NSError? = error
                        while let value = current, codes.count < 8 {
                            // Error text can contain media paths. Store only
                            // framework identifiers and numeric codes locally.
                            codes.append(["domain": value.domain, "code": value.code])
                            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
                        }
                        if let data = try? JSONSerialization.data(withJSONObject: codes, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: diagnosticURL, options: [.atomic])
                        }
                    }
                }
            }
        }
    }
    func detach() {
        if let timeToken { player?.removeTimeObserver(timeToken) }
        timeToken = nil; observation = nil; player?.pause(); player = nil
        seconds = 0; isReady = false; failure = nil
    }
    var position: String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
