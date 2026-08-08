import Foundation

/// The authored world, read out of the app bundle.
///
/// `maps.json` and every map's `objects.json` and `npc.json` used to arrive in the `init`
/// frame — around 100 KB of JSON on every connection and every map change, describing content
/// that only changes when somebody edits it. They ship with the app now
/// (`tools/assets/stage.sh` stages `data/` into `GameAssets/data/`), and `init` carries only
/// the live half: which map, who else is on it, and the player's own character.
///
/// The server reads the same files and still watches them, so a `objects_update` or
/// `npcs_update` frame overrides what is here for the rest of the session — that is the path
/// the macOS editor drives when it writes to `data/` on a machine running a local server.
enum WorldData {
    private static let root = "data"

    /// Every map in `maps.json`, in file order.
    static let maps: [MapData] = {
        guard let data = AssetLocator.data(for: "\(root)/maps.json") else {
            Log.world("maps.json is missing from the bundle — the world cannot load")
            return []
        }
        do {
            let maps = try JSONDecoder().decode([MapData].self, from: data)
            Log.world("Loaded \(maps.count) maps from the bundle")
            return maps
        } catch {
            Log.world("maps.json failed to decode: \(error)")
            return []
        }
    }()

    /// The id/name pairs the map-change UI and the editor's map picker list.
    static let mapsList: [MapListEntry] = maps.map { MapListEntry(id: $0.id, name: $0.name) }

    static func map(id: Int) -> MapData? {
        maps.first { $0.id == id }
    }

    // Decoded on first use and kept: a player crossing back and forth between two maps should
    // not re-parse either one.
    private static var objectsCache: [Int: [WorldObject]] = [:]
    private static var npcsCache: [Int: [GameCharacter]] = [:]

    static func objects(mapId: Int) -> [WorldObject] {
        if let cached = objectsCache[mapId] { return cached }
        let loaded: [WorldObject] = load(map(id: mapId)?.objects, as: [WorldObject].self) ?? []
        objectsCache[mapId] = loaded
        return loaded
    }

    static func npcs(mapId: Int) -> [GameCharacter] {
        if let cached = npcsCache[mapId] { return cached }
        let loaded: [GameCharacter] = load(map(id: mapId)?.npcs, as: [GameCharacter].self) ?? []
        npcsCache[mapId] = loaded
        return loaded
    }

    /// `maps.json` names these files relative to `data/` — `"junior_school/objects.json"`.
    /// A minigame map names neither, which is why a missing path is not an error.
    private static func load<T: Decodable>(_ relativePath: String?, as type: T.Type) -> T? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        guard let data = AssetLocator.data(for: "\(root)/\(relativePath)") else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Log.world("\(relativePath) failed to decode: \(error)")
            return nil
        }
    }
}
