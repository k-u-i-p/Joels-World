import Foundation
import simd

/// One vertex of a loaded mesh. Matches `MeshVertex` in `Shaders.metal`.
struct MeshVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}

/// A drawable chunk of a glTF file: one primitive, with its node's transform already baked
/// into the vertex data.
///
/// Baking is safe because nothing in this game's asset set is animated or skinned — verified
/// across all 40 shipping `.glb` files (0 skins, 0 animations, 0 morph targets, 0 sparse
/// accessors, every primitive mode 4/triangles). That check is what keeps this loader small;
/// re-run it before adding new models.
struct GLTFPrimitive {
    var vertices: [MeshVertex]
    var indices: [UInt32]
    /// Lowercased node name, used for the name-based material overrides the JS does
    /// (`characters.js:195-202` — `hair` → hair material, `face`/`head`/`skin` → skin).
    var nodeName: String
    /// Lowercased material name; `eye`/`animetest` materials keep their authored look.
    var materialName: String
    var baseColor: SIMD4<Float>
    /// `pbrMetallicRoughness` factors, defaulted per the glTF spec (both 1) exactly as the
    /// three.js `GLTFLoader` does.
    var roughness: Float
    var metalness: Float
    /// Index into `GLTFAsset.images`, if the material had a base-colour texture.
    var imageIndex: Int?
    /// `KHR_texture_transform`, pre-resolved. `uv * scale + offset`, rotation in radians.
    var uvTransform: (offset: SIMD2<Float>, scale: SIMD2<Float>, rotation: Float)?

    /// `emissiveFactor` × `KHR_materials_emissive_strength` — three.js's `emissive` colour
    /// times its `emissiveIntensity`, which is what the extension sets. Already linear:
    /// `emissiveFactor` is authored in linear space, unlike a base colour *texture*.
    var emissive: SIMD3<Float>
    /// Index into `GLTFAsset.images` for `emissiveTexture`, which is frequently a *different*
    /// image from the base colour — `desk.glb` lights its texture 0 over its texture 2.
    var emissiveImageIndex: Int?

    /// Dielectric F0, pre-composed from `KHR_materials_ior` and `KHR_materials_specular` the
    /// way three.js's `MeshPhysicalMaterial` does:
    /// `min(pow2((ior − 1)/(ior + 1)) · specularColorFactor, 1) · specularFactor`.
    /// The glTF defaults (ior 1.5, both specular factors 1) give exactly the 0.04 that
    /// `MeshStandardMaterial` hard-codes, so a material using neither extension is unchanged.
    var specularF0: SIMD3<Float>
    /// `specularFactor`, which three.js mixes towards 1 by metalness to get `specularF90`.
    var specularIntensity: Float
    /// `KHR_materials_transmission`'s `transmissionFactor`. See `Shaders.metal` for what the
    /// renderer can and cannot do with it without a backdrop pass.
    var transmission: Float
}

/// One vertex of a skinned mesh. Carries the two attributes `MeshVertex` has no room for.
struct GLTFSkinVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
    /// Indices into `GLTFSkinnedMesh.jointNames`.
    var joints: SIMD4<UInt16>
    /// How much each of `joints` moves this vertex. Renormalised to sum to 1 on load.
    var weights: SIMD4<Float>
    /// Tangent frame for the normal map: `xyz` the surface tangent along +u, `w` the handedness
    /// that turns it into a bitangent (`cross(normal, tangent) * w`). glTF's `TANGENT` attribute
    /// exactly, and generated from the UVs when the file has none — which is four of the five
    /// characters. `xyz` is zero only where a mesh has no UVs at all to derive one from.
    var tangent: SIMD4<Float> = .zero
}

/// A skinned mesh and the skeleton that deforms it, both in the mesh's own space.
///
/// Unlike `GLTFPrimitive` **nothing is baked**. A skinned mesh's own node transform is ignored
/// by the glTF spec — the joints define where the vertices go — so baking it would apply the
/// file's root scale twice. The bind pose lives entirely in `inverseBind`: joint `j`'s bind
/// world transform is `inverseBind[j].inverse`, in the same space as `vertices`. That holds
/// even for this model, whose 52 joint nodes all carry an identity local transform and keep
/// the whole rest pose in the inverse-bind matrices.
struct GLTFSkinnedMesh {
    var vertices: [GLTFSkinVertex]
    var indices: [UInt32]
    /// Joint node names, in the order `GLTFSkinVertex.joints` indexes them.
    var jointNames: [String]
    /// `bind⁻¹` per joint.
    var inverseBind: [Float4x4]
    /// Each joint's parent as an index into `jointNames`, or nil where the joint is a root of
    /// the skin. Derived from the node hierarchy, not from the matrices.
    var parents: [Int?]
    var baseColorImage: Int?
    var normalImage: Int?
    /// `normalTexture.scale`, which three.js reads into `normalScale`. It multiplies the map's
    /// x and y before the frame is rebuilt, so 0 is a flat surface and 1 the map as authored.
    var normalScale: Float = 1
    /// Whether the tangents came from the file's `TANGENT` attribute or were generated here.
    /// Only worth knowing when a normal map looks wrong — see `GLTFLoader.generateTangents`.
    var authoredTangents: Bool = false
    var baseColor: SIMD4<Float>
    var roughness: Float
    var metalness: Float
}

