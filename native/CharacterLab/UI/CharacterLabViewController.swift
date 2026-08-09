import AppKit
import MetalKit
import simd

/// The lab's surface: a Metal view running the game's own renderer, a readout over the top,
/// and the keys that drive it.
///
/// There is no `AdminSession` here and no socket — the lab is not a place in the world, so
/// there is nothing to connect to. It builds a bare `GameState`, hands it a `CharacterLabScene`
/// through `startToolScene`, and lets the renderer do exactly what it does in the game.
final class CharacterLabViewController: NSViewController {

    let state = GameState()
    let scene: CharacterLabScene

    private var metalView: MTKView!
    private var renderer: Renderer?
    private let readout = CharacterLabReadoutView()

    /// Raised each frame so the sidebar's scrubber can follow the clock.
    var onFrame: (() -> Void)?

    private var capture: CaptureRun?
    /// Drives frames by hand while a capture is running; see `viewDidLoad`.
    private var captureTimer: Timer?
    /// Drives them while the window is occluded; see `chooseFrameSource`.
    private var occlusionTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?

    deinit {
        occlusionTimer?.invalidate()
        captureTimer?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    init() {
        scene = CharacterLabScene(take: CharacterLabArguments.takeId,
                                  cast: CharacterLabArguments.cast)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = LabContainerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        (view as? LabContainerView)?.controller = self
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice() else {
            presentFatal("This Mac does not support Metal.")
            return
        }

        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        // A capture blits the drawable, and a blit source has to be readable.
        metalView.framebufferOnly = false
        // **A capture drives its own frames.** `MTKView` runs off a display link, and a display
        // link stops when the window is fully occluded — which, for an app launched from a
        // terminal that then fails to come to the front, is immediately and permanently. The
        // scripted modes are exactly the ones nobody is watching, so they cannot depend on being
        // visible: they pause the view's own loop and call `draw()` by hand.
        metalView.isPaused = CharacterLabArguments.quitsAfterCapture
        view.addSubview(metalView)

        readout.frame = view.bounds
        readout.autoresizingMask = [.width, .height]
        view.addSubview(readout)

        guard let renderer = Renderer(view: metalView, state: state) else {
            presentFatal("Failed to initialise the renderer.")
            return
        }
        self.renderer = renderer
        renderer.onFrame = { [weak self] _ in self?.frameDidRender() }
        metalView.delegate = renderer

        applyArguments()
        state.startToolScene(scene)
        startCaptureIfRequested(device: device)
        scheduleSmokeTestExitIfRequested()
    }

    /// `-labquitafter <seconds>`: says what is on screen and quits.
    private func scheduleSmokeTestExitIfRequested() {
        guard let seconds = CharacterLabArguments.quitAfterSeconds else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            print("Character lab state: take \(scene.take.id) · cast \(scene.castKind.rawValue) "
                  + "· view \(scene.view.rawValue) · t \(format(scene.clock)) of \(format(scene.take.seconds)) s "
                  + "· \(scene.isPaused ? "paused" : "playing")")
            for line in scene.readout() { print("  \(line)") }
            // A clock that has not moved means no frames were drawn, which is a window problem
            // and not a lab one — so the smoke test says enough to tell the two apart.
            let window = view.window
            print("  frames \(framesRendered) · drawable \(Int(metalView.drawableSize.width))×\(Int(metalView.drawableSize.height))"
                  + " · window \(window?.isVisible == true ? "visible" : "hidden")"
                  + " · \(window?.occlusionState.contains(.visible) == true ? "on screen" : "occluded")"
                  + " · app \(NSApp.isActive ? "active" : "inactive")")
            NSApp.terminate(nil)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)

        guard let window = view.window else { return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main) { [weak self] _ in self?.chooseFrameSource() }
        chooseFrameSource()
    }

