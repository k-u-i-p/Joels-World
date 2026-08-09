import Foundation
import simd

/// Retargeting: driving somebody else's skeleton with our own movement code.
///
/// `CharacterRig.pose` knows nothing about any of this. It produces what it always produced —
/// a world transform per `RigPart` — and this file is what lets a bought, rigged glTF character
/// wear those transforms without the rig, the gaits, the IK or the emotes changing at all.
///
/// **Why it cannot just copy the matrices across.** The engine's own body is built to the rig's
/// proportions, so `pose.parts[.leftUpperArm]` is literally where that bone goes. A bought model
/// has its own arm length, its own hip height and — nearly always — a different rest pose: this
/// one is a T-pose, arms straight out, where the engine's rest hangs the arms by the thighs.
/// Copying a matrix onto a bone of the wrong length tears the mesh off the joint.
///
/// **What it does instead.** Every transform `CharacterRig` emits has its **+Y along the bone**
/// — `IKSolver.segmentTransform` builds the limbs that way and the torso, pelvis and neck get a
/// `rotationX(π/2)` to match. So the direction each bone should point is knowable, and that is
/// all this takes. Positions come from forward kinematics down the model's *own* skeleton, so
/// the model keeps its own proportions, and the rest-pose mismatch never arises: we aim bones,
/// we do not replay a delta from a rest pose that does not match.
///
/// The consequence worth knowing: **the model's limb lengths win, not the rig's.** Where the rig
/// asks a hand to reach a point its arm can reach and the model's arm is shorter, the model's
/// hand stops short. Tennis is the one place that will show — see `HANDOFF`.

// MARK: - Canonical bones

/// The humanoid slots this engine knows how to drive, independent of what any one file calls
/// them. A model maps its own bones onto these; everything downstream speaks only this enum.
enum HumanoidBone: String, CaseIterable {
    case hips
    case spine, spine1, spine2
    case neck, head
    case leftShoulder, leftUpperArm, leftLowerArm, leftHand
    case rightShoulder, rightUpperArm, rightLowerArm, rightHand
    case leftUpperLeg, leftLowerLeg, leftFoot, leftToes
    case rightUpperLeg, rightLowerLeg, rightFoot, rightToes

    /// The next bone down the same limb, used to work out which way a bone points in the bind
    /// pose. A bone with no successor here takes its direction from its parent instead.
    var successor: HumanoidBone? {
        switch self {
        case .hips: return .spine
        case .spine: return .spine1
        case .spine1: return .spine2
        case .spine2: return .neck
        case .neck: return .head
        case .leftShoulder: return .leftUpperArm
        case .leftUpperArm: return .leftLowerArm
        case .leftLowerArm: return .leftHand
        case .rightShoulder: return .rightUpperArm
        case .rightUpperArm: return .rightLowerArm
        case .rightLowerArm: return .rightHand
        case .leftUpperLeg: return .leftLowerLeg
        case .leftLowerLeg: return .leftFoot
        case .leftFoot: return .leftToes
        case .rightUpperLeg: return .rightLowerLeg
        case .rightLowerLeg: return .rightFoot
        case .rightFoot: return .rightToes
        case .head, .leftHand, .rightHand, .leftToes, .rightToes: return nil
        }
    }

    /// Which `RigPart`'s transform aims this bone, if any.
    ///
    /// Bones with no driver are not left behind — they ride their parent rigidly, which is
    /// exactly right for fingers, toes and the spare spine links a bought rig has and this one
    /// does not. It is why a 52-bone model gets articulated fingers for free: the hand is aimed,
    /// and fifteen finger bones follow it as one piece.
    ///
    /// **Left is driven by `RigPart.right`, and that is not a typo.** `RigPart`'s sides are named
    /// for the *rig's* mirror image, not the character's: `CharacterRig.leftShoulder` is
    /// `(3, -10, 26)`, and local −Y is the character's **right**. The file's are named the way
    /// every other tool names them, for the character — `mixamorig:LeftArm` sits at engine +Y.
    /// Pairing them by name puts the model's left arm on the rig's right one and mirrors the
    /// whole character, which a symmetric walk hides completely and a wave gives away
    /// immediately: the boy waved with the wrong hand.
    var driver: RigPart? {
        switch self {
        case .hips: return .pelvis
        // The engine has one torso bone and a bought rig usually has three. Aiming all three at
        // the same target makes the spine straight rather than stacked, which is what the one
        // torso bone means anyway.
        case .spine, .spine1, .spine2: return .torso
        case .neck, .head: return .neck
        // **Not** the shoulder part, tempting as the name is. That part is a deltoid ball
        // aligned *down the humerus*, and a bought rig's `LeftShoulder` is the clavicle — a bone
        // that runs sideways from the spine. Aiming a clavicle down the arm swings the whole
        // shoulder girdle inward and buries the arm in the chest. The clavicle rides the spine,
        // which is very nearly what a real one does.
        case .leftShoulder: return nil
        case .leftUpperArm: return .rightUpperArm
        case .leftLowerArm: return .rightLowerArm
        case .leftHand: return .rightHand
        case .rightShoulder: return nil    // see `leftShoulder`
        case .rightUpperArm: return .leftUpperArm
        case .rightLowerArm: return .leftLowerArm
        case .rightHand: return .leftHand
        case .leftUpperLeg: return .rightUpperLeg
        case .leftLowerLeg: return .rightLowerLeg
        case .rightUpperLeg: return .leftUpperLeg
        case .rightLowerLeg: return .leftLowerLeg
        // No `RigPart` reaches the feet: the engine's ankle is the end of the leg IK and the
        // shoe is a separate GLB sitting on it. A bought model's foot rides the shin, which
        // points the toes as the shin swings — right for a walk, and the reason a run's
        // foot-plant looks stiffer here than the rest of the body does.
        case .leftFoot, .leftToes, .rightFoot, .rightToes: return nil
        }
    }

