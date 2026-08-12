import Metal
import MetalKit
import simd

/// A vertex/index buffer pair ready to draw.
final class GPUMesh {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init?(device: MTLDevice, mesh: MeshData) {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
              let vertexBuffer = device.makeBuffer(bytes: mesh.vertices,
                                                   length: MemoryLayout<MeshVertex>.stride * mesh.vertices.count,
                                                   options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                                  length: MemoryLayout<UInt32>.stride * mesh.indices.count,
                                                  options: .storageModeShared)
        else { return nil }

        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = mesh.indices.count
    }
}

/// Which rig colour a piece of an imported model takes. Port of the name-matching in
/// `characters.js:189-206` (heads) and the blanket tint in `applyShoeModel` (shoes).
enum MaterialSlot {
    /// Node name contains `hair` — takes the character's hair colour.
    case hair
    /// Node name contains `face`, `head` or `skin` — takes the character's skin colour.
    case skin
    /// Every shoe mesh, tinted with the character's shoe colour.
    case shoe
    /// Keeps the colour and texture the artist authored (eyes, eyelashes, trim).
    case authored
}

/// One draw call's worth of an imported model: all primitives that share a slot, colour
/// and texture, merged into a single buffer.
struct ModelGroup {
    var slot: MaterialSlot
    var baseColor: SIMD4<Float>
    /// Authored `MeshStandardMaterial` parameters. Slot-driven pieces overwrite these with the
    /// rig's own material table (`characters.js:771-778`).
    var roughness: Float
    var metalness: Float
    var texture: MTLTexture?
    /// The glTF material extensions, resolved by `GLTFLoader`. Defaults here reproduce
    /// `MeshStandardMaterial` exactly, so a model using none of them renders as before.
    var surface: SurfaceExtensions
    var emissiveTexture: MTLTexture?
    /// The material's tangent-space normal map. Nine of the props have one; everything else is
    /// lit off its geometry as before.
    var normalTexture: MTLTexture?
    /// `normalTexture.scale`.
    var normalScale: Float = 1
    var mesh: GPUMesh
}

/// The parts of a glTF material that only `MeshPhysicalMaterial` carries: emission, the
/// dielectric F0 that `KHR_materials_ior` / `_specular` move off 0.04, and transmission.
struct SurfaceExtensions {
    var emissive: SIMD3<Float> = .zero
    var specularF0: SIMD3<Float> = SIMD3(repeating: 0.04)
    var specularIntensity: Float = 1
    var transmission: Float = 0

    static let standard = SurfaceExtensions()

    var isEmissive: Bool { emissive != .zero }
    var isTransmissive: Bool { transmission > 0 }
}

struct LoadedModel {
    var groups: [ModelGroup]
}

/// Loads `.glb` models and turns them into per-slot GPU meshes, with in-flight deduplication
/// so twenty characters wearing the same head cause one download and one parse.
///
/// All 104 MB of models ship inside the app (PLAN.md §5), so a load is a file read followed by
/// a parse. The parse is the expensive half — heads arrive as up to 46 primitives — and still
/// runs off the main queue.
final class ModelStore {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let parseQueue = DispatchQueue(label: "com.allr.joelsworld.gltf", qos: .userInitiated)

    private var models: [String: LoadedModel] = [:]
    private var pending: [String: [(LoadedModel) -> Void]] = [:]
    private var failed: Set<String> = []

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    /// Already-parsed model, if it is resident.
    func model(_ path: String) -> LoadedModel? { models[path] }

    func hasFailed(_ path: String) -> Bool { failed.contains(path) }

    /// Fire-and-forget request for the render loop, which asks again on every frame until the
    /// model shows up. Unlike `load` it queues no callback, so repeat calls cost nothing.
    func request(path: String, classifier: @escaping (GLTFPrimitive) -> MaterialSlot) {
        if models[path] != nil || failed.contains(path) || pending[path] != nil { return }
        load(path: path, classifier: classifier) { _ in }
    }

