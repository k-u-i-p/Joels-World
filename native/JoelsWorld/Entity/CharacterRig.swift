import Foundation
import simd

/// Head GLBs, with the per-model scale and Z offset the artist's exports need.
/// Tables copied verbatim from `characters.js:24-45` — the order matters, because the head a
/// character gets is chosen by hashing its id into this list.
enum HeadTables {
    static let male: [(name: String, scale: Float, z: Float)] = [
        ("male_hair_long", 90, -10.5),
        ("male_hair_messy", 90, -10.5),
        ("male_hair_short", 90, -10.5),
        ("male_hair_short_2", 90, -10.5),
        ("male_hair_spiky", 90, -10.5),
        ("male_hair_bald", 90, -10.5),
    ]

    /// `female_hair_short_2` has no `.glb` on the asset host — it is kept because removing it
    /// would shift every other female character's deterministic head choice. Characters that
    /// hash onto it simply render headless, exactly as they do on the web.
    static let female: [(name: String, scale: Float, z: Float)] = [
        ("female_hair_bun", 85, -10.5),
        ("female_hair_long", 85, -10.5),
        ("female_hair_long_2", 85, -10.5),
        ("female_hair_long_3", 85, -10.5),
        ("female_hair_messy", 85, -10.5),
        ("female_hair_neat", 85, -10.5),
        ("female_hair_pigtails", 85, -10.5),
        ("female_hair_pigtails_2", 85, -10.5),
        ("female_hair_ponytail", 32, -10.5),
        ("female_hair_short", 85, -10.5),
        ("female_hair_short_2", 85, -10.5),
    ]

    static func entry(named: String) -> (name: String, scale: Float, z: Float)? {
        male.first { $0.name == named } ?? female.first { $0.name == named }
    }
}

/// `HAIR_COLOR_MAP` / `HAIR_COLORS` (`characters.js:60-67`). Order is load-bearing: the
/// fallback hair colour is picked by hashing the character id into `values`.
enum HairColors {
    static let map: [String: String] = [
        "blonde": "#efca41",
        "grey": "#5d5d5d",
        "black": "#222222",
        "red": "#9a3e10",
        "brown": "#6e2c00",
    ]
    static let values = ["#efca41", "#5d5d5d", "#222222", "#9a3e10", "#6e2c00"]
}

/// The primitive body parts, each of which maps to one procedural mesh and one colour.
enum RigPart: CaseIterable {
    case torso
    case leftUpperArm, leftLowerArm, leftHand
    case rightUpperArm, rightLowerArm, rightHand
    case leftUpperLeg, leftLowerLeg
    case rightUpperLeg, rightLowerLeg
}

/// Per-character palette. Defaults match `buildSkeletonMaterials` (`characters.js:770-779`).
struct RigColors {
    var skin: SIMD3<Float>
    var shirt: SIMD3<Float>
    var arm: SIMD3<Float>
    var pants: SIMD3<Float>
    var shoe: SIMD3<Float>
    var hair: SIMD3<Float>
}

/// Everything the renderer needs to draw one character this frame. All transforms are
/// world-space and already include the character's position, heading and scale.
struct RigPose {
    var colors: RigColors
    var parts: [(part: RigPart, transform: Float4x4)] = []

    /// Head GLB name and its fully-composed transform (group × the model's own offset,
    /// rotation and scale from `HeadTables`).
    var headModel: String?
    var headTransform = matrix_identity_float4x4

    /// Shoe GLB transforms, and the box transforms used until that model has loaded.
    var leftShoeModel = matrix_identity_float4x4
    var rightShoeModel = matrix_identity_float4x4
    var leftShoeBox = matrix_identity_float4x4
    var rightShoeBox = matrix_identity_float4x4

    /// Ground shadow blob, drawn blended just above the map.
    var shadowTransform = matrix_identity_float4x4

    /// World XY of the character, for the clip-mask raymarch pivot (`characters.js:1226`).
    var worldPivot: SIMD2<Float> = .zero

    /// Emote props for this frame, with `worldTransform` already composed.
    var props: [PropDraw] = []

    /// `HOLDABLE_OBJECTS` key and the transform its model is drawn with — the racket rides in
    /// the right hand (`characters.js:1176-1207`).
    var holding: String?
    var holdingTransform = matrix_identity_float4x4
}

