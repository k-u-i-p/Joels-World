import Foundation
import simd

/// Fast 2-bone inverse kinematics. Direct port of `solve2BoneIK` (`characters.js:278-316`)
/// and its companion `pointLimbSegment`.
enum IKSolver {

    /// Returns the elbow/knee position for a two-segment limb reaching `end` from `start`.
    ///
    /// `end` is clamped **in place** when the target is out of reach or too close, exactly as
    /// the JS mutates the shared target vector — the caller then draws the hand/foot at the
    /// clamped position, which is what keeps limbs from detaching at extremes.
    ///
    /// `bendingNormal` locks the articulation plane so elbows and knees can never flip.
    static func solve(start: SIMD3<Float>,
                      end: inout SIMD3<Float>,
                      l1: Float,
                      l2: Float,
                      bendingNormal: SIMD3<Float>) -> SIMD3<Float> {
        var delta = end - start
        var distance = simd_length(delta)

        let maxReach = l1 + l2 - 0.01
        let minReach = abs(l1 - l2) + 0.01

        if distance > maxReach {
            delta = normalizedOrZero(delta) * maxReach
            end = start + delta
            distance = maxReach
        } else if distance < minReach {
            // Prevent a collapsing singularity by forcing a minimum separation.
            if distance < 0.001 { delta = SIMD3(0, 0, 1) }
            delta = normalizedOrZero(delta) * minReach
            end = start + delta
            distance = minReach
        }

        // Law of cosines for the interior angle at the root joint.
        var cosTheta = (l1 * l1 + distance * distance - l2 * l2) / (2 * l1 * distance)
        cosTheta = clampf(cosTheta, -1, 1)
        let theta = acos(cosTheta)

        let direction = normalizedOrZero(delta)
        return start + rotate(direction, axis: bendingNormal, angle: theta) * l1
    }

    /// Places a capsule so its +Y axis spans `start`→`end`, centred between them.
    /// Returns `nil` for degenerate spans, matching the JS early-out at `dist < 0.1`.
    static func segmentTransform(start: SIMD3<Float>, end: SIMD3<Float>) -> Float4x4? {
        let delta = end - start
        let distance = simd_length(delta)
        guard distance >= 0.1 else { return nil }

        let midpoint = start + delta * 0.5
        let rotation = rotationFromUnitY(to: delta / distance)
        return Float4x4.translation(midpoint) * rotation
    }

    /// Rotation taking +Y onto `direction`. Port of `Quaternion.setFromUnitVectors`, including
    /// its antiparallel special case (a limb pointing straight down would otherwise be NaN).
    static func rotationFromUnitY(to direction: SIMD3<Float>) -> Float4x4 {
        Float4x4(quaternionFromUnitY(to: direction))
    }

    /// A **full orthonormal basis** with +Y along `direction`, rolled so that +Z leans towards
    /// `reference`.
    ///
    /// `rotationFromUnitY` pins one axis and leaves the rotation about it undefined — whatever
    /// the shortest-arc quaternion happens to produce, which swings about wildly as the limb
    /// moves. That is fine for a capsule, which is round, and useless for anything with a front
    /// and a back. It is why the hand was a mitt revolved about the wrist for a whole session:
    /// a thumb would have spun.
    ///
    /// `reference` only has to be *not parallel* to the direction; the component along it is
    /// projected out. The arms pass their own bending normal — the vector the elbow already
    /// articulates about — so the palm faces the way the elbow bends, which is what a palm does.
    static func basis(alongY direction: SIMD3<Float>,
                      rolledTowards reference: SIMD3<Float>) -> Float4x4 {
        let y = normalizedOrZero(direction)
        guard simd_length(y) > 1e-6 else { return matrix_identity_float4x4 }

        var z = reference - y * simd_dot(reference, y)
        if simd_length(z) < 1e-4 {
            // Degenerate: the reference lies along the limb. Any perpendicular will do, and the
            // roll it produces is arbitrary but at least continuous.
            let fallback: SIMD3<Float> = abs(y.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
            z = fallback - y * simd_dot(fallback, y)
        }
        z = normalizedOrZero(z)
        let x = simd_cross(y, z)

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4(x, 0)
        matrix.columns.1 = SIMD4(y, 0)
        matrix.columns.2 = SIMD4(z, 0)
        return matrix
    }

    static func quaternionFromUnitY(to direction: SIMD3<Float>) -> simd_quatf {
        let from = SIMD3<Float>(0, 1, 0)
        var r = simd_dot(from, direction) + 1

        var x: Float, y: Float, z: Float
        if r < .ulpOfOne {
            r = 0
            if abs(from.x) > abs(from.z) {
                x = -from.y; y = from.x; z = 0
            } else {
                x = 0; y = -from.z; z = from.y
            }
        } else {
            x = from.y * direction.z - from.z * direction.y
            y = from.z * direction.x - from.x * direction.z
            z = from.x * direction.y - from.y * direction.x
        }

        let q = simd_quatf(ix: x, iy: y, iz: z, r: r)
        let length = simd_length(q.vector)
        return length > 1e-8 ? simd_quatf(vector: q.vector / length) : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    }

    // MARK: - Helpers

    /// Rodrigues rotation — the equivalent of `Vector3.applyAxisAngle`.
    private static func rotate(_ v: SIMD3<Float>, axis: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let k = normalizedOrZero(axis)
        let c = cos(angle), s = sin(angle)
        return v * c + simd_cross(k, v) * s + k * simd_dot(k, v) * (1 - c)
    }

    private static func normalizedOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(v)
        return length > 1e-8 ? v / length : .zero
    }
}
