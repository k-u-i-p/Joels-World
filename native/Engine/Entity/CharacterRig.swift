import Foundation
import simd

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

/// **The bones of the rig.** Each is a frame `pose` puts somewhere in the world, and each is
/// what `HumanoidRig` aims the matching bone of a bought model at.
///
/// They were *body parts* once: one procedural mesh and one colour each, a capsule per limb
/// segment with a sphere stuffed into every elbow, knee and shoulder to hide the seam. Nothing
/// draws them now — a character is one bought model — so the joint fillers no longer fill
/// anything. **They are kept because they are still good aiming points**: `.leftElbow` is where
/// the elbow is, and a retargeter that knows that does not have to work it out.
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

    /// **The bought model this character is drawn with**, already resolved to an asset path by
    /// `CharacterModels`. It rides on the pose because the pose is the only thing that reaches
    /// the renderer per character — everything else about a draw is a global, and a global is
    /// what made every pupil the same boy.
    var model: String = CharacterModels.defaultPath

    /// The head *group* — the frame props parented to the head inherit, including its
    /// non-uniform scale. It used to be the placement of a head GLB as well; the bought model
    /// brings its own head, so this is only an anchor now.
    var headTransform = matrix_identity_float4x4

    /// **The two foot frames**, at the ankle with +X along the foot. Nothing draws a shoe any
    /// more — a bought model has its own — but `HumanoidRig` drives the imported feet off these,
    /// and `CharacterRig.soleClearance` measures the floor with them. See `shoeFrame`.
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

/// A two-bone limb's three joints, in whatever space the caller asked for.
typealias RigChain = (root: SIMD3<Float>, mid: SIMD3<Float>, tip: SIMD3<Float>)

/// The rig at rest — see `CharacterRig.bindPose`. Everything is in bind space: the character
/// standing at the world origin, facing +X, at scale 1.
struct RigBindPose {
    /// Rest transform per skinning bone. The joint fillers — shoulders, elbows, knees — are
    /// absent: they were only ever there to hide a seam between two capsules.
    var bones: [RigPart: Float4x4]

    var leftArm: RigChain      ///< shoulder → elbow → wrist
    var rightArm: RigChain
    var leftLeg: RigChain      ///< hip → knee → ankle
    var rightLeg: RigChain
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

/// Poses the character rig.
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

    /// **The legs are 20% longer than they were** (12 / 9.7). Measured off a render, the old rig
    /// stood with its hip joint at 38.6% of its total height; a real ten-year-old's is at about
    /// 48%, and even a deliberately chunky cartoon child is around 43%. Short legs under a large
    /// head is *toddler* proportion, and it was the thing making these read as much younger than
    /// the pupils they are meant to be.
    ///
    /// The head cannot be part of the fix — it is an authored GLB, scaled to match the web
    /// version, and it is 31% of the character's height on its own. So the legs do the work, and
    /// they get the hip to 41.7%. Everything downstream follows on its own: `bodyPivotHeight` is
    /// derived from these, so the feet stay on the floor, and the stride is written in angles, so
    /// a longer leg simply takes a longer step.
    static let thighBone: Float = 14.4
    static let shinBone: Float = 11.6

    // MARK: - Standing on the floor

    /// **How big the shoe is drawn.** It was 0.65, and at 0.65 the slip-on GLB is 18.3 units from
    /// heel to toe on a character 66 units tall — 28% of its own height in foot. A real foot is
    /// about 15% and a chunky cartoon one about 20%. They were clown shoes, and next to a leg of
    /// 20.8 they were the loudest wrong thing on the whole character.
    static let shoeScale: Float = 0.50

    /// How far `slip_on_shoes.glb` hangs below its own origin, in the model's units — measured
    /// off the file, not guessed (its lowest vertex is at −0.07 under a node scaled 100 and
    /// translated −2). The shoe is drawn with its origin **at the ankle**, so this is what ties
    /// how big the shoe is to how high the character has to stand.
    static let shoeSoleBelowAnkle: Float = 9.001

    /// **How far the toe and the heel reach from the ankle**, in the same model units as
    /// `shoeSoleBelowAnkle` and measured off the same file. The mesh spans −0.083…0.269 along
    /// its own +Z under a node scaled 80 on that axis, and `shoeModelLocal` turns the model's
    /// +Z into the shoe frame's +X — so the shoe runs from 6.62 behind the ankle to 21.54 in
    /// front of it.
    ///
    /// Scaled by `shoeScale` that is a foot 14.1 long with the ankle 23% of the way back from
    /// the toe, which is where a real ankle sits, and it is why `shoeScale` reads right.
    ///
    /// These exist because a foot that pitches has a **lowest corner that is not its origin**:
    /// the sole clearance under a toe-down foot is `shoeSoleBelowAnkle` only while the foot is
    /// level. `soleClearance` is the thing that knows that, and nothing had a number for the
    /// length of the foot before it needed one.
    static let shoeToeAheadOfAnkle: Float = 21.54
    static let shoeHeelBehindAnkle: Float = 6.62
    /// The same measurement across the foot — the model's own ±0.066 on X, scaled 100.
    static let shoeHalfWidth: Float = 6.6

    /// How far the sole is allowed under the floor. A shoe resting exactly on z = 0 shows a hard
    /// line where it meets the ground; a little sink hides it. The old rig had 1.05 of sink by
    /// accident, which is where "the feet look planted" came from.
    static let footSink: Float = 0.4

    /// How high the body pivot stands off the ground. Every local coordinate in this file is
    /// measured from it, so anything converting a rig-local point into world space adds it back.
    ///
    /// **Derived, not chosen.** It used to be a flat 15.5, which meant that changing a bone
    /// length or a shoe scale left the character hovering or buried and the only way to find out
    /// was to look. It is now whatever puts the sole of the shoe `footSink` under the floor with
    /// the legs at rest, so the three things that decide it — leg length, shoe size and sink —
    /// are each a number with a name and none of them can be changed alone and be wrong.
    static let bodyPivotHeight: Float =
        shoeSoleBelowAnkle * shoeScale - footSink - (neutralLeftFoot.z + ankleLift)

    // Joint anchors, from `buildSkeletonRig`. Public because `CharacterMotor` measures a limb's
    // reach from them — an arm can only get so far from the shoulder it hangs off.
    static let leftShoulder = SIMD3<Float>(3, -10, 26)
    static let rightShoulder = SIMD3<Float>(3, 10, 26)
    static let leftHip = SIMD3<Float>(0, -6, 10)
    static let rightHip = SIMD3<Float>(0, 6, 10)

    // MARK: - Anatomy
    //
    // Where the torso, the pelvis and the neck sit in the rig's own frame — +X forward, +Y the
    // character's left, +Z up — measured from the body pivot.
    //
    // **This used to be the shape of the body as well as its skeleton**: a torso silhouette of
    // five rings, a pelvis profile with a squash, a radius at each end of every limb, a deltoid,
    // an elbow and a knee. Those numbers were what the procedural body was *generated from*, and
    // the procedural body is gone. What is left is the placements below, which are not geometry —
    // they position `RigPart.torso`, `.pelvis` and `.neck`, and `HumanoidRig` aims a bought
    // model's spine, hips and neck at exactly those.

    /// Where the torso part is centred.
    static let torsoCentreZ: Float = 20

    /// Where the pelvis part is centred.
    static let pelvisCentreZ: Float = 11

    /// The base of the neck, and how long it is.
    static let neckBase = SIMD3<Float>(1, 0, 30.5)
    static let neckLength: Float = 7

    /// How much of the head's rotation the neck takes. A neck that took all of it would swivel
    /// like an owl; one that took none would leave the head floating free of the shoulders.
    static let neckFollowsHead: Float = 0.45

