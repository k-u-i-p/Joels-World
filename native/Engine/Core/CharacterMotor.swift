import Foundation
import simd

/// **Everything that moves about a character, in one place.**
///
/// Before this there were three separate ways a character could be moved and each one kept its
/// own bookkeeping. `GameState` assembled a `LocomotionState` out of loose fields on `Player`
/// every frame and unpacked it again afterwards. `PhysicsEngine.processInterpolation` walked
/// remote players and NPCs through positions and kept an `ObservedMotion` beside them.
/// `Tennis3DGame` held a `LocomotionState` per side, clamped the court by hand, and posed the
/// racket arm by writing limb targets straight into `RigMutation` — tracking, in the process,
/// its own copy of where the hand had been last sub-step so it could work out how fast it was
/// going. Three sets of state, three sets of bugs, and no shared idea of what a character is
/// doing.
///
/// A `CharacterMotor` owns all of it for one character: **position, height, velocity, heading,
/// gait, and every limb**. It is the only thing in the game allowed to move a limb, and the only
/// thing that tracks a velocity.
///
/// ## Asking it for things
///
/// Everything is a *request*, and the motor makes a best effort:
///
/// ```swift
/// motor.moveCharacterTo(x: 400, y: 120, targetSpeed: 180)   // go there
/// motor.driveCharacter(velocityX: vx, velocityY: vy)        // or: go this way, this fast
/// motor.faceTowards(270)                                    // keep your chest to the net
/// motor.jump(speed: 260)                                    // leave the ground
/// motor.moveHandTo(.rightHand, local: contactPose)          // put your hand there
/// motor.step(dt: dt, constrain: walls)                      // one frame of all of it
/// ```
///
/// Nothing here is a command that always succeeds. A wall eats the movement; a target outside
/// the arm's reach is clamped and the shortfall shows up as `strain(of:)`; a jump while already
/// airborne is ignored. What comes back out — `x`, `y`, `z`, `gait`, `hand(_:)` — is what
/// actually happened, which is the only thing worth drawing.
///
/// ## Frames
///
/// Body position is **world space, Y-down**, and `facing` is degrees with 0° = +X increasing
/// clockwise, the same as `GameCharacter.rotation`. Limb positions are in the **rig's local
/// frame**: +X forward, +Y the character's left, +Z up, origin at the body pivot 15.5 units off
/// the ground. `localToWorld(_:)` converts. Getting these two confused is the source of every
/// "the animation is mirrored" bug this system has ever had, and `LocomotionSelfTest` pins the
/// signs.
final class CharacterMotor {

    // MARK: - Body

    /// Tuning for the ground movement: top speed, how hard it can accelerate and brake, how
    /// fast it can turn, and how far a stride covers.
    var profile: LocomotionProfile

    /// Position, velocity, heading and gait. Read-only from outside — everything that changes it
    /// goes through a request and a `step`.
    private(set) var body = LocomotionState()

    /// Height off the ground. Real, integrated, and the thing `GameCharacter.z` is drawn at.
    private(set) var z: Double = 0
    /// Vertical velocity, world units per second, positive up.
    private(set) var verticalVelocity: Double = 0
    /// The ground under this character. A minigame with a raised court moves it.
    var groundZ: Double = 0
    /// World units per second squared. 900 is a little heavier than earth at this scale, which
    /// is what keeps a jump from hanging.
    var gravity: Double = 900
    private(set) var isAirborne = false

    var x: Double { body.x }
    var y: Double { body.y }
    var vx: Double { body.vx }
    var vy: Double { body.vy }
    var facing: Double { body.facing }
    var speed: Double { body.speed }
    var gait: Gait { body.gait }

    // MARK: - Intent

    /// What the controller is asking the body to do. One of three things, and never a mixture:
    /// a destination to walk to, a velocity to hold, or nothing at all.
    enum Steering {
        /// Brake to a stop and stay there.
        case idle
        /// Hold this world-space velocity. What a thumbstick produces.
        case velocity(x: Double, y: Double)
        /// Walk to this point and stop on it, easing off on the approach. What a tap on a
        /// tennis court, an NPC waypoint or an AI decision produces.
        case destination(x: Double, y: Double, speed: Double)
    }

    private(set) var steering: Steering = .idle

    /// A heading to hold regardless of which way the body is travelling, in degrees. Nil faces
    /// the direction of travel. This is the switch that turns a run into a side-step: tennis
    /// pins it to the net so a player back-pedals instead of turning their back on the ball.
    private(set) var facingIntent: Double?

