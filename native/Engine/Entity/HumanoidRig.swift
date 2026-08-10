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

    /// What aims this bone.
    ///
    /// Nearly everything is a `RigPart`, and every `RigPart` transform has its **+Y along the
    /// bone** — `IKSolver.segmentTransform` builds the limbs that way and the torso, pelvis and
    /// neck take a `rotationX(π/2)` to match.
    ///
    /// The feet are not, because **no `RigPart` reaches an ankle**: the engine's leg IK ends at
    /// the ankle and the shoe is a separate GLB standing on it. What the pose does carry is a
    /// frame for that shoe, and it is a perfectly good frame — `RigPose.leftShoeBox` sits at the
    /// ankle with **+X along the foot** and +Z out of the top of it. So a foot is driven by the
    /// shoe rather than by a part, and the only thing that makes it a special case is which
    /// column of the frame runs down the bone.
    enum Driver: Hashable {
        /// A rig part, +Y along the bone.
        case limb(RigPart)
        /// `RigPose.leftShoeBox` / `rightShoeBox`, +X along the foot. Named for the **rig's**
        /// sides, like `RigPart` and unlike `HumanoidBone` — see the note on `driver`.
        case shoe(rigLeft: Bool)

        /// Which column of the driver's frame points down the bone.
        var alongBone: Int {
            switch self {
            case .limb: return 1
            case .shoe: return 0
            }
        }

        /// The rig part, for the two places that want one: the side check, which compares against
        /// a bind-pose bone, and the grip, which asks which hand is holding something.
        var part: RigPart? {
            if case let .limb(part) = self { return part }
            return nil
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
    var driver: Driver? {
        switch self {
        case .hips: return .limb(.pelvis)
        // The engine has one torso bone and a bought rig usually has three. Aiming all three at
        // the same target makes the spine straight rather than stacked, which is what the one
        // torso bone means anyway.
        case .spine, .spine1, .spine2: return .limb(.torso)
        case .neck, .head: return .limb(.neck)
        // **Not** the shoulder part, tempting as the name is. That part is a deltoid ball
        // aligned *down the humerus*, and a bought rig's `LeftShoulder` is the clavicle — a bone
        // that runs sideways from the spine. Aiming a clavicle down the arm swings the whole
        // shoulder girdle inward and buries the arm in the chest. The clavicle rides the spine,
        // which is very nearly what a real one does.
        case .leftShoulder: return nil
        case .leftUpperArm: return .limb(.rightUpperArm)
        case .leftLowerArm: return .limb(.rightLowerArm)
        case .leftHand: return .limb(.rightHand)
        case .rightShoulder: return nil    // see `leftShoulder`
        case .rightUpperArm: return .limb(.leftUpperArm)
        case .rightLowerArm: return .limb(.leftLowerArm)
        case .rightHand: return .limb(.leftHand)
        case .leftUpperLeg: return .limb(.rightUpperLeg)
        case .leftLowerLeg: return .limb(.rightLowerLeg)
        case .rightUpperLeg: return .limb(.leftUpperLeg)
        case .rightLowerLeg: return .limb(.leftLowerLeg)
        // The shoe frames, and the same side inversion as everything above: `leftShoeBox` is
        // built from `leftAnkle`, and `CharacterRig` says so itself — "local +Y is the
        // character's left, so `leftFoot` (y = −6) is the character's *right* foot".
        case .leftFoot: return .shoe(rigLeft: false)
        case .rightFoot: return .shoe(rigLeft: true)
        // Toes ride the foot, which is what a toe does.
        case .leftToes, .rightToes: return nil
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
    /// The **foot** has one too, and an easier one: *up*. Its driver is a shoe frame, whose +Z is
    /// out of the top of the shoe, and the model's own answer needs no landmark hunting at all —
    /// a humanoid is rigged standing on flat ground, so the top of its foot in the bind pose is
    /// engine +Z. Aim alone would leave a foot rolling with whatever the shin carried in, which
    /// is an ankle that turns the sole outward through a stride.
    ///
    /// Nothing else on a humanoid has a landmark this clean, which is why nothing else takes a
    /// roll. A spine has no thumb and no sole.
    var rollTarget: SIMD3<Float>? {
        switch self {
        case .leftHand, .rightHand: return SIMD3(0, 0, 1)
        case .leftFoot, .rightFoot: return SIMD3(0, 0, 1)
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

// MARK: - Closing a hand

/// **How far each knuckle bends, and about what.**
///
/// A bought model's fingers arrive articulated and are driven by nothing: they ride the hand as
/// one rigid piece, which is what gives us fifteen finger bones for free and also means a racket
/// sits in a palm held flat like a paddle. The rig has no finger drivers and is not going to grow
/// fifteen of them — so the fingers are posed from a **single number** instead, an amount of
/// closure between an open hand and a fist, and the amount comes from something the rig already
/// says: whether this character is holding anything.
///
/// **The axis is measured, not assumed.** Two directions are already known about a hand at load —
/// `boneAxis`, along the fingers, and `rollAxis`, out towards the thumb, square to it. Call them
/// `f` and `t`, and their cross product `n = t × f`. For a **right** hand `n` is the way the palm
/// faces, and a finger closing is a rotation about `+t` — check it on your own hand: fingers
/// north, palm down, thumb west, and curling takes the fingertips downward, the way the palm
/// faces. A **left** hand is that mirrored, so `n` comes out on the back of the hand and the same
/// closure is a rotation about `−t`.
///
/// The **thumb** is the odd one and comes out the same for both: it does not close alongside the
/// fingers, it comes *across* to meet them, which is a rotation about `n` either way.
///
/// Only the hand's own frame is used, so this needs no new landmark and works on any rig whose
/// thumb `rollAxis` was found. A hand with no thumb bone gets no curl at all rather than a
/// guessed one — the same rule the palm roll already follows.
enum Grip {
    /// Radians per joint, indexed by how far below the hand the joint sits: 1 is the knuckle,
    /// 2 the middle joint, 3 the last one. Anything deeper is an exporter's `_end` marker and
    /// gets nothing.
    ///
    /// They **compound**, because a child joint inherits its parent's bend before adding its own,
    /// which is exactly what a finger does. So the fingertip of a closed hand is through about
    /// 0.90 + 1.15 + 0.70 = 2.75 rad, a bit under a half turn, which is a fist.
    static let fingerGrip: [Float] = [0, 0.90, 1.15, 0.70]
    static let thumbGrip: [Float] = [0, 0.55, 0.60, 0.45]

    /// And with nothing in the hand. Not zero: a model is rigged in a T-pose with its fingers
    /// straight out and splayed, and a hand left at its bind pose hangs off the wrist as a flat
    /// paddle. A relaxed hand has a bend in every knuckle, so this is the pose the character
    /// stands in and the grip above is what it closes *from*.
    static let fingerRest: [Float] = [0, 0.22, 0.30, 0.18]
    static let thumbRest: [Float] = [0, 0.15, 0.18, 0.12]

    static func angle(level: Int, thumb: Bool, closed: Bool) -> Float {
        let table = closed ? (thumb ? thumbGrip : fingerGrip) : (thumb ? thumbRest : fingerRest)
        return level < table.count ? table[level] : 0
    }
}

// MARK: - What a foot measures

/// **How big a character's shoe is**, in engine units about its own ankle joint.
///
/// `CharacterRig.shoeFrame` needs four numbers to keep a sole off the floor — how far the sole
/// hangs below the ankle, how far the toe and heel reach either side of it, and how wide it is.
/// Those numbers used to be constants measured off `slip_on_shoes.glb`, which was the right
/// answer while the engine *drew* that shoe on a procedural body. It stopped being the right
/// answer the moment a bought model arrived wearing its own: nothing draws the slip-on any more,
/// and a family of five has feet from 2.9 to 7.0 deep against the slip-on's 4.5.
///
/// So the slip-on's numbers stay as `slipOn` — the fallback for the frames before a model has
/// landed, and for anything that has no model at all — and a loaded model publishes its own.
///
/// A shoe on its own turned out to be half an answer; see `WornLeg` for the other half.
struct FootShape {
    /// The lowest point of the sole, below the ankle joint.
    var soleBelowAnkle: Float
    /// How far the toe reaches in front of the ankle, and the heel behind it. A foot's ankle is
    /// not in the middle of it, and a pitched foot's lowest corner depends on which end is down.
    var toeAheadOfAnkle: Float
    var heelBehindAnkle: Float
    /// Half the width across the sole, for the corner a banked character stands on.
    var halfWidth: Float

    /// `slip_on_shoes.glb` at `CharacterRig.shoeScale`, which is what every character was sized
    /// by until models started carrying their own feet.
    static let slipOn = FootShape(soleBelowAnkle: 9.001 * 0.50,
                                  toeAheadOfAnkle: 21.54 * 0.50,
                                  heelBehindAnkle: 6.62 * 0.50,
                                  halfWidth: 6.6 * 0.50)
}

/// **The leg the character is actually wearing** — two bone lengths and the shoe on the end.
///
/// `FootShape` fixed half of a bug and left the other half standing, and the half it left is the
/// bigger one. The rig poses an *abstract* leg — `CharacterRig.thighBone` 14.4 and `shinBone`
/// 11.6 — and every number that decides where the floor is was derived from it:
/// `bodyPivotHeight` (how high the character rides), `groundContactSink` (how far the pelvis
/// drops to plant the lower foot) and the ankle handed to `shoeFrame` (which pitch keeps the sole
/// out of the ground).
///
/// **Nothing draws that leg.** `HumanoidRetargeter` walks the *model's* bones: it takes the
/// direction the rig's thigh points and steps the model's own thigh length along it, then the
/// same for the shin. So the drawn ankle is at `hip + modelThigh·d₁ + modelShin·d₂`, and the rig
/// was computing the floor for `hip + 14.4·d₁ + 11.6·d₂`. On this cast the two are between 0.9
/// and 3.8 units apart, which is most of a shoe, and it is why every bought character stood about
/// a unit and a quarter off the ground with its sole in fresh air.
///
/// The models are not to blame and neither is the scale: `ScaleMode.hips` sizes a model so its
/// **straight** hip-to-sole matches `engineHipHeight`, which is the rig's hip height with its
/// knee **bent** at rest. Two different poses, one number, and a model whose leg bones then come
/// out about 5% short of the rig's. A chunky child with a deep shoe (the son's sole is 7.0 below
/// his ankle against the slip-on's 4.5) loses more of his leg to the shoe than the rig ever did.
///
/// So the rig stops guessing and asks. Every place that used to reason about the floor in
/// `thighBone`/`shinBone`/`slipOn` now reasons in these, and `WornLeg.rig` — the old constants —
/// is what it falls back to for the few frames before the `.glb` lands.
struct WornLeg {
    /// Hip to knee and knee to ankle, in engine units, as the retargeter will walk them.
    let thigh: Float
    let shin: Float
    /// The shoe on the end of it.
    let foot: FootShape

    /// **Rig-local height of the drawn ankle with the legs at rest.** The rig's own answer is
    /// `neutralLeftFoot.z + ankleLift`; a worn leg's is wherever its own two bones end up along
    /// the same two directions, which is the whole of the bug this type exists for.
    let restAnkleZ: Float

    /// **How high the body pivot has to ride** for this leg to stand its own sole `footSink`
    /// under the floor. The old `CharacterRig.bodyPivotHeight` is exactly this for `.rig`.
    let rideHeight: Float

    /// Hip to ankle with the knee straight — the longest this leg reaches.
    var reach: Float { thigh + shin }

    /// Derived once, at load, because both numbers cost a two-bone solve and a walking crowd
    /// would otherwise pay for them twice per character per frame.
    init(thigh: Float, shin: Float, foot: FootShape) {
        self.thigh = thigh
        self.shin = shin
        self.foot = foot
        let rest = CharacterRig.wornAnkle(hip: CharacterRig.leftHip,
                                          foot: CharacterRig.neutralLeftFoot,
                                          bendNormal: CharacterRig.legBendNormalLeft,
                                          thigh: thigh, shin: shin)
        restAnkleZ = rest.z
        rideHeight = foot.soleBelowAnkle - CharacterRig.footSink - rest.z
    }

    /// **The rig's own abstract leg**, which is what every character was posed as until models
    /// started carrying their own. The fallback while a model is still being read off disk, and
    /// the answer for anything with no model at all.
    static let rig = WornLeg(thigh: CharacterRig.thighBone,
                             shin: CharacterRig.shinBone,
                             foot: .slipOn)
}

/// **Worn legs by model path**, filled in as models load.
///
/// `CharacterRig.pose` runs in the entity layer and needs a leg before it can place a foot; the
/// measurement lives on `HumanoidSkeleton`, which only exists once the `.glb` has been parsed in
/// the render layer. Rather than thread a model through every pose signature — the pose already
/// carries the path, and the store is already a cache keyed by it — the skeleton publishes here
/// and the rig looks up.
///
/// **Main thread only.** `ImportedCharacterStore` parses on a background queue and publishes its
/// results back on the main queue; posing happens there too. Nothing here is synchronised, and
/// nothing needs to be as long as that stays true.
enum WornLegs {
    private static var byPath: [String: WornLeg] = [:]

    static func publish(_ leg: WornLeg, for path: String) { byPath[path] = leg }

    /// The rig's own leg until the model lands. A character is a shadow blob for those few frames
    /// anyway, and falling back to the old constants makes every correction below a no-op rather
    /// than a guess.
    static func leg(for path: String?) -> WornLeg {
        guard let path, let leg = byPath[path] else { return .rig }
        return leg
    }

    /// Just the shoe, for the two callers that only ever wanted that.
    static func shape(for path: String?) -> FootShape { leg(for: path).foot }
}

/// Where one foot's sole is, as two points that ride the joint. See `HumanoidSkeleton.solePoints`.
struct SolePoints {
    /// Index of the foot joint these are held in the frame of.
    let joint: Int
    /// Lowest point of the front half of the sole and of the back half, in that joint's frame.
    let toe: SIMD3<Float>
    let heel: SIMD3<Float>
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
    /// **Where a bone points at bind, in the driver's frame** — the direction `solve` aims it at
    /// when the driver is at rest, instead of taking a column of the driver straight off.
    /// `.zero` for every joint that wants the plain column. See `driverAim` in the initialiser.
    let driverAim: [SIMD3<Float>]
    /// **Two points on each sole**, in that foot joint's own bind-local frame: the lowest vertex
    /// in the front half of the foot and the lowest in the back half.
    ///
    /// These exist because everything else here describes what the rig *intends*.
    /// `CharacterRig.soleClearance` and `soleTilt` measure `RigPose.leftShoeBox`, which is the
    /// frame the rig hands the retargeter — and a report built on it can only say the rig asked
    /// for a flat foot, never that it got one. Skinning two real vertices through the solved joint
    /// says where the shoe actually is. See `HumanoidRetargeter.drawnSole`.
    let solePoints: [SolePoints]

    /// This model's own shoe, measured off its mesh. `nil` if no foot matched, which also means
    /// nothing is aiming a shoe frame at it.
    let footShape: FootShape?
    /// **This model's own leg**, bones and shoe together — what `CharacterRig` reasons about the
    /// floor with. `nil` if either foot or either leg bone is missing, in which case the rig
    /// keeps its own abstract leg and the character stands where it always did.
    let wornLeg: WornLeg?
    let jointCount: Int
    /// Height the mesh measured, in the file's own units, before scaling.
    let measuredHeight: Float
    /// Uniform scale taken from the file's units to engine units.
    let normalizeScale: Float
    /// File space → engine space. **The vertices have to be put through this too**: `inverseBind`
    /// inverts a bind pose that has already been normalised, so feeding it raw file-space
    /// positions scales the model twice and turns it inside out.
    let normalizeTransform: Float4x4

    /// The axis each finger joint bends about, in its own bind-local frame, and how far it bends
    /// with an empty hand and with a full grip. `.zero` / 0 for everything that is not a finger.
    /// See `Grip` for where the numbers and the axes come from.
    let curlAxis: [SIMD3<Float>]
    let curlRest: [Float]
    let curlGrip: [Float]
    /// Which `RigPart` drives the hand each finger hangs off, so only the hand that is actually
    /// holding something closes. Nil for every joint that is not a finger.
    let curlHandPart: [RigPart?]
    /// Hands whose fingers are curling, for reporting.
    private(set) var curledHands: [HumanoidBone] = []

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

        // --- Aim targets ---
        //
        // **A foot is not aimed at a column of its driver, and that was the toe-up bug.**
        //
        // Every other bone is: `Driver.alongBone` names the column that runs down the bone, and
        // the aim turns the bone onto it. That works because a rig part's +Y and a model bone's
        // long axis mean the same thing — *down the limb*.
        //
        // The shoe frame's +X does not mean that. It was built for `slip_on_shoes.glb`, a shoe
        // whose origin sat at the ankle with its length running **horizontally** through it, so
        // +X is "along the sole" — and it is still exactly the right frame for the *sole*, which
        // is why `shoeFrame` reasons in it. But the bone the frame now drives is a real skeleton's
        // foot, which runs from the ankle **down and forward to the ball of the foot**: 35° on
        // `mother`, 47° on `son`. Aiming that bone at a horizontal axis rotates the whole foot up
        // by its own declination, and every character stood with the heel down and the toe in the
        // air — a shape you have to see from the side, which is not the view a flat sole was
        // checked in.
        //
        // So a foot names the direction it points **at bind** instead, held in the driver's frame.
        // When the frame is level, the aim reproduces the bind pose exactly and the sole is flat;
        // when `shoeFrame` pitches the frame, the whole foot pitches with it by the same angle.
        // The model's own toe-out splay survives too, which a single column never had room for.
        //
        // It reproduces bind however `boneAxis` was arrived at — including the fallbacks for a
        // foot with no toe joint — because both sides of the aim are measured off the same pose.
        var aimOut = [SIMD3<Float>](repeating: .zero, count: count)
        for index in 0..<count {
            guard let bone = bones[index], case .shoe = bone.driver else { continue }
            let direction = bindWorld[index].orthonormalRotation * axesOut[index]
            guard simd_length(direction) > 1e-5 else { continue }
            aimOut[index] = simd_normalize(direction)
        }
        driverAim = aimOut

        // --- What the shoe measures ---
        //
        // The four numbers `CharacterRig.shoeFrame` needs to keep a sole off the floor, taken off
        // this model's own mesh rather than off the slip-on GLB nothing draws any more. See
        // `FootShape`.
        //
        // **Which vertices are the shoe**: the ones this foot owns. A vertex bound more than half
        // to the ankle, the toe, or anything under them is flesh that moves with the foot and
        // nothing else — which on a shod character is the shoe, and on a bare one is the foot.
        // Either way it is the thing that meets the floor, which is what the number is for.
        //
        // **Both feet averaged into one shape.** They differ by under 2% on all five models, and
        // one shape sidesteps the left/right inversion between `RigPart` and `HumanoidBone` that
        // has caught this file twice — see the note on `driver`. A character with genuinely odd
        // feet would want two, and would have to get the sides right to deserve them.
        //
        // Measured in world-aligned engine axes rather than the ankle's own frame, because that
        // is the frame `shoeFrame` reasons in: a humanoid is rigged standing flat on the ground
        // facing +X, so at bind the sole is level and forward is +X.
        var descendsFromFoot = [Bool](repeating: false, count: count)
        for index in order {
            if let bone = bones[index], case .shoe = bone.driver { descendsFromFoot[index] = true }
            else if let parent = mesh.parents[index] { descendsFromFoot[index] = descendsFromFoot[parent] }
        }

        var shapes: [FootShape] = []
        var soles: [SolePoints] = []
        for foot in [HumanoidBone.leftFoot, .rightFoot] {
            guard let footIndex = found[foot] else { continue }
            // This foot's own chain: the ankle and everything hanging off it, but not the other
            // foot's — `descendsFromFoot` is true for both, so the walk is repeated per side.
            var chain: Set<Int> = []
            for index in order {
                if index == footIndex { chain.insert(index) }
                else if let parent = mesh.parents[index], chain.contains(parent) { chain.insert(index) }
            }

            let ankle = position(of: footIndex)
            var soleBelow = -Float.greatestFiniteMagnitude
            var toeAhead = -Float.greatestFiniteMagnitude
            var heelBehind = -Float.greatestFiniteMagnitude
            var halfWidth: Float = 0
            var owned = 0

            // **The two ends of the sole, kept as actual vertices**, so the drawn foot can be
            // measured rather than inferred. `FootShape` is four extents that a *frame* is
            // reasoned about; these are points on the mesh, and putting them through the solved
            // joint says where the shoe really ended up. See `HumanoidSkeleton.solePoints`.
            var lowestToe = SIMD3<Float>.zero, lowestHeel = SIMD3<Float>.zero
            var toeDepth = Float.greatestFiniteMagnitude
            var heelDepth = Float.greatestFiniteMagnitude

            for vertex in mesh.vertices {
                var weight: Float = 0
                for lane in 0..<4 where chain.contains(Int(vertex.joints[lane])) {
                    weight += vertex.weights[lane]
                }
                guard weight > 0.5 else { continue }
                owned += 1
                let world = normalize * SIMD4(vertex.position, 1)
                let point = SIMD3(world.x, world.y, world.z)
                let relative = point - ankle
                soleBelow = max(soleBelow, -relative.z)
                toeAhead = max(toeAhead, relative.x)
                heelBehind = max(heelBehind, -relative.x)
                halfWidth = max(halfWidth, abs(relative.y))

                // The lowest vertex in the front half of the foot and the lowest in the back
                // half: the ball of the sole and the back of the heel, which is the pair a person
                // stands on and the pair a tilt is visible in.
                if relative.x > 0, relative.z < toeDepth { toeDepth = relative.z; lowestToe = point }
                if relative.x <= 0, relative.z < heelDepth { heelDepth = relative.z; lowestHeel = point }
            }

            // A foot with almost no vertices of its own is a rig whose weights we have misread,
            // and a measurement off a handful of them is worse than the fallback.
            guard owned >= 20, soleBelow > 0, toeAhead > 0 else { continue }
            shapes.append(FootShape(soleBelowAnkle: soleBelow,
                                    toeAheadOfAnkle: toeAhead,
                                    heelBehindAnkle: max(heelBehind, 0),
                                    halfWidth: max(halfWidth, 0.1)))

            // Held in the foot joint's **own** frame, so posing the joint carries them with it —
            // which is exactly how a vertex bound entirely to that joint is skinned.
            let intoJoint = bindWorld[footIndex].inverse
            func local(_ point: SIMD3<Float>) -> SIMD3<Float> {
                let result = intoJoint * SIMD4(point, 1)
                return SIMD3(result.x, result.y, result.z)
            }
            if toeDepth < .greatestFiniteMagnitude, heelDepth < .greatestFiniteMagnitude {
                soles.append(SolePoints(joint: footIndex,
                                        toe: local(lowestToe),
                                        heel: local(lowestHeel)))
            }
        }

        solePoints = soles

        if shapes.isEmpty {
            footShape = nil
        } else {
            let n = Float(shapes.count)
            footShape = FootShape(
                soleBelowAnkle: shapes.reduce(0) { $0 + $1.soleBelowAnkle } / n,
                toeAheadOfAnkle: shapes.reduce(0) { $0 + $1.toeAheadOfAnkle } / n,
                heelBehindAnkle: shapes.reduce(0) { $0 + $1.heelBehindAnkle } / n,
                halfWidth: shapes.reduce(0) { $0 + $1.halfWidth } / n)
        }

        // --- What the leg measures ---
        //
        // Hip to knee and knee to ankle, in the same normalised engine units the retargeter will
        // step along them in — which is the whole point: these are not a description of the
        // model, they are exactly the two numbers `solve` uses to decide where the drawn ankle
        // lands. See `WornLeg` for why the rig needs them.
        //
        // Both legs averaged, for the same reason the feet are: the sides differ by a rounding
        // error on every model here, and one leg sidesteps the left/right inversion between
        // `RigPart` and `HumanoidBone`.
        func boneLength(_ from: HumanoidBone, _ to: HumanoidBone) -> Float? {
            guard let a = found[from], let b = found[to] else { return nil }
            let length = simd_length(position(of: b) - position(of: a))
            return length > 1e-4 ? length : nil
        }
        let thighs = [boneLength(.leftUpperLeg, .leftLowerLeg),
                      boneLength(.rightUpperLeg, .rightLowerLeg)].compactMap { $0 }
        let shins = [boneLength(.leftLowerLeg, .leftFoot),
                     boneLength(.rightLowerLeg, .rightFoot)].compactMap { $0 }

        if let footShape, !thighs.isEmpty, !shins.isEmpty {
            wornLeg = WornLeg(thigh: thighs.reduce(0, +) / Float(thighs.count),
                              shin: shins.reduce(0, +) / Float(shins.count),
                              foot: footShape)
        } else {
            // A leg this could not measure is a leg the rig must not try to correct for: a wrong
            // ride height is worse than the old one, because it is confidently wrong.
            wornLeg = nil
        }

        // --- Roll axes ---
        // Measured the same way and for the same reason: a direction taken off the bind pose,
        // held in the joint's own frame so it survives being posed. `HumanoidBone.rollTarget` is
        // the other half — where this axis is turned to face each frame.
        var rollOut = [SIMD3<Float>](repeating: .zero, count: count)
        for index in 0..<count {
            guard let bone = bones[index], bone.rollTarget != nil else { continue }

            /// The landmark, in **world** bind space. Two bones want one and they find it two
            /// different ways: a hand measures its own thumb, and a foot does not have to measure
            /// anything, because a humanoid is rigged standing on flat ground and so the top of
            /// its foot at bind is simply up.
            let landmark: SIMD3<Float>
            switch bone {
            case .leftFoot, .rightFoot:
                landmark = SIMD3(0, 0, 1)
            default:
                guard let thumb = children(of: index).first(where: {
                    HumanoidNaming.isThumb(mesh.jointNames[$0])
                }) else { continue }
                landmark = position(of: thumb) - position(of: index)
            }

            let local = bindWorld[index].orthonormalRotation.transpose * landmark
            // Square it up against the bone's own length. The two have to be exactly
            // perpendicular for the roll to be a roll: `HumanoidRetargeter` turns this axis onto
            // its target with the same shortest arc it aims a bone with, and a shortest arc
            // between two vectors already square to the bone is a rotation about the bone and
            // nothing else. A thumb that is 20° forward of the palm would otherwise re-aim it,
            // and a foot bone that runs forward *and down* — most of them do — would otherwise
            // be re-aimed by its own sole.
            let axis = axesOut[index]
            let perpendicular = local - axis * simd_dot(local, axis)
            if simd_length(perpendicular) > 1e-4 { rollOut[index] = simd_normalize(perpendicular) }
        }
        rollAxis = rollOut

        // --- Finger curl ---
        //
        // Which joints are fingers, how deep each one sits under its hand, and which of them are
        // thumb. One pass in `order`, so a joint's parent has always been classified first and
        // this is a walk *down* rather than a walk back up to the wrist per joint.
        var handRoot = [Int?](repeating: nil, count: count)
        var level = [Int](repeating: 0, count: count)
        var isThumb = [Bool](repeating: false, count: count)
        for index in order {
            guard let parent = mesh.parents[index] else { continue }
            let thumbHere = HumanoidNaming.isThumb(mesh.jointNames[index])
            if bones[parent] == .leftHand || bones[parent] == .rightHand {
                handRoot[index] = parent
                level[index] = 1
                isThumb[index] = thumbHere
            } else if let root = handRoot[parent] {
                handRoot[index] = root
                level[index] = level[parent] + 1
                // Named off the first joint of the chain: Mixamo spells the whole thumb
                // `LeftHandThumb1..4`, but a rig that only names its root joint still gets it.
                isThumb[index] = isThumb[parent] || thumbHere
            }
        }

        var curlOut = [SIMD3<Float>](repeating: .zero, count: count)
        var restOut = [Float](repeating: 0, count: count)
        var gripOut = [Float](repeating: 0, count: count)
        var partOut = [RigPart?](repeating: nil, count: count)
        var curled: Set<HumanoidBone> = []
        for index in 0..<count {
            guard let hand = handRoot[index], let handBone = bones[hand] else { continue }
            let angleRest = Grip.angle(level: level[index], thumb: isThumb[index], closed: false)
            let angleGrip = Grip.angle(level: level[index], thumb: isThumb[index], closed: true)
            if angleRest == 0 && angleGrip == 0 { continue }

            // The hand's own frame, in the bind pose. `rollOut` is zero for a hand with no thumb
            // bone under it, and there is nothing to build a frame out of in that case — so those
            // fingers stay as rigid as they were rather than bending about a guess.
            let handRotation = bindWorld[hand].orthonormalRotation
            guard rollOut[hand] != .zero else { continue }
            let along = simd_normalize(handRotation * axesOut[hand])
            let toThumb = simd_normalize(handRotation * rollOut[hand])
            let palm = simd_cross(toThumb, along)
            // See `Grip`: fingers about ±thumb depending on which hand, thumb about the palm
            // normal on both.
            let worldAxis = isThumb[index] ? palm
                                           : toThumb * (handBone == .leftHand ? -1 : 1)

            // Into the joint's own frame, so it rides the joint the way `boneAxis` does.
            curlOut[index] = simd_normalize(bindWorld[index].orthonormalRotation.transpose * worldAxis)
            restOut[index] = angleRest
            gripOut[index] = angleGrip
            partOut[index] = handBone.driver?.part
            curled.insert(handBone)
        }
        curlAxis = curlOut
        curlRest = restOut
        curlGrip = gripOut
        curlHandPart = partOut
        curledHands = HumanoidBone.allCases.filter(curled.contains)

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
        //
        // The feet are in it too, and they have to be: their driver is a shoe frame rather than a
        // `RigPart`, so there is no bind-pose bone to look up — but `RigBindPose` carries each
        // leg's three joints, and the tip of one is the ankle the shoe stands on.
        var swapped: [HumanoidBone] = []
        for bone in HumanoidBone.allCases {
            guard let index = found[bone], let driver = bone.driver else { continue }
            let rig: Float
            switch driver {
            case let .limb(part):
                guard let rest = Self.engineBind.bones[part] else { continue }
                rig = rest.columns.3.y
            case let .shoe(rigLeft):
                rig = rigLeft ? Self.engineBind.leftLeg.tip.y : Self.engineBind.rightLeg.tip.y
            }
            let model = position(of: index).y
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
                if case .shoe = bone.driver { note = "  (driven by the shoe frame)" }
                switch bone {
                // Worth a line of its own: a hand with no thumb bone under it still draws, it
                // just hangs at whatever roll the forearm carries it to — which is the exact
                // symptom this measurement exists to cure, and impossible to tell from a bad
                // measurement by looking.
                case .leftHand, .rightHand:
                    note += rollAxis[index] == .zero ? "  (no thumb — palm rides the forearm)"
                                                     : "  (palm rolled by its thumb)"
                case .leftFoot, .rightFoot:
                    note += rollAxis[index] == .zero ? "  (sole not found — foot rides the shin)"
                                                     : "  (sole levelled by the shoe)"
                default: break
                }
                lines.append("  \(bone.rawValue) ← \(jointNames[index])" + note)
            } else {
                lines.append("  \(bone.rawValue) — MISSING")
                unmatched += 1
            }
        }
        let fingers = curlAxis.filter { $0 != .zero }.count
        lines.append("  \(jointCount - matched.count) unnamed joints ride their parents"
                     + (fingers > 0 ? ", \(fingers) of them fingers that curl" : ""))
        if !curledHands.isEmpty, curledHands.count < 2 {
            // One hand curling and not the other means a hand whose thumb was never found, and
            // that hand is going to hold a racket in a flat palm while the other one closes.
            lines.append("  only \(curledHands.map(\.rawValue).joined(separator: ", ")) curls"
                         + " — the other hand has no thumb bone to take a frame from")
        }
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
    private var driverRotations = [HumanoidBone.Driver: simd_float3x3]()
    private var driverOrigins = [RigPart: SIMD3<Float>]()
    /// The character scale the last `solve` ran at. `worldTransforms` carries bone offsets scaled
    /// by it, so anything reading a point *in* a joint's frame has to scale it the same way.
    private var lastScale: Float = 1

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
            driverRotations[.limb(part)] = transform.orthonormalRotation
            let origin = transform.columns.3
            driverOrigins[part] = SIMD3(origin.x, origin.y, origin.z)
        }
        // The two frames that are not parts. `CharacterRig` hands these over separately because
        // the shoe is a separate model rather than a bone of the body — see `HumanoidBone.Driver`.
        driverRotations[.shoe(rigLeft: true)] = pose.leftShoeBox.orthonormalRotation
        driverRotations[.shoe(rigLeft: false)] = pose.rightShoeBox.orthonormalRotation

        // The character's own placement. Everything `CharacterRig` emits already carries the
        // world position, heading and map scale, so the root joint can be read straight off the
        // pelvis — but the scale has to be taken *out* of the rotation and put back on the
        // skeleton's bone lengths, or the model keeps its authored size wherever it stands.
        let rootPart = pose.parts.first { $0.part == .pelvis }?.transform
            ?? pose.parts.first?.transform
            ?? matrix_identity_float4x4
        let characterScale = simd_length(SIMD3(rootPart.columns.0.x, rootPart.columns.0.y, rootPart.columns.0.z))
        let scale = characterScale > 1e-5 ? characterScale : 1
        lastScale = scale

        // Which hand, if any, is closed round something this frame.
        //
        // **`RigPart.rightHand` is the character's left** — the naming inversion in
        // `HumanoidBone.driver` again — and that is the hand a racket goes in:
        // `CharacterRig.pose` composes `holdingTransform` off `rightHandAnchor`. So the part is
        // named here rather than the bone, and it stays right if that anchor ever moves.
        //
        // **It snaps rather than blends, on purpose.** The prop it is closing around appears and
        // disappears in one frame — a racket is drawn only while `pose.holding` is set — so a
        // hand that took a quarter of a second to close would be gripping air on the way in and
        // clutching nothing on the way out. `solve` has no timestep to smooth over anyway.
        let holdingPart: RigPart? = pose.holding != nil ? .rightHand : nil

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

            if let bone = skeleton.bone[index], let key = bone.driver,
               let driver = driverRotations[key] {

                // Which column runs down the bone: +Y for a rig part, +X for a shoe frame.
                let alongBone = driver[key.alongBone]

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
                    //
                    // A bone with a `driverAim` names that direction in the driver's own frame
                    // rather than borrowing a column of it. Only the feet do; see `driverAim`.
                    let aim = skeleton.driverAim[index]
                    let target = aim == .zero ? simd_normalize(alongBone)
                                              : simd_normalize(driver * aim)
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
                        // **Squared up against the direction the bone was just aimed at**, the
                        // same way `rollAxis` was squared up against the bone at load — and for
                        // the same reason, which the comment there states and this line did not
                        // honour: *a shortest arc between two vectors already square to the bone
                        // is a rotation about the bone and nothing else.* Only one side of the arc
                        // was square. The other was `rollTarget` straight off the driver.
                        //
                        // For a hand that was harmless — `rollTarget` is +Z of the hand part and
                        // the bone is aimed at its +Y, so the two are already perpendicular. For a
                        // foot it was not, because a foot bone runs forward **and down**: the
                        // son's ankle-to-toe is 34° below horizontal, and the shoe frame's up is
                        // square to the *shoe*, not to that. So the arc that was meant to level
                        // the sole re-aimed the bone by most of that angle, and every model with a
                        // steeply angled foot bone was drawn standing with its toes in the air —
                        // 2.8 units of toe-up on the boy, none of which the rig had asked for and
                        // none of which anything measuring `RigPose.leftShoeBox` could see.
                        let wanted = driver * rollTarget
                        let square = wanted - target * simd_dot(wanted, target)
                        if simd_length(square) > 1e-4 {
                            let want = simd_normalize(square)
                            let have = simd_normalize(rotation * skeleton.rollAxis[index])
                            rotation = Self.shortestArc(from: have, to: want) * rotation
                        }
                    }
                }
            }

            // A finger. Nothing drives one, so it is not aimed at anything — it takes whatever
            // the hand did to it and then bends by its own share of `Grip`. Doing it here, in
            // `order`, is what makes the bends compound down the finger for free: a joint's
            // children have not been visited yet and will inherit this rotation as their rest.
            if skeleton.curlAxis[index] != .zero {
                let closed = holdingPart != nil && skeleton.curlHandPart[index] == holdingPart
                let angle = closed ? skeleton.curlGrip[index] : skeleton.curlRest[index]
                if angle != 0 {
                    let axis = simd_normalize(rotation * skeleton.curlAxis[index])
                    rotation = simd_float3x3(simd_quatf(angle: angle, axis: axis)) * rotation
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

    /// **Where each drawn sole ended up**, after the last `solve` — one entry per foot, world
    /// space, `toe` and `heel` being the two points `HumanoidSkeleton.solePoints` measured.
    ///
    /// This is the only honest answer to "is the shoe flat on the floor". Every other number in
    /// this engine measures `RigPose.leftShoeBox`, which is what the rig *asked* the retargeter
    /// for; this is what the retargeter did with it, skinned through the joint the way the GPU
    /// will skin the mesh around it. A level shoe frame that comes out here as a tilted sole is a
    /// retargeting bug, and nothing built on the shoe box could ever have said so.
    func drawnSole() -> [(toe: SIMD3<Float>, heel: SIMD3<Float>)] {
        skeleton.solePoints.compactMap { sole in
            guard sole.joint < worldTransforms.count else { return nil }
            let joint = worldTransforms[sole.joint]
            func place(_ point: SIMD3<Float>) -> SIMD3<Float> {
                let world = joint * SIMD4(point * lastScale, 1)
                return SIMD3(world.x, world.y, world.z)
            }
            return (toe: place(sole.toe), heel: place(sole.heel))
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
