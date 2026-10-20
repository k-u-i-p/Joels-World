import Foundation
import simd

/// Everything **Destroy the World** is built out of: the trees, houses, haystacks and campfires
/// you set fire to, the train you ride on, the flamethrower in your hands, and the fields,
/// mountains and clouds rolling past.
///
/// It is all boxes and cylinders, on purpose. Joel asked for **low-poly**, and a box is the most
/// low-poly thing there is: a pine tree is four green cubes stacked and twisted, a mountain is one
/// huge cube stood on its corner, and a flame is a little glowing cube that tumbles as it rises.
///
/// Everything here is in **metres, in render space**: X across the track (right is +X), Y along
/// it (the train drives towards +Y), Z up. `m()` turns metres into world units at the last
/// moment, when a shape is handed to the renderer.
///
/// The one rule that matters (the same one School Rush lives by): `ScenePrimitiveRenderer` keeps
/// one GPU mesh per **distinct size**, and stops caching after 256. So every size in this file is
/// a constant, or a constant times a whole-number step — never a size that slides smoothly.
enum DestroyWorldKit {

    // MARK: - Scale

    /// World units per metre. There are no characters in this game to pin it to, so it is chosen
    /// for the far clip plane instead: the camera sees 4000 units, which at 20 to the metre is
    /// 200 m of countryside.
    static let unitsPerMetre: Float = 20

    static func m(_ metres: Float) -> Float { metres * unitsPerMetre }
    static func m(_ metres: SIMD3<Float>) -> SIMD3<Float> { metres * unitsPerMetre }

    // MARK: - The train

    /// How high your eyes are: on the roof of the last carriage, standing up.
    static let roofTop: Float = 3.83
    static let eyeHeight: Float = 5.3

    /// How much track is drawn ahead of you and behind you.
    static let drawAhead: Float = 175
    static let drawBehind: Float = 45

    static let skyHex = "#8fd3ff"

    // MARK: - Colours

    static func hex(_ string: String) -> SIMD3<Float> { parseHexColor(string) }

    static let charcoal = SIMD3<Float>(0.12, 0.10, 0.09)
    static let iceTint = SIMD3<Float>(0.45, 0.78, 1.00)

    private static let groundColor = hex("#78bf55")
    private static let fieldColors = ["#7ac74f", "#8fd16a", "#a8d96b", "#e0cf68", "#6fb85a",
                                      "#b9e07a", "#d6b85a", "#86c95e"].map(hex)
    private static let ballastColor = hex("#8a8178")
    private static let railColor = hex("#a7b0ba")
    private static let sleeperColor = hex("#5d4632")
    private static let poleColor = hex("#6b4f34")
    private static let forestColors = ["#2f7d3a", "#3a8f45", "#27693a"].map(hex)
    private static let mountainColors = ["#8d8070", "#7b6f63", "#9a8b78"].map(hex)
    private static let snowColor = hex("#f7fbff")

    private static let carriageRed = hex("#c0392b")
    private static let carriageCream = hex("#f5e6c8")
    private static let windowColor = hex("#2b3a4a")
    private static let roofColor = hex("#8a8f96")
    private static let frameColor = hex("#2d2d34")
    private static let locoBody = hex("#2c3e50")
    private static let wheelColor = hex("#c0392b")
    private static let brassColor = hex("#d4a017")

    // MARK: - Building blocks

    /// A box, centred on `at` (metres), turned `spin` about the vertical.
    static func box(_ size: SIMD3<Float>, at: SIMD3<Float>, spin: Float = 0,
                    color: SIMD3<Float>, roughness: Float = 0.9, metalness: Float = 0,
                    unlit: Bool = false, opacity: Float = 1,
                    castsShadow: Bool = false) -> ScenePrimitive {
        ScenePrimitive(shape: .box(width: m(size.x), height: m(size.y), depth: m(size.z)),
                       transform: Float4x4.translation(m(at)) * Float4x4.rotationZ(spin),
                       color: color, opacity: opacity, roughness: roughness,
                       metalness: metalness, unlit: unlit, castsShadow: castsShadow)
    }

