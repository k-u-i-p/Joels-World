import Metal
import simd

/// Which of the rig's colours a vertex takes.
///
/// The body used to be twenty draw calls, one per part, and the colour came from the draw. It
/// is one draw now, so the colour has to travel *with the vertex*: this is an index into a
/// palette the shader is handed alongside the joint matrices. Hair and shoe are absent because
/// the head and shoe GLBs are still drawn the old way.
enum ColorSlot: Float {
    case skin = 0
    case shirt = 1
    case arm = 2
    case pants = 3
    /// Collars, cuffs and socks. **No vertex ever carries this one** — it is in the palette
    /// because the *texture* chooses it, per texel, and the shader needs somewhere to read it
    /// from. See `ClothingAtlas`.
    case trim = 4
}

/// A vertex of the skinned body. Layout must match `SkinVertex` in `Shaders.metal`.
///
/// The joint indices are floats rather than the `ushort4` a glTF file would use. It costs eight
/// bytes a vertex on a mesh of about three thousand, and it buys the guarantee that Swift's and
/// Metal's ideas of where each field starts cannot silently disagree — every member is four-byte
/// or sixteen-byte aligned in both languages, in the same order, with nothing implicit.
struct SkinVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    /// How much each of `joints` moves this vertex. Sums to 1.
    var weights: SIMD4<Float>
    /// Indices into the joint matrix array. Unused slots carry a zero weight.
    var joints: SIMD4<Float>
    var uv: SIMD2<Float>
    /// `ColorSlot.rawValue`.
    var colorSlot: Float
    var pad: Float = 0
}

struct SkinMeshData {
    var vertices: [SkinVertex] = []
    var indices: [UInt32] = []
}

/// Vertex and index buffers for the skinned body, plus the bind-pose inverses the joint
/// matrices are built from.
final class GPUSkinMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// `bind⁻¹` per bone, indexed by `SkinnedBody.boneOrder`. Multiplying this frame's transform
    /// by it gives the matrix that carries a bind-space vertex to where it belongs now.
    let inverseBind: [Float4x4]

    init?(device: MTLDevice, mesh: SkinMeshData, inverseBind: [Float4x4]) {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              let vertexBuffer = device.makeBuffer(bytes: mesh.vertices,
                                                   length: MemoryLayout<SkinVertex>.stride * mesh.vertices.count,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                                  length: MemoryLayout<UInt32>.stride * mesh.indices.count,
                                                  options: .storageModeShared)
        else { return nil }

        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = mesh.indices.count
        self.inverseBind = inverseBind
    }
}

/// **The body as one skinned mesh.**
///
/// The rig used to be a string of separate solids — a capsule per limb segment, with a sphere
/// stuffed into every elbow, knee and shoulder to hide the seam where two of them crossed. It
/// worked, and from a distance it reads as a body, but the joints are balls: bend an arm far
/// enough and you can see the three pieces it is made of. Nothing about a taper or a nicer
/// silhouette fixes that, because the surfaces genuinely are separate.
///
/// So they are not separate any more. An arm is **one continuous tube** swept from the shoulder
/// through the elbow to the wrist, and the vertices near the elbow are moved by a blend of the
/// upper arm's bone and the forearm's rather than by one or the other. The joint stops being a
/// gap that needs filling and becomes a crease, which is what an elbow is.
///
/// Nothing was modelled by hand to do this. The rig already knew where every joint sits
/// (`CharacterRig.bindPose`) and how thick a limb is at each end (`shoulderEndScale` and
/// friends); the geometry and the weights are both generated from those. That is the whole
/// trick and it is why this is a few hundred lines rather than an art commission.
///
/// What it does **not** do is turn these into the modelled characters in a shop-bought asset:
/// there is still no collar, no cuff, no sock roll, and the face is whatever the head GLB
/// already carried. Those are authored details, and no amount of sweeping tubes invents them.
enum SkinnedBody {

