import UIKit
import QuartzCore

/// Destroy the World's screen furniture: the score, how much of the world is gone, the combo
/// counter, the big **ULTIMATE COMBO** banner, the "+50 FROZEN!" pop-ups, the crosshair and
/// the FIRE button.
///
/// Like `SchoolEscapeView` it draws none of the world — the train, the fields and every flame
/// come out of the Metal renderer behind it.
///
/// **Controls.** Hold FIRE to shoot. Drag anywhere to look round and aim — and you can drag the
/// FIRE button itself while holding it, so one thumb can do both.
final class DestroyWorldView: UIView, UIGestureRecognizerDelegate {

    // MARK: - Subviews

    private let warmTint = UIView()

    private let scorePanel = Theme.glassPanel(cornerRadius: 14)
    private let scoreLabel = UILabel()
    private let bestLabel = UILabel()

    private let worldPanel = Theme.glassPanel(cornerRadius: 14)
    private let worldLabel = UILabel()
    private let worldTrack = UIView()
    private let worldFill = UIView()
    private var worldFillWidth: NSLayoutConstraint?

    private let comboPanel = Theme.glassPanel(cornerRadius: 14)
    private let comboLabel = UILabel()
    private let multiplierLabel = UILabel()
    private let comboTrack = UIView()
    private let comboFill = UIView()
    private var comboFillWidth: NSLayoutConstraint?

    private let bannerTitle = UILabel()
    private let bannerSubtitle = UILabel()

    private let crosshair = UIView()
    private var crosshairY: NSLayoutConstraint?

    private let fireButton = FireButton()
    private let restartButton = UIButton(type: .custom)
    private let hint = UILabel()

    private var game: DestroyWorldGame?
    private var lastStepTime: CFTimeInterval?
    private var lastBannerSerial = -1
    private var hasScored = false

    /// How far a drag turns you: radians per point.
    private let lookSensitivity = 0.0075

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
        isMultipleTouchEnabled = true

