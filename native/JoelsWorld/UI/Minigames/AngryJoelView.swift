import AVFoundation
import SpriteKit
import UIKit

/// **Angry Joel** — Angry Birds, with Joel in the slingshot and the pigs wearing a face of
/// their own. Joel's idea.
///
/// Pull Joel back from the slingshot, let go, and knock every pig off its tower. Three Joels a
/// level; clear a level and the next one builds itself.
///
/// It is a SpriteKit scene rather than the Metal renderer, because SpriteKit already has the
/// one thing this game is made of: blocks that fall over. Everything Joel is likely to want to
/// change is in `AngryJoelScene.Tuning` or `AngryJoelScene.levels`.
final class AngryJoelView: UIView {
    private let skView = SKView()
    private let scene = AngryJoelScene(size: CGSize(width: 800, height: 400))
    private let exitButton = UIButton(type: .system)

    /// Tapped **Exit**. Nil hides the button — the `-angryjoel` test switch has nowhere to go.
    var onExit: (() -> Void)? {
        didSet { exitButton.isHidden = onExit == nil }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        skView.translatesAutoresizingMaskIntoConstraints = false
        skView.ignoresSiblingOrder = true
        addSubview(skView)
        NSLayoutConstraint.activate([
            skView.topAnchor.constraint(equalTo: topAnchor),
            skView.bottomAnchor.constraint(equalTo: bottomAnchor),
            skView.leadingAnchor.constraint(equalTo: leadingAnchor),
            skView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        scene.scaleMode = .resizeFill
        skView.presentScene(scene)

        var config = UIButton.Configuration.filled()
        config.title = "Exit"
        config.baseBackgroundColor = UIColor(white: 0, alpha: 0.35)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        exitButton.configuration = config
        exitButton.isHidden = true
        exitButton.translatesAutoresizingMaskIntoConstraints = false
        exitButton.addAction(UIAction { [weak self] _ in self?.onExit?() }, for: .touchUpInside)
        addSubview(exitButton)
        NSLayoutConstraint.activate([
            exitButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            exitButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

final class AngryJoelScene: SKScene, SKPhysicsContactDelegate {
    /// The numbers worth playing with.
    enum Tuning {
        /// **How big everything is.** 1 is normal; 1.425 is 42.5% bigger — Joel, the pigs, the
        /// blocks and the slingshot all grow together.
        static let bigness: CGFloat = 1.425
        /// How far back the slingshot stretches, in points.
        static let maxPull: CGFloat = 110
        /// How hard it flings: launch speed is the pull times this.
        static let power: CGFloat = 10
        /// How big Joel is (radius, points).
        static let joelRadius: CGFloat = 24 * bigness
        /// How big a pig is (radius, points).
        static let pigRadius: CGFloat = 22 * bigness
        /// How much health a pig has. Every hit takes off how fast it was hit.
        static let pigHealth: CGFloat = 150
        /// How much health a wooden block has.
        static let blockHealth: CGFloat = 500
        /// Bumps gentler than this don't hurt anything — so a tower doesn't wreck itself
        /// just by standing there.
        static let gentleBump: CGFloat = 60
        /// Points for breaking a block.
        static let blockPoints = 500
        /// Joels you get each level. Just one — make it count!
        static let joelsPerLevel = 1
        /// Points for each pig.
        static let pigPoints = 5000
    }

    /// One thing in a level: a wooden block or a pig. `x` is measured from where the towers
    /// start, `y` up from the ground.
    enum Piece {
        case block(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)
        case pig(x: CGFloat, y: CGFloat)
    }

    /// **A hut**: two posts, a roof, and a pig inside. `x` is the left post, `y` is what it
    /// stands on (0 is the ground). The roof's top is at `y + height + 14`.
    static func hut(_ x: CGFloat, _ y: CGFloat = 0, height: CGFloat = 60, pig: Bool = true) -> [Piece] {
        var pieces: [Piece] = [
            .block(x: x, y: y, w: 14, h: height),
            .block(x: x + 70, y: y, w: 14, h: height),
            .block(x: x + 35, y: y + height, w: 100, h: 14),
        ]
        if pig { pieces.append(.pig(x: x + 35, y: y)) }
        return pieces
    }

    /// **The levels.** Each one is a list of pieces — add a new list to add a level.
    static let levels: [[Piece]] = [
        // 1. One little hut.
        hut(0, height: 70),
        // 2. One hut, and a pig with nowhere to hide right behind it.
        hut(0) + [.pig(x: 125, y: 0)],
        // 3. The big castle.
        [
            .block(x: 0, y: 0, w: 14, h: 60),
            .block(x: 70, y: 0, w: 14, h: 60),
            .block(x: 140, y: 0, w: 14, h: 60),
            .block(x: 35, y: 60, w: 70, h: 14),
            .block(x: 105, y: 60, w: 70, h: 14),
            .pig(x: 35, y: 0),
            .pig(x: 105, y: 0),
            .block(x: 35, y: 74, w: 14, h: 50),
            .block(x: 105, y: 74, w: 14, h: 50),
            .block(x: 70, y: 124, w: 110, h: 14),
            .pig(x: 70, y: 74),
            .pig(x: 70, y: 138),
        ],
        // 4. A hut on a hut.
        hut(60) + hut(60, 74) + [.pig(x: 95, y: 148)],
        // 5. Three in a row.
        hut(0) + hut(100) + hut(200),
        // 6. The pyramid.
        hut(0) + hut(100) + hut(50, 74) + [.pig(x: 85, y: 148)],
        // 7. The tall tower.
        hut(100, height: 50) + hut(100, 64, height: 50) + hut(100, 128, height: 50)
            + [.pig(x: 135, y: 192)],
        // 8. The fortress: two tall huts with a lookout on top.
        hut(0, height: 80) + hut(100, height: 80) + hut(50, 94, height: 50)
            + [.pig(x: 85, y: 158)],
        // 9. Twin towers, joined by a bridge.
        hut(0, height: 50) + hut(0, 64, height: 50)
            + hut(150, height: 50) + hut(150, 64, height: 50)
            + [.block(x: 110, y: 128, w: 170, h: 14), .pig(x: 110, y: 142)],
        // 10. Pigs on stilts: three tall legs, one long deck.
        [
            .block(x: 0, y: 0, w: 14, h: 120),
            .block(x: 85, y: 0, w: 14, h: 120),
            .block(x: 170, y: 0, w: 14, h: 120),
            .block(x: 85, y: 120, w: 200, h: 14),
            .pig(x: 42, y: 0), .pig(x: 128, y: 0),
            .pig(x: 42, y: 134), .pig(x: 128, y: 134),
        ],
        // 11. The great castle.
        hut(0) + hut(100) + hut(200) + hut(50, 74) + hut(150, 74) + hut(100, 148, height: 50),
        // 12. Pig King's palace.
        hut(0) + hut(100) + hut(200) + hut(50, 74) + hut(150, 74) + hut(100, 148, height: 50)
            + [.pig(x: 135, y: 212)],
    ]

    private enum Category {
        static let joel: UInt32 = 1
        static let pig: UInt32 = 2
        static let block: UInt32 = 4
        static let ground: UInt32 = 8
    }

    /// The level is always this big. The camera zooms so all of it fits on the screen,
    /// whichever way round the phone is held.
    private static let levelSize = CGSize(width: 900, height: 420)

    private let world = SKNode()
    private let cam = SKCameraNode()
    private let band = SKShapeNode()
    private let scoreLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let joelsLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let messageLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")

    private lazy var joelTexture = SKTexture(image: Self.faceImage(path: "avatars/angry_joel.png",
                                                                   ring: .systemRed,
                                                                   angry: true))
    private lazy var pigTexture = SKTexture(image: Self.faceImage(path: "avatars/angry_joel_pig.png",
                                                                  ring: UIColor(red: 0.35, green: 0.75, blue: 0.2, alpha: 1),
                                                                  angry: false))

    /// `-angryjoellevel 9` starts on level 9 — for testing the hard ones.
    private var level: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-angryjoellevel"), i + 1 < args.count,
              let n = Int(args[i + 1]) else { return 0 }
        return max(0, min(n - 1, AngryJoelScene.levels.count - 1))
    }()
    private var score = 0
    private var joelsLeft = 0
    private var joel: SKSpriteNode?
    private var dragging = false
    private var flying = false
    private var flightTime: TimeInterval = 0
    private var stillTime: TimeInterval = 0
    /// Pigs can't be popped by the tower settling in the first second of a level.
    private var levelAge: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    private var waitingForTap = false
    private var levelWon = false
    /// `-angryjoeldemo`: a robot fires the shots, for testing without a thumb.
    private let demo = ProcessInfo.processInfo.arguments.contains("-angryjoeldemo")
    private var demoShot = 0
    private var demoWait: TimeInterval = 0
    private var built = false

    private var groundY: CGFloat { 50 }
    private var slingPoint: CGPoint { CGPoint(x: 120, y: groundY + 90 * Tuning.bigness) }
    private var towersX: CGFloat { 470 }
    private var pigs: [SKNode] { world.children.filter { $0.name == "pig" } }

    // MARK: - Setting up

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.53, green: 0.8, blue: 0.98, alpha: 1)
        physicsWorld.contactDelegate = self
        addChild(world)
        addChild(cam)
        camera = cam

        band.strokeColor = UIColor(red: 0.35, green: 0.18, blue: 0.08, alpha: 1)
        band.lineWidth = 6
        band.zPosition = 5
        addChild(band)

        for label in [scoreLabel, joelsLabel, messageLabel] {
            label.fontColor = .white
            label.zPosition = 100
            cam.addChild(label)
        }
        scoreLabel.fontSize = 22
        scoreLabel.horizontalAlignmentMode = .left
        joelsLabel.fontSize = 22
        joelsLabel.horizontalAlignmentMode = .right
        messageLabel.fontSize = 44
        messageLabel.numberOfLines = 2
        messageLabel.verticalAlignmentMode = .center

        startLevel()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard built else { return }
        layoutHUD()
    }

    /// Zooms the camera so the whole level fits, with the ground along the bottom of the
    /// screen, and pins the score to the corners.
    private func layoutHUD() {
        guard size.width > 0, size.height > 0 else { return }
        let level = Self.levelSize
        let zoom = max(level.width / size.width, level.height / size.height)
        cam.setScale(zoom)
        cam.position = CGPoint(x: size.width * zoom / 2, y: size.height * zoom / 2)

        // The HUD sits on the camera, so it is measured in screen points from the middle.
        let safe = view?.safeAreaInsets ?? .zero
        let top = size.height / 2 - max(safe.top, 16) - 24
        let wide = size.width > size.height
        scoreLabel.fontSize = wide ? 22 : 17
        joelsLabel.fontSize = wide ? 22 : 17
        scoreLabel.position = CGPoint(x: -size.width / 2 + max(safe.left, 16) + 8, y: top)
        joelsLabel.position = CGPoint(x: size.width / 2 - max(safe.right, 16) - 8,
                                      y: wide ? top : top - 26)
        if !wide { joelsLabel.horizontalAlignmentMode = .left; joelsLabel.position.x = scoreLabel.position.x }
        else { joelsLabel.horizontalAlignmentMode = .right }
        messageLabel.fontSize = wide ? 44 : 30
        messageLabel.position = CGPoint(x: 0, y: wide ? size.height * 0.1 : 0)
        updateHUD()
    }

    private func updateHUD() {
        scoreLabel.text = "LEVEL \(level + 1)   SCORE \(score)"
        joelsLabel.text = "JOELS LEFT: \(joelsLeft)"
    }

    private func startLevel() {
        world.removeAllChildren()
        built = true
        joel = nil
        flying = false
        dragging = false
        waitingForTap = false
        levelWon = false
        levelAge = 0
        joelsLeft = Tuning.joelsPerLevel
        messageLabel.text = nil

        // The ground.
        let ground = SKShapeNode(rect: CGRect(x: -2000, y: 0, width: 6000, height: groundY))
        ground.fillColor = UIColor(red: 0.36, green: 0.7, blue: 0.25, alpha: 1)
        ground.strokeColor = .clear
        ground.physicsBody = SKPhysicsBody(edgeFrom: CGPoint(x: -2000, y: groundY),
                                           to: CGPoint(x: 4000, y: groundY))
        ground.physicsBody?.categoryBitMask = Category.ground
        ground.physicsBody?.friction = 0.9
        world.addChild(ground)

        // The slingshot: a Y of two posts.
        let sling = slingPoint
        let post = SKShapeNode()
        let path = CGMutablePath()
        path.move(to: CGPoint(x: sling.x, y: groundY))
        path.addLine(to: CGPoint(x: sling.x, y: sling.y - 30 * Tuning.bigness))
        path.move(to: CGPoint(x: sling.x - 16 * Tuning.bigness, y: sling.y + 8 * Tuning.bigness))
        path.addLine(to: CGPoint(x: sling.x, y: sling.y - 30 * Tuning.bigness))
        path.addLine(to: CGPoint(x: sling.x + 16 * Tuning.bigness, y: sling.y + 8 * Tuning.bigness))
        post.path = path
        post.strokeColor = UIColor(red: 0.45, green: 0.25, blue: 0.1, alpha: 1)
        post.lineWidth = 10 * Tuning.bigness
        post.lineCap = .round
        post.zPosition = 1
        world.addChild(post)

        for piece in Self.levels[level] {
            switch piece {
            case let .block(x, y, w, h):
                let k = Tuning.bigness
                addBlock(center: CGPoint(x: towersX + x * k, y: groundY + (y + h / 2) * k),
                         size: CGSize(width: w * k, height: h * k))
            case let .pig(x, y):
                addPig(at: CGPoint(x: towersX + x * Tuning.bigness,
                                   y: groundY + y * Tuning.bigness + Tuning.pigRadius))
            }
        }

        layoutHUD()
        loadJoel()
    }

    private func addBlock(center: CGPoint, size: CGSize) {
        let block = SKSpriteNode(color: UIColor(red: 0.8, green: 0.55, blue: 0.27, alpha: 1), size: size)
        block.position = center
        block.name = "block"
        block.userData = ["health": Tuning.blockHealth]
        let body = SKPhysicsBody(rectangleOf: size)
        body.categoryBitMask = Category.block
        body.contactTestBitMask = Category.joel | Category.block | Category.ground | Category.pig
        body.density = 0.6
        body.friction = 0.8
        block.physicsBody = body
        world.addChild(block)
    }

    private func addPig(at point: CGPoint) {
        let pig = SKSpriteNode(texture: pigTexture,
                               size: CGSize(width: Tuning.pigRadius * 2, height: Tuning.pigRadius * 2))
        pig.position = point
        pig.name = "pig"
        pig.userData = ["health": Tuning.pigHealth]
        pig.zPosition = 2
        let body = SKPhysicsBody(circleOfRadius: Tuning.pigRadius)
        body.categoryBitMask = Category.pig
        body.contactTestBitMask = Category.joel | Category.block | Category.ground | Category.pig
        body.density = 0.5
        body.friction = 0.6
        pig.physicsBody = body

        // Pig ears.
        for side in [-1.0, 1.0] as [CGFloat] {
            let ear = SKShapeNode(circleOfRadius: 7 * Tuning.bigness)
            ear.fillColor = UIColor(red: 0.35, green: 0.75, blue: 0.2, alpha: 1)
            ear.strokeColor = .clear
            ear.position = CGPoint(x: side * Tuning.pigRadius * 0.7, y: Tuning.pigRadius * 0.85)
            ear.zPosition = -1
            pig.addChild(ear)
        }
        world.addChild(pig)
    }

    /// Puts the next Joel in the slingshot.
    private func loadJoel() {
        let node = SKSpriteNode(texture: joelTexture,
                                size: CGSize(width: Tuning.joelRadius * 2, height: Tuning.joelRadius * 2))
        node.position = slingPoint
        node.zPosition = 10
        node.name = "joel"
        world.addChild(node)
        joel = node
        flying = false
        drawBand(to: slingPoint)
    }

    // MARK: - The slingshot

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if waitingForTap {
            nextAfterMessage()
            return
        }
        guard let joel, !flying else { return }
        if touch.location(in: self).distance(to: joel.position) < 90 {
            dragging = true
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let touch = touches.first, let joel else { return }
        var offset = touch.location(in: self) - slingPoint
        let length = offset.length
        if length > Tuning.maxPull { offset = offset * (Tuning.maxPull / length) }
        joel.position = slingPoint + offset
        drawBand(to: joel.position)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let joel else { return }
        dragging = false
        let pull = slingPoint - joel.position
        guard pull.length > 12 else {
            // Barely pulled: put him back.
            joel.position = slingPoint
            drawBand(to: slingPoint)
            return
        }
        NSLog("[AngryJoel] fling pull=(%.0f, %.0f)", pull.x, pull.y)
        fling(joel, pull: pull)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func fling(_ joel: SKSpriteNode, pull: CGPoint) {
        let body = SKPhysicsBody(circleOfRadius: Tuning.joelRadius)
        body.categoryBitMask = Category.joel
        body.contactTestBitMask = Category.pig | Category.block
        body.density = 2
        body.friction = 0.5
        body.restitution = 0.3
        body.usesPreciseCollisionDetection = true
        joel.physicsBody = body
        body.velocity = CGVector(dx: pull.x * Tuning.power, dy: pull.y * Tuning.power)
        body.angularVelocity = -6

        flying = true
        flightTime = 0
        stillTime = 0
        joelsLeft -= 1
        updateHUD()
        drawBand(to: nil)
        Sound.play("media/jump.mp3")
    }

    private func drawBand(to point: CGPoint?) {
        guard let point else {
            band.path = nil
            return
        }
        let sling = slingPoint
        let path = CGMutablePath()
        path.move(to: CGPoint(x: sling.x - 16 * Tuning.bigness, y: sling.y + 8 * Tuning.bigness))
        path.addLine(to: point)
        path.addLine(to: CGPoint(x: sling.x + 16 * Tuning.bigness, y: sling.y + 8 * Tuning.bigness))
        band.path = path
    }

    // MARK: - Popping pigs

    /// How fast everything was going last frame. By the time `didBegin` hears about a crash
    /// the physics has already bounced things apart, so their speed *now* is no use — this is
    /// how hard they were going when they hit.
    private var speedBeforeHit: [ObjectIdentifier: CGVector] = [:]

    override func didSimulatePhysics() {
        speedBeforeHit.removeAll(keepingCapacity: true)
        for node in world.children {
            if let body = node.physicsBody { speedBeforeHit[ObjectIdentifier(body)] = body.velocity }
        }
    }

    func didBegin(_ contact: SKPhysicsContact) {
        guard levelAge > 1 else { return }
        let a = contact.bodyA, b = contact.bodyB
        let va = speedBeforeHit[ObjectIdentifier(a)] ?? a.velocity
        let vb = speedBeforeHit[ObjectIdentifier(b)] ?? b.velocity
        let speed = (va - vb).length
        guard speed > Tuning.gentleBump else { return }
        for body in [a, b] {
            guard let node = body.node, let health = node.userData?["health"] as? CGFloat else { continue }
            let left = health - speed
            node.userData?["health"] = left
            if left <= 0 {
                if node.name == "pig" { pop(node) } else if node.name == "block" { smash(node) }
            }
        }
    }

    private func smash(_ block: SKNode) {
        guard block.name == "block" else { return }
        block.name = "broken"
        block.physicsBody = nil
        score += Tuning.blockPoints
        updateHUD()
        // Splinters.
        for _ in 0..<5 {
            let bit = SKSpriteNode(color: UIColor(red: 0.8, green: 0.55, blue: 0.27, alpha: 1),
                                   size: CGSize(width: 8 * Tuning.bigness, height: 5 * Tuning.bigness))
            bit.position = block.position
            bit.zPosition = 3
            world.addChild(bit)
            let dx = CGFloat.random(in: -60...60), dy = CGFloat.random(in: 20...80)
            bit.run(.sequence([.group([.moveBy(x: dx, y: dy, duration: 0.5),
                                       .rotate(byAngle: .pi * 2, duration: 0.5),
                                       .fadeOut(withDuration: 0.5)]),
                               .removeFromParent()]))
        }
        block.run(.sequence([.fadeOut(withDuration: 0.1), .removeFromParent()]))
    }

    private func pop(_ pig: SKNode) {
        guard pig.name == "pig" else { return }
        pig.name = "popped"
        pig.physicsBody = nil
        score += Tuning.pigPoints
        updateHUD()
        NSLog("[AngryJoel] pig popped, %d left", pigs.count)
        Sound.play("media/hit_tennis_ball2.mp3")

        let points = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        points.text = "\(Tuning.pigPoints)"
        points.fontSize = 22
        points.fontColor = .white
        points.position = pig.position
        points.zPosition = 50
        world.addChild(points)
        points.run(.sequence([.group([.moveBy(x: 0, y: 50, duration: 0.8), .fadeOut(withDuration: 0.8)]),
                              .removeFromParent()]))

        pig.run(.sequence([.group([.scale(to: 1.6, duration: 0.15), .fadeOut(withDuration: 0.15)]),
                           .removeFromParent()]))
    }

    // MARK: - Every frame

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate == 0 ? 0 : min(currentTime - lastUpdate, 0.1)
        lastUpdate = currentTime
        levelAge += dt

        // A pig that falls off the edge of the world is popped too.
        for pig in pigs where pig.position.y < -100 || pig.position.x > Self.levelSize.width + 200 {
            pop(pig)
        }

        if demo { runDemo(dt) }
        // Checked even after "OUT OF JOELS!", because a tower can still squash the last pig
        // a moment later — and that should count.
        if pigs.isEmpty && levelAge > 1 && !levelWon {
            levelWon = true
            score += joelsLeft * 10000
            let last = level == Self.levels.count - 1
            showMessage(last ? "YOU WIN!\nTap to play again" : "LEVEL CLEAR!\nTap for the next one")
            return
        }

        guard !waitingForTap else { return }

        guard flying, let joel, let body = joel.physicsBody else { return }
        flightTime += dt
        stillTime = body.velocity.length < 20 ? stillTime + dt : 0
        let gone = joel.position.x > Self.levelSize.width + 100 || joel.position.x < -100 || joel.position.y < -100
        if gone || stillTime > 1 || flightTime > 8 {
            joel.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
            self.joel = nil
            flying = false
            if joelsLeft > 0 {
                run(.wait(forDuration: 0.4)) { [weak self] in self?.loadJoel() }
            } else {
                // Give the towers a moment to finish falling before saying it's over.
                run(.wait(forDuration: 3)) { [weak self] in
                    guard let self, !self.pigs.isEmpty, !self.waitingForTap else { return }
                    self.showMessage("OUT OF JOELS!\nTap to try again")
                }
            }
        }
    }

    private func runDemo(_ dt: TimeInterval) {
        demoWait += dt
        guard demoWait > 2.5 else { return }
        if waitingForTap {
            demoWait = 0
            NSLog("[AngryJoel] demo: %@ score=%d", messageLabel.text ?? "", score)
            nextAfterMessage()
            return
        }
        guard let joel, !flying, levelAge > 1.5 else { return }
        demoWait = 0
        let pulls = [CGPoint(x: 100, y: 30), CGPoint(x: 105, y: 45), CGPoint(x: 95, y: 20)]
        let pull = pulls[demoShot % pulls.count]
        demoShot += 1
        joel.position = slingPoint - pull
        NSLog("[AngryJoel] demo: level %d shot %d", level + 1, demoShot)
        fling(joel, pull: pull)
    }

    private func showMessage(_ text: String) {
        messageLabel.text = text
        waitingForTap = true
        updateHUD()
    }

    private func nextAfterMessage() {
        if pigs.isEmpty {
            if level == Self.levels.count - 1 {
                level = 0
                score = 0
            } else {
                level += 1
            }
        }
        startLevel()
    }

    // MARK: - Pictures

    /// A face cut into a circle with a coloured ring round it — and, for Joel, angry eyebrows.
    private static func faceImage(path: String, ring: UIColor, angry: Bool) -> UIImage {
        let size = CGSize(width: 256, height: 256)
        let photo = AssetLocator.url(for: path).flatMap { UIImage(contentsOfFile: $0.path) }
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
            cg.saveGState()
            cg.addEllipse(in: circle)
            cg.clip()
            if let photo {
                photo.draw(in: CGRect(origin: .zero, size: size))
            } else {
                ring.setFill()
                cg.fill(circle)
            }
            if angry {
                UIColor.black.setStroke()
                cg.setLineWidth(16)
                cg.setLineCap(.round)
                cg.move(to: CGPoint(x: 50, y: 66))
                cg.addLine(to: CGPoint(x: 112, y: 92))
                cg.move(to: CGPoint(x: 196, y: 66))
                cg.addLine(to: CGPoint(x: 134, y: 92))
                cg.strokePath()
            }
            cg.restoreGState()
            ring.setStroke()
            cg.setLineWidth(14)
            cg.strokeEllipse(in: circle)
        }
    }
}

/// Short one-shot sounds out of `assets/media`.
private enum Sound {
    private static var players: [AVAudioPlayer] = []

    static func play(_ path: String) {
        guard let url = AssetLocator.url(for: path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        players.removeAll { !$0.isPlaying }
        player.volume = 0.6
        player.play()
        players.append(player)
    }
}

private extension CGPoint {
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    var length: CGFloat { (x * x + y * y).squareRoot() }
    func distance(to other: CGPoint) -> CGFloat { (self - other).length }
}

private extension CGVector {
    static func - (a: CGVector, b: CGVector) -> CGVector { CGVector(dx: a.dx - b.dx, dy: a.dy - b.dy) }
    var length: CGFloat { (dx * dx + dy * dy).squareRoot() }
}
