import Metal
import simd

/// Draws the static `.glb` props placed on a map — every world object whose `shape` is
/// `3d_model`. Port of `MapManager.loadSingleModel` and `updateDynamicModels`
/// (`maps.js:125-187`, `maps.js:348-383`).
///
/// Props keep the colours and textures their artist authored, cast and receive shadows, and —
/// unlike characters — are **not** clip-masked: the JS only injects that shader into character
/// materials.
final class PropRenderer {
    /// One placed instance. The model itself may still be loading.
    private struct Placement {
        var id: Int
        var path: String
        var transform: Float4x4
    }

    private let models: ModelStore
    private var placements: [Placement] = []
    /// Identity of the object list the placements were built from, so the transforms are only
    /// rebuilt when the server actually sends new objects.
    private var signature: [Int: String] = [:]

    init(models: ModelStore) {
        self.models = models
    }

    /// Rebuilds the placement list when the object set changes. Safe to call every frame.
    func sync(objects: [WorldObject]) {
        var newSignature: [Int: String] = [:]
        for object in objects {
            guard object.shape == "3d_model", let model = object.model, !model.isEmpty else { continue }
            newSignature[object.id] = "\(model)|\(object.x),\(object.y),\(object.z ?? 0)"
                + "|\(object.rotation ?? 0)|\(object.scale ?? 1)"
        }
        guard newSignature != signature else { return }
        signature = newSignature

        placements = objects.compactMap { object in
            guard object.shape == "3d_model", let model = object.model, !model.isEmpty else { return nil }
            return Placement(id: object.id, path: Self.assetPath(model), transform: Self.transform(for: object))
        }

        Log.render("Props: \(placements.count) 3D model instance(s) placed")
    }

    func clear() {
        placements.removeAll()
        signature.removeAll()
    }

    var isEmpty: Bool { placements.isEmpty }

    /// True once a loaded model turns out to carry a transmissive material, so the renderer
    /// only encodes the extra blended sub-pass when there is something in it.
    var hasTransmissive: Bool {
        placements.contains { models.model($0.path)?.groups.contains { $0.surface.isTransmissive } == true }
    }

    /// Draws every prop whose model has finished loading, requesting the rest.
    /// `encoder` must already have a pipeline bound that consumes `CharacterUniforms`.
    ///
    /// `transmissive` selects which half of the model to draw: opaque materials go through the
    /// scene pass, and anything with `KHR_materials_transmission` is left for the blended
    /// sub-pass that runs after the characters.
    func draw(viewProjection: Float4x4,
              encoder: MTLRenderCommandEncoder,
              fallbackTexture: MTLTexture,
              transmissive: Bool = false) {
        for placement in placements {
            guard let model = models.model(placement.path) else {
                models.request(path: placement.path, classifier: { _ in .authored })
                continue
            }

            for group in model.groups where group.surface.isTransmissive == transmissive {
                var uniforms = CharacterUniforms(
                    modelViewProjection: viewProjection * placement.transform,
                    model: placement.transform,
                    color: group.baseColor,
                    // Zero map size switches the clip-mask march off.
                    clipParams: SIMD4(0, 0, 0, 0),
                    textured: group.texture != nil,
                    unlit: false,
                    material: SurfaceMaterial(group: group),
                    emissiveTextured: group.emissiveTexture != nil
                )

                encoder.setVertexBuffer(group.mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
                encoder.setFragmentTexture(group.texture ?? fallbackTexture, index: 0)
                encoder.setFragmentTexture(group.emissiveTexture ?? fallbackTexture, index: 3)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: group.mesh.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: group.mesh.indexBuffer,
                                              indexBufferOffset: 0)
            }
        }
    }

    // MARK: - Placement

    private static func assetPath(_ model: String) -> String {
        model.hasPrefix("/") ? String(model.dropFirst()) : model
    }

    /// `maps.js:127-144`. A pivot group carries the object's world placement, and the model
    /// inside it is tipped upright by 90° about X — glTF is authored Y-up, this world is Z-up.
    /// User rotation is negated because world rotations are clockwise while render space is not.
    private static func transform(for object: WorldObject) -> Float4x4 {
        let scale = Float(object.scale ?? 1)
        let userRotation = -Float(object.rotation ?? 0) * degToRad

        return Float4x4.translation(SIMD3(Float(object.x), Float(-object.y), Float(object.z ?? 0)))
            * Float4x4.rotationZ(userRotation)
            * Float4x4.scale(SIMD3(repeating: scale))
            * Float4x4.rotationX(.pi / 2)
    }
}
