import Foundation

/// How a character's legs should be moving this frame.
///
/// The rig used to be told one number — `legAnimationTime`, a phase that only ever produced a
/// forward walk. That is why every character in the game turns on the spot and then walks
/// straight ahead: there was nowhere to say "this one is moving sideways". `Gait` is that
/// somewhere. `forward` and `lateral` are the velocity resolved into the character's **own**
/// frame, so a body running left while facing the net comes out as a side-step.
///
/// The frame is the rig's: local **+X is forward**, local **+Y is the character's left**
/// (`CharacterRig.leftHip` sits at y = −6, which is the mirror of what the names suggest — see
/// the note in `Locomotion.resolve`), local **+Z is up**.
struct Gait {
    /// Stride phase in radians. One full 2π cycle is a left step and a right step.
    var phase: Double = 0
    /// Velocity along local +X, as a fraction of top speed. Negative is backpedalling.
    var forward: Double = 0
    /// Velocity along local +Y, as a fraction of top speed. Non-zero means side-stepping.
    var lateral: Double = 0
    /// 0 standing, 1 flat out. Scales the whole stride so a walk is not a sprint.
    var intensity: Double = 0
    /// Forward acceleration as a fraction of what the legs can produce, smoothed. Leans the
    /// torso into a sprint start and back out of a skid.
    var leanForward: Double = 0
    /// Sideways acceleration, same units. Banks the body into a change of direction.
    var leanLateral: Double = 0

    /// A character standing still.
    static let still = Gait()

    /// The pre-`Gait` behaviour: a plain forward walk at a given phase, which is what every
    /// caller that still passes `legAnimationTime` gets.
    static func walking(phase: Double) -> Gait {
        guard phase > 0 else { return .still }
        return Gait(phase: phase, forward: 1, lateral: 0, intensity: 1)
    }

    var isMoving: Bool { intensity > 0.01 }
}

/// Tuning for one kind of mover. Speeds are world units per second.
struct LocomotionProfile {
    var maxSpeed: Double
    /// How hard the legs can push. A low number is a heavy, floaty character; a high one is
    /// arcade-instant.
    var acceleration: Double
    /// How hard they can stop. Higher than `acceleration` for anything that should feel
    /// planted rather than skiddy.
    var braking: Double
    /// Degrees per second the body can re-aim. This is what produces the side-step: while the
    /// body is still coming round, the velocity is off to one side of the facing, and the gait
    /// says so.
    var turnRate: Double
    /// World units covered per full 2π stride cycle — two footfalls.
    var strideLength: Double
    /// How much acceleration tilts the torso. 0 disables the lean.
    var lean: Double = 1

    /// The overworld player. `Player.moveSpeed` is 3 units per 1/60 s frame in the old
    /// per-frame formulation, which is 180 units a second.
    static let player = LocomotionProfile(maxSpeed: 180,
                                          acceleration: 900,
                                          braking: 1400,
                                          turnRate: 540,
                                          strideLength: 62)

    /// Running flat out costs the same acceleration but reaches further.
    static let playerRunning = LocomotionProfile(maxSpeed: 216,
                                                 acceleration: 1000,
                                                 braking: 1400,
                                                 turnRate: 480,
                                                 strideLength: 72)
}

/// Position, velocity and heading for one mover.
struct LocomotionState {
    /// World space, Y-down.
    var x: Double = 0
    var y: Double = 0
    var vx: Double = 0
    var vy: Double = 0
    /// Degrees, 0° = +X, increasing clockwise — the same convention as `GameCharacter.rotation`.
    var facing: Double = 0
    var gait = Gait()

    var speed: Double { (vx * vx + vy * vy).squareRoot() }

    mutating func teleport(x: Double, y: Double, facing: Double) {
        self.x = x
        self.y = y
        self.facing = facing
        vx = 0
        vy = 0
        gait = .still
    }
}

/// Inertial ground movement, shared by the overworld player and the tennis players.
///
/// Deliberately knows nothing about walls: it produces a *demanded* delta, and the caller
/// decides what the world does with it (`PhysicsEngine.processMovement` for the overworld, a
/// court-bounds clamp for tennis). Feed the accepted delta back through
/// `commit(_:actualDx:actualDy:)` so a character shoved into a wall stops rather than running
/// on the spot with a velocity it is not using.
enum Locomotion {

