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
        // Measured off the **playable** rectangle, not the drawn apron: the apron is deliberately
        // eleven metres bigger than anyone can walk so its edge stays out of frame, and hanging
        // the dead-ball test off it would let a shot fly for another second and a half before
        // anybody called it.
        let strayed = abs(ball.x) > Tennis3DCourt.playableHalfWidth + Tennis3DCourt.metres(5)
            || abs(ball.y) > Tennis3DCourt.playableHalfLength + Tennis3DCourt.metres(10)
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
        timeSinceBallEvent = 0

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
        timeSinceBallEvent = 0
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
        // Both anchors reset to the marks: the receiver measures the return from where they are
        // standing to take it, and the server from where they serve.
        player.anchor = (x: player.motor.x, y: player.motor.y)
        npc.anchor = (x: npc.motor.x, y: npc.motor.y)
        // A second serve is the same point, but the rally starts again from the serve.
        rallyShots = 0

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
        timeSinceBallEvent = 0
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
    /// `mishit` is how badly the ball was struck, 0 for a clean one. It is applied **after** the
    /// solver, so it is a genuine error rather than a different target — see `Tuning.mishitPace`.
    func launchBall(to target: (x: Double, y: Double), speed: Double, topspin: Double,
                    mishit: Double = 0) {
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

        // The mishit, in all three of the ways a shot can go wrong. Pace decides whether it lands
        // short or long, loft whether it clips the cord or floats past the baseline, and the
        // sideways swing of the racket face whether it goes wide.
        //
        // The third one is easy to leave out and the game is poorer without it: with only pace
        // and loft, `aimX` is honoured exactly on every ball ever struck, so aiming down the line
        // is free and no shot is ever wide. Every mistake looked like the same mistake.
        //
        // Signed and deterministic, like everything else here, so a given point still plays out
        // the same way every time it is replayed.
        var aimedX = directionX
        var aimedY = directionY
        if mishit > 0 {
            horizontalSpeed *= 1 + random.spread(Tuning.mishitPace * mishit)
            verticalSpeed *= 1 + random.spread(Tuning.mishitLoft * mishit)

            let swing = random.spread(Tuning.mishitFace * mishit)
            let cosine = cos(swing), sine = sin(swing)
            (aimedX, aimedY) = (directionX * cosine - directionY * sine,
                                directionX * sine + directionY * cosine)
        }

        ball.vx = aimedX * horizontalSpeed
        ball.vy = aimedY * horizontalSpeed
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
    func idealIntercept() -> SIMD3<Double>? { intercept(for: player) }

    /// The same question asked on either side of the net. The opponent's brain uses it too:
    /// standing a stride behind where the ball will *land* is wrong for a serve, which lands
    /// near the service line and then travels another ten metres.
    func intercept(for side: Side) -> SIMD3<Double>? {
        // `isTheirBall`, not `canHit`: the marker has to be up *before* the serve bounces,
        // because running to it is exactly what the receiver needs the extra half second for.
        // The loop below already refuses to return a point before the bounce.
        guard ball.inFlight, isTheirBall(side) else { return nil }

        var position = ball.position
        var velocity = SIMD3(ball.vx, ball.vy, ball.vz)
        var spin = ball.topspin
        var bounces = ball.bounces
        var elapsed: Double = 0

        let step = Tuning.physicsStep * 4
        // Every height the swing can be lifted to, which is the same band `timeUntilInReach`
        // fires in — see the note on `strikeBand`. `contactHeight` is still the *comfortable*
        // height, and the cost below still prefers it; it is no longer the only one.
        let contactHeight = contactHeadHeight
        let band = strikeBand(for: side)

        // The first playable moment is usually not the useful one, and pointing at it was
        // quietly losing every service game. A serve bounces near the service line and kicks
        // on past the baseline; the earliest instant it is at hitting height is a few metres
        // *in front of* a receiver who is standing behind their own baseline. The marker sent
        // them sprinting forward into a ball that was already going over their shoulder.
        //
        // So the walk below scores every playable moment by **how far the player has to move to
        // meet it**, and picks the cheapest one they can actually get to. That is what a tennis
        // player does: stand still and let the ball come, and move only as far as you have to.
        // Taking the earliest playable moment instead is a lunge at a ball that was about to
        // arrive anyway, which is how both sides were losing every return.
        //
        // If nothing is reachable, the closest near-miss comes back regardless, so the marker
        // still shows where the ball was catchable — a player who is out of position should see
        // by how much, not see nothing at all.
        // Cost is measured from the **anchor** — where they stood when the shot was struck — and
        // reachability from where they are now. Costing from the live position instead is the
        // feedback loop described on `Side.anchor`, and it walked both players into the net.
        let anchor = SIMD2(side.anchor.x, side.anchor.y)
        let here = SIMD2(side.motor.x, side.motor.y)
        let reach = Tuning.racketLength + sweetRadius(for: side)
        let topSpeed = side.isPlayer ? Tuning.playerTopSpeed : Tuning.npcTopSpeed
        var best: (point: SIMD3<Double>, cost: Double)?
        var nearest: (point: SIMD3<Double>, shortfall: Double)?

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
                if bounces >= 2 { break }
            }

            // Not playable until it is over the net and on this side of it, and — off a serve —
            // not until it has bounced in the box.
            guard position.y * side.half > Tennis3DCourt.metres(0.4) else { continue }
            if isServeInFlight && side !== server && bounces == 0 { continue }
            // Prefer the ball on its way down, which is where a groundstroke is struck.
            guard velocity.z < 0 || bounces > 0 else { continue }
            guard position.z >= band.low, position.z <= band.high else { continue }

            let ground = SIMD2(position.x, position.y)
            // Cost is "how far do I have to move", plus a penalty for a ball that is not at the
            // height the racket swings through — a shin-high ball two steps away is a worse
            // proposition than a waist-high one three steps away, and the ground distance alone
            // cannot say so.
            //
            // The penalty was there to break ties, back when a ball more than half a metre off
            // height was not a shot at all. Now that the band runs from the ankles to over the
            // head it is the whole of "would you rather take this early and high, or move your
            // feet and meet it at the waist" — and since a stretched contact now costs real pace
            // (see `strike`), the answer should usually be the second one. Hence 1.3 rather than
            // the 1.5 it was: a metre off height is worth walking 1.3 m to avoid, and no further.
            let offHeight = abs(position.z - contactHeight)
            // **And a penalty for backing up behind your own baseline**, which is the difference
            // between a rally and a metronome.
            //
            // A topspin ball kicks on five or six metres past its bounce, and its path crosses
            // racket height twice: once on the way up, a couple of metres inside the baseline,
            // and again on the way down, a couple of metres behind it. Measured purely on
            // distance from the anchor, the second one is always the cheaper — so both players
            // drifted back until they were standing on the fence and the game had no front half
            // at all. Every ball was met at y = 13 to 14 m, which meant nobody was ever pulled
            // forward, which meant `planShot`'s attack on a short ball could never once fire.
            //
            // Take the ball early: it is what a coach says, it is what makes a short ball short,
            // and it is the cheapest possible way to give the court a front half back.
            //
            // 0.8 m of cost per metre behind the line. Measured: it moves the median contact
            // point from 14.0 m — flat against the back fence, which is where the whole game was
            // being played — to 8.5 m, a stride or two inside the baseline.
            //
            // 0.45 was tried, on the theory that 8.5 m is standing on the service line and a
            // rally should be played from the baseline. It moved the median all of half a metre
            // and doubled the mean rally to twenty shots, because the little that did change came
            // straight off `planShot`'s attack bonus. The lesson is that this number is not
            // really a positioning knob at all — it is the rally-length knob wearing a disguise,
            // and the honest positioning knob is how far the ball carries.
            let behindBaseline = max(0, abs(ground.y) - Tennis3DCourt.halfLength)
            let cost = max(0, simd_length(ground - anchor) - reach)
                + offHeight * 1.3
                + behindBaseline * 0.8
            let needed = max(0, simd_length(ground - here) - reach)
            let possible = groundCovered(in: elapsed, topSpeed: topSpeed)

            if needed <= possible {
                if best == nil || cost < best!.cost { best = (position, cost) }
            } else if nearest == nil || needed - possible < nearest!.shortfall {
                nearest = (position, needed - possible)
            }
        }

        return best?.point ?? nearest?.point
    }

    /// How far a player can travel from a standing start in `time`, accelerating at
    /// `Tuning.acceleration` up to `topSpeed`.
    ///
    /// The straight `topSpeed × time` this replaces was optimistic by about a metre over the
    /// length of a return — enough that a lunge the player could not actually make looked
    /// reachable, which is exactly the ball they then arrived at a stride too late for.
    private func groundCovered(in time: Double, topSpeed: Double) -> Double {
        let timeToTopSpeed = topSpeed / Tuning.acceleration
        if time <= timeToTopSpeed { return 0.5 * Tuning.acceleration * time * time }
        return 0.5 * topSpeed * timeToTopSpeed + topSpeed * (time - timeToTopSpeed)
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
        //
        // **The size is quantised, and it has to be.** `ScenePrimitiveRenderer` caches one GPU
        // mesh per distinct `Shape` and keeps it, on the assumption — true of a court — that a
        // scene resolves to a dozen or so. A shadow that shrinks smoothly is a *different* plane
        // every frame, so it minted a fresh pair of Metal buffers sixty times a second and never
        // freed one. Memory climbed until iOS killed the app mid-match, which is what was ending
        // every run about ten seconds in. Rounded to the centimetre it resolves to about thirty
        // sizes, and the stepping is invisible on a shadow this soft.
        let height = max(0, ball.z)
        let smooth = Tennis3DCourt.metres(0.34) / (1 + height / Tennis3DCourt.metres(3.0))
        let step = Tennis3DCourt.metres(0.01)
        let shadowSize = Float((smooth / step).rounded() * step)
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
        out.append(contentsOf: aimMarker())
        return out
    }

    /// **Where the player has asked the ball to go**, if they have asked. A yellow ring on
    /// Alex's half of the court.
    ///
    /// Deliberately not a cross: the green X already means "put your racket here", and a second
    /// cross meaning something completely different, on a screen a ten-year-old is reading at
    /// speed, is how you teach somebody that the markers are noise. A ring is a target.
    private func aimMarker() -> [ScenePrimitive] {
        guard let aim = playerAim, phase == .rally || phase == .toss else { return [] }

        let gold = parseHexColor("#f1c40f")
        let half = Float(Tennis3DCourt.metres(0.7))

        /// **Nothing may lie flat on Alex's half of the court.**
        ///
        /// The first two attempts at this marker were a flat gold square and then a square
        /// outline made of thin bars, both a couple of units above the surface, and *neither
        /// appeared on screen at all* — while a small post standing in the middle of them, from
        /// the same array, in the same blended pass, drew perfectly every frame.
        ///
        /// It is the depth buffer. The camera orbits at 1631 units with `Camera.far` at 2000, and
        /// the far baseline is right out at the end of that range, where a 32-bit depth value
        /// cannot separate two surfaces two units apart. Near the player the same trick is fine —
        /// the ball's shadow lies 1.6 units up and has never flickered — because precision at the
        /// bottom of the screen is a different world from precision at the top. Part 1 recorded
        /// "z-fighting between three ground planes 1.5 cm apart" as a solved mystery; this is the
        /// same mystery, and the rule that falls out of it is the sentence above.
        ///
        /// So the target is five little posts, four corners and a bullseye, and it reads better
        /// than the square would have: from a camera tipped 46° over, something standing up is
        /// something you can see.
        func post(_ dx: Float, _ dy: Float, height: Double, opacity: Float) -> ScenePrimitive {
            let thickness = Float(Tennis3DCourt.metres(0.11))
            let tall = Float(Tennis3DCourt.metres(height))
            return ScenePrimitive(
                shape: .box(width: thickness, height: thickness, depth: tall),
                transform: Float4x4.translation(SIMD3(Float(aim.x) + dx,
                                                      Float(-aim.y) + dy, tall / 2)),
                color: gold,
                opacity: opacity,
                unlit: true,
                castsShadow: false)
        }

        return [post(-half, -half, height: 0.5, opacity: 0.9),
                post(half, -half, height: 0.5, opacity: 0.9),
                post(-half, half, height: 0.5, opacity: 0.9),
                post(half, half, height: 0.5, opacity: 0.9),
                post(0, 0, height: 0.32, opacity: 0.7)]
    }

    /// The green X, straight out of the 2D game — where the racket should meet the ball.
    ///
    /// Drawn twice: once floating where the strings should meet the ball, and once flat on the
    /// court **where the feet should be**.
    ///
    /// Those two are not the same place, and drawing the second one under the first was a quiet
    /// lie the game told for as long as it existed. The racket head is more than a metre in
    /// front of and to the side of the body, so a player who runs to the mark under the ball has
    /// put their chest where their strings needed to be, and the ball goes past inside their
    /// reach. The ground mark now shows the stance, which is the thing you can actually stand
    /// on; the floating one still shows the ball.
    private func interceptMarker() -> [ScenePrimitive] {
        guard let intercept = idealIntercept() else { return [] }
        let feet = stance(toMeet: intercept, for: player)

        // The X is drawn the size of the sweet spot it stands for, so the Easy button visibly
        // makes the target bigger rather than only making it bigger in the maths.
        let arm = Float(sweetRadius(for: player))
        let thickness = Float(Tennis3DCourt.metres(0.07))
        let green = parseHexColor("#2ecc71")
        var out: [ScenePrimitive] = []

        func cross(x: Double, y: Double, atZ z: Float, opacity: Float, scale: Float) {
            for sign in [Float(1), Float(-1)] {
                out.append(ScenePrimitive(
                    shape: .box(width: arm * 2 * scale, height: thickness, depth: thickness),
                    transform: Float4x4.translation(SIMD3(Float(x), Float(-y), z))
                        * Float4x4.rotationZ(sign * .pi / 4),
                    color: green,
                    opacity: opacity,
                    unlit: true,
                    castsShadow: false))
            }
        }

        cross(x: intercept.x, y: intercept.y, atZ: Float(intercept.z), opacity: 0.95, scale: 1)
        cross(x: feet.x, y: feet.y, atZ: 2.0, opacity: 0.35, scale: 0.85)
        return out
    }
}
