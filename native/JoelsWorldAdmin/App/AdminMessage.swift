import Foundation

extension JSONValue {
    init(_ value: Double) { self = .number(value) }
    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: String) { self = .string(value) }
    init(_ value: Bool) { self = .bool(value) }

    /// Round-trips any `Encodable` into loose JSON. Used for `cloneData`, which puts a whole
    /// object or NPC record on the wire so the server can copy every authored field.
    init?<T: Encodable>(encoding value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        self = decoded
    }
}

/// The editor half of the wire protocol, mirroring `handleAdminMessage` in `server/admin.js`.
/// Every case names the `type` the server switches on.
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

    var payload: [String: JSONValue] {
        switch self {
        case .moveObject(let id, let x, let y):
            return ["type": .string("move_object"), "id": JSONValue(id),
                    "x": JSONValue(x), "y": JSONValue(y)]

        case .renameObject(let id, let name):
            // `admin.js` deletes the key when the name is blank; the server does that when
            // `data.name` is falsy, so an empty string is the right thing to send.
            return ["type": .string("rename_object"), "id": JSONValue(id),
                    "name": .string(name ?? "")]

        case .resizeObject(let id, let width, let length, let x, let y):
            return ["type": .string("resize_object"), "id": JSONValue(id),
                    "width": JSONValue(width), "length": JSONValue(length),
                    "x": JSONValue(x), "y": JSONValue(y)]

        case .rotateObject(let id, let rotation):
            return ["type": .string("rotate_object"), "id": JSONValue(id),
                    "rotation": JSONValue(rotation)]

        case .deleteObject(let id):
            return ["type": .string("delete_object"), "id": JSONValue(id)]

        case .updateObject(let id, let updates):
            return ["type": .string("update_object"), "id": JSONValue(id),
                    "updates": .object(updates)]

        case .createObject(let shape, let x, let y, let fields):
            var payload: [String: JSONValue] = ["type": .string("create_object"),
                                                "shape": .string(shape),
                                                "x": JSONValue(x), "y": JSONValue(y)]
            payload.merge(fields) { _, new in new }
            return payload

        case .cloneObject(let x, let y, let source):
            var payload: [String: JSONValue] = ["type": .string("create_object"),
                                                "x": JSONValue(x), "y": JSONValue(y)]
            if let clone = JSONValue(encoding: source) { payload["cloneData"] = clone }
            return payload

        case .moveNPC(let id, let x, let y):
            return ["type": .string("move_npc"), "id": JSONValue(id),
                    "x": JSONValue(x), "y": JSONValue(y)]

        case .updateNPC(let id, let updates):
            return ["type": .string("update_npc"), "id": JSONValue(id),
                    "updates": .object(updates)]

        case .createNPC(let x, let y):
            return ["type": .string("create_npc"), "x": JSONValue(x), "y": JSONValue(y)]

        case .cloneNPC(let x, let y, let source):
            var payload: [String: JSONValue] = ["type": .string("create_npc"),
                                                "x": JSONValue(x), "y": JSONValue(y)]
            if let clone = JSONValue(encoding: source) { payload["cloneData"] = clone }
            return payload

        case .deleteNPC(let id):
            return ["type": .string("delete_npc"), "id": JSONValue(id)]
        }
    }
}
