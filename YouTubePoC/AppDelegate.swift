import UIKit
import AVFAudio
import AVFoundation
import AVKit
import MediaPlayer
import WebKit

/// Verifies the actual webpage media URL in a paused player before PiP handoff.
@MainActor
final class NativeAudioSourceProbe {
    var onCompatible: ((String, AVURLAsset, AVPlayer?) -> Void)?
    private var videoID = ""
    private var pip = false
    private var expectedDuration = 0.0
    private var candidates: [URL] = []
    private var attempted: Set<URL> = []
    private var activeCandidate: URL?
    private var task: Task<Void, Never>?
    private var asset: AVURLAsset?
    private var probePlayer: AVPlayer?
    private var generation = 0
    private var foundCompatibleSource = false
    #if DEBUG
    private var didRunPreparationRetryCheck = false
    #endif

    func receive(_ message: [String: Any]) {
        guard let id = message["videoID"] as? String, !id.isEmpty,
              let source = message["url"] as? String,
              let url = URL(string: source), url.scheme == "https",
              let host = url.host,
              host == "googlevideo.com" || host.hasSuffix(".googlevideo.com"),
              url.path == "/videoplayback" || url.path == "/api/manifest/hls_playlist" ||
                url.path.hasPrefix("/api/manifest/hls_playlist/") ||
                url.path == "/api/manifest/hls_variant" ||
                url.path.hasPrefix("/api/manifest/hls_variant/") else { return }
        if id != videoID { reset(videoID: id) }
        guard !candidates.contains(url), candidates.count < 4 else { return }
        candidates.append(url)
        let mime = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "mime" })?.value ?? "unknown"
        PlaybackAudioSession.shared.log("NATIVE_SOURCE observed mime=\(mime) candidates=\(candidates.count)")
        startIfPossible()
    }

    func update(_ media: [String: Any]) {
        let id = media["videoID"] as? String ?? ""
        if id != videoID { reset(videoID: id) }
        expectedDuration = (media["duration"] as? Double) ?? 0
        let foregroundProbe = !id.isEmpty && UIApplication.shared.applicationState == .active
        if foregroundProbe && expectedDuration <= 0 {
            expectedDuration = (media["sourceDuration"] as? Double) ?? 0
        }
        let active = ((media["pip"] as? Bool ?? false) || foregroundProbe) &&
            !(media["ad"] as? Bool ?? false)
        if pip && !active { cancel(retryInterrupted: true) }
        pip = active
        guard active else { return }
        if media["event"] as? String == "presentation" {
            PlaybackAudioSession.shared.log("NATIVE_SOURCE PiP probe candidates=\(candidates.count) transport=\(media["transport"] as? String ?? "unknown")")
        }
        startIfPossible()
    }

    private func reset(videoID: String) {
        cancel()
        self.videoID = videoID
        pip = false
        expectedDuration = 0
        candidates.removeAll()
        attempted.removeAll()
        foundCompatibleSource = false
    }

    private func cancel(retryInterrupted: Bool = false) {
        if retryInterrupted, let candidate = activeCandidate {
            attempted.remove(candidate)
            PlaybackAudioSession.shared.log("NATIVE_SOURCE interrupted preparation queued for foreground retry")
        }
        activeCandidate = nil
        generation += 1
        task?.cancel()
        task = nil
        asset?.cancelLoading()
        asset = nil
        probePlayer?.replaceCurrentItem(with: nil)
        probePlayer = nil
    }

    private func startIfPossible() {
        guard pip, expectedDuration.isFinite, expectedDuration > 0,
              task == nil, !foundCompatibleSource,
              let url = candidates.first(where: { !attempted.contains($0) }) else { return }
        attempted.insert(url)
        activeCandidate = url
        generation += 1
        let currentGeneration = generation
        let expected = expectedDuration
        // Same device/IP as WebKit. Do not log signed media URLs.
        let source = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                "Referer": "https://www.youtube.com/"
            ]
        ])
        asset = source
        PlaybackAudioSession.shared.log("NATIVE_SOURCE loading stream metadata expectedDuration=\(expected)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == currentGeneration, self.task != nil else { return }
            PlaybackAudioSession.shared.log("NATIVE_SOURCE metadata loading timed out")
            self.cancel()
            self.startIfPossible()
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["YOUTUBE_PREPARATION_RETRY_SMOKE"] == "1",
           !didRunPreparationRetryCheck {
            didRunPreparationRetryCheck = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.generation == currentGeneration, self.task != nil else { return }
                PlaybackAudioSession.shared.log("NATIVE_SOURCE debug interrupt and retry check")
                self.cancel(retryInterrupted: true)
                self.startIfPossible()
            }
        }
        #endif
        task = Task { [weak self] in
            do {
                let playable = try await source.load(.isPlayable)
                let duration = try await source.load(.duration).seconds
                let tracks = try await source.loadTracks(withMediaType: .audio)
                guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
                var verifiedPlayer: AVPlayer?
                var audioTracks = tracks.count
                var videoTracks = try await source.loadTracks(withMediaType: .video).count
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                if url.path.hasPrefix("/api/manifest/hls_") {
                    // HLS tracks are discovered dynamically by the player item;
                    // a ready AVURLAsset may legitimately expose no audio tracks.
                    let item = AVPlayerItem(asset: source)
                    let player = AVPlayer(playerItem: item)
                    self.probePlayer = player
                    // Transfer this verified, paused player on success;
                    // avoid repeating the HLS loading delay with another item.
                    for _ in 0..<40 {
                        if item.status != .unknown { break }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard !Task.isCancelled, self.generation == currentGeneration else { return }
                    let itemAudio = item.tracks.filter { $0.assetTrack?.mediaType == .audio }.count
                    let itemVideo = item.tracks.filter { $0.assetTrack?.mediaType == .video }.count
                    let itemError = item.error as NSError?
                    PlaybackAudioSession.shared.log("NATIVE_SOURCE HLS playerItem status=\(item.status.rawValue) audioTracks=\(itemAudio) videoTracks=\(itemVideo) duration=\(item.duration.seconds) errorDomain=\(itemError?.domain ?? "none") errorCode=\(itemError?.code ?? 0)")
                    audioTracks = max(audioTracks, itemAudio)
                    if item.status == .readyToPlay { videoTracks = max(videoTracks, itemVideo) }
                    for event in item.errorLog()?.events.suffix(3) ?? [] {
                        PlaybackAudioSession.shared.log("NATIVE_SOURCE HLS error status=\(event.errorStatusCode) domain=\(event.errorDomain)")
                    }
                    if item.status == .readyToPlay && itemAudio > 0 && itemVideo > 0 {
                        verifiedPlayer = player
                    } else {
                        player.replaceCurrentItem(with: nil)
                    }
                    self.probePlayer = nil
                }
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                let compatible = playable && audioTracks > 0 && videoTracks > 0 && duration.isFinite &&
                    abs(duration - expected) < 3
                self.foundCompatibleSource = compatible
                PlaybackAudioSession.shared.log("NATIVE_SOURCE metadata compatible=\(compatible) playable=\(playable) duration=\(duration) expected=\(expected) audioTracks=\(audioTracks)")
                self.task = nil
                self.asset = nil
                self.activeCandidate = nil
                if compatible {
                    self.onCompatible?(self.videoID, source, verifiedPlayer)
                } else {
                    verifiedPlayer?.replaceCurrentItem(with: nil)
                }
                self.startIfPossible()
            } catch {
                guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
                let value = error as NSError
                self.probePlayer?.replaceCurrentItem(with: nil)
                self.probePlayer = nil
                PlaybackAudioSession.shared.log("NATIVE_SOURCE load failed domain=\(value.domain) code=\(value.code)")
                self.task = nil
                self.asset = nil
                self.activeCandidate = nil
                self.startIfPossible()
            }
        }
    }
}


