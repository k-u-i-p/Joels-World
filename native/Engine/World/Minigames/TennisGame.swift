import CoreGraphics
import Foundation

/// Port of `client/public/src/minigames/tennis.js` — the simulation half.
///
/// The rendering half is `TennisView`, and the two are coupled the same way the JS couples
/// them: **the racket hitbox is a by-product of drawing it.** `drawRacket` extracts the racket
/// head's position out of the canvas transform (`tennis.js:1641-1656`) and writes it back onto
/// `racketCurrentPosition`, which the *next* frame's `processRacketDeflections` tests the ball
/// against. That one-frame lag is load-bearing — the aim converges towards its target 10% a
/// frame, so testing against the drawn racket rather than the intended one is what makes a
/// mistimed swing miss. `TennisView.draw` writes `racket[.player/.npc]` for the same reason.
///
/// The simulation is four files: this one holds the state and drives the frame, `TennisCourt`
/// the dimensions and the state vocabulary, `TennisGame+Ball` the ball and the serve, and
/// `TennisGame+Movement` the two characters' locomotion. Because Swift's `private` does not
/// reach across files, the state below is internal rather than `private(set)`. **Only these
/// four files write it** — `TennisView` and the debug harness read it and nothing more.
final class TennisGame: Minigame {
    let player = Side()
    let npc = Side()
    var ball = Ball()

    var bounceCount = 0
    var resetting = false
    var resetDelayTimer: Double = 0
    var rallyCount = 0
    var introPhase: IntroPhase = .walkToNet
    var introTimer: Double = 0
    var nextServerIsPlayer = false
    var lastHitter: Hitter?
    var isServe: ServeState = .inPlay
    var servePhase: ServePhase = .idle
    var faults = 0
    var serveSide: Double = -1
    var activeServiceBox: ServiceBox?

    /// The `setTimeout`s `serveBall` and `throwBall` schedule, as wall-clock deadlines so a
    /// stalled frame does not stretch the serve the way an accumulated `dt` would.
    var throwDeadline: TimeInterval?
    var apexDeadline: TimeInterval?

    /// The opponent's appearance, taken from the map's first NPC.
    private(set) var opponent: GameCharacter
    /// The local player's appearance, for the 2D drawing code.
    private(set) var myCharacter: GameCharacter?

    unowned let host: MinigameHost
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
        resetting = false
        resetDelayTimer = 0

        // A cinematic walk-on from behind the baselines, rather than serving straight away.
        let serveX = servePositionX
        player.current.x = serveX.player
        player.current.y = Self.playerBaseY + 30
        player.current.z = 0
        npc.current.x = serveX.npc
        npc.current.y = Self.npcBaseY - 30
        npc.current.z = 0
        player.target = Position(x: serveX.player, y: Self.playerBaseY, z: 0, rotation: 270)
        npc.target = Position(x: serveX.npc, y: Self.npcBaseY, z: 0, rotation: 90)
        introPhase = .walkToNet
        introTimer = 0

        // Out of sight under the court until the first serve puts it in a hand.
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

    /// Where the two of them stand for a serve, whoever is serving: `serveBall` puts the
    /// service box diagonally opposite the `serveSide` corner, so the server takes that corner
    /// and the receiver waits in the box's own half.
    ///
    /// The intro walk-on and the between-points reset both come here. They used to work it out
    /// separately and disagree — the intro mirrored the pair whenever the NPC was serving,
    /// which started every match with the serve down the line and the receiver on the far side.
    var servePositionX: (player: Double, npc: Double) {
        let offset = serveSide * Self.courtWidth * 0.4
        return (player: offset, npc: -offset)
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

        // How near the crosshair a tap has to land to mean "swing at that" rather than
        // "run to exactly here".
        let swingRadius: Double = 40

        var target = Intercept(x: worldX, y: worldY, z: Self.restingZ, t: 0, vx: 0, vy: 0, vz: 0)
        if let intercept = player.lastIntercept,
           hypot(worldX - intercept.x, worldY - intercept.y) < swingRadius {
            target = intercept
        }

        let optimal = optimalInterceptPosition(for: player, intercept: target)
        moveCharacter(player, toX: optimal.x, toY: optimal.y)
    }

