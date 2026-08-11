import Foundation
import simd

/// The track School Rush runs down: how wide it is, where the three lanes are, and every piece
/// of scenery and every obstacle that scrolls past.
///
/// It is built the same way `Tennis3DCourt` is — as a list of boxes, cylinders and planes the
/// renderer turns into draw calls — with one difference that shapes the whole file: **an endless
/// runner has no static geometry.** The tennis court is eighty primitives built once because a
/// court does not move. Here the world is a strip that never ends, so the scenery is generated
/// from the player's position every frame, one six-metre tile at a time, and tiles that have
/// gone past are simply not asked for again.
///
/// The one rule that governs the numbers below: `ScenePrimitiveRenderer` caches a GPU mesh per
/// **distinct size**, so every hedge is the same hedge and every paving slab is the same slab.
/// A track that varied its sizes smoothly would ask for a new mesh sixty times a second.
enum SchoolRushTrack {

    // MARK: - Scale

    /// World units per metre, the same conversion tennis uses, and for the same reason: it is
    /// pinned to the character rig, which is about 50 units tall. Get it wrong and the runner is
    /// an ant on a motorway.
    static let unitsPerMetre: Double = 27

    static func metres(_ value: Double) -> Double { value * unitsPerMetre }

    // MARK: - Shape of the track

    /// Three lanes, because two is a coin toss and four is more than a thumb can aim at.
    static let laneCount = 3
    /// Far enough apart that standing in the wrong one is obvious from this camera, close enough
    /// that a swipe crosses one in a quarter of a second.
    static let laneSpacing = metres(1.75)

    /// Where lane 0, 1 and 2 sit in world X. Lane 1 is the middle, which is where a run starts.
    static func laneX(_ lane: Int) -> Double { Double(lane - 1) * laneSpacing }

    /// Half the width of the paving. A stride wider than the outer lanes, so a swerve has
    /// somewhere to overshoot into rather than hitting an invisible wall.
    static let pathHalfWidth = metres(2.95)

    /// **Which way forward is.** The camera sits on the +Y side looking towards −Y, so running
    /// away from it means running down decreasing Y — exactly as the tennis player faces the net
    /// at 270°. Everything in this game is measured as "metres travelled", which is −y.
    static func metresTravelled(fromY y: Double) -> Double { -y / unitsPerMetre }

    /// One repeating piece of track. Also the paving stripe, which is what actually sells the
    /// speed: a runner on a plain surface at 14 m/s looks like a runner standing still.
    static let tileLength = metres(6)

    /// How much track is drawn. Ahead is generous — the far clip plane is 4000 units and the
    /// camera orbits at about 730, so there is plenty of room and the horizon should be scenery
    /// rather than an edge. Behind is only enough that the ground does not vanish under the
    /// player's own shadow.
    static let drawAhead = metres(96)
    static let drawBehind = metres(24)

    // MARK: - Colours

    /// The clear colour behind everything, which from this camera is the top of the frame.
    static let skyHex = "#a9d9ef"

    private static let pavingLight = parseHexColor("#c8bfae")
    private static let pavingDark = parseHexColor("#b3ab9b")
    private static let kerbColor = parseHexColor("#8d8578")
    private static let laneLineColor = parseHexColor("#f6f4e9")
    /// Two greens rather than one, alternating tile by tile. Mown stripes are the cheapest thing
    /// in this file and do more for how the verge reads than anything else on it — the same trick
    /// the tennis stadium's lawn uses.
    private static let grassColor = parseHexColor("#5da13c")
    private static let grassStripeColor = parseHexColor("#6cb247")
    private static let hedgeColor = parseHexColor("#2c6b34")
    private static let buildingColor = parseHexColor("#cbab86")
    private static let roofColor = parseHexColor("#7c4b3b")
    private static let postColor = parseHexColor("#39434f")
    private static let lampColor = parseHexColor("#fff4c4")

