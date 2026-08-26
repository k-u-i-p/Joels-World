import Foundation
import simd

/// **The school at night** — everything in School Escape that stands still.
///
/// Unlike Five Nights, which built its school out of boxes, this game plays on the *real* main
/// building: the night repaint of `new_background.png` packed into a one-quad textured model
/// (`tools/assets/build_escape_ground.py`), with the overworld's own `walls.glb` standing on
/// top of it and the overworld's own `clip_mask.png` deciding what blocks you. All coordinates
/// here are **map pixels**, origin at the centre of the map, y down — the same numbers the map
/// editor shows, so a key can be moved by reading a position off the editor.
enum SchoolEscapeMap {

    static let mapWidth: Double = 5584
    static let mapHeight: Double = 3072

    // MARK: - Where things are (Joel's plan, drawn on the night map)

    /// You start in Ms Crosbie's classroom — she is the one who gives you the detention.
    static let spawn = SIMD2<Double>(-1985, 900)

    /// Mr Hardy starts his rounds at the far end of the east corridor, a long way from you.
    static let teacherSpawn = SIMD2<Double>(1800, -100)

    /// The corridor loop Mr Hardy walks when he has not seen anybody: past his own office,
    /// down to reception, along the whole corridor east and back, then the south leg past the
    /// classrooms. Every point checked walkable against the clip mask.
    static let patrol: [SIMD2<Double>] = [
        SIMD2(1800, -100),
        SIMD2(300, -60),
        SIMD2(-950, 120),
        SIMD2(-1440, -830),   // outside his office door
        SIMD2(-950, 120),
        SIMD2(-1430, 250),    // the junction into the south corridor —
        SIMD2(-1430, 650),    // — then straight down it, past the chest, and back.
        SIMD2(-1430, 250),
    ]

    struct Key {
        var name: String
        var hex: String
        var position: SIMD2<Double>
    }

    /// The four keys, exactly where Joel drew them.
    static let keys: [Key] = [
        Key(name: "ORANGE", hex: "#ff8c1a", position: SIMD2(-2520, 470)),   // Ms Crosbie's room
        Key(name: "GREEN", hex: "#3ddc55", position: SIMD2(-2295, -965)),   // Mr Hardy's office
        Key(name: "WHITE", hex: "#f2f2f2", position: SIMD2(660, 190)),      // first east classroom
        Key(name: "BLUE", hex: "#3fa9ff", position: SIMD2(2052, -866)),     // the kitchen
    ]

    /// Collect all four keys and open this to win. The alcove off the south corridor.
    static let chest = SIMD2<Double>(-1380, 1120)

    /// Mr Hardy's office door — the only way in or out of the room with the green key. When he
    /// locks it, this rectangle blocks movement *and* sight.
    struct DoorRect {
        var minX: Double, maxX: Double, minY: Double, maxY: Double
        var centre: SIMD2<Double> { SIMD2((minX + maxX) / 2, (minY + maxY) / 2) }
        func contains(_ x: Double, _ y: Double) -> Bool {
            x >= minX && x <= maxX && y >= minY && y <= maxY
        }
    }

    static let officeDoor = DoorRect(minX: -1600, maxX: -1430, minY: -900, maxY: -760)

    // MARK: - The scene

    /// The night background as the ground, the real walls on top, and Joel's deer thing
    /// standing guard in Mr Hardy's office.
    ///
    /// The ground model is authored directly in render space (see the build script), so it takes
    /// an identity transform. The walls take exactly the transform `PropRenderer` gives object
    /// id 18 in `data/main_building/objects.json` — same numbers, same result as the overworld.
    static let sceneModels: [SceneModel] = [
        SceneModel(path: "main_building/night_ground.glb",
                   transform: Float4x4.translation(SIMD3(0, 0, 0))),
        SceneModel(path: "main_building/walls.glb",
                   transform: Float4x4.translation(SIMD3(-2793, 1539, 0))
                       * Float4x4.rotationX(.pi / 2)),
        // The deer thing, in the corner of Mr Hardy's office, watching the green key. Its
        // Sketchfab root already stands it up (they bake their own Y-up fix in), so unlike a
        // raw glTF it takes no `rotationX(.pi / 2)` — with one it lay flat on its side.
        SceneModel(path: "models/deer_thing.glb",
                   transform: Float4x4.translation(SIMD3(-2100, 1210, 0))
                       * Float4x4.rotationZ(2.2)
                       * Float4x4.scale(SIMD3(repeating: 90))),
    ]