    /// **Roll is inherited, not taken from the driver's axes — and that is deliberate.**
    ///
    /// The obvious thing is to take the driver's whole rotation for the bones whose spin looks
    /// meaningful: the spine, whose roll is the character's facing, and the hands, whose
    /// transform `IKSolver.basis` builds as a real orthonormal basis rather than a shortest arc.
    /// It does not work, and the failure is worth writing down because it is invisible in the
    /// arithmetic and obvious the moment you render it.
    ///
    /// The rig's parts are **lathes standing on +Y**: the torso's +Z means "the way the lathe's
    /// seam faces", an artefact of how the mesh was swept. A bought bone's local axes mean
    /// whatever the rigger's software chose. Rolling one onto the other aligns two quantities
    /// that are not the same quantity, and for this model it yawed the entire character 90° —
    /// a boy standing side-on in a shot framed for his face.
    ///
    /// So: the **root** takes the driver's rotation whole, because its roll genuinely is the
    /// character's heading and there is no parent to inherit one from. Every other bone takes
    /// only its *direction* from the rig and its roll from its parent. A limb keeps a stable
    /// spin as it swings, which is what a shortest-arc driver cannot give it anyway.
    ///
    /// The exception is the palm, and it is the exception because there is **a landmark on both
    /// skeletons that means the same thing**: the thumb. See `rollTarget`.
    var inheritsRoll: Bool { rollTarget == nil }

    /// Where this bone's `HumanoidSkeleton.rollAxis` should be turned to face, as a direction in
    /// the **driver part's own frame** — or nil for a bone that inherits its parent's roll.
    ///
    /// This is the one honest way to move a roll across two skeletons that share no rest pose:
    /// not by aligning axis conventions, which mean different things on either side (see
    /// `inheritsRoll`), but by naming a **physical feature both models have** and turning one
    /// onto the other. For a hand that feature is the thumb, and it is measurable at both ends:
    ///
    /// - On the model, from its own thumb bone — every rigged humanoid has one, and it is called
    ///   `thumb` in every naming scheme in `HumanoidNaming.aliases`.
    /// - On the rig, it is **+Z of the hand part's frame, and a constant**. `CharacterRig.Hand`
    ///   roots the thumb at `(-0.30, 1.30, 1.60)` and splays it "out towards +Z, the thumb side";
    ///   the left hand is that mesh mirrored in X, which leaves +Z alone. So both hands agree,
    ///   and the `Hand.restRoll` quarter-turn is already inside the part transform, so a model's
    ///   thumb lands exactly where the engine's own does.
    ///
    /// Nothing else on a humanoid has a landmark this clean, which is why nothing else takes a
    /// roll. A spine has no thumb.
    var rollTarget: SIMD3<Float>? {
        switch self {
        case .leftHand, .rightHand: return SIMD3(0, 0, 1)
        default: return nil
        }
    }
}

// MARK: - Name matching

enum HumanoidNaming {
    /// Reduce a file's bone name to something comparable: drop the namespace, the exporter's
    /// numeric suffix, and every separator.
    ///
    /// `mixamorig:LeftForeArm_010` → `leftforearm`. The `_010` matters: this model came through
    /// FAB's FBX converter, which numbers every node, so a bare equality test against
    /// `mixamorig:LeftForeArm` matches nothing at all.
    static func normalize(_ raw: String) -> String {
        var name = raw.lowercased()
        if let colon = name.lastIndex(of: ":") { name = String(name[name.index(after: colon)...]) }
        // Trailing exporter index: `_010`, `_end_066`. Strip repeatedly, and strip a trailing
        // `end` with it, so `..._end_066` and `..._066` both land on the same stem.
        while true {
            if let underscore = name.lastIndex(of: "_") {
                let tail = String(name[name.index(after: underscore)...])
                if !tail.isEmpty, tail.allSatisfy(\.isNumber) || tail == "end" {
                    name = String(name[..<underscore])
                    continue
                }
            }
            break
        }
        return name.filter { $0.isLetter || $0.isNumber }
    }

