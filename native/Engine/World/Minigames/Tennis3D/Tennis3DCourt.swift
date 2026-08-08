import Foundation
import simd

/// The court: its dimensions, and the geometry that draws it.
///
/// Everything here is a **real tennis court in real units**, which is the biggest single change
/// from the 2D game. That one had a 120-unit court and a `gameScale` constant dividing every
/// velocity and gravity by 255 to keep the ball behaving after it was shrunk. Once the court is
/// the size a court actually is, gravity is 9.81 m/s², a serve is 40 m/s because that is what a
/// serve is, and there is nothing left to normalise.
///
/// The conversion is pinned to the **character rig**, not to the art: a rig stands about 50
/// units tall from the floor to the crown of the head, and a tennis player is about 1.85 m, so
/// one metre is 27 units. Get that wrong and the players are ants on an aircraft carrier.
///
/// Layout, in world space (Y-down, as the whole engine is):
///
/// ```
///          x = −halfDoubles ......... 0 ......... +halfDoubles
///   y = −halfLength   ┌───────────────────────────────┐   NPC baseline
///                     │        (far service boxes)     │
///   y = −serviceLine  ├───────────────────────────────┤
///   y = 0             ╞══════════ N E T ══════════════╡
///   y = +serviceLine  ├───────────────────────────────┤
///                     │       (near service boxes)     │
///   y = +halfLength   └───────────────────────────────┘   player baseline
/// ```
///
/// The player is always at the **+Y** end, which puts them at the bottom of the screen with the
/// camera behind them — the same framing the 2D game had, just tipped into three dimensions.
enum Tennis3DCourt {

    // MARK: - Scale

    /// World units per metre, pinned to the rig's own height. See the note above.
    static let unitsPerMetre: Double = 27

    static func metres(_ value: Double) -> Double { value * unitsPerMetre }

    // MARK: - Dimensions (ITF, in metres, converted)

    /// 23.77 m baseline to baseline.
    static let length = metres(23.77)
    static let halfLength = length / 2

    /// 8.23 m between the singles sidelines.
    static let singlesWidth = metres(8.23)
    static let halfSingles = singlesWidth / 2

    /// 10.97 m across the doubles court. Kept because the tramlines are half the look of a
    /// tennis court even in a singles match.
    static let doublesWidth = metres(10.97)
    static let halfDoubles = doublesWidth / 2

    /// 6.40 m from the net to the service line.
    static let serviceLine = metres(6.40)

    /// The net: 0.914 m at the centre, 1.07 m at the posts, and the posts stand 0.914 m outside
    /// the doubles sideline.
    static let netCentreHeight = metres(0.914)
    static let netPostHeight = metres(1.07)
    static let netPostOffset = halfDoubles + metres(0.914)

    /// **How far out the net is actually drawn**, which is not where its posts would be.
    ///
    /// `netPostOffset` is the doubles post, and it stays that way because `netHeight(atX:)` is
    /// the sag curve the ball is tested against and moving it would move the physics. But this
    /// is a singles match, and the stadium's umpire chair stands at 6.2–7.8 m from the centre
    /// line — a doubles post at 6.4 m is planted inside it. Singles sticks go 0.914 m outside
    /// the *singles* sideline, which is 5.03 m, clear of the chair and correct for the match
    /// being played. Nothing legal ever crosses the net past 4.1 m anyway.
    static let netEdge = halfSingles + metres(0.914)

    /// Painted lines are 5 cm wide; the baseline is 10 cm.
    static let lineWidth = metres(0.05)
    static let baselineWidth = metres(0.10)

