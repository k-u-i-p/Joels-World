import CoreGraphics
import CoreText
import Metal
import MetalKit
import simd
#if canImport(UIKit)
import UIKit
#endif

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
}

/// The `MeshStandardMaterial` parameters the rig is built from (`characters.js:771-778`).
struct SurfaceMaterial {
    var roughness: Float
    var metalness: Float

    static let skin = SurfaceMaterial(roughness: 0.6, metalness: 0.1)
    static let shirt = SurfaceMaterial(roughness: 0.8, metalness: 0.0)
    static let arm = SurfaceMaterial(roughness: 0.8, metalness: 0.0)
    static let pants = SurfaceMaterial(roughness: 0.9, metalness: 0.0)
    static let shoe = SurfaceMaterial(roughness: 0.7, metalness: 0.2)
    static let hair = SurfaceMaterial(roughness: 0.5, metalness: 0.1)
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
    private var upperArmMesh: GPUMesh!
    private var lowerArmMesh: GPUMesh!
    private var handMesh: GPUMesh!
    private var upperLegMesh: GPUMesh!
    private var lowerLegMesh: GPUMesh!
    private var shoeBoxMesh: GPUMesh!
    private var shadowMesh: GPUMesh!
    private var shadowTexture: MTLTexture?

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

    /// Shared by the prop renderer, which needs the same "no texture here" placeholder.
    var fallbackTexture: MTLTexture { whiteTexture }

    init?(device: MTLDevice, models: ModelStore) {
        self.device = device
        self.models = models
        guard buildMeshes() else { return nil }
    }

    // MARK: - Setup

    private func buildMeshes() -> Bool {
        // Torso: a capsule widened across the shoulders and flattened front-to-back, matching
        // the geometry-space scale at characters.js:792.
        var torso = MeshFactory.capsule(radius: CharacterRig.torsoRadius,
                                        length: CharacterRig.torsoLength,
                                        capSegments: 10, radialSegments: 16)
        MeshFactory.applyScale(&torso, SIMD3(0.65, 1, 1.15))

        let upperArm = MeshFactory.capsule(radius: CharacterRig.upperArmRadius,
                                           length: CharacterRig.upperArmLength,
                                           capSegments: 8, radialSegments: 10)
        let lowerArm = MeshFactory.capsule(radius: CharacterRig.lowerArmRadius,
                                           length: CharacterRig.lowerArmLength,
                                           capSegments: 8, radialSegments: 10)
        let hand = MeshFactory.sphere(radius: CharacterRig.handRadius,
                                      widthSegments: 12, heightSegments: 12)

        // Thighs stay uniform; calves taper to 60% at the ankle (characters.js:872-874).
        var upperLeg = MeshFactory.capsule(radius: CharacterRig.upperLegRadius,
                                           length: CharacterRig.upperLegLength,
                                           capSegments: 8, radialSegments: 10)
        MeshFactory.applyTaper(&upperLeg, topScale: 1.0, bottomScale: 1.0,
                               length: CharacterRig.upperLegLength)

        var lowerLeg = MeshFactory.capsule(radius: CharacterRig.lowerLegRadius,
                                           length: CharacterRig.lowerLegLength,
                                           capSegments: 8, radialSegments: 10)
        MeshFactory.applyTaper(&lowerLeg, topScale: 1.0, bottomScale: 0.6,
                               length: CharacterRig.lowerLegLength)

        guard let torsoMesh = GPUMesh(device: device, mesh: torso),
              let upperArmMesh = GPUMesh(device: device, mesh: upperArm),
              let lowerArmMesh = GPUMesh(device: device, mesh: lowerArm),
              let handMesh = GPUMesh(device: device, mesh: hand),
              let upperLegMesh = GPUMesh(device: device, mesh: upperLeg),
              let lowerLegMesh = GPUMesh(device: device, mesh: lowerLeg),
              let shoeBoxMesh = GPUMesh(device: device, mesh: MeshFactory.box(width: 11, height: 8, depth: 5)),
              let shadowMesh = GPUMesh(device: device, mesh: MeshFactory.plane(width: 28, height: 28))
        else {
            Log.render("Failed to build character meshes")
            return false
        }

        self.torsoMesh = torsoMesh
        self.upperArmMesh = upperArmMesh
        self.lowerArmMesh = lowerArmMesh
        self.handMesh = handMesh
        self.upperLegMesh = upperLegMesh
        self.lowerLegMesh = lowerLegMesh
        self.shoeBoxMesh = shoeBoxMesh
        self.shadowMesh = shadowMesh

        shadowTexture = Self.makeShadowTexture(device: device)
        whiteTexture = Self.makeWhiteTexture(device: device)
        buildPropMeshes()
        heartTexture = Self.makeHeartTexture(device: device)
        return whiteTexture != nil
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

    /// `emotes.js:675-682` paints ❤️ at 100 px into a 128² canvas and uses it as a sprite map.
    private static func makeHeartTexture(device: MTLDevice) -> MTLTexture? {
        guard let cgImage = makeHeartImage(size: CGSize(width: 128, height: 128)) else { return nil }
        return try? MTKTextureLoader(device: device).newTexture(
            cgImage: cgImage,
            options: [.SRGB: true, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)])
    }

#if canImport(UIKit)
    private static func makeHeartImage(size: CGSize) -> CGImage? {
        // On a simulator runtime with no usable emoji font the glyph comes out as a black box,
        // which makes `love` spawn four black squares. Fall back to the bundled artwork.
        if !EmojiImage.systemCanRenderEmoji,
           let fallback = EmojiImage.fallbackImage("❤️", pointSize: 100) {
            let composed = UIGraphicsImageRenderer(size: size).image { _ in
                fallback.draw(in: CGRect(x: 14, y: 14, width: 100, height: 100))
            }
            if let cgImage = composed.cgImage { return cgImage }
        }

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 100),
                .paragraphStyle: paragraph,
            ]
            let text = "❤️" as NSString
            let bounds = text.boundingRect(with: size,
                                           options: .usesLineFragmentOrigin,
                                           attributes: attributes,
                                           context: nil)
            // `textBaseline = 'middle'` centres the glyph box on the canvas centre.
            text.draw(in: CGRect(x: 0, y: (size.height - bounds.height) / 2,
                                 width: size.width, height: bounds.height),
                      withAttributes: attributes)
        }
        return image.cgImage
    }