    /// The bones, in the order the shader's joint array expects. Elbows, knees and shoulders
    /// are not among them — they were never joints, only the plaster over one.
    static let boneOrder: [RigPart] = [
        .pelvis, .torso, .neck,
        .leftUpperArm, .leftLowerArm, .leftHand,
        .rightUpperArm, .rightLowerArm, .rightHand,
        .leftUpperLeg, .leftLowerLeg,
        .rightUpperLeg, .rightLowerLeg,
    ]

    /// Fixed array size on the shader side, so the uniform block never changes shape.
    static let boneCount = 16
    /// `ColorSlot` count. The palette is uploaded as this many colours then this many
    /// roughness/metalness pairs.
    static let paletteCount = 5

    static let boneIndex: [RigPart: Int] = {
        var map: [RigPart: Int] = [:]
        for (index, part) in boneOrder.enumerated() { map[part] = index }
        return map
    }()

    // MARK: - Building

    /// Builds the body in bind space and returns it alongside the bind inverses.
    static func build() -> (mesh: SkinMeshData, inverseBind: [Float4x4]) {
        let bind = CharacterRig.bindPose()
        var out = SkinMeshData()

        appendBody(&out, bind: bind)
        appendArms(&out, bind: bind)
        appendLegs(&out, bind: bind)

        recomputeNormals(&out)

        var inverseBind = [Float4x4](repeating: matrix_identity_float4x4, count: boneCount)
        for (index, part) in boneOrder.enumerated() {
            if let matrix = bind.bones[part] { inverseBind[index] = matrix.inverse }
        }
        return (out, inverseBind)
    }

    // MARK: - Torso, pelvis, neck and hands
    //
    // These four keep the meshes they always had. A lathe with a waistline and a hem that hangs
    // over the shorts is already the right shape; what it lacked was any way to bend. All that
    // is added here is weights — which is the cheap half of skinning, and on the body it is the
    // whole win: a torso weighted partly to the pelvis has a waist that twists.

    private static func appendBody(_ out: inout SkinMeshData, bind: RigBindPose) {
        var torso = MeshFactory.revolved(profile: CharacterRig.torsoProfile, radialSegments: 24)
        MeshFactory.applyScale(&torso, CharacterRig.torsoSquash)
        append(torso, into: &out, bind: bind.bones[.torso] ?? matrix_identity_float4x4,
               slot: .shirt, region: .torso,
               uv: { local, world in
                   // Bottom of the profile to the top: the hem of the shirt to the neck root.
                   SIMD2(facing(world), (local.y - profileFloor(CharacterRig.torsoProfile))
                                        / profileHeight(CharacterRig.torsoProfile))
               }) { local, _ in
            // Read on the lathe's own axis, which stands on +Y before the transform turns it
            // upright: −6.4 is the hem of the shirt and 13.6 is where the neck leaves it.
            var weights = SkinWeights()
            weights.add(.pelvis, 0.5 * (1 - smoothstep((local.y + 6.0) / 3.6)))
            weights.add(.neck, 0.45 * smoothstep((local.y - 9.5) / 4.1))
            weights.fill(.torso)
            return weights
        }

        var pelvis = MeshFactory.revolved(profile: CharacterRig.pelvisProfile, radialSegments: 24)
        MeshFactory.applyScale(&pelvis, CharacterRig.pelvisSquash)
        append(pelvis, into: &out, bind: bind.bones[.pelvis] ?? matrix_identity_float4x4,
               slot: .pants, region: .pelvis,
               uv: { local, world in
                   SIMD2(facing(world), (local.y - profileFloor(CharacterRig.pelvisProfile))
                                        / profileHeight(CharacterRig.pelvisProfile))
               }) { local, world in
            var weights = SkinWeights()
            weights.add(.torso, 0.45 * smoothstep((local.y - 2.4) / 2.6))
            // The bottom of the shorts goes with whichever thigh is leaving through it, so a
            // raised knee lifts the hem on that side instead of dragging the whole pelvis.
            let leg = simd_distance(world, bind.leftLeg.root) < simd_distance(world, bind.rightLeg.root)
                ? RigPart.leftUpperLeg : RigPart.rightUpperLeg
            weights.add(leg, 0.35 * (1 - smoothstep((local.y + 5.6) / 2.4)))
            weights.fill(.pelvis)
            return weights
        }

        let neck = MeshFactory.cylinder(radiusTop: CharacterRig.neckRadiusTop,
                                        radiusBottom: CharacterRig.neckRadiusBottom,
                                        height: CharacterRig.neckLength,
                                        radialSegments: 16)
        append(neck, into: &out, bind: bind.bones[.neck] ?? matrix_identity_float4x4,
               slot: .skin, region: .blank) { local, _ in
            var weights = SkinWeights()
            let half = CharacterRig.neckLength / 2
            weights.add(.torso, 0.5 * (1 - smoothstep((local.y + half) / half)))
            weights.fill(.neck)
            return weights
        }

        // The hands ride their own bone whole. They are the one part deliberately *not* blended
        // into the limb above them: the forearm bone's roll is the shortest arc onto the arm's
        // direction and the hand bone's is pinned to the elbow's bending plane, so the two can
        // differ by most of a turn — a blend across that boundary is the classic skinning
        // failure where a wrist screws shut. The wrist ring is small and sits inside the palm.
        let rightHand = CharacterRenderer.buildHand()
        let leftHand = MeshFactory.mirroredInX(rightHand)
        append(rightHand, into: &out, bind: bind.bones[.rightHand] ?? matrix_identity_float4x4,
               slot: .skin, region: .blank) { _, _ in
            var weights = SkinWeights(); weights.fill(.rightHand); return weights
        }
        append(leftHand, into: &out, bind: bind.bones[.leftHand] ?? matrix_identity_float4x4,
               slot: .skin, region: .blank) { _, _ in
            var weights = SkinWeights(); weights.fill(.leftHand); return weights
        }
    }

