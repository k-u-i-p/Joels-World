import Metal
import simd

/// Draws the solid shapes a world-rendered minigame hands over each frame — the tennis court,
/// its painted lines, the net, the ball.
///
/// The overworld has two sources of geometry: chunked ground images and authored `.glb` props.
/// A minigame has neither. Rather than invent a court model or a court texture, `Tennis3DGame`
/// describes itself as a list of boxes, spheres, cylinders and planes, and this turns that list
/// into draw calls.
///
/// **Sizes live in the mesh, not in the transform.** `Shaders.metal` transforms normals by the
/// model matrix rather than by its inverse transpose, so baking a non-uniform scale into a
/// primitive's transform would light it wrongly — a stretched net cord would shade as if it
/// were still square. Each distinct `ScenePrimitive.Shape` therefore gets its own GPU mesh,
/// built on first sight and kept. A tennis court resolves to about a dozen of them.
final class ScenePrimitiveRenderer {
    private let device: MTLDevice
    private var meshes: [ScenePrimitive.Shape: GPUMesh] = [:]
    /// Guards the assumption above. A caller that varies a size smoothly — the ball's shadow
    /// used to shrink by a fraction of a millimetre a frame — asks for a brand new mesh sixty
    /// times a second and never stops, and an unbounded cache of Metal buffers gets the app
    /// killed by the memory monitor a minute later with no crash report to explain it. Past this
    /// many distinct shapes the cache stops growing and says so once; the shapes still draw,
    /// they just rebuild each time, which is slow enough to notice and find.
    private static let cacheLimit = 256
    private var warnedAboutCacheLimit = false

    init(device: MTLDevice) {
        self.device = device
    }

    /// Drops every cached mesh. Called when a minigame ends, so a court does not sit in memory
    /// for the rest of the session.
    func clear() {
        meshes.removeAll()
        warnedAboutCacheLimit = false
    }

    /// Draws the opaque primitives, or the blended ones, depending on `blended`.
    ///
    /// `encoder` must already have a pipeline bound that consumes `CharacterUniforms` — the
    /// character pipeline for the opaque pass, the blended one for the rest.
    func draw(_ primitives: [ScenePrimitive],
              blended: Bool,
              viewProjection: Float4x4,
              encoder: MTLRenderCommandEncoder,
              fallbackTexture: MTLTexture) {
        for primitive in primitives where primitive.blended == blended {
            guard let mesh = mesh(for: primitive.shape) else { continue }
            encode(primitive, mesh: mesh, viewProjection: viewProjection,
                   encoder: encoder, fallbackTexture: fallbackTexture)
        }
    }

    /// The shadow-map pass: only what actually casts. The ground planes and the painted lines
    /// opt out — a flat plane casts nothing, and a line lying on the surface it would shadow
    /// only produces acne.
    func drawShadowCasters(_ primitives: [ScenePrimitive],
                           viewProjection: Float4x4,
                           encoder: MTLRenderCommandEncoder,
                           fallbackTexture: MTLTexture) {
        for primitive in primitives where primitive.castsShadow && !primitive.blended {
            guard let mesh = mesh(for: primitive.shape) else { continue }
            encode(primitive, mesh: mesh, viewProjection: viewProjection,
                   encoder: encoder, fallbackTexture: fallbackTexture)
        }
    }

    private func encode(_ primitive: ScenePrimitive,
                        mesh: GPUMesh,
                        viewProjection: Float4x4,
                        encoder: MTLRenderCommandEncoder,
                        fallbackTexture: MTLTexture) {
        var uniforms = CharacterUniforms(
            modelViewProjection: viewProjection * primitive.transform,
            model: primitive.transform,
            color: SIMD4(primitive.color, primitive.opacity),
            // A zero map size switches the clip-mask raymarch off: a minigame has no
            // walkability mask, and the court must not be dissolved by a stale one.
            clipParams: SIMD4(0, 0, 0, 0),
            textured: false,
            unlit: primitive.unlit,
            material: SurfaceMaterial(roughness: primitive.roughness,
                                      metalness: primitive.metalness)
        )

        encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
        encoder.setFragmentTexture(fallbackTexture, index: 0)
        encoder.setFragmentTexture(fallbackTexture, index: 3)
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: .uint32,
                                      indexBuffer: mesh.indexBuffer,
                                      indexBufferOffset: 0)
    }

    // MARK: - Mesh cache

    private func mesh(for shape: ScenePrimitive.Shape) -> GPUMesh? {
        if let cached = meshes[shape] { return cached }

        let data: MeshData
        switch shape {
        case .box(let width, let height, let depth):
            data = MeshFactory.box(width: width, height: height, depth: depth)
        case .sphere(let radius):
            data = MeshFactory.sphere(radius: radius, widthSegments: 16, heightSegments: 12)
        case .cylinder(let radius, let height):
            data = MeshFactory.cylinder(radiusTop: radius, radiusBottom: radius,
                                        height: height, radialSegments: 12)
        case .plane(let width, let height):
            data = MeshFactory.plane(width: width, height: height)
        }

        guard let built = GPUMesh(device: device, mesh: data) else {
            Log.render("Failed to build a scene primitive mesh for \(shape)")
            return nil
        }

        if meshes.count >= Self.cacheLimit {
            if !warnedAboutCacheLimit {
                warnedAboutCacheLimit = true
                Log.render("Scene primitives have asked for more than \(Self.cacheLimit) distinct "
                           + "shapes — something is varying a size continuously. Not caching any "
                           + "more; quantise the size instead. Latest: \(shape)")
            }
            return built
        }

        meshes[shape] = built
        return built
    }
}
