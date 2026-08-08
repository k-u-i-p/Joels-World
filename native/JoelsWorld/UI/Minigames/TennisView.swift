import UIKit

/// The tennis minigame's screen: the court art, the 2D characters drawn over it, and the
/// scoreboard. Port of the rendering half of `tennis.js` (`1564-1986`).
///
/// The web build redraws the court bitmap into the same canvas every frame. Here it is a static
/// `UIImageView` underneath a transparent `TennisCanvasView`, which is the same picture without
/// re-blitting a 2493×1260 image sixty times a second. Everything above it — the layout maths,
/// the transform, the draw order — is the JS line for line.
final class TennisView: UIView {
    /// Fixed virtual height the court art is mapped onto, independent of how far the players
    /// are allowed to run past the baselines (`tennis.js:1698`).
    private static let virtualGameHeight = TennisGame.courtHeight + (75 * 2) + 20

    private let courtImage = UIImageView()
    private let canvas = TennisCanvasView()
    private let scoreboard = Theme.glassPanel()
    private let npcScore = UILabel()
    private let playerScore = UILabel()

    private var game: TennisGame?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // `#7bed9f`, the grass the JS paints outside the court art.
        backgroundColor = UIColor(cgColor: CSS.hex("#7bed9f"))
        isHidden = true

        courtImage.contentMode = .scaleToFill
        addSubview(courtImage)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        addSubview(canvas)

        scoreboard.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scoreboard)

        configure(npcScore, color: "#f1c40f")
        configure(playerScore, color: "#2ecc71")

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = UIColor(white: 1, alpha: 0.3)

        let row = UIStackView(arrangedSubviews: [npcScore, separator, playerScore])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 15
        scoreboard.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            scoreboard.centerXAnchor.constraint(equalTo: centerXAnchor),
            scoreboard.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 20),

            row.topAnchor.constraint(equalTo: scoreboard.contentView.topAnchor, constant: 15),
            row.bottomAnchor.constraint(equalTo: scoreboard.contentView.bottomAnchor, constant: -15),
            row.leadingAnchor.constraint(equalTo: scoreboard.contentView.leadingAnchor, constant: 30),
            row.trailingAnchor.constraint(equalTo: scoreboard.contentView.trailingAnchor, constant: -30),

            separator.widthAnchor.constraint(equalToConstant: 2),
            separator.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(courtTapped))
        addGestureRecognizer(tap)
    }

    private func configure(_ label: UILabel, color: String) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = Theme.display(22)
        label.textColor = UIColor(cgColor: CSS.hex(color))
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = CGSize(width: 2, height: 2)
    }

    // MARK: - Lifecycle

    func present(game: TennisGame) {
        self.game = game
        canvas.game = game
        isHidden = false
        updateScoreboard()

        game.onScoreChanged = { [weak self] in self?.updateScoreboard() }

        SVGImage.load(path: "/minigames/tennis/map.svg") { [weak self] image in
            guard let self else { return }
            self.courtImage.image = image
            self.canvas.courtAspect = image.map { $0.size.width / $0.size.height }
            self.setNeedsLayout()
        }
    }

    func dismiss() {
        isHidden = true
        game?.onScoreChanged = nil
        game = nil
        canvas.game = nil
    }

    /// Called once per simulated frame, from the render loop.
    func step() {
        guard !isHidden else { return }
        canvas.setNeedsDisplay()
    }

    private func updateScoreboard() {
        guard let game else { return }
        let score = game.currentScore
        npcScore.text = "NPC: " + (score.npcText ?? "")
        playerScore.text = "YOU: " + (score.playerText ?? "")
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds

        guard let layout = layout() else {
            courtImage.frame = .zero
            return
        }
        courtImage.frame = CGRect(x: layout.offsetX, y: layout.offsetY,
                                  width: layout.renderWidth, height: layout.renderHeight)
    }

    /// The court's placement on screen, and the transform from game coordinates to it.
    struct Layout {
        var offsetX: CGFloat
        var offsetY: CGFloat
        var renderWidth: CGFloat
        var renderHeight: CGFloat
        var scale: CGFloat
        var centerX: CGFloat
    }

    /// `tennis.js:1693-1716`.
    static func layout(viewport: CGSize, courtAspect: CGFloat) -> Layout {
        let renderHeight = viewport.height
        let renderWidth = renderHeight * courtAspect
        let scale = renderHeight / virtualGameHeight
        let gameWidth = virtualGameHeight * courtAspect

        return Layout(offsetX: (viewport.width - renderWidth) / 2,
                      offsetY: 0,
                      renderWidth: renderWidth,
                      renderHeight: renderHeight,
                      scale: scale,
                      centerX: gameWidth / 2)
    }

    private func layout() -> Layout? {
        guard let aspect = canvas.courtAspect, bounds.height > 0 else { return nil }
        return Self.layout(viewport: bounds.size, courtAspect: aspect)
    }

    // MARK: - Input

    /// The `pointerdown` handler. See `TennisGame.handleTap` for why the mapping is the inverse
    /// of the court transform rather than the JS's stale 3D raycast.
    @objc private func courtTapped(_ recognizer: UITapGestureRecognizer) {
        guard let game, let layout = layout() else { return }
        let point = recognizer.location(in: self)
        let worldX = (point.x - layout.offsetX) / layout.scale - layout.centerX
        let worldY = (point.y - layout.offsetY) / layout.scale
        game.handleTap(worldX: Double(worldX), worldY: Double(worldY))
    }
}

