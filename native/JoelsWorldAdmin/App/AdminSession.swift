import Foundation

/// Where the editor connects. Persisted in `UserDefaults` so the app comes back up pointed at
/// the same server.
///
/// There is no admin key any more. The editor's connection is an ordinary one — it exists to
/// show live players moving over the map being edited, and nothing else. Edits go to `data/`
/// on disk through `WorldFileStore`, so there is nothing for a server to authorise.
struct AdminServerSettings {
    var host: String

    private static let hostKey = "admin_host"

    /// `-host <host[:port]>` wins, so a scripted run points itself at a local server the same
    /// way `-data` points it at a checkout; otherwise the last host the operator connected to.
    static func load() -> AdminServerSettings {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-host"), index + 1 < arguments.count {
            return AdminServerSettings(host: arguments[index + 1])
        }
        return AdminServerSettings(host: UserDefaults.standard.string(forKey: hostKey) ?? "joels-world.com")
    }

    func save() {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
    }

    /// Pushes the settings into the engine's global config, which is where `NetworkClient`
    /// reads the host from.
    func apply() {
        Config.hostOverride = host.trimmingCharacters(in: .whitespaces)
    }
}

/// Where the game's own UI gets drawn. The map view controller is the only object with a
/// surface to put it on, so the session holds it at arm's length through this.
protocol AdminGameUI: AnyObject {
    func showDialog(_ request: DialogRequest)
    func hideDialog()
    func showAvatar(sourceId: Int, name: String?, imagePath: String)
    /// A nil `sourceId` dismisses whatever portrait is up; an id only dismisses that NPC's.
    func hideAvatar(sourceId: Int?)
    func setMapName(_ name: String?)
    func addChatMessage(sender: String, message: String)
    func clearChat()
}

protocol AdminSessionDelegate: AnyObject {
    /// A fresh `init` frame landed: new map, objects and NPCs.
    func adminSessionDidLoadWorld()
    /// `objects_update` or `npcs_update` — the server re-read the JSON after an edit.
    func adminSessionDidReplaceEntities()
    func adminSession(didChangeStatus status: String)
}

/// Owns the network client and the game state for the editor. The renderer is attached
/// separately by the view controller, because it needs the `MTKView`.
final class AdminSession {
    let state = GameState()
    let network = NetworkClient()

    /// The same sound stack the game has. The editor used to have none — every audio hook
    /// below was a no-op — which meant a `play_sound` you had just authored could only be
    /// checked by building the game onto a phone.
    let audio = GameAudio()

    weak var delegate: AdminSessionDelegate?

    /// Set by `AdminMapViewController` once its views exist. Nil until then, which is why
    /// every forward below is optional rather than assumed.
    weak var ui: AdminGameUI?

    /// The map list comes out of the bundled `maps.json` now, not out of `init`.
    let maps: [MapListEntry] = WorldData.mapsList
    private(set) var isConnected = false

    /// Where edits land. Read-only when it could not find the checkout's `data/` — the editor
    /// is still perfectly usable for looking around, but nothing can be saved.
    let files = WorldFileStore()

    /// The last thing a save said, shown in the status line. Nil when nothing has been saved.
    private(set) var lastSaveMessage: String?

    private var settings = AdminServerSettings.load()

    var serverSettings: AdminServerSettings { settings }

    /// Keeps trying until the socket is actually open, and never stops.
    ///
    /// Two things need catching, and one timer catches both.
    ///
    /// The first is a connection that *fails*: `NetworkClient` retries five times on its own,
    /// then gives up and says so. The editor is a window somebody leaves open all day, across
    /// server restarts and closed lids, so giving up is the wrong ending for it.
    ///
    /// The second is a connection that neither opens nor fails. `NetworkClient` sets
    /// `waitsForConnectivity`, and detects "open" with a ping round-trip — so when the server
    /// is unreachable at launch, the ping's completion is simply never called. No error, no
    /// reconnect, no `onDisconnected`: the editor sits on "Connecting to joels-world.com…"
    /// for as long as you leave it, and the only way out is the Connect button. That is the
    /// bug behind "the admin doesn't connect". A connection that has not opened by the time
    /// this fires is torn down and started again from scratch.
    private var retryTimer: Timer?
    private let retryInterval: TimeInterval = 8
    private var attempt = 0