    /// Where a point on the torso or the shorts is round the body, as the clothing atlas's `u`:
    /// **0 at the middle of the chest, 0.5 at the side, 1 down the spine**, and the same coming
    /// round the other way.
    ///
    /// Measured in **bind space**, where +X is the character's front, rather than from the
    /// lathe's own revolve angle — so the middle of the chest is the middle of the chest whatever
    /// `MeshFactory` and the bind rotation do between them. Both lathes stand on the rig's own Z
    /// axis, so there is no centre to subtract.
    ///
    /// Taking the *magnitude* of the angle is what folds it, and folding is what stops the last
    /// quad round the body carrying u from 0.96 back to 0 — see `ClothingAtlas.uv`.
    private static func facing(_ world: SIMD3<Float>) -> Float {
        abs(atan2(-world.y, world.x)) / .pi
    }

    private static func profileFloor(_ profile: [(y: Float, radius: Float)]) -> Float {
        profile.first?.y ?? 0
    }

    private static func profileHeight(_ profile: [(y: Float, radius: Float)]) -> Float {
        max((profile.last?.y ?? 1) - (profile.first?.y ?? 0), 1e-4)
    }

    // MARK: - Arms and legs

    private static func appendArms(_ out: inout SkinMeshData, bind: RigBindPose) {
        // Same radii the three separate pieces used, so the arm comes out the thickness it
        // always was. The shoulder end takes the deltoid's radius rather than the upper arm's,
        // because the dome that caps this tube *is* the deltoid now.
        let radii = (root: CharacterRig.shoulderRadius,
                     mid: CharacterRig.upperArmRadius * CharacterRig.elbowEndScale,
                     tip: CharacterRig.lowerArmRadius * CharacterRig.wristEndScale)

        for (chain, bones, anchorWeight) in [
            (bind.leftArm, (RigPart.leftUpperArm, RigPart.leftLowerArm, RigPart.leftHand), Float(0.5)),
            (bind.rightArm, (RigPart.rightUpperArm, RigPart.rightLowerArm, RigPart.rightHand), Float(0.5)),
        ] {
            let rings = limbRings(chain: chain,
                                  radii: radii,
                                  bones: (bones.0, bones.1),
                                  anchor: (.torso, anchorWeight, 0.30),
                                  // The wrist is the one limb end nothing covers, so it closes
                                  // flush on the joint plane instead of doming past it.
                                  tipInset: radii.tip * 0.9,
                                  segments: (8, 8),
                                  blend: 0.42,
                                  capSteps: 5)
            appendTube(rings, into: &out, slot: .arm, region: .arm, radial: 16)
        }
    }

