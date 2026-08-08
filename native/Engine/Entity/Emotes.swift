import Foundation
import simd

/// The limb targets and body transform an emote is allowed to move, plus the props it spawns.
///
/// The JS mutates `vis.rig` directly inside each `updateLimbs3D`; this is the same set of
/// fields, gathered so the emote closures stay free of rendering types. The three transform
/// fields start out at whatever the previous frame left them (they live on `RigRuntime`),
/// because that is what three.js's retained `Object3D`s give the JS for free.
struct RigMutation {
    var bodyPivotPosition: SIMD3<Float>
    var bodyPivotRotation: SIMD3<Float>
    var headRotation: SIMD3<Float>

    var leftHandTarget: SIMD3<Float>
    var rightHandTarget: SIMD3<Float>
    var leftFootTarget: SIMD3<Float>
    var rightFootTarget: SIMD3<Float>

    var props: [PropDraw] = []

    /// `c.holding` — the model to put in the right hand. Only `tennis` sets it.
    var holding: String?
}

/// What an emote closure knows about the moment it is being posed for.
struct EmoteContext {
    /// `Date.now() - emote.startTime`, in milliseconds.
    var elapsed: Double
    /// `Date.now()` — `cry` keys its tears off the absolute clock rather than the emote's age.
    var nowMs: Double
    /// The character's heading in degrees, for `wet`'s footprint placement.
    var rotationDegrees: Double
    /// The character's render-space position `(x, -y, z)`, which `wet` reads off the mesh group.
    var worldPosition: SIMD3<Float>
    /// State that outlives the frame: the footprint pool and the dance notes' tumble.
    var runtime: RigRuntime
}

/// One entry in the `emotes` table (`emotes.js:64`).
struct EmoteDefinition {
    var duration: Double
    var message: String?
    var messageWhenNear: String?
    var sound: String?
    /// Port of `updateLimbs3D`.
    var pose: (inout RigMutation, EmoteContext) -> Void
    /// Port of `onEnd`. Runs when the emote is replaced or expires.
    var onEnd: ((inout GameCharacter) -> Void)?
}

/// The emote system: what a pose is allowed to change, how one is looked up, and the chat line
/// it announces itself with.
///
/// The twenty poses themselves are `EmoteTable.swift` — they are 90% of the code and none of
/// the interface, so they sit apart from it.
enum Emotes {

    static func definition(_ name: String?) -> EmoteDefinition? {
        guard let name else { return nil }
        return table[name]
    }

    /// Every emote name, in the order anything that lists them shows them: the iOS picker, the
    /// editor's emote pop-ups and `-emotedemo`. Being derived from `table` is the point — a
    /// name that appears in a list is by construction a name that can pose the rig.
    ///
    /// `server/emotes.js` holds the same 20 names for the AI agents' prompt and for rejecting
    /// nonsense from the wire. **The two must be kept in step.**
    static let names: [String] = table.keys.sorted()

    // MARK: - Messages

    /// Port of `getEmoteMessage` (`emotes.js:18-62`).
    ///
    /// `message_when_near` wins whenever any other character is inside its own interaction
    /// radius; the nearest one names the target. The web build calls this with `playerObj`
    /// null from the chat handler, so the extra player check below is only reachable from a
    /// caller that passes one.
    static func message(for name: String,
                        sourceName: String?,
                        sourceX: Double,
                        sourceY: Double,
                        sourceId: Int,
                        hasWorld: Bool,
                        characters: [GameCharacter],
                        npcs: [GameCharacter],
                        physics: PhysicsEngine,
                        playerObject: (id: Int, x: Double, y: Double, name: String?)? = nil) -> String? {
        guard let emote = table[name],
              emote.message != nil || emote.messageWhenNear != nil
        else { return nil }

        var targetName: String?

        if hasWorld, emote.messageWhenNear != nil {
            var minDistanceSquared = Double.infinity

            func check(_ list: [GameCharacter]) {
                for candidate in physics.findCharacters(list, x: sourceX, y: sourceY, ignoreId: nil) {
                    if candidate.id == sourceId { continue }
                    let dx = sourceX - candidate.x
                    let dy = sourceY - candidate.y
                    let distanceSquared = dx * dx + dy * dy
                    if distanceSquared < minDistanceSquared {
                        minDistanceSquared = distanceSquared
                        targetName = candidate.name
                    }
                }
            }

            check(characters)
            check(npcs)

            if let playerObject, playerObject.id != sourceId {
                let dx = playerObject.x - sourceX
                let dy = playerObject.y - sourceY
                let distanceSquared = dx * dx + dy * dy
                if distanceSquared < minDistanceSquared {
                    minDistanceSquared = distanceSquared
                    targetName = playerObject.name ?? "Someone"
                }
            }
        }

        // `String.replace` in JS swaps the *first* occurrence only; no template uses a
        // placeholder twice, so a plain replacement matches.
        if let target = targetName, let template = emote.messageWhenNear {
            return template
                .replacingOccurrences(of: "{name}", with: sourceName ?? "Someone")
                .replacingOccurrences(of: "{target_name}", with: target)
        }
        if let template = emote.message {
            return template.replacingOccurrences(of: "{name}", with: sourceName ?? "Someone")
        }
        return ""
    }

}
