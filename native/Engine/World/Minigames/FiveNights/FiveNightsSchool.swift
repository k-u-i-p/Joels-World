import Foundation
import simd

/// The building **Five Nights at St Peters** is played in: a security office with a corridor out
/// of each side, and six rooms hanging off those corridors for the cameras to look at.
///
/// It is built the same way `SchoolRushTrack` and the tennis court are — a list of boxes and
/// planes the renderer turns into draw calls — with one difference that decides every number
/// below: **this world does not move, so it is built once.** `building` is a `let` that is
/// assembled the first time it is asked for and handed back unchanged every frame after that.
/// Only the two shutters and the two doorway lights are rebuilt per frame, because only they
/// change.
///
/// **There are no ceilings and the near wall of every room is a low rail.** The camera in this
/// engine orbits a focus point from a fixed distance and looks at it from above — it cannot be
/// put inside a room at head height, because the eye would then be outside the building looking
/// at the back of a wall. So every room is a dollhouse: full-height walls on the three far
/// sides, an ankle-high rail on the side the camera looks from. It reads as a plan view of a
/// school at night, which is what a CCTV monitor shows anyway.
enum FiveNightsSchool {

    // MARK: - Scale

    /// World units per metre — the same 27 the runner and the tennis court use, and for the same
    /// reason: it is pinned to the character rig, which is about 50 units tall.
    static let unitsPerMetre: Double = 27

    static func metres(_ value: Double) -> Double { value * unitsPerMetre }

    /// Which side of the office something is on. The two doors, the two lights, and every child's
    /// route end up sorted by this.
    enum Side {
        case west
        case east

        var other: Side { self == .west ? .east : .west }
        /// −1 for the west side, +1 for the east. Multiplying by this mirrors any placement.
        var sign: Double { self == .west ? -1 : 1 }
        var label: String { self == .west ? "WEST" : "EAST" }
    }

    // MARK: - Rooms

    /// Every place a child can be, plus the office they are trying to reach.
    enum Room: Int, CaseIterable {
        case office
        case assemblyHall
        case classroom
        case toilets
        case westCorridor
        case diningHall
        case playground
        case mainEntrance
    }

    /// Where a room is and how big, in **metres**, centred on the office at the origin.
    struct Plan {
        var name: String
        var x: Double
        var y: Double
        var width: Double
        var length: Double
        /// The playground has no roof and no lino, so it gets grass and a wall rather than a
        /// floor and plaster.
        var outdoor: Bool = false
    }

    static func plan(_ room: Room) -> Plan {
        switch room {
        case .office:        return Plan(name: "Security Office", x: 0, y: 0, width: 7.5, length: 6)
        case .westCorridor:  return Plan(name: "West Corridor", x: -10.5, y: 0, width: 11, length: 3.6)
        case .mainEntrance:  return Plan(name: "Main Entrance", x: 11, y: 0, width: 12, length: 4.6)
        case .classroom:     return Plan(name: "Classroom", x: -21, y: -8, width: 10, length: 9)
        case .toilets:       return Plan(name: "Toilets", x: -21, y: 8, width: 10, length: 9)
        case .diningHall:    return Plan(name: "Dining Hall", x: 21, y: -8, width: 11, length: 9)
        case .playground:    return Plan(name: "Playground", x: 21, y: 8, width: 11, length: 9, outdoor: true)
        case .assemblyHall:  return Plan(name: "Assembly Hall", x: 0, y: -13, width: 15, length: 10)
        }
    }

    /// The rooms with a camera in them, in the order they are numbered on the monitor. The office
    /// is not one of them — you are sitting in it.
    static let cameras: [Room] = [
        .assemblyHall, .classroom, .toilets, .westCorridor, .diningHall, .playground, .mainEntrance,
    ]

    static func cameraNumber(of room: Room) -> Int {
        (cameras.firstIndex(of: room) ?? 0) + 1
    }

    // MARK: - Places a character can stand, in world units

    /// The middle of a room. Two children in the same room would stand in the same spot, so
    /// `slot` spreads them out instead — this is only used for the camera.
    static func centre(of room: Room) -> (x: Double, y: Double) {
        let p = plan(room)
        return (metres(p.x), metres(p.y))
    }

    /// Where the `index`-th child in a room stands. Spread across the room's width, and staggered
    /// in depth so two of them never line up into one silhouette.
    static func slot(_ room: Room, index: Int) -> (x: Double, y: Double) {
        let p = plan(room)
        // Centred on the middle of the cast, not on the middle of a group of four: with five
        // children the old offset pushed the last one through the wall of a ten-metre room.
        let across = (Double(index) - 2.0) * min(1.9, p.width / 6)
        let back = (index % 2 == 0) ? -0.6 : 0.6
        return (metres(p.x + across), metres(p.y + back))
    }

    /// The doorway of the office, from outside: where a child stands when it is one step from
    /// getting in, and where the light shines.
    static func doorway(_ side: Side) -> (x: Double, y: Double) {
        (metres(side.sign * 5.4), 0)
    }

    /// In the office, right in front of the guard. Nothing good stands here.
    static let officeFloor = (x: 0.0, y: metres(1.0))

    /// Where Balloon Barry stands while he is in: off to one side of the desk, where he is
    /// impossible to miss and impossible to do anything about.
    static let barryPerch = (x: metres(-2.3), y: metres(0.4))

    // MARK: - Camera views

