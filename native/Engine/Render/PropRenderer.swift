import Metal
import simd

/// Draws the static `.glb` props placed on a map — every world object whose `shape` is
/// `3d_model`. Port of `MapManager.loadSingleModel` and `updateDynamicModels`
/// (`maps.js:125-187`, `maps.js:348-383`).
///
/// Props keep the colours and textures their artist authored, cast and receive shadows, and —
/// unlike characters — are **not** clip-masked: the JS only injects that shader into character
/// materials.
///
/// A world-rendered minigame has no server objects to place, so it hands over `SceneModel`s
/// instead (`sync(minigameModels:)`). They draw through exactly the same path; the only
/// difference is that they choose whether to enter the shadow pass.
///
/// **Two things keep the cost of that proportional to what is on screen.** The junior campus
/// places 271 props from 28 models across 4372×3841 units, of which a screenful is maybe a
/// twelfth:
///
/// - *Culling* (`draw`) tests each placement's world bounding sphere against the frustum of the
///   matrix it is about to be drawn with, so the scene pass skips what is off screen and the
///   shadow pass skips what is outside the spotlight's cone.
/// - *Streaming* (`updateStreaming`) asks `ModelStore` for a few models at a time, nearest the
///   player first — so entering a map does not parse every model it contains on one frame.
final class PropRenderer {
    /// One placed instance. The model itself may still be loading.
    private struct Placement {
        var path: String
        var transform: Float4x4
        var castsShadow: Bool = true
        /// Render-space origin of the placement, which is known before the model is, and is
        /// what streaming sorts on.
        var origin: SIMD3<Float>
        /// Set by `updateStreaming` the frame the model arrives; the three fields below are only
        /// meaningful once it is true.
        var resolved = false
        /// Where this instance sits in render space, and how big it is. Stays nil for a model
        /// that parsed to no geometry.
        var sphere: BoundingSphere?
        /// Which of the two scene passes this placement has anything for, so each can skip the
        /// rest before touching the model table — which matters most to the transmissive
        /// sub-pass, where a handful of glass materials used to walk all 271.
        var drawsOpaque = false
        var drawsTransmissive = false
    }

    /// The fields a `Placement` is built from. Compared field by field every frame to spot a
    /// genuinely new object list — cheap enough to do that, unlike the interpolated string this
    /// replaced, which allocated once per object per frame.
    private struct PlacementKey: Equatable {
        var id: Int
        var model: String
        var x: Double
        var y: Double
        var z: Double
        var rotation: Double
        var scale: Double
    }

    private let models: ModelStore
    private var placements: [Placement] = []
    private var signature: [PlacementKey] = []
    /// The minigame's own models, kept apart from the server's so `sync(objects:)` cannot
    /// discard them and vice versa.
    private var minigamePlacements: [Placement] = []
    private var minigameSignature: [SceneModel] = []

    /// True once a resident model turns out to carry a transmissive material, so the renderer
    /// only encodes the extra blended sub-pass when there is something in it. Recomputed by
    /// `updateStreaming` from the per-placement flags, which costs a bool read per placement.
    private(set) var hasTransmissive = false

    /// `-propstats` and `-nocull` — see `Config`.
    private static let statsEnabled = Config.propStatsEnabled
    private static let cullingEnabled = Config.propCullingEnabled
    private var lastStatsTime: CFAbsoluteTime = 0
    private var loggedBounds: Set<String> = []
    private var sceneDrawn = 0
    private var sceneCulled = 0
    private var shadowDrawn = 0
    private var shadowCulled = 0

    init(models: ModelStore) {
        self.models = models
    }

    /// Rebuilds the placement list when the object set changes. Safe to call every frame.
    func sync(objects: [WorldObject]) {
        var keys: [PlacementKey] = []
        keys.reserveCapacity(objects.count)
        for object in objects {
            guard object.shape == "3d_model", let model = object.model, !model.isEmpty else { continue }
            keys.append(PlacementKey(id: object.id, model: model,
                                     x: object.x, y: object.y, z: object.z ?? 0,
                                     rotation: object.rotation ?? 0, scale: object.scale ?? 1))
        }
        guard keys != signature else { return }
        signature = keys

        placements = keys.map { key in
            let transform = Self.transform(for: key)
            return Placement(path: Self.assetPath(key.model), transform: transform,
                             origin: Self.origin(of: transform))
        }
        Log.render("Props: \(placements.count) 3D model instance(s) placed")
    }