    /// **The hand's frame**, which the retargeter reads and nothing draws any more.
    ///
    /// It is the forearm's: **y = 0 is the wrist, +Y runs out to the fingertips, +Z is the thumb
    /// side, +X is the back of the hand.** `IKSolver.quaternionFromUnitY` pinned the direction
    /// the forearm pointed and left the roll about it undefined; `IKSolver.basis` fixes that roll
    /// against the arm's own bending normal, which is what makes a hand with a side possible at
    /// all — and what `HumanoidRig` aims a bought model's wrist and thumb with.
    enum Hand {
        /// **How far the hand mesh is rolled about the forearm at rest.**
        ///
        /// `IKSolver.basis` aims the forearm and rolls it to the plane the elbow bends in, which
        /// is the right reference for *where the elbow goes* and simply not the same thing as
        /// which way a palm faces. A quarter turn about the forearm's own long axis puts the
        /// thumb forward, the back of the hand outward and the palm against the thigh, which is
        /// where a hanging hand's palm is. Same sign for both hands.
        ///
        /// **It is applied to the hand part only, not to `rightHandAnchor`.** The racket and
        /// every emote prop ride on that anchor, and their placement was tuned against the
        /// unrolled frame; spinning it here would roll the strings a quarter turn with it and
        /// turn the tennis racket edge-on.
        ///
        /// This is the whole of what is left of `Hand`. It used to carry a palm profile, four
        /// fingers with a taper and a spread, and a thumb — the numbers a hand was **generated**
        /// from. A bought model arrives with its hand already modelled, and `HumanoidRig` finds
        /// its fingers by name, so none of those numbers describe anything any more.
        static let restRoll: Float = 1.25
    }

    // Neutral limb targets, reset every frame in `updateCharacter3D:1136-1139`. Public because
    // `CharacterMotor` starts every limb here, and a released one settles back to it.
    //
    // **These are derived from the neutral angles rather than written down beside them.** They
    // used to be four hand-typed vectors that had to agree with `neutralArmSwing` and friends to
    // within 0.01, with a self-test assertion standing over them to check that two constants
    // still matched. Deriving them means the question cannot be asked: change an angle, or a bone
    // length, and the position follows. The assertion still passes, and now says something about
    // `armTarget` rather than about somebody's arithmetic.
    static let neutralLeftHand = armTarget(shoulder: leftShoulder,
                                           swing: neutralArmSwing,
                                           sideways: -neutralArmSideways,
                                           flex: neutralArmFlex)
    static let neutralRightHand = armTarget(shoulder: rightShoulder,
                                            swing: neutralArmSwing,
                                            sideways: neutralArmSideways,
                                            flex: neutralArmFlex)
    static let neutralLeftFoot = legTarget(hip: leftHip,
                                           swing: neutralLegSwing,
                                           sideways: -neutralLegSideways,
                                           flex: neutralLegFlex)
    static let neutralRightFoot = legTarget(hip: rightHip,
                                            swing: neutralLegSwing,
                                            sideways: neutralLegSideways,
                                            flex: neutralLegFlex)

    private static let bendNormalArmL = simd_normalize(SIMD3<Float>(0, 1, -0.5))
    private static let bendNormalArmR = simd_normalize(SIMD3<Float>(0, 1, 0.5))
    private static let bendNormalLegL = simd_normalize(SIMD3<Float>(0, -1, -0.2))
    private static let bendNormalLegR = simd_normalize(SIMD3<Float>(0, -1, 0.2))

    // MARK: - Arms, by angle rather than by displacement

    /// **Where an arm points and how bent its elbow is**, turned into a hand target the IK can
    /// solve without clamping anything.
    ///
    /// The walk cycle used to swing an arm by shoving the hand through space — `hand.x += swing`
    /// — and that is why the arms read as broomsticks on a hinge. Two things go wrong with it:
    ///
    /// 1. **The elbow is not controlled, it is a leftover.** How bent an arm looks is decided
    ///    entirely by how far the hand is from the shoulder, and the neutral hand sits 16.37 out
    ///    of a possible 17 — 96% of full extension, which is a locked arm. Every pose the tables
    ///    could describe was a straight stick pivoting at the shoulder. A person's arm is never
    ///    straight; a running one is folded to a right angle.
    /// 2. **Most of the swing was never drawn.** A hand pushed along +X leaves the sphere the
    ///    shoulder can actually reach almost immediately, and `IKSolver.solve` clamps it back
    ///    without saying so (the same silent clamp that cost the tennis game a session — see the
    ///    handoff). Past about six units the hand stopped travelling and only the clamp moved.
    ///
    /// Asking for an *angle* fixes both. The hand target comes out on a sphere of radius
    /// `2·armBone·cos(flex/2)`, which is exactly the distance two equal bones with `flex`
    /// radians of bend at the elbow can span — so it is always reachable, never clamped, and the
    /// elbow ends up at the angle that was asked for.
    ///
    /// - Parameters:
    ///   - swing: sagittal, radians. 0 hangs straight down, positive swings the hand forward.
    ///   - sideways: radians from straight down towards the character's **left** (local +Y).
    ///     Signed absolutely, not per-arm, so "both arms sweep left" is the same number added to
    ///     both — which is what an arm counterweight is.
    ///   - flex: how far the elbow is from straight, radians. 0 is locked out, π/2 is a right
    ///     angle. Clamped short of folding the forearm onto the upper arm.
    static func armTarget(shoulder: SIMD3<Float>,
                          swing: Float,
                          sideways: Float,
                          flex: Float) -> SIMD3<Float> {
        let bend = min(max(flex, 0), 2.4)
        let reach = 2 * armBone * cos(bend / 2)
        let sideCos = cos(sideways), sideSin = sin(sideways)
        let swingCos = cos(swing), swingSin = sin(swing)
        // Straight down, tipped `sideways` towards the character's left, then swung forward.
        let direction = SIMD3<Float>(sideCos * swingSin, sideSin, -sideCos * swingCos)
        return shoulder + direction * reach
    }

    /// **The resting arm.** This is where a character's arms are whenever nothing else has an
    /// opinion, which is most of the time on most of the characters on screen, so it is worth
    /// more than any pose in the walk cycle.
    ///
    /// They were 0.405 forward and 0.375 out: **23° of shoulder flexion and 21° of abduction**,
    /// held there permanently. That is not a person standing, it is a person carrying two
    /// invisible buckets, and from the side it read as sleepwalking — the hands hung six units
    /// clear in front of the hips with daylight under both armpits.
    ///
    /// A relaxed arm hangs almost straight down. The numbers now are 7° forward, so the hand sits
    /// just ahead of the hip rather than in front of the body, and 10° out — which is not styling
    /// but clearance: the pelvis is 8.8 units of half-width at hip height and a wrist hanging
    /// dead vertical from a shoulder at y = ±10 would be inside the shorts.
    ///
    /// `flex` stays where it was. A resting elbow really does carry 25–30° of bend, and it is
    /// also what keeps the arm off full extension — `LocomotionSelfTest` requires the neutral
    /// reach to stay 0.4 clear of `2 · armBone` so the IK has somewhere to go.
    static let neutralArmSwing: Float = 0.13
    static let neutralArmSideways: Float = 0.17
    static let neutralArmFlex: Float = 0.52

    // MARK: - Legs, by angle rather than by displacement

    /// How far the ankle rides above the foot target, so the calf does not punch through the
    /// shoe. It used to be a bare 2.3 down in the IK block; `legTarget` needs the same number to
    /// know what it is aiming at, so it has a name now.
    static let ankleLift: Float = 2.3

