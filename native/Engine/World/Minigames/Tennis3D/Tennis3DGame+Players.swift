import Foundation
import simd

/// The two people on the court: how they run, how they swing, how the racket meets the ball,
/// and how the opponent decides where to be.
///
/// Three things here are new relative to the 2D game and worth calling out:
///
/// 1. **Movement goes through `Locomotion`**, the same system the overworld player uses. Neither
///    player teleports towards a target any more — they accelerate, carry momentum, and turn at
///    a bounded rate. Because both of them are asked to keep facing the net, almost everything
///    they do comes out of `Gait` as a side-step, which is what a tennis player actually does.
/// 2. **The racket is simulated, not drawn.** Its head follows an arc through the swing, and
///    contact is the closest approach between that arc and the ball's own path over one physics
///    sub-step. The old game read the hitbox back out of the renderer's canvas transform, a
///    frame late; nothing here touches the renderer at all.
/// 3. **The swing is triggered by prediction.** Every frame a player who is allowed to hit asks
///    "when will the ball be inside my reach?", and starts the backswing exactly early enough to
///    arrive. Being in the wrong place is therefore the only way to miss — which is the whole
///    game, given the player controls position and nothing else.
extension Tennis3DGame {

    // MARK: - Body geometry

    /// Turns a point in a character's own frame into world space.
    ///
    /// Local axes are the rig's: **+X forward, +Y the character's left, +Z up**, with the origin
    /// at the feet. The rig's body pivot sits 15.5 units up, and that offset is folded in here
    /// so callers can write shoulder and hand positions straight out of `CharacterRig`.
    func worldPoint(local: SIMD3<Double>, of side: Side) -> SIMD3<Double> {
        let radians = side.locomotion.facing * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        return SIMD3(
            side.locomotion.x + local.x * cosine + local.y * sine,
            side.locomotion.y + local.x * sine - local.y * cosine,
            local.z + 15.5
        )
    }

    /// The rig's right shoulder, which is where the racket arm hangs from.
    /// `CharacterRig.rightShoulder` is (3, 10, 26) in body-pivot space.
    private var shoulderLocal: SIMD3<Double> { SIMD3(3, 10, 26) }

    /// The hand position at the moment a serve is struck — reaching up and slightly in front.
    /// Shared by the swing choreography and by `tossBall`, which solves the toss backwards
    /// from where this puts the strings.
    var serveContactHandLocal: SIMD3<Double> { SIMD3(11, 7, 46) }

    /// Where the racket head is right now, in world space.
    ///
    /// The hand goes wherever the swing puts it; the head is a fixed distance further along the
    /// line from the shoulder through the hand. That is not quite how a wrist works, and it is
    /// exactly how a racket looks from above.
    ///
    /// `handOverride` asks the same question about a hand position the swing has not reached
    /// yet — "where *will* the strings be" — which is what the serve solver needs.
    func racketHead(of side: Side, handOverride: SIMD3<Double>? = nil) -> SIMD3<Double> {
        let hand = handOverride ?? handLocal(for: side)
        var reach = hand - shoulderLocal
        let length = simd_length(reach)
        reach = length > 1e-6 ? reach / length : SIMD3(1, 0, 0)
        return worldPoint(local: hand + reach * Tuning.racketLength, of: side)
    }

    // MARK: - Swing shape

