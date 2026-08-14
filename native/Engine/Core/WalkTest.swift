#if DEBUG
import Foundation

/// Verification harness: feeds synthetic joystick input so the game loop, physics, clip
/// mask and camera can be exercised without a GUI simulator to inject touches into.
///
/// Enable with `-walktest` on the launch arguments. It sweeps the heading through a full
/// circle so the player walks into scenery and collision responses show up in the log, and
/// swings the throttle from a crawl to a sprint and back over a slower cycle, so the whole
/// walk-to-run range gets exercised — and so a hard change of direction happens at every speed,
/// which is what puts a bracing foot out.
final class WalkTest {
    private let start = Date.timeIntervalSinceReferenceDate
    private let sweepSeconds: Double
    /// One full crawl → sprint → crawl cycle. Deliberately not a multiple of `sweepSeconds`, so
    /// the two never line up and every combination of heading and speed comes round eventually.
    private let throttleSeconds: Double

    init(sweepSeconds: Double = 8, throttleSeconds: Double = 11) {
        self.sweepSeconds = sweepSeconds
        self.throttleSeconds = throttleSeconds
    }

    var elapsed: Double {
        Date.timeIntervalSinceReferenceDate - start
    }

    func currentInput() -> InputState {
        // 0.25 to 1: below a quarter the character is barely moving and nothing is learned.
        let swing = (1 - cos(elapsed / throttleSeconds * 2 * .pi)) / 2
        return InputState.stick(headingDegrees: (elapsed / sweepSeconds) * 360,
                                throttle: 0.25 + 0.75 * swing)
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-walktest")
    }

    /// `-zoom <n>` pins the camera zoom, so a screenshot can be framed the same way the web
    /// client frames one for a side-by-side parity check.
    static var zoomOverride: Double? {
        argument("-zoom").flatMap(Double.init)
    }

    /// `-pitch <radians>` tips the overworld camera off its near-overhead default. It exists for
    /// looking at the character rig: from above you can see a hat and a pair of shoes, and
    /// nothing about whether the body underneath has a neck, a waist or a knee. 0 is straight
    /// down and π/2.1 is the flattest the camera will go; 0.9 is a good three-quarter view.
    static var pitchOverride: Double? {
        argument("-pitch").flatMap(Double.init)
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

    /// `-maptour 2,3,1,0` asks for each of those maps in turn, on a loop. The point is the
    /// *leaving*: a map change is the only thing that calls `ModelStore.evictMapModels`, and the
    /// only other way to cause one is to walk into a trigger zone, which `simctl` cannot do. With
    /// `-propstats` the resident-model count should fall back each time round.
    static var mapTour: [Int]? {
        guard let ids = argument("-maptour")?.split(separator: ",").compactMap({ Int($0) }),
              !ids.isEmpty
        else { return nil }
        return ids
    }

    /// Seconds to hold each stop of `-maptour`, from `-maptourhold <s>`. The default is long
    /// enough for a map to finish streaming at three models at a time.
    static var mapTourHold: Double {
        argument("-maptourhold").flatMap(Double.init) ?? 12
    }

    /// `-footballdemo` plays your side of a football match without a thumb: it chases the ball
    /// and kicks it, through the same `setMoveInput` and `kick()` a stick and a button reach.
    static var playsFootball: Bool {
        ProcessInfo.processInfo.arguments.contains("-footballdemo")
    }

    /// `-footballtrace` logs one line a second: the score, who has the ball and where it is.
    static var tracesFootball: Bool {
        ProcessInfo.processInfo.arguments.contains("-footballtrace")
    }

    /// `-schoolrushdemo` plays School Rush without a thumb: it jumps the jumpable and swerves
    /// round the rest, which is the only way `simctl` can find out whether the controls work.
    static var playsSchoolRush: Bool {
        ProcessInfo.processInfo.arguments.contains("-schoolrushdemo")
    }

    /// `-schoolrushtrace` logs one line a second: distance, lane, pace, lives and what is next.
    static var tracesSchoolRush: Bool {
        ProcessInfo.processInfo.arguments.contains("-schoolrushtrace")
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

    /// `-tennis3dtrace` logs the 3D rebuild once a second: phase, ball, both players and the
    /// score. The `-tennistrace` above only understands the superseded canvas game.
    static var traces3DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis3dtrace")
    }

    /// `-tennis3ddemo` plays the human's side of the 3D game on its own, by steering at the
    /// intercept the game itself predicts. It goes through `steer(racketToWorldX:y:)`, the same
    /// call a finger ends up in, so a whole match — including the match-over panel, which no run
    /// had ever reached — can be played out from `simctl` with no touches at all.
    static var plays3DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis3ddemo")
    }

    /// `-tennis3dtaps` plays the same side, but **through the screen**: the marker is projected
    /// back to a point on the glass and pushed into `Tennis3DView` where UIKit would have put it.
    ///
    /// The difference matters. `-tennis3ddemo` hands the game world coordinates it computed
    /// itself, so it cannot catch anything wrong with turning a touch into a place on the court —
    /// which is the half of the control scheme that has never been exercised by anything, because
    /// neither `simctl` nor the simulator panel can inject a touch. This one round-trips
    /// project → unproject → racket offset, and a metre of error anywhere in it shows up as a
    /// player who misses every ball.
    static var tapPlays3DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis3dtaps")
    }

    /// `-tennispitch <radians>` and `-tenniswidth <metres>` override the 3D game's camera, so the
    /// framing can be swept without a rebuild between each try. 0 is straight down; 0.9 is about
    /// where a television camera sits behind the baseline.
    static var tennisCameraPitch: Double? {
        argument("-tennispitch").flatMap(Double.init)
    }

    /// How many metres of court the screen is wide, at the focus point.
    static var tennisCameraWidth: Double? {
        argument("-tenniswidth").flatMap(Double.init)
    }

    /// `-tennisdifficulty <0…1>` overrides how good the opponent is, for balancing runs.
    /// See `Tennis3DGame.Tuning.difficulty`.
    static var tennisDifficulty: Double? {
        argument("-tennisdifficulty").flatMap(Double.init)
    }

    /// `-tennis3ddrag` plays the human's side **by dragging** rather than tapping: one `.began`
    /// on the player, then `.changed` all the way round the point, then `.ended`.
    ///
    /// `-tennis3dtaps` covers the tap recogniser's path and nothing else. The drag has its own
    /// bookkeeping — the grab test, the offset held constant for the rest of the gesture, and the
    /// `isDragging` flag that stops the tap recogniser fighting it — and none of it had ever run,
    /// on any machine, in five sessions. Being unable to inject a touch is not a reason for the
    /// logic behind the touch to go unexercised.
    static var dragPlays3DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis3ddrag")
    }

    /// `-tennis3dhittest` asks the window, once a second, which view would receive a touch in the
    /// middle of the court. The one question no amount of driving the view from inside can
    /// answer: whether a layer stacked above the court is quietly eating every gesture.
    static var hitTests3DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis3dhittest")
    }

    /// `-tennis3daim` makes the tap bot pick a corner of Alex's court before each of its shots,
    /// by tapping it — which is the only way the aiming gesture gets exercised end to end, since
    /// the bot's ordinary taps are all on its own half. See `Tennis3DGame.aimShot`.
    static var aims3DTennis: Bool {
        ProcessInfo.processInfo.arguments.contains("-tennis3daim")
    }

    /// `-tennisgames <n>` overrides how many games win the match, for a run that has to reach the
    /// match-over panel and the badge without playing a full one. See `Tennis3DMatchLength`.
    static var tennisGamesToWin: Int? {
        argument("-tennisgames").flatMap(Int.init)
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
