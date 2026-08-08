import simd

/// Port of the camera block in `main.js:545-621`.
///
/// World space is Y-down; render space negates Y. The camera orbits the player on a sphere
/// defined by pitch/yaw at a distance chosen so that, looking straight down, one world unit
/// maps to one screen point — matching the web build's framing.
struct Camera {
    /// Focus point in *world* coordinates (Y-down).
    var x: Double = 0
    var y: Double = 0
    var zoom: Double = 1

    /// Inertial offset applied when pushing into a wall.
    var springX: Double = 0
    var springY: Double = 0

    var pitch: Double = 0
    var yaw: Double = 0

    let fovDegrees: Float = 30
    let near: Float = 1
    let far: Float = 2000

    private(set) var viewProjection = matrix_identity_float4x4
    private(set) var inverseViewProjection = matrix_identity_float4x4
    private(set) var view = matrix_identity_float4x4
    private(set) var projection = matrix_identity_float4x4
    private(set) var eye = SIMD3<Float>(0, 0, 1)

    /// The focus point in *render* space (Y negated). The spotlight tracks this.
    var renderTarget: SIMD2<Float> { SIMD2(Float(x), Float(-y)) }

    mutating func setPitch(delta: Double) {
        pitch = min(max(0, pitch + delta), .pi / 2.1)
    }

    /// Recomputes the matrices. `viewport` is in points, matching the JS which uses CSS pixels.
    mutating func update(playerX: Double,
                         playerY: Double,
                         viewport: SIMD2<Float>,
                         mapData: MapData?) {
        let viewportWidth = Double(viewport.x)
        let viewportHeight = Double(viewport.y)

        x = playerX + springX
        // Bias the focus upward so the player sits lower in frame, leaving headroom.
        y = playerY - (viewportHeight / zoom * 0.15) + springY

        clampToMap(mapData: mapData, viewportWidth: viewportWidth, viewportHeight: viewportHeight)

        // Avoid gimbal lock when looking straight down.
        let effectivePitch = max(0.001, pitch)

        let fovRadians = fovDegrees * degToRad
        // three.js `camera.zoom` scales the frustum rather than moving the camera.
        let zoomedFov = 2 * atan(tan(fovRadians / 2) / Float(zoom))
        let orbitDistance = viewportHeight / (2 * tan(Double(fovRadians) / 2))

        let targetX = x
        let targetY = -y

        eye = SIMD3(
            Float(targetX + sin(yaw) * sin(effectivePitch) * orbitDistance),
            Float(targetY - cos(yaw) * sin(effectivePitch) * orbitDistance),
            Float(cos(effectivePitch) * orbitDistance)
        )

        let center = SIMD3<Float>(Float(targetX), Float(targetY), 0)
        let view = Float4x4.lookAt(eye: eye, center: center, up: SIMD3(0, 0, 1))
        let projection = Float4x4.perspective(fovYRadians: zoomedFov,
                                              aspect: viewport.x / max(viewport.y, 1),
                                              near: near,
                                              far: far)

        self.view = view
        self.projection = projection
        viewProjection = projection * view
        inverseViewProjection = viewProjection.inverse
    }

    /// Keeps the view inside the map, honouring `camera_permitted_offset`.
    private mutating func clampToMap(mapData: MapData?, viewportWidth: Double, viewportHeight: Double) {
        guard let mapData, mapData.width > 0, mapData.height > 0 else { return }

        let halfMapW = mapData.width / 2
        let halfMapH = mapData.height / 2
        let viewHalfW = (viewportWidth / zoom) / 2
        let viewHalfH = (viewportHeight / zoom) / 2

        var minX = -halfMapW + viewHalfW
        var maxX = halfMapW - viewHalfW
        var minY = -halfMapH + viewHalfH
        var maxY = halfMapH - viewHalfH

        if let offset = mapData.camera_permitted_offset {
            if let ox = offset.x {
                if ox < 0 { minX += ox }
                if ox > 0 { maxX += ox }
            }
            if let oy = offset.y {
                if oy < 0 { minY += oy }
                if oy > 0 { maxY += oy }
            }
            if let top = offset.top { minY -= top }
            if let bottom = offset.bottom { maxY += bottom }
            if let left = offset.left { minX -= left }
            if let right = offset.right { maxX += right }
        }

        x = minX <= maxX ? min(max(x, minX), maxX) : 0
        y = minY <= maxY ? min(max(y, minY), maxY) : 0
    }

    /// Projects a world point (Y-down) to screen points, the way `THREE.Vector3.project`
    /// followed by the viewport mapping at `characters.js:1243-1249` does.
    ///
    /// `ndc` is returned alongside so callers can apply the JS visibility test
    /// (`z <= 1 && |x| <= 1.3 && |y| <= 1.3`) without projecting twice.
    func project(worldX: Double, worldY: Double, z: Double,
                 viewport: SIMD2<Float>) -> (screen: SIMD2<Float>, ndc: SIMD3<Float>) {
        let clip = viewProjection * SIMD4<Float>(Float(worldX), Float(-worldY), Float(z), 1)
        let w = clip.w == 0 ? 1e-6 : clip.w
        let ndc = SIMD3(clip.x / w, clip.y / w, clip.z / w)
        let screen = SIMD2((ndc.x * 0.5 + 0.5) * viewport.x,
                           (-(ndc.y * 0.5) + 0.5) * viewport.y)
        return (screen, ndc)
    }

    /// Intersects the ray through an NDC point with the ground plane (render-space z = 0).
    /// Returns render-space XY, or nil when the ray points at or above the horizon.
    func unprojectToGroundPlane(ndc: SIMD2<Float>) -> SIMD2<Float>? {
        let nearPoint = unproject(SIMD3(ndc.x, ndc.y, 0))
        let farPoint = unproject(SIMD3(ndc.x, ndc.y, 1))

        let direction = farPoint - nearPoint
        if abs(direction.z) < 1e-6 { return nil }

        let t = -nearPoint.z / direction.z
        if t < 0 { return nil }

        let hit = nearPoint + direction * t
        return SIMD2(hit.x, hit.y)
    }

    private func unproject(_ ndc: SIMD3<Float>) -> SIMD3<Float> {
        let clip = SIMD4<Float>(ndc.x, ndc.y, ndc.z, 1)
        let world = inverseViewProjection * clip
        return SIMD3(world.x, world.y, world.z) / world.w
    }
}