    private static let bagColor = parseHexColor("#28407e")
    private static let bagFlapColor = parseHexColor("#d94f3d")
    private static let bagPocketColor = parseHexColor("#1d3060")
    private static let bagStrapColor = parseHexColor("#4a5568")
    private static let coneColor = parseHexColor("#f26a1b")
    private static let coneBandColor = parseHexColor("#f4f4f0")
    private static let coneBaseColor = parseHexColor("#2b2b2b")
    private static let binColor = parseHexColor("#2f7d4f")
    private static let binRimColor = parseHexColor("#1e4b30")
    private static let binMouthColor = parseHexColor("#101c14")
    private static let carColor = parseHexColor("#c0392b")
    private static let carGlassColor = parseHexColor("#4a6b80")
    private static let tyreColor = parseHexColor("#1c1c1c")
    private static let tailLightColor = parseHexColor("#ff5a4a")
    private static let coinColor = parseHexColor("#f5c518")

    // MARK: - Scenery

    /// Every piece of ground and roadside furniture within sight of a runner at `y`.
    ///
    /// Around a hundred primitives, rebuilt each frame. That sounds wasteful and is not: the
    /// tennis court hands over about the same number every frame already, and generating them is
    /// a loop over fifteen tiles doing arithmetic.
    static func scenery(aroundY y: Double) -> [ScenePrimitive] {
        let travelled = -y
        let first = Int(floor((travelled - drawBehind) / tileLength))
        let last = Int(floor((travelled + drawAhead) / tileLength))
        guard first <= last else { return [] }

        var out: [ScenePrimitive] = []
        out.reserveCapacity((last - first + 1) * 8)
        for tile in first...last { appendTile(tile, to: &out) }
        return out
    }

    private static func appendTile(_ tile: Int, to out: inout [ScenePrimitive]) {
        let centreY = -(Double(tile) + 0.5) * tileLength

        // The paving, in alternating stripes. This is the speedometer.
        out.append(slab(x: 0, y: centreY,
                        width: pathHalfWidth * 2, length: tileLength, z: 2,
                        color: tile % 2 == 0 ? pavingLight : pavingDark))

        // The two lines between the lanes, so which lane you are in is never a guess.
        for side in [-1.0, 1.0] {
            out.append(slab(x: side * laneSpacing / 2, y: centreY,
                            width: metres(0.09), length: tileLength, z: 4,
                            color: laneLineColor, unlit: true))
        }

        // Grass either side, a kerb where it meets the paving, and a hedge beyond that so the
        // track has walls.
        for side in [-1.0, 1.0] {
            out.append(slab(x: side * (pathHalfWidth + metres(4)), y: centreY,
                            width: metres(8), length: tileLength, z: 0,
                            color: tile % 2 == 0 ? grassColor : grassStripeColor))
            // The kerb. A hand's width of raised stone between path and grass, which is what
            // stops the two reading as one flat sheet of colour with a line drawn on it.
            out.append(upright(x: side * (pathHalfWidth + metres(0.09)), y: centreY,
                               sizeX: metres(0.18), sizeY: tileLength, height: metres(0.12),
                               color: kerbColor, castsShadow: false))
            out.append(upright(x: side * (pathHalfWidth + metres(0.45)), y: centreY,
                               sizeX: metres(0.7), sizeY: tileLength, height: metres(1.15),
                               color: hedgeColor, castsShadow: false))
        }

        // A lamp post every fourth tile — 24 m apart — alternating sides.
        if tile % 4 == 0 {
            let side: Double = (tile / 4) % 2 == 0 ? -1 : 1
            let x = side * (pathHalfWidth + metres(1.3))
            out.append(ScenePrimitive(
                shape: .cylinder(radius: Float(metres(0.09)), height: Float(metres(3.4))),
                transform: Float4x4.translation(SIMD3(Float(x), Float(-centreY), Float(metres(1.7))))
                    // MeshFactory builds cylinders along +Y; stand it up along +Z.
                    * Float4x4.rotationX(.pi / 2),
                color: postColor,
                roughness: 0.5,
                metalness: 0.4,
                castsShadow: false))
            out.append(ScenePrimitive(
                shape: .sphere(radius: Float(metres(0.26))),
                transform: Float4x4.translation(SIMD3(Float(x), Float(-centreY), Float(metres(3.5)))),
                color: lampColor,
                unlit: true,
                castsShadow: false))
        }

        // A school block every third tile, set back behind the grass. **Always on the right**,
        // because the school bus parks on the left and the two are big enough to stand in each
        // other. Alternating both would need the two rules to know about each other; giving each
        // a side is the same picture and no arithmetic.
        //
        // It is there to give the horizon something to be, so it never casts a shadow — a 12 m
        // building in a 1024² shadow map costs more than the shadow is worth.
        if tile % 3 == 0 {
            // **9.5 m from the centre line, not 14.** The camera's field of view narrowed when
            // the runner was brought closer, and at 14 m the buildings were never once in shot —
            // a whole third of the scenery budget spent on something nobody could see. The near
            // face now sits 2.2 m past the hedge, which is where a school building stands.
            let x = pathHalfWidth + metres(6.6)
            out.append(upright(x: x, y: centreY, sizeX: metres(9), sizeY: metres(12),
                               height: metres(5.5), color: buildingColor, castsShadow: false))
            out.append(ScenePrimitive(
                shape: .box(width: Float(metres(9.6)), height: Float(metres(12.6)),
                            depth: Float(metres(0.5))),
                transform: Float4x4.translation(SIMD3(Float(x), Float(-centreY),
                                                      Float(metres(5.75)))),
                color: roofColor,
                roughness: 0.9,
                castsShadow: false))
        }
    }

