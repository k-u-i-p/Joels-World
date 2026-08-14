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
enum MaterialSlot: Hashable {
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
    /// The ORM map: G scales `roughness`, B scales `metalness`. See
    /// `GLTFPrimitive.metallicRoughnessImageIndex` for why leaving this unsampled was not a
    /// missing refinement but a material bug.
    var metallicRoughnessTexture: MTLTexture?
    /// The glTF material extensions, resolved by `GLTFLoader`. Defaults here reproduce
    /// `MeshStandardMaterial` exactly, so a model using none of them renders as before.
    var surface: SurfaceExtensions
    var emissiveTexture: MTLTexture?
    /// The material's tangent-space normal map. Nine of the props have one; everything else is
    /// lit off its geometry as before.
    var normalTexture: MTLTexture?
    /// `normalTexture.scale`.
    var normalScale: Float = 1
    /// `doubleSided` — the draw turns culling off rather than leaving the pass's back-face cull
    /// in place. A leaf card has no reverse side to hide.
    var doubleSided: Bool = false
    /// `alphaCutoff` for a `MASK` material, 0 otherwise.
    var alphaCutoff: Float = 0
    var mesh: GPUMesh
}

/// The parts of a glTF material that only `MeshPhysicalMaterial` carries: emission, the
/// dielectric F0 that `KHR_materials_ior` / `_specular` move off 0.04, and transmission.
struct SurfaceExtensions: Hashable {
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
    /// The model's own-space extent, unioned across every group. `PropRenderer` runs a
    /// placement's transform over this to get the sphere it culls against. Empty for a model
    /// that parsed to no geometry, which is then never culled — it draws nothing anyway.
    var bounds: BoundingBox = .empty
}

/// How long a loaded model stays resident.
enum ModelLifetime {
    /// Dropped when the map changes. Everything a map or a minigame places: the campus
    /// buildings, the benches, the tennis stadium. Between them these are most of the 104 MB
    /// of models, and none of it is worth holding once the player has walked out of the map.
    case map
    /// Kept for the life of the session. Only the tennis racket a character holds, which
    /// belongs to a character rather than to any one map.
    case session
}

/// Loads `.glb` models and turns them into per-slot GPU meshes, deduplicated by path so twenty
/// characters wearing the same head cause one read and one parse.
///
/// All 104 MB of models ship inside the app (PLAN.md §5), so a load is a file read followed by
/// a parse. The parse is the expensive half — heads arrive as up to 46 primitives — and runs off
/// the main queue; only the GPU upload comes back to it.
///
/// Every stored property here is main-thread-only. The parse queue touches nothing but its own
/// locals until it hops back.
final class ModelStore {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    /// Concurrent, so `maxConcurrentStreamedLoads` means what it says. `GLTFLoader` is static
    /// functions over their arguments, so several parses at once share nothing.
    private let parseQueue = DispatchQueue(label: "com.allr.joelsworld.gltf",
                                           qos: .userInitiated, attributes: .concurrent)

    private var models: [String: LoadedModel] = [:]
    /// Requested, not yet parsed. Also what stops a second request for the same path becoming a
    /// second load.
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []
    /// Paths asked for with `.map`, and exactly the ones `evictMapModels` drops.
    private var mapScoped: Set<String> = []
    /// Paths anything has ever asked for with `.session`. A model both a map and a character
    /// want outlives the map — the cheaper mistake by far, since the only `.session` model in
    /// the game is one tennis racket.
    private var sessionScoped: Set<String> = []
    /// Bumped by every eviction. A load that was already in flight when the map changed
    /// compares its captured value against this and throws its result away rather than
    /// re-populating the cache with the map the player has just left.
    private var generation = 0

    /// **The whole point of the streaming budget.** Walking into the junior campus places 271
    /// props drawn from 28 distinct models; without a cap the first frame on that map kicks off
    /// 28 reads and 28 parses, and the campus buildings alone are hundreds of thousands of
    /// vertices — three parses of that size in flight is already the memory peak worth having.
    ///
    /// Three at a time, nearest first, spreads the arrival over a second or so of walking. Props
    /// fade in from where the player is standing outward instead of everything landing together.
    static let maxConcurrentStreamedLoads = 3

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    /// Already-parsed model, if it is resident.
    func model(_ path: String) -> LoadedModel? { models[path] }

    func hasFailed(_ path: String) -> Bool { failed.contains(path) }

    /// True between the request and the parse finishing.
    func isLoading(_ path: String) -> Bool { inFlight.contains(path) }

    /// How many more streamed loads may start this frame. The caller checks this so it can
    /// spend the budget on the props nearest the player rather than on whichever it walks
    /// over first — see `PropRenderer.updateStreaming`.
    var streamingSlots: Int { max(0, Self.maxConcurrentStreamedLoads - inFlight.count) }

    /// Number of models currently holding GPU buffers and textures.
    var residentCount: Int { models.count }