    /// Aliases per canonical bone, already normalised. Covers the naming this project is
    /// realistically going to meet: Mixamo (and anything Mixamo-derived, which is most of the
    /// asset stores), Blender/Rigify, Unity's humanoid names, and the VRM spec.
    static let aliases: [HumanoidBone: [String]] = [
        .hips:          ["hips", "hip", "pelvis", "bip01pelvis", "cog", "root", "torso"],
        .spine:         ["spine", "spine0", "spine01", "abdomen", "chestlower"],
        .spine1:        ["spine1", "spine02", "chest", "upperchest0"],
        .spine2:        ["spine2", "spine03", "upperchest", "chestupper"],
        .neck:          ["neck", "neck0", "neck01"],
        .head:          ["head"],

        .leftShoulder:  ["leftshoulder", "lshoulder", "shoulderl", "leftcollar", "claviclel", "lcollar"],
        .leftUpperArm:  ["leftarm", "larm", "leftupperarm", "upperarml", "upperarml", "lupperarm"],
        .leftLowerArm:  ["leftforearm", "lforearm", "leftlowerarm", "lowerarml", "forearml"],
        .leftHand:      ["lefthand", "lhand", "handl"],

        .rightShoulder: ["rightshoulder", "rshoulder", "shoulderr", "rightcollar", "clavicler", "rcollar"],
        .rightUpperArm: ["rightarm", "rarm", "rightupperarm", "upperarmr", "rupperarm"],
        .rightLowerArm: ["rightforearm", "rforearm", "rightlowerarm", "lowerarmr", "forearmr"],
        .rightHand:     ["righthand", "rhand", "handr"],

        .leftUpperLeg:  ["leftupleg", "leftupperleg", "lupleg", "thighl", "lthigh", "upperlegl"],
        .leftLowerLeg:  ["leftleg", "leftlowerleg", "lleg", "shinl", "lshin", "calfl", "lowerlegl"],
        .leftFoot:      ["leftfoot", "lfoot", "footl", "anklel"],
        .leftToes:      ["lefttoebase", "lefttoes", "ltoe", "toel", "lefttoe"],

        .rightUpperLeg: ["rightupleg", "rightupperleg", "rupleg", "thighr", "rthigh", "upperlegr"],
        .rightLowerLeg: ["rightleg", "rightlowerleg", "rleg", "shinr", "rshin", "calfr", "lowerlegr"],
        .rightFoot:     ["rightfoot", "rfoot", "footr", "ankler"],
        .rightToes:     ["righttoebase", "righttoes", "rtoe", "toer", "righttoe"],
    ]

    private static let lookup: [String: HumanoidBone] = {
        var map: [String: HumanoidBone] = [:]
        for (bone, names) in aliases {
            for name in names where map[name] == nil { map[name] = bone }
        }
        return map
    }()

    /// Is this joint part of a thumb?
    ///
    /// Not a canonical bone — nothing drives a thumb — but the skeleton measures two things off
    /// one at load, so it has to be able to pick it out of a hand's children. Every naming scheme
    /// this engine meets spells it `thumb`; Mixamo's is `LeftHandThumb1`, Rigify's `thumb.01.L`,
    /// and `normalize` has already flattened both.
    static func isThumb(_ rawName: String) -> Bool { normalize(rawName).contains("thumb") }

    /// The canonical bone a file's joint name means, or nil for a joint this engine does not
    /// drive — every finger, and the `HeadTop_End` markers exporters leave behind.
    static func bone(for rawName: String, overrides: [String: HumanoidBone] = [:]) -> HumanoidBone? {
        let normalized = normalize(rawName)
        if let override = overrides[normalized] ?? overrides[rawName] { return override }
        return lookup[normalized]
    }
}

// MARK: - Per-model profile

/// The handful of things about a model that cannot be worked out from the file.
///
/// Everything else — scale, bone directions, the skeleton tree — is measured on load. This is
/// deliberately small: a Mixamo-named, Y-up, +Z-facing character needs `.standard` and nothing
/// written down at all.
struct HumanoidProfile {
    /// Which way is up in the file. glTF says +Y and nearly every exporter obeys.
    var upAxis: SIMD3<Float> = SIMD3(0, 1, 0)
    /// Which way the character faces in the file, in the file's own axes.
    var forwardAxis: SIMD3<Float> = SIMD3(0, 0, 1)
    /// How to size the model against the rig.
    ///
    /// `hips` — the default — matches the model's **hip height** to the rig's. It is the one
    /// that puts the feet on the floor: `CharacterRig.bodyPivotHeight` is derived from leg
    /// length so that the soles land at ground level, so a model whose hips are at the rig's hip
    /// height has legs that reach the floor. Matching total height instead leaves a
    /// big-headed character standing on tiptoe or shin-deep in it, because the head is a
    /// different fraction of the whole in every stylised model.
    ///
    /// `height` — match `targetHeight` overall. Right when a model has to fit a doorway more
    /// than it has to stand convincingly.
    enum ScaleMode: String { case hips, height }
    var scaleMode: ScaleMode = .hips

    /// Height in engine units for `ScaleMode.height`. `CharacterRig` builds its own body 66
    /// units tall (`CharacterRig.swift` — "a character 66 units tall").
    var targetHeight: Float = 66
    /// Bone name (raw or normalised) → canonical bone, for a rig this engine cannot name-match.
    var overrides: [String: HumanoidBone] = [:]

    static let standard = HumanoidProfile()