    /// How close counts as arrived, and how hard the approach eases off. The defaults suit a
    /// character the size of a school pupil; a minigame working in metres sets its own.
    var arrivalRadius: Double = 4
    var arrivalGain: Double = 4.5

    // MARK: - Limbs

    private var limbs: [Limb: LimbState]

    // MARK: - Observed movers

    /// Set for a character this client does not drive. Its position arrives from somewhere else
    /// — the server, or an interpolator walking it to a waypoint — and the velocity and gait are
    /// read back out of it rather than produced.
    private(set) var isObserved = false
    private var observation = ObservedMotion()

    // MARK: - Lifecycle

    init(profile: LocomotionProfile = .player) {
        self.profile = profile
        var built: [Limb: LimbState] = [:]
        for limb in Limb.allCases {
            built[limb] = LimbState(limb: limb, profile: limb.isHand ? .arm : .leg)
        }
        limbs = built
    }

    /// Puts the character somewhere with no travel in between: a spawn, a map change, a serve
    /// mark, a server-side teleport. Everything carried between frames is dropped, because a
    /// jump across the map is not a stride — feed one in and the torso throws itself flat on its
    /// face at four thousand units a second.
    func teleport(x: Double, y: Double, z: Double = 0, facing: Double? = nil) {
        body.teleport(x: x, y: y, facing: facing ?? body.facing)
        self.z = z
        verticalVelocity = 0
        isAirborne = false
        steering = .idle
        observation.reset()
        for limb in Limb.allCases { limbs[limb]?.reset() }
    }

    // MARK: - Asking the body for things

    /// **Go and stand there.** The headline call.
    ///
    /// - Parameters:
    ///   - x/y: where, in world space.
    ///   - targetSpeed: how fast to get there, capped by the profile's top speed. Nil is flat
    ///     out. The motor eases off inside `arrivalRadius` rather than skidding past the mark
    ///     and coming back.
    ///   - facing: a heading to hold while doing it, in degrees. Nil faces the way it is going.
    func moveCharacterTo(x: Double, y: Double, targetSpeed: Double? = nil, facing: Double? = nil) {
        steering = .destination(x: x, y: y, speed: targetSpeed ?? profile.maxSpeed)
        facingIntent = facing
    }

    /// **Go this way, this fast.** What a thumbstick means. Given in world units per second, so
    /// a caller that wants "full tilt north" passes `(0, -profile.maxSpeed)`.
    func driveCharacter(velocityX: Double, velocityY: Double, facing: Double? = nil) {
        steering = .velocity(x: velocityX, y: velocityY)
        facingIntent = facing
    }

    /// Stop asking for anything. The character brakes to a halt where it is and finishes the
    /// step it is mid-way through rather than freezing on one leg.
    func holdPosition() {
        steering = .idle
        facingIntent = nil
    }

    /// Hold a heading without changing what the body is being asked to do.
    func faceTowards(_ degrees: Double?) {
        facingIntent = degrees
    }

    /// Sets the heading outright, with no turn. For tank controls, where the *input* aims the
    /// body directly and there is nothing to ease towards.
    func setFacing(_ degrees: Double) {
        body.facing = Locomotion.normalize(degrees)
    }

    /// Where the body is being sent, if anywhere.
    var destination: (x: Double, y: Double)? {
        guard case let .destination(x, y, _) = steering else { return nil }
        return (x, y)
    }

    /// How far there is left to go. Infinite when nothing is being asked for.
    var distanceToDestination: Double {
        guard let destination else { return .infinity }
        return hypot(destination.x - body.x, destination.y - body.y)
    }

    /// On the mark **and stopped**. Both halves matter: a character still drifting onto its mark
    /// is not standing on it, and anything solved from where they are standing — a tennis serve,
    /// most obviously — gets the wrong answer if it starts a moment early.
    func hasArrived(within tolerance: Double? = nil) -> Bool {
        let radius = tolerance ?? arrivalRadius
        guard body.speed < max(radius * 2, 1) else { return false }
        guard let destination else { return true }
        return hypot(destination.x - body.x, destination.y - body.y) <= radius
    }

