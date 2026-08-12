import UIKit
import QuartzCore

/// Five Nights at St Peters' screen furniture: the clock, the power meter, the two door buttons,
/// the two light buttons, and the camera monitor.
///
/// Like `SchoolRushView` and `Tennis3DView` this draws nothing of the world — the school, the
/// shutters and the children all come out of the Metal renderer behind it. What is here is the
/// security desk: the numbers, the buttons, and the scan lines that turn a rendered room into a
/// camera feed.
///
/// **The scan lines and the burst of static are not decoration.** A cut from the office to a
/// camera is a teleport, and without something to mark it the picture just changes and reads as a
/// glitch. Half a second of static says "you switched channel" — and it is also, exactly as in
/// the original, half a second in which you cannot see what is happening.
final class FiveNightsView: UIView {

    // MARK: - Subviews

    private let statusPanel = Theme.glassPanel(cornerRadius: 14)
    private let nightLabel = UILabel()
    private let clockLabel = UILabel()
    private let clockTrack = UIView()
    private let clockFill = UIView()

    private let powerLabel = UILabel()
    private let powerCaption = UILabel()
    /// The usage meter: five blocks, lit one at a time. Straight out of the original, where it is
    /// the only warning you get that you are burning the night.
    private var usageBlocks: [UIView] = []

    /// **The two buttons the whole game is played with.** There is one door in this school and
    /// one monitor, so there are two buttons: everything else on screen is information.
    private let mainDoorButton = FiveNightsView.controlButton("MAIN DOOR")
    private let camerasButton = FiveNightsView.controlButton("CAMERAS")

    /// The seven seconds, counted down in the middle of the picture — **only while the monitor is
    /// actually pointed at CAM 7.** Off it you get the bang and the banner and nothing else, which
    /// is what makes looking worth the power.
    private let countdownLabel = UILabel()

    private let camBar = UIStackView()
    private var camButtons: [(button: UIButton, room: FiveNightsSchool.Room)] = []
    private let camLabel = UILabel()

    /// The four layers that turn a rendered room into a camera feed: a green cast, a vignette,
    /// scan lines, and a flash of static whenever the channel changes. None of them touch the
    /// renderer — they are `UIView`s over the top of it, which is why a "night vision" mode costs
    /// nothing and can be switched on and off in a frame.
    private let nightVision = UIView()
    private let vignette = UIView()
    private let scanlines = UIView()
    private let staticFlash = UIView()

    /// The timestamp in the corner of the feed, and the recording dot beside it.
    private let recDot = UIView()
    private let stampLabel = UILabel()

    private let bannerPanel = Theme.glassPanel(cornerRadius: 16)
    private let bannerTitle = UILabel()
    private let bannerSubtitle = UILabel()

    private let overPanel = Theme.glassPanel(cornerRadius: 18)
    private let overTitle = UILabel()
    private let overDetail = UILabel()
    private let nextNightButton = Theme.button(title: "Next night", color: Theme.success,
                                               filled: true)
    private let retryButton = Theme.button(title: "Try again", color: Theme.primary, filled: true)
    private let leaveButton = Theme.button(title: "Back to school", color: Theme.danger)

    private let hint = UILabel()

    private var game: FiveNightsGame?
    private var lastStepTime: CFTimeInterval?
    /// Runs while the monitor is up, and drives everything that wobbles or blinks on it.
    private var feedClock: Double = 0
    /// How far up the monitor's layers are, 0 to 1. See `step()`.
    private var monitorAlpha: CGFloat = 0
    /// The last flash token seen, so a change can be spotted without the game calling back.
    private var lastFlashToken = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    private func setup() {
        backgroundColor = .clear
        isHidden = true
        isUserInteractionEnabled = true

        buildMonitorLayers()
        buildStatusPanel()
        buildControls()
        buildCamBar()
        buildBanner()
        buildOverPanel()
        buildHint()
        layoutEverything()
    }