    /// **Keeps the clock running when the window is behind something.**
    ///
    /// `MTKView` draws off a display link, and AppKit stops the display link the moment a window
    /// is fully occluded. That is right for a game — nobody is looking — and wrong for a tool
    /// whose numbers are being read in a terminal next to it, and wrong again for an app
    /// launched from a shell that is never allowed to come to the front, where it means the lab
    /// renders precisely nothing.
    ///
    /// So: display link while visible, a 30 Hz hand-crank while not.
    private func chooseFrameSource() {
        // A capture already drives its own frames and must not be second-guessed.
        guard !CharacterLabArguments.quitsAfterCapture else { return }

        let visible = view.window?.occlusionState.contains(.visible) ?? false
        if visible {
            occlusionTimer?.invalidate()
            occlusionTimer = nil
            metalView.isPaused = false
        } else {
            metalView.isPaused = true
            guard occlusionTimer == nil else { return }
            occlusionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.metalView.draw()
            }
        }
    }

    /// The launch arguments that describe *what* to look at, applied before the first frame so
    /// a headless grab never photographs the default take on its way to the requested one.
    private func applyArguments() {
        scene.select(cast: CharacterLabArguments.cast)
        if let id = CharacterLabArguments.takeId, id != "all" { scene.select(takeId: id) }
        if let view = CharacterLabArguments.view { scene.viewOverride = view }
        if let speed = CharacterLabArguments.speedScale { scene.speedScale = speed }
        if let width = CharacterLabArguments.frameWidth { scene.frameWidthMetres = width }
        scene.showsGrid = CharacterLabArguments.showsGrid
        scene.showsRuler = CharacterLabArguments.showsRuler
        if let time = CharacterLabArguments.time {
            scene.isPaused = true
            scene.seek(to: time)
        }
    }

    private var framesRendered = 0

    private func frameDidRender() {
        framesRendered += 1
        readout.update(scene: scene)
        onFrame?()
    }

    private func presentFatal(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.frame = view.bounds.insetBy(dx: 20, dy: 20)
        view.addSubview(label)
    }

    // MARK: - Keys
    //
    // Space plays and pauses; ← and → step a frame; ⇧← and ⇧→ step ten; [ and ] change take;
    // 1…5 pick a camera; Q/E swing it; R/F tip it; − and = zoom; G and H toggle the grid and
    // the ruler. Printed by the sidebar's "Keys" button so they do not have to be remembered.

    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": scene.isPaused.toggle()
        case "[": stepTake(-1)
        case "]": stepTake(1)
        case "1": scene.viewOverride = .side
        case "2": scene.viewOverride = .threeQuarter
        case "3": scene.viewOverride = .front
        case "4": scene.viewOverride = .back
        case "5": scene.viewOverride = .top
        case "0": scene.viewOverride = nil; scene.yawTrim = 0; scene.pitchTrim = 0
        case "q": scene.yawTrim -= 0.08
        case "e": scene.yawTrim += 0.08
        case "r": scene.pitchTrim += 0.05
        case "f": scene.pitchTrim -= 0.05
        case "-", "_": scene.frameWidthMetres = min(20, scene.frameWidthMetres * 1.15)
        case "=", "+": scene.frameWidthMetres = max(1, scene.frameWidthMetres / 1.15)
        case "g": scene.showsGrid.toggle()
        case "h": scene.showsRuler.toggle()
        default:
            switch event.keyCode {
            case 123: scene.isPaused = true; scene.step(frames: shift ? -10 : -1)
            case 124: scene.isPaused = true; scene.step(frames: shift ? 10 : 1)
            default: return false
            }
        }
        onFrame?()
        return true
    }

    func stepTake(_ delta: Int) {
        let count = CharacterLabTake.all.count
        scene.select(takeIndex: (scene.takeIndex + delta + count) % count)
        onFrame?()
    }

    // MARK: - Capture

    /// One picture to take: which take, at what time, captioned how.
    private struct CaptureItem {
        let takeId: String
        let time: Double
        let caption: String
    }

    /// The state of a headless run: what is left to grab, and what has been grabbed.
    private final class CaptureRun {
        var items: [CaptureItem]
        var frames: [CharacterLabCapture.Frame] = []
        var index = 0
        let title: String
        let subtitle: String
        let columns: Int?
        let path: String
        let isSingleShot: Bool

        init(items: [CaptureItem], title: String, subtitle: String,
             columns: Int?, path: String, isSingleShot: Bool) {
            self.items = items
            self.title = title
            self.subtitle = subtitle
            self.columns = columns
            self.path = path
            self.isSingleShot = isSingleShot
        }
    }

    private func startCaptureIfRequested(device: MTLDevice) {
        guard CharacterLabArguments.quitsAfterCapture else { return }

        let run: CaptureRun
        if let path = CharacterLabArguments.shotPath {
            let take = scene.take
            let time = CharacterLabArguments.time ?? take.seconds * 0.45
            run = CaptureRun(items: [CaptureItem(takeId: take.id, time: time,
                                                 caption: "\(take.title) — t \(format(time)) s")],
                             title: take.title,
                             subtitle: take.watchFor,
                             columns: 1,
                             path: path,
                             isSingleShot: true)
        } else if let path = CharacterLabArguments.sheetPath, CharacterLabArguments.wantsEveryTake {
            // One representative frame of every take: 45% in, which is past any settling and
            // short of any loop.
            let items = CharacterLabTake.all.map {
                CaptureItem(takeId: $0.id, time: $0.seconds * 0.45, caption: $0.title)
            }
            run = CaptureRun(items: items,
                             title: "Character lab — every take",
                             subtitle: "\(scene.castKind.title) · one frame each, 45% into the take",
                             columns: nil,
                             path: path,
                             isSingleShot: false)
        } else if let path = CharacterLabArguments.sheetPath {
            let take = scene.take
            let count = max(2, CharacterLabArguments.sheetFrames)
            // A moving take is filmed over exactly one stride, so the strip is a walk cycle
            // rather than eight samples of an unrelated interval. Everything else — standing,
            // the emotes — gets the whole take.
            let stride = CharacterLabReport.strideWindow(take: take,
                                                         cast: scene.castKind,
                                                         speedScale: scene.speedScale)
            let start = stride?.start ?? 0
            let span = stride?.duration ?? take.seconds
            let items = (0..<count).map { index -> CaptureItem in
                let time = start + span * Double(index) / Double(count)
                return CaptureItem(takeId: take.id, time: time,
                                   caption: "t \(format(time)) s")
            }
            let what = stride == nil ? "over \(format(take.seconds)) s"
                                     : "over one stride, \(format(span)) s"
            run = CaptureRun(items: items,
                             title: "\(take.title) — \(count) frames \(what)",
                             subtitle: take.watchFor,
                             columns: min(count, 4),
                             path: path,
                             isSingleShot: false)
        } else {
            return
        }

        capture = run
        scene.isPaused = true

        // The hand-cranked frame loop the paused view needs. It runs for the whole capture,
        // including the warm-up — models are loaded on demand *while drawing*, so a warm-up
        // with no frames in it warms nothing up.
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.metalView.draw()
        }

        // Heads and shoes are read off disk on a background queue; grabbing before they land
        // photographs a headless character, which looks exactly like a bug in the rig.
        DispatchQueue.main.asyncAfter(deadline: .now() + CharacterLabArguments.warmUpSeconds) {
            [weak self] in self?.grabNext(device: device)
        }
    }

    private func grabNext(device: MTLDevice) {
        guard let run = capture else { return }
        guard run.index < run.items.count else { return finishCapture() }

        let item = run.items[run.index]
        scene.select(takeId: item.takeId)
        scene.seek(to: item.time)

        var grabbed = false
        renderer?.captureHandler = { [weak self] texture, commandBuffer in
            guard !grabbed else { return }
            grabbed = true
            MetalCapture.capture(texture: texture, commandBuffer: commandBuffer, device: device) { image in
                guard let self, let run = self.capture else { return }
                self.renderer?.captureHandler = nil
                if let image {
                    run.frames.append(CharacterLabCapture.Frame(image: image, caption: item.caption))
                } else {
                    Log.render("Character lab: frame \(run.index) of '\(item.takeId)' could not be read back")
                }
                run.index += 1
                self.grabNext(device: device)
            }
        }
    }

    private func finishCapture() {
        guard let run = capture else { return }
        capture = nil
        captureTimer?.invalidate()
        captureTimer = nil

        let wrote: Bool
        if run.isSingleShot, let frame = run.frames.first {
            wrote = CharacterLabCapture.write(frame.image, to: run.path)
        } else {
            wrote = CharacterLabCapture.writeSheet(run.frames,
                                                   title: run.title,
                                                   subtitle: run.subtitle,
                                                   columns: run.columns,
                                                   to: run.path)
        }

        if wrote {
            Log.render("Character lab wrote \(run.frames.count) frame(s) to \(run.path)")
        } else {
            Log.render("Character lab failed to write \(run.path)")
        }
        // What was actually in the picture. A character whose model had not landed by the time
        // the shutter went is a shadow with nothing above it, and at a lineup's zoom that reads
        // as a gap in the row rather than as a missing model. Raise `-labwarmup` if this is short.
        let loaded = renderer?.loadedCharacterModels ?? []
        Log.render("Character lab: \(loaded.count) model(s) resident — "
                   + (loaded.isEmpty ? "none" : loaded.joined(separator: ", ")))
        NSApp.terminate(nil)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

// MARK: - Views

/// Routes key presses to the controller. `NSViewController` is in the responder chain but the
/// Metal view swallows nothing, so the container is the simplest place to catch them.
private final class LabContainerView: NSView {
    weak var controller: CharacterLabViewController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }
}

