import Foundation
import simd

/// The pitch: how big it is, where the goals are, and every piece of geometry that draws it.
///
/// Built the same way `Tennis3DCourt` is — a list of boxes, planes and cylinders the renderer
/// turns into draw calls — and with the same conversion, because it is the same conversion:
/// **one metre is 27 world units**, pinned to the character rig rather than to the art. A pupil
/// is about 1.4 m and stands about 38 units tall. Get this wrong and twenty players are ants on
/// an airfield.
///
/// Two decisions here shape the whole game:
///
/// 1. **The pitch has boards round it, like a five-a-side cage.** A real pitch has touchlines,
///    and a ball crossing one is a throw-in — which needs a referee, a restart, a player walking
///    to the line and a rule nobody wanted to explain. Boards mean the ball comes back and the
///    game never stops. It is also, genuinely, what school football on an all-weather pitch is.
/// 2. **It is five a side on a 72 m by 46 m pitch**, not eleven on the 100 × 64 of a real one —
///    and the camera shows a fixed 40 m of it whatever those numbers say, so the size of the
///    pitch and the size of the players are two separate decisions. See `length` below.
///
/// Layout in world space (Y-down, as the whole engine is):
///
/// ```
///   y = −halfLength   ┌────────── RED GOAL ──────────┐   red defend, blue attack
///                     │                              │
///   y = 0             ├────────── halfway ───────────┤
///                     │                              │
///   y = +halfLength   └────────── BLUE GOAL ─────────┘   blue defend — camera end
/// ```
enum FootballPitch {

    // MARK: - Scale

    /// World units per metre. Pinned to the rig, exactly as tennis and School Rush are.
    static let unitsPerMetre: Double = 27

    static func metres(_ value: Double) -> Double { value * unitsPerMetre }

    // MARK: - Dimensions

    /// **72 m by 46 m, and the camera does not zoom out to suit it.**
    ///
    /// It went 72 × 46 → 50 × 34 when the squads went from ten a side to five, and back up again
    /// when Joel asked for a bigger pitch. What makes that work rather than making five players
    /// look lost is that the two decisions are now independent: the camera shows a fixed 40 m of
    /// width (`FootballGame.updateCamera`) whatever size the pitch is, so a bigger pitch is more
    /// room to run into rather than smaller players. You see about half of it at a time and the
    /// camera follows the ball over the rest.
    static let length = metres(72)
    static let halfLength = length / 2
    static let width = metres(46)
    static let halfWidth = width / 2

    /// 6.5 m by 2.2 m — between a five-a-side goal and a full-size one.
    ///
    /// It is not the 5 m it was, and the reason is the beach ball: `checkGoal` wants the whole
    /// ball over the line and between the posts, so `ballRadius` eats 1.3 m of any goal's mouth.
    /// A 5 m goal on a pitch this long left 3.7 m to aim at from thirty metres out.
    static let goalWidth = metres(6.5)
    static let goalHalfWidth = goalWidth / 2
    static let goalHeight = metres(2.2)
    static let goalDepth = metres(1.8)

    /// Grass outside the lines, and the boards at the edge of it. The ball rebounds off the
    /// boards; nobody may go past them.
    static let sideRunOff = metres(3.4)
    static let endRunOff = metres(5.0)
    static let boardHeight = metres(1.0)

    static let boardX = halfWidth + sideRunOff
    static let boardY = halfLength + endRunOff

    /// The penalty area, kept in the real proportions and scaled with the pitch so it is a
    /// sensible fraction of it rather than swallowing the half.
    static let penaltyDepth = metres(13.0)
    static let penaltyHalfWidth = metres(15.0)
    static let sixYardDepth = metres(4.6)
    static let sixYardHalfWidth = metres(8.2)
    static let penaltySpot = metres(10.0)
    static let centreCircleRadius = metres(8.2)

    /// Painted lines are 12 cm wide. Wider than a real 10 cm because from this camera a real one
    /// is a shimmer.
    static let lineWidth = metres(0.12)

    /// **Six times a real size 4 ball**, which is 0.105 m. Joel asked for it twice as big as it
    /// already was, and he is the developer.
    ///
    /// A correctly-sized ball, from a camera fitting a whole pitch across a phone, is three
    /// pixels: genuinely impossible to find, and a football game in which you cannot find the
    /// ball is not a football game. Every arcade football game ever made oversizes the ball; this
    /// one is a beach ball, and there is nothing wrong with that.
    ///
    /// Almost only the drawing changes: possession is `Tuning.controlRadius` from the player and
    /// takes no notice of this. But `checkGoal` wants the **whole ball** over the line and
    /// between the posts, so a beach ball narrows a 6.5 m goal to 5.2 m of scorable mouth —
    /// which is why `shoot(from:)` aims inside `goalHalfWidth − ballRadius`, not at the post.
    static let ballRadius = metres(0.64)

