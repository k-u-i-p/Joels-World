import AppKit

/// Turns held keys into an `InputState` for the frame loop.
///
/// The web client polled `inputManager.isPressed(...)` once a frame rather than moving on the
/// keystroke, so a held key produces smooth motion instead of the OS's key-repeat stutter
/// (`main.js:314-321`). This does the same: `keyDown`/`keyUp` only maintain the pressed set,
/// and `inputState()` is read by `Renderer`'s `inputProvider`.
///
/// The mapping is the JS one — ← → turn, ↑ ↓ drive — plus WASD, which the browser build never
/// had a reason to bind and a Mac app is expected to answer.
final class KeyboardMovement {
    private enum Key {
        case turnLeft, turnRight, forward, back
    }

    private var pressed: Set<Key> = []

    /// Codes are physical (`NSEvent.keyCode`), so WASD lands on the same three keys under a
    /// non-QWERTY layout that a game would put them on.
    private static func key(for code: UInt16) -> Key? {
        switch code {
        case 123, 0: return .turnLeft    // ←, A
        case 124, 2: return .turnRight   // →, D
        case 126, 13: return .forward    // ↑, W
        case 125, 1: return .back        // ↓, S
        default: return nil
        }
    }

    /// True when the event was a movement key and should not travel any further.
    @discardableResult
    func keyDown(_ event: NSEvent) -> Bool {
        // A modified key is a command (⌘C, ⌥←), not movement.
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control),
              let key = Self.key(for: event.keyCode)
        else { return false }
        pressed.insert(key)
        return true
    }

    @discardableResult
    func keyUp(_ event: NSEvent) -> Bool {
        guard let key = Self.key(for: event.keyCode) else { return false }
        pressed.remove(key)
        return true
    }

    /// Keys held when the window loses focus never deliver their `keyUp`, so the character
    /// would walk away on its own. `input.js` clears on `window`'s `blur` for the same reason.
    func releaseAll() {
        pressed.removeAll()
    }

    func inputState() -> InputState {
        var state = InputState()
        state.turn = (pressed.contains(.turnRight) ? 1 : 0) - (pressed.contains(.turnLeft) ? 1 : 0)
        state.forward = (pressed.contains(.forward) ? 1 : 0) - (pressed.contains(.back) ? 1 : 0)
        return state
    }
}
