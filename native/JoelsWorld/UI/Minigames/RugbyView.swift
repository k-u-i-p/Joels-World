import UIKit
import QuartzCore

/// Rugby's screen furniture: the class picker, a scoreboard, a banner, a thumbstick — and no
/// button, because **a pass is a tap on the pitch**. Tap where you want the ball to land and it
/// is thrown there; tap with no ball and you dive at the carrier.
///
/// Like `FootballView` this draws none of the world. It is a transparent layer that catches
/// touches and puts numbers on top, and the stick is a second instance of the overworld's own
/// `JoystickView`.
final class RugbyView: UIView, UIGestureRecognizerDelegate {

    // MARK: - Subviews

    private let scorePanel = Theme.glassPanel(cornerRadius: 14)
    private let blueLabel = UILabel()
    private let scoreLabel = UILabel()
    private let redLabel = UILabel()
    private let targetLabel = UILabel()

    private let bannerPanel = Theme.glassPanel(cornerRadius: 16)
    private let bannerTitle = UILabel()
    private let bannerSubtitle = UILabel()

    private let stick = JoystickView()
    private let hint = UILabel()

    /// **The class picker**, up before the first whistle. Royal or Challenger, and a row saying
    /// which kind of match this is: against the computer now, online once Dad has done the server.
    private let pickPanel = Theme.glassPanel(cornerRadius: 18)
    private let pickTitle = UILabel()
    private var classButtons: [UIButton] = []
    private let modeNPC = UILabel()
    private let modeOnline = UILabel()

    private let overPanel = Theme.glassPanel(cornerRadius: 18)
    private let overTitle = UILabel()
    private let overDetail = UILabel()
    private let playAgainButton = Theme.button(title: "Play again", color: Theme.success,
                                               filled: true)
    private let changeClassButton = Theme.button(title: "Change player", color: Theme.primary)
    private let leaveButton = Theme.button(title: "Back to school", color: Theme.danger)

    private var game: RugbyGame?
    private var lastStepTime: CFTimeInterval?

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

        buildScorePanel()
        buildBanner()
        buildControls()
        buildPicker()
        buildOverPanel()
        buildHint()

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    private func buildScorePanel() {
        addSubview(scorePanel)
        scorePanel.translatesAutoresizingMaskIntoConstraints = false

        style(blueLabel, size: 16, color: UIColor(hex: 0x6fa8ff), weight: .heavy)
        blueLabel.text = "BLUE"
        style(redLabel, size: 16, color: UIColor(hex: 0xff8a78), weight: .heavy)
        redLabel.text = "RED"
        style(scoreLabel, size: 30, color: .white, weight: .heavy)
        scoreLabel.text = "0 – 0"
        style(targetLabel, size: 11, color: Theme.textMuted, weight: .semibold)
        targetLabel.text = "FIRST TO 3 TRIES"
        targetLabel.textAlignment = .center

        let row = UIStackView(arrangedSubviews: [blueLabel, scoreLabel, redLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14

        let column = UIStackView(arrangedSubviews: [row, targetLabel])
        column.axis = .vertical
        column.alignment = .center
        column.translatesAutoresizingMaskIntoConstraints = false
        scorePanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            scorePanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            scorePanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.topAnchor.constraint(equalTo: scorePanel.contentView.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: scorePanel.contentView.bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: scorePanel.contentView.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: scorePanel.contentView.trailingAnchor, constant: -18),
        ])
    }

