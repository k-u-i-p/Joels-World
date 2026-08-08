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
///
/// This used to be eleven parts — a squashed capsule for the torso, a capsule per limb segment
/// and a sphere for each hand. Next to the head GLBs, which are modelled down to individual
/// strands of hair, a body with no neck, no shoulders, no waist and ball hands was the thing
/// giving the characters away. The additions are all joints: the places where two capsules meet
/// at an angle and, before this, simply crossed through one another.
enum RigPart: CaseIterable {
    case torso
    /// The hips, in trouser colour. Splitting it off the torso is what gives a character a
    /// waistline instead of one shirt-coloured tube from neck to knee.
    case pelvis
    case neck
    case leftShoulder, rightShoulder
    case leftUpperArm, leftLowerArm, leftElbow, leftHand
    case rightUpperArm, rightLowerArm, rightElbow, rightHand
    case leftUpperLeg, leftLowerLeg, leftKnee
    case rightUpperLeg, rightLowerLeg, rightKnee

    /// True for the parts that only smooth a joint over. They sit inside the silhouette the
    /// limbs and body already cast, so the shadow pass skips them: the shadow map is identical
    /// either way and it is the one pass that draws every character a second time.
    var isJointFiller: Bool {
        switch self {
        case .neck, .leftShoulder, .rightShoulder,
             .leftElbow, .rightElbow, .leftKnee, .rightKnee:
            return true
        default:
            return false
        }
    }
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

/// A last word on the pose, applied after the walk cycle and any emote.
///
/// The rig's poses all come from tables — a walk phase, an emote, an idle sway — which is fine
/// for the overworld, where nothing needs to point a limb at a moving object. A minigame does:
/// the tennis player's racket arm has to arrive at the ball. Rather than bolt a tennis-shaped
/// special case into `updateCharacter3D`, a caller can hand over a closure and pose whatever it
/// likes in the character's own local frame (+X forward, +Y left, +Z up).
///
/// `RigMutation` is what the emote table already mutates, so an override composes with an emote
/// rather than fighting it.
typealias RigOverride = (inout RigMutation) -> Void

/// Poses the procedural character rig.
///
/// Port of `buildSkeletonRig` / `buildSkeletonLimbs` / `updateCharacter3D` /
/// `resolveInverseKinematics` (`characters.js:786-1079`). Holds no Metal types: it emits
/// transforms, and `Renderer` owns the meshes they are drawn with.
///
/// The walk cycle, the idle sway and the emote poses (`Emotes.table`) all land here; anything
/// that outlives a frame is kept on the caller's `RigRuntime`.
enum CharacterRig {

    /// Bone lengths — joint to joint. `IKSolver` solves against these, **and every capsule is
    /// built to exactly this length**, which is the load-bearing part.
    ///
    /// A capsule is a cylinder of `length` with a hemisphere of `radius` on each end. Make the
    /// cylinder the length of the bone and each hemisphere is centred precisely on a joint, so
    /// the limb's cross-section at the joint is a full `radius` and a sphere of that radius
    /// placed there is exactly tangent — invisible on a straight limb, and filling the notch on
    /// a bent one. Make the cylinder any shorter and the cap is centred short of the joint, the
    /// limb pinches in before it gets there, and the joint sphere becomes a bulge sitting proud
    /// of it. That is the difference between an arm and a string of beads, and the arms had it
    /// wrong: 8 against a bone of 8.5. The legs were already right.
    static let armBone: Float = 8.5
    static let thighBone: Float = 12
    static let shinBone: Float = 9.7

    // Limb radii, from `buildSkeletonLimbs`.
    static let upperArmRadius: Float = 3.3, upperArmLength: Float = armBone
    static let lowerArmRadius: Float = 3.3, lowerArmLength: Float = armBone
    static let handRadius: Float = 3.8
    static let upperLegRadius: Float = 3.6, upperLegLength: Float = thighBone
    static let lowerLegRadius: Float = 3.6, lowerLegLength: Float = shinBone
    static let torsoRadius: Float = 9, torsoLength: Float = 8

    // Joint anchors, from `buildSkeletonRig`.
    private static let leftShoulder = SIMD3<Float>(3, -10, 26)
    private static let rightShoulder = SIMD3<Float>(3, 10, 26)
    private static let leftHip = SIMD3<Float>(0, -6, 10)
    private static let rightHip = SIMD3<Float>(0, 6, 10)

