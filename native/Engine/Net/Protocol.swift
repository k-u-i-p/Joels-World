import Foundation

/// Loose JSON passthrough for parts of the payload the client stores but does not yet
/// interpret (`on_enter` / `on_exit` event trees, agent config). Phase 4 consumes these.
enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var isEmpty: Bool {
        switch self {
        case .null: return true
        case .array(let a): return a.isEmpty
        default: return false
        }
    }

    // MARK: Accessors

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        switch self {
        case .number(let n): return n
        // The event JSON quotes some ids (`"map": "3"`), and the JS coerces with Number().
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// Strings in an array, skipping anything that is not one.
    var stringArray: [String]? {
        guard case .array(let a) = self else { return nil }
        return a.compactMap(\.stringValue)
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// JavaScript truthiness, which the ported event code branches on directly.
    /// Note an *empty array* is truthy in JS, so `on_enter: []` counts as present.
    var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// Mirrors `x && (typeof x === 'number' || x.length > 0)`, the guard `main.js` and
    /// `physics.js` put in front of every `processEvents` call.
    var hasRunnableActions: Bool {
        guard isTruthy else { return false }
        if case .array(let a) = self { return !a.isEmpty }
        return true
    }
}

// MARK: - World data

struct CameraOffset: Codable {
    var x: Double?
    var y: Double?
    var top: Double?
    var bottom: Double?
    var left: Double?
    var right: Double?
}

struct MapLayer: Codable {
    var z: Int?
    var alpha: Double?
    var chunked: Bool?
    var spring: Bool?
    var overlay: Bool?
    var image: String?
    var chunk_size: Double?
    var grid_w: Int?
    var grid_h: Int?
    var path_template: String?
}

struct MapData: Codable {
    var id: Int
    var name: String?
    var width: Double
    var height: Double
    var layers: [MapLayer]?
    var clip_mask: String?
    var character_scale: Double?
    var default_zoom: Double?
    var background_color: String?
    var camera_permitted_offset: CameraOffset?
    var `import`: String?
    var on_enter: JSONValue?

    /// Paths, relative to `data/`, to this map's authored objects and NPCs — `maps.json`
    /// fields the server keeps for itself and the client now reads too. `WorldData` resolves
    /// them. Absent on minigame maps, which have no world.
    var objects: String?
    var npcs: String?

    /// A minigame map is a `import`ed script with no world of its own, so it carries no
    /// dimensions — `maps.json` id 4, Tennis. Decoding those as zero keeps the rest of the
    /// `init` frame usable; the synthesised initialiser would throw and take the whole world
    /// with it, leaving a player who was last in a minigame unable to load at all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 0
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 0
        layers = try container.decodeIfPresent([MapLayer].self, forKey: .layers)
        clip_mask = try container.decodeIfPresent(String.self, forKey: .clip_mask)
        character_scale = try container.decodeIfPresent(Double.self, forKey: .character_scale)
        default_zoom = try container.decodeIfPresent(Double.self, forKey: .default_zoom)
        background_color = try container.decodeIfPresent(String.self, forKey: .background_color)
        camera_permitted_offset = try container.decodeIfPresent(CameraOffset.self,
                                                                forKey: .camera_permitted_offset)
        `import` = try container.decodeIfPresent(String.self, forKey: .import)
        on_enter = try container.decodeIfPresent(JSONValue.self, forKey: .on_enter)
        objects = try container.decodeIfPresent(String.self, forKey: .objects)
        npcs = try container.decodeIfPresent(String.self, forKey: .npcs)
    }

    /// True for the minigame maps, which Phase 7 implements.
    var isMinigame: Bool { `import` != nil }
}

/// A collision volume or trigger zone. `clip == -1` means walk-through.
struct WorldObject: Codable {
    var id: Int
    var name: String?
    var shape: String?
    var x: Double = 0
    var y: Double = 0
    var z: Double?
    var width: Double?
    var length: Double?
    var rotation: Double?
    var clip: Double?
    var noclip: Bool?
    var model: String?
    var scale: Double?
    var on_enter: JSONValue?
    var on_exit: JSONValue?
}

struct EmoteState: Codable, Equatable {
    var name: String
    var startTime: Double
}

/// One step of an NPC patrol route. Every field is an *offset* from where the NPC started,
/// not an absolute position (`characters.js:1379-1400`).
struct Waypoint: Codable {
    var x: Double?
    var y: Double?
    var rotation: Double?
    /// Milliseconds to hold at this step; falls back to the NPC's `move_time`.
    var move_time: Double?
}

