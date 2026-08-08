import Foundation

/// What the renderer and the nameplate layer read off the simulation each frame.
///
/// Both are pure derivations — no state is touched, which is why they sit outside `GameState`
/// itself and reach it through nothing but its `private(set)` getters. Both also return
/// nothing at all while a minigame is up: it owns the screen, and neither the overworld roster
/// nor its DOM-era nameplates are on it.
extension GameState {
    /// One character the renderer should pose and draw this frame.
    ///
    /// This used to be a bare `(character, legAnimationTime)` pair, which could only ever
    /// describe a forward walk — the reason every character in the game turns on the spot
    /// before setting off. `Gait` replaces the single phase with the velocity resolved into the
    /// body's own frame, so side-stepping and back-pedalling are expressible; `poseOverride` is
    /// how a minigame aims a racket arm at a ball.
    struct DrawableCharacter {
        var character: GameCharacter
        var gait: Gait
        var poseOverride: RigOverride?
    }

    /// Everything that should be drawn as a character this frame: the local player first,
    /// then remote players, then NPCs — each with the gait its rig should use.
    var drawableCharacters: [DrawableCharacter] {
        // A minigame owns the screen. One drawn by the Metal renderer supplies its own cast;
        // one that draws itself on a 2D canvas has nothing here at all.
        if let minigame {
            guard let world = minigame as? WorldRenderedMinigame else { return [] }
            return world.sceneCharacters.map {
                DrawableCharacter(character: $0.character,
                                  gait: $0.gait,
                                  poseOverride: $0.poseOverride)
            }
        }

        var out: [DrawableCharacter] = []

        if var mine = player.appearance {
            mine.x = player.x
            mine.y = player.y
            mine.z = player.z
            mine.rotation = player.rotation
            mine.name = player.name
            // The live emote lives on `player`, not on the appearance record the roster
            // arrived with — without this the local player is the one character whose emote
            // never poses the rig.
            mine.emote = player.emote
            out.append(DrawableCharacter(character: mine, gait: player.gait))
        }

        // Remote players and NPCs have no controller — the server names a position, or
        // `NPCBehaviour` names a waypoint, and the interpolator eases them there. Their gait is
        // read back off the positions they actually walked through
        // (`Locomotion.observe`), so they side-step and back-pedal on the same terms the local
        // player does rather than being stuck facing wherever they happen to be walking.
        for character in characters where character.id != player.id {
            out.append(DrawableCharacter(
                character: character,
                gait: visuals[character.id]?.motion.gait ?? .still))
        }
        for npc in npcs {
            out.append(DrawableCharacter(
                character: npc,
                gait: visuals[npc.id]?.motion.gait ?? .still))
        }

        return out
    }

    /// What the nameplate/bubble layer needs about one character. Kept free of UIKit types so
    /// the `World` layer stays renderer- and UI-agnostic.
    struct OverlaySubject {
        var id: Int
        var name: String?
        var hideNameplate: Bool
        var x: Double
        var y: Double
        var z: Double
        var chatMessage: String?
        var chatTime: TimeInterval?
    }

    /// In the same order the JS draws them, which decides which three bubbles win when more
    /// than three characters are talking at once.
    var overlaySubjects: [OverlaySubject] {
        // Nameplates and bubbles are DOM nodes the minigames never create.
        if minigame != nil { return [] }

        var out: [OverlaySubject] = []
        out.reserveCapacity(characters.count + npcs.count + 1)

        func append(_ character: GameCharacter, x: Double, y: Double, z: Double, name: String?) {
            let visual = visuals[character.id]
            out.append(OverlaySubject(id: character.id,
                                      name: name,
                                      hideNameplate: character.hide_nameplate ?? false,
                                      x: x, y: y, z: z,
                                      chatMessage: visual?.chatMessage,
                                      chatTime: visual?.chatTime))
        }

        if let mine = player.appearance {
            append(mine, x: player.x, y: player.y, z: player.z, name: player.name)
        }
        for character in characters where character.id != player.id {
            append(character, x: character.x, y: character.y, z: character.z ?? 0, name: character.name)
        }
        for npc in npcs {
            append(npc, x: npc.x, y: npc.y, z: npc.z ?? 0, name: npc.name)
        }
        return out
    }
}
