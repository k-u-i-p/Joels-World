import Foundation

/// The locally-controlled player. Mirrors the `player` object in `main.js:252`.
///
/// Unlike every other character on the map this one is not a `GameCharacter`: it carries the
/// input-driven fields the simulation owns — the run timer, the leg phase, the trigger zone it
/// is standing in — alongside the appearance record the server sent. `GameState.syncPlayerNow`
/// is where the two are folded back together into something the wire accepts.
struct Player {
    var id: Int = 0
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var rotation: Double = 0
    var width: Double = 40
    var height: Double = 40
    var moveSpeed: Double = 3
    var rotationSpeed: Double = 3
    var name: String?

    var isRunning = false
    var runDirectionStart: TimeInterval?
    var legAnimationTime: Double = 0
    var activeBuilding: Int?
    var emote: EmoteState?
    /// Badges earned, carried on the session record and topped up by `badge_earned`.
    var badges: [String] = []

    /// Last values sent upstream, so sync only fires on change.
    var lastSentX: Double?
    var lastSentY: Double?
    var lastSentRotation: Double?
    var lastSentEmote: EmoteState??

    /// Colours and appearance arrive from the server; retained for Phase 2 rendering.
    var appearance: GameCharacter?
}