struct GLTFAsset {
    var primitives: [GLTFPrimitive]
    /// Encoded image bytes (PNG/JPEG), indexed by the order textures reference them.
    var images: [Int: Data]
    /// Skinned meshes, which take an entirely separate path — see `GLTFSkinnedMesh`.
    var skinnedMeshes: [GLTFSkinnedMesh] = []
}

enum GLTFError: Error, CustomStringConvertible {
    case notGLB
    case badChunk
    case missingJSON
    case unsupported(String)

    var description: String {
        switch self {
        case .notGLB: return "not a .glb container"
        case .badChunk: return "malformed GLB chunk table"
        case .missingJSON: return "no JSON chunk"
        case .unsupported(let what): return "unsupported: \(what)"
        }
    }
}

/// Minimal binary-glTF reader: geometry, node hierarchy, base-colour materials and embedded
/// images, plus **skins** — see `GLTFSkinnedMesh`. No animation or morph targets: the character
/// rig drives every skeleton in this game, so a file's own clips are of no use to us.
enum GLTFLoader {

    // MARK: - Public entry point

    static func load(data: Data) throws -> GLTFAsset {
        let (json, binary) = try splitGLB(data)

        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw GLTFError.missingJSON
        }

        let buffers = try resolveBuffers(root: root, binaryChunk: binary)
        let bufferViews = root["bufferViews"] as? [[String: Any]] ?? []
        let accessors = root["accessors"] as? [[String: Any]] ?? []
        let meshes = root["meshes"] as? [[String: Any]] ?? []
        let nodes = root["nodes"] as? [[String: Any]] ?? []
        let materials = root["materials"] as? [[String: Any]] ?? []
        let textures = root["textures"] as? [[String: Any]] ?? []
        let imageDefs = root["images"] as? [[String: Any]] ?? []

        var images: [Int: Data] = [:]
        for (index, image) in imageDefs.enumerated() {
            if let viewIndex = image["bufferView"] as? Int,
               let slice = sliceBufferView(viewIndex, bufferViews: bufferViews, buffers: buffers) {
                images[index] = slice
            }
            // URI-referenced images are not used by any shipping asset; they would need a
            // sibling-file fetch, which .glb avoids by construction.
        }

        var primitives: [GLTFPrimitive] = []
        var skinnedMeshes: [GLTFSkinnedMesh] = []
        let skins = root["skins"] as? [[String: Any]] ?? []

        // Walk the scene graph so each primitive inherits its ancestors' transforms.
        let sceneIndex = root["scene"] as? Int ?? 0
        let scenes = root["scenes"] as? [[String: Any]] ?? []
        let roots = (scenes.indices.contains(sceneIndex)
                     ? scenes[sceneIndex]["nodes"] as? [Int]
                     : nil) ?? Array(nodes.indices)

        var visited = Set<Int>()

        func visit(_ nodeIndex: Int, parent: Float4x4) {
            guard nodes.indices.contains(nodeIndex), !visited.contains(nodeIndex) else { return }
            visited.insert(nodeIndex)

            let node = nodes[nodeIndex]
            let world = parent * localTransform(of: node)
            let name = (node["name"] as? String ?? "").lowercased()

            // A skinned mesh takes the other path entirely: `world` is deliberately not passed,
            // because the spec says a skinned mesh ignores its own node's transform.
            if let meshIndex = node["mesh"] as? Int, meshes.indices.contains(meshIndex),
               let skinIndex = node["skin"] as? Int, skins.indices.contains(skinIndex) {
                for primitive in meshes[meshIndex]["primitives"] as? [[String: Any]] ?? [] {
                    if let mode = primitive["mode"] as? Int, mode != 4 {
                        Log.render("glTF: skipping skinned primitive with mode \(mode)")
                        continue
                    }
                    if let parsed = buildSkinnedMesh(primitive,
                                                     skin: skins[skinIndex],
                                                     nodes: nodes,
                                                     accessors: accessors,
                                                     bufferViews: bufferViews,
                                                     buffers: buffers,
                                                     materials: materials,
                                                     textures: textures) {
                        skinnedMeshes.append(parsed)
                    }
                }
                for child in node["children"] as? [Int] ?? [] { visit(child, parent: world) }
                return
            }

            if let meshIndex = node["mesh"] as? Int, meshes.indices.contains(meshIndex) {
                let mesh = meshes[meshIndex]
                let meshName = (mesh["name"] as? String ?? "").lowercased()
                for primitive in mesh["primitives"] as? [[String: Any]] ?? [] {
                    if let mode = primitive["mode"] as? Int, mode != 4 {
                        Log.render("glTF: skipping primitive with mode \(mode) (only triangles are supported)")
                        continue
                    }
                    if let parsed = buildPrimitive(primitive,
                                                   transform: world,
                                                   nodeName: name.isEmpty ? meshName : name,
                                                   accessors: accessors,
                                                   bufferViews: bufferViews,
                                                   buffers: buffers,
                                                   materials: materials,
                                                   textures: textures) {
                        primitives.append(parsed)
                    }
                }
            }

            for child in node["children"] as? [Int] ?? [] {
                visit(child, parent: world)
            }
        }