/// The numbers over the picture: which take, where the clock is, and what each subject's motor
/// currently believes about itself.
private final class CharacterLabReadoutView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let watchFor = NSTextField(labelWithString: "")
    private let numbers = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        watchFor.font = .systemFont(ofSize: 11)
        numbers.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        for field in [title, watchFor, numbers] {
            field.textColor = .white
            field.maximumNumberOfLines = 0
            field.shadow = {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                return shadow
            }()
            addSubview(field)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Hit-testing off, so every click and drag reaches the Metal view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(scene: CharacterLabScene) {
        let take = scene.take
        title.stringValue = "\(take.title)   t \(String(format: "%.2f", scene.clock)) / \(String(format: "%.1f", take.seconds)) s"
            + (scene.isPaused ? "   ⏸" : "")
        watchFor.stringValue = take.watchFor
        numbers.stringValue = (["\(take.id) · \(scene.view.title) · ×\(String(format: "%.2f", scene.speedScale)) speed"]
                               + scene.readout()).joined(separator: "\n")
        layoutFields()
    }

    private func layoutFields() {
        let margin: CGFloat = 14
        let width = bounds.width - margin * 2
        title.frame = CGRect(x: margin, y: bounds.height - margin - 20, width: width, height: 20)
        watchFor.frame = CGRect(x: margin, y: bounds.height - margin - 40, width: width, height: 18)

        let height = numbers.sizeThatFits(NSSize(width: width, height: 400)).height
        numbers.frame = CGRect(x: margin, y: margin, width: width, height: height)
    }

    override func layout() {
        super.layout()
        layoutFields()
    }
}