    /// Rebuilds the minigame's placements when they change. Safe to call every frame.
    func sync(minigameModels: [SceneModel]) {
        guard minigameModels != minigameSignature else { return }
        minigameSignature = minigameModels

        minigamePlacements = minigameModels.map { model in
            Placement(path: AssetLocator.relative(model.path), transform: model.transform,
                      castsShadow: model.castsShadow, origin: Self.origin(of: model.transform))
        }
        if !minigamePlacements.isEmpty {
            Log.render("Props: \(minigamePlacements.count) minigame model(s) placed")
        }
    }

    func clear() {
        placements.removeAll()
        signature.removeAll()
        minigamePlacements.removeAll()
        minigameSignature.removeAll()
        hasTransmissive = false
        loggedBounds.removeAll()
    }

    var isEmpty: Bool { placements.isEmpty && minigamePlacements.isEmpty }

    // MARK: - Streaming

    /// Asks `ModelStore` for the models nearest the camera, a few at a time, and works out what
    /// the passes need to know about anything that has arrived since the last frame: its world
    /// bounding sphere, and which of the two passes it belongs in.
    ///
    /// **Order, not a radius.** The obvious policy — skip anything more than a screen or two
    /// away — is wrong here, and wrong in a way that only shows up on one map. A placement's
    /// distance has to be measured from something known before its model loads, which leaves
    /// only the point the map editor placed it at; and `junior_school_buildings.glb` is a single
    /// placement covering the entire campus, whose origin is nowhere near the middle of it. Under
    /// a radius test that building never loads at all — the player stands in a school with no
    /// school around them, and it never recovers, because the test does not change as they walk.
    ///
    /// So everything on the map is asked for eventually; distance only decides what is asked for
    /// *first*. The stall this was written to fix is caused by the count, not the total — 28
    /// parses on one frame — and `ModelStore.maxConcurrentStreamedLoads` is what fixes it. The
    /// memory those 28 hold is given back by `evictMapModels` on the way out.
    ///
    /// Call once per frame, before the passes. Everything it does is cheap and per-placement:
    /// no allocation for the common case where nothing is missing.
    func updateStreaming(camera: Camera) {
        let focus = SIMD3(camera.renderTarget.x, camera.renderTarget.y, 0)

        // Nearest distance² to each model still missing, so the budget is spent on the ones the
        // player is standing next to. Keyed by model rather than per placement: the campus's 271
        // placements draw on 28 models, and a duplicate cannot cost budget it will not use.
        // Stays empty — and so allocates nothing — once everything on the map has arrived.
        var wanted: [String: Float] = [:]
        var transmissive = false

        forEachPlacement { placement in
            if !placement.resolved {
                if let model = models.model(placement.path) {
                    placement.sphere = model.bounds.boundingSphere(transformedBy: placement.transform)
                    placement.drawsTransmissive = model.groups.contains { $0.surface.isTransmissive }
                    placement.drawsOpaque = model.groups.contains { !$0.surface.isTransmissive }
                    placement.resolved = true
                    logBounds(of: placement, model: model)
                } else if !models.hasFailed(placement.path), !models.isLoading(placement.path) {
                    let distanceSquared = simd_length_squared(placement.origin - focus)
                    wanted[placement.path] = Swift.min(wanted[placement.path] ?? .infinity,
                                                       distanceSquared)
                }
            }
            if placement.drawsTransmissive { transmissive = true }
        }
        hasTransmissive = transmissive

        // `request` marks a path in flight synchronously, so taking the nearest `slots` is
        // exactly the budget — no path appears twice.
        let slots = models.streamingSlots
        if slots > 0 && !wanted.isEmpty {
            for (path, _) in wanted.sorted(by: { $0.value < $1.value }).prefix(slots) {
                models.request(path: path, classifier: { _ in .authored }, lifetime: .map)
            }
        }

        reportStats(camera: camera)
    }

    /// One line per distinct model, not per placement — the campus would print 271.
    private func logBounds(of placement: Placement, model: LoadedModel) {
        guard Self.statsEnabled, let sphere = placement.sphere,
              loggedBounds.insert(placement.path).inserted else { return }
        Log.render(String(format: "  bounds %@ local(%.0f,%.0f,%.0f)-(%.0f,%.0f,%.0f)"
                          + " → first placement at (%.0f,%.0f,%.0f) r=%.0f",
                          placement.path,
                          model.bounds.min.x, model.bounds.min.y, model.bounds.min.z,
                          model.bounds.max.x, model.bounds.max.y, model.bounds.max.z,
                          sphere.center.x, sphere.center.y, sphere.center.z, sphere.radius))
    }

