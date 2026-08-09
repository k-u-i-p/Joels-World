import Metal
import MetalKit
import simd

/// CPU-side mirror of the shader uniform struct. Layout must stay in step with `Shaders.metal`.
private struct DrawUniforms {
    var modelViewProjection: Float4x4
    var model: Float4x4
    var tint: SIMD4<Float>
    /// x = lit (ground) vs unlit (overlay).
    var flags: SIMD4<Float>
}

private struct QuadVertex {
    var position: SIMD3<Float>
    var uv: SIMD2<Float>
}

/// Forward renderer with the three.js pass order reproduced:
///
/// 1. **Shadow** — characters and props into the spotlight's 1024² depth map.
/// 2. **Scene** — ground tiles, props, characters, overlays into an offscreen colour buffer,
///    alongside a view-space normal buffer and a readable depth buffer.
/// 3. **SSAO** and **blur** — `SSAOPass` + `SSAOBlurShader`.
/// 4. **Composite** — beauty × ambient occlusion, resolved to the drawable.
///
/// Everything after step 1 runs in **linear** colour: the tile and glTF textures decode from
/// sRGB on sample, hex colours are linearised on parse, and the `_srgb` render targets encode
/// on write. That is exactly the chain three.js sets up with `SRGBColorSpace` textures and an
/// `OutputPass`, and it is what makes the lighting maths transferable.
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    private var quadPipeline: MTLRenderPipelineState!
    private var quadOverlayPipeline: MTLRenderPipelineState!
    private var characterPipeline: MTLRenderPipelineState!
    private var characterBlendPipeline: MTLRenderPipelineState!
    /// Premultiplied blend, for props carrying `KHR_materials_transmission`.
    private var characterTransmissivePipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var ssaoPipeline: MTLRenderPipelineState!
    private var ssaoBlurPipeline: MTLRenderPipelineState!
    private var compositePipeline: MTLRenderPipelineState!

    private var opaqueDepthState: MTLDepthStencilState!
    private var overlayDepthState: MTLDepthStencilState!
    private var shadowDepthState: MTLDepthStencilState!

    private var samplerState: MTLSamplerState!
    private var linearSamplerState: MTLSamplerState!
    private var shadowSamplerState: MTLSamplerState!

    private var quadVertexBuffer: MTLBuffer!
    private var ssaoKernelBuffer: MTLBuffer!

    // Offscreen targets, rebuilt whenever the drawable resizes.
    private var sceneColorTexture: MTLTexture?
    private var sceneNormalTexture: MTLTexture?
    private var sceneDepthTexture: MTLTexture?
    private var aoTexture: MTLTexture?
    private var aoBlurTexture: MTLTexture?
    private var shadowTexture: MTLTexture!
    private var targetSize = SIMD2<Int>(0, 0)

    private let textures: TextureCache
    private let modelStore: ModelStore
    private var characters: CharacterRenderer!
    private var props: PropRenderer!
    /// The court, the net and the ball, when a minigame is drawing through this renderer.
    private var primitives: ScenePrimitiveRenderer!
    private let state: GameState

    /// Per-character rig state that outlives a frame, keyed by character id. three.js keeps
    /// this on the retained `Object3D`s; here it has to be held explicitly.
    private var rigRuntimes: [Int: RigRuntime] = [:]

    private var lighting = SceneLighting()
    private let shadowsEnabled = Config.shadowsEnabled
    private let ssaoEnabled = Config.ssaoEnabled

    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// Supplies fresh input each frame; owned by the view controller.
    var inputProvider: (() -> InputState)?

    /// Called on the main thread once the simulation has stepped, with the viewport in
    /// points. The UI layer uses it to reposition nameplates and bubbles, which the web build
    /// does inside its own draw call.
    var onFrame: ((SIMD2<Float>) -> Void)?

    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var viewportPoints = SIMD2<Float>(1, 1)

    private static let sceneColorFormat = MTLPixelFormat.bgra8Unorm_srgb
    private static let sceneNormalFormat = MTLPixelFormat.rgba8Unorm
    private static let depthFormat = MTLPixelFormat.depth32Float
    private static let aoFormat = MTLPixelFormat.r8Unorm

    init?(view: MTKView, state: GameState) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.textures = TextureCache(device: device)
        self.modelStore = ModelStore(device: device)
        self.state = state
        super.init()

        guard let characters = CharacterRenderer(device: device, models: modelStore) else { return nil }
        self.characters = characters
        self.props = PropRenderer(models: modelStore)
        self.primitives = ScenePrimitiveRenderer(device: device)

        // The composite pass owns the drawable and needs no depth of its own.
        view.colorPixelFormat = Self.sceneColorFormat
        view.depthStencilPixelFormat = .invalid
        clearColor = Self.backgroundClearColor(nil)

        guard buildPipelines(view: view), buildShadowMap() else { return nil }
        buildMeshes()
    }

    // MARK: - Setup

    private func buildPipelines(view: MTKView) -> Bool {
        guard let library = device.makeDefaultLibrary() else {
            Log.render("No default Metal library — are the .metal sources in the target?")
            return false
        }

        /// Scene-pass pipeline: colour attachment 0 plus the view-space normal buffer SSAO reads.
        /// Blended draws (overlays, shadow blobs) leave the normal buffer alone, so it stays
        /// consistent with the depth buffer, which they also do not write.
        func makeScenePipeline(vertex: String, fragment: String,
                               blended: Bool,
                               premultiplied: Bool = false) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.sceneColorFormat
            descriptor.colorAttachments[1].pixelFormat = Self.sceneNormalFormat
            descriptor.depthAttachmentPixelFormat = Self.depthFormat

            if blended {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                // A transmissive surface emits its specular highlight on top of whatever it
                // lets through, so its colour arrives already scaled by coverage and must not
                // be scaled again. Everything else blends the ordinary way.
                attachment.sourceRGBBlendFactor = premultiplied ? .one : .sourceAlpha
                attachment.sourceAlphaBlendFactor = premultiplied ? .one : .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[1].writeMask = []
            }

            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        func makePostPipeline(fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        // Depth-only: no fragment function, no colour attachments.
        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "shadowVertex")
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.depthAttachmentPixelFormat = Self.depthFormat

        let shadowSkinnedDescriptor = MTLRenderPipelineDescriptor()
        shadowSkinnedDescriptor.vertexFunction = library.makeFunction(name: "shadowSkinnedVertex")
        shadowSkinnedDescriptor.fragmentFunction = nil
        shadowSkinnedDescriptor.depthAttachmentPixelFormat = Self.depthFormat

        guard let quad = makeScenePipeline(vertex: "quadVertex", fragment: "quadFragment", blended: false),
              let quadOverlay = makeScenePipeline(vertex: "quadVertex", fragment: "quadFragment", blended: true),
              let character = makeScenePipeline(vertex: "characterVertex", fragment: "characterFragment", blended: false),
              let characterBlend = makeScenePipeline(vertex: "characterVertex", fragment: "characterFragment", blended: true),
              let characterTransmissive = makeScenePipeline(vertex: "characterVertex",
                                                            fragment: "characterFragment",
                                                            blended: true, premultiplied: true),
              let characterSkinned = makeScenePipeline(vertex: "characterSkinnedVertex",
                                                       fragment: "characterFragment", blended: false),
              let shadow = try? device.makeRenderPipelineState(descriptor: shadowDescriptor),
              let shadowSkinned = try? device.makeRenderPipelineState(descriptor: shadowSkinnedDescriptor),
              let ssao = makePostPipeline(fragment: "ssaoFragment", format: Self.aoFormat),
              let ssaoBlur = makePostPipeline(fragment: "ssaoBlurFragment", format: Self.aoFormat),
              let composite = makePostPipeline(fragment: "compositeFragment", format: view.colorPixelFormat)
        else {
            Log.render("Failed to build render pipelines")
            return false
        }

        quadPipeline = quad
        quadOverlayPipeline = quadOverlay
        characterPipeline = character
        characterBlendPipeline = characterBlend
        characterTransmissivePipeline = characterTransmissive
        shadowPipeline = shadow
        // The body is skinned and everything attached to it is not, so the character renderer
        // needs both vertex functions to hand and has to switch between them mid-character.
        characters.pipelines = CharacterPipelines(rigid: character,
                                                  skinned: characterSkinned,
                                                  shadowRigid: shadow,
                                                  shadowSkinned: shadowSkinned)
        ssaoPipeline = ssao
        ssaoBlurPipeline = ssaoBlur
        compositePipeline = composite

        let opaque = MTLDepthStencilDescriptor()
        opaque.depthCompareFunction = .less
        opaque.isDepthWriteEnabled = true
        opaqueDepthState = device.makeDepthStencilState(descriptor: opaque)
        shadowDepthState = device.makeDepthStencilState(descriptor: opaque)

        // Overlays blend against what is already there and must not occlude each other.
        let overlay = MTLDepthStencilDescriptor()
        overlay.depthCompareFunction = .lessEqual
        overlay.isDepthWriteEnabled = false
        overlayDepthState = device.makeDepthStencilState(descriptor: overlay)

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .nearest
        sampler.magFilter = .nearest
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: sampler)

        // Model textures (eyes, shoe trim) look better filtered than the pixel-exact tiles.
        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .repeat
        linear.tAddressMode = .repeat
        linearSamplerState = device.makeSamplerState(descriptor: linear)

        // Hardware PCF: bilinear filtering *of the comparison result*, not of the depth.
        let shadowSampler = MTLSamplerDescriptor()
        shadowSampler.minFilter = .linear
        shadowSampler.magFilter = .linear
        shadowSampler.sAddressMode = .clampToEdge
        shadowSampler.tAddressMode = .clampToEdge
        shadowSampler.compareFunction = .lessEqual
        shadowSamplerState = device.makeSamplerState(descriptor: shadowSampler)

        let kernel = SSAOSettings.kernel()
        ssaoKernelBuffer = device.makeBuffer(bytes: kernel,
                                             length: MemoryLayout<SIMD4<Float>>.stride * kernel.count,
                                             options: .storageModeShared)

        return ssaoKernelBuffer != nil
    }

    private func buildShadowMap() -> Bool {
        let size = SceneLighting.shadowMapSize
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.depthFormat,
                                                                  width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        shadowTexture = device.makeTexture(descriptor: descriptor)
        if shadowTexture == nil { Log.render("Failed to allocate the shadow map") }
        return shadowTexture != nil
    }

    private func buildMeshes() {
        // Unit quad on the XY plane, centred on the origin; scaled per tile.
        let quad: [QuadVertex] = [
            QuadVertex(position: SIMD3(-0.5, -0.5, 0), uv: SIMD2(0, 0)),
            QuadVertex(position: SIMD3( 0.5, -0.5, 0), uv: SIMD2(1, 0)),
            QuadVertex(position: SIMD3( 0.5,  0.5, 0), uv: SIMD2(1, 1)),
            QuadVertex(position: SIMD3(-0.5, -0.5, 0), uv: SIMD2(0, 0)),
            QuadVertex(position: SIMD3( 0.5,  0.5, 0), uv: SIMD2(1, 1)),
            QuadVertex(position: SIMD3(-0.5,  0.5, 0), uv: SIMD2(0, 1)),
        ]
        quadVertexBuffer = device.makeBuffer(bytes: quad,
                                             length: MemoryLayout<QuadVertex>.stride * quad.count,
                                             options: .storageModeShared)
    }

    /// Allocates the offscreen buffers the scene and post passes share.
    private func resizeTargets(to size: SIMD2<Int>) {
        guard size.x > 0, size.y > 0, size != targetSize else { return }
        targetSize = size

        func makeTexture(format: MTLPixelFormat, storage: MTLStorageMode = .private) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                      width: size.x, height: size.y,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = storage
            return device.makeTexture(descriptor: descriptor)
        }

        sceneColorTexture = makeTexture(format: Self.sceneColorFormat)
        sceneNormalTexture = makeTexture(format: Self.sceneNormalFormat)
        sceneDepthTexture = makeTexture(format: Self.depthFormat)
        aoTexture = makeTexture(format: Self.aoFormat)
        aoBlurTexture = makeTexture(format: Self.aoFormat)
    }

    /// #7bed9f is the grass green `renderer.setClearColor` uses when a map names none.
    ///
    /// The background alone is pre-encoded, because the web build encodes it **twice**: three.js
    /// writes the clear colour into the composer's buffer already sRGB-encoded and `OutputPass`
    /// then encodes it a second time. Measured on the live client — linear 0.198 arrives on
    /// screen as 185, not the 123 a single encode gives. Scene geometry is not affected; only
    /// the area outside the map, where nothing is drawn, shows this.
    private static func backgroundClearColor(_ hex: String?) -> MTLClearColor {
        let rgb = parseHexColor(hex ?? "#7bed9f")
        return MTLClearColor(red: Double(linearToSRGB(rgb.x)),
                             green: Double(linearToSRGB(rgb.y)),
                             blue: Double(linearToSRGB(rgb.z)),
                             alpha: 1)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewportPoints = SIMD2(Float(view.bounds.width), Float(view.bounds.height))
        resizeTargets(to: SIMD2(Int(size.width), Int(size.height)))
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        var dt = now - lastFrameTime
        lastFrameTime = now
        if dt > 0.1 { dt = 0.1 }   // Matches the JS frame-time clamp (gameloop.js:83).

        if view.bounds.width > 0 {
            viewportPoints = SIMD2(Float(view.bounds.width), Float(view.bounds.height))
        }
        resizeTargets(to: SIMD2(Int(view.drawableSize.width), Int(view.drawableSize.height)))

        state.update(dt: dt,
                     input: inputProvider?() ?? InputState(),
                     viewport: viewportPoints)

        if state.mapDidChange {
            textures.purge()
            props.clear()
            primitives.clear()
            state.clearMapChangedFlag()
            // A minigame paints its own surround — the tennis court's grass green — in place of
            // whatever the map named.
            clearColor = Self.backgroundClearColor(state.worldRenderedMinigame?.backgroundColor
                                                   ?? state.mapData?.background_color)
        }

        onFrame?(viewportPoints)

        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // The 2D minigames draw themselves over the top of this view; there is no world behind
        // them to render (`tennis.js` never touches three.js).
        guard state.hasWorld,
              !state.suppressesWorldRendering,
              let sceneColor = sceneColorTexture,
              let sceneNormal = sceneNormalTexture,
              let sceneDepth = sceneDepthTexture
        else {
            presentBlank(view: view, drawable: drawable, commandBuffer: commandBuffer)
            return
        }

        props.sync(objects: state.objects)
        props.sync(minigameModels: state.worldRenderedMinigame?.sceneModels ?? [])

        // A minigame rebuilds its geometry every frame: the court is static but the ball is not,
        // and at this scale one array is cheaper than tracking what moved.
        let scenePrimitives = state.worldRenderedMinigame?.scenePrimitives ?? []

        lighting.update(cameraTarget: state.camera.renderTarget)
        var scene = lighting.uniforms(camera: state.camera,
                                      viewport: SIMD2(Float(targetSize.x), Float(targetSize.y)),
                                      shadowsEnabled: shadowsEnabled)

        let poses = preparePoses()

        // Every character's joint matrices are written into one ring buffer, a slice each, and
        // the GPU reads them long after this frame is encoded. This is the frame boundary that
        // keeps the ring big enough for the cast — see `CharacterRenderer.beginFrame`.
        characters.beginFrame()

        if shadowsEnabled {
            encodeShadowPass(commandBuffer: commandBuffer, poses: poses,
                             primitives: scenePrimitives)
        }

        encodeScenePass(commandBuffer: commandBuffer,
                        color: sceneColor, normal: sceneNormal, depth: sceneDepth,
                        scene: &scene, poses: poses, primitives: scenePrimitives)

        if ssaoEnabled, let ao = aoTexture, let aoBlur = aoBlurTexture {
            encodeSSAOPass(commandBuffer: commandBuffer, target: ao,
                           depth: sceneDepth, normal: sceneNormal, scene: &scene)
            encodeBlurPass(commandBuffer: commandBuffer, target: aoBlur, source: ao)
        }

        encodeCompositePass(view: view, commandBuffer: commandBuffer, color: sceneColor)

        captureHandler?(drawable.texture, commandBuffer)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Called with the finished drawable just before it is presented, so a caller can blit it
    /// somewhere readable. Exists because there is no screenshot tool available to the macOS
    /// admin app the way `simctl io screenshot` serves the iOS one; the view hierarchy
    /// snapshot APIs do not capture Metal content.
    ///
    /// The view must be created with `framebufferOnly = false` for the texture to be a valid
    /// blit source.
    var captureHandler: ((MTLTexture, MTLCommandBuffer) -> Void)?

    private func presentBlank(view: MTKView, drawable: CAMetalDrawable, commandBuffer: MTLCommandBuffer) {
        if let descriptor = view.currentRenderPassDescriptor {
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = clearColor
            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        }
        // A capture has to fire here too. Otherwise a screenshot of a session that never got
        // a world — which is exactly the failure worth photographing — waits forever.
        captureHandler?(drawable.texture, commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Passes

    /// Depth-only render from the spotlight's point of view. Ground tiles are omitted: they are
    /// `receiveShadow` in the JS but never `castShadow`, and a flat plane casts nothing anyway.
    ///
    /// three.js avoids shadow acne by rendering back faces (`shadowSide`); here the equivalent
    /// job is done by the constant bias in `sampleShadow`, which does not depend on every mesh
    /// in the asset set being consistently wound.
    private func encodeShadowPass(commandBuffer: MTLCommandBuffer,
                                  poses: [RigPose],
                                  primitives scenePrimitives: [ScenePrimitive]) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.depthAttachment.texture = shadowTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        descriptor.depthAttachment.storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Shadow map"
        encoder.setRenderPipelineState(shadowPipeline)
        encoder.setDepthStencilState(shadowDepthState)
        // three.js renders the *back* faces of a `FrontSide` material into the shadow map
        // (`shadowSide`), which is what keeps the lit surface itself off its own depth test.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.front)

        props.drawShadowCasters(viewProjection: lighting.viewProjection, encoder: encoder,
                                fallbackTexture: characters.fallbackTexture)
        primitives.drawShadowCasters(scenePrimitives,
                                     viewProjection: lighting.viewProjection,
                                     encoder: encoder,
                                     fallbackTexture: characters.fallbackTexture)
        for pose in poses {
            characters.draw(pose: pose, viewProjection: lighting.viewProjection,
                            encoder: encoder, includeProps: false)
        }

        encoder.endEncoding()
    }

    private func encodeScenePass(commandBuffer: MTLCommandBuffer,
                                 color: MTLTexture,
                                 normal: MTLTexture,
                                 depth: MTLTexture,
                                 scene: inout SceneUniforms,
                                 poses: [RigPose],
                                 primitives scenePrimitives: [ScenePrimitive]) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = color
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = clearColor
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[1].texture = normal
        descriptor.colorAttachments[1].loadAction = .clear
        // A +Z view-space normal, so untouched pixels never occlude anything.
        descriptor.colorAttachments[1].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 1, alpha: 1)
        descriptor.colorAttachments[1].storeAction = .store
        descriptor.depthAttachment.texture = depth
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        descriptor.depthAttachment.storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Scene"

        // Every material in the JS is left at three.js's default `FrontSide`, so back faces are
        // culled. Without this, open shells — the shed panels, the roof edges of
        // `junior_school_buildings.glb` — show their unlit interior instead of letting the
        // ground through, which is what dragged the darkest 5% of the frame far below the web
        // build's. glTF guarantees counter-clockwise front faces, and `MeshFactory` follows
        // three.js's winding, so one setting covers both.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)

        encoder.setVertexBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 2)
        encoder.setFragmentTexture(shadowTexture, index: 2)
        encoder.setFragmentSamplerState(shadowSamplerState, index: 2)

        let viewProjection = state.camera.viewProjection
        let chunks = state.map.visibleChunks(camera: state.camera)

        // Ground first, with depth writes, so overlays and geometry sort against it.
        encoder.setRenderPipelineState(quadPipeline)
        encoder.setDepthStencilState(opaqueDepthState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        for chunk in chunks where !chunk.isOverlay {
            drawChunk(chunk, viewProjection: viewProjection, encoder: encoder)
        }

        // Props are opaque and depth-tested, so they sort against the ground on their own.
        if !props.isEmpty || !scenePrimitives.isEmpty {
            encoder.setRenderPipelineState(characterPipeline)
            encoder.setFragmentSamplerState(linearSamplerState, index: 0)
            // `characterFragment` declares `clipSampler` at 1, so it has to be bound even though
            // props pass a zero `clipParams` and never sample the mask.
            encoder.setFragmentSamplerState(samplerState, index: 1)
            encoder.setFragmentTexture(characters.fallbackTexture, index: 1)
            props.draw(viewProjection: viewProjection, encoder: encoder,
                       fallbackTexture: characters.fallbackTexture)
            // A minigame's court is the ground for this frame, so it goes down before the
            // characters standing on it.
            primitives.draw(scenePrimitives, blended: false, viewProjection: viewProjection,
                            encoder: encoder, fallbackTexture: characters.fallbackTexture)
        }

        drawCharacters(viewProjection: viewProjection, encoder: encoder, poses: poses)

        // Transmissive prop materials — a glass lens, a bottle — after everything opaque, so
        // there is something behind them to show through. Same opaque-then-transparent order
        // three.js sorts into.
        if props.hasTransmissive {
            encoder.setRenderPipelineState(characterTransmissivePipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setFragmentSamplerState(linearSamplerState, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 1)
            encoder.setFragmentTexture(characters.fallbackTexture, index: 1)
            props.draw(viewProjection: viewProjection, encoder: encoder,
                       fallbackTexture: characters.fallbackTexture, transmissive: true)
        }

        // A minigame's blended geometry — the ball's ground shadow, the aim marker — after the
        // characters, so it lays over them rather than punching a hole in one.
        if scenePrimitives.contains(where: { $0.blended }) {
            encoder.setRenderPipelineState(characterBlendPipeline)
            encoder.setDepthStencilState(overlayDepthState)
            encoder.setFragmentSamplerState(linearSamplerState, index: 0)
            encoder.setFragmentSamplerState(samplerState, index: 1)
            encoder.setFragmentTexture(characters.fallbackTexture, index: 1)
            primitives.draw(scenePrimitives, blended: true, viewProjection: viewProjection,
                            encoder: encoder, fallbackTexture: characters.fallbackTexture)
        }

        // Overlays last, blended, ascending in depth.
        encoder.setRenderPipelineState(quadOverlayPipeline)
        encoder.setDepthStencilState(overlayDepthState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        for chunk in chunks.filter({ $0.isOverlay }).sorted(by: { $0.z < $1.z }) {
            drawChunk(chunk, viewProjection: viewProjection, encoder: encoder)
        }

        encoder.endEncoding()
    }

    private func encodeSSAOPass(commandBuffer: MTLCommandBuffer,
                                target: MTLTexture,
                                depth: MTLTexture,
                                normal: MTLTexture,
                                scene: inout SceneUniforms) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "SSAO"
        encoder.setRenderPipelineState(ssaoPipeline)

        var settings = SIMD4<Float>(SSAOSettings.kernelRadius,
                                    SSAOSettings.minDistance,
                                    SSAOSettings.maxDistance,
                                    0)
        encoder.setFragmentBytes(&scene, length: MemoryLayout<SceneUniforms>.stride, index: 2)
        encoder.setFragmentBuffer(ssaoKernelBuffer, offset: 0, index: 3)
        encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 4)
        encoder.setFragmentTexture(depth, index: 0)
        encoder.setFragmentTexture(normal, index: 1)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeBlurPass(commandBuffer: MTLCommandBuffer, target: MTLTexture, source: MTLTexture) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "SSAO blur"
        encoder.setRenderPipelineState(ssaoBlurPipeline)

        var texelSize = SIMD4<Float>(1 / Float(targetSize.x), 1 / Float(targetSize.y), 0, 0)
        encoder.setFragmentBytes(&texelSize, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(linearSamplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func encodeCompositePass(view: MTKView, commandBuffer: MTLCommandBuffer, color: MTLTexture) {
        guard let descriptor = view.currentRenderPassDescriptor else { return }
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.depthAttachment.texture = nil

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Composite"
        encoder.setRenderPipelineState(compositePipeline)

        var settings = SIMD4<Float>(ssaoEnabled ? 1 : 0, 0, 0, 0)
        encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(color, index: 0)
        encoder.setFragmentTexture(aoBlurTexture ?? color, index: 1)
        encoder.setFragmentSamplerState(linearSamplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: - Draw helpers

    private func drawChunk(_ chunk: ChunkDraw,
                           viewProjection: Float4x4,
                           encoder: MTLRenderCommandEncoder) {
        guard let texture = textures.texture(for: chunk.path) else {
            textures.requestTexture(path: chunk.path)
            return
        }

        let model = Float4x4.translation(SIMD3(chunk.centerX, chunk.centerY, chunk.z))
            * Float4x4.scale(SIMD3(chunk.size, chunk.size, 1))

        // Ground layers are `MeshLambertMaterial` and take the light; overlays are
        // `MeshBasicMaterial` and stay flat (`maps.js:276`).
        var uniforms = DrawUniforms(modelViewProjection: viewProjection * model,
                                    model: model,
                                    tint: SIMD4(1, 1, 1, chunk.alpha),
                                    flags: SIMD4(chunk.isOverlay ? 0 : 1, 0, 0, 0))

        encoder.setVertexBytes(&uniforms, length: MemoryLayout<DrawUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Poses every on-screen character once per frame; the result feeds both the shadow pass
    /// and the scene pass. Port of `drawCharacters` (`characters.js:1282-1310`).
    private func preparePoses() -> [RigPose] {
        characters.syncClipMask(state.physics.clipMask)

        let scale = state.mapData?.character_scale ?? 1
        // The wall clock, unless the character lab has pinned it to its own timeline.
        let now = SceneClock.now
        let viewProjection = state.camera.viewProjection

        // Camera basis in world space, so `love`'s heart sprites can be billboarded the way
        // `THREE.Sprite` billboards itself.
        let view = state.camera.view
        let cameraRight = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let cameraUp = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)

        var poses: [RigPose] = []
        let drawable = state.drawableCharacters
        poses.reserveCapacity(drawable.count)

        var live = Set<Int>()
        for entry in drawable {
            live.insert(entry.character.id)
            guard isOnScreen(entry.character, viewProjection: viewProjection) else { continue }

            let runtime = rigRuntimes[entry.character.id] ?? {
                let fresh = RigRuntime()
                rigRuntimes[entry.character.id] = fresh
                return fresh
            }()

            poses.append(CharacterRig.pose(character: entry.character,
                                           gait: entry.gait,
                                           mapCharacterScale: scale,
                                           time: now,
                                           runtime: runtime,
                                           cameraRight: cameraRight,
                                           cameraUp: cameraUp,
                                           override: entry.poseOverride))
        }

        // Characters that left the world take their rig state with them, the way the JS drops
        // the whole proxy in `cleanupCharacter` (`characters.js:430-461`).
        rigRuntimes = rigRuntimes.filter { live.contains($0.key) }
        return poses
    }

    private func drawCharacters(viewProjection: Float4x4,
                                encoder: MTLRenderCommandEncoder,
                                poses: [RigPose]) {
        guard !poses.isEmpty else { return }

        encoder.setFragmentSamplerState(linearSamplerState, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 1)

        encoder.setRenderPipelineState(characterBlendPipeline)
        encoder.setDepthStencilState(overlayDepthState)
        for pose in poses {
            characters.drawShadow(pose: pose, viewProjection: viewProjection, encoder: encoder)
        }

        encoder.setRenderPipelineState(characterPipeline)
        encoder.setDepthStencilState(opaqueDepthState)
        for pose in poses {
            characters.draw(pose: pose, viewProjection: viewProjection, encoder: encoder)
        }

        // Transparent emote props last, so they blend over the rig rather than being hidden by
        // it — the same order three.js's opaque-then-transparent sort produces.
        guard poses.contains(where: { pose in pose.props.contains(where: { $0.transparent }) }) else { return }
        encoder.setRenderPipelineState(characterBlendPipeline)
        encoder.setDepthStencilState(overlayDepthState)
        for pose in poses {
            characters.drawTransparentProps(pose: pose, viewProjection: viewProjection, encoder: encoder)
        }
    }

    /// Frustum check on the character's centre, with the same generous margin the JS uses so
    /// nothing pops at the edges (`characters.js:1288-1289`).
    private func isOnScreen(_ character: GameCharacter, viewProjection: Float4x4) -> Bool {
        let position = SIMD4<Float>(Float(character.x),
                                    Float(-character.y),
                                    Float(character.z ?? 0) + 5,
                                    1)
        let clip = viewProjection * position
        guard clip.w > 0 else { return false }
        let ndc = SIMD3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
        return ndc.z <= 1 && abs(ndc.x) <= 1.3 && abs(ndc.y) <= 1.3
    }
}
