import UIKit
import QuartzCore
import simd

/// The 3D tennis game's screen furniture: the scoreboard, the announcement banner, the
/// match-over panel, and the finger.
///
/// Unlike `TennisView`, which drew the whole game, this draws nothing — the court, the players
/// and the ball all come out of the Metal renderer behind it. What is left is a transparent
/// layer that catches touches and puts words on top, which is why it is a handful of labels and
/// two gesture recognisers rather than six hundred lines of `CGContext`.
final class Tennis3DView: UIView {

    // MARK: - Subviews

    private let scoreboard = Theme.glassPanel(cornerRadius: 14)
    private let opponentLabel = UILabel()
    private let opponentScore = UILabel()
    private let playerLabel = UILabel()
    private let playerScore = UILabel()
    private let gamesLabel = UILabel()
    private let serveIndicator = UILabel()

    private let bannerPanel = Theme.glassPanel(cornerRadius: 16)
    private let bannerTitle = UILabel()
    private let bannerSubtitle = UILabel()

    private let hint = UILabel()

    private let matchPanel = Theme.glassPanel(cornerRadius: 18)
    private let matchTitle = UILabel()
    private let matchDetail = UILabel()
    private let playAgainButton = Theme.button(title: "Play again", color: Theme.success, filled: true)
    private let leaveButton = Theme.button(title: "Back to school", color: Theme.danger)

    private var game: Tennis3DGame?
    /// True while a finger is down, so the drag keeps re-aiming rather than the tap winning.
    private var isDragging = false
    /// When `step()` last ran, so the fades can be measured in seconds. See `step()`.
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
        // The court is drawn behind this view; only the panels should be opaque to touches, and
        // they get their own handling below.
        isUserInteractionEnabled = true