        for rootNode in roots {
            visit(rootNode, parent: matrix_identity_float4x4)
        }

        // Defensive: a file whose scene list omits mesh-bearing nodes still renders.
        for index in nodes.indices where !visited.contains(index) {
            if nodes[index]["mesh"] != nil {
                visit(index, parent: matrix_identity_float4x4)
            }
        }

        return GLTFAsset(primitives: primitives, images: images, skinnedMeshes: skinnedMeshes)
    }

    // MARK: - Skins

    private static func buildSkinnedMesh(_ primitive: [String: Any],
                                         skin: [String: Any],
                                         nodes: [[String: Any]],
                                         accessors: [[String: Any]],
                                         bufferViews: [[String: Any]],
                                         buffers: [Data],
                                         materials: [[String: Any]],
                                         textures: [[String: Any]]) -> GLTFSkinnedMesh? {
        guard let attributes = primitive["attributes"] as? [String: Any],
              let positionIndex = attributes["POSITION"] as? Int,
              let positions = readAccessor(positionIndex, accessors: accessors,
                                           bufferViews: bufferViews, buffers: buffers),
              let jointIndex = attributes["JOINTS_0"] as? Int,
              let jointData = readAccessor(jointIndex, accessors: accessors,
                                           bufferViews: bufferViews, buffers: buffers),
              let weightIndex = attributes["WEIGHTS_0"] as? Int,
              let weightData = readAccessor(weightIndex, accessors: accessors,
                                            bufferViews: bufferViews, buffers: buffers)
        else {
            Log.render("glTF: skinned primitive is missing POSITION, JOINTS_0 or WEIGHTS_0")
            return nil
        }

        let count = positions.count / positions.componentsPerElement
        guard count > 0 else { return nil }

        if attributes["JOINTS_1"] != nil {
            // Four influences is what the shader blends. A fifth would need a second vertex
            // attribute and a second loop; no rig this game has met uses one.
            Log.render("glTF: JOINTS_1 present and ignored — vertices with 5+ influences will deform loosely")
        }

        let jointNodes = skin["joints"] as? [Int] ?? []
        guard !jointNodes.isEmpty else { return nil }

        let jointNames = jointNodes.map { nodes.indices.contains($0)
            ? (nodes[$0]["name"] as? String ?? "joint\($0)") : "joint\($0)" }

        // Parents, from the node hierarchy rather than the matrices: a joint's parent is
        // whichever joint lists it as a child. Joints whose parent is outside the skin (or
        // absent) come back nil and are treated as roots.
        var slotOfNode: [Int: Int] = [:]
        for (slot, node) in jointNodes.enumerated() { slotOfNode[node] = slot }
        var parents = [Int?](repeating: nil, count: jointNodes.count)
        for (slot, node) in jointNodes.enumerated() {
            guard nodes.indices.contains(node) else { continue }
            for child in nodes[node]["children"] as? [Int] ?? [] {
                if let childSlot = slotOfNode[child] { parents[childSlot] = slot }
            }
        }

        // Inverse bind matrices. The spec allows the accessor to be absent, in which case every
        // joint's inverse bind is the identity.
        var inverseBind = [Float4x4](repeating: matrix_identity_float4x4, count: jointNodes.count)
        if let ibmIndex = skin["inverseBindMatrices"] as? Int,
           let ibm = readAccessor(ibmIndex, accessors: accessors,
                                  bufferViews: bufferViews, buffers: buffers) {
            for slot in 0..<min(jointNodes.count, ibm.count / 16) {
                inverseBind[slot] = ibm.matrix4(at: slot)
            }
        }

        var normals: AccessorData?
        if let index = attributes["NORMAL"] as? Int {
            normals = readAccessor(index, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
        }
        // **UV set 0, unless it is empty — in which case set 1.**
        //
        // A material names the UV set it samples with a `texCoord`, and every character seen so
        // far omits it, which means set 0. `family.glb` has *two* sets, and set 0 is 27,091
        // pairs of zeros: the real map is in set 1. It is the export that is wrong, but the way
        // it is wrong is silent — every vertex samples the same texel of the atlas, so the
        // character arrives fully rigged, correctly scaled, posed by the walk cycle, and
        // uniformly the colour of whatever happens to sit at the top-left of its texture. It
        // reads as "the loader ignored the texture", which is the one thing it did not do.
        //
        // So an all-zero set 0 falls through to set 1 when there is one, and says so. Anything
        // that genuinely wants zero UVs everywhere is asking for one texel and does not care.
        var uvs: AccessorData?
        if let index = attributes["TEXCOORD_0"] as? Int {
            uvs = readAccessor(index, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
        }
        if uvs?.floats.allSatisfy({ $0 == 0 }) == true,
           let second = attributes["TEXCOORD_1"] as? Int,
           let fallback = readAccessor(second, accessors: accessors, bufferViews: bufferViews,
                                       buffers: buffers) {
            Log.render("glTF: TEXCOORD_0 is entirely zeros — using TEXCOORD_1")
            uvs = fallback
        }

        // `TANGENT` is optional in glTF and an exporter only writes it when it feels like it:
        // `stylized_boy.glb` has one, the four family models do not, and all five carry a normal
        // map. So it is read when present and derived from the UVs below when it is not.
        var tangents: AccessorData?
        if let index = attributes["TANGENT"] as? Int {
            tangents = readAccessor(index, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
        }

        var vertices: [GLTFSkinVertex] = []
        vertices.reserveCapacity(count)

        for i in 0..<count {
            var normal = SIMD3<Float>(0, 0, 1)
            if let normals, i * normals.componentsPerElement < normals.count {
                let n = normals.vector3(at: i)
                let length = simd_length(n)
                normal = length > 1e-6 ? n / length : SIMD3(0, 0, 1)
            }

            var uv = SIMD2<Float>(0, 0)
            if let uvs, i * uvs.componentsPerElement < uvs.count {
                uv = uvs.vector2(at: i)
            }

            let rawJoints = jointData.vector4(at: i)
            var weights = weightData.vector4(at: i)

            // Exporters routinely leave weights summing to 0.998 or 1.002, and a normalised
            // UNSIGNED_BYTE accessor cannot hit 1 exactly. Left alone that reads as a mesh that
            // quietly shrinks towards the origin under animation.
            let total = weights.x + weights.y + weights.z + weights.w
            weights = total > 1e-5 ? weights / total : SIMD4(1, 0, 0, 0)

            var tangent = SIMD4<Float>.zero
            if let tangents, i * tangents.componentsPerElement < tangents.count {
                let t = tangents.vector4(at: i)
                let length = simd_length(SIMD3(t.x, t.y, t.z))
                // A zero-length authored tangent is no frame at all; the generator below is not
                // run in that case, so it stays zero and the shader falls back to the normal.
                if length > 1e-6 {
                    tangent = SIMD4(t.x / length, t.y / length, t.z / length, t.w < 0 ? -1 : 1)
                }
            }

            vertices.append(GLTFSkinVertex(
                position: positions.vector3(at: i),
                normal: normal,
                uv: uv,
                joints: SIMD4(UInt16(clamping: Int(rawJoints.x)), UInt16(clamping: Int(rawJoints.y)),
                              UInt16(clamping: Int(rawJoints.z)), UInt16(clamping: Int(rawJoints.w))),
                weights: weights,
                tangent: tangent))
        }

        var indices: [UInt32] = []
        if let indexAccessor = primitive["indices"] as? Int,
           let data = readAccessor(indexAccessor, accessors: accessors,
                                   bufferViews: bufferViews, buffers: buffers) {
            indices = data.asIndices()
        } else {
            indices = Array(0..<UInt32(count))
        }

        if tangents == nil {
            generateTangents(vertices: &vertices, indices: indices)
        }

        func imageSource(of reference: Any?) -> Int? {
            guard let reference = reference as? [String: Any],
                  let textureIndex = reference["index"] as? Int,
                  textures.indices.contains(textureIndex)
            else { return nil }
            return textures[textureIndex]["source"] as? Int
        }

        var baseColor = SIMD4<Float>(1, 1, 1, 1)
        var roughness: Float = 1
        var metalness: Float = 1
        var baseColorImage: Int?
        var normalImage: Int?
        var normalScale: Float = 1

        if let materialIndex = primitive["material"] as? Int, materials.indices.contains(materialIndex) {
            let material = materials[materialIndex]
            if let pbr = material["pbrMetallicRoughness"] as? [String: Any] {
                if let factor = pbr["baseColorFactor"] as? [Double], factor.count == 4 {
                    baseColor = SIMD4(Float(factor[0]), Float(factor[1]), Float(factor[2]), Float(factor[3]))
                }
                if let factor = pbr["roughnessFactor"] as? Double { roughness = Float(factor) }
                if let factor = pbr["metallicFactor"] as? Double { metalness = Float(factor) }
                baseColorImage = imageSource(of: pbr["baseColorTexture"])
            }
            if let normal = material["normalTexture"] as? [String: Any] {
                normalImage = imageSource(of: normal)
                if let scale = normal["scale"] as? Double { normalScale = Float(scale) }
                // Both maps are sampled with the one interpolated UV, so a normal map on a
                // different `texCoord` from the base colour would silently sample the wrong set.
                if let texCoord = normal["texCoord"] as? Int, texCoord != 0 {
                    Log.render("glTF: normalTexture wants TEXCOORD_\(texCoord); only set 0 is sampled")
                }
            }
        }

        return GLTFSkinnedMesh(vertices: vertices,
                               indices: indices,
                               jointNames: jointNames,
                               inverseBind: inverseBind,
                               parents: parents,
                               baseColorImage: baseColorImage,
                               normalImage: normalImage,
                               normalScale: normalScale,
                               authoredTangents: tangents != nil,
                               baseColor: baseColor,
                               roughness: roughness,
                               metalness: metalness)
    }

    /// **Tangents from the UVs**, for the four characters whose exporter wrote none.
    ///
    /// A normal map stores its perturbation in *tangent space* — a frame in which +x runs along
    /// increasing u across the surface, +y along increasing v, and +z is the geometric normal.
    /// Without that frame the map cannot be applied at all: there is nothing to say which way
    /// "right" is on the skin of the arm.
    ///
    /// The frame is recovered per triangle by solving the two edges against their UV deltas, then
    /// averaged at each vertex so it varies smoothly rather than faceting, and finally made
    /// perpendicular to the vertex normal (Gram–Schmidt) because the averaged tangent generally
    /// is not. `w` records whether the UV shell is mirrored, which is how the left arm can share
    /// the right arm's patch of the atlas without its bumps coming out inside-out.
    ///
    /// This is the standard Lengyel construction rather than MikkTSpace. It differs from
    /// MikkTSpace where a mesh has hard UV seams that also share vertices; a character atlas
    /// splits vertices at its seams, so the two agree here.
    private static func generateTangents(vertices: inout [GLTFSkinVertex], indices: [UInt32]) {
        var tangentSum = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        var bitangentSum = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }

            let edge1 = vertices[b].position - vertices[a].position
            let edge2 = vertices[c].position - vertices[a].position
            let deltaUV1 = vertices[b].uv - vertices[a].uv
            let deltaUV2 = vertices[c].uv - vertices[a].uv

            // A degenerate triangle in UV space (a seam collapsed to a point, or an unwrapped
            // face) has no frame to give; its vertices take theirs from their other triangles.
            let determinant = deltaUV1.x * deltaUV2.y - deltaUV2.x * deltaUV1.y
            guard abs(determinant) > 1e-12 else { continue }
            let r = 1 / determinant

            let tangent = (edge1 * deltaUV2.y - edge2 * deltaUV1.y) * r
            let bitangent = (edge2 * deltaUV1.x - edge1 * deltaUV2.x) * r

            for index in [a, b, c] {
                tangentSum[index] += tangent
                bitangentSum[index] += bitangent
            }
        }

        for index in vertices.indices {
            let normal = vertices[index].normal
            var tangent = tangentSum[index] - normal * simd_dot(normal, tangentSum[index])
            let length = simd_length(tangent)

            if length > 1e-6 {
                tangent /= length
            } else {
                // No usable UV frame here. Any tangent perpendicular to the normal keeps the
                // basis valid; a flat region of the map then perturbs nothing, which is right.
                let axis = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
                tangent = simd_normalize(simd_cross(axis, normal))
            }

            let handedness: Float = simd_dot(simd_cross(normal, tangent), bitangentSum[index]) < 0 ? -1 : 1
            vertices[index].tangent = SIMD4(tangent, handedness)
        }
    }

    // MARK: - Container

    private static func splitGLB(_ data: Data) throws -> (json: Data, binary: Data?) {
        guard data.count >= 12 else { throw GLTFError.notGLB }

        let magic: UInt32 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
        guard magic == 0x46546C67 else { throw GLTFError.notGLB }   // "glTF"

        var offset = 12
        var json: Data?
        var binary: Data?

        while offset + 8 <= data.count {
            let length = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
            let type = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self) }
            let start = offset + 8
            guard start + length <= data.count else { throw GLTFError.badChunk }

            let chunk = data.subdata(in: start..<(start + length))
            if type == 0x4E4F534A { json = chunk }          // "JSON"
            else if type == 0x004E4942 { binary = chunk }   // "BIN\0"

            offset = start + length
        }

        guard let json else { throw GLTFError.missingJSON }
        return (json, binary)
    }

    private static func resolveBuffers(root: [String: Any], binaryChunk: Data?) throws -> [Data] {
        var out: [Data] = []
        for buffer in root["buffers"] as? [[String: Any]] ?? [] {
            if buffer["uri"] == nil {
                guard let binaryChunk else { throw GLTFError.badChunk }
                out.append(binaryChunk)
            } else if let uri = buffer["uri"] as? String,
                      let range = uri.range(of: "base64,") {
                out.append(Data(base64Encoded: String(uri[range.upperBound...])) ?? Data())
            } else {
                throw GLTFError.unsupported("external buffer file")
            }
        }
        if out.isEmpty, let binaryChunk { out.append(binaryChunk) }
        return out
    }

    private static func sliceBufferView(_ index: Int,
                                        bufferViews: [[String: Any]],
                                        buffers: [Data]) -> Data? {
        guard bufferViews.indices.contains(index) else { return nil }
        let view = bufferViews[index]
        let bufferIndex = view["buffer"] as? Int ?? 0
        guard buffers.indices.contains(bufferIndex) else { return nil }

        let offset = view["byteOffset"] as? Int ?? 0
        let length = view["byteLength"] as? Int ?? 0
        let buffer = buffers[bufferIndex]
        guard offset + length <= buffer.count else { return nil }
        return buffer.subdata(in: offset..<(offset + length))
    }

    // MARK: - Node transforms

    private static func localTransform(of node: [String: Any]) -> Float4x4 {
        if let m = node["matrix"] as? [Double], m.count == 16 {
            // glTF matrices are column-major, same as simd.
            let f = m.map { Float($0) }
            return Float4x4(columns: (SIMD4(f[0], f[1], f[2], f[3]),
                                      SIMD4(f[4], f[5], f[6], f[7]),
                                      SIMD4(f[8], f[9], f[10], f[11]),
                                      SIMD4(f[12], f[13], f[14], f[15])))
        }

        var result = matrix_identity_float4x4

        if let t = node["translation"] as? [Double], t.count == 3 {
            result = Float4x4.translation(SIMD3(Float(t[0]), Float(t[1]), Float(t[2])))
        }
        if let r = node["rotation"] as? [Double], r.count == 4 {
            // glTF stores quaternions xyzw; simd_quatf takes ix, iy, iz, r.
            let q = simd_quatf(ix: Float(r[0]), iy: Float(r[1]), iz: Float(r[2]), r: Float(r[3]))
            result = result * Float4x4(q)
        }
        if let s = node["scale"] as? [Double], s.count == 3 {
            result = result * Float4x4.scale(SIMD3(Float(s[0]), Float(s[1]), Float(s[2])))
        }

        return result
    }

    // MARK: - Primitives

    private static func buildPrimitive(_ primitive: [String: Any],
                                       transform: Float4x4,
                                       nodeName: String,
                                       accessors: [[String: Any]],
                                       bufferViews: [[String: Any]],
                                       buffers: [Data],
                                       materials: [[String: Any]],
                                       textures: [[String: Any]]) -> GLTFPrimitive? {
        guard let attributes = primitive["attributes"] as? [String: Any],
              let positionIndex = attributes["POSITION"] as? Int,
              let positions = readAccessor(positionIndex, accessors: accessors,
                                           bufferViews: bufferViews, buffers: buffers)
        else { return nil }

        let count = positions.count / positions.componentsPerElement
        guard count > 0 else { return nil }

        var normals: AccessorData?
        if let index = attributes["NORMAL"] as? Int {
            normals = readAccessor(index, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
        }
        var uvs: AccessorData?
        if let index = attributes["TEXCOORD_0"] as? Int {
            uvs = readAccessor(index, accessors: accessors, bufferViews: bufferViews, buffers: buffers)
        }

        // Normals transform by the inverse transpose, so non-uniform node scales stay correct.
        let normalMatrix = transform.upperLeft3x3.inverse.transpose

        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(count)

        for i in 0..<count {
            let p = positions.vector3(at: i)
            let world = transform * SIMD4<Float>(p, 1)

            var normal = SIMD3<Float>(0, 0, 1)
            if let normals, i * normals.componentsPerElement < normals.count {
                normal = normalMatrix * normals.vector3(at: i)
                let length = simd_length(normal)
                normal = length > 1e-6 ? normal / length : SIMD3(0, 0, 1)
            }

            var uv = SIMD2<Float>(0, 0)
            if let uvs, i * uvs.componentsPerElement < uvs.count {
                uv = uvs.vector2(at: i)
            }

            vertices.append(MeshVertex(position: SIMD3(world.x, world.y, world.z),
                                       normal: normal,
                                       uv: uv))
        }

        var indices: [UInt32] = []
        if let indexAccessor = primitive["indices"] as? Int,
           let data = readAccessor(indexAccessor, accessors: accessors,
                                   bufferViews: bufferViews, buffers: buffers) {
            indices = data.asIndices()
        } else {
            indices = Array(0..<UInt32(count))
        }

        // If the file had no normals, derive flat ones so lighting still reads correctly.
        if normals == nil {
            recomputeNormals(vertices: &vertices, indices: indices)
        }

        var materialName = ""
        var baseColor = SIMD4<Float>(1, 1, 1, 1)
        var roughness: Float = 1
        var metalness: Float = 1
        var imageIndex: Int?
        var uvTransform: (offset: SIMD2<Float>, scale: SIMD2<Float>, rotation: Float)?
        var emissive = SIMD3<Float>(0, 0, 0)
        var emissiveImageIndex: Int?
        var specularColorFactor = SIMD3<Float>(1, 1, 1)
        var specularIntensity: Float = 1
        var ior: Float = 1.5
        var transmission: Float = 0

        /// A texture reference (`{ index, texCoord }`) resolved to the image it samples.
        func imageSource(of reference: Any?) -> Int? {
            guard let reference = reference as? [String: Any],
                  let textureIndex = reference["index"] as? Int,
                  textures.indices.contains(textureIndex)
            else { return nil }
            return textures[textureIndex]["source"] as? Int
        }

        if let materialIndex = primitive["material"] as? Int, materials.indices.contains(materialIndex) {
            let material = materials[materialIndex]
            materialName = (material["name"] as? String ?? "").lowercased()

            if let pbr = material["pbrMetallicRoughness"] as? [String: Any] {
                if let factor = pbr["baseColorFactor"] as? [Double], factor.count == 4 {
                    baseColor = SIMD4(Float(factor[0]), Float(factor[1]), Float(factor[2]), Float(factor[3]))
                }
                if let factor = pbr["roughnessFactor"] as? Double { roughness = Float(factor) }
                if let factor = pbr["metallicFactor"] as? Double { metalness = Float(factor) }
                if let texture = pbr["baseColorTexture"] as? [String: Any] {
                    imageIndex = imageSource(of: texture)
                    if let extensions = texture["extensions"] as? [String: Any],
                       let ktt = extensions["KHR_texture_transform"] as? [String: Any] {
                        let offset = (ktt["offset"] as? [Double]).map { SIMD2(Float($0[0]), Float($0[1])) }
                            ?? SIMD2<Float>(0, 0)
                        let scale = (ktt["scale"] as? [Double]).map { SIMD2(Float($0[0]), Float($0[1])) }
                            ?? SIMD2<Float>(1, 1)
                        let rotation = Float(ktt["rotation"] as? Double ?? 0)
                        uvTransform = (offset, scale, rotation)
                    }
                }
            }

            if let factor = material["emissiveFactor"] as? [Double], factor.count == 3 {
                emissive = SIMD3(Float(factor[0]), Float(factor[1]), Float(factor[2]))
            }
            emissiveImageIndex = imageSource(of: material["emissiveTexture"])

            // The UV transform is baked into the vertices, so a second texture with its *own*
            // transform cannot be honoured. No shipping asset does it; say so if one starts.
            if let emissiveTexture = material["emissiveTexture"] as? [String: Any],
               let extensions = emissiveTexture["extensions"] as? [String: Any],
               extensions["KHR_texture_transform"] != nil {
                Log.render("glTF material '\(materialName)': KHR_texture_transform on emissiveTexture is ignored")
            }

            if let extensions = material["extensions"] as? [String: Any] {
                // Scales `emissiveFactor`. three.js sets `emissiveIntensity`, which multiplies
                // the emissive colour — so folding it in here is the same thing.
                if let strength = (extensions["KHR_materials_emissive_strength"]
                    as? [String: Any])?["emissiveStrength"] as? Double {
                    emissive *= Float(strength)
                }

                if let specular = extensions["KHR_materials_specular"] as? [String: Any] {
                    if let factor = specular["specularFactor"] as? Double {
                        specularIntensity = Float(factor)
                    }
                    if let factor = specular["specularColorFactor"] as? [Double], factor.count == 3 {
                        specularColorFactor = SIMD3(Float(factor[0]), Float(factor[1]), Float(factor[2]))
                    }
                }

                if let value = (extensions["KHR_materials_ior"] as? [String: Any])?["ior"] as? Double {
                    ior = Float(value)
                }

                if let factor = (extensions["KHR_materials_transmission"]
                    as? [String: Any])?["transmissionFactor"] as? Double {
                    transmission = Float(factor)
                }
            }
        }

        // three.js: `specularColor = min(pow2((ior − 1)/(ior + 1)) · specularColorFactor, 1)
        // · specularIntensity`, before the metalness mix the shader applies against albedo.
        let iorTerm = pow((ior - 1) / (ior + 1), 2)
        let specularF0 = simd_min(specularColorFactor * iorTerm, SIMD3(repeating: 1)) * specularIntensity

        return GLTFPrimitive(vertices: vertices,
                             indices: indices,
                             nodeName: nodeName,
                             materialName: materialName,
                             baseColor: baseColor,
                             roughness: roughness,
                             metalness: metalness,
                             imageIndex: imageIndex,
                             uvTransform: uvTransform,
                             emissive: emissive,
                             emissiveImageIndex: emissiveImageIndex,
                             specularF0: specularF0,
                             specularIntensity: specularIntensity,
                             transmission: transmission)
    }

    private static func recomputeNormals(vertices: inout [MeshVertex], indices: [UInt32]) {
        var accumulated = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            let face = simd_cross(vertices[b].position - vertices[a].position,
                                  vertices[c].position - vertices[a].position)
            accumulated[a] += face
            accumulated[b] += face
            accumulated[c] += face
        }

        for index in vertices.indices {
            let length = simd_length(accumulated[index])
            vertices[index].normal = length > 1e-6 ? accumulated[index] / length : SIMD3(0, 0, 1)
        }
    }

    // MARK: - Accessors

    /// A decoded accessor, normalised to `Float` (or raw integers for index buffers).
    private struct AccessorData {
        var floats: [Float]
        var componentsPerElement: Int
        var count: Int { floats.count }

        func vector2(at index: Int) -> SIMD2<Float> {
            let base = index * componentsPerElement
            guard base + 1 < floats.count else { return .zero }
            return SIMD2(floats[base], floats[base + 1])
        }

        func vector3(at index: Int) -> SIMD3<Float> {
            let base = index * componentsPerElement
            guard base + 2 < floats.count else { return .zero }
            return SIMD3(floats[base], floats[base + 1], floats[base + 2])
        }

        func vector4(at index: Int) -> SIMD4<Float> {
            let base = index * componentsPerElement
            guard base + 3 < floats.count else { return .zero }
            return SIMD4(floats[base], floats[base + 1], floats[base + 2], floats[base + 3])
        }

        /// A MAT4 element. glTF stores matrices column-major, same as simd.
        func matrix4(at index: Int) -> Float4x4 {
            let base = index * componentsPerElement
            guard base + 15 < floats.count else { return matrix_identity_float4x4 }
            return Float4x4(columns: (SIMD4(floats[base], floats[base + 1], floats[base + 2], floats[base + 3]),
                                      SIMD4(floats[base + 4], floats[base + 5], floats[base + 6], floats[base + 7]),
                                      SIMD4(floats[base + 8], floats[base + 9], floats[base + 10], floats[base + 11]),
                                      SIMD4(floats[base + 12], floats[base + 13], floats[base + 14], floats[base + 15])))
        }

        func asIndices() -> [UInt32] {
            floats.map { UInt32(max(0, $0)) }
        }
    }

    private static func componentsPerElement(_ type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }

    private static func componentByteSize(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1   // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2   // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4   // UNSIGNED_INT, FLOAT
        default: return 4
        }
    }

    private static func readAccessor(_ index: Int,
                                     accessors: [[String: Any]],
                                     bufferViews: [[String: Any]],
                                     buffers: [Data]) -> AccessorData? {
        guard accessors.indices.contains(index) else { return nil }
        let accessor = accessors[index]

        let count = accessor["count"] as? Int ?? 0
        let type = accessor["type"] as? String ?? "SCALAR"
        let componentType = accessor["componentType"] as? Int ?? 5126
        let normalized = accessor["normalized"] as? Bool ?? false
        let components = componentsPerElement(type)
        let componentSize = componentByteSize(componentType)

        if accessor["sparse"] != nil {
            Log.render("glTF: sparse accessors are not supported (accessor \(index))")
            return nil
        }

        var floats = [Float](repeating: 0, count: count * components)

        // An accessor with no bufferView reads as all zeroes, per spec.
        guard let viewIndex = accessor["bufferView"] as? Int,
              bufferViews.indices.contains(viewIndex) else {
            return AccessorData(floats: floats, componentsPerElement: components)
        }

        let view = bufferViews[viewIndex]
        let bufferIndex = view["buffer"] as? Int ?? 0
        guard buffers.indices.contains(bufferIndex) else { return nil }
        let buffer = buffers[bufferIndex]

        let viewOffset = view["byteOffset"] as? Int ?? 0
        let accessorOffset = accessor["byteOffset"] as? Int ?? 0
        let stride = view["byteStride"] as? Int ?? (components * componentSize)
        let base = viewOffset + accessorOffset

        buffer.withUnsafeBytes { raw in
            for element in 0..<count {
                let elementBase = base + element * stride
                for component in 0..<components {
                    let at = elementBase + component * componentSize
                    guard at + componentSize <= raw.count else { continue }

                    let value: Float
                    switch componentType {
                    case 5126:
                        value = raw.loadUnaligned(fromByteOffset: at, as: Float.self)
                    case 5125:
                        value = Float(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                    case 5123:
                        let v = raw.loadUnaligned(fromByteOffset: at, as: UInt16.self)
                        value = normalized ? Float(v) / 65535 : Float(v)
                    case 5122:
                        let v = raw.loadUnaligned(fromByteOffset: at, as: Int16.self)
                        value = normalized ? max(Float(v) / 32767, -1) : Float(v)
                    case 5121:
                        let v = raw.loadUnaligned(fromByteOffset: at, as: UInt8.self)
                        value = normalized ? Float(v) / 255 : Float(v)
                    case 5120:
                        let v = raw.loadUnaligned(fromByteOffset: at, as: Int8.self)
                        value = normalized ? max(Float(v) / 127, -1) : Float(v)
                    default:
                        value = 0
                    }
                    floats[element * components + component] = value
                }
            }
        }

        return AccessorData(floats: floats, componentsPerElement: components)
    }
}

private extension Float4x4 {
    /// The rotation/scale part, for transforming normals.
    var upperLeft3x3: simd_float3x3 {
        simd_float3x3(columns: (SIMD3(columns.0.x, columns.0.y, columns.0.z),
                                SIMD3(columns.1.x, columns.1.y, columns.1.z),
                                SIMD3(columns.2.x, columns.2.y, columns.2.z)))
    }
}