    private static func appendLegs(_ out: inout SkinMeshData, bind: RigBindPose) {
        let radii = (root: CharacterRig.upperLegRadius * CharacterRig.hipEndScale,
                     mid: CharacterRig.upperLegRadius * CharacterRig.kneeEndScale,
                     tip: CharacterRig.lowerLegRadius * CharacterRig.ankleEndScale)

        for (chain, bones) in [
            (bind.leftLeg, (RigPart.leftUpperLeg, RigPart.leftLowerLeg)),
            (bind.rightLeg, (RigPart.rightUpperLeg, RigPart.rightLowerLeg)),
        ] {
            let rings = limbRings(chain: chain,
                                  radii: radii,
                                  bones: bones,
                                  anchor: (.pelvis, 0.5, 0.28),
                                  // The ankle domes past the joint on purpose — the shoe model
                                  // swallows it, exactly as it did before.
                                  tipInset: 0,
                                  segments: (9, 8),
                                  blend: 0.40,
                                  capSteps: 5)
            appendTube(rings, into: &out, slot: .pants, region: .leg, radial: 16)
        }
    }

    /// One cross-section of a swept limb.
    private struct SweptRing {
        var centre: SIMD3<Float>
        /// Which way the limb is running here. At the middle joint this is the bisector of the
        /// two segments, so the surface creases evenly rather than mitring to one side.
        var tangent: SIMD3<Float>
        var radius: Float
        var weights: SkinWeights
    }

