import Foundation
import simd

/// CPU-side geometry, ready to be uploaded as a `GPUMesh`.
struct MeshData {
    var vertices: [MeshVertex]
    var indices: [UInt32]
}

/// Procedural primitives matching the three.js geometries the character rig is built from
/// (`characters.js:791-901`).
///
/// All primitives are generated with their long axis along **+Y**, exactly like three.js, so
/// the rig's `pointLimbSegment` port can keep using the same (0,1,0) reference vector.
enum MeshFactory {

    /// Port of `THREE.CapsuleGeometry(radius, length, capSegments, radialSegments)`.
    ///
    /// three.js builds this as a lathe of a two-arc profile: a bottom cap from the south pole
    /// round to the equator, a straight cylinder wall of `length`, then a top cap. Total
    /// height is `length + 2 * radius`.
    static func capsule(radius: Float,
                        length: Float,
                        capSegments: Int = 8,
                        radialSegments: Int = 12) -> MeshData {
        let half = length / 2
        var profile: [SIMD2<Float>] = []

        // Bottom cap: angle 1.5π → 2π, centred on (0, -half).
        let capDivisions = max(2, capSegments * 2)
        for i in 0...capDivisions {
            let t = Float(i) / Float(capDivisions)
            let angle = Float.pi * 1.5 + t * (Float.pi * 0.5)
            profile.append(SIMD2(radius * cos(angle), -half + radius * sin(angle)))
        }
        // Cylinder wall: straight line up the side (the arc endpoints already sit on it).
        profile.append(SIMD2(radius, half))
        // Top cap: angle 0 → 0.5π, centred on (0, +half).
        for i in 1...capDivisions {
            let t = Float(i) / Float(capDivisions)
            let angle = t * (Float.pi * 0.5)
            profile.append(SIMD2(radius * cos(angle), half + radius * sin(angle)))
        }

        return lathe(profile: profile, radialSegments: radialSegments)
    }

    /// Revolves a hand-authored silhouette around the +Y axis.
    ///
    /// The three.js primitives can describe a limb but not a body: a torso is a capsule squashed
    /// in two axes, which gives a character no shoulders, no waist and no hips. This is the way
    /// out — `profile` is a list of `(height, radius)` pairs read bottom to top, and the shape
    /// between them is whatever the artist wrote down. Give it a zero radius at each end to close
    /// the solid; leave one open and you get a tube.
    ///
    /// The profile is smooth-shaded, so keep the steps small where the curvature is high or the
    /// shoulder line will facet.
    static func revolved(profile: [(y: Float, radius: Float)], radialSegments: Int = 20) -> MeshData {
        lathe(profile: profile.map { SIMD2($0.radius, $0.y) }, radialSegments: radialSegments)
    }

    /// **A lathe whose cross-section is allowed to change shape as it climbs**, not just size:
    /// an ellipse per ring, with its two half-axes given separately.
    ///
    /// `revolved` plus a single `applyScale` — which is how the torso and the pelvis were both
    /// built — can only produce **one** aspect ratio for the whole solid. Every ring is the same
    /// ellipse scaled up and down, so a torso wide enough at the shoulders is necessarily deep
    /// enough there too, and one thin enough at the waist is thin everywhere. That is a barrel,
    /// and no amount of adjusting the silhouette in one plane fixes it, because the other plane
    /// is following along multiplied by a constant.
    ///
    /// A body is not like that in the one place it matters most. Shoulders are **wide and
    /// shallow** and a chest is **narrower and deep**, and the ratio between the two changes
    /// more over the twenty units of a torso than the size does. So each ring carries both.
    ///
    /// `halfDepth` is on local **X** and `halfWidth` on local **Z**, which is the same pair
    /// `applyScale(SIMD3(0.62, 1, 1.12))` used to act on — so a profile ported from the old form
    /// is `(y, radius × 0.62, radius × 1.12)` and comes out identical. Winding, vertex order and
    /// the shared seam all match `lathe`, because it is `lathe` with the radius made a function
    /// of the angle.
    static func revolvedElliptical(profile: [(y: Float, halfDepth: Float, halfWidth: Float)],
                                   radialSegments: Int = 24) -> MeshData {
        let segments = max(3, radialSegments)
        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(profile.count * segments)

        for (row, ring) in profile.enumerated() {
            for segment in 0..<segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                // `lathe` places (r sin φ, y, r cos φ); this is that with a different r per axis.
                let position = SIMD3(ring.halfDepth * sin(phi), ring.y, ring.halfWidth * cos(phi))
                vertices.append(MeshVertex(position: position, normal: .zero,
                                           uv: SIMD2(Float(segment) / Float(segments),
                                                     Float(row) / Float(max(profile.count - 1, 1)))))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(max(profile.count - 1, 0) * segments * 6)
        for row in 0..<max(profile.count - 1, 0) {
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = UInt32(row * segments + segment)
                let b = UInt32(row * segments + next)
                let c = UInt32((row + 1) * segments + next)
                let d = UInt32((row + 1) * segments + segment)
                indices.append(contentsOf: [a, d, c, a, c, b])
            }
        }

        var mesh = MeshData(vertices: vertices, indices: indices)
        recomputeNormals(&mesh)
        return mesh
    }