    /// Decode from the JSON that sits beside a model, so a new character is a data change.
    /// Every key is optional.
    init(json: [String: Any] = [:]) {
        if let axis = json["upAxis"] as? [Double], axis.count == 3 {
            upAxis = SIMD3(Float(axis[0]), Float(axis[1]), Float(axis[2]))
        }
        if let axis = json["forwardAxis"] as? [Double], axis.count == 3 {
            forwardAxis = SIMD3(Float(axis[0]), Float(axis[1]), Float(axis[2]))
        }
        if let height = json["targetHeight"] as? Double { targetHeight = Float(height) }
        if let mode = (json["scaleMode"] as? String).flatMap(ScaleMode.init(rawValue:)) {
            scaleMode = mode
        }
        if let map = json["boneOverrides"] as? [String: String] {
            for (key, value) in map {
                if let bone = HumanoidBone(rawValue: value) {
                    overrides[HumanoidNaming.normalize(key)] = bone
                } else {
                    Log.render("humanoid profile: '\(value)' is not a bone name (key '\(key)')")
                }
            }
        }
    }
}

// MARK: - The retargeted skeleton

/// A bought skeleton, measured once and turned into everything `solve` needs per frame.
///
/// All of it is in **engine space**: Z-up, facing +X, scaled so the model stands
/// `profile.targetHeight` tall. Doing that conversion here rather than at draw time means the
/// per-frame path never has to think about the file's axes again.
final class HumanoidSkeleton {

    /// Joints in an order that always visits a parent before its children, so forward kinematics
    /// is one pass with no recursion.
    let order: [Int]
    let parents: [Int?]
    /// Rest transform of each joint relative to its parent, in engine space.
    let localBind: [Float4x4]
    /// `bind⁻¹` in engine space — what the skinning shader multiplies by.
    let inverseBind: [Float4x4]
    /// Which canonical bone each joint is, where it is one we drive.
    let bone: [HumanoidBone?]
    /// The joint's own long axis, in its bind-local frame. Constant, and the whole trick: it is
    /// what lets a bone be *aimed* without knowing anything about the rest pose it came from.
    let boneAxis: [SIMD3<Float>]
    /// A second axis, perpendicular to `boneAxis` and in the same bind-local frame, for the few
    /// bones whose spin about their own length is worth carrying across — today the hands, where
    /// it points at the thumb. `.zero` for every bone that inherits its parent's roll.
    let rollAxis: [SIMD3<Float>]
    let jointCount: Int
    /// Height the mesh measured, in the file's own units, before scaling.
    let measuredHeight: Float
    /// Uniform scale taken from the file's units to engine units.
    let normalizeScale: Float
    /// File space → engine space. **The vertices have to be put through this too**: `inverseBind`
    /// inverts a bind pose that has already been normalised, so feeding it raw file-space
    /// positions scales the model twice and turns it inside out.
    let normalizeTransform: Float4x4

    /// Joints whose canonical bone we recognised, for reporting.
    private(set) var matched: [HumanoidBone: Int] = [:]

    /// Where the model's leg roots sit relative to its own hips joint, in the hips' bind-local
    /// frame and in engine units.
    ///
    /// This is what the root is anchored by. Anchoring on the hips joint itself does not work:
    /// every rig puts it at a slightly different height in the pelvis, and `RigPart.pelvis`'s
    /// transform is the centre of a *lathe*, lower again. Matching where the legs hang from
    /// instead is a landmark both skeletons agree on, and it is the one that decides whether the
    /// feet reach the floor.
    let hipsToLegMid: SIMD3<Float>

    /// Canonical bones whose model sits on the opposite side of the character from the `RigPart`
    /// driving them. Empty is what you want; anything in it means a mirrored character.
    let mirrored: [HumanoidBone]

    /// The rig at rest, built once. Two things here want it — the hip height every model is
    /// scaled by, and the side check — and `bindPose` runs the whole IK to produce it.
    static let engineBind = CharacterRig.bindPose()

    /// Hip height above the soles at rest, taken from `CharacterRig.bindPose`. The number the
    /// model is scaled to under `ScaleMode.hips`.
    static let engineHipHeight: Float =
        (engineBind.leftLeg.root.z + engineBind.rightLeg.root.z) * 0.5

