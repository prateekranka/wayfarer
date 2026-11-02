import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Owns the one preview player used by the app.
///
/// The controller is main-actor isolated because AVFoundation player state and
/// the SwiftUI observation model are both consumed by the main actor.
@MainActor @Observable
final class PlaybackController {
    @ObservationIgnored let player: AVPlayer

    var wantsPlayback = true
    var isMuted = false {
        didSet {
            player.isMuted = isMuted
            refreshAudioStatus()
        }
    }
    private(set) var isReady = false
    private(set) var isPlaying = false
    private(set) var seconds = 0.0
    private(set) var duration = 0.0
    private(set) var error: String?
    private(set) var audioError: String?
    private(set) var itemFailed = false
    private(set) var audioStatus = "Audio track status unknown · Sound on"
    private(set) var owner: UUID?

    @ObservationIgnored private var ownerIsActive = false
    @ObservationIgnored private var sceneIsActive = true
    @ObservationIgnored private var audioSessionIsActive = false
    @ObservationIgnored private var audioSessionHasError = false
    @ObservationIgnored private var hasAudioTrack: Bool?
    @ObservationIgnored private var shouldResumeAfterInterruption = false
    @ObservationIgnored private var isInterrupted = false
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var isLoadingItem = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var itemStatusObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemDurationObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemEndObserver: NSObjectProtocol?
    @ObservationIgnored private var sessionObservers: [NSObjectProtocol] = []

    init() {
        player = AVPlayer()
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        installSessionObservers()
        refreshAudioStatus()
    }