    /// One limb segment: a shaft tapering from `radiusStart` at `−length/2` to `radiusEnd` at
    /// `+length/2`, with each end either domed *past* its joint or closed *at* it.
    ///
    /// `capsule` plus `applyTaper` gets close but cannot express the second case, and the
    /// difference matters. `applyTaper` narrows a hemispherical cap without shortening it, so a
    /// tapered capsule still reaches a full untapered radius beyond its own joint. At a shoulder,
    /// an elbow or a knee that is exactly what you want — the overshoot buries itself in the
    /// neighbouring segment and the surfaces blend. At a **wrist** it is a bug: the forearm
    /// reaches three units past the hand and wears it like a bracelet.
    ///
    /// - Parameters:
    ///   - domeStart/domeEnd: `true` puts a hemisphere of the local radius beyond the joint, so a
    ///     joint sphere of that radius sits tangent to it. `false` tucks a rounded end inside, so
    ///     the segment finishes flush with the joint plane and whatever comes next owns
    ///     everything past it.
    static func limb(length: Float,
                     radiusStart: Float,
                     radiusEnd: Float,
                     domeStart: Bool = true,
                     domeEnd: Bool = true,
                     radialSegments: Int = 14,
                     capSegments: Int = 6) -> MeshData {
        let half = length / 2
        let steps = max(2, capSegments)
        var profile: [SIMD2<Float>] = []

        // Bottom end.
        if domeStart {
            // A hemisphere centred on the joint, bulging past it.
            for i in 0...steps {
                let angle = Float.pi / 2 * (Float(i) / Float(steps) - 1)
                profile.append(SIMD2(radiusStart * cos(angle), -half + radiusStart * sin(angle)))
            }
        } else {
            // A quarter-ellipse tucked inside, closing exactly on the joint plane.
            let inset = radiusStart * 0.9
            for i in 0...steps {
                let angle = Float.pi / 2 * (Float(i) / Float(steps) - 1)
                profile.append(SIMD2(radiusStart * cos(angle), -half + inset * (1 + sin(angle))))
            }
        }

        // Top end.
        if domeEnd {
            for i in 0...steps {
                let angle = Float.pi / 2 * (Float(i) / Float(steps))
                profile.append(SIMD2(radiusEnd * cos(angle), half + radiusEnd * sin(angle)))
            }
        } else {
            let inset = radiusEnd * 0.9
            for i in 0...steps {
                let angle = Float.pi / 2 * (Float(i) / Float(steps))
                profile.append(SIMD2(radiusEnd * cos(angle), half - inset * (1 - sin(angle))))
            }
        }

        return lathe(profile: profile, radialSegments: radialSegments)
    }

