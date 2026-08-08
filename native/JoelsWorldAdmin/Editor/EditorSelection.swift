import Foundation

/// Port of `window.selectedObject` / `window.selectedNpc` (`admin.js:144-237`).
///
/// Selection is by id, and every read resolves against the live world — the server replaces
/// the whole `objects` array on each edit, so holding a copy would go stale immediately.
struct EditorSelection {
    private(set) var objectIds: [Int] = []
    private(set) var npcId: Int?

    // MARK: Objects

    mutating func setObject(_ id: Int?) {
        objectIds = id.map { [$0] } ?? []
    }

    mutating func addObject(_ id: Int) {
        if !objectIds.contains(id) { objectIds.append(id) }
    }

    mutating func removeObject(_ id: Int) {
        objectIds.removeAll { $0 == id }
    }

    func hasObject(_ id: Int) -> Bool { objectIds.contains(id) }

    /// The JS `get()` returns the *first* selected id, and the whole edit panel is written
    /// against it — a multi-selection edits nothing but its positions.
    func object(in objects: [WorldObject]) -> WorldObject? {
        guard let first = objectIds.first else { return nil }
        return objects.first { $0.id == first }
    }

    func objects(in objects: [WorldObject]) -> [WorldObject] {
        objects.filter { objectIds.contains($0.id) }
    }

    // MARK: NPCs

    mutating func setNPC(_ id: Int?) {
        npcId = id
    }

    func npc(in npcs: [GameCharacter]) -> GameCharacter? {
        guard let npcId else { return nil }
        return npcs.first { $0.id == npcId }
    }
}

/// The geometry `admin.js` does by hand: hit tests, the resize-handle corner, and the
/// top-left anchor a resize pivots around.
enum EditorGeometry {
    /// `findObjectAtXY` — topmost first, so the last object in the array wins an overlap.
    static func object(at worldX: Double, worldY: Double, in objects: [WorldObject]) -> WorldObject? {
        for object in objects.reversed() {
            let width = object.width ?? 0
            let length = object.length ?? 0
            if object.shape == "circle" {
                let radius = max(width, length) / 2
                if hypot(worldX - object.x, worldY - object.y) <= radius { return object }
            } else {
                let local = localPoint(worldX: worldX, worldY: worldY, object: object)
                if abs(local.x) <= width / 2 && abs(local.y) <= length / 2 { return object }
            }
        }
        return nil
    }

    /// `findNpcAtXY` — a circle of `max(width, height) / 2`, defaulting to 20.
    static func npc(at worldX: Double, worldY: Double, in npcs: [GameCharacter]) -> GameCharacter? {
        for npc in npcs.reversed() {
            let size = max(npc.width ?? 0, npc.height ?? 0) / 2
            let radius = size > 0 ? size : 20
            if hypot(worldX - npc.x, worldY - npc.y) <= radius { return npc }
        }
        return nil
    }

    /// Rotates a world point into the object's own unrotated frame.
    static func localPoint(worldX: Double, worldY: Double, object: WorldObject) -> (x: Double, y: Double) {
        let dx = worldX - object.x
        let dy = worldY - object.y
        let angle = -(object.rotation ?? 0) * .pi / 180
        return (dx * cos(angle) - dy * sin(angle),
                dx * sin(angle) + dy * cos(angle))
    }

    /// The bottom-right corner grab handle, in the object's local frame.
    static func handleOffset(for object: WorldObject) -> (x: Double, y: Double) {
        if object.shape == "circle" {
            let radius = max(object.width ?? 0, object.length ?? 0) / 2
            return (radius * 0.707, radius * 0.707)
        }
        return ((object.width ?? 0) / 2, (object.length ?? 0) / 2)
    }

    /// `checkResizeHandleHit` — a 15 px screen-space radius, divided by zoom so the grab area
    /// stays the same size on screen at any magnification.
    static func hitsResizeHandle(object: WorldObject, worldX: Double, worldY: Double, zoom: Double) -> Bool {
        let local = localPoint(worldX: worldX, worldY: worldY, object: object)
        let handle = handleOffset(for: object)
        return hypot(local.x - handle.x, local.y - handle.y) <= 15 / (zoom == 0 ? 1 : zoom)
    }

    /// `getObjectTopLeftAnchor` — the world position of the object's unrotated top-left corner.
    /// A resize keeps this fixed and moves the centre, so the box grows away from the corner
    /// the user is not dragging.
    static func topLeftAnchor(of object: WorldObject) -> (x: Double, y: Double) {
        let angle = (object.rotation ?? 0) * .pi / 180
        let halfWidth = (object.width ?? 0) / 2
        let halfLength = (object.length ?? 0) / 2
        return (object.x + (-halfWidth) * cos(angle) - (-halfLength) * sin(angle),
                object.y + (-halfWidth) * sin(angle) + (-halfLength) * cos(angle))
    }

    /// `applyResizeWithTopLeftAnchor` — sets the new size and back-solves the centre.
    static func applyResize(to object: inout WorldObject,
                            width: Double, length: Double,
                            anchorX: Double, anchorY: Double) {
        object.width = width
        object.length = length
        let angle = (object.rotation ?? 0) * .pi / 180
        object.x = (anchorX - ((-width / 2) * cos(angle) - (-length / 2) * sin(angle))).rounded()
        object.y = (anchorY - ((-width / 2) * sin(angle) + (-length / 2) * cos(angle))).rounded()
    }
}