    // MARK: - Anatomy
    //
    // Everything below is new. The numbers are all in the rig's own frame — +X forward, +Y the
    // character's left, +Z up — measured from the body pivot, which stands 15.5 above the
    // ground. The old body was a capsule spanning z 7…33 with a half-width of 10.35 and a
    // half-depth of 5.85; the torso and pelvis profiles below are built to sit inside that same
    // envelope, so a character still fits the doorways, nameplates and clip mask it always did.
    // Widen them and you will find the walls first.

    /// Where the torso mesh is centred, and how it is squashed. Front-to-back is much thinner
    /// than side-to-side, which is what stops a character reading as a barrel from overhead —
    /// the angle almost every camera in this game looks from.
    static let torsoCentreZ: Float = 20
    static let torsoSquash = SIMD3<Float>(0.62, 1, 1.12)

    /// Shirt: hem, waist, chest and the slope up into the neck. Read bottom to top; the radius
    /// is before `torsoSquash`, so the widest point comes out at 9.3 × 1.12 = 10.4 across.
    static let torsoProfile: [(y: Float, radius: Float)] = [
        (-6.4, 0.0),    // closed, and buried inside the pelvis
        (-6.0, 7.2),
        (-4.6, 8.0),    // hem — wider than the shorts underneath it, so it hangs over them
        (-2.4, 7.9),    // waist — the narrowest point above the hips
        ( 0.8, 8.4),
        ( 4.0, 9.0),
        ( 6.6, 9.3),    // chest, widest
        ( 8.6, 9.2),
        (10.2, 8.6),    // shoulder yoke
        (11.4, 7.0),    // trapezius, sloping in
        (12.5, 5.0),
        (13.2, 3.6),    // neck root
        (13.6, 0.0),    // closed, under the neck
    ]

    /// Shorts. Its own solid rather than a colour band on the torso, because the two want
    /// different silhouettes: hips flare where a waist tucks in.
    static let pelvisCentreZ: Float = 11
    static let pelvisSquash = SIMD3<Float>(0.62, 1, 1.10)
    static let pelvisProfile: [(y: Float, radius: Float)] = [
        (-6.2, 0.0),
        (-5.6, 6.2),    // where the thighs leave
        (-4.0, 7.4),
        (-1.4, 8.0),    // hip, widest
        ( 1.2, 7.6),
        ( 3.2, 6.6),
        ( 4.4, 5.0),    // tucks in under the hem rather than pushing through it
        ( 5.0, 0.0),    // closed, under the shirt
    ]

    /// Neck: a short taper from the shoulders up into the head model, which swallows the top of
    /// it. Without one the head sits straight on the chest, which is the single most obvious
    /// tell that the body is not modelled to the same standard as the hair.
    static let neckBase = SIMD3<Float>(1, 0, 30.5)
    static let neckLength: Float = 7
    static let neckRadiusBottom: Float = 4.1
    static let neckRadiusTop: Float = 3.2
    /// How much of the head's rotation the neck takes. A head that turns while the neck stays
    /// bolted forward looks broken; taking a share of it reads as the neck twisting with it.
    static let neckFollowsHead: Float = 0.45

    /// How much of its radius each limb keeps at each end. The value at a joint is shared by
    /// both segments that meet there, so the two capsules line up exactly and the limb reads as
    /// one tapering shape rather than as two tubes of different thickness butted together.
    static let shoulderEndScale: Float = 1.12
    static let elbowEndScale: Float = 0.95
    static let wristEndScale: Float = 0.72
    static let hipEndScale: Float = 1.06
    static let kneeEndScale: Float = 0.95
    static let ankleEndScale: Float = 0.62

    /// Deltoid. Elongated along the humerus and turned to follow it, so it caps the shoulder
    /// rather than sitting on it as a ball — and so it covers the seam where the upper arm
    /// crosses into the chest.
    static let shoulderRadius: Float = 3.75
    static let shoulderStretch = SIMD3<Float>(1, 1.25, 1)

    /// Elbow and knee, at **exactly** the radius the limb has there.
    ///
    /// The first attempt made these deliberately wider, on the theory that a bulge reads as a
    /// joint. It does not: it reads as a balloon animal, three separate blobs stacked up an arm.
    /// Matched to the limb they are invisible on a straight limb — which is the point — and on a
    /// bent one they fill the notch the two capsule caps would otherwise leave on the inside of
    /// the bend. A wave emote is the case that needs them.
    static let elbowRadius: Float = upperArmRadius * elbowEndScale
    static let kneeRadius: Float = upperLegRadius * kneeEndScale