    /// **Leave the ground.** Ignored if the feet are not on it, which is what stops a held
    /// button from flying.
    ///
    /// - Parameter speed: initial upward velocity, world units per second. Against the default
    ///   gravity of 900, 260 is about a 37-unit hop lasting a little under 0.6 s.
    @discardableResult
    func jump(speed: Double = 260) -> Bool {
        guard !isAirborne, z <= groundZ + 0.001 else { return false }
        verticalVelocity = speed
        isAirborne = true
        return true
    }

    /// Puts the character on the ground at a given height without a jump — a minigame raising
    /// its court, or a lift.
    func setGround(_ height: Double) {
        groundZ = height
        if !isAirborne { z = height }
    }

    // MARK: - Asking a limb for things

    /// **Put that hand there.** The limb equivalent of `moveCharacterTo`, and the reason no
    /// other file in the game writes a limb target any more.
    ///
    /// `local` is in the rig's own frame: +X forward, +Y the character's left, +Z up, measured
    /// from the body pivot. The motor works out whether the arm can reach it, moves the hand
    /// there under its own acceleration and speed limits, and hands the result to the rig. An
    /// ask outside the arm's reach is clamped rather than refused, and how far outside shows up
    /// as `strain(of:)` — so a caller that cares can tell the difference between "the hand is on
    /// its way" and "that was never going to happen".
    ///
    /// - Parameter speed: overrides the limb's top speed for this and every later ask. A swing
    ///   wants a fast hand; a wave does not.
    func moveHandTo(_ limb: Limb, local: SIMD3<Float>, speed: Float? = nil) {
        limbs[limb]?.drive(to: local, speed: speed)
    }

    /// The same for a foot. Identical machinery — a foot is an IK endpoint like any other — and
    /// separate only because "move the character's hand to the ball" and "plant the character's
    /// foot on that step" are different enough sentences to deserve different names.
    func moveFootTo(_ limb: Limb, local: SIMD3<Float>, speed: Float? = nil) {
        limbs[limb]?.drive(to: local, speed: speed)
    }

    /// Hands a limb back to the rig's own animation — the walk cycle, the idle sway, whatever
    /// emote is running. Eased over `LimbProfile.releaseTime`, so a hand that was holding a pose
    /// rejoins the walk rather than snapping into it.
    func releaseLimb(_ limb: Limb) {
        limbs[limb]?.release()
    }

    func releaseAllLimbs() {
        for limb in Limb.allCases { limbs[limb]?.release() }
    }

    /// Where a limb actually is, in the rig's local frame. **Not** where it was asked to be:
    /// this is the position after the reach clamp and after the limb's own inertia, which is
    /// where a racket, a ball or a handshake really meets it.
    func limbPosition(_ limb: Limb) -> SIMD3<Float> {
        limbs[limb]?.position ?? limb.neutral
    }

    /// How fast a limb is travelling, local units per second. The thing every minigame used to
    /// work out for itself by remembering last frame.
    func limbVelocity(_ limb: Limb) -> SIMD3<Float> {
        limbs[limb]?.velocity ?? .zero
    }

    /// How far outside its reach the last ask for this limb was. Zero when it was reachable.
    func strain(of limb: Limb) -> Float {
        limbs[limb]?.strain ?? 0
    }

    /// Has the limb got to where it was sent?
    func limbHasArrived(_ limb: Limb, within tolerance: Float = 0.6) -> Bool {
        limbs[limb]?.hasArrived(within: tolerance) ?? true
    }

    func isDriving(_ limb: Limb) -> Bool {
        limbs[limb]?.isDriven ?? false
    }

    /// Tuning for one limb, for a caller that wants a heavier or faster arm than the default.
    func setLimbProfile(_ limb: Limb, _ profile: LimbProfile) {
        limbs[limb]?.profile = profile
    }

    // MARK: - The frame

    /// What one step of the body actually did.
    struct StepResult {
        /// The movement the motor asked the world for.
        var demanded: SIMD2<Double>
        /// What it got. Different from `demanded` when something was in the way.
        var accepted: SIMD2<Double>
        /// True when the two differ by enough to matter — a wall, a fence, a court edge.
        var blocked: Bool
        /// True on the frame the feet touch down after a jump.
        var landed: Bool
    }

    /// **One frame of everything.** Body, height, and every limb.
    ///
    /// - Parameter constrain: the world's veto. It is handed the position the motor would like
    ///   to move to and returns the one it is allowed — a wall test, a court fence, a clamp.
    ///   Whatever comes back is committed *and fed back into the velocity*, so a character
    ///   shoved into a wall sheds its speed into it instead of storing it up and firing sideways
    ///   the moment it turns away. Nil accepts the demand as-is.
    @discardableResult
    func step(dt: Double,
              constrain: ((_ proposedX: Double, _ proposedY: Double) -> (x: Double, y: Double))? = nil)
        -> StepResult {
        let result = stepBody(dt: dt, constrain: constrain)
        stepLimbs(dt: dt)
        return result
    }