    /// **Where a leg points and how bent its knee is**, turned into a foot target.
    ///
    /// The same argument as `armTarget`, one session later. The walk cycle swung a leg by pushing
    /// its foot through space — `foot.x += legSwing * 23` — and the legs were in exactly the
    /// state the arms were: `neutralLeftFoot` puts its ankle **20.80 from the hip against a
    /// 21.70 reach**, so a standing leg is at 96% of full extension, and a full-throttle stride
    /// asked for 26. `IKSolver.solve` pulled that back onto the reach sphere without saying so
    /// (trap 2 in the handoff), which is why the foot *rose* as the stride lengthened. It read as
    /// a high-kneed sprint and it was luck, not control: nothing in the tables could ask for a
    /// knee angle, so nothing could tell a walk's knee from a sprint's.
    ///
    /// The legs' two bones are **not** equal — a 12-unit thigh and a 9.7-unit shin — so the span
    /// is the law of cosines rather than the arms' `2·b·cos(flex/2)`. Both reduce to the same
    /// thing when the bones match.
    ///
    /// Returns a **foot** target, i.e. `ankleLift` below the ankle the angles describe, because
    /// that is what the rest of `pose` and every emote already work in.
    ///
    /// - Parameters:
    ///   - swing: sagittal, radians. 0 hangs straight down, positive swings the foot forward.
    ///   - sideways: radians from straight down towards the character's **left** (local +Y).
    ///     Signed absolutely, exactly as `armTarget`'s is.
    ///   - flex: how far the knee is from straight, radians. 0 is locked out. A knee only bends
    ///     one way, and this is that way.
    static func legTarget(hip: SIMD3<Float>,
                          swing: Float,
                          sideways: Float,
                          flex: Float) -> SIMD3<Float> {
        let bend = min(max(flex, 0), 2.4)
        let reach = (thighBone * thighBone + shinBone * shinBone
                     + 2 * thighBone * shinBone * cos(bend)).squareRoot()
        let sideCos = cos(sideways), sideSin = sin(sideways)
        let swingCos = cos(swing), swingSin = sin(swing)
        let direction = SIMD3<Float>(sideCos * swingSin, sideSin, -sideCos * swingCos)
        return hip + direction * reach - SIMD3<Float>(0, 0, ankleLift)
    }

    /// The neutral leg in those angles: 0.0963 rad forward of vertical, square to the body, on a
    /// 0.5826 rad knee. `LocomotionSelfTest` pins the round trip, both legs.
    ///
    /// Unchanged by the longer bones, because they are angles — the leg got longer and the pose
    /// did not move. What *is* different is what they span, which is `neutralLegSpan`.
    static let neutralLegSwing: Float = 0.09632
    static let neutralLegSideways: Float = 0
    static let neutralLegFlex: Float = 0.58257

    /// Hip to ankle with the leg at rest. The law of cosines again, and the number anything
    /// wanting to move a hip *sideways by a distance* has to divide by to get an angle — see
    /// `IdleBehaviour.loadWeight`, which is the reason it has a name.
    static let neutralLegSpan: Float = (thighBone * thighBone + shinBone * shinBone
                                        + 2 * thighBone * shinBone * cos(neutralLegFlex)).squareRoot()

    /// One leg's three angles. Named for the character's own sides, not the rig's.
    struct LegAngles {
        var swing: Float
        var sideways: Float
        var flex: Float

        static let neutral = LegAngles(swing: neutralLegSwing,
                                       sideways: neutralLegSideways,
                                       flex: neutralLegFlex)
    }

    /// **The walk cycle's legs**, as a pure function of the gait.
    ///
    /// It is lifted out of `pose` rather than left inline for one reason: the contact promise
    /// below it — that the lower foot lands on the floor rather than floating up the arc a
    /// swinging leg sweeps — is a claim about the whole stride, and there is no way to check a
    /// claim about a whole stride from inside a function that draws one frame of it. This one
    /// takes numbers and returns numbers, so `LocomotionSelfTest` can walk it through a full
    /// cycle at every throttle and measure what the feet do.
    ///
    /// `right` is the leg whose foot target is `neutralLeftFoot` — the rig's names run the other
    /// way round, see the note in `Gait`.
    static func strideLegs(phase: Float,
                           forward: Float,
                           lateral: Float,
                           run: Float,
                           effort: Float) -> (right: LegAngles, left: LegAngles) {
        var right = LegAngles.neutral
        var left = LegAngles.neutral
        left.sideways = -left.sideways

        let legSwing = sin(phase)
        let legVelocity = cos(phase)
        // The stride's amplitude, not the character's speed: `Gait.forward` runs to 1.4 on an
        // overspeed frame and a leg swung that far leaves the floor no matter what the knee does.
        let drive = min(max(forward, -1), 1)

        // 0.40 rad either side of the hang puts about 11 units of foot in front of the hip and 9
        // behind at full throttle — a 20-unit stride, which is what the old 23-unit ask *drew*
        // once the IK had clamped it back onto the reach sphere.
        let strideSwing: Float = 0.40 + run * 0.10
        // Feet stay inside the hips' 12-unit separation, so a side-step shuffles rather than
        // crossing its own legs over. 0.26 rad on a 20.8-unit leg is the old 5.5 units.
        let strideSideways: Float = 0.26

        right.swing += legSwing * strideSwing * drive
        left.swing -= legSwing * strideSwing * drive

        right.sideways += legSwing * strideSideways * lateral
        left.sideways -= legSwing * strideSideways * lateral

        // **The stance knee straightens as the leg reaches the ends of its stride**, and this is
        // the term that makes an angle-driven leg work at all. A leg swung about a fixed-length
        // hip sweeps its foot round an arc, so the foot climbs at both extremes — the compass
        // problem. A person's does not, because the standing leg is not at full extension in the
        // middle of a stride and it *is* at the ends: the knee pays for the arc.
        //
        // Without it the feet ride up to four units off the floor at a sprint and the body has to
        // sink that far to follow, which is a character bobbing like a buoy.
        let straighten = abs(legSwing) * 0.53 * abs(drive)
        right.flex = max(0.05, right.flex - straighten)
        left.flex = max(0.05, left.flex - straighten)

        // **The knee is the tell, and this is the first time it has been one.** A foot does not
        // leave the ground because something lifted it: the knee folds and the heel comes up
        // under the hip. The fold peaks mid-swing — `legVelocity` is largest exactly when the leg
        // is passing under the body — and unfolds to nearly straight at both ends of the stride,
        // which is what a leg taking weight does.
        //
        // A walk peaks at about 63° of knee and a sprint at 115°, which is roughly where people
        // actually are. The old `foot.z += 11` put a walk at 99° and had no way to tell the two
        // apart, because the number it moved was a height and the knee was whatever fell out.
        let liftFlex: Float = 0.88 + run * 0.60
        right.flex += max(0, legVelocity) * liftFlex * effort
        left.flex += max(0, -legVelocity) * liftFlex * effort

        // Both legs drift towards the direction of travel, so the whole stance leads the shuffle
        // rather than the legs scissoring around a stationary centre.
        right.sideways += lateral * 0.12
        left.sideways += lateral * 0.12

        return (right, left)
    }

    /// How far the body has to sink for the lower foot to reach the floor.
    ///
    /// A leg posed by angle sweeps its foot round an arc, so the foot **rises at both ends of the
    /// stride** — the same reason a compass draws a curve and not a line. A person does not float
    /// up at mid-stride; their pelvis drops instead, and by exactly this much.
    ///
    /// This is where the walk's bounce comes from now. It used to be a hand-tuned
    /// `cos(2·phase) × 0.5` in the walk cycle, which is the same shape and the same phase by
    /// coincidence rather than by derivation: the geometry produces about a unit of drop at a
    /// full-throttle stride and nothing at mid-stance, on its own.
    static func groundContactSink(leftFoot: SIMD3<Float>, rightFoot: SIMD3<Float>) -> Float {
        min(max(min(leftFoot.z, rightFoot.z) - neutralLeftFoot.z, -3), 3)
    }

