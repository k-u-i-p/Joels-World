import Foundation
import simd

/// The ball: what it does in the air, what it does when it lands, and the two ways it is put
/// into play.
///
/// The flight is integrated at a fixed 240 Hz with gravity, quadratic drag and a Magnus term
/// for topspin. That is more physics than a school game needs, and it is worth it for one
/// reason: **it makes the shot solver honest**. Aiming is not "pick a target and teleport the
/// ball along a parabola" — it is "pick a launch velocity, simulate it, see where it actually
/// lands, adjust". So a ball hit too flat clips the net, a ball hit too hard sails long, and
/// neither outcome had to be special-cased.
extension Tennis3DGame {

    /// The ball's whole state. World space, Y-down, Z up from the court surface.
    struct Ball {
        var x: Double = 0
        var y: Double = 0
        var z: Double = -100

        var vx: Double = 0
        var vy: Double = 0
        var vz: Double = 0

        /// 0 is flat, 1 is as much topspin as anyone here hits. Slice is negative.
        var topspin: Double = 0

        /// Bounces since the last time a racket touched it. Two ends the point.
        var bounces = 0
        /// Who hit it last. Nil before the first serve of the match.
        var lastHitByPlayer: Bool?
        /// Did it clip the net cord on the way over? A serve that does is a let.
        var clippedNet = false

        /// True while it is subject to gravity. False when it is in a hand before a serve.
        var inFlight = false
        /// True while it sits in the server's hand, so it can be drawn following them around.
        var heldByServer = false

        var speed: Double { (vx * vx + vy * vy + vz * vz).squareRoot() }
        var horizontalSpeed: Double { (vx * vx + vy * vy).squareRoot() }
        var position: SIMD3<Double> { SIMD3(x, y, z) }

        /// Out of sight under the court, which is where it lives between matches.
        mutating func parkOffCourt() {
            self = Ball()
        }
    }

    // MARK: - Flight

    /// One physics sub-step.
    func advanceBall(dt: Double) {
        guard ball.inFlight else {
            if ball.heldByServer { holdBallInServersHand() }
            return
        }

        let previous = ball.position

        // --- Integrate ---
        let speed = ball.speed
        let horizontal = ball.horizontalSpeed
        let dragFactor = Tuning.drag * speed

        let ax = -dragFactor * ball.vx
        let ay = -dragFactor * ball.vy
        var az = -Tuning.gravity - dragFactor * ball.vz

        // Topspin drives the ball down, slice holds it up. Perpendicular to travel in the
        // vertical plane, simplified to a straight vertical term — the horizontal component of
        // Magnus on a pure topspin ball is zero anyway.
        az -= Tuning.magnus * ball.topspin * horizontal

        ball.vx += ax * dt
        ball.vy += ay * dt
        ball.vz += az * dt

        ball.x += ball.vx * dt
        ball.y += ball.vy * dt
        ball.z += ball.vz * dt

        // Spin bleeds off in the air.
        ball.topspin *= (1 - 0.35 * dt)

        // --- The net ---
        // Tested as a crossing of the y = 0 plane rather than as a proximity check, so a ball
        // travelling 500 units a second cannot step straight through it.
        if (previous.y < 0) != (ball.y < 0) {
            let travel = ball.y - previous.y
            let fraction = travel == 0 ? 0 : (0 - previous.y) / travel
            let crossingX = previous.x + (ball.x - previous.x) * fraction
            let crossingZ = previous.z + (ball.z - previous.z) * fraction

            if abs(crossingX) <= Tennis3DCourt.netPostOffset,
               crossingZ <= Tennis3DCourt.netHeight(atX: crossingX) + Tennis3DCourt.ballRadius {
                hitTheNet(atX: crossingX, z: crossingZ)
                return
            }
        }

        // --- The ground ---
        if ball.z <= Tennis3DCourt.ballRadius && ball.vz < 0 {
            bounce()
        }

        // --- Gone ---
        // Far enough past the fence that nothing is going to bring it back.
        let strayed = abs(ball.x) > Tennis3DCourt.surfaceHalfWidth * 1.6
            || abs(ball.y) > Tennis3DCourt.surfaceHalfLength * 1.6
        if strayed && phase == .rally {
            resolveDeadBall()
        }
    }

