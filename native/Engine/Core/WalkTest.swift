#if DEBUG
import Foundation

/// Verification harness: feeds synthetic joystick input so the game loop, physics, clip
/// mask and camera can be exercised without a GUI simulator to inject touches into.
///
/// Enable with `-walktest` on the launch arguments. It sweeps the heading through a full
/// circle so the player walks into scenery and collision responses show up in the log.
final class WalkTest {
    private let start = Date.timeIntervalSinceReferenceDate
    private let sweepSeconds: Double

    init(sweepSeconds: Double = 8) {
        self.sweepSeconds = sweepSeconds
    }

    var elapsed: Double {
        Date.timeIntervalSinceReferenceDate - start
    }

    func currentInput() -> InputState {
        InputState(isMoving: true,
                   angleDegrees: (elapsed / sweepSeconds) * 360)
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-walktest")
    }

    /// `-zoom <n>` pins the camera zoom, so a screenshot can be framed the same way the web
    /// client frames one for a side-by-side parity check.
    static var zoomOverride: Double? {
        argument("-zoom").flatMap(Double.init)
    }

    /// `-at <x> <y>` drops the player at a fixed world position on spawn, so the same view can
    /// be rendered in both clients and the two images diffed.
    static var positionOverride: (x: Double, y: Double)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-at"), index + 2 < arguments.count,
              let x = Double(arguments[index + 1]), let y = Double(arguments[index + 2])
        else { return nil }
        return (x, y)
    }

    /// `-tennis2d` loads the superseded 2D canvas tennis game on the tennis map instead of the
    /// 3D rebuild. The old game is kept in the tree for comparison; this is how to reach it.
    static var prefers2DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis2d")
    }

    /// `-npctrace` logs every roaming or patrolling NPC once a second, so the Phase 4
    /// behaviour port can be checked without watching the screen.
    static var tracesNPCs: Bool {
        ProcessInfo.processInfo.arguments.contains("-npctrace")
    }

    /// `-autoconfirm` answers yes to any `show_dialog` a second after it appears. There is no
    /// way to inject a touch from `simctl`, and this is the only path to a map change.
    static var autoConfirmsDialogs: Bool {
        ProcessInfo.processInfo.arguments.contains("-autoconfirm")
    }

    /// `-uidemo` walks the Phase 5 UI through every surface on a timer — chat feed, speech
    /// bubble, each dialog, the minimap and the rejection flash — so it can be screenshotted
    /// without touch injection. Each step logs its name, so the log lines up with the images.
    static var runsUIDemo: Bool {
        ProcessInfo.processInfo.arguments.contains("-uidemo")
    }

    /// `-emote <name>` holds one emote from the moment the player joins, restarting it as it
    /// expires, so a single pose and its props can be framed for a screenshot.
    static var heldEmote: String? {
        argument("-emote")
    }

    /// `-emotedemo [seconds]` puts the player through every emote in turn, holding each one
    /// long enough to screenshot. Without touch injection this is the only way to see a pose
    /// that is not reachable from a trigger zone.
    static var emoteDemoInterval: Double? {
        guard ProcessInfo.processInfo.arguments.contains("-emotedemo") else { return nil }
        return argument("-emotedemo").flatMap(Double.init) ?? 3
    }

    /// `-map <id>` requests a map change as soon as the first world arrives. The tennis court
    /// is behind a trigger zone halfway across Junior Campus, and `simctl` cannot walk there.
    static var initialMapId: Int? {
        argument("-map").flatMap(Int.init)
    }

    /// `-tennistrace` logs the state of a tennis point once a second: the ball, the serve
    /// state, where each racket is and what each player is aiming at.
    static var tracesTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennistrace")
    }

    /// `-tennisdemo` plays the player's side by "tapping" wherever the swing is predicted to
    /// meet the ball. It drives `handleTap`, so it exercises the real input path — the only
    /// way to, since the simulator MCP panel cannot inject touches and `simctl` never could.
    static var playsTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennisdemo")
    }

    /// `-exitafter <seconds>` presses the minigame's exit button on a timer, so the dialog and
    /// the map change back out of a minigame can be driven end to end with `-autoconfirm`.
    static var exitAfterSeconds: Double? {
        argument("-exitafter").flatMap(Double.init)
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}
#endif
