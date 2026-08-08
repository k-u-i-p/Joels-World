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
    /// The demo restarts the match once after it ends, to prove `restartMatch()` is clean and
    /// that the badge does not fire a second time. Only once — otherwise it plays for ever.
    private var tennis3DHasRestarted = false
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
        if let game = minigame as? Tennis3DGame {
            start3DTennisDemo(game)
            start3DTennisTrace(game)
            startExitTimer { [weak game] in game?.requestExit() }
        }
    }

    func minigameDidEnd() {
        for timer in [tennisDemoTimer, tennisExitTimer, tennis3DDemoTimer, tennis3DTraceTimer] {
            timer?.invalidate()
        }
        tennisDemoTimer = nil
        tennisExitTimer = nil
        tennis3DDemoTimer = nil
        tennis3DTraceTimer = nil
        tennis3DHasRestarted = false
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
    /// `steer(toWorldX:y:)` a finger ends up in — so it exercises the real control path, not a
    /// back door. Between shots it recovers to the middle of the baseline, which is what the
    /// hint tells a person to do.
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

            // `idealStance`, not `idealIntercept`: where the feet go, not where the ball is.
            if let stance = game.idealStance() {
                game.steer(toWorldX: stance.x, y: stance.y)
            } else {
                game.steer(toWorldX: 0,
                           y: Tennis3DCourt.halfLength + Tennis3DCourt.metres(0.5))
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

            Log.world(String(format:
                "tennis3d %@ server=%@ faults=%d serveInFlight=%@ ball=(%.1f, %.1f, %.1f)m v=(%.1f, %.1f, %.1f)m/s bounces=%d spin=%.2f",
                "\(game.phase)", board.serverIsPlayer ? "you" : board.opponentName,
                game.faults, "\(game.isServeInFlight)",
                game.ball.x / metre, game.ball.y / metre, game.ball.z / metre,
                game.ball.vx / metre, game.ball.vy / metre, game.ball.vz / metre,
                game.ball.bounces, game.ball.topspin))

            Log.world(String(format:
                "tennis3d   you=(%.1f, %.1f)m face=%.0f° speed=%.1f swing=%@ | %@=(%.1f, %.1f)m face=%.0f° speed=%.1f swing=%@ | %@–%@ games %d–%d",
                game.player.locomotion.x / metre, game.player.locomotion.y / metre,
                game.player.locomotion.facing, game.player.locomotion.speed / metre,
                "\(game.player.swing.stage)",
                board.opponentName,
                game.npc.locomotion.x / metre, game.npc.locomotion.y / metre,
                game.npc.locomotion.facing, game.npc.locomotion.speed / metre,
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

            Log.world(String(format:
                "walktest t=%.1fs pos=(%.1f, %.1f) heading=%.0f° moved=%.1fpx mask=%@ blocked=%@",
                walkTest.elapsed, player.x, player.y, player.rotation, moved,
                maskLoaded ? "loaded" : "none",
                moved < 1 ? "YES" : "no"))

            if walkTest.elapsed > 12 { timer.invalidate() }
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