    // MARK: - Where things are

    /// The goal line a team defends. `attackDirection` is −1 for blue (attacking towards −Y,
    /// away from the camera) and +1 for red.
    static func ownGoalY(attackDirection: Double) -> Double { -attackDirection * halfLength }
    static func targetGoalY(attackDirection: Double) -> Double { attackDirection * halfLength }

    // MARK: - Colours

    private static let grassColor = parseHexColor("#4f9c3f")
    private static let grassStripeColor = parseHexColor("#59a848")
    private static let surroundColor = parseHexColor("#3f7f33")
    private static let lineColor = parseHexColor("#f2f6ef")
    private static let boardColor = parseHexColor("#e6eaee")
    private static let blueBoardColor = parseHexColor("#2f6fd0")
    private static let redBoardColor = parseHexColor("#c9402f")
    private static let postColor = parseHexColor("#fbfbf8")
    private static let netColor = parseHexColor("#dfe6ea")
    private static let hedgeColor = parseHexColor("#2f6b33")

    static let skyHex = "#8fc6e8"

    /// Team kit colours, for the HUD and for the ring under whoever has the ball. The players
    /// themselves wear the `red` and `blue` outfit textures — see `GameCharacter.outfit`.
    static let blueHex = "#2f6fd0"
    static let redHex = "#c9402f"

    // MARK: - Heights
    //
    // Everything painted on the ground is a flat plane, and flat planes at the same height
    // z-fight. Each layer gets two units of its own, the way the tennis court's apron and lines
    // do.

    private static let grassZ: Double = 0
    private static let stripeZ: Double = 1
    private static let lineZ: Double = 3

    // MARK: - The pitch, built once

    /// Everything that never moves. Built once because — unlike School Rush's endless track —
    /// a pitch is a pitch: about two hundred primitives that are identical on every frame of
    /// every match.
    static let staticPrimitives: [ScenePrimitive] = buildStatic()

    private static func buildStatic() -> [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        out.reserveCapacity(260)

        appendGround(to: &out)
        appendMarkings(to: &out)
        appendBoards(to: &out)
        appendGoal(attackDirection: -1, to: &out)   // the goal blue attacks, at −Y
        appendGoal(attackDirection: 1, to: &out)    // the goal blue defends, at +Y

        return out
    }

    // MARK: - Ground

    private static func appendGround(to out: inout [ScenePrimitive]) {
        // **The surround, and it is deliberately enormous.**
        //
        // It was eight metres of grass past the boards, and from this camera that put the edge of
        // the world about two thirds of the way up the screen: everything beyond it was the clear
        // colour, so the top third of every frame was a flat blue band that read as sky and was
        // actually nothing at all. A 300 m field costs one more plane and one more draw call and
        // fills the frame with grass all the way to the top.
        out.append(plane(x: 0, y: 0,
                         width: metres(300), length: metres(300),
                         z: grassZ - 1, color: surroundColor))

        // A hedge round the field, well back from the boards. Nothing in the game touches it —
        // it is there so the pitch sits *in* somewhere rather than floating on a green sheet, and
        // so the eye has a horizon to measure the far goal against.
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

        out.append(plane(x: 0, y: 0, width: width, length: length, z: grassZ, color: grassColor))

        // **Mown stripes, and they are not decoration.** Twenty players running about on one flat
        // green sheet gives the eye nothing to measure movement against; the stripes are what
        // make a run up the pitch read as a run. Eight of them across the length, which is what
        // a roller actually leaves.
        let stripes = 6
        let stripeLength = length / Double(stripes)
        for index in 0..<stripes where index % 2 == 0 {
            let centreY = -halfLength + (Double(index) + 0.5) * stripeLength
            out.append(plane(x: 0, y: centreY, width: width, length: stripeLength,
                             z: stripeZ, color: grassStripeColor))
        }
    }

    // MARK: - Markings

