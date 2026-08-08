import AVFoundation

/// Port of `sound.js`.
///
/// The JS has two backends — Web Audio in the browser and the Capacitor `NativeAudio` plugin
/// on device — and the native app replaces both with one `AVAudioEngine` graph. The shape of
/// the API is kept: a looping *background* track with a settable volume, and pooled one-shots
/// that return a handle with `pause` / `fadeOut` / `setRate`.
///
/// `setRate` maps to `AVAudioUnitVarispeed`, which shifts pitch along with speed exactly the
/// way Web Audio's `playbackRate` does — the running footsteps are meant to sound faster
/// *and* higher.
final class SoundManager {

    /// One playing sound. Mirrors the object `playPooled` returns in `sound.js:129-161`.
    final class Handle {
        fileprivate weak var manager: SoundManager?
        fileprivate let player = AVAudioPlayerNode()
        fileprivate let varispeed = AVAudioUnitVarispeed()
        fileprivate var attached = false
        fileprivate var volume: Float = 1
        fileprivate var fadeTimer: Timer?

        /// What this handle is playing, kept so the graph can be rebuilt from scratch when the
        /// system reconfigures the audio route out from under it.
        fileprivate var buffer: AVAudioPCMBuffer?
        fileprivate var loops = false

        /// True once the caller has asked for this to stop; a buffer that is still loading
        /// checks it before starting.
        private(set) var stopped = false

        fileprivate init(manager: SoundManager) {
            self.manager = manager
        }

        func pause() {
            stopped = true
            manager?.tearDown(self)
        }

        /// Ramps to silence and then stops, the way the Web Audio path does with a gain
        /// ramp. The Capacitor path could not fade and simply stopped early.
        func fadeOut(durationMs: Double = 500) {
            guard !stopped else { return }
            stopped = true
            guard attached, let manager else { return }

            let steps = max(1, Int(durationMs / 25))
            var step = 0
            let start = player.volume
            fadeTimer?.invalidate()
            fadeTimer = Timer.scheduledTimer(withTimeInterval: durationMs / 1000 / Double(steps),
                                             repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                step += 1
                self.player.volume = start * Float(1 - Double(step) / Double(steps))
                if step >= steps {
                    timer.invalidate()
                    manager.tearDown(self)
                }
            }
        }

        func setRate(_ rate: Double) {
            varispeed.rate = Float(max(0.25, min(4, rate)))
        }
    }

    private let engine = AVAudioEngine()
    private var sessionActive = false

    /// Set whenever something outside this class can have taken the output away — an
    /// interruption, a route change, a trip through the background, a media services reset.
    ///
    /// It exists because neither `AVAudioSession` nor `AVAudioEngine` will admit to it: the
    /// session reports itself active and the engine reports `isRunning` while the IO it was
    /// rendering into is long gone. `play()` on a player node in that state raises
    /// `player did not see an IO cycle` and takes the process with it, so the next sound
    /// stops the engine outright and builds the graph again from a state we know.
    private var needsRestart = true

    /// Decoded PCM keyed by asset path, so the same splash costs one download and one decode.
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var pendingLoads: [String: [(AVAudioPCMBuffer?) -> Void]] = [:]
    private var failed: Set<String> = []

    /// Everything currently making noise, so a map change can silence the lot.
    private var active: [Handle] = []

    private var background: Handle?
    private var currentBackgroundPath: String?

    private let decodeQueue = DispatchQueue(label: "com.allr.joelsworld.audio", qos: .userInitiated)

    /// Session calls run here rather than on the main thread. `setCategory` and `setActive` are
    /// round trips to the audio server, not property sets, and `AVAudioSession` logs
    /// *"This method can lead to UI unresponsiveness if called on the main thread"* for the
    /// activation. On a game that is a dropped frame at the worst possible moment.
    private let sessionQueue = DispatchQueue(label: "com.allr.joelsworld.audio.session")

    /// Bumped whenever the session is deliberately given up, so an activation that was already
    /// in flight cannot come back and report an active session that is no longer wanted.
    private var sessionGeneration = 0

    init() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(configurationChanged),
                           name: .AVAudioEngineConfigurationChange, object: engine)

        // There is no `AVAudioSession` on the Mac — a Mac app does not share one output with a
        // phone call, and nothing takes the engine away mid-note. `AVAudioEngine` itself, the
        // graph, the buffers and the pooling are all the same on both, which is what lets the
        // map editor play the map's music without a second sound stack.
#if os(iOS)
        center.addObserver(self, selector: #selector(sessionInterrupted),
                           name: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance())
        center.addObserver(self, selector: #selector(mediaServicesReset),
                           name: AVAudioSession.mediaServicesWereResetNotification,
                           object: AVAudioSession.sharedInstance())