    /// The body and its height, without the limbs.
    ///
    /// Split out because a minigame running its physics on a fixed sub-step wants the limbs
    /// stepped at that rate — a racket head crossing a ball in four milliseconds is the whole
    /// contact test — while steering the body once a frame is plenty.
    @discardableResult
    func stepBody(dt: Double,
                  constrain: ((_ proposedX: Double, _ proposedY: Double) -> (x: Double, y: Double))? = nil)
        -> StepResult {
        guard dt > 0 else {
            return StepResult(demanded: .zero, accepted: .zero, blocked: false, landed: false)
        }

        var desired = (x: 0.0, y: 0.0)
        switch steering {
        case .idle:
            break
        case let .velocity(vx, vy):
            desired = (vx, vy)
        case let .destination(targetX, targetY, requestedSpeed):
            let dx = targetX - body.x
            let dy = targetY - body.y
            let distance = hypot(dx, dy)
            if distance > arrivalRadius {
                // Ease off on the approach. Without this a character overshoots its mark and
                // has to come back, which is the tell of a steering system that only knows
                // "go" and "stop".
                let top = min(requestedSpeed, profile.maxSpeed)
                let approach = min(top, distance * arrivalGain)
                desired = (dx / distance * approach, dy / distance * approach)
            }
        }

        let demand = Locomotion.step(&body,
                                     desired: desired,
                                     facingIntent: facingIntent,
                                     profile: profile,
                                     dt: dt)

        let proposedX = body.x + demand.dx
        let proposedY = body.y + demand.dy
        let allowed = constrain?(proposedX, proposedY) ?? (x: proposedX, y: proposedY)
        let actualDx = allowed.x - body.x
        let actualDy = allowed.y - body.y
        Locomotion.commit(&body, actualDx: actualDx, actualDy: actualDy, dt: dt)

        let landed = stepVertical(dt: dt)

        let blocked = abs(actualDx - demand.dx) > 0.01 || abs(actualDy - demand.dy) > 0.01
        return StepResult(demanded: SIMD2(demand.dx, demand.dy),
                          accepted: SIMD2(actualDx, actualDy),
                          blocked: blocked,
                          landed: landed)
    }

    /// Every limb, one step. Safe to call at a different rate from the body.
    func stepLimbs(dt: Double) {
        guard dt > 0 else { return }
        for limb in Limb.allCases { limbs[limb]?.step(dt: dt) }
    }

    /// Gravity and the ground. Returns true on the frame the feet touch down.
    private func stepVertical(dt: Double) -> Bool {
        guard isAirborne || z > groundZ + 1e-6 else {
            z = groundZ
            verticalVelocity = 0
            return false
        }
        // The exact parabola, not Euler's approximation to it: `v·dt − ½g·dt²` is what a
        // constant acceleration actually integrates to over a step. Plain semi-implicit Euler
        // loses ½g·dt² of height *every frame*, which came to 1.25 units off a 30-unit jump at
        // 60 Hz — and, worse, a different number at 120 Hz. Deterministic animation means the
        // same jump whatever the display is doing.
        z += verticalVelocity * dt - 0.5 * gravity * dt * dt
        verticalVelocity -= gravity * dt
        guard z <= groundZ else { return false }
        z = groundZ
        verticalVelocity = 0
        isAirborne = false
        return true
    }

    // MARK: - Characters this client does not drive

    /// **Read the movement back out of positions somebody else decided.**
    ///
    /// A remote player's position comes off the wire and an interpolator eases towards it; an
    /// NPC's comes from a waypoint and the same interpolator walks there. Nothing in either path
    /// ever forms a velocity, which is why every character but the local player used to be stuck
    /// with a forward-only walk whichever way it was actually travelling. Differentiating the
    /// position gives the velocity back and the gait falls out of it, so a patrolling NPC whose
    /// waypoint rotation faces down the corridor genuinely side-steps across it.
    ///
    /// Call it every frame, including frames where the character did not move — that is what
    /// lets the stride finish its step and settle instead of creeping.
    func observe(x: Double, y: Double, z: Double, facing: Double, dt: Double) {
        isObserved = true
        let dx = x - body.x
        let dy = y - body.y
        body.x = x
        body.y = y
        body.facing = facing
        self.z = z

        guard dt > 0 else { return }
        Locomotion.observe(&observation, dx: dx, dy: dy, facing: facing,
                           profile: .observed, dt: dt)
        body.vx = observation.vx
        body.vy = observation.vy
        body.gait = observation.gait
        stepLimbs(dt: dt)
    }