    /// **One foot's world frame: pitched to follow the shin, and stopped by the floor.**
    ///
    /// The rigid ankle of the previous session took the shin's own lean and gave it to the foot,
    /// which is right for a foot in the air and wrong for a foot on the ground — a shin rotates
    /// through a whole stride while the sole under it stays flat on the floor. What was missing
    /// was any way to know which of the two a foot was doing, and the answer turns out not to
    /// need the gait to say: **the floor already knows.** A foot whose shin lean would drive its
    /// toe through the ground is, by definition, a foot on the ground.
    ///
    /// So the rule is one sentence with no tuned number in it: *take the shin's pitch, and if it
    /// buries a corner of the sole, wind it back — by the least that lifts that corner onto the
    /// floor, and never past level.*
    ///
    /// Every property a real ankle has falls out of that:
    ///
    /// - **A planted foot is flat**, because level is where it gets stopped.
    /// - **A foot in the air keeps the whole of its shin pitch**, because nothing is in its way.
    ///   Heel strike stays toe-up and push-off stays toe-down; those are swing-phase poses.
    /// - **The release is smooth**, because the constraint slackens continuously as the ankle
    ///   rises — a 0.45 rad toe-down foot is level at the floor, 0.19 at four units up, and its
    ///   own pitch again by nine. Nothing pops.
    /// - **The heel lets go sooner than the toe**, because it is 3.3 from the ankle against the
    ///   toe's 10.8, and a short lever leaves the floor first. That is also the real asymmetry.
    ///
    /// "Never past level" is what makes it safe when the floor cannot be satisfied at all — an
    /// ankle dropped below its resting height by the pelvis sink has no pitch that lifts the sole
    /// out, and level is the best of a bad set, because level is where the two corners meet and
    /// therefore where the **lower** of them is highest. That last fact is exactly what makes the
    /// wind-back well defined in the first place: the lowest corner rises monotonically all the
    /// way from the shin's pitch to level, so "the least that lifts it" is a single answer.
    ///
    /// The arithmetic works on the columns of the composed frame rather than on the rig-local
    /// numbers, so the character's scale, the pelvis sink, the acceleration lean and the bank in
    /// a hard turn are all already in it. The bank is the one term that does not depend on the
    /// pitch — tipping sideways lowers a corner by an amount no amount of pitching recovers — so
    /// it comes in as a constant drop, taken on the worse side.
    static func shoeFrame(ankle: SIMD3<Float>, shin: SIMD3<Float>, bodyPivot: Float4x4) -> Float4x4 {
        let base = bodyPivot * Float4x4.translation(ankle)
        let rigid = atan2(-shin.x, -shin.z)

        // How much world height a unit along the foot and a unit up out of it are worth. After a
        // pitch of θ the foot's own axis is `cos θ · along − sin θ · up`, so it lies flat when
        // `cos θ · alongZ = sin θ · upZ` — that angle is `level`.
        let alongZ = base.columns.0.z, upZ = base.columns.2.z
        let level = atan2(alongZ, upZ)

        let sole = -shoeSoleBelowAnkle * shoeScale
        let originZ = base.columns.3.z
        let bankDrop = -abs(shoeHalfWidth * shoeScale * base.columns.1.z)
        // A corner at `along` sits at `originZ + bankDrop + radius · cos(θ − phase)`, which is
        // the whole of the geometry: one sinusoid per corner, and the floor is a line across it.
        let wanted = -footSink - originZ - bankDrop

        func cleared(along: Float) -> Float {
            let cosCoefficient = along * alongZ + sole * upZ
            let sinCoefficient = sole * alongZ - along * upZ
            let radius = (cosCoefficient * cosCoefficient
                          + sinCoefficient * sinCoefficient).squareRoot()
            guard radius > 1e-4 else { return level }
            let ratio = wanted / radius
            // Above the sinusoid's own crest: no pitch clears this corner, so take level.
            guard ratio <= 1 else { return level }
            let phase = atan2(sinCoefficient, cosCoefficient)
            guard radius * cos(rigid - phase) < wanted else { return rigid }
            let half = acos(max(-1, ratio))
            let low = phase - half, high = phase + half
            return abs(low - rigid) <= abs(high - rigid) ? low : high
        }

        // Take the most-corrected of the two, then clamp the whole thing to the run from the
        // shin's own pitch to level. The clamp is what makes a candidate on the far side of
        // `rigid` — a corner that pitching away from level would never have helped — a no-op.
        var pitch = rigid
        for along in [shoeToeAheadOfAnkle * shoeScale, -shoeHeelBehindAnkle * shoeScale] {
            let candidate = cleared(along: along)
            pitch = level >= rigid ? min(level, max(pitch, candidate))
                                   : max(level, min(pitch, candidate))
        }

        return base * Float4x4.rotationY(pitch)
    }

    /// **How high the lowest corner of a shoe is above the floor**, given that shoe's world frame
    /// — `RigPose.leftShoeBox` or `rightShoeBox`. Negative is under the floor.
    ///
    /// It exists because "how high is the sole" had until now been answered as *the origin's
    /// height, minus how far the sole hangs below the origin*, which is only true of a **level**
    /// foot. A foot pitched toe-down by 0.3 rad puts its toe three units lower than that answer,
    /// and three units is most of a shoe: the difference between a foot on the floor and a foot
    /// buried in it, invisible to every number the lab printed.
    ///
    /// Four corners rather than two, because the body pivot banks as well as pitches and a tipped
    /// foot's lowest point is a corner of the sole, not a point on its centre line. The frame
    /// carries the character's scale, so the corners come out in world units for free.
    static func soleClearance(_ shoeBox: Float4x4) -> Float {
        let sole = -shoeSoleBelowAnkle * shoeScale
        let halfWidth = shoeHalfWidth * shoeScale
        var lowest = Float.greatestFiniteMagnitude
        for along in [shoeToeAheadOfAnkle * shoeScale, -shoeHeelBehindAnkle * shoeScale] {
            for across in [halfWidth, -halfWidth] {
                let corner = shoeBox * SIMD4<Float>(along, across, sole, 1)
                lowest = min(lowest, corner.z)
            }
        }
        return lowest
    }

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
        pose.model = CharacterModels.path(for: character.model)

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
        var leftHand = neutralLeftHand
        var rightHand = neutralRightHand
        var leftFoot = neutralLeftFoot
        var rightFoot = neutralRightFoot

        // **The arms are gathered as joint angles and become hand targets once**, at the bottom
        // of this section. See `armTarget` for why: an arm swung by pushing its hand through
        // space is a straight stick on a hinge whose swing gets silently clamped, and no amount
        // of tuning the offsets makes it look like a person.
        //
        // Named for the *character's* sides, not the rig's — `leftHand` is the character's right
        // hand, which is a trap this file has fallen into before (see `Gait`). `sideways` is
        // signed absolutely, positive towards the character's left, so the two arms start out
        // mirrored and "both arms sweep left" is one number added to both.
        var rightArmSwing = neutralArmSwing, leftArmSwing = neutralArmSwing
        var rightArmSideways = -neutralArmSideways, leftArmSideways = neutralArmSideways
        var rightArmFlex = neutralArmFlex, leftArmFlex = neutralArmFlex

        // **And the legs, the same way**, for the same reasons — see `legTarget`. Named for the
        // character's sides too, so `rightLeg` is the leg whose foot is `leftFoot`. The stride
        // itself lives in `strideLegs` so the self-test can walk it through a whole cycle.
        var rightLeg = LegAngles.neutral
        var leftLeg = LegAngles.neutral
        leftLeg.sideways = -leftLeg.sideways

        let isWalking = gait.isMoving || gait.phase > 0

        // How far into a run this is, 0 walking and 1 flat out. It is the only thing separating
        // the two: everything below scales off `forward`/`effort`, which are now a genuine
        // fraction of a sprint rather than always ~1, and `run` adds the handful of things a
        // run does *differently* — higher knees, a deeper bounce, a forward lean.
        let run = Float(gait.run)

        // A twist at the waist, gathered here and spent once the body pivot is built. Positive
        // turns the chest towards the character's left.
        var waistTwist: Float = 0
        // How far the head turns off the chest to look where the body is going.
        var headTurn: Float = 0
        // And the rest of the head, which only the idle behaviour has anything to say about.
        var headPitch: Float = 0
        var headTilt: Float = 0