    /// Where the camera looks for a given feed, and how many metres of it fit across the screen.
    /// Wider is further away; this is the only thing that decides how big a child looks.
    static func view(of room: Room) -> (x: Double, y: Double, widthMetres: Double) {
        let p = plan(room)
        // **CAM 7 is framed on the door, not on the room.** Centred like the others, the front
        // doors sat half off the right-hand edge of the picture — and the front doors are the
        // only thing on that camera anybody needs to see. So it looks down the last two thirds
        // of the hall instead, tight enough that a child standing at them is unmistakable.
        if room == .mainEntrance {
            return (metres(p.x + 2.6), metres(p.y), p.width)
        }
        return (metres(p.x), metres(p.y), p.width + 4)
    }

    /// The office view: both doorways at once, and a metre of corridor past each of them. This is
    /// the picture the whole game is played from, so it is framed by hand rather than from the
    /// office's own plan.
    static let officeView = (x: 0.0, y: metres(0.6), widthMetres: 15.5)

    // MARK: - Colours

    /// The clear colour, which is everything past the outside walls.
    ///
    /// **It is far darker than it looks here, and deliberately so.** `Renderer` runs a map's
    /// `background_color` through `linearToSRGB` by hand and then hands it to a drawable that is
    /// itself sRGB, so the value is encoded twice: `#080810` — a night blue — arrives on screen
    /// as a mid-grey lilac, which is what the first build of this looked like. Working backwards
    /// through the second encode, a final colour of about `#0a0a12` needs this. Anything set here
    /// should be checked on a device rather than reasoned about.
    static let nightHex = "#010103"

    /// **A school nobody has cleaned in years**, which is the look Joel asked for. Two rules got
    /// it there and both are worth keeping if these are ever repainted:
    ///
    /// - **Nothing is saturated and nothing is bright.** Damp concrete is a green-grey, dead
    ///   grass is a brown-green, and old lino is the colour of dishwater. A single clean colour
    ///   anywhere in the frame makes the rest look like a mistake rather than a ruin.
    /// - **Every surface has a dirtier version of itself.** `stainColor`, `rustColor` and
    ///   `debrisColor` are what the decay pass paints with, and they are close enough to the
    ///   surfaces they sit on to read as damp and dust rather than as spilled paint.
    private static let floorColor = parseHexColor("#26262b")
    private static let corridorFloorColor = parseHexColor("#2b2c31")
    private static let officeFloorColor = parseHexColor("#33343a")
    private static let grassColor = parseHexColor("#2b3122")
    private static let wallColor = parseHexColor("#3f4a43")
    private static let railColor = parseHexColor("#333a35")
    private static let woodColor = parseHexColor("#4b3b2a")
    private static let deskTopColor = parseHexColor("#6a563c")
    private static let metalColor = parseHexColor("#4a525c")
    private static let lockerColor = parseHexColor("#35493f")
    /// Four banks of lockers, all rusted, none the same colour — straight off the reference.
    private static let lockerColors = [
        parseHexColor("#6b4038"),
        parseHexColor("#4f5340"),
        parseHexColor("#2f4568"),
        parseHexColor("#5b6b40"),
    ]
    /// A chalkboard nobody has washed: dark green-black under a pale wooden frame.
    private static let boardColor = parseHexColor("#22282b")
    private static let boardFrameColor = parseHexColor("#8a7248")
    /// The orange-topped school desks in the same picture. The one warm thing in the building.
    private static let deskOrangeColor = parseHexColor("#a3672a")
    /// The toilet block: tile blue below, cracked white above.
    private static let tileColor = parseHexColor("#2c5566")
    private static let porcelainColor = parseHexColor("#9aa0a0")
    /// The glass in the front doors: filthy, but still glass.
    private static let glassColor = parseHexColor("#3c4f52")
    /// The street outside, seen through them. The brightest thing in the game, on purpose —
    /// it is what everybody in the building is walking towards.
    private static let outsideColor = parseHexColor("#6f7f9a")
    private static let whiteboardColor = parseHexColor("#8d9285")
    private static let screenColor = parseHexColor("#39c1a3")
    private static let shutterColor = parseHexColor("#6a7078")
    /// The school's own fire-door green, off the reference Joel sent.
    private static let doorColor = parseHexColor("#6f8b7c")
    private static let lightColor = parseHexColor("#ffe9a8")
    private static let frameColor = parseHexColor("#6e4630")

    /// Damp on the floor and up the walls. Dark, translucent and unlit, so it reads as a stain
    /// rather than as a hole.
    private static let stainColor = parseHexColor("#191b18")
    private static let rustColor = parseHexColor("#5d3a25")
    private static let debrisColor = parseHexColor("#4a4a47")
    /// Fallen ceiling tiles. The one pale thing left in the building, which is what makes the
    /// floor look like it has something on it.
    private static let ceilingTileColor = parseHexColor("#7c7f75")
    /// The exit signs, still running off whatever circuit has not failed yet. Unlit and green:
    /// in a dark corridor they are the only thing with a colour, and the eye goes straight to
    /// them, which is exactly where the children come from.
    private static let exitSignColor = parseHexColor("#3fa15c")

    // MARK: - The building

    /// Everything that never changes. Built once, handed back every frame.
    static var building: [ScenePrimitive] { cachedBuilding }

    private static let cachedBuilding: [ScenePrimitive] = buildBuilding()

