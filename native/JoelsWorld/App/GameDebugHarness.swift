#if DEBUG
import Foundation

/// The launch-argument verification harness: `-walktest`, `-npctrace`, `-uidemo`,
/// `-emotedemo`, `-emote`, `-map`, `-tennisdemo`, `-tennistrace`, `-tennis3ddemo`,
/// `-tennis3dtrace`, `-exitafter`, `-autojoin`, `-selftest`.
///
/// `simctl` cannot inject touches, so every part of the game that a person would reach by
/// tapping is reached from here instead — the dialogs open themselves, the emotes cycle, the
/// tennis player swings — and the numbers behind each one go to the log where a screenshot
/// cannot lie about them. `WalkTest` reads the arguments; this drives the app from them.
///
/// It lives outside `GameViewController` because it is nine timers and a pile of one-shot
/// latches, none of which the shipping app has any use for. The whole file compiles out of a
/// release build.
final class GameDebugHarness {
    /// The screen being driven. Unowned because the view controller owns the harness.
    private unowned let host: GameViewController

    private var walkTest: WalkTest?
    private var walkTestTimer: Timer?
    private var npcTraceTimer: Timer?
    private var emoteDemoTimer: Timer?
    private var tennisTraceTimer: Timer?
    private var tennisDemoTimer: Timer?
    private var tennisExitTimer: Timer?
    private var tennis3DTraceTimer: Timer?
    private var tennis3DDemoTimer: Timer?
    private var tennis3DTapTimer: Timer?
    private var tennis3DDragTimer: Timer?
    private var tennis3DHitTestTimer: Timer?
    private var schoolRushDemoTimer: Timer?
    private var schoolRushTraceTimer: Timer?
    /// True once `-tennis3ddrag` has sent its `.began`, so every tick after it is a `.changed` —
    /// which is what makes it a drag rather than a stream of separate grabs.
    private var tennis3DDragInProgress = false
    /// The demo restarts the match once after it ends, to prove `restartMatch()` is clean and
    /// that the badge does not fire a second time. Only once — otherwise it plays for ever.
    private var tennis3DHasRestarted = false
    /// Which corner `-tennis3daim` picks next.
    private var tennis3DAimFlip = false
    private var uiDemoStarted = false
    private var requestedInitialMap = false

    init(host: GameViewController) {
        self.host = host
        // `-selftest` checks the pure movement maths. It needs no world, no Metal and no
        // network, so it runs the moment the harness exists rather than waiting for a join
        // that may never come.
        if LocomotionSelfTest.isEnabled { LocomotionSelfTest.run() }
    }

    // MARK: - Hooks

    /// Synthetic joystick input, when `-walktest` asked for it. `nil` leaves the renderer on
    /// the real stick.
    func walkTestInputProvider() -> (() -> InputState)? {
        guard WalkTest.isEnabled else { return nil }
        let walkTest = WalkTest()
        self.walkTest = walkTest
        return { walkTest.currentInput() }
    }

    /// Called once the `init` frame has been applied and there is a world to drive.
    func worldDidLoad() {
        startWalkTestLogging()
        startNPCTrace()
        startUIDemo()
        startEmoteDemo()
        startTennisTrace()
        requestInitialMap()
        if EmoteDump.isEnabled { EmoteDump.run() }
    }