    // MARK: - The school bus

    /// **The one authored model in the game**, parked on the left-hand verge every seventh tile —
    /// 42 m apart, so there is usually one in shot and never a row of them.
    ///
    /// It is scenery rather than an obstacle, and that is a decision rather than an oversight.
    /// The rule is "you can jump over everything except people", and the bus is 3 m to the roof:
    /// a jump that cleared it would have to peak higher than the bus is tall, which would also
    /// clear every row of obstacles in the game and turn the jump button into a cheat code. Eleven
    /// metres of school bus standing beside the path does more for the place than eleven metres of
    /// wall across it.
    ///
    /// The model is authored in **metres, Y-up, with the bus lying along its own X**. So: tip it
    /// up (glTF Y-up → this world's Z-up, the same `rotationX` `PropRenderer` applies to every
    /// placed prop), scale it to world units, then turn it a quarter turn about the vertical so
    /// its length runs along the track instead of across it.
    static func sceneryModels(aroundY y: Double) -> [SceneModel] {
        let travelled = -y
        let first = Int(floor((travelled - drawBehind) / tileLength))
        let last = Int(floor((travelled + drawAhead) / tileLength))
        guard first <= last else { return [] }

        var out: [SceneModel] = []
        let busX = Float(-(pathHalfWidth + metres(2.9)))
        let treeX = Float(-(pathHalfWidth + metres(5.4)))

        for tile in first...last {
            let centreY = Float((Double(tile) + 0.5) * tileLength)   // render space negates Y

            if tile % 7 == 0 {
                out.append(SceneModel(
                    path: "models/school_bus.glb",
                    transform: Float4x4.translation(SIMD3(busX, centreY, 0))
                        * Float4x4.rotationZ(.pi / 2)
                        * Float4x4.scale(SIMD3(repeating: Float(unitsPerMetre)))
                        * Float4x4.rotationX(.pi / 2),
                    castsShadow: false))
            }

            // Trees fill the left verge wherever a bus is not parked. The model is 6.6 m tall in
            // its own units and its trunk starts 0.37 below its origin, so it is scaled to about
            // five metres and lifted by that same 0.37 to stand on the grass rather than in it.
            // Turned a different way on every third one, so a row of them is not one tree
            // photocopied — which is exactly what it looked like before the rotation went in.
            if tile % 5 == 0 && tile % 7 != 0 {
                let scale = Float(unitsPerMetre) * 0.78
                let spin = Float(tile % 3) * 1.9
                out.append(SceneModel(
                    path: "models/fantasy_tree.glb",
                    transform: Float4x4.translation(SIMD3(treeX, centreY, 0.373 * scale))
                        * Float4x4.rotationZ(spin)
                        * Float4x4.scale(SIMD3(repeating: scale))
                        * Float4x4.rotationX(.pi / 2),
                    castsShadow: false))
            }
        }
        return out
    }

