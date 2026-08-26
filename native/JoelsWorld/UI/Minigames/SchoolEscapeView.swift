import UIKit
import QuartzCore

/// School Escape's screen furniture: the thumbstick, the key counter, the announcement banner,
/// the red edges while Mr Hardy is after you, the flash when he gets you, and the escape panel.
///
/// Like `FootballView` this draws none of the world — the school, the keys and both characters
/// come out of the Metal renderer behind it. The stick is the overworld's own `JoystickView`,
/// second instance, same as football.
final class SchoolEscapeView: UIView {

    // MARK: - Subviews

    private let statusPanel = Theme.glassPanel(cornerRadius: 14)
    private let keysLabel = UILabel()
    private let clockLabel = UILabel()

    private let bannerPanel = Theme.glassPanel(cornerRadius: 16)
    private let bannerTitle = UILabel()
    private let bannerSubtitle = UILabel()

    private let stick = JoystickView()
    private let hint = UILabel()

    /// The chase vignette: a thick red border that pulses while Mr Hardy has you in his sights.
    private let chaseEdge = UIView()
    /// The jumpscare: a full-screen flash with the word on it, over the camera's dive into
    /// Mr Hardy's face.
    private let scareFlash = UIView()
    private let scareLabel = UILabel()

    private let overPanel = Theme.glassPanel(cornerRadius: 18)
    private let overTitle = UILabel()
    private let overDetail = UILabel()
    private let playAgainButton = Theme.button(title: "Escape again", color: Theme.success,
                                               filled: true)
    private let leaveButton = Theme.button(title: "Back to bed", color: Theme.danger)

    private var game: SchoolEscapeGame?
    private var lastStepTime: CFTimeInterval?
    private var wasCaught = false

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