// MARK: - The canvas

/// Everything the JS draws into `#uiCanvas` after the court bitmap.
private final class TennisCanvasView: UIView {
    var game: TennisGame?
    /// Width ÷ height of the court art. Nil until it has been rasterised, which is what the JS
    /// `if (!bgImage.complete) { restore(); return; }` guard waits for.
    var courtAspect: CGFloat?

    override func draw(_ rect: CGRect) {
        guard let game,
              let aspect = courtAspect,
              let context = UIGraphicsGetCurrentContext(),
              bounds.height > 0
        else { return }

        let layout = TennisView.layout(viewport: bounds.size, courtAspect: aspect)
        let canvas = Canvas2D(context)

        canvas.save()
        canvas.translate(layout.offsetX, layout.offsetY)
        canvas.scale(layout.scale, layout.scale)

        let courtScale = CGFloat(TennisGame.courtScale)
        let zoom = CGFloat(TennisGame.cameraZoom)

        let npcLimbs = TennisGame.limbs(for: game.npc,
                                        rightArmX: game.npc.racket.armX,
                                        rightArmY: game.npc.racket.armY)
        let playerLimbs = TennisGame.limbs(for: game.player,
                                           rightArmX: game.player.racket.armX,
                                           rightArmY: game.player.racket.armY)

        drawCharacterShadowed(canvas, layout: layout, zoom: zoom, courtScale: courtScale,
                              appearance: Character2D.Appearance(game.opponent),
                              side: game.npc, limbs: npcLimbs)

        drawInterceptCrosshair(canvas, game: game, layout: layout, courtScale: courtScale)

        drawCharacterShadowed(canvas, layout: layout, zoom: zoom, courtScale: courtScale,
                              appearance: Character2D.Appearance(game.myCharacter),
                              side: game.player, limbs: playerLimbs)

        if game.introPhase == .playing {
            drawBall(canvas, game: game, centerX: layout.centerX, courtScale: courtScale,
                     layoutScale: layout.scale)
        }

        // The admin-only layers — the bounce and NPC-intercept crosshairs, the racket hitbox
        // ellipses, the court bounds, the service box, and the whole side-profile diagnostics
        // panel — are all gated on `window.isAdmin` in the JS. Nothing carries that flag any
        // more: the editor is a separate Mac app that never opens a minigame, so they have no
        // native counterpart.

        canvas.restore()
    }