    /// `-confirmdialogs`: takes the Yes branch of whatever prompt just came up, a second later.
    func dialogWasShown(_ request: DialogRequest) {
        guard WalkTest.autoConfirmsDialogs,
              request.confirmAction != nil || request.onConfirm != nil
        else { return }

        Log.world("Dialog: '\(request.text)' — auto-confirming")
        let action = request.confirmAction
        let handler = request.onConfirm
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let host = self?.host, !host.dialog.isHidden else { return }
            host.dialog.dismiss()
            if case .changeMap(let mapId) = action { host.network.sendChangeMap(mapId) }
            handler?()
        }
    }

    /// `-tennisdemo` swings at every ball the prediction says is reachable; `-tennis3ddemo` does
    /// the same job for the 3D rebuild; `-tennis3dtrace` narrates it; `-exitafter <s>` presses
    /// the exit button once the rally has run long enough to be worth looking at.
    func minigameDidStart(_ minigame: Minigame) {
        if let game = minigame as? TennisGame {
            startTennisDemo(game)
            startExitTimer { [weak game] in game?.requestExit() }
        }
        if let game = minigame as? SchoolRushGame {
            startSchoolRushDemo(game)
            startSchoolRushTrace(game)
            startExitTimer { [weak game] in game?.requestExit() }
        }
        if let game = minigame as? Tennis3DGame {
            start3DTennisDemo(game)
            start3DTennisTapDemo(game)
            start3DTennisDragDemo(game)
            start3DTennisHitTest(game)
            start3DTennisTrace(game)
            startExitTimer { [weak game] in game?.requestExit() }
        }
    }

    func minigameDidEnd() {
        for timer in [tennisDemoTimer, tennisExitTimer, tennis3DDemoTimer, tennis3DTapTimer,
                      tennis3DDragTimer, tennis3DHitTestTimer, tennis3DTraceTimer,
                      schoolRushDemoTimer, schoolRushTraceTimer] {
            timer?.invalidate()
        }
        schoolRushDemoTimer = nil
        schoolRushTraceTimer = nil
        tennisDemoTimer = nil
        tennisExitTimer = nil
        tennis3DDemoTimer = nil
        tennis3DTapTimer = nil
        tennis3DDragTimer = nil
        tennis3DHitTestTimer = nil
        tennis3DTraceTimer = nil
        tennis3DHasRestarted = false
        tennis3DDragInProgress = false
    }

    /// `-schoolrushdemo`: runs the course on its own.
    ///
    /// It presses exactly what a thumb presses — `jump()` and `changeLane(by:)` — so what this
    /// proves is that the controls work, not merely that the simulation does. Twenty times a
    /// second, which is quicker than a person and slow enough that a decision is still a
    /// decision. It restarts once when the run ends, to show the panel's Run again button leaves
    /// the game in a state that can be played.
    private func startSchoolRushDemo(_ game: SchoolRushGame) {
        guard WalkTest.playsSchoolRush, schoolRushDemoTimer == nil else { return }
        Log.world("-schoolrushdemo: running the course")
        var hasRestarted = false

        schoolRushDemoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            switch game.debugNextAction() {
            case .carryOn:
                break
            case .jump:
                game.jump()
            case let .moveTo(lane):
                game.changeLane(by: lane > game.lane ? 1 : -1)
            }

            if game.phase == .over, !hasRestarted, game.speedInMetresPerSecond < 0.5 {
                hasRestarted = true
                Log.world("-schoolrushdemo: run over — restarting in 3 s to check the panel")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { game.restartRun() }
            }
        }
    }

    private func startSchoolRushTrace(_ game: SchoolRushGame) {
        guard WalkTest.tracesSchoolRush, schoolRushTraceTimer == nil else { return }
        schoolRushTraceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Log.world(game.debugTraceLine)
        }
    }

    private func startTennisDemo(_ game: TennisGame) {
        guard WalkTest.playsTennis, tennisDemoTimer == nil else { return }
        tennisDemoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak game] _ in
            guard let game, let intercept = game.player.lastIntercept, intercept.t >= 0 else {
                return
            }
            game.handleTap(worldX: intercept.x, worldY: intercept.y)
        }
    }

    private func startExitTimer(_ press: @escaping () -> Void) {
        guard let delay = WalkTest.exitAfterSeconds, tennisExitTimer == nil else { return }
        tennisExitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Log.world("-exitafter: pressing the exit button")
            press()
        }
    }

    // MARK: - 3D tennis

    /// `-tennis3ddemo`: plays the human's side without a human.
    ///
    /// It steers at the intercept the game itself predicts, through the same
    /// `steer(racketToWorldX:y:)` a finger ends up in — so it exercises the real control path,
    /// not a back door. Between shots it recovers to the middle of the baseline, which is what
    /// the hint tells a person to do.
    ///
    /// This exists because balance cannot be judged from a screenshot. A whole match played out
    /// against the trace below is the only way to see whether the opponent is any good, and it
    /// is also the only way to reach the match-over panel, which no hand-played run ever did.
    private func start3DTennisDemo(_ game: Tennis3DGame) {
        guard WalkTest.plays3DTennis, tennis3DDemoTimer == nil else { return }
        Log.world("-tennis3ddemo: playing the player's side")

        tennis3DDemoTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak game] _ in
            guard let self, let game else { return }

            if game.phase == .matchOver {
                guard !self.tennis3DHasRestarted else { return }
                self.tennis3DHasRestarted = true
                Log.world("-tennis3ddemo: match over — restarting in 4 s to check the panel")
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak game] in
                    game?.restartMatch()
                }
                return
            }

            // Leave the serve alone: the server is standing on their mark and the toss is solved
            // from where they are, so steering them mid-toss is a guaranteed double fault.
            guard game.phase == .rally || (game.phase == .toss && !game.serverIsPlayer) else {
                return
            }

            // The intercept, through the racket-aimed entry point — because that is now what a
            // finger does. It used to compute the stance itself and steer the feet, which meant
            // the bot was quietly exercising a path no player could reach.
            if let intercept = game.idealIntercept() {
                game.steer(racketToWorldX: intercept.x, y: intercept.y)
            } else {
                // Recovering between shots is about where to *stand*, so it stays on the feet
                // entry point.
                game.steer(toWorldX: 0,
                           y: Tennis3DCourt.halfLength + Tennis3DCourt.metres(0.5))
            }
        }
    }

    /// `-tennis3dtaps`: plays the human's side **by tapping the screen**.
    ///
    /// `-tennis3ddemo` above hands the game a point it worked out in world coordinates, which is
    /// a fine test of the tennis and no test at all of the controls. This one takes the same
    /// point, projects it back through the live camera to a pixel on the glass, and pushes that
    /// pixel into `Tennis3DView` at the line the tap recogniser enters — so the ray cast, the
    /// height plane it is cut on, and the racket offset all have to be right or the player misses
    /// everything. It is the closest thing to a thumb that exists without a person holding one.
    ///
    /// Three or four taps a second, because that is roughly what a ten-year-old chasing a ball
    /// manages, and because a tap that lands sixty times a second is a drag rather than a tap.
    private func start3DTennisTapDemo(_ game: Tennis3DGame) {
        guard WalkTest.tapPlays3DTennis, tennis3DTapTimer == nil else { return }
        Log.world("-tennis3dtaps: playing the player's side through the screen")

        tennis3DTapTimer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self, weak game] _ in
            guard let self, let game, let view = self.host.tennis3d as Tennis3DView? else { return }
            guard game.phase == .rally || (game.phase == .toss && !game.serverIsPlayer) else {
                return
            }
            // `-tennis3daim`: before running for the ball, tap a corner of Alex's court. It
            // alternates corners so a whole run is not one repeated shot, and it goes in through
            // the same `debugTouch` a steering tap does — the near/far decision, the ground-plane
            // unprojection and the clamp are all part of what is being tested.
            if WalkTest.aims3DTennis, game.playerAim == nil, game.ball.lastHitByPlayer == false {
                self.tennis3DAimFlip.toggle()
                let corner = Tennis3DCourt.halfSingles * (self.tennis3DAimFlip ? 0.8 : -0.8)
                let depth = -Tennis3DCourt.halfLength * 0.72
                if let point = view.debugScreenPoint(worldX: corner, worldY: depth, z: 0) {
                    view.debugTouch(at: point)
                }
            }

            guard let intercept = game.idealIntercept(),
                  let point = view.debugScreenPoint(worldX: intercept.x, worldY: intercept.y,
                                                    z: intercept.z)
            else { return }
            view.debugTouch(at: point)
        }
    }

    /// `-tennis3ddrag`: plays the human's side **by dragging**, at 30 Hz.
    ///
    /// The gesture is a real one rather than a series of taps: a single `.began` on the player —
    /// so the grab branch runs, with its 1.8 m radius and its held offset — then `.changed` every
    /// tick for the rest of the point, then `.ended` when the point does. A tap bot can never
    /// catch a bug in any of that, because it never begins or ends anything.
    private func start3DTennisDragDemo(_ game: Tennis3DGame) {
        guard WalkTest.dragPlays3DTennis, tennis3DDragTimer == nil else { return }
        Log.world("-tennis3ddrag: playing the player's side by dragging")

        tennis3DDragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak game] _ in
            guard let self, let game, let view = self.host.tennis3d as Tennis3DView? else { return }

            // Between points the finger comes off, exactly as a player's would.
            guard game.phase == .rally || (game.phase == .toss && !game.serverIsPlayer) else {
                if self.tennis3DDragInProgress {
                    self.tennis3DDragInProgress = false
                    if let point = view.debugScreenPoint(worldX: game.player.motor.x,
                                                         worldY: game.player.motor.y, z: 0) {
                        view.debugDrag(.ended, at: point)
                    }
                }
                return
            }

            // A drag starts **on the player** — that is the branch worth testing, and it is what
            // a thumb naturally does. Every tick after it follows the ball.
            if !self.tennis3DDragInProgress {
                guard let start = view.debugScreenPoint(worldX: game.playerRacketAnchor.x,
                                                        worldY: game.playerRacketAnchor.y,
                                                        z: game.playerContactHeight) else { return }
                view.debugDrag(.began, at: start)
                self.tennis3DDragInProgress = true
                return
            }

            guard let intercept = game.idealIntercept(),
                  let point = view.debugScreenPoint(worldX: intercept.x, worldY: intercept.y,
                                                    z: intercept.z)
            else { return }
            view.debugDrag(.changed, at: point)
        }
    }

    /// `-tennis3dhittest`: once a second, which view would a touch in the middle of the court
    /// actually land on? See `Tennis3DView.debugHitTestReport`.
    private func start3DTennisHitTest(_ game: Tennis3DGame) {
        guard WalkTest.hitTests3DTennis, tennis3DHitTestTimer == nil else { return }

        tennis3DHitTestTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.host.tennis3d as Tennis3DView? else { return }
            let bounds = view.bounds
            let probes: [(String, CGPoint)] = [
                ("court centre", CGPoint(x: bounds.midX, y: bounds.midY)),
                ("near baseline", CGPoint(x: bounds.midX, y: bounds.maxY - 180)),
                ("bottom-right corner", CGPoint(x: bounds.maxX - 60, y: bounds.maxY - 90)),
                ("Alex's half", CGPoint(x: bounds.midX, y: bounds.minY + bounds.height * 0.35)),
            ]
            for (name, point) in probes {
                Log.world("tennis3d hit-test · \(name) \(Int(point.x)),\(Int(point.y)) → \(view.debugHitTestReport(at: point))")
            }
        }
    }

    /// `-tennis3dtrace`: one line a second for the point, one for the two players.
    private func start3DTennisTrace(_ game: Tennis3DGame) {
        guard WalkTest.traces3DTennis, tennis3DTraceTimer == nil else { return }

        tennis3DTraceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak game] _ in
            guard let game else { return }
            let board = game.scoreboard
            let metre = Tennis3DCourt.unitsPerMetre

            game.traceSample(String(format:
                "tennis3d %@ server=%@ faults=%d serveInFlight=%@ ball=(%.1f, %.1f, %.1f)m v=(%.1f, %.1f, %.1f)m/s bounces=%d spin=%.2f",
                "\(game.phase)", board.serverIsPlayer ? "you" : board.opponentName,
                game.faults, "\(game.isServeInFlight)",
                game.ball.x / metre, game.ball.y / metre, game.ball.z / metre,
                game.ball.vx / metre, game.ball.vy / metre, game.ball.vz / metre,
                game.ball.bounces, game.ball.topspin))

            game.traceSample(String(format:
                "tennis3d   you=(%.1f, %.1f)m face=%.0f° speed=%.1f swing=%@ | %@=(%.1f, %.1f)m face=%.0f° speed=%.1f swing=%@ | %@–%@ games %d–%d",
                game.player.motor.x / metre, game.player.motor.y / metre,
                game.player.motor.facing, game.player.motor.speed / metre,
                "\(game.player.swing.stage)",
                board.opponentName,
                game.npc.motor.x / metre, game.npc.motor.y / metre,
                game.npc.motor.facing, game.npc.motor.speed / metre,
                "\(game.npc.swing.stage)",
                board.playerPoints, board.npcPoints, board.playerGames, board.npcGames))
        }
    }

    /// Reads `-autojoin <Name>` from the launch arguments: skips the lobby, for scripted runs.
    static func autoJoinName() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-autojoin"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        let name = arguments[arguments.index(after: flag)]
        return name.allSatisfy { $0.isLetter && $0.isASCII } ? name : nil
    }

    // MARK: - Traces

    /// Samples the player each half second so collision behaviour is visible in the log.
    private func startWalkTestLogging() {
        guard let walkTest, walkTestTimer == nil else { return }

        var previous: (x: Double, y: Double)?
        walkTestTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }

            let player = self.host.state.player
            let maskLoaded = self.host.state.physics.clipMask != nil
            let moved = previous.map { hypot(player.x - $0.x, player.y - $0.y) } ?? 0
            previous = (player.x, player.y)

            // The gait goes out too. The stick's throttle is what decides `speed`, `intensity`
            // and `run`, and `brace`/`turn` are what the legs and the waist counteract the
            // inertia with — none of which can be checked from a screenshot, and all of which
            // are a sign away from being backwards.
            let gait = player.gait
            let speed = hypot(player.velocityX, player.velocityY)
            Log.world(String(format:
                "walktest t=%.1fs pos=(%.1f, %.1f) heading=%.0f° moved=%.1fpx mask=%@ blocked=%@ "
                + "speed=%.0f intensity=%.2f run=%.2f fwd=%+.2f lat=%+.2f brace=%+.2f turn=%+.2f",
                walkTest.elapsed, player.x, player.y, player.rotation, moved,
                maskLoaded ? "loaded" : "none",
                moved < 1 ? "YES" : "no",
                speed, gait.intensity, gait.run, gait.forward, gait.lateral,
                gait.leanLateral, gait.turning))

            if walkTest.elapsed > 30 { timer.invalidate() }
        }
    }

    /// Logs the client-simulated NPCs each second: where they are and where they are heading.
    private func startNPCTrace() {
        guard WalkTest.tracesNPCs, npcTraceTimer == nil else { return }

        npcTraceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let state = self?.host.state else { return }
            for npc in state.npcs where npc.roam_radius != nil || npc.waypoints != nil {
                let visual = state.visuals[npc.id]
                Log.world(String(format: "npc %d %@ pos=(%.1f, %.1f) rot=%.0f target=(%.1f, %.1f) rot=%.0f wait=%.2f idx=%d",
                                 npc.id, npc.name ?? "?", npc.x, npc.y, npc.rotation ?? 0,
                                 visual?.targetX ?? .nan, visual?.targetY ?? .nan,
                                 visual?.targetRotation ?? .nan,
                                 visual?.waitTimer ?? .nan, visual?.moveIndex ?? -1))
            }
        }
    }

    /// `-tennistrace`: one line a second describing the point in play.
    private func startTennisTrace() {
        guard WalkTest.tracesTennis, tennisTraceTimer == nil else { return }

        tennisTraceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let game = self?.host.state.minigame as? TennisGame else { return }
            let score = game.currentScore
            Log.world(String(format:
                "tennis %@ serve=%@/%@ ball=(%.1f, %.1f, %.1f) v=(%.1f, %.1f, %.1f) bounces=%d rally=%d",
                "\(game.introPhase)", "\(game.isServe)", "\(game.servePhase)",
                game.ball.x, game.ball.y, game.ball.z,
                game.ball.vx, game.ball.vy, game.ball.vz,
                game.bounceCount, game.rallyCount))
            Log.world(String(format:
                "tennis   player pos=(%.1f, %.1f, %.1f) rot=%.0f racket=(%.1f, %.1f) w=%.1f h=%.1f | npc pos=(%.1f, %.1f, %.1f) racket=(%.1f, %.1f) | score %@-%@",
                game.player.current.x, game.player.current.y, game.player.current.z,
                game.player.current.rotation,
                game.player.racket.x, game.player.racket.y,
                game.player.racket.w, game.player.racket.h,
                game.npc.current.x, game.npc.current.y, game.npc.current.z,
                game.npc.racket.x, game.npc.racket.y,
                score.playerText ?? "-", score.npcText ?? "-"))
        }
    }

    // MARK: - Demos

    /// `-emotedemo`: steps the player through every emote in the table so each pose can be
    /// screenshotted. `-emote <name>` holds a single one. Both go through `submitChat`, so
    /// they exercise the whole path the picker takes — pose, chat line and sound.
    private func startEmoteDemo() {
        if let held = WalkTest.heldEmote, emoteDemoTimer == nil {
            // Re-issued on a timer because the short emotes expire on their own duration.
            emoteDemoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let host = self?.host, host.state.player.emote?.name != held else { return }
                host.submitChat("/\(held)")
            }
            return
        }

        guard let interval = WalkTest.emoteDemoInterval, emoteDemoTimer == nil else { return }
        let names = Emotes.names
        var index = 0

        emoteDemoTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard index < names.count else {
                timer.invalidate()
                Log.world("emotedemo: finished")
                return
            }
            let name = names[index]
            index += 1
            Log.world("emotedemo: /\(name)")
            self.host.submitChat("/\(name)")
        }
    }

    /// `-uidemo`: opens each piece of the UI in turn so a screenshot can be taken of it.
    private func startUIDemo() {
        guard WalkTest.runsUIDemo, !uiDemoStarted else { return }
        uiDemoStarted = true

        let steps: [(Double, String, () -> Void)] = [
            (1.0, "chat feed", { [weak self] in
                guard let host = self?.host else { return }
                host.hud.addChatMessage(sender: "Frank", message: "Anyone seen my lunch?")
                host.hud.addChatMessage(sender: "Mr Savage", message: "Back to class, all of you.")
                host.hud.addChatMessage(sender: "Tester", message: "Hello from the native client!")
                host.state.setLocalChat("Hello from the native client!")
            }),
            (4.0, "emotes dialog", { [weak self] in self?.host.emotesDialog.present() }),
            (7.0, "badges dialog", { [weak self] in
                guard let host = self?.host else { return }
                host.emotesDialog.dismiss()
                host.handle(.badgeEarned("tennis"))
                host.badgesDialog.present()
            }),
            (10.0, "help dialog", { [weak self] in
                self?.host.badgesDialog.dismiss()
                self?.host.helpDialog.present()
            }),
            (13.0, "minimap", { [weak self] in
                guard let host = self?.host else { return }
                host.helpDialog.dismiss()
                host.minimap.present(mapId: host.state.mapData?.id)
            }),
            (16.0, "map change rejected", { [weak self] in
                self?.host.minimap.dismiss()
                self?.host.handle(.mapChangeRejected)
            }),
            (18.0, "emote command", { [weak self] in
                // The same path the emote picker takes: a `/name` line off the chat field.
                self?.host.submitChat("/dance")
            }),
            (19.0, "door dialog", { [weak self] in
                self?.host.dialog.present(DialogRequest(text: "Enter the Pool building?",
                                                        confirmAction: nil))
            }),
        ]

        for (delay, name, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Log.world("uidemo: \(name)")
                action()
            }
        }
    }

    /// `-map <id>`: jumps straight to a map instead of walking to its door.
    private func requestInitialMap() {
        guard let mapId = WalkTest.initialMapId, !requestedInitialMap else { return }
        requestedInitialMap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Log.world("-map: requesting map \(mapId)")
            self?.host.network.sendChangeMap(mapId)
        }
    }
}
#endif