/// Native PiP owns the actual audio/video and its remote-command session.
/// WebKit is paused before the handoff; it is restored only on PiP return.
private final class NativePlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private var audioPauseButton: UIButton?

    func configureAudioControls(onToggle: @escaping () -> Void, onReturn: @escaping () -> Void) {
        let pause = UIButton(type: .system)
        let back = UIButton(type: .system)
        for button in [pause, back] {
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.7)
            config.baseForegroundColor = .white
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            button.configuration = config
        }
        pause.setTitle("暂停", for: .normal)
        pause.accessibilityLabel = "后台音频播放或暂停"
        back.setTitle("返回网页", for: .normal)
        pause.addAction(UIAction { _ in onToggle() }, for: .touchUpInside)
        back.addAction(UIAction { _ in onReturn() }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [pause, back])
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])
        audioPauseButton = pause
    }

    func updateAudioControls(playing: Bool) {
        audioPauseButton?.setTitle(playing ? "暂停" : "播放", for: .normal)
    }
}

/// Retry only the still-current user request, once, before any real progress.
enum NativeResumeRecovery {
    static func shouldRetry(wantsPlaying: Bool, ready: Bool, ended: Bool, delta: Double, attempt: Int) -> Bool {
        wantsPlaying && ready && !ended && delta.isFinite && delta <= 0.1 && attempt == 0
    }
}