    // MARK: - Characters

    /// `drawCharacterShadowed` (`tennis.js:1721-1821`).
    private func drawCharacterShadowed(_ canvas: Canvas2D,
                                       layout: TennisView.Layout,
                                       zoom: CGFloat,
                                       courtScale: CGFloat,
                                       appearance: Character2D.Appearance,
                                       side: TennisGame.Side,
                                       limbs: Limbs2D) {
        let rotation = CGFloat(side.current.rotation) * .pi / 180
        let z = CGFloat(side.current.z)

        canvas.save()
        canvas.translate(layout.centerX + CGFloat(side.current.x), CGFloat(side.current.y))
        canvas.scale(zoom * courtScale, zoom * courtScale)

        // Soft body shadow, offset as if the sun were at 11 o'clock.
        var bodyShadow = canvas.createRadialGradient(-2, 4, 3, -2, 4, 15)
        bodyShadow.addColorStop(0, CSS.black(0.5))
        bodyShadow.addColorStop(1, CSS.black(0))
        canvas.fillStyle = .gradient(bodyShadow)
        canvas.beginPath()
        canvas.arc(-2, 4, 15, 0, .pi * 2)
        canvas.fill()

        canvas.save()
        canvas.translate(-2, 4)
        canvas.rotate(rotation)
        drawRacket(canvas, limbs: limbs, racket: side.racket, isShadow: true)
        canvas.restore()

        canvas.rotate(rotation)

        // The legs stretch: the torso lifts first, and only past `JUMP_Z` do the shoes leave
        // the ground with it.
        let shoeZ = max(0, z - CGFloat(TennisGame.jumpZ))
        let torsoZ = max(0, z) - shoeZ

        if shoeZ > 0 {
            canvas.save()
            canvas.rotate(-rotation)
            canvas.translate(-2, 4)
            canvas.rotate(rotation)

            let shadowRadius = max(1.0, 4 - shoeZ * 0.05)
            let opacity = max(0.1, 0.4 - shoeZ * 0.005)
            canvas.fillStyle = .color(CSS.black(opacity))

            canvas.beginPath()
            canvas.ellipse(limbs.leftLegEndX, limbs.leftLegEndY,
                           shadowRadius * 1.5, shadowRadius, 0, 0, .pi * 2)
            canvas.fill()

            canvas.beginPath()
            canvas.ellipse(limbs.rightLegEndX, limbs.rightLegEndY,
                           shadowRadius * 1.5, shadowRadius, 0, 0, .pi * 2)
            canvas.fill()
            canvas.restore()
        }

        canvas.rotate(-rotation)
        canvas.translate(0, -shoeZ / (zoom * courtScale))
        canvas.rotate(rotation)

        let shoeColor = appearance.shoeColor ?? "#1a252f"
        Character2D.drawShoe(canvas, x: limbs.leftLegEndX, y: limbs.leftLegEndY,
                             color: shoeColor, isLeft: true)
        Character2D.drawShoe(canvas, x: limbs.rightLegEndX, y: limbs.rightLegEndY,
                             color: shoeColor, isLeft: false)

        // Legs are drawn as single strokes from the hovering hip down to the planted shoe.
        let torsoOffsetScreen = -torsoZ / (zoom * courtScale)
        canvas.strokeStyle = .color(CSS.hex(appearance.pantsColor ?? "#2980b9"))
        canvas.lineWidth = 4.5
        canvas.lineCap = .round

        func drawStretchingLeg(_ startX: CGFloat, _ startY: CGFloat,
                               _ endX: CGFloat, _ endY: CGFloat) {
            canvas.beginPath()
            canvas.save()
            canvas.rotate(-rotation)
            canvas.translate(0, torsoOffsetScreen)
            canvas.rotate(rotation)
            canvas.moveTo(startX, startY)
            canvas.restore()
            canvas.lineTo(endX, endY)
            canvas.stroke()
        }

        drawStretchingLeg(limbs.leftLegStartX, limbs.leftLegStartY,
                          limbs.leftLegEndX, limbs.leftLegEndY)
        drawStretchingLeg(limbs.rightLegStartX, limbs.rightLegStartY,
                          limbs.rightLegEndX, limbs.rightLegEndY)

        canvas.rotate(-rotation)
        canvas.translate(0, -torsoZ / (zoom * courtScale))
        canvas.rotate(rotation)

        drawRacket(canvas, limbs: limbs, racket: side.racket, isShadow: false,
                   writeBackTo: side, layout: layout, courtScale: courtScale)
        Character2D.drawUpperBody(canvas, appearance, limbs)
        canvas.restore()
    }