    /// **How far outside the lines anyone may go.** The run-back is what makes a deep ball
    /// retrievable; the side run is a stride past the tramlines for a wide one.
    ///
    /// It was 4.2 m and 2.2 m, and it was the reason the camera had to sit so far back: the
    /// playable rectangle was 32 m long against a 23.77 m court, so framing the court meant
    /// letting a player walk off the bottom of the screen. Trimmed to a stride and a half, the
    /// whole playable area fits the frame and the court can fill it.
    ///
    /// 2.8 m rather than the 2.2 m it was first trimmed to. At 2.2 m a measured match produced
    /// two misses and **both** were the player standing on the back fence at 14.0 m with the ball
    /// still climbing through 1.6 m over their head — a topspin reply that carries past the
    /// baseline needs a step and a half behind it before it drops to racket height, and pinning
    /// the player is not the same thing as beating them.
    static let runBack = metres(2.8)
    static let sideRun = metres(1.6)

    static let playableHalfWidth = halfDoubles + sideRun
    static let playableHalfLength = halfLength + runBack

    // MARK: - The stadium

    /// The model the court stands in, and where it stands.
    ///
    /// `tools/assets/build_stadium.js` builds it from the Fab export: the same stadium, with its
    /// own court and net taken out, because those are drawn here — in the place the ball physics
    /// believes in, at the size `unitsPerMetre` says. Two courts a centimetre apart is a z-fight,
    /// and the one that would win is the one the game does not know about.
    ///
    /// The model is authored in **metres, Y-up, court along Z**, and its arena floor sits 19 mm
    /// below its origin. So: tip it up (glTF Y-up → this world's Z-up, the same `rotationX`
    /// `PropRenderer` applies to every placed prop), scale by `unitsPerMetre`, then lift it by
    /// that 19 mm so the floor lands exactly on z = 0 — which is the plane the lawn used to
    /// occupy, and is two units below the apron, the separation the apron and the painted lines
    /// have always used.
    ///
    /// The court's long axis comes out along world Y and its centre on the origin without any
    /// further help, because `rotationX(π/2)` takes glTF +Z to render −Y, and the model's court
    /// is centred on its own origin to the millimetre.
    static let stadiumModel = SceneModel(
        path: "models/tennis_stadium.glb",
        transform: Float4x4.translation(SIMD3(0, 0, Float(metres(0.019))))
            * Float4x4.scale(SIMD3(repeating: Float(unitsPerMetre)))
            * Float4x4.rotationX(.pi / 2))

    /// **The drawn apron is deliberately far bigger than the playable one**, so that its edge is
    /// never in shot where it would be read as the edge of the world.
    ///
    /// These used to be the same rectangle, which meant the hard court visibly stopped a metre
    /// or two outside the tramlines with flat empty grass beyond it — a hard line drawn across
    /// the top and bottom of the screen. A court is a court because it goes on past the frame.
    ///
    /// It is **not symmetric**, because the camera is not. `apronCentreY` pushes it towards the
    /// near baseline: the bottom of the frame is a stride and a half behind the player and has to
    /// be hard court, while the top of the frame is a long way up the other end.
    ///
    /// How far up the other end is decided by something that cannot be changed from here.
    /// `Camera.far` is 2000 units and the camera orbits at 1631, so the ground simply **stops**
    /// about 18 m past the far baseline, whatever is drawn there — that pale green band across
    /// the top of the frame was never the lawn, it was the clear colour showing through the far
    /// clip plane. Making the apron bigger did nothing at all. So the apron stops a few metres
    /// short of the clip instead and the lawn fills the gap, and the clear colour is a sky rather
    /// than a green — see `skyHex`.
    static let surfaceHalfWidth = halfDoubles + metres(6)
    static let surfaceHalfLength = halfLength + metres(4.5)
    static let apronCentreY = metres(1.5)

    /// The ball. A real one is 33 mm across, which at this scale is under a unit and invisible
    /// from a camera 25 m up — so it is drawn at three times life size, the same lie every
    /// televised tennis graphic tells. The **physics** radius stays honest, because it is what
    /// decides whether a ball caught the line.
    static let ballRadius = metres(0.033)
    static let ballDrawRadius = metres(0.10)