    /// A flat plane lying on the ground at height `z` (metres).
    static func plane(width: Float, length: Float, at: SIMD3<Float>,
                      color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(shape: .plane(width: m(width), height: m(length)),
                       transform: Float4x4.translation(m(at)),
                       color: color, roughness: 0.95, castsShadow: false)
    }

    /// A shape plus where it sits on its object, relative to the object's base.
    struct Part {
        var shape: ScenePrimitive.Shape
        /// Already in world units.
        var local: Float4x4
        var color: SIMD3<Float>
        /// False for things that do not go black in a fire — stones, glass.
        var burns = true
        var roughness: Float = 0.9
    }

    private static func boxPart(_ size: SIMD3<Float>, at: SIMD3<Float>,
                                rotation: Float4x4 = matrix_identity_float4x4,
                                color: SIMD3<Float>, burns: Bool = true) -> Part {
        Part(shape: .box(width: m(size.x), height: m(size.y), depth: m(size.z)),
             local: Float4x4.translation(m(at)) * rotation,
             color: color, burns: burns)
    }

    /// A cylinder part. `MeshFactory` builds them along +Y, so `rotation` says which way it lies.
    private static func cylinderPart(radius: Float, length: Float, at: SIMD3<Float>,
                                     rotation: Float4x4, color: SIMD3<Float>,
                                     burns: Bool = true) -> Part {
        Part(shape: .cylinder(radius: m(radius), height: m(length)),
             local: Float4x4.translation(m(at)) * rotation,
             color: color, burns: burns)
    }

    /// Stands a +Y cylinder up along +Z.
    static let upright = Float4x4.rotationX(.pi / 2)
    /// Lays a +Y cylinder across, along X — wheels and hay bales.
    static let sideways = Float4x4.rotationZ(.pi / 2)

    // MARK: - Things to destroy

    enum Kind: CaseIterable {
        case pine
        case oak
        case house
        case hay
        /// Already on fire when you get there. Joel: *"add fires"* — and *"if you shoot fire it
        /// turns into ice"*, so a campfire is the quickest way to make ice.
        case campfire
    }

    /// How far a flame has to get to touch it, across the ground.
    static func radius(of kind: Kind, variant: Int) -> Float {
        switch kind {
        case .pine: return 1.25 * pineScale[variant]
        case .oak: return 1.8 * oakScale[variant]
        case .house: return 2.9
        case .hay: return 1.6
        case .campfire: return 1.0
        }
    }

    static func height(of kind: Kind, variant: Int) -> Float {
        switch kind {
        case .pine: return 5.6 * pineScale[variant]
        case .oak: return 5.0 * oakScale[variant]
        case .house: return 5.6
        case .hay: return 2.3
        case .campfire: return 1.6
        }
    }

    static let pineScale: [Float] = [0.85, 1.0, 1.25]
    static let oakScale: [Float] = [0.85, 1.0, 1.2]
    static let variants = 3

    /// The parts of each kind, built once. Index by `[variant]`.
    static let parts: [Kind: [[Part]]] = {
        var out: [Kind: [[Part]]] = [:]
        out[.pine] = pineScale.map(pine)
        out[.oak] = oakScale.map(oak)
        out[.house] = [hex("#f4e1c1"), hex("#e8c39e"), hex("#f7f2e8")].map(house)
        out[.hay] = (0..<variants).map { _ in hay() }
        out[.campfire] = (0..<variants).map { _ in campfire() }
        return out
    }()

    /// **A low-poly pine**: a brown post and four green cubes, each smaller than the one below
    /// and each turned 45° from the last, so from any side the outline is a stepped cone.
    private static func pine(_ s: Float) -> [Part] {
        let greens = ["#2f7d3a", "#3b9447", "#4caf50", "#5cbf5c"].map(hex)
        let tiers: [(w: Float, h: Float, z: Float)] = [(2.5, 1.5, 1.6), (1.9, 1.4, 2.8),
                                                       (1.3, 1.3, 3.9), (0.65, 0.9, 4.9)]
        var out = [boxPart(SIMD3(0.4, 0.4, 1.9) * s, at: SIMD3(0, 0, 0.95) * s,
                           color: hex("#7a5230"))]
        for (index, tier) in tiers.enumerated() {
            out.append(boxPart(SIMD3(tier.w, tier.w, tier.h) * s, at: SIMD3(0, 0, tier.z) * s,
                               rotation: Float4x4.rotationZ(index % 2 == 0 ? 0 : .pi / 4),
                               color: greens[index]))
        }
        return out
    }