/// Poses the procedural character rig.
///
/// Port of `buildSkeletonRig` / `buildSkeletonLimbs` / `updateCharacter3D` /
/// `resolveInverseKinematics` (`characters.js:786-1079`). Holds no Metal types: it emits
/// transforms, and `Renderer` owns the meshes they are drawn with.
///
/// The walk cycle, the idle sway and the emote poses (`Emotes.table`) all land here; anything
/// that outlives a frame is kept on the caller's `RigRuntime`.
enum CharacterRig {

    // Limb dimensions, from `buildSkeletonLimbs`.
    static let upperArmRadius: Float = 3.3, upperArmLength: Float = 8
    static let lowerArmRadius: Float = 3.3, lowerArmLength: Float = 8
    static let handRadius: Float = 3.8
    static let upperLegRadius: Float = 3.6, upperLegLength: Float = 12
    static let lowerLegRadius: Float = 3.6, lowerLegLength: Float = 9.7
    static let torsoRadius: Float = 9, torsoLength: Float = 8

    // Joint anchors, from `buildSkeletonRig`.
    private static let leftShoulder = SIMD3<Float>(3, -10, 26)
    private static let rightShoulder = SIMD3<Float>(3, 10, 26)
    private static let leftHip = SIMD3<Float>(0, -6, 10)
    private static let rightHip = SIMD3<Float>(0, 6, 10)

    // Neutral limb targets, reset every frame in `updateCharacter3D:1136-1139`.
    private static let baseLeftHand = SIMD3<Float>(9, -16, 12)
    private static let baseRightHand = SIMD3<Float>(9, 16, 12)
    private static let baseLeftFoot = SIMD3<Float>(2, -6, -13)
    private static let baseRightFoot = SIMD3<Float>(2, 6, -13)

    private static let bendNormalArmL = simd_normalize(SIMD3<Float>(0, 1, -0.5))
    private static let bendNormalArmR = simd_normalize(SIMD3<Float>(0, 1, 0.5))
    private static let bendNormalLegL = simd_normalize(SIMD3<Float>(0, -1, -0.2))
    private static let bendNormalLegR = simd_normalize(SIMD3<Float>(0, -1, 0.2))

    // MARK: - Appearance

    /// Deterministic string hash from `getConsistentRandom` (`characters.js:69-77`).
    /// Reproduces the JS `<<`/`|0` 32-bit wrap-around exactly so ids pick the same head here
    /// and on the web.
    static func consistentRandom(_ id: String, _ max: Int) -> Int {
        guard max > 0 else { return 0 }
        var hash: Int32 = 0
        for scalar in id.unicodeScalars {
            hash = (hash &<< 5) &- hash &+ Int32(truncatingIfNeeded: Int(scalar.value))
        }
        return Int(abs(Int64(hash))) % max
    }

    static func colors(for character: GameCharacter) -> RigColors {
        var hair = HairColors.values[consistentRandom("\(character.id)_color", HairColors.values.count)]
        if let named = character.hair_color, let mapped = HairColors.map[named] {
            hair = mapped
        }

        return RigColors(
            skin: parseHexColor(character.color ?? "#f1c40f"),
            shirt: parseHexColor(character.shirt_color ?? "#3498db"),
            arm: parseHexColor(character.arm_color ?? character.shirt_color ?? "#3498db"),
            pants: parseHexColor(character.pants_color ?? "#2c3e50"),
            shoe: parseHexColor(character.shoe_color ?? "#7f8c8d"),
            hair: parseHexColor(hair)
        )
    }

    /// Head selection from `applyHeadModel` (`characters.js:164-181`): a deterministic pick
    /// per id, overridden by an explicit `head` field, with a fallback for legacy values.
    static func headEntry(for character: GameCharacter) -> (name: String, scale: Float, z: Float) {
        let isFemale = character.gender == "female"
        let table = isFemale ? HeadTables.female : HeadTables.male

        var name = table[consistentRandom("\(character.id)_head", table.count)].name
        if let explicit = character.head {
            name = explicit.replacingOccurrences(of: ".glb", with: "")
        }

        if let entry = HeadTables.entry(named: name) { return entry }
        let fallback = isFemale ? "female_hair_ponytail" : "male_hair_short"
        return HeadTables.entry(named: fallback)!
    }

    // MARK: - Posing