        warmTint.translatesAutoresizingMaskIntoConstraints = false
        warmTint.isUserInteractionEnabled = false
        warmTint.backgroundColor = UIColor(red: 1, green: 0.35, blue: 0.05, alpha: 1)
        warmTint.alpha = 0
        addSubview(warmTint)
        NSLayoutConstraint.activate([
            warmTint.topAnchor.constraint(equalTo: topAnchor),
            warmTint.bottomAnchor.constraint(equalTo: bottomAnchor),
            warmTint.leadingAnchor.constraint(equalTo: leadingAnchor),
            warmTint.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        buildWorldMeter()
        buildScore()
        buildCombo()
        buildBanner()
        buildCrosshair()
        buildControls()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    private func buildScore() {
        addSubview(scorePanel)
        scorePanel.translatesAutoresizingMaskIntoConstraints = false
        style(scoreLabel, font: Theme.display(30), color: UIColor(hex: 0xffd94d))
        style(bestLabel, font: Theme.body(13, weight: .semibold), color: Theme.textMuted)
        scoreLabel.text = "0"
        bestLabel.text = "BEST 0"

        let column = UIStackView(arrangedSubviews: [scoreLabel, bestLabel])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        scorePanel.contentView.addSubview(column)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Under the world meter rather than beside it, so a narrow phone has room for both.
            scorePanel.topAnchor.constraint(equalTo: worldPanel.bottomAnchor, constant: 8),
            scorePanel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 14),
            column.topAnchor.constraint(equalTo: scorePanel.contentView.topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: scorePanel.contentView.bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: scorePanel.contentView.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: scorePanel.contentView.trailingAnchor, constant: -16),
            scorePanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    private func buildWorldMeter() {
        addSubview(worldPanel)
        worldPanel.translatesAutoresizingMaskIntoConstraints = false
        style(worldLabel, font: Theme.body(13, weight: .heavy), color: .white)
        worldLabel.text = "WORLD DESTROYED 0%"
        worldLabel.textAlignment = .center

        worldTrack.translatesAutoresizingMaskIntoConstraints = false
        worldTrack.backgroundColor = UIColor(white: 1, alpha: 0.18)
        worldTrack.layer.cornerRadius = 4
        worldTrack.clipsToBounds = true
        worldFill.translatesAutoresizingMaskIntoConstraints = false
        worldFill.backgroundColor = UIColor(hex: 0xff6a1a)
        worldTrack.addSubview(worldFill)

        worldPanel.contentView.addSubview(worldLabel)
        worldPanel.contentView.addSubview(worldTrack)
        worldLabel.translatesAutoresizingMaskIntoConstraints = false

        let fill = worldFill.widthAnchor.constraint(equalToConstant: 0)
        worldFillWidth = fill
        NSLayoutConstraint.activate([
            worldPanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            worldPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            worldPanel.widthAnchor.constraint(equalToConstant: 210),

            worldLabel.topAnchor.constraint(equalTo: worldPanel.contentView.topAnchor, constant: 7),
            worldLabel.leadingAnchor.constraint(equalTo: worldPanel.contentView.leadingAnchor, constant: 10),
            worldLabel.trailingAnchor.constraint(equalTo: worldPanel.contentView.trailingAnchor, constant: -10),

            worldTrack.topAnchor.constraint(equalTo: worldLabel.bottomAnchor, constant: 5),
            worldTrack.leadingAnchor.constraint(equalTo: worldPanel.contentView.leadingAnchor, constant: 12),
            worldTrack.trailingAnchor.constraint(equalTo: worldPanel.contentView.trailingAnchor, constant: -12),
            worldTrack.heightAnchor.constraint(equalToConstant: 8),
            worldTrack.bottomAnchor.constraint(equalTo: worldPanel.contentView.bottomAnchor, constant: -9),

            worldFill.leadingAnchor.constraint(equalTo: worldTrack.leadingAnchor),
            worldFill.topAnchor.constraint(equalTo: worldTrack.topAnchor),
            worldFill.bottomAnchor.constraint(equalTo: worldTrack.bottomAnchor),
            fill,
        ])
    }

    private func buildCombo() {
        addSubview(comboPanel)
        comboPanel.translatesAutoresizingMaskIntoConstraints = false
        comboPanel.alpha = 0
        style(comboLabel, font: Theme.display(26), color: UIColor(hex: 0xff9f1a))
        comboLabel.adjustsFontSizeToFitWidth = true
        comboLabel.minimumScaleFactor = 0.5
        style(multiplierLabel, font: Theme.body(13, weight: .heavy), color: .white)
        comboLabel.textAlignment = .center
        multiplierLabel.textAlignment = .center

        comboTrack.translatesAutoresizingMaskIntoConstraints = false
        comboTrack.backgroundColor = UIColor(white: 1, alpha: 0.18)
        comboTrack.layer.cornerRadius = 3
        comboTrack.clipsToBounds = true
        comboFill.translatesAutoresizingMaskIntoConstraints = false
        comboFill.backgroundColor = UIColor(hex: 0xffd94d)
        comboTrack.addSubview(comboFill)

        let column = UIStackView(arrangedSubviews: [comboLabel, multiplierLabel, comboTrack])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        comboPanel.contentView.addSubview(column)

        let fill = comboFill.widthAnchor.constraint(equalToConstant: 0)
        comboFillWidth = fill
        NSLayoutConstraint.activate([
            comboPanel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 14),
            comboPanel.topAnchor.constraint(equalTo: scorePanel.bottomAnchor, constant: 10),
            comboPanel.widthAnchor.constraint(equalToConstant: 170),
            column.topAnchor.constraint(equalTo: comboPanel.contentView.topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: comboPanel.contentView.bottomAnchor, constant: -9),
            column.leadingAnchor.constraint(equalTo: comboPanel.contentView.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: comboPanel.contentView.trailingAnchor, constant: -12),
            comboTrack.heightAnchor.constraint(equalToConstant: 6),
            comboFill.leadingAnchor.constraint(equalTo: comboTrack.leadingAnchor),
            comboFill.topAnchor.constraint(equalTo: comboTrack.topAnchor),
            comboFill.bottomAnchor.constraint(equalTo: comboTrack.bottomAnchor),
            fill,
        ])
    }

    private func buildBanner() {
        for label in [bannerTitle, bannerSubtitle] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
            label.alpha = 0
            addSubview(label)
        }
        bannerTitle.adjustsFontSizeToFitWidth = true
        bannerTitle.minimumScaleFactor = 0.4
        style(bannerSubtitle, font: Theme.body(16, weight: .heavy), color: .white)

        NSLayoutConstraint.activate([
            bannerTitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerTitle.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),
            bannerTitle.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            bannerSubtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerSubtitle.topAnchor.constraint(equalTo: bannerTitle.bottomAnchor, constant: 2),
            bannerSubtitle.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    private func buildCrosshair() {
        crosshair.translatesAutoresizingMaskIntoConstraints = false
        crosshair.isUserInteractionEnabled = false
        crosshair.layer.cornerRadius = 13
        crosshair.layer.borderWidth = 2.5
        crosshair.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = UIColor(hex: 0xff6a1a)
        dot.layer.cornerRadius = 3
        crosshair.addSubview(dot)
        addSubview(crosshair)

        let y = crosshair.centerYAnchor.constraint(equalTo: centerYAnchor)
        crosshairY = y
        NSLayoutConstraint.activate([
            crosshair.centerXAnchor.constraint(equalTo: centerXAnchor),
            y,
            crosshair.widthAnchor.constraint(equalToConstant: 26),
            crosshair.heightAnchor.constraint(equalToConstant: 26),
            dot.centerXAnchor.constraint(equalTo: crosshair.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: crosshair.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    private func buildControls() {
        fireButton.translatesAutoresizingMaskIntoConstraints = false
        fireButton.onFiring = { [weak self] on in
            self?.game?.setFiring(on)
        }
        fireButton.onDrag = { [weak self] delta in
            self?.aim(by: delta)
        }
        addSubview(fireButton)

        restartButton.translatesAutoresizingMaskIntoConstraints = false
        restartButton.setTitle("NEW TRAIN", for: .normal)
        restartButton.titleLabel?.font = Theme.body(13, weight: .heavy)
        restartButton.setTitleColor(.white, for: .normal)
        restartButton.backgroundColor = UIColor(white: 1, alpha: 0.14)
        restartButton.layer.cornerRadius = 16
        restartButton.layer.borderWidth = 1.5
        restartButton.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        restartButton.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        addSubview(restartButton)

        hint.translatesAutoresizingMaskIntoConstraints = false
        style(hint, font: Theme.body(14, weight: .semibold), color: .white)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "Hold FIRE to burn things · drag to aim\nShoot a fire and it turns to ICE — then melt the ice!"
        hint.isUserInteractionEnabled = false
        addSubview(hint)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            fireButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -26),
            fireButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -26),
            fireButton.widthAnchor.constraint(equalToConstant: 118),
            fireButton.heightAnchor.constraint(equalToConstant: 118),

            restartButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            restartButton.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -18),
            restartButton.widthAnchor.constraint(equalToConstant: 112),
            restartButton.heightAnchor.constraint(equalToConstant: 34),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: fireButton.topAnchor, constant: -14),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    private func style(_ label: UILabel, font: UIFont, color: UIColor) {
        label.font = font
        label.textColor = color
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.75
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
    }

    // MARK: - Input

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let delta = pan.translation(in: self)
        pan.setTranslation(.zero, in: self)
        aim(by: delta)
    }

    /// Dragging right turns you right; dragging down aims lower.
    private func aim(by delta: CGPoint) {
        game?.aim(dx: -Double(delta.x) * lookSensitivity,
                  dy: Double(delta.y) * lookSensitivity * 0.7)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // The FIRE button does its own dragging, and the restart button is a button.
        guard let view = touch.view else { return true }
        return !view.isDescendant(of: fireButton) && !view.isDescendant(of: restartButton)
    }

    @objc private func restartTapped() {
        game?.restart()
        hasScored = false
        hint.alpha = 1
    }

    // MARK: - Lifecycle

    func present(game: DestroyWorldGame) {
        self.game = game
        isHidden = false
        hint.alpha = 1
        hasScored = false
        lastStepTime = nil
        lastBannerSerial = -1
        game.onPresentationChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func dismiss() {
        isHidden = true
        fireButton.reset()
        game?.onPresentationChanged = nil
        game = nil
    }

    #if DEBUG
    /// For `-destroyworlddemo`, which cannot press the button: show the button lit when the
    /// game is firing, so a screenshot tells the truth.
    func debugShowFiring(_ on: Bool) { fireButton.showPressed(on) }
    #endif

    /// Once per rendered frame.
    func step() {
        guard !isHidden, let game else { return }

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - (lastStepTime ?? now)))
        lastStepTime = now

        // The crosshair sits exactly where the flame is going.
        crosshairY?.constant = CGFloat(game.crosshairOffset) * bounds.height / 2

        // The world turns orange as you destroy it.
        warmTint.alpha = CGFloat(game.worldDestroyed * 0.16)

        // The combo bar runs down.
        comboFillWidth?.constant = CGFloat(game.comboTimeLeft) * (comboTrack.bounds.width)
        fade(comboPanel, to: game.combo >= 2 ? 1 : 0, rate: 10, dt: dt)

        stepBanner(game: game, now: now, dt: dt)

        for popup in game.takePopups() { showPopup(popup) }

        if !hasScored, game.score > 0 { hasScored = true }
        fade(hint, to: hasScored ? 0 : 1, rate: 1.5, dt: dt)
    }

    /// The big words in the middle. A combo banner is **rainbow**, and wobbles.
    private func stepBanner(game: DestroyWorldGame, now: CFTimeInterval, dt: Double) {
        guard let announcement = game.announcement else {
            fade(bannerTitle, to: 0, rate: 7, dt: dt)
            fade(bannerSubtitle, to: 0, rate: 7, dt: dt)
            return
        }

        let colour: UIColor
        if announcement.isCombo {
            let hue = CGFloat((now * 1.4).truncatingRemainder(dividingBy: 1))
            colour = UIColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
        } else {
            colour = UIColor(hex: 0xffd94d)
        }
        let size: CGFloat = announcement.isCombo ? 58 : 46
        bannerTitle.attributedText = NSAttributedString(string: announcement.text, attributes: [
            .font: Theme.display(size),
            .foregroundColor: colour,
            .strokeColor: UIColor.black,
            .strokeWidth: -4.0,
        ])
        bannerSubtitle.text = announcement.subtitle
        bannerTitle.alpha = 1
        bannerSubtitle.alpha = announcement.subtitle == nil ? 0 : 1

        if announcement.serial != lastBannerSerial {
            lastBannerSerial = announcement.serial
            // Slam in big and spring back to size.
            bannerTitle.transform = CGAffineTransform(scaleX: 1.9, y: 1.9).rotated(by: -0.12)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.45,
                           initialSpringVelocity: 0.8, options: [.allowUserInteraction]) {
                self.bannerTitle.transform = .identity
            }
        } else if announcement.isCombo, bannerTitle.layer.animationKeys()?.isEmpty ?? true {
            // A combo keeps wobbling while it is up.
            bannerTitle.transform = CGAffineTransform(rotationAngle: CGFloat(0.05 * sin(now * 14)))
                .scaledBy(x: 1 + CGFloat(0.04 * sin(now * 9)), y: 1 + CGFloat(0.04 * sin(now * 9)))
        }
    }