    private func buildBanner() {
        addSubview(bannerPanel)
        bannerPanel.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.alpha = 0

        style(bannerTitle, size: 34, color: .white, weight: .heavy)
        style(bannerSubtitle, size: 14, color: Theme.textMuted, weight: .semibold)
        bannerTitle.textAlignment = .center
        bannerSubtitle.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [bannerTitle, bannerSubtitle])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            bannerPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerPanel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -70),
            column.topAnchor.constraint(equalTo: bannerPanel.contentView.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bannerPanel.contentView.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: bannerPanel.contentView.leadingAnchor, constant: 28),
            column.trailingAnchor.constraint(equalTo: bannerPanel.contentView.trailingAnchor, constant: -28),
        ])
    }

    private func buildControls() {
        addSubview(stick)
        stick.translatesAutoresizingMaskIntoConstraints = false
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stick.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            stick.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -32),
            stick.widthAnchor.constraint(equalToConstant: 130),
            stick.heightAnchor.constraint(equalToConstant: 130),
        ])
    }

    private func buildPicker() {
        addSubview(pickPanel)
        pickPanel.translatesAutoresizingMaskIntoConstraints = false
        pickPanel.isHidden = true

        style(pickTitle, size: 24, color: .white, weight: .heavy)
        pickTitle.text = "Pick your player"
        pickTitle.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [pickTitle])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false

        for (index, playerClass) in RugbyGame.PlayerClass.allCases.enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.layer.cornerRadius = 14
            button.layer.borderWidth = 2
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
            button.backgroundColor = (playerClass == .royal
                ? UIColor(hex: 0x2f6fd0) : UIColor(hex: 0xc9402f)).withAlphaComponent(0.85)
            button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.textAlignment = .center

            let title = NSMutableAttributedString(
                string: "\(playerClass.icon) \(playerClass.title)\n",
                attributes: [.font: Theme.body(20, weight: .heavy), .foregroundColor: UIColor.white])
            title.append(NSAttributedString(
                string: playerClass.blurb,
                attributes: [.font: Theme.body(13, weight: .semibold),
                             .foregroundColor: UIColor.white.withAlphaComponent(0.85)]))
            button.setAttributedTitle(title, for: .normal)
            button.addTarget(self, action: #selector(classTapped(_:)), for: .touchUpInside)
            classButtons.append(button)
            column.addArrangedSubview(button)
        }

        // The two kinds of match. Only one of them works today.
        style(modeNPC, size: 13, color: .white, weight: .heavy)
        modeNPC.text = "VS NPCs  ✓"
        modeNPC.textAlignment = .center
        style(modeOnline, size: 13, color: Theme.textMuted, weight: .semibold)
        modeOnline.text = "ONLINE — needs Dad's server first"
        modeOnline.textAlignment = .center
        let modes = UIStackView(arrangedSubviews: [modeNPC, modeOnline])
        modes.axis = .vertical
        modes.spacing = 2
        column.addArrangedSubview(modes)
        column.setCustomSpacing(16, after: classButtons[classButtons.count - 1])

        pickPanel.contentView.addSubview(column)
        NSLayoutConstraint.activate([
            pickPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            pickPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pickPanel.widthAnchor.constraint(equalToConstant: 320),
            column.topAnchor.constraint(equalTo: pickPanel.contentView.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: pickPanel.contentView.bottomAnchor, constant: -20),
            column.leadingAnchor.constraint(equalTo: pickPanel.contentView.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: pickPanel.contentView.trailingAnchor, constant: -20),
        ])
    }

    private func buildOverPanel() {
        addSubview(overPanel)
        overPanel.translatesAutoresizingMaskIntoConstraints = false
        overPanel.isHidden = true

        style(overTitle, size: 28, color: .white, weight: .heavy)
        style(overDetail, size: 15, color: Theme.textMuted, weight: .medium)
        overTitle.textAlignment = .center
        overDetail.textAlignment = .center
        overDetail.numberOfLines = 0

        playAgainButton.addTarget(self, action: #selector(playAgainTapped), for: .touchUpInside)
        changeClassButton.addTarget(self, action: #selector(changeClassTapped), for: .touchUpInside)
        leaveButton.addTarget(self, action: #selector(leaveTapped), for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [overTitle, overDetail, playAgainButton,
                                                    changeClassButton, leaveButton])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 12
        column.setCustomSpacing(18, after: overDetail)
        column.translatesAutoresizingMaskIntoConstraints = false
        overPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            overPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            overPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            overPanel.widthAnchor.constraint(equalToConstant: 300),
            column.topAnchor.constraint(equalTo: overPanel.contentView.topAnchor, constant: 22),
            column.bottomAnchor.constraint(equalTo: overPanel.contentView.bottomAnchor, constant: -22),
            column.leadingAnchor.constraint(equalTo: overPanel.contentView.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: overPanel.contentView.trailingAnchor, constant: -22),
        ])
    }

    private func buildHint() {
        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        style(hint, size: 14, color: .white, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "Tap the pitch to throw the ball there. No ball? Tap to dive.\n"
            + "You play whoever has the yellow ring"
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: stick.topAnchor, constant: -14),
        ])
    }

    private func style(_ label: UILabel, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        label.font = Theme.body(size, weight: weight)
        label.textColor = color
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
    }

    // MARK: - Input

    /// A tap is only a pass if it landed on the pitch — not on the stick, not on a button.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let view = touch.view else { return true }
        if view is UIControl { return false }
        for panel in [stick, pickPanel, overPanel, scorePanel] as [UIView]
        where view.isDescendant(of: panel) { return false }
        return true
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        handleTap(at: recognizer.location(in: self))
    }

    /// The line a tap does its work on — separate so a test can enter here with a point.
    func handleTap(at point: CGPoint) {
        guard let game, bounds.width > 0, bounds.height > 0 else { return }
        let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1,
                               1 - Float(point.y / bounds.height) * 2)
        guard let ground = game.groundPoint(ndc: ndc) else { return }
        #if DEBUG
        // One line per tap, so a run with `-rugbytrace` shows where a finger landed on the grass.
        // This is how tap-to-pass was proved to work from the glass down, not just from `tap()`.
        Log.world(String(format: "[Rugby] tap at (%.0f, %.0f) → (%.1f, %.1f) m",
                         point.x, point.y,
                         ground.x / RugbyPitch.unitsPerMetre, ground.y / RugbyPitch.unitsPerMetre))
        #endif
        game.tap(worldX: ground.x, worldY: ground.y)
    }

    @objc private func classTapped(_ sender: UIButton) {
        let classes = RugbyGame.PlayerClass.allCases
        guard classes.indices.contains(sender.tag) else { return }
        pickPanel.isHidden = true
        hint.alpha = 1
        game?.choose(classes[sender.tag])
    }

    @objc private func playAgainTapped() {
        overPanel.isHidden = true
        hint.alpha = 0
        game?.restartMatch()
    }

    @objc private func changeClassTapped() {
        overPanel.isHidden = true
        game?.returnToChoosing()
        pickPanel.isHidden = false
    }

    @objc private func leaveTapped() {
        game?.requestExit()
    }

    // MARK: - Lifecycle

    func present(game: RugbyGame) {
        self.game = game
        isHidden = false
        hint.alpha = 0
        overPanel.isHidden = true
        pickPanel.isHidden = game.phase != .choosing
        lastStepTime = nil
        game.onPresentationChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func dismiss() {
        isHidden = true
        game?.onPresentationChanged = nil
        game = nil
    }

    /// Once per rendered frame. This is where the stick is read — see `FootballView.step()`.
    func step() {
        guard !isHidden, let game else { return }

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - (lastStepTime ?? now)))
        lastStepTime = now

        game.setMoveInput(stick.state.move)

        let bannerWanted: CGFloat = (game.announcement == nil || !overPanel.isHidden
                                     || !pickPanel.isHidden) ? 0 : 1
        fade(bannerPanel, to: bannerWanted, rate: 9, dt: dt)
        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        if game.phase == .over, overPanel.isHidden { showOverPanel(for: game) }
        if game.phase != .over, !overPanel.isHidden { overPanel.isHidden = true }
        // The demo picks a class from code, so the picker has to follow the phase, not the tap.
        if game.phase != .choosing, !pickPanel.isHidden { pickPanel.isHidden = true }
        if game.phase == .choosing, pickPanel.isHidden { pickPanel.isHidden = false }

        let hintWanted: CGFloat = pickPanel.isHidden && game.blueScore + game.redScore == 0 ? 1 : 0
        fade(hint, to: hintWanted, rate: 1.4, dt: dt)
    }

    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    private func showOverPanel(for game: RugbyGame) {
        overPanel.isHidden = false
        hint.alpha = 0
        let won = game.blueScore > game.redScore
        overTitle.text = won ? "You win!" : "Red win"
        var lines = ["Full time: \(game.blueScore) – \(game.redScore)"]
        if let playerClass = game.playerClass { lines.append("Played as \(playerClass.title)") }
        lines.append(won ? "Rugby badge earned." : "Have another go — first to 3 tries.")
        overDetail.text = lines.joined(separator: "\n")
    }

    private func refresh() {
        guard let game else { return }
        scoreLabel.text = "\(game.blueScore) – \(game.redScore)"
    }
}
