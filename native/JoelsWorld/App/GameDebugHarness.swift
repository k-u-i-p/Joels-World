#if DEBUG
import Foundation

/// The launch-argument verification harness: `-walktest`, `-npctrace`, `-uidemo`,
/// `-emotedemo`, `-emote`, `-map`, `-tennisdemo`, `-tennistrace`, `-exitafter`, `-autojoin`.
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
    private var uiDemoStarted = false
    private var requestedInitialMap = false

    init(host: GameViewController) {
        self.host = host
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

    /// `-tennisdemo` swings at every ball the prediction says is reachable; `-exitafter <s>`
    /// presses the exit button once the rally has run long enough to be worth looking at.
    func minigameDidStart(_ minigame: Minigame) {
        guard let game = minigame as? TennisGame else { return }

        if WalkTest.playsTennis, tennisDemoTimer == nil {
            tennisDemoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak game] _ in
                guard let game, let intercept = game.player.lastIntercept, intercept.t >= 0 else {
                    return
                }
                game.handleTap(worldX: intercept.x, worldY: intercept.y)
            }
        }

        if let delay = WalkTest.exitAfterSeconds, tennisExitTimer == nil {
            tennisExitTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak game] _ in
                Log.world("-exitafter: pressing the exit button")
                game?.requestExit()
            }
        }
    }

    func minigameDidEnd() {
        tennisDemoTimer?.invalidate()
        tennisDemoTimer = nil
        tennisExitTimer?.invalidate()
        tennisExitTimer = nil
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