    /// The racket hand's position through the swing, in the character's own frame.
    ///
    /// Four poses per stroke, eased between. Written as literal coordinates rather than derived
    /// from anything, because a swing is choreography: these are the numbers that look right
    /// from the camera the game is played on.
    private func handLocal(for side: Side) -> SIMD3<Double> {
        let rest = SIMD3<Double>(9, 16, 12)
        let swing = side.swing
        guard swing.isSwinging else { return rest }

        let mirror: Double = swing.isBackhand ? -1 : 1

        // Forehand: the arm loads behind the hip, drives through in front, finishes across the
        // body. Backhand mirrors it about the body's centre line. A serve is its own shape.
        let loaded: SIMD3<Double>
        let contact: SIMD3<Double>
        let finish: SIMD3<Double>

        if swing.isServe {
            loaded = SIMD3(-9, 13, 33)
            contact = serveContactHandLocal
            finish = SIMD3(8, -13, 8)
        } else {
            loaded = SIMD3(-7, 22 * mirror, 19)
            contact = SIMD3(16, 17 * mirror, 21)
            finish = SIMD3(9, -9 * mirror, 30)
        }

        switch swing.stage {
        case .idle:
            return rest
        case .backswing:
            return blend(rest, loaded, easeOut(swing.elapsed / Tuning.backswingTime))
        case .forward:
            // Linear through the strike, deliberately: an eased contact would slow the head
            // down exactly where its speed decides how hard the ball comes off.
            return blend(loaded, contact,
                         min(1, swing.elapsed / Tuning.forwardSwingTime))
        case .follow:
            return blend(contact, finish, easeOut(swing.elapsed / Tuning.followThroughTime))
        }
    }

    /// The off hand. It only does anything interesting during a serve, where it throws the ball.
    private func offHandLocal(for side: Side) -> SIMD3<Double> {
        let rest = SIMD3<Double>(9, -16, 12)
        guard side.swing.isServe, side.swing.isSwinging else { return rest }

        switch side.swing.stage {
        case .backswing:
            return blend(SIMD3(6, -13, 24), SIMD3(7, -12, 40),
                         easeOut(side.swing.elapsed / Tuning.backswingTime))
        default:
            return blend(SIMD3(7, -12, 40), rest,
                         min(1, side.swing.elapsed / (Tuning.followThroughTime * 1.4)))
        }
    }

    /// Poses the rig for whatever the swing is doing, and rolls the racket face with it.
    func swingPose(for side: Side) -> RigOverride? {
        let hand = handLocal(for: side)
        let offHand = offHandLocal(for: side)
        let swing = side.swing

        // A neutral, still character needs no override at all — let the idle sway have it.
        guard swing.isSwinging else { return nil }

        // The strings turn over through the stroke: open on the backswing, square at contact,
        // rolled shut on the follow-through. Sold with a single roll about the forearm.
        let faceRoll: Float
        switch swing.stage {
        case .idle: faceRoll = 0
        case .backswing: faceRoll = Float(-0.7 + 0.7 * (swing.elapsed / Tuning.backswingTime))
        case .forward: faceRoll = Float(0.35 * (swing.elapsed / Tuning.forwardSwingTime))
        case .follow: faceRoll = Float(0.35 + 0.9 * (swing.elapsed / Tuning.followThroughTime))
        }

        // The shoulders turn into the shot — a quarter of the arm's own rotation, which is
        // enough to read as a body that is hitting rather than an arm flapping.
        let coil: Float
        switch swing.stage {
        case .backswing: coil = Float(0.30 * (swing.elapsed / Tuning.backswingTime))
        case .forward: coil = Float(0.30 - 0.5 * (swing.elapsed / Tuning.forwardSwingTime))
        case .follow: coil = Float(-0.20 * (1 - swing.elapsed / Tuning.followThroughTime))
        case .idle: coil = 0
        }
        let signedCoil = swing.isBackhand ? -coil : coil

        return { mutation in
            mutation.rightHandTarget = SIMD3(Float(hand.x), Float(hand.y), Float(hand.z))
            mutation.leftHandTarget = SIMD3(Float(offHand.x), Float(offHand.y), Float(offHand.z))
            mutation.bodyPivotRotation.z += signedCoil
            mutation.holdingRotation = SIMD3(faceRoll, 0, 0)
        }
    }

    private func blend(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        let clamped = min(max(t, 0), 1)
        return a + (b - a) * clamped
    }

    private func easeOut(_ t: Double) -> Double {
        let clamped = min(max(t, 0), 1)
        return 1 - (1 - clamped) * (1 - clamped)
    }

    // MARK: - Swing lifecycle