    /// Scan lines are a four-pixel pattern tiled over the whole screen — two dark rows, two clear.
    /// A pattern colour costs one small image and no per-frame work at all.
    private static let scanlineImage: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.image { context in
            UIColor(white: 0, alpha: 0.22).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        }
    }()

    private func buildMonitorLayers() {
        // A green cast over everything. Real night-vision is green because the tube was; a
        // camera feed in a dark school is green because that is what everyone expects one to
        // look like, and it costs one translucent view.
        nightVision.backgroundColor = UIColor(red: 0.24, green: 0.85, blue: 0.45, alpha: 0.16)
        nightVision.isUserInteractionEnabled = false
        nightVision.alpha = 0
        addSubview(nightVision)

        // The vignette: a radial gradient from clear to black, which is what makes the picture
        // look like it is coming down a wire rather than out of a games console.
        let gradient = CAGradientLayer()
        gradient.type = .radial
        gradient.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
        gradient.locations = [0.45, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 1.1, y: 1.1)
        vignette.layer.addSublayer(gradient)
        vignetteGradient = gradient
        vignette.isUserInteractionEnabled = false
        vignette.alpha = 0
        addSubview(vignette)

        scanlines.backgroundColor = UIColor(patternImage: Self.scanlineImage)
        scanlines.isUserInteractionEnabled = false
        scanlines.alpha = 0
        addSubview(scanlines)

        staticFlash.backgroundColor = UIColor(white: 0.75, alpha: 1)
        staticFlash.isUserInteractionEnabled = false
        staticFlash.alpha = 0
        addSubview(staticFlash)

        style(camLabel, size: 15, color: UIColor(hex: 0x8effd0), weight: .heavy)
        camLabel.textAlignment = .center
        camLabel.alpha = 0
        addSubview(camLabel)

        recDot.backgroundColor = Theme.danger
        recDot.layer.cornerRadius = 4
        recDot.alpha = 0
        addSubview(recDot)

        style(stampLabel, size: 12, color: UIColor(hex: 0x8effd0), weight: .semibold)
        stampLabel.alpha = 0
        addSubview(stampLabel)
    }

    private var vignetteGradient: CAGradientLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        // A gradient layer is not laid out by Auto Layout, so it is resized by hand — and without
        // disabling the implicit animation it would slide into place over a quarter of a second
        // every time the device rotates.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        vignetteGradient?.frame = bounds
        CATransaction.commit()
    }

    /// Top-left: which night it is, what time it is, and how much power is left. The button bar
    /// takes the top-right corner during a minigame, so everything lives on this side.
    private func buildStatusPanel() {
        addSubview(statusPanel)

        style(nightLabel, size: 12, color: Theme.textMuted, weight: .semibold)
        nightLabel.text = "NIGHT 1"
        style(clockLabel, size: 30, color: .white, weight: .heavy)
        clockLabel.text = "12 AM"

        clockTrack.backgroundColor = UIColor(white: 1, alpha: 0.18)
        clockTrack.layer.cornerRadius = 2
        clockFill.backgroundColor = UIColor(hex: 0x8effd0)
        clockFill.layer.cornerRadius = 2
        clockTrack.addSubview(clockFill)

        style(powerCaption, size: 11, color: Theme.textMuted, weight: .semibold)
        powerCaption.text = "POWER LEFT"
        style(powerLabel, size: 20, color: UIColor(hex: 0xf5c518), weight: .bold)
        powerLabel.text = "100%"

        usageBlocks = (0..<5).map { _ in
            let block = UIView()
            block.backgroundColor = Theme.danger
            block.layer.cornerRadius = 2
            block.alpha = 0.2
            block.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                block.widthAnchor.constraint(equalToConstant: 10),
                block.heightAnchor.constraint(equalToConstant: 14),
            ])
            return block
        }
        let usageRow = UIStackView(arrangedSubviews: usageBlocks)
        usageRow.axis = .horizontal
        usageRow.spacing = 3

        let column = UIStackView(arrangedSubviews: [nightLabel, clockLabel, clockTrack,
                                                    powerCaption, powerLabel, usageRow])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.setCustomSpacing(10, after: clockTrack)
        column.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.contentView.addSubview(column)

        clockTrack.translatesAutoresizingMaskIntoConstraints = false
        clockFill.translatesAutoresizingMaskIntoConstraints = false
        clockFillWidth = clockFill.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: statusPanel.contentView.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: statusPanel.contentView.bottomAnchor,
                                           constant: -10),
            column.leadingAnchor.constraint(equalTo: statusPanel.contentView.leadingAnchor,
                                            constant: 14),
            column.trailingAnchor.constraint(equalTo: statusPanel.contentView.trailingAnchor,
                                             constant: -14),
            clockTrack.widthAnchor.constraint(equalToConstant: 108),
            clockTrack.heightAnchor.constraint(equalToConstant: 4),
            clockFill.leadingAnchor.constraint(equalTo: clockTrack.leadingAnchor),
            clockFill.topAnchor.constraint(equalTo: clockTrack.topAnchor),
            clockFill.bottomAnchor.constraint(equalTo: clockTrack.bottomAnchor),
            clockFillWidth,
        ])
    }

    private var clockFillWidth: NSLayoutConstraint!

    private func buildControls() {
        mainDoorButton.addTarget(self, action: #selector(mainDoorTapped), for: .touchUpInside)
        camerasButton.addTarget(self, action: #selector(camerasTapped), for: .touchUpInside)
        for button in [mainDoorButton, camerasButton] { addSubview(button) }

        style(countdownLabel, size: 54, color: Theme.danger, weight: .heavy)
        countdownLabel.textAlignment = .center
        countdownLabel.alpha = 0
        addSubview(countdownLabel)
    }

    /// The channel buttons, in the order the rooms are numbered. Hidden until the monitor is up.
    private func buildCamBar() {
        camBar.axis = .horizontal
        camBar.spacing = 5
        camBar.distribution = .fillEqually
        camBar.alpha = 0
        camBar.isUserInteractionEnabled = false
        addSubview(camBar)

        for room in FiveNightsSchool.cameras {
            let number = FiveNightsSchool.cameraNumber(of: room)
            let button = Self.controlButton("\(number)", sized: false)
            button.addTarget(self, action: #selector(camTapped), for: .touchUpInside)
            camButtons.append((button, room))
            camBar.addArrangedSubview(button)
        }
    }

    private func buildBanner() {
        addSubview(bannerPanel)
        style(bannerTitle, size: 26, color: .white, weight: .heavy)
        bannerTitle.textAlignment = .center
        style(bannerSubtitle, size: 13, color: Theme.textMuted, weight: .semibold)
        bannerSubtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [bannerTitle, bannerSubtitle])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.contentView.addSubview(stack)
        bannerPanel.alpha = 0

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bannerPanel.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bannerPanel.contentView.bottomAnchor,
                                          constant: -12),
            stack.leadingAnchor.constraint(equalTo: bannerPanel.contentView.leadingAnchor,
                                           constant: 26),
            stack.trailingAnchor.constraint(equalTo: bannerPanel.contentView.trailingAnchor,
                                            constant: -26),
        ])
    }

    private func buildOverPanel() {
        addSubview(overPanel)
        overPanel.isHidden = true

        style(overTitle, size: 24, color: .white, weight: .heavy)
        overTitle.textAlignment = .center
        style(overDetail, size: 14, color: Theme.textMuted, weight: .regular)
        overDetail.textAlignment = .center
        overDetail.numberOfLines = 0

        nextNightButton.addTarget(self, action: #selector(nextNightTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        leaveButton.addTarget(self, action: #selector(leaveTapped), for: .touchUpInside)
        for button in [nextNightButton, retryButton, leaveButton] {
            button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        }

        let stack = UIStackView(arrangedSubviews: [overTitle, overDetail, nextNightButton,
                                                   retryButton, leaveButton])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(16, after: overDetail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        overPanel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: overPanel.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: overPanel.contentView.bottomAnchor,
                                          constant: -22),
            stack.leadingAnchor.constraint(equalTo: overPanel.contentView.leadingAnchor,
                                           constant: 22),
            stack.trailingAnchor.constraint(equalTo: overPanel.contentView.trailingAnchor,
                                            constant: -22),
        ])
    }

    private func buildHint() {
        style(hint, size: 12, color: Theme.textMuted, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "One door out, on CAM 7 · when somebody reaches it you have 7 seconds · "
            + "watching a room freezes whoever is in it, but the cameras cost power"
        addSubview(hint)
    }

    private func layoutEverything() {
        for view in [statusPanel, mainDoorButton, camerasButton, countdownLabel,
                     camBar, bannerPanel, overPanel, hint, scanlines, staticFlash,
                     nightVision, vignette, recDot, stampLabel, camLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }

        let guide = safeAreaLayoutGuide
        var constraints: [NSLayoutConstraint] = [
            statusPanel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 10),
            statusPanel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),

            camLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 16),
            camLabel.centerXAnchor.constraint(equalTo: centerXAnchor),

            stampLabel.topAnchor.constraint(equalTo: camLabel.bottomAnchor, constant: 4),
            stampLabel.centerXAnchor.constraint(equalTo: centerXAnchor, constant: 10),
            recDot.centerYAnchor.constraint(equalTo: stampLabel.centerYAnchor),
            recDot.trailingAnchor.constraint(equalTo: stampLabel.leadingAnchor, constant: -6),
            recDot.widthAnchor.constraint(equalToConstant: 8),
            recDot.heightAnchor.constraint(equalToConstant: 8),

            // **The door button is the big one, on the left, where a thumb already is.** The
            // monitor sits beside it. Two buttons and nothing else along the bottom, because
            // there are only two things you can do.
            mainDoorButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            mainDoorButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
            mainDoorButton.heightAnchor.constraint(equalToConstant: 60),
            mainDoorButton.widthAnchor.constraint(equalToConstant: 168),

            camerasButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -14),
            camerasButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),
            camerasButton.heightAnchor.constraint(equalToConstant: 60),
            camerasButton.widthAnchor.constraint(equalToConstant: 140),

            countdownLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -120),

            // **Above the door buttons, not beside them.** Seven channels centred on the same
            // row as two 104-point door buttons is 280 points of stack in whatever is left of a
            // portrait screen, and the first build had "CAM 1" sitting on top of "WEST DOOR".
            camBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            camBar.bottomAnchor.constraint(equalTo: mainDoorButton.topAnchor, constant: -10),
            camBar.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor,
                                            constant: 14),
            camBar.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor,
                                             constant: -14),
            camBar.widthAnchor.constraint(equalToConstant: 322),
            camBar.heightAnchor.constraint(equalToConstant: 38),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: camBar.topAnchor, constant: -14),
            hint.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor, multiplier: 0.62),

            bannerPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            // High, not centred: the middle of the picture is where the child you are looking
            // for is standing, and a banner over the top of them defeats the camera.
            bannerPanel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -200),

            overPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            overPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            overPanel.widthAnchor.constraint(equalToConstant: 320),
        ]

        for layer in [scanlines, staticFlash, nightVision, vignette] {
            constraints += [
                layer.topAnchor.constraint(equalTo: topAnchor),
                layer.bottomAnchor.constraint(equalTo: bottomAnchor),
                layer.leadingAnchor.constraint(equalTo: leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Buttons

    /// A chunky dark button that can be lit up when whatever it controls is switched on.
    ///
    /// `sized` is off for the seven channel buttons: those are laid out by the stack view that
    /// holds them, and a button that also insists on its own 38×104 fights it.
    private static func controlButton(_ title: String, sized: Bool = true) -> UIButton {
        let button = Theme.makePlainButton()
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Theme.body(13, weight: .heavy)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        button.layer.cornerRadius = 9
        button.layer.cornerCurve = .continuous
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        // Sized by constraint rather than by content insets: `contentEdgeInsets` is deprecated,
        // and its replacement lives on `UIButton.Configuration`, which `Theme.makePlainButton`
        // deliberately turns off so a title can still be set after the fact.
        if sized {
            button.heightAnchor.constraint(equalToConstant: 38).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        }
        return button
    }

    private func setLit(_ button: UIButton, _ lit: Bool, color: UIColor) {
        button.backgroundColor = lit ? color : UIColor(white: 0.1, alpha: 0.7)
        button.layer.borderColor = (lit ? color : UIColor(white: 1, alpha: 0.25)).cgColor
    }

    @objc private func mainDoorTapped() { game?.toggleMainDoor() }

    @objc private func camerasTapped() {
        guard let game else { return }
        game.setTablet(!game.tabletUp)
    }

    @objc private func camTapped(_ sender: UIButton) {
        guard let entry = camButtons.first(where: { $0.button === sender }) else { return }
        game?.selectCam(entry.room)
    }

    @objc private func nextNightTapped() {
        overPanel.isHidden = true
        game?.nextNight()
    }

    @objc private func retryTapped() {
        overPanel.isHidden = true
        game?.retryNight()
    }

    @objc private func leaveTapped() {
        game?.requestExit()
    }

    // MARK: - Lifecycle

    func present(game: FiveNightsGame) {
        self.game = game
        isHidden = false
        overPanel.isHidden = true
        hint.alpha = 1
        lastStepTime = nil
        lastFlashToken = game.camFlashToken

        game.onPresentationChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func dismiss() {
        isHidden = true
        game?.onPresentationChanged = nil
        game = nil
    }

    /// Once per rendered frame, after the simulation has stepped. The clock and the power change
    /// every frame so they live here; the buttons change rarely and go through `refresh()`.
    func step() {
        guard !isHidden, let game else { return }

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - (lastStepTime ?? now)))
        lastStepTime = now

        clockLabel.text = game.clockText
        clockFillWidth.constant = 108 * CGFloat(game.nightProgress)
        powerLabel.text = "\(Int(game.power.rounded()))%"
        // Yellow while there is plenty, red once there is not — the number is the whole game and
        // it should change colour before it changes to a problem.
        powerLabel.textColor = game.power < 25 ? Theme.danger : UIColor(hex: 0xf5c518)

        // The feed changed: a flash of static, fading out over about a third of a second.
        if game.camFlashToken != lastFlashToken {
            lastFlashToken = game.camFlashToken
            staticFlash.alpha = 0.55
        }
        staticFlash.alpha = max(0, staticFlash.alpha - CGFloat(dt) * 1.8)

        // **One eased number drives every layer of the feed**, rather than each of them easing
        // itself: they have to come up together or the green arrives before the scan lines and
        // the monitor looks like it is booting.
        let monitorWanted: CGFloat = game.tabletUp ? 1 : 0
        monitorAlpha += (monitorWanted - monitorAlpha) * CGFloat(1 - exp(-12 * dt))

        // The feed breathes: the green cast wobbles, and the recording dot blinks about once a
        // second. Both are cheap, and a picture that is perfectly still reads as a screenshot
        // rather than as a camera.
        feedClock += dt
        let flicker = CGFloat(0.9 + 0.1 * sin(feedClock * 5.5))
        nightVision.alpha = monitorAlpha * flicker
        vignette.alpha = monitorAlpha
        scanlines.alpha = monitorAlpha * 0.85
        camLabel.alpha = monitorAlpha
        camBar.alpha = monitorAlpha
        stampLabel.alpha = monitorAlpha
        camBar.isUserInteractionEnabled = game.tabletUp
        recDot.alpha = game.tabletUp && sin(feedClock * 3.2) > -0.2 ? 1 : 0

        // **The seven seconds**, shown only to somebody who spent the power looking at CAM 7.
        // It flashes under two seconds, because at that point the shutter will only just make it.
        if let left = game.exitCountdown, game.watchingExit {
            countdownLabel.text = String(format: "%.1f", left)
            let urgent = left < 2 && sin(feedClock * 18) > 0
            countdownLabel.textColor = urgent ? .white : Theme.danger
            countdownLabel.alpha = 1
        } else {
            fade(countdownLabel, to: 0, rate: 8, dt: dt)
        }

        // 12 AM through 6 AM with the seconds running, which is the one thing on screen that
        // proves the picture is live.
        stampLabel.text = String(format: "%@ · %02d · CCTV-%d", game.clockText,
                                 Int(game.elapsed) % 60, game.cameraNumber)

        let bannerWanted: CGFloat = (game.announcement == nil || !overPanel.isHidden) ? 0 : 1
        fade(bannerPanel, to: bannerWanted, rate: 9, dt: dt)
        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        // The instructions go once the first hour has been survived — by then they have either
        // been read or worked out.
        fade(hint, to: game.hour >= 1 ? 0 : 1, rate: 2.5, dt: dt)

        if game.phase != .onDuty, overPanel.isHidden {
            showOverPanel(for: game)
        }
        if game.phase == .onDuty, !overPanel.isHidden {
            overPanel.isHidden = true
        }
    }

    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    private func showOverPanel(for game: FiveNightsGame) {
        overPanel.isHidden = false
        bannerPanel.alpha = 0
        hint.alpha = 0

        overTitle.text = game.endTitle
        overDetail.text = game.endDetail
        // Only offer the next night when there is one and it has been earned.
        nextNightButton.isHidden = game.phase != .survived
            || game.night >= FiveNightsGame.Tuning.nights
        retryButton.setTitle(game.phase == .survived ? "Play that night again" : "Try again",
                             for: .normal)
    }

    /// Everything that changes rarely: which buttons are lit, and which camera is selected.
    private func refresh() {
        guard let game else { return }

        nightLabel.text = "NIGHT \(game.night)"
        setLit(mainDoorButton, game.mainDoorClosed, color: Theme.danger)
        mainDoorButton.setTitle(game.mainDoorClosed ? "DOOR SHUT" : "MAIN DOOR", for: .normal)
        // While Barry has the fuse the monitor is dead: greyed out, and titled with what is
        // actually wrong rather than left looking like it still works.
        setLit(camerasButton, game.tabletUp, color: Theme.primary)
        camerasButton.setTitle(game.camerasBroken ? "NO SIGNAL" : "CAMERAS", for: .normal)
        camerasButton.setTitleColor(game.camerasBroken ? Theme.textMuted : .white, for: .normal)

        for (button, room) in camButtons {
            setLit(button, game.tabletUp && game.currentCam == room, color: Theme.primary)
        }
        camLabel.text = "CAM \(game.cameraNumber) · \(game.cameraName.uppercased())"

        let bars = game.usageBars
        for (index, block) in usageBlocks.enumerated() {
            block.alpha = index < bars ? 1 : 0.18
        }
    }

    private func style(_ label: UILabel, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        label.font = Theme.body(size, weight: weight)
        label.textColor = color
    }
}