    /// Fire-and-forget request for the render loop, which asks again on every frame until the
    /// model shows up; a repeat call costs a dictionary and a set lookup. `path` is relative to
    /// the asset root, e.g. `models/heads/x.glb`. Main thread only.
    func request(path: String, classifier: @escaping (GLTFPrimitive) -> MaterialSlot,
                 lifetime: ModelLifetime = .session) {
        // Before the early-out below, so a character asking for a model the map already placed
        // still promotes it out of map scope.
        switch lifetime {
        case .map:
            if !sessionScoped.contains(path) { mapScoped.insert(path) }
        case .session:
            sessionScoped.insert(path)
            mapScoped.remove(path)
        }

        if models[path] != nil || failed.contains(path) || inFlight.contains(path) { return }
        inFlight.insert(path)

        let requestGeneration = generation

        fetch(path: path) { [weak self] data in
            guard let self else { return }
            guard let data else {
                DispatchQueue.main.async {
                    // Worth a line. A prop whose GLB is not in the bundle draws nothing and says
                    // nothing, which looks exactly like a prop nobody ever placed — and the
                    // stats line below counts it as neither drawn nor culled.
                    Log.render("Model '\(path)' could not be read — is it in the app bundle?")
                    self.failed.insert(path)
                    self.inFlight.remove(path)
                }
                return
            }

            // Already on `parseQueue` — `fetch` reads there so the mapped-file read and the
            // page faults it defers are off the frame's thread too.
            let started = CFAbsoluteTimeGetCurrent()
            do {
                var asset = try GLTFLoader.load(data: data)
                let (merged, bounds) = Self.merge(primitives: asset.primitives,
                                                  classifier: classifier)
                // Two facts about the primitives, so the vertex arrays themselves can go here
                // rather than being held across the hop to the main queue. They are the larger
                // half of a parse and `merged` is already a second copy of them.
                let primitiveCount = asset.primitives.count
                let generatedTangents = asset.primitives.contains {
                    $0.normalImageIndex != nil && !$0.authoredTangents
                }
                asset.primitives = []
                let images = asset.images
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
                        guard let bytes = images[imageIndex] else { return nil }
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
                        let key = group.key
                        var surface = key.surface
                        let emissiveTexture = texture(key.emissiveImageIndex)
                        if key.emissiveImageIndex != nil, emissiveTexture == nil {
                            surface.emissive = .zero
                        }

                        groups.append(ModelGroup(slot: key.slot,
                                                 baseColor: key.baseColor,
                                                 roughness: key.roughness,
                                                 metalness: key.metalness,
                                                 texture: texture(key.imageIndex),
                                                 // Linear, like the normal map: G and B are
                                                 // material scalars, not a colour. Decoding
                                                 // them as sRGB would darken both and make
                                                 // every mapped surface read rougher and less
                                                 // metallic than it was authored.
                                                 metallicRoughnessTexture:
                                                    texture(key.metallicRoughnessImageIndex,
                                                            srgb: false),
                                                 surface: surface,
                                                 emissiveTexture: emissiveTexture,
                                                 normalTexture: texture(key.normalImageIndex,
                                                                        srgb: false),
                                                 normalScale: key.normalScale,
                                                 doubleSided: key.doubleSided,
                                                 alphaCutoff: key.alphaCutoff,
                                                 mesh: gpuMesh))
                    }

                    let model = LoadedModel(groups: groups, bounds: bounds)

                    // The map changed while this was parsing. Caching it now would undo the
                    // eviction that map change performed — the old campus back in memory,
                    // held by nothing that will ever draw it. Waiters below still get the
                    // model; only the cache entry is skipped.
                    let stale = lifetime == .map && requestGeneration != self.generation
                    if !stale {
                        self.models[path] = model
                    }
                    self.inFlight.remove(path)

                    Log.render(String(format: "Model '%@': %d primitives → %d draw groups in %.0f ms%@",
                                      path, primitiveCount, groups.count, elapsed,
                                      stale ? " (discarded — map changed)" : ""))

                    // Says nothing for the twelve models with no normal map, and one line for
                    // the nine that have one. Worth having: a normal map that silently did
                    // not arrive looks exactly like a model that never had one.
                    let mapped = groups.filter { $0.normalTexture != nil }
                    if !mapped.isEmpty {
                        Log.render(String(format: "  normal maps on %d of %d groups, "
                                          + "scale %.2f, tangents %@",
                                          mapped.count, groups.count, mapped[0].normalScale,
                                          generatedTangents ? "generated from the UVs"
                                                            : "from the file"))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    Log.render("Model '\(path)' failed to parse: \(error)")
                    self.failed.insert(path)
                    self.inFlight.remove(path)
                }
            }
        }
    }

    // MARK: - Eviction

    /// Drops every `.map` model, called when the map changes.
    ///
    /// This is what makes the map-scoped lifetime worth having: the GPU buffers and textures a
    /// `LoadedModel` holds are freed the moment the last reference to it goes, so clearing the
    /// dictionary hands the memory back. Without it, an afternoon of walking between the campus,
    /// the main building, detention and the tennis stadium accumulates every model any of them
    /// ever used and never gives one back.
    ///
    /// Main thread only, so it can only race a parse, not a dictionary write — and `generation`
    /// covers the parse.
    func evictMapModels() {
        guard !mapScoped.isEmpty else { return }
        generation += 1

        var dropped = 0
        for path in mapScoped where models.removeValue(forKey: path) != nil { dropped += 1 }
        mapScoped.removeAll()

        // `failed` is deliberately kept. A model that would not parse is a packaging mistake,
        // not a transient one, and re-reading it on every map change buys nothing.
        if dropped > 0 {
            Log.render("Models: evicted \(dropped) map-scoped model(s), \(models.count) still resident")
        }
    }

    // MARK: - Fetching

    /// Every GLB ships with the app (PLAN.md §5), so this is a mapped file read. `mappedIfSafe`
    /// matters here more than anywhere else: a head is up to 6 MB and several load at once the
    /// moment a crowded map opens.
    ///
    /// **The read happens on `parseQueue`, not on the caller's thread**, which is the frame's.
    /// `mappedIfSafe` makes the read itself look free — it is the page faults during the parse
    /// that cost — but "looks free" is not free, and 28 of them on the frame a map opens is a
    /// visible stall. The completion therefore runs on `parseQueue`.
    private func fetch(path: String, completion: @escaping (Data?) -> Void) {
        guard let url = AssetLocator.url(for: path) else {
            completion(nil)
            return
        }
        parseQueue.async {
            completion(try? Data(contentsOf: url, options: .mappedIfSafe))
        }
    }

    // MARK: - Merging

    /// Everything two primitives must agree on to share a buffer. A struct rather than the
    /// interpolated string this used to build per primitive: nothing can drop out of the key by
    /// being left off the end of it. That did happen — before the normal map and its scale were
    /// part of it, `antique_desk.glb`'s fourteen normal-mapped materials collapsed onto whichever
    /// group they matched on colour, and thirteen were drawn wearing the fourteenth's map.
    private struct GroupKey: Hashable {
        var slot: MaterialSlot
        var baseColor: SIMD4<Float>
        var roughness: Float
        var metalness: Float
        var imageIndex: Int?
        var surface: SurfaceExtensions
        var emissiveImageIndex: Int?
        var normalImageIndex: Int?
        var normalScale: Float
        var metallicRoughnessImageIndex: Int?
        /// Both of these change *how the group is drawn*, not just how it is shaded, so they
        /// have to split the group the same way a texture does — one cull mode and one cutoff
        /// per draw call.
        var doubleSided: Bool
        var alphaCutoff: Float
    }

    private struct MergedGroup {
        var key: GroupKey
        var mesh: MeshData
    }

    /// Collapses primitives into one buffer per key. Heads arrive as up to 46 separate
    /// primitives; this turns them into a handful of draws.
    ///
    /// Also unions the model's own-space bounds while it is already walking every vertex, since
    /// that is where the culling test's sphere comes from and a second pass over half a million
    /// vertices to get it would be pure waste.
    private static func merge(primitives: [GLTFPrimitive],
                              classifier: (GLTFPrimitive) -> MaterialSlot)
        -> (groups: [MergedGroup], bounds: BoundingBox) {
        var groups: [MergedGroup] = []
        var lookup: [GroupKey: Int] = [:]
        var bounds = BoundingBox.empty

        for primitive in primitives {
            let slot = classifier(primitive)

            // A slot-driven piece is recoloured at draw time and takes the rig's material
            // wholesale, so its authored look is irrelevant and every such piece shares one
            // buffer. The rig has no emissive or transmissive parts, hence `.standard`.
            let key: GroupKey
            if slot == .authored {
                key = GroupKey(slot: slot,
                               baseColor: primitive.baseColor,
                               roughness: primitive.roughness,
                               metalness: primitive.metalness,
                               imageIndex: primitive.imageIndex,
                               surface: SurfaceExtensions(
                                   emissive: primitive.emissive,
                                   specularF0: primitive.specularF0,
                                   specularIntensity: primitive.specularIntensity,
                                   transmission: primitive.transmission),
                               emissiveImageIndex: primitive.emissiveImageIndex,
                               normalImageIndex: primitive.normalImageIndex,
                               normalScale: primitive.normalScale,
                               metallicRoughnessImageIndex: primitive.metallicRoughnessImageIndex,
                               doubleSided: primitive.doubleSided,
                               alphaCutoff: primitive.alphaCutoff)
            } else {
                key = GroupKey(slot: slot, baseColor: SIMD4(1, 1, 1, 1), roughness: 1,
                               metalness: 0, imageIndex: nil, surface: .standard,
                               emissiveImageIndex: nil, normalImageIndex: nil, normalScale: 1,
                               metallicRoughnessImageIndex: nil,
                               doubleSided: false, alphaCutoff: 0)
            }

            let index: Int
            if let existing = lookup[key] {
                index = existing
            } else {
                index = groups.count
                groups.append(MergedGroup(key: key, mesh: MeshData(vertices: [], indices: [])))
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

            for vertex in primitiveVertices { bounds.expand(vertex.position) }

            let base = UInt32(groups[index].mesh.vertices.count)
            groups[index].mesh.vertices.append(contentsOf: primitiveVertices)
            groups[index].mesh.indices.append(contentsOf: primitive.indices.map { $0 + base })
        }

        return (groups, bounds)
    }
}