    /// **A low-poly round tree**: a trunk and two big cubes tipped onto their corners, which is
    /// what a gem looks like and what a low-poly treetop looks like.
    private static func oak(_ s: Float) -> [Part] {
        let gem = Float4x4.rotationZ(.pi / 4) * Float4x4.rotationX(.pi / 4)
        let gem2 = Float4x4.rotationZ(0.3) * Float4x4.rotationY(.pi / 4)
        return [
            boxPart(SIMD3(0.5, 0.5, 2.4) * s, at: SIMD3(0, 0, 1.2) * s, color: hex("#6e4a2a")),
            boxPart(SIMD3(2.5, 2.5, 2.5) * s, at: SIMD3(0, 0, 3.3) * s, rotation: gem,
                    color: hex("#6abf3f")),
            boxPart(SIMD3(1.7, 1.7, 1.7) * s, at: SIMD3(0.7, 0.5, 4.1) * s, rotation: gem2,
                    color: hex("#7fd14e")),
        ]
    }

    /// **A cottage**: walls, a pointed roof made of two tipped slabs, a triangle at each end to
    /// fill the gap under them, a door and two windows on the side facing the track (local −X),
    /// and a chimney.
    private static func house(_ wall: SIMD3<Float>) -> [Part] {
        let roofRed = hex("#c0392b")
        let slab = Float(2.5 * 1.4142 + 0.45)
        return [
            boxPart(SIMD3(5, 4, 3), at: SIMD3(0, 0, 1.5), color: wall),
            // The gable ends: a square turned 45° about Y, its bottom half hidden in the walls.
            boxPart(SIMD3(3.536, 3.96, 3.536), at: SIMD3(0, 0, 3), rotation: Float4x4.rotationY(.pi / 4),
                    color: wall),
            boxPart(SIMD3(slab, 4.6, 0.2), at: SIMD3(-1.2, 0, 4.3),
                    rotation: Float4x4.rotationY(-.pi / 4), color: roofRed),
            boxPart(SIMD3(slab, 4.6, 0.2), at: SIMD3(1.2, 0, 4.3),
                    rotation: Float4x4.rotationY(.pi / 4), color: roofRed),
            boxPart(SIMD3(0.12, 0.95, 1.9), at: SIMD3(-2.5, 0, 0.95), color: hex("#7b4a2a")),
            boxPart(SIMD3(0.12, 0.95, 0.8), at: SIMD3(-2.5, 1.35, 1.9), color: hex("#bfe6ff"),
                    burns: false),
            boxPart(SIMD3(0.12, 0.95, 0.8), at: SIMD3(-2.5, -1.35, 1.9), color: hex("#bfe6ff"),
                    burns: false),
            boxPart(SIMD3(0.55, 0.55, 1.5), at: SIMD3(1.3, 1.0, 4.6), color: hex("#8e5a45")),
        ]
    }

    /// **A haystack**: three round bales, two on the ground and one on top.
    private static func hay() -> [Part] {
        let straw = hex("#e7c45a")
        return [
            cylinderPart(radius: 0.7, length: 1.4, at: SIMD3(0, -0.72, 0.7), rotation: sideways,
                         color: straw),
            cylinderPart(radius: 0.7, length: 1.4, at: SIMD3(0, 0.72, 0.7), rotation: sideways,
                         color: hex("#dcb84e")),
            cylinderPart(radius: 0.7, length: 1.4, at: SIMD3(0, 0, 1.85), rotation: sideways,
                         color: hex("#f0d070")),
        ]
    }