    /// **The whole idea, in one function.** Rings along a two-bone limb, each carrying the
    /// weights that will move it.
    ///
    /// Away from the middle joint a ring belongs entirely to the bone it sits on. Within
    /// `blend` of the joint it cross-fades to the other bone, arriving at exactly half and half
    /// *on* the joint — which is what makes the surface fold there instead of tearing. The
    /// tangent is interpolated on the same schedule, so the ring on the joint faces along the
    /// bisector and the crease is symmetrical.
    ///
    /// `anchor` is the same trick at the other end: the top of an arm keeps a share of the
    /// chest so the deltoid stays welded to the shoulder when the waist twists, and the top of
    /// a thigh keeps a share of the pelvis.
    ///
    /// - Parameters:
    ///   - chain: the limb's three joints, in bind space.
    ///   - radii: how thick the limb is at each of them.
    ///   - tipInset: how far *short* of the far joint the tube closes. Zero domes a hemisphere
    ///     past it instead, for ends something else covers.
    ///   - segments: rings along each of the two bones.
    ///   - blend: fraction of each bone spent cross-fading at the middle joint.
    private static func limbRings(chain: RigChain,
                                  radii: (root: Float, mid: Float, tip: Float),
                                  bones: (root: RigPart, tip: RigPart),
                                  anchor: (bone: RigPart, weight: Float, span: Float),
                                  tipInset: Float,
                                  segments: (Int, Int),
                                  blend: Float,
                                  capSteps: Int) -> [SweptRing] {
        let upper = chain.mid - chain.root
        let lower = chain.tip - chain.mid
        let upperLength = simd_length(upper), lowerLength = simd_length(lower)
        guard upperLength > 1e-4, lowerLength > 1e-4 else { return [] }
        let d1 = upper / upperLength, d2 = lower / lowerLength

        /// How much of this ring belongs to the far bone: 0 at the limb's root, 0.5 on the
        /// middle joint, 1 by `blend` into the second bone. Doubles as the tangent's blend.
        func tipShare(segment1 t: Float) -> Float { 0.5 * smoothstep((t - (1 - blend)) / blend) }
        func tipShare(segment2 u: Float) -> Float { 0.5 + 0.5 * smoothstep(u / blend) }

        func ringWeights(tip share: Float, anchorShare: Float) -> SkinWeights {
            var weights = SkinWeights()
            weights.add(bones.tip, share)
            weights.add(anchor.bone, anchorShare)
            weights.fill(bones.root)
            return weights
        }

        func tangent(_ share: Float) -> SIMD3<Float> {
            simd_normalize(d1 * (1 - share) + d2 * share)
        }

        var rings: [SweptRing] = []

        // The cap over the root joint: a hemisphere bulging back past it, which is what buries
        // the top of an arm in the chest and the top of a thigh in the shorts.
        let rootWeights = ringWeights(tip: 0, anchorShare: anchor.weight)
        for step in 0..<capSteps {
            let angle = Float.pi / 2 * Float(step) / Float(capSteps)
            rings.append(SweptRing(centre: chain.root - d1 * (radii.root * cos(angle)),
                                   tangent: d1,
                                   radius: radii.root * sin(angle),
                                   weights: rootWeights))
        }

        // First bone, root joint through to the middle joint inclusive.
        for step in 0...segments.0 {
            let t = Float(step) / Float(segments.0)
            let share = tipShare(segment1: t)
            rings.append(SweptRing(centre: chain.root + d1 * (upperLength * t),
                                   tangent: tangent(share),
                                   radius: mix(radii.root, radii.mid, t),
                                   weights: ringWeights(tip: share,
                                                        anchorShare: anchor.weight * (1 - smoothstep(t / anchor.span)))))
        }

        // Second bone. The tube stops `tipInset` short of the far joint and the cap covers the
        // rest, so the two together span exactly the bone — the same arrangement `MeshFactory`
        // made for a capsule, and the reason a limb's cross-section at a joint is a full radius.
        let overshoot = tipInset > 0 ? tipInset : radii.tip
        let tubeLength = lowerLength - tipInset
        for step in 1...segments.1 {
            let u = Float(step) / Float(segments.1)
            let share = tipShare(segment2: u)
            rings.append(SweptRing(centre: chain.mid + d2 * (tubeLength * u),
                                   tangent: tangent(share),
                                   radius: mix(radii.mid, radii.tip, u),
                                   weights: ringWeights(tip: share, anchorShare: 0)))
        }

        let tipWeights = ringWeights(tip: 1, anchorShare: 0)
        for step in 1...capSteps {
            let angle = Float.pi / 2 * Float(step) / Float(capSteps)
            rings.append(SweptRing(centre: chain.mid + d2 * (tubeLength + overshoot * sin(angle)),
                                   tangent: d2,
                                   radius: radii.tip * cos(angle),
                                   weights: tipWeights))
        }

        return rings
    }

