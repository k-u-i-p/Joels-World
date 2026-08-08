import Foundation
import Network

/// WebSocket client. Port of `network.js`.
///
/// Differences from the JS: the session token lives in the Keychain rather than Capacitor
/// Preferences, reachability comes from `NWPathMonitor` rather than the Capacitor Network
/// plugin, and message delivery is hopped to the main queue so the game loop owns all state.
final class NetworkClient {
    enum State {
        case idle, connecting, open, closed
    }

    private(set) var state: State = .idle

    /// Called on the main queue for every decoded server frame.
    var onMessage: ((ServerMessage) -> Void)?
    /// Called on the main queue when the socket opens.
    var onOpen: (() -> Void)?
    /// Called on the main queue when reconnection has been given up on.
    var onDisconnected: ((String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let session: URLSession
    private let pathMonitor = NWPathMonitor()

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private let baseReconnectDelay: TimeInterval = 1.0

    /// Matches the JS `SYNC_THROTTLE_MS`.
    private let syncThrottle: TimeInterval = 0.05
    private var lastSyncTime: TimeInterval = 0
    private var pendingSyncWorkItem: DispatchWorkItem?

    /// Queued until the socket opens — the JS does the same for `create_character`.
    private var pendingName: String?
    /// True once the world has been received; drives the `state=` query parameter.
    private var hasWorld = false

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)
        startPathMonitor()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: - Connection

    func connect() {
        guard state != .connecting else { return }
        state = .connecting

        let url = Config.websocketURL(state: hasWorld ? "running" : "new",
                                      token: SessionStore.loadToken())
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop(on: task)

        // URLSessionWebSocketTask has no explicit "opened" callback without a delegate;
        // a zero-payload ping round-trip confirms the handshake completed.
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.task === task else { return }
                if let error {
                    self.handleFailure(error.localizedDescription)
                } else {
                    self.state = .open
                    self.reconnectAttempts = 0
                    if let name = self.pendingName {
                        self.pendingName = nil
                        self.sendCreateCharacter(name)
                    }
                    self.onOpen?()
                }
            }
        }
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .closed
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    guard self.task === task else { return }
                    self.handleFailure(error.localizedDescription)
                }
            case .success(let message):
                let data: Data?
                switch message {
                case .data(let d): data = d
                case .string(let s): data = Data(s.utf8)
                @unknown default: data = nil
                }

                if let data {
                    do {
                        let decoded = try ServerMessage.decode(data)
                        DispatchQueue.main.async {
                            guard self.task === task else { return }
                            if case .initWorld = decoded { self.hasWorld = true }
                            if case .sessionToken(let token) = decoded {
                                SessionStore.saveToken(token)
                            }
                            self.onMessage?(decoded)
                        }
                    } catch {
                        Log.net("Failed to decode frame: \(error)")
                    }
                }
                self.receiveLoop(on: task)
            }
        }
    }

    private func handleFailure(_ reason: String) {
        Log.net("Connection lost: \(reason)")
        state = .closed
        task = nil
        attemptReconnect()
    }

    private func attemptReconnect() {
        guard reconnectAttempts < maxReconnectAttempts else {
            onDisconnected?("We were unable to reach the server. Please verify your internet connection.")
            return
        }
        let delay = baseReconnectDelay * pow(1.5, Double(reconnectAttempts))
        reconnectAttempts += 1
        Log.net(String(format: "Reconnecting in %.0fms (attempt %d/%d)",
                       delay * 1000, reconnectAttempts, maxReconnectAttempts))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self, path.status == .satisfied else { return }
            DispatchQueue.main.async {
                guard self.state == .closed else { return }
                self.reconnectAttempts = 0
                self.connect()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "joelsworld.path"))
    }

    // MARK: - Sending

    private func send<T: Encodable>(_ payload: T) {
        guard state == .open, let task else { return }
        do {
            let data = try JSONEncoder().encode(payload)
            guard let string = String(data: data, encoding: .utf8) else { return }
            task.send(.string(string)) { error in
                if let error { Log.net("Send failed: \(error.localizedDescription)") }
            }
        } catch {
            Log.net("Encode failed: \(error)")
        }
    }

    func sendCreateCharacter(_ name: String) {
        guard state == .open else {
            pendingName = name
            return
        }
        Log.net("Sending create_character for \(name)")
        send(CreateCharacterMessage(name: name))
    }

    func sendChat(_ message: String) {
        send(ChatMessage(message: message))
    }

    /// Answering yes to a door dialog. The server replies with a fresh `init`, or with
    /// `map_change_rejected` if the current map has `can_leave: false`.
    ///
    /// `force` is the editor's escape hatch from that rejection; the game never passes it.
    func sendChangeMap(_ mapId: Int, force: Bool = false) {
        send(ChangeMapMessage(mapId: mapId, force: force ? true : nil))
    }

    /// `log` events from NPC interactions, which feed the server-side AI agents.
    func sendLog(message: String, npcId: Int?) {
        send(LogMessage(message: message, npc_id: npcId))
    }

    /// Minigame results (Phase 7). The server echoes `badge_earned` back.
    func sendAwardBadge(_ badge: String) {
        send(AwardBadgeMessage(badge: badge))
    }

    /// Throttled player-state sync, mirroring `syncPlayerToJSON` in `network.js:369`.
    func syncPlayer(_ character: GameCharacter) {
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastSyncTime

        if elapsed >= syncThrottle {
            lastSyncTime = now
            pendingSyncWorkItem?.cancel()
            pendingSyncWorkItem = nil
            send(UpdateMessage(character: character))
        } else if pendingSyncWorkItem == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lastSyncTime = Date.timeIntervalSinceReferenceDate
                self.pendingSyncWorkItem = nil
                self.send(UpdateMessage(character: character))
            }
            pendingSyncWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (syncThrottle - elapsed), execute: item)
        }
    }
}
