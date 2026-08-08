#if DEBUG
import AppKit

/// A slider that calls a closure. `AdminUI` has buttons, checkboxes and pop-ups but no slider,
/// because nothing in the map editor is a continuous value; the lab is nearly all of them.
final class ActionSlider: NSSlider {
    var handler: ((Double) -> Void)?

    @objc func fire() { handler?(doubleValue) }

    static func make(min: Double, max: Double, value: Double,
                     action: @escaping (Double) -> Void) -> ActionSlider {
        let slider = ActionSlider()
        slider.minValue = min
        slider.maxValue = max
        slider.doubleValue = value
        slider.isContinuous = true
        slider.controlSize = .small
        slider.handler = action
        slider.target = slider
        slider.action = #selector(fire)
        return slider
    }
}

/// The lab's control column: pick a take, scrub it, change who is standing there, move the
/// camera, and write out whatever is on screen.
///
/// It is deliberately the same set of things the launch arguments expose, because the two are
/// used together — the window is for finding the frame worth looking at, and `-labtake … -labtime …`
/// is for asking for that frame again tomorrow. "Copy command" writes the current state out as
/// the command line that reproduces it.
final class CharacterLabControlsView: NSView {

    private weak var lab: CharacterLabViewController?

    private let takePopUp: ActionPopUpButton
    private let castPopUp: ActionPopUpButton
    private let viewPopUp: ActionPopUpButton
    private let scrubber: ActionSlider
    private let timeLabel = AdminUI.label("0.00 s")
    private let playButton: NSButton
    private let watchForLabel = AdminUI.label("")
    private let statusLabel = AdminUI.label("")

    /// Guards the scrubber against fighting the clock: while the frame callback is writing the
    /// slider's value, the slider's own action must not write it back.
    private var isSyncing = false

    /// The last clock value pushed *into* the scrubber.
    ///
    /// `isSyncing` alone is not enough. The scrubber is written every frame from the clock, and
    /// AppKit can deliver the resulting action a runloop pass later — after the flag has been
    /// put back — where it is indistinguishable from a drag. The lab then paused itself a few
    /// seconds into every session, at whatever time the clock happened to be showing. An action
    /// carrying exactly the value we wrote is not a drag, so it is dropped.
    private var pushedClock: Double = -1

    init(lab: CharacterLabViewController) {
        self.lab = lab
        let scene = lab.scene

        takePopUp = AdminUI.popUp(CharacterLabTake.all.map(\.title)) { _ in }
        castPopUp = AdminUI.popUp(CharacterLabCast.Kind.allCases.map(\.title)) { _ in }
        viewPopUp = AdminUI.popUp(["Take's own"] + CharacterLabView.allCases.map(\.title)) { _ in }
        scrubber = ActionSlider.make(min: 0, max: scene.take.seconds, value: 0) { _ in }
        playButton = AdminUI.button("Pause") {}

        super.init(frame: .zero)
        build(scene: scene)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Building

    private func build(scene: CharacterLabScene) {
        takePopUp.handler = { [weak self] title in
            guard let index = CharacterLabTake.all.firstIndex(where: { $0.title == title }) else { return }
            self?.lab?.scene.select(takeIndex: index)
            self?.refresh()
        }
        castPopUp.handler = { [weak self] title in
            guard let kind = CharacterLabCast.Kind.allCases.first(where: { $0.title == title }) else { return }
            self?.lab?.scene.select(cast: kind)
            self?.refresh()
        }
        viewPopUp.handler = { [weak self] title in
            guard let scene = self?.lab?.scene else { return }
            scene.viewOverride = CharacterLabView.allCases.first { $0.title == title }
            scene.yawTrim = 0
            scene.pitchTrim = 0
            self?.refresh()
        }
        scrubber.handler = { [weak self] value in
            guard let self, !self.isSyncing, let scene = self.lab?.scene else { return }
            guard abs(value - self.pushedClock) > 1e-9 else { return }
            scene.isPaused = true
            scene.seek(to: value)
            self.refresh()
        }
        playButton.target = playButton
        (playButton as? ActionButton)?.handler = { [weak self] in
            self?.lab?.scene.isPaused.toggle()
            self?.refresh()
        }

        let stack = AdminUI.verticalStack([
            AdminUI.sectionTitle("Take"),
            takePopUp,
            watchForLabel,
            AdminUI.row("", [
                AdminUI.button("◀ Prev") { [weak self] in self?.lab?.stepTake(-1); self?.refresh() },
                AdminUI.button("Next ▶") { [weak self] in self?.lab?.stepTake(1); self?.refresh() },
            ]),

            AdminUI.sectionTitle("Clock"),
            scrubber,
            AdminUI.row("", [
                playButton,
                AdminUI.button("−10") { [weak self] in self?.step(-10) },
                AdminUI.button("−1") { [weak self] in self?.step(-1) },
                AdminUI.button("+1") { [weak self] in self?.step(1) },
                AdminUI.button("+10") { [weak self] in self?.step(10) },
                timeLabel,
            ]),
            AdminUI.row("Rate", [
                ActionSlider.make(min: 0.1, max: 2, value: scene.rate) { [weak self] value in
                    self?.lab?.scene.rate = value
                },
            ]),

            AdminUI.sectionTitle("Subject"),
            castPopUp,
            AdminUI.row("Speed", [
                ActionSlider.make(min: 0.1, max: 1.5, value: scene.speedScale) { [weak self] value in
                    self?.lab?.scene.speedScale = value
                    self?.refresh()
                },
            ]),

            AdminUI.sectionTitle("Camera"),
            viewPopUp,
            AdminUI.row("Width", [
                ActionSlider.make(min: 1.5, max: 16, value: scene.frameWidthMetres) { [weak self] value in
                    self?.lab?.scene.frameWidthMetres = value
                },
            ]),
            AdminUI.row("", [
                AdminUI.checkbox("Grid", checked: scene.showsGrid) { [weak self] on in
                    self?.lab?.scene.showsGrid = on
                },
                AdminUI.checkbox("Ruler", checked: scene.showsRuler) { [weak self] on in
                    self?.lab?.scene.showsRuler = on
                },
            ]),

            AdminUI.sectionTitle("Write out"),
            AdminUI.row("", [
                AdminUI.button("Copy command") { [weak self] in self?.copyCommand() },
                AdminUI.button("Keys") { [weak self] in self?.showKeys() },
            ]),
            statusLabel,
        ])

        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])