    // MARK: - Obstacles

    /// What is in the way, and how you are meant to get past it.
    ///
    /// `top` is the only number the collision test reads: a runner whose feet are above it has
    /// cleared the thing. `isJumpable` is not a rule the physics enforces — it is a promise the
    /// *generator* keeps, so a lane blocked by a person always has a free lane beside it.
    struct Obstacle {
        enum Kind {
            case bag
            case cone
            case bin
            case pupil
            case car
        }

        var kind: Kind
        var x: Double
        var y: Double
        /// Which of the three lanes this sits in, so the generator can reason about what is free.
        var lane: Int

        var halfWidth: Double { Self.halfWidth(of: kind) }
        var halfDepth: Double { Self.halfDepth(of: kind) }
        var top: Double { Self.top(of: kind) }
        var isJumpable: Bool { Self.isJumpable(kind) }

        static func halfWidth(of kind: Kind) -> Double {
            switch kind {
            case .bag: return metres(0.24)
            case .cone: return metres(0.20)
            case .bin: return metres(0.34)
            case .pupil: return metres(0.34)
            case .car: return metres(0.90)
            }
        }

        static func halfDepth(of kind: Kind) -> Double {
            switch kind {
            case .bag: return metres(0.20)
            case .cone: return metres(0.20)
            case .bin: return metres(0.34)
            case .pupil: return metres(0.30)
            case .car: return metres(1.95)
            }
        }

        /// How high you have to be to be over it.
        static func top(of kind: Kind) -> Double {
            switch kind {
            case .bag: return metres(0.54)
            case .cone: return metres(0.72)
            case .bin: return metres(0.92)
            case .pupil: return metres(1.55)
            case .car: return metres(1.42)
            }
        }

        /// **Everything except people**, which is Joel's rule and the reason the jump is as big
        /// as it is.
        ///
        /// A car is 3.9 m long and 1.42 m to the roof, so clearing one is not a hop: the runner
        /// has to stay above 1.52 m for the whole four and a half metres it takes to pass over
        /// it. That is what set `SchoolRushGame.Tuning.jumpSpeed` — the arithmetic is there. A
        /// person is not jumpable because a person is the one thing you are meant to go *round*,
        /// and because leaping over a classmate's head is a different game.
        static func isJumpable(_ kind: Kind) -> Bool { kind != .pupil }
    }

    /// A gold coin standing on edge, facing the runner.
    struct Coin {
        var x: Double
        var y: Double
        /// Height off the ground of its centre. Coins over a jumpable obstacle sit high enough
        /// that collecting them and clearing the obstacle are the same move.
        var z: Double
        var collected = false
    }