        // What this character is doing with itself while it stands there. Zero unless the idle
        // branch below fills it in; the body-pivot half of it is spent much further down, after
        // the inertia block, because that block *assigns* the pivot roll rather than adding to it.
        var idle = IdleBehaviour.Offsets()

        if isWalking {
            let legTimer = Float(gait.phase)
            let effort = Float(min(1.2, max(abs(gait.forward), abs(gait.lateral))))
            // The bounce is a **run's** now, not a walk's. A walk's pelvic drop used to be the
            // 0.5 term here, hand-tuned; it is derived from the legs instead — see the contact
            // correction below, which lands the same shape and the same phase out of the
            // geometry. What is left is the part a run does that a walk does not: leave the
            // ground.
            runtime.bodyPivotPosition.z = bodyPivotHeight
                + cos(legTimer * 2) * run * 1.8 * effort
            runtime.bodyPivotPosition.x = cos(legTimer * 2) * 1.0 * effort

            // applyWalkCycle (`characters.js:981-1001`), rewritten **as joint angles**: a hip
            // that swings, a hip that abducts, and — the part that did not exist before — a
            // knee that bends. See `strideLegs`.
            //
            // The amplitudes are a sprint's, not a walk's, and `forward` scales them. They used
            // to be a walk's, because a walk was the only thing a character could be doing:
            // `forward` was pinned at ~1 whatever speed the profile was set to. Now the stick's
            // throttle decides the speed and `forward` is a real fraction of top speed, so a
            // stick half over gets half the step — which is where the walk lives.
            let legSwing = sin(legTimer)

            let forward = Float(gait.forward)
            let lateral = Float(gait.lateral)

            (rightLeg, leftLeg) = strideLegs(phase: legTimer,
                                             forward: forward,
                                             lateral: lateral,
                                             run: run,
                                             effort: effort)

            // The arms swing **about the shoulder**, and the elbow does something.
            //
            // The phase trails the legs by a fifth of a step, because an arm is thrown by the
            // shoulder rather than wired to the opposite hip: a walk where the hand and the
            // contralateral foot reach the front on the same frame is the metronome look that
            // gives a rig away.
            let armPhase = legTimer - 0.35
            let armSweep = sin(armPhase)
            let swingAmplitude = (0.62 + run * 0.34) * forward
            rightArmSwing -= armSweep * swingAmplitude
            leftArmSwing += armSweep * swingAmplitude

            // **The elbow is the tell.** A walking arm hangs nearly straight and folds a little
            // as it comes through the front; a running one is carried at a right angle the whole
            // way round and closes further still at the front. This is the single biggest
            // difference between a walk and a run in a human, and the old hand-displacement
            // swing had no way at all to say it — the elbow angle was whatever fell out of how
            // far the hand happened to be from the shoulder.
            let carriedFlex = run * 0.55
            let pumpFlex = (0.30 + run * 0.40) * effort
            rightArmFlex += carriedFlex + max(0, -armSweep) * pumpFlex
            leftArmFlex += carriedFlex + max(0, armSweep) * pumpFlex

            // An arm also comes **across the body** at the front and opens out again at the
            // back. A swing kept in one plane is a pendulum on a bracket; the small sideways
            // component is most of what is left of the difference.
            let across = (0.12 + run * 0.10) * abs(forward)
            rightArmSideways += max(0, -armSweep) * across
            leftArmSideways -= max(0, armSweep) * across

            // Side-stepping throws the arms out for balance instead of pumping them; running
            // tucks the elbows in against the ribs.
            let heldOut = abs(lateral) * 0.26 - run * 0.10
            rightArmSideways -= heldOut
            leftArmSideways += heldOut

            // The shoulders counter-rotate against the hips once per step, opposite to the arm
            // swing — the arm going forward belongs to the shoulder coming forward. Without it
            // a walk is a mannequin on rails with its arms wagging, and it costs one term.
            waistTwist += -legSwing * forward * 0.16 * effort
        } else if emoteDefinition == nil {
            // Standing *and* not posed by an emote. When an emote is running the JS leaves the
            // body pivot wherever the emote put it, so a `wave` that started mid-stride keeps
            // the last frame's walk bob until it ends.
            runtime.bodyPivotPosition.z = bodyPivotHeight
            runtime.bodyPivotPosition.x = 0

            // applyIdleSway (`characters.js:1003-1013`), in the joints rather than in the hand
            // positions. 0.025 rad on a 16.4-unit arm is the 0.4 units of x the JS swayed by;
            // the breath is the elbow opening and closing a fraction instead of the hand
            // sliding up and down, which is what a hanging arm actually does.
            let armSwayAngle = Float(cos(idleTime * 1.5)) * 0.025
            rightArmSwing += armSwayAngle
            leftArmSwing -= armSwayAngle
            let breathFlex = Float(sin(idleTime * 2.0)) * 0.10
            rightArmFlex += breathFlex
            leftArmFlex += breathFlex

            // **And the part that is not a sine wave.** The sway above is what the JS did and it
            // is the same on every character in the scene; `IdleBehaviour` is what makes one
            // pupil stand differently from the pupil beside them and do something occasionally.
            // It is handed the wall clock rather than a per-character timer, so every client
            // watching the same NPC sees the same fidget at the same moment.
            idle = IdleBehaviour.offsets(seed: IdleBehaviour.seed(for: character.id),
                                         time: time,
                                         legSpan: neutralLegSpan)

            rightLeg.swing += idle.rightLeg.swing
            rightLeg.sideways += idle.rightLeg.sideways
            rightLeg.flex += idle.rightLeg.flex
            leftLeg.swing += idle.leftLeg.swing
            leftLeg.sideways += idle.leftLeg.sideways
            leftLeg.flex += idle.leftLeg.flex

            waistTwist += idle.chestTwist
            headTurn += idle.headTurn
            headPitch += idle.headPitch
            headTilt += idle.headTilt
        }

        // --- Counteracting the inertia ---
        //
        // A character changing direction is being shoved about by its own feet, and the tell of
        // a game that skips this is a body that slides onto a new heading with its legs still
        // doing a tidy forward walk. Four things happen instead, all off signals `Locomotion`
        // already resolves and none of them needing to know what the character is doing or why:
        //
        //   * **A foot steps out to brace.** To be pushed left you plant your right foot out to
        //     the right and shove off it. The outboard foot goes wide and the inboard one tucks
        //     under to get out of its way. This is the one you can see from across the room.
        //   * **The hands counterweight.** Both swing towards the acceleration and the trailing
        //     one crosses the chest, which is the shape someone cutting inside makes.
        //   * **The feet plant ahead to brake** and drive out behind to accelerate.
        //   * **The shoulders trail the hips through a turn**, and the head leads it.
        //
        // The signs, once, carefully. Local +Y is the character's **left**, so `leftFoot`
        // (y = −6) is the character's *right* foot — the rig's names run the other way round,
        // see the note in `Gait`. `gait.leanLateral` is positive for an acceleration towards the
        // character's left; `gait.turning` is positive for a turn towards their right.
        let brace = Float(gait.leanLateral)
        let braking = max(0, -Float(gait.leanForward))
        let driving = max(0, Float(gait.leanForward))

        // How far the pushing leg abducts, and how far the other one gets out of its way. 0.31
        // and 0.12 rad are the 6.5 and 2.5 units these used to be, on a 20.8-unit leg.
        let stepOut: Float = 0.31, tuckIn: Float = 0.12
        if brace > 0 {
            // Pushed towards the character's left: their right leg plants out to the right,
            // which is towards local −Y, which is a negative `sideways`.
            rightLeg.sideways -= brace * stepOut
            leftLeg.sideways -= brace * tuckIn
        } else {
            leftLeg.sideways -= brace * stepOut
            rightLeg.sideways -= brace * tuckIn
        }
        // And the braced knee bends to take the load — the thing a leg posed by displacement
        // could not be asked for. A cut taken on two locked legs is a mannequin being slid
        // sideways, and the hips sink with it.
        rightLeg.flex += abs(brace) * 0.20
        leftLeg.flex += abs(brace) * 0.20
        runtime.bodyPivotPosition.z -= abs(brace) * 1.5