    /// `drawRacket` (`tennis.js:1574-1663`).
    ///
    /// When `writeBackTo` is set this also does what the JS's `transformData` block does: pulls
    /// the racket head's canvas position back out of the transform and stores it as the hitbox
    /// the next frame's collision test uses.
    private func drawRacket(_ canvas: Canvas2D,
                            limbs: Limbs2D,
                            racket: TennisGame.Racket,
                            isShadow: Bool,
                            writeBackTo side: TennisGame.Side? = nil,
                            layout: TennisView.Layout? = nil,
                            courtScale: CGFloat = 1) {
        let pitch = CGFloat(racket.pitch)
        let yaw = CGFloat(racket.yaw)
        let roll = CGFloat(racket.roll)

        let pitchMult = max(0.05, abs(cos(pitch)))
        let rx = max(1, 8 * roll)

        canvas.save()
        canvas.translate(limbs.rightArmX, limbs.rightArmY)
        // Point the racket along the +X forward vector.
        canvas.rotate(yaw + .pi / 2)

        let handleLen = 15 * pitchMult
        if !isShadow {
            canvas.fillStyle = .color(CSS.hex("#2c3e50"))
            canvas.fillRect(-2, -handleLen + 5 * pitchMult, 4, handleLen)
            canvas.strokeStyle = .color(CSS.hex("#e74c3c"))
            canvas.lineWidth = 2
        }

        canvas.beginPath()
        let headCy = -18 * pitchMult
        let headRy = 12 * pitchMult
        canvas.ellipse(0, headCy, rx, max(1, headRy), 0, 0, .pi * 2)

        if isShadow {
            let radius = max(1, max(rx, headRy)) + 10.0
            var shadow = canvas.createRadialGradient(0, headCy, 0, 0, headCy, radius)
            shadow.addColorStop(0, CSS.black(0.1))
            shadow.addColorStop(1, CSS.black(0))
            canvas.fillStyle = .gradient(shadow)
            canvas.fill()
            canvas.restore()
            return
        }

        canvas.stroke()

        // Strings, clipped to the head.
        canvas.save()
        canvas.clip()
        canvas.strokeStyle = .color(CSS.rgba(236, 240, 241, 0.5))
        canvas.lineWidth = 0.5
        canvas.beginPath()

        var i: CGFloat = -5
        while i <= 5 {
            canvas.moveTo(i * roll, headCy - headRy + 2)
            canvas.lineTo(i * roll, headCy + headRy - 2)
            i += 3
        }
        var j = headCy - headRy + 2
        while j <= headCy + headRy - 2 {
            canvas.moveTo(-rx + 1, j)
            canvas.lineTo(rx - 1, j)
            j += 4 * pitchMult
        }
        canvas.stroke()
        canvas.restore()

        if let side, let layout {
            let point = canvas.transformPoint(CGPoint(x: 0, y: headCy))

            // Undo the viewport mapping to recover pure game coordinates.
            let gameX = (point.x - layout.offsetX) / layout.scale - layout.centerX
            let gameY = (point.y - layout.offsetY) / layout.scale

            side.racket.x = Double(gameX)
            side.racket.y = Double(gameY)
            side.racket.w = Double(max(1, rx * CGFloat(TennisGame.cameraZoom) * courtScale))
            side.racket.h = Double(max(1, headRy * CGFloat(TennisGame.cameraZoom) * courtScale))
            side.racket.angle = side.current.rotation * .pi / 180 + Double(yaw) + .pi / 2
        }

        canvas.restore()
    }