    isolated deinit {
        removeItemObservers()
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Loads a new item for `owner` and keeps the current pause and mute choices.
    ///
    /// Takes ownership of the player and replaces the outgoing item.
    ///
    /// The generation check protects a newly displayed preview from a late
    /// metadata continuation belonging to an old preview.
    func load(item: AVPlayerItem, owner: UUID, autoplay: Bool? = nil) async {
        guard !Task.isCancelled else { return }

        let wasActive = self.owner == owner && ownerIsActive
        self.owner = owner
        ownerIsActive = wasActive
        loadGeneration += 1
        let generation = loadGeneration
        isLoadingItem = true

        removeItemObservers()
        pauseAndDeactivate()
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        isReady = false
        itemFailed = false
        seconds = 0
        duration = 0
        error = nil
        audioError = nil
        hasAudioTrack = nil
        audioSessionHasError = false
        refreshAudioStatus()

        if let autoplay { wantsPlayback = autoplay }
        itemStatusObserver = item.observe(\AVPlayerItem.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.updateItemStatus()
            }
        }
        itemDurationObserver = item.observe(\AVPlayerItem.duration, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.updateDuration()
            }
        }
        itemEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                isPlaying = false
                wantsPlayback = false
                deactivateAudioSession()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.updateTime(time)
            }
        }

        // CompositionBuilder attaches its audio mix to the item before this
        // method is called. Readiness is still loaded asynchronously for URL
        // backed items, and the generation check drops stale results.
        do {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            let itemDuration = try await item.asset.load(.duration)
            guard self.owner == owner, loadGeneration == generation else { return }
            hasAudioTrack = !tracks.isEmpty
            if itemDuration.isNumeric, itemDuration.seconds.isFinite {
                duration = max(0, itemDuration.seconds)
            }
            refreshAudioStatus()
            updateItemStatus()
        } catch {
            guard self.owner == owner, loadGeneration == generation else { return }
            if Task.isCancelled {
                isLoadingItem = false
                pauseAndDeactivate()
                return
            }
            // A failed audio metadata read must not make the video preview
            // fail or force the proxy path. AVPlayer reports real item errors
            // through its status observation below.
            hasAudioTrack = nil
            refreshAudioStatus()
        }

        guard self.owner == owner, loadGeneration == generation else { return }
        guard !Task.isCancelled else {
            isLoadingItem = false
            pauseAndDeactivate()
            return
        }
        _ = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        guard self.owner == owner, loadGeneration == generation, !Task.isCancelled else { return }
        isLoadingItem = false
        startPlaybackIfPossible()
    }

    /// Changes whether this owner is the visible preview.
    func setActive(_ active: Bool, owner: UUID) {
        guard self.owner == owner else { return }
        ownerIsActive = active
        if active {
            startPlaybackIfPossible()
        } else {
            pauseAndDeactivate()
        }
    }

    /// Releases the item only when the caller still owns it.
    func release(owner: UUID) {
        guard self.owner == owner else { return }
        loadGeneration += 1
        isLoadingItem = false
        ownerIsActive = false
        pauseAndDeactivate()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        self.owner = nil
        isReady = false
        isPlaying = false
        seconds = 0
        duration = 0
        error = nil
        audioError = nil
        itemFailed = false
        hasAudioTrack = nil
        audioSessionHasError = false
        refreshAudioStatus()
    }

    func togglePlayback() {
        wantsPlayback.toggle()
        if wantsPlayback {
            if duration > 0, seconds >= duration - 0.05 {
                seek(to: 0)
            }
            startPlaybackIfPossible()
        } else {
            pauseAndDeactivate()
        }
    }

    func toggleMute() {
        isMuted.toggle()
    }

    func seek(to value: Double) {
        guard let item = player.currentItem else { return }
        let upperBound = duration > 0 ? duration : max(0, item.duration.seconds)
        let clamped = min(max(0, value), upperBound)
        seconds = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Pauses playback while the app is inactive, without changing user intent.
    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        if active {
            startPlaybackIfPossible()
        } else {
            pauseAndDeactivate()
        }
    }

    func owns(_ owner: UUID) -> Bool {
        self.owner == owner
    }

    private func startPlaybackIfPossible() {
        guard sceneIsActive, ownerIsActive, wantsPlayback, !isInterrupted,
              !isLoadingItem,
              let item = player.currentItem,
              item.status == .readyToPlay else {
            isPlaying = false
            return
        }

        activateAudioSession()
        player.play()
        isPlaying = true
    }

    private func activateAudioSession() {
        guard !audioSessionIsActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            audioSessionIsActive = true
            audioSessionHasError = false
            audioError = nil
        } catch {
            // Video playback can continue without an active audio session.
            // Keep this as a diagnostic state instead of a preview failure.
            audioSessionIsActive = false
            audioSessionHasError = true
            audioError = "Sound could not start. Pause and play to try again."
        }
        refreshAudioStatus()
    }

    private func deactivateAudioSession() {
        guard audioSessionIsActive else { return }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
        audioSessionIsActive = false
        refreshAudioStatus()
    }

    private func pauseAndDeactivate() {
        player.pause()
        isPlaying = false
        deactivateAudioSession()
    }

    private func updateItemStatus() {
        guard let item = player.currentItem else {
            isReady = false
            return
        }
        isReady = item.status == .readyToPlay
        if item.status == .failed {
            itemFailed = true
            error = "This preview could not play. Try opening the project again."
            pauseAndDeactivate()
        } else if isReady {
            updateDuration()
            startPlaybackIfPossible()
        }
    }

    private func updateDuration() {
        guard let item = player.currentItem else { return }
        let value = item.duration.seconds
        if value.isFinite, value >= 0 { duration = value }
    }

    private func updateTime(_ time: CMTime) {
        guard time.isNumeric, time.seconds.isFinite else { return }
        seconds = max(0, time.seconds)
        updateDuration()
        isPlaying = player.timeControlStatus == .playing
    }

    private func refreshAudioStatus() {
        let track = switch hasAudioTrack {
        case true: "Audio track available"
        case false: "No audio track"
        case nil: "Audio track status unknown"
        }
        let volume = isMuted ? "Muted" : "Sound on"
        let session = audioSessionHasError ? " · Audio session unavailable" : ""
        audioStatus = "\(track) · \(volume)\(session)"
    }

    private func removeItemObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        itemStatusObserver = nil
        itemDurationObserver = nil
        if let itemEndObserver {
            NotificationCenter.default.removeObserver(itemEndObserver)
        }
        itemEndObserver = nil
    }

    private func installSessionObservers() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(
                    type: rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:)),
                    options: rawOptions.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                )
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)))
            }
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(
        type: AVAudioSession.InterruptionType?,
        options: AVAudioSession.InterruptionOptions
    ) {
        guard let type else { return }
        switch type {
        case .began:
            shouldResumeAfterInterruption = isPlaying && wantsPlayback
            isInterrupted = true
            pauseAndDeactivate()
        case .ended:
            isInterrupted = false
            let shouldResume = shouldResumeAfterInterruption
            shouldResumeAfterInterruption = false
            if !options.contains(.shouldResume) { wantsPlayback = false }
            guard shouldResume,
                  options.contains(.shouldResume),
                  wantsPlayback else { return }
            startPlaybackIfPossible()
        @unknown default:
            shouldResumeAfterInterruption = false
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable else { return }
        // Do not resume through the phone speaker after headphones disconnect.
        wantsPlayback = false
        pauseAndDeactivate()
    }

    private func handleMediaServicesReset() {
        pauseAndDeactivate()
        audioSessionHasError = false
        refreshAudioStatus()
        if ownerIsActive, wantsPlayback {
            startPlaybackIfPossible()
        }
    }
}

/// A gesture-neutral AVPlayerLayer surface for use inside a paged SwiftUI view.
@MainActor
struct PlaybackSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = videoGravity
    }

    static func dismantleUIView(_ view: PlayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