    /// Advances one player's swing by a sub-step, and tests the racket against the ball while
    /// the head is travelling forward.
    func advanceSwing(_ side: Side, dt: Double) {
        if side.swing.cooldown > 0 { side.swing.cooldown -= dt }

        guard side.swing.isSwinging else {
            side.swing.previousHead = nil
            considerStartingSwing(side, dt: dt)
            return
        }

        let headBefore = side.swing.previousHead ?? racketHead(of: side)
        side.swing.elapsed += dt

        switch side.swing.stage {
        case .backswing where side.swing.elapsed >= Tuning.backswingTime:
            side.swing.stage = .forward
            side.swing.elapsed = 0
        case .forward where side.swing.elapsed >= Tuning.forwardSwingTime:
            side.swing.stage = .follow
            side.swing.elapsed = 0
        case .follow where side.swing.elapsed >= Tuning.followThroughTime:
            if !side.swing.hasStruck {
                let metre = Tennis3DCourt.unitsPerMetre
                let head = racketHead(of: side)
                trace(String(format: "MISS %@ at (%.1f, %.1f)m head=(%.1f, %.1f, %.1f)m target=(%.1f, %.1f)m — ball (%.1f, %.1f, %.1f)m, %.1fm from head",
                             side.isPlayer ? "you" : opponentName,
                             side.locomotion.x / metre, side.locomotion.y / metre,
                             head.x / metre, head.y / metre, head.z / metre,
                             (side.moveTarget?.x ?? .nan) / metre,
                             (side.moveTarget?.y ?? .nan) / metre,
                             ball.x / metre, ball.y / metre, ball.z / metre,
                             simd_length(ball.position - head) / metre))
            }
            side.swing = SwingState()
            side.swing.cooldown = Tuning.swingCooldown
            return
        default:
            break
        }

        let headAfter = racketHead(of: side)
        side.swing.previousHead = headAfter

        // Only the forward half of the stroke can hit anything, and only once.
        guard side.swing.stage == .forward, !side.swing.hasStruck, ball.inFlight else { return }
        guard canHit(side) else { return }

        if let contact = sweptContact(headFrom: headBefore, headTo: headAfter, dt: dt) {
            side.swing.hasStruck = true
            strike(side, at: contact)
        }
    }

    /// Closest approach between the racket head's path and the ball's, over one sub-step.
    ///
    /// Both are moving, both are moving fast, and the sub-step is 4 ms — so a point-in-sphere
    /// test at the end of the step would miss most contacts outright. Solving for the minimum
    /// of the relative motion is four lines and misses nothing.
    private func sweptContact(headFrom: SIMD3<Double>,
                              headTo: SIMD3<Double>,
                              dt: Double) -> SIMD3<Double>? {
        let ballFrom = ball.position - SIMD3(ball.vx, ball.vy, ball.vz) * dt
        let ballTo = ball.position

        let relativeStart = ballFrom - headFrom
        let relativeMotion = (ballTo - ballFrom) - (headTo - headFrom)

        let denominator = simd_length_squared(relativeMotion)
        var t: Double = 0
        if denominator > 1e-9 {
            t = min(1, max(0, -simd_dot(relativeStart, relativeMotion) / denominator))
        }

        let separation = simd_length(relativeStart + relativeMotion * t)
        guard separation <= Tuning.sweetRadius + Tennis3DCourt.ballRadius else { return nil }

        return ballFrom + (ballTo - ballFrom) * t
    }

    /// Is this player allowed to play the ball **right now**?
    ///
    /// Stated once, positively. The 2D game expressed the same rules as thirteen overlapping
    /// early returns, two of which were unreachable.
    func canHit(_ side: Side) -> Bool {
        guard isTheirBall(side) else { return false }
        // A serve has to bounce in the box before it can be returned.
        if phase == .rally && isServeInFlight && ball.bounces == 0 { return false }
        return true
    }

