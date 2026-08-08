import Foundation

/// Snapshot of movement intent for one simulation step.
///
/// Lives in the engine rather than beside the joystick that produces it on iOS: the macOS
/// admin app drives `GameState.update` with a standing "not moving" value, since its camera
/// is free rather than following a walking player.
struct InputState {
    var isMoving = false
    /// Heading in degrees, 0° = +X, clockwise (world convention).
    var angleDegrees: Double = 0
}