    /// Steps one mover a frame towards `desired` and returns the movement it demands.
    ///
    /// - Parameters:
    ///   - desired: velocity the controller is asking for, in world units per second. Zero
    ///     means "stop", which brakes rather than snapping to a halt.
    ///   - facingIntent: a heading, in degrees, to turn towards regardless of travel. Tennis
    ///     passes "face the net" so the player back-pedals and side-steps instead of turning
    ///     their back on the ball. `nil` faces the direction of travel.
    static func step(_ state: inout LocomotionState,
                     desired: (x: Double, y: Double),
                     facingIntent: Double?,
                     profile: LocomotionProfile,
                     dt: Double) -> (dx: Double, dy: Double) {
        guard dt > 0 else { return (0, 0) }

        // --- Velocity: chase the demand, at a bounded rate ---
        var demandX = desired.x
        var demandY = desired.y
        let demandSpeed = (demandX * demandX + demandY * demandY).squareRoot()
        if demandSpeed > profile.maxSpeed {
            demandX = demandX / demandSpeed * profile.maxSpeed
            demandY = demandY / demandSpeed * profile.maxSpeed
        }

        let deltaX = demandX - state.vx
        let deltaY = demandY - state.vy
        let deltaLength = (deltaX * deltaX + deltaY * deltaY).squareRoot()

        // Slowing down is a different muscle from speeding up, and a mover asked to stop uses
        // the stronger one — which is what stops a released stick from feeling like ice.
        let rate = demandSpeed < 1 ? profile.braking : profile.acceleration
        let maxChange = rate * dt

        var accelX: Double = 0
        var accelY: Double = 0
        if deltaLength > 1e-6 {
            let applied = min(maxChange, deltaLength)
            accelX = deltaX / deltaLength * applied
            accelY = deltaY / deltaLength * applied
            state.vx += accelX
            state.vy += accelY
        }

        // Numerically, a velocity chasing zero never quite arrives; park it so `isMoving` and
        // the stride both settle.
        if demandSpeed < 1 && state.speed < 1 {
            state.vx = 0
            state.vy = 0
        }

        // --- Heading: turn towards the intent, at a bounded rate ---
        let speed = state.speed
        let travelHeading = speed > 1 ? atan2(state.vy, state.vx) * 180 / .pi : state.facing
        let targetFacing = facingIntent ?? travelHeading
        state.facing = turn(state.facing, towards: targetFacing, limit: profile.turnRate * dt)

        // --- Resolve into the body's own frame ---
        resolve(&state, accelX: accelX / dt, accelY: accelY / dt, profile: profile, dt: dt)

        return (dx: state.vx * dt, dy: state.vy * dt)
    }

    /// Writes back what the world actually allowed. A delta the caller clipped — a wall, the
    /// court fence — kills the velocity along the direction that was blocked, so the character
    /// stops dead against it instead of sliding along holding a full head of steam.
    static func commit(_ state: inout LocomotionState, actualDx: Double, actualDy: Double, dt: Double) {
        guard dt > 0 else { return }
        state.x += actualDx
        state.y += actualDy
        state.vx = actualDx / dt
        state.vy = actualDy / dt
    }

    /// Turns `current` towards `target` by at most `limit` degrees, the short way round.
    static func turn(_ current: Double, towards target: Double, limit: Double) -> Double {
        let difference = ((target - current) + 540).truncatingRemainder(dividingBy: 360) - 180
        if abs(difference) <= limit { return normalize(target) }
        return normalize(current + (difference < 0 ? -limit : limit))
    }

    static func normalize(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    // MARK: - Gait

    /// Splits the world-space velocity and acceleration into the character's own axes, and
    /// advances the stride by the distance actually covered.
    ///
    /// Local +Y is the character's **left** in world terms. The mesh group applies
    /// `rotationZ(-rotation)` and render space negates Y, so local (0, 1) lands on world
    /// (sin θ, −cos θ) — the negation of the world right vector (−sin θ, cos θ).
    ///
    /// Worth knowing because the rig's own naming runs the other way: `leftHip` sits at local
    /// y = −6, which by that mapping is on the character's *right*. Nothing downstream cares —
    /// the body is symmetric — but `Gait.lateral` is defined against the **axis**, not against
    /// either limb's name, so it stays unambiguous.
    private static func resolve(_ state: inout LocomotionState,
                                accelX: Double, accelY: Double,
                                profile: LocomotionProfile,
                                dt: Double) {
        let radians = state.facing * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)

        let forward = state.vx * cosine + state.vy * sine
        let lateral = state.vx * sine - state.vy * cosine

        let speed = state.speed
        let top = max(profile.maxSpeed, 1)

        state.gait.forward = clamp(forward / top, -1.4, 1.4)
        state.gait.lateral = clamp(lateral / top, -1.4, 1.4)
        state.gait.intensity = clamp(speed / top, 0, 1.4)

        // Stride advances with ground covered, not with time, so a character easing to a halt
        // takes shorter and shorter steps instead of moonwalking.
        if speed > 1 {
            let distance = speed * dt
            state.gait.phase += distance / max(profile.strideLength, 1) * 2 * .pi
            if state.gait.phase > .pi * 4 { state.gait.phase -= .pi * 4 }
        } else if state.gait.phase != 0 {
            // Finish the step rather than snapping mid-stride, which is the one thing the old
            // `convergePhysics` got right and worth keeping.
            let remainder = state.gait.phase.truncatingRemainder(dividingBy: .pi)
            if remainder > 0.15 && remainder < .pi - 0.15 {
                state.gait.phase += (.pi * 6) * dt
            } else {
                state.gait.phase = 0
            }
        }

        // Lean follows acceleration, smoothed hard — raw frame-to-frame acceleration is far too
        // noisy to drive a torso with.
        let accelForward = accelX * cosine + accelY * sine
        let accelLateral = accelX * sine - accelY * cosine
        let reference = max(profile.acceleration, 1)
        let smoothing = min(1, dt * 8)
        state.gait.leanForward += (clamp(accelForward / reference, -1, 1) * profile.lean
                                   - state.gait.leanForward) * smoothing
        state.gait.leanLateral += (clamp(accelLateral / reference, -1, 1) * profile.lean
                                   - state.gait.leanLateral) * smoothing
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
