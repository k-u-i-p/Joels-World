import Foundation
import Metal
import MetalKit
import simd

/// A bought, rigged character: its mesh on the GPU and the skeleton `HumanoidRetargeter` aims.
///
/// **It reuses the body's shaders exactly as they are.** `characterSkinnedVertex` blends four
/// weighted bone matrices out of a buffer and `characterFragment` already has a textured branch,
/// so an imported character needs no new pipeline — only different buffers bound to the same
/// one. What makes the fragment take that branch rather than the clothing-atlas branch is
/// `clothed: false`; see `CharacterUniforms.surface`.
///
/// The one thing that is genuinely different is where the bone matrices live. The procedural
/// body has 13 bones and passes them with `setVertexBytes`, which tops out at 4 KB — 64
/// matrices. A bought rig has 52 here and routinely more elsewhere once fingers and twist bones
/// are counted, so these go in a real buffer.
final class ImportedCharacterBody {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let skeleton: HumanoidSkeleton
    /// Joint names, kept for the lab's report.
    let jointNames: [String]

    let baseColorTexture: MTLTexture?
    let baseColor: SIMD4<Float>
    let roughness: Float
    let metalness: Float

    /// Triangles, for the budget line in the report — a bought character is typically several
    /// times the procedural body and this is the number that decides whether it ships.
    var triangleCount: Int { indexCount / 3 }

    init?(device: MTLDevice,
          mesh: GLTFSkinnedMesh,
          skeleton: HumanoidSkeleton,
          baseColorTexture: MTLTexture?) {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty else { return nil }

        // Into engine space, and into the layout the existing skinned pipeline expects.
        let normalize = skeleton.normalizeTransform
        let normalMatrix = normalize.orthonormalRotation

        var vertices: [SkinVertex] = []
        vertices.reserveCapacity(mesh.vertices.count)
        for vertex in mesh.vertices {
            let position = normalize * SIMD4(vertex.position, 1)
            let normal = simd_normalize(normalMatrix * vertex.normal)
            vertices.append(SkinVertex(
                position: SIMD3(position.x, position.y, position.z),
                normal: normal,
                weights: vertex.weights,
                // The shader indexes with `uint(v.joints[i])`; the procedural body carries them
                // as floats for the alignment reasons in `SkinnedBody`, and this matches so both
                // can share one vertex descriptor.
                joints: SIMD4(Float(vertex.joints.x), Float(vertex.joints.y),
                              Float(vertex.joints.z), Float(vertex.joints.w)),
                uv: vertex.uv,
                // No colour slot: an imported character's colour is its own texture, and
                // `clothed: false` is what stops the palette being consulted at all.
                colorSlot: 0))
        }

        guard let vertexBuffer = device.makeBuffer(bytes: vertices,
                                                   length: MemoryLayout<SkinVertex>.stride * vertices.count,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                                  length: MemoryLayout<UInt32>.stride * mesh.indices.count,
                                                  options: .storageModeShared)
        else { return nil }

        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = mesh.indices.count
        self.skeleton = skeleton
        self.jointNames = mesh.jointNames
        self.baseColorTexture = baseColorTexture
        self.baseColor = mesh.baseColor
        self.roughness = mesh.roughness
        self.metalness = mesh.metalness
    }
}

/// Loads and caches imported characters, the way `ModelStore` does for rigid models.
///
/// Kept separate from `ModelStore` rather than folded into it because the two share nothing
/// downstream of the parse: a rigid model is merged into draw groups by material, and a skinned
/// one is a single mesh whose skeleton is the point of it.
final class ImportedCharacterStore {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let parseQueue = DispatchQueue(label: "com.allr.joelsworld.humanoid", qos: .userInitiated)

    private var bodies: [String: ImportedCharacterBody] = [:]
    private var failed: Set<String> = []
    private var loading: Set<String> = []
    /// The last skeleton report per model, for the lab.
    private(set) var reports: [String: String] = [:]

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    func body(_ path: String) -> ImportedCharacterBody? { bodies[path] }
    func hasFailed(_ path: String) -> Bool { failed.contains(path) }