    private static func appendMarkings(to out: inout [ScenePrimitive]) {
        // Touchlines and goal lines.
        for side in [-1.0, 1.0] {
            out.append(line(x: side * halfWidth, y: 0, length: length, angle: .pi / 2))
            out.append(line(x: 0, y: side * halfLength, length: width, angle: 0))
        }

        // Halfway line and centre circle.
        out.append(line(x: 0, y: 0, length: width, angle: 0))
        appendArc(centreX: 0, centreY: 0, radius: centreCircleRadius, into: &out)
        out.append(ScenePrimitive(
            shape: .plane(width: Float(metres(0.5)), height: Float(metres(0.5))),
            transform: Float4x4.translation(SIMD3(0, 0, Float(lineZ))),
            color: lineColor, roughness: 0.95, unlit: true, castsShadow: false))

        for direction in [-1.0, 1.0] {
            let goalLine = direction * halfLength
            // Into the pitch is the opposite sign to the goal line itself.
            let inwards = -direction

            // Penalty area and six-yard box: three sides each, the fourth being the goal line.
            for box in [(depth: penaltyDepth, half: penaltyHalfWidth),
                        (depth: sixYardDepth, half: sixYardHalfWidth)] {
                let front = goalLine + inwards * box.depth
                out.append(line(x: 0, y: front, length: box.half * 2, angle: 0))
                for side in [-1.0, 1.0] {
                    out.append(line(x: side * box.half,
                                    y: (goalLine + front) / 2,
                                    length: box.depth,
                                    angle: .pi / 2))
                }
            }

            // The spot, and the D outside the box — the arc of the centre-circle radius drawn
            // about the spot, clipped to whatever falls outside the penalty area.
            let spotY = goalLine + inwards * penaltySpot
            out.append(ScenePrimitive(
                shape: .plane(width: Float(metres(0.34)), height: Float(metres(0.34))),
                transform: Float4x4.translation(SIMD3(0, Float(-spotY), Float(lineZ))),
                color: lineColor, roughness: 0.95, unlit: true, castsShadow: false))
            appendArc(centreX: 0, centreY: spotY, radius: centreCircleRadius,
                      clip: { _, y in inwards * (y - (goalLine + inwards * penaltyDepth)) > 0 },
                      into: &out)
        }
    }