#endif

        // Warmed now rather than on the first sound. Every sound has a fetch and a decode in
        // front of it, so the session is up long before anything needs it and the synchronous
        // fallback in `activateSession()` never has to run on the main thread.
        primeSession()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Playback

    /// A one-shot (or looping) effect. Port of `playPooled` (`sound.js:88`).
    @discardableResult
    func playPooled(_ path: String, volume: Double = 1, loop: Bool = false) -> Handle {
        let handle = Handle(manager: self)
        handle.volume = Float(max(0, volume))

        load(path: path) { [weak self, weak handle] buffer in
            guard let self, let handle, !handle.stopped, let buffer else { return }
            self.start(handle: handle, buffer: buffer, loop: loop)
        }

        return handle
    }

    /// The map's looping music. Re-issuing the same path only changes the volume, so an
    /// `on_enter` that fires twice does not restart the track (`sound.js:181`).
    func playBackground(_ path: String, volume: Double = 1) {
        if currentBackgroundPath == path, let background {
            background.volume = Float(max(0, volume))
            background.player.volume = background.volume
            return
        }

        stopBackground()
        currentBackgroundPath = path
        background = playPooled(path, volume: volume, loop: true)
    }

    func stopBackground() {
        background?.pause()
        background = nil
        currentBackgroundPath = nil
    }

    /// Stops everything — used when the app goes to the background.
    ///
    /// The engine goes down with the sounds. A suspended app has its session deactivated for
    /// it, and an engine left "running" against that dead session is precisely what kills the
    /// first sound played on the way back in.
    func stopAll() {
        for handle in active { handle.pause() }
        background = nil
        currentBackgroundPath = nil

        engine.stop()
        sessionActive = false
        sessionGeneration &+= 1
        needsRestart = true
    }

    /// Coming back from the background, where `stopAll` gave the session up. Warming it here
    /// keeps the activation off the main thread and off the first sound after the switch.
    func resumeSession() {
        primeSession()
    }

    // MARK: - Engine

    private func start(handle: Handle, buffer: AVAudioPCMBuffer, loop: Bool) {
        if needsRestart {
            needsRestart = false
            engine.stop()
        }
        guard activateSession() else {
            // No session, no IO cycle. Better a silent sound than a dead process.
            return
        }

        engine.attach(handle.player)
        engine.attach(handle.varispeed)
        engine.connect(handle.player, to: handle.varispeed, format: buffer.format)
        engine.connect(handle.varispeed, to: engine.mainMixerNode, format: buffer.format)
        handle.attached = true
        handle.player.volume = handle.volume
        handle.buffer = buffer
        handle.loops = loop
        active.append(handle)

        // The engine is started *after* the first player is wired up. Starting (or preparing)
        // an engine whose graph is still empty raises `required condition is false: NULL !=
        // engine` and aborts the process.
        if !engine.isRunning {
            do {
                try engine.start()
                Log.world("Audio engine running at \(Int(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate)) Hz")
            } catch {
                Log.world("Audio engine failed to start: \(error.localizedDescription)")
                tearDown(handle)
                return
            }
        }

        // `play()` aborts the process rather than throwing if the engine is not rendering, so
        // this is the last chance to back out.
        guard engine.isRunning else {
            Log.world("Audio engine is not running; dropping the sound")
            needsRestart = true
            tearDown(handle)
            return
        }

        if loop {
            handle.player.scheduleBuffer(buffer, at: nil, options: .loops)
        } else {
            handle.player.scheduleBuffer(buffer, at: nil) { [weak self, weak handle] in
                // Completion fires on an audio thread; teardown touches the engine graph.
                DispatchQueue.main.async {
                    guard let self, let handle else { return }
                    self.tearDown(handle)
                }
            }
        }
        handle.player.play()
    }

    private func tearDown(_ handle: Handle) {
        handle.fadeTimer?.invalidate()
        handle.fadeTimer = nil
        guard handle.attached else { return }
        handle.attached = false
        handle.player.stop()
        engine.detach(handle.player)
        engine.detach(handle.varispeed)
        active.removeAll { $0 === handle }
    }

    // MARK: - Route changes

    /// The system reconfigured the engine — most often because something else on the device
    /// wanted the output. Raising the keyboard is one of those: the keyboard's click sounds
    /// join the route and the hardware format is renegotiated.
    ///
    /// `AVAudioEngine` stops itself and drops its connections when this fires. Nodes that were
    /// left `play()`ing carry on rendering into the dead graph, which is what players hear as
    /// a crackle, so the graph has to be built again rather than merely restarted.
    @objc private func configurationChanged(_ notification: Notification) {
        // Flagged here rather than in the hop below: a sound started in between would see an
        // engine that still claims to be running and play into nothing.
        needsRestart = true

        // Posted from an audio thread; the graph is main-thread work.
        DispatchQueue.main.async { [weak self] in
            Log.world("Audio route reconfigured — rebuilding the engine graph")
            self?.rebuildGraph()
        }
    }