    init() {
        state.delegate = self
        settings.apply()
        wire()
    }

    func connect(using newSettings: AdminServerSettings? = nil) {
        if let newSettings {
            settings = newSettings
            settings.save()
            settings.apply()
            // A token issued by one server means nothing to another.
            SessionStore.clearToken()
        }
        attempt = 0
        startConnecting()
    }

    private func startConnecting() {
        attempt += 1
        isConnected = false
        // Unconditional: an attempt that hung has a live task holding the old callbacks, and
        // `NetworkClient.connect` refuses to start a second one while it thinks it is still
        // connecting.
        network.disconnect()

        let suffix = attempt > 1 ? " (attempt \(attempt))" : ""
        delegate?.adminSession(didChangeStatus: "Connecting to \(settings.host)…\(suffix)")
        if attempt > 1 { Log.net("Retrying the connection to \(settings.host) — attempt \(attempt)") }

        network.connect()
        scheduleRetry()
    }

    private func scheduleRetry() {
        cancelRetry()
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval,
                                          repeats: false) { [weak self] _ in
            guard let self, !self.isConnected else { return }
            self.startConnecting()
        }
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func wire() {
        network.onOpen = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.attempt = 0
            self.cancelRetry()
            // The socket's "opened" callback is a ping round-trip, so on a resumed session it
            // can land *after* the `init` frame it was waiting for. Don't overwrite a status
            // line that is already describing a loaded world.
            if !self.state.hasWorld {
                self.delegate?.adminSession(didChangeStatus: "Connected — waiting for world")
            } else {
                self.delegate?.adminSession(didChangeStatus: self.statusLine())
            }
            // A resumed session delivers `init` unprompted; only ask for a character if it
            // does not. The name is a plain one: the editor connects as an ordinary client
            // and the server validates its name like anyone else's.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.state.hasWorld else { return }
                self.network.sendCreateCharacter("Admin")
            }
        }

        network.onDisconnected = { [weak self] message in
            guard let self else { return }
            self.isConnected = false
            self.scheduleRetry()
            self.delegate?.adminSession(didChangeStatus: "Disconnected — \(message) Trying again "
                                                      + "in \(Int(self.retryInterval))s.")
        }

        network.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .initWorld(let payload):
            state.apply(initPayload: payload)
            ui?.setMapName(state.mapData?.name)
            ui?.clearChat()
            delegate?.adminSessionDidLoadWorld()
            delegate?.adminSession(didChangeStatus: statusLine())
            requestInitialMapIfNeeded()

        case .tick(let characters):
            state.applyTick(characters)

        case .update(let character):
            state.applyTick([character])

        case .disconnect(let id):
            state.removeCharacter(id: id)

        case .objectsUpdate(let objects):
            state.replaceObjects(objects)
            delegate?.adminSessionDidReplaceEntities()

        case .npcsUpdate(let npcs):
            state.replaceNPCs(npcs)
            delegate?.adminSessionDidReplaceEntities()

        case .error(let text):
            delegate?.adminSession(didChangeStatus: "Server error — \(text)")
            Log.net("Server error: \(text)")

        case .chat(let id, let text):
            // Both halves of what the game does with a line: a bubble over the speaker's head,
            // and a row in the HUD's feed.
            let sender = state.applyChat(id: id, message: text)
            ui?.addChatMessage(sender: sender, message: text)
            Log.world("Chat — \(sender): \(text)")

        case .badgeEarned(let badge):
            // The editor connects as an ordinary player, so it can be awarded one.
            state.addBadge(badge)
            ui?.addChatMessage(sender: "System", message: "You earned the badge: \(badge)!")
            Log.world("Badge earned: \(badge)")

        case .mapChangeRejected:
            // The editor forces its map changes, so this should not arrive any more. If it
            // does, say so rather than leaving the picker looking broken.
            delegate?.adminSession(didChangeStatus: "Map change refused by the server — the "
                                                 + "current map has can_leave: false.")
            audio.playEffect("/media/buzzer.mp3", volume: 1, rate: 1)
            Log.world("Map change rejected")

        case .sessionToken:
            break

        case .unknown(let type):
            Log.net("Ignoring unknown message type '\(type)'")
        }
    }

    /// `-map <id>` opens straight onto a map, mirroring the iOS build's argument of the same
    /// name. The server also remembers the last map a session was on, so this is the only way
    /// to make a scripted run deterministic.
    private var requestedInitialMap = false

    private func requestInitialMapIfNeeded() {
        guard let mapId = WalkTest.initialMapId, !requestedInitialMap else { return }
        requestedInitialMap = true
        guard state.mapData?.id != mapId else { return }
        network.sendChangeMap(mapId)
    }

    private func statusLine() -> String {
        let name = state.mapData?.name ?? "map \(state.mapData?.id ?? -1)"
        var line = "\(name) — \(state.objects.count) objects, \(state.npcs.count) NPCs"
        if let lastSaveMessage { line += " · \(lastSaveMessage)" }
        guard files.dataDirectory != nil else {
            return "⚠︎ Read-only: no data/ directory found, so nothing can be saved. Launch "
                 + "with -data <path to the checkout's data/>.\n\(line)"
        }
        return line
    }

    // MARK: - Chat

    /// Port of `GameViewController.submitChat`. The `/emote` branch is kept: the editor
    /// connects as a real player, so an operator checking how an emote looks and sounds on a
    /// map should be able to fire one from the same place a player would.
    func submitChat(_ message: String) {
        guard !message.isEmpty else { return }

        if message.hasPrefix("/") {
            let command = String(message.dropFirst()).lowercased()
            // Gated on the local emote table, not the server's, exactly as `main.js:222` does.
            guard let definition = Emotes.definition(command) else {
                Log.world("Ignoring unknown command '/\(command)'")
                return
            }
            audio.clearEmoteAudio()
            state.setPlayerEmote(EmoteState(name: command,
                                            startTime: EventInterpreter.nowMilliseconds()))

            // The emote announces itself in chat — "{name} waved at {target_name}". The line
            // comes back off the socket as an ordinary `chat`, which is what fills the feed.
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

    // MARK: - Editing

    /// Forced, unlike the game's. Detention is authored `can_leave: false`, so the server
    /// answers an ordinary `change_map` from there with `map_change_rejected` — which left the
    /// map picker doing nothing at all, and left the editor stuck on whichever map the saved
    /// session last put it on. An editor has to be able to open any map and leave it again.
    func changeMap(_ mapId: Int) {
        network.sendChangeMap(mapId, force: true)
    }

    /// A door prompt, on the other hand, is one of the things the editor exists to *test*, so
    /// it goes through unforced and gets refused exactly as it would in the game.
    func changeMapThroughDoor(_ mapId: Int) {
        network.sendChangeMap(mapId)
    }

    // MARK: - Camera

    /// Tips the camera over, without saving. The sidebar slider and R/F both come through here.
    func setCameraPitch(_ pitch: Double) {
        state.camera.setPitch(delta: pitch - state.camera.pitch)
    }

    /// Zooms without saving. Same clamp as the scroll wheel's.
    func setCameraZoom(_ zoom: Double) {
        state.camera.zoom = min(max(0.1, zoom), 5)
    }

    /// **Writes where the camera is standing into the map's own record in `maps.json`** —
    /// `camera_angle` and `default_zoom`, for whichever map is open in the editor.
    ///
    /// The angle is rounded to whole degrees and the zoom to two places: the file is meant to be
    /// read and edited by hand, and neither a tenth of a degree nor a thousandth of a zoom is a
    /// difference anyone can see. What is saved is what the game opens that map at.
    @discardableResult
    func saveCameraView() -> Bool {
        let degrees = (state.camera.pitch * 180 / .pi).rounded()
        let zoom = (state.camera.zoom * 100).rounded() / 100
        guard send(.updateMap(updates: ["camera_angle": JSONValue(degrees),
                                        "default_zoom": JSONValue(zoom)]))
        else { return false }
        // Keep the in-memory record in step, so nothing in this session reads back the old view.
        state.setMapCameraView(angle: degrees, zoom: zoom)
        lastSaveMessage = "\(state.mapData?.name ?? "map"): \(Int(degrees))°, zoom \(zoom) saved"
        delegate?.adminSession(didChangeStatus: statusLine())
        return true
    }

    /// Applies an edit to the files on disk and to the view, in that order.
    ///
    /// The in-memory update is not an optimism — it is the only update the editor is
    /// guaranteed to get. A locally-running server watching `data/` will send back an
    /// `objects_update` a moment later and overwrite it with the same content; a remote server
    /// reading a different checkout will not, and the editor should still show what it just
    /// wrote.
    @discardableResult
    func send(_ message: AdminMessage) -> Bool {
        guard let mapId = state.mapData?.id else {
            lastSaveMessage = "no map loaded"
            delegate?.adminSession(didChangeStatus: statusLine())
            return false
        }

        do {
            let kind = try files.apply(message, mapId: mapId)
            switch kind {
            case .objects: state.replaceObjects(try files.objects(mapId: mapId))
            case .npcs: state.replaceNPCs(try files.npcs(mapId: mapId))
            // Nothing to re-read. `maps.json` is decoded once from the *bundle* at launch
            // (`WorldData.maps`), so the file that was just written is not the copy this
            // process is running on; the caller has already applied the change to the live
            // camera, and every app picks it up on its next build.
            case .map: break
            }
            lastSaveMessage = "saved"
            delegate?.adminSessionDidReplaceEntities()
            delegate?.adminSession(didChangeStatus: statusLine())
            return true
        } catch {
            lastSaveMessage = "save failed — \(error)"
            Log.world("Edit failed: \(error)")
            delegate?.adminSession(didChangeStatus: statusLine())
            return false
        }
    }
}

/// Everything the simulation asks of the app around it — the editor's answers are the game's.
///
/// Walking the camera through a map is how the operator checks that an NPC's events fire where
/// they were authored to, and that check is only worth anything if it looks and sounds like the
/// game: the same portraits, the same door prompts, the same sounds at the same trigger lines.
extension AdminSession: GameStateDelegate {
    func gameStateSyncPlayer(_ character: GameCharacter) {
        network.syncPlayer(character)
    }

    /// Forwarded, like the game's. These are what an NPC's `log` actions fire when the camera
    /// walks into its radius, and they are the *only* thing that wakes the server's AI agents
    /// (`ChatManager.handleLogMessage` → `AIAgentManager.appendEvent`). Swallowing them here —
    /// which is what this used to do — meant an agent NPC never said anything to the editor,
    /// so there was no way to check an agent's writing without loading the game on a phone.
    ///
    /// The cost of that is real, though: each one can pulse an agent, and an agent pulse is a
    /// Claude API call. Walking the editor around a map full of agent NPCs spends money.
    func gameStateSendLog(message: String, npcId: Int) {
        Log.world("Log → npc \(npcId): \(message)")
        network.sendLog(message: message, npcId: npcId)
    }

    func gameStateChangeMap(_ mapId: Int) {
        network.sendChangeMap(mapId)
    }

    // MARK: - Dialogs and portraits

    func gameStateShowDialog(_ request: DialogRequest) {
        ui?.showDialog(request)
    }

    func gameStateHideDialog() {
        ui?.hideDialog()
    }

    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String) {
        Log.world("Avatar: \(name ?? "NPC") (\(sourceId)) \(imagePath)")
        ui?.showAvatar(sourceId: sourceId, name: name, imagePath: imagePath)
    }

    func gameStateHideAvatar() {
        ui?.hideAvatar(sourceId: nil)
    }

    /// Walking back out of an NPC's radius takes its portrait and anything it raised with it.
    func gameStateCleanupNPCUI(sourceId: Int) {
        ui?.hideAvatar(sourceId: sourceId)
        ui?.hideDialog()
    }

    /// Not a port: the game shows a `say` as a bubble over the speaker and nothing else, and
    /// in the editor the speaker is often off screen or behind a panel. It goes in the feed
    /// too, so an authored line can be read back where it was triggered.
    func gameStateDidSay(sourceId: Int, name: String?, message: String) {
        Log.world("Say: \(name ?? "NPC") (\(sourceId)): \(message)")
        ui?.addChatMessage(sender: name ?? "NPC \(sourceId)", message: message)
    }

    // MARK: - Audio

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

    /// Footsteps, for the camera. It *is* the player here — it walks the real clip mask — so
    /// it makes the same noise doing it.
    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool) {
        audio.setWalking(active: active, isRunning: isRunning)
    }

    func gameStateClearEmoteAudio() {
        audio.clearEmoteAudio()
    }

    func gameStatePlayEffect(path: String, volume: Double, rate: Double) {
        audio.playEffect(path, volume: volume, rate: rate)
    }
}
