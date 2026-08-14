import simd

/// An axis-aligned box. Used two ways: in a model's own space, where `GLTFLoader` has already
/// baked the node transforms into the vertices, and in render space once a placement's transform
/// has been applied to it.
struct BoundingBox {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    /// Inverted bounds, so the first `expand` sets both ends.
    static let empty = BoundingBox(min: SIMD3(repeating: .greatestFiniteMagnitude),
                                   max: SIMD3(repeating: -.greatestFiniteMagnitude))

    var isEmpty: Bool { min.x > max.x }

    mutating func expand(_ point: SIMD3<Float>) {
        min = simd.min(min, point)
        max = simd.max(max, point)
    }

    /// The box's eight corners run through `transform`, and the sphere is drawn round the
    /// result. Conservative twice over — the corners of a rotated box overshoot the geometry,
    /// and a sphere overshoots the box — which is what a culling test wants: it may say "maybe
    /// visible" about something that is not, but never the reverse.
    func boundingSphere(transformedBy transform: Float4x4) -> BoundingSphere? {
        guard !isEmpty else { return nil }

        var world = BoundingBox.empty
        for i in 0..<8 {
            let corner = SIMD3(i & 1 == 0 ? min.x : max.x,
                               i & 2 == 0 ? min.y : max.y,
                               i & 4 == 0 ? min.z : max.z)
            let transformed = transform * SIMD4(corner, 1)
            world.expand(SIMD3(transformed.x, transformed.y, transformed.z))
        }

        let center = (world.min + world.max) * 0.5
        return BoundingSphere(center: center, radius: simd_length(world.max - center))
    }
}

struct BoundingSphere {
    var center: SIMD3<Float>
    var radius: Float
}

/// The six clipping planes of a view-projection matrix, for deciding whether a prop is worth
/// encoding a draw call for.
///
/// Extracted the Gribb–Hartmann way: each plane is a sum or difference of two *rows* of the
/// matrix, which works for any projection without needing to know how it was built. That matters
/// here because the same test serves two very different frusta — the player's camera, and the
/// spotlight's shadow cone (`Lighting.viewProjection`). A prop outside the light's frustum casts
/// nothing into the shadow map, so both passes cull with the matrix they are about to draw with.
///
/// Metal's clip volume is `-w ≤ x,y ≤ w` and `0 ≤ z ≤ w` — note the near plane is `row2` alone,
/// not `row3 + row2`, which is the OpenGL form and would place it half a frustum too far back.
struct Frustum {
    private let left: SIMD4<Float>
    private let right: SIMD4<Float>
    private let bottom: SIMD4<Float>
    private let top: SIMD4<Float>
    private let near: SIMD4<Float>
    private let far: SIMD4<Float>

    init(viewProjection m: Float4x4) {
        // `simd_float4x4` is column-major, so a row has to be gathered across the columns.
        let row0 = SIMD4(m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x)
        let row1 = SIMD4(m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y)
        let row2 = SIMD4(m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z)
        let row3 = SIMD4(m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w)

        left = Self.normalized(row3 + row0)
        right = Self.normalized(row3 - row0)
        bottom = Self.normalized(row3 + row1)
        top = Self.normalized(row3 - row1)
        near = Self.normalized(row2)
        far = Self.normalized(row3 - row2)
    }

    /// Scales the plane so `xyz` is a unit normal, which is what lets the sphere test compare
    /// the signed distance against a radius in world units.
    private static func normalized(_ plane: SIMD4<Float>) -> SIMD4<Float> {
        let length = simd_length(SIMD3(plane.x, plane.y, plane.z))
        return length > 0 ? plane / length : plane
    }

    /// False only when the sphere is wholly outside one plane — the cheap, conservative test.
    /// A sphere straddling two planes near a corner can pass while being outside the frustum;
    /// that costs one wasted draw, and the exact test costs more than it saves.
    ///
    /// The centre goes in homogeneous, so `plane · centre` is one four-wide dot that picks up
    /// the plane's `w` on its own rather than a three-wide dot and an add.
    func intersects(_ sphere: BoundingSphere) -> Bool {
        let center = SIMD4(sphere.center, 1)
        let reach = -sphere.radius
        return simd_dot(left, center) >= reach && simd_dot(right, center) >= reach
            && simd_dot(bottom, center) >= reach && simd_dot(top, center) >= reach
            && simd_dot(near, center) >= reach && simd_dot(far, center) >= reach
    }
}