    /// Is this ball this player's to deal with at all — never mind whether the strings may
    /// legally touch it this instant?
    ///
    /// The difference between this and `canHit` is the whole reason a serve was unreturnable.
    /// A swing takes 0.285 s to bring the racket to the ball, and `canHit` says no until the
    /// serve has **bounced** — which happens about 0.4 s before the ball reaches the receiver.
    /// So the receiver could not begin to move the racket until it was almost too late, and
    /// every legal serve in the game was an ace. Preparation asks this question instead;
    /// `timeUntilInReach` only ever returns a moment after the bounce, so the strings still
    /// arrive legally.
    func isTheirBall(_ side: Side) -> Bool {
        switch phase {
        case .toss:
            // Only the server, only their own toss, and only before it lands.
            return side === server && ball.bounces == 0
        case .rally:
            // Not your own ball back, and not after it has bounced twice.
            guard ball.bounces < 2 else { return false }
            if let last = ball.lastHitByPlayer, last == side.isPlayer { return false }
            return true
        default:
            return false
        }
    }

    /// Decides whether to start a swing, by asking when the ball will be within reach.
    private func considerStartingSwing(_ side: Side, dt: Double) {
        guard side.swing.cooldown <= 0, ball.inFlight, isTheirBall(side) else { return }

        // The opponent is given a beat to react; the player's swing is automatic, because the
        // player's job is to be standing in the right place.
        if !side.isPlayer && side.reactionDelay > 0 { return }

        // Start the backswing so that the middle of the forward swing lands on the ball.
        let leadTime = Tuning.backswingTime + Tuning.forwardSwingTime * 0.5

        // A serve is timed rather than searched for: `tossBall` already decided when the
        // strings meet the ball, so there is nothing to predict.
        if phase == .toss && side === server {
            if tossElapsed >= serveStrikeTime - leadTime { beginSwing(side) }
            return
        }

        guard let arrival = timeUntilInReach(of: side), arrival <= leadTime else { return }
        beginSwing(side)
    }

    /// How long until the ball is inside this player's strike zone, or nil if it never is.
    ///
    /// Runs the ball forward through the same integrator the live one uses and checks the
    /// distance from the player's *predicted* standing position — predicted, because a player
    /// sprinting sideways will not be where they are now by the time the ball arrives.
    private func timeUntilInReach(of side: Side) -> Double? {
        var position = ball.position
        var velocity = SIMD3(ball.vx, ball.vy, ball.vz)
        var spin = ball.topspin
        var elapsed: Double = 0
        var bounces = ball.bounces

        let step = Tuning.physicsStep * 4
        let reach = Tuning.racketLength + Tuning.sweetRadius + Tennis3DCourt.metres(0.35)
        let lowest = Tennis3DCourt.metres(0.15)
        let highest = Tennis3DCourt.metres(2.6)

        while elapsed < 2.0 {
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

            // A serve is not returnable until it has bounced.
            if isServeInFlight && side !== server && bounces == 0 { continue }
            guard position.z >= lowest, position.z <= highest else { continue }

            let standing = predictedStandingPosition(of: side, after: elapsed)
            let distance = hypot(position.x - standing.x, position.y - standing.y)
            if distance <= reach { return elapsed }
        }

        return nil
    }

    /// Where a player will be in `time` seconds, given where they are heading. Straight-line
    /// extrapolation of the current velocity, clamped to the time it takes to reach the target.
    private func predictedStandingPosition(of side: Side, after time: Double) -> SIMD2<Double> {
        let here = SIMD2(side.locomotion.x, side.locomotion.y)
        guard let target = side.moveTarget else {
            return here + SIMD2(side.locomotion.vx, side.locomotion.vy) * time
        }
        let toTarget = SIMD2(target.x, target.y) - here
        let distance = simd_length(toTarget)
        guard distance > 1 else { return here }

        let topSpeed = side.isPlayer ? Tuning.playerTopSpeed : Tuning.npcTopSpeed
        let travelled = min(distance, topSpeed * time)
        return here + toTarget / distance * travelled
    }

    private func beginSwing(_ side: Side) {
        var swing = SwingState()
        swing.stage = .backswing
        swing.elapsed = 0
        swing.isServe = phase == .toss && side === server
        swing.previousHead = racketHead(of: side)

        // Backhand when the ball is on the far side of the body from the racket arm. The racket
        // hangs off local +Y, so a ball at negative local Y has to be crossed to.
        let radians = side.locomotion.facing * .pi / 180
        let toBallX = ball.x - side.locomotion.x
        let toBallY = ball.y - side.locomotion.y
        let lateral = toBallX * sin(radians) - toBallY * cos(radians)
        swing.isBackhand = !swing.isServe && lateral < -Tennis3DCourt.metres(0.15)

        let plan = planShot(for: side, isServe: swing.isServe)
        swing.aim = plan.aim
        swing.power = plan.power
        swing.topspin = plan.topspin

        side.swing = swing
    }