    /// Requests a model. `path` is relative to the asset root, e.g. `models/heads/x.glb`.
    /// The completion runs on the main thread, possibly synchronously if already loaded.
    func load(path: String, classifier: @escaping (GLTFPrimitive) -> MaterialSlot,
              completion: @escaping (LoadedModel) -> Void) {
        if let existing = models[path] {
            completion(existing)
            return
        }
        if failed.contains(path) { return }

        if pending[path] != nil {
            pending[path]?.append(completion)
            return
        }
        pending[path] = [completion]

        fetch(path: path) { [weak self] data in
            guard let self else { return }
            guard let data else {
                DispatchQueue.main.async {
                    self.failed.insert(path)
                    self.pending[path] = nil
                }
                return
            }

            self.parseQueue.async {
                let started = CFAbsoluteTimeGetCurrent()
                do {
                    let asset = try GLTFLoader.load(data: data)
                    let merged = Self.merge(asset: asset, classifier: classifier)
                    let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

                    DispatchQueue.main.async {
                        // A material can point its emissive map at the same image as its base
                        // colour (`banquet_table.glb` does), so images are uploaded once each.
                        // Keyed by image *and* colour space: the same image could in principle
                        // be a base colour on one material and a normal map on another, and the
                        // two need different textures. See the sRGB note below.
                        var textures: [String: MTLTexture] = [:]
                        func texture(_ imageIndex: Int?, srgb: Bool = true) -> MTLTexture? {
                            guard let imageIndex else { return nil }
                            let key = "\(imageIndex)-\(srgb)"
                            if let existing = textures[key] { return existing }
                            guard let bytes = asset.images[imageIndex] else { return nil }
                            // No vertical flip: glTF UVs put (0,0) at the image's top-left,
                            // which is already Metal's sampling origin. Flipping mirrors V,
                            // and materials that pack a sub-rectangle of an atlas through
                            // `KHR_texture_transform` — as every surface of
                            // `junior_school_buildings.glb` does — then sample the wrong
                            // region entirely. (Map tiles *do* need the flip; their quad UVs
                            // are built bottom-up. See `TextureCache`.)
                            //
                            // sRGB is on because glTF base-colour and emissive textures are
                            // both sRGB-encoded and three.js tags them as such; the sampler
                            // decodes so shading stays linear. **A normal map passes `srgb:
                            // false`**: its channels are the x, y and z of a direction, not a
                            // colour, and decoding them as one tilts the whole surface away
                            // from the light — a prop that looks grimy rather than bumpy.
                            //
                            // The Core Graphics fallback is the same one the tiles need, and
                            // it is load-bearing here: `desk.glb`'s emissive map is a 1-bit
                            // greyscale PNG that `MTKTextureLoader` will not decode, and
                            // losing it leaves that material's white `emissiveFactor`
                            // unmodulated — a solid white desk, 27 times over.
                            let loaded = (try? self.textureLoader.newTexture(
                                data: bytes,
                                options: [.SRGB: srgb,
                                          .generateMipmaps: false]))
                                ?? ImageDecoder.texture(from: bytes, device: self.device,
                                                        flipped: false, srgb: srgb)
                            if let loaded {
                                textures[key] = loaded
                            } else {
                                Log.render("Model '\(path)': image \(imageIndex) failed to decode (\(bytes.count) bytes)")
                            }
                            return loaded
                        }

                        var groups: [ModelGroup] = []
                        for group in merged {
                            guard let gpuMesh = GPUMesh(device: self.device, mesh: group.mesh) else { continue }

                            // glTF multiplies `emissiveFactor` by the map, so a *declared* map
                            // that would not decode has to zero the factor rather than be
                            // treated as absent — an unmodulated white factor is far more
                            // wrong than no emission at all.
                            var surface = group.surface
                            let emissiveTexture = texture(group.emissiveImageIndex)
                            if group.emissiveImageIndex != nil, emissiveTexture == nil {
                                surface.emissive = .zero
                            }

                            groups.append(ModelGroup(slot: group.slot,
                                                     baseColor: group.baseColor,
                                                     roughness: group.roughness,
                                                     metalness: group.metalness,
                                                     texture: texture(group.imageIndex),
                                                     surface: surface,
                                                     emissiveTexture: emissiveTexture,
                                                     normalTexture: texture(group.normalImageIndex,
                                                                            srgb: false),
                                                     normalScale: group.normalScale,
                                                     mesh: gpuMesh))
                        }

                        let model = LoadedModel(groups: groups)
                        self.models[path] = model
                        Log.render(String(format: "Model '%@': %d primitives → %d draw groups in %.0f ms",
                                          path, asset.primitives.count, groups.count, elapsed))

                        // Says nothing for the twelve models with no normal map, and one line for
                        // the nine that have one. Worth having: a normal map that silently did
                        // not arrive looks exactly like a model that never had one.
                        let mapped = groups.filter { $0.normalTexture != nil }
                        if !mapped.isEmpty {
                            let generated = asset.primitives.contains {
                                $0.normalImageIndex != nil && !$0.authoredTangents
                            }
                            Log.render(String(format: "  normal maps on %d of %d groups, "
                                              + "scale %.2f, tangents %@",
                                              mapped.count, groups.count, mapped[0].normalScale,
                                              generated ? "generated from the UVs" : "from the file"))
                        }

                        let waiters = self.pending[path] ?? []
                        self.pending[path] = nil
                        for waiter in waiters { waiter(model) }
                    }
                } catch {
                    DispatchQueue.main.async {
                        Log.render("Model '\(path)' failed to parse: \(error)")
                        self.failed.insert(path)
                        self.pending[path] = nil
                    }
                }
            }
        }
    }