    // MARK: - Frame

    /// `run(dt)` (`tennis.js:1353-1561`), up to the point where the JS starts rendering.
    ///
    /// Tapping is the whole control scheme. The web build's other movement source is the arrow
    /// keys, which no touch device has, and it hides the joystick on the way in
    /// (`tennis.js:675-676`).
    func update(dt: Double) {
        guard active else { return }
        fireDueTimers()

        if introPhase != .playing {
            handleIntroSequence(dt: dt)
            return
        }

        // Between points, both of them walk back to their serve marks.
        if resetting {
            let serveX = servePositionX
            moveCharacter(player, toX: serveX.player, toY: Self.playerBaseY)
            moveCharacter(npc, toX: serveX.npc, toY: Self.npcBaseY)
        }

        processBallMovement(dt: dt)

        let playerMoved = processCharacter(player, isPlayer: true, dt: dt)
        if !playerMoved { player.target.rotation = 270 }

        // The NPC only repositions while it is legally allowed to play the ball.
        if canCharacterHit(isPlayer: false) { moveToIntercept(npc) }

        let npcMoved = processCharacter(npc, isPlayer: false, dt: dt)
        if !npcMoved { npc.target.rotation = 90 }

        // Both back on their marks: count the delay down, then serve.
        if resetting && !playerMoved && !npcMoved {
            if resetDelayTimer > 0 {
                resetDelayTimer -= dt
            } else {
                serveBall(nextServerIsPlayer ? player : npc)
            }
        }

        // Racket contact is resolved before the floor can end the rally, so a shot scooped off
        // the deck on the same frame it lands still counts.
        processRacketDeflections(visualBallY: ball.y - ball.z)
        processBallLeavingCourt()
    }

    /// The ball has left the playing area entirely, which ends the point one way or the other
    /// depending on whether it ever landed in.
    private func processBallLeavingCourt() {
        guard !resetting else { return }

        let margin: Double = 150
        let outX = abs(ball.x) > Self.playableHalfWidth + margin
        let outY = ball.y < Self.courtY - margin
            || ball.y > Self.courtY + Self.courtHeight + margin
        guard outX || outY else { return }

        switch bounceCount {
        case 0 where isServe != .inPlay:
            triggerFault(playerServing: lastHitter == .player)
        case 0:
            // Struck straight out, without ever landing.
            triggerPointReset(nextPlayerServing: lastHitter == .player)
        case 1:
            // Bounced in, then left the court — a winner for whoever hit it.
            triggerPointReset(nextPlayerServing: lastHitter == .npc)
        default:
            break    // A second bounce has already ended the point.
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

    /// `canCharacterHit` (`tennis.js:115-164`). The JS is thirteen overlapping `return false`
    /// clauses, two of them unreachable; this is the same truth table stated once. The two
    /// forms were checked to agree on all 6912 combinations of the state they read.
    func canCharacterHit(isPlayer: Bool) -> Bool {
        guard !resetting, introPhase == .playing, servePhase != .idle else { return false }

        if isServe == .inPlay {
            // Whoever hit last has to let the other one play it.
            return (lastHitter == .player) != isPlayer
        }
        if isServe == (isPlayer ? .npcServe : .playerServe) {
            // Receiving: a serve is only returnable once it has bounced, and not before the
            // toss reaches its apex.
            return servePhase == .live && bounceCount > 0
        }
        // Serving: one swing at your own toss, before it lands.
        return servePhase == .justThrown || (bounceCount == 0 && rallyCount == 0)
    }

    func distanceToBallXY(_ side: Side) -> Double {
        hypot(ball.x - side.current.x, ball.y - side.current.y)
    }

    // MARK: - Aiming

    /// `calculateArmReach` (`tennis.js:192-231`).
    func armReach(for side: Side, towards x: Double, _ y: Double, _ z: Double)
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
    func racketReturnAim(from incomingX: Double, _ incomingY: Double, _ incomingZ: Double,
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
    func optimalInterceptPoint(for side: Side) -> Intercept {
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
                // Stop at the bounce that would end the point: one more from a ball still in
                // the air, none at all from one that has already bounced.
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

    func setNewInterceptPoints() {
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

}