    /// What happens the instant the strings meet the ball.
    private func strike(_ side: Side, at contact: SIMD3<Double>) {
        ball.x = contact.x
        ball.y = contact.y
        ball.z = max(contact.z, Tennis3DCourt.ballRadius)
        ball.lastHitByPlayer = side.isPlayer
        ball.bounces = 0
        ball.clippedNet = false
        timeSinceBallEvent = 0

        // How cleanly it was struck: dead centre of the sweet spot at the middle of the forward
        // swing is a clean hit; anything else bleeds pace and skews the aim. This is where
        // positioning turns into a better or worse shot.
        let timingError = abs(side.swing.elapsed - Tuning.forwardSwingTime * 0.5)
            / (Tuning.forwardSwingTime * 0.5)
        let quality = max(0.35, 1 - timingError * 0.55)

        var aim = side.swing.aim
        // A mistimed shot drifts towards the middle of the court rather than flying anywhere —
        // being late should cost you the corner, not hand you a winner.
        let drift = (1 - quality) * 1.4
        aim.x += (0 - aim.x) * drift * 0.6
        aim.y += (side.half * -Tennis3DCourt.halfLength * 0.55 - aim.y) * drift * 0.35

        let baseSpeed = side.swing.isServe
            ? (faults == 0 ? Tuning.firstServeSpeed : Tuning.secondServeSpeed)
            : Tuning.rallySpeed
        let speed = baseSpeed * side.swing.power * (0.72 + 0.28 * quality)

        launchBall(to: aim, speed: speed, topspin: side.swing.topspin)

        if side.swing.isServe {
            phase = .rally
            isServeInFlight = true
        }

        // The opponent needs a moment before it starts running, and a fresh dose of error.
        let other = side.isPlayer ? npc : player
        other.reactionDelay = Tuning.npcReaction
        other.positionBias = (x: random.spread(Tuning.npcPositionError),
                              y: random.spread(Tuning.npcPositionError))

        let sound = side.isPlayer ? "/media/hit_tennis_ball.mp3" : "/media/hit_tennis_ball2.mp3"
        host.minigamePlayEffect(path: sound,
                                volume: 0.55 + quality * 0.45,
                                rate: 0.86 + quality * 0.26)

        let metre = Tennis3DCourt.unitsPerMetre
        trace(String(format: "STRIKE %@%@ at (%.1f, %.1f, %.1f)m quality=%.2f aim=(%.1f, %.1f)m",
                     side.isPlayer ? "you" : opponentName,
                     side.swing.isServe ? " serve" : (side.swing.isBackhand ? " backhand" : ""),
                     contact.x / metre, contact.y / metre, contact.z / metre,
                     quality, aim.x / metre, aim.y / metre))
    }

    // MARK: - Aiming

