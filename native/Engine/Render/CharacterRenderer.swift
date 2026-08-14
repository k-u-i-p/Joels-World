import CoreGraphics
import Metal
import MetalKit
import simd

/// Uniform block for the character pipeline. Layout must match `CharacterUniforms` in
/// `Shaders.metal`; every member is 16-byte aligned so both sides agree without padding.
struct CharacterUniforms {
    var modelViewProjection: Float4x4
    var model: Float4x4
    var color: SIMD4<Float>
    /// xy = world pivot, z = map width, w = map height. A zero map size disables the mask.
    var clipParams: SIMD4<Float>
    /// x = textured, y = unlit, z = roughness, w = metalness.
    var flags: SIMD4<Float>
    /// xyz = emissive radiance, w = an emissive map is bound at texture 3.
    var emissive: SIMD4<Float>
    /// xyz = dielectric F0, w = specular intensity (three.js's `specularF90` before the
    /// metalness mix). The defaults (0.04, 1) are what `MeshStandardMaterial` hard-codes.
    var specular: SIMD4<Float>
    /// x = transmission, y = a tangent-space normal map is bound at texture 4, z = its
    /// `normalTexture.scale`, w unused. `y` used to say the clothing atlas was bound at texture
    /// 0; the clothing atlas dressed the procedural body and went with it.
    var surface: SIMD4<Float>
    /// x = `alphaCutoff` (0 for anything but a `MASK` material), y = a metallic-roughness map is
    /// bound at texture 5, zw unused.
    var extra: SIMD4<Float>
}

/// The `MeshStandardMaterial` parameters the rig is built from (`characters.js:771-778`),
/// plus the `MeshPhysicalMaterial` extras an imported glTF material can carry.
struct SurfaceMaterial {
    var roughness: Float
    var metalness: Float
    var extensions: SurfaceExtensions = .standard

    static let skin = SurfaceMaterial(roughness: 0.6, metalness: 0.1)
    static let shirt = SurfaceMaterial(roughness: 0.8, metalness: 0.0)
    static let arm = SurfaceMaterial(roughness: 0.8, metalness: 0.0)
    static let pants = SurfaceMaterial(roughness: 0.9, metalness: 0.0)
    static let shoe = SurfaceMaterial(roughness: 0.7, metalness: 0.2)
    static let hair = SurfaceMaterial(roughness: 0.5, metalness: 0.1)
    /// The material of an imported model's draw group, extensions included.
    init(group: ModelGroup) {
        self.init(roughness: group.roughness,
                  metalness: group.metalness,
                  extensions: group.surface)
    }

    init(roughness: Float, metalness: Float, extensions: SurfaceExtensions = .standard) {
        self.roughness = roughness
        self.metalness = metalness
        self.extensions = extensions
    }
}

extension CharacterUniforms {
    /// Packs a material into the three uniform slots the fragment shader reads.
    init(modelViewProjection: Float4x4,
         model: Float4x4,
         color: SIMD4<Float>,
         clipParams: SIMD4<Float>,
         textured: Bool,
         unlit: Bool,
         material: SurfaceMaterial,
         emissiveTextured: Bool = false,
         normalTextured: Bool = false,
         normalScale: Float = 1,
         metallicRoughnessTextured: Bool = false,
         alphaCutoff: Float = 0) {
        let extensions = material.extensions
        self.init(modelViewProjection: modelViewProjection,
                  model: model,
                  color: color,
                  clipParams: clipParams,
                  flags: SIMD4(textured ? 1 : 0, unlit ? 1 : 0,
                               material.roughness, material.metalness),
                  emissive: SIMD4(extensions.emissive, emissiveTextured ? 1 : 0),
                  specular: SIMD4(extensions.specularF0, extensions.specularIntensity),
                  surface: SIMD4(extensions.transmission, normalTextured ? 1 : 0, normalScale, 0),
                  extra: SIMD4(alphaCutoff, metallicRoughnessTextured ? 1 : 0, 0, 0))
    }
}

