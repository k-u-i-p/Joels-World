import Foundation

/// Reads and writes the authored world on disk — `data/<map>/objects.json` and `npc.json`.
///
/// This is the editor's half of a change the whole project turns on: the world ships inside
/// the apps now, so editing it means editing the files in a checkout, not asking a running
/// server to mutate its own copy. `server/admin.js` and the fourteen socket messages that fed
/// it are gone; these operations are a faithful port of what it did, applied here instead.
///
/// A locally-running server still notices. `MapManager.initializeMaps` and
/// `NPCManager.initializeMapNPCs` watch these two files and broadcast `objects_update` /
/// `npcs_update` when they change, so a save reaches every connected client — including the
/// editor's own live view — without the editor telling anyone.
final class WorldFileStore {
    enum StoreError: Error, CustomStringConvertible {
        case noDataDirectory
        case mapHasNoFile(mapId: Int, kind: String)
        case notAnArray(String)

        var description: String {
            switch self {
            case .noDataDirectory:
                return "No data/ directory chosen. Pass -data <path to the checkout's data/>, "
                     + "or pick one when prompted."
            case .mapHasNoFile(let mapId, let kind):
                return "Map \(mapId) declares no \(kind) file in maps.json"
            case .notAnArray(let path):
                return "\(path) is not a JSON array"
            }
        }
    }

    /// Where the checkout's `data/` lives. The bundled copy under `GameAssets/data` is a build
    /// product and is deliberately not a candidate — writing there would be overwritten by the
    /// next build and would never reach git.
    private(set) var dataDirectory: URL?

    private static let defaultsKey = "admin_data_directory"

    init() {
        dataDirectory = Self.locate()
    }