    init(mesh: GLTFSkinnedMesh, profile: HumanoidProfile) {
        let count = mesh.jointNames.count
        jointCount = count
        parents = mesh.parents

        // --- Order: parents before children ---
        var depth = [Int](repeating: 0, count: count)
        for index in 0..<count {
            var d = 0
            var walk = mesh.parents[index]
            var guardCount = 0
            while let parent = walk, guardCount < count {
                d += 1; walk = mesh.parents[parent]; guardCount += 1
            }
            depth[index] = d
        }
        order = (0..<count).sorted { depth[$0] == depth[$1] ? $0 < $1 : depth[$0] < depth[$1] }

        // --- Name matching ---
        // Before scaling, because the landmark the model is scaled by is its hips.
        var bones = [HumanoidBone?](repeating: nil, count: count)
        var found: [HumanoidBone: Int] = [:]
        for index in 0..<count {
            guard let bone = HumanoidNaming.bone(for: mesh.jointNames[index],
                                                 overrides: profile.overrides) else { continue }
            // A rig with two joints claiming one slot — a `Root` above `Hips`, say — should use
            // the one nearer the leaves, so prefer the deeper of the two.
            if let existing = found[bone], depth[existing] >= depth[index] { continue }
            found[bone] = index
        }
        for (bone, index) in found { bones[index] = bone }
        bone = bones
        matched = found

        // --- Normalisation into engine space ---
        // Height is measured on the *mesh*, not the skeleton: the top joint of a Mixamo rig is
        // inside the skull and the lowest is the ankle, so a skeleton-derived height is short by
        // most of a head and a whole foot, and the character comes out oversized to compensate.
        let up = simd_normalize(profile.upAxis)
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for vertex in mesh.vertices {
            let along = simd_dot(vertex.position, up)
            lowest = min(lowest, along); highest = max(highest, along)
        }
        measuredHeight = max(highest - lowest, 1e-4)

        // The file's own bind pose, before any scaling, so the hip landmark can be measured in
        // the file's units and turned into the scale that lands it at the rig's hip height.
        let rawBind = mesh.inverseBind.map { $0.inverse }
        func rawPosition(_ index: Int) -> SIMD3<Float> {
            let column = rawBind[index].columns.3
            return SIMD3(column.x, column.y, column.z)
        }
        /// Where the legs hang from, in the file's units — the landmark both skeletons share.
        func rawLegMid() -> SIMD3<Float>? {
            switch (found[.leftUpperLeg], found[.rightUpperLeg]) {
            case let (left?, right?): return (rawPosition(left) + rawPosition(right)) * 0.5
            case let (single?, nil), let (nil, single?): return rawPosition(single)
            default: return found[.hips].map(rawPosition)
            }
        }

        switch profile.scaleMode {
        case .height:
            normalizeScale = profile.targetHeight / measuredHeight
        case .hips:
            if let legMid = rawLegMid() {
                let hipAboveSoles = simd_dot(legMid, up) - lowest
                normalizeScale = hipAboveSoles > 1e-4
                    ? Self.engineHipHeight / hipAboveSoles
                    : profile.targetHeight / measuredHeight
            } else {
                // No legs matched — nothing to anchor on, so fall back rather than divide by a
                // landmark that is not there.
                normalizeScale = profile.targetHeight / measuredHeight
            }
        }

        // Rotation taking the file's (forward, up) onto the engine's (+X, +Z). `CharacterRig`'s
        // rest stands at the origin facing +X with +Z up.
        let forward = simd_normalize(profile.forwardAxis - up * simd_dot(profile.forwardAxis, up))
        let side = simd_cross(up, forward)
        // Columns are where the file's axes land: forward → +X, side → +Y, up → +Z.
        var axes = matrix_identity_float4x4
        axes.columns.0 = SIMD4(forward.x, side.x, up.x, 0)
        axes.columns.1 = SIMD4(forward.y, side.y, up.y, 0)
        axes.columns.2 = SIMD4(forward.z, side.z, up.z, 0)
        let normalize = Float4x4.scale(SIMD3(repeating: normalizeScale)) * axes
        normalizeTransform = normalize

        // --- Bind pose ---
        //
        // **Orthonormalised, and it is load-bearing.** A joint's bind transform carries whatever
        // scale its node chain had, and an FBX→glTF conversion routinely leaves a 0.01 on the
        // root — this file does. `solve` builds each joint's world transform from a *rotation*
        // and a position, with no scale in it, so leaving scale in the bind here makes
        // `jointWorld × bind⁻¹` a matrix that is part inverse-scale and part not: the joints land
        // in the right places and the flesh around them comes out several times too big.
        //
        // Dropping it costs nothing real. A bind pose is a skeleton at rest; per-bone scale in
        // one is an exporter artefact, not something an artist meant.
        var bindWorld = [Float4x4](repeating: matrix_identity_float4x4, count: count)
        for index in 0..<count {
            let raw = normalize * mesh.inverseBind[index].inverse
            var rigid = Float4x4.from3x3(raw.orthonormalRotation)
            rigid.columns.3 = raw.columns.3
            bindWorld[index] = rigid
        }
        inverseBind = bindWorld.map { $0.inverse }

        var local = [Float4x4](repeating: matrix_identity_float4x4, count: count)
        for index in 0..<count {
            if let parent = mesh.parents[index] {
                local[index] = bindWorld[parent].inverse * bindWorld[index]
            } else {
                local[index] = bindWorld[index]
            }
        }
        localBind = local

        // --- The hip landmark, in engine units ---
        // Held in the hips' own frame so it turns with the character rather than having to be
        // re-derived every time the pelvis rotates.
        func position(of index: Int) -> SIMD3<Float> {
            let column = bindWorld[index].columns.3
            return SIMD3(column.x, column.y, column.z)
        }
        if let hips = found[.hips] {
            var legMid = position(of: hips)
            switch (found[.leftUpperLeg], found[.rightUpperLeg]) {
            case let (left?, right?): legMid = (position(of: left) + position(of: right)) * 0.5
            case let (single?, nil), let (nil, single?): legMid = position(of: single)
            default: break
            }
            hipsToLegMid = bindWorld[hips].orthonormalRotation.transpose * (legMid - position(of: hips))
        } else {
            hipsToLegMid = .zero
        }

        // --- Bone axes ---
        // Where each joint points in the bind pose, expressed in its own local frame. Measured
        // from the joint to the next one down the same limb; a bone with no successor (a hand,
        // the head) borrows its parent's direction, because a leaf joint has no length of its
        // own to measure.
        var axesOut = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: count)
        func children(of index: Int) -> [Int] {
            (0..<count).filter { mesh.parents[$0] == index }
        }
        func worldDirection(of index: Int) -> SIMD3<Float>? {
            guard let bone = bones[index] else { return nil }
            if let successor = bone.successor, let match = found[successor] {
                let delta = position(of: match) - position(of: index)
                let length = simd_length(delta)
                return length > 1e-5 ? delta / length : nil
            }
            // No named successor. Fall back to the file's own children, which is right for a rig
            // with bones we do not name — a `Head` whose only child is `HeadTop_End` still knows
            // which way is up.
            //
            // **The centroid of them, not the first one**, and the thumb left out where there is
            // anything else. It matters in exactly one place and it matters a lot: a hand's first
            // child in file order is `LeftHandThumb1`, so taking the first child aimed the palm's
            // long axis straight down the thumb and stood the whole hand a third of a turn out of
            // true. A thumb leaves the palm's plane by design; the fingers are the hand's length.
            let all = children(of: index)
            let fingers = all.filter { !HumanoidNaming.isThumb(mesh.jointNames[$0]) }
            let used = fingers.isEmpty ? all : fingers
            guard !used.isEmpty else { return nil }
            let centroid = used.reduce(SIMD3<Float>.zero) { $0 + position(of: $1) } / Float(used.count)
            let delta = centroid - position(of: index)
            let length = simd_length(delta)
            return length > 1e-5 ? delta / length : nil
        }
        for index in order {
            var direction = worldDirection(of: index)
            if direction == nil, let parent = mesh.parents[index] {
                // A leaf: take the parent's world direction, already computed because `order`
                // visits parents first.
                let rotation = bindWorld[parent].orthonormalRotation
                direction = rotation * axesOut[parent]
            }
            guard let direction else { continue }
            // Into the joint's own frame, where it stays constant however the joint is posed.
            axesOut[index] = simd_normalize(bindWorld[index].orthonormalRotation.transpose * direction)
        }
        boneAxis = axesOut