    // MARK: - Primitive builders

    private static func place(_ x: Double, _ y: Double, _ z: Double) -> Float4x4 {
        Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z)))
    }

    /// A key on the floor: a glowing ball that bobs, over a faint ring so it reads from the
    /// tipped-over camera.
    static func keyPrimitives(_ key: Key, bob: Double) -> [ScenePrimitive] {
        let color = parseHexColor(key.hex)
        return [
            ScenePrimitive(shape: .sphere(radius: 16),
                           transform: place(key.position.x, key.position.y, 55 + 12 * bob),
                           color: color,
                           unlit: true,
                           castsShadow: false),
            ScenePrimitive(shape: .cylinder(radius: 30, height: 3),
                           transform: place(key.position.x, key.position.y, 3)
                               * Float4x4.rotationX(.pi / 2),
                           color: color,
                           opacity: 0.35,
                           unlit: true,
                           castsShadow: false),
        ]
    }

    /// The chest: a brown box with a darker lid. It glows gold once every key is held, and the
    /// lid stands open once it is won.
    static func chestPrimitives(armed: Bool, open: Bool) -> [ScenePrimitive] {
        let wood = parseHexColor("#8a5a2b")
        let lidColor = parseHexColor(open ? "#3c2510" : "#5c3a18")
        var out = [
            ScenePrimitive(shape: .box(width: 130, height: 90, depth: 70),
                           transform: place(chest.x, chest.y, 35),
                           color: wood),
            ScenePrimitive(shape: .box(width: 138, height: 98, depth: 26),
                           transform: open
                               ? place(chest.x, chest.y - 60, 96)
                                   * Float4x4.rotationX(-1.2)
                               : place(chest.x, chest.y, 83),
                           color: lidColor),
        ]
        if armed {
            out.append(ScenePrimitive(shape: .cylinder(radius: 95, height: 3),
                                      transform: place(chest.x, chest.y, 2)
                                          * Float4x4.rotationX(.pi / 2),
                                      color: parseHexColor("#ffd94d"),
                                      opacity: 0.35,
                                      unlit: true,
                                      castsShadow: false))
        }
        return out
    }

    /// Mr Hardy's office door, drawn shut. `closed` is 0 open (nothing drawn) to 1 shut; it
    /// *drops from above* rather than growing, because the renderer builds one GPU mesh per
    /// distinct shape size and an animated size would mint a mesh every frame.
    static func doorPrimitives(closed: Double) -> [ScenePrimitive] {
        guard closed > 0.01 else { return [] }
        let rect = officeDoor
        // Fully open it hangs out of sight above the wall tops; fully shut it sits on the floor.
        let drop = 85 + (1 - closed) * 260
        return [
            ScenePrimitive(shape: .box(width: 26,
                                       height: Float(rect.maxY - rect.minY),
                                       depth: 170),
                           transform: place(rect.centre.x, rect.centre.y, drop),
                           color: parseHexColor("#4a2c14")),
        ]
    }

    /// The red ring under Mr Hardy while he is after you — the "he has seen you" telegraph.
    /// Fixed size, pulsing glow — same one-mesh-per-size rule as the door.
    static func alarmPrimitive(x: Double, y: Double, pulse: Double) -> ScenePrimitive {
        ScenePrimitive(shape: .cylinder(radius: 62, height: 3),
                       transform: place(x, y, 2) * Float4x4.rotationX(.pi / 2),
                       color: parseHexColor("#ff2d2d"),
                       opacity: Float(0.35 + 0.35 * pulse),
                       unlit: true,
                       castsShadow: false)
    }
}
