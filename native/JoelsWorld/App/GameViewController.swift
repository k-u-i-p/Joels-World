import MetalKit
import UIKit

/// Hosts the Metal view and the whole UI layer. Replaces `index.html` + the `main.js`
/// bootstrap.
final class GameViewController: UIViewController {
    private var metalView: MTKView!
    private var renderer: Renderer!
    private let state = GameState()
    private let network = NetworkClient()
    private let audio = GameAudio()

    private let joystick = JoystickView()
    private let lobby = LobbyView()
    private let dialog = DialogView()

    private let overlay = CharacterOverlayView()
    private let hud = HUDView()
    private let buttons = ButtonBarView()
    private let emotesDialog = EmotesDialogView()
    private let badgesDialog = BadgesDialogView()
    private let helpDialog = HelpDialogView()
    private let minimap = MinimapDialogView()
    private let rejectedOverlay = MapChangeRejectedView()
    private let disconnectDialog = DisconnectDialogView()
    private let tennis = TennisView()

    #if DEBUG
    private var walkTest: WalkTest?
    private var walkTestTimer: Timer?
    private var npcTraceTimer: Timer?
    private var tennisDemoTimer: Timer?
    private var tennisExitTimer: Timer?
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupMetalView()
        setupOverlays()
        wireNetwork()

        EmoteCatalog.load()
        network.connect()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Setup