/// The four pipeline states a character needs, built by `Renderer` and handed to
/// `CharacterRenderer` because it is the thing that knows when to switch between them.
///
/// A character is drawn with two vertex functions in the same pass: the body is skinned and
/// everything hung off it — head, hair, shoes, the racket, emote props — is a rigid mesh with
/// its own transform. Both passes need both.
struct CharacterPipelines {
    var rigid: MTLRenderPipelineState
    var skinned: MTLRenderPipelineState
    var shadowRigid: MTLRenderPipelineState
    var shadowSkinned: MTLRenderPipelineState
}

/// Draws a character: one bought, rigged model, whatever it is holding, its emote props and its
/// ground shadow blob.
///
/// **It used to draw a character it generated.** Sessions 1–4 built a humanoid out of Swift — a
/// capsule per limb with a sphere in every joint, then one skinned mesh with a painted-on
/// uniform, plus a head GLB and a shoe GLB on top. Session 5 imported a bought model alongside
/// it and this session removed the generated one, so a character is one skinned draw now and the
/// ladder of fallbacks underneath it is gone. `SkinnedBody` and `ClothingAtlas` were the two
/// files that went; `git log` has them if the reasoning is ever wanted back.
///
/// The pose itself still comes from `CharacterRig`, which holds no Metal types and has no idea
/// any of this changed — that is `HumanoidRig`'s whole job.
final class CharacterRenderer {
    private let device: MTLDevice
    private let models: ModelStore

    /// The ground blob every character casts, and its falloff texture.
    private var shadowMesh: GPUMesh!
    private var shadowTexture: MTLTexture?

    /// Pipelines for the skinned body. Owned by `Renderer`, which builds them, and handed over
    /// here because the body has to be drawn with a different vertex function from the props it
    /// is drawn among.
    var pipelines: CharacterPipelines?

    /// Matches `SKIN_PALETTE_COUNT` in `Shaders.metal`. A bought model takes its colour from its
    /// own texture and uses none of these slots, but the skinned vertex function reads the
    /// palette unconditionally, so one is still bound and it has to be the size the shader
    /// expects. Scratch, so drawing a crowd allocates nothing.
    private static let paletteCount = 5
    private var palette = [SIMD4<Float>](repeating: .zero, count: paletteCount * 2)

    /// One GPU mesh per emote prop geometry, built up front and shared by every character.
    private var propMeshes: [PropMesh: GPUMesh] = [:]
    /// The ❤️ sprite `love` draws, rendered once from the same 128² canvas the JS uses.
    private var heartTexture: MTLTexture?

    /// GPU copy of the walkability mask, uploaded when the CPU mask changes.
    private var clipTexture: MTLTexture?
    private var clipTextureIdentity: ObjectIdentifier?
    private var clipMapSize = SIMD2<Float>(0, 0)

    /// A 1×1 white stand-in, so the fragment shader can always bind texture 0.
    private var whiteTexture: MTLTexture!
    /// A 1×1 flat normal, for texture 4 on every draw without a map of its own.
    private var flatNormalTexture: MTLTexture!

    // MARK: - Imported characters

    /// Bought, rigged models, keyed by asset path.
    private let importedBodies: ImportedCharacterStore
    /// One retargeter per model. `solve` is called once per character per pass and holds no
    /// per-character state between calls, so a model needs only one.
    private var retargeters: [String: HumanoidRetargeter] = [:]
    /// Scratch for the imported skeleton's joint matrices, on the CPU side.
    private var importedJoints: [Float4x4] = []

    /// **Where every character's joint matrices go, and why it is a ring and not a buffer.**
    ///
    /// A bought rig has too many bones for `setVertexBytes`' 4 KB — see `ImportedCharacterBody`
    /// — so the matrices go in a real buffer. `setVertexBytes` **copies** at encode time; a
    /// buffer does not. It is read by the GPU when the draw actually runs, which is after the
    /// whole frame has been encoded.
    ///
    /// So one buffer, written per character, gives every character in a crowd the *last*
    /// character's matrices — and those matrices carry position, so a class of thirty draws
    /// thirty times in one place and looks like one pupil with twenty-nine spare shadows. That
    /// is exactly what a school register looked like the first time the bought model drew the
    /// whole cast, and it had been latent since the model was imported: the procedural body was
    /// still the default, and it passed its bones the copying way.
    ///
    /// Each character now takes its own slice. The ring holds `framesInFlight` times the busiest
    /// frame yet seen, so by the time the cursor comes back round to a slice, the frame that
    /// wrote it is several frames retired and the GPU is long done with it.
    private var jointRing: MTLBuffer?
    private var jointCursor = 0
    private var jointBytesThisFrame = 0
    private var jointBytesBusiestFrame = 0

