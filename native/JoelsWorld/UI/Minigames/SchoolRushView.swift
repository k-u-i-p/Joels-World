import UIKit
import QuartzCore

/// School Rush's screen furniture and its controls: the distance and coin counters, the lives,
/// the banner, the game-over panel, and the four gestures that steer the run.
///
/// Like `Tennis3DView` this draws nothing — the track, the runner and everything in the way come
/// out of the Metal renderer behind it. What is here is a transparent layer that catches swipes
/// and puts numbers on top.
///
/// **Both swipes and taps work**, deliberately. A swipe is the gesture the genre taught everyone;
/// a tap on the left or right third of the screen is what a ten-year-old actually does when a car
/// is arriving and there is no time to think. A tap in the middle jumps.
final class SchoolRushView: UIView {

    // MARK: - Subviews

    private let scorePanel = Theme.glassPanel(cornerRadius: 14)
    private let distanceLabel = UILabel()
    private let distanceCaption = UILabel()
    private let coinsLabel = UILabel()
    private let bestLabel = UILabel()
    /// "JUMP +7%". Hidden until the first ten coins have been collected, so it appears as a
    /// reward rather than sitting at zero explaining itself.
    private let boostLabel = UILabel()

    /// **Lives and coins are drawn, not typed.** The obvious version of this used "❤️❤️❤️" and
    /// "🪙 12" and both came out as empty boxes on the device: `Theme.body` is an explicit font
    /// and setting one turns off the system's emoji fallback. Three red dots and a gold disc are
    /// a couple of `UIView`s and cannot fail to render.
    private var lifeDots: [UIView] = []
    private let coinDot = UIView()

    private let bannerPanel = Theme.glassPanel(cornerRadius: 16)
    private let bannerTitle = UILabel()
    private let bannerSubtitle = UILabel()

    private let hint = UILabel()

    private let overPanel = Theme.glassPanel(cornerRadius: 18)
    private let overTitle = UILabel()
    private let overDetail = UILabel()
    private let runAgainButton = Theme.button(title: "Run again", color: Theme.success, filled: true)
    private let leaveButton = Theme.button(title: "Back to school", color: Theme.danger)