    /// Turns rings into triangles.
    ///
    /// The ring frames are carried forward rather than derived from scratch — each one takes the
    /// last one's cross-axis and squares it against its own tangent. Rebuilding the frame per
    /// ring from a fixed reference makes the tube twist as it turns a corner, which shows up as
    /// a spiral crease down the inside of an arm.
    ///
    /// A ring of zero radius becomes a single vertex and the strip a fan, which is what closes
    /// each end. Winding and vertex order match `MeshFactory.lathe` exactly, so the normals
    /// this mesh accumulates agree with every other mesh in the game.
    ///
    /// The clothing atlas's `v` is **arc length along the centre line**, not the ring index:
    /// the caps are five rings over a couple of units and the shaft is eight rings over ten, so
    /// an index would put the cuff of a sleeve somewhere near the shoulder. Arc length also means
    /// `ClothingAtlas.sleeveEnd` can be read as "this far down the arm" and stay true if the ring
    /// counts ever change.
    private static func appendTube(_ rings: [SweptRing],
                                   into out: inout SkinMeshData,
                                   slot: ColorSlot,
                                   region: ClothingRegion,
                                   radial: Int) {
        guard rings.count >= 2 else { return }
        let segments = max(3, radial)

        var travelled: [Float] = [0]
        for index in 1..<rings.count {
            travelled.append(travelled[index - 1]
                             + simd_distance(rings[index].centre, rings[index - 1].centre))
        }
        let total = max(travelled[rings.count - 1], 1e-4)

        // Seed the frame with any axis not parallel to the first tangent.
        var cross = SIMD3<Float>(0, 0, 1)
        if abs(simd_dot(cross, rings[0].tangent)) > 0.9 { cross = SIMD3(1, 0, 0) }

        var rowStart: [Int] = []
        var rowCount: [Int] = []

        for (index, ring) in rings.enumerated() {
            let along = travelled[index] / total
            let tangent = simd_normalize(ring.tangent)
            // Square the carried axis against this ring's tangent — parallel transport, near
            // enough, and stable for the small turns a limb makes.
            var v = cross - tangent * simd_dot(cross, tangent)
            if simd_length(v) < 1e-4 {
                let fallback: SIMD3<Float> = abs(tangent.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
                v = fallback - tangent * simd_dot(fallback, tangent)
            }
            v = simd_normalize(v)
            cross = v
            // `lathe` revolves as (r·sin φ, y, r·cos φ), which puts the axis on the *left* of the
            // radial and tangential pair. `u = tangent × v` reproduces that handedness, and with
            // it the winding below comes out the same way round as every other lathe.
            let u = simd_cross(tangent, v)

            let (joints, weights) = ring.weights.packed()
            rowStart.append(out.vertices.count)

            if ring.radius < 1e-4 {
                out.vertices.append(SkinVertex(position: ring.centre, normal: tangent,
                                               weights: weights, joints: joints,
                                               uv: ClothingAtlas.uv(region, u: 0.5, v: along),
                                               colorSlot: slot.rawValue))
                rowCount.append(1)
                continue
            }

            for segment in 0..<segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                let outward = u * sin(phi) + v * cos(phi)
                out.vertices.append(SkinVertex(position: ring.centre + outward * ring.radius,
                                               normal: outward,
                                               weights: weights, joints: joints,
                                               // Folded the same way `facing` folds the torso's,
                                               // so the ring closes without a jump.
                                               uv: ClothingAtlas.uv(region,
                                                                    u: abs(2 * Float(segment) / Float(segments) - 1),
                                                                    v: along),
                                               colorSlot: slot.rawValue))
            }
            rowCount.append(segments)
        }

        for row in 0..<(rings.count - 1) {
            let lower = rowStart[row], upper = rowStart[row + 1]
            let lowerIsPoint = rowCount[row] == 1, upperIsPoint = rowCount[row + 1] == 1
            if lowerIsPoint && upperIsPoint { continue }

            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = UInt32(lower + (lowerIsPoint ? 0 : segment))
                let b = UInt32(lower + (lowerIsPoint ? 0 : next))
                let c = UInt32(upper + (upperIsPoint ? 0 : next))
                let d = UInt32(upper + (upperIsPoint ? 0 : segment))
                if lowerIsPoint {
                    out.indices.append(contentsOf: [a, d, c])
                } else if upperIsPoint {
                    out.indices.append(contentsOf: [a, d, b])
                } else {
                    out.indices.append(contentsOf: [a, d, c, a, c, b])
                }
            }
        }
    }

    // MARK: - Reusing an existing mesh

    /// Transforms an unskinned `MeshData` into bind space, weights it and gives it a place in the
    /// clothing atlas.
    ///
    /// Both closures are handed the vertex twice — once in the mesh's own space, which is where a
    /// profile height like "the hem of the shirt" is legible, and once in bind space, which is
    /// where "nearer the left hip than the right" and "round the front" are.
    ///
    /// The mesh's **own** UVs are thrown away. `MeshFactory.lathe` writes a plain revolve
    /// parameterisation and says in as many words that the rig's flat-coloured materials never
    /// read it; what the atlas needs is anatomical, so `uv` supplies it. `region: .blank` with the
    /// default closure is the honest answer for anything that is skin.
    private static func append(_ mesh: MeshData,
                               into out: inout SkinMeshData,
                               bind: Float4x4,
                               slot: ColorSlot,
                               region: ClothingRegion,
                               uv: (_ local: SIMD3<Float>, _ world: SIMD3<Float>) -> SIMD2<Float>
                                   = { _, _ in SIMD2(0.5, 0.5) },
                               weights: (_ local: SIMD3<Float>, _ world: SIMD3<Float>) -> SkinWeights) {
        let offset = UInt32(out.vertices.count)
        // Every bind matrix for these parts is a translation and a rotation, so the same matrix
        // carries the normals.
        let rotation = simd_float3x3(SIMD3(bind.columns.0.x, bind.columns.0.y, bind.columns.0.z),
                                     SIMD3(bind.columns.1.x, bind.columns.1.y, bind.columns.1.z),
                                     SIMD3(bind.columns.2.x, bind.columns.2.y, bind.columns.2.z))

        for vertex in mesh.vertices {
            let placed = bind * SIMD4(vertex.position, 1)
            let world = SIMD3(placed.x, placed.y, placed.z)
            let (joints, packed) = weights(vertex.position, world).packed()
            let placement = uv(vertex.position, world)
            out.vertices.append(SkinVertex(position: world,
                                           normal: rotation * vertex.normal,
                                           weights: packed, joints: joints,
                                           uv: ClothingAtlas.uv(region, u: placement.x, v: placement.y),
                                           colorSlot: slot.rawValue))
        }
        out.indices.append(contentsOf: mesh.indices.map { $0 + offset })
    }

    /// Area-weighted vertex normals, the same rule `MeshFactory` uses. Run over the whole body
    /// at once: the surfaces share no vertices, so nothing bleeds from one into another.
    private static func recomputeNormals(_ mesh: inout SkinMeshData) {
        var accumulated = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            i += 3
            let face = simd_cross(mesh.vertices[b].position - mesh.vertices[a].position,
                                  mesh.vertices[c].position - mesh.vertices[a].position)
            accumulated[a] += face
            accumulated[b] += face
            accumulated[c] += face
        }

        for index in mesh.vertices.indices {
            let length = simd_length(accumulated[index])
            if length > 1e-6 { mesh.vertices[index].normal = accumulated[index] / length }
        }
    }

    // MARK: - Helpers

    private static func smoothstep(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
}