#if os(iOS)
    @objc private func sessionInterrupted(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // The session is gone; so is the engine. Drop the graph and wait.
                self.sessionActive = false
                self.sessionGeneration &+= 1
                self.needsRestart = true
                self.rebuildGraph(restart: false)

            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                guard options.contains(.shouldResume) else { return }
                self.primeSession { self.rebuildGraph() }

            @unknown default:
                break
            }
        }
    }

    /// The audio server died and took every session, engine and node with it. Nothing that was
    /// playing survives; the category has to be set again on the replacement session.
    @objc private func mediaServicesReset(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Log.world("Media services were reset — reconfiguring audio")
            self.sessionActive = false
            self.sessionGeneration &+= 1
            self.needsRestart = true
            self.primeSession { self.rebuildGraph() }
        }
    }
#endif

    /// Tears the whole graph down and, when `restart` is set, brings the loops back.
    ///
    /// Only looping sounds are restored. A one-shot is a splash or a racket hit that is over
    /// in well under a second, and restarting it from the top would be more noticeable than
    /// losing it.
    private func rebuildGraph(restart: Bool = true) {
        let loops: [(Handle, AVAudioPCMBuffer)] = active.compactMap { handle in
            guard handle.loops, !handle.stopped, let buffer = handle.buffer else { return nil }
            return (handle, buffer)
        }

        for handle in active { tearDown(handle) }
        engine.stop()

        guard restart else { return }
        for (handle, buffer) in loops {
            start(handle: handle, buffer: buffer, loop: true)
        }
    }

    /// Gets the session up off the main thread, then runs `work` back on the main thread.
    ///
    /// `.playback` matches what the Capacitor build got from `NativeAudio`: the game's own music
    /// keeps playing with the ring switch on silent, which is what players expect from a game
    /// rather than from a web page. It is set again on every prime because a media services
    /// reset hands back a session with the category reset to the default.
    ///
    /// Call on the main thread — `sessionGeneration` is read there.
    func primeSession(then work: (() -> Void)? = nil) {
#if os(iOS)
        let generation = sessionGeneration
        sessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)

            var activated = true
            do {
                try session.setActive(true)
            } catch {
                Log.world("Audio session failed to activate: \(error.localizedDescription)")
                activated = false
            }

            DispatchQueue.main.async {
                if let self, activated, self.sessionGeneration == generation {
                    self.sessionActive = true
                }
                work?()
            }
        }
#else
        work?()
#endif
    }

    /// The last-resort activation, on the calling (main) thread.
    ///
    /// Only reached when a sound beats the background prime — a race the fetch and decode in
    /// front of every sound makes very unlikely, but the alternative to blocking here is a
    /// silently dropped sound, and the engine must not be started against a dead session.
    @discardableResult
    private func activateSession() -> Bool {
#if os(iOS)
        guard !sessionActive else { return true }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            Log.world("Audio session failed to activate: \(error.localizedDescription)")
        }
        return sessionActive
#else
        // Nothing to activate on the Mac; the engine is the whole of it.
        sessionActive = true
        return true
#endif
    }

    // MARK: - Loading

    /// Decoded PCM for an asset path, fetching and decoding at most once per path.
    private func load(path: String, completion: @escaping (AVAudioPCMBuffer?) -> Void) {
        if let buffer = buffers[path] {
            completion(buffer)
            return
        }
        if failed.contains(path) {
            completion(nil)
            return
        }
        if pendingLoads[path] != nil {
            pendingLoads[path]?.append(completion)
            return
        }
        pendingLoads[path] = [completion]

        fetchFile(path: path) { [weak self] fileURL in
            guard let self else { return }
            guard let fileURL else {
                self.finishLoad(path: path, buffer: nil)
                return
            }

            self.decodeQueue.async {
                let buffer = Self.decode(fileURL: fileURL)
                DispatchQueue.main.async { self.finishLoad(path: path, buffer: buffer) }
            }
        }
    }

    private func finishLoad(path: String, buffer: AVAudioPCMBuffer?) {
        if let buffer {
            buffers[path] = buffer
        } else {
            failed.insert(path)
            Log.world("Audio load failed: \(path)")
        }
        let waiting = pendingLoads.removeValue(forKey: path) ?? []
        for callback in waiting { callback(buffer) }
    }

    private static func decode(fileURL: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil
        else { return nil }
        return buffer
    }

    /// Resolves an asset path to a file in the bundle. All 11 MB of audio ships with the app
    /// (PLAN.md §5), which suits `AVAudioFile` — it wants a real file, and the previous
    /// network path had to spool downloads into Caches to give it one.
    private func fetchFile(path: String, completion: @escaping (URL?) -> Void) {
        completion(AssetLocator.url(for: path))
    }
}