    /// One straight painted line, `length` long, rotated by `angle` about the vertical.
    ///
    /// Written in **render space** — Y negated — because that is what the transform wants and
    /// converting an angle between the two conventions is exactly the kind of sign error that
    /// costs an afternoon.
    private static func line(x: Double, y: Double, length: Double, angle: Double) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(length), height: Float(lineWidth)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(lineZ)))
                * Float4x4.rotationZ(Float(angle)),
            color: lineColor,
            roughness: 0.95,
            unlit: true,
            castsShadow: false)
    }

    /// A painted arc, as short straight segments. `clip` drops the ones that should not be
    /// painted — which is how the D outside the penalty area is drawn without a second shape.
    ///
    /// Every segment is the **same size**, deliberately: `ScenePrimitiveRenderer` caches one GPU
    /// mesh per distinct `Shape`, so a hundred identical segments cost one mesh and a hundred
    /// transforms, while a hundred subtly different ones would cost a hundred meshes.
    private static func appendArc(centreX: Double, centreY: Double, radius: Double,
                                  clip: ((Double, Double) -> Bool)? = nil,
                                  into out: inout [ScenePrimitive]) {
        let segments = 72
        let step = 2 * Double.pi / Double(segments)
        // A shade longer than the chord, so consecutive segments overlap rather than leaving a
        // dotted line at the joins.
        let segmentLength = 2 * radius * sin(abs(step) / 2) * 1.15

        for index in 0..<segments {
            let angle = (Double(index) + 0.5) * step
            let x = centreX + radius * cos(angle)
            let y = centreY + radius * sin(angle)
            if let clip, !clip(x, y) { continue }

            out.append(ScenePrimitive(
                shape: .plane(width: Float(segmentLength), height: Float(lineWidth)),
                transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(lineZ)))
                    // Tangent to the circle. The world's Y is negated in render space, so the
                    // angle is too — and the tangent is a further quarter turn on from that.
                    * Float4x4.rotationZ(Float(-angle + .pi / 2)),
                color: lineColor,
                roughness: 0.95,
                unlit: true,
                castsShadow: false))
        }
    }

    // MARK: - Boards

    /// The perimeter the ball bounces off. Painted in the two teams' colours behind their own
    /// goals, which is the cheapest way to make "which way am I kicking?" answerable at a glance
    /// — and that question is otherwise genuinely hard from a camera that follows the ball.
    private static func appendBoards(to out: inout [ScenePrimitive]) {
        let thickness = metres(0.3)

        for side in [-1.0, 1.0] {
            out.append(box(x: side * boardX, y: 0,
                           sizeX: thickness, sizeY: boardY * 2, height: boardHeight,
                           color: boardColor))
        }
        for direction in [-1.0, 1.0] {
            // −Y is the goal blue attacks, so the boards behind it are red's.
            let color = direction < 0 ? redBoardColor : blueBoardColor
            out.append(box(x: 0, y: direction * boardY,
                           sizeX: boardX * 2, sizeY: thickness, height: boardHeight,
                           color: color))
        }
    }

    // MARK: - Goals

    private static func appendGoal(attackDirection: Double, to out: inout [ScenePrimitive]) {
        // The goal a team attacking in `attackDirection` is aiming at.
        let goalLine = attackDirection * halfLength
        let backY = goalLine + attackDirection * goalDepth
        let postRadius = metres(0.07)

        for side in [-1.0, 1.0] {
            out.append(post(x: side * goalHalfWidth, y: goalLine,
                            radius: postRadius, height: goalHeight))
        }

        // The crossbar: the same cylinder laid on its side.
        out.append(ScenePrimitive(
            shape: .cylinder(radius: Float(postRadius), height: Float(goalWidth + postRadius * 2)),
            transform: Float4x4.translation(SIMD3(0, Float(-goalLine), Float(goalHeight)))
                * Float4x4.rotationZ(.pi / 2),
            color: postColor,
            roughness: 0.4,
            castsShadow: true))

        // The net: back, roof and two sides, all unlit and blended. Unlit because a
        // semi-transparent plane's shading depends on which way its normal happens to point, and
        // a net that is bright from one end of the pitch and black from the other is worse than
        // a net with no shading at all.
        out.append(ScenePrimitive(
            shape: .plane(width: Float(goalWidth), height: Float(goalHeight)),
            transform: Float4x4.translation(SIMD3(0, Float(-backY), Float(goalHeight / 2)))
                * Float4x4.rotationX(.pi / 2),
            color: netColor, opacity: 0.34, unlit: true, castsShadow: false))

        out.append(ScenePrimitive(
            shape: .plane(width: Float(goalWidth), height: Float(goalDepth)),
            transform: Float4x4.translation(SIMD3(0, Float(-(goalLine + backY) / 2),
                                                  Float(goalHeight))),
            color: netColor, opacity: 0.30, unlit: true, castsShadow: false))

        for side in [-1.0, 1.0] {
            out.append(ScenePrimitive(
                shape: .plane(width: Float(goalDepth), height: Float(goalHeight)),
                transform: Float4x4.translation(SIMD3(Float(side * goalHalfWidth),
                                                      Float(-(goalLine + backY) / 2),
                                                      Float(goalHeight / 2)))
                    * Float4x4.rotationZ(.pi / 2)
                    * Float4x4.rotationX(.pi / 2),
                color: netColor, opacity: 0.30, unlit: true, castsShadow: false))
        }
    }

    // MARK: - Primitive helpers

    private static func plane(x: Double, y: Double, width: Double, length: Double, z: Double,
                             color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .plane(width: Float(width), height: Float(length)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z))),
            color: color,
            roughness: 0.96,
            castsShadow: false)
    }

    /// A box standing on the ground. `sizeX` runs across the pitch, `sizeY` along it.
    private static func box(x: Double, y: Double,
                            sizeX: Double, sizeY: Double, height: Double,
                            color: SIMD3<Float>) -> ScenePrimitive {
        ScenePrimitive(
            shape: .box(width: Float(sizeX), height: Float(sizeY), depth: Float(height)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(height / 2))),
            color: color,
            roughness: 0.85,
            castsShadow: false)
    }

    /// An upright cylinder. `MeshFactory` builds them along +Y, so they are stood up here.
    private static func post(x: Double, y: Double,
                             radius: Double, height: Double) -> ScenePrimitive {
        ScenePrimitive(
            shape: .cylinder(radius: Float(radius), height: Float(height)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(height / 2)))
                * Float4x4.rotationX(.pi / 2),
            color: postColor,
            roughness: 0.4,
            castsShadow: true)
    }

    // MARK: - Things that move

    static func ballPrimitive(x: Double, y: Double, z: Double) -> ScenePrimitive {
        ScenePrimitive(
            shape: .sphere(radius: Float(ballRadius)),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(z))),
            color: parseHexColor("#fdfdf8"),
            roughness: 0.55,
            castsShadow: true)
    }

    /// The disc under a player's feet.
    ///
    /// **This is how you know which one is you**, and it is not optional: nameplates are switched
    /// off during a minigame, so twenty pupils in two kits are otherwise twenty identical pupils.
    /// A flat cylinder rather than a ring, because a ring is a mesh nobody else needs and a disc
    /// under the boots reads instantly at this camera height. It has to be **wider than the
    /// character is**, or the character stands on it and hides it.
    static func markerPrimitive(x: Double, y: Double, radius: Double,
                                color: SIMD3<Float>, opacity: Float) -> ScenePrimitive {
        ScenePrimitive(
            shape: .cylinder(radius: Float(radius), height: Float(metres(0.02))),
            transform: Float4x4.translation(SIMD3(Float(x), Float(-y), Float(lineZ + 1)))
                * Float4x4.rotationX(.pi / 2),
            color: color,
            opacity: opacity,
            unlit: true,
            castsShadow: false)
    }
}