    // MARK: - Ball and crosshairs

    /// `drawBall` (`tennis.js:1827-1856`).
    private func drawBall(_ canvas: Canvas2D, game: TennisGame,
                          centerX: CGFloat, courtScale: CGFloat, layoutScale: CGFloat) {
        let ball = game.ball
        let x = CGFloat(ball.x)
        let y = CGFloat(ball.y)
        let z = CGFloat(ball.z)
        let radius = CGFloat(TennisGame.ballRadius)

        canvas.save()
        let shadowRadius = max(0.1, max(2 * courtScale, (radius * 2 - z * 0.05) * courtScale))
        let sx = centerX + x - 2
        let sy = y + 4

        var gradient = canvas.createRadialGradient(sx, sy, 0, sx, sy, shadowRadius)
        gradient.addColorStop(0, CSS.black(0.6))
        gradient.addColorStop(1, CSS.black(0))

        canvas.beginPath()
        canvas.fillStyle = .gradient(gradient)
        canvas.arc(sx, sy, shadowRadius, 0, .pi * 2)
        canvas.fill()
        canvas.restore()

        canvas.save()
        let size = max(6, radius * 2 * courtScale)
        canvas.translate(centerX + x, y - z)
        if let image = EmojiImage.image("🎾", pointSize: size * layoutScale) {
            canvas.drawImageCentered(image, size: size)
        } else {
            canvas.font = .systemFont(ofSize: size)
            canvas.fillTextCentered("🎾", 0, 0)
        }
        canvas.restore()
    }

    /// The green X marking where the player's swing is predicted to meet the ball
    /// (`tennis.js:1884-1906`). Eased towards the raw physics target so it does not jitter.
    private func drawInterceptCrosshair(_ canvas: Canvas2D, game: TennisGame,
                                        layout: TennisView.Layout, courtScale: CGFloat) {
        let servingAtUs = game.isServe == .npcServe && game.servePhase == .live
            && game.rallyCount > 0
        let shouldShow = (game.canCharacterHit(isPlayer: true) || servingAtUs)
            && game.ball.vy != 0 && !game.resetting

        guard shouldShow, let best = game.player.lastIntercept, best.t >= 0 else {
            game.player.visualInterceptTarget = nil
            return
        }

        let targetX = Double(layout.centerX) + best.x
        let targetY = best.y - best.z

        if var current = game.player.visualInterceptTarget {
            current.x += (targetX - current.x) * 0.25
            current.y += (targetY - current.y) * 0.25
            game.player.visualInterceptTarget = current
        } else {
            game.player.visualInterceptTarget = (x: targetX, y: targetY)
        }

        guard let point = game.player.visualInterceptTarget else { return }
        drawCrosshair(canvas, x: CGFloat(point.x), y: CGFloat(point.y),
                      color: CSS.rgba(46, 204, 113, 0.9), courtScale: courtScale)
    }

    /// `drawCrosshair` (`tennis.js:1858-1870`).
    private func drawCrosshair(_ canvas: Canvas2D, x: CGFloat, y: CGFloat,
                               color: CGColor, courtScale: CGFloat) {
        canvas.save()
        canvas.strokeStyle = .color(color)
        canvas.lineWidth = max(1, 2 * courtScale)
        canvas.beginPath()
        let size = 5 * courtScale
        canvas.moveTo(x - size, y - size)
        canvas.lineTo(x + size, y + size)
        canvas.moveTo(x + size, y - size)
        canvas.lineTo(x - size, y + size)
        canvas.stroke()
        canvas.restore()
    }
}