        // --- Roll axes ---
        // Measured the same way and for the same reason: a direction taken off the bind pose,
        // held in the joint's own frame so it survives being posed. `HumanoidBone.rollTarget` is
        // the other half — where this axis is turned to face each frame.
        var rollOut = [SIMD3<Float>](repeating: .zero, count: count)
        for index in 0..<count {
            guard let bone = bones[index], bone.rollTarget != nil,
                  let thumb = children(of: index).first(where: {
                      HumanoidNaming.isThumb(mesh.jointNames[$0])
                  })
            else { continue }
            let toThumb = position(of: thumb) - position(of: index)
            let local = bindWorld[index].orthonormalRotation.transpose * toThumb
            // Square it up against the bone's own length. The two have to be exactly
            // perpendicular for the roll to be a roll: `HumanoidRetargeter` turns this axis onto
            // its target with the same shortest arc it aims a bone with, and a shortest arc
            // between two vectors already square to the bone is a rotation about the bone and
            // nothing else. A thumb that is 20° forward of the palm would otherwise re-aim it.
            let axis = axesOut[index]
            let perpendicular = local - axis * simd_dot(local, axis)
            if simd_length(perpendicular) > 1e-4 { rollOut[index] = simd_normalize(perpendicular) }
        }
        rollAxis = rollOut

