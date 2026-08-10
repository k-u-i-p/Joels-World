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
    /// at the feet. The body pivot's height is folded in here so callers can write shoulder and
    /// hand positions straight out of `CharacterRig`. **Do not write that height out as a number
    /// anywhere** — see `headHeight`, which did, and cost this game a session's worth of near
    /// misses for it, twice.
    ///
    /// That height is `CharacterMotor.rideHeight` and is **per character**, not the constant it
    /// used to be: a bought model stands on its own legs, and they are not the rig's.
    func worldPoint(local: SIMD3<Double>, of side: Side) -> SIMD3<Double> {
        side.motor.localToWorld(local)
    }

    /// The rig's right shoulder, which is where the racket arm hangs from.
    /// `CharacterRig.rightShoulder` is (3, 10, 26) in body-pivot space.
    private var shoulderLocal: SIMD3<Double> { SIMD3(3, 10, 26) }

    /// **Pulls a hand pose inside the arm's reach**, exactly the way the motor will.
    ///
    /// Every pose below was authored against a rig that clamped silently. `IKSolver.solve` moves
    /// an out-of-reach target in place and says nothing about it, so the swing *drew* the arm at
    /// full stretch with the hand — and the racket — at the clamped position, while every
    /// calculation in the game used the position that had been asked for: where to throw the
    /// toss, where to put the feet, where the strings were for the contact test. The strings you
    /// could see were never the strings that hit the ball.
    ///
    /// The serve pose is 21.7 units from the shoulder and an arm is 16.6 long. That is a fifth
    /// of a metre of pure fiction, and the moment `CharacterMotor` started reporting where the
    /// hand really was, every service game in the match became a run of double faults — the
    /// server threw the ball to a point the arm could not reach and swung 0.63 m under it, over
    /// and over. Clamping here, at the one place the poses are written down, puts the drawing
    /// and the simulation back on the same arm.
    func reachable(_ hand: SIMD3<Double>, from shoulder: SIMD3<Float>) -> SIMD3<Double> {
        let clamped = LimbProfile.arm.reachable(
            SIMD3<Float>(Float(hand.x), Float(hand.y), Float(hand.z)), from: shoulder)
        return SIMD3(Double(clamped.x), Double(clamped.y), Double(clamped.z))
    }

    /// The hand position at the moment a serve is struck — reaching up and slightly in front.
    /// Shared by the swing choreography and by `tossBall`, which solves the toss backwards
    /// from where this puts the strings.
    var serveContactHandLocal: SIMD3<Double> {
        reachable(SIMD3(11, 7, 46), from: CharacterRig.rightShoulder)
    }

    /// The three poses of a groundstroke on the racket side: loaded behind the hip, through the
    /// ball, finished across the body. `mirror` flips them for a backhand, and `lift` raises the
    /// whole stroke to meet a ball that is not at waist height.
    ///
    /// One definition. `handLocal` animates through it and `stance(toMeet:for:)` measures from
    /// it, so where the strings arrive and where the feet are told to be cannot drift apart.
    func groundstrokePoses(mirror: Double, lift: Double = 0)
        -> (loaded: SIMD3<Double>, contact: SIMD3<Double>, finish: SIMD3<Double>) {
        // Clamped to the arm, because a backhand mirrors these about the body's centre line and
        // the mirrored poses are two arms' length from the racket shoulder. See `reachable`.
        // The lift is applied *before* the clamp, so a high ball costs reach rather than silently
        // getting it for free.
        let shoulder = CharacterRig.rightShoulder
        let up = SIMD3<Double>(0, 0, lift)
        return (loaded: reachable(SIMD3(-7, 22 * mirror, 19) + up, from: shoulder),
                contact: reachable(SIMD3(16, 17 * mirror, 21) + up, from: shoulder),
                // The follow-through comes back down whatever the ball did — an arm that finishes
                // above the head on every high ball looks like a smash, not a rally shot.
                finish: reachable(SIMD3(9, -9 * mirror, 30) + up * 0.4, from: shoulder))
    }

    /// Where the racket hand is at the instant the swing is **timed** to meet the ball.
    ///
    /// Not the `contact` pose — the *middle* of the forward swing. `considerStartingSwing` starts
    /// the backswing so that `forwardSwingTime × 0.5` lands on the ball, and `strike` scores
    /// timing quality against that same midpoint, so the midpoint is where the game believes the
    /// strings meet the ball. Measuring the stance from the end pose instead put the feet most
    /// of a metre wrong on every single shot — which showed up as a beautifully consistent
    /// half-metre near miss, over and over, whatever the player did.
    func strikeHandLocal(lift: Double = 0) -> SIMD3<Double> {
        let poses = groundstrokePoses(mirror: 1, lift: lift)
        return poses.loaded + (poses.contact - poses.loaded) * 0.5
    }

    /// **Where the feet have to be** for the strings to meet a ball at `meeting`.
    ///
    /// This is the piece that was missing, and without it nobody could return a serve. Both
    /// players were being sent to stand *where the ball would be* — but the racket head is a
    /// metre and a bit forward and to the racket side of the body, so a player standing on the
    /// ball watches it go past inside their reach. The closest the strings ever got was 1.0 m,
    /// against a sweet spot of 0.33 m: near enough to look like bad luck, and never once a hit.
    ///
    /// The offset is computed from the same contact pose the swing actually uses, rotated by the
    /// heading they will be facing — which is always the net.
    func stance(toMeet meeting: SIMD3<Double>, for side: Side) -> (x: Double, y: Double) {
        let offset = contactHeadWorldOffset(for: side, lift: lift(forBallHeight: meeting.z, for: side))
        return (x: meeting.x - offset.x, y: meeting.y - offset.y)
    }

    /// The ground-plane vector from a player's feet to their strings at contact, in world space.
    /// One definition, used by the stance, by the swing trigger and by the marker.
    ///
    /// It barely moves with `lift`, and that is worth knowing rather than assuming: raising the
    /// hand rotates the arm about the shoulder, so the racket head goes *up* far more than it
    /// comes *in*. Over the whole lift range the horizontal reach changes by a couple of
    /// centimetres. It is threaded through anyway, because the day somebody widens the range is
    /// the day the assumption stops holding, and this is the third handoff in a row to be written
    /// about two pieces of code disagreeing about where the racket is.
    func contactHeadWorldOffset(for side: Side, lift: Double = 0) -> SIMD2<Double> {
        let head = contactHeadLocal(lift: lift)
        let radians = netFacing(for: side) * .pi / 180
        // The rotation half of `worldPoint(local:of:)`.
        return SIMD2(head.x * cos(radians) + head.y * sin(radians),
                     head.x * sin(radians) - head.y * cos(radians))
    }

    /// Where the player should be standing to play whatever is coming, or nil if nothing is.
    func idealStance() -> (x: Double, y: Double)? {
        guard let meeting = idealIntercept() else { return nil }
        return stance(toMeet: meeting, for: player)
    }

    /// How high off the court the strings pass on a groundstroke played at `lift`. `worldPoint`
    /// lifts a local point by the rig's body pivot, so this is that same sum.
    ///
    /// The intercept used to accept any ball between knee and shoulder and pick purely on how
    /// far the player had to run, which meant it happily chose one a third of a metre above
    /// where the racket was ever going to be. Every return was then a near miss of exactly that
    /// size, over and over, which is what a systematic error looks like in a log.
    ///
    /// **And it happened again**, in the session that lengthened the rig's legs. This sum was
    /// written as a literal `15.5` while `worldPoint` went through `CharacterMotor`, which reads
    /// `CharacterRig.bodyPivotHeight`. The moment that stopped being 15.5 the two disagreed by
    /// 3.4 units — 0.13 m — and the log filled with misses whose strings finished between 0.46
    /// and 0.60 m from a ball, against a 0.45 m sweet spot: near misses of exactly one systematic
    /// size, on low balls, which is the same fingerprint as last time. Reading the constant is
    /// the fix, and it is the fourth handoff in a row to be written about two pieces of code
    /// disagreeing about where the strings are.
    /// **And a fifth time, avoided rather than paid for.** `bodyPivotHeight` stopped being the
    /// height a character stands at when the rig started riding at the worn model's own
    /// `WornLeg.rideHeight` — 1.2 to 1.5 units lower, 0.05 m, an eighth of the sweet spot. Same
    /// two pieces of code, same disagreement, same fingerprint in the log. So this asks the motor
    /// for the number rather than reading a constant that used to be it: `side.motor.rideHeight`
    /// is by construction the one `worldPoint` folds in, because `worldPoint` is that motor.
    func headHeight(lift: Double, of side: Side) -> Double {
        contactHeadLocal(lift: lift).z + side.motor.rideHeight
    }

    /// Where the strings pass on the plain waist-high stroke. The height everything falls back
    /// to when there is no particular ball to play.
    func contactHeadHeight(of side: Side) -> Double { headHeight(lift: 0, of: side) }

    /// **The lift that puts the strings on a ball at `height`.**
    ///
    /// Solved by bisection rather than by algebra, because the relationship is not linear: the
    /// arm rotates about the shoulder as the hand rises, and the racket, being a rigid extension
    /// of that line, amplifies the rotation about two and a half times. Twelve iterations over a
    /// range of eighteen units settle to well under a centimetre, and the whole thing is a few
    /// dozen multiplications — it runs a handful of times a frame at most.
    ///
    /// **This is the only place a ball height becomes a racket height.** The stance, the swing
    /// trigger, the choreography and the marker all call it, which is the point: the last three
    /// handoffs each contain a bug that was two pieces of code disagreeing about where the strings
    /// were, and every one of them was two copies of a sum like this one.
    func lift(forBallHeight height: Double, for side: Side) -> Double {
        var low = -Tuning.strikeLiftDown
        var high = Tuning.strikeLiftUp
        if height <= headHeight(lift: low, of: side) { return low }
        if height >= headHeight(lift: high, of: side) { return high }
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if headHeight(lift: middle, of: side) < height { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// **How big this player's sweet spot is.** Alex's never changes; the player's is what the
    /// Easy / Normal / Hard buttons move, and on Normal it is the same 0.42 m it has always been.
    /// See `Tuning.playerReachScale` for why the difficulty setting reaches across the net at all.
    func sweetRadius(for side: Side) -> Double {
        side.isPlayer ? Tuning.sweetRadius * Tuning.playerReachScale : Tuning.sweetRadius
    }

    /// **How far above or below the strings a ball may be and still be a shot.**
    ///
    /// One definition, read by both the thing that picks where to stand (`intercept(for:)`) and
    /// the thing that decides when to swing (`timeUntilInReach`). They disagreed by two metres
    /// for as long as the game existed: the intercept would sensibly wait for a ball to drop to
    /// racket height, and the swing trigger would fire the moment it was anywhere overhead. The
    /// two questions have to be asked of the same strike zone or the feet and the arm are playing
    /// different shots.
    ///
    /// A little wider than the sweet spot, because the swing is timed to a *predicted* height and
    /// the ball is still falling while the racket comes through.
    func verticalReach(for side: Side) -> Double {
        sweetRadius(for: side) + Tennis3DCourt.metres(0.16)
    }

    /// **Every height a ball can be played at**: the whole lift range, plus the tolerance either
    /// end of it.
    ///
    /// This replaces a band half a metre either side of one fixed height. It is much wider — from
    /// the ankles to well above the head — and that is not a loosening, because the racket now
    /// genuinely goes there. Widening it *without* the lift would put back the part-3 bug exactly:
    /// a full stroke fired at a ball the strings were never going to reach.
    func strikeBand(for side: Side) -> (low: Double, high: Double) {
        let tolerance = verticalReach(for: side)
        return (low: headHeight(lift: -Tuning.strikeLiftDown, of: side) - tolerance,
                high: headHeight(lift: Tuning.strikeLiftUp, of: side) + tolerance)
    }

    /// The racket head at the timed strike, in the character's own frame. Derived from the
    /// swing choreography, not written down separately.
    private func contactHeadLocal(lift: Double) -> SIMD3<Double> {
        let hand = strikeHandLocal(lift: lift)
        var reach = hand - shoulderLocal
        let length = simd_length(reach)
        reach = length > 1e-6 ? reach / length : SIMD3(1, 0, 0)
        return hand + reach * Tuning.racketLength
    }

    /// 270° points at −Y for the near player, 90° at +Y for the far one. Both keep their chest
    /// to the net, which is what makes the racket offset above a fixed direction in world space.
    func netFacing(for side: Side) -> Double { side.isPlayer ? 270 : 90 }

    /// Where the racket head is right now, in world space.
    ///
    /// The hand goes wherever the swing puts it; the head is a fixed distance further along the
    /// line from the shoulder through the hand. That is not quite how a wrist works, and it is
    /// exactly how a racket looks from above.
    ///
    /// `handOverride` asks the same question about a hand position the swing has not reached
    /// yet — "where *will* the strings be" — which is what the serve solver needs.
    ///
    /// Without an override this reads the hand **the motor has actually moved**, not the pose
    /// the choreography asked for. The two are close but never identical: an arm has a top speed
    /// and a mass, and the ball is met by the racket that exists rather than by the one that was
    /// requested. Reading the same position the rig is drawn with is what keeps the contact test
    /// honest — the 2D game's habit of reading its hitbox out of a frame-old drawing is the
    /// failure mode at the other end of this.
    func racketHead(of side: Side, handOverride: SIMD3<Double>? = nil) -> SIMD3<Double> {
        let hand = handOverride ?? SIMD3<Double>(side.motor.limbPosition(.rightHand))
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
        let rest = SIMD3<Double>(CharacterRig.neutralRightHand)
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
            let poses = groundstrokePoses(mirror: mirror, lift: swing.lift)
            loaded = poses.loaded
            contact = poses.contact
            finish = poses.finish
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
        let rest = SIMD3<Double>(CharacterRig.neutralLeftHand)
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

    /// **Asks the motor to put the hands where the swing wants them.** Called on every physics
    /// sub-step, because the racket head is where the ball is met and a tenth of a second is the
    /// whole forward swing.
    ///
    /// This is the line the refactor draws. The choreography — the four poses of a forehand,
    /// where a serve reaches — is tennis, and lives here. *Moving a hand there* is not, and does
    /// not: `moveHandTo` works out whether the arm can reach, accelerates the hand, and keeps
    /// its velocity. Nothing in this file writes a limb target or remembers where a hand was
    /// last frame any more.
    private func driveHands(for side: Side, dt: Double) {
        if side.swing.isSwinging {
            let hand = handLocal(for: side)
            let offHand = offHandLocal(for: side)
            side.motor.moveHandTo(.rightHand, local: SIMD3(Float(hand.x), Float(hand.y), Float(hand.z)))
            side.motor.moveHandTo(.leftHand, local: SIMD3(Float(offHand.x), Float(offHand.y), Float(offHand.z)))
        } else {
            // Back to the walk cycle and the idle sway, eased rather than snapped.
            side.motor.releaseLimb(.rightHand)
            side.motor.releaseLimb(.leftHand)
        }
        side.motor.stepLimbs(dt: dt)
    }

    /// The parts of the pose that are not limbs: how far the shoulders turn into the shot, and
    /// which way the strings are facing. Composed on top of the motor's own limb pass.
    func swingPose(for side: Side) -> RigOverride? {
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
            mutation.chestTwist += signedCoil
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
            driveHands(for: side, dt: dt)
            considerStartingSwing(side, dt: dt)
            return
        }

        // Where the strings are *before* this sub-step moves them. No remembered copy: the hand
        // has not moved yet, so asking is the same as remembering and cannot go stale.
        let headBefore = racketHead(of: side)
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
                let close = side.swing.closestBall
                trace(String(format: "MISS %@ at (%.1f, %.1f)m — closest the strings got was %.2fm, "
                             + "with the ball at (%.1f, %.1f, %.1f)m (sweet spot is %.2fm)",
                             side.isPlayer ? "you" : opponentName,
                             side.motor.x / metre, side.motor.y / metre,
                             side.swing.closestApproach / metre,
                             close.x / metre, close.y / metre, close.z / metre,
                             (sweetRadius(for: side) + Tennis3DCourt.ballRadius) / metre))
            }
            side.swing = SwingState()
            side.swing.cooldown = Tuning.swingCooldown
            return
        default:
            break
        }

        driveHands(for: side, dt: dt)
        let headAfter = racketHead(of: side)

        // Only the forward half of the stroke can hit anything, and only once.
        guard side.swing.stage == .forward, !side.swing.hasStruck, ball.inFlight else { return }
        guard canHit(side) else { return }

        let separation = simd_length(ball.position - headAfter)
        if separation < side.swing.closestApproach {
            side.swing.closestApproach = separation
            side.swing.closestBall = ball.position
        }

        if let contact = sweptContact(headFrom: headBefore, headTo: headAfter, dt: dt,
                                      radius: sweetRadius(for: side)) {
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
                              dt: Double,
                              radius: Double) -> SIMD3<Double>? {
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
        guard separation <= radius + Tennis3DCourt.ballRadius else { return nil }

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
            if tossElapsed >= serveStrikeTime - leadTime { beginSwing(side, ballHeight: nil) }
            return
        }

        guard let arrival = timeUntilInReach(of: side), arrival.time <= leadTime else { return }
        beginSwing(side, ballHeight: arrival.height)
    }

    /// How long until the ball is inside this player's strike zone, **and how high it will be
    /// when it gets there** — or nil if it never is.
    ///
    /// The height is the other half of the answer now. It is what the swing is built around, so
    /// returning the moment without it would leave the arm guessing at the one number that
    /// decides whether the strings meet the ball or pass under it.
    ///
    /// Runs the ball forward through the same integrator the live one uses and checks the
    /// distance from the player's *predicted* standing position — predicted, because a player
    /// sprinting sideways will not be where they are now by the time the ball arrives.
    private func timeUntilInReach(of side: Side) -> (time: Double, height: Double)? {
        var position = ball.position
        var velocity = SIMD3(ball.vx, ball.vy, ball.vz)
        var spin = ball.topspin
        var elapsed: Double = 0
        var bounces = ball.bounces

        let step = Tuning.physicsStep * 4
        // Measured against where the **strings** will be, not where the body will be. Those are
        // 1.4 m apart, and once both players started standing off the ball so the racket could
        // reach it — which is what makes a return possible at all — a body-centred test stopped
        // firing entirely and the opponent simply watched every serve go by without swinging.
        //
        // The horizontal margin is generous because the player is still running when this fires;
        // the **vertical** one is not, and that is the whole point of it being separate.
        let reach = sweetRadius(for: side) + Tennis3DCourt.metres(0.6)
        let band = strikeBand(for: side)

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

            // **Is the ball at a height the strings can get to?**
            //
            // This test used to accept anything between 0.15 m and 2.6 m and then measure the
            // distance on the ground plane alone, which is to say it ignored height entirely. A
            // topspin rally ball lands mid-court and climbs back to about 1.7 m, and it passes
            // directly *above* the receiver on the way to their baseline — so the test fired,
            // the player swung a full stroke into thin air 0.7 m under it, and by the time the
            // 0.63 s swing and its cooldown were done the ball had bounced twice behind them.
            // Fourteen misses in a twenty-point match.
            //
            // Part 3 fixed it by pinning the test to the one height the strings passed through.
            // That was right about the disagreement and wrong about which side to settle it on:
            // the strings should have been the thing that moved. `strikeBand` is now the whole
            // range the swing can lift to, and the lift that goes with this particular ball is
            // handed to `beginSwing` below — so the test firing and the strings arriving are once
            // again the same claim.
            guard position.z >= band.low, position.z <= band.high else { continue }

            // The racket head shifts a little as the stroke rises, so the offset is asked for at
            // the lift this ball will actually be played at.
            let headOffset = contactHeadWorldOffset(for: side,
                                                    lift: lift(forBallHeight: position.z, for: side))
            let standing = predictedStandingPosition(of: side, after: elapsed) + headOffset
            let distance = hypot(position.x - standing.x, position.y - standing.y)
            if distance <= reach { return (elapsed, position.z) }
        }

        return nil
    }

    /// Where a player will be in `time` seconds, given where they are heading. Straight-line
    /// extrapolation of the current velocity, clamped to the time it takes to reach the target.
    private func predictedStandingPosition(of side: Side, after time: Double) -> SIMD2<Double> {
        let here = SIMD2(side.motor.x, side.motor.y)
        guard let target = side.moveTarget else {
            return here + SIMD2(side.motor.vx, side.motor.vy) * time
        }
        let toTarget = SIMD2(target.x, target.y) - here
        let distance = simd_length(toTarget)
        guard distance > 1 else { return here }

        let topSpeed = side.isPlayer ? Tuning.playerTopSpeed : Tuning.npcTopSpeed
        let travelled = min(distance, topSpeed * time)
        return here + toTarget / distance * travelled
    }

    /// - Parameter ballHeight: where the ball will be when the strings arrive, or nil for a serve,
    ///   which has its own choreography and throws the ball to it rather than the other way round.
    private func beginSwing(_ side: Side, ballHeight: Double?) {
        var swing = SwingState()
        swing.stage = .backswing
        swing.elapsed = 0
        swing.isServe = phase == .toss && side === server
        // **The one moment the height of the stroke is decided.** Everything after this reads
        // `swing.lift`: the poses the arm animates through, the head the contact test sweeps,
        // and the racket the renderer draws.
        swing.lift = ballHeight.map { lift(forBallHeight: $0, for: side) } ?? 0

        // Backhand when the ball is on the far side of the body from the racket arm. The racket
        // hangs off local +Y, so a ball at negative local Y has to be crossed to.
        let radians = side.motor.facing * .pi / 180
        let toBallX = ball.x - side.motor.x
        let toBallY = ball.y - side.motor.y
        let lateral = toBallX * sin(radians) - toBallY * cos(radians)
        swing.isBackhand = !swing.isServe && lateral < -Tennis3DCourt.metres(0.15)

        let plan = planShot(for: side, isServe: swing.isServe)
        swing.aim = plan.aim
        swing.power = plan.power
        swing.topspin = plan.topspin
        // A chosen target is spent by the shot that uses it, hit or miss. Keeping it would mean
        // every ball for the rest of the point went to the same corner, which is both a worse
        // game and not what tapping once looks like it should do.
        if side.isPlayer && !swing.isServe { clearAim() }

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

        rallyShots += 1
        longestRally = max(longestRally, rallyShots)
        if rallyShots == 4 || rallyShots == 8 {
            // The crowd wakes up for a long one. Twice per point at most, so a twenty-shot rally
            // does not turn into twenty overlapping claps.
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.3 + 0.2 * Double(rallyShots) / 8)
        }
        onPresentationChanged?()

        // How cleanly it was struck: dead centre of the sweet spot at the middle of the forward
        // swing is a clean hit; anything else bleeds pace and skews the aim. This is where
        // positioning turns into a better or worse shot.
        let timingError = abs(side.swing.elapsed - Tuning.forwardSwingTime * 0.5)
            / (Tuning.forwardSwingTime * 0.5)

        // **And how comfortable the shot was.** A ball met above the shoulder or scraped off the
        // ankles is a worse shot than one met at the waist, and that is what stops the lift from
        // turning the game into a metronome.
        //
        // The first measured run with the lift in and nothing else changed produced a 59-shot
        // rally and two points in four minutes, because being out of position had stopped costing
        // anything: the racket simply went to wherever the ball was. Squared, so drifting half a
        // stretch off the waist is nearly free and full stretch costs a third of the shot. The
        // effect arrives through the existing `quality` machinery — less pace, and the aim pulled
        // back towards the middle of the court — so a stretched reply is a short weak one that
        // invites the next shot rather than a coin toss on whether the ball comes back at all.
        // Position decides how *good* the shot is, which is a better game than position deciding
        // whether there is a shot.
        let stretch = side.swing.lift >= 0
            ? side.swing.lift / Tuning.strikeLiftUp
            : -side.swing.lift / Tuning.strikeLiftDown
        let quality = max(0.30, (1 - timingError * 0.55) * (1 - 0.40 * stretch * stretch))

        var aim = side.swing.aim
        // A mistimed shot drifts towards the middle of the court rather than flying anywhere —
        // being late should cost you the corner, not hand you a winner. That is still true across
        // the court, and it is why the sideways pull stays where it was.
        //
        // **The pull towards the service line does not.** It was 0.35 and it was quietly
        // shortening every shot in the game by about half a metre — measured, the median ball was
        // aimed 9.3 m out and struck 8.7 m. That was the right safety net when `quality` could
        // only bleed pace, because a bad shot had to land somewhere sensible. Now that a bad shot
        // genuinely misses (see `mishit` below), aiming it safer *as well* is counting the same
        // mistake twice, and between them they made it impossible for any ball to reach the
        // baseline. A player meant to hit it deep; what they get is the error, not a different
        // plan.
        let drift = (1 - quality) * 1.4
        aim.x += (0 - aim.x) * drift * 0.6
        aim.y += (side.half * -Tennis3DCourt.halfLength * 0.55 - aim.y) * drift * 0.10

        // Alex hits softer on Easy and harder on Hard. Pace is time — a ball 10% slower is most
        // of a stride's worth of extra time to reach it, and reaching it is the whole game.
        let pace = side.isPlayer ? 1 : Tuning.npcPaceScale
        let baseSpeed = side.swing.isServe
            ? (faults == 0 ? Tuning.firstServeSpeed : Tuning.secondServeSpeed) * pace
            : Tuning.rallySpeed * pace
        let speed = baseSpeed * side.swing.power * (0.72 + 0.28 * quality)

        // **A shot struck badly enough now actually misses.** The serve is exempt: the server is
        // standing still and chose where the ball goes, so a mishit there is a double fault the
        // player did nothing to earn, and part 1 settled that the interesting decisions in this
        // game are on the return rather than the ball toss.
        //
        // Shaped so that **only a genuinely bad shot misses**. A flat `1 - quality` puts an error
        // on every ball in the game — the median quality is 0.70, so the typical rally shot would
        // carry a third of the maximum error and the game would read as random rather than as
        // demanding. Clean contact is exact; everything from a comfortable shot down to a
        // full-stretch scramble slides into it.
        let sloppy = max(0, (1 - quality) - Tuning.mishitThreshold) / (1 - Tuning.mishitThreshold)
        let mishit = side.swing.isServe
            ? 0
            : sloppy * (side.isPlayer ? Tuning.playerMishitScale : Tuning.npcMishitScale)

        launchBall(to: aim, speed: speed, topspin: side.swing.topspin, mishit: mishit)

        if side.swing.isServe {
            phase = .rally
            isServeInFlight = true
        }

        // The opponent needs a moment before it starts running, and a fresh dose of error. Its
        // anchor is pinned here too: from this instant until it plays the ball, "how far do I
        // have to move" is measured from where it was standing when the shot was struck.
        let other = side.isPlayer ? npc : player
        other.reactionDelay = Tuning.npcReaction
        other.anchor = (x: other.motor.x, y: other.motor.y)
        other.positionBias = (x: random.spread(Tuning.npcPositionError),
                              y: random.spread(Tuning.npcPositionError))

        let sound = side.isPlayer ? "/media/hit_tennis_ball.mp3" : "/media/hit_tennis_ball2.mp3"
        host.minigamePlayEffect(path: sound,
                                volume: 0.55 + quality * 0.45,
                                rate: 0.86 + quality * 0.26)

        let metre = Tennis3DCourt.unitsPerMetre
        trace(String(format: "STRIKE %@%@ at (%.1f, %.1f, %.1f)m quality=%.2f mishit=%.2f aim=(%.1f, %.1f)m",
                     side.isPlayer ? "you" : opponentName,
                     side.swing.isServe ? " serve" : (side.swing.isBackhand ? " backhand" : ""),
                     contact.x / metre, contact.y / metre, contact.z / metre,
                     quality, mishit, aim.x / metre, aim.y / metre))
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

        // Depth: deep by default, with the odd shorter one. Struck from a long way behind the
        // baseline, aim shorter and loop it — a defensive ball hit flat for the baseline mostly
        // goes long. See the note on `stretched` below.
        let stretched = abs(side.motor.y) > Tennis3DCourt.halfLength + Tennis3DCourt.metres(1.5)

        // **The player asked for a corner.** Their target wins outright — no away-from-Alex, no
        // slide nudge, no random depth. It is still only a request: `strike` drags a mistimed or
        // stretched shot back towards the middle, so choosing the line and then reaching for the
        // ball off balance gets you most of the way there and not all of it.
        if side.isPlayer, let aim = playerAim {
            return (aim: aim,
                    power: stretched ? 0.82 : 1.0,
                    topspin: stretched ? 0.62 : 0.42)
        }

        // Hit away from where the other player is standing. For the human this is automatic —
        // it is what a real player does without thinking, and there is no second thumb free to
        // aim with.
        //
        // How far off centre it is aimed is the single number that decides how long a rally
        // runs, and it is worth knowing how narrow the useful band is. Measured against the
        // `-tennis3ddemo` bot, which never misplaces its feet:
        //
        // | Range | What happened |
        // |---|---|
        // | 0.45–0.80 | mean rally 2.7 shots — a 3.3 m sprint on every ball, so the point was over by the third |
        // | 0.30–0.68 | rallies that never ended at all: two points in four minutes |
        // | 0.38–0.78 | what part 3 shipped |
        // | **0.42–0.86** | what is here |
        //
        // A person will end points a good deal sooner than the bot does, so erring towards the
        // longer rally is the right side to be on — but the whole table above was measured
        // against players who could not reach a ball above their own shoulder. Now that they can,
        // the same aim moves nobody, and it had to open up to keep ending points.
        // **Attacking a short ball.** How far inside your own baseline you are standing when you
        // hit it, from 0 on the baseline to 1 three metres in.
        //
        // Without this there is no way for a point to end. Once the racket could reach a high
        // ball, a measured match produced rallies of 19 and 9 shots and a point about every
        // ninety seconds, because every reply was struck from the same place with the same aim
        // whether the incoming ball was a rocket or a floating apology. Real tennis ends points
        // by moving somebody forward and then hitting past them, and the pieces for that were
        // already here: a stretched shot lands short, a short ball pulls the other player in, and
        // now being in has a payoff — a wider target and more pace on it. That is a whole rally
        // shape rather than a number, and it is why the counterweight goes here rather than into
        // making the strike zone smaller again.
        //
        // Measured from a stride and a half *inside* the line rather than from the line itself,
        // because that is where a rally is played from now — the intercept prefers an early ball
        // and the median contact sits at 8.5 m against an 11.9 m baseline. Zeroing it on the line
        // pinned `attack` at 1 for every ball of every rally, which is a flat pace bonus with a
        // misleading name rather than a reason to move somebody.
        // Part 5 moved this zero-point a stride and a half *inside* the line, because the median
        // contact then sat at 8.5 m against an 11.9 m baseline and measuring from the line pinned
        // `attack` at 1 for every ball of every rally — a flat pace bonus with a misleading name.
        //
        // It has since swung the whole way back. Measured over 69 shots this session the median
        // contact is at **11.1 m**, three-quarters of a metre inside the line and a good two and a
        // half metres further out than part 5 saw, because a deeper ball pushes the receiver back.
        // Against a zero-point at 10.4 m that pins `attack` at **0** instead, and the short-ball
        // attack — the pace bonus, the wider target, and now the deeper one — has been silently
        // inert. A mechanic that is always 0 is as broken as one that is always 1, and it is
        // harder to notice.
        //
        // Back on the line, then, with the full three metres to run over: the median ball is now
        // played at about 0.26 of it and a genuine short ball reaches 1.
        let insideBaseline = (Tennis3DCourt.halfLength - abs(side.motor.y))
            / Tennis3DCourt.metres(3.0)
        let attack = min(1, max(0, insideBaseline))

        // Alex's range is the difficulty setting's second real lever: pulled in on Easy so the
        // reply arrives near enough to stand still for, pushed towards the lines on Hard.
        let range = side.isPlayer ? (0.42, 0.86) : Tuning.npcAimRange
        let awayFromOpponent: Double = opponent.motor.x > 0 ? -1 : 1
        var aimX = awayFromOpponent * Tennis3DCourt.halfSingles
            * random.range(range.0, range.1 + 0.22 * attack)

        // Sliding across the court while you hit drags the ball with you, which gives the drag
        // control a second job: it steers the shot.
        let radians = side.motor.facing * .pi / 180
        let lateralSpeed = side.motor.vx * sin(radians) - side.motor.vy * cos(radians)
        aimX -= lateralSpeed / Tuning.playerTopSpeed * Tennis3DCourt.metres(2.4)
        aimX = min(max(aimX, -Tennis3DCourt.halfSingles + Tennis3DCourt.metres(0.5)),
                   Tennis3DCourt.halfSingles - Tennis3DCourt.metres(0.5))

        // Depth, from the `stretched` test above.
        //
        // The threshold was the baseline itself, and **every shot in the game qualified**: a
        // topspin ball is met a metre or two behind the line, which is where a baseline player
        // stands. So both players hit nothing but heavy defensive loops at each other. That is
        // what made the rallies short — a 0.85-topspin ball dives, bounces steeply, sits up to
        // 1.6 m and carries ten metres past the bounce, which is well past the back fence, so
        // the point ended with somebody pinned against it watching the ball go over their head.
        // Being properly stretched is a metre and a half further back than that.
        // **And how near the baseline a confident shot is allowed to go.**
        //
        // 0.58–0.82 of a half-court is 6.9 to 9.7 m from the net against an 11.9 m baseline, so
        // even the deepest ball in the game landed with two metres to spare. Measured across 228
        // shots: the median ball landed 4.3 m inside the line and the worst-struck one in the
        // whole sample missed its target by 1.5 m. **Nothing could go out because nothing was
        // ever aimed near enough to the line to.** That is the real reason five sessions of
        // measurement never saw a single ball land long, and no amount of scaling up the mishit
        // fixes it — a shot aimed at the service line does not go out, it just lands short.
        //
        // So depth is the other half of the risk: standing in and hitting through the ball aims
        // it nearer the line, where a mishit costs a point. `attack` is already "how far inside
        // your own baseline you are", so the reward for good position and the risk that comes
        // with it are the same number.
        // The margin to the baseline has to be the same size as the mishit for the mishit to mean
        // anything, and it took three measured passes to get there:
        //
        // | Depth | Median aim | Deepest aim | Balls landing out |
        // |---|---|---|---|
        // | 0.58–0.82, what part 5 shipped | 7.6 m | 9.4 m | none in 228 |
        // | 0.60–0.84 | 8.7 m | 9.8 m | none in 116 |
        // | 0.68–0.88, with the drift fix | 9.1 m | 10.2 m | none in 69 |
        // | 0.72–0.92 + 0.08 attack | 9.55 m | 10.7 m | none in 68, but 6 within a metre |
        // | **0.76–0.96 + 0.10 attack** | ⏳ | ⏳ | ⏳ |
        //
        // The last of those got the deepest ball to 11.5 m — 0.4 m from the line — and still
        // nothing out, because landing long needs a deep aim *and* a bad strike at the same time
        // and each is only a tail. Measured over 186 shots the two are satisfyingly independent
        // (median aim 9.3 m in every mishit bucket), the worst strikes miss by ±2.3 m, and the
        // sum lands about one and a half standard deviations short of the line. Hence a move on
        // both levers at once rather than a fourth nibble at one of them: this depth, and a
        // bigger `mishitPace`/`mishitLoft` to go with it.
        let depth = stretched
            ? random.range(0.46, 0.64)
            : random.range(0.76, 0.96) + 0.10 * attack
        let aimY = targetHalf * Tennis3DCourt.halfLength * depth

        return (aim: (x: aimX, y: aimY),
                // Standing in, you can hit through the ball. Standing out, you cannot.
                power: stretched ? 0.82 : random.range(0.92, 1.05) * (1 + 0.14 * attack),
                // Enough spin to bring a hard ball down inside the baseline, not so much that it
                // kicks over the receiver's shoulder. See the note on `stretched` above.
                topspin: stretched ? 0.62 : random.range(0.30, 0.52))
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
                    let feet = stance(toMeet: meeting, for: npc)
                    npc.moveTarget = (
                        x: feet.x + npc.positionBias.x,
                        y: min(-Tennis3DCourt.metres(1.0), feet.y + npc.positionBias.y)
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
                // A metre and a bit behind it, which is where the reply will be at racket height
                // — recovering onto the line itself means walking backwards again immediately.
                npc.moveTarget = (x: 0, y: -Tennis3DCourt.halfLength - Tennis3DCourt.metres(1.2))
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
    /// position and there is time to get back. Both cases fall out of what the motor is told to
    /// face, and the legs follow automatically.
    ///
    /// What is left here after the motor took over is the *tennis*: who may move, which way they
    /// look, and where the fence is. The acceleration, the braking, the turn, the arrival easing
    /// and the velocity a fence sheds are all `CharacterMotor`'s, and identical to the
    /// overworld's.
    private func run(_ side: Side, dt: Double, profile: LocomotionProfile) {
        side.motor.profile = profile

        // A server stands still from the moment they take the ball until they have struck it.
        // Not stagecraft — a requirement. `tossBall` solves the toss backwards from where the
        // strings will be, given where the server is standing *at the moment of the toss*, so a
        // server who drifts even half a metre swings through thin air. Both sides were losing
        // serves to it; the opponent lost every one.
        let isServing = (phase == .ready || phase == .toss) && side === server
        if isServing { side.motor.holdPosition() }

        let distance = side.motor.distanceToDestination

        // Face the net by default. 270° points at −Y for the near player, 90° at +Y for the
        // far one.
        let netFacing: Double = side.isPlayer ? 270 : 90
        var facing: Double? = netFacing

        // A long run with time to make it: turn and sprint properly rather than shuffling.
        let ballIsClose = ball.inFlight
            && abs(ball.y - side.motor.y) < Tennis3DCourt.metres(7)
        if distance > Tennis3DCourt.metres(3.0) && !ballIsClose && !side.swing.isSwinging {
            facing = nil
        }
        // Mid-swing the feet are planted; nothing turns the body but the stroke.
        if side.swing.isSwinging { facing = netFacing }
        side.motor.faceTowards(facing)

        // The court fence, and the net, as the world's veto on the move. The motor commits
        // whatever comes back and sheds the blocked velocity into it, so a player pinned against
        // the fence stops there instead of storing up speed to fire sideways on release.
        side.motor.stepBody(dt: dt) { proposedX, proposedY in
            let clampedX = min(max(proposedX, -Tennis3DCourt.playableHalfWidth),
                               Tennis3DCourt.playableHalfWidth)
            let netKeepOut = Tennis3DCourt.metres(0.5)
            let clampedY = side.isPlayer
                ? min(max(proposedY, netKeepOut), Tennis3DCourt.playableHalfLength)
                : min(max(proposedY, -Tennis3DCourt.playableHalfLength), -netKeepOut)
            return (x: clampedX, y: clampedY)
        }
    }
}
