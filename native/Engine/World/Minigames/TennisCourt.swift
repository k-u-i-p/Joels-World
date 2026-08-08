import CoreGraphics
import Foundation

/// Limb offsets in character-local space. `getLimbs` (`tennis.js:308-327`).
///
/// Lives in the `World` layer because `serveBall` needs the left hand's position to put the ball
/// in it; `Character2D` reads the same struct when it draws. `CGFloat` rather than `Double`
/// because every other reader is drawing code — this is a geometry type, not a renderer one, so
/// it does not breach the "no framework types below `Render`" rule PLAN.md §4 sets.
struct Limbs2D {
    var leftArmX: CGFloat = 0
    var leftArmY: CGFloat = 0
    var rightArmX: CGFloat = 0
    var rightArmY: CGFloat = 0
    var leftLegStartX: CGFloat = 0
    var leftLegStartY: CGFloat = 0
    var leftLegEndX: CGFloat = 0
    var leftLegEndY: CGFloat = 0
    var rightLegStartX: CGFloat = 0
    var rightLegStartY: CGFloat = 0
    var rightLegEndX: CGFloat = 0
    var rightLegEndY: CGFloat = 0
}

/// The court's dimensions and the vocabulary the simulation is written in.
///
/// Every number here is `tennis.js:21-44` scaled by `gameScale` — the court was shrunk from
/// its original 255 units to 120, and each velocity, gravity and net height is normalised
/// against that so the ball behaves identically at the new size. Nothing here is state; the
/// mutable half of the game is on `TennisGame` itself.
extension TennisGame {
    // MARK: - Constants (`tennis.js:21-44`)

    static let courtX: Double = -60
    static let courtY: Double = 85
    static let courtWidth: Double = 120
    static let courtHeight: Double = 205

    /// Normalises every velocity against the court having been shrunk from its original 255.
    static let gameScale = courtWidth / 255

    static let playerSpeed = 250 * gameScale
    static let npcSpeed = 175 * gameScale
    static let ballSpeed = 200 * gameScale
    static let maximumBallSpeed = 300 * gameScale
    static let ballRadius: Double = 3
    static let gravity = 800 * gameScale
    static let netHeight = 45 * gameScale
    static let dampingMultiplier: Double = 0.6
    static let maxJump: Double = 80
    static let minCrouch: Double = 5
    static let jumpZ: Double = 15
    static let restingZ: Double = 10
    static let restingRacketRoll: Double = 0.6

    static let playableOvershootX: Double = 75
    static let playableOvershootY: Double = 50
    static let playableHalfWidth = courtWidth / 2 + playableOvershootX

    static let playerBaseY = courtY + courtHeight + 10
    static let npcBaseY = courtY - 10

    static let netY = courtY + courtHeight / 2
    /// `camera.zoom` for this map, set once in `initMinigame` and never changed.
    static let cameraZoom: Double = 1.8
    /// The scale the court art is drawn at, `COURT_INNER_BOUNDS.width / 255`.
    static let courtScale = courtWidth / 255

    static let restingArmX = -2 + 4 * cos(Double.pi * 0.25)
    static let restingArmY = 14 + 4 * sin(Double.pi * 0.25)

    // MARK: - State

    struct Position {
        var x: Double = 0
        var y: Double = 0
        var z: Double = 0
        var rotation: Double = 0
    }

    /// Where the racket actually ended up, in game coordinates. Everything but `pitch`/`yaw`/
    /// `roll`/`armX`/`armY` is filled in by the renderer.
    struct Racket {
        var x: Double = 0
        var y: Double = 0
        var groundY: Double = 0
        var z: Double = 0
        var w: Double = 1
        var h: Double = 1
        var angle: Double = 0
        var pitch: Double = 0
        var yaw: Double = .pi * 0.25
        var roll: Double = TennisGame.restingRacketRoll
        var armX: Double = TennisGame.restingArmX
        var armY: Double = TennisGame.restingArmY
    }

    struct RacketTarget {
        var pitch: Double = 0
        var yaw: Double = .pi * 0.25
        var roll: Double = TennisGame.restingRacketRoll
        var armX: Double = TennisGame.restingArmX
        var armY: Double = TennisGame.restingArmY
    }

    /// The trajectory point a character has decided to swing at.
    struct Intercept {
        var x: Double
        var y: Double
        var z: Double
        var t: Double
        var vx: Double
        var vy: Double
        var vz: Double
    }

    struct Ball {
        var x: Double = 0
        var y: Double = TennisGame.courtY + TennisGame.courtHeight / 2
        var z: Double = 0
        var vx: Double = TennisGame.ballSpeed * 0.7
        var vy: Double = TennisGame.ballSpeed * 0.7
        var vz: Double = 0
    }

    final class Side {
        var current = Position()
        var target = Position()
        var racket = Racket()
        var racketTarget = RacketTarget()
        var score = 0
        var movementDirectionX: Double = 1
        var movementDirectionY: Double = 1
        var legTimer: Double = 0
        var lastIntercept: Intercept?
        var lastHitTarget: (x: Double, y: Double, z: Double)?
        var previousMoveToIntercept: Intercept?
        var lastJumpTime: Double = 0
        var lastZChangeTime: Double = 0
        /// Render-only easing of the green crosshair (`tennis.js:1893-1898`).
        var visualInterceptTarget: (x: Double, y: Double)?
    }

    enum ServeState { case playerServe, npcServe, inPlay }
    enum ServePhase { case idle, justThrown, live }
    enum IntroPhase { case walkToNet, shakeHands, walkToBaseline, playing }
    enum Hitter { case player, npc }

    struct ServiceBox {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
    }
}