    /// Builds this frame's pose.
    ///
    /// Port of `updateCharacter3D` (`characters.js:1081-1210`), in the same order: reset the
    /// body pivot's yaw, tear down a changed emote, restore the neutral limb targets, apply
    /// breathing, then *either* the walk cycle or the idle sway, then the emote on top, and
    /// finally the IK.
    ///
    /// - Parameters:
    ///   - legAnimationTime: the walk phase; `0` means standing (`characters.js:1157`).
    ///   - time: seconds, used for the idle breathing and sway.
    ///   - runtime: state that has to survive between frames, because three.js keeps it on the
    ///     retained `Object3D`s — see `RigRuntime`.
    ///   - cameraRight/cameraUp: world-space camera basis, so sprite props can face the viewer.
    static func pose(character: GameCharacter,
                     legAnimationTime: Double,
                     mapCharacterScale: Double,
                     time: Double,
                     runtime: RigRuntime,
                     cameraRight: SIMD3<Float> = SIMD3(1, 0, 0),
                     cameraUp: SIMD3<Float> = SIMD3(0, 0, 1)) -> RigPose {
        var pose = RigPose(colors: colors(for: character))

        // --- Root transform (`ensureThreeSetup` + `drawCharacter:1220`) ---
        let baseScale = Float(mapCharacterScale)
        let widthScale = Float((character.width ?? 40) / 40)
        let heightScale = Float((character.height ?? 40) / 40)
        let maxScale = baseScale * max(widthScale, heightScale)

        let renderX = Float(character.x)
        let renderY = Float(-character.y)          // render space negates world Y
        let renderZ = Float(character.z ?? 0)

        pose.worldPivot = SIMD2(renderX, renderY)

        let meshGroup = Float4x4.translation(SIMD3(renderX, renderY, renderZ))
            * Float4x4.rotationZ(Float(-(character.rotation ?? 0)) * degToRad)
            * Float4x4.scale(SIMD3(repeating: maxScale))

        // --- Emote teardown (`updateCharacter3D:1097-1115`) ---
        // Swapping emote drops the old one's props and puts the body pivot back at rest. The
        // `onEnd` side of this — clearing `holding` — belongs to the character record and is
        // handled by `GameState`, which owns it.
        let emote = character.emote
        let emoteDefinition = Emotes.definition(emote?.name)
        if runtime.currentEmoteName != emote?.name {
            runtime.resetForEmoteChange(to: emote?.name)
        }

        // `bodyPivot.rotation.z` is zeroed every frame; only x and y are ever posed.
        runtime.bodyPivotRotation.z = 0

        // --- Idle breathing and sway (`updateCharacter3D:1146-1155`) ---
        var hash = 0
        for scalar in "\(character.id)".unicodeScalars { hash += Int(scalar.value) }
        let idleTime = time + Double(hash) * 0.1

        let breath = Float(sin(idleTime * 2) * 0.02)
        runtime.bodyPivotRotation.y = Float(sin(idleTime * 1.5) * 0.05)

        // --- Walk cycle vs idle sway (`updateCharacter3D:1157-1174`) ---
        var leftHand = baseLeftHand
        var rightHand = baseRightHand
        var leftFoot = baseLeftFoot
        var rightFoot = baseRightFoot

        let isWalking = legAnimationTime > 0

        if isWalking {
            let legTimer = Float(legAnimationTime)
            runtime.bodyPivotPosition.z = 15.5 + cos(legTimer * 2) * 0.5
            runtime.bodyPivotPosition.x = cos(legTimer * 2) * 1.0

            // applyWalkCycle (`characters.js:981-1001`)
            let legSwing = sin(legTimer)
            let legVelocity = cos(legTimer)
            let armSwingX: Float = 6, armLiftZ: Float = 6
            let legStrideX: Float = 14, stepLiftZ: Float = 8

            leftHand.x += -legSwing * armSwingX
            leftHand.z += abs(legSwing) * armLiftZ
            rightHand.x += legSwing * armSwingX
            rightHand.z += abs(legSwing) * armLiftZ

            leftFoot.x += legSwing * legStrideX
            leftFoot.z += max(0, legVelocity) * stepLiftZ
            rightFoot.x += -legSwing * legStrideX
            rightFoot.z += max(0, -legVelocity) * stepLiftZ
        } else if emoteDefinition == nil {
            // Standing *and* not posed by an emote. When an emote is running the JS leaves the
            // body pivot wherever the emote put it, so a `wave` that started mid-stride keeps
            // the last frame's walk bob until it ends.
            runtime.bodyPivotPosition.z = 15.5
            runtime.bodyPivotPosition.x = 0

            // applyIdleSway (`characters.js:1003-1013`)
            let armSwayZ = Float(sin(idleTime * 2.0) * 0.6)
            let armSwayX = Float(cos(idleTime * 1.5) * 0.4)
            leftHand.z += armSwayZ
            leftHand.x += armSwayX
            rightHand.z += armSwayZ
            rightHand.x -= armSwayX
        }

        // --- Emote overrides (`applyEmoteOverrides:1015-1026`) ---
        var mutation = RigMutation(bodyPivotPosition: runtime.bodyPivotPosition,
                                   bodyPivotRotation: runtime.bodyPivotRotation,
                                   headRotation: runtime.headRotation,
                                   leftHandTarget: leftHand,
                                   rightHandTarget: rightHand,
                                   leftFootTarget: leftFoot,
                                   rightFootTarget: rightFoot,
                                   holding: character.holding)

        if let emoteDefinition, let emote {
            // Both branches kill the idle sway before posing.
            mutation.bodyPivotRotation.y = 0
            emoteDefinition.pose(&mutation,
                                 EmoteContext(elapsed: EventInterpreter.nowMilliseconds() - emote.startTime,
                                              nowMs: EventInterpreter.nowMilliseconds(),
                                              rotationDegrees: character.rotation ?? 0,
                                              worldPosition: SIMD3(renderX, renderY, renderZ),
                                              runtime: runtime))
        } else if character.emoji != nil {
            mutation.bodyPivotRotation.y = 0
            mutation.leftHandTarget = SIMD3(5, -20, 35)
            mutation.rightHandTarget = SIMD3(5, 20, 35)
        }

        runtime.bodyPivotPosition = mutation.bodyPivotPosition
        runtime.bodyPivotRotation = mutation.bodyPivotRotation
        runtime.headRotation = mutation.headRotation
        leftHand = mutation.leftHandTarget
        rightHand = mutation.rightHandTarget
        leftFoot = mutation.leftFootTarget
        rightFoot = mutation.rightFootTarget
        pose.holding = mutation.holding

        let bodyPivot = meshGroup
            * Float4x4.translation(runtime.bodyPivotPosition)
            * Float4x4.eulerXYZ(runtime.bodyPivotRotation.x,
                                runtime.bodyPivotRotation.y,
                                runtime.bodyPivotRotation.z)

        // --- Torso (`buildSkeletonRig:807-808`, breathing at :1153) ---
        let torso = bodyPivot
            * Float4x4.translation(SIMD3(0, 0, 20))
            * Float4x4.rotationX(.pi / 2)
            * Float4x4.scale(SIMD3(1 + breath, 1 + breath, 1))
        pose.parts.append((.torso, torso))

        // --- Head (`buildSkeletonRig:810-812` + `applyHeadModel:209-213`) ---
        // The head *group* — props parented to it (laser beams, tears, crumbs) inherit this
        // whole transform, including the non-uniform 0.65/0.65/0.7 scale.
        let headAnchor = bodyPivot
            * Float4x4.translation(SIMD3(2, 0, 36))
            * Float4x4.eulerXYZ(runtime.headRotation.x, runtime.headRotation.y, runtime.headRotation.z)
            * Float4x4.scale(SIMD3(0.65, 0.65, 0.7))

        let head = headEntry(for: character)
        pose.headModel = head.name
        pose.headTransform = headAnchor
            * Float4x4.translation(SIMD3(0, 0, head.z))
            * Float4x4.eulerXYZ(.pi / 2, .pi / 2, 0)
            * Float4x4.scale(SIMD3(repeating: head.scale))

        // --- Inverse kinematics (`resolveInverseKinematics:1028-1079`) ---
        // Ankles ride 2.3 above the foot target so calves do not punch through the shoes.
        var leftAnkle = leftFoot;  leftAnkle.z += 2.3
        var rightAnkle = rightFoot; rightAnkle.z += 2.3

        let leftElbow = IKSolver.solve(start: leftShoulder, end: &leftHand,
                                       l1: 8.5, l2: 8.5, bendingNormal: bendNormalArmL)
        let rightElbow = IKSolver.solve(start: rightShoulder, end: &rightHand,
                                        l1: 8.5, l2: 8.5, bendingNormal: bendNormalArmR)
        let leftKnee = IKSolver.solve(start: leftHip, end: &leftAnkle,
                                      l1: 12, l2: 9.7, bendingNormal: bendNormalLegL)
        let rightKnee = IKSolver.solve(start: rightHip, end: &rightAnkle,
                                       l1: 12, l2: 9.7, bendingNormal: bendNormalLegR)

        func append(_ part: RigPart, _ start: SIMD3<Float>, _ end: SIMD3<Float>) {
            if let local = IKSolver.segmentTransform(start: start, end: end) {
                pose.parts.append((part, bodyPivot * local))
            }
        }

        append(.leftUpperArm, leftShoulder, leftElbow)
        append(.leftLowerArm, leftElbow, leftHand)
        append(.rightUpperArm, rightShoulder, rightElbow)
        append(.rightLowerArm, rightElbow, rightHand)
        append(.leftUpperLeg, leftHip, leftKnee)
        append(.leftLowerLeg, leftKnee, leftAnkle)
        append(.rightUpperLeg, rightHip, rightKnee)
        append(.rightLowerLeg, rightKnee, rightAnkle)

        // Hands inherit the forearm's orientation.
        let leftForearmRotation = Float4x4(IKSolver.quaternionFromUnitY(to: safeDirection(from: leftElbow, to: leftHand)))
        let rightForearmRotation = Float4x4(IKSolver.quaternionFromUnitY(to: safeDirection(from: rightElbow, to: rightHand)))
        let leftHandAnchor = bodyPivot * Float4x4.translation(leftHand) * leftForearmRotation
        let rightHandAnchor = bodyPivot * Float4x4.translation(rightHand) * rightForearmRotation
        pose.parts.append((.leftHand, leftHandAnchor))
        pose.parts.append((.rightHand, rightHandAnchor))

        // --- Held model (`characters.js:1184-1206`) ---
        // `HOLDABLE_OBJECTS.tennis_racket` is offset (0,0,0), unrotated, scaled 3×.
        if pose.holding != nil {
            pose.holdingTransform = rightHandAnchor * Float4x4.scale(SIMD3(repeating: 3))
        }

        // --- Emote props ---
        // The anchors are only settled now, which is exactly when three.js resolves them: the
        // props are children of nodes the IK has just moved.
        pose.props = mutation.props
        for index in pose.props.indices {
            let anchor: Float4x4
            switch pose.props[index].anchor {
            case .head: anchor = headAnchor
            case .leftHand: anchor = leftHandAnchor
            case .rightHand: anchor = rightHandAnchor
            case .bodyPivot: anchor = bodyPivot
            case .meshGroup: anchor = meshGroup
            case .world: anchor = matrix_identity_float4x4
            }

            let placed = anchor * pose.props[index].local
            guard let spriteScale = pose.props[index].billboardScale else {
                pose.props[index].worldTransform = placed
                continue
            }

            // A `THREE.Sprite` keeps its parent's world position and scale but takes the
            // camera's orientation, so it always faces the viewer.
            let inheritedScale = simd_length(SIMD3(anchor.columns.0.x, anchor.columns.0.y, anchor.columns.0.z))
            let forward = simd_cross(cameraRight, cameraUp)
            var basis = matrix_identity_float4x4
            basis.columns.0 = SIMD4(cameraRight, 0)
            basis.columns.1 = SIMD4(cameraUp, 0)
            basis.columns.2 = SIMD4(forward, 0)

            let origin = SIMD3(placed.columns.3.x, placed.columns.3.y, placed.columns.3.z)
            pose.props[index].worldTransform = Float4x4.translation(origin)
                * basis
                * Float4x4.scale(SIMD3(repeating: inheritedScale * spriteScale))
        }

        // --- Shoes (`resolveInverseKinematics:1073-1078`, `loadSharedModels:86-89`) ---
        // The shoe yaws to follow the shin's pitch; the model itself is rotated out of its
        // Y-up export into the game's X-forward / Z-up frame.
        let leftShin = leftAnkle - leftKnee
        let rightShin = rightAnkle - rightKnee
        let leftShoeGroup = bodyPivot * Float4x4.translation(leftAnkle)
            * Float4x4.rotationY(atan2(leftShin.y, -leftShin.z))
        let rightShoeGroup = bodyPivot * Float4x4.translation(rightAnkle)
            * Float4x4.rotationY(atan2(rightShin.y, -rightShin.z))

        let shoeModelLocal = Float4x4.eulerXYZ(0, .pi / 2, .pi / 2) * Float4x4.scale(SIMD3(repeating: 0.65))
        pose.leftShoeModel = leftShoeGroup * shoeModelLocal
        pose.rightShoeModel = rightShoeGroup * shoeModelLocal
        pose.leftShoeBox = leftShoeGroup
        pose.rightShoeBox = rightShoeGroup

        // --- Shadow blob (`buildShadowBlob:903-921`) ---
        pose.shadowTransform = meshGroup * Float4x4.translation(SIMD3(0, 0, 0.5))

        return pose
    }

    private static func safeDirection(from: SIMD3<Float>, to: SIMD3<Float>) -> SIMD3<Float> {
        let delta = to - from
        let length = simd_length(delta)
        return length > 1e-6 ? delta / length : SIMD3(0, 1, 0)
    }
}