        buildChaseEdge()
        buildStatusPanel()
        buildBanner()
        buildControls()
        buildScareFlash()
        buildOverPanel()
    }

    /// 🔑 2/4 and the clock, top centre.
    private func buildStatusPanel() {
        addSubview(statusPanel)
        statusPanel.translatesAutoresizingMaskIntoConstraints = false

        // Plain words, not a key emoji — the HUD font has no colour-emoji fallback and drew a
        // question-mark box.
        style(keysLabel, size: 20, color: UIColor(hex: 0xffd94d), weight: .heavy)
        keysLabel.text = "KEYS 0/4"
        style(clockLabel, size: 14, color: Theme.textMuted, weight: .semibold)
        clockLabel.text = "0:00"
        clockLabel.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [keysLabel, clockLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            statusPanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            statusPanel.centerXAnchor.constraint(equalTo: centerXAnchor),

            column.topAnchor.constraint(equalTo: statusPanel.contentView.topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: statusPanel.contentView.bottomAnchor,
                                           constant: -8),
            column.leadingAnchor.constraint(equalTo: statusPanel.contentView.leadingAnchor,
                                            constant: 18),
            column.trailingAnchor.constraint(equalTo: statusPanel.contentView.trailingAnchor,
                                             constant: -18),
        ])
    }

    private func buildBanner() {
        addSubview(bannerPanel)
        bannerPanel.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.alpha = 0

        style(bannerTitle, size: 30, color: .white, weight: .heavy)
        style(bannerSubtitle, size: 14, color: Theme.textMuted, weight: .semibold)
        bannerTitle.textAlignment = .center
        bannerSubtitle.textAlignment = .center
        // "MR HARDY IS LOCKING YOU IN!" is wider than a portrait phone at 30 pt; shrink to
        // fit rather than crop to "R HARDY IS LOCKING YOU I".
        bannerTitle.adjustsFontSizeToFitWidth = true
        bannerTitle.minimumScaleFactor = 0.5

        let column = UIStackView(arrangedSubviews: [bannerTitle, bannerSubtitle])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            bannerPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerPanel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -70),
            bannerPanel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),

            column.topAnchor.constraint(equalTo: bannerPanel.contentView.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: bannerPanel.contentView.bottomAnchor,
                                           constant: -12),
            column.leadingAnchor.constraint(equalTo: bannerPanel.contentView.leadingAnchor,
                                            constant: 28),
            column.trailingAnchor.constraint(equalTo: bannerPanel.contentView.trailingAnchor,
                                             constant: -28),
        ])
    }

    private func buildControls() {
        addSubview(stick)
        stick.translatesAutoresizingMaskIntoConstraints = false

        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        style(hint, size: 14, color: .white, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "Walk over the glowing keys — all 4 open the chest.\nIf Mr Hardy sees you, RUN."

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stick.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            stick.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -32),
            stick.widthAnchor.constraint(equalToConstant: 130),
            stick.heightAnchor.constraint(equalToConstant: 130),

            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: stick.topAnchor, constant: -14),
        ])
    }

    private func buildChaseEdge() {
        addSubview(chaseEdge)
        chaseEdge.translatesAutoresizingMaskIntoConstraints = false
        chaseEdge.isUserInteractionEnabled = false
        chaseEdge.layer.borderColor = UIColor(hex: 0xff2d2d).cgColor
        chaseEdge.layer.borderWidth = 10
        chaseEdge.alpha = 0

        NSLayoutConstraint.activate([
            chaseEdge.topAnchor.constraint(equalTo: topAnchor),
            chaseEdge.bottomAnchor.constraint(equalTo: bottomAnchor),
            chaseEdge.leadingAnchor.constraint(equalTo: leadingAnchor),
            chaseEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func buildScareFlash() {
        addSubview(scareFlash)
        scareFlash.translatesAutoresizingMaskIntoConstraints = false
        scareFlash.isUserInteractionEnabled = false
        scareFlash.backgroundColor = UIColor(hex: 0x8a0000)
        scareFlash.alpha = 0

        style(scareLabel, size: 54, color: .white, weight: .heavy)
        scareLabel.text = "CAUGHT!"
        scareLabel.textAlignment = .center
        scareLabel.translatesAutoresizingMaskIntoConstraints = false
        scareFlash.addSubview(scareLabel)

        NSLayoutConstraint.activate([
            scareFlash.topAnchor.constraint(equalTo: topAnchor),
            scareFlash.bottomAnchor.constraint(equalTo: bottomAnchor),
            scareFlash.leadingAnchor.constraint(equalTo: leadingAnchor),
            scareFlash.trailingAnchor.constraint(equalTo: trailingAnchor),

            scareLabel.centerXAnchor.constraint(equalTo: scareFlash.centerXAnchor),
            scareLabel.centerYAnchor.constraint(equalTo: scareFlash.centerYAnchor),
        ])
    }

    private func buildOverPanel() {
        addSubview(overPanel)
        overPanel.translatesAutoresizingMaskIntoConstraints = false
        overPanel.isHidden = true

        style(overTitle, size: 28, color: .white, weight: .heavy)
        style(overDetail, size: 15, color: Theme.textMuted, weight: .medium)
        overTitle.textAlignment = .center
        overTitle.text = "YOU ESCAPED!"
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

    private func style(_ label: UILabel, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        label.font = Theme.body(size, weight: weight)
        label.textColor = color
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
    }

    // MARK: - Input

    @objc private func playAgainTapped() {
        overPanel.isHidden = true
        hint.alpha = 1
        game?.restartRun()
    }

    @objc private func leaveTapped() {
        game?.requestExit()
    }

    // MARK: - Lifecycle

    func present(game: SchoolEscapeGame) {
        self.game = game
        isHidden = false
        hint.alpha = 1
        overPanel.isHidden = true
        scareFlash.alpha = 0
        chaseEdge.alpha = 0
        wasCaught = false
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

        clockLabel.text = game.clockText

        let bannerWanted: CGFloat = (game.announcement == nil || !overPanel.isHidden) ? 0 : 1
        fade(bannerPanel, to: bannerWanted, rate: 9, dt: dt)
        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        // The red edges breathe while he is after you.
        if game.isBeingChased {
            let pulse = 0.55 + 0.35 * sin(now * 7)
            chaseEdge.alpha = CGFloat(pulse)
        } else {
            fade(chaseEdge, to: 0, rate: 6, dt: dt)
        }

        // The flash slams on with the catch and burns off over the jumpscare.
        if game.isCaught {
            if !wasCaught {
                wasCaught = true
                scareFlash.alpha = 0.9
            } else {
                fade(scareFlash, to: 0, rate: 1.6, dt: dt)
            }
        } else {
            wasCaught = false
            fade(scareFlash, to: 0, rate: 8, dt: dt)
        }

        if game.phase == .escaped, overPanel.isHidden {
            overPanel.isHidden = false
            hint.alpha = 0
            overDetail.text = game.endDetail
        }
        if game.phase != .escaped, !overPanel.isHidden {
            overPanel.isHidden = true
        }

        fade(hint, to: game.keysHeld > 0 ? 0 : 1, rate: 1.2, dt: dt)
    }

    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    /// Everything that changes rarely: the key count.
    private func refresh() {
        guard let game else { return }
        keysLabel.text = "KEYS \(game.keysHeld)/\(game.totalKeys)"
    }
}