/// Up to four bones and their shares of one vertex.
///
/// `fill` is the one that matters: it hands the *remainder* to a bone rather than a fixed
/// amount, so a caller adds whatever blends it wants and finishes with "and the rest belongs to
/// this one". Weights that do not sum to 1 shrink or inflate the surface as it moves, and the
/// bug reads as a limb that quietly deflates mid-stride.
struct SkinWeights {
    private var bones: [RigPart] = []
    private var shares: [Float] = []

    mutating func add(_ bone: RigPart, _ share: Float) {
        guard share > 0.0005, bones.count < 4 else { return }
        bones.append(bone)
        shares.append(share)
    }

    /// Gives `bone` everything not already claimed.
    mutating func fill(_ bone: RigPart) {
        add(bone, max(0, 1 - shares.reduce(0, +)))
    }

    /// Joint indices and weights, normalised, padded out to four.
    func packed() -> (joints: SIMD4<Float>, weights: SIMD4<Float>) {
        var joints = SIMD4<Float>(repeating: 0)
        var weights = SIMD4<Float>(repeating: 0)
        let total = shares.reduce(0, +)
        guard total > 1e-5 else { return (joints, SIMD4(1, 0, 0, 0)) }

        for (slot, bone) in bones.enumerated() {
            joints[slot] = Float(SkinnedBody.boneIndex[bone] ?? 0)
            weights[slot] = shares[slot] / total
        }
        return (joints, weights)
    }
}
