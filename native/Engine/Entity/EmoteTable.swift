import Foundation
import simd

/// The emote table, ported from `emotes.js`.
///
/// Every pose is a literal transcription: same constants, same maths, same order of
/// assignment. Two things about the JS are reproduced deliberately rather than fixed —
///
/// - **Props inside one emote share a single three.js material.** Where the JS assigns
///   `mesh.material.opacity` inside a `for` loop with a per-mesh value, every mesh in that
///   group ends up with the *last* value written. `cry`'s six tears, `love`'s four hearts,
///   `swim`'s three ripples, `sleep`'s three letters, `eat`'s crumbs and `wet`'s footprints
///   all fade in lockstep because of it. `sharedOpacity` reproduces that.
/// - **Props are retained between frames.** When a pose stops updating a prop — `jump`'s dust
///   through the middle of the arc, `fart`'s cloud after a second — it keeps its last
///   transform. In both cases the last value written was a zero opacity, so emitting nothing
///   is equivalent, and that is what these closures do.
///
/// This is the twenty poses and nothing else. The types they are written in terms of, and the
/// lookup and chat-line code written in terms of them, are in `Emotes.swift`.
extension Emotes {
    // Palette, linearised the same way every other colour in the client is.
    private static let laserRed = parseHexColor("#ff0000")
    private static let waterBlue = parseHexColor("#3498db")
    private static let appleRed = parseHexColor("#e74c3c")
    private static let stemGreen = parseHexColor("#27ae60")
    private static let porcelain = parseHexColor("#ecf0f1")
    private static let steakPurple = parseHexColor("#8e44ad")
    private static let steel = parseHexColor("#bdc3c7")
    private static let notePurple = parseHexColor("#9b59b6")
    private static let gasGreen = parseHexColor("#2ecc71")
    private static let tennisYellow = parseHexColor("#caff28")
    private static let rugbyWhite = parseHexColor("#f0f0f0")

    // MARK: - Helpers

    /// The three.js material every prop in one group shares: the value the *last* loop
    /// iteration wrote is the one they all render with.
    private static func sharedOpacity(_ props: inout [PropDraw], from index: Int, _ value: Float) {
        guard index < props.count else { return }
        for i in index..<props.count { props[i].opacity = value }
    }

    /// JS `%` on the non-negative values these poses use.
    private static func mod(_ value: Double, _ divisor: Double) -> Double {
        value.truncatingRemainder(dividingBy: divisor)
    }

    private static func t(_ x: Float, _ y: Float, _ z: Float) -> Float4x4 {
        .translation(SIMD3(x, y, z))
    }

    // MARK: - The table