    /// Counts from the frame just encoded — `updateStreaming` runs before the passes, so this
    /// reports the previous one, which for a once-a-second line makes no difference.
    private func reportStats(camera: Camera) {
        guard Self.statsEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastStatsTime >= 1 else { return }
        lastStatsTime = now

        let placed = placements.count + minigamePlacements.count
        Log.render(String(format: "  camera focus (%.0f,%.0f) zoom %.2f pitch %.2f",
                          camera.renderTarget.x, camera.renderTarget.y, camera.zoom, camera.pitch))
        Log.render("Props: \(placed) placed, \(models.residentCount) model(s) resident — "
                   + "scene drew \(sceneDrawn), culled \(sceneCulled); "
                   + "shadow drew \(shadowDrawn), culled \(shadowCulled)")
    }

    // MARK: - Drawing

    /// The shadow-map pass: only the placements that opted in. Every server-placed prop does;
    /// a minigame's scenery generally should not — see `SceneModel.castsShadow`.
    ///
    /// `viewProjection` is the spotlight's, so the culling inside `draw` is against the light's
    /// cone. A prop outside it lands nowhere in the shadow map and can be skipped outright,
    /// which is a bigger saving than the scene pass gets: the cone is narrower than the view.
    ///
    /// `alphaTestPipeline` is swapped in for `MASK` materials and only those — a leaf's shape
    /// lives in its alpha channel, which the depth-only pipeline cannot see.
    func drawShadowCasters(viewProjection: Float4x4,
                           encoder: MTLRenderCommandEncoder,
                           fallbackTexture: MTLTexture,
                           fallbackNormalTexture: MTLTexture,
                           pipeline: MTLRenderPipelineState? = nil,
                           alphaTestPipeline: MTLRenderPipelineState? = nil) {
        // The shadow pass culls *front* faces, so that is what a single-sided prop restores to.
        draw(viewProjection: viewProjection, encoder: encoder,
             fallbackTexture: fallbackTexture, fallbackNormalTexture: fallbackNormalTexture,
             transmissive: false, shadowCastersOnly: true, cullMode: .front,
             pipeline: pipeline, alphaTestPipeline: alphaTestPipeline)
    }

