import Foundation

/// **Who stands in the lab.**
///
/// Four casts, because there are four different questions a character gets looked at for:
///
/// - `.solo` — one pupil, alone, framed close. The one to use for a rig or an animation: a
///   knee, an elbow, where a foot lands.
/// - `.school` — five real pupils out of `data/junior_school/npc.json`. The one to use for
///   crowds and for scale: these are the actual sizes, names **and models** the game puts on
///   screen.
/// - `.models` — **one of every model in `CharacterModels`, at the same size.** The one to use
///   when the question is about the models themselves rather than about the game: five bodies
///   side by side, nothing else different between them, so a proportion or a skeleton that
///   retargets badly stands out against four that do not. It is also the shot that proves all
///   five load at once — see the ring in `CharacterRenderer`.
/// - `.extremes` — five synthetic characters chosen to break things: the darkest skin against
///   the darkest shirt, white on white, a teacher scaled to 52 × 58, a headless one. Contrast
///   bugs and scale bugs hide behind well-chosen colours.
///
/// Everything is deterministic: the ids are fixed, so `consistentRandom` picks the same head
/// and the same hair every run.
enum CharacterLabCast {
    enum Kind: String, CaseIterable {
        case solo
        case school
        case models
        case extremes

        var title: String {
            switch self {
            case .solo: return "One pupil"
            case .school: return "Five from Junior Campus"
            case .models: return "One of every model"
            case .extremes: return "Awkward colours and sizes"
            }
        }
    }

    /// The cast, in the order they are laid out left to right. Positions are filled in by
    /// `CharacterLabScene` — everything here is appearance.
    static func characters(_ kind: Kind) -> [GameCharacter] {
        switch kind {
        case .solo:
            return [pupil()]
        case .school:
            return schoolPupils()
        case .models:
            return everyModel()
        case .extremes:
            return extremes()
        }
    }

    /// One character per catalogue entry, identical in every other way.
    ///
    /// **Same `width` and `height` for all five on purpose.** A model is scaled to the rig's hip
    /// height on load, so this is the lineup that shows what each one's *own* proportions do with
    /// that — a long-legged adult and a short-legged child both stand hip-high to the same line,
    /// and how much taller that leaves the adult's head is the model's own answer, not a number
    /// anybody typed. Give them the sizes the game gives a teacher and a pupil and you would be
    /// photographing `npc.json` instead.
    private static func everyModel() -> [GameCharacter] {
        CharacterModels.all.enumerated().map { index, entry in
            var character = pupil()
            character.id = labId(index)
            character.name = entry.title
            character.model = entry.key
            return character
        }
    }

    /// The lab's default subject: a Junior Campus pupil. The colours below are still set and
    /// still stored; nothing draws with them now that the character is a textured bought model.
    static func pupil() -> GameCharacter {
        var character = GameCharacter(id: labId(0))
        character.name = "Subject"
        character.gender = "male"
        character.head = "male_hair_short"
        character.hair_color = "#3b2b1a"
        character.shirt_color = "#2ecc71"
        character.arm_color = "#2ecc71"
        character.pants_color = "#2c3e50"
        character.shoe_color = "#5e3a1f"
        character.width = 40
        character.height = 40
        character.hide_nameplate = true
        return character
    }

    /// Five pupils lifted straight out of the bundled map data, so the lineup is the game's own
    /// palette rather than one invented here. Falls back to variations on `pupil()` if the data
    /// tree is missing — the editor can be run without one.
    private static func schoolPupils() -> [GameCharacter] {
        let shirts = ["#e74c3c", "#2ecc71", "#e67e22", "#9b59b6", "#3498db"]
        var out: [GameCharacter] = []

        let bundled = WorldData.npcs(mapId: 0).filter { ($0.width ?? 40) <= 44 }
        for (index, npc) in bundled.prefix(5).enumerated() {
            var character = npc
            character.id = labId(index)
            character.hide_nameplate = true
            out.append(character)
        }

        while out.count < 5 {
            var character = pupil()
            character.id = labId(out.count)
            character.gender = out.count % 2 == 0 ? "male" : "female"
            character.head = nil
            character.shirt_color = shirts[out.count % shirts.count]
            character.arm_color = character.shirt_color
            out.append(character)
        }
        return out
    }

    /// The colours and sizes that catch bugs the pretty ones hide.
    private static func extremes() -> [GameCharacter] {
        func make(_ index: Int, _ configure: (inout GameCharacter) -> Void) -> GameCharacter {
            var character = pupil()
            character.id = labId(index)
            configure(&character)
            return character
        }

        return [
            // Dark on dark: the clothing atlas's shade channel multiplies, so a near-black
            // shirt is where a seam either survives or disappears.
            make(0) {
                $0.name = "Dark on dark"
                $0.color = "#5b3a1f"
                $0.shirt_color = "#1c2833"
                $0.arm_color = "#1c2833"
                $0.pants_color = "#141a1f"
                $0.shoe_color = "#111111"
            },
            // White on white: the trim channel mixes *towards* `trimColor`, so a white shirt is
            // where a collar stops being a collar.
            make(1) {
                $0.name = "White on white"
                $0.color = "#f6e0c8"
                $0.shirt_color = "#f4f4f4"
                $0.arm_color = "#f4f4f4"
                $0.pants_color = "#e8e8e8"
                $0.shoe_color = "#dddddd"
            },
            // A teacher: 52 × 58, which is the largest scale anything in the game is drawn at.
            make(2) {
                $0.name = "Teacher scale"
                $0.gender = "male"
                $0.head = "male_hair_messy"
                $0.hair_color = "#4a4a4a"
                $0.shirt_color = "#1c2833"
                $0.arm_color = "#1c2833"
                $0.width = 52
                $0.height = 58
            },
            // The bare channel mixes towards skin, so the loudest skin there is says exactly
            // where a sleeve ends and where a sock starts.
            make(3) {
                $0.name = "Loud skin"
                $0.color = "#ff2d95"
                $0.shirt_color = "#101010"
                $0.arm_color = "#101010"
                $0.pants_color = "#101010"
                $0.shoe_color = "#101010"
            },
            // `female_hair_short_2` has no `.glb` on the asset host, so this one renders
            // headless on purpose — it is what a missing model looks like.
            make(4) {
                $0.name = "Missing head"
                $0.gender = "female"
                $0.head = "female_hair_short_2"
                $0.shirt_color = "#9b59b6"
                $0.arm_color = "#9b59b6"
            },
        ]
    }

    /// Lab ids sit well above anything the server hands out, so a rig runtime keyed by id can
    /// never collide with a real character's if both are ever on screen at once.
    private static func labId(_ index: Int) -> Int { 900_000 + index }
}