    private func setupMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            showFatal("This device does not support Metal.")
            return
        }

        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        view.addSubview(metalView)

        guard let renderer = Renderer(view: metalView, state: state) else {
            showFatal("Failed to initialise the renderer.")
            return
        }
        self.renderer = renderer

        #if DEBUG
        if WalkTest.isEnabled {
            let walkTest = WalkTest()
            self.walkTest = walkTest
            renderer.inputProvider = { walkTest.currentInput() }
        } else {
            renderer.inputProvider = { [weak self] in self?.joystick.state ?? InputState() }
        }
        #else
        renderer.inputProvider = { [weak self] in self?.joystick.state ?? InputState() }
        #endif

        renderer.onFrame = { [weak self] viewport in
            self?.updateOverlays(viewport: viewport)
        }

        metalView.delegate = renderer
    }

    private func setupOverlays() {
        // Bottom to top: world, the 2D minigame surface, nameplates, controls, HUD, dialogs.
        for subview in [tennis, overlay, joystick, buttons, hud, minimap, emotesDialog,
                        badgesDialog, helpDialog, dialog, rejectedOverlay, disconnectDialog,
                        lobby] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        joystick.isHidden = true
        buttons.isHidden = true
        hud.isHidden = true
        lobby.isHidden = true

        lobby.onStart = { [weak self] name in
            self?.lobby.setBusy(true)
            self?.network.sendCreateCharacter(name)
        }

        dialog.onConfirm = { [weak self] action in
            switch action {
            case .changeMap(let mapId):
                Log.world("Requesting map change to \(mapId)")
                self?.network.sendChangeMap(mapId)
            }
        }

        hud.onChatSubmit = { [weak self] message in
            self?.submitChat(message)
        }

        buttons.onMap = { [weak self] in
            guard let self else { return }
            self.minimap.present(mapId: self.state.mapData?.id)
        }
        buttons.onBadges = { [weak self] in
            guard let self else { return }
            self.badgesDialog.setEarned(self.state.player.badges)
            self.badgesDialog.present()
        }
        buttons.onEmotes = { [weak self] in self?.emotesDialog.present() }
        buttons.onHelp = { [weak self] in self?.helpDialog.present() }
        buttons.onExit = { [weak self] in
            (self?.state.minigame as? TennisGame)?.requestExit()
        }

        emotesDialog.onEmote = { [weak self] command in self?.submitChat(command) }

        disconnectDialog.onReconnect = { [weak self] in self?.network.connect() }

        // A tap on the world dismisses the keyboard, the way blurring the web chat input does.
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        metalView.addGestureRecognizer(tap)

        let guide = view.safeAreaLayoutGuide
        var constraints: [NSLayoutConstraint] = [
            joystick.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            joystick.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -32),
            joystick.widthAnchor.constraint(equalToConstant: 130),
            joystick.heightAnchor.constraint(equalToConstant: 130),

            buttons.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -20),
        ]

        // Everything else is a full-screen layer.
        for subview in [tennis, overlay, hud, minimap, emotesDialog, badgesDialog, helpDialog,
                        dialog, rejectedOverlay, disconnectDialog, lobby] as [UIView] {
            constraints += [
                subview.topAnchor.constraint(equalTo: view.topAnchor),
                subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func wireNetwork() {
        state.delegate = self

        network.onOpen = { [weak self] in
            guard let self else { return }
            self.disconnectDialog.dismiss()
            // Give a resumed session a moment to deliver `init` before prompting for a name.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard !self.state.hasWorld else { return }

                #if DEBUG
                // `-autojoin <Name>` skips the lobby, for automated verification runs.
                if let name = Self.autoJoinName() {
                    Log.net("Auto-joining as \(name)")
                    self.network.sendCreateCharacter(name)
                    return
                }
                #endif

                self.lobby.isHidden = false
            }
        }

        network.onDisconnected = { [weak self] message in
            self?.disconnectDialog.present(message: message)
        }

        network.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    // MARK: - Per-frame UI

    /// Repositions the nameplates, the speech bubbles and the minimap dot. Runs after the
    /// simulation step, from the render loop.
    private func updateOverlays(viewport: SIMD2<Float>) {
        guard state.hasWorld else { return }

        // A 2D minigame redraws its own surface instead, once per simulated frame.
        if state.suppressesWorldRendering {
            tennis.step()
            return
        }

        let camera = state.camera
        var entries: [OverlayEntry] = []
        entries.reserveCapacity(16)

        for subject in state.overlaySubjects {
            // The JS frustum test projects five units above the character's origin.
            let probe = camera.project(worldX: subject.x, worldY: subject.y, z: subject.z + 5,
                                       viewport: viewport)
            let isVisible = probe.ndc.z <= 1 && abs(probe.ndc.x) <= 1.3 && abs(probe.ndc.y) <= 1.3
            guard isVisible else { continue }

            let anchor = camera.project(worldX: subject.x, worldY: subject.y, z: subject.z,
                                        viewport: viewport)
            let live = CharacterOverlayView.isBubbleLive(chatTime: subject.chatTime)
            entries.append(OverlayEntry(
                id: subject.id,
                name: subject.name,
                screen: CGPoint(x: CGFloat(anchor.screen.x), y: CGFloat(anchor.screen.y)),
                isVisible: true,
                chatMessage: live ? subject.chatMessage : nil,
                showsNameplate: !subject.hideNameplate))
        }

        overlay.update(entries: entries, zoom: camera.zoom)

        if minimap.isOpen, let mapData = state.mapData {
            minimap.updateDot(playerX: state.player.x, playerY: state.player.y,
                              mapWidth: mapData.width, mapHeight: mapData.height)
        }
    }

    // MARK: - Chat

    /// Port of the `chatSubmit` handler (`main.js:219-247`). A leading slash names an emote;
    /// anything else is a chat line, echoed locally before the server bounces it back.
    private func submitChat(_ message: String) {
        guard !message.isEmpty else { return }

        if message.hasPrefix("/") {
            let command = String(message.dropFirst()).lowercased()
            // `main.js:222` gates on the local emote table, not the server's list. They come
            // from the same file, but gating locally keeps the command path off the network.
            guard let definition = Emotes.definition(command) else {
                Log.world("Ignoring unknown command '/\(command)'")
                return
            }
            audio.clearEmoteAudio()
            state.setPlayerEmote(EmoteState(name: command,
                                            startTime: EventInterpreter.nowMilliseconds()))

            // The emote announces itself in chat — "{name} waved at {target_name}" — and then
            // plays whatever sound its table entry names.
            if let line = state.emoteMessage(for: command) {
                network.sendChat(line)
                state.setLocalChat(line)
            }
            if let sound = definition.sound {
                audio.playEmoteSound(sound)
            }
            return
        }

        network.sendChat(message)
        state.setLocalChat(message)
    }

    @objc private func backgroundTapped() {
        hud.dismissKeyboard()
    }

    @objc private func appDidEnterBackground() {
        audio.suspend()
    }

    // MARK: - Server messages

    private func handle(_ message: ServerMessage) {
        switch message {
        case .initWorld(let payload):
            lobby.isHidden = true
            lobby.setBusy(false)
            joystick.isHidden = false
            buttons.isHidden = false
            hud.isHidden = false
            overlay.reset()
            state.apply(initPayload: payload)
            hud.setMapName(state.mapData?.name)
            badgesDialog.setEarned(state.player.badges)
            #if DEBUG
            startWalkTestLoggingIfNeeded()
            startNPCTraceIfNeeded()
            startUIDemoIfNeeded()
            startEmoteDemoIfNeeded()
            startTennisTraceIfNeeded()
            requestInitialMapIfNeeded()
            if EmoteDump.isEnabled { EmoteDump.run() }
            #endif

        case .tick(let characters):
            state.applyTick(characters)

        case .update(let character):
            state.applyTick([character])

        case .disconnect(let id):
            state.removeCharacter(id: id)
            overlay.removeCharacter(id: id)

        case .objectsUpdate(let objects):
            state.replaceObjects(objects)

        case .npcsUpdate(let npcs):
            state.replaceNPCs(npcs)

        case .chat(let id, let text):
            let sender = state.applyChat(id: id, message: text)
            hud.addChatMessage(sender: sender, message: text)
            Log.world("Chat — \(sender): \(text)")

        case .badgeEarned(let badge):
            state.addBadge(badge)
            hud.addChatMessage(sender: "System", message: "You earned the badge: \(badge)!")
            badgesDialog.setEarned(state.player.badges)
            Log.world("Badge earned: \(badge)")

        case .mapChangeRejected:
            // `can_leave: false` — Detention keeps you until the server says otherwise.
            rejectedOverlay.flash()
            audio.playEffect("/media/buzzer.mp3")
            Log.world("Map change rejected")

        case .error(let text):
            lobby.setBusy(false)
            lobby.showError(text)

        case .sessionToken:
            break   // Stored by NetworkClient.

        case .unknown(let type):
            Log.net("Ignoring unknown message type '\(type)'")
        }
    }

    #if DEBUG
    /// Samples the player each half second so collision behaviour is visible in the log.
    private func startWalkTestLoggingIfNeeded() {
        guard let walkTest, walkTestTimer == nil else { return }

        var previous: (x: Double, y: Double)?
        walkTestTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }

            let player = self.state.player
            let maskLoaded = self.state.physics.clipMask != nil
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
    private func startNPCTraceIfNeeded() {
        guard WalkTest.tracesNPCs, npcTraceTimer == nil else { return }

        npcTraceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            for npc in self.state.npcs where npc.roam_radius != nil || npc.waypoints != nil {
                let visual = self.state.visuals[npc.id]
                Log.world(String(format: "npc %d %@ pos=(%.1f, %.1f) rot=%.0f target=(%.1f, %.1f) rot=%.0f wait=%.2f idx=%d",
                                 npc.id, npc.name ?? "?", npc.x, npc.y, npc.rotation ?? 0,
                                 visual?.targetX ?? .nan, visual?.targetY ?? .nan,
                                 visual?.targetRotation ?? .nan,
                                 visual?.waitTimer ?? .nan, visual?.moveIndex ?? -1))
            }
        }
    }

    /// `-emotedemo`: steps the player through every emote in the table so each pose can be
    /// screenshotted. Goes through `submitChat`, so it exercises the whole path the picker
    /// takes — pose, chat line and sound.
    private var emoteDemoTimer: Timer?

    private func startEmoteDemoIfNeeded() {
        if let held = WalkTest.heldEmote, emoteDemoTimer == nil {
            // Re-issued on a timer because the short emotes expire on their own duration.
            emoteDemoTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, self.state.player.emote?.name != held else { return }
                self.submitChat("/\(held)")
            }
            return
        }

        guard let interval = WalkTest.emoteDemoInterval, emoteDemoTimer == nil else { return }
        let names = Emotes.table.keys.sorted()
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
            self.submitChat("/\(name)")
        }
    }

    /// `-uidemo`: opens each piece of the UI in turn so a screenshot can be taken of it.
    /// `simctl` cannot inject touches, so this is the only way to see the dialogs on device.
    private var uiDemoStarted = false

    private func startUIDemoIfNeeded() {
        guard WalkTest.runsUIDemo, !uiDemoStarted else { return }
        uiDemoStarted = true

        let steps: [(Double, String, () -> Void)] = [
            (1.0, "chat feed", { [weak self] in
                guard let self else { return }
                self.hud.addChatMessage(sender: "Frank", message: "Anyone seen my lunch?")
                self.hud.addChatMessage(sender: "Mr Savage", message: "Back to class, all of you.")
                self.hud.addChatMessage(sender: "Tester", message: "Hello from the native client!")
                self.state.setLocalChat("Hello from the native client!")
            }),
            (4.0, "emotes dialog", { [weak self] in self?.emotesDialog.present() }),
            (7.0, "badges dialog", { [weak self] in
                guard let self else { return }
                self.emotesDialog.dismiss()
                self.handle(.badgeEarned("tennis"))
                self.badgesDialog.present()
            }),
            (10.0, "help dialog", { [weak self] in
                self?.badgesDialog.dismiss()
                self?.helpDialog.present()
            }),
            (13.0, "minimap", { [weak self] in
                guard let self else { return }
                self.helpDialog.dismiss()
                self.minimap.present(mapId: self.state.mapData?.id)
            }),
            (16.0, "map change rejected", { [weak self] in
                self?.minimap.dismiss()
                self?.handle(.mapChangeRejected)
            }),
            (18.0, "emote command", { [weak self] in
                // The same path the emote picker takes: a `/name` line off the chat field.
                self?.submitChat("/dance")
            }),
            (19.0, "door dialog", { [weak self] in
                self?.dialog.present(DialogRequest(text: "Enter the Pool building?",
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
    private var requestedInitialMap = false

    private func requestInitialMapIfNeeded() {
        guard let mapId = WalkTest.initialMapId, !requestedInitialMap else { return }
        requestedInitialMap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            Log.world("-map: requesting map \(mapId)")
            self?.network.sendChangeMap(mapId)
        }
    }

    /// `-tennistrace`: one line a second describing the point in play.
    private var tennisTraceTimer: Timer?

    private func startTennisTraceIfNeeded() {
        guard WalkTest.tracesTennis, tennisTraceTimer == nil else { return }

        tennisTraceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let game = self?.state.minigame as? TennisGame else { return }
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

    /// Reads `-autojoin <Name>` from the launch arguments.
    private static func autoJoinName() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-autojoin"),
              arguments.index(after: flag) < arguments.endIndex
        else { return nil }
        let name = arguments[arguments.index(after: flag)]
        return name.allSatisfy { $0.isLetter && $0.isASCII } ? name : nil
    }
    #endif

    // MARK: - Game state

    private func showFatal(_ message: String) {
        let label = UILabel(frame: view.bounds)
        label.text = message
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }
}

// MARK: - GameStateDelegate

extension GameViewController: GameStateDelegate {
    func gameStateSyncPlayer(_ character: GameCharacter) {
        network.syncPlayer(character)
    }

    func gameStateSendLog(message: String, npcId: Int) {
        Log.world("Log → npc \(npcId): \(message)")
        network.sendLog(message: message, npcId: npcId)
    }

    func gameStateShowDialog(_ request: DialogRequest) {
        dialog.present(request)
        #if DEBUG
        if WalkTest.autoConfirmsDialogs, request.confirmAction != nil || request.onConfirm != nil {
            Log.world("Dialog: '\(request.text)' — auto-confirming")
            let action = request.confirmAction
            let handler = request.onConfirm
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.dialog.isHidden else { return }
                self.dialog.dismiss()
                if case .changeMap(let mapId) = action { self.network.sendChangeMap(mapId) }
                handler?()
            }
        }
        #endif
    }

    func gameStateHideDialog() {
        dialog.dismiss()
    }

    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String) {
        Log.world("Avatar: \(name ?? "NPC") (\(sourceId)) \(imagePath)")
        hud.showAvatar(sourceId: sourceId, name: name, imagePath: imagePath)
    }

    func gameStateHideAvatar() {
        hud.hideAvatar(sourceId: nil)
    }

    func gameStateCleanupNPCUI(sourceId: Int) {
        hud.hideAvatar(sourceId: sourceId)
        dialog.dismiss()
    }

    func gameStateDidSay(sourceId: Int, name: String?, message: String) {
        Log.world("Say: \(name ?? "NPC") (\(sourceId)): \(message)")
    }

    func gameStatePlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool) {
        Log.world(String(format: "Sound%@: %@ @ %.2f (source %d)",
                         isBackground ? " (background)" : "", path, volume, sourceId))
        audio.play(sourceId: sourceId, path: path, volume: volume, isBackground: isBackground)
    }

    func gameStateStopSound(sourceId: Int) {
        audio.stop(sourceId: sourceId)
    }

    func gameStateStopBackgroundSound() {
        audio.stopBackground()
    }

    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool) {
        audio.setWalking(active: active, isRunning: isRunning)
    }

    func gameStateClearEmoteAudio() {
        audio.clearEmoteAudio()
    }

    func gameStatePlayEffect(path: String, volume: Double, rate: Double) {
        audio.playEffect(path, volume: volume, rate: rate)
    }

    func gameStateChangeMap(_ mapId: Int) {
        Log.world("Requesting map change to \(mapId)")
        network.sendChangeMap(mapId)
    }

    func gameStateAwardBadge(_ badge: String) {
        Log.world("Claiming badge: \(badge)")
        network.sendAwardBadge(badge)
    }

    /// The minigame takes the screen: the joystick and the chat HUD go away, the map button
    /// becomes the exit button, and the game's own surface comes up (`tennis.js:662-693`).
    func gameStateDidStartMinigame(_ minigame: Minigame) {
        joystick.isHidden = true
        hud.isHidden = true
        buttons.setMinigameMode(true)

        if let game = minigame as? TennisGame {
            tennis.present(game: game)
            #if DEBUG
            startTennisDemoIfNeeded(game: game)
            #endif
        }
    }

    #if DEBUG
    /// `-tennisdemo` / `-exitafter <s>`.
    private func startTennisDemoIfNeeded(game: TennisGame) {
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

    private func stopTennisDemo() {
        tennisDemoTimer?.invalidate()
        tennisDemoTimer = nil
        tennisExitTimer?.invalidate()
        tennisExitTimer = nil
    }
    #endif

    func gameStateDidEndMinigame() {
        #if DEBUG
        stopTennisDemo()
        #endif
        tennis.dismiss()
        buttons.setMinigameMode(false)
        joystick.isHidden = false
        hud.isHidden = false
    }
}
