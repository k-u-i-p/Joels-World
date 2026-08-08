import Foundation

/// What an event tree hangs off. `events.js` inspects the source to decide whether an effect
/// lands on the player or on the NPC that owns the tree, and whether a sound is background
/// music or a positional one-shot.
enum EventSource {
    case object(WorldObject)
    case character(GameCharacter)
    case map(MapData)

    var id: Int {
        switch self {
        case .object(let o): return o.id
        case .character(let c): return c.id
        case .map(let m): return m.id
        }
    }

    var name: String? {
        switch self {
        case .object(let o): return o.name
        case .character(let c): return c.name
        case .map(let m): return m.name
        }
    }

    var isMap: Bool {
        if case .map = self { return true }
        return false
    }

    /// `events.js:116` — `shape === 'rect' || shape === 'circle' && !gender`. Trigger zones and
    /// the map itself act *on the player*; an NPC's own tree acts on the NPC.
    var targetsPlayer: Bool {
        switch self {
        case .map:
            return true
        case .object(let o):
            return o.shape == "rect" || o.shape == "circle"
        case .character:
            // Characters have no `shape` field at all, so neither arm can match: an NPC's
            // own tree always acts on the NPC.
            return false
        }
    }
}

/// Which tree is being run, so a numeric reference resolves against the same key on the
/// object it points at (`events.js:196-201`).
enum EventKey: String {
    case onEnter = "on_enter"
    case onExit = "on_exit"
}

enum DialogAction: Equatable {
    case changeMap(Int)
}

struct DialogRequest {
    var text: String
    /// Nil means the dialog is informational — "No" and "Yes" both just dismiss it.
    var confirmAction: DialogAction?
    /// The minigames raise dialogs whose Yes does something the enum cannot name — award a
    /// badge *and* change map, say. `uiManager.showActionDialog` takes a bare callback for
    /// exactly this reason (`ui.js:52`).
    var onConfirm: (() -> Void)?
}

/// The side effects `events.js` produces. `GameState` implements the ones that are pure game
/// state (emotes, speech, network sends) and forwards presentation to the view layer.
protocol EventInterpreterDelegate: AnyObject {
    /// `avatar` — show the NPC portrait and swap the title bar for its name. Phase 5 UI.
    func eventShowAvatar(sourceId: Int, name: String?, imagePath: String)
    /// `say` — the source speaks; the JS parks it on `chatMessage` / `chatTime`.
    func eventSay(sourceId: Int, message: String)
    /// `show_dialog` — a yes/no prompt, the only route to a map change.
    func eventShowDialog(_ request: DialogRequest)
    /// `play_sound` — background music when the source is the map, a pooled one-shot otherwise.
    func eventPlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool)
    /// `emote` / `player_emote` / `clear_emote`.
    func eventSetEmote(_ emote: EmoteState?, sourceId: Int, targetsPlayer: Bool)
    /// `log` — forwarded to the server, which feeds the AI agents watching that NPC.
    func eventLog(message: String, npcId: Int)
}

/// Port of `client/public/src/events.js`.
///
/// The event trees are authored JSON on maps, objects and NPCs: an array of actions, each a
/// dictionary of handler name → payload. A tree can also be a bare object id, meaning
/// "run that object's tree for this same event" — several map objects share one door dialog
/// that way.
///
/// **One deliberate difference:** JS runs an action's handlers in JSON key order, which Swift
/// dictionaries do not preserve. Handlers run in the fixed order they are declared in
/// `events.js` instead. No shipping tree has two handlers whose effects interact, so this is
/// unobservable today — but a new tree that, say, sets an emote and clears it in one action
/// would need real key ordering.
final class EventInterpreter {
    weak var delegate: EventInterpreterDelegate?

    /// `sourceObj._lastLogTimes` (`events.js:161`) — per source, per message text.
    private var lastLogTimes: [Int: [String: TimeInterval]] = [:]

    /// Handler order — see the note on the type.
    private static let handlerOrder = [
        "avatar", "say", "show_dialog", "play_sound",
        "emote", "player_emote", "clear_emote", "log",
    ]

    func reset() {
        lastLogTimes.removeAll()
    }