    static let table: [String: EmoteDefinition] = [

        // MARK: laser
        "laser": EmoteDefinition(
            duration: 5000,
            message: "{name} is firing backwards lasers!",
            messageWhenNear: "{name} shot a laser at {target_name}!",
            sound: "/media/laser.mp3",
            pose: { rig, ctx in
                let hover = Float(sin(ctx.elapsed / 100) * 3)
                rig.bodyPivotPosition = SIMD3(0, 0, 15.5 + hover + 10)

                rig.leftHandTarget = SIMD3(0, -25, 15)
                rig.rightHandTarget = SIMD3(0, 25, 15)
                rig.leftFootTarget = SIMD3(-4, -6, -20)
                rig.rightFootTarget = SIMD3(-4, 6, -20)

                rig.bodyPivotRotation.x = .pi / 16

                // Both beams originate inside the eyes and are parented to the head, so they
                // track wherever it is looking.
                let alpha = Float(0.5 + sin(ctx.elapsed / 50) * 0.5)
                for y in [Float(-4.5), 4.5] {
                    rig.props.append(PropDraw(mesh: .laserBeam, anchor: .head,
                                              local: t(150, y, 3.5),
                                              color: laserRed, opacity: alpha,
                                              unlit: true, transparent: true))
                }
            }
        ),

        // MARK: bounce
        "bounce": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} is bouncing",
            messageWhenNear: "{name} is bouncing with {target_name}",
            sound: "/media/jump.mp3",
            pose: { rig, ctx in
                let danceTime = ctx.elapsed / 150
                let bounce = Float(abs(sin(danceTime)) * 20)
                let tilt = Float(sin(danceTime * 0.8) * 0.3)

                rig.bodyPivotPosition.z = 25.5 + bounce
                rig.bodyPivotRotation.x = tilt

                // Additive: the limbs keep whatever the walk cycle or idle sway put there.
                rig.leftHandTarget.z += bounce * 0.5
                rig.rightHandTarget.z += bounce * 0.5
                rig.leftFootTarget.z -= bounce
                rig.rightFootTarget.z -= bounce
            }
        ),

        // MARK: wave
        "wave": EmoteDefinition(
            duration: 3000,
            message: "{name} waves",
            messageWhenNear: "{name} waved at {target_name}",
            sound: nil,
            pose: { rig, ctx in
                let armSwing = Float(sin(ctx.elapsed / 100) * 10)
                rig.rightHandTarget = SIMD3(10, 20 + armSwing, 32)
            }
        ),

        // MARK: wet
        "wet": EmoteDefinition(
            duration: 10000,
            message: "{name} is dripping wet",
            messageWhenNear: "{name} dripped water all over {target_name}",
            sound: "/media/wet_footprints.mp3",
            pose: { rig, ctx in
                let elapsed = ctx.elapsed

                // --- Footprints, dropped into the scene root so they stay behind ---
                if ctx.runtime.footprints.isEmpty {
                    ctx.runtime.footprints = Array(repeating: Footprint(), count: 16)
                }

                let stepIndex = Int(floor(elapsed / 400)) % 16
                var print = ctx.runtime.footprints[stepIndex]

                if !print.visible || print.lastDrop < elapsed - 6000 {
                    let sideOffset = Float(stepIndex % 2 == 0 ? 5 : -5)
                    let yaw = Float(ctx.rotationDegrees) * degToRad
                    print.x = ctx.worldPosition.x + cos(yaw + .pi / 2) * sideOffset
                    print.y = ctx.worldPosition.y + sin(yaw + .pi / 2) * sideOffset
                    print.rotation = -yaw
                    print.visible = true
                    print.lastDrop = elapsed
                    ctx.runtime.footprints[stepIndex] = print
                }

                let footprintStart = rig.props.count
                var lastFootprintOpacity: Float?
                for index in ctx.runtime.footprints.indices where ctx.runtime.footprints[index].visible {
                    let age = elapsed - ctx.runtime.footprints[index].lastDrop
                    if age > 6400 {
                        ctx.runtime.footprints[index].visible = false
                        continue
                    }
                    ctx.runtime.footprints[index].scale = Float(1 - age / 12800)
                    lastFootprintOpacity = Float(0.8 * (1 - age / 6400))

                    let footprint = ctx.runtime.footprints[index]
                    rig.props.append(PropDraw(
                        mesh: .footprint, anchor: .world,
                        local: t(footprint.x, footprint.y, 0.5)
                            * .rotationZ(footprint.rotation)
                            * .scale(SIMD3(repeating: footprint.scale)),
                        color: waterBlue, opacity: 0.6, unlit: true, transparent: true))
                }
                if let lastFootprintOpacity {
                    sharedOpacity(&rig.props, from: footprintStart, lastFootprintOpacity)
                }

                // --- Water shedding off the body ---
                for index in 0..<3 {
                    let offset = Double(index) * 333
                    let progress = mod(elapsed + offset, 1000) / 1000
                    let dropY = Float(index - 1) * 8
                    let dropZ = Float(25 - progress * 30)
                    rig.props.append(PropDraw(
                        mesh: .waterDrop, anchor: .meshGroup,
                        local: t(0, dropY, dropZ) * .scale(SIMD3(repeating: Float(5 - progress))),
                        color: waterBlue, opacity: 0.8, transparent: true, roughness: 0.1))
                }
            }
        ),

        // MARK: eat
        "eat": EmoteDefinition(
            duration: 5000,
            message: "{name} is eating an apple",
            messageWhenNear: "{name} is eating an apple in front of {target_name}",
            sound: "/media/chewing.mp3",
            pose: { rig, ctx in
                let eatTime = ctx.elapsed / 150
                let bringToMouth = Float(max(0, sin(eatTime)))

                rig.rightHandTarget = SIMD3(10, 16 - bringToMouth * 16, 12 + bringToMouth * 24)

                // The apple rides in the hand, so it inherits the forearm's orientation.
                rig.props.append(PropDraw(mesh: .apple, anchor: .rightHand, local: t(0, 0, 0),
                                          color: appleRed, roughness: 0.5))
                rig.props.append(PropDraw(mesh: .appleStem, anchor: .rightHand, local: t(0, 0, 3.5),
                                          color: stemGreen))

                guard bringToMouth > 0.8 else { return }

                let crumbStart = rig.props.count
                var lastCrumbOpacity: Float = 1
                for index in 0..<3 {
                    let crumbTime = Float(mod(ctx.elapsed, 200 + Double(index) * 50) / 250)
                    let dropX = 8 + crumbTime * (5 + Float(index) * 2)
                    let dropY = Float(index - 1) * 3 + crumbTime * 4
                    let dropZ = -crumbTime * 10
                    lastCrumbOpacity = 1 - crumbTime
                    rig.props.append(PropDraw(mesh: .crumb, anchor: .head,
                                              local: t(dropX, dropY, dropZ),
                                              color: appleRed, transparent: true))
                }
                sharedOpacity(&rig.props, from: crumbStart, lastCrumbOpacity)
            }
        ),

        // MARK: lunch
        "lunch": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} is having lunch",
            messageWhenNear: "{name} is having lunch with {target_name}",
            sound: "/media/chewing.mp3",
            pose: { rig, ctx in
                rig.bodyPivotPosition.z = 8
                rig.leftFootTarget = SIMD3(12, -6, -5)
                rig.rightFootTarget = SIMD3(12, 6, -5)

                let armMove = Float(sin(ctx.elapsed / 200))

                // Place setting sits on the floor in front of the character; the cutlery is
                // held, one piece per hand.
                rig.props.append(PropDraw(mesh: .plate, anchor: .meshGroup, local: t(22, 0, 1),
                                          color: porcelain, roughness: 0.3))
                rig.props.append(PropDraw(mesh: .steak, anchor: .meshGroup, local: t(22, 0, 2.1),
                                          color: steakPurple, roughness: 0.8))
                rig.props.append(PropDraw(mesh: .cutlery, anchor: .rightHand, local: t(0, 0, 4),
                                          color: steel))
                rig.props.append(PropDraw(mesh: .cutlery, anchor: .leftHand, local: t(0, 0, 4),
                                          color: steel))

                if armMove > 0 {
                    rig.rightHandTarget = SIMD3(8 + armMove * 2, 8 - armMove * 8, 12 + armMove * 14)
                    rig.leftHandTarget = SIMD3(20, -12, -6)
                } else {
                    rig.leftHandTarget = SIMD3(8 - armMove * 2, -8 - armMove * 8, 12 - armMove * 14)
                    rig.rightHandTarget = SIMD3(20, 12, -6)
                }
            }
        ),

        // MARK: write
        "write": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} is writing",
            messageWhenNear: "{name} is writing with {target_name}",
            sound: nil,
            pose: { rig, ctx in
                rig.bodyPivotPosition.z = 8
                rig.leftFootTarget = SIMD3(12, -6, -5)
                rig.rightFootTarget = SIMD3(12, 6, -5)

                let writeTime = ctx.elapsed / 100
                let armMoveX = Float(sin(writeTime) * 3)
                let armMoveY = Float(cos(writeTime * 1.3) * 2)

                rig.props.append(PropDraw(mesh: .book, anchor: .bodyPivot, local: t(25, 0, 20),
                                          color: porcelain, roughness: 0.9))
                rig.props.append(PropDraw(mesh: .pen, anchor: .rightHand,
                                          local: t(0, 0, 5) * .rotationX(.pi / 4),
                                          color: waterBlue))

                rig.rightHandTarget = SIMD3(19 + armMoveX, 4 + armMoveY, 22)
                rig.leftHandTarget = SIMD3(15, -8, 0)
            }
        ),

        // MARK: jump
        "jump": EmoteDefinition(
            duration: 800,
            message: "{name} leaps forward",
            messageWhenNear: "{name} leaped over {target_name}!",
            sound: "/media/jump.mp3",
            pose: { rig, ctx in
                let age = ctx.elapsed
                guard age < 800 else { return }

                let progress = age / 800
                let height = Float(progress * (1 - progress) * 4 * 30)

                rig.bodyPivotPosition.z = 15.5 + height
                rig.bodyPivotRotation.y = Float(sin(progress * .pi) * 0.4)

                let tuck = Float(sin(progress * .pi))
                rig.leftFootTarget = SIMD3(-2, -6, -13 + tuck * 15)
                rig.rightFootTarget = SIMD3(-2, 6, -13 + tuck * 15)

                let armSwing = Float(cos(progress * .pi * 2))
                rig.leftHandTarget = SIMD3(10 * armSwing, -16, 20 - armSwing * 10)
                rig.rightHandTarget = SIMD3(10 * armSwing, 16, 20 - armSwing * 10)

                // Dust puffs at take-off and landing only. Through the middle of the arc the
                // JS stops updating them and they sit at zero opacity, so nothing is emitted.
                guard progress < 0.25 || progress > 0.75 else { return }
                let dustProgress = Float(progress < 0.25 ? progress / 0.25 : (progress - 0.75) / 0.25)
                let opacity = max(0, 1 - dustProgress * 1.5)
                for index in 0..<4 {
                    let x = -10 + Float(index % 2) * 20 + dustProgress * 10
                    let y = -10 + Float(index / 2) * 20
                    rig.props.append(PropDraw(
                        mesh: .dust, anchor: .meshGroup,
                        local: t(x, y, 0) * .scale(SIMD3(repeating: 1 + dustProgress * 2)),
                        color: steel, opacity: opacity, transparent: true))
                }
            }
        ),

        // MARK: dance
        "dance": EmoteDefinition(
            duration: 8000,
            message: "{name} is busting a move",
            messageWhenNear: "{name} is dancing with {target_name}",
            sound: nil,
            pose: { rig, ctx in
                let danceTime = ctx.elapsed / 150
                let bob = Float(abs(sin(danceTime * 2)) * 6)
                let tilt = Float(sin(danceTime) * 0.3)

                rig.bodyPivotPosition.z = 15.5 + bob
                rig.bodyPivotRotation.x = tilt

                let armSwing = Float(sin(danceTime * 2))
                let legStep = Float(cos(danceTime * 2))

                rig.leftHandTarget = SIMD3(0, -20 - armSwing * 10, 20 + armSwing * 15)
                rig.rightHandTarget = SIMD3(0, 20 - armSwing * 10, 20 - armSwing * 15)
                rig.leftFootTarget = SIMD3(0, -6 - max(0, -legStep * 10), -13)
                rig.rightFootTarget = SIMD3(0, 6 + max(0, legStep * 10), -13)

                // The notes tumble by a fixed step per frame rather than off the clock, so the
                // spin has to be carried forward the way three.js carries `note.rotation`.
                if ctx.runtime.noteSpin.count != 3 {
                    ctx.runtime.noteSpin = Array(repeating: .zero, count: 3)
                }
                for index in 0..<3 {
                    let offset = Double(index) * 400
                    let progress = Float(mod(ctx.elapsed + offset, 1200) / 1200)
                    let noteX = sin(progress * .pi * 4 + Float(index)) * 15
                    let noteZ = 15 + progress * 40

                    ctx.runtime.noteSpin[index] += SIMD2(0.1, 0.1)
                    let spin = ctx.runtime.noteSpin[index]

                    rig.props.append(PropDraw(
                        mesh: .note, anchor: .meshGroup,
                        local: t(noteX, 0, noteZ)
                            * .eulerXYZ(spin.x, spin.y, 0)
                            * .scale(SIMD3(repeating: max(0.01, 1 - progress))),
                        color: notePurple))
                }
            }
        ),

        // MARK: fart
        "fart": EmoteDefinition(
            duration: 2000,
            message: "{name} is farting",
            messageWhenNear: "{name} farted on {target_name}",
            sound: "/media/fart.mp3",
            pose: { rig, ctx in
                // After a second the clouds are held at zero opacity, so they stop being drawn.
                guard ctx.elapsed < 1000 else { return }
                let progress = Float(ctx.elapsed / 1000)
                let alpha = max(0, 1 - progress)
                for index in 0..<3 {
                    let x = -8 - progress * 15 - Float(index) * 5
                    let y = Float(index - 1) * 5
                    let z = 10 + progress * 5
                    rig.props.append(PropDraw(
                        mesh: .gasCloud, anchor: .meshGroup,
                        local: t(x, y, z) * .scale(SIMD3(repeating: 1 + progress)),
                        color: gasGreen, opacity: alpha, unlit: true, transparent: true))
                }
            }
        ),

        // MARK: dead
        "dead": EmoteDefinition(
            duration: 10000,
            message: "{name} is dead",
            messageWhenNear: "{name} died in front of {target_name}",
            sound: nil,
            pose: { rig, _ in
                rig.bodyPivotPosition = SIMD3(0, 0, 4)
                rig.bodyPivotRotation.y = -.pi / 2

                rig.leftHandTarget = SIMD3(10, -25, 4)
                rig.rightHandTarget = SIMD3(10, 25, 4)
                rig.leftFootTarget = SIMD3(-15, -15, 4)
                rig.rightFootTarget = SIMD3(-15, 15, 4)
            }
        ),

        // MARK: cry
        "cry": EmoteDefinition(
            duration: 5000,
            message: "{name} is crying",
            messageWhenNear: "{name} cried on {target_name}",
            sound: "/media/violin.mp3",
            pose: { rig, ctx in
                rig.bodyPivotRotation.y = .pi / 16
                rig.leftHandTarget = SIMD3(16, -4, 20)
                rig.rightHandTarget = SIMD3(16, 4, 20)

                let start = rig.props.count
                var lastOpacity: Float = 1
                for index in 0..<6 {
                    // Note the absolute clock: unlike every other emote, the tears do not
                    // restart when the emote does.
                    let offset = Double(index) * (1000.0 / 6.0)
                    let progress = Float(mod(ctx.nowMs + offset, 1000) / 1000)

                    let size = 3.0 - progress
                    let z = 2 - pow(progress, 2) * 45
                    let x = 6 + progress * 20
                    let y = Float(index % 2 == 0 ? 1 : -1) * (8 + progress * 35)

                    lastOpacity = 1 - pow(progress, 2)
                    rig.props.append(PropDraw(
                        mesh: .tearLarge, anchor: .head,
                        local: t(x, y, z) * .scale(SIMD3(repeating: size)),
                        color: waterBlue, unlit: true, transparent: true))
                }
                sharedOpacity(&rig.props, from: start, lastOpacity)
            }
        ),

        // MARK: gritty
        "gritty": EmoteDefinition(
            duration: 5000,
            message: "{name} is doing the gritty",
            messageWhenNear: "{name} hit the gritty on {target_name}!",
            sound: nil,
            pose: { rig, ctx in
                let danceTime = ctx.elapsed / 150
                let swing = Float(sin(danceTime))
                let fastSwing = Float(sin(danceTime * 2))

                rig.bodyPivotPosition.z = 15.5 - abs(fastSwing * 4)
                rig.bodyPivotPosition.x = fastSwing * 2

                if swing > 0 {
                    rig.leftFootTarget = SIMD3(-2, -6, -13)
                    rig.rightFootTarget = SIMD3(10, 16, -13)
                } else {
                    rig.leftFootTarget = SIMD3(10, -16, -13)
                    rig.rightFootTarget = SIMD3(-2, 6, -13)
                }

                rig.leftHandTarget = SIMD3(10 + swing * 8, -6, 12)
                rig.rightHandTarget = SIMD3(10 - swing * 8, 6, 12)
            }
        ),

        // MARK: laugh
        "laugh": EmoteDefinition(
            duration: 5000,
            message: "{name} is rolling on the floor laughing",
            messageWhenNear: "{name} laughed at {target_name}",
            sound: "/media/laugh.mp3",
            pose: { rig, ctx in
                let laughTime = ctx.elapsed / 100
                let rock = Float(sin(laughTime) * 6)
                let kick = Float(sin(laughTime * 2) * 8)

                rig.bodyPivotPosition = SIMD3(0, rock, 8)
                rig.bodyPivotRotation.x = -.pi / 4 + rock * 0.05

                rig.leftHandTarget = SIMD3(10, -4, 12 + kick * 0.5)
                rig.rightHandTarget = SIMD3(10, 4, 12 - kick * 0.5)
                rig.leftFootTarget = SIMD3(15 + kick, -8, 8 - kick)
                rig.rightFootTarget = SIMD3(15 - kick, 8, 8 + kick)

                let progress = Float(mod(ctx.elapsed, 1000) / 1000)
                let opacity = 1 - progress
                for index in 0..<2 {
                    let y = index == 0 ? -5 - progress * 5 : 5 + progress * 5
                    rig.props.append(PropDraw(mesh: .tearSmall, anchor: .head, local: t(4, y, 0),
                                              color: waterBlue, opacity: opacity,
                                              unlit: true, transparent: true))
                }
            }
        ),

        // MARK: love
        "love": EmoteDefinition(
            duration: 5000,
            message: "{name} is in love",
            messageWhenNear: "{name} blew a kiss to {target_name}",
            sound: "/media/romance.mp3",
            pose: { rig, ctx in
                let age = ctx.elapsed
                let hover = Float(sin(age / 150) * 2)
                rig.bodyPivotPosition.z = 15.5 + hover

                rig.leftHandTarget = SIMD3(10, -2, 12)
                rig.rightHandTarget = SIMD3(10, 2, 12)

                let kick = Float(max(0, -sin(age / 150) * 8))
                rig.leftFootTarget = SIMD3(-kick, -3, -13 + kick * 0.5)
                rig.rightFootTarget = SIMD3(-kick, 3, -13 + kick * 0.5)

                let start = rig.props.count
                var lastOpacity: Float = 1
                for index in 0..<4 {
                    let offset = Double(index) * 500
                    let progress = Float(mod(age + offset, 2000) / 2000)
                    lastOpacity = 1 - pow(progress, 2)

                    let x = 20 + progress * 20
                    let y = sin(progress * .pi * 6 + Float(index)) * 6
                    let z = 15 + progress * 40

                    rig.props.append(PropDraw(mesh: .heart, anchor: .meshGroup,
                                              local: t(x, y, z),
                                              color: SIMD3(repeating: 1),
                                              unlit: true, transparent: true,
                                              billboardScale: 10 - progress * 2))
                }
                sharedOpacity(&rig.props, from: start, lastOpacity)
            }
        ),

        // MARK: tennis
        "tennis": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} is playing tennis",
            messageWhenNear: "{name} is playing tennis with {target_name}!",
            sound: nil,
            pose: { rig, ctx in
                rig.holding = "tennis_racket"

                rig.bodyPivotPosition.z = 15.5
                rig.leftFootTarget = SIMD3(-2, -8, -13)
                rig.rightFootTarget = SIMD3(2, 10, -13)

                let bounceCycle = mod(ctx.elapsed, 1000) / 1000
                let ballZ = Float(-2 + 1.5 + (4 * 50 * bounceCycle * (1 - bounceCycle)))

                rig.props.append(PropDraw(mesh: .tennisBall, anchor: .meshGroup,
                                          local: t(12, -10, ballZ), color: tennisYellow))

                // The free hand tracks the ball, staying just above it.
                rig.leftHandTarget = SIMD3(12, -10, max(-1, ballZ + 3))

                let sway = Float(sin(ctx.elapsed / 500) * 3)
                rig.rightHandTarget = SIMD3(8 + sway, 12, 15)
            },
            onEnd: { character in
                if character.holding == "tennis_racket" { character.holding = nil }
            }
        ),

        // MARK: rugby
        "rugby": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} is holding a rugby ball",
            messageWhenNear: "{name} passed the ball to {target_name}!",
            sound: nil,
            pose: { rig, _ in
                rig.rightHandTarget = SIMD3(12, 5, 12)
                rig.leftHandTarget = SIMD3(12, -5, 12)

                rig.props.append(PropDraw(mesh: .rugbyBall, anchor: .meshGroup,
                                          local: t(10, 0, 12) * .rotationX(.pi / 2),
                                          color: rugbyWhite))
            }
        ),

        // MARK: sit
        "sit": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} sat down",
            messageWhenNear: "{name} sat next to {target_name}",
            sound: nil,
            pose: { rig, _ in
                rig.bodyPivotPosition.z = 8
                rig.leftFootTarget = SIMD3(12, -6, -1)
                rig.rightFootTarget = SIMD3(12, 6, -1)
                rig.leftHandTarget = SIMD3(8, -12, 13)
                rig.rightHandTarget = SIMD3(8, 12, 13)
            }
        ),

        // MARK: swim
        "swim": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} is swimming",
            messageWhenNear: "{name} splashed {target_name}!",
            sound: "/media/splash.mp3",
            pose: { rig, ctx in
                let swimTime = ctx.elapsed / 200
                let bob = Float(sin(swimTime) * 3)

                rig.bodyPivotPosition = SIMD3(0, 0, 15.5 + bob)
                rig.bodyPivotRotation.y = .pi / 2
                // The only emote that poses the head separately — it holds it above the water.
                rig.headRotation.y = -.pi / 3

                let stroke = Float(sin(swimTime))
                let sweep = Float(cos(swimTime))
                rig.leftHandTarget = SIMD3(15 - stroke * 10, -8 - sweep * 10, 15.5)
                rig.rightHandTarget = SIMD3(15 - stroke * 10, 8 + sweep * 10, 15.5)

                let frogZ = sweep * 8
                let spread = max(0, stroke * 12)
                let frogX = Float(cos(swimTime * 2) * 3)
                rig.leftFootTarget = SIMD3(frogX, -4 - spread, -13 + frogZ)
                rig.rightFootTarget = SIMD3(frogX, 4 + spread, -13 + frogZ)

                let start = rig.props.count
                var lastOpacity: Float = 1
                for index in 0..<3 {
                    let offset = Double(index) * 400
                    let progress = Float(mod(ctx.elapsed + offset, 1200) / 1200)
                    lastOpacity = 1 - progress
                    rig.props.append(PropDraw(
                        mesh: .ripple, anchor: .meshGroup,
                        local: t(0, 0, 0.5) * .scale(SIMD3(repeating: 0.1 + progress * 3)),
                        color: waterBlue, unlit: true, transparent: true))
                }
                sharedOpacity(&rig.props, from: start, lastOpacity)
            }
        ),

        // MARK: sleep
        "sleep": EmoteDefinition(
            duration: 3_600_000,
            message: "{name} fell asleep",
            messageWhenNear: "{name} fell asleep next to {target_name}",
            sound: "/media/snoring.mp3",
            pose: { rig, ctx in
                rig.bodyPivotPosition = SIMD3(0, 0, 4)
                rig.bodyPivotRotation.x = -.pi / 2
                rig.bodyPivotPosition.z += Float(sin(ctx.elapsed / 500))

                rig.leftHandTarget = SIMD3(10, -15, 4)
                rig.rightHandTarget = SIMD3(10, 15, 4)
                rig.leftFootTarget = SIMD3(-15, -6, 4)
                rig.rightFootTarget = SIMD3(-15, 6, 4)

                // Three 'Z's, each three boxes, drifting away from the sleeper's head.
                let start = rig.props.count
                var lastOpacity: Float = 1
                for index in 0..<3 {
                    let offset = Double(index) * 800
                    let progress = Float(mod(ctx.elapsed + offset, 2400) / 2400)
                    lastOpacity = 1 - pow(progress, 2)

                    let letter = t(-5 - progress * 30,
                                   sin(progress * .pi * 4 + Float(index) * 2) * 8,
                                   10 + progress * 20)
                        * .scale(SIMD3(repeating: 0.5 + progress * 1.5))

                    rig.props.append(PropDraw(mesh: .zBarFlat, anchor: .meshGroup,
                                              local: letter * t(0, 0, 2),
                                              color: gasGreen, transparent: true))
                    rig.props.append(PropDraw(mesh: .zBarDiagonal, anchor: .meshGroup,
                                              local: letter * .rotationY(.pi / 4),
                                              color: gasGreen, transparent: true))
                    rig.props.append(PropDraw(mesh: .zBarFlat, anchor: .meshGroup,
                                              local: letter * t(0, 0, -2),
                                              color: gasGreen, transparent: true))
                }
                sharedOpacity(&rig.props, from: start, lastOpacity)
            }
        ),
    ]
}
