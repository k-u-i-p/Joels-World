import Foundation
import simd

/// The rugby pitch: how big it is, where the try lines and posts are, and every piece of
/// geometry that draws it.
///
/// Built exactly the way `FootballPitch` is — a list of boxes, planes, cylinders and spheres the
/// renderer turns into draw calls — and at the same scale, because it is the same scale:
/// **one metre is 27 world units**, pinned to the character rig.
///
/// Two decisions shape the game:
///
/// 1. **Boards, not touchlines.** A ball over the touchline in real rugby is a line-out, which
///    needs a referee and a restart nobody wanted to explain to a ten-year-old. The boards bring
///    it back, the way the football cage does.
/// 2. **A try is the ball carried over the line.** There is no kicking at all — no conversions,
///    no penalties, no drop goals. The posts are there because a rugby pitch without them does
///    not look like one.
///
/// Layout in world space (Y-down, as the whole engine is):
///
/// ```
///   y = −halfLength   ┌──────── dead-ball line ───────┐
///   y = −halfField    ├──────── RED TRY LINE ─────────┤   red defend, blue attack
///                     │                                │
///   y = 0             ├────────── halfway ────────────┤
///                     │                                │
///   y = +halfField    ├──────── BLUE TRY LINE ────────┤   blue defend — camera end
///   y = +halfLength   └──────── dead-ball line ───────┘
/// ```
enum RugbyPitch {

    // MARK: - Scale

    static let unitsPerMetre: Double = 27

    static func metres(_ value: Double) -> Double { value * unitsPerMetre }

    // MARK: - Dimensions

    /// Try line to try line. A real pitch is 100 m; this is a five-a-side one on a school field,
    /// and the camera frames a fixed 32 m of it whatever these say — see `RugbyGame.updateCamera`.
    static let fieldLength = metres(70)
    static let halfField = fieldLength / 2
    /// The in-goal area behind each try line. Cross the try line with the ball and it is a try;
    /// this is how much grass there is to do it on before the boards.
    static let inGoalDepth = metres(6)
    static let halfLength = halfField + inGoalDepth
    static let width = metres(44)
    static let halfWidth = width / 2

    static let sideRunOff = metres(3.0)
    static let endRunOff = metres(2.5)
    static let boardHeight = metres(1.0)
    static let boardX = halfWidth + sideRunOff
    static let boardY = halfLength + endRunOff

    /// The 22 and the 10 m lines, measured from the try line and the halfway line respectively.
    static let twentyTwo = metres(22)
    static let tenMetre = metres(10)

    /// The H. Real posts are 5.6 m apart with a 3 m crossbar; these are to scale.
    static let postHalfWidth = metres(2.8)
    static let postHeight = metres(8)
    static let crossbarHeight = metres(3)

    static let lineWidth = metres(0.12)

    /// The ball's body radius. **Oversized, like the football**, because a real one is a few pixels
    /// from this camera and a game in which you cannot see the ball is not a game. The egg shape
    /// is built from this in `ballPrimitives`.
    static let ballRadius = metres(0.5)

    // MARK: - Where things are

    static func tryLineY(attackDirection: Double) -> Double { attackDirection * halfField }
    static func ownTryLineY(attackDirection: Double) -> Double { -attackDirection * halfField }

    // MARK: - Colours

    private static let grassColor = parseHexColor("#4f9c3f")
    private static let grassStripeColor = parseHexColor("#59a848")
    private static let inGoalColor = parseHexColor("#3f8a36")
    private static let surroundColor = parseHexColor("#3f7f33")
    private static let lineColor = parseHexColor("#f2f6ef")
    private static let boardColor = parseHexColor("#e6eaee")
    private static let blueBoardColor = parseHexColor("#2f6fd0")
    private static let redBoardColor = parseHexColor("#c9402f")
    private static let postColor = parseHexColor("#fbfbf8")
    private static let padColor = parseHexColor("#f0c431")
    private static let hedgeColor = parseHexColor("#2f6b33")
    private static let ballColor = parseHexColor("#f3efe6")

    static let skyHex = "#8fc6e8"
    static let blueHex = "#2f6fd0"
    static let redHex = "#c9402f"

    // MARK: - Heights

    private static let grassZ: Double = 0
    private static let stripeZ: Double = 1
    private static let lineZ: Double = 3

