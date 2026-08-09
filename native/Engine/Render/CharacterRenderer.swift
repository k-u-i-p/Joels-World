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
    /// x = transmission, y = the clothing atlas is bound at texture 0 and `uv` addresses it
    /// (the skinned body, and nothing else), zw unused.
    var surface: SIMD4<Float>
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
    /// Collars, cuffs and socks. No vertex carries this one — the clothing atlas picks it per
    /// texel and the fragment shader mixes towards it, colour and material together.
    static let trim = SurfaceMaterial(roughness: 0.85, metalness: 0.0)

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
         clothed: Bool = false) {
        let extensions = material.extensions
        self.init(modelViewProjection: modelViewProjection,
                  model: model,
                  color: color,
                  clipParams: clipParams,
                  flags: SIMD4(textured ? 1 : 0, unlit ? 1 : 0,
                               material.roughness, material.metalness),
                  emissive: SIMD4(extensions.emissive, emissiveTextured ? 1 : 0),
                  specular: SIMD4(extensions.specularF0, extensions.specularIntensity),
                  surface: SIMD4(extensions.transmission, clothed ? 1 : 0, 0, 0))
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

/// Draws the procedural character rig: the shared primitive meshes, the glTF head and shoe
/// models, and the ground shadow blob.
///
/// Port of the render half of `characters.js`. The pose itself comes from `CharacterRig`,
/// which holds no Metal types.
final class CharacterRenderer {
    private let device: MTLDevice
    private let models: ModelStore

    // Shared primitive geometry — built once, drawn for every character.
    private var torsoMesh: GPUMesh!
    private var pelvisMesh: GPUMesh!
    private var neckMesh: GPUMesh!
    private var shoulderMesh: GPUMesh!
    private var upperArmMesh: GPUMesh!
    private var lowerArmMesh: GPUMesh!
    private var elbowMesh: GPUMesh!
    private var leftHandMesh: GPUMesh!
    private var rightHandMesh: GPUMesh!
    private var upperLegMesh: GPUMesh!
    private var lowerLegMesh: GPUMesh!
    private var kneeMesh: GPUMesh!
    private var shoeBoxMesh: GPUMesh!
    private var shadowMesh: GPUMesh!
    private var shadowTexture: MTLTexture?

    /// The body as one skinned mesh — see `SkinnedBody`. When it is present the primitive parts
    /// above are only used for the emote props and the shoe stand-in; when it is `nil` the rig
    /// falls back to drawing them one at a time, which is what the game did before.
    private var skinnedBody: GPUSkinMesh?
    /// The collars, buttons, cuffs and socks — see `ClothingAtlas`. One texture for every
    /// character, because it says what to *do* to a colour rather than what colour to be.
    private var clothingTexture: MTLTexture?
    /// Pipelines for the skinned body. Owned by `Renderer`, which builds them, and handed over
    /// here because the body has to be drawn with a different vertex function from the head,
    /// the shoes and the props it is drawn among.
    var pipelines: CharacterPipelines?

    /// Scratch for the per-character uniform blocks, so posing a crowd allocates nothing.
    private var jointMatrices = [Float4x4](repeating: matrix_identity_float4x4,
                                           count: SkinnedBody.boneCount)
    private var palette = [SIMD4<Float>](repeating: .zero, count: SkinnedBody.paletteCount * 2)

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

    // MARK: - Imported characters

    /// Bought, rigged models, keyed by asset path.
    private let importedBodies: ImportedCharacterStore
    /// One retargeter per model. `solve` is called once per character per pass and holds no
    /// per-character state between calls, so a model needs only one.
    private var retargeters: [String: HumanoidRetargeter] = [:]
    /// Scratch for the imported skeleton's joint matrices, and the buffer they are uploaded in.
    /// A bought rig has too many bones for `setVertexBytes`' 4 KB — see `ImportedCharacterBody`.
    private var importedJoints: [Float4x4] = []
    private var importedJointBuffer: MTLBuffer?

    /// The model every character is drawn with, or nil for the procedural body.
    ///
    /// Set it and the rig, the gaits, the IK and every minigame carry on untouched — that is the
    /// whole point of `HumanoidRig`. `JW_CHARACTER_MODEL` sets it without a rebuild, which is how
    /// the character lab switches between the two.
    var importedModelPath: String? {
        didSet { if importedModelPath != oldValue { retargeters.removeAll() } }
    }
    /// Per-model profile, read from a `.rig.json` beside the model if it has one.
    var importedProfile: HumanoidProfile = .standard

    /// Shared by the prop renderer, which needs the same "no texture here" placeholder.
    var fallbackTexture: MTLTexture { whiteTexture }

    init?(device: MTLDevice, models: ModelStore) {
        self.device = device
        self.models = models
        self.importedBodies = ImportedCharacterStore(device: device)
        guard buildMeshes() else { return nil }

        if let path = ProcessInfo.processInfo.environment["JW_CHARACTER_MODEL"], !path.isEmpty {
            importedModelPath = path
            importedProfile = Self.profile(besideModel: path)
        }
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

    /// Every limb is generated with +Y running from its **start** joint to its **end** joint,
    /// because that is the axis `IKSolver.segmentTransform` maps onto the bone. So for an upper
    /// arm, `radiusStart` is the shoulder and `radiusEnd` the elbow; for a calf, `radiusStart` is
    /// the knee and `radiusEnd` the ankle.
    ///
    /// That is worth spelling out because the old calf had it backwards — it was tapered to 60%
    /// at the *knee* and left full width at the ankle, which is a leg on upside down. It is the
    /// one place here that deliberately departs from `characters.js`.
    private func buildMeshes() -> Bool {
        // Torso and pelvis are hand-authored silhouettes rather than squashed capsules: a
        // capsule cannot have a shoulder line and a waist, and without those a character is a
        // pill with a beautifully modelled head on top.
        let torso = MeshFactory.revolvedElliptical(profile: CharacterRig.torsoProfile,
                                                   radialSegments: 28)

        var pelvis = MeshFactory.revolved(profile: CharacterRig.pelvisProfile, radialSegments: 24)
        MeshFactory.applyScale(&pelvis, CharacterRig.pelvisSquash)

        let neck = MeshFactory.cylinder(radiusTop: CharacterRig.neckRadiusTop,
                                        radiusBottom: CharacterRig.neckRadiusBottom,
                                        height: CharacterRig.neckLength,
                                        radialSegments: 16)

        // Deltoid: a sphere stretched along the humerus, which the pose turns to follow it.
        var shoulder = MeshFactory.sphere(radius: CharacterRig.shoulderRadius,
                                          widthSegments: 14, heightSegments: 12)
        MeshFactory.applyScale(&shoulder, CharacterRig.shoulderStretch)

        // Arms thicken towards the body and thin towards the wrist, as arms do. Both segments
        // use `elbowEndScale` where they meet, so the taper runs continuously through the joint.
        //
        // The wrist is the only end of any limb that nothing else covers, so it is the only one
        // closed flush rather than domed past its joint — see `MeshFactory.limb`. Everywhere
        // else the overshoot is what makes the joint blend.
        let upperArm = MeshFactory.limb(length: CharacterRig.upperArmLength,
                                        radiusStart: CharacterRig.upperArmRadius * CharacterRig.shoulderEndScale,
                                        radiusEnd: CharacterRig.upperArmRadius * CharacterRig.elbowEndScale)

        let lowerArm = MeshFactory.limb(length: CharacterRig.lowerArmLength,
                                        radiusStart: CharacterRig.lowerArmRadius * CharacterRig.elbowEndScale,
                                        radiusEnd: CharacterRig.lowerArmRadius * CharacterRig.wristEndScale,
                                        domeEnd: false)

        let elbow = MeshFactory.sphere(radius: CharacterRig.elbowRadius,
                                       widthSegments: 12, heightSegments: 10)

        // A hand with a thumb, assembled from four ellipsoids and merged into one mesh. See
        // `CharacterRig.Hand` for the frame and for why this could not be done until the forearm
        // had a basis instead of a direction.
        let rightHand = Self.buildHand()
        // The left is the right, mirrored — including the winding, or it renders inside-out.
        let leftHand = MeshFactory.mirroredInX(rightHand)

        // Thighs are heaviest at the hip; calves are heaviest at the knee and narrow into the
        // ankle, where the shoe takes over.
        let upperLeg = MeshFactory.limb(length: CharacterRig.upperLegLength,
                                        radiusStart: CharacterRig.upperLegRadius * CharacterRig.hipEndScale,
                                        radiusEnd: CharacterRig.upperLegRadius * CharacterRig.kneeEndScale)

        // The ankle end is domed past the joint on purpose: the shoe model swallows it.
        let lowerLeg = MeshFactory.limb(length: CharacterRig.lowerLegLength,
                                        radiusStart: CharacterRig.lowerLegRadius * CharacterRig.kneeEndScale,
                                        radiusEnd: CharacterRig.lowerLegRadius * CharacterRig.ankleEndScale)

        let knee = MeshFactory.sphere(radius: CharacterRig.kneeRadius,
                                      widthSegments: 12, heightSegments: 10)

        guard let torsoMesh = GPUMesh(device: device, mesh: torso),
              let pelvisMesh = GPUMesh(device: device, mesh: pelvis),
              let neckMesh = GPUMesh(device: device, mesh: neck),
              let shoulderMesh = GPUMesh(device: device, mesh: shoulder),
              let upperArmMesh = GPUMesh(device: device, mesh: upperArm),
              let lowerArmMesh = GPUMesh(device: device, mesh: lowerArm),
              let elbowMesh = GPUMesh(device: device, mesh: elbow),
              let leftHandMesh = GPUMesh(device: device, mesh: leftHand),
              let rightHandMesh = GPUMesh(device: device, mesh: rightHand),
              let upperLegMesh = GPUMesh(device: device, mesh: upperLeg),
              let lowerLegMesh = GPUMesh(device: device, mesh: lowerLeg),
              let kneeMesh = GPUMesh(device: device, mesh: knee),
              let shoeBoxMesh = GPUMesh(device: device, mesh: MeshFactory.box(width: 11, height: 8, depth: 5)),
              let shadowMesh = GPUMesh(device: device, mesh: MeshFactory.plane(width: 28, height: 28))
        else {
            Log.render("Failed to build character meshes")
            return false
        }

        self.torsoMesh = torsoMesh
        self.pelvisMesh = pelvisMesh
        self.neckMesh = neckMesh
        self.shoulderMesh = shoulderMesh
        self.upperArmMesh = upperArmMesh
        self.lowerArmMesh = lowerArmMesh
        self.elbowMesh = elbowMesh
        self.leftHandMesh = leftHandMesh
        self.rightHandMesh = rightHandMesh
        self.upperLegMesh = upperLegMesh
        self.lowerLegMesh = lowerLegMesh
        self.kneeMesh = kneeMesh
        self.shoeBoxMesh = shoeBoxMesh
        self.shadowMesh = shadowMesh

        // The skinned body, built from the same anatomy the parts above are. If it fails to
        // build the rig still draws — as twenty separate solids with balls for joints, which is
        // what it was — so this is a `Log` and not a `return false`.
        let (skin, inverseBind) = SkinnedBody.build()
        skinnedBody = GPUSkinMesh(device: device, mesh: skin, inverseBind: inverseBind)
        if skinnedBody == nil {
            Log.render("Failed to build the skinned body — falling back to the rigid rig")
        } else {
            Log.render("Skinned body: \(skin.vertices.count) vertices, \(skin.indices.count / 3) triangles")
        }

        clothingTexture = ClothingAtlas.make(device: device)
        if clothingTexture == nil {
            Log.render("Failed to build the clothing atlas — the body falls back to flat colours")
        }

        shadowTexture = ProceduralTextures.makeShadowTexture(device: device)
        whiteTexture = ProceduralTextures.makeWhiteTexture(device: device)
        buildPropMeshes()
        heartTexture = ProceduralTextures.makeHeartTexture(device: device)
        return whiteTexture != nil
    }

    /// **The right hand**: a lofted palm, four tapered fingers rooted inside it, and a thumb.
    ///
    /// It was three ellipsoids and a capsule merged, which read as a bunch of bananas: three
    /// closed surfaces pushed into each other, creasing wherever they crossed, and none of them
    /// the shape of any part of a hand. The attempt after that made the whole hand one loft with
    /// the fingers pressed into it as grooves, and the shape that came out was a **flipper** — a
    /// ring tapering to nothing at the far end is a paddle whatever is grooved into it.
    ///
    /// So: a palm that is a loft, because a palm is one smooth flattened form and a lathe cannot
    /// make one; and fingers that are separate solids, because four rounded tips at four
    /// different heights is what a hand's silhouette *is*. Intersecting surfaces are not the
    /// problem they were — a finger really does emerge from a palm and really does crease where
    /// it does, and every root here is buried a unit and a half inside, so no crease lands
    /// anywhere but at a knuckle.
    ///
    /// **The UVs are anatomical and they are kept.** `u` folds about the back: 0 down the middle
    /// of the back of the hand, 0.5 at either edge, 1 down the middle of the palm — the same
    /// fold the torso uses, and for the same reason (see `ClothingAtlas.uv`). Each finger folds
    /// about its own centre line, so the underside of every finger is the shaded side. `v` runs
    /// 0 at the buried wrist ring to 1 at `fingerReach`. `SkinnedBody` reads them straight
    /// through: an angle round a ring is known where the ring is made and nowhere afterwards.
    static func buildHand() -> MeshData {
        let hand = CharacterRig.Hand.self
        let profile = hand.palmProfile
        let firstY = profile.first?.y ?? 0
        let span = max(hand.fingerReach - firstY, 1e-4)

        /// Where a point in the hand's own space lands in the atlas. `centre` is the axis the
        /// fold is taken about — the palm's is the middle of the hand, a finger's is its own.
        func place(_ position: SIMD3<Float>, foldedAbout centre: Float) -> SIMD2<Float> {
            // Measured from +X, the back of the hand, and folded so both edges arrive at 0.5.
            var fromBack = abs(atan2(position.z - centre, position.x))
            if fromBack > .pi { fromBack = 2 * .pi - fromBack }
            return SIMD2(fromBack / .pi, min(max((position.y - firstY) / span, 0), 1))
        }

        var rings: [[MeshVertex]] = []
        for ring in profile {
            var points: [MeshVertex] = []
            for segment in 0..<hand.radialSegments {
                // The same winding `lathe` uses — angle 0 at +Z, turning towards +X — so a
                // lofted part and a revolved one can share a mesh without one being inside-out.
                let angle = Float(segment) / Float(hand.radialSegments) * 2 * .pi
                let position = SIMD3(ring.through * sin(angle), ring.y, ring.across * cos(angle))
                points.append(MeshVertex(position: position, normal: .zero,
                                         uv: place(position, foldedAbout: 0)))
            }
            rings.append(points)
        }
        // No end caps: the first and last rings of the profile have no radius at all, so both
        // ends are closed already.
        var parts = [MeshFactory.loft(rings: rings)]

        // The fingers. Each is curled towards the palm and fanned out from the middle of the
        // hand, in that order — the curl is about +Z and the fan about +X, and doing the fan
        // first would carry the curl out of the plane it is meant to be in.
        for finger in hand.fingers {
            let curl = hand.fingerCurl
            let spread = finger.across * hand.fingerSpread
            var mesh = MeshFactory.limb(length: finger.length,
                                        radiusStart: finger.radius,
                                        radiusEnd: finger.radius * hand.fingerTaper,
                                        radialSegments: hand.fingerSegments, capSegments: 4)
            MeshFactory.applyRotation(&mesh, .rotationZ(curl))
            MeshFactory.applyRotation(&mesh, .rotationX(spread))
            let axis = SIMD3<Float>(-sin(curl), cos(curl) * cos(spread), cos(curl) * sin(spread))
            let root = SIMD3<Float>(0, finger.root, finger.across)
            mesh = MeshFactory.translated(mesh, by: root + axis * (finger.length / 2))
            // `limb` writes a lathe's own parameterisation, which means nothing here. A finger
            // folds about its own centre line, so its underside reads as its underside.
            for index in mesh.vertices.indices {
                mesh.vertices[index].uv = place(mesh.vertices[index].position,
                                                foldedAbout: finger.across)
            }
            parts.append(mesh)
        }

        // The thumb: tapered, domed both ends, swung out of the palm's plane and then forward.
        // Same order, and the same reason.
        var thumb = MeshFactory.limb(length: hand.thumbLength,
                                     radiusStart: hand.thumbRadiusRoot,
                                     radiusEnd: hand.thumbRadiusTip,
                                     radialSegments: 12, capSegments: 5)
        MeshFactory.applyRotation(&thumb, .rotationZ(hand.thumbForward))
        MeshFactory.applyRotation(&thumb, .rotationX(hand.thumbSplay))
        // `limb` is centred on its own middle, so it is pushed half its length along the axis
        // those two rotations left it pointing down, or it starts through the palm rather than
        // at the root.
        let thumbAxis = SIMD3<Float>(-sin(hand.thumbForward),
                                     cos(hand.thumbForward) * cos(hand.thumbSplay),
                                     cos(hand.thumbForward) * sin(hand.thumbSplay))
        thumb = MeshFactory.translated(thumb, by: hand.thumbRoot + thumbAxis * (hand.thumbLength / 2))
        for index in thumb.vertices.indices {
            thumb.vertices[index].uv = place(thumb.vertices[index].position,
                                             foldedAbout: hand.thumbRoot.z)
        }
        parts.append(thumb)

        return MeshFactory.merge(parts)
    }

    /// Every geometry the emote table instantiates, with the constructor arguments and the
    /// geometry-space rotations `emotes.js` bakes in before instancing.
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
            .rugbyBall: scaled(MeshFactory.sphere(radius: 3.5, widthSegments: 12, heightSegments: 12),
                               SIMD3(1.5, 1, 1)),
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
    ///   `castShadow` on its own clone. It doubles as the flag for "this is the shadow pass",
    ///   which is also where the joint fillers are dropped: they sit inside the silhouette the
    ///   limbs already cast, and the shadow pass is the one that draws every character twice.
    func draw(pose: RigPose,
              viewProjection: Float4x4,
              encoder: MTLRenderCommandEncoder,
              includeProps: Bool = true) {
        encoder.setFragmentTexture(clipTexture ?? whiteTexture, index: 1)

        let shadowPass = !includeProps

        // An imported character is the whole body — head, hair and shoes included — so when one
        // draws, the three rigid models that dress the procedural rig are skipped with it.
        let importedDrew = drawImportedBody(pose: pose, viewProjection: viewProjection,
                                            encoder: encoder, shadowPass: shadowPass)

        if !importedDrew,
           !drawSkinnedBody(pose: pose, viewProjection: viewProjection,
                            encoder: encoder, shadowPass: shadowPass) {
            for (part, transform) in pose.parts {
                if shadowPass && part.isJointFiller { continue }
                guard let mesh = mesh(for: part) else { continue }
                drawMesh(mesh, transform: transform, color: SIMD4(color(for: part, colors: pose.colors), 1),
                         texture: nil, unlit: false, material: material(for: part),
                         pivot: pose.worldPivot,
                         viewProjection: viewProjection, encoder: encoder)
            }
        }

        if !importedDrew {
            drawHead(pose: pose, viewProjection: viewProjection, encoder: encoder)
            drawShoes(pose: pose, viewProjection: viewProjection, encoder: encoder)
        }
        drawHolding(pose: pose, viewProjection: viewProjection, encoder: encoder)

        if includeProps {
            drawProps(pose: pose, transparent: false, viewProjection: viewProjection, encoder: encoder)
        }
    }

    /// Draws a bought, rigged character in place of the procedural body, and returns `false` if
    /// there is none set, it has not finished loading, or it failed.
    ///
    /// The pose it is handed is **the same pose the procedural body gets** — `CharacterRig` has
    /// no idea any of this exists. `HumanoidRetargeter.solve` is the whole difference: it turns
    /// the rig's per-`RigPart` transforms into one skinning matrix per joint of somebody else's
    /// skeleton, keeping that skeleton's own proportions. See `HumanoidRig.swift`.
    private func drawImportedBody(pose: RigPose,
                                  viewProjection: Float4x4,
                                  encoder: MTLRenderCommandEncoder,
                                  shadowPass: Bool) -> Bool {
        guard let path = importedModelPath, let pipelines else { return false }

        guard let body = importedBodies.body(path) else {
            // Not resident yet. Ask again — `request` is cheap once it is loading — and let the
            // procedural body draw this frame, so a character never blinks out while it loads.
            importedBodies.request(path: path, profile: importedProfile)
            return false
        }

        let retargeter = retargeters[path] ?? {
            let made = HumanoidRetargeter(skeleton: body.skeleton)
            retargeters[path] = made
            return made
        }()
        retargeter.solve(pose: pose, into: &importedJoints)

        let byteLength = MemoryLayout<Float4x4>.stride * body.skeleton.jointCount
        if importedJointBuffer == nil || importedJointBuffer!.length < byteLength {
            importedJointBuffer = device.makeBuffer(length: byteLength, options: .storageModeShared)
        }
        guard let jointBuffer = importedJointBuffer else { return false }
        importedJoints.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            jointBuffer.contents().copyMemory(from: base, byteCount: byteLength)
        }

        // The palette is still bound because the shared vertex function reads it, but nothing
        // downstream uses it: `clothed: false` sends the fragment to its textured branch, where
        // the colour is the model's own map times slot 0.
        palette[0] = body.baseColor
        palette[SkinnedBody.paletteCount] = SIMD4(body.roughness, body.metalness, 0, 0)

        var uniforms = CharacterUniforms(
            modelViewProjection: viewProjection,
            model: matrix_identity_float4x4,
            color: SIMD4(1, 1, 1, 1),
            clipParams: SIMD4(pose.worldPivot.x, pose.worldPivot.y, clipMapSize.x, clipMapSize.y),
            textured: body.baseColorTexture != nil,
            unlit: false,
            material: SurfaceMaterial(roughness: body.roughness, metalness: body.metalness),
            clothed: false
        )

        encoder.setRenderPipelineState(shadowPass ? pipelines.shadowSkinned : pipelines.skinned)
        encoder.setVertexBuffer(body.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setVertexBuffer(jointBuffer, offset: 0, index: 2)
        if !shadowPass {
            encoder.setVertexBytes(&palette,
                                   length: MemoryLayout<SIMD4<Float>>.stride * SkinnedBody.paletteCount * 2,
                                   index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
            encoder.setFragmentTexture(body.baseColorTexture ?? whiteTexture, index: 0)
            encoder.setFragmentTexture(whiteTexture, index: 3)
        }
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: body.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: body.indexBuffer,
                                      indexBufferOffset: 0)

        encoder.setRenderPipelineState(shadowPass ? pipelines.shadowRigid : pipelines.rigid)
        return true
    }

    /// The skeleton report for the model in use, for the lab to print.
    var importedReport: String? {
        guard let path = importedModelPath else { return nil }
        return importedBodies.reports[path]
    }

    /// Draws the body as one skinned mesh, and returns `false` if it could not — either because
    /// the mesh failed to build or because `Renderer` has not handed over the pipelines yet, in
    /// which case the caller falls back to the twenty rigid parts.
    ///
    /// The joint matrix for a bone is **this frame's transform times the inverse of its bind
    /// transform**. `CharacterRig` already produces the first of those for every bone as part of
    /// posing the old rigid rig, so nothing about the walk cycle, the emotes, the IK or a
    /// minigame's override had to change to make this work — the pose is the same, it is only
    /// spent differently.
    ///
    /// Leaves the encoder on the rigid pipeline, because the head, the shoes and the props that
    /// follow are all rigid meshes.
    private func drawSkinnedBody(pose: RigPose,
                                 viewProjection: Float4x4,
                                 encoder: MTLRenderCommandEncoder,
                                 shadowPass: Bool) -> Bool {
        if ProcessInfo.processInfo.environment["JW_RIGID_RIG"] != nil { return false }
        guard let body = skinnedBody, let pipelines else { return false }

        var filled: UInt32 = 0
        for (part, transform) in pose.parts {
            guard let index = SkinnedBody.boneIndex[part] else { continue }
            jointMatrices[index] = transform * body.inverseBind[index]
            filled |= 1 << UInt32(index)
        }
        // A bone the pose skipped — `segmentTransform` gives up on a limb shorter than 0.1 —
        // rides the pelvis rather than the identity, which would leave that geometry standing at
        // the world origin in the rest pose for everyone to see.
        let fallback = jointMatrices[SkinnedBody.boneIndex[.pelvis] ?? 0]
        for index in 0..<SkinnedBody.boneCount where filled & (1 << UInt32(index)) == 0 {
            jointMatrices[index] = fallback
        }

        palette[0] = SIMD4(pose.colors.skin, 1)
        palette[1] = SIMD4(pose.colors.shirt, 1)
        palette[2] = SIMD4(pose.colors.arm, 1)
        palette[3] = SIMD4(pose.colors.pants, 1)
        // No vertex carries the trim slot; the clothing atlas picks it per texel.
        palette[4] = SIMD4(ClothingAtlas.trimColor, 1)
        // Skin's and trim's entries are read by the *texture*, not by a vertex: `characterFragment`
        // mixes towards them wherever it mixes the colour, so a bare forearm below a short sleeve
        // is lit as skin rather than as the cotton the vertex it belongs to is made of.
        for (offset, material) in [SurfaceMaterial.skin, .shirt, .arm, .pants, .trim].enumerated() {
            palette[SkinnedBody.paletteCount + offset] = SIMD4(material.roughness, material.metalness, 0, 0)
        }

        // The joint matrices already carry the character's position, heading and scale, so the
        // model matrix is the identity and the "model-view-projection" is just the camera.
        var uniforms = CharacterUniforms(
            modelViewProjection: viewProjection,
            model: matrix_identity_float4x4,
            color: SIMD4(1, 1, 1, 1),
            clipParams: SIMD4(pose.worldPivot.x, pose.worldPivot.y, clipMapSize.x, clipMapSize.y),
            textured: false,
            unlit: false,
            material: .shirt,
            clothed: clothingTexture != nil
        )

        encoder.setRenderPipelineState(shadowPass ? pipelines.shadowSkinned : pipelines.skinned)
        encoder.setVertexBuffer(body.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setVertexBytes(&jointMatrices,
                               length: MemoryLayout<Float4x4>.stride * SkinnedBody.boneCount,
                               index: 2)
        if !shadowPass {
            encoder.setVertexBytes(&palette,
                                   length: MemoryLayout<SIMD4<Float>>.stride * SkinnedBody.paletteCount * 2,
                                   index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
            encoder.setFragmentTexture(clothingTexture ?? whiteTexture, index: 0)
            encoder.setFragmentTexture(whiteTexture, index: 3)
        }
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: body.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: body.indexBuffer,
                                      indexBufferOffset: 0)

        encoder.setRenderPipelineState(shadowPass ? pipelines.shadowRigid : pipelines.rigid)
        return true
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
                     masked: false, emissiveTexture: group.emissiveTexture)
        }
    }

    /// Ground shadows are blended and depth-write-free, so they are drawn in their own pass.
    func drawShadow(pose: RigPose, viewProjection: Float4x4, encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentTexture(clipTexture ?? whiteTexture, index: 1)
        drawMesh(shadowMesh, transform: pose.shadowTransform, color: SIMD4(1, 1, 1, 1),
                 texture: shadowTexture, unlit: true, material: .shirt, pivot: pose.worldPivot,
                 viewProjection: viewProjection, encoder: encoder)
    }

    private func drawHead(pose: RigPose, viewProjection: Float4x4, encoder: MTLRenderCommandEncoder) {
        guard let headName = pose.headModel else { return }
        let path = "models/heads/\(headName).glb"

        guard let model = models.model(path) else {
            models.request(path: path, classifier: Self.headSlot)
            return
        }

        for group in model.groups {
            let color: SIMD4<Float>
            let material: SurfaceMaterial
            switch group.slot {
            case .hair: color = SIMD4(pose.colors.hair, 1); material = .hair
            case .skin: color = SIMD4(pose.colors.skin, 1); material = .skin
            case .shoe: color = SIMD4(pose.colors.shoe, 1); material = .shoe
            case .authored:
                color = group.baseColor
                material = SurfaceMaterial(group: group)
            }
            drawMesh(group.mesh, transform: pose.headTransform, color: color,
                     texture: group.texture, unlit: false, material: material,
                     pivot: pose.worldPivot,
                     viewProjection: viewProjection, encoder: encoder,
                     emissiveTexture: group.emissiveTexture)
        }
    }

    private func drawShoes(pose: RigPose, viewProjection: Float4x4, encoder: MTLRenderCommandEncoder) {
        let path = "models/slip_on_shoes.glb"
        let color = SIMD4(pose.colors.shoe, 1)

        guard let model = models.model(path) else {
            // Box stand-ins until the model arrives, matching the JS fallback rig.
            models.request(path: path, classifier: { _ in .shoe })
            for transform in [pose.leftShoeBox, pose.rightShoeBox] {
                drawMesh(shoeBoxMesh, transform: transform, color: color, texture: nil,
                         unlit: false, material: .shoe, pivot: pose.worldPivot,
                         viewProjection: viewProjection, encoder: encoder)
            }
            return
        }

        for transform in [pose.leftShoeModel, pose.rightShoeModel] {
            for group in model.groups {
                drawMesh(group.mesh, transform: transform, color: color, texture: nil,
                         unlit: false, material: .shoe, pivot: pose.worldPivot,
                         viewProjection: viewProjection, encoder: encoder)
            }
        }
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
                          emissiveTexture: MTLTexture? = nil) {
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
            emissiveTextured: emissiveTexture != nil
        )

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture ?? whiteTexture, index: 0)
        encoder.setFragmentTexture(emissiveTexture ?? whiteTexture, index: 3)
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0)
    }

    // MARK: - Part tables

    private func mesh(for part: RigPart) -> GPUMesh? {
        switch part {
        case .torso: return torsoMesh
        case .pelvis: return pelvisMesh
        case .neck: return neckMesh
        case .leftShoulder, .rightShoulder: return shoulderMesh
        case .leftUpperArm, .rightUpperArm: return upperArmMesh
        case .leftLowerArm, .rightLowerArm: return lowerArmMesh
        case .leftElbow, .rightElbow: return elbowMesh
        case .leftHand: return leftHandMesh
        case .rightHand: return rightHandMesh
        case .leftUpperLeg, .rightUpperLeg: return upperLegMesh
        case .leftLowerLeg, .rightLowerLeg: return lowerLegMesh
        case .leftKnee, .rightKnee: return kneeMesh
        }
    }

    /// A joint takes the colour of whatever it is a joint *in*: a deltoid belongs to the sleeve,
    /// a knee to the trouser leg. The neck is the one that belongs to neither — it is skin, and
    /// it is what carries the head colour down onto the body.
    private func color(for part: RigPart, colors: RigColors) -> SIMD3<Float> {
        switch part {
        case .torso: return colors.shirt
        case .pelvis: return colors.pants
        case .neck: return colors.skin
        case .leftShoulder, .rightShoulder,
             .leftUpperArm, .leftLowerArm, .rightUpperArm, .rightLowerArm,
             .leftElbow, .rightElbow:
            return colors.arm
        case .leftHand, .rightHand: return colors.skin
        case .leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg,
             .leftKnee, .rightKnee:
            return colors.pants
        }
    }

    private func material(for part: RigPart) -> SurfaceMaterial {
        switch part {
        case .torso: return .shirt
        case .pelvis: return .pants
        case .neck: return .skin
        case .leftShoulder, .rightShoulder,
             .leftUpperArm, .leftLowerArm, .rightUpperArm, .rightLowerArm,
             .leftElbow, .rightElbow:
            return .arm
        case .leftHand, .rightHand: return .skin
        case .leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg,
             .leftKnee, .rightKnee:
            return .pants
        }
    }

    /// Name-based material assignment for head GLBs (`characters.js:189-206`): eyes and
    /// eyelashes keep what the artist authored, hair takes the hair colour, and the face
    /// takes the skin colour.
    static func headSlot(_ primitive: GLTFPrimitive) -> MaterialSlot {
        let material = primitive.materialName
        if material.contains("eye") || material.contains("animetest") { return .authored }

        let name = primitive.nodeName
        if name.contains("hair") { return .hair }
        if name.contains("face") || name.contains("head") || name.contains("skin") { return .skin }
        return .authored
    }
}