    /// `-data <path>` first, so `-selftest` and any scripted run are deterministic; then the
    /// directory the operator last chose; then a walk up from the running binary, which finds
    /// it whenever the app was built inside the checkout.
    private static func locate() -> URL? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-data"), index + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
            if isDataDirectory(url) { return url }
            Log.world("-data \(arguments[index + 1]) does not look like the data/ directory")
        }

        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            let url = URL(fileURLWithPath: stored)
            if isDataDirectory(url) { return url }
        }

        // DerivedData puts the built app well outside the checkout, so this only succeeds for
        // a build configured to land inside it. Harmless when it does not.
        var candidate = Bundle.main.bundleURL
        for _ in 0..<8 {
            candidate = candidate.deletingLastPathComponent()
            let data = candidate.appendingPathComponent("data", isDirectory: true)
            if isDataDirectory(data) { return data }
        }
        return nil
    }

    private static func isDataDirectory(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("maps.json").path)
    }

    /// Records an operator's choice for next launch.
    func use(directory: URL) {
        dataDirectory = directory
        UserDefaults.standard.set(directory.path, forKey: Self.defaultsKey)
    }

    var isWritable: Bool {
        guard let dataDirectory else { return false }
        return FileManager.default.isWritableFile(atPath: dataDirectory.path)
    }

    // MARK: - File access

    private func url(for relativePath: String) throws -> URL {
        guard let dataDirectory else { throw StoreError.noDataDirectory }
        return dataDirectory.appendingPathComponent(relativePath)
    }

    private func loadArray(at relativePath: String) throws -> [OrderedJSON] {
        let fileURL = try url(for: relativePath)
        let data = try Data(contentsOf: fileURL)
        guard let items = try OrderedJSON.parse(data).arrayValue else {
            throw StoreError.notAnArray(relativePath)
        }
        return items
    }

    private func save(_ items: [OrderedJSON], to relativePath: String) throws {
        let fileURL = try url(for: relativePath)
        try OrderedJSON.array(items).serialized().write(to: fileURL, options: .atomic)
        Log.world("Wrote \(items.count) entries to \(relativePath)")
    }

    /// Loads, mutates and saves a map's entity file in one step. The closure returns false to
    /// abandon the write — an edit naming an id that is not there changes nothing, which is
    /// what `admin.js` did.
    @discardableResult
    private func edit(_ relativePath: String,
                      _ mutate: (inout [OrderedJSON]) -> Bool) throws -> Bool {
        var items = try loadArray(at: relativePath)
        guard mutate(&items) else { return false }
        try save(items, to: relativePath)
        return true
    }

    private func objectsPath(mapId: Int) throws -> String {
        guard let path = WorldData.map(id: mapId)?.objects else {
            throw StoreError.mapHasNoFile(mapId: mapId, kind: "objects")
        }
        return path
    }

    private func npcsPath(mapId: Int) throws -> String {
        guard let path = WorldData.map(id: mapId)?.npcs else {
            throw StoreError.mapHasNoFile(mapId: mapId, kind: "npc")
        }
        return path
    }

    // MARK: - Reading back

    func objects(mapId: Int) throws -> [WorldObject] {
        let data = OrderedJSON.array(try loadArray(at: try objectsPath(mapId: mapId))).serialized()
        return try JSONDecoder().decode([WorldObject].self, from: data)
    }

    func npcs(mapId: Int) throws -> [GameCharacter] {
        let data = OrderedJSON.array(try loadArray(at: try npcsPath(mapId: mapId))).serialized()
        return try JSONDecoder().decode([GameCharacter].self, from: data)
    }

    // MARK: - Edits

    /// Applies one editor operation. Returns the entity kind that changed so the caller knows
    /// which list to re-read.
    @discardableResult
    func apply(_ edit: AdminMessage, mapId: Int) throws -> AdminMessage.Kind {
        switch edit {
        case .moveObject(let id, let x, let y):
            try mutateObject(id: id, mapId: mapId) {
                $0["x"] = .number(x)
                $0["y"] = .number(y)
            }

        case .renameObject(let id, let name):
            try mutateObject(id: id, mapId: mapId) {
                // `admin.js` removed the key for a blank name rather than storing "".
                $0["name"] = (name?.isEmpty == false) ? .string(name!) : nil
            }

        case .resizeObject(let id, let width, let length, let x, let y):
            try mutateObject(id: id, mapId: mapId) {
                $0["width"] = .number(width)
                $0["length"] = .number(length)
                $0["x"] = .number(x)
                $0["y"] = .number(y)
            }

        case .rotateObject(let id, let rotation):
            try mutateObject(id: id, mapId: mapId) { $0["rotation"] = .number(rotation) }

        case .updateObject(let id, let updates):
            try mutateObject(id: id, mapId: mapId) { $0.assign(Self.ordered(updates)) }

        case .deleteObject(let id):
            try self.edit(try objectsPath(mapId: mapId)) { items in
                guard let index = Self.index(of: id, in: items) else { return false }
                items.remove(at: index)
                return true
            }

        case .createObject(let shape, let x, let y, let fields):
            try self.edit(try objectsPath(mapId: mapId)) { items in
                var new = OrderedJSON.object([
                    (key: "id", value: .number(Double(Self.nextId(in: items)))),
                    (key: "shape", value: .string(shape)),
                    (key: "x", value: .number(x)),
                    (key: "y", value: .number(y)),
                ])
                new.assign(Self.ordered(fields))
                items.append(new)
                return true
            }

        case .cloneObject(let x, let y, let source):
            try self.edit(try objectsPath(mapId: mapId)) { items in
                items.append(Self.clone(of: source, in: items,
                                        id: Self.nextId(in: items), x: x, y: y))
                return true
            }

        case .moveNPC(let id, let x, let y):
            try mutateNPC(id: id, mapId: mapId) {
                $0["x"] = .number(x)
                $0["y"] = .number(y)
            }

        case .updateNPC(let id, let updates):
            try mutateNPC(id: id, mapId: mapId) { $0.assign(Self.ordered(updates)) }

        case .deleteNPC(let id):
            try self.edit(try npcsPath(mapId: mapId)) { items in
                guard let index = Self.index(of: id, in: items) else { return false }
                items.remove(at: index)
                return true
            }

        case .createNPC(let x, let y):
            try self.edit(try npcsPath(mapId: mapId)) { items in
                items.append(Self.blankNPC(id: Self.nextId(in: items), x: x, y: y))
                return true
            }

        case .cloneNPC(let x, let y, let source):
            try self.edit(try npcsPath(mapId: mapId)) { items in
                items.append(Self.clone(of: source, in: items,
                                        id: Self.nextId(in: items), x: x, y: y))
                return true
            }
        }

        return edit.kind
    }

    private func mutateObject(id: Int, mapId: Int, _ body: (inout OrderedJSON) -> Void) throws {
        try edit(try objectsPath(mapId: mapId)) { items in
            guard let index = Self.index(of: id, in: items) else { return false }
            body(&items[index])
            return true
        }
    }

    private func mutateNPC(id: Int, mapId: Int, _ body: (inout OrderedJSON) -> Void) throws {
        try edit(try npcsPath(mapId: mapId)) { items in
            guard let index = Self.index(of: id, in: items) else { return false }
            body(&items[index])
            return true
        }
    }

    // MARK: - Helpers

    private static func index(of id: Int, in items: [OrderedJSON]) -> Int? {
        items.firstIndex { $0["id"]?.numberValue == Double(id) }
    }

    /// `admin.js` numbered a new entity `max(id) + 1`, treating a non-numeric id as 0.
    private static func nextId(in items: [OrderedJSON]) -> Int {
        let highest = items.reduce(0) { max($0, Int($1["id"]?.numberValue ?? 0)) }
        return highest + 1
    }

    /// `Object.assign(new, {...clone, id: undefined}, { id, x, y })` — every authored field
    /// carries over, and the new position and id win.
    ///
    /// The source is taken from the *file* rather than from the selected `WorldObject` or
    /// `GameCharacter`, because those model the fields the game reads and the JSON carries
    /// more than that. Copying the record verbatim means a duplicated NPC keeps its agent
    /// block, and a duplicated object keeps whatever was authored on it. The struct is only a
    /// fallback for a selection that is somehow not in the file.
    private static func clone<T: Encodable & Identified>(of source: T,
                                                         in items: [OrderedJSON],
                                                         id: Int,
                                                         x: Double,
                                                         y: Double) -> OrderedJSON {
        var value: OrderedJSON = .object([])
        if let index = index(of: source.id, in: items) {
            value = items[index]
        } else if let encoded = try? JSONEncoder().encode(source),
                  let parsed = try? OrderedJSON.parse(encoded) {
            value = parsed
        }
        value["id"] = .number(Double(id))
        value["x"] = .number(x)
        value["y"] = .number(y)
        return value
    }

    /// The starting NPC `admin.js` created, field for field and in the same order.
    private static func blankNPC(id: Int, x: Double, y: Double) -> OrderedJSON {
        .object([
            (key: "id", value: .number(Double(id))),
            (key: "name", value: .string("New NPC")),
            (key: "x", value: .number(x)),
            (key: "y", value: .number(y)),
            (key: "width", value: .number(40)),
            (key: "height", value: .number(40)),
            (key: "rotation", value: .number(0)),
            (key: "shirt_color", value: .string("#3498db")),
            (key: "pants_color", value: .string("#2c3e50")),
            (key: "arm_color", value: .string("#3498db")),
            (key: "on_enter", value: .array([])),
            (key: "on_exit", value: .array([])),
        ])
    }

    /// The inspectors build updates as a `[String: JSONValue]` dictionary, which has no order
    /// of its own. Sorting by key at least makes a save reproducible; existing keys keep their
    /// position in the file regardless, so this only decides where genuinely new ones land.
    private static func ordered(_ updates: [String: JSONValue]) -> [(key: String, value: OrderedJSON)] {
        updates.keys.sorted().map { (key: $0, value: OrderedJSON(updates[$0]!)) }
    }
}

/// Just enough to find a record's twin on disk. Both entity types carry an `id`.
protocol Identified {
    var id: Int { get }
}

extension WorldObject: Identified {}
extension GameCharacter: Identified {}

extension OrderedJSON {
    /// Bridges the inspectors' loose values. `JSONValue`'s objects are unordered, so this is
    /// only used for values the editor is *writing* — never for re-reading a file.
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let v): self = .bool(v)
        case .number(let v): self = .number(v)
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(OrderedJSON.init))
        case .object(let v):
            self = .object(v.keys.sorted().map { (key: $0, value: OrderedJSON(v[$0]!)) })
        }
    }
}