    /// **A campfire**: a ring of grey stones and two crossed logs. The flames are particles.
    private static func campfire() -> [Part] {
        var out: [Part] = []
        for index in 0..<6 {
            let angle = Float(index) / 6 * 2 * .pi
            out.append(boxPart(SIMD3(0.4, 0.4, 0.32),
                               at: SIMD3(cos(angle) * 0.75, sin(angle) * 0.75, 0.16),
                               rotation: Float4x4.rotationZ(angle + 0.4),
                               color: hex(index % 2 == 0 ? "#8e9aa3" : "#76838c"), burns: false))
        }
        out.append(boxPart(SIMD3(1.3, 0.24, 0.24), at: SIMD3(0, 0, 0.2),
                           rotation: Float4x4.rotationZ(0.6), color: hex("#6e4a2a")))
        out.append(boxPart(SIMD3(1.3, 0.24, 0.24), at: SIMD3(0, 0, 0.42),
                           rotation: Float4x4.rotationZ(-0.6), color: hex("#5b3b20")))
        return out
    }

    /// The block of ice something is frozen inside, at full size. Shrinks in eighths as it melts.
    static func iceSize(of kind: Kind) -> SIMD3<Float> {
        switch kind {
        case .pine: return SIMD3(3.4, 3.4, 7.4)
        case .oak: return SIMD3(4.6, 4.6, 6.6)
        case .house: return SIMD3(6.0, 5.0, 6.6)
        case .hay: return SIMD3(2.0, 3.4, 3.0)
        case .campfire: return SIMD3(2.2, 2.2, 2.0)
        }
    }

    /// Whole-number steps, so a melting block of ice is eight meshes rather than one a frame.
    static let iceSteps = 8

    // MARK: - Scenery

    /// Turns a cube so its corner (1,1,1) points straight up: a low-poly peak, or a treetop.
    static let onCorner = Float4x4.rotationX(0.9553) * Float4x4.rotationZ(.pi / 4)

    /// `value % count`, but never negative — tiles behind the start line have negative numbers.
    static func wrap(_ value: Int, _ count: Int) -> Int { ((value % count) + count) % count }