    // MARK: - Colours

    /// **Grass, now that the court stands in a grass-court stadium.** The 2D game's palette was
    /// a blue-grey hard court (`#3c4a52` apron, `#2f6f8f` inside the lines) and it was right for
    /// a court on its own in a field; a blue court in the middle of Centre Court is not. The two
    /// greens are sampled off the model's own lawn texture — the light mown stripe and the dark
    /// one — so the game's court and the stadium floor it sits on read as the same grass.
    ///
    /// Reverting is those two hex strings and nothing else.
    static let surfaceColor = parseHexColor("#4a7a34")
    static let insideColor = parseHexColor("#6b9a44")
    static let grassColor = parseHexColor("#7bed9f")
    static let lineColor = parseHexColor("#f5f7fa")
    static let netColor = parseHexColor("#1b2430")
    static let netTapeColor = parseHexColor("#f5f7fa")
    static let postColor = parseHexColor("#22303c")
    static let ballColor = parseHexColor("#d7f205")

    /// What is left when the ground runs out — which, from a camera tipped over behind the
    /// baseline, is the top eighth of the frame.
    ///
    /// It used to be the grass colour, on the assumption that nothing would ever show through.
    /// Something does: `Camera.far` is 2000 units against an orbit of 1631, so the ground stops
    /// dead about 18 m past the far baseline and the clear colour shows above it. No amount of
    /// extra apron reaches past a clip plane, and matching the clear colour to the grass does not
    /// work either — the clear colour is written straight to a linear target and the same hex
    /// comes back a good deal paler than the shaded plane next to it.
    ///
    /// So it is a **sky**. A hard straight line between pale blue and a green field is a horizon,
    /// which is the one thing that line is allowed to be.
    static let skyHex = "#a9d9ef"

    // MARK: - Bounds tests

    /// Did a bounce land in, for a ball hit into the given half? `half` is the sign of the Y a
    /// legal bounce has to be on: −1 for the NPC's end, +1 for the player's.
    static func isInCourt(x: Double, y: Double, half: Double) -> Bool {
        guard abs(x) <= halfSingles + ballRadius else { return false }
        if half < 0 { return y <= 0 && y >= -halfLength - ballRadius }
        return y >= 0 && y <= halfLength + ballRadius
    }

    /// The service box a serve has to land in. `receiverHalf` is the sign of the receiver's end;
    /// `deuceCourt` is true for the box to the server's right.
    ///
    /// The server stands right of centre on a deuce point and serves diagonally, so the target
    /// box is on the receiver's right as the receiver looks at it — which is the far side of the
    /// court in world X from where the server is standing.
    static func serviceBox(receiverHalf: Double, deuceCourt: Bool) -> (minX: Double, maxX: Double,
                                                                      minY: Double, maxY: Double) {
        // Written out rather than folded together, because getting it backwards is the bug the
        // 2D game shipped with: every serve went down the line instead of across it.
        //
        // The camera sits behind the +Y baseline, so on screen +X is right and −Y is away. The
        // player faces away, which puts their right — and so their deuce court — at +X; the NPC
        // faces the camera, which puts its deuce court at −X. A serve always crosses, so the
        // target box is on the opposite side of the centre line from the server.
        let servingFromPlayerEnd = receiverHalf < 0
        let targetsPositiveX = servingFromPlayerEnd ? !deuceCourt : deuceCourt

        let minX = targetsPositiveX ? 0 : -halfSingles
        let maxX = targetsPositiveX ? halfSingles : 0

        if receiverHalf < 0 {
            return (minX: minX, maxX: maxX, minY: -serviceLine, maxY: 0)
        }
        return (minX: minX, maxX: maxX, minY: 0, maxY: serviceLine)
    }