    /// Where a shot is aimed, how hard, and with how much spin.
    ///
    /// Deterministic: every number comes out of `random`, which is re-seeded from the score at
    /// the start of each point. The player's aim is decided by where they are standing and
    /// which way they are moving, which is the only steering the control scheme gives them.
    private func planShot(for side: Side, isServe: Bool)
        -> (aim: (x: Double, y: Double), power: Double, topspin: Double) {
        let targetHalf = -side.half

        if isServe {
            let box = Tennis3DCourt.serviceBox(receiverHalf: targetHalf, deuceCourt: deuceCourt)
            // Aim inside the lines by a comfortable margin, then miss it a little — a second
            // serve misses less, because it is hit slower and safer.
            let inset = Tennis3DCourt.metres(0.7)
            let centreX = (box.minX + box.maxX) / 2
            let wide = random.chance(0.55)
            let edgeX = wide
                ? (box.minX < 0 ? box.minX + inset : box.maxX - inset)
                : centreX * 0.35
            let depth = faults == 0 ? 0.78 : 0.62
            let targetY = targetHalf * Tennis3DCourt.serviceLine * depth

            let errorScale = faults == 0 ? 1.0 : 0.5
            return (aim: (x: edgeX + random.spread(Tennis3DCourt.metres(0.75)) * errorScale,
                          y: targetY + random.spread(Tennis3DCourt.metres(0.9)) * errorScale),
                    power: 1.0,
                    topspin: faults == 0 ? 0.35 : 0.8)
        }

        let opponent = side.isPlayer ? npc : player

        // Hit away from where the other player is standing. For the human this is automatic —
        // it is what a real player does without thinking, and there is no second thumb free to
        // aim with.
        let awayFromOpponent: Double = opponent.locomotion.x > 0 ? -1 : 1
        var aimX = awayFromOpponent * Tennis3DCourt.halfSingles * random.range(0.45, 0.80)

        // Sliding across the court while you hit drags the ball with you, which gives the drag
        // control a second job: it steers the shot.
        let radians = side.locomotion.facing * .pi / 180
        let lateralSpeed = side.locomotion.vx * sin(radians) - side.locomotion.vy * cos(radians)
        aimX -= lateralSpeed / Tuning.playerTopSpeed * Tennis3DCourt.metres(2.4)
        aimX = min(max(aimX, -Tennis3DCourt.halfSingles + Tennis3DCourt.metres(0.5)),
                   Tennis3DCourt.halfSingles - Tennis3DCourt.metres(0.5))

        // Depth: deep by default, with the odd shorter one. Struck from behind the baseline,
        // aim shorter — a defensive ball hit for the baseline mostly goes long.
        let stretched = abs(side.locomotion.y) > Tennis3DCourt.halfLength
        let depth = stretched ? random.range(0.50, 0.68) : random.range(0.62, 0.86)
        let aimY = targetHalf * Tennis3DCourt.halfLength * depth

        return (aim: (x: aimX, y: aimY),
                power: stretched ? 0.82 : random.range(0.92, 1.05),
                topspin: stretched ? 0.85 : random.range(0.45, 0.75))
    }

    // MARK: - Steering

    /// The human player. Their move target is set by the finger; everything else is inertia.
    func steerPlayer(dt: Double) {
        run(player, dt: dt, profile: profile(topSpeed: Tuning.playerTopSpeed))
    }

    /// The opponent. Reads the ball the same way a person would — where is it going to land,
    /// where do I need to stand to hit it, and where should I recover to afterwards.
    func steerOpponent(dt: Double) {
        if npc.reactionDelay > 0 { npc.reactionDelay -= dt }

        // Never chase your own ball toss. `tossBall` solves the toss backwards from where the
        // server's strings will be *given where they are standing now*, so a server who takes a
        // single step after the toss swings through empty air — which is what made every one of
        // Alex's service games a run of double faults. The ball is above their own baseline and
        // heading down, so the "read the landing and go" branch below found it irresistible.
        let servingOwnToss = phase == .toss && server === npc
        if (phase == .rally || phase == .toss) && !servingOwnToss {
            if npc.reactionDelay <= 0, ball.inFlight, ball.vy < 0 || ball.y < 0 {
                // Stand where the ball can be *struck*, not where it lands. Those are the same
                // place for a groundstroke and eight metres apart for a serve, which bounces
                // near the service line and runs on past the baseline — so aiming at the bounce
                // sent Alex charging forward into a ball already going over her shoulder, and
                // the player's serve was unbreakable. `intercept(for:)` accounts for how far she
                // can actually run in the time available.
                if let meeting = intercept(for: npc) {
                    npc.moveTarget = (
                        x: meeting.x + npc.positionBias.x + Tennis3DCourt.metres(0.45),
                        y: min(-Tennis3DCourt.metres(1.0), meeting.y + npc.positionBias.y)
                    )
                } else if let landing = predictedLanding(), landing.point.y < 0 {
                    // Nothing playable predicted — cover the bounce and hope.
                    let standOff = Tennis3DCourt.metres(1.1)
                    npc.moveTarget = (
                        x: landing.point.x + npc.positionBias.x + Tennis3DCourt.metres(0.45),
                        y: min(-Tennis3DCourt.metres(1.0),
                               landing.point.y - standOff + npc.positionBias.y)
                    )
                }
            } else if ball.vy > 0 || ball.lastHitByPlayer == false {
                // Its own ball is on the way over: recover towards the middle of the baseline.
                npc.moveTarget = (x: 0, y: -Tennis3DCourt.halfLength - Tennis3DCourt.metres(0.6))
            }
        }

        run(npc, dt: dt, profile: profile(topSpeed: Tuning.npcTopSpeed))
    }