        // --- The side check ---
        //
        // **Does each bone end up on the side of the body the rig is driving it from?** It is one
        // line of arithmetic per limb and it is here because the answer was *no* for a whole
        // session and nobody could see it: a mirrored character walks, runs, stands and idles
        // perfectly, because every one of those is symmetric. It took a wave — an emote that uses
        // one arm — before anything looked wrong, and by then the mirror had been under every
        // other measurement in this file.
        //
        // Both sides of the comparison are rest poses about the character's own centre line, so
        // the sign of Y is all it takes. Bones near the middle say nothing and are left out.
        var swapped: [HumanoidBone] = []
        for bone in HumanoidBone.allCases {
            guard let index = found[bone], let part = bone.driver,
                  let rest = Self.engineBind.bones[part] else { continue }
            let model = position(of: index).y
            let rig = rest.columns.3.y
            guard abs(model) > 1, abs(rig) > 1 else { continue }
            if (model < 0) != (rig < 0) { swapped.append(bone) }
        }
        mirrored = swapped
    }

    /// One line per recognised bone, for the lab's report and for working out why a model came
    /// out in a heap.
    func describe(jointNames: [String]) -> String {
        var lines: [String] = []
        lines.append("skeleton: \(jointCount) joints, "
                     + "measured \(String(format: "%.3f", measuredHeight)) file units "
                     + "→ ×\(String(format: "%.2f", normalizeScale))")
        var unmatched = 0
        for bone in HumanoidBone.allCases {
            if let index = matched[bone] {
                var note = bone.driver == nil ? "  (rides its parent)" : ""
                if bone.rollTarget != nil {
                    // Worth a line of its own: a hand with no thumb bone under it still draws,
                    // it just hangs at whatever roll the forearm carries it to — which is the
                    // exact symptom this measurement exists to cure, and impossible to tell from
                    // a bad measurement by looking.
                    note += rollAxis[index] == .zero ? "  (no thumb — palm rides the forearm)"
                                                     : "  (palm rolled by its thumb)"
                }
                lines.append("  \(bone.rawValue) ← \(jointNames[index])" + note)
            } else {
                lines.append("  \(bone.rawValue) — MISSING")
                unmatched += 1
            }
        }
        lines.append("  \(jointCount - matched.count) unnamed joints ride their parents")
        if unmatched > 0 { lines.append("  \(unmatched) canonical bones unmatched") }
        if !mirrored.isEmpty {
            lines.append("  MIRRORED: \(mirrored.map(\.rawValue).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Solving a frame

/// Turns one `RigPose` into one skinning matrix per joint of a bought skeleton.
///
/// Held per drawn character rather than per model, because the scratch arrays are the whole
/// cost of it and reusing them keeps this off the allocator in the draw loop.
final class HumanoidRetargeter {
    private let skeleton: HumanoidSkeleton
    private var worldTransforms: [Float4x4]
    private var driverRotations = [RigPart: simd_float3x3]()
    private var driverOrigins = [RigPart: SIMD3<Float>]()

    /// The rest orientation of a `CharacterRig` part that stands upright: `rotationX(π/2)`, which
    /// is what the torso, pelvis and neck are built with so their lathe's +Y points up the body.
    private static let uprightRest = Float4x4.rotationX(.pi / 2).orthonormalRotation

    init(skeleton: HumanoidSkeleton) {
        self.skeleton = skeleton
        worldTransforms = [Float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointCount)
    }

    /// Fill `out` with `jointWorld × bind⁻¹` per joint — exactly what `characterVertex` already
    /// multiplies a vertex by. `out` is resized if it is short.
    func solve(pose: RigPose, into out: inout [Float4x4]) {
        driverRotations.removeAll(keepingCapacity: true)
        driverOrigins.removeAll(keepingCapacity: true)
        for (part, transform) in pose.parts {
            driverRotations[part] = transform.orthonormalRotation
            let origin = transform.columns.3
            driverOrigins[part] = SIMD3(origin.x, origin.y, origin.z)
        }

        // The character's own placement. Everything `CharacterRig` emits already carries the
        // world position, heading and map scale, so the root joint can be read straight off the
        // pelvis — but the scale has to be taken *out* of the rotation and put back on the
        // skeleton's bone lengths, or the model keeps its authored size wherever it stands.
        let rootPart = pose.parts.first { $0.part == .pelvis }?.transform
            ?? pose.parts.first?.transform
            ?? matrix_identity_float4x4
        let characterScale = simd_length(SIMD3(rootPart.columns.0.x, rootPart.columns.0.y, rootPart.columns.0.z))
        let scale = characterScale > 1e-5 ? characterScale : 1

        for index in skeleton.order {
            let localRest = skeleton.localBind[index]

            // Where this joint would be if it simply rode its parent.
            var inherited: Float4x4
            if let parent = skeleton.parents[index] {
                var scaled = localRest
                scaled.columns.3 = SIMD4(localRest.columns.3.x * scale,
                                         localRest.columns.3.y * scale,
                                         localRest.columns.3.z * scale,
                                         1)
                inherited = worldTransforms[parent] * scaled
            } else {
                inherited = localRest
            }

            var rotation = inherited.orthonormalRotation
            var origin = SIMD3(inherited.columns.3.x, inherited.columns.3.y, inherited.columns.3.z)

            if let bone = skeleton.bone[index], let part = bone.driver,
               let driver = driverRotations[part] {

                if skeleton.parents[index] == nil {
                    // The root takes the driver whole: its roll *is* which way the character is
                    // facing, and there is no parent to inherit a facing from. The correction is
                    // the constant that puts the file's hips orientation back where the rig's
                    // upright rest expects it.
                    rotation = driver * Self.uprightRest.transpose * inherited.orthonormalRotation
                    origin = rootOrigin(rotation: rotation, scale: scale, fallback: rootPart)
                } else {
                    // Aim the bone: the smallest rotation taking where it currently points onto
                    // where the rig says it should point. Smallest matters — anything larger
                    // spins the mesh about its own long axis for no reason.
                    let target = simd_normalize(SIMD3(driver.columns.1.x, driver.columns.1.y, driver.columns.1.z))
                    let current = simd_normalize(rotation * skeleton.boneAxis[index])
                    rotation = Self.shortestArc(from: current, to: target) * rotation

                    // Roll is whatever the parent carried in — see `HumanoidBone.inheritsRoll`
                    // for why taking it from the driver's axes is wrong rather than merely
                    // imprecise — **unless the bone names a landmark the rig has too**. A hand
                    // does: its thumb.
                    //
                    // The same `shortestArc` does the work a second time, and it comes out a
                    // pure spin about the bone rather than a re-aim, because both vectors are
                    // already square to it: `rollAxis` was squared up against `boneAxis` at load
                    // and the aim above puts `boneAxis` exactly on `target`, while `rollTarget`
                    // is square to the driver's own +Y by construction.
                    if let rollTarget = bone.rollTarget, skeleton.rollAxis[index] != .zero {
                        let want = simd_normalize(driver * rollTarget)
                        let have = simd_normalize(rotation * skeleton.rollAxis[index])
                        rotation = Self.shortestArc(from: have, to: want) * rotation
                    }
                }
            }

            var world = Float4x4.from3x3(rotation)
            world.columns.3 = SIMD4(origin, 1)
            worldTransforms[index] = world
        }

        if out.count < skeleton.jointCount {
            out = [Float4x4](repeating: matrix_identity_float4x4, count: skeleton.jointCount)
        }
        for index in 0..<skeleton.jointCount {
            out[index] = worldTransforms[index] * skeleton.inverseBind[index]
        }
    }

    /// Where to stand the model's root so its legs hang from the rig's hips.
    ///
    /// **`RigPart.pelvis`'s origin is not the hip joint** — it is the centre of the pelvis lathe,
    /// several units lower, and anchoring on it buries the character to the thigh. The real hip
    /// is recoverable exactly: `IKSolver.segmentTransform` puts a limb's origin at the *midpoint*
    /// of its two joints, and `RigPart.leftKnee` is a joint filler whose origin is the knee
    /// itself, so `hip = 2 × midpoint − knee`. The same trick gives every other joint in the rig
    /// if anything ever needs them.
    private func rootOrigin(rotation: simd_float3x3, scale: Float, fallback: Float4x4) -> SIMD3<Float> {
        func hip(_ limb: RigPart, _ knee: RigPart) -> SIMD3<Float>? {
            guard let midpoint = driverOrigins[limb], let knee = driverOrigins[knee] else { return nil }
            return midpoint * 2 - knee
        }

        let hips: SIMD3<Float>
        switch (hip(.leftUpperLeg, .leftKnee), hip(.rightUpperLeg, .rightKnee)) {
        case let (left?, right?): hips = (left + right) * 0.5
        case let (single?, nil), let (nil, single?): hips = single
        default:
            // A pose with no legs at all — `segmentTransform` drops a limb shorter than 0.1 —
            // so there is nothing better than the pelvis, sunk or not.
            let column = fallback.columns.3
            return SIMD3(column.x, column.y, column.z)
        }
        return hips - rotation * (skeleton.hipsToLegMid * scale)
    }

    /// The smallest rotation taking `from` onto `to`. Same shape as
    /// `IKSolver.quaternionFromUnitY`, including the antiparallel case that would otherwise be
    /// a NaN — a bone asked to point exactly backwards is rare but a walk cycle finds it.
    private static func shortestArc(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_float3x3 {
        let dot = simd_dot(from, to)
        if dot > 0.999999 { return matrix_identity_float3x3 }
        if dot < -0.999999 {
            // Any perpendicular will do; pick one that cannot itself be parallel to `from`.
            let fallback: SIMD3<Float> = abs(from.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            let axis = simd_normalize(simd_cross(from, fallback))
            return simd_float3x3(simd_quatf(angle: .pi, axis: axis))
        }
        let axis = simd_cross(from, to)
        return simd_float3x3(simd_quatf(ix: axis.x, iy: axis.y, iz: axis.z, r: 1 + dot).normalized)
    }
}

// MARK: - Helpers

extension Float4x4 {
    /// The rotation part with any scale divided out.
    ///
    /// Needed because not every part transform is rigid: the torso carries a breath scale of
    /// `(1 + breath, 1, 1 + breath)`, and reading a bone direction off it without normalising
    /// makes the character's chest direction wobble in time with its breathing.
    var orthonormalRotation: simd_float3x3 {
        func unit(_ v: SIMD4<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            let x = SIMD3(v.x, v.y, v.z)
            let length = simd_length(x)
            return length > 1e-6 ? x / length : fallback
        }
        return simd_float3x3(columns: (unit(columns.0, SIMD3(1, 0, 0)),
                                       unit(columns.1, SIMD3(0, 1, 0)),
                                       unit(columns.2, SIMD3(0, 0, 1))))
    }

    /// A 3×3 rotation widened to 4×4. Spelled as a factory rather than an `init` so it cannot
    /// become ambiguous with simd's own cross-size matrix conversions.
    static func from3x3(_ rotation: simd_float3x3) -> Float4x4 {
        Float4x4(columns: (SIMD4(rotation.columns.0, 0),
                           SIMD4(rotation.columns.1, 0),
                           SIMD4(rotation.columns.2, 0),
                           SIMD4(0, 0, 0, 1)))
    }
}