    // MARK: - The pitch, built once

    static let staticPrimitives: [ScenePrimitive] = buildStatic()

    private static func buildStatic() -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        out.reserveCapacity(200)
        appendGround(to: &out)
        appendMarkings(to: &out)
        appendBoards(to: &out)
        appendPosts(attackDirection: -1, to: &out)
        appendPosts(attackDirection: 1, to: &out)
        return out
    }

    // MARK: - Ground

    private static func appendGround(to out: inout [ScenePrimitive]) {
        // The surround is enormous on purpose — see `FootballPitch.appendGround`. Without it the
        // top third of the screen is a flat blue band where the world ends.
        out.append(plane(x: 0, y: 0, width: metres(300), length: metres(300),
                         z: grassZ - 1, color: surroundColor))

        let hedgeOut = metres(14)
        let hedgeHeight = metres(2.2)
        for side in [-1.0, 1.0] {
            out.append(box(x: side * (boardX + hedgeOut), y: 0,
                           sizeX: metres(1.6), sizeY: (boardY + hedgeOut) * 2 + metres(1.6),
                           height: hedgeHeight, color: hedgeColor))
            out.append(box(x: 0, y: side * (boardY + hedgeOut),
                           sizeX: (boardX + hedgeOut) * 2 + metres(1.6), sizeY: metres(1.6),
                           height: hedgeHeight, color: hedgeColor))
        }

        out.append(plane(x: 0, y: 0, width: width, length: fieldLength, z: grassZ,
                         color: grassColor))

        // The in-goal areas, a shade darker, so "am I over the line yet?" has an answer you can
        // see from a camera that is following the ball.
        for direction in [-1.0, 1.0] {
            out.append(plane(x: 0, y: direction * (halfField + inGoalDepth / 2),
                             width: width, length: inGoalDepth, z: grassZ, color: inGoalColor))
        }

        // Mown stripes, so a run up the pitch reads as a run.
        let stripes = 7
        let stripeLength = fieldLength / Double(stripes)
        for index in 0..<stripes where index % 2 == 0 {
            let centreY = -halfField + (Double(index) + 0.5) * stripeLength
            out.append(plane(x: 0, y: centreY, width: width, length: stripeLength,
                             z: stripeZ, color: grassStripeColor))
        }
    }

    // MARK: - Markings

    private static func appendMarkings(to out: inout [ScenePrimitive]) {
        // Touchlines run the whole length, in-goal included. Dead-ball lines close the ends.
        for side in [-1.0, 1.0] {
            out.append(line(x: side * halfWidth, y: 0, length: halfLength * 2, angle: .pi / 2))
            out.append(line(x: 0, y: side * halfLength, length: width, angle: 0))
            // Try lines, drawn a little fatter: they are the whole game.
            out.append(ScenePrimitive(
                shape: .plane(width: Float(width), height: Float(lineWidth * 2.2)),
                transform: Float4x4.translation(SIMD3(0, Float(-side * halfField), Float(lineZ))),
                color: lineColor, roughness: 0.95, unlit: true, castsShadow: false))
            // The 22s.
            out.append(line(x: 0, y: side * (halfField - twentyTwo), length: width, angle: 0))
            // The 10 m lines, dashed.
            appendDashed(y: side * tenMetre, into: &out)
        }
        // Halfway.
        out.append(line(x: 0, y: 0, length: width, angle: 0))
    }

    /// A dashed line across the pitch. Every dash is the same size, so the renderer caches one
    /// mesh for all of them.
    private static func appendDashed(y: Double, into out: inout [ScenePrimitive]) {
        let dash = metres(2.0)
        let gap = metres(1.5)
        var x = -halfWidth + dash / 2
        while x + dash / 2 <= halfWidth + 1 {
            out.append(ScenePrimitive(
                shape: .plane(width: Float(dash), height: Float(lineWidth)),
                transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(lineZ))),
                color: lineColor, roughness: 0.95, unlit: true, castsShadow: false))
            x += dash + gap
        }
    }

    private static func line(x: Double, y: Double, length: Double, angle: Double) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(length), height: Float(lineWidth)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(lineZ)))
                * Float4x4.rotationZ(Float(angle)),
            color: lineColor, roughness: 0.95, unlit: true, castsShadow: false)
    }

    // MARK: - Boards

    private static func appendBoards(to out: inout [ScenePrimitive]) {
        let thickness = metres(0.3)
        for side in [-1.0, 1.0] {
            out.append(box(x: side * boardX, y: 0,
                           sizeX: thickness, sizeY: boardY * 2, height: boardHeight,
                           color: boardColor))
        }
        for direction in [-1.0, 1.0] {
            // −Y is the end blue attacks, so the boards behind it are red's.
            let color = direction < 0 ? redBoardColor : blueBoardColor
            out.append(box(x: 0, y: direction * boardY,
                           sizeX: boardX * 2, sizeY: thickness, height: boardHeight,
                           color: color))
        }
    }

    // MARK: - Posts

    /// The H on the try line a team attacking in `attackDirection` is running at.
    private static func appendPosts(attackDirection: Double, to out: inout [ScenePrimitive]) {
        let lineY = tryLineY(attackDirection: attackDirection)
        let postRadius = metres(0.09)

        for side in [-1.0, 1.0] {
            out.append(post(x: side * postHalfWidth, y: lineY, radius: postRadius,
                            height: postHeight, color: postColor))
            // Padding round the bottom, in school yellow.
            out.append(post(x: side * postHalfWidth, y: lineY, radius: metres(0.22),
                            height: metres(1.8), color: padColor))
        }

        out.append(ScenePrimitive(
            shape: .cylinder(radius: Float(postRadius),
                             height: Float(postHalfWidth * 2 + postRadius * 2)),
            transform: Float4x4.translation(SIMD3(0, Float(-lineY), Float(crossbarHeight)))
                * Float4x4.rotationZ(.pi / 2),
            color: postColor, roughness: 0.4, castsShadow: true))
    }

    // MARK: - Primitive helpers

    private static func plane(x: Double, y: Double, width: Double, length: Double, z: Double,
                             color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(width), height: Float(length)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z))),
            color: color, roughness: 0.96, castsShadow: false)
    }

    private static func box(x: Double, y: Double,
                            sizeX: Double, sizeY: Double, height: Double,
                            color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .box(width: Float(sizeX), height: Float(sizeY), depth: Float(height)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(height / 2))),
            color: color, roughness: 0.85, castsShadow: false)
    }

    private static func post(x: Double, y: Double, radius: Double, height: Double,
                             color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .cylinder(radius: Float(radius), height: Float(height)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(height / 2)))
                * Float4x4.rotationX(.pi / 2),
            color: color, roughness: 0.4, castsShadow: true)
    }

    // MARK: - Things that move

    /// **The ball is an egg made of five spheres.** The renderer's shapes are a closed set and a
    /// stretched sphere would light wrongly (see `ScenePrimitive`), so a rugby ball is a fat
    /// sphere in the middle and two smaller ones each side along `axis` — the direction it is
    /// pointing, in world radians. Three distinct radii, so three cached meshes.
    static func ballPrimitives(x: Double, y: Double, z: Double, axis: Double) -> [ScenePrimitive] {
        let dx = cos(axis)
        let dy = sin(axis)
        let parts: [(offset: Double, radius: Double)] = [
            (0, 1), (0.42, 0.78), (-0.42, 0.78), (0.74, 0.46), (-0.74, 0.46),
        ]
        return parts.map { part in
            let along = part.offset * ballRadius * 1.25
            return ScenePrimitive(
                shape: .sphere(radius: Float(ballRadius * part.radius)),
                transform: Float4x4.translation(SIMD3(Float(x + dx * along),
                                                      Float(-(y + dy * along)),
                                                      Float(z))),
                color: ballColor, roughness: 0.6, castsShadow: true)
        }
    }

    /// The disc under a player's feet — how you know which one is you. See
    /// `FootballPitch.markerPrimitive`.
    static func markerPrimitive(x: Double, y: Double, radius: Double,
                                color: SIMD3<Float>, opacity: Float) -> ScenePrimitive {
        ScenePrimitive(
            shape: .cylinder(radius: Float(radius), height: Float(metres(0.02))),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(lineZ + 1)))
                * Float4x4.rotationX(.pi / 2),
            color: color, opacity: opacity, unlit: true, castsShadow: false)
    }
}