    private static func buildBuilding() -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        buildOffice(&out)
        buildCorridor(.west, into: &out)
        buildMainEntrance(&out)
        buildClassroom(&out)
        buildToilets(&out)
        buildDiningHall(&out)
        buildPlayground(&out)
        buildAssemblyHall(&out)
        // The years nobody was here. Last, so the mess lies on top of everything else.
        for room in Room.allCases { decay(room, into: &out) }
        return out
    }

    // MARK: - The years nobody was here

    /// Damp, dust, fallen ceiling and broken chairs, scattered over one room.
    ///
    /// **Deterministic, and generated once.** The scatter is a seeded generator keyed off the
    /// room, so the same tile is on the same floor every night and in every session — a mess that
    /// rearranged itself between camera cuts would read as a rendering fault, and this way the
    /// whole thing still costs nothing at run time because `building` is built once.
    ///
    /// It is also the difference between "a school at night" and "a school nobody has been in for
    /// years", which is the whole of what Joel asked for. Four things do almost all of that work:
    /// water stains on the floor, ceiling tiles that have come down, rubble against the walls, and
    /// chairs that are no longer chairs.
    private static func decay(_ room: Room, into out: inout [ScenePrimitive]) {
        let p = plan(room)
        var random = DeterministicRandom(seed: 0xDECA1 &+ UInt64(room.rawValue) &* 7717)
        let halfW = p.width / 2 - 0.7
        let halfL = p.length / 2 - 0.7

        // Damp patches. Big, dark, translucent and flat on the floor.
        for _ in 0..<(room == .office ? 2 : 4) {
            let size = random.range(1.2, 3.4)
            out.append(patch(x: p.x + random.range(-halfW, halfW),
                             y: p.y + random.range(-halfL, halfL),
                             size: size, color: stainColor, opacity: 0.55, z: 0.01))
        }

        // Ceiling tiles that have come down, lying at whatever angle they landed at. Not in the
        // playground, which has no ceiling to lose.
        if !p.outdoor {
            for _ in 0..<(room == .office ? 1 : 3) {
                out.append(tiltedSlab(x: p.x + random.range(-halfW, halfW),
                                      y: p.y + random.range(-halfL, halfL),
                                      width: 0.6, length: 0.6,
                                      spin: random.range(0, .pi),
                                      color: ceilingTileColor, z: 0.03))
            }
        }

        // Rubble, pushed up against the walls the way it always ends up.
        for _ in 0..<5 {
            let againstWall = random.chance(0.6)
            let x = againstWall ? p.x + (random.chance(0.5) ? -halfW : halfW)
                                : p.x + random.range(-halfW, halfW)
            let y = againstWall ? p.y + random.range(-halfL, halfL)
                                : p.y + random.range(-halfL, halfL)
            let size = random.range(0.12, 0.34)
            out.append(box(x: x, y: y, z0: 0, sizeX: size, sizeY: size, height: size * 0.6,
                           color: debrisColor, castsShadow: false))
        }

        // Broken chairs: a seat on the floor and a bent leg beside it. Three thin boxes is not a
        // chair, but a flat plate at an angle with a stick across it is unmistakably the remains
        // of one from a camera three metres up.
        for _ in 0..<(room == .office || room == .westCorridor || room == .mainEntrance ? 1 : 2) {
            let x = p.x + random.range(-halfW, halfW)
            let y = p.y + random.range(-halfL, halfL)
            let spin = random.range(0, .pi)
            out.append(tiltedSlab(x: x, y: y, width: 0.42, length: 0.42, spin: spin,
                                  color: metalColor, z: 0.06))
            out.append(box(x: x + random.range(-0.4, 0.4), y: y + random.range(-0.4, 0.4),
                           z0: 0, sizeX: 0.5, sizeY: 0.05, height: 0.05,
                           color: rustColor, castsShadow: false))
        }
    }

    /// A flat, translucent patch on the floor — damp, or a stain, or the shadow of something that
    /// used to stand here.
    private static func patch(x: Double, y: Double, size: Double, color: SIMD3<Float>,
                              opacity: Float, z: Double) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(metres(size)), height: Float(metres(size))),
            transform: Float4x4.translation(SIMD3(Float(metres(x)), Float(-metres(y)),
                                                  Float(metres(z)))),
            color: color,
            opacity: opacity,
            unlit: true,
            castsShadow: false)
    }

    /// A flat slab lying at an angle on the floor — a fallen ceiling tile, or a chair seat that
    /// came off its frame.
    private static func tiltedSlab(x: Double, y: Double, width: Double, length: Double,
                                   spin: Double, color: SIMD3<Float>, z: Double) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(metres(width)), height: Float(metres(length))),
            transform: Float4x4.translation(SIMD3(Float(metres(x)), Float(-metres(y)),
                                                  Float(metres(z))))
                * Float4x4.rotationZ(Float(spin)),
            color: color,
            roughness: 0.95,
            castsShadow: false)
    }

    /// A running-man sign over a doorway. Nothing else in the building has a colour.
    private static func exitSign(x: Double, y: Double) -> [ScenePrimitive] {
        [box(x: x, y: y, z0: 2.25, sizeX: 0.5, sizeY: 0.08, height: 0.22,
             color: exitSignColor, unlit: true, castsShadow: false)]
    }

    // MARK: The office

    private static func buildOffice(_ out: inout [ScenePrimitive]) {
        let p = plan(.office)
        let halfW = p.width / 2, halfL = p.length / 2

        out.append(floor(x: p.x, y: p.y, width: p.width, length: p.length, color: officeFloorColor))

        // Far wall, and the two side walls with a doorway-sized hole in each.
        out.append(wallAlongX(fromX: -halfW, toX: halfW, y: -halfL, height: 2.4))
        for side in [Side.west, Side.east] {
            let x = side.sign * halfW
            out.append(wallAlongY(x: x, fromY: -halfL, toY: -0.9, height: 2.4))
            out.append(wallAlongY(x: x, fromY: 0.9, toY: halfL, height: 2.4))
            // The lintel over the doorway, which is what makes the gap read as a door rather than
            // as a missing piece of wall.
            out.append(box(x: x, y: 0, z0: 2.05, sizeX: 0.25, sizeY: 1.8, height: 0.35,
                           color: wallColor))
            // A running-man sign over the east doorway, pointing the way everybody is trying to
            // go. Green is the only colour in the building, so this is where the eye goes.
            if side == .east { out.append(contentsOf: exitSign(x: x + 0.4, y: 0)) }
        }
        // The near side is a rail, so the camera can see over it into the room.
        out.append(box(x: 0, y: halfL, z0: 0, sizeX: p.width, sizeY: 0.25, height: 0.4,
                       color: railColor))

        // The desk you sit behind, with the monitor bank on it.
        out.append(box(x: 0, y: 1.7, z0: 0, sizeX: 3.2, sizeY: 0.8, height: 0.72, color: woodColor))
        out.append(box(x: 0, y: 1.7, z0: 0.72, sizeX: 3.2, sizeY: 0.8, height: 0.06,
                       color: deskTopColor))
        for offsetX in [-0.85, 0.0, 0.85] {
            out.append(box(x: offsetX, y: 1.45, z0: 0.78, sizeX: 0.7, sizeY: 0.1, height: 0.46,
                           color: metalColor))
            // The screen itself is unlit, so it glows the same green from every angle instead of
            // going grey whenever the camera is not square to it. Same trick as the tennis lines.
            out.append(box(x: offsetX, y: 1.38, z0: 0.84, sizeX: 0.6, sizeY: 0.04, height: 0.36,
                           color: screenColor, unlit: true, castsShadow: false))
        }
        // A chair, a mug and the office fan — the three things every FNAF office has.
        out.append(box(x: 0, y: 2.5, z0: 0, sizeX: 0.55, sizeY: 0.55, height: 0.45,
                       color: metalColor))
        out.append(cylinder(x: 1.3, y: 2.0, z0: 0.78, radius: 0.05, height: 0.12,
                            color: whiteboardColor))
        out.append(cylinder(x: -1.55, y: 1.9, z0: 0.78, radius: 0.06, height: 0.5,
                            color: metalColor))
        out.append(box(x: -1.55, y: 1.9, z0: 1.28, sizeX: 0.5, sizeY: 0.1, height: 0.5,
                       color: metalColor))
    }

    // MARK: The corridors

    private static func buildCorridor(_ side: Side, into out: inout [ScenePrimitive]) {
        let room: Room = side == .west ? .westCorridor : .mainEntrance
        let p = plan(room)
        let halfL = p.length / 2

        out.append(floor(x: p.x, y: p.y, width: p.width, length: p.length,
                         color: corridorFloorColor))
        out.append(wallAlongX(fromX: p.x - p.width / 2, toX: p.x + p.width / 2,
                              y: -halfL, height: 2.4))
        out.append(box(x: p.x, y: halfL, z0: 0, sizeX: p.width, sizeY: 0.25, height: 0.4,
                       color: railColor))

        // A row of lockers down the far wall. Six of one size rather than one long box, because
        // the gaps between them are what say "lockers" from above — and **each bank a different
        // faded colour**, off the reference Joel sent: a corridor of six identical green boxes
        // reads as storage, and six rusted-out ones in four colours reads as a school somebody
        // walked out of.
        for index in 0..<6 {
            let x = p.x - p.width / 2 + 1.4 + Double(index) * 1.6
            out.append(box(x: x, y: -1.15, z0: 0, sizeX: 1.0, sizeY: 0.45, height: 1.9,
                           color: lockerColors[(index + (side == .west ? 0 : 2)) % lockerColors.count]))
            // Every third one hangs open: the door swung out into the corridor, and the dark
            // hole where it should be.
            guard index % 3 == 1 else { continue }
            out.append(box(x: x - 0.5, y: -0.7, z0: 0, sizeX: 0.08, sizeY: 0.9, height: 1.9,
                           color: rustColor))
            out.append(box(x: x, y: -1.15, z0: 0.1, sizeX: 0.86, sizeY: 0.1, height: 1.7,
                           color: stainColor))
        }
        // And a bin at the far end, so the eye has something to catch on.
        out.append(cylinder(x: p.x + side.sign * 4.2, y: 1.0, z0: 0, radius: 0.3, height: 0.9,
                            color: metalColor))
    }

    /// **The main entrance, and the only door in the school that matters.**
    ///
    /// This is CAM 7 and the whole game points at it: every child's route ends here, and there
    /// are the front doors out onto the street.
    ///
    /// **They are in the far wall, not the end wall**, and that is not a decorative choice. Every
    /// camera in this game looks down −Y from above, so anything standing in a wall that runs
    /// north-south is seen edge-on — the first version put these doors in the end wall and they
    /// came out as a two-pixel sliver with a child hidden behind them. In the far wall they face
    /// the camera square on, which is the whole job of CAM 7.
    private static func buildMainEntrance(_ out: inout [ScenePrimitive]) {
        let p = plan(.mainEntrance)
        let halfW = p.width / 2, halfL = p.length / 2
        let doorX = p.x + 3.0
        let wallY = p.y - halfL

        out.append(floor(x: p.x, y: p.y, width: p.width, length: p.length,
                         color: corridorFloorColor))
        out.append(wallAlongY(x: p.x + halfW, fromY: p.y - halfL, toY: p.y + halfL, height: 2.6))
        out.append(box(x: p.x, y: p.y + halfL, z0: 0, sizeX: p.width, sizeY: 0.25, height: 0.4,
                       color: railColor))

        // The far wall, with the doorway cut out of it.
        out.append(wallAlongX(fromX: p.x - halfW, toX: doorX - 1.5, y: wallY, height: 2.6))
        out.append(wallAlongX(fromX: doorX + 1.5, toX: p.x + halfW, y: wallY, height: 2.6))
        out.append(box(x: doorX, y: wallY, z0: 2.2, sizeX: 3.0, sizeY: 0.3, height: 0.4,
                       color: wallColor))

        // The night outside, first, so everything else stands in front of it. It is the one
        // bright thing in the building and the reason the room reads as a way out.
        out.append(patch(x: doorX, y: wallY - 1.4, size: 3.0, color: outsideColor,
                         opacity: 0.55, z: 0.02))

        // The doors themselves: two leaves of dirty glass in a frame, with a push bar across
        // each. They never move — a child who reaches them walks straight through unless the
        // shutter is down.
        for leaf in [-0.72, 0.72] {
            out.append(box(x: doorX + leaf, y: wallY, z0: 0.05, sizeX: 1.34, sizeY: 0.12,
                           height: 2.1, color: glassColor, castsShadow: false))
            out.append(box(x: doorX + leaf, y: wallY + 0.12, z0: 1.0, sizeX: 1.1, sizeY: 0.1,
                           height: 0.08, color: metalColor, castsShadow: false))
        }
        out.append(contentsOf: exitSign(x: doorX, y: wallY + 0.4))

        // Reception: a desk to one side, a noticeboard, and a bin knocked over.
        out.append(box(x: p.x - 3.4, y: p.y + 1.2, z0: 0, sizeX: 2.6, sizeY: 0.8, height: 0.95,
                       color: woodColor))
        out.append(box(x: p.x - 1.0, y: wallY + 0.2, z0: 1.0, sizeX: 2.4, sizeY: 0.1,
                       height: 1.1, color: boardFrameColor))
        out.append(cylinder(x: doorX + 2.4, y: p.y + 1.2, z0: 0.15, radius: 0.3, height: 0.9,
                            color: rustColor))
        // And the lockers, along the near half of the far wall.
        for index in 0..<3 {
            let x = p.x - halfW + 1.2 + Double(index) * 1.6
            out.append(box(x: x, y: wallY + 0.55, z0: 0, sizeX: 1.0, sizeY: 0.45,
                           height: 1.9, color: lockerColors[(index + 2) % lockerColors.count]))
        }
    }

    // MARK: The rooms off them

    private static func buildClassroom(_ out: inout [ScenePrimitive]) {
        let p = plan(.classroom)
        shell(p, into: &out, floorColor: floorColor)

        // The chalkboard, flat against the far wall: a pale wooden frame round a board so
        // stained it is nearly black. The frame is the whole trick — the board on its own
        // disappears into the wall behind it.
        let boardY = p.y - p.length / 2 + 0.2
        out.append(box(x: p.x, y: boardY, z0: 0.85, sizeX: 5.2, sizeY: 0.12, height: 1.3,
                       color: boardFrameColor))
        out.append(box(x: p.x, y: boardY - 0.04, z0: 0.95, sizeX: 4.8, sizeY: 0.1, height: 1.1,
                       color: boardColor))
        // The teacher's desk, then six pupil desks in two rows of three — one of them shoved out
        // of line and one on its side, because nobody tidied up.
        out.append(box(x: p.x, y: p.y - 2.6, z0: 0, sizeX: 1.8, sizeY: 0.8, height: 0.75,
                       color: woodColor))
        for row in 0..<2 {
            for column in 0..<3 {
                let askew = (row == 0 && column == 2) ? 0.45 : 0.0
                if row == 1 && column == 0 {
                    // On its side: a desk top standing on edge, with its legs in the air.
                    out.append(box(x: p.x - 2.6, y: p.y + 2.2, z0: 0, sizeX: 1.2, sizeY: 0.1,
                                   height: 0.62, color: deskOrangeColor))
                    out.append(box(x: p.x - 2.2, y: p.y + 2.2, z0: 0.05, sizeX: 0.05, sizeY: 0.6,
                                   height: 0.05, color: metalColor))
                    continue
                }
                out.append(desk(x: p.x - 2.6 + Double(column) * 2.6 + askew,
                                y: p.y + 0.2 + Double(row) * 2.0))
            }
        }
    }

    /// The toilet block, off the picture Joel sent: tiled to waist height, a run of sinks under a
    /// long mirror on one wall, and three cubicle partitions sticking out of the other.
    ///
    /// It replaced the library on **CAM 3**, which keeps the count at the seven he asked for. A
    /// row of cubicles is also a much better camera than a row of bookshelves: every one of them
    /// is somewhere a child could be standing that you cannot quite see.
    private static func buildToilets(_ out: inout [ScenePrimitive]) {
        let p = plan(.toilets)
        shell(p, into: &out, floorColor: floorColor)
        let halfW = p.width / 2, halfL = p.length / 2

        // Tiling: a band of blue up the two long walls, over the plaster.
        out.append(box(x: p.x, y: p.y - halfL + 0.2, z0: 0, sizeX: p.width, sizeY: 0.1,
                       height: 1.2, color: tileColor))
        out.append(box(x: p.x - halfW + 0.2, y: p.y, z0: 0, sizeX: 0.1, sizeY: p.length,
                       height: 1.2, color: tileColor))

        // Four sinks along the far wall, under one long mirror.
        out.append(box(x: p.x, y: p.y - halfL + 0.3, z0: 1.25, sizeX: 5.6, sizeY: 0.06,
                       height: 0.9, color: porcelainColor))
        for index in 0..<4 {
            let x = p.x - 2.4 + Double(index) * 1.6
            out.append(box(x: x, y: p.y - halfL + 0.55, z0: 0.72, sizeX: 0.7, sizeY: 0.45,
                           height: 0.22, color: porcelainColor))
            out.append(box(x: x, y: p.y - halfL + 0.4, z0: 0.94, sizeX: 0.06, sizeY: 0.06,
                           height: 0.22, color: metalColor))
        }

        // Three cubicles: a back wall, two partitions apiece, and a door hanging off the last one.
        for index in 0..<3 {
            let x = p.x - 2.2 + Double(index) * 2.2
            out.append(box(x: x, y: p.y + 2.4, z0: 0.12, sizeX: 0.08, sizeY: 1.9, height: 1.9,
                           color: porcelainColor))
            out.append(box(x: x + 1.1, y: p.y + 2.4, z0: 0.12, sizeX: 0.08, sizeY: 1.9,
                           height: 1.9, color: porcelainColor))
            out.append(box(x: x + 0.55, y: p.y + 1.5, z0: 0, sizeX: 0.5, sizeY: 0.4, height: 0.6,
                           color: porcelainColor))
        }
        // The one door still on its hinges, swung out into the room.
        out.append(box(x: p.x + 1.5, y: p.y + 1.5, z0: 0.12, sizeX: 0.9, sizeY: 0.07,
                       height: 1.9, color: doorColor))
    }

    /// The dining hall — and **the bus that came through the wall of it**, which is the first
    /// thing anybody looks at on CAM 5.
    ///
    /// `shell` is not used here, because the far wall of this room is not a wall any more: it is
    /// two stubs with a bus-shaped hole between them. The bus itself is an authored model
    /// (`crashedBus`) rather than boxes — `school_bus.glb` is already in the repo, already
    /// authored in metres, and already used by School Rush, so it drops straight in at
    /// `unitsPerMetre` and comes with its own rust.
    private static func buildDiningHall(_ out: inout [ScenePrimitive]) {
        let p = plan(.diningHall)
        let halfW = p.width / 2, halfL = p.length / 2

        out.append(floor(x: p.x, y: p.y, width: p.width, length: p.length, color: floorColor))
        out.append(wallAlongY(x: p.x - halfW, fromY: p.y - halfL, toY: p.y + halfL, height: 2.4))
        out.append(wallAlongY(x: p.x + halfW, fromY: p.y - halfL, toY: p.y + halfL, height: 2.4))
        out.append(box(x: p.x, y: p.y + halfL, z0: 0, sizeX: p.width, sizeY: 0.25, height: 0.4,
                       color: railColor))

        // The far wall, in two pieces either side of the hole. The stubs are shorter than the
        // wall they came from and their inner ends are ragged — a clean rectangular gap reads as
        // a doorway, and a doorway is not what happened here.
        let holeHalf = 1.9
        out.append(wallAlongX(fromX: p.x - halfW, toX: p.x - holeHalf, y: p.y - halfL,
                              height: 2.4))
        out.append(wallAlongX(fromX: p.x + holeHalf, toX: p.x + halfW, y: p.y - halfL,
                              height: 2.4))
        for edge in [-1.0, 1.0] {
            out.append(box(x: p.x + edge * holeHalf, y: p.y - halfL, z0: 0,
                           sizeX: 0.5, sizeY: 0.4, height: 1.4, color: wallColor))
            out.append(box(x: p.x + edge * (holeHalf + 0.35), y: p.y - halfL, z0: 1.4,
                           sizeX: 0.6, sizeY: 0.3, height: 0.7, color: wallColor))
        }
        // Brick and plaster thrown across the floor in front of the hole, thinning out with
        // distance — which is what makes it read as something that burst *in*.
        var rubble = DeterministicRandom(seed: 0xB05_C7A5)
        for _ in 0..<14 {
            let spread = rubble.range(0.3, 4.5)
            let size = rubble.range(0.14, 0.42) * (1.4 - spread / 6)
            out.append(box(x: p.x + rubble.range(-3.2, 3.2),
                           y: p.y - halfL + spread,
                           z0: 0, sizeX: size, sizeY: size, height: size * 0.7,
                           color: rubble.chance(0.4) ? wallColor : debrisColor,
                           castsShadow: false))
        }
        // Glass from the windscreen: pale, flat, unlit, in a fan in front of the nose.
        for _ in 0..<8 {
            out.append(patch(x: p.x + rubble.range(-2.4, 2.4),
                             y: p.y - halfL + rubble.range(0.5, 3.5),
                             size: rubble.range(0.2, 0.5),
                             color: porcelainColor, opacity: 0.5, z: 0.02))
        }

        // The serving counter, shoved out of line by whatever went through here.
        out.append(box(x: p.x + 2.6, y: p.y - p.length / 2 + 1.2, z0: 0, sizeX: 4.4, sizeY: 0.9,
                       height: 1.0, color: metalColor))
        // Three long tables with a bench either side of each.
        for index in 0..<3 {
            let y = p.y - 1.6 + Double(index) * 2.2
            out.append(box(x: p.x, y: y, z0: 0, sizeX: 7.5, sizeY: 0.9, height: 0.74,
                           color: deskTopColor))
            for offset in [-0.85, 0.85] {
                out.append(box(x: p.x, y: y + offset, z0: 0, sizeX: 7.5, sizeY: 0.3, height: 0.44,
                               color: woodColor))
            }
        }
    }

    private static func buildPlayground(_ out: inout [ScenePrimitive]) {
        let p = plan(.playground)
        let halfW = p.width / 2, halfL = p.length / 2

        out.append(floor(x: p.x, y: p.y, width: p.width, length: p.length, color: grassColor))
        // Outdoors, so a low wall the whole way round rather than a room's three walls: there is
        // nothing above it to hide anything.
        out.append(box(x: p.x, y: p.y - halfL, z0: 0, sizeX: p.width, sizeY: 0.3, height: 0.9,
                       color: railColor))
        out.append(box(x: p.x, y: p.y + halfL, z0: 0, sizeX: p.width, sizeY: 0.3, height: 0.4,
                       color: railColor))
        for sideX in [-1.0, 1.0] {
            out.append(box(x: p.x + sideX * halfW, y: p.y, z0: 0, sizeX: 0.3, sizeY: p.length,
                           height: 0.9, color: railColor))
        }

        // The climbing frame, the swings and the slide are `low_poly_kids_playground.glb` —
        // see `playgroundModel`. What is left here is the furniture round the edge of it: a
        // bench, a bin, and the goalposts painted on the end wall.
        out.append(box(x: p.x - 3.9, y: p.y + 2.8, z0: 0, sizeX: 1.6, sizeY: 0.5, height: 0.45,
                       color: woodColor))
        out.append(cylinder(x: p.x - 4.6, y: p.y - 2.2, z0: 0, radius: 0.3, height: 0.9,
                            color: rustColor))
        for postX in [-1.4, 1.4] {
            out.append(box(x: p.x + postX, y: p.y - halfL + 0.4, z0: 0, sizeX: 0.12, sizeY: 0.12,
                           height: 1.6, color: frameColor))
        }
        out.append(box(x: p.x, y: p.y - halfL + 0.4, z0: 1.6, sizeX: 2.9, sizeY: 0.12,
                       height: 0.12, color: frameColor))
    }

    private static func buildAssemblyHall(_ out: inout [ScenePrimitive]) {
        let p = plan(.assemblyHall)
        shell(p, into: &out, floorColor: floorColor)

        // The stage at the far end.
        out.append(box(x: p.x, y: p.y - p.length / 2 + 1.4, z0: 0, sizeX: 11.0, sizeY: 2.6,
                       height: 0.5, color: woodColor))
        // Five rows of benches facing it. This is where every child starts the night.
        for row in 0..<5 {
            out.append(box(x: p.x, y: p.y - 1.6 + Double(row) * 1.5, z0: 0,
                           sizeX: 10.0, sizeY: 0.4, height: 0.45, color: woodColor))
        }
    }

    // MARK: - Building blocks

    /// Floor, three walls and a near rail — the shape every ordinary room shares.
    private static func shell(_ p: Plan, into out: inout [ScenePrimitive],
                              floorColor: SIMD3<Float>) {
        let halfW = p.width / 2, halfL = p.length / 2
        out.append(floor(x: p.x, y: p.y, width: p.width, length: p.length, color: floorColor))
        out.append(wallAlongX(fromX: p.x - halfW, toX: p.x + halfW, y: p.y - halfL, height: 2.4))
        out.append(wallAlongY(x: p.x - halfW, fromY: p.y - halfL, toY: p.y + halfL, height: 2.4))
        out.append(wallAlongY(x: p.x + halfW, fromY: p.y - halfL, toY: p.y + halfL, height: 2.4))
        out.append(box(x: p.x, y: p.y + halfL, z0: 0, sizeX: p.width, sizeY: 0.25, height: 0.4,
                       color: railColor))
    }

    private static func floor(x: Double, y: Double, width: Double, length: Double,
                              color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(metres(width)), height: Float(metres(length))),
            transform: Float4x4.translation(SIMD3(Float(metres(x)), Float(-metres(y)), 0)),
            color: color,
            roughness: 0.95,
            castsShadow: false)
    }

    private static func wallAlongX(fromX: Double, toX: Double, y: Double,
                                   height: Double) -> ScenePrimitive {
        box(x: (fromX + toX) / 2, y: y, z0: 0,
            sizeX: abs(toX - fromX), sizeY: 0.25, height: height, color: wallColor)
    }

    private static func wallAlongY(x: Double, fromY: Double, toY: Double,
                                   height: Double) -> ScenePrimitive {
        box(x: x, y: (fromY + toY) / 2, z0: 0,
            sizeX: 0.25, sizeY: abs(toY - fromY), height: height, color: wallColor)
    }

    private static func desk(x: Double, y: Double) -> ScenePrimitive {
        box(x: x, y: y, z0: 0, sizeX: 1.2, sizeY: 0.6, height: 0.7, color: deskOrangeColor)
    }

    /// A box standing on the floor, given in metres and placed in **render space** — which negates
    /// Y and measures Z up from the floor. `sizeX` runs across the plan, `sizeY` down it.
    static func box(x: Double, y: Double, z0: Double,
                    sizeX: Double, sizeY: Double, height: Double,
                    color: SIMD3<Float>,
                    unlit: Bool = false,
                    castsShadow: Bool = true) -> ScenePrimitive {
        ScenePrimitive(
            shape: .box(width: Float(metres(sizeX)),
                        height: Float(metres(sizeY)),
                        depth: Float(metres(height))),
            transform: Float4x4.translation(SIMD3(Float(metres(x)),
                                                  Float(-metres(y)),
                                                  Float(metres(z0 + height / 2)))),
            color: color,
            roughness: 0.9,
            unlit: unlit,
            castsShadow: castsShadow)
    }

    private static func cylinder(x: Double, y: Double, z0: Double,
                                 radius: Double, height: Double,
                                 color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .cylinder(radius: Float(metres(radius)), height: Float(metres(height))),
            transform: Float4x4.translation(SIMD3(Float(metres(x)),
                                                  Float(-metres(y)),
                                                  Float(metres(z0 + height / 2))))
                * Float4x4.rotationX(.pi / 2),
            color: color,
            roughness: 0.9)
    }

    // MARK: - The bus

    /// **The school bus that came through the dining hall wall.** Its nose and front doors are
    /// inside the room and the rest of it is still out in the car park, which is exactly the shot
    /// CAM 5 gives you.
    ///
    /// `school_bus.glb` is authored in metres — School Rush parks it beside the track the same
    /// way — so the scale here is simply `unitsPerMetre`. Two details do all the work:
    ///
    /// - **It is not square to the hole.** A few degrees off the wall's normal is the difference
    ///   between a bus that crashed and a bus that was parked indoors.
    /// - **It is nose-down and rolled slightly**, because the front axle is sitting on the rubble
    ///   of the wall it went through rather than on the floor.
    static let crashedBus = SceneModel(
        path: "models/school_bus.glb",
        transform: Float4x4.translation(SIMD3(Float(metres(21.4)),
                                              Float(-metres(-15.5)),
                                              Float(metres(0.35))))
            * Float4x4.rotationZ(.pi / 2 + 0.16)
            * Float4x4.rotationY(-0.06)
            * Float4x4.scale(SIMD3(repeating: Float(unitsPerMetre)))
            * Float4x4.rotationX(.pi / 2),
        // It is the biggest thing in the building and half of it is in a room you look at, so
        // this is the one prop worth the second shadow pass.
        castsShadow: true)

    /// **The rusted-out playground on CAM 6.** `low_poly_kids_playground.glb`, the same model and
    /// the same scale the junior campus places it at (`objects.json` id 67, scale 25) — which is
    /// the only reliable way to size one of these: copy a placement that already looks right.
    ///
    /// It stands where four box posts used to. A climbing frame made of boxes reads as scaffolding;
    /// this one has a slide and swings, and the shapes are what make a dark yard read as a
    /// playground rather than as a car park.
    static let playgroundModel = SceneModel(
        path: "models/low_poly_kids_playground.glb",
        transform: Float4x4.translation(SIMD3(Float(metres(22.2)), Float(-metres(8.4)), 0))
            * Float4x4.rotationZ(0.4)
            // 20 rather than the campus's 25: at 25 the frame is ten metres across and hangs
            // over the yard wall, and this yard is eleven metres wide with a bench in it.
            * Float4x4.scale(SIMD3(repeating: 20))
            * Float4x4.rotationX(.pi / 2))

    // MARK: - The parts that move

    /// The roller shutter in one of the office doorways. `closed` is 0 when it is fully up and 1
    /// when it is fully down, so the door can be caught halfway.
    ///
    /// It is drawn at every position rather than only when shut: a shutter hanging above the
    /// doorway is what tells you the door is open and could be closed, and watching it come down
    /// is most of the satisfaction of pressing the button.
    /// **The security shutter over the front doors.** `closed` is 0 fully up and 1 fully down,
    /// so it can be caught halfway — and halfway is not shut, which is the point of the seven
    /// seconds you get.
    ///
    /// A school really does have one of these over its main entrance, which is why this is the
    /// door the whole game is about: there is no second way out, and no lights to check, because
    /// everything you need to know is on CAM 7 if you look at it.
    static func mainDoor(closed: Double) -> [ScenePrimitive] {
        let p = plan(.mainEntrance)
        let doorX = p.x + 3.0
        // **On the inside face of the wall, not the outside.** Every camera looks at this room
        // from the south, so a shutter hung on the street side sits behind 2.6 m of wall and is
        // invisible from the only angle anybody ever sees it — which is exactly how the first
        // version of this looked: the button said DOOR SHUT and the picture said nothing.
        let y = p.y - p.length / 2 + 0.26
        let travel = 2.3
        let z0 = travel - closed * travel
        return [
            box(x: doorX, y: y, z0: z0, sizeX: 3.0, sizeY: 0.22, height: 2.25,
                color: shutterColor, castsShadow: true),
            // The corrugations, three ribs across it, so it reads as a roller shutter rather
            // than as a slab dropped in a doorway.
            box(x: doorX, y: y + 0.13, z0: z0 + 0.5, sizeX: 3.0, sizeY: 0.06, height: 0.1,
                color: metalColor, castsShadow: false),
            box(x: doorX, y: y + 0.13, z0: z0 + 1.1, sizeX: 3.0, sizeY: 0.06, height: 0.1,
                color: metalColor, castsShadow: false),
            box(x: doorX, y: y + 0.13, z0: z0 + 1.7, sizeX: 3.0, sizeY: 0.06, height: 0.1,
                color: metalColor, castsShadow: false),
            // A yellow stripe along the bottom edge, so a shutter on its way down is obvious in
            // a dark room and on a green camera.
            box(x: doorX, y: y, z0: z0, sizeX: 3.0, sizeY: 0.26, height: 0.14,
                color: lightColor, unlit: true, castsShadow: false),
        ]
    }

    /// Just inside the front doors: where a child stands during their seven seconds.
    static let exitSpot = (x: metres(14.0), y: metres(-1.2))
}