#else
    /// macOS has no `UIGraphicsImageRenderer` and no missing-emoji problem, so the glyph goes
    /// straight through Core Text. Same 100 pt ❤️ centred in the same 128² canvas.
    private static func makeHeartImage(size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        let font = CTFontCreateUIFontForLanguage(.system, 100, nil)
            ?? CTFontCreateWithName("AppleColorEmoji" as CFString, 100, nil)
        let attributed = NSAttributedString(string: "❤️",
                                            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        ctx.textPosition = CGPoint(x: (size.width - bounds.width) / 2 - bounds.minX,
                                   y: (size.height - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
#endif

    /// The soft ground blob: a flat 25%-black disc, exactly as `buildShadowBlob` paints it.
    private static func makeShadowTexture(device: MTLDevice) -> MTLTexture? {
        let size = 30
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.25)
            ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: 28, height: 28))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return texture
    }

    private static func makeWhiteTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var white: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &white, bytesPerRow: 4)
        return texture
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
    ///   `castShadow` on its own clone.
    func draw(pose: RigPose,
              viewProjection: Float4x4,
              encoder: MTLRenderCommandEncoder,
              includeProps: Bool = true) {
        encoder.setFragmentTexture(clipTexture ?? whiteTexture, index: 1)

        for (part, transform) in pose.parts {
            guard let mesh = mesh(for: part) else { continue }
            drawMesh(mesh, transform: transform, color: SIMD4(color(for: part, colors: pose.colors), 1),
                     texture: nil, unlit: false, material: material(for: part),
                     pivot: pose.worldPivot,
                     viewProjection: viewProjection, encoder: encoder)
        }

        drawHead(pose: pose, viewProjection: viewProjection, encoder: encoder)
        drawShoes(pose: pose, viewProjection: viewProjection, encoder: encoder)
        drawHolding(pose: pose, viewProjection: viewProjection, encoder: encoder)

        if includeProps {
            drawProps(pose: pose, transparent: false, viewProjection: viewProjection, encoder: encoder)
        }
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
                     material: SurfaceMaterial(roughness: group.roughness, metalness: group.metalness),
                     pivot: pose.worldPivot,
                     viewProjection: viewProjection, encoder: encoder,
                     masked: false)
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
                material = SurfaceMaterial(roughness: group.roughness, metalness: group.metalness)
            }
            drawMesh(group.mesh, transform: pose.headTransform, color: color,
                     texture: group.texture, unlit: false, material: material,
                     pivot: pose.worldPivot,
                     viewProjection: viewProjection, encoder: encoder)
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
                          masked: Bool = true) {
        // A zero map size switches the clip-mask raymarch off for this draw.
        let mapSize = masked ? clipMapSize : SIMD2<Float>(0, 0)
        var uniforms = CharacterUniforms(
            modelViewProjection: viewProjection * transform,
            model: transform,
            color: color,
            clipParams: SIMD4(pivot.x, pivot.y, mapSize.x, mapSize.y),
            flags: SIMD4(texture != nil ? 1 : 0, unlit ? 1 : 0,
                         material.roughness, material.metalness)
        )

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture ?? whiteTexture, index: 0)
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
        case .leftUpperArm, .rightUpperArm: return upperArmMesh
        case .leftLowerArm, .rightLowerArm: return lowerArmMesh
        case .leftHand, .rightHand: return handMesh
        case .leftUpperLeg, .rightUpperLeg: return upperLegMesh
        case .leftLowerLeg, .rightLowerLeg: return lowerLegMesh
        }
    }

    private func color(for part: RigPart, colors: RigColors) -> SIMD3<Float> {
        switch part {
        case .torso: return colors.shirt
        case .leftUpperArm, .leftLowerArm, .rightUpperArm, .rightLowerArm: return colors.arm
        case .leftHand, .rightHand: return colors.skin
        case .leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg: return colors.pants
        }
    }

    private func material(for part: RigPart) -> SurfaceMaterial {
        switch part {
        case .torso: return .shirt
        case .leftUpperArm, .leftLowerArm, .rightUpperArm, .rightLowerArm: return .arm
        case .leftHand, .rightHand: return .skin
        case .leftUpperLeg, .leftLowerLeg, .rightUpperLeg, .rightLowerLeg: return .pants
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
