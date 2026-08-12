import Foundation

extension JSONValue {
    init(_ value: Double) { self = .number(value) }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }

    /// Round-trips any `Encodable` into loose JSON, for the inspectors that build an update
    /// out of a whole record rather than field by field.
    init?<T: Encodable>(encoding value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// One edit the editor can make to the authored world.
///
/// These were socket frames until the world moved into the app bundle — each case named a
/// `type` that `server/admin.js` switched on, and the server did the writing. `WorldFileStore`
/// applies them to `data/` on disk instead; the cases survived the move unchanged, so every
/// inspector and the self-test still speak in them.
enum AdminMessage {
    case moveObject(id: Int, x: Double, y: Double)
    case renameObject(id: Int, name: String?)
    case resizeObject(id: Int, width: Double, length: Double, x: Double, y: Double)
    case rotateObject(id: Int, rotation: Double)
    case deleteObject(id: Int)
    case updateObject(id: Int, updates: [String: JSONValue])
    case createObject(shape: String, x: Double, y: Double, fields: [String: JSONValue])
    case cloneObject(x: Double, y: Double, source: WorldObject)

    case moveNPC(id: Int, x: Double, y: Double)
    case updateNPC(id: Int, updates: [String: JSONValue])
    case createNPC(x: Double, y: Double)
    case cloneNPC(x: Double, y: Double, source: GameCharacter)
    case deleteNPC(id: Int)

    /// Fields on the map's own record in `maps.json` — the camera angle, so far. The only edit
    /// here that writes a file the two entity lists do not live in.
    case updateMap(updates: [String: JSONValue])

    /// Which file a given edit lands in.
    enum Kind {
        case objects
        case npcs
        case map
    }

    var kind: Kind {
        switch self {
        case .moveObject, .renameObject, .resizeObject, .rotateObject,
             .deleteObject, .updateObject, .createObject, .cloneObject:
            return .objects
        case .moveNPC, .updateNPC, .createNPC, .cloneNPC, .deleteNPC:
            return .npcs
        case .updateMap:
            return .map
        }
    }
}