    /// Port of `processEvents` (`events.js:195`).
    func process(source: EventSource,
                 actions rawActions: JSONValue?,
                 event: EventKey,
                 objects: [WorldObject],
                 player: Player) {
        guard let rawActions else { return }

        var actions = rawActions
        if case .number(let referencedId) = rawActions {
            // A bare id: borrow that object's tree for the same event.
            guard let parent = objects.first(where: { $0.id == Int(referencedId) }) else { return }
            let parentTree = event == .onEnter ? parent.on_enter : parent.on_exit
            guard let parentTree else { return }
            actions = parentTree
        }

        guard let list = actions.arrayValue else { return }

        for action in list {
            guard let entries = action.objectValue else { continue }
            for key in Self.handlerOrder {
                guard let payload = entries[key] else { continue }
                run(handler: key, payload: payload, source: source, player: player)
            }
        }
    }

    // MARK: - Handlers

    private func run(handler: String, payload: JSONValue, source: EventSource, player: Player) {
        switch handler {
        case "avatar":
            guard let raw = payload.stringValue else { return }
            let path = raw.hasPrefix("/") ? raw : "/" + raw
            delegate?.eventShowAvatar(sourceId: source.id, name: source.name, imagePath: path)

        case "say":
            guard let lines = payload.stringArray, let line = lines.randomElement() else { return }
            delegate?.eventSay(sourceId: source.id,
                               message: substitute(line, source: source, player: player))

        case "show_dialog":
            let text = payload["description"]?.stringValue ?? "Proceed?"
            var confirm: DialogAction?
            if payload["type"]?.stringValue == "change_map" {
                if let mapId = payload["map"]?.numberValue, mapId.isFinite {
                    confirm = .changeMap(Int(mapId))
                } else {
                    Log.world("show_dialog: invalid map id \(String(describing: payload["map"]))")
                }
            }
            delegate?.eventShowDialog(DialogRequest(text: text, confirmAction: confirm))

        case "play_sound":
            guard let raw = payload["sound"]?.stringValue else { return }
            let path = raw.hasPrefix("/") ? raw : "/" + raw
            // The JS clamps a numeric volume at zero and defaults anything else to 1.
            let volume = payload["volume"]?.numberValue.map { max(0, $0) } ?? 1
            delegate?.eventPlaySound(sourceId: source.id,
                                     path: path,
                                     volume: volume,
                                     isBackground: source.isMap)

        case "emote":
            guard let name = payload.stringValue else { return }
            delegate?.eventSetEmote(EmoteState(name: name, startTime: Self.nowMilliseconds()),
                                    sourceId: source.id,
                                    targetsPlayer: source.targetsPlayer)

        case "player_emote":
            guard let name = payload.stringValue else { return }
            delegate?.eventSetEmote(EmoteState(name: name, startTime: Self.nowMilliseconds()),
                                    sourceId: source.id,
                                    targetsPlayer: true)

        case "clear_emote":
            delegate?.eventSetEmote(nil, sourceId: source.id, targetsPlayer: source.targetsPlayer)

        case "log":
            runLog(payload: payload, source: source, player: player)

        default:
            break
        }
    }

    /// `log` accepts either a bare string or `{ message, rate_limit }`, where `rate_limit` is
    /// seconds and is tracked per exact message text.
    private func runLog(payload: JSONValue, source: EventSource, player: Player) {
        let message: String?
        var rateLimit: Double = 0

        if let text = payload.stringValue {
            message = text
        } else {
            message = payload["message"]?.stringValue
            rateLimit = payload["rate_limit"]?.numberValue ?? 0
        }

        guard let message, !message.isEmpty else { return }

        if rateLimit > 0 {
            let now = Date.timeIntervalSinceReferenceDate
            let last = lastLogTimes[source.id]?[message] ?? 0
            if now - last < rateLimit { return }
            lastLogTimes[source.id, default: [:]][message] = now
        }

        delegate?.eventLog(message: substitute(message, source: source, player: player),
                           npcId: source.id)
    }

    // MARK: - Template substitution

    /// The placeholders `events.js` fills in on `say` and `log` text.
    private func substitute(_ text: String, source: EventSource, player: Player) -> String {
        var out = text.replacingOccurrences(of: "{name}", with: player.name ?? "Student")
        out = out.replacingOccurrences(of: "{player_id}", with: String(player.id))
        out = out.replacingOccurrences(of: "{npc_name}", with: source.name ?? "NPC")
        out = out.replacingOccurrences(of: "{npc_id}", with: String(source.id))
        return out
    }

    /// Emote start times are JS epoch milliseconds — they travel to other clients over the
    /// wire, so the clock has to match the web client's. `SceneClock` is that wall clock,
    /// except in the character lab, which pins it so an emote poses the same way twice.
    static func nowMilliseconds() -> Double {
        SceneClock.nowMilliseconds
    }
}
