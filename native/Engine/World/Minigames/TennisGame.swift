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

/// Port of `client/public/src/minigames/tennis.js` — the simulation half.
///
/// The rendering half is `TennisView`, and the two are coupled the same way the JS couples
/// them: **the racket hitbox is a by-product of drawing it.** `drawRacket` extracts the racket
/// head's position out of the canvas transform (`tennis.js:1641-1656`) and writes it back onto
/// `racketCurrentPosition`, which the *next* frame's `processRacketDeflections` tests the ball
/// against. That one-frame lag is load-bearing — the aim converges towards its target 10% a
/// frame, so testing against the drawn racket rather than the intended one is what makes a
/// mistimed swing miss. `TennisView.draw` writes `racket[.player/.npc]` for the same reason.
final class TennisGame: Minigame {
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

    let player = Side()
    let npc = Side()
    private(set) var ball = Ball()

    private(set) var bounceCount = 0
    private(set) var resetting = false
    private var resetDelayTimer: Double = 0
    private(set) var rallyCount = 0
    private(set) var introPhase: IntroPhase = .walkToNet
    private var introTimer: Double = 0
    private var nextServerIsPlayer = false
    private var lastHitter: Hitter?
    private(set) var isServe: ServeState = .inPlay
    private(set) var servePhase: ServePhase = .idle
    private var faults = 0
    private var serveSide: Double = -1
    private(set) var activeServiceBox: ServiceBox?
    private(set) var tossTarget: (x: Double, y: Double, z: Double)?

    /// The `setTimeout`s `serveBall` and `throwBall` schedule, as wall-clock deadlines so a
    /// stalled frame does not stretch the serve the way an accumulated `dt` would.
    private var throwDeadline: TimeInterval?
    private var apexDeadline: TimeInterval?

    /// The opponent's appearance, taken from the map's first NPC.
    private(set) var opponent: GameCharacter
    /// The local player's appearance, for the 2D drawing code.
    private(set) var myCharacter: GameCharacter?

    private unowned let host: MinigameHost
    private var active = false

    /// Raised whenever the score changes, so the scoreboard can be refreshed.
    var onScoreChanged: (() -> Void)?