    // MARK: - Posing

    /// True when at least one limb is being driven or is still handing back.
    var isPosingLimbs: Bool {
        Limb.allCases.contains { limbs[$0]?.isEngaged == true || limbs[$0]?.isDriven == true }
    }

    /// **The rig's last word on the pose**, or nil when there is nothing to say.
    ///
    /// Handed to `CharacterRig.pose` as its `override`, which runs after the walk cycle and
    /// after any emote — so a driven hand wins, an undriven one keeps whatever the walk or the
    /// emote gave it, and a limb being released crossfades between the two. `extra` composes on
    /// top for the things that are not limbs: a shoulder coil, the roll of a racket face.
    ///
    /// It is returned even when nothing is being driven, and that is deliberate: the read-back
    /// below is how the motor knows where the walk cycle has left a hand, and it has to have
    /// been watching *before* a minigame asks for that hand or the first frame of the ask starts
    /// from stale data. The cost when idle is four vector reads.
    func poseOverride(then extra: RigOverride? = nil) -> RigOverride? {
        { [self] mutation in
            applyLimbs(to: &mutation)
            extra?(&mutation)
        }
    }

    /// Mixes each limb into the pose, and — for limbs it is not driving — reads the rig's own
    /// animation back in.
    ///
    /// That read-back is the piece that makes engaging seamless. A hand that has spent the last
    /// minute in the walk cycle is somewhere the motor has never been told about; without
    /// tracking it, the first frame of a swing would start the hand from wherever it was left
    /// and whip it across the body. Tracking it costs nothing and means `moveHandTo` always
    /// begins from where the hand visibly is.
    private func applyLimbs(to mutation: inout RigMutation) {
        for limb in Limb.allCases {
            guard var state = limbs[limb] else { continue }
            let rigPose = mutation[limb]
            state.observeRigPose(rigPose)
            if state.isEngaged {
                mutation[limb] = simd_mix(rigPose, state.position, SIMD3(repeating: state.blend))
            }
            limbs[limb] = state
        }
    }

    // MARK: - Frames

    /// Turns a point in the character's own frame into world space, Y-down. The rig's body pivot
    /// stands 15.5 units off the ground and that offset is folded in, so a caller can write
    /// shoulder and hand positions straight out of `CharacterRig`.
    func localToWorld(_ local: SIMD3<Double>) -> SIMD3<Double> {
        let radians = body.facing * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return SIMD3(body.x + local.x * cosine + local.y * sine,
                     body.y + local.x * sine - local.y * cosine,
                     z + local.z + Double(CharacterRig.bodyPivotHeight))
    }

    func localToWorld(_ local: SIMD3<Float>) -> SIMD3<Double> {
        localToWorld(SIMD3(Double(local.x), Double(local.y), Double(local.z)))
    }

    /// The ground-plane half of the same rotation: a local offset in world XY, with no position
    /// added. What a caller needs to answer "if my hand is here relative to me, where do my feet
    /// have to be for it to land there?".
    func localOffsetInWorld(_ local: SIMD2<Double>, facing: Double? = nil) -> SIMD2<Double> {
        let radians = (facing ?? body.facing) * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        return SIMD2(local.x * cosine + local.y * sine,
                     local.x * sine - local.y * cosine)
    }
}

private extension RigMutation {
    /// The limb targets, by `Limb`, so the motor can loop over them instead of writing the same
    /// four lines out four times.
    subscript(limb: Limb) -> SIMD3<Float> {
        get {
            switch limb {
            case .leftHand: return leftHandTarget
            case .rightHand: return rightHandTarget
            case .leftFoot: return leftFootTarget
            case .rightFoot: return rightFootTarget
            }
        }
        set {
            switch limb {
            case .leftHand: leftHandTarget = newValue
            case .rightHand: rightHandTarget = newValue
            case .leftFoot: leftFootTarget = newValue
            case .rightFoot: rightFootTarget = newValue
            }
        }
    }
}
