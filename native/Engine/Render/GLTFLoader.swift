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

struct GLTFAsset {
    var primitives: [GLTFPrimitive]
    /// Encoded image bytes (PNG/JPEG), indexed by the order textures reference them.
    var images: [Int: Data]
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
/// images. No skinning, animation or morph targets — see `GLTFPrimitive`.
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

        return GLTFAsset(primitives: primitives, images: images)
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