        // Stopping means getting a foot in front of your own weight; starting means leaving both
        // behind it. Braking also **bends both knees**, because that is what absorbs it: a stop
        // is taken in the legs, not by sliding to a halt on two straight ones.
        let checkStep = braking * 0.24 - driving * 0.15
        rightLeg.swing += checkStep
        leftLeg.swing += checkStep
        rightLeg.flex += braking * 0.35
        leftLeg.flex += braking * 0.35

        // The counterweight. Both arms sweep towards the acceleration, which puts the trailing
        // one across the chest and throws the leading one wide — the shape someone cutting
        // inside makes. The elbows close at the same time, because a folded arm is a shorter
        // lever and comes round faster, which is exactly why people do it.
        rightArmSideways += brace * 0.42
        leftArmSideways += brace * 0.42
        rightArmFlex += abs(brace) * 0.35
        leftArmFlex += abs(brace) * 0.20

        // Stopping throws the hands back behind the body; setting off throws them forward.
        let checkSwing = driving * 0.30 - braking * 0.40
        rightArmSwing += checkSwing
        leftArmSwing += checkSwing

        // --- An idle gesture takes an arm over ---
        //
        // Everything else on this page is an offset from the hanging arm, because everything else
        // *is* the hanging arm doing something. Reaching for your own face is not; it is a
        // different pose, and the only honest way to write it is where the arm ends up. So these
        // crossfade rather than add, and they do it last, after the swing and the counterweight
        // have had their say — a hand on its way to a nose does not also need to be bracing.
        func reach(_ swing: inout Float, _ side: inout Float, _ flex: inout Float,
                   _ arm: IdleBehaviour.ArmReach?) {
            guard let arm else { return }
            swing += (arm.swing - swing) * arm.weight
            side += (arm.sideways - side) * arm.weight
            flex += (arm.flex - flex) * arm.weight
        }
        reach(&rightArmSwing, &rightArmSideways, &rightArmFlex, idle.rightArm)
        reach(&leftArmSwing, &leftArmSideways, &leftArmFlex, idle.leftArm)

        // --- The arms become hand targets ---
        // Capped short of horizontal: past about 75° out, an arm is being held up rather than
        // swung, and none of the signals above mean that.
        func sideways(_ angle: Float) -> Float { min(max(angle, -1.3), 1.3) }
        leftHand = armTarget(shoulder: leftShoulder,
                             swing: rightArmSwing,
                             sideways: sideways(rightArmSideways),
                             flex: rightArmFlex)
        rightHand = armTarget(shoulder: rightShoulder,
                              swing: leftArmSwing,
                              sideways: sideways(leftArmSideways),
                              flex: leftArmFlex)

        // --- The legs become foot targets ---
        // A hip has far less range than a shoulder: it swings freely fore and aft and hardly
        // abducts at all, which is why the two caps are so different.
        func hipSideways(_ angle: Float) -> Float { min(max(angle, -0.6), 0.6) }
        func hipSwing(_ angle: Float) -> Float { min(max(angle, -1.1), 1.1) }
        leftFoot = legTarget(hip: leftHip,
                             swing: hipSwing(rightLeg.swing),
                             sideways: hipSideways(rightLeg.sideways),
                             flex: rightLeg.flex)
        rightFoot = legTarget(hip: rightHip,
                              swing: hipSwing(leftLeg.swing),
                              sideways: hipSideways(leftLeg.sideways),
                              flex: leftLeg.flex)

        // --- Keeping the planted foot on the floor ---
        //
        // See `groundContactSink`: a leg posed by angle sweeps its foot round an arc, and what
        // stops the character floating up it is the pelvis dropping, exactly as a person's does.
        // Scaled back as the run comes in, because a sprint genuinely does leave the ground and
        // pinning the lower foot to the floor would take the flight phase away.
        runtime.bodyPivotPosition.z -= groundContactSink(leftFoot: leftFoot, rightFoot: rightFoot)
            * (1 - run * 0.35)

        // A turn is led from the pelvis and the chest catches up, so the waist twists *against*
        // the turn while it is happening — while the head goes the other way and looks where the
        // body is heading. Turning right (`turning` > 0) leaves the chest facing left of the
        // hips, which is a positive `chestTwist`.
        waistTwist += Float(gait.turning) * 0.30
        headTurn -= Float(gait.turning) * 0.35

        // --- Lean into the acceleration ---
        // Nothing in the JS does this; it is what sells the inertia `Locomotion` introduced.
        // Rotation about local Y tips "up" towards +X, so a positive angle leans forward; about
        // local X it tips towards −Y, so the sign flips for a bank to the character's left.
        // Capped well short of anything that would put a shoulder through the floor.
        let maxLean: Float = 0.22
        runtime.bodyPivotRotation.y += min(maxLean, max(-maxLean, Float(gait.leanForward) * maxLean))
        runtime.bodyPivotRotation.x = min(maxLean, max(-maxLean, Float(-gait.leanLateral) * maxLean))
        // A sprint is run leaning into, whether or not it is still gathering speed — the
        // acceleration lean above has nothing left to give once the character is at top speed.
        runtime.bodyPivotRotation.y += run * 0.12

        // --- And the idle behaviour's half of the body pivot ---
        //
        // Down here, and not up in the idle branch, for one reason: the lean block immediately
        // above **assigns** `bodyPivotRotation.x` rather than adding to it, so a roll written any
        // earlier is thrown away. `.y` is left alone by nobody and could have gone either side.
        //
        // The lateral shift is what a weight shift actually is — the hips move over one foot —
        // and it is applied here as a translation rather than being folded into the legs, because
        // the legs have already been given the counter-angle that keeps their feet on the ground.
        runtime.bodyPivotPosition.x += idle.hipShift.x
        runtime.bodyPivotPosition.y = idle.hipShift.y
        runtime.bodyPivotPosition.z += idle.hipShift.z
        runtime.bodyPivotRotation.x += idle.lean.x
        runtime.bodyPivotRotation.y += idle.lean.y

        // --- Emote overrides (`applyEmoteOverrides:1015-1026`) ---
        var mutation = RigMutation(bodyPivotPosition: runtime.bodyPivotPosition,
                                   bodyPivotRotation: runtime.bodyPivotRotation,
                                   headRotation: runtime.headRotation,
                                   leftHandTarget: leftHand,
                                   rightHandTarget: rightHand,
                                   leftFootTarget: leftFoot,
                                   rightFootTarget: rightFoot,
                                   chestTwist: waistTwist,
                                   holding: character.holding)