    /// Stitches a stack of rings into one closed surface, with a point at each end.
    ///
    /// **A lathe cannot describe a hand.** Everything else on this body is round about an axis,
    /// and `revolved` is exactly the right tool for a torso or a leg; a hand is flat one way,
    /// wide the other, and has four fingers cut into its far half. That is three things a single
    /// radius per height cannot say. This is the same idea with the radius replaced by a whole
    /// ring — the caller decides where every point of every ring goes, and this only joins them
    /// up.
    ///
    /// Every ring must have the same number of points, wound the way `lathe` winds its own so
    /// that a lofted part and a revolved one can sit in the same mesh without one of them being
    /// inside-out. The caller's UVs are kept: a loft is used where the parameterisation *means*
    /// something, which is the whole reason it is not a lathe.
    ///
    /// `capStart` and `capEnd` close the ends. Passing nil leaves a tube open, which is only
    /// ever right when something else covers the hole.
    static func loft(rings: [[MeshVertex]],
                     capStart: MeshVertex? = nil,
                     capEnd: MeshVertex? = nil) -> MeshData {
        guard let segments = rings.first?.count, segments >= 3, rings.count >= 2,
              rings.allSatisfy({ $0.count == segments }) else {
            return MeshData(vertices: [], indices: [])
        }

        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(rings.count * segments + 2)
        for ring in rings { vertices.append(contentsOf: ring) }

        var indices: [UInt32] = []
        for row in 0..<(rings.count - 1) {
            let lower = row * segments, upper = (row + 1) * segments
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = UInt32(lower + segment), b = UInt32(lower + next)
                let c = UInt32(upper + next), d = UInt32(upper + segment)
                indices.append(contentsOf: [a, d, c, a, c, b])
            }
        }