        for label in [watchForLabel, statusLabel] {
            label.maximumNumberOfLines = 4
            label.preferredMaxLayoutWidth = 260
        }
    }

    private func step(_ frames: Int) {
        lab?.scene.isPaused = true
        lab?.scene.step(frames: frames)
        refresh()
    }

    // MARK: - Keeping up with the scene

    /// Called every frame, so the scrubber follows a playing take.
    func refresh() {
        guard let scene = lab?.scene else { return }
        isSyncing = true
        defer { isSyncing = false }

        // `reload` rather than `selectItem`, so a selection written *from* the model can never
        // be read back as one the operator made. Same reason `ActionPopUpButton` has it.
        takePopUp.reload(selected: CharacterLabTake.all[scene.takeIndex].title)
        castPopUp.reload(selected: scene.castKind.title)
        viewPopUp.reload(selected: scene.viewOverride?.title ?? "Take's own")
        scrubber.maxValue = scene.take.seconds
        scrubber.doubleValue = scene.clock
        pushedClock = scene.clock
        timeLabel.stringValue = String(format: "%.2f s", scene.clock)
        playButton.title = scene.isPaused ? "Play" : "Pause"
        watchForLabel.stringValue = scene.take.watchFor
    }

    // MARK: - Write out

    /// Puts the command line that reproduces exactly what is on screen on the clipboard. The
    /// window is for finding a frame; this is for asking for it again from a script.
    private func copyCommand() {
        guard let scene = lab?.scene else { return }
        var parts = ["-lab",
                     "-labtake", scene.take.id,
                     "-labcast", scene.castKind.rawValue,
                     "-labtime", String(format: "%.2f", scene.clock),
                     "-labwidth", String(format: "%.1f", scene.frameWidthMetres)]
        if let view = scene.viewOverride { parts += ["-labview", view.rawValue] }
        if scene.speedScale != 1 { parts += ["-labspeed", String(format: "%.2f", scene.speedScale)] }
        if !scene.showsGrid { parts.append("-labnogrid") }
        if !scene.showsRuler { parts.append("-labnoruler") }
        parts += ["-labshot", "/tmp/lab.png"]

        let command = "\"$APP/Contents/MacOS/Joels World Map Editor\" " + parts.joined(separator: " ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusLabel.stringValue = "Copied:\n\(command)"
    }

    private func showKeys() {
        statusLabel.stringValue = """
        space play/pause · ←→ step a frame (⇧ ten) · [ ] change take
        1–5 side/¾/front/back/top · 0 back to the take's own
        Q E swing · R F tip · − = zoom · G grid · H ruler
        """
    }
}
#endif
