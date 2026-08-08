import Foundation
import simd

/// Snapshot of movement intent for one simulation step.
///
/// Lives in the engine rather than beside the joystick that produces it on iOS, because the
/// macOS admin app drives `GameState.update` from the keyboard instead.
///
/// The two input styles are the two branches of the web client's
/// `getDemandedMovementVector` (`input.js:33-56`): a thumbstick sets the heading directly and
/// always walks forward, while the keyboard is *tank controls* — turn in place with left and
/// right, then drive along whatever heading that leaves you on. A thumbstick suppresses the
/// keys entirely, exactly as `TouchMove` takes the whole branch in the JS.
///
/// ## The stick is a vector, not a switch
///
/// It used to be `isMoving: Bool` plus a heading, which threw away the one thing an analogue
/// stick knows that a keyboard does not: **how far over it is pushed**. Every touch past the
/// dead zone meant the same flat-out run, and the only way to move slowly was the 2.5-second
/// hold-to-run timer running the other way. `move` keeps the magnitude, and `throttle` is what
/// `GameState` scales the demanded speed by — so a nudge is an amble and a shove is a sprint.
struct InputState {

    /// Thumbstick displacement, as a **world-space vector with a magnitude of 0…1**. Zero is
    /// the stick centred (or no touch at all); a magnitude of 1 is pushed to the rim.
    ///
    /// World space is Y-down and UIKit's view space is too, so a touch below the stick's centre
    /// is `+y` in both and no sign has to be flipped on the way in.
    var move = SIMD2<Double>(0, 0)

    /// Keyboard tank controls. `turn` is −1 (left) / 0 / +1 (right), applied at the
    /// character's `rotationSpeed` per frame (`main.js:314-321`); `forward` is +1 (ahead) /
    /// 0 / −1 (astern) along the current heading.
    var turn: Double = 0
    var forward: Double = 0

    /// **How much of the character's top speed is being asked for**, 0…1. The magnitude of
    /// `move`, clamped — a stick that reports a corner-of-the-square 1.41 must not outrun one
    /// pushed straight along an axis.
    var throttle: Double {
        min(1, (move.x * move.x + move.y * move.y).squareRoot())
    }

    /// True when the stick is asking for anything at all. The keyboard's `forward` is a separate
    /// branch and deliberately does not count here, the same way `TouchMove` did not in the JS.
    var isMoving: Bool { throttle > 0 }

    /// Heading in degrees, 0° = +X, clockwise (world convention). Meaningless — and zero — when
    /// the stick is centred, so read `isMoving` first.
    var angleDegrees: Double {
        guard move.x != 0 || move.y != 0 else { return 0 }
        return atan2(move.y, move.x) * 180 / .pi
    }

    /// A stick pushed `throttle` of the way over along `headingDegrees`. For callers that think
    /// in headings — the walk test, and anything replaying a recorded input.
    static func stick(headingDegrees: Double, throttle: Double) -> InputState {
        let clamped = min(1, max(0, throttle))
        let radians = headingDegrees * .pi / 180
        return InputState(move: SIMD2(cos(radians) * clamped, sin(radians) * clamped))
    }
}