        if let capStart {
            let apex = UInt32(vertices.count)
            vertices.append(capStart)
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                indices.append(contentsOf: [apex, UInt32(segment), UInt32(next)])
            }
        }
        if let capEnd {
            let apex = UInt32(vertices.count)
            vertices.append(capEnd)
            let last = (rings.count - 1) * segments
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                indices.append(contentsOf: [apex, UInt32(last + next), UInt32(last + segment)])
            }
        }

        var mesh = MeshData(vertices: vertices, indices: indices)
        recomputeNormals(&mesh)
        return mesh
    }

    /// Concatenates several meshes into one, so a shape made of parts costs one draw call.
    ///
    /// The character rig is drawn twice per character — scene and shadow map — and every part is
    /// a separate draw. A hand built as a palm, a finger block and a thumb would be three, times
    /// two, times everybody on the map. Merged it is one, and the parts are rigid relative to
    /// each other anyway, so nothing is lost.
    static func merge(_ meshes: [MeshData]) -> MeshData {
        var out = MeshData(vertices: [], indices: [])
        for mesh in meshes {
            let offset = UInt32(out.vertices.count)
            out.vertices.append(contentsOf: mesh.vertices)
            out.indices.append(contentsOf: mesh.indices.map { $0 + offset })
        }
        return out
    }

    /// Moves a mesh in its own space, for assembling a composite out of primitives.
    static func translated(_ mesh: MeshData, by offset: SIMD3<Float>) -> MeshData {
        var copy = mesh
        for index in copy.vertices.indices { copy.vertices[index].position += offset }
        return copy
    }

    /// Mirrors a mesh through the YZ plane — a left hand from a right one.
    ///
    /// Negating X flips the winding of every triangle, so the index order is reversed too;
    /// without that the mirrored copy is inside-out and backface culling eats it. Normals flip
    /// with the positions for the same reason.
    static func mirroredInX(_ mesh: MeshData) -> MeshData {
        var copy = mesh
        for index in copy.vertices.indices {
            copy.vertices[index].position.x = -copy.vertices[index].position.x
            copy.vertices[index].normal.x = -copy.vertices[index].normal.x
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(copy.indices.count)
        var i = 0
        while i + 2 < copy.indices.count {
            indices.append(contentsOf: [copy.indices[i], copy.indices[i + 2], copy.indices[i + 1]])
            i += 3
        }
        copy.indices = indices
        return copy
    }

    /// Port of `THREE.SphereGeometry(radius, widthSegments, heightSegments)`.
    static func sphere(radius: Float, widthSegments: Int = 12, heightSegments: Int = 12) -> MeshData {
        var profile: [SIMD2<Float>] = []
        for i in 0...heightSegments {
            // From the south pole up to the north pole.
            let angle = -Float.pi / 2 + Float.pi * Float(i) / Float(heightSegments)
            profile.append(SIMD2(radius * cos(angle), radius * sin(angle)))
        }
        return lathe(profile: profile, radialSegments: widthSegments)
    }

    /// Port of `THREE.BoxGeometry(width, height, depth)`, centred on the origin.
    static func box(width: Float, height: Float, depth: Float) -> MeshData {
        let hx = width / 2, hy = height / 2, hz = depth / 2
        let faces: [(normal: SIMD3<Float>, corners: [SIMD3<Float>])] = [
            (SIMD3(0, 0, 1),  [SIMD3(-hx, -hy, hz), SIMD3(hx, -hy, hz), SIMD3(hx, hy, hz), SIMD3(-hx, hy, hz)]),
            (SIMD3(0, 0, -1), [SIMD3(hx, -hy, -hz), SIMD3(-hx, -hy, -hz), SIMD3(-hx, hy, -hz), SIMD3(hx, hy, -hz)]),
            (SIMD3(1, 0, 0),  [SIMD3(hx, -hy, -hz), SIMD3(hx, hy, -hz), SIMD3(hx, hy, hz), SIMD3(hx, -hy, hz)]),
            (SIMD3(-1, 0, 0), [SIMD3(-hx, hy, -hz), SIMD3(-hx, -hy, -hz), SIMD3(-hx, -hy, hz), SIMD3(-hx, hy, hz)]),
            (SIMD3(0, 1, 0),  [SIMD3(-hx, hy, -hz), SIMD3(-hx, hy, hz), SIMD3(hx, hy, hz), SIMD3(hx, hy, -hz)]),
            (SIMD3(0, -1, 0), [SIMD3(-hx, -hy, hz), SIMD3(-hx, -hy, -hz), SIMD3(hx, -hy, -hz), SIMD3(hx, -hy, hz)]),
        ]

        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []
        let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]

        for face in faces {
            let base = UInt32(vertices.count)
            for (corner, position) in face.corners.enumerated() {
                vertices.append(MeshVertex(position: position, normal: face.normal, uv: uvs[corner]))
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        return MeshData(vertices: vertices, indices: indices)
    }

    /// Port of `THREE.CylinderGeometry(radiusTop, radiusBottom, height, radialSegments)` —
    /// long axis along +Y, centred on the origin, with flat caps.
    ///
    /// The wall is smooth-shaded around the circumference like three.js's, but the caps get
    /// their own vertices so the rim stays a hard edge.
    static func cylinder(radiusTop: Float,
                         radiusBottom: Float,
                         height: Float,
                         radialSegments: Int = 8) -> MeshData {
        let segments = max(3, radialSegments)
        let half = height / 2
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []

        // Wall. The slope of the profile decides the normal's Y component, so a cone's
        // sides light correctly rather than as if they were vertical.
        let slope = (radiusBottom - radiusTop) / height
        for row in 0...1 {
            let radius = row == 0 ? radiusBottom : radiusTop
            let y = row == 0 ? -half : half
            for segment in 0...segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                let sinPhi = sin(phi), cosPhi = cos(phi)
                let normal = simd_normalize(SIMD3(sinPhi, slope, cosPhi))
                vertices.append(MeshVertex(position: SIMD3(radius * sinPhi, y, radius * cosPhi),
                                           normal: normal,
                                           uv: SIMD2(Float(segment) / Float(segments), Float(row))))
            }
        }
        for segment in 0..<segments {
            let a = UInt32(segment)
            let b = UInt32(segment + 1)
            let c = UInt32(segments + 1 + segment + 1)
            let d = UInt32(segments + 1 + segment)
            indices.append(contentsOf: [a, c, b, a, d, c])
        }

        // Caps, each a triangle fan around its own centre vertex.
        func addCap(radius: Float, y: Float, normal: SIMD3<Float>) {
            guard radius > 0 else { return }
            let centre = UInt32(vertices.count)
            vertices.append(MeshVertex(position: SIMD3(0, y, 0), normal: normal, uv: SIMD2(0.5, 0.5)))
            for segment in 0...segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                vertices.append(MeshVertex(position: SIMD3(radius * sin(phi), y, radius * cos(phi)),
                                           normal: normal,
                                           uv: SIMD2(sin(phi) * 0.5 + 0.5, cos(phi) * 0.5 + 0.5)))
            }
            for segment in 0..<segments {
                let a = centre + 1 + UInt32(segment)
                let b = centre + 1 + UInt32(segment + 1)
                indices.append(contentsOf: normal.y > 0 ? [centre, a, b] : [centre, b, a])
            }
        }
        addCap(radius: radiusTop, y: half, normal: SIMD3(0, 1, 0))
        addCap(radius: radiusBottom, y: -half, normal: SIMD3(0, -1, 0))

        return MeshData(vertices: vertices, indices: indices)
    }

    /// Port of `THREE.CircleGeometry(radius, segments)` — a fan on the XY plane facing +Z.
    static func circle(radius: Float, segments: Int = 16) -> MeshData {
        let count = max(3, segments)
        let normal = SIMD3<Float>(0, 0, 1)
        var vertices = [MeshVertex(position: .zero, normal: normal, uv: SIMD2(0.5, 0.5))]
        for segment in 0...count {
            let phi = Float(segment) / Float(count) * 2 * .pi
            vertices.append(MeshVertex(position: SIMD3(radius * cos(phi), radius * sin(phi), 0),
                                       normal: normal,
                                       uv: SIMD2(cos(phi) * 0.5 + 0.5, sin(phi) * 0.5 + 0.5)))
        }
        var indices: [UInt32] = []
        for segment in 0..<count {
            indices.append(contentsOf: [0, UInt32(segment + 1), UInt32(segment + 2)])
        }
        return MeshData(vertices: vertices, indices: indices)
    }

    /// Port of `THREE.TorusGeometry(radius, tube, radialSegments, tubularSegments)` — the ring
    /// lies in the XY plane with its hole along Z, matching three.js's default orientation.
    static func torus(radius: Float,
                      tube: Float,
                      radialSegments: Int = 8,
                      tubularSegments: Int = 6) -> MeshData {
        let radial = max(3, radialSegments)
        let tubular = max(3, tubularSegments)
        var vertices: [MeshVertex] = []
        var indices: [UInt32] = []

        for j in 0...radial {
            for i in 0...tubular {
                let u = Float(i) / Float(tubular) * 2 * .pi
                let v = Float(j) / Float(radial) * 2 * .pi
                let position = SIMD3((radius + tube * cos(v)) * cos(u),
                                     (radius + tube * cos(v)) * sin(u),
                                     tube * sin(v))
                let centre = SIMD3(radius * cos(u), radius * sin(u), 0)
                vertices.append(MeshVertex(position: position,
                                           normal: simd_normalize(position - centre),
                                           uv: SIMD2(Float(i) / Float(tubular), Float(j) / Float(radial))))
            }
        }

        for j in 1...radial {
            for i in 1...tubular {
                let a = UInt32((tubular + 1) * j + i - 1)
                let b = UInt32((tubular + 1) * (j - 1) + i - 1)
                let c = UInt32((tubular + 1) * (j - 1) + i)
                let d = UInt32((tubular + 1) * j + i)
                indices.append(contentsOf: [a, b, d, b, c, d])
            }
        }

        return MeshData(vertices: vertices, indices: indices)
    }

    /// Bakes a rotation into the geometry, matching `BufferGeometry.rotateX/rotateY/rotateZ`.
    /// The emote props lean on this: `beamGeo.rotateZ(π/2)` turns the laser cylinder to point
    /// along X before it is ever instanced (`emotes.js:91`).
    static func applyRotation(_ mesh: inout MeshData, _ rotation: Float4x4) {
        for index in mesh.vertices.indices {
            let position = rotation * SIMD4(mesh.vertices[index].position, 1)
            let normal = rotation * SIMD4(mesh.vertices[index].normal, 0)
            mesh.vertices[index].position = SIMD3(position.x, position.y, position.z)
            mesh.vertices[index].normal = simd_normalize(SIMD3(normal.x, normal.y, normal.z))
        }
    }

    /// Port of `THREE.PlaneGeometry(width, height)` — XY plane, facing +Z.
    static func plane(width: Float, height: Float) -> MeshData {
        let hx = width / 2, hy = height / 2
        let vertices = [
            MeshVertex(position: SIMD3(-hx, -hy, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 1)),
            MeshVertex(position: SIMD3( hx, -hy, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 1)),
            MeshVertex(position: SIMD3( hx,  hy, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(1, 0)),
            MeshVertex(position: SIMD3(-hx,  hy, 0), normal: SIMD3(0, 0, 1), uv: SIMD2(0, 0)),
        ]
        return MeshData(vertices: vertices, indices: [0, 1, 2, 0, 2, 3])
    }

    // `applyTaper` — the port of the closure at `characters.js:849` — used to live here. It
    // scaled a capsule's X and Z along its length, which narrows the hemispherical end caps
    // without shortening them, so a tapered limb still reached a full untapered radius past its
    // own joint. `limb(...)` above replaces it and controls both.

    /// Bakes a non-uniform scale into the geometry, matching `BufferGeometry.scale()` —
    /// normals are scaled by the inverse so they stay perpendicular to the squashed surface.
    static func applyScale(_ mesh: inout MeshData, _ s: SIMD3<Float>) {
        let inverse = SIMD3<Float>(s.x == 0 ? 1 : 1 / s.x,
                                   s.y == 0 ? 1 : 1 / s.y,
                                   s.z == 0 ? 1 : 1 / s.z)
        for index in mesh.vertices.indices {
            mesh.vertices[index].position *= s
            let normal = mesh.vertices[index].normal * inverse
            let length = simd_length(normal)
            mesh.vertices[index].normal = length > 1e-6 ? normal / length : SIMD3(0, 1, 0)
        }
    }

    // MARK: - Internals

    /// Revolves a 2D profile (x = radius, y = height) around the Y axis.
    ///
    /// The seam shares its vertices rather than duplicating them, so accumulated normals come
    /// out smooth all the way round. UVs are unused by the rig's flat-coloured materials.
    private static func lathe(profile: [SIMD2<Float>], radialSegments: Int) -> MeshData {
        let segments = max(3, radialSegments)
        let rows = profile.count
        guard rows >= 2 else { return MeshData(vertices: [], indices: []) }

        var vertices: [MeshVertex] = []
        vertices.reserveCapacity(rows * segments)

        for row in 0..<rows {
            let point = profile[row]
            for segment in 0..<segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                let position = SIMD3(point.x * sin(phi), point.y, point.x * cos(phi))
                let u = Float(segment) / Float(segments)
                let v = Float(row) / Float(rows - 1)
                vertices.append(MeshVertex(position: position, normal: .zero, uv: SIMD2(u, v)))
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((rows - 1) * segments * 6)

        for row in 0..<(rows - 1) {
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = UInt32(row * segments + segment)
                let b = UInt32(row * segments + next)
                let c = UInt32((row + 1) * segments + next)
                let d = UInt32((row + 1) * segments + segment)
                indices.append(contentsOf: [a, d, c, a, c, b])
            }
        }

        var mesh = MeshData(vertices: vertices, indices: indices)
        recomputeNormals(&mesh)
        return mesh
    }

    /// Area-weighted vertex normals, matching `BufferGeometry.computeVertexNormals()`.
    private static func recomputeNormals(_ mesh: inout MeshData) {
        var accumulated = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            i += 3
            let face = simd_cross(mesh.vertices[b].position - mesh.vertices[a].position,
                                  mesh.vertices[c].position - mesh.vertices[a].position)
            accumulated[a] += face
            accumulated[b] += face
            accumulated[c] += face
        }

        for index in mesh.vertices.indices {
            let length = simd_length(accumulated[index])
            mesh.vertices[index].normal = length > 1e-6
                ? accumulated[index] / length
                : SIMD3(0, 1, 0)
        }
    }
}
