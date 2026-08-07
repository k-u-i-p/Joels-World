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

    /// Decoded PCM keyed by asset path, so the same splash costs one download and one decode.
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var pendingLoads: [String: [(AVAudioPCMBuffer?) -> Void]] = [:]
    private var failed: Set<String> = []

    /// Everything currently making noise, so a map change can silence the lot.
    private var active: [Handle] = []

    private var background: Handle?
    private var currentBackgroundPath: String?

    private let session: URLSession
    private let decodeQueue = DispatchQueue(label: "com.allr.joelsworld.audio", qos: .userInitiated)

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                   diskCapacity: 64 * 1024 * 1024,
                                   diskPath: "joelsworld-audio")
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)

        // `.playback` matches what the Capacitor build got from `NativeAudio`: the game's own
        // music keeps playing with the ring switch on silent, which is what players expect
        // from a game rather than from a web page.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
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
    func stopAll() {
        for handle in active { handle.pause() }
        background = nil
        currentBackgroundPath = nil
    }

    // MARK: - Engine

    private func start(handle: Handle, buffer: AVAudioPCMBuffer, loop: Bool) {
        activateSession()

        engine.attach(handle.player)
        engine.attach(handle.varispeed)
        engine.connect(handle.player, to: handle.varispeed, format: buffer.format)
        engine.connect(handle.varispeed, to: engine.mainMixerNode, format: buffer.format)
        handle.attached = true
        handle.player.volume = handle.volume
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

    private func activateSession() {
        guard !sessionActive else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            Log.world("Audio session failed to activate: \(error.localizedDescription)")
        }
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

    /// Resolves an asset path to a file on disk. Bundle first (PLAN.md §5 wants the audio
    /// shipped inside the app), then the asset host with an on-disk copy in Caches —
    /// `AVAudioFile` needs a real file, so the bytes are written out rather than kept in the
    /// `URLCache` alone.
    private func fetchFile(path: String, completion: @escaping (URL?) -> Void) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let name = (trimmed as NSString).deletingPathExtension
        let ext = (trimmed as NSString).pathExtension

        if let bundled = Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(forResource: (name as NSString).lastPathComponent, withExtension: ext) {
            completion(bundled)
            return
        }

        let cacheURL = Self.cacheDirectory.appendingPathComponent(
            trimmed.replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            completion(cacheURL)
            return
        }

        guard let url = URL(string: trimmed, relativeTo: Config.assetBaseURL) else {
            completion(nil)
            return
        }

        session.dataTask(with: url) { data, _, error in
            if let error {
                Log.world("Audio fetch failed: \(trimmed) — \(error.localizedDescription)")
            }
            guard let data, (try? data.write(to: cacheURL)) != nil else {
                completion(nil)
                return
            }
            completion(cacheURL)
        }.resume()
    }

    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
