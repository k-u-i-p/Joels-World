import Foundation

/// Where the editor connects, and with what key. Persisted in `UserDefaults` so the app comes
/// back up pointed at the same server.
struct AdminServerSettings {
    var host: String
    var adminKey: String

    private static let hostKey = "admin_host"
    private static let keyKey = "admin_key"

    static func load() -> AdminServerSettings {
        let defaults = UserDefaults.standard
        return AdminServerSettings(
            host: defaults.string(forKey: hostKey) ?? "joels-world.com",
            adminKey: defaults.string(forKey: keyKey) ?? "")
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: Self.hostKey)
        defaults.set(adminKey, forKey: Self.keyKey)
    }

    /// Pushes the settings into the engine's global config, which is where `NetworkClient`
    /// and every asset fetch read the host from.
    func apply() {
        Config.hostOverride = host.trimmingCharacters(in: .whitespaces)
        let key = adminKey.trimmingCharacters(in: .whitespaces)
        Config.adminKey = key.isEmpty ? nil : key
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

    private(set) var maps: [MapListEntry] = []
    private(set) var isConnected = false

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
            // does not. The server names an admin connection "Admin" when the name is blank.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.state.hasWorld else { return }
                self.network.sendCreateCharacter("")
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
            maps = payload.mapsList ?? maps
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
        return "\(name) — \(state.objects.count) objects, \(state.npcs.count) NPCs"
    }

    // MARK: - Admin traffic

    func changeMap(_ mapId: Int) {
        network.sendChangeMap(mapId)
    }

    func send(_ message: AdminMessage) {
        network.sendAdmin(message.payload)
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