@MainActor
final class NativePiPPlayback: NSObject, AVPictureInPictureControllerDelegate {
    weak var webView: WKWebView?
    var onError: ((String) -> Void)?
    var onReady: ((String) -> Void)?
    private(set) var ownsPlayback = false
    private enum Mode: String { case pip, audio }
    private var mode: Mode = .pip
    private var handoffCompleted = false
    private var automaticHandoff = false
    private var automaticCancellationRequested = false
    private var automaticStartupPending = false
    private var handoffTime: Double?
    private var audioActivated = false
    private var handoffTask: UIBackgroundTaskIdentifier = .invalid
    private var deferredRestoreScript: String?
    private var lastPrimeAt = Date.distantPast
    private var automaticSuppressedVideoID = ""
    private var automaticRetryAfter = Date.distantPast
    private var videoID = ""
    private var asset: AVURLAsset?
    private var player: AVPlayer?
    private var surface: NativePlayerSurface?
    private var pipController: AVPictureInPictureController?
    private var session: MPNowPlayingSession?
    private var itemObservation: NSKeyValueObservation?
    private var stateObservation: NSKeyValueObservation?
    private var pipObservation: NSKeyValueObservation?
    private var displayObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var pendingRequest: [String: Any]?
    private var generation = 0
    private var preparationGeneration = 0
    private var wantsPlaying = true
    private var restoreRequested = false
    private var isStoppingPiP = false
    private var didRequestPiP = false
    private var lastProgressLog = Date.distantPast
    private var resumeAfterInterruption = false
    private var resumeGeneration = 0
    private var resumePending = false
    private var resumeTask: UIBackgroundTaskIdentifier = .invalid

