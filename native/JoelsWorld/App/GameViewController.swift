import MetalKit
import UIKit

/// Hosts the Metal view and the whole UI layer. Replaces `index.html` + the `main.js`
/// bootstrap.
///
/// What the simulation asks of the app in return — play this sound, raise this dialog, sync
/// the player — is `GameViewController+GameState.swift`. The launch-argument test harness that
/// drives the screen without a finger on it is `GameDebugHarness`.
///
/// Its subviews are `internal` rather than `private` because those two both reach for them;
/// nothing outside this file's neighbours has any business with them.
final class GameViewController: UIViewController {
    private var metalView: MTKView!
    private var renderer: Renderer!
    let state = GameState()
    let network = NetworkClient()
    let audio = GameAudio()

    let joystick = JoystickView()
    private let lobby = LobbyView()
    let dialog = DialogView()

    private let overlay = CharacterOverlayView()
    let hud = HUDView()
    let buttons = ButtonBarView()
    let emotesDialog = EmotesDialogView()
    let badgesDialog = BadgesDialogView()
    let helpDialog = HelpDialogView()
    let minimap = MinimapDialogView()
    private let rejectedOverlay = MapChangeRejectedView()
    private let disconnectDialog = DisconnectDialogView()
    let tennis = TennisView()
    let tennis3d = Tennis3DView()
    let schoolRush = SchoolRushView()
    let football = FootballView()
    let fiveNights = FiveNightsView()
    let schoolEscape = SchoolEscapeView()

    #if DEBUG
    private(set) lazy var debug = GameDebugHarness(host: self)
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupMetalView()
        setupOverlays()
        wireNetwork()

        #if DEBUG
        // `-fivenights`: the night watch with no server behind it, so the scene can be looked at
        // on a machine that is not talking to Cloud Run. See `GameDebugHarness`.
        if debug.startOfflineMinigameIfRequested() { return }
        #endif

        network.connect()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil)
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

        let stick: () -> InputState = { [weak self] in self?.joystick.state ?? InputState() }
        #if DEBUG
        renderer.inputProvider = debug.walkTestInputProvider() ?? stick
        #else
        renderer.inputProvider = stick
        #endif

        renderer.onFrame = { [weak self] viewport in
            self?.updateOverlays(viewport: viewport)
        }

        metalView.delegate = renderer
    }

    /// Which corner the button row is pinned to. Swapped by `setButtonBarOutOfPlay`.
    private var buttonsBottomConstraint: NSLayoutConstraint?
    private var buttonsTopConstraint: NSLayoutConstraint?

    /// **Moves the button row out of the bottom-right corner for the duration of a minigame.**
    ///
    /// Hiding three of the five buttons was not enough. A hit-test probe of the live hierarchy
    /// (`-tennis3dhittest`) reports the bottom-right corner of the court resolving to `UIButton`
    /// rather than `Tennis3DView`, which means a drag that *starts* there never reaches the game
    /// at all — and that corner is exactly where the near player stands when a deep ball has
    /// pushed them back onto the fence. It is the drag you most need and the one that did
    /// nothing.
    ///
    /// The top-right is empty sky above the far baseline in tennis, clear of the scoreboard, and
    /// nobody ever stands there — it is the opponent's end of the court.
    func setButtonBarOutOfPlay(_ outOfPlay: Bool) {
        buttonsBottomConstraint?.isActive = !outOfPlay
        buttonsTopConstraint?.isActive = outOfPlay
    }

    private func setupOverlays() {
        // Bottom to top: world, the 2D minigame surface, nameplates, controls, HUD, dialogs.
        for subview in [tennis, tennis3d, schoolRush, football, fiveNights, schoolEscape,
                        overlay, joystick,
                        buttons, hud,
                        minimap, emotesDialog, badgesDialog, helpDialog, dialog, rejectedOverlay,
                        disconnectDialog, lobby] as [UIView] {
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
            switch self?.state.minigame {
            case let game as TennisGame: game.requestExit()
            case let game as Tennis3DGame: game.requestExit()
            case let game as SchoolRushGame: game.requestExit()
            case let game as FootballGame: game.requestExit()
            case let game as FiveNightsGame: game.requestExit()
            case let game as SchoolEscapeGame: game.requestExit()
            default: break
            }
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
        ]

        // The button row lives in the bottom-right corner in the world, and in the **top**-right
        // corner during a minigame. See `setButtonBarOutOfPlay`.
        buttonsBottomConstraint = buttons.bottomAnchor.constraint(equalTo: guide.bottomAnchor,
                                                                  constant: -20)
        buttonsTopConstraint = buttons.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12)
        constraints += [buttonsBottomConstraint].compactMap { $0 }

        // Everything else is a full-screen layer.
        for subview in [tennis, tennis3d, schoolRush, football, fiveNights, schoolEscape,
                        overlay, hud, minimap,
                        emotesDialog,
                        badgesDialog, helpDialog, dialog, rejectedOverlay, disconnectDialog,
                        lobby] as [UIView] {
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
                if let name = GameDebugHarness.autoJoinName() {
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

        // A 3D one is already on screen behind the HUD; only its score furniture needs a tick,
        // and its nameplates stay off, so there is nothing else to do this frame.
        if state.worldRenderedMinigame != nil {
            tennis3d.step()
            schoolRush.step()
            football.step()
            fiveNights.step()
            schoolEscape.step()
            return
        }

        overlay.update(entries: CharacterOverlay.entries(in: state, viewport: viewport),
                       zoom: state.camera.zoom)

        if minimap.isOpen, let mapData = state.mapData {
            minimap.updateDot(playerX: state.player.x, playerY: state.player.y,
                              mapWidth: mapData.width, mapHeight: mapData.height)
        }
    }

    // MARK: - Chat

    /// Port of the `chatSubmit` handler (`main.js:219-247`). A leading slash names an emote;
    /// anything else is a chat line, echoed locally before the server bounces it back.
    func submitChat(_ message: String) {
        guard !message.isEmpty else { return }

        if message.hasPrefix("/") {
            let command = String(message.dropFirst()).lowercased()

            // "/flush" is a secret, not an emote: standing in the Toilets it flushes the
            // player down to The Sewers (map 9 in maps.json). Anywhere else it stays quiet,
            // which is what keeps it a secret.
            if command == "flush" {
                if let zoneId = state.player.activeBuilding,
                   let zone = state.objects.first(where: { $0.id == zoneId }),
                   zone.name == "Toilets" {
                    audio.playEmoteSound("/media/toilet_flush.mp3")
                    network.sendChangeMap(9)
                } else {
                    Log.world("Ignoring '/flush' outside the Toilets")
                }
                return
            }

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

    @objc private func appWillEnterForeground() {
        audio.resume()
    }

    // MARK: - Server messages

    func handle(_ message: ServerMessage) {
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
            debug.worldDidLoad()
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

    // MARK: - Failure

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