/// A player or NPC. Mirrors the server's character record.
struct GameCharacter: Codable {
    var id: Int
    var name: String?
    var x: Double = 0
    var y: Double = 0
    var z: Double?
    var width: Double?
    var height: Double?
    var rotation: Double?
    var gender: String?
    var head: String?
    /// Which bought model this character wears — a key from `CharacterModels`, or a path.
    /// `nil` is the catalogue's default. `head` used to do this job for the fourteen head GLBs
    /// the procedural character wore; it is parsed and ignored now (see part 4 of the imported
    /// characters handoff).
    var model: String?
    var color: String?
    var hair_color: String?
    var shirt_color: String?
    var pants_color: String?
    var arm_color: String?
    var shoe_color: String?
    var interaction_radius: Double?
    var roam_radius: Double?
    var emoji: String?
    var hide_nameplate: Bool?
    var emote: EmoteState?
    /// Pose an NPC falls back to whenever it has no active emote (`characters.js:1090`).
    var default_emote: EmoteState?
    /// `HOLDABLE_OBJECTS` key for a model carried in the right hand. Set by the `tennis` emote
    /// and cleared by its `onEnd` (`emotes.js:711-715`).
    var holding: String?
    var moveSpeed: Double?
    var rotationSpeed: Double?
    var waypoints: [Waypoint]?
    /// Default milliseconds per waypoint step.
    var move_time: Double?
    var badges: [String]?
    var on_enter: JSONValue?
    var on_exit: JSONValue?

    var halfWidth: Double { (width ?? 40) }
    var halfHeight: Double { (height ?? 40) }
}

struct MapListEntry: Codable {
    var id: Int
    var name: String?
}

// MARK: - Server → client

/// The live half of a connection. The authored half — the map, the map list, the objects and
/// the NPCs — ships with the app; `mapId` is what selects it out of `WorldData`.
struct InitPayload: Codable {
    var mapId: Int?
    var characters: [GameCharacter]?
    var myCharacter: GameCharacter?
}

/// Decoded form of every server frame the client acts on.
enum ServerMessage {
    case initWorld(InitPayload)
    case sessionToken(String)
    case tick([GameCharacter])
    case update(GameCharacter)
    case chat(id: Int, message: String)
    case disconnect(id: Int)
    case objectsUpdate([WorldObject])
    case npcsUpdate([GameCharacter])
    case badgeEarned(String)
    case mapChangeRejected
    case error(String)
    case unknown(String)

    /// Server frames are discriminated by a `type` string.
    static func decode(_ data: Data) throws -> ServerMessage {
        struct TypeProbe: Codable { var type: String }
        let decoder = JSONDecoder()
        let type = (try? decoder.decode(TypeProbe.self, from: data))?.type ?? ""

        switch type {
        case "init":
            return .initWorld(try decoder.decode(InitPayload.self, from: data))
        case "session_token":
            struct P: Codable { var token: String }
            return .sessionToken(try decoder.decode(P.self, from: data).token)
        case "tick":
            struct P: Codable { var characters: [GameCharacter] }
            return .tick(try decoder.decode(P.self, from: data).characters)
        case "update":
            struct P: Codable { var character: GameCharacter }
            return .update(try decoder.decode(P.self, from: data).character)
        case "chat":
            struct P: Codable { var id: Int; var message: String }
            let p = try decoder.decode(P.self, from: data)
            return .chat(id: p.id, message: p.message)
        case "disconnect":
            struct P: Codable { var id: Int }
            return .disconnect(id: try decoder.decode(P.self, from: data).id)
        case "objects_update":
            struct P: Codable { var objects: [WorldObject]? }
            return .objectsUpdate(try decoder.decode(P.self, from: data).objects ?? [])
        case "npcs_update":
            struct P: Codable { var npcs: [GameCharacter]? }
            return .npcsUpdate(try decoder.decode(P.self, from: data).npcs ?? [])
        case "badge_earned":
            struct P: Codable { var badge: String }
            return .badgeEarned(try decoder.decode(P.self, from: data).badge)
        case "map_change_rejected":
            return .mapChangeRejected
        case "error":
            struct P: Codable { var message: String? }
            return .error(try decoder.decode(P.self, from: data).message ?? "Unknown server error")
        default:
            return .unknown(type)
        }
    }
}

// MARK: - Client → server

struct CreateCharacterMessage: Encodable {
    let type = "create_character"
    var name: String
}

struct ChatMessage: Encodable {
    let type = "chat"
    var message: String
}

struct UpdateMessage: Encodable {
    let type = "update"
    var character: GameCharacter
}

/// Answering yes to a `show_dialog` of `type: change_map` (`events.js:84-91`).
/// The server replies with a fresh `init`, or with `map_change_rejected` when the current
/// map sets `can_leave: false` (`ClientManager.js:207`).
struct ChangeMapMessage: Encodable {
    let type = "change_map"
    var mapId: Int
    /// Overrides a map's `can_leave: false` (`ClientManager.js:196`). Omitted entirely when
    /// false, so an ordinary player's request is byte-for-byte what it always was. Only the
    /// editor sets it — it has to be able to open Detention and leave again.
    var force: Bool?
}

/// The `log` event handler — feeds the AI agents' event stream (`events.js:190`).
struct LogMessage: Encodable {
    let type = "log"
    var message: String
    var npc_id: Int?
}

/// Sent by the minigames in Phase 7; the server echoes `badge_earned` back.
struct AwardBadgeMessage: Encodable {
    let type = "award_badge"
    var badge: String
}