    /// The shapes one obstacle is made of. Every size here is a constant, so the mesh cache sees
    /// about two dozen distinct shapes for the whole game — well inside its limit of 256.
    static func primitives(for obstacle: Obstacle) -> [ScenePrimitive] {
        let x = obstacle.x
        let y = obstacle.y

        /// A cylinder standing on its end at height `z`, which is what most of the small props
        /// are made of. `MeshFactory` builds cylinders along +Y, so each one is tipped upright.
        func disc(radius: Double, height: Double, z: Double,
                  color: SIMD3<Float>, roughness: Float = 0.85) -> ScenePrimitive {
            ScenePrimitive(
                shape: .cylinder(radius: Float(metres(radius)), height: Float(metres(height))),
                transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(metres(z))))
                    * Float4x4.rotationX(.pi / 2),
                color: color,
                roughness: roughness)
        }

        switch obstacle.kind {
        case .bag:
            // **A rucksack standing up, not a blue box.** The first version was one box with a
            // red bar across it and Joel could not tell what it was meant to be — which is fair,
            // it was a box. A bag is a body, a flap, a front pocket and two straps, and it has to
            // stand up rather than lie down: from a camera behind and above, a flat thing is a
            // stain on the pavement and an upright one is something in the way.
            return [
                upright(x: x, y: y, sizeX: metres(0.44), sizeY: metres(0.26),
                        height: metres(0.46), color: bagColor),
                // The flap over the top, which is the part that says "bag" from above.
                upright(x: x, y: y - metres(0.02), sizeX: metres(0.47), sizeY: metres(0.30),
                        height: metres(0.10), z0: metres(0.44), color: bagFlapColor),
                // The front pocket, on the side the runner sees coming.
                upright(x: x, y: y + metres(0.16), sizeX: metres(0.30), sizeY: metres(0.09),
                        height: metres(0.20), z0: metres(0.06), color: bagPocketColor),
                // Two shoulder straps down the back.
                upright(x: x - metres(0.11), y: y - metres(0.15), sizeX: metres(0.07),
                        sizeY: metres(0.05), height: metres(0.36), z0: metres(0.05),
                        color: bagStrapColor),
                upright(x: x + metres(0.11), y: y - metres(0.15), sizeX: metres(0.07),
                        sizeY: metres(0.05), height: metres(0.36), z0: metres(0.05),
                        color: bagStrapColor),
            ]

        case .cone:
            // **Three cylinders and a white band.** There is no cone primitive, and a single
            // straight cylinder in traffic orange is a barrel. Three of decreasing radius give a
            // stepped taper the eye reads as a cone at any distance this game shows one at, and
            // the reflective band is the detail that names it.
            return [
                upright(x: x, y: y, sizeX: metres(0.38), sizeY: metres(0.38),
                        height: metres(0.05), color: coneBaseColor),
                disc(radius: 0.155, height: 0.20, z: 0.15, color: coneColor, roughness: 0.8),
                disc(radius: 0.128, height: 0.10, z: 0.31, color: coneBandColor, roughness: 0.55),
                disc(radius: 0.115, height: 0.20, z: 0.40, color: coneColor, roughness: 0.8),
                disc(radius: 0.070, height: 0.18, z: 0.60, color: coneColor, roughness: 0.8),
            ]

        case .bin:
            // **A litter bin with a mouth.** Two flat cylinders read as a tin can; a foot at the
            // bottom, a heavier rim at the top and a dark opening inside that rim read as
            // something you could actually drop a crisp packet into.
            return [
                disc(radius: 0.33, height: 0.07, z: 0.035, color: binRimColor),
                disc(radius: 0.29, height: 0.78, z: 0.44, color: binColor),
                disc(radius: 0.34, height: 0.10, z: 0.86, color: binRimColor),
                disc(radius: 0.25, height: 0.03, z: 0.905, color: binMouthColor, roughness: 1),
            ]

        case .pupil:
            // Drawn as a real character, not as boxes — see `SchoolRushGame.sceneCharacters`.
            return []

        case .car:
            // **Built to be recognised from behind and above**, which is the only angle this game
            // ever shows it from. The first version was a full-width slab with a full-width glass
            // slab on top and it read as a red wall: at 24° above the ground a four-metre car is
            // compressed to about 1.7 m of screen depth, so almost all of what you see is roof.
            // The greenhouse is therefore narrower than the body and pushed forward, which leaves
            // a boot lid and two tail lights at the near end — and a red box with a boot and tail
            // lights is unmistakably the back of a car.
            //
            // It is also **deliberately a small car**: 3.9 m long and 1.42 m to the roof, because
            // every centimetre longer or taller is a bigger jump needed to clear it, and the jump
            // has to stay a jump rather than a flight.
            var out: [ScenePrimitive] = [
                upright(x: x, y: y, sizeX: metres(1.78), sizeY: metres(3.90),
                        height: metres(0.66), z0: metres(0.30), color: carColor),
                upright(x: x, y: y - metres(0.40), sizeX: metres(1.50), sizeY: metres(1.75),
                        height: metres(0.46), z0: metres(0.96), color: carGlassColor),
            ]
            // Tail lights, on the rear face — the near end, which is +Y.
            for sideX in [-1.0, 1.0] {
                out.append(ScenePrimitive(
                    shape: .box(width: Float(metres(0.40)), height: Float(metres(0.10)),
                                depth: Float(metres(0.15))),
                    transform: Float4x4.translation(SIMD3(Float(x + sideX * metres(0.58)),
                                                          Float(-(y + metres(1.93))),
                                                          Float(metres(0.78)))),
                    color: tailLightColor,
                    unlit: true,
                    castsShadow: false))
            }
            // Four wheels. A cylinder is built along +Y, so a quarter turn about Z lays it on its
            // side with the axle running across the car.
            for sideX in [-1.0, 1.0] {
                for offsetY in [-metres(1.25), metres(1.25)] {
                    out.append(ScenePrimitive(
                        shape: .cylinder(radius: Float(metres(0.30)), height: Float(metres(0.22))),
                        transform: Float4x4.translation(SIMD3(Float(x + sideX * metres(0.85)),
                                                              Float(-(y + offsetY)),
                                                              Float(metres(0.30))))
                            * Float4x4.rotationZ(.pi / 2),
                        color: tyreColor,
                        roughness: 0.95))
                }
            }
            return out
        }
    }

    /// A coin, drawn on edge so its face points at the camera. A sphere would have been simpler
    /// and would have read as a ball.
    ///
    /// **Unlit, which is the whole reason it looks like gold.** Metal and a low roughness were the
    /// obvious choice and came out a dark olive disc: there is no environment map in this
    /// renderer, so a mirror-like surface has nothing to reflect but one directional light and
    /// spends most of its area reflecting the void. Flat gold reads as gold from every angle,
    /// which is the same trick the painted tennis lines use.
    static func primitive(for coin: Coin) -> ScenePrimitive {
        ScenePrimitive(
            shape: .cylinder(radius: Float(metres(0.20)), height: Float(metres(0.06))),
            transform: Float4x4.translation(SIMD3(Float(coin.x), Float(-coin.y), Float(coin.z))),
            color: coinColor,
            unlit: true,
            castsShadow: false)
    }

    // MARK: - Building blocks

    /// A flat slab lying on the ground, centred on (x, y) in **world** space. Render space
    /// negates Y; a plane already faces +Z, so nothing needs rotating.
    private static func slab(x: Double, y: Double, width: Double, length: Double, z: Double,
                             color: SIMD3<Float>, unlit: Bool = false) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(width), height: Float(length)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z))),
            color: color,
            roughness: 0.95,
            unlit: unlit,
            castsShadow: false)
    }

    /// A box standing on the ground. `sizeX` runs across the track, `sizeY` along it, `height`
    /// up — which is `ScenePrimitive.Shape.box`'s width, height and depth in that order.
    private static func upright(x: Double, y: Double,
                                sizeX: Double, sizeY: Double, height: Double,
                                z0: Double = 0,
                                color: SIMD3<Float>,
                                castsShadow: Bool = true) -> ScenePrimitive {
        ScenePrimitive(
            shape: .box(width: Float(sizeX), height: Float(sizeY), depth: Float(height)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z0 + height / 2))),
            color: color,
            roughness: 0.9,
            castsShadow: castsShadow)
    }
}