    /// What the drawable queue depth works out at. Three is what `MTKView` allows by default,
    /// and the ring is sized against it rather than against a guess at the cast size.
    private static let framesInFlight = 3
    /// Enough for a modest crowd before the ring ever has to grow.
    private static let jointRingMinimum = 64 * 1024

    /// **Which model a character is drawn with is the pose's business now**, not this class's.
    ///
    /// It used to be one path here, shared by everybody, for a good reason at the time: there was
    /// one bought model. `RigPose.model` carries the path per character now, resolved from
    /// `npc.json` by `CharacterModels`, and everything below — the body store, the retargeters,
    /// the profiles — is keyed by it.
    ///
    /// `JW_CHARACTER_MODEL` used to be read here and applied at draw time. It is
    /// `CharacterModels.override` now, resolved where the pose is built — see the note there for
    /// what a draw-time swap was quietly doing to every measurement the lab took.

    /// Per-model profile, read once from a `.rig.json` beside each model if it has one.
    private var profiles: [String: HumanoidProfile] = [:]

    /// Shared by the prop renderer, which needs the same "no texture here" placeholder.
    var fallbackTexture: MTLTexture { whiteTexture }
    /// The same, for the normal-map slot — props and scene primitives carry no tangents and so
    /// never sample it, but the shader declares it and Metal wants it bound.
    var fallbackNormalTexture: MTLTexture { flatNormalTexture }

    init?(device: MTLDevice, models: ModelStore) {
        self.device = device
        self.models = models
        self.importedBodies = ImportedCharacterStore(device: device)
        guard buildMeshes() else { return nil }

    }

    /// The profile for a model, read from disk the first time it is asked for.
    private func profile(for path: String) -> HumanoidProfile {
        if let known = profiles[path] { return known }
        let made = Self.profile(besideModel: path)
        profiles[path] = made
        return made
    }

