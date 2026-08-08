import Foundation

/// What the renderer and the nameplate layer read off the simulation each frame.
///
/// Both are pure derivations — no state is touched, which is why they sit outside `GameState`
/// itself and reach it through nothing but its `private(set)` getters. Both also return
/// nothing at all while a minigame is up: it owns the screen, and neither the overworld roster
/// nor its DOM-era nameplates are on it.
extension GameState {
    /// Everything that should be drawn as a character this frame: the local player first,
    /// then remote players, then NPCs — each with the walk phase its rig should use.
    var drawableCharacters: [(character: GameCharacter, legAnimationTime: Double)] {
        // A minigame owns the screen; the overworld roster is not on it.
        if minigame != nil { return [] }

        var out: [(GameCharacter, Double)] = []

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
            out.append((mine, player.legAnimationTime))
        }

        for character in characters where character.id != player.id {
            out.append((character, visuals[character.id]?.legAnimationTime ?? 0))
        }
        for npc in npcs {
            out.append((npc, visuals[npc.id]?.legAnimationTime ?? 0))
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