        if let emoteDefinition, let emote {
            // Both branches kill the idle sway before posing.
            mutation.bodyPivotRotation.y = 0
            // And the waist, for the same reason: an emote's pose was authored against a square
            // pair of shoulders. A minigame that wants a coil adds one back in its `override`,
            // which runs after this — that is what the tennis swing does.
            mutation.chestTwist = 0
            headTurn = 0; headPitch = 0; headTilt = 0
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

        // The head looks where the body is going. Added *after* the write-back on purpose:
        // `runtime.headRotation` survives between frames, so anything folded into it would
        // accumulate a frame at a time until the character was looking over its own shoulder.
        // This is a view of it for this frame only.
        let headRotation = runtime.headRotation + SIMD3<Float>(headTilt, headPitch, headTurn)

        let bodyPivot = meshGroup
            * Float4x4.translation(runtime.bodyPivotPosition)
            * Float4x4.eulerXYZ(runtime.bodyPivotRotation.x,
                                runtime.bodyPivotRotation.y,
                                runtime.bodyPivotRotation.z)

        // --- The waist ---
        //
        // Everything above the hips hangs off `chest`, everything below off `bodyPivot`. The
        // only difference between them is `chestTwist`, a rotation about the body's up axis —
        // and that one rotation is the difference between a person turning into a shot and a
        // chess piece being twisted on its base. The tennis coil used to be
        // `bodyPivotRotation.z`, which turns the feet with the shoulders.
        //
        // Hand targets are written in the **body** frame and stay that way; they are rotated
        // into the chest's frame only for the arm IK, and rotated back for anything world-facing.
        // A caller aiming a hand at a point in space therefore never has to know the chest has
        // moved, which is the property that lets `CharacterMotor` stay ignorant of tennis.
        let chestTwist = mutation.chestTwist
        let chest = bodyPivot * Float4x4.rotationZ(chestTwist)

        let twistCos = cos(-chestTwist), twistSin = sin(-chestTwist)
        func intoChest(_ point: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(point.x * twistCos - point.y * twistSin,
                  point.x * twistSin + point.y * twistCos,
                  point.z)
        }

        // --- Torso and pelvis ---
        // Both are lathes standing on +Y, so `rotationX(π/2)` turns them upright. The breath
        // swells the chest only — nobody's hips inflate when they inhale.
        let torso = chest
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
        let neck = chest
            * Float4x4.translation(neckBase)
            * Float4x4.eulerXYZ(headRotation.x * neckFollowsHead,
                                headRotation.y * neckFollowsHead,
                                headRotation.z * neckFollowsHead)
            * Float4x4.translation(SIMD3(0, 0, neckLength / 2))
            * Float4x4.rotationX(.pi / 2)
        pose.parts.append((.neck, neck))

        // --- Head (`buildSkeletonRig:810-812` + `applyHeadModel:209-213`) ---
        // The head *group* — props parented to it (laser beams, tears, crumbs) inherit this
        // whole transform, including the non-uniform 0.65/0.65/0.7 scale.
        let headAnchor = chest
            * Float4x4.translation(SIMD3(2, 0, 36))
            * Float4x4.eulerXYZ(headRotation.x, headRotation.y, headRotation.z)
            * Float4x4.scale(SIMD3(0.65, 0.65, 0.7))

        pose.headTransform = headAnchor

        // --- Inverse kinematics (`resolveInverseKinematics:1028-1079`) ---
        // Ankles ride `ankleLift` above the foot target so calves do not punch through the shoes.
        // `legTarget` aims at the ankle and subtracts it back off, so the two agree.
        var leftAnkle = leftFoot;  leftAnkle.z += ankleLift
        var rightAnkle = rightFoot; rightAnkle.z += ankleLift

        // The arms are solved in the **chest** frame, so a turn at the waist carries the whole
        // shoulder girdle with it and the arms stay attached to it. `IKSolver.solve` clamps an
        // out-of-reach target in place, so `leftHandChest` comes back as where the hand really
        // ended up — which is why the hand and the forearm are drawn from it rather than from
        // what was asked for.
        var leftHandChest = intoChest(leftHand)
        var rightHandChest = intoChest(rightHand)

        let leftElbow = IKSolver.solve(start: leftShoulder, end: &leftHandChest,
                                       l1: armBone, l2: armBone, bendingNormal: bendNormalArmL)
        let rightElbow = IKSolver.solve(start: rightShoulder, end: &rightHandChest,
                                        l1: armBone, l2: armBone, bendingNormal: bendNormalArmR)
        let leftKnee = IKSolver.solve(start: leftHip, end: &leftAnkle,
                                      l1: thighBone, l2: shinBone, bendingNormal: bendNormalLegL)
        let rightKnee = IKSolver.solve(start: rightHip, end: &rightAnkle,
                                       l1: thighBone, l2: shinBone, bendingNormal: bendNormalLegR)

        func append(_ part: RigPart, _ start: SIMD3<Float>, _ end: SIMD3<Float>, in frame: Float4x4) {
            if let local = IKSolver.segmentTransform(start: start, end: end) {
                pose.parts.append((part, frame * local))
            }
        }

        append(.leftUpperArm, leftShoulder, leftElbow, in: chest)
        append(.leftLowerArm, leftElbow, leftHandChest, in: chest)
        append(.rightUpperArm, rightShoulder, rightElbow, in: chest)
        append(.rightLowerArm, rightElbow, rightHandChest, in: chest)
        append(.leftUpperLeg, leftHip, leftKnee, in: bodyPivot)
        append(.leftLowerLeg, leftKnee, leftAnkle, in: bodyPivot)
        append(.rightUpperLeg, rightHip, rightKnee, in: bodyPivot)
        append(.rightLowerLeg, rightKnee, rightAnkle, in: bodyPivot)

        // --- Joints ---
        // Two capsules meeting at an angle cross through each other and leave a ridge where
        // their surfaces intersect. A ball fractionally wider than either turns that ridge into
        // a bulge, which is what an elbow, a knee and a shoulder actually look like — and it is
        // what lets the limbs taper without opening a step at the join.
        //
        // The deltoids are turned to follow the humerus so their long axis lies along the arm.
        // Elbows and knees are spheres and need no orientation.
        func joint(_ part: RigPart,
                   at position: SIMD3<Float>,
                   in frame: Float4x4,
                   alignedTo direction: SIMD3<Float>? = nil) {
            var transform = frame * Float4x4.translation(position)
            if let direction {
                transform = transform * IKSolver.rotationFromUnitY(to: direction)
            }
            pose.parts.append((part, transform))
        }

        joint(.leftShoulder, at: leftShoulder, in: chest,
              alignedTo: safeDirection(from: leftShoulder, to: leftElbow))
        joint(.rightShoulder, at: rightShoulder, in: chest,
              alignedTo: safeDirection(from: rightShoulder, to: rightElbow))
        joint(.leftElbow, at: leftElbow, in: chest)
        joint(.rightElbow, at: rightElbow, in: chest)
        joint(.leftKnee, at: leftKnee, in: bodyPivot)
        joint(.rightKnee, at: rightKnee, in: bodyPivot)

        // --- Hands ---
        //
        // A hand needs a **basis**, not a direction. `quaternionFromUnitY` pins where the
        // forearm points and leaves the roll about it arbitrary, which is why the hand used to
        // be a mitt revolved about the wrist: anything with a front and a back would have spun
        // freely. `IKSolver.basis` fixes the roll against the arm's own bending normal — the
        // vector the elbow already articulates about — so the palm faces the way the elbow
        // bends, which is what a palm does, and the thumb has somewhere to be.
        let leftForearmRotation = IKSolver.basis(alongY: safeDirection(from: leftElbow, to: leftHandChest),
                                                 rolledTowards: bendNormalArmL)
        let rightForearmRotation = IKSolver.basis(alongY: safeDirection(from: rightElbow, to: rightHandChest),
                                                  rolledTowards: bendNormalArmR)
        let leftHandAnchor = chest * Float4x4.translation(leftHandChest) * leftForearmRotation
        let rightHandAnchor = chest * Float4x4.translation(rightHandChest) * rightForearmRotation

        // The hand *mesh* is rolled about the forearm; the **anchor is not** — see
        // `Hand.restRoll`. Everything that rides in a hand hangs off the anchor, and the racket's
        // grip was tuned against the unrolled frame.
        //
        // This reaches the imported body by the right route: the
        // renderer builds each bone as `transform × inverseBind`, and `bindPose` does *not* apply
        // the roll — so the hand is built unrolled and turned at draw time, rather than being
        // baked into the mesh and cancelled straight back out again.
        let handRoll = Float4x4.rotationY(Hand.restRoll)
        pose.parts.append((.leftHand, leftHandAnchor * handRoll))
        pose.parts.append((.rightHand, rightHandAnchor * handRoll))

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
        //
        // The shoe pitches to follow the shin, staying square to it the way an ankle with no
        // joint of its own does; the model itself is rotated out of its Y-up export into the
        // game's X-forward / Z-up frame.
        //
        // **The pitch used to read `shin.y`, which is sideways.** In this frame — the character's
        // own, +X forward, +Y left, +Z up — a leg swinging fore and aft moves entirely in X and
        // Z, so the old angle came out 0 for the whole of every gait and the shoes stayed dead
        // level from heel strike to push-off. It only ever moved on the small sideways component
        // a hip abduction leaves, which is a shoe rolling for no reason rather than pitching for
        // a good one. The line reads as a faithful port of a three.js expression whose Y *was*
        // up; here it is not.
        //
        // Square to the shin means the shin's own rotation away from vertical, applied backwards:
        // `rotationY` takes +X down as its angle grows, and a shin leaning forward should take
        // the toe *up*. Hence the negated X.
        //
        // **And then the floor gets a say**, which is `shoeFrame` below — because square to the
        // shin is only the right answer for a foot that is in the air. A standing character's
        // shin is not vertical: the neutral leg is 0.096 rad forward of the hip with a 0.583 rad
        // knee, which leaves the shin leaning 0.222 rad *back* and put the toe of every standing
        // shoe 2.7 units under the floor. Nothing caught it because a foot's pitch is invisible
        // from the front, which is the view a flat sole was checked in.
        let leftShin = leftAnkle - leftKnee
        let rightShin = rightAnkle - rightKnee
        let leftShoeGroup = shoeFrame(ankle: leftAnkle, shin: leftShin, bodyPivot: bodyPivot)
        let rightShoeGroup = shoeFrame(ankle: rightAnkle, shin: rightShin, bodyPivot: bodyPivot)

        pose.leftShoeBox = leftShoeGroup
        pose.rightShoeBox = rightShoeGroup

        // --- Shadow blob (`buildShadowBlob:903-921`) ---
        // On the **ground**, not on the character. It used to hang off `meshGroup`, which
        // carries the character's height — fine while nothing was ever off the ground, and
        // wrong the moment `CharacterMotor` made the jump real: the shadow went up with the
        // jumper. It keeps the heading and the scale and drops the height.
        pose.shadowTransform = Float4x4.translation(SIMD3(renderX, renderY, 0.5))
            * Float4x4.rotationZ(Float(-(character.rotation ?? 0)) * degToRad)
            * Float4x4.scale(SIMD3(repeating: maxScale))

        return pose
    }

