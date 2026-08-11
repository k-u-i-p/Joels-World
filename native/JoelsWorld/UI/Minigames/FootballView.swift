import UIKit
import QuartzCore

/// Football's screen furniture and its two controls: a thumbstick to run with and a button to
/// kick with.
///
/// Like `Tennis3DView` and `SchoolRushView` this draws nothing — the pitch, the ball and all
/// twenty players come out of the Metal renderer behind it. What is here is a transparent layer
/// that catches touches and puts numbers on top.
///
/// **The stick is the overworld's own `JoystickView`**, not a copy of it. Running about is
/// running about, and the one thing worse than a minigame with unfamiliar controls is a minigame
/// whose controls are *nearly* the familiar ones. The overworld's stick is hidden while a
/// minigame is up, so this is a second instance of the same class rather than a borrowed one.
final class FootballView: UIView {

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
    private let kickButton = UIButton(type: .custom)

    private let hint = UILabel()

    private let overPanel = Theme.glassPanel(cornerRadius: 18)
    private let overTitle = UILabel()
    private let overDetail = UILabel()
    private let playAgainButton = Theme.button(title: "Play again", color: Theme.success,
                                               filled: true)
    private let leaveButton = Theme.button(title: "Back to school", color: Theme.danger)

    private var game: FootballGame?
    /// When `step()` last ran, so the fades are measured in seconds rather than in frames.
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
        buildOverPanel()
        buildHint()
    }

    /// BLUE 1 – 0 RED, across the top. The team names are in their kit colours, because from a
    /// camera that follows the ball "which of these is me?" is otherwise a real question.
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
        targetLabel.text = "FIRST TO 3"
        targetLabel.textAlignment = .center

        let row = UIStackView(arrangedSubviews: [blueLabel, scoreLabel, redLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14

        let column = UIStackView(arrangedSubviews: [row, targetLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        scorePanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            scorePanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            scorePanel.centerXAnchor.constraint(equalTo: centerXAnchor),

            column.topAnchor.constraint(equalTo: scorePanel.contentView.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: scorePanel.contentView.bottomAnchor,
                                           constant: -8),
            column.leadingAnchor.constraint(equalTo: scorePanel.contentView.leadingAnchor,
                                            constant: 18),
            column.trailingAnchor.constraint(equalTo: scorePanel.contentView.trailingAnchor,
                                             constant: -18),
        ])
    }

    /// GO!, GOAL!, BLUE WIN! — the three things worth interrupting a match to say.
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
            column.bottomAnchor.constraint(equalTo: bannerPanel.contentView.bottomAnchor,
                                           constant: -12),
            column.leadingAnchor.constraint(equalTo: bannerPanel.contentView.leadingAnchor,
                                            constant: 28),
            column.trailingAnchor.constraint(equalTo: bannerPanel.contentView.trailingAnchor,
                                             constant: -28),
        ])
    }

    /// The stick on the left and the kick button on the right, at the same height and the same
    /// distance in — the layout every game with a thumb on each side of the phone uses.
    private func buildControls() {
        addSubview(stick)
        stick.translatesAutoresizingMaskIntoConstraints = false

        kickButton.translatesAutoresizingMaskIntoConstraints = false
        kickButton.setTitle("KICK", for: .normal)
        kickButton.titleLabel?.font = Theme.body(18, weight: .heavy)
        kickButton.setTitleColor(.white, for: .normal)
        kickButton.layer.cornerRadius = 47
        kickButton.layer.borderWidth = 2
        kickButton.addTarget(self, action: #selector(kickTapped), for: .touchDown)
        addSubview(kickButton)
        styleKickButton(armed: false)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stick.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            stick.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -32),
            stick.widthAnchor.constraint(equalToConstant: 130),
            stick.heightAnchor.constraint(equalToConstant: 130),

            kickButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -34),
            kickButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -54),
            kickButton.widthAnchor.constraint(equalToConstant: 94),
            kickButton.heightAnchor.constraint(equalToConstant: 94),
        ])
    }

    /// **The button says whether you can use it**, by lighting up when the ball is at your feet.
    /// Without that the only way to find out is to press it and watch nothing happen, and a
    /// button that does nothing most of the time gets mashed.
    private func styleKickButton(armed: Bool) {
        kickButton.backgroundColor = armed
            ? UIColor(hex: 0x2f9e44).withAlphaComponent(0.92)
            : UIColor(white: 1, alpha: 0.14)
        kickButton.layer.borderColor = armed
            ? UIColor.white.withAlphaComponent(0.9).cgColor
            : UIColor.white.withAlphaComponent(0.3).cgColor
        kickButton.setTitleColor(armed ? .white : UIColor(white: 1, alpha: 0.55), for: .normal)
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
        leaveButton.addTarget(self, action: #selector(leaveTapped), for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [overTitle, overDetail,
                                                    playAgainButton, leaveButton])
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
            column.bottomAnchor.constraint(equalTo: overPanel.contentView.bottomAnchor,
                                           constant: -22),
            column.leadingAnchor.constraint(equalTo: overPanel.contentView.leadingAnchor,
                                            constant: 22),
            column.trailingAnchor.constraint(equalTo: overPanel.contentView.trailingAnchor,
                                             constant: -22),
        ])
    }

    /// One line telling a ten-year-old what the controls are. It fades out once the match is
    /// plainly under way.
    private func buildHint() {
        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        style(hint, size: 14, color: .white, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "You play whoever has the yellow ring — it moves\n"
            + "to whichever team mate is nearest the ball"

        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: stick.topAnchor, constant: -14),
        ])
    }

    private func style(_ label: UILabel, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        label.font = Theme.body(size, weight: weight)
        label.textColor = color
        // A thin black shadow, because these sit over a bright green pitch.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
    }

    // MARK: - Input

    @objc private func kickTapped() {
        game?.kick()
    }

    @objc private func playAgainTapped() {
        overPanel.isHidden = true
        hint.alpha = 0
        game?.restartMatch()
    }

    @objc private func leaveTapped() {
        game?.requestExit()
    }

    // MARK: - Lifecycle

    func present(game: FootballGame) {
        self.game = game
        isHidden = false
        hint.alpha = 1
        overPanel.isHidden = true
        lastStepTime = nil

        game.onPresentationChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func dismiss() {
        isHidden = true
        game?.onPresentationChanged = nil
        game = nil
    }

    /// Once per rendered frame, after the simulation has stepped.
    ///
    /// **This is also where the stick is read.** The joystick reports a vector continuously
    /// rather than firing an event, so somebody has to sample it every frame — and the frame the
    /// renderer is already driving is the right somebody.
    func step() {
        guard !isHidden, let game else { return }

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - (lastStepTime ?? now)))
        lastStepTime = now

        game.setMoveInput(stick.state.move)
        styleKickButton(armed: game.humanHasBall)

        let bannerWanted: CGFloat = (game.announcement == nil || !overPanel.isHidden) ? 0 : 1
        fade(bannerPanel, to: bannerWanted, rate: 9, dt: dt)
        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        if game.phase == .over, overPanel.isHidden {
            showOverPanel(for: game)
        }
        // And it goes away whenever a match is under way, rather than only when its own button
        // was the thing that started one.
        if game.phase != .over, !overPanel.isHidden {
            overPanel.isHidden = true
        }

        fade(hint, to: game.blueScore + game.redScore > 0 ? 0 : 1, rate: 1.4, dt: dt)
    }

    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    private func showOverPanel(for game: FootballGame) {
        overPanel.isHidden = false
        hint.alpha = 0

        let won = game.blueScore > game.redScore
        overTitle.text = won ? "You win!" : "Red win"
        var lines = ["Full time: \(game.blueScore) – \(game.redScore)"]
        lines.append(won ? "Football badge earned." : "Have another go — first to 3.")
        overDetail.text = lines.joined(separator: "\n")
    }

    /// Everything that changes rarely: the score.
    private func refresh() {
        guard let game else { return }
        scoreLabel.text = "\(game.blueScore) – \(game.redScore)"
    }
}