    /// Fire-and-forget, called every frame until the model turns up — same contract as
    /// `ModelStore.request`.
    func request(path: String, profile: HumanoidProfile = .standard) {
        if bodies[path] != nil || failed.contains(path) || loading.contains(path) { return }
        loading.insert(path)

        guard let url = AssetLocator.url(for: path) else {
            failed.insert(path)
            loading.remove(path)
            Log.render("Imported character '\(path)': not found in the asset bundle")
            return
        }

        parseQueue.async { [weak self] in
            guard let self else { return }
            let started = CFAbsoluteTimeGetCurrent()

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let asset = try? GLTFLoader.load(data: data),
                  let mesh = asset.skinnedMeshes.first
            else {
                DispatchQueue.main.async {
                    self.failed.insert(path)
                    self.loading.remove(path)
                    Log.render("Imported character '\(path)': no skinned mesh in the file")
                }
                return
            }

            if asset.skinnedMeshes.count > 1 {
                // One draw, one skin. A model split into body/hair/eyes meshes would need one
                // buffer each; nothing has asked for it yet, and saying so beats a silently
                // half-drawn character.
                Log.render("Imported character '\(path)': \(asset.skinnedMeshes.count) skinned meshes, only the first is drawn")
            }

            let skeleton = HumanoidSkeleton(mesh: mesh, profile: profile)
            let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

            DispatchQueue.main.async {
                var texture: MTLTexture?
                if let imageIndex = mesh.baseColorImage, let bytes = asset.images[imageIndex] {
                    // Same rules as `ModelStore`: no vertical flip (glTF UVs already start at
                    // the top-left) and sRGB on, because a base-colour texture is sRGB-encoded
                    // and shading has to happen in linear space.
                    texture = (try? self.textureLoader.newTexture(
                        data: bytes, options: [.SRGB: true, .generateMipmaps: true]))
                        ?? ImageDecoder.texture(from: bytes, device: self.device, flipped: false)
                    if texture == nil {
                        Log.render("Imported character '\(path)': base colour image failed to decode")
                    }
                }

                self.loading.remove(path)
                guard let body = ImportedCharacterBody(device: self.device,
                                                       mesh: mesh,
                                                       skeleton: skeleton,
                                                       baseColorTexture: texture) else {
                    self.failed.insert(path)
                    Log.render("Imported character '\(path)': could not build GPU buffers")
                    return
                }

                self.bodies[path] = body
                self.reports[path] = skeleton.describe(jointNames: mesh.jointNames)

                let missing = HumanoidBone.allCases.filter { skeleton.matched[$0] == nil }
                Log.render("Imported character '\(path)': \(body.triangleCount) triangles, "
                           + "\(skeleton.jointCount) joints, "
                           + "\(skeleton.matched.count)/\(HumanoidBone.allCases.count) bones matched, "
                           + "parsed in \(Int(elapsed)) ms")
                Log.render(String(format: "  scale ×%.3f — %.3f file units tall → %.1f engine units; "
                                  + "rig hip height %.1f",
                                  skeleton.normalizeScale, skeleton.measuredHeight,
                                  skeleton.measuredHeight * skeleton.normalizeScale,
                                  HumanoidSkeleton.engineHipHeight))
                if !missing.isEmpty {
                    // Not fatal — an unmatched bone rides its parent — but an unmatched *arm* is
                    // why a character came out in a heap, and this is the line that says so.
                    Log.render("  unmatched: \(missing.map(\.rawValue).joined(separator: ", "))")
                }
                // Fingers are the one part of a bought rig that is posed without being driven,
                // so a model whose hands never close looks like a bug in the grip rather than
                // what it is — a rig this could not find a thumb on. See `Grip`.
                let fingers = skeleton.curlAxis.filter { $0 != .zero }.count
                Log.render("  \(fingers) finger joints curl, on "
                           + (skeleton.curledHands.isEmpty
                              ? "neither hand — no thumb bone to take a frame from"
                              : skeleton.curledHands.map(\.rawValue).joined(separator: " and ")))
                if !skeleton.mirrored.isEmpty {
                    // The one failure this whole system cannot show you: a mirrored character
                    // walks, runs and stands perfectly. See `HumanoidSkeleton`'s side check.
                    Log.render("  MIRRORED — these bones are on the wrong side of the body: "
                               + skeleton.mirrored.map(\.rawValue).joined(separator: ", "))
                }
            }
        }
    }
}