    func prepare(videoID: String, asset: AVURLAsset, verifiedPlayer: AVPlayer? = nil) {
        guard !ownsPlayback else { return }
        if self.videoID == videoID, self.asset === asset, player != nil { return }
        preparationGeneration += 1
        let token = preparationGeneration
        itemObservation?.invalidate()
        player?.replaceCurrentItem(with: nil)
        self.videoID = videoID
        self.asset = asset
        let player = verifiedPlayer ?? AVPlayer(playerItem: AVPlayerItem(asset: asset))
        guard let item = player.currentItem else { return }
        self.player = player
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, self.preparationGeneration == token else { return }
                if item.status == .readyToPlay {
                    self.log("prepared video=\(videoID) audioTracks=\(item.tracks.filter { $0.assetTrack?.mediaType == .audio }.count) videoTracks=\(item.tracks.filter { $0.assetTrack?.mediaType == .video }.count)")
                    if let request = self.pendingRequest, request["videoID"] as? String == videoID {
                        self.pendingRequest = nil
                        self.begin(request)
                    }
                    self.onReady?(videoID)
                } else if item.status == .failed {
                    let error = item.error as NSError?
                    self.log("prepare failed domain=\(error?.domain ?? "none") code=\(error?.code ?? 0)")
                    if self.pendingRequest != nil {
                        self.pendingRequest = nil
                        self.fail("这段视频暂时无法交给原生播放器，请稍后重试。")
                    }
                }
            }
        }
    }

    func request(_ state: [String: Any]) {
        guard !ownsPlayback, UIApplication.shared.applicationState == .active,
              let id = state["videoID"] as? String, !id.isEmpty,
              !(state["ad"] as? Bool ?? false) else { return }
        if id == videoID, player?.currentItem?.status == .readyToPlay {
            begin(state)
            return
        }
        pendingRequest = state
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.generation == token, self.pendingRequest != nil else { return }
            self.pendingRequest = nil
            self.fail("原生播放准备超时，请稍后重试。")
        }
    }

    /// Pre-seek only while foreground; never start a second audible player.
    func primeAudioPosition(_ state: [String: Any]) {
        guard !ownsPlayback, pendingRequest == nil,
              UIApplication.shared.applicationState == .active,
              state["videoID"] as? String == videoID,
              !(state["ad"] as? Bool ?? true), !(state["paused"] as? Bool ?? true),
              let time = state["currentTime"] as? Double, time.isFinite, time >= 0,
              let player, player.currentItem?.status == .readyToPlay,
              Date().timeIntervalSince(lastPrimeAt) >= 5 else { return }
        lastPrimeAt = Date()
        if abs(player.currentTime().seconds - time) > 3 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                        toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                        toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
        }
    }

    func requestAutomatic(_ state: [String: Any], foreground: Bool = false) {
        if foreground && (automaticSuppressedVideoID == videoID || Date() < automaticRetryAfter) { return }
        guard !ownsPlayback, pendingRequest == nil else {
            log("AUTO_HANDOFF skipped native owner or manual request")
            return
        }
        guard UIApplication.shared.applicationState != .background,
              state["videoID"] as? String == videoID, !videoID.isEmpty,
              !(state["ad"] as? Bool ?? true),
              !(state["paused"] as? Bool ?? true),
              !(state["ended"] as? Bool ?? true) else {
            log("AUTO_HANDOFF skipped cached content not playing")
            return
        }
        guard player?.currentItem?.status == .readyToPlay else {
            log("AUTO_HANDOFF skipped native source not ready")
            return
        }
        log("AUTO_HANDOFF trigger foreground=\(foreground) appState=\(UIApplication.shared.applicationState.rawValue)")
        begin(state, automatic: true)
    }

    func applicationBecameActive() {
        if automaticHandoff && ownsPlayback {
            if handoffCompleted {
                // Keep native ownership across unlock instead of another WebKit handoff.
                updateAudioPresentation(background: false)
                log("AUTO_HANDOFF retained native playback on foreground")
            } else {
                // Wait for the atomic page snapshot before restoring its position.
                automaticCancellationRequested = true
                log("AUTO_HANDOFF foreground cancellation requested")
            }
        }
        if let script = deferredRestoreScript {
            deferredRestoreScript = nil
            webView?.evaluateJavaScript(script)
            log("AUTO_HANDOFF deferred webpage restoration")
        }
    }

    private func endHandoffTask() {
        automaticStartupPending = false
        guard handoffTask != .invalid else { return }
        let task = handoffTask
        handoffTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    func navigationWillChange() {
        pendingRequest = nil
        deferredRestoreScript = nil
        automaticSuppressedVideoID = ""
        automaticRetryAfter = .distantPast
        lastPrimeAt = .distantPast
        preparationGeneration += 1
        if ownsPlayback {
            pipController?.delegate = nil
            pipController?.stopPictureInPicture()
            finish(restorePlaying: false)
        }
        deferredRestoreScript = nil
        itemObservation?.invalidate()
        itemObservation = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        asset = nil
        videoID = ""
        generation += 1
    }

    private func begin(_ state: [String: Any], automatic: Bool = false) {
        let requestedMode: Mode = automatic || state["playbackMode"] as? String == "audio" ? .audio : .pip
        guard !ownsPlayback, let webView, let player,
              state["videoID"] as? String == videoID,
              player.currentItem?.status == .readyToPlay,
              (requestedMode == .audio || AVPictureInPictureController.isPictureInPictureSupported()),
              (UIApplication.shared.applicationState == .active ||
               (automatic && UIApplication.shared.applicationState == .inactive)) else {
            fail("当前无法开始原生播放，请稍后重试。")
            return
        }
        mode = requestedMode
        automaticHandoff = automatic
        automaticCancellationRequested = false
        handoffTime = nil
        audioActivated = false
        deferredRestoreScript = nil
        handoffCompleted = false
        ownsPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = mode == .audio ? .continuesIfPossible : .automatic
        log("handoff requested mode=\(mode.rawValue) automatic=\(automatic)")
        generation += 1
        let token = generation
        restoreRequested = false
        isStoppingPiP = false
        didRequestPiP = false
        let id = videoID
        let quotedID = quote(id)
        if automatic {
            automaticStartupPending = true
            handoffTask = UIApplication.shared.beginBackgroundTask(withName: "NativePlaybackHandoff") { [weak self] in
                guard let self, self.generation == token, self.ownsPlayback else { return }
                self.log("AUTO_HANDOFF task expired")
                self.finish(restorePlaying: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.generation == token, self.ownsPlayback,
                      self.automaticStartupPending else { return }
                self.log("AUTO_HANDOFF timed out; restore on foreground")
                self.finish(restorePlaying: self.handoffTime == nil || self.wantsPlaying)
            }
        }
        // For automatic handoff, the page must still be playing this exact source.
        // The URL is passed only in memory, never to diagnostics.
        let sourceArgument = automatic ? ", \(quote(asset?.url.absoluteString ?? ""))" : ""
        webView.evaluateJavaScript("window.__rayPauseForNativePiP?.(\(quotedID)\(sourceArgument))") { [weak self] result, error in
            guard let self, self.generation == token, self.ownsPlayback else { return }
            guard error == nil, let snapshot = result as? [String: Any],
                  snapshot["videoID"] as? String == id,
                  let time = snapshot["currentTime"] as? Double, time.isFinite,
                  snapshot["paused"] as? Bool == true,
                  (!automatic || snapshot["wasPlaying"] as? Bool == true),
                  (automatic || UIApplication.shared.applicationState == .active) else {
                self.log("AUTO_HANDOFF snapshot rejected automatic=\(automatic)")
                self.finish(restorePlaying: automatic)
                if !automatic { self.fail("播放状态已改变，请重新开始。") }
                return
            }
            self.wantsPlaying = snapshot["wasPlaying"] as? Bool ?? true
            self.handoffTime = time
            if automatic && self.automaticCancellationRequested {
                self.finish(restorePlaying: self.wantsPlaying)
                return
            }
            let view = NativePlayerSurface()
            view.backgroundColor = .black
            view.playerLayer.videoGravity = .resizeAspect
            view.playerLayer.player = player
            let bounds = webView.bounds
            if let rect = state["rect"] as? [String: Double],
               let x = rect["x"], let y = rect["y"], let w = rect["width"], let h = rect["height"],
               [x,y,w,h].allSatisfy({ $0.isFinite }), w > 0, h > 0 {
                let proposed = CGRect(x: x * bounds.width, y: y * bounds.height,
                                      width: w * bounds.width, height: h * bounds.height)
                let clipped = proposed.intersection(bounds)
                view.frame = clipped.isNull || clipped.width < 20 || clipped.height < 20
                    ? CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width * 9 / 16) : clipped
            } else {
                view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.width * 9 / 16)
            }
            webView.addSubview(view)
            self.surface = view
            if self.mode == .audio && UIApplication.shared.applicationState != .active {
                self.updateAudioPresentation(background: true)
            }
            if self.mode == .pip {
                guard let pip = AVPictureInPictureController(playerLayer: view.playerLayer) else {
                    self.finish(restorePlaying: self.wantsPlaying)
                    self.fail("当前设备无法启动画中画。")
                    return
                }
                self.pipController = pip
                pip.delegate = self
                pip.canStartPictureInPictureAutomaticallyFromInline = false
                self.pipObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.tryStartPiP(token: token) }
                }
                self.displayObservation = view.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.tryStartPiP(token: token) }
                }
            } else {
                view.configureAudioControls(onToggle: { [weak self] in self?.command("toggle") },
                                            onReturn: { [weak self] in
                    guard let self, self.ownsPlayback, self.mode == .audio else { return }
                    self.automaticSuppressedVideoID = self.videoID
                    self.finish(restorePlaying: self.wantsPlaying)
                })
            }
            do {
                // WebKit has really paused. Automatic handoff races the background
                // transition: log and roll back if iOS denies activation.
                try AVAudioSession.sharedInstance().setActive(true)
                self.audioActivated = true
                self.log("handoff audio activated appState=\(UIApplication.shared.applicationState.rawValue)")
            } catch {
                let value = error as NSError
                self.log("handoff audio activation failed domain=\(value.domain) code=\(value.code)")
                self.finish(restorePlaying: self.wantsPlaying)
                if !automatic { self.fail("原生音频初始化失败，请重试。") }
                return
            }
            self.installSession(state, player: player)
            self.stateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.ownsPlayback else { return }
                    self.log("state=\(player.timeControlStatus.rawValue) rate=\(player.rate) time=\(player.currentTime().seconds)")
                    if self.handoffCompleted &&
                        (self.mode == .audio || self.pipController?.isPictureInPictureActive == true) &&
                        !self.isStoppingPiP {
                        if player.timeControlStatus == .paused && !self.resumePending { self.wantsPlaying = false }
                        if player.timeControlStatus == .playing { self.wantsPlaying = true }
                    }
                    self.surface?.updateAudioControls(playing: self.wantsPlaying)
                    if player.timeControlStatus == .playing {
                        self.activateSession()
                        if self.handoffCompleted { self.endHandoffTask() }
                    }
                }
            }
            self.timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
                DispatchQueue.main.async {
                    guard let self, self.ownsPlayback, self.generation == token else { return }
                    PlaybackAudioSession.shared.update(playing: player.timeControlStatus == .playing,
                                                       pip: self.pipController?.isPictureInPictureActive ?? false)
                    if Date().timeIntervalSince(self.lastProgressLog) >= 15 {
                        self.lastProgressLog = Date()
                        self.log("progress time=\(time.seconds) state=\(player.timeControlStatus.rawValue) sessionActive=\(self.session?.isActive ?? false) pipActive=\(self.pipController?.isPictureInPictureActive ?? false) appState=\(UIApplication.shared.applicationState.rawValue)")
                    }
                }
            }
            player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                DispatchQueue.main.async {
                    guard let self, self.generation == token, self.ownsPlayback else { return }
                    guard completed else {
                        self.finish(restorePlaying: self.wantsPlaying)
                        if !automatic { self.fail("原生播放定位失败，请重试。") }
                        return
                    }
                    self.handoffCompleted = true
                    if self.wantsPlaying { player.play() }
                    self.surface?.updateAudioControls(playing: self.wantsPlaying)
                    self.activateSession()
                    if self.mode == .pip {
                        self.tryStartPiP(token: token)
                    } else {
                        self.log("audio handoff complete pipControllerPresent=\(self.pipController != nil) playingRequested=\(self.wantsPlaying) automatic=\(automatic)")
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.generation == token, self.ownsPlayback, self.mode == .pip,
                      !(self.pipController?.isPictureInPictureActive ?? false) else { return }
                self.log("PiP start timed out")
                self.finish(restorePlaying: self.wantsPlaying)
                self.fail("画中画启动超时，已返回网页播放。")
            }
        }
    }

    private func tryStartPiP(token: Int) {
        guard generation == token, ownsPlayback, mode == .pip, !didRequestPiP,
              UIApplication.shared.applicationState == .active,
              let pipController, pipController.isPictureInPicturePossible,
              surface?.playerLayer.isReadyForDisplay == true else { return }
        didRequestPiP = true
        log("starting native PiP")
        pipController.startPictureInPicture()
    }

    private func updateAudioPresentation(background: Bool) {
        guard ownsPlayback, mode == .audio, let surface else { return }
        surface.playerLayer.player = background ? nil : player
        log("audio presentation attached=\(!background) appState=\(UIApplication.shared.applicationState.rawValue)")
    }

    private func installSession(_ state: [String: Any], player: AVPlayer) {
        player.currentItem?.nowPlayingInfo = [
            MPMediaItemPropertyTitle: state["title"] as? String ?? "YouTube Desktop",
            MPMediaItemPropertyArtist: state["artist"] as? String ?? ""
        ]
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        self.session = session
        let center = session.remoteCommandCenter
        for (command, action) in [(center.playCommand, "play"), (center.pauseCommand, "pause"),
                                  (center.togglePlayPauseCommand, "toggle")] {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                PlaybackAudioSession.shared.log("REMOTE_NATIVE received \(action) mainThread=\(Thread.isMainThread)")
                DispatchQueue.main.async { self.command(action) }
                return .success
            }
            commandTargets.append((command, target))
        }
        center.changePlaybackPositionCommand.isEnabled = true
        let seekTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent,
                  event.positionTime.isFinite else { return .commandFailed }
            DispatchQueue.main.async {
                guard self.ownsPlayback else { return }
                self.cancelResumeRequest()
                self.player?.seek(to: CMTime(seconds: max(0, event.positionTime), preferredTimescale: 600))
            }
            return .success
        }
        commandTargets.append((center.changePlaybackPositionCommand, seekTarget))
        let notifications = NotificationCenter.default
        if mode == .audio {
            notificationObservers.append(notifications.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateAudioPresentation(background: true) }
            })
            notificationObservers.append(notifications.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                   object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.updateAudioPresentation(background: false) }
            })
        }
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            DispatchQueue.main.async {
                guard let self, self.ownsPlayback,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.cancelResumeRequest()
                self.resumeAfterInterruption = false
                self.wantsPlaying = false
                self.player?.pause()
                self.log("paused after audio device disconnected")
            }
        })
        notificationObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                               object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            DispatchQueue.main.async {
                guard let self, self.ownsPlayback else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = self.wantsPlaying
                    self.cancelResumeRequest()
                    self.wantsPlaying = false
                    self.player?.pause()
                } else if self.resumeAfterInterruption &&
                    options & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0 {
                    self.command("play")
                }
            }
        })
    }

    private func activateSession() {
        guard ownsPlayback, let session, !session.isActive else { return }
        let token = generation
        session.becomeActiveIfPossible { [weak self] active in
            DispatchQueue.main.async {
                guard let self, self.generation == token, self.ownsPlayback else { return }
                self.log("NowPlaying active=\(active) canBecomeActive=\(session.canBecomeActive)")
            }
        }
    }

    private func command(_ action: String) {
        guard ownsPlayback, let player else { return }
        let play = action == "play" || (action == "toggle" && !wantsPlaying)
        cancelResumeRequest()
        resumeAfterInterruption = false
        wantsPlaying = play
        let start = player.currentTime().seconds
        log("command \(action) targetPlaying=\(play) time=\(start)")
        surface?.updateAudioControls(playing: wantsPlaying)
        guard play else {
            player.pause()
            return
        }

        // A remote command can arrive after iOS has suspended paused audio.
        // Protect only this bounded request, never the whole paused interval.
        resumePending = true
        let token = generation
        let request = resumeGeneration
        resumeTask = UIApplication.shared.beginBackgroundTask(withName: "NativePlaybackResume") { [weak self] in
            guard let self, self.resumeGeneration == request else { return }
            self.log("resume task expired")
            self.cancelResumeRequest()
        }
        activateAudioForResume()
        activateSession()
        startRequestedPlayback(player)
        logResumeState(player, phase: "requested")
        checkResume(player, start: start, token: token, request: request, attempt: 0)
    }

    private func cancelResumeRequest() {
        resumeGeneration += 1
        resumePending = false
        guard resumeTask != .invalid else { return }
        let task = resumeTask
        resumeTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func activateAudioForResume() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            audioActivated = true
            log("resume audio activated appState=\(UIApplication.shared.applicationState.rawValue)")
        } catch {
            let error = error as NSError
            log("resume audio activation failed domain=\(error.domain) code=\(error.code)")
        }
    }

    private func startRequestedPlayback(_ player: AVPlayer) {
        // Bypass the HLS stall prediction only when media is actually buffered.
        // Keep AVPlayer's normal loading behavior when the buffer is empty.
        if player.currentItem?.isPlaybackBufferEmpty == false {
            player.playImmediately(atRate: 1)
        } else {
            player.play()
        }
    }

    private func logResumeState(_ player: AVPlayer, phase: String) {
        let item = player.currentItem
        log("resume \(phase) state=\(player.timeControlStatus.rawValue) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "none") itemStatus=\(item?.status.rawValue ?? -1) bufferEmpty=\(item?.isPlaybackBufferEmpty ?? true) likelyToKeepUp=\(item?.isPlaybackLikelyToKeepUp ?? false)")
    }

    private func checkResume(_ player: AVPlayer, start: Double, token: Int, request: Int, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == token, self.resumeGeneration == request,
                  self.ownsPlayback, self.wantsPlaying, self.player === player else { return }
            let delta = player.currentTime().seconds - start
            let verified = delta.isFinite && delta > 0.1 && player.timeControlStatus == .playing
            self.log("resume verified=\(verified) delta=\(delta) state=\(player.timeControlStatus.rawValue) attempt=\(attempt)")
            self.logResumeState(player, phase: "checked")
            if NativeResumeRecovery.shouldRetry(wantsPlaying: self.wantsPlaying,
                                                ready: player.currentItem?.status == .readyToPlay,
                                                ended: self.hasReachedEnd(player),
                                                delta: delta, attempt: attempt) {
                self.log("resume retry within same play request")
                self.activateAudioForResume()
                self.startRequestedPlayback(player)
                self.checkResume(player, start: start, token: token, request: request, attempt: attempt + 1)
            } else {
                self.cancelResumeRequest()
            }
        }
    }

    private func hasReachedEnd(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem else { return true }
        let duration = item.duration.seconds
        let time = player.currentTime().seconds
        return duration.isFinite && duration > 0 && time.isFinite && time >= duration - 0.05
    }

    private func finish(restorePlaying: Bool) {
        cancelResumeRequest()
        generation += 1
        let id = videoID
        let elapsed = handoffCompleted ? player?.currentTime().seconds : handoffTime
        let wasAutomatic = automaticHandoff
        if wasAutomatic { automaticRetryAfter = Date().addingTimeInterval(15) }
        endHandoffTask()
        ownsPlayback = false
        handoffCompleted = false
        player?.pause()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        stateObservation?.invalidate(); stateObservation = nil
        pipObservation?.invalidate(); pipObservation = nil
        displayObservation?.invalidate(); displayObservation = nil
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        session?.automaticallyPublishesNowPlayingInfo = false
        session?.nowPlayingInfoCenter.nowPlayingInfo = nil
        session = nil
        pipController?.delegate = nil
        pipController = nil
        surface?.playerLayer.player = nil
        surface?.removeFromSuperview()
        surface = nil
        if audioActivated {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        audioActivated = false
        PlaybackAudioSession.shared.update(playing: false, pip: false)
        let timeArgument = elapsed?.isFinite == true ? String(max(0, elapsed!)) :
            "(window.__rayNativePiPVideo?.currentTime || 0)"
        let script = "window.__rayRestoreAfterNativePiP?.(\(quote(id)), \(timeArgument), \(restorePlaying ? "true" : "false"))"
        if wasAutomatic && UIApplication.shared.applicationState != .active {
            deferredRestoreScript = script
            log("AUTO_HANDOFF restoration deferred until foreground")
        } else {
            webView?.evaluateJavaScript(script)
        }
        automaticHandoff = false
        handoffTime = nil
        log("returned to WebKit time=\(elapsed ?? -1) playing=\(restorePlaying)")
    }

    private func fail(_ message: String) {
        webView?.evaluateJavaScript("window.__rayResetPiPButton?.()")
        onError?(message)
    }

    private func quote(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [value]), encoding: .utf8)!
            .dropFirst().dropLast().description
    }

    private func log(_ message: String) { PlaybackAudioSession.shared.log("NATIVE_PLAYBACK mode=\(mode.rawValue) \(message)") }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pipController.map({ ObjectIdentifier($0) }) == controllerID else { return }
            self.log("PiP active=true sessionActive=\(self.session?.isActive ?? false)")
            self.activateSession()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pipController.map({ ObjectIdentifier($0) }) == controllerID else { return }
            let value = error as NSError
            self.log("PiP failed domain=\(value.domain) code=\(value.code)")
            self.finish(restorePlaying: self.wantsPlaying)
            self.fail("画中画启动失败，已返回网页播放。")
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pipController.map({ ObjectIdentifier($0) }) == controllerID else {
                completionHandler(false)
                return
            }
            self.restoreRequested = true
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pipController.map({ ObjectIdentifier($0) }) == controllerID else { return }
            self.finish(restorePlaying: self.restoreRequested && self.wantsPlaying && UIApplication.shared.applicationState == .active)
        }
    }
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pipController.map({ ObjectIdentifier($0) }) == controllerID else { return }
            self.isStoppingPiP = true
        }
    }
}