    // MARK: - Bind pose

    /// The rig standing still, with the character at the world origin facing +X.
    ///
    /// **What it is for now.** It used to be the space the procedural body's vertices were
    /// generated in. Nothing generates vertices any more, but `HumanoidRig` measures against
    /// this: how long the rig's own arm is, where its ankle sits, which way its thumb points —
    /// every constant the retargeter compares a bought skeleton to comes from here.
    ///
    /// It has to agree with what `pose` produces for a still, un-emoting character — same
    /// constants, same order, same IK. It is written out separately rather than obtained by
    /// calling `pose` because `pose` needs a `GameCharacter`, a `RigRuntime` and a clock, and
    /// bakes in breathing and idle sway that have no business in a rest pose.
    ///
    /// Getting it *wrong* is not fatal, which is worth knowing before reading the next hundred
    /// lines nervously: the mesh is built in whatever space this returns and skinned back out of
    /// it, so a disagreement shows up as a body that is subtly the wrong shape everywhere, not
    /// as a crash or a limb in the wrong place.
    static func bindPose() -> RigBindPose {
        let bodyPivot = Float4x4.translation(SIMD3(0, 0, bodyPivotHeight))
        // No waist twist and no emote at rest, so the chest is the body pivot.
        let chest = bodyPivot

        var bones: [RigPart: Float4x4] = [:]
        bones[.torso] = chest
            * Float4x4.translation(SIMD3(0, 0, torsoCentreZ))
            * Float4x4.rotationX(.pi / 2)
        bones[.pelvis] = bodyPivot
            * Float4x4.translation(SIMD3(0, 0, pelvisCentreZ))
            * Float4x4.rotationX(.pi / 2)
        bones[.neck] = chest
            * Float4x4.translation(neckBase)
            * Float4x4.translation(SIMD3(0, 0, neckLength / 2))
            * Float4x4.rotationX(.pi / 2)

        // The neutral limb targets, run through the same IK `pose` uses. `solve` clamps its
        // `end` in place, so these come back as where the hand and ankle really ended up.
        var leftWrist = neutralLeftHand
        var rightWrist = neutralRightHand
        var leftAnkle = neutralLeftFoot;  leftAnkle.z += ankleLift
        var rightAnkle = neutralRightFoot; rightAnkle.z += ankleLift

        let leftElbow = IKSolver.solve(start: leftShoulder, end: &leftWrist,
                                       l1: armBone, l2: armBone, bendingNormal: bendNormalArmL)
        let rightElbow = IKSolver.solve(start: rightShoulder, end: &rightWrist,
                                        l1: armBone, l2: armBone, bendingNormal: bendNormalArmR)
        let leftKnee = IKSolver.solve(start: leftHip, end: &leftAnkle,
                                      l1: thighBone, l2: shinBone, bendingNormal: bendNormalLegL)
        let rightKnee = IKSolver.solve(start: rightHip, end: &rightAnkle,
                                       l1: thighBone, l2: shinBone, bendingNormal: bendNormalLegR)

        func segment(_ part: RigPart, _ start: SIMD3<Float>, _ end: SIMD3<Float>, in frame: Float4x4) {
            if let local = IKSolver.segmentTransform(start: start, end: end) {
                bones[part] = frame * local
            }
        }

        segment(.leftUpperArm, leftShoulder, leftElbow, in: chest)
        segment(.leftLowerArm, leftElbow, leftWrist, in: chest)
        segment(.rightUpperArm, rightShoulder, rightElbow, in: chest)
        segment(.rightLowerArm, rightElbow, rightWrist, in: chest)
        segment(.leftUpperLeg, leftHip, leftKnee, in: bodyPivot)
        segment(.leftLowerLeg, leftKnee, leftAnkle, in: bodyPivot)
        segment(.rightUpperLeg, rightHip, rightKnee, in: bodyPivot)
        segment(.rightLowerLeg, rightKnee, rightAnkle, in: bodyPivot)

        bones[.leftHand] = chest * Float4x4.translation(leftWrist)
            * IKSolver.basis(alongY: safeDirection(from: leftElbow, to: leftWrist),
                             rolledTowards: bendNormalArmL)
        bones[.rightHand] = chest * Float4x4.translation(rightWrist)
            * IKSolver.basis(alongY: safeDirection(from: rightElbow, to: rightWrist),
                             rolledTowards: bendNormalArmR)

        // The joint anchors again, this time in bind space rather than in the chest's or the
        // body pivot's, because that is the space the mesh is swept in.
        func into(_ frame: Float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
            let v = frame * SIMD4(point, 1)
            return SIMD3(v.x, v.y, v.z)
        }

        return RigBindPose(
            bones: bones,
            leftArm: (into(chest, leftShoulder), into(chest, leftElbow), into(chest, leftWrist)),
            rightArm: (into(chest, rightShoulder), into(chest, rightElbow), into(chest, rightWrist)),
            leftLeg: (into(bodyPivot, leftHip), into(bodyPivot, leftKnee), into(bodyPivot, leftAnkle)),
            rightLeg: (into(bodyPivot, rightHip), into(bodyPivot, rightKnee), into(bodyPivot, rightAnkle))
        )
    }

    private static func safeDirection(from: SIMD3<Float>, to: SIMD3<Float>) -> SIMD3<Float> {
        let delta = to - from
        let length = simd_length(delta)
        return length > 1e-6 ? delta / length : SIMD3(0, 1, 0)
    }
}
