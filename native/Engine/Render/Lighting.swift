import simd

/// CPU mirror of `SceneUniforms` in `Shaders.metal`. Every member is 16-byte aligned, so both
/// sides agree without explicit padding.
struct SceneUniforms {
    var view: Float4x4
    var projection: Float4x4
    var inverseProjection: Float4x4
    var lightViewProjection: Float4x4
    var cameraPosition: SIMD4<Float>
    var lightPosition: SIMD4<Float>
    var lightDirection: SIMD4<Float>
    /// x = ambient intensity, y = spot intensity, z = cos(cone), w = cos(penumbra cone).
    var lightParams: SIMD4<Float>
    /// x = 1 / shadow map size, y = depth bias, z = shadows enabled, w unused.
    var shadowParams: SIMD4<Float>
    /// x = near, y = far, zw = viewport size in pixels.
    var cameraParams: SIMD4<Float>
    /// xyz = the ambient scale on a straight-down-facing surface; the sky half is 1.
    var ambientGround: SIMD4<Float>
}

/// Port of the light rig in `main.js:47-61` and its per-frame tracking at `main.js:613-616`.
///
/// One white ambient light plus one spotlight that hovers 700 units "south" of, and 1500 above,
/// whatever the camera is looking at — so the shadows always radiate away from the viewer as
/// the player walks. `decay` and `distance` are both 0 in the JS, which switches off three.js's
/// distance attenuation entirely: brightness depends only on the cone, never on range.
struct SceneLighting {
    static let ambientIntensity: Float = 1.5
    static let spotIntensity: Float = 2.0
    static let coneAngle: Float = .pi / 4
    static let penumbra: Float = 0.1

    /// **The ground half of the hemisphere ambient.** `ambientIntensity` is the sky half and is
    /// unchanged, so this is the only new number: what a surface facing straight down receives,
    /// as a fraction. A vertical face — a wall, the side of a trunk — sits at the midpoint,
    /// 0.72, which is the whole effect. The JS has no hemisphere light and this is a deliberate
    /// departure from it; there is nothing in `main.js` to check this against.
    ///
    /// Very slightly warm, because a bounce off tarmac and grass is not the same white as the
    /// sky. Small enough not to move the palette — set it to 1,1,1 to make it purely a
    /// brightness ramp.
    static let ambientGround = SIMD3<Float>(0.47, 0.45, 0.42)

    static let shadowMapSize = 1024
    static let shadowNear: Float = 1000
    static let shadowFar: Float = 4000

    /// The light sits this far behind (screen-down from) and above the focus point.
    static let offsetY: Float = -700
    static let height: Float = 1500

    /// Nudge in light-clip depth applied before the shadow comparison. three.js leaves
    /// `shadow.bias` at 0 and relies on back-face rendering alone; the shadow pass here culls
    /// front faces the same way, and this only mops up the residual acne on the ground plane,
    /// which is nearly parallel to the light's far plane.
    static let depthBias: Float = 0.0008

    private(set) var position = SIMD3<Float>(0, 0, height)
    private(set) var target = SIMD3<Float>(0, 0, 0)
    /// Unit vector from the target towards the light — what three.js stores as
    /// `spotLight.direction` and compares the fragment's light vector against.
    private(set) var direction = SIMD3<Float>(0, 0, 1)
    private(set) var viewProjection = matrix_identity_float4x4

    /// `cameraTarget` is the camera's focus point in *render* space (Y already negated).
    mutating func update(cameraTarget: SIMD2<Float>) {
        position = SIMD3(cameraTarget.x, cameraTarget.y + Self.offsetY, Self.height)
        target = SIMD3(cameraTarget.x, cameraTarget.y, 0)
        direction = normalize(position - target)

        // three.js `SpotLightShadow`: a perspective camera whose vertical FOV is twice the cone
        // angle, aspect 1, spanning `shadow.camera.near ... far`. Its `up` is the default +Y.
        let view = Float4x4.lookAt(eye: position, center: target, up: SIMD3(0, 1, 0))
        let projection = Float4x4.perspective(fovYRadians: 2 * Self.coneAngle,
                                              aspect: 1,
                                              near: Self.shadowNear,
                                              far: Self.shadowFar)
        viewProjection = projection * view
    }

    var coneCos: Float { cos(Self.coneAngle) }
    var penumbraCos: Float { cos(Self.coneAngle * (1 - Self.penumbra)) }

    func uniforms(camera: Camera, viewport: SIMD2<Float>, shadowsEnabled: Bool) -> SceneUniforms {
        SceneUniforms(
            view: camera.view,
            projection: camera.projection,
            inverseProjection: camera.projection.inverse,
            lightViewProjection: viewProjection,
            cameraPosition: SIMD4(camera.eye, 1),
            lightPosition: SIMD4(position, 1),
            lightDirection: SIMD4(direction, 0),
            lightParams: SIMD4(Self.ambientIntensity, Self.spotIntensity, coneCos, penumbraCos),
            shadowParams: SIMD4(1 / Float(Self.shadowMapSize),
                                Self.depthBias,
                                shadowsEnabled ? 1 : 0,
                                0),
            cameraParams: SIMD4(camera.near, camera.far, viewport.x, viewport.y),
            ambientGround: SIMD4(Self.ambientGround, 0)
        )
    }
}

/// Screen-space ambient occlusion settings, matching `main.js:74-77`.
enum SSAOSettings {
    static let kernelSize = 32
    static let kernelRadius: Float = 32
    static let minDistance: Float = 0.000001
    static let maxDistance: Float = 1.5

    /// Port of `SSAOPass.generateSampleKernel`. The JS seeds this from `Math.random()`; a fixed
    /// sequence is used here so the AO term is identical from run to run, which makes
    /// screenshot comparison against the web build meaningful.
    static func kernel() -> [SIMD4<Float>] {
        var random = SplitMix64(seed: 0x5EED_1234_ABCD_0001)
        var samples: [SIMD4<Float>] = []
        samples.reserveCapacity(kernelSize)

        for i in 0..<kernelSize {
            var sample = SIMD3<Float>(random.nextUnit() * 2 - 1,
                                      random.nextUnit() * 2 - 1,
                                      random.nextUnit())
            let length = simd_length(sample)
            sample = length > 0 ? sample / length : SIMD3(0, 0, 1)

            // Cluster samples towards the origin, exactly as the JS lerps 0.1 → 1 over i².
            let t = Float(i) / Float(kernelSize)
            sample *= 0.1 + (1 - 0.1) * (t * t)

            samples.append(SIMD4(sample, 0))
        }
        return samples
    }
}

/// Small deterministic PRNG, so the AO kernel is stable across launches.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func nextUnit() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return Float(z >> 40) / Float(1 << 24)
    }
}