    private func profile(topSpeed: Double) -> LocomotionProfile {
        LocomotionProfile(maxSpeed: topSpeed,
                          acceleration: Tuning.acceleration,
                          braking: Tuning.braking,
                          turnRate: Tuning.turnRate,
                          strideLength: Tuning.strideLength)
    }

    /// Moves one player towards their target, and decides which way they face while doing it.
    ///
    /// The facing rule is the whole reason `Gait` exists. A tennis player keeps their chest to
    /// the net and shuffles; they only turn and run when the ball has put them a long way out of
    /// position and there is time to get back. Both cases fall out of what `facingIntent` is set
    /// to, and the legs follow automatically.
    private func run(_ side: Side, dt: Double, profile: LocomotionProfile) {
        var desired = (x: 0.0, y: 0.0)
        var distance: Double = 0

        // A server stands still from the moment they take the ball until they have struck it.
        // Not stagecraft — a requirement. `tossBall` solves the toss backwards from where the
        // strings will be, given where the server is standing *at the moment of the toss*, so a
        // server who drifts even half a metre swings through thin air. Both sides were losing
        // serves to it; the opponent lost every one.
        let isServing = (phase == .ready || phase == .toss) && side === server
        if isServing {
            side.moveTarget = nil
        } else if let target = side.moveTarget {
            let dx = target.x - side.locomotion.x
            let dy = target.y - side.locomotion.y
            distance = hypot(dx, dy)

            if distance > Tennis3DCourt.metres(0.12) {
                // Ease off on the approach, so nobody skids past their mark and has to come
                // back — the arrival behaviour every steering system needs and the 2D game's
                // "snap when within 1 unit" did not have.
                let approach = min(profile.maxSpeed, distance * 4.5)
                desired = (dx / distance * approach, dy / distance * approach)
            }
        }

        // Face the net by default. 270° points at −Y for the near player, 90° at +Y for the
        // far one.
        let netFacing: Double = side.isPlayer ? 270 : 90
        var facingIntent: Double? = netFacing

        // A long run with time to make it: turn and sprint properly rather than shuffling.
        let ballIsClose = ball.inFlight
            && abs(ball.y - side.locomotion.y) < Tennis3DCourt.metres(7)
        if distance > Tennis3DCourt.metres(3.0) && !ballIsClose && !side.swing.isSwinging {
            facingIntent = nil
        }
        // Mid-swing the feet are planted; nothing turns the body but the stroke.
        if side.swing.isSwinging { facingIntent = netFacing }

        let demand = Locomotion.step(&side.locomotion,
                                     desired: desired,
                                     facingIntent: facingIntent,
                                     profile: profile,
                                     dt: dt)

        // The court fence, and the net. Applied as a clamp on the accepted delta so
        // `Locomotion.commit` sees what really happened and sheds the velocity into it.
        var newX = side.locomotion.x + demand.dx
        var newY = side.locomotion.y + demand.dy
        newX = min(max(newX, -Tennis3DCourt.playableHalfWidth), Tennis3DCourt.playableHalfWidth)
        let netKeepOut = Tennis3DCourt.metres(0.5)
        if side.isPlayer {
            newY = min(max(newY, netKeepOut), Tennis3DCourt.playableHalfLength)
        } else {
            newY = min(max(newY, -Tennis3DCourt.playableHalfLength), -netKeepOut)
        }

        Locomotion.commit(&side.locomotion,
                          actualDx: newX - side.locomotion.x,
                          actualDy: newY - side.locomotion.y,
                          dt: dt)
    }
}