        buildScoreboard()
        buildBanner()
        buildMatchPanel()
        buildHint()
        buildGestures()
    }

    /// The original's scoreboard, kept almost verbatim: a glass strip at the top with the
    /// opponent in yellow on the left and YOU in green on the right. What is new is the games
    /// line underneath — the 2D game only ever tracked points, so there was nothing to show.
    private func buildScoreboard() {
        scoreboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scoreboard)

        style(opponentLabel, size: 10, color: Theme.warning, weight: .semibold, display: false)
        style(opponentScore, size: 19, color: Theme.warning, display: true)
        style(playerLabel, size: 10, color: Theme.success, weight: .semibold, display: false)
        style(playerScore, size: 19, color: Theme.success, display: true)
        style(gamesLabel, size: 10, color: UIColor(white: 1, alpha: 0.7), weight: .medium,
              display: false)
        style(serveIndicator, size: 10, color: UIColor(white: 1, alpha: 0.55), weight: .medium,
              display: false)

        opponentLabel.textAlignment = .center
        playerLabel.textAlignment = .center
        opponentScore.textAlignment = .center
        playerScore.textAlignment = .center
        gamesLabel.textAlignment = .center
        serveIndicator.textAlignment = .center

        let opponentColumn = UIStackView(arrangedSubviews: [opponentLabel, opponentScore])
        opponentColumn.axis = .vertical
        opponentColumn.alignment = .center
        opponentColumn.spacing = 1

        let playerColumn = UIStackView(arrangedSubviews: [playerLabel, playerScore])
        playerColumn.axis = .vertical
        playerColumn.alignment = .center
        playerColumn.spacing = 1

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 1, alpha: 0.25)

        let row = UIStackView(arrangedSubviews: [opponentColumn, separator, playerColumn])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 18

        // Games and who is serving share one line. The far player stands at the top of the
        // screen, right where a taller scoreboard would sit on their head.
        let footer = UIStackView(arrangedSubviews: [gamesLabel, serveIndicator])
        footer.axis = .horizontal
        footer.alignment = .center
        footer.spacing = 10

        let column = UIStackView(arrangedSubviews: [row, footer])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 1
        scoreboard.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            scoreboard.centerXAnchor.constraint(equalTo: centerXAnchor),
            scoreboard.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),

            column.topAnchor.constraint(equalTo: scoreboard.contentView.topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: scoreboard.contentView.bottomAnchor, constant: -6),
            column.leadingAnchor.constraint(equalTo: scoreboard.contentView.leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(equalTo: scoreboard.contentView.trailingAnchor, constant: -18),

            separator.widthAnchor.constraint(equalToConstant: 2),
            separator.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    /// The banner that calls the point. The 2D game had no equivalent — a fault or a winner
    /// simply happened and the score quietly changed, which made it very hard to tell what the
    /// game thought you had just done.
    private func buildBanner() {
        bannerPanel.translatesAutoresizingMaskIntoConstraints = false
        bannerPanel.alpha = 0
        addSubview(bannerPanel)

        style(bannerTitle, size: 30, color: .white, display: true)
        style(bannerSubtitle, size: 14, color: UIColor(white: 1, alpha: 0.8), weight: .medium,
              display: false)
        bannerTitle.textAlignment = .center
        bannerSubtitle.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [bannerTitle, bannerSubtitle])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 2
        bannerPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            bannerPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerPanel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            bannerPanel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.86),

            column.topAnchor.constraint(equalTo: bannerPanel.contentView.topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bannerPanel.contentView.bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: bannerPanel.contentView.leadingAnchor, constant: 26),
            column.trailingAnchor.constraint(equalTo: bannerPanel.contentView.trailingAnchor, constant: -26),
        ])
    }

    private func buildMatchPanel() {
        matchPanel.translatesAutoresizingMaskIntoConstraints = false
        matchPanel.isHidden = true
        addSubview(matchPanel)

        style(matchTitle, size: 30, color: .white, display: true)
        style(matchDetail, size: 15, color: UIColor(white: 1, alpha: 0.85), weight: .regular,
              display: false)
        matchTitle.textAlignment = .center
        matchDetail.textAlignment = .center
        matchDetail.numberOfLines = 0

        playAgainButton.addTarget(self, action: #selector(playAgainTapped), for: .touchUpInside)
        leaveButton.addTarget(self, action: #selector(leaveTapped), for: .touchUpInside)

        let column = UIStackView(arrangedSubviews: [matchTitle, matchDetail,
                                                    playAgainButton, leaveButton])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 10
        column.setCustomSpacing(18, after: matchDetail)
        matchPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            matchPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            matchPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            matchPanel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.78),

            column.topAnchor.constraint(equalTo: matchPanel.contentView.topAnchor, constant: 22),
            column.bottomAnchor.constraint(equalTo: matchPanel.contentView.bottomAnchor, constant: -22),
            column.leadingAnchor.constraint(equalTo: matchPanel.contentView.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: matchPanel.contentView.trailingAnchor, constant: -22),
        ])
    }

    /// One line telling a ten-year-old what the controls are, which fades out once they have
    /// obviously worked it out.
    private func buildHint() {
        style(hint, size: 13, color: UIColor(white: 1, alpha: 0.85), weight: .semibold,
              display: false)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.text = "Drag yourself around the court — or tap where to run"
        hint.textAlignment = .center
        hint.numberOfLines = 0
        addSubview(hint)

        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -96),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
        ])
    }

    private func buildGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
    }

    private func style(_ label: UILabel, size: CGFloat, color: UIColor,
                       weight: UIFont.Weight = .regular, display: Bool) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = display ? Theme.display(size) : Theme.body(size, weight: weight)
        label.textColor = color
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.75
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 1, height: 1)
    }

    // MARK: - Lifecycle

    func present(game: Tennis3DGame) {
        self.game = game
        isHidden = false
        isDragging = false
        hint.alpha = 1
        lastStepTime = nil
        matchPanel.isHidden = true

        game.onPresentationChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    func dismiss() {
        isHidden = true
        game?.onPresentationChanged = nil
        game = nil
    }

    /// Called once per rendered frame, after the simulation has stepped. Everything that
    /// changes continuously — the banner's fade, the hint coming and going — lives here; the
    /// score does not, because it changes rarely and says so.
    ///
    /// The frame callback carries a viewport and no `dt`, so this measures its own. Both fades
    /// used to ease a fixed fraction *per frame*, which meant they ran at half speed on a
    /// 120 Hz display and twice as fast on a dropped frame.
    func step() {
        guard !isHidden, let game else { return }

        let now = CACurrentMediaTime()
        // Clamped the same way the simulation clamps its own step: a frame the app spent in the
        // background must not fade everything at once.
        let dt = min(0.1, max(0, now - (lastStepTime ?? now)))
        lastStepTime = now

        // The match-over panel and the banner both sit in the middle of the screen and overlap,
        // so the "GAME, SET AND MATCH" call goes away as soon as the panel it duplicates is up.
        let bannerWanted: CGFloat = (game.announcement == nil || !matchPanel.isHidden) ? 0 : 1
        fade(bannerPanel, to: bannerWanted, rate: 9, dt: dt)

        // The hint is up until the player first touches the court, and comes back if they stop
        // playing for a while — a ten-year-old who puts the phone down mid-match should not
        // have to remember what the controls were. Twelve seconds is longer than any pause
        // between points, so it never flashes back on mid-match.
        fade(hint, to: game.secondsSinceSteer > 12 ? 1 : 0, rate: 4, dt: dt)
    }

    /// Exponential ease towards `target`, framed in seconds rather than in frames.
    private func fade(_ view: UIView, to target: CGFloat, rate: Double, dt: Double) {
        guard abs(view.alpha - target) > 0.004 else {
            view.alpha = target
            return
        }
        view.alpha += (target - view.alpha) * CGFloat(1 - exp(-rate * dt))
    }

    /// Pulls everything static out of the game in one go.
    private func refresh() {
        guard let game else { return }
        let board = game.scoreboard

        opponentLabel.text = board.opponentName.uppercased()
        playerLabel.text = "YOU"
        opponentScore.text = board.npcPoints
        playerScore.text = board.playerPoints
        gamesLabel.text = "Games \(board.playerGames)—\(board.npcGames)"
        serveIndicator.text = board.serverIsPlayer ? "· your serve" : "· \(board.opponentName) serving"

        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        if board.isMatchOver {
            matchTitle.text = board.playerWonMatch ? "YOU WIN!" : "BEATEN"
            matchDetail.text = board.playerWonMatch
                ? "You beat \(board.opponentName) \(board.playerGames)—\(board.npcGames). "
                    + "The tennis badge is yours."
                : "\(board.opponentName) took it \(board.npcGames)—\(board.playerGames). "
                    + "Another go?"
            // Only fade it in on the way up. `refresh()` runs on every presentation change, and
            // the announcement expiring is one — so without this the panel restarts its fade
            // from nothing a few seconds after it appears.
            if matchPanel.isHidden {
                matchPanel.isHidden = false
                matchPanel.alpha = 0
                UIView.animate(withDuration: 0.35) { self.matchPanel.alpha = 1 }
            }
        } else {
            matchPanel.isHidden = true
        }
    }

    @objc private func playAgainTapped() {
        game?.restartMatch()
        refresh()
    }

    @objc private func leaveTapped() {
        game?.requestExit()
    }

    // MARK: - Input

    /// Drag: the player chases your finger. Tap: they run to where you tapped and stop.
    ///
    /// Both end up in the same place — `Tennis3DGame.steer(toWorldX:y:)` sets a point on the
    /// court to head for, and `Locomotion` does the rest. That is why a drag feels like
    /// dragging rather than like teleporting: the character is accelerating towards the finger,
    /// not being placed under it.
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            isDragging = true
            steer(to: recognizer.location(in: self))
        default:
            isDragging = false
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard !isDragging else { return }
        steer(to: recognizer.location(in: self))
    }

    private func steer(to point: CGPoint) {
        guard let game, let world = worldPoint(for: point) else { return }
        game.steer(toWorldX: world.x, y: world.y)
    }

    /// Turns a point on the screen into a point on the court.
    ///
    /// The 2D game inverted its own court transform to do this. Here the court is a real plane
    /// in a real perspective projection, so the honest answer is a ray cast — which the camera
    /// already knows how to do, because the map layer needs the same thing to work out which
    /// ground tiles are on screen.
    private func worldPoint(for point: CGPoint) -> (x: Double, y: Double)? {
        guard let game, bounds.width > 0, bounds.height > 0 else { return nil }

        let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1,
                               1 - Float(point.y / bounds.height) * 2)
        guard let hit = game.lastCamera.unprojectToGroundPlane(ndc: ndc) else { return nil }
        // Render space negates Y.
        return (x: Double(hit.x), y: Double(-hit.y))
    }

    /// Lets touches through to the panels, but never swallows one meant for the court.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        if !matchPanel.isHidden {
            let inPanel = matchPanel.convert(point, from: self)
            if matchPanel.bounds.contains(inPanel) {
                return super.hitTest(point, with: event)
            }
        }
        // Everything else on this layer is text, and text should not eat a drag.
        return self
    }
}
