import AVFoundation
import SpriteKit
import UIKit

/// **Angry Joel** — Angry Birds, with Joel in the slingshot and the pigs wearing a face of
/// their own. Joel's idea.
///
/// Pull a bird back from the slingshot, let go, and knock every pig off its tower. Three birds
/// a level — Joel, the Blues and Bomb; clear a level and the next one builds itself.
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
        /// **How big everything is.** 1 is normal; 1.425 is 42.5% bigger — the birds, the pigs,
        /// the blocks and the slingshot all grow together.
        static let bigness: CGFloat = 1.425
        /// **How big the buildings are**, on top of `bigness`. 1.5 is 50% bigger blocks and huts;
        /// the birds and pigs stay the same.
        static let buildingSize: CGFloat = 1.5
        /// How far back the slingshot stretches, in points.
        static let maxPull: CGFloat = 110
        /// How hard it flings: launch speed is the pull times this.
        static let power: CGFloat = 17
        /// How big a pig is (radius, points).
        static let pigRadius: CGFloat = 22 * bigness
        /// How much health a pig has. Every hit takes off how fast it was hit.
        static let pigHealth: CGFloat = 250
        /// How much a crash hurts: the speed of the crash times this. Smaller makes everything
        /// tougher; bigger makes everything break.
        static let hitDamage: CGFloat = 0.34
        /// Bumps gentler than this don't hurt anything — so a tower doesn't wreck itself
        /// just by standing there.
        static let gentleBump: CGFloat = 60
        /// Points for breaking a block.
        static let blockPoints = 500
        /// Points for each pig.
        static let pigPoints = 5000
        /// **The birds you get each level, in order.** Add more to get more goes.
        static let birds: [Bird] = [.joel, .blues, .bomb]
        /// How far Bomb's explosion reaches.
        static let blastRadius: CGFloat = 170
        /// How much damage the explosion does right in the middle.
        static let blastDamage: CGFloat = 900
        /// How hard the explosion throws things.
        static let blastPush: CGFloat = 900
        /// How many Blues you get when you tap.
        static let bluesSplit = 3
    }

    /// **The birds.** Each one has its own face, size and colour — and the Blues and Bomb have a
    /// trick when you tap the screen while they're flying.
    enum Bird {
        /// Joel: the red one. No trick — he just hits hard.
        case joel
        /// Tap while flying and he splits into three.
        case blues
        /// Tap while flying — or wait for him to hit something — and he explodes.
        case bomb

        var face: String {
            switch self {
            case .joel: return "avatars/angry_joel.png"
            case .blues: return "avatars/angry_joel_blues.png"
            case .bomb: return "avatars/angry_joel_bomb.png"
            }
        }
        var ring: UIColor {
            switch self {
            case .joel: return .systemRed
            case .blues: return UIColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)
            case .bomb: return UIColor(white: 0.08, alpha: 1)
            }
        }
        var radius: CGFloat {
            switch self {
            case .joel: return 24 * Tuning.bigness
            case .blues: return 16 * Tuning.bigness
            case .bomb: return 30 * Tuning.bigness
            }
        }
        var density: CGFloat {
            switch self {
            case .joel: return 1
            case .blues: return 1
            case .bomb: return 1.7
            }
        }
        /// Joel gets drawn-on angry eyebrows; the Blues' face is angry enough already.
        var eyebrows: Bool { self == .joel }
    }

    /// What a block is made of.
    enum Material {
        case wood, stone, glass

        var color: UIColor {
            switch self {
            case .wood: return UIColor(red: 0.8, green: 0.55, blue: 0.27, alpha: 1)
            case .stone: return UIColor(red: 0.55, green: 0.56, blue: 0.6, alpha: 1)
            case .glass: return UIColor(red: 0.68, green: 0.9, blue: 1, alpha: 0.75)
            }
        }
        /// How much bashing it takes before it breaks.
        var health: CGFloat {
            switch self {
            case .wood: return 500
            case .stone: return 1300
            case .glass: return 180
            }
        }
        var density: CGFloat {
            switch self {
            case .wood: return 0.6
            case .stone: return 1.4
            case .glass: return 0.4
            }
        }
    }

    /// One thing in a level: a block or a pig. `x` is measured from where the towers start,
    /// `y` up from the ground.
    enum Piece {
        case block(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, material: Material = .wood)
        case pig(x: CGFloat, y: CGFloat)
    }

    /// **A hut**: two posts, a roof, and a pig inside. `x` is the left post, `y` is what it
    /// stands on (0 is the ground). The roof's top is at `y + height + 14`.
    static func hut(_ x: CGFloat, _ y: CGFloat = 0, height: CGFloat = 60, pig: Bool = true,
                    material: Material = .wood) -> [Piece] {
        var pieces: [Piece] = [
            .block(x: x, y: y, w: 14, h: height, material: material),
            .block(x: x + 70, y: y, w: 14, h: height, material: material),
            .block(x: x + 35, y: y + height, w: 100, h: 14, material: material),
        ]
        if pig { pieces.append(.pig(x: x + 35, y: y)) }
        return pieces
    }

    /// **The levels.** Each one is a list of pieces — add a new list to add a level.
    /// There is room from `x: 0` out to about `x: 480`.
    static let levels: [[Piece]] = [
        // 1. Two little huts.
        hut(0, height: 70) + hut(250),
        // 2. One hut, a pig with nowhere to hide, and a glass hut out the back.
        hut(0) + [.pig(x: 125, y: 0)] + hut(280, material: .glass),
        // 3. The big castle, and a stone hut.
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
        ] + hut(290, material: .stone),
        // 4. A hut on a hut, and a glass hut on a stone hut.
        hut(0) + hut(0, 74) + [.pig(x: 35, y: 148)]
            + hut(250, material: .stone) + hut(250, 74, material: .glass),
        // 5. Three in a row, and one more.
        hut(0) + hut(100) + hut(200) + hut(330, height: 80, material: .stone),
        // 6. The pyramid, and a glass tower.
        hut(0) + hut(100) + hut(50, 74) + [.pig(x: 85, y: 148)]
            + hut(300, material: .glass) + hut(300, 74, material: .glass),
        // 7–12 are the hard ones — Joel's rule: **one big building each.**
        // 7. The tall tower.
        hut(100, height: 50) + hut(100, 64, height: 50, material: .stone) + hut(100, 128, height: 50)
            + [.pig(x: 135, y: 192)],
        // 8. The fortress: two tall huts with a lookout on top.
        hut(0, height: 80, material: .stone) + hut(100, height: 80, material: .stone)
            + hut(50, 94, height: 50) + [.pig(x: 85, y: 158)],
        // 9. Twin towers, joined by a bridge.
        hut(0, height: 50) + hut(0, 64, height: 50, material: .glass)
            + hut(150, height: 50) + hut(150, 64, height: 50, material: .glass)
            + [.block(x: 110, y: 128, w: 170, h: 14, material: .stone), .pig(x: 110, y: 142)],
        // 10. Pigs on stilts: three tall legs, one long deck.
        [
            .block(x: 0, y: 0, w: 14, h: 120),
            .block(x: 85, y: 0, w: 14, h: 120),
            .block(x: 170, y: 0, w: 14, h: 120),
            .block(x: 85, y: 120, w: 200, h: 14, material: .stone),
            .pig(x: 42, y: 0), .pig(x: 128, y: 0),
            .pig(x: 42, y: 134), .pig(x: 128, y: 134),
        ],
        // 11. The great castle.
        hut(0, material: .stone) + hut(100, material: .stone) + hut(200, material: .stone)
            + hut(50, 74) + hut(150, 74) + hut(100, 148, height: 50, material: .glass),
        // 12. Pig King's palace.
        hut(0, material: .stone) + hut(100, material: .stone) + hut(200, material: .stone)
            + hut(50, 74, material: .stone) + hut(150, 74, material: .stone)
            + hut(100, 148, height: 50) + [.pig(x: 135, y: 212)],
    ]

    private enum Category {
        static let bird: UInt32 = 1
        static let pig: UInt32 = 2
        static let block: UInt32 = 4
        static let ground: UInt32 = 8
    }

    /// How much of the world fits on the screen at once, with the phone held sideways. The
    /// camera zooms so this much shows.
    private static let viewSize = CGSize(width: 2400, height: 1100)
    /// **How wide a slice of the world shows with the phone held upright.** Smaller is more
    /// zoomed in — everything bigger on screen, and the camera follows the bird further.
    private static let uprightViewWidth: CGFloat = 2500
    /// **How wide the whole world is.** Wider than the screen, so the camera follows the bird
    /// out to the towers.
    private static let worldWidth: CGFloat = 2500

    private let world = SKNode()
    private let cam = SKCameraNode()
    private let band = SKShapeNode()
    private let scoreLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let birdsLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let messageLabel = SKLabelNode(fontNamed: "AvenirNext-Heavy")

    /// **The copyright note.** Shown on a card when the game opens, and in small letters along
    /// the bottom the whole time you play.
    static let copyrightNote = "Angry Birds was created by Rovio Entertainment. "
        + "Angry Joel is a fan-made version — it is not made by Rovio or connected to them."
    static let copyrightFooter = "Fan-made. Angry Birds is by Rovio Entertainment."

    private let introCard = SKShapeNode()
    private let introTitle = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let introNote = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    private let introTap = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    private let footer = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    /// True while the copyright card is up; the first tap closes it.
    private var showingIntro = true

    private var birdTextures: [Bird: SKTexture] = [:]
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

    /// Birds still waiting their turn, not counting the one in the slingshot.
    private var queue: [Bird] = []
    /// The bird sitting in the slingshot.
    private var loaded: SKSpriteNode?
    private var loadedKind: Bird = .joel
    /// Everything flying from the last shot — one bird, or three Blues.
    private var inFlight: [SKSpriteNode] = []
    private var flyingKind: Bird = .joel
    /// True from the moment a bird leaves the slingshot until it's all over.
    private var shotActive = false
    /// The Blues can split and Bomb can explode — once.
    private var trickReady = false
    /// Seconds until Bomb goes off by himself, once he's hit something.
    private var bombFuse: TimeInterval?

    private var dragging = false
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

    /// Where the camera is looking, left to right.
    private var camX: CGFloat = 0

    private var groundY: CGFloat { 50 }
    private var slingPoint: CGPoint { CGPoint(x: 290, y: groundY + 90 * Tuning.bigness) }
    private var towersX: CGFloat { 1280 }
    private var pigs: [SKNode] { world.children.filter { $0.name == "pig" } }
    private var birdsLeft: Int { queue.count + (loaded == nil ? 0 : 1) }

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

        for label in [scoreLabel, birdsLabel, messageLabel] {
            label.fontColor = .white
            label.zPosition = 100
            cam.addChild(label)
        }
        scoreLabel.fontSize = 22
        scoreLabel.horizontalAlignmentMode = .left
        birdsLabel.fontSize = 22
        birdsLabel.horizontalAlignmentMode = .right
        messageLabel.fontSize = 44
        messageLabel.numberOfLines = 2
        messageLabel.verticalAlignmentMode = .center

        footer.text = Self.copyrightFooter
        footer.fontColor = UIColor(red: 0.1, green: 0.2, blue: 0.35, alpha: 0.75)
        footer.horizontalAlignmentMode = .left
        footer.zPosition = 100
        cam.addChild(footer)

        introCard.fillColor = UIColor(white: 0, alpha: 0.75)
        introCard.strokeColor = .clear
        introCard.zPosition = 200
        introTitle.text = "ANGRY JOEL"
        introNote.text = Self.copyrightNote
        introNote.numberOfLines = 0
        introNote.verticalAlignmentMode = .center
        introTap.text = "Tap to play"
        for label in [introTitle, introNote, introTap] {
            label.fontColor = .white
            label.zPosition = 1
            introCard.addChild(label)
        }
        introTitle.fontColor = UIColor(red: 1, green: 0.35, blue: 0.3, alpha: 1)
        introTap.fontColor = UIColor(red: 0.5, green: 0.9, blue: 0.4, alpha: 1)
        cam.addChild(introCard)

        startLevel()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard built else { return }
        layoutHUD()
    }

    /// How zoomed out the camera is: big enough that `viewSize` of the world fits on screen.
    private var zoom: CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        if size.height > size.width {
            return Self.uprightViewWidth / size.width
        }
        return max(Self.viewSize.width / size.width, Self.viewSize.height / size.height)
    }

    /// **How much further the slingshot stretches when zoomed right out**, so it's still a
    /// proper pull for a thumb. The fling is just as hard either way.
    private var pullScale: CGFloat { min(2.5, max(1, zoom * 0.5)) }

    /// The furthest left and right the camera can look without showing past the world's ends.
    private var camRange: ClosedRange<CGFloat> {
        let half = size.width * zoom / 2
        let left = half, right = Self.worldWidth - half
        return left <= right ? left...right : (Self.worldWidth / 2)...(Self.worldWidth / 2)
    }

    /// Zooms the camera, keeps the ground along the bottom of the screen, and pins the score
    /// to the corners.
    private func layoutHUD() {
        guard size.width > 0, size.height > 0 else { return }
        cam.setScale(zoom)
        cam.position = CGPoint(x: camX.clamped(to: camRange), y: size.height * zoom / 2)

        // The HUD sits on the camera, so it is measured in screen points from the middle.
        let safe = view?.safeAreaInsets ?? .zero
        let top = size.height / 2 - max(safe.top, 16) - 24
        let wide = size.width > size.height
        scoreLabel.fontSize = wide ? 22 : 17
        birdsLabel.fontSize = wide ? 22 : 17
        scoreLabel.position = CGPoint(x: -size.width / 2 + max(safe.left, 16) + 8, y: top)
        if wide {
            birdsLabel.horizontalAlignmentMode = .right
            // Left of the Exit button.
            birdsLabel.position = CGPoint(x: size.width / 2 - max(safe.right, 16) - 90, y: top)
        } else {
            birdsLabel.horizontalAlignmentMode = .left
            birdsLabel.position = CGPoint(x: scoreLabel.position.x, y: top - 26)
        }
        messageLabel.fontSize = wide ? 44 : 30
        messageLabel.position = CGPoint(x: 0, y: wide ? size.height * 0.1 : 0)

        // Tucked under the score, where nothing is ever built.
        footer.fontSize = wide ? 12 : 11
        footer.position = CGPoint(x: scoreLabel.position.x, y: wide ? top - 26 : top - 50)

        // The copyright card, sized to the screen.
        let cardWidth = min(size.width - 40, 520)
        introNote.fontSize = wide ? 18 : 16
        introNote.preferredMaxLayoutWidth = cardWidth - 40
        let noteHeight = introNote.frame.height
        let cardHeight = noteHeight + 130
        introCard.path = CGPath(roundedRect: CGRect(x: -cardWidth / 2, y: -cardHeight / 2,
                                                    width: cardWidth, height: cardHeight),
                                cornerWidth: 18, cornerHeight: 18, transform: nil)
        introTitle.fontSize = 30
        introTitle.position = CGPoint(x: 0, y: cardHeight / 2 - 48)
        introNote.position = CGPoint(x: 0, y: 4)
        introTap.fontSize = 20
        introTap.position = CGPoint(x: 0, y: -cardHeight / 2 + 22)
        updateHUD()
    }

    private func updateHUD() {
        scoreLabel.text = "LEVEL \(level + 1)   SCORE \(score)"
        birdsLabel.text = "BIRDS LEFT: \(birdsLeft)"
    }

    private func startLevel() {
        world.removeAllChildren()
        built = true
        loaded = nil
        inFlight = []
        shotActive = false
        trickReady = false
        bombFuse = nil
        dragging = false
        waitingForTap = false
        levelWon = false
        levelAge = 0
        queue = Tuning.birds
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
            let k = Tuning.bigness * Tuning.buildingSize
            switch piece {
            case let .block(x, y, w, h, material):
                addBlock(center: CGPoint(x: towersX + x * k, y: groundY + (y + h / 2) * k),
                         size: CGSize(width: w * k, height: h * k), material: material)
            case let .pig(x, y):
                addPig(at: CGPoint(x: towersX + x * k, y: groundY + y * k + Tuning.pigRadius))
            }
        }

        // Start looking at the towers, then swing back to the slingshot — like the real thing.
        camX = camRange.upperBound
        layoutHUD()
        loadNextBird()
    }

    private func addBlock(center: CGPoint, size: CGSize, material: Material) {
        let block = SKSpriteNode(color: material.color, size: size)
        block.position = center
        block.name = "block"
        block.userData = ["health": material.health]
        let body = SKPhysicsBody(rectangleOf: size)
        body.categoryBitMask = Category.block
        body.contactTestBitMask = Category.bird | Category.block | Category.ground | Category.pig
        body.density = material.density
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
        body.contactTestBitMask = Category.bird | Category.block | Category.ground | Category.pig
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

    // MARK: - Birds

    private func texture(for bird: Bird) -> SKTexture {
        if let texture = birdTextures[bird] { return texture }
        let texture = SKTexture(image: Self.faceImage(path: bird.face, ring: bird.ring, angry: bird.eyebrows))
        birdTextures[bird] = texture
        return texture
    }

    private func makeBird(_ bird: Bird) -> SKSpriteNode {
        let node = SKSpriteNode(texture: texture(for: bird),
                                size: CGSize(width: bird.radius * 2, height: bird.radius * 2))
        node.zPosition = 10
        node.name = "bird"
        if bird == .bomb {
            // A fuse with a spark on the end.
            let fuse = SKShapeNode()
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: bird.radius * 0.9))
            path.addQuadCurve(to: CGPoint(x: bird.radius * 0.45, y: bird.radius * 1.45),
                              control: CGPoint(x: bird.radius * 0.05, y: bird.radius * 1.4))
            fuse.path = path
            fuse.strokeColor = UIColor(white: 0.2, alpha: 1)
            fuse.lineWidth = 4 * Tuning.bigness
            fuse.zPosition = -1
            node.addChild(fuse)
            let spark = SKShapeNode(circleOfRadius: 4 * Tuning.bigness)
            spark.fillColor = .systemOrange
            spark.strokeColor = .systemYellow
            spark.position = CGPoint(x: bird.radius * 0.45, y: bird.radius * 1.45)
            spark.run(.repeatForever(.sequence([.scale(to: 1.5, duration: 0.12),
                                                .scale(to: 0.8, duration: 0.12)])))
            node.addChild(spark)
        }
        return node
    }

    /// Puts the next bird in the slingshot, and lines the rest up on the grass behind it.
    private func loadNextBird() {
        world.children.filter { $0.name == "waiting" }.forEach { $0.removeFromParent() }
        guard !queue.isEmpty else {
            loaded = nil
            updateHUD()
            return
        }
        loadedKind = queue.removeFirst()
        let node = makeBird(loadedKind)
        node.position = slingPoint
        world.addChild(node)
        loaded = node
        drawBand(to: slingPoint)

        var x = slingPoint.x - 40 * Tuning.bigness
        for bird in queue {
            let waiting = makeBird(bird)
            waiting.name = "waiting"
            waiting.zPosition = 4
            x -= bird.radius
            waiting.position = CGPoint(x: x, y: groundY + bird.radius)
            x -= bird.radius + 8
            world.addChild(waiting)
        }
        updateHUD()
    }

    private func giveBody(_ node: SKSpriteNode, _ bird: Bird) -> SKPhysicsBody {
        let body = SKPhysicsBody(circleOfRadius: bird.radius)
        body.categoryBitMask = Category.bird
        body.contactTestBitMask = Category.pig | Category.block | Category.ground
        body.collisionBitMask = Category.pig | Category.block | Category.ground
        body.density = bird.density
        body.friction = 0.5
        body.restitution = 0.3
        body.usesPreciseCollisionDetection = true
        node.physicsBody = body
        return body
    }

    // MARK: - The slingshot

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        if showingIntro {
            closeIntro()
            return
        }
        if waitingForTap {
            nextAfterMessage()
            return
        }
        // A tap while the Blues or Bomb are flying sets off their trick.
        if shotActive && trickReady && !inFlight.isEmpty {
            useTrick()
            return
        }
        guard let loaded, !shotActive else { return }
        // About half a thumb's width on screen, however far out the camera is.
        if touch.location(in: self).distance(to: loaded.position) < max(90, 45 * zoom) {
            dragging = true
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let touch = touches.first, let loaded else { return }
        var offset = touch.location(in: self) - slingPoint
        let length = offset.length
        let maxPull = Tuning.maxPull * pullScale
        if length > maxPull { offset = offset * (maxPull / length) }
        loaded.position = slingPoint + offset
        drawBand(to: loaded.position)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let loaded else { return }
        dragging = false
        let pull = (slingPoint - loaded.position) * (1 / pullScale)
        guard pull.length > 12 else {
            // Barely pulled: put it back.
            loaded.position = slingPoint
            drawBand(to: slingPoint)
            return
        }
        fling(pull: pull)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func fling(pull: CGPoint) {
        guard let node = loaded else { return }
        NSLog("[AngryJoel] fling %@ pull=(%.0f, %.0f)", "\(loadedKind)", pull.x, pull.y)
        let body = giveBody(node, loadedKind)
        body.velocity = CGVector(dx: pull.x * Tuning.power, dy: pull.y * Tuning.power)
        body.angularVelocity = -6

        loaded = nil
        inFlight = [node]
        flyingKind = loadedKind
        shotActive = true
        trickReady = flyingKind != .joel
        bombFuse = nil
        flightTime = 0
        stillTime = 0
        updateHUD()
        drawBand(to: nil)
        Sound.play("media/jump.mp3")
    }

    private func useTrick() {
        trickReady = false
        switch flyingKind {
        case .joel:
            break
        case .blues:
            splitBlues()
        case .bomb:
            if let bomb = inFlight.first { explode(bomb) }
        }
    }

    /// One Blue becomes three, fanning out a little up and down.
    private func splitBlues() {
        guard let blue = inFlight.first, let body = blue.physicsBody else { return }
        NSLog("[AngryJoel] the Blues split")
        let v = body.velocity
        let extra = Tuning.bluesSplit - 1
        for i in 0..<extra {
            let angle: CGFloat = (i % 2 == 0 ? 1 : -1) * 0.22 * CGFloat(i / 2 + 1)
            let copy = makeBird(.blues)
            copy.position = blue.position
            world.addChild(copy)
            let copyBody = giveBody(copy, .blues)
            copyBody.velocity = CGVector(dx: v.dx * cos(angle) - v.dy * sin(angle),
                                         dy: v.dx * sin(angle) + v.dy * cos(angle))
            copyBody.angularVelocity = -6
            inFlight.append(copy)
        }
        Sound.play("media/hit_tennis_ball2.mp3", rate: 1.8)
    }

    /// **Bomb goes off.** Everything nearby is thrown away from him and hurt — more the closer
    /// it was.
    private func explode(_ bomb: SKSpriteNode) {
        NSLog("[AngryJoel] BOOM")
        let center = bomb.position
        inFlight.removeAll { $0 === bomb }
        bomb.removeFromParent()
        trickReady = false
        bombFuse = nil

        let caught = world.children.filter { node in
            node.physicsBody?.isDynamic == true && (node.position - center).length < Tuning.blastRadius
        }
        for node in caught {
            guard let body = node.physicsBody else { continue }
            let offset = node.position - center
            let distance = offset.length
            let strength = 1 - distance / Tuning.blastRadius
            let direction = distance > 1 ? offset * (1 / distance) : CGPoint(x: 0, y: 1)
            let kick = Tuning.blastPush * strength * body.mass
            body.applyImpulse(CGVector(dx: direction.x * kick, dy: (direction.y + 0.3) * kick))
            damage(node, by: Tuning.blastDamage * strength)
        }

        // The bang.
        let flash = SKShapeNode(circleOfRadius: Tuning.blastRadius)
        flash.position = center
        flash.fillColor = UIColor(red: 1, green: 0.6, blue: 0.1, alpha: 0.8)
        flash.strokeColor = .systemYellow
        flash.lineWidth = 8
        flash.zPosition = 40
        flash.setScale(0.2)
        world.addChild(flash)
        flash.run(.sequence([.group([.scale(to: 1, duration: 0.25), .fadeOut(withDuration: 0.4)]),
                             .removeFromParent()]))
        Sound.play("media/hit_tennis_ball2.mp3", rate: 0.5, volume: 1)
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
        let a = contact.bodyA, b = contact.bodyB

        // Bomb lights his fuse the first time he hits anything.
        if flyingKind == .bomb, trickReady, bombFuse == nil,
           a.categoryBitMask == Category.bird || b.categoryBitMask == Category.bird {
            bombFuse = 1.2
        }

        guard levelAge > 1 else { return }
        let va = speedBeforeHit[ObjectIdentifier(a)] ?? a.velocity
        let vb = speedBeforeHit[ObjectIdentifier(b)] ?? b.velocity
        let speed = (va - vb).length
        guard speed > Tuning.gentleBump else { return }
        for body in [a, b] {
            if let node = body.node { damage(node, by: speed * Tuning.hitDamage) }
        }
    }

    /// Takes health off a pig or a block, and breaks it if there's none left.
    private func damage(_ node: SKNode, by amount: CGFloat) {
        guard let health = node.userData?["health"] as? CGFloat else { return }
        let left = health - amount
        node.userData?["health"] = left
        if left <= 0 {
            if node.name == "pig" { pop(node) } else if node.name == "block" { smash(node) }
        }
    }

    private func smash(_ block: SKNode) {
        guard block.name == "block" else { return }
        block.name = "broken"
        block.physicsBody = nil
        score += Tuning.blockPoints
        updateHUD()
        // Splinters, the same colour as the block.
        let color = (block as? SKSpriteNode)?.color ?? Material.wood.color
        for _ in 0..<5 {
            let bit = SKSpriteNode(color: color,
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

        moveCamera(dt)

        // A pig that falls off the edge of the world is popped too.
        for pig in pigs where pig.position.y < -100 || pig.position.x > Self.worldWidth + 200 {
            pop(pig)
        }

        if demo { runDemo(dt) }
        // Checked even after "OUT OF BIRDS!", because a tower can still squash the last pig
        // a moment later — and that should count.
        if pigs.isEmpty && levelAge > 1 && !levelWon {
            levelWon = true
            score += birdsLeft * 10000
            let last = level == Self.levels.count - 1
            showMessage(last ? "YOU WIN!\nTap to play again" : "LEVEL CLEAR!\nTap for the next one")
            return
        }

        guard !waitingForTap, shotActive else { return }

        // Bomb's fuse.
        if let fuse = bombFuse {
            bombFuse = fuse - dt
            if fuse - dt <= 0, let bomb = inFlight.first { explode(bomb) }
        }

        flightTime += dt
        let maxSpeed = inFlight.compactMap { $0.physicsBody?.velocity.length }.max() ?? 0
        stillTime = maxSpeed < 20 ? stillTime + dt : 0
        let allGone = inFlight.allSatisfy {
            $0.position.x > Self.worldWidth + 100 || $0.position.x < -100 || $0.position.y < -100
        }
        if allGone || stillTime > 1 || flightTime > 8 {
            // Bomb that never went off goes off now.
            if trickReady, flyingKind == .bomb, let bomb = inFlight.first { explode(bomb) }
            for bird in inFlight {
                bird.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
            }
            inFlight = []
            shotActive = false
            trickReady = false
            if !queue.isEmpty {
                run(.wait(forDuration: 0.6)) { [weak self] in self?.loadNextBird() }
            } else {
                updateHUD()
                // Give the towers a moment to finish falling before saying it's over.
                run(.wait(forDuration: 3)) { [weak self] in
                    guard let self, !self.pigs.isEmpty, !self.waitingForTap else { return }
                    self.showMessage("OUT OF BIRDS!\nTap to try again")
                }
            }
        }
    }

    /// Follows whatever is flying; otherwise sits on the slingshot. At the start of a level it
    /// holds on the towers for a moment first, so you can see what you're up against.
    private func moveCamera(_ dt: TimeInterval) {
        let range = camRange
        var target = range.lowerBound
        // How quickly the camera catches up: snappy behind a fast bird, gentle otherwise.
        var catchUp: CGFloat = 3
        if shotActive, let lead = inFlight.map(\.position.x).max() {
            target = lead
            catchUp = 10
        } else if levelAge < 1.4 && !showingIntro {
            target = range.upperBound
        } else if showingIntro {
            target = range.upperBound
        }
        camX += (target.clamped(to: range) - camX) * min(1, CGFloat(dt) * catchUp)
        cam.position.x = camX.clamped(to: range)
    }

    private func closeIntro() {
        showingIntro = false
        levelAge = 0
        introCard.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
    }

    private func runDemo(_ dt: TimeInterval) {
        if showingIntro { closeIntro() }
        demoWait += dt
        // The Blues split, a little after launch.
        if shotActive, trickReady, flyingKind == .blues, flightTime > 0.4 { useTrick() }
        guard demoWait > 2.5 else { return }
        if waitingForTap {
            demoWait = 0
            NSLog("[AngryJoel] demo: %@ score=%d", messageLabel.text ?? "", score)
            nextAfterMessage()
            return
        }
        guard let loaded, !shotActive, levelAge > 2 else { return }
        demoWait = 0
        let pulls = [CGPoint(x: 100, y: 40), CGPoint(x: 100, y: 45), CGPoint(x: 95, y: 35)]
        let pull = pulls[demoShot % pulls.count]
        demoShot += 1
        loaded.position = slingPoint - pull * pullScale
        NSLog("[AngryJoel] demo: level %d shot %d", level + 1, demoShot)
        fling(pull: pull)
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
    /// A face that isn't there yet is a plain circle in the ring's colour.
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

    /// `rate` above 1 is higher and quicker; below 1 is deeper and slower.
    static func play(_ path: String, rate: Float = 1, volume: Float = 0.6) {
        guard let url = AssetLocator.url(for: path),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        players.removeAll { !$0.isPlaying }
        player.volume = volume
        if rate != 1 {
            player.enableRate = true
            player.rate = rate
        }
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

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