    /// A number between 0 and 1 that is always the same for the same two whole numbers — so a
    /// field is the same colour every frame without having to remember it.
    static func hash(_ a: Int, _ b: Int) -> Float {
        var x = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663))
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        x = x &* 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return Float(x % 10_000) / 10_000
    }

    /// The countryside around a train whose rear carriage is at `trainY`: the ground, the fields,
    /// the track, telegraph poles, a forest on the horizon, mountains and clouds.
    static func scenery(trainY: Float) -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        out.reserveCapacity(300)

        let from = trainY - drawBehind
        let to = trainY + drawAhead
        let middle = (from + to) / 2
        let length = drawAhead + drawBehind

        // One enormous plane underneath everything, so there is never a hole to the sky.
        out.append(ScenePrimitive(shape: .plane(width: m(700), height: m(700)),
                                  transform: Float4x4.translation(SIMD3(0, m(trainY + 60), -6)),
                                  color: groundColor, roughness: 1, castsShadow: false))

        // Fields, a patchwork either side, 24 m at a time.
        let fieldLength: Float = 24
        let firstField = Int(floor(from / fieldLength))
        let lastField = Int(floor(to / fieldLength))
        for tile in firstField...lastField {
            let y = (Float(tile) + 0.5) * fieldLength
            for side in [-1, 1] {
                let near = fieldColors[Int(hash(tile, side * 3) * Float(fieldColors.count))]
                let far = fieldColors[Int(hash(tile, side * 7 + 1) * Float(fieldColors.count))]
                out.append(plane(width: 26, length: fieldLength - 0.8,
                                 at: SIMD3(Float(side) * 16.5, y, 0), color: near))
                out.append(plane(width: 58, length: fieldLength - 0.8,
                                 at: SIMD3(Float(side) * 60, y, 0), color: far))
            }
        }

        // The track: a gravel bed, two rails, and sleepers where you can see them (in front of
        // the engine and behind your carriage — the train covers the rest).
        out.append(box(SIMD3(3.4, length, 0.3), at: SIMD3(0, middle, 0.15), color: ballastColor))
        for side: Float in [-0.72, 0.72] {
            out.append(box(SIMD3(0.1, length, 0.16), at: SIMD3(side, middle, 0.46),
                           color: railColor, roughness: 0.35, metalness: 0.6))
        }
        let sleeperSpacing: Float = 1.1
        for range in [(trainY - 32, trainY - 3), (trainY + 34, trainY + 75)] {
            var y = (range.0 / sleeperSpacing).rounded(.down) * sleeperSpacing
            while y < range.1 {
                out.append(box(SIMD3(2.5, 0.26, 0.12), at: SIMD3(0, y, 0.34),
                               color: sleeperColor))
                y += sleeperSpacing
            }
        }

        // Telegraph poles on the left, every 30 m — they are what tells you how fast you are going.
        let poleSpacing: Float = 30
        var poleY = (from / poleSpacing).rounded(.down) * poleSpacing
        while poleY < to {
            out.append(ScenePrimitive(shape: .cylinder(radius: m(0.12), height: m(7)),
                                      transform: Float4x4.translation(m(SIMD3(-4.6, poleY, 3.5)))
                                          * upright,
                                      color: poleColor, castsShadow: false))
            out.append(box(SIMD3(1.5, 0.14, 0.14), at: SIMD3(-4.6, poleY, 6.6), color: poleColor))
            poleY += poleSpacing
        }

        // A forest on the horizon, far too far away to burn: a trunk with a cube stood on its
        // corner for a top, which is the low-poly way to draw a tree from a long way off.
        let forestTile: Float = 10
        let firstTree = Int(floor(from / forestTile))
        let lastTree = Int(floor(to / forestTile))
        for tile in firstTree...lastTree {
            for side in [-1, 1] {
                let key = tile * 4
                let across = 30 + hash(key, side) * 55
                let along = (Float(tile) + hash(key, side + 9)) * forestTile
                let tall = hash(key, side + 21) < 0.5
                let size: Float = tall ? 3.4 : 2.6
                let spot = SIMD3(Float(side) * across, along, 0)
                out.append(box(SIMD3(0.5, 0.5, 2.4), at: spot + SIMD3(0, 0, 1.2),
                               color: hex("#5b3b20")))
                out.append(ScenePrimitive(
                    shape: .box(width: m(size), height: m(size), depth: m(size)),
                    transform: Float4x4.translation(m(spot + SIMD3(0, 0, 2.2 + size * 0.7)))
                        * Float4x4.rotationZ(hash(key, side + 33) * 2) * onCorner,
                    color: forestColors[wrap(key + side + 3, forestColors.count)],
                    roughness: 0.95, castsShadow: false))
            }
        }

        appendMountains(from: from, to: to, into: &out)
        appendClouds(from: from, to: to, into: &out)
        return out
    }

    /// **Low-poly mountains**: a cube stood on one corner pokes three faces out of the ground,
    /// which is exactly the shape of a low-poly peak. A smaller white cube on the same corner is
    /// the snow.
    private static func appendMountains(from: Float, to: Float, into out: inout [ScenePrimitive]) {
        let spacing: Float = 65
        let first = Int(floor((from - 40) / spacing))
        let last = Int(floor((to + 20) / spacing))
        for tile in first...last {
            for side in [-1, 1] {
                let big = hash(tile, side * 5) < 0.5
                let size: Float = big ? 46 : 34
                let across = 110 + hash(tile, side * 11) * 35
                let along = (Float(tile) + hash(tile, side * 13)) * spacing
                let spin = hash(tile, side * 17) * 2 * .pi
                let peakHeight = size * 0.866
                let base = SIMD3(Float(side) * across, along, -peakHeight * 0.35)
                let turn = Float4x4.rotationZ(spin) * onCorner

                out.append(ScenePrimitive(
                    shape: .box(width: m(size), height: m(size), depth: m(size)),
                    transform: Float4x4.translation(m(base)) * turn,
                    color: mountainColors[wrap(tile + side + 4, mountainColors.count)],
                    roughness: 1, castsShadow: false))
                let snow = size * 0.3
                out.append(ScenePrimitive(
                    shape: .box(width: m(snow), height: m(snow), depth: m(snow)),
                    transform: Float4x4.translation(m(base + SIMD3(0, 0, peakHeight - snow * 0.866)))
                        * turn,
                    color: snowColor, roughness: 0.8, castsShadow: false))
            }
        }
    }

    /// Clouds: three white boxes each, high up and far out.
    private static func appendClouds(from: Float, to: Float, into out: inout [ScenePrimitive]) {
        let spacing: Float = 45
        let first = Int(floor((from - 40) / spacing))
        let last = Int(floor((to + 40) / spacing))
        for tile in first...last {
            // Never right overhead — a cloud on top of you is a white wall across the sky.
            let side: Float = hash(tile, 29) < 0.5 ? -1 : 1
            let across = side * (50 + hash(tile, 31) * 70)
            let along = (Float(tile) + hash(tile, 37)) * spacing
            let height = 30 + hash(tile, 41) * 12
            let centre = SIMD3(across, along, height)
            out.append(box(SIMD3(14, 8, 4), at: centre, spin: 0.2, color: SIMD3(1, 1, 1),
                           unlit: true))
            out.append(box(SIMD3(9, 6, 3.4), at: centre + SIMD3(6, 2, 2), spin: 0.5,
                           color: SIMD3(0.93, 0.96, 1), unlit: true))
            out.append(box(SIMD3(8, 6, 3), at: centre + SIMD3(-7, -1, 1.2), spin: -0.3,
                           color: SIMD3(0.96, 0.98, 1), unlit: true))
        }
    }

    // MARK: - The train

    /// Where the engine's chimney is, relative to you. The smoke comes out of here.
    static let chimneyOffset = SIMD3<Float>(0, 33.6, 5.4)

    /// The train: your carriage (you stand near its back end), one more carriage, and the engine.
    static func train(trainY y: Float) -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        for centre in [y + 2, y + 15] {
            out.append(box(SIMD3(2.6, 12, 0.5), at: SIMD3(0, centre, 1.0), color: frameColor))
            out.append(box(SIMD3(3.0, 11.6, 2.4), at: SIMD3(0, centre, 2.45), color: carriageRed,
                           castsShadow: true))
            out.append(box(SIMD3(3.04, 11.0, 0.75), at: SIMD3(0, centre, 2.75), color: carriageCream))
            for window in 0..<5 {
                out.append(box(SIMD3(3.08, 1.2, 0.55),
                               at: SIMD3(0, centre - 4 + Float(window) * 2, 2.75),
                               color: windowColor, roughness: 0.3))
            }
            out.append(box(SIMD3(3.2, 12.0, 0.18), at: SIMD3(0, centre, 3.74), color: roofColor))
            // A walkway down the middle of the roof, which is what you are standing on.
            out.append(box(SIMD3(0.9, 11.6, 0.04), at: SIMD3(0, centre, 3.85),
                           color: hex("#6b5a48")))
            for along: Float in [-4.2, 4.2] {
                for side: Float in [-1.3, 1.3] {
                    out.append(ScenePrimitive(
                        shape: .cylinder(radius: m(0.45), height: m(0.25)),
                        transform: Float4x4.translation(m(SIMD3(side, centre + along, 0.45)))
                            * sideways,
                        color: frameColor, roughness: 0.6, metalness: 0.4))
                }
            }
            // The coupling to the next carriage.
            out.append(box(SIMD3(0.4, 1.2, 0.3), at: SIMD3(0, centre + 6.5, 1.1), color: frameColor))
        }

        // The engine.
        let engine = y + 28.5
        out.append(box(SIMD3(2.6, 13, 0.5), at: SIMD3(0, engine, 1.0), color: frameColor))
        out.append(box(SIMD3(3.0, 4.5, 3.0), at: SIMD3(0, y + 24.3, 2.75), color: locoBody,
                       castsShadow: true))
        out.append(box(SIMD3(3.3, 5.0, 0.22), at: SIMD3(0, y + 24.3, 4.35), color: carriageRed))
        out.append(box(SIMD3(3.06, 1.2, 0.8), at: SIMD3(0, y + 24.3, 3.4), color: windowColor,
                       roughness: 0.3))
        out.append(ScenePrimitive(shape: .cylinder(radius: m(1.2), height: m(8.6)),
                                  transform: Float4x4.translation(m(SIMD3(0, y + 30.8, 2.55))),
                                  color: locoBody, roughness: 0.5, metalness: 0.3,
                                  castsShadow: true))
        out.append(box(SIMD3(2.0, 0.2, 2.0), at: SIMD3(0, y + 35.15, 2.55), spin: 0,
                       color: carriageRed))
        out.append(box(SIMD3(0.5, 0.15, 0.5), at: SIMD3(0, y + 35.3, 3.1), color: hex("#fff3b0"),
                       unlit: true))
        out.append(ScenePrimitive(shape: .cylinder(radius: m(0.35), height: m(1.5)),
                                  transform: Float4x4.translation(m(SIMD3(0, y + 33.6, 4.35)))
                                      * upright,
                                  color: frameColor, roughness: 0.6, metalness: 0.3))
        out.append(ScenePrimitive(shape: .cylinder(radius: m(0.5), height: m(0.25)),
                                  transform: Float4x4.translation(m(SIMD3(0, y + 33.6, 5.1)))
                                      * upright,
                                  color: frameColor, roughness: 0.6, metalness: 0.3))
        out.append(box(SIMD3(0.8, 0.8, 0.7), at: SIMD3(0, y + 30, 3.9), spin: .pi / 4,
                       color: brassColor, roughness: 0.4, metalness: 0.6))
        out.append(box(SIMD3(2.8, 0.7, 0.7), at: SIMD3(0, y + 35.4, 0.7), spin: 0,
                       color: carriageRed))
        for along: Float in [26.5, 28.7, 30.9] {
            for side: Float in [-1.35, 1.35] {
                out.append(ScenePrimitive(
                    shape: .cylinder(radius: m(0.8), height: m(0.22)),
                    transform: Float4x4.translation(m(SIMD3(side, y + along, 0.8))) * sideways,
                    color: wheelColor, roughness: 0.6, metalness: 0.2))
            }
        }
        return out
    }

    // MARK: - The flamethrower

    /// The flamethrower, held low and to the right, pointing wherever you are aiming.
    ///
    /// `basis` turns the gun's own axes (X right, Y down the barrel, Z up) into the world, with
    /// its origin already at the grip. Built every frame because it moves with your eyes.
    static func flamethrower(basis: Float4x4, firing: Bool, time: Float) -> [ScenePrimitive] {
        func part(_ shape: ScenePrimitive.Shape, at: SIMD3<Float>,
                  rotation: Float4x4 = matrix_identity_float4x4, color: SIMD3<Float>,
                  roughness: Float = 0.6, metalness: Float = 0,
                  unlit: Bool = false) -> ScenePrimitive {
            ScenePrimitive(shape: shape,
                           transform: basis * Float4x4.translation(m(at)) * rotation,
                           color: color, roughness: roughness, metalness: metalness,
                           unlit: unlit, castsShadow: false)
        }

        var out: [ScenePrimitive] = [
            // The fuel tank, red with a yellow stripe.
            part(.box(width: m(0.17), height: m(0.32), depth: m(0.17)), at: SIMD3(0, -0.05, -0.07),
                 color: hex("#d63031"), roughness: 0.5),
            part(.box(width: m(0.18), height: m(0.06), depth: m(0.18)), at: SIMD3(0, 0.03, -0.07),
                 color: hex("#fdcb6e"), roughness: 0.5),
            // The barrel and nozzle. Cylinders already run along +Y, which is down the barrel.
            part(.cylinder(radius: m(0.03), height: m(0.46)), at: SIMD3(0, 0.29, 0.035),
                 color: hex("#b8c2cc"), roughness: 0.3, metalness: 0.5),
            part(.cylinder(radius: m(0.05), height: m(0.08)), at: SIMD3(0, 0.54, 0.035),
                 color: hex("#f39c12"), roughness: 0.4, metalness: 0.3),
            // The grip and trigger guard.
            part(.box(width: m(0.05), height: m(0.07), depth: m(0.17)), at: SIMD3(0, -0.18, -0.13),
                 color: hex("#1e1e24")),
        ]
        // The pilot light at the tip: a little blue flame when idle, a roaring orange one when
        // the trigger is down.
        let flicker = 0.5 + 0.5 * sin(time * 40)
        out.append(part(.box(width: m(firing ? 0.09 : 0.04), height: m(firing ? 0.09 : 0.04),
                             depth: m(firing ? 0.09 : 0.04)),
                        at: SIMD3(0, 0.6, 0.035),
                        rotation: Float4x4.rotationY(time * 9),
                        color: firing ? SIMD3(1, 0.75 + 0.2 * flicker, 0.3) : SIMD3(0.4, 0.7, 1),
                        unlit: true))
        return out
    }
}