    /// "+50 FROZEN!" floating up from the crosshair and fading away.
    private func showPopup(_ popup: DestroyWorldGame.Popup) {
        let label = UILabel()
        let colour: UIColor
        switch popup.style {
        case .fire: colour = UIColor(hex: 0xff8c1a)
        case .ice: colour = UIColor(hex: 0x8fe3ff)
        case .melt: colour = UIColor(hex: 0x4da6ff)
        case .destroy: colour = UIColor(hex: 0xffd94d)
        case .info: colour = .white
        }
        label.attributedText = NSAttributedString(string: popup.text, attributes: [
            .font: Theme.display(26),
            .foregroundColor: colour,
            .strokeColor: UIColor.black,
            .strokeWidth: -4.0,
        ])
        label.sizeToFit()
        label.isUserInteractionEnabled = false
        let jitter = CGFloat.random(in: -70...70)
        label.center = CGPoint(x: crosshair.center.x + jitter, y: crosshair.center.y - 34)
        insertSubview(label, belowSubview: bannerTitle)

        label.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.18) {
            label.transform = CGAffineTransform(scaleX: 1.15, y: 1.15)
        }
        UIView.animate(withDuration: 1.1, delay: 0.15, options: [.curveEaseOut]) {
            label.center.y -= 90
            label.alpha = 0
            label.transform = .identity
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    /// The numbers that change only when something happens.
    private func refresh() {
        guard let game else { return }
        scoreLabel.text = "\(game.score)"
        bestLabel.text = "BEST \(game.best)"
        let percent = Int((game.worldDestroyed * 100).rounded(.down))
        worldLabel.text = game.destroyedCount > DestroyWorldGame.Tuning.worldSize
            ? "WORLD DESTROYED! +\(game.destroyedCount - DestroyWorldGame.Tuning.worldSize)"
            : "WORLD DESTROYED \(percent)%"
        worldFillWidth?.constant = CGFloat(game.worldDestroyed) * worldTrack.bounds.width
        if game.combo >= 2 {
            comboLabel.text = "COMBO x\(game.combo)"
            multiplierLabel.text = "POINTS x\(game.multiplier)"
        }
    }
}

/// The big round FIRE button. Held down, it fires; dragged while held, it aims.
private final class FireButton: UIView {
    var onFiring: ((Bool) -> Void)?
    var onDrag: ((CGPoint) -> Void)?

