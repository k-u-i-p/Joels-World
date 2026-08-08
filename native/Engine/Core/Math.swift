import simd

typealias Float4x4 = simd_float4x4

let degToRad: Float = .pi / 180

extension Float4x4 {
    static func translation(_ t: SIMD3<Float>) -> Float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> Float4x4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        return m
    }

    /// Rotation about the Z axis (the "up" axis in this game's world space).
    static func rotationZ(_ radians: Float) -> Float4x4 {
        let c = cos(radians), s = sin(radians)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(c, s, 0, 0)
        m.columns.1 = SIMD4(-s, c, 0, 0)
        return m
    }

    static func rotationX(_ radians: Float) -> Float4x4 {
        let c = cos(radians), s = sin(radians)
        var m = matrix_identity_float4x4
        m.columns.1 = SIMD4(0, c, s, 0)
        m.columns.2 = SIMD4(0, -s, c, 0)
        return m
    }

    static func rotationY(_ radians: Float) -> Float4x4 {
        let c = cos(radians), s = sin(radians)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(c, 0, -s, 0)
        m.columns.2 = SIMD4(s, 0, c, 0)
        return m
    }

    /// three.js `Euler` default order — `Object3D.rotation.set(x, y, z)` composes as X·Y·Z.
    static func eulerXYZ(_ x: Float, _ y: Float, _ z: Float) -> Float4x4 {
        rotationX(x) * rotationY(y) * rotationZ(z)
    }

    /// Right-handed perspective projection mapping z into [0, 1] (Metal's clip convention).
    static func perspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> Float4x4 {
        let y = 1 / tan(fovYRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        var m = Float4x4()
        m.columns.0 = SIMD4(x, 0, 0, 0)
        m.columns.1 = SIMD4(0, y, 0, 0)
        m.columns.2 = SIMD4(0, 0, z, -1)
        m.columns.3 = SIMD4(0, 0, z * near, 0)
        return m
    }

    /// Right-handed look-at view matrix.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> Float4x4 {
        let f = normalize(center - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(s.x, u.x, -f.x, 0)
        m.columns.1 = SIMD4(s.y, u.y, -f.y, 0)
        m.columns.2 = SIMD4(s.z, u.z, -f.z, 0)
        m.columns.3 = SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        return m
    }
}

func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(v, lo), hi)
}

func clampd(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(v, lo), hi)
}

/// The sRGB electro-optical transfer function — the "gamma" curve. Port of three.js
/// `SRGBToLinear` in `ColorManagement.js`.
func srgbToLinear(_ c: Float) -> Float {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

/// Inverse of `srgbToLinear` — the encode the `_srgb` render targets apply on write.
func linearToSRGB(_ c: Float) -> Float {
    c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
}

/// Parses `#rrggbb` into **linear** 0...1 components.
///
/// Every hex colour in this game (character colours, `background_color`) is authored in sRGB,
/// and three.js converts it on the way in — `ColorManagement.enabled` has defaulted to true
/// since r152, and `new THREE.Color('#rrggbb')` therefore lands in the linear working space.
/// Lighting has to happen in linear space to match, and the render targets encode back to sRGB
/// on write.
func parseHexColor(_ hex: String?) -> SIMD3<Float> {
    guard var s = hex else { return SIMD3(1, 1, 1) }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return SIMD3(1, 1, 1) }
    return SIMD3(
        srgbToLinear(Float((value >> 16) & 0xFF) / 255),
        srgbToLinear(Float((value >> 8) & 0xFF) / 255),
        srgbToLinear(Float(value & 0xFF) / 255)
    )
}