    private var game: SchoolRushGame?
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
        buildOverPanel()
        buildHint()
        buildGestures()
    }

    /// The counters, along the top: how far, how many coins, how many lives left.
    private func buildScorePanel() {
        addSubview(scorePanel)
        scorePanel.translatesAutoresizingMaskIntoConstraints = false

        style(distanceLabel, size: 30, color: .white, weight: .heavy)
        distanceLabel.text = "0 m"
        style(distanceCaption, size: 11, color: Theme.textMuted, weight: .semibold)
        distanceCaption.text = "DISTANCE"
        style(coinsLabel, size: 18, color: UIColor(hex: 0xf5c518), weight: .bold)
        coinsLabel.text = "0"
        style(bestLabel, size: 11, color: Theme.textMuted, weight: .semibold)
        bestLabel.text = "BEST 0 m"

        let left = UIStackView(arrangedSubviews: [distanceCaption, distanceLabel, bestLabel])
        left.axis = .vertical
        left.alignment = .leading
        left.spacing = 0

        lifeDots = (0..<3).map { _ in dot(size: 15, color: Theme.danger) }
        let livesRow = UIStackView(arrangedSubviews: lifeDots)
        livesRow.axis = .horizontal
        livesRow.alignment = .center
        livesRow.spacing = 5

        let coinRow = UIStackView(arrangedSubviews: [dotView(coinDot, size: 15,
                                                             color: UIColor(hex: 0xf5c518)),
                                                     coinsLabel])
        coinRow.axis = .horizontal
        coinRow.alignment = .center
        coinRow.spacing = 6

        style(boostLabel, size: 12, color: Theme.success, weight: .bold)
        boostLabel.isHidden = true

        let right = UIStackView(arrangedSubviews: [livesRow, coinRow, boostLabel])
        right.axis = .vertical
        right.alignment = .trailing
        right.spacing = 6

        let row = UIStackView(arrangedSubviews: [left, right])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        row.spacing = 26
        row.translatesAutoresizingMaskIntoConstraints = false
        scorePanel.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            scorePanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            scorePanel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor,
                                                constant: 16),

            row.topAnchor.constraint(equalTo: scorePanel.contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: scorePanel.contentView.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: scorePanel.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: scorePanel.contentView.trailingAnchor,
                                          constant: -14),
        ])
    }

    /// GO!, OUCH!, BADGE! — the three things worth interrupting the run to say.
    private func buildBanner() {
        addSubview(bannerPanel)
        bannerPanel.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.alpha = 0

        style(bannerTitle, size: 34, color: .white, weight: .heavy)
        style(bannerSubtitle, size: 14, color: Theme.textMuted, weight: .semibold)
        bannerTitle.textAlignment = .center
        bannerSubtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [bannerTitle, bannerSubtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            bannerPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerPanel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -60),

            stack.topAnchor.constraint(equalTo: bannerPanel.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bannerPanel.contentView.bottomAnchor,
                                          constant: -12),
            stack.leadingAnchor.constraint(equalTo: bannerPanel.contentView.leadingAnchor,
                                           constant: 28),
            stack.trailingAnchor.constraint(equalTo: bannerPanel.contentView.trailingAnchor,
                                            constant: -28),
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

        runAgainButton.addTarget(self, action: #selector(runAgainTapped), for: .touchUpInside)
        leaveButton.addTarget(self, action: #selector(leaveTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [overTitle, overDetail,
                                                   runAgainButton, leaveButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12
        stack.setCustomSpacing(18, after: overDetail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        overPanel.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            overPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            overPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            overPanel.widthAnchor.constraint(equalToConstant: 300),

            stack.topAnchor.constraint(equalTo: overPanel.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: overPanel.contentView.bottomAnchor,
                                          constant: -22),
            stack.leadingAnchor.constraint(equalTo: overPanel.contentView.leadingAnchor,
                                           constant: 22),
            stack.trailingAnchor.constraint(equalTo: overPanel.contentView.trailingAnchor,
                                            constant: -22),
        ])
    }

    /// One line telling a ten-year-old what the controls are. It goes away on the first swipe.
    private func buildHint() {
        addSubview(hint)
        hint.translatesAutoresizingMaskIntoConstraints = false
        style(hint, size: 14, color: .white, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.text = "Tap left or right to change lane\nTap here — or swipe up — to jump"

        // Pinned by its edges rather than given a maximum width: a multi-line label with only a
        // `lessThanOrEqualTo` width has no width to wrap against until it has been laid out, and
        // lays out to nothing.
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            hint.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -18),
        ])
    }

    /// Three swipes and a tap. The swipes are the genre's controls; the tap is the one that
    /// actually gets used when something is arriving fast.
    ///
    /// **The tap waits for every swipe to fail**, which is not a detail. Without it a swipe that
    /// was a little too slow to register — which is most of a ten-year-old's swipes — fell
    /// through to the tap recogniser, and a swipe that started in the middle of the screen came
    /// out as a jump. "As soon as you click, an instant jump triggers" was exactly that.
    private func buildGestures() {
        var swipes: [UISwipeGestureRecognizer] = []
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
            swipe.direction = direction
            addGestureRecognizer(swipe)
            swipes.append(swipe)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        for swipe in swipes { tap.require(toFail: swipe) }
        addGestureRecognizer(tap)
    }

    /// A filled circle of a fixed size, for a life or a coin.
    private func dot(size: CGFloat, color: UIColor) -> UIView {
        dotView(UIView(), size: size, color: color)
    }

    @discardableResult
    private func dotView(_ view: UIView, size: CGFloat, color: UIColor) -> UIView {
        view.backgroundColor = color
        view.layer.cornerRadius = size / 2
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor(white: 0, alpha: 0.35).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size),
            view.heightAnchor.constraint(equalToConstant: size),
        ])
        return view
    }

    private func style(_ label: UILabel, size: CGFloat, color: UIColor, weight: UIFont.Weight) {
        label.font = Theme.body(size, weight: weight)
        label.textColor = color
        // A thin black shadow, because these sit over a bright sky and a pale path.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.7
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
    }

    // MARK: - Input

    @objc private func swiped(_ recogniser: UISwipeGestureRecognizer) {
        guard let game else { return }
        switch recogniser.direction {
        case .left: game.changeLane(by: -1)
        case .right: game.changeLane(by: 1)
        case .up: game.jump()
        default: break
        }
    }

    /// Left third, right third, middle. Nothing on the panels — those are buttons and get the
    /// touch first.
    @objc private func tapped(_ recogniser: UITapGestureRecognizer) {
        guard let game, overPanel.isHidden else { return }
        // **The jump zone is the bottom middle, not the whole middle third.** The lanes are the
        // two sides, and the middle of the *upper* screen is where the track is — the part you
        // are looking at, and so the part a stray finger lands on. Putting the jump low keeps it
        // under the thumb and out of the way of a glance.
        let point = recogniser.location(in: self)
        if point.y > bounds.height * 0.55 && abs(point.x - bounds.midX) < bounds.width * 0.22 {
            game.jump()
        } else if point.x < bounds.midX {
            game.changeLane(by: -1)
        } else {
            game.changeLane(by: 1)
        }
    }

    @objc private func runAgainTapped() {
        overPanel.isHidden = true
        hint.alpha = 0
        game?.restartRun()
    }

    @objc private func leaveTapped() {
        game?.requestExit()
    }

    // MARK: - Lifecycle

    func present(game: SchoolRushGame) {
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

    /// Once per rendered frame, after the simulation has stepped. The distance changes every
    /// frame so it lives here; everything that changes rarely goes through `refresh()`.
    func step() {
        guard !isHidden, let game else { return }

        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - (lastStepTime ?? now)))
        lastStepTime = now

        distanceLabel.text = "\(Int(game.distance)) m"

        let bannerWanted: CGFloat = (game.announcement == nil || !overPanel.isHidden) ? 0 : 1
        fade(bannerPanel, to: bannerWanted, rate: 9, dt: dt)
        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        // The game-over panel waits for the runner to actually stop, so the panel does not land
        // on top of a character still sliding forwards.
        if game.phase == .over, overPanel.isHidden, game.speedInMetresPerSecond < 0.6 {
            showOverPanel(for: game)
        }
        // And it goes away whenever a run is under way, rather than only when its own button was
        // the thing that started one. `restartRun()` can be called from elsewhere — the demo
        // harness does — and a panel left sitting over a live run is unplayable.
        if game.phase == .running, !overPanel.isHidden {
            overPanel.isHidden = true
        }

        // The controls hint goes as soon as it has plainly been read: on the first swipe, or
        // after the first fifteen metres for a player who worked it out without one.
        fade(hint, to: game.distance > 15 ? 0 : 1, rate: 3, dt: dt)
    }

    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    private func showOverPanel(for game: SchoolRushGame) {
        overPanel.isHidden = false
        hint.alpha = 0

        let distance = Int(game.distance)
        let best = Int(game.best)
        overTitle.text = distance >= Int(SchoolRushGame.Tuning.badgeDistance)
            ? "Badge run!" : "Out of puff"

        var lines = ["\(distance) m · \(game.coins) coins"]
        if distance >= best {
            lines.append("A new best.")
        } else {
            lines.append("Best so far: \(best) m")
        }
        if distance < Int(SchoolRushGame.Tuning.badgeDistance) {
            lines.append("Reach \(Int(SchoolRushGame.Tuning.badgeDistance)) m for the badge.")
        }
        overDetail.text = lines.joined(separator: "\n")
    }

    /// Everything that changes rarely: coins, lives, the best run.
    private func refresh() {
        guard let game else { return }
        coinsLabel.text = "\(game.coins)"
        for (index, dot) in lifeDots.enumerated() {
            dot.alpha = index < game.lives ? 1 : 0.22
        }
        bestLabel.text = "BEST \(Int(game.best)) m"
        let boost = Int((game.jumpBoost * 100).rounded())
        boostLabel.text = "JUMP +\(boost)%"
        boostLabel.isHidden = boost <= 0
    }
}