    private let label = UILabel()
    private var trackedTouch: UITouch?
    private var lastPoint: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        backgroundColor = UIColor(hex: 0xe8590c).withAlphaComponent(0.78)
        layer.cornerRadius = 59
        layer.borderWidth = 3
        layer.borderColor = UIColor(hex: 0xffd94d).cgColor
        layer.shadowColor = UIColor(hex: 0xff6a1a).cgColor
        layer.shadowRadius = 0
        layer.shadowOpacity = 0.9

        label.translatesAutoresizingMaskIntoConstraints = false
        label.attributedText = NSAttributedString(string: "FIRE", attributes: [
            .font: Theme.display(34),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -4.0,
        ])
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard trackedTouch == nil, let touch = touches.first else { return }
        trackedTouch = touch
        lastPoint = touch.location(in: superview)
        showPressed(true)
        onFiring?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let point = touch.location(in: superview)
        onDrag?(CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
        lastPoint = point
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        reset()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        reset()
    }

    func reset() {
        let wasFiring = trackedTouch != nil
        trackedTouch = nil
        showPressed(false)
        if wasFiring { onFiring?(false) }
    }

    func showPressed(_ on: Bool) {
        transform = on ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
        layer.shadowRadius = on ? 22 : 0
        backgroundColor = UIColor(hex: on ? 0xff7b1a : 0xe8590c).withAlphaComponent(on ? 0.95 : 0.78)
    }
}