    // MARK: - Fetching

    /// Every GLB ships with the app (PLAN.md §5), so this is a mapped file read. `mappedIfSafe`
    /// matters here more than anywhere else: a head is up to 6 MB and several load at once the
    /// moment a crowded map opens.
    private func fetch(path: String, completion: @escaping (Data?) -> Void) {
        guard let url = AssetLocator.url(for: path) else {
            completion(nil)
            return
        }
        completion(try? Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: - Merging

    private struct MergedGroup {
        var slot: MaterialSlot
        var baseColor: SIMD4<Float>
        var roughness: Float
        var metalness: Float
        var imageIndex: Int?
        var surface: SurfaceExtensions
        var emissiveImageIndex: Int?
        var normalImageIndex: Int?
        var normalScale: Float
        var mesh: MeshData
    }

    /// Collapses primitives into one buffer per (slot, colour, texture). Heads arrive as up to
    /// 46 separate primitives; this turns them into a handful of draws.
    private static func merge(asset: GLTFAsset,
                              classifier: (GLTFPrimitive) -> MaterialSlot) -> [MergedGroup] {
        var groups: [MergedGroup] = []
        var lookup: [String: Int] = [:]

        for primitive in asset.primitives {
            let slot = classifier(primitive)

            // Slot-driven pieces are recoloured at draw time, so their authored colour is
            // irrelevant and they can all share one buffer.
            let color: SIMD4<Float> = (slot == .authored) ? primitive.baseColor : SIMD4(1, 1, 1, 1)
            let imageIndex = (slot == .authored) ? primitive.imageIndex : nil
            let roughness = (slot == .authored) ? primitive.roughness : 1
            let metalness = (slot == .authored) ? primitive.metalness : 0
            // A recoloured piece takes the rig's material wholesale, so it takes the rig's
            // (standard) surface too — the rig has no emissive or transmissive parts.
            let surface = (slot == .authored)
                ? SurfaceExtensions(emissive: primitive.emissive,
                                    specularF0: primitive.specularF0,
                                    specularIntensity: primitive.specularIntensity,
                                    transmission: primitive.transmission)
                : .standard
            let emissiveImageIndex = (slot == .authored) ? primitive.emissiveImageIndex : nil
            let normalImageIndex = (slot == .authored) ? primitive.normalImageIndex : nil
            let normalScale = (slot == .authored) ? primitive.normalScale : 1

            // The normal map and its scale join the key. Without them, `antique_desk.glb`'s
            // fourteen normal-mapped materials would collapse into whichever group they matched
            // on colour, and thirteen of them would be drawn wearing the fourteenth's map.
            let key = "\(slot)-\(color)-\(roughness)-\(metalness)-\(imageIndex ?? -1)"
                + "-\(surface.emissive)-\(surface.specularF0)-\(surface.specularIntensity)"
                + "-\(surface.transmission)-\(emissiveImageIndex ?? -1)"
                + "-\(normalImageIndex ?? -1)-\(normalScale)"
            let index: Int
            if let existing = lookup[key] {
                index = existing
            } else {
                groups.append(MergedGroup(slot: slot,
                                          baseColor: color,
                                          roughness: roughness,
                                          metalness: metalness,
                                          imageIndex: imageIndex,
                                          surface: surface,
                                          emissiveImageIndex: emissiveImageIndex,
                                          normalImageIndex: normalImageIndex,
                                          normalScale: normalScale,
                                          mesh: MeshData(vertices: [], indices: [])))
                index = groups.count - 1
                lookup[key] = index
            }

            var primitiveVertices = primitive.vertices
            if let transform = primitive.uvTransform {
                // `KHR_texture_transform` composes as translation · rotation · scale, and its
                // rotation matrix is [[cos, sin], [-sin, cos]]. Scale first, then rotate, then
                // offset — the order only shows up once an asset actually uses rotation, but
                // getting it wrong then is silent.
                let c = cos(transform.rotation), s = sin(transform.rotation)
                for vertexIndex in primitiveVertices.indices {
                    let scaled = primitiveVertices[vertexIndex].uv * transform.scale
                    let rotated = SIMD2(scaled.x * c + scaled.y * s,
                                        -scaled.x * s + scaled.y * c)
                    primitiveVertices[vertexIndex].uv = rotated + transform.offset
                }
            }

            let base = UInt32(groups[index].mesh.vertices.count)
            groups[index].mesh.vertices.append(contentsOf: primitiveVertices)
            groups[index].mesh.indices.append(contentsOf: primitive.indices.map { $0 + base })
        }

        return groups
    }
}

extension MaterialSlot: Equatable {}
