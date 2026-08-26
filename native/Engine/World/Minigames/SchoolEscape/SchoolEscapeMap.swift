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

    /// Vertical stretch on the walls, roof and office door. Modest again — the "500% bigger
    /// school" is done by *shrinking the player* (see `Tuning.eyeHeight`), and against a
    /// 40-unit eye even these walls are eight of you high.
    static let tall: Float = 1.6

    /// Exactly the transform `PropRenderer` gives a placed object, so everything lands where
    /// the overworld draws it: position with Y negated, clockwise rotation negated, uniform
    /// scale, then the glTF Y-up → Z-up tip. `stretch` scales world-height only — safe for
    /// the walls because their side normals have no Z to distort.
    private static func placed(_ x: Double, _ y: Double, z: Double = 0,
                               rotation: Double = 0, scale: Double = 1,
                               stretch: Float = 1) -> Float4x4 {
        Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z)))
            * Float4x4.scale(SIMD3(1, 1, stretch))
            * Float4x4.rotationZ(Float(-rotation) * .pi / 180)
            * Float4x4.scale(SIMD3(repeating: Float(scale)))
            * Float4x4.rotationX(.pi / 2)
    }

    /// Desks that are only *painted* on the floor — flat nonsense at eye height, which is
    /// where Joel's first-person camera lives. A real desk and chair stand on each painted
    /// one: Ms Crosbie's room (3 × 4 plus her own desk) and the middle classroom (3 × 3).
    /// The east classrooms and the cafeteria already have real furniture in
    /// `objects.json`, drawn below.
    private static let paintedDesks: [SIMD2<Double>] = {
        var desks: [SIMD2<Double>] = []
        for y in [550.0, 730, 900, 1075] {
            for x in [-2410.0, -2245, -2075] { desks.append(SIMD2(x, y)) }
        }
        for y in [555.0, 730, 905] {
            for x in [-915.0, -705, -495] { desks.append(SIMD2(x, y)) }
        }
        return desks
    }()

    /// The night background as the ground, every 3D prop the overworld places on this map
    /// (walls included), real furniture over the painted desks, and Joel's deer thing standing
    /// guard in Mr Hardy's office.
    ///
    /// The ground model is authored directly in render space (see the build script), so it
    /// takes an identity transform.
    static let sceneModels: [SceneModel] = {
        var out: [SceneModel] = [
            SceneModel(path: "main_building/night_ground.glb",
                       transform: Float4x4.translation(SIMD3(0, 0, 0))),
            // The deer thing. Its Sketchfab root already stands it up (they bake their own
            // Y-up fix in), so unlike a raw glTF it takes no `rotationX(.pi / 2)` — with one
            // it lay flat on its side.
            SceneModel(path: "models/deer_thing.glb",
                       transform: Float4x4.translation(SIMD3(-2100, 1210, 0))
                           * Float4x4.rotationZ(2.2)
                           * Float4x4.scale(SIMD3(repeating: 120))),
        ]

        for object in WorldData.objects(mapId: 2) where object.shape == "3d_model" {
            guard let model = object.model else { continue }
            // The walls get the full vertical stretch; the placed furniture a gentler one,
            // so a chair grows without swallowing its painted footprint.
            let stretch: Float = model.hasSuffix("walls.glb") ? tall : 1
            out.append(SceneModel(path: model,
                                  transform: placed(object.x, object.y, z: object.z ?? 0,
                                                    rotation: object.rotation ?? 0,
                                                    scale: object.scale ?? 1,
                                                    stretch: stretch)))
        }

        for desk in paintedDesks {
            out.append(SceneModel(path: "models/desk.glb",
                                  transform: placed(desk.x, desk.y, scale: 1.05)))
            out.append(SceneModel(path: "models/chair.glb",
                                  transform: placed(desk.x, desk.y + 62, scale: 1.15)))
        }
        // Ms Crosbie's own desk, side-on against the west wall, and Mr Hardy's in his office
        // — the same antique the detention room uses, sized for this map's smaller pupils.
        out.append(SceneModel(path: "models/desk.glb",
                              transform: placed(-2615, 520, rotation: 90, scale: 1.05)))
        out.append(SceneModel(path: "models/antique_desk.glb",
                              transform: placed(-2190, -1070, scale: 180)))
        return out
    }()

    // MARK: - Primitive builders

    private static func place(_ x: Double, _ y: Double, _ z: Double) -> Float4x4 {
        Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z)))
    }

    /// A key on the floor: a glowing ball that bobs, over a faint ring so it reads from the
    /// tipped-over camera.
    static func keyPrimitives(_ key: Key, bob: Double) -> [ScenePrimitive] {
        let color = parseHexColor(key.hex)
        return [
            ScenePrimitive(shape: .sphere(radius: 14),
                           transform: place(key.position.x, key.position.y, 34 + 8 * bob),
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
        // Fully open it hangs out of sight above the wall tops; fully shut it sits on the
        // floor. Its height rides `tall`, so it always fills the stretched doorway.
        let doorHeight = Double(170 * tall)
        let drop = doorHeight / 2 + (1 - closed) * (doorHeight + 120)
        return [
            ScenePrimitive(shape: .box(width: 26,
                                       height: Float(rect.maxY - rect.minY),
                                       depth: Float(doorHeight)),
                           transform: place(rect.centre.x, rect.centre.y, drop),
                           color: parseHexColor("#4a2c14")),
        ]
    }

    /// **The roof.** Joel's ask — with only night sky over the walls the school felt like a
    /// film set. Four dark slabs at 212, just over the 201-unit walls, covering the wings
    /// of the building and leaving the car park and gardens under open sky. `castsShadow`
    /// stays false so a lid over the whole school does not black out the shadow map, and the
    /// undersides read near-black on their own because the ambient knows they face down.
    ///
    /// Only drawn in eyes mode during play — the win camera looks down from above, and from
    /// up there a roof is a school-shaped hole in the picture.
    static let roof: [ScenePrimitive] = [
        // West wing: office, storage, Ms Crosbie's room.
        (SIMD2(-2146.0, -75.0), SIMD2(Float(1292), Float(2830))),
        // Cafeteria and kitchen.
        (SIMD2(1846.0, -960.0), SIMD2(Float(1892), Float(1060))),
        // The toilets block.
        (SIMD2(0.0, -755.0), SIMD2(Float(700), Float(650))),
        // Central corridor and the south classrooms.
        (SIMD2(646.0, 455.0), SIMD2(Float(4292), Float(1770))),
    ].map { centre, size in
        ScenePrimitive(shape: .box(width: size.x, height: size.y, depth: 16),
                       transform: place(centre.x, centre.y, Double(212 * tall)),
                       color: parseHexColor("#17171c"),
                       roughness: 1,
                       castsShadow: false)
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