    /// Reads `<model>.rig.json` if the model has one. Everything in it is optional; a
    /// Mixamo-named, Y-up, +Z-facing character needs no file at all.
    static func profile(besideModel path: String) -> HumanoidProfile {
        let sidecar = (path as NSString).deletingPathExtension + ".rig.json"
        guard let url = AssetLocator.url(for: sidecar),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .standard }
        Log.render("Imported character: using profile '\(sidecar)'")
        return HumanoidProfile(json: json)
    }

    // MARK: - Setup

    /// Builds what is left to build: the ground shadow, the white stand-in, the emote props and
    /// the heart sprite. It used to build a body too — a torso silhouette, a tapered capsule per
    /// limb segment, a sphere per joint and a lofted hand with a thumb, plus the skinned mesh
    /// and clothing atlas that replaced them. All of that drew the procedural character, and the
    /// procedural character is gone.
    private func buildMeshes() -> Bool {
        guard let shadowMesh = GPUMesh(device: device,
                                       mesh: MeshFactory.plane(width: 28, height: 28))
        else {
            Log.render("Failed to build character meshes")
            return false
        }
        self.shadowMesh = shadowMesh

        shadowTexture = ProceduralTextures.makeShadowTexture(device: device)
        whiteTexture = ProceduralTextures.makeWhiteTexture(device: device)
        flatNormalTexture = ProceduralTextures.makeFlatNormalTexture(device: device)
        buildPropMeshes()
        heartTexture = ProceduralTextures.makeHeartTexture(device: device)
        return whiteTexture != nil && flatNormalTexture != nil
    }

    private func buildPropMeshes() {
        func rotated(_ mesh: MeshData, _ rotation: Float4x4) -> MeshData {
            var copy = mesh
            MeshFactory.applyRotation(&copy, rotation)
            return copy
        }
        func scaled(_ mesh: MeshData, _ scale: SIMD3<Float>) -> MeshData {
            var copy = mesh
            MeshFactory.applyScale(&copy, scale)
            return copy
        }

        let sources: [PropMesh: MeshData] = [
            .laserBeam: rotated(MeshFactory.cylinder(radiusTop: 0.5, radiusBottom: 0.5,
                                                     height: 300, radialSegments: 8),
                                .rotationZ(.pi / 2)),
            .waterDrop: MeshFactory.sphere(radius: 1.5, widthSegments: 6, heightSegments: 6),
            .footprint: MeshFactory.circle(radius: 6, segments: 16),
            .apple: MeshFactory.sphere(radius: 3.5, widthSegments: 10, heightSegments: 10),
            .appleStem: MeshFactory.cylinder(radiusTop: 0.3, radiusBottom: 0.3, height: 3, radialSegments: 5),
            .crumb: MeshFactory.box(width: 1.5, height: 1.5, depth: 1.5),
            .plate: rotated(MeshFactory.cylinder(radiusTop: 8, radiusBottom: 6,
                                                 height: 1, radialSegments: 16),
                            .rotationX(.pi / 2)),
            .steak: rotated(MeshFactory.cylinder(radiusTop: 4, radiusBottom: 4,
                                                 height: 1.2, radialSegments: 8),
                            .rotationX(.pi / 2)),
            .cutlery: MeshFactory.box(width: 0.5, height: 6, depth: 2),
            .book: MeshFactory.box(width: 18, height: 14, depth: 0.5),
            .pen: MeshFactory.cylinder(radiusTop: 0.5, radiusBottom: 0.5, height: 6, radialSegments: 6),
            .dust: MeshFactory.sphere(radius: 4, widthSegments: 6, heightSegments: 6),
            .note: MeshFactory.box(width: 3, height: 3, depth: 3),
            .gasCloud: MeshFactory.sphere(radius: 8, widthSegments: 8, heightSegments: 8),
            .tearLarge: MeshFactory.sphere(radius: 2, widthSegments: 6, heightSegments: 6),
            .tearSmall: MeshFactory.sphere(radius: 1.5, widthSegments: 4, heightSegments: 4),
            .tennisBall: MeshFactory.sphere(radius: 2, widthSegments: 20, heightSegments: 20),
            // **Bigger than the JS, on purpose** — see `PropMesh.rugbyBall`. A bought pupil is
            // getting on for eighty engine units tall where the abstract rig it is posed from is
            // about sixty, so a ball built to the rig's scale reads as a golf ball in its hands.
            .rugbyBall: scaled(MeshFactory.sphere(radius: 4.5, widthSegments: 20, heightSegments: 16),
                               SIMD3(1.55, 1, 1)),
            .ripple: rotated(MeshFactory.torus(radius: 5, tube: 0.5,
                                               radialSegments: 4, tubularSegments: 16),
                             .rotationX(.pi / 2)),
            .zBarFlat: MeshFactory.box(width: 4, height: 1, depth: 1),
            .zBarDiagonal: MeshFactory.box(width: 1, height: 4, depth: 1),
            // A sprite is a unit quad; the camera-facing basis and the scale come from the pose.
            .heart: MeshFactory.plane(width: 1, height: 1),
        ]

        for (key, mesh) in sources {
            if let gpu = GPUMesh(device: device, mesh: mesh) {
                propMeshes[key] = gpu
            } else {
                Log.render("Failed to build prop mesh \(key)")
            }
        }
    }

    // MARK: - Clip mask upload

    /// Mirrors the CPU walkability mask into a texture the character shader can march.
    /// Cheap to call every frame — it only re-uploads when the mask object changes.
    func syncClipMask(_ mask: ClipMask?) {
        guard let mask else {
            clipTexture = nil
            clipTextureIdentity = nil
            clipMapSize = SIMD2(0, 0)
            return
        }

        let identity = ObjectIdentifier(mask)
        guard identity != clipTextureIdentity else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: mask.pixelWidth,
                                                                  height: mask.pixelHeight,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }

        mask.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, mask.pixelWidth, mask.pixelHeight),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: mask.pixelWidth * 4)
        }

        clipTexture = texture
        clipTextureIdentity = identity
        clipMapSize = SIMD2(Float(mask.worldWidth), Float(mask.worldHeight))
        Log.render("Clip mask uploaded to GPU: \(mask.pixelWidth)×\(mask.pixelHeight)")
    }

    // MARK: - Drawing

    /// Draws one character. `encoder` must already have the character pipeline bound.
    ///
    /// - Parameter includeProps: `false` for the shadow pass. Emote props are added to the rig
    ///   after `ensureThreeSetup`'s `castShadow` traverse has already run (`characters.js:970`),
    ///   so in the JS they never cast — the held model does, because `loadHoldingModel` sets
    ///   `castShadow` on its own clone. It doubles as the flag for "this is the shadow pass".
    ///
    /// **A character is one bought model and nothing else now.** This used to be a ladder of
    /// three: the imported body if there was one, else the skinned procedural body, else twenty
    /// rigid parts drawn one at a time — and then a head GLB and a shoe GLB on top of whichever
    /// of the two procedural ones drew. The bought model is the whole body, head, hair and shoes
    /// included, so all of that went with it. What is left is the body, whatever it is holding,
    /// and its emote props.
    ///
    /// The one thing worth knowing: `drawImportedBody` returns `false` for the frames before the
    /// model is resident, and there is no longer anything behind it. A character is **invisible**
    /// for those frames rather than briefly procedural. It is a few frames on a background load
    /// and the shadow blob still draws, so a character fades up rather than pops in.
    func draw(pose: RigPose,
              viewProjection: Float4x4,
              encoder: MTLRenderCommandEncoder,
              includeProps: Bool = true) {
        encoder.setFragmentTexture(clipTexture ?? whiteTexture, index: 1)

        let shadowPass = !includeProps

        _ = drawImportedBody(pose: pose, viewProjection: viewProjection,
                             encoder: encoder, shadowPass: shadowPass)

        drawHolding(pose: pose, viewProjection: viewProjection, encoder: encoder)

        if includeProps {
            drawProps(pose: pose, transparent: false, viewProjection: viewProjection, encoder: encoder)
        }
    }

    /// **Call once at the top of each frame**, before anything is encoded.
    ///
    /// All it does is size the joint ring: it remembers the busiest frame so far and keeps room
    /// for `framesInFlight` of those, so the cursor cannot lap a frame the GPU has not finished.
    /// It deliberately does *not* reset the cursor — the cursor running on across frames is what
    /// keeps a slice out of reach until several frames have gone by.
    func beginFrame() {
        jointBytesBusiestFrame = max(jointBytesBusiestFrame, jointBytesThisFrame)
        jointBytesThisFrame = 0

        let wanted = max(Self.jointRingMinimum, jointBytesBusiestFrame * Self.framesInFlight)
        if (jointRing?.length ?? 0) < wanted {
            jointRing = device.makeBuffer(length: wanted, options: .storageModeShared)
            jointCursor = 0
        }
    }

    /// A slice of the ring for one character's joint matrices, or `nil` if it will not fit.
    ///
    /// Offsets are 256-byte aligned because the shader takes the matrices in the `constant`
    /// address space, and that is the alignment Metal requires for a constant buffer offset on
    /// the Macs this also builds for.
    private func takeJointSlice(byteLength: Int) -> (MTLBuffer, Int)? {
        let stride = (byteLength + 255) & ~255
        if jointRing == nil { beginFrame() }
        guard let ring = jointRing, stride <= ring.length else { return nil }
        if jointCursor + stride > ring.length { jointCursor = 0 }
        let offset = jointCursor
        jointCursor += stride
        jointBytesThisFrame += stride
        return (ring, offset)
    }

    /// Draws a bought, rigged character, and returns `false` if
    /// there is none set, it has not finished loading, or it failed.
    ///
    /// The pose it is handed is **the pose the rig has always produced** — `CharacterRig` has
    /// no idea any of this exists. `HumanoidRetargeter.solve` is the whole difference: it turns
    /// the rig's per-`RigPart` transforms into one skinning matrix per joint of somebody else's
    /// skeleton, keeping that skeleton's own proportions. See `HumanoidRig.swift`.
    private func drawImportedBody(pose: RigPose,
                                  viewProjection: Float4x4,
                                  encoder: MTLRenderCommandEncoder,
                                  shadowPass: Bool) -> Bool {
        guard let pipelines else { return false }
        let path = pose.model

        guard let body = importedBodies.body(path) else {
            // Not resident yet. Ask again — `request` is cheap once it is loading — and draw
            // nothing this frame. There is no procedural body behind this any more, so the
            // character is its shadow blob until the model lands.
            importedBodies.request(path: path, profile: profile(for: path))
            return false
        }

        let retargeter = retargeters[path] ?? {
            let made = HumanoidRetargeter(skeleton: body.skeleton)
            retargeters[path] = made
            return made
        }()
        retargeter.solve(pose: pose, into: &importedJoints)

        let byteLength = MemoryLayout<Float4x4>.stride * body.skeleton.jointCount
        guard let (jointBuffer, jointOffset) = takeJointSlice(byteLength: byteLength) else {
            return false
        }
        importedJoints.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            jointBuffer.contents().advanced(by: jointOffset)
                .copyMemory(from: base, byteCount: byteLength)
        }

        // The palette is still bound because the shared vertex function reads it. Slot 0 is the
        // only one anything reads back: `tint` takes its colour and `surfaceParams` the pair
        // after it, and the fragment then multiplies that by the model's own base colour map.
        palette[0] = body.baseColor
        palette[Self.paletteCount] = SIMD4(body.roughness, body.metalness, 0, 0)

        var uniforms = CharacterUniforms(
            modelViewProjection: viewProjection,
            model: matrix_identity_float4x4,
            color: SIMD4(1, 1, 1, 1),
            clipParams: SIMD4(pose.worldPivot.x, pose.worldPivot.y, clipMapSize.x, clipMapSize.y),
            textured: body.baseColorTexture != nil,
            unlit: false,
            material: SurfaceMaterial(roughness: body.roughness, metalness: body.metalness),
            normalTextured: body.normalTexture != nil,
            normalScale: body.normalScale
        )

        encoder.setRenderPipelineState(shadowPass ? pipelines.shadowSkinned : pipelines.skinned)
        encoder.setVertexBuffer(body.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setVertexBuffer(jointBuffer, offset: jointOffset, index: 2)
        if !shadowPass {
            encoder.setVertexBytes(&palette,
                                   length: MemoryLayout<SIMD4<Float>>.stride * Self.paletteCount * 2,
                                   index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
            // The outfit's texture if this character is wearing one and it has landed, and the
            // model's own otherwise — an outfit is one texture swapped on a shared mesh.
            let outfit = importedBodies.outfitTexture(model: path, outfit: pose.outfit)
            encoder.setFragmentTexture(outfit ?? body.baseColorTexture ?? whiteTexture, index: 0)
            encoder.setFragmentTexture(whiteTexture, index: 3)
            encoder.setFragmentTexture(body.normalTexture ?? flatNormalTexture, index: 4)
            // No character model ships a metallic-roughness map — all five declare their
            // factors outright. White leaves them untouched.
            encoder.setFragmentTexture(whiteTexture, index: 5)
        }
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: body.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: body.indexBuffer,
                                      indexBufferOffset: 0)

        encoder.setRenderPipelineState(shadowPass ? pipelines.shadowRigid : pipelines.rigid)
        return true
    }

    /// The skeleton report for every model that has finished loading, for the lab to print.
    /// Ordered by the catalogue so two runs print the same thing in the same order.
    var importedReports: [(path: String, report: String)] {
        let loaded = importedBodies.reports
        let catalogued = CharacterModels.all.map(\.path).filter { loaded[$0] != nil }
        let extras = loaded.keys.filter { !catalogued.contains($0) }.sorted()
        return (catalogued + extras).map { ($0, loaded[$0]!) }
    }

    /// The blended half of the emote props, drawn after the opaque rig so they sort against it
    /// the way three.js's transparent pass does.
    func drawTransparentProps(pose: RigPose,
                              viewProjection: Float4x4,
                              encoder: MTLRenderCommandEncoder) {
        drawProps(pose: pose, transparent: true, viewProjection: viewProjection, encoder: encoder)
    }

    /// Emote props carry the material the JS gave them and, unlike the rig itself, are **not**
    /// clip-mask injected — `injectClipMask` only runs over `buildSkeletonMaterials`, so a
    /// laser beam or a footprint stays visible through a wall.
    private func drawProps(pose: RigPose,
                           transparent: Bool,
                           viewProjection: Float4x4,
                           encoder: MTLRenderCommandEncoder) {
        for prop in pose.props where prop.transparent == transparent {
            guard let mesh = propMeshes[prop.mesh] else { continue }
            let texture = prop.mesh.isSprite ? heartTexture : nil
            drawMesh(mesh, transform: prop.worldTransform,
                     color: SIMD4(prop.color, prop.opacity),
                     texture: texture,
                     unlit: prop.unlit,
                     material: SurfaceMaterial(roughness: prop.roughness, metalness: prop.metalness),
                     pivot: pose.worldPivot,
                     viewProjection: viewProjection, encoder: encoder,
                     masked: false)
        }
    }

    /// The tennis racket. Same GLB the web build loads, placed by `HOLDABLE_OBJECTS`.
    private func drawHolding(pose: RigPose, viewProjection: Float4x4, encoder: MTLRenderCommandEncoder) {
        guard let holding = pose.holding, holding == "tennis_racket" else { return }
        let path = "models/tennis_racquet.glb"

        guard let model = models.model(path) else {
            models.request(path: path, classifier: { _ in .authored })
            return
        }

        for group in model.groups {
            drawMesh(group.mesh, transform: pose.holdingTransform,
                     color: group.baseColor, texture: group.texture, unlit: false,
                     material: SurfaceMaterial(group: group),
                     pivot: pose.worldPivot,
                     viewProjection: viewProjection, encoder: encoder,
                     masked: false, emissiveTexture: group.emissiveTexture,
                     normalTexture: group.normalTexture, normalScale: group.normalScale)
        }
    }

    /// Ground shadows are blended and depth-write-free, so they are drawn in their own pass.
    func drawShadow(pose: RigPose, viewProjection: Float4x4, encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentTexture(clipTexture ?? whiteTexture, index: 1)
        drawMesh(shadowMesh, transform: pose.shadowTransform, color: SIMD4(1, 1, 1, 1),
                 texture: shadowTexture, unlit: true, material: .shirt, pivot: pose.worldPivot,
                 viewProjection: viewProjection, encoder: encoder)
    }

    private func drawMesh(_ mesh: GPUMesh,
                          transform: Float4x4,
                          color: SIMD4<Float>,
                          texture: MTLTexture?,
                          unlit: Bool,
                          material: SurfaceMaterial,
                          pivot: SIMD2<Float>,
                          viewProjection: Float4x4,
                          encoder: MTLRenderCommandEncoder,
                          masked: Bool = true,
                          emissiveTexture: MTLTexture? = nil,
                          normalTexture: MTLTexture? = nil,
                          normalScale: Float = 1) {
        // A zero map size switches the clip-mask raymarch off for this draw.
        let mapSize = masked ? clipMapSize : SIMD2<Float>(0, 0)
        var uniforms = CharacterUniforms(
            modelViewProjection: viewProjection * transform,
            model: transform,
            color: color,
            clipParams: SIMD4(pivot.x, pivot.y, mapSize.x, mapSize.y),
            textured: texture != nil,
            unlit: unlit,
            material: material,
            emissiveTextured: emissiveTexture != nil,
            normalTextured: normalTexture != nil,
            normalScale: normalScale
        )

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture ?? whiteTexture, index: 0)
        encoder.setFragmentTexture(emissiveTexture ?? whiteTexture, index: 3)
        encoder.setFragmentTexture(normalTexture ?? flatNormalTexture, index: 4)
        encoder.setFragmentTexture(whiteTexture, index: 5)
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0)
    }
}