    private func hitTheNet(atX x: Double, z: Double) {
        ball.x = x
        ball.y = ball.vy > 0 ? Tennis3DCourt.metres(0.12) : -Tennis3DCourt.metres(0.12)
        ball.z = max(Tennis3DCourt.ballRadius, z)
        // A net cord kills almost all the pace and dumps the ball on whichever side it was
        // going; a lucky one trickles over.
        ball.vy *= -0.22
        ball.vx *= 0.25
        ball.vz = abs(ball.vz) * 0.30
        ball.topspin = 0
        ball.clippedNet = true

        host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: 0.35, rate: 0.7)
    }

    private func bounce() {
        ball.z = Tennis3DCourt.ballRadius
        ball.vz = -ball.vz * Tuning.bounceRestitution

        // Friction takes pace off along the ground, and topspin gives some of it back — which
        // is why a heavy topspin ball kicks forward off the bounce.
        let kick = 1 + max(0, ball.topspin) * 0.22
        ball.vx *= Tuning.bounceFriction * kick
        ball.vy *= Tuning.bounceFriction * kick
        ball.topspin *= 0.45

        ball.bounces += 1
        onBounce()
    }

    /// Keeps the ball in the server's off hand until the toss.
    private func holdBallInServersHand() {
        let hand = worldPoint(local: SIMD3(6, -13, 24), of: server)
        ball.x = hand.x
        ball.y = hand.y
        ball.z = hand.z
    }

    // MARK: - Serving

    /// The server takes the ball; a beat later they toss it.
    func beginServe() {
        ball = Ball()
        ball.heldByServer = true
        ball.inFlight = false
        ball.lastHitByPlayer = serverIsPlayer
        holdBallInServersHand()

        player.swing = SwingState()
        npc.swing = SwingState()

        phase = .ready
        phaseTimer = 0.85
        onPresentationChanged?()
    }

    /// Up it goes — aimed at the exact point in the air where the racket is going to be.
    ///
    /// Every other shot in the game is a chase: the ball is going somewhere and a player has to
    /// get there. A serve is the opposite — the server is standing still and *chose* where to
    /// put the ball — so rather than tossing it vaguely upward and hoping the swing finds it,
    /// the toss is solved backwards from the contact point. `serveStrikeTime` then says exactly
    /// when to start the backswing.
    ///
    /// It looks like a toss and it always connects, which for a ten-year-old's serve is the
    /// right trade: the interesting decisions in this game are on the return, not the ball
    /// toss.
    func tossBall() {
        let hand = worldPoint(local: SIMD3(6, -13, 24), of: server)
        let contact = serveContactPoint(for: server)

        // How long the ball hangs before the strings arrive. Long enough to read as a toss.
        let hang = 0.85

        ball.heldByServer = false
        ball.inFlight = true
        ball.bounces = 0
        ball.clippedNet = false
        ball.topspin = 0
        ball.x = hand.x
        ball.y = hand.y
        ball.z = hand.z

        // Solved so the ball is at the contact point, on the way down, at t = `hang`. Drag on a
        // ball moving this slowly is a rounding error, so the closed form is exact enough.
        ball.vz = (contact.z - hand.z + 0.5 * Tuning.gravity * hang * hang) / hang
        ball.vx = (contact.x - hand.x) / hang
        ball.vy = (contact.y - hand.y) / hang

        tossElapsed = 0
        serveStrikeTime = hang
        phase = .toss
        server.swing = SwingState()
    }

    /// Where the racket head will be at the moment of contact on a serve, given where the
    /// server is standing right now. The mirror of `handLocal`'s serve contact pose.
    func serveContactPoint(for side: Side) -> SIMD3<Double> {
        racketHead(of: side, handOverride: serveContactHandLocal)
    }

    // MARK: - Striking

    /// Sends the ball from wherever it is towards `target`, at `speed`, with `topspin`.
    ///
    /// The launch is solved by simulation rather than by a closed form: drag and Magnus make
    /// the closed form wrong by several metres over the length of a court, and being wrong in a
    /// *consistent* direction would mean every shot from the baseline lands short. Three
    /// refinement passes get it inside a few centimetres, which is well under the error the
    /// aiming deliberately adds on top.
    func launchBall(to target: (x: Double, y: Double), speed: Double, topspin: Double) {
        let start = ball.position
        var dx = target.x - start.x
        var dy = target.y - start.y
        var range = (dx * dx + dy * dy).squareRoot()
        if range < 1 {
            // Aiming at your own feet: push the target away rather than dividing by nothing.
            dy = ball.lastHitByPlayer == true ? -1 : 1
            dx = 0
            range = 1
        }
        let directionX = dx / range
        let directionY = dy / range

        let cappedSpeed = min(speed, Tuning.maxBallSpeed)

        // First guess: the drag-free arc that reaches the target in the time the speed implies.
        let flightTime = range / max(cappedSpeed * 0.88, 1)
        var horizontalSpeed = range / flightTime
        var verticalSpeed = (0.5 * Tuning.gravity * flightTime * flightTime - start.z) / flightTime

        // Two independent knobs, adjusted alternately until both are satisfied: the launch
        // angle has to clear the cord, and the pace has to carry the right distance. Raising
        // one moves the other, so it takes a few passes — but each is a straight ratio, and
        // four are always plenty.
        let netMargin = Tennis3DCourt.metres(0.18)
        for _ in 0..<4 {
            let trial = simulateFlight(from: start,
                                       vx: directionX * horizontalSpeed,
                                       vy: directionY * horizontalSpeed,
                                       vz: verticalSpeed,
                                       topspin: topspin)
            var adjusted = false

            if let clearance = trial.netClearance, clearance < netMargin {
                verticalSpeed += (netMargin - clearance) / max(trial.timeToNet, 0.05)
                adjusted = true
            }
            if trial.range > 1 {
                let ratio = range / trial.range
                if abs(ratio - 1) > 0.01 {
                    horizontalSpeed *= ratio
                    adjusted = true
                }
            }
            if !adjusted { break }
        }

        // Whatever the solver decided, nothing leaves a racket faster than a serve.
        let launchSpeed = (horizontalSpeed * horizontalSpeed
                           + verticalSpeed * verticalSpeed).squareRoot()
        if launchSpeed > Tuning.maxBallSpeed {
            let scale = Tuning.maxBallSpeed / launchSpeed
            horizontalSpeed *= scale
            verticalSpeed *= scale
        }

        ball.vx = directionX * horizontalSpeed
        ball.vy = directionY * horizontalSpeed
        ball.vz = verticalSpeed
        ball.topspin = topspin
        ball.inFlight = true
        ball.heldByServer = false
        ball.bounces = 0
        ball.clippedNet = false
    }

    /// Runs a copy of the ball forward until it lands, without touching the live one.
    ///
    /// - Returns: how far it travelled horizontally, where it landed, and how far it cleared the
    ///   net by (nil if it never reached the net).
    func simulateFlight(from start: SIMD3<Double>,
                        vx: Double, vy: Double, vz: Double,
                        topspin: Double,
                        maxTime: Double = 4.0)
        -> (range: Double, landing: SIMD2<Double>, netClearance: Double?, timeToNet: Double,
            flightTime: Double) {
        var position = start
        var velocity = SIMD3(vx, vy, vz)
        var spin = topspin
        var elapsed: Double = 0
        var netClearance: Double?
        var timeToNet: Double = 0

        // A coarser step than the live simulation: this runs several times per stroke and the
        // answer only has to be good to a few centimetres.
        let step = Tuning.physicsStep * 4

        while elapsed < maxTime {
            let previousX = position.x
            let previousY = position.y
            let previousZ = position.z

            let speed = simd_length(velocity)
            let horizontal = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            let dragFactor = Tuning.drag * speed

            velocity.x += -dragFactor * velocity.x * step
            velocity.y += -dragFactor * velocity.y * step
            velocity.z += (-Tuning.gravity - dragFactor * velocity.z
                           - Tuning.magnus * spin * horizontal) * step
            position += velocity * step
            spin *= (1 - 0.35 * step)
            elapsed += step

            if netClearance == nil, (previousY < 0) != (position.y < 0) {
                let travel = position.y - previousY
                let fraction = travel == 0 ? 0 : (0 - previousY) / travel
                let crossingX = previousX + (position.x - previousX) * fraction
                let crossingZ = previousZ + (position.z - previousZ) * fraction
                netClearance = crossingZ - Tennis3DCourt.netHeight(atX: crossingX)
                timeToNet = elapsed
            }

            if position.z <= Tennis3DCourt.ballRadius && velocity.z < 0 { break }
        }

        let landing = SIMD2(position.x, position.y)
        let range = simd_length(landing - SIMD2(start.x, start.y))
        return (range, landing, netClearance, timeToNet, elapsed)
    }

    /// The point in the air where the player's racket ought to meet the ball.
    ///
    /// The 2D game drew a green X here and it was the single most useful thing on the screen —
    /// it turned "somewhere over there" into "stand *here*". This is the same idea, computed
    /// properly: the ball is run forward through the real integrator, and the first moment it
    /// is on the player's side of the net, past any bounce it still owes, and at a height a
    /// racket can actually reach, is the answer.
    ///
    /// Nil when there is nothing to hit — the opponent's ball to play, or a shot already gone.
    func idealIntercept() -> SIMD3<Double>? {
        guard ball.inFlight, canHit(player) else { return nil }

        var position = ball.position
        var velocity = SIMD3(ball.vx, ball.vy, ball.vz)
        var spin = ball.topspin
        var bounces = ball.bounces
        var elapsed: Double = 0

        let step = Tuning.physicsStep * 4
        // The band a stroke is comfortable in: knee height to a little above the shoulder.
        let lowest = Tennis3DCourt.metres(0.45)
        let highest = Tennis3DCourt.metres(1.75)

        while elapsed < 2.5 {
            let speed = simd_length(velocity)
            let horizontal = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            let dragFactor = Tuning.drag * speed

            velocity.x += -dragFactor * velocity.x * step
            velocity.y += -dragFactor * velocity.y * step
            velocity.z += (-Tuning.gravity - dragFactor * velocity.z
                           - Tuning.magnus * spin * horizontal) * step
            position += velocity * step
            spin *= (1 - 0.35 * step)
            elapsed += step

            if position.z <= Tennis3DCourt.ballRadius && velocity.z < 0 {
                position.z = Tennis3DCourt.ballRadius
                velocity.z = -velocity.z * Tuning.bounceRestitution
                velocity.x *= Tuning.bounceFriction
                velocity.y *= Tuning.bounceFriction
                bounces += 1
                if bounces >= 2 { return nil }
            }

            // Not playable until it is over the net, and — off a serve — not until it has
            // bounced in the box.
            guard position.y > Tennis3DCourt.metres(0.4) else { continue }
            if isServeInFlight && bounces == 0 { continue }
            // Prefer the ball on its way down, which is where a groundstroke is struck.
            guard velocity.z < 0 || bounces > 0 else { continue }
            guard position.z >= lowest, position.z <= highest else { continue }

            return position
        }

        return nil
    }

    /// Where the live ball is going to land, for the opponent's brain and the aim marker.
    /// Cheap enough to call every frame.
    func predictedLanding() -> (point: SIMD2<Double>, time: Double)? {
        guard ball.inFlight else { return nil }
        let result = simulateFlight(from: ball.position,
                                    vx: ball.vx, vy: ball.vy, vz: ball.vz,
                                    topspin: ball.topspin)
        return (result.landing, result.flightTime)
    }

    // MARK: - Scene

    /// The ball itself, its shadow, and — while the ball is coming towards the player — a ring
    /// on the court showing where it is going to land.
    ///
    /// The 2D game drew a crosshair at the predicted *intercept*, which told the player where
    /// their racket would meet the ball. This shows where the ball will **land** instead, which
    /// is the thing a player actually has to run to.
    func ballPrimitives() -> [ScenePrimitive] {
        guard ball.z > -50 else { return [] }
        var out: [ScenePrimitive] = []

        out.append(ScenePrimitive(
            shape: .sphere(radius: Float(Tennis3DCourt.ballDrawRadius)),
            transform: Float4x4.translation(SIMD3(Float(ball.x), Float(-ball.y), Float(ball.z))),
            color: Tennis3DCourt.ballColor,
            roughness: 0.85))

        // A shadow that shrinks and fades with height, which is the only cue a top-down camera
        // gives for how high the ball is.
        let height = max(0, ball.z)
        let shadowSize = Float(Tennis3DCourt.metres(0.34)
                               / (1 + height / Tennis3DCourt.metres(3.0)))
        out.append(ScenePrimitive(
            shape: .plane(width: shadowSize, height: shadowSize),
            transform: Float4x4.translation(SIMD3(Float(ball.x), Float(-ball.y), 1.6)),
            color: SIMD3(0, 0, 0),
            opacity: Float(0.45 / (1 + height / Tennis3DCourt.metres(2.2))),
            unlit: true,
            castsShadow: false))

        // The landing ring, only while the ball is on its way to the player and only once it
        // is over the net — before that it is noise.
        if phase == .rally || phase == .toss,
           ball.inFlight,
           ball.vy > 0,
           let prediction = predictedLanding(),
           prediction.point.y > 0 {
            let ring = Float(Tennis3DCourt.metres(0.9))
            out.append(ScenePrimitive(
                shape: .plane(width: ring, height: ring),
                transform: Float4x4.translation(SIMD3(Float(prediction.point.x),
                                                      Float(-prediction.point.y), 1.8)),
                color: parseHexColor("#2ecc71"),
                opacity: 0.42,
                unlit: true,
                castsShadow: false))
        }

        out.append(contentsOf: interceptMarker())
        return out
    }

    /// The green X, straight out of the 2D game — where the racket should meet the ball.
    ///
    /// Drawn twice: once floating at the intercept itself, and once as a fainter copy flat on
    /// the court directly beneath it. The floating one is the honest answer; the one on the
    /// ground is the one a player can actually run to, because from a camera this high a mark
    /// in mid-air is impossible to judge the position of.
    private func interceptMarker() -> [ScenePrimitive] {
        guard let intercept = idealIntercept() else { return [] }

        let arm = Float(Tennis3DCourt.metres(0.42))
        let thickness = Float(Tennis3DCourt.metres(0.07))
        let green = parseHexColor("#2ecc71")
        var out: [ScenePrimitive] = []

        func cross(atZ z: Float, opacity: Float, scale: Float) {
            for sign in [Float(1), Float(-1)] {
                out.append(ScenePrimitive(
                    shape: .box(width: arm * 2 * scale, height: thickness, depth: thickness),
                    transform: Float4x4.translation(SIMD3(Float(intercept.x),
                                                          Float(-intercept.y), z))
                        * Float4x4.rotationZ(sign * .pi / 4),
                    color: green,
                    opacity: opacity,
                    unlit: true,
                    castsShadow: false))
            }
        }

        cross(atZ: Float(intercept.z), opacity: 0.95, scale: 1)
        cross(atZ: 2.0, opacity: 0.35, scale: 0.85)
        return out
    }
}