    /// Draws every prop whose model has finished loading and whose bounds reach the frustum.
    /// `encoder` must already have a pipeline bound that consumes `CharacterUniforms`.
    ///
    /// `transmissive` selects which half of the model to draw: opaque materials go through the
    /// scene pass, and anything with `KHR_materials_transmission` is left for the blended
    /// sub-pass that runs after the characters.
    ///
    /// `cullMode` is the mode the pass set up and the one this restores to: a double-sided
    /// material turns culling off for its own draw and hands it straight back.
    func draw(viewProjection: Float4x4,
              encoder: MTLRenderCommandEncoder,
              fallbackTexture: MTLTexture,
              fallbackNormalTexture: MTLTexture,
              transmissive: Bool = false,
              shadowCastersOnly: Bool = false,
              cullMode: MTLCullMode = .back,
              pipeline: MTLRenderPipelineState? = nil,
              alphaTestPipeline: MTLRenderPipelineState? = nil) {
        let frustum = Frustum(viewProjection: viewProjection)
        var drawn = 0
        var culled = 0
        var wronglyCulled = 0
        var currentCull = cullMode
        // nil in the scene pass, where the pass's own pipeline is already the right one and
        // masked materials are alpha-tested inside `characterFragment`.
        var alphaTested = false

        forEachPlacement { placement in
            if shadowCastersOnly && !placement.castsShadow { return }
            // Also false while the model is still loading — there is nothing to draw yet. This
            // is why the model table is only consulted for what survives culling: on the campus
            // that is 6–28 lookups a pass rather than 271.
            guard transmissive ? placement.drawsTransmissive : placement.drawsOpaque else { return }

            // The sphere is always there by now: a placement with something to draw has
            // geometry, and geometry is where the bounds came from.
            if Self.cullingEnabled, let sphere = placement.sphere, !frustum.intersects(sphere) {
                culled += 1
                if Self.statsEnabled, Self.isOnScreen(sphere.center, viewProjection) {
                    wronglyCulled += 1
                }
                return
            }
            guard let model = models.model(placement.path) else { return }
            drawn += 1

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
                    emissiveTextured: group.emissiveTexture != nil,
                    normalTextured: group.normalTexture != nil,
                    normalScale: group.normalScale,
                    metallicRoughnessTextured: group.metallicRoughnessTexture != nil,
                    alphaCutoff: group.alphaCutoff
                )

                // `doubleSided`. Tracked rather than set every draw because a state change on
                // the encoder is not free and one prop in twenty wants the non-default — and
                // restored to the pass's own mode after, since the scene pass culls backs and
                // the shadow pass culls fronts.
                let wanted: MTLCullMode = group.doubleSided ? .none : cullMode
                if wanted != currentCull {
                    encoder.setCullMode(wanted)
                    currentCull = wanted
                }

                // Same idea for the shadow pass's two pipelines: switch in the alpha-tested one
                // for a masked material and switch straight back out.
                if let pipeline, let alphaTestPipeline {
                    let wantsAlphaTest = group.alphaCutoff > 0
                    if wantsAlphaTest != alphaTested {
                        encoder.setRenderPipelineState(wantsAlphaTest ? alphaTestPipeline : pipeline)
                        alphaTested = wantsAlphaTest
                    }
                }

                encoder.setVertexBuffer(group.mesh.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CharacterUniforms>.stride, index: 1)
                encoder.setFragmentTexture(group.texture ?? fallbackTexture, index: 0)
                encoder.setFragmentTexture(group.emissiveTexture ?? fallbackTexture, index: 3)
                encoder.setFragmentTexture(group.normalTexture ?? fallbackNormalTexture, index: 4)
                encoder.setFragmentTexture(group.metallicRoughnessTexture ?? fallbackTexture, index: 5)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: group.mesh.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: group.mesh.indexBuffer,
                                              indexBufferOffset: 0)
            }
        }

        // Hand the pass its own cull mode and pipeline back — characters and minigame geometry
        // are drawn after this on the same encoder and expect both unchanged.
        if currentCull != cullMode { encoder.setCullMode(cullMode) }
        if alphaTested, let pipeline { encoder.setRenderPipelineState(pipeline) }

        // The transmissive sub-pass sees the same placements, so counting it would double the
        // scene figure. Left out.
        if shadowCastersOnly {
            shadowDrawn = drawn
            shadowCulled = culled
        } else if !transmissive {
            sceneDrawn = drawn
            sceneCulled = culled
        }
        if wronglyCulled > 0 {
            Log.render("Props: \(wronglyCulled) placement(s) culled with their centre on screen "
                       + "— the frustum planes are wrong")
        }
    }

    /// Both placement lists in one walk, by reference so a pass can fill in a sphere. The two
    /// stay separate arrays because `sync(objects:)` and `sync(minigameModels:)` each replace
    /// their own wholesale; everything downstream wants them together.
    private func forEachPlacement(_ body: (inout Placement) -> Void) {
        for index in placements.indices { body(&placements[index]) }
        for index in minigamePlacements.indices { body(&minigamePlacements[index]) }
    }

    /// A sphere whose *centre* projects inside the clip volume cannot legitimately be culled,
    /// whatever its radius — which is what makes this the check a screenshot cannot do. A plane
    /// taken from the wrong row, or with its sign inverted, culls things that are plainly on
    /// screen, and at a glance a frame missing some of its scenery looks much like a frame that
    /// never had it.
    private static func isOnScreen(_ point: SIMD3<Float>, _ viewProjection: Float4x4) -> Bool {
        let clip = viewProjection * SIMD4(point, 1)
        return clip.w > 0 && abs(clip.x) <= clip.w && abs(clip.y) <= clip.w
            && clip.z >= 0 && clip.z <= clip.w
    }

    // MARK: - Placement

    private static func assetPath(_ model: String) -> String {
        model.hasPrefix("/") ? String(model.dropFirst()) : model
    }

    /// `maps.js:127-144`. A pivot group carries the object's world placement, and the model
    /// inside it is tipped upright by 90° about X — glTF is authored Y-up, this world is Z-up.
    /// User rotation is negated because world rotations are clockwise while render space is not.
    private static func transform(for key: PlacementKey) -> Float4x4 {
        Float4x4.translation(SIMD3(Float(key.x), Float(-key.y), Float(key.z)))
            * Float4x4.rotationZ(-Float(key.rotation) * degToRad)
            * Float4x4.scale(SIMD3(repeating: Float(key.scale)))
            * Float4x4.rotationX(.pi / 2)
    }

    /// Where the transform puts the model's own origin — its translation column. Not the centre
    /// of the geometry, which is not known until the model loads, but it is the placed point the
    /// map editor positioned and close enough to sort a load order by.
    private static func origin(of transform: Float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }
}