    var usesWorldRenderer: Bool { false }

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host
        self.myCharacter = myCharacter
        // `tennis.js:589-593` — the map's first NPC, or a stand-in when it has none.
        self.opponent = npcs.first ?? GameCharacter(id: 999, name: "Opponent", width: 40,
                                                    height: 40, gender: "male",
                                                    shirt_color: "#e74c3c")
    }

    // MARK: - Lifecycle

    /// `initMinigame` (`tennis.js:585-696`), minus the DOM.
    func start() {
        Log.world("[Tennis] Initialising minigame")
        active = true

        serveSide = -1
        let serveOffset = Self.courtWidth * 0.4
        player.current.x = serveSide * -serveOffset
        player.current.y = Self.playerBaseY
        npc.current.x = serveSide * serveOffset
        npc.current.y = Self.npcBaseY
        resetDelayTimer = 0
        player.current.z = 0
        npc.current.z = 0
        npc.target = Position(x: npc.current.x, y: npc.current.y, z: 0, rotation: 90)
        player.target = Position(x: player.current.x, y: player.current.y, z: 0, rotation: 270)
        resetting = false

        // The cinematic walk-on, rather than serving straight away.
        introPhase = .walkToNet
        introTimer = 0
        player.current.y = Self.playerBaseY + 30
        npc.current.y = Self.npcBaseY - 30
        ball.z = -100
        ball.vx = 0
        ball.vy = 0

        host.minigamePlayBackground(path: "/media/hushed_crowd.mp3", volume: 0.5)
        onScoreChanged?()
    }

    func stop() {
        active = false
        throwDeadline = nil
        apexDeadline = nil
        host.minigameStopBackground()
    }

    /// The exit button — `tennis.js:684-692`.
    func requestExit() {
        host.minigameShowDialog("Return to the junior school?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    // MARK: - Scoring

    struct Score {
        var playerText: String?
        var npcText: String?
        var winner: Hitter?
    }

    /// `getTennisScore` (`tennis.js:907-916`).
    static func score(player p: Int, npc n: Int) -> Score {
        let points = ["Love", "15", "30", "40"]
        if p >= 4 || n >= 4 {
            if abs(p - n) >= 2 { return Score(winner: p > n ? .player : .npc) }
            if p == n { return Score(playerText: "Deuce", npcText: "Deuce") }
            return Score(playerText: p > n ? "Ad" : "-", npcText: n > p ? "Ad" : "-")
        }
        if p == 3 && n == 3 { return Score(playerText: "Deuce", npcText: "Deuce") }
        return Score(playerText: points[p], npcText: points[n])
    }

    var currentScore: Score { Self.score(player: player.score, npc: npc.score) }

    // MARK: - Input

    /// A tap on the court. Port of the `pointerdown` handler (`tennis.js:630-659`): tapping
    /// close to the predicted intercept sends the player to the spot that puts their racket on
    /// it; anything else is a plain "run here".
    ///
    /// **This is the one deliberate deviation from the JS.** The web handler converts the touch
    /// through `screenToWorld`, which raycasts against `threeCamera` — but `threeCamera` is
    /// never configured while a minigame runs, because `main.js`'s `draw` is unregistered from
    /// the game loop on the way in. It therefore still holds the *previous map's* camera, and
    /// the tap lands thousands of units from the court, leaving only the bounds clamp in
    /// `processCharacter` to salvage it. `TennisView` inverts its own court transform instead,
    /// which is the mapping the handler is plainly reaching for.
    func handleTap(worldX: Double, worldY: Double) {
        guard active, !resetting else { return }

        if let intercept = player.lastIntercept {
            let dx = worldX - intercept.x
            let dy = worldY - intercept.y
            if sqrt(dx * dx + dy * dy) < 40 {
                let optimal = optimalInterceptPosition(for: player, intercept: intercept)
                _ = moveCharacter(player, toX: optimal.x, y: optimal.y, z: Self.restingZ)
                return
            }
        }

        let target = Intercept(x: worldX, y: worldY, z: Self.restingZ, t: 0, vx: 0, vy: 0, vz: 0)
        let optimal = optimalInterceptPosition(for: player, intercept: target)
        _ = moveCharacter(player, toX: optimal.x, y: optimal.y, z: Self.restingZ)
    }

    // MARK: - Frame

    /// `run(dt)` (`tennis.js:1353-1561`), up to the point where the JS starts rendering.
    func update(dt: Double) {
        guard active else { return }
        fireDueTimers()

        if introPhase != .playing {
            handleIntroSequence(dt: dt)
            return
        }

        if resetting {
            let serveOffset = Self.courtWidth * 0.4
            let targetX = serveSide * serveOffset
            _ = moveCharacter(player, toX: targetX, y: Self.playerBaseY, z: Self.restingZ)
            _ = moveCharacter(npc, toX: -targetX, y: Self.npcBaseY, z: Self.restingZ)
        }
        // The web build's other movement source is the arrow keys, which no touch device has —
        // it hides the joystick on the way in (`tennis.js:675-676`). Tapping is the whole
        // control scheme on a phone, in both builds.

        processBallMovement(dt: dt)

        let playerMoved = processCharacter(player, isPlayer: true, dt: dt)
        if !playerMoved { player.target.rotation = 270 }

        // The NPC only repositions while it is legally allowed to play the ball.
        if canCharacterHit(isPlayer: false) { moveToIntercept(npc) }

        let npcMoved = processCharacter(npc, isPlayer: false, dt: dt)
        if !npcMoved { npc.target.rotation = 90 }

        let visualBallY = ball.y - ball.z

        if resetting && !playerMoved && !npcMoved {
            if resetDelayTimer > 0 {
                resetDelayTimer -= dt
            } else {
                serveBall(nextServerIsPlayer ? player : npc)
            }
        }

        // Racket contact is resolved before the floor can end the rally, so a shot scooped off
        // the deck on the same frame it lands still counts.
        processRacketDeflections(visualBallY: visualBallY)

        if !resetting {
            let isOffScreenX = abs(ball.x) > Self.playableHalfWidth + 150
            let courtMaxY = Self.courtY + Self.courtHeight
            let isOffScreenY = ball.y < Self.courtY - 150 || ball.y > courtMaxY + 150

            if isOffScreenX || isOffScreenY {
                if bounceCount == 0 {
                    // Flew out without ever bouncing.
                    if isServe != .inPlay {
                        triggerFault(playerServing: lastHitter == .player)
                    } else {
                        triggerPointReset(nextPlayerServing: lastHitter == .player)
                    }
                } else if bounceCount == 1 {
                    // Bounced in, then left the court — a winner.
                    triggerPointReset(nextPlayerServing: lastHitter == .npc)
                }
            }
        }
    }

    /// The two `setTimeout`s the serve sequence relies on.
    private func fireDueTimers() {
        let now = Date.timeIntervalSinceReferenceDate

        if let deadline = throwDeadline, now >= deadline {
            throwDeadline = nil
            throwBall(nextServerIsPlayer ? player : npc)
        }
        if let deadline = apexDeadline, now >= deadline {
            apexDeadline = nil
            setNewInterceptPoints()
            servePhase = .live
        }
    }

    // MARK: - Rules

    /// `canCharacterHit` (`tennis.js:115-164`). Reproduced statement for statement — several of
    /// the clauses are redundant with each other, and it is not worth guessing which.
    func canCharacterHit(isPlayer: Bool) -> Bool {
        if resetting { return false }
        if introPhase != .playing { return false }

        let lastHitterWasPlayer = lastHitter == .player

        if servePhase == .idle { return false }

        if isPlayer && lastHitterWasPlayer && isServe == .inPlay { return false }
        if !isPlayer && !lastHitterWasPlayer && isServe == .inPlay { return false }

        if isPlayer && isServe == .playerServe && servePhase == .idle { return false }
        if !isPlayer && isServe == .npcServe && servePhase == .idle { return false }

        if isPlayer && isServe == .npcServe && servePhase != .live { return false }
        if !isPlayer && isServe == .playerServe && servePhase != .live { return false }

        if isPlayer && isServe == .playerServe && servePhase == .live
            && (bounceCount > 0 || rallyCount > 0) { return false }
        if !isPlayer && isServe == .npcServe && servePhase == .live
            && (bounceCount > 0 || rallyCount > 0) { return false }

        if isPlayer && isServe == .npcServe && servePhase == .live && bounceCount == 0 { return false }
        if !isPlayer && isServe == .playerServe && servePhase == .live && bounceCount == 0 { return false }

        return true
    }

    private func distanceToBallXY(_ side: Side) -> Double {
        let dx = ball.x - side.current.x
        let dy = ball.y - side.current.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Aiming

    /// `calculateArmReach` (`tennis.js:192-231`).
    private func armReach(for side: Side, towards x: Double, _ y: Double, _ z: Double)
        -> (x: Double, y: Double, z: Double) {
        let dx = x - side.current.x
        let dy = y - side.current.y
        let dist2D = sqrt(dx * dx + dy * dy)

        let angleToBall = atan2(dy, dx)
        let charFacing = side.current.rotation * .pi / 180
        var localAngle = angleToBall - charFacing

        while localAngle <= -.pi { localAngle += .pi * 2 }
        while localAngle > .pi { localAngle -= .pi * 2 }

        // Anatomical limits: no bending the arm round into the character's own back.
        let minAngle = -Double.pi * 0.6      // backhand, -108°
        let maxAngle = Double.pi * 0.75      // forehand, 135°
        localAngle = min(max(localAngle, minAngle), maxAngle)

        let maxReach: Double = 14
        let actualReach = min(dist2D, maxReach)

        return (x: -2 + actualReach * cos(localAngle),
                y: 14 + actualReach * sin(localAngle),
                z: z)
    }

    /// `calculateRacketReturnAimAngle` (`tennis.js:241-304`). The stringbed normal bisects the
    /// incoming and outgoing directions; the handle then sits 90° off it.
    private func racketReturnAim(from incomingX: Double, _ incomingY: Double, _ incomingZ: Double,
                                 at pointX: Double, _ pointY: Double, _ pointZ: Double,
                                 side: Side,
                                 target: (x: Double, y: Double, z: Double))
        -> (roll: Double, pitch: Double, yaw: Double) {
        var bx = incomingX
        var by = incomingY
        let bz = incomingZ

        // A serve toss drifts sideways at a trivial speed; deflecting off that would aim the
        // racket at nothing. Zeroing it lets the normal point straight at the target.
        if isServe != .inPlay {
            bx = 0
            by = 0
        }

        let rawInLen = sqrt(bx * bx + by * by + bz * bz)
        let inLen = rawInLen == 0 ? 1 : rawInLen
        let vInX = bx / inLen
        let vInY = by / inLen
        let vInZ = bz / inLen

        let outDx = target.x - pointX
        let outDy = target.y - pointY
        let outDz = target.z - pointZ
        let rawOutLen = sqrt(outDx * outDx + outDy * outDy + outDz * outDz)
        let outLen = rawOutLen == 0 ? 1 : rawOutLen
        let vOutX = outDx / outLen
        let vOutY = outDy / outLen
        let vOutZ = outDz / outLen

        var nx = vOutX - vInX
        var ny = vOutY - vInY
        var nz = vOutZ - vInZ
        let rawNLen = sqrt(nx * nx + ny * ny + nz * nz)
        let nLen = rawNLen == 0 ? 1 : rawNLen
        nx /= nLen
        ny /= nLen
        nz /= nLen

        // The handle draws perpendicular to the strings' pushing normal.
        var absoluteYaw = atan2(ny, nx)
        absoluteYaw += .pi / 2

        let targetPitch = asin(min(1, max(-1, nz))) * 0.5
        // 0 stands the face up for a flat drive, 1 lays it flat for a scooped lob.
        let roll = abs(nz)

        let charFacing = side.current.rotation * .pi / 180
        var localYaw = absoluteYaw - charFacing
        while localYaw <= -.pi { localYaw += .pi * 2 }
        while localYaw > .pi { localYaw -= .pi * 2 }

        // Wrist limits, either side of the natural 45° resting yaw.
        localYaw = min(max(localYaw, -Double.pi * 0.25), Double.pi * 0.75)

        return (roll: roll, pitch: targetPitch, yaw: localYaw)
    }

    /// `getLimbs` (`tennis.js:308-327`).
    static func limbs(for side: Side, rightArmX: Double, rightArmY: Double) -> Limbs2D {
        let legSwing = CGFloat(sin(side.legTimer))
        let legStride: CGFloat = 5
        let armStride: CGFloat = 8
        let safeDirX = CGFloat(side.movementDirectionX == 0 ? 1 : side.movementDirectionX)
        let safeDirY = CGFloat(side.movementDirectionY == 0 ? 1 : side.movementDirectionY)

        return Limbs2D(
            leftArmX: -2 - legSwing * armStride, leftArmY: -14,
            rightArmX: CGFloat(rightArmX), rightArmY: CGFloat(rightArmY),
            leftLegStartX: -2, leftLegStartY: -6,
            leftLegEndX: -2 + (safeDirY * legSwing * legStride),
            leftLegEndY: -6 + (-safeDirX * legSwing * legStride),
            rightLegStartX: -2, rightLegStartY: 6,
            rightLegEndX: -2 - (safeDirY * legSwing * legStride),
            rightLegEndY: 6 - (-safeDirX * legSwing * legStride))
    }

    // MARK: - Prediction

    /// `calculateOptimalInterceptPoint` (`tennis.js:336-427`). Steps a copy of the ball forward
    /// at a fixed 60 Hz and scores every reachable point on it.
    private func optimalInterceptPoint(for side: Side) -> Intercept {
        var simX = ball.x
        var simY = ball.y
        var simZ = ball.z
        let simVX = ball.vx
        let simVY = ball.vy
        var simVZ = ball.vz
        var simBounces = bounceCount

        var bestScore = -Double.infinity
        var best = Intercept(x: simX, y: simY, z: simZ, t: -1, vx: simVX, vy: simVY, vz: simVZ)

        var currentT: Double = 0
        let simDt = 0.016
        let maxT = 5.0

        let isPlayer = side === player

        while currentT <= maxT {
            let isWithinCourtX = abs(simX) <= Self.playableHalfWidth
            let isWithinCourtY = simY >= (Self.npcBaseY - Self.playableOvershootY)
                && simY <= (Self.playerBaseY + Self.playableOvershootY)
            let isOnCorrectSide = isPlayer ? (simY >= Self.netY) : (simY <= Self.netY)

            // Only points the character could physically leap to or crouch under.
            let isWithinReachZ = simZ >= Self.minCrouch && simZ <= Self.maxJump
            let isComfortableZ = simZ >= Self.restingZ && simZ <= Self.jumpZ

            if isWithinCourtX && isWithinCourtY && isWithinReachZ && isOnCorrectSide {
                let distSq = pow(simX - side.current.x, 2)
                    + pow(simY - side.current.y, 2)
                    + pow(simZ - side.current.z, 2)

                var score = -distSq
                if isComfortableZ { score += 100_000 }
                // Hitting the ball on the way down is awkward; hitting it near its apex is not.
                if simVZ < 0 { score -= abs(simVZ) * 50 }
                score -= abs(simVZ) * 20
                score -= currentT * 2000

                if score > bestScore {
                    bestScore = score
                    best = Intercept(x: simX, y: simY, z: simZ, t: currentT,
                                     vx: simVX, vy: simVY, vz: simVZ)
                }
            }

            simZ += simVZ * simDt
            simVZ -= Self.gravity * simDt
            simX += simVX * simDt
            simY += simVY * simDt

            if simZ < 0 {
                simBounces += 1
                // Note the JS adds `state.bounceCount` a second time here; `simBounces` already
                // started from it. Reproduced, because it is what prunes the search.
                if simBounces + bounceCount > 1 { break }
                simZ = 0
                simVZ = abs(simVZ) * Self.dampingMultiplier
            }

            currentT += simDt

            if abs(simX) > Self.playableHalfWidth + 50
                || simY < Self.courtY - 100
                || simY > Self.courtY + Self.courtHeight + 100 {
                break
            }
        }

        return best
    }

    private func setNewInterceptPoints() {
        resetRacketToNeutral(player)
        resetRacketToNeutral(npc)

        player.lastIntercept = optimalInterceptPoint(for: player)
        npc.lastIntercept = optimalInterceptPoint(for: npc)
        player.previousMoveToIntercept = nil
        npc.previousMoveToIntercept = nil
    }

    /// `getLandingSpot` (`tennis.js:1135-1146`).
    func landingSpot() -> (x: Double, y: Double) {
        let det = ball.vz * ball.vz + 2 * Self.gravity * ball.z
        var tLand: Double = 0
        if det >= 0 { tLand = (ball.vz + sqrt(det)) / Self.gravity }
        return (x: ball.x + ball.vx * tLand, y: ball.y + ball.vy * tLand)
    }

    // MARK: - Ball physics

    private func moveBall(x: Double, y: Double, z: Double) {
        ball.x = x
        ball.y = y
        ball.z = z
        ball.vx = 0
        ball.vy = 0
        ball.vz = 0
    }

    /// `processBallMovement` (`tennis.js:447-503`).
    ///
    /// The web build also samples the flight into `trajectoryPoints` here, for the side-profile
    /// graph in the admin diagnostics overlay. That overlay is gated on `window.isAdmin`, and
    /// the native client has no admin mode (`admin.js` stays a web page — PLAN.md §7), so the
    /// sampling is left out along with the graph.
    private func processBallMovement(dt: Double) {
        let previousBallY = ball.y

        if servePhase == .idle { return }   // Ball in hand.

        ball.z += ball.vz * dt
        ball.vz -= Self.gravity * dt
        ball.x += ball.vx * dt
        ball.y += ball.vy * dt

        // Net collision: did the ball cross the centre line this frame, and how high was it?
        if (previousBallY < Self.netY && ball.y >= Self.netY)
            || (previousBallY >= Self.netY && ball.y < Self.netY) {
            if ball.z < Self.netHeight {
                ball.vy *= -0.3
                ball.vx *= 0.3
                ball.y = Self.netY + (ball.vy < 0 ? -5 : (ball.vy > 0 ? 5 : 0))
            }
        }

        if ball.z < 0 {
            ball.z = 0
            bounceCount += 1
            ball.vz = abs(ball.vz) * Self.dampingMultiplier
            onBounce()
        }
    }

    /// The bounce handler passed into `processBallMovement` (`tennis.js:1397-1452`).
    private func onBounce() {
        setNewInterceptPoints()

        if bounceCount == 1 && !resetting {
            guard let hitter = lastHitter else {
                // The serve toss hit the floor before the racket found it.
                triggerFault(playerServing: isServe == .playerServe)
                return
            }

            let minX = Self.courtX
            let maxX = Self.courtX + Self.courtWidth
            let minY = Self.courtY
            let maxY = Self.courtY + Self.courtHeight
            let inBoundsX = ball.x >= minX && ball.x <= maxX
            var validBounce = false

            if isServe != .inPlay {
                if let box = activeServiceBox,
                   ball.x >= box.minX, ball.x <= box.maxX,
                   ball.y >= box.minY, ball.y <= box.maxY {
                    validBounce = true
                    isServe = .inPlay    // The serve landed; the rally is open.
                }
            } else {
                switch hitter {
                case .player: validBounce = inBoundsX && ball.y >= minY && ball.y <= Self.netY
                case .npc: validBounce = inBoundsX && ball.y >= Self.netY && ball.y <= maxY
                }
            }

            if !validBounce {
                if isServe != .inPlay {
                    triggerFault(playerServing: hitter == .player)
                } else {
                    triggerPointReset(nextPlayerServing: hitter == .player)
                }
            }
        }

        // Two valid bounces means whoever should have returned it lost the point.
        if bounceCount == 2 && !resetting {
            triggerPointReset(nextPlayerServing: ball.y > Self.netY)
        }
    }

    /// `hitBallToTarget` (`tennis.js:513-575`).
    private func hitBallToTarget(x targetX: Double, y targetY: Double, velocity: Double) {
        var boundedVelocity = min(velocity, Self.maximumBallSpeed)
        bounceCount = 0

        let dx = targetX - ball.x
        let dy = targetY - ball.y
        let dist = sqrt(dx * dx + dy * dy)

        var timeToTarget = dist / boundedVelocity

        // Cap the flight time so nothing turns into a moonball; a target further away than that
        // gets driven harder and flatter instead.
        let maxFlightTime = 1.3
        if timeToTarget > maxFlightTime {
            timeToTarget = maxFlightTime
            boundedVelocity = dist / timeToTarget
        }

        var vZ = (0.5 * Self.gravity * timeToTarget * timeToTarget - ball.z) / timeToTarget

        let crossesNet = (ball.y < Self.netY && targetY > Self.netY)
            || (ball.y > Self.netY && targetY < Self.netY)

        if crossesNet {
            let timeToNet = (abs(Self.netY - ball.y) / abs(dy)) * timeToTarget
            let requiredClearanceHeight = Self.netHeight + Self.ballRadius + 5
            let minVZ = (requiredClearanceHeight - ball.z
                         + 0.5 * Self.gravity * timeToNet * timeToNet) / timeToNet

            // A flat stroke that would hit the net gets an upward assist — but a hard, fast or
            // very low shot resists it, which is what lets a ball find the net at all.
            if vZ < minVZ {
                var assist = 1.0
                if boundedVelocity > 250 { assist -= 0.2 }
                if ball.z < 20 { assist -= 0.4 }
                assist = min(max(assist + (Double.random(in: 0..<1) * 0.2 - 0.1), 0), 1)
                vZ = vZ + (minVZ - vZ) * assist
            }
        }

        ball.vz = vZ
        ball.vx = (dx / dist) * boundedVelocity
        ball.vy = (dy / dist) * boundedVelocity
    }

    // MARK: - Serving

    /// `generateReturnBallHitCords` (`tennis.js:712-748`).
    private func returnBallHitTarget(isPlayer: Bool, racket: Racket?) -> (x: Double, y: Double) {
        if isServe != .inPlay {
            return serveTarget(isPlayer: isPlayer)
        }

        let courtCenterX = Self.courtX + Self.courtWidth / 2
        var targetX: Double
        var targetY: Double

        if isPlayer {
            // Deep into the NPC's half, diagonally away from where it is standing.
            targetY = Self.courtY + Self.courtHeight * (0.1 + Double.random(in: 0..<1) * 0.25)
            targetX = npc.current.x > courtCenterX
                ? Self.courtX + Self.courtWidth * (0.1 + Double.random(in: 0..<1) * 0.2)
                : Self.courtX + Self.courtWidth * (0.8 + Double.random(in: 0..<1) * 0.1)

            // How cleanly the racket met the ball skews the shot.
            if let racket { targetX += (ball.x - racket.x) * 1.5 }
        } else {
            targetY = Self.courtY + Self.courtHeight * (0.6 + Double.random(in: 0..<1) * 0.3)
            targetX = Self.courtX + Self.courtWidth * (0.15 + Double.random(in: 0..<1) * 0.7)
        }

        targetX = min(max(targetX, Self.courtX + 10), Self.courtX + Self.courtWidth - 10)
        return (x: targetX, y: targetY)
    }

    /// `calculateServeTarget` (`tennis.js:750-773`) — 90% aimed inside the box, 10% a fault.
    private func serveTarget(isPlayer: Bool) -> (x: Double, y: Double) {
        guard let box = activeServiceBox else { return (0, 0) }

        if Double.random(in: 0..<1) < 0.9 {
            let aimWide = Double.random(in: 0..<1) > 0.5
            let safeLeft = box.minX + 15
            let safeRight = box.maxX - 15
            let safeY = isPlayer ? box.minY + 20 : box.maxY - 20

            var tx = aimWide ? safeLeft : safeRight
            var ty = safeY
            tx += Double.random(in: 0..<1) * 10 - 5
            ty += Double.random(in: 0..<1) * 10 - 5
            return (x: tx, y: ty)
        }

        return (x: box.minX + Double.random(in: 0..<1) * (box.maxX - box.minX)
                    + (Double.random(in: 0..<1) * 60 - 30),
                y: box.minY + Double.random(in: 0..<1) * (box.maxY - box.minY)
                    + (isPlayer ? -40 : 40))
    }

    /// `serveBall` (`tennis.js:781-845`).
    private func serveBall(_ side: Side) {
        let isPlayer = side === player
        resetting = false
        isServe = isPlayer ? .playerServe : .npcServe
        servePhase = .idle
        player.lastIntercept = nil
        npc.lastIntercept = nil
        player.previousMoveToIntercept = nil
        npc.previousMoveToIntercept = nil

        // Put the ball in the server's left hand.
        let server = isPlayer ? player : npc
        let rotation = server.current.rotation * .pi / 180
        let limbs = Self.limbs(for: server, rightArmX: 0, rightArmY: 0)

        let leftArmX = Double(limbs.leftArmX)
        let leftArmY = Double(limbs.leftArmY)
        let armWorldX = (leftArmX * cos(rotation) - leftArmY * sin(rotation))
            * Self.cameraZoom * Self.courtScale
        let armWorldY = (leftArmX * sin(rotation) + leftArmY * cos(rotation))
            * Self.cameraZoom * Self.courtScale

        moveBall(x: server.current.x + armWorldX,
                 y: server.current.y + armWorldY,
                 z: server.current.z)

        // Service boxes, cross-court, inside the singles lines (12.5% doubles alleys a side).
        let centerX = Self.courtX + Self.courtWidth / 2
        let serviceBoxDepth = Self.courtHeight * 0.245
        let doublesAlleyWidth = Self.courtWidth * 0.125
        let singlesMinX = Self.courtX + doublesAlleyWidth
        let singlesMaxX = Self.courtX + Self.courtWidth - doublesAlleyWidth

        if isPlayer {
            activeServiceBox = ServiceBox(
                minX: serveSide == -1 ? centerX : singlesMinX,
                maxX: serveSide == -1 ? singlesMaxX : centerX,
                minY: Self.netY - serviceBoxDepth,
                maxY: Self.netY)
        } else {
            activeServiceBox = ServiceBox(
                minX: serveSide == 1 ? centerX : singlesMinX,
                maxX: serveSide == 1 ? singlesMaxX : centerX,
                minY: Self.netY,
                maxY: Self.netY + serviceBoxDepth)
        }

        lastHitter = isPlayer ? .player : .npc

        // A one-second beat before the toss.
        throwDeadline = Date.timeIntervalSinceReferenceDate + 1.0
    }

    /// `throwBall` (`tennis.js:861-904`) — the toss, timed so the ball is at its apex when the
    /// server is allowed to strike it.
    private func throwBall(_ side: Side) {
        let isPlayer = side === player
        servePhase = .justThrown

        let startX = ball.x
        let startY = ball.y

        tossTarget = (x: startX + (isPlayer ? 85 * Self.gameScale : -85 * Self.gameScale),
                      y: startY + (isPlayer ? -15 * Self.gameScale : 15 * Self.gameScale),
                      z: 125 * Self.gameScale)
        guard let toss = tossTarget else { return }

        let dz = max(1, toss.z - ball.z)
        let vZ = sqrt(2 * Self.gravity * dz)
        let tApex = vZ / Self.gravity
        let tFall = sqrt((2 * toss.z) / Self.gravity)
        let tTotalFlight = tApex + tFall

        ball.vx = (toss.x - startX) / tTotalFlight
        ball.vy = (toss.y - startY) / tTotalFlight
        ball.vz = vZ

        bounceCount = 0
        rallyCount = 0

        apexDeadline = Date.timeIntervalSinceReferenceDate + tApex
    }

    /// `triggerFault` (`tennis.js:926-944`).
    private func triggerFault(playerServing: Bool) {
        if resetting { return }
        faults += 1

        if faults >= 2 {
            triggerPointReset(nextPlayerServing: !playerServing)
        } else {
            resetting = true
            resetDelayTimer = 1.0
            nextServerIsPlayer = playerServing    // Same server, second serve.
        }

        player.lastIntercept = nil
        npc.lastIntercept = nil
    }

    /// `triggerPointReset` (`tennis.js:952-993`). The loser of the rally serves next, which is
    /// also how the point is attributed.
    private func triggerPointReset(nextPlayerServing: Bool) {
        if resetting { return }
        resetting = true
        player.previousMoveToIntercept = nil
        npc.previousMoveToIntercept = nil
        player.lastHitTarget = nil
        npc.lastHitTarget = nil

        if nextPlayerServing { npc.score += 1 } else { player.score += 1 }
        faults = 0

        var wonSet = false
        let scoreData = Self.score(player: player.score, npc: npc.score)
        if let winner = scoreData.winner {
            if winner == .player {
                host.minigameAwardBadge("tennis")
                wonSet = true
            }
            player.score = 0
            npc.score = 0
        }
        onScoreChanged?()

        self.nextServerIsPlayer = nextPlayerServing
        // Deuce court (-1) on an even total, advantage court (1) on an odd one.
        serveSide = (player.score + npc.score) % 2 == 0 ? -1 : 1
        resetDelayTimer = 1.5

        if wonSet {
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 1.0)
        } else if rallyCount >= 4 {
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.7)
        }
    }

    // MARK: - Contact

    /// `processRacketDeflections` (`tennis.js:1001-1021`) and the hit handler that follows it
    /// (`tennis.js:1504-1540`). The hitbox is the ellipse the racket head was *drawn* as.
    private func processRacketDeflections(visualBallY: Double) {
        if resetting { return }

        func evaluateHit(_ racket: Racket) -> Bool {
            let dx = ball.x - racket.x
            let dy = visualBallY - racket.y
            let localDx = dx * cos(-racket.angle) - dy * sin(-racket.angle)
            let localDy = dx * sin(-racket.angle) + dy * cos(-racket.angle)

            return pow(localDx, 2) / pow(racket.w + Self.ballRadius, 2)
                + pow(localDy, 2) / pow(racket.h + Self.ballRadius, 2) <= 1
        }

        if canCharacterHit(isPlayer: true) && evaluateHit(player.racket) {
            processHit(isPlayer: true)
        } else if canCharacterHit(isPlayer: false) && evaluateHit(npc.racket) {
            processHit(isPlayer: false)
        }
    }

    private func processHit(isPlayer: Bool) {
        let side = isPlayer ? player : npc
        let payload = side.lastHitTarget.map { (x: $0.x, y: $0.y) }
            ?? returnBallHitTarget(isPlayer: isPlayer, racket: side.racket)

        var returnSpeed = sqrt(ball.vx * ball.vx + ball.vy * ball.vy) * (isPlayer ? 1.05 : 1.1)
        if isServe != .inPlay {
            returnSpeed = Self.ballSpeed * (isPlayer ? 0.8 : 0.65)
        }

        rallyCount += 1
        lastHitter = isPlayer ? .player : .npc
        bounceCount = 0
        hitBallToTarget(x: payload.x, y: payload.y, velocity: returnSpeed)

        let soundFile = isPlayer ? "/media/hit_tennis_ball.mp3" : "/media/hit_tennis_ball2.mp3"
        host.minigamePlayEffect(path: soundFile,
                                volume: 0.7 + Double.random(in: 0..<1) * 0.5,
                                rate: 0.85 + Double.random(in: 0..<1) * 0.3)

        ball.z = max(10, ball.z)    // Lift a ball scooped off the deck.

        setNewInterceptPoints()

        if isPlayer {
            if isServe == .playerServe {
                // Chase the serve down where it is going to land.
                let spot = landingSpot()
                _ = moveCharacter(npc,
                                  toX: spot.x + 40 * Self.gameScale,
                                  toY: spot.y - 220 * Self.gameScale * 0.7)
            } else {
                _ = moveCharacter(npc,
                                  toX: Self.courtX + (Self.courtWidth / 2)
                                       * (0.5 + Double.random(in: 0..<1)),
                                  toY: Self.npcBaseY + 50 * Self.gameScale
                                       * (0.5 + Double.random(in: 0..<1)))
            }
        }
    }

    // MARK: - Movement

    /// `moveCharacterTo` (`tennis.js:1026-1034`). Returns whether the character still has
    /// meaningful distance to cover.
    @discardableResult
    private func moveCharacter(_ side: Side, toX x: Double, y: Double,
                               z: Double = TennisGame.restingZ) -> Bool {
        side.target.x = x
        side.target.y = y
        side.target.z = z
        return abs(x - side.current.x) > 10
            || abs(y - side.current.y) > 10
            || abs(z - side.current.z) > 10
    }

    /// The two-argument form the JS gets from a default parameter.
    @discardableResult
    private func moveCharacter(_ side: Side, toX x: Double, toY y: Double) -> Bool {
        moveCharacter(side, toX: x, y: y, z: Self.restingZ)
    }

    /// `getOptimalInterceptPosition` (`tennis.js:1037-1072`). Where the *body* has to stand for
    /// the racket head to end up on the intercept point.
    private func optimalInterceptPosition(for side: Side, intercept: Intercept)
        -> (x: Double, y: Double, z: Double) {
        let rotation = side.current.rotation * .pi / 180
        let racket = side.racket

        let armWorldX = racket.armX * cos(rotation) - racket.armY * sin(rotation)
        let armWorldY = racket.armX * sin(rotation) + racket.armY * cos(rotation)

        let maxReach: Double = 43

        let absoluteYaw = racket.yaw + rotation
        let handleWorldX = cos(absoluteYaw)
        let handleWorldY = sin(absoluteYaw)

        // An arm forced to tilt up or down covers less ground horizontally.
        let dz = intercept.z - side.current.z
        let planarScale = sqrt(max(0.1, 1 - pow(min(abs(dz), maxReach) / maxReach, 2)))

        var stringbedWorldX = (armWorldX + handleWorldX) * planarScale
        let stringbedWorldY = (armWorldY + handleWorldY) * planarScale

        if side === npc {
            stringbedWorldX -= maxReach / 2 * Self.gameScale
        } else {
            stringbedWorldX += maxReach / 2 * Self.gameScale
        }

        return (x: intercept.x - stringbedWorldX,
                y: intercept.y - stringbedWorldY,
                z: intercept.z)
    }

    /// `moveToIntercept` (`tennis.js:1454-1470`) — only re-targets when the prediction moves.
    private func moveToIntercept(_ side: Side) {
        if side.lastIntercept == nil { setNewInterceptPoints() }
        guard let intercept = side.lastIntercept else { return }

        if let previous = side.previousMoveToIntercept,
           previous.x == intercept.x, previous.y == intercept.y {
            return
        }

        let target = optimalInterceptPosition(for: side, intercept: intercept)
        _ = moveCharacter(side, toX: target.x, y: target.y, z: Self.restingZ)
        side.previousMoveToIntercept = intercept
    }

    /// `convergePhysics` (`tennis.js:1148-1226`).
    @discardableResult
    private func convergePhysics(_ side: Side, dt: Double, isPlayer: Bool,
                                 speedMult: Double = 1.0) -> Bool {
        let prevX = side.current.x
        let prevY = side.current.y
        let speed = (isPlayer ? Self.playerSpeed : Self.npcSpeed) * dt * speedMult

        var mx: Double = 0
        let dx = side.target.x - side.current.x
        if abs(dx) > 1 {
            mx = (dx < 0 ? -1 : 1) * min(speed, abs(dx))
            side.current.x += mx
        } else {
            side.current.x = side.target.x
        }

        var my: Double = 0
        let dy = side.target.y - side.current.y
        if abs(dy) > 1 {
            my = (dy < 0 ? -1 : 1) * min(speed, abs(dy))
            side.current.y += my
        } else {
            side.current.y = side.target.y
        }

        let moveLen = sqrt(mx * mx + my * my)
        if moveLen > 0 {
            side.movementDirectionX = mx / moveLen
            side.movementDirectionY = my / moveLen
        }

        let dz = side.target.z - side.current.z
        if abs(dz) > 1 {
            side.current.z += (dz < 0 ? -1 : 1) * min(speed * 0.5, abs(dz))
        } else {
            side.current.z = side.target.z
        }

        // Only count as moved if it is visually significant, so sub-pixel target smoothing does
        // not leave the legs running on the spot.
        let charMoved = abs(side.current.x - prevX) > 0.5 || abs(side.current.y - prevY) > 0.5

        if charMoved {
            side.legTimer += speed * 0.1
            var targetRot = atan2(side.current.y - prevY, side.current.x - prevX) * 180 / .pi
            if targetRot < 0 { targetRot += 360 }

            if introPhase == .playing {
                // Never turn your back on the net.
                if isPlayer && targetRot > 0 && targetRot < 180 {
                    targetRot = 270
                } else if !isPlayer && targetRot > 180 && targetRot < 360 {
                    targetRot = 90
                }
            }

            side.target.rotation = targetRot
        } else if side.legTimer > 0 {
            // Finish the stride rather than snapping mid-step.
            let phase = side.legTimer.truncatingRemainder(dividingBy: .pi)
            if phase > 0.1 && phase < .pi - 0.1 {
                side.legTimer += speed * 0.1
            } else {
                side.legTimer = 0
            }
        }

        let diffRot = side.target.rotation - side.current.rotation
        side.current.rotation += ((diffRot + 540).truncatingRemainder(dividingBy: 360) - 180) * 0.1

        let target = side.racketTarget
        side.racket.pitch += (target.pitch - side.racket.pitch) * 0.1
        side.racket.roll += (target.roll - side.racket.roll) * 0.1
        side.racket.armX += (target.armX - side.racket.armX) * 0.2
        side.racket.armY += (target.armY - side.racket.armY) * 0.2

        let dYaw = target.yaw - side.racket.yaw
        side.racket.yaw += ((dYaw + .pi * 3).truncatingRemainder(dividingBy: .pi * 2) - .pi) * 0.1

        return charMoved
    }

    private func resetRacketToNeutral(_ side: Side) {
        side.racketTarget.armX = Self.restingArmX
        side.racketTarget.armY = Self.restingArmY
        side.racketTarget.pitch = 0
        side.racketTarget.yaw = .pi * 0.25
        side.racketTarget.roll = Self.restingRacketRoll
    }

    /// `processCharacter` (`tennis.js:1240-1346`) — bounds, leaps, aim, then convergence.
    @discardableResult
    private func processCharacter(_ side: Side, isPlayer: Bool, dt: Double) -> Bool {
        side.target.x = min(max(side.target.x, -Self.playableHalfWidth), Self.playableHalfWidth)
        if isPlayer {
            side.target.y = min(max(side.target.y, Self.netY + 10),
                                Self.playerBaseY + Self.playableOvershootY - 10)
        } else {
            side.target.y = min(max(side.target.y, Self.npcBaseY - Self.playableOvershootY + 10),
                                Self.netY - 10)
        }

        let now = EventInterpreter.nowMilliseconds()
        let distanceXY = distanceToBallXY(side)

        if canCharacterHit(isPlayer: isPlayer),
           let intercept = side.lastIntercept, intercept.t >= 0, distanceXY < 100 {

            /// True while the racket is still in front of the oncoming ball — once it is more
            /// than 10 units behind, the swing has been missed and the character tracks the
            /// prediction instead of the ball itself.
            func isRacketInRange(racketX: Double, racketY: Double) -> Bool {
                let speed = sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
                if speed == 0 { return true }
                let nx = ball.vx / speed
                let ny = ball.vy / speed
                let dot = (racketX - ball.x) * nx + (racketY - ball.y) * ny
                return dot <= 10
            }

            let rotation = side.current.rotation * .pi / 180
            let armWorldX = side.racketTarget.armX * cos(rotation)
                - side.racketTarget.armY * sin(rotation)
            let armWorldY = side.racketTarget.armX * sin(rotation)
                + side.racketTarget.armY * cos(rotation)
            let racketWorldX = side.current.x + armWorldX
            let racketWorldY = side.current.y + armWorldY
            let inRange = isRacketInRange(racketX: racketWorldX, racketY: racketWorldY)

            var reach = inRange
                ? armReach(for: side, towards: ball.x, ball.y, ball.z)
                : armReach(for: side, towards: intercept.x, intercept.y, intercept.z)
            reach.z = min(max(reach.z, Self.minCrouch), Self.maxJump)

            let lastZChange = now - side.lastZChangeTime
            if lastZChange > 150 {
                if intercept.t < 0.3 && (now - side.lastJumpTime > 500)
                    && side.current.z <= Self.jumpZ {
                    side.lastJumpTime = now
                    side.target.z = reach.z      // Jump — only from the ground.
                    side.lastZChangeTime = now
                } else if intercept.t < 0.25 && (now - side.lastJumpTime > 500)
                            && reach.z < Self.restingZ {
                    side.target.z = reach.z      // Crouch.
                    side.lastZChangeTime = now
                } else if reach.z >= Self.restingZ && reach.z < Self.jumpZ {
                    side.target.z = reach.z
                    side.lastZChangeTime = now
                } else {
                    side.target.z = Self.restingZ
                    side.lastZChangeTime = now
                }
            }

            side.racketTarget.armX = reach.x
            side.racketTarget.armY = reach.y

            let flat = returnBallHitTarget(isPlayer: isPlayer, racket: side.racket)
            let target = (x: flat.x, y: flat.y, z: Self.netHeight * Self.gameScale + 5)
            side.lastHitTarget = target

            let aim = inRange
                ? racketReturnAim(from: ball.vx, ball.vy, ball.vz,
                                  at: ball.x, ball.y, ball.z,
                                  side: side, target: target)
                : racketReturnAim(from: intercept.vx, intercept.vy, intercept.vz,
                                  at: intercept.x, intercept.y, intercept.z,
                                  side: side, target: target)

            side.racketTarget.pitch = aim.pitch
            side.racketTarget.yaw = aim.yaw
            side.racketTarget.roll = aim.roll
        } else {
            side.target.z = Self.restingZ
            resetRacketToNeutral(side)
        }

        return convergePhysics(side, dt: dt, isPlayer: isPlayer)
    }

    /// `handleIntroSequence` (`tennis.js:1078-1133`) — walk to the net, shake hands, walk back,
    /// then serve.
    private func handleIntroSequence(dt: Double) {
        switch introPhase {
        case .walkToNet:
            let pMoving = moveCharacter(player, toX: 0, toY: Self.netY + 25)
            let nMoving = moveCharacter(npc, toX: 0, toY: Self.netY - 25)

            convergePhysics(player, dt: dt, isPlayer: true, speedMult: 0.5)
            convergePhysics(npc, dt: dt, isPlayer: false, speedMult: 0.5)

            // Override whatever the convergence decided; they face each other.
            player.target.rotation = 270
            npc.target.rotation = 90

            if !pMoving && !nMoving {
                introPhase = .shakeHands
                introTimer = 2.0
                player.legTimer = 0
                npc.legTimer = 0
            }

        case .shakeHands:
            introTimer -= dt
            player.current.rotation = 270 + sin(introTimer * 20) * 10
            npc.current.rotation = 90 - sin(introTimer * 20) * 10
            if introTimer <= 0 { introPhase = .walkToBaseline }

        case .walkToBaseline:
            let serveOffset = Self.courtWidth * 0.4
            let targetPX = nextServerIsPlayer ? serveSide * serveOffset : serveSide * -serveOffset
            let targetNX = nextServerIsPlayer ? serveSide * -serveOffset : serveSide * serveOffset

            let pFar = moveCharacter(player, toX: targetPX, toY: Self.playerBaseY)
            let nFar = moveCharacter(npc, toX: targetNX, toY: Self.npcBaseY)

            convergePhysics(player, dt: dt, isPlayer: true, speedMult: 0.6)
            convergePhysics(npc, dt: dt, isPlayer: false, speedMult: 0.6)

            if !pFar { player.target.rotation = 270 }
            if !nFar { npc.target.rotation = 90 }

            let finishedRotating = player.current.rotation.rounded() == player.target.rotation.rounded()
                && npc.current.rotation.rounded() == npc.target.rotation.rounded()

            if !pFar && !nFar && finishedRotating {
                player.legTimer = 0
                npc.legTimer = 0
                introPhase = .playing
                serveBall(nextServerIsPlayer ? player : npc)
            }

        case .playing:
            break
        }
    }
}
