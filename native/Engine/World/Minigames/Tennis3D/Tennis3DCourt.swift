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

    /// Painted lines are 5 cm wide; the baseline is 10 cm.
    static let lineWidth = metres(0.05)
    static let baselineWidth = metres(0.10)

    /// The apron of hard court outside the lines, and the grass beyond that. The run-back is
    /// what makes a deep ball retrievable, so it cannot be trimmed much — but the apron is kept
    /// tight so the `#7bed9f` grass frames the court the way it did in the 2D game, rather than
    /// the whole screen going hard-court grey.
    static let runBack = metres(4.2)
    static let sideRun = metres(2.2)

    static let surfaceHalfWidth = halfDoubles + sideRun
    static let surfaceHalfLength = halfLength + runBack

    /// How far outside the surface a character may stray before being clamped. Slightly inside
    /// the apron edge, so nobody stands on the grass.
    static let playableHalfWidth = surfaceHalfWidth - metres(0.5)
    static let playableHalfLength = surfaceHalfLength - metres(0.5)

    /// The ball. A real one is 33 mm across, which at this scale is under a unit and invisible
    /// from a camera 25 m up — so it is drawn at three times life size, the same lie every
    /// televised tennis graphic tells. The **physics** radius stays honest, because it is what
    /// decides whether a ball caught the line.
    static let ballRadius = metres(0.033)
    static let ballDrawRadius = metres(0.10)

    // MARK: - Colours

    /// The 2D game's palette, kept: a blue-grey hard court, `#7bed9f` grass, white lines.
    static let surfaceColor = parseHexColor("#3c4a52")
    static let insideColor = parseHexColor("#2f6f8f")
    static let grassColor = parseHexColor("#7bed9f")
    static let lineColor = parseHexColor("#f5f7fa")
    static let netColor = parseHexColor("#1b2430")
    static let netTapeColor = parseHexColor("#f5f7fa")
    static let postColor = parseHexColor("#22303c")
    static let ballColor = parseHexColor("#d7f205")

    static let grassHex = "#7bed9f"

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

        // Grass, then the hard-court apron, then the darker playing area inside the lines. Each
        // sits a hair above the last so they never z-fight.
        slab(x: 0, y: 0, width: surfaceHalfWidth * 6, length: surfaceHalfLength * 6, z: 0,
             color: grassColor, unlit: false)
        slab(x: 0, y: 0, width: surfaceHalfWidth * 2, length: surfaceHalfLength * 2, z: 0.4,
             color: surfaceColor, unlit: false)
        slab(x: 0, y: 0, width: doublesWidth, length: length, z: 0.8,
             color: insideColor, unlit: false)

        // --- Painted lines ---
        let lineZ = 1.2

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
        let span = netPostOffset * 2

        // Posts.
        for side in [-1.0, 1.0] {
            out.append(ScenePrimitive(
                shape: .cylinder(radius: Float(metres(0.05)), height: Float(netPostHeight)),
                transform: Float4x4.translation(SIMD3(Float(side * netPostOffset), 0,
                                              Float(netPostHeight / 2)))
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
            let x = -netPostOffset + t * span
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
                let x0 = -netPostOffset + span * Double(segment) / Double(segments)
                let x1 = -netPostOffset + span * Double(segment + 1) / Double(segments)
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
            let x0 = -netPostOffset + span * Double(segment) / Double(segments)
            let x1 = -netPostOffset + span * Double(segment + 1) / Double(segments)
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