    /// Where a server stands: on their own deuce side, a stride outside the centre mark.
    /// The mirror of `serviceBox`'s reasoning — the player's deuce court is +X, the NPC's is −X.
    static func serveStanceX(isPlayer: Bool, deuceCourt: Bool) -> Double {
        let onPositiveX = isPlayer ? deuceCourt : !deuceCourt
        let offset = metres(1.6)
        return onPositiveX ? offset : -offset
    }

    /// Net height at a given X, interpolated from the centre strap out to the posts the way a
    /// real net sags.
    static func netHeight(atX x: Double) -> Double {
        let t = min(1, abs(x) / netPostOffset)
        return netCentreHeight + (netPostHeight - netCentreHeight) * t * t
    }

    // MARK: - Geometry

    /// The static half of the scene: grass, court surface, painted lines, net and posts.
    ///
    /// Built once when the game starts rather than every frame — it is around eighty primitives
    /// and none of them ever move.
    static func staticPrimitives() -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []

        /// A flat slab lying on the ground at height `z`, centred on (x, y) in **world** space.
        func slab(x: Double, y: Double, width: Double, length: Double, z: Double,
                  color: SIMD3<Float>, unlit: Bool) {
            out.append(ScenePrimitive(
                shape: .plane(width: Float(width), height: Float(length)),
                // Render space negates Y. A plane faces +Z already, so no rotation is needed.
                transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z))),
                color: color,
                roughness: 0.95,
                unlit: unlit,
                castsShadow: false))
        }

        // The apron, then the lighter playing area inside the lines, then the paint.
        //
        // **There is no lawn slab any more.** There used to be one four times the apron's size at
        // z = 0, standing in for the world outside the court; the stadium's own arena floor is
        // that now, and it is at exactly z = 0 — see `stadiumModel`. Drawing both would be two
        // coplanar planes 40 m across, which is the one thing a depth buffer cannot arbitrate.
        //
        // The gaps between what is left used to be 0.4 units — a centimetre and a half — and the
        // grass was six times the size of the surface, which is nearly three hundred metres long.
        // A depth buffer asked to separate three planes a centimetre apart across three hundred
        // metres cannot, and the result was ragged slabs of the wrong colour appearing off the
        // corners of the court and vanishing again as the camera drifted. Two units of separation
        // is plenty of room; from this camera, seven centimetres of lift is invisible.
        slab(x: 0, y: apronCentreY, width: surfaceHalfWidth * 2, length: surfaceHalfLength * 2,
             z: 2, color: surfaceColor, unlit: false)
        slab(x: 0, y: 0, width: doublesWidth, length: length, z: 4,
             color: insideColor, unlit: false)

        // --- Painted lines ---
        let lineZ = 6.0

        func lineAlongX(y: Double, from x0: Double, to x1: Double, width: Double) {
            slab(x: (x0 + x1) / 2, y: y, width: abs(x1 - x0), length: width, z: lineZ,
                 color: lineColor, unlit: true)
        }
        func lineAlongY(x: Double, from y0: Double, to y1: Double, width: Double) {
            slab(x: x, y: (y0 + y1) / 2, width: width, length: abs(y1 - y0), z: lineZ,
                 color: lineColor, unlit: true)
        }

        // Baselines, then the doubles sidelines, then the singles sidelines.
        lineAlongX(y: -halfLength, from: -halfDoubles, to: halfDoubles, width: baselineWidth)
        lineAlongX(y: halfLength, from: -halfDoubles, to: halfDoubles, width: baselineWidth)
        lineAlongY(x: -halfDoubles, from: -halfLength, to: halfLength, width: lineWidth)
        lineAlongY(x: halfDoubles, from: -halfLength, to: halfLength, width: lineWidth)
        lineAlongY(x: -halfSingles, from: -halfLength, to: halfLength, width: lineWidth)
        lineAlongY(x: halfSingles, from: -halfLength, to: halfLength, width: lineWidth)

        // Service lines and the centre service line between them.
        lineAlongX(y: -serviceLine, from: -halfSingles, to: halfSingles, width: lineWidth)
        lineAlongX(y: serviceLine, from: -halfSingles, to: halfSingles, width: lineWidth)
        lineAlongY(x: 0, from: -serviceLine, to: serviceLine, width: lineWidth)

        // The little centre marks on each baseline.
        lineAlongY(x: 0, from: halfLength - metres(0.1), to: halfLength, width: lineWidth)
        lineAlongY(x: 0, from: -halfLength, to: -halfLength + metres(0.1), width: lineWidth)

        out.append(contentsOf: netPrimitives())
        return out
    }

    /// The net, built as real cord rather than a texture: verticals, horizontals, the white tape
    /// along the top and two posts. Around forty draws, which is nothing, and it reads properly
    /// from the low camera angle where a flat billboard would not.
    private static func netPrimitives() -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        let cord = Float(metres(0.012))
        let span = netEdge * 2

        // Posts.
        for side in [-1.0, 1.0] {
            out.append(ScenePrimitive(
                shape: .cylinder(radius: Float(metres(0.05)), height: Float(netHeight(atX: netEdge))),
                transform: Float4x4.translation(SIMD3(Float(side * netEdge), 0,
                                              Float(netHeight(atX: netEdge) / 2)))
                    // MeshFactory builds cylinders along +Y; stand it up along +Z.
                    * Float4x4.rotationX(.pi / 2),
                color: postColor,
                roughness: 0.6,
                metalness: 0.3))
        }

        // Verticals, one every 10 cm of real net, each cut to the sagging height at its X.
        let verticalCount = 46
        for index in 0...verticalCount {
            let t = Double(index) / Double(verticalCount)
            let x = -netEdge + t * span
            let height = netHeight(atX: x)
            out.append(ScenePrimitive(
                shape: .box(width: cord, height: Float(height), depth: cord),
                transform: Float4x4.translation(SIMD3(Float(x), 0, Float(height / 2)))
                    * Float4x4.rotationX(.pi / 2),
                color: netColor,
                roughness: 0.95,
                castsShadow: false))
        }

        // Horizontals. Each runs the full span at a constant fraction of the local height, so
        // they follow the sag rather than cutting straight across it — approximated by chopping
        // each into eight segments.
        let rows = 7
        let segments = 8
        for row in 1...rows {
            let fraction = Double(row) / Double(rows + 1)
            for segment in 0..<segments {
                let x0 = -netEdge + span * Double(segment) / Double(segments)
                let x1 = -netEdge + span * Double(segment + 1) / Double(segments)
                let midX = (x0 + x1) / 2
                let z = netHeight(atX: midX) * fraction
                out.append(ScenePrimitive(
                    shape: .box(width: Float(x1 - x0), height: cord, depth: cord),
                    transform: Float4x4.translation(SIMD3(Float(midX), 0, Float(z))),
                    color: netColor,
                    roughness: 0.95,
                    castsShadow: false))
            }
        }

        // The white tape along the top, and the centre strap holding the net down.
        let tape = Float(metres(0.06))
        for segment in 0..<segments {
            let x0 = -netEdge + span * Double(segment) / Double(segments)
            let x1 = -netEdge + span * Double(segment + 1) / Double(segments)
            let midX = (x0 + x1) / 2
            let z = netHeight(atX: midX)
            out.append(ScenePrimitive(
                shape: .box(width: Float(x1 - x0), height: tape, depth: tape),
                transform: Float4x4.translation(SIMD3(Float(midX), 0, Float(z))),
                color: netTapeColor,
                roughness: 0.8))
        }
        out.append(ScenePrimitive(
            shape: .box(width: tape, height: Float(netCentreHeight), depth: tape * 0.6),
            transform: Float4x4.translation(SIMD3(0, 0, Float(netCentreHeight / 2))) * Float4x4.rotationX(.pi / 2),
            color: netTapeColor,
            roughness: 0.8))

        return out
    }
}
