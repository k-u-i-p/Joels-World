#if DEBUG
import Foundation
import simd

/// `-emotedump`: poses every emote once at a fixed instant and logs the result.
///
/// This exists so Phase 6 can be checked the way Phases 2 and 3 were — against numbers read
/// out of the running web client, not against a screenshot. Because the clock, the elapsed
/// time and the character are all pinned, the same values can be produced in the browser by
/// stubbing `Date.now` and calling `emotes[name].updateLimbs3D` on a hand-built rig.
enum EmoteDump {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-emotedump")
    }

    /// Fixed inputs. `cry` reads the absolute clock rather than the emote's age, so the wall
    /// time has to be pinned too.
    private static let elapsed: Double = 1234
    private static let nowMs: Double = 1_700_000_000_000
    private static let rotationDegrees: Double = 45
    private static let worldPosition = SIMD3<Float>(100, -200, 0)

    static func run() {
        Log.world("emotedump: elapsed=\(Int(elapsed))ms now=\(Int(nowMs)) rot=\(Int(rotationDegrees))°")

        for name in Emotes.table.keys.sorted() {
            guard let definition = Emotes.table[name] else { continue }
            let runtime = RigRuntime()

            // The neutral targets `updateCharacter3D` restores before every pose, and the
            // zeroed sway `applyEmoteOverrides` applies on the way in.
            var rig = RigMutation(bodyPivotPosition: SIMD3(0, 0, 15.5),
                                  bodyPivotRotation: .zero,
                                  headRotation: .zero,
                                  leftHandTarget: SIMD3(9, -16, 12),
                                  rightHandTarget: SIMD3(9, 16, 12),
                                  leftFootTarget: SIMD3(2, -6, -13),
                                  rightFootTarget: SIMD3(2, 6, -13))

            definition.pose(&rig, EmoteContext(elapsed: elapsed,
                                               nowMs: nowMs,
                                               rotationDegrees: rotationDegrees,
                                               worldPosition: worldPosition,
                                               runtime: runtime))

            Log.world("""
                emote \(name) pivot=\(fmt(rig.bodyPivotPosition)) \
                pivotRot=\(fmt(rig.bodyPivotRotation)) head=\(fmt(rig.headRotation)) \
                lh=\(fmt(rig.leftHandTarget)) rh=\(fmt(rig.rightHandTarget)) \
                lf=\(fmt(rig.leftFootTarget)) rf=\(fmt(rig.rightFootTarget)) \
                props=\(rig.props.count) holding=\(rig.holding ?? "-")
                """)

            for (index, prop) in rig.props.enumerated() {
                let origin = SIMD3(prop.local.columns.3.x, prop.local.columns.3.y, prop.local.columns.3.z)
                // Uniform scale comes back as the length of the first basis column; a sprite
                // keeps its scale aside, because the camera basis supplies its orientation.
                let scale = prop.billboardScale
                    ?? simd_length(SIMD3(prop.local.columns.0.x,
                                         prop.local.columns.0.y,
                                         prop.local.columns.0.z))
                Log.world(String(format: "  prop %d %@ anchor=%@ at=%@ scale=%.3f opacity=%.3f",
                                 index, "\(prop.mesh)", "\(prop.anchor)", fmt(origin), scale, prop.opacity))
            }
        }
    }

    private static func fmt(_ v: SIMD3<Float>) -> String {
        String(format: "(%.4f, %.4f, %.4f)", v.x, v.y, v.z)
    }
}
#endif