    /// The hand, revolved about the forearm so it has no roll to get wrong. `IKSolver`'s
    /// `quaternionFromUnitY` pins the direction a limb points and nothing else, so anything with
    /// a front and a back would spin freely about the wrist. A mitt does not care.
    ///
    /// y = 0 is the wrist and +Y runs out to the fingertips. The forearm is the one limb built
    /// with `domeEnd: false`, so it finishes flush at the wrist and everything past that belongs
    /// to the hand. The first attempt at this had a domed forearm reaching a full radius past
    /// the wrist and a mitt too short to cover it, which came out as a bracelet with a thumb
    /// poking through the end.
    static let handProfile: [(y: Float, radius: Float)] = [
        (-2.6, 0.0),
        (-2.0, 2.5),    // cuff, flush with the sleeve
        (-0.2, 3.05),
        ( 1.4, 3.15),   // knuckles, widest
        ( 3.0, 2.85),
        ( 4.4, 2.0),
        ( 5.2, 0.0),    // fingertips, past the forearm's cap at 3.3
    ]

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
    ///   - gait: how the legs are moving. `Gait.still` is standing; `Gait.walking(phase:)` is
    ///     the forward-only walk this used to be able to express and nothing more.
    ///   - time: seconds, used for the idle breathing and sway.
    ///   - runtime: state that has to survive between frames, because three.js keeps it on the
    ///     retained `Object3D`s — see `RigRuntime`.
    ///   - cameraRight/cameraUp: world-space camera basis, so sprite props can face the viewer.
    ///   - override: a final pass over the pose, for callers that need to aim a limb somewhere
    ///     the tables cannot describe. See `RigOverride`.
    static func pose(character: GameCharacter,
                     gait: Gait,
                     mapCharacterScale: Double,
                     time: Double,
                     runtime: RigRuntime,
                     cameraRight: SIMD3<Float> = SIMD3(1, 0, 0),
                     cameraUp: SIMD3<Float> = SIMD3(0, 0, 1),
                     override: RigOverride? = nil) -> RigPose {
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

        let isWalking = gait.isMoving || gait.phase > 0

        if isWalking {
            let legTimer = Float(gait.phase)
            let effort = Float(min(1.2, max(abs(gait.forward), abs(gait.lateral))))
            runtime.bodyPivotPosition.z = 15.5 + cos(legTimer * 2) * 0.5 * effort
            runtime.bodyPivotPosition.x = cos(legTimer * 2) * 1.0 * effort

            // applyWalkCycle (`characters.js:981-1001`), split into a forward stride and a
            // lateral one. Running dead ahead reproduces the original exactly — `forward` is 1
            // and `lateral` is 0, so every added term below falls away.
            let legSwing = sin(legTimer)
            let legVelocity = cos(legTimer)
            let armSwingX: Float = 6, armLiftZ: Float = 6
            let legStrideX: Float = 14, stepLiftZ: Float = 8
            // Feet stay inside the hips' 12-unit separation, so a side-step shuffles rather
            // than crossing its own legs over.
            let legStrideY: Float = 5.5

            let forward = Float(gait.forward)
            let lateral = Float(gait.lateral)

            leftHand.x += -legSwing * armSwingX * forward
            leftHand.z += abs(legSwing) * armLiftZ * effort
            rightHand.x += legSwing * armSwingX * forward
            rightHand.z += abs(legSwing) * armLiftZ * effort

            // Side-stepping throws the arms out for balance instead of pumping them.
            leftHand.y -= abs(lateral) * 4
            rightHand.y += abs(lateral) * 4

            leftFoot.x += legSwing * legStrideX * forward
            leftFoot.y += legSwing * legStrideY * lateral
            leftFoot.z += max(0, legVelocity) * stepLiftZ * effort

            rightFoot.x += -legSwing * legStrideX * forward
            rightFoot.y += -legSwing * legStrideY * lateral
            rightFoot.z += max(0, -legVelocity) * stepLiftZ * effort

            // Both feet drift towards the direction of travel, so the whole stance leads the
            // shuffle rather than the legs scissoring around a stationary centre.
            leftFoot.y += lateral * 2.5
            rightFoot.y += lateral * 2.5
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

        // --- Lean into the acceleration ---
        // Nothing in the JS does this; it is what sells the inertia `Locomotion` introduced.
        // Rotation about local Y tips "up" towards +X, so a positive angle leans forward; about
        // local X it tips towards −Y, so the sign flips for a bank to the character's left.
        // Capped well short of anything that would put a shoulder through the floor.
        let maxLean: Float = 0.22
        runtime.bodyPivotRotation.y += min(maxLean, max(-maxLean, Float(gait.leanForward) * maxLean))
        runtime.bodyPivotRotation.x = min(maxLean, max(-maxLean, Float(-gait.leanLateral) * maxLean))

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

        // The caller's last word, after the tables have had theirs.
        override?(&mutation)

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

        // --- Torso and pelvis ---
        // Both are lathes standing on +Y, so `rotationX(π/2)` turns them upright. The breath
        // swells the chest only — nobody's hips inflate when they inhale.
        let torso = bodyPivot
            * Float4x4.translation(SIMD3(0, 0, torsoCentreZ))
            * Float4x4.rotationX(.pi / 2)
            * Float4x4.scale(SIMD3(1 + breath, 1, 1 + breath))
        pose.parts.append((.torso, torso))

        let pelvis = bodyPivot
            * Float4x4.translation(SIMD3(0, 0, pelvisCentreZ))
            * Float4x4.rotationX(.pi / 2)
        pose.parts.append((.pelvis, pelvis))

        // --- Neck ---
        // Hinged at its base and taking a share of the head's rotation, so a nod or a turn
        // carries down into it instead of snapping the head off the shoulders.
        let neck = bodyPivot
            * Float4x4.translation(neckBase)
            * Float4x4.eulerXYZ(runtime.headRotation.x * neckFollowsHead,
                                runtime.headRotation.y * neckFollowsHead,
                                runtime.headRotation.z * neckFollowsHead)
            * Float4x4.translation(SIMD3(0, 0, neckLength / 2))
            * Float4x4.rotationX(.pi / 2)
        pose.parts.append((.neck, neck))

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
                                       l1: armBone, l2: armBone, bendingNormal: bendNormalArmL)
        let rightElbow = IKSolver.solve(start: rightShoulder, end: &rightHand,
                                        l1: armBone, l2: armBone, bendingNormal: bendNormalArmR)
        let leftKnee = IKSolver.solve(start: leftHip, end: &leftAnkle,
                                      l1: thighBone, l2: shinBone, bendingNormal: bendNormalLegL)
        let rightKnee = IKSolver.solve(start: rightHip, end: &rightAnkle,
                                       l1: thighBone, l2: shinBone, bendingNormal: bendNormalLegR)

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

        // --- Joints ---
        // Two capsules meeting at an angle cross through each other and leave a ridge where
        // their surfaces intersect. A ball fractionally wider than either turns that ridge into
        // a bulge, which is what an elbow, a knee and a shoulder actually look like — and it is
        // what lets the limbs taper without opening a step at the join.
        //
        // The deltoids are turned to follow the humerus so their long axis lies along the arm.
        // Elbows and knees are spheres and need no orientation.
        func joint(_ part: RigPart, at position: SIMD3<Float>, alignedTo direction: SIMD3<Float>? = nil) {
            var transform = bodyPivot * Float4x4.translation(position)
            if let direction {
                transform = transform * IKSolver.rotationFromUnitY(to: direction)
            }
            pose.parts.append((part, transform))
        }

        joint(.leftShoulder, at: leftShoulder,
              alignedTo: safeDirection(from: leftShoulder, to: leftElbow))
        joint(.rightShoulder, at: rightShoulder,
              alignedTo: safeDirection(from: rightShoulder, to: rightElbow))
        joint(.leftElbow, at: leftElbow)
        joint(.rightElbow, at: rightElbow)
        joint(.leftKnee, at: leftKnee)
        joint(.rightKnee, at: rightKnee)

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
            let twist = mutation.holdingRotation.map {
                Float4x4.eulerXYZ($0.x, $0.y, $0.z)
            } ?? matrix_identity_float4x4
            pose.holdingTransform = rightHandAnchor * twist * Float4x4.scale(SIMD3(repeating: 3))
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
