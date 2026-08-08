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
    /// "RALLY 6", once a point is long enough to be worth counting.
    private let rallyLabel = UILabel()

    /// The three difficulty buttons, the two match-length buttons, and the panel they share.
    /// Between points only — see `step()`.
    private let difficultyPanel = Theme.glassPanel(cornerRadius: 12)
    private let difficultyCaption = UILabel()
    private var difficultyButtons: [UIButton] = []
    private let matchLengthCaption = UILabel()
    private var matchLengthButtons: [UIButton] = []

    private let matchPanel = Theme.glassPanel(cornerRadius: 18)
    private let matchTitle = UILabel()
    private let matchDetail = UILabel()
    private let playAgainButton = Theme.button(title: "Play again", color: Theme.success, filled: true)
    private let leaveButton = Theme.button(title: "Back to school", color: Theme.danger)

    private var game: Tennis3DGame?
    /// True while a finger is down, so the drag keeps re-aiming rather than the tap winning.
    private var isDragging = false
    /// Set when a drag began on the player: how far the character was from the finger at that
    /// moment, held constant for the rest of the drag. Nil for a drag that began anywhere else,
    /// which steers straight at the finger. See `panned`.
    private var grabOffset: (x: Double, y: Double)?
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
        buildDifficultyRow()
        buildRallyCounter()
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

    /// **How good Alex is, as three buttons.**
    ///
    /// It was a constant with a debug flag on it, which meant the one thing a ten-year-old is
    /// certain to want — "make her harder, I keep winning" — needed a rebuild. It sits just under
    /// the scoreboard and shows itself **only between points**, so it is always a tap away and
    /// never under the ball during a rally.
    private func buildDifficultyRow() {
        difficultyPanel.translatesAutoresizingMaskIntoConstraints = false
        difficultyPanel.alpha = 0
        addSubview(difficultyPanel)

        style(difficultyCaption, size: 10, color: UIColor(white: 1, alpha: 0.75), weight: .semibold,
              display: false)
        difficultyCaption.text = "ALEX"
        difficultyCaption.textAlignment = .center

        style(matchLengthCaption, size: 10, color: UIColor(white: 1, alpha: 0.75), weight: .semibold,
              display: false)
        matchLengthCaption.text = "MATCH"
        matchLengthCaption.textAlignment = .center

        difficultyButtons = Tennis3DDifficulty.allCases.map { level in
            pill(title: level.title, tag: level.rawValue,
                 action: #selector(difficultyTapped(_:)))
        }
        matchLengthButtons = Tennis3DMatchLength.allCases.map { length in
            pill(title: length.title, tag: length.rawValue,
                 action: #selector(matchLengthTapped(_:)))
        }

        let alexRow = UIStackView(arrangedSubviews: [difficultyCaption] + difficultyButtons)
        alexRow.axis = .horizontal
        alexRow.alignment = .center
        alexRow.spacing = 6

        let lengthRow = UIStackView(arrangedSubviews: [matchLengthCaption] + matchLengthButtons)
        lengthRow.axis = .horizontal
        lengthRow.alignment = .center
        lengthRow.spacing = 6

        // The captions are different widths, so the two rows would sit ragged; centring each row
        // in the panel and letting them find their own width is fine at this size and saves a
        // second set of constraints tying the captions together.
        let column = UIStackView(arrangedSubviews: [alexRow, lengthRow])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 4
        difficultyPanel.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            difficultyPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            difficultyPanel.topAnchor.constraint(equalTo: scoreboard.bottomAnchor, constant: 6),

            column.topAnchor.constraint(equalTo: difficultyPanel.contentView.topAnchor, constant: 5),
            column.bottomAnchor.constraint(equalTo: difficultyPanel.contentView.bottomAnchor, constant: -5),
            column.leadingAnchor.constraint(equalTo: difficultyPanel.contentView.leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: difficultyPanel.contentView.trailingAnchor, constant: -10),
        ])
    }

    /// One of the little chooser pills in the settings panel.
    private func pill(title: String, tag: Int, action: Selector) -> UIButton {
        let button = Theme.makePlainButton()
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Theme.body(12, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 7
        button.layer.cornerCurve = .continuous
        // Sized rather than inset: `contentEdgeInsets` is deprecated, and a fixed pill is
        // easier for a thumb to land on than one that hugs its own text.
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 62).isActive = true
        button.tag = tag
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    /// The rally counter. Nothing in the rules turns on it — it is there because counting your
    /// own rally is half of what makes hitting a ball back and forth fun, and because a game
    /// that never tells you a rally was long has no way of saying "that was a good one".
    private func buildRallyCounter() {
        style(rallyLabel, size: 15, color: UIColor(white: 1, alpha: 0.9), display: true)
        rallyLabel.translatesAutoresizingMaskIntoConstraints = false
        rallyLabel.textAlignment = .center
        rallyLabel.alpha = 0
        addSubview(rallyLabel)

        // Top left, on the grass. The middle of the screen is the court, the bottom is where the
        // player stands, and the top middle is the scoreboard — this corner is the only part of
        // the frame with nothing in it, at either end of a rally.
        NSLayoutConstraint.activate([
            rallyLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor,
                                                constant: 16),
            rallyLabel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
    }

    /// One line telling a ten-year-old what the controls are, which fades out once they have
    /// obviously worked it out.
    private func buildHint() {
        style(hint, size: 13, color: UIColor(white: 1, alpha: 0.85), weight: .semibold,
              display: false)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.text = "Tap the green X — that is where your racket has to be. "
            + "Or grab yourself and drag.\nTap Alex's side of the court to hit it there"
        hint.textAlignment = .center
        hint.numberOfLines = 0
        addSubview(hint)

        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Clear of the near baseline. The court now fills the frame, so the bottom of the
            // screen is where the player stands rather than spare apron — two lines of text at
            // 96 points up sat on their head.
            hint.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -190),
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
        grabOffset = nil
        hint.alpha = 1
        difficultyPanel.alpha = 1
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

        // The difficulty buttons are up whenever the ball is not, which is every pause between
        // points. Never during a rally: they sit near the top of the screen, which is where the
        // far player and a deep ball both are.
        let playing = game.phase == .rally || game.phase == .toss
        fade(difficultyPanel, to: playing ? 0 : 1, rate: 7, dt: dt)

        // From the third shot, because "RALLY 1" on every serve is noise. It holds through the
        // pause after the point so you get to see what you managed.
        let shots = game.scoreboard.rallyShots
        if shots >= 3 { rallyLabel.text = "RALLY \(shots)" }
        fade(rallyLabel, to: shots >= 3 ? 1 : 0, rate: 6, dt: dt)
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

        difficultyCaption.text = board.opponentName.uppercased()
        highlight(difficultyButtons, selectedTag: game.difficulty.rawValue)
        highlight(matchLengthButtons, selectedTag: game.matchLength.rawValue)

        if let announcement = game.announcement {
            bannerTitle.text = announcement.text
            bannerSubtitle.text = announcement.subtitle
            bannerSubtitle.isHidden = announcement.subtitle == nil
        }

        if board.isMatchOver {
            matchTitle.text = board.playerWonMatch ? "YOU WIN!" : "BEATEN"
            let rally = board.longestRally >= 3
                ? " Your longest rally was \(board.longestRally) shots."
                : ""
            matchDetail.text = (board.playerWonMatch
                ? "You beat \(board.opponentName) \(board.playerGames)—\(board.npcGames). "
                    + "The tennis badge is yours."
                : "\(board.opponentName) took it \(board.npcGames)—\(board.playerGames). "
                    + "Another go?") + rally
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

    private func highlight(_ buttons: [UIButton], selectedTag: Int) {
        for button in buttons {
            let selected = button.tag == selectedTag
            button.backgroundColor = selected ? Theme.primary : UIColor(white: 1, alpha: 0.12)
            button.setTitleColor(selected ? .white : UIColor(white: 1, alpha: 0.7), for: .normal)
        }
    }

    @objc private func difficultyTapped(_ sender: UIButton) {
        guard let game, let level = Tennis3DDifficulty(rawValue: sender.tag) else { return }
        game.difficulty = level
        game.announce("\(game.scoreboard.opponentName.uppercased()): \(level.title.uppercased())",
                      subtitle: level.blurb, duration: 1.6)
        refresh()
    }

    @objc private func matchLengthTapped(_ sender: UIButton) {
        guard let game, let length = Tennis3DMatchLength(rawValue: sender.tag) else { return }
        game.matchLength = length
        game.announce("\(length.title.uppercased()) MATCH", subtitle: length.blurb, duration: 1.6)
        refresh()
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
    ///
    /// **A drag that starts on your own player grabs them instead**, and from then on the
    /// character moves by however far the finger has moved rather than to wherever it now is.
    /// The two behave identically once the finger has travelled — the difference is the first
    /// instant. Without it, putting a thumb on your own character and moving it a centimetre
    /// jerked them a metre sideways to line up under the middle of the thumb, because a thumb is
    /// two centimetres across and a court is only sixteen metres wide on screen. Grabbing is also
    /// the gesture that does not put a thumb on top of the thing you are trying to watch.
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let finger = recognizer.location(in: self)
        switch recognizer.state {
        case .began: handleDrag(.began, at: finger)
        case .changed: handleDrag(.changed, at: finger)
        default: handleDrag(.ended, at: finger)
        }
    }

    /// The three things a drag can be, independent of `UIPanGestureRecognizer`.
    ///
    /// Split out so the drag can be driven without a finger — see `debugDrag`. A
    /// `UIPanGestureRecognizer` cannot be constructed with a chosen state and location, so as
    /// long as the bookkeeping lived inside `panned` there was no way to exercise it at all, and
    /// "nobody has played it with a thumb" stayed the oldest item on the handoff list for five
    /// sessions. Now the only untested step is UIKit's own delivery of a touch to this view,
    /// which `-tennis3dhittest` checks from the other end.
    enum DragPhase { case began, changed, ended }

    private func handleDrag(_ phase: DragPhase, at finger: CGPoint) {
        switch phase {
        case .began:
            isDragging = true
            grabOffset = nil
            // The grab test asks about the **body**, which stands on the ground, so it reads the
            // ground plane. The steering below asks about the **strings**, which do not.
            if let game,
               let feet = worldPoint(for: finger),
               hypot(feet.x - game.player.motor.x, feet.y - game.player.motor.y)
                   < Tennis3DCourt.metres(1.8),
               let strings = worldPoint(for: finger, height: game.playerContactHeight) {
                let anchor = game.playerRacketAnchor
                grabOffset = (x: anchor.x - strings.x, y: anchor.y - strings.y)
                game.trace(String(format: "DRAG grabbed, offset (%.2f, %.2f)m",
                                  grabOffset!.x / Tennis3DCourt.unitsPerMetre,
                                  grabOffset!.y / Tennis3DCourt.unitsPerMetre))
            } else {
                game?.trace("DRAG began off the player — steering straight at the finger")
            }
            steer(to: finger)
        case .changed:
            isDragging = true
            steer(to: finger)
        case .ended:
            isDragging = false
            grabOffset = nil
        }
    }

    /// **A tap on your own half moves you. A tap on Alex's half aims your next shot there.**
    ///
    /// The two cannot be confused, because you cannot stand on Alex's half — `steer` clamps the
    /// feet to this side of the net, so a tap over there used to mean nothing more useful than
    /// "run at the net". One tap, no second finger, and no gesture to learn.
    ///
    /// Read on the **floor**, not at racket height: an aim is a place on the court, whereas a
    /// steer is a place for the strings. Those two planes are more than a metre apart on screen
    /// from this camera, which is why they are two different unprojections rather than one.
    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard !isDragging else { return }
        handleTap(at: recognizer.location(in: self))
    }

    /// The line a tap actually does its work on, so `-tennis3dtaps` can enter here rather than
    /// having to reimplement the near/far decision and then not be testing it.
    private func handleTap(at finger: CGPoint) {
        guard let game else { return }
        if let ground = worldPoint(for: finger), ground.y < -Tennis3DCourt.metres(0.5) {
            game.aimShot(atWorldX: ground.x, y: ground.y)
            return
        }
        steer(to: finger)
    }

    /// **A finger points at a racket, not at a pair of feet.**
    ///
    /// The thing on screen worth aiming at is the green X, and the green X is where the ball has
    /// to meet the strings. So the point under the finger is handed to the game as a target for
    /// the *racket head*, and the game works backwards to where the feet have to go — the same
    /// sum `stance(toMeet:for:)` does for the opponent. Aiming the feet at it instead, which is
    /// what this did, planted the chest where the strings needed to be and the ball sailed past
    /// a metre inside the reach.
    private func steer(to point: CGPoint) {
        guard let game,
              let world = worldPoint(for: point, height: game.playerContactHeight) else { return }
        let offset = grabOffset ?? (x: 0, y: 0)
        game.steer(racketToWorldX: world.x + offset.x, y: world.y + offset.y)
    }

    /// Turns a point on the screen into a point on the court, at a given height above it.
    ///
    /// The 2D game inverted its own court transform to do this. Here the court is a real plane
    /// in a real perspective projection, so the honest answer is a ray cast — which the camera
    /// already knows how to do, because the map layer needs the same thing to work out which
    /// ground tiles are on screen.
    ///
    /// `height` matters more than it sounds. The camera is tipped 0.80 rad — 46° — over behind
    /// the baseline, so a marker floating at racket height sits well over a metre up-screen of
    /// the patch of court beneath it; reading every touch off the floor meant a tap that looked
    /// dead on the X asked for a point a couple of sweet spots behind it. The camera only
    /// unprojects to the floor, so the ray is re-cut here: it runs from the eye through the floor
    /// hit, and is stopped at `height` on the way.
    private func worldPoint(for point: CGPoint, height: Double = 0) -> (x: Double, y: Double)? {
        guard let game, bounds.width > 0, bounds.height > 0 else { return nil }

        let ndc = SIMD2<Float>(Float(point.x / bounds.width) * 2 - 1,
                               1 - Float(point.y / bounds.height) * 2)
        guard let hit = game.lastCamera.unprojectToGroundPlane(ndc: ndc) else { return nil }

        var render = SIMD2(Double(hit.x), Double(hit.y))
        let eye = game.lastCamera.eye
        if height > 0, Double(eye.z) > height + 1 {
            let eyePlane = SIMD2(Double(eye.x), Double(eye.y))
            render = eyePlane + (render - eyePlane) * ((Double(eye.z) - height) / Double(eye.z))
        }
        // Render space negates Y.
        return (x: render.x, y: -render.y)
    }

#if DEBUG
    // MARK: - Driving it without a finger
    //
    // `simctl` cannot inject a touch, and "nobody has played it with a thumb" has been the oldest
    // item on the handoff list for three sessions running. The gesture recognisers themselves are
    // UIKit's and are not the risk; the risk is everything between a point on the glass and a
    // target on the court — the ray cast, the height plane the ray is cut on, and the racket
    // offset. `-tennis3dtaps` drives exactly that, by projecting the green X back to a screen
    // point and pushing it in where UIKit would have. If the round trip is wrong by a metre, the
    // player misses every ball and the trace says so.

    /// Where a point in the world lands on this view.
    func debugScreenPoint(worldX: Double, worldY: Double, z: Double) -> CGPoint? {
        guard let game, bounds.width > 0, bounds.height > 0 else { return nil }
        let viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        let projected = game.lastCamera.project(worldX: worldX, worldY: worldY, z: z,
                                                viewport: viewport)
        guard projected.ndc.z <= 1, abs(projected.ndc.x) <= 1.3, abs(projected.ndc.y) <= 1.3 else {
            return nil
        }
        return CGPoint(x: CGFloat(projected.screen.x), y: CGFloat(projected.screen.y))
    }

    /// Enters at the same line `tapped(_:)` does, with the CGPoint UIKit would have handed it —
    /// including the near/far decision, so a tap aimed at Alex's court really does go through
    /// the aiming path rather than a test-only shortcut into it.
    func debugTouch(at point: CGPoint) {
        grabOffset = nil
        handleTap(at: point)
    }

    /// Enters at the same line `panned(_:)` does, with the phase and the CGPoint UIKit would have
    /// handed it. This is what makes the **drag** testable rather than only the tap: the grab
    /// radius, the offset held across the gesture, and the `.began`/`.changed` bookkeeping are
    /// all on this path.
    func debugDrag(_ phase: DragPhase, at point: CGPoint) {
        handleDrag(phase, at: point)
    }

    /// **Would a touch on the court actually reach this view?**
    ///
    /// The half of the input path `debugDrag` and `debugTouch` cannot cover, because they both
    /// start *inside* the view. This asks the real window the question UIKit asks — hit-test this
    /// point — and reports which view wins. Anything other than `Tennis3DView` means a layer
    /// stacked above the court is eating the gesture and no finger will ever work, however
    /// correct everything downstream is.
    func debugHitTestReport(at point: CGPoint) -> String {
        guard let window else { return "no window" }
        let hit = window.hitTest(window.convert(point, from: self), with: nil)
        let name = hit.map { String(describing: type(of: $0)) } ?? "nil"
        return "\(name)\(hit === self ? " ✓" : " ✗ — this view is not reachable")"
    }
#endif

    /// Lets touches through to the panels, but never swallows one meant for the court.
    ///
    /// A panel only counts while it is actually on screen: the difficulty row fades out during a
    /// rally, and an invisible strip of buttons across the top of the court that quietly ate the
    /// first centimetre of every drag would be a genuinely maddening bug to be on the wrong end
    /// of at ten years old.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        for panel in [matchPanel, difficultyPanel] where !panel.isHidden && panel.alpha > 0.5 {
            if panel.bounds.contains(panel.convert(point, from: self)) {
                return super.hitTest(point, with: event)
            }
        }
        // Everything else on this layer is text, and text should not eat a drag.
        return self
    }
}
