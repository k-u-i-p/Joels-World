import Foundation

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
struct InputState {
    /// Thumbstick: the heading comes straight off the stick and the character walks forward.
    var isMoving = false
    /// Heading in degrees, 0° = +X, clockwise (world convention).
    var angleDegrees: Double = 0

    /// Keyboard tank controls. `turn` is −1 (left) / 0 / +1 (right), applied at the
    /// character's `rotationSpeed` per frame (`main.js:314-321`); `forward` is +1 (ahead) /
    /// 0 / −1 (astern) along the current heading.
    var turn: Double = 0
    var forward: Double = 0
}
