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

    weak var delegate: AdminSessionDelegate?

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
            network.disconnect()
        }
        delegate?.adminSession(didChangeStatus: "Connecting to \(settings.host)…")
        network.connect()
    }

    private func wire() {
        network.onOpen = { [weak self] in
            guard let self else { return }
            self.isConnected = true
            self.delegate?.adminSession(didChangeStatus: "Connected — waiting for world")
            // A resumed session delivers `init` unprompted; only ask for a character if it
            // does not. The name is a plain one: the editor connects as an ordinary client
            // and the server validates its name like anyone else's.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.state.hasWorld else { return }
                self.network.sendCreateCharacter("Admin")
            }
        }

        network.onDisconnected = { [weak self] message in
            self?.isConnected = false
            self?.delegate?.adminSession(didChangeStatus: "Disconnected — \(message)")
        }

        network.onMessage = { [weak self] message in
            self?.handle(message)
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .initWorld(let payload):
            state.apply(initPayload: payload)
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

        case .chat, .badgeEarned, .mapChangeRejected, .sessionToken:
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

    // MARK: - Editing

    func changeMap(_ mapId: Int) {
        network.sendChangeMap(mapId)
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

/// The editor implements only the two hooks it wants. Everything else on `GameStateDelegate`
/// has a no-op default: `say`, `avatar`, sounds and door dialogs all fire while the camera
/// wanders over a map, and the editor has no surface for any of them.
extension AdminSession: GameStateDelegate {
    func gameStateSyncPlayer(_ character: GameCharacter) {
        network.syncPlayer(character)
    }

    func gameStateSendLog(message: String, npcId: Int) {
        // Editor movement is not gameplay; keep it out of the AI agents' log.
    }

    func gameStateChangeMap(_ mapId: Int) {
        network.sendChangeMap(mapId)
    }
}