/// Audio configuration and playback diagnostics for the active playback owner.
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()
    private let audio = AVAudioSession.sharedInstance()
    private var observers: [NSObjectProtocol] = []
    private var playing = false
    private var pip = false
    private let logLock = NSLock()

    func start() {
        configure()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: audio, queue: .main) { [weak self] note in
            guard let self else { return }
            let info = note.userInfo ?? [:]
            let rawType = (info[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? NSNumber)?.uintValue ?? 0
            let options = (info[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            self.log("interruption type=\(rawType) reason=\(reason) options=\(options) playing=\(self.playing) pip=\(self.pip)")
            // WebKit/GPU owns the active audio session; observing this process's
            // interruption is diagnostic only. Never compete with it via setActive.
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: audio, queue: .main) { [weak self] note in
            self?.log("route changed reason=\(String(describing: note.userInfo?[AVAudioSessionRouteChangeReasonKey])) route=\(self?.route ?? "")")
            // WebKit owns disconnect pausing. Do not force playback onto the speaker.
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: audio, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.log("media services reset")
            self.configure()
        })
        log("launched version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") build=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")")
    }

    func update(playing: Bool, pip: Bool) {
        self.playing = playing
        self.pip = pip
    }

    func foreground() {
        log("will enter foreground playing=\(playing) pip=\(pip)")
    }

    private var route: String {
        audio.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
    }

    private func configure() {
        do {
            try audio.setCategory(.playback, mode: .moviePlayback)
            log("audio category configured")
        } catch {
            log("audio configuration failed: \(error)")
        }
    }

    func log(_ message: String) {
        logLock.lock()
        defer { logLock.unlock() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        print("[YouTubeDesktop][Playback] \(message)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playback.log")
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 512 * 1024 {
                let previous = url.appendingPathExtension("previous")
                if FileManager.default.fileExists(atPath: previous.path) {
                    try FileManager.default.removeItem(at: previous)
                }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                // This log must remain writable while the device is locked.
                try data.write(to: url, options: [.atomic, .noFileProtection])
            } else {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            print("[YouTubeDesktop][Playback] log failed: \(error)")
        }
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PlaybackAudioSession.shared.start()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        (window?.rootViewController as? ViewController)?.applicationWillResignActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        PlaybackAudioSession.shared.log("did enter background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        PlaybackAudioSession.shared.foreground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        PlaybackAudioSession.shared.log("did become active")
        (window?.rootViewController as? ViewController)?.applicationBecameActive()
    }
}
