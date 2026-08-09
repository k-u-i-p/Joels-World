import Foundation

/// **Which body a character wears.**
///
/// Sessions 5–8 imported one bought model and drew every character in the game with it, because
/// there was only one. The visible cost was written down at the end of
/// `HANDOFF-imported-characters-part4.md`: *every pupil is the same boy*. This is the fix, and
/// it is deliberately a **table plus one string in `npc.json`** rather than anything cleverer —
/// adding a sixth character should be dropping a `.glb` in `assets/models/characters/` and
/// adding one line here, and picking who wears it should be a green-zone data change.
///
/// The key is what `npc.json` writes:
///
/// ```json
/// { "name": "Mr Hardy", "model": "man", ... }
/// ```
///
/// An unknown key falls back to `defaultKey` rather than drawing nothing, because a typo in a
/// data file should cost you the right character, not the whole character — a missing body is
/// invisible now that the procedural fallback is gone (see `CharacterRenderer.draw`).
///
/// A path may also be written straight out (`"models/characters/father.glb"`), which is what the
/// lab's `JW_CHARACTER_MODEL` does and what a model being tried out for the first time wants.
/// Anything containing a `/` is treated as a path.
enum CharacterModels {

    struct Entry {
        /// What `npc.json` writes.
        let key: String
        /// Asset path, relative to the staged tree — see `AssetLocator`.
        let path: String
        /// For the lab and the editor.
        let title: String
    }

    /// **The five bought characters.**
    ///
    /// Four of them — `boy`, `girl`, `man`, `woman` — are one family set and share a skeleton:
    /// 65 Mixamo-named joints, one skinned mesh, one material with a base colour map. `stylized_boy`
    /// is the original from part 1 and is a different build entirely (52 joints, and the UV set
    /// that needed `GLTFLoader`'s UV1 fallback), which is a useful thing to have in the lineup:
    /// it is the one that proves the retargeter is reading a file rather than remembering one.
    ///
    /// Sizes are **not** here. Every model is scaled to the rig's hip height on load
    /// (`HumanoidProfile.ScaleMode.hips`), which is what puts its feet on the floor; a teacher is
    /// taller than a pupil because `npc.json` gives them a bigger `width`/`height`, exactly as
    /// before. Bake a height into the model and the soles stop landing.
    static let all: [Entry] = [
        Entry(key: "boy", path: "models/characters/son.glb", title: "Boy"),
        Entry(key: "girl", path: "models/characters/daughter.glb", title: "Girl"),
        Entry(key: "man", path: "models/characters/father.glb", title: "Man"),
        Entry(key: "woman", path: "models/characters/mother.glb", title: "Woman"),
        Entry(key: "stylized_boy", path: "models/characters/stylized_boy.glb", title: "Stylized boy"),
    ]

    /// What a character with no `model` gets. The player is a pupil, and so is most of the cast.
    static let defaultKey = "boy"

    static let byKey: [String: Entry] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    static var defaultPath: String { byKey[defaultKey]!.path }

    /// Resolves whatever `npc.json` said into an asset path.
    static func path(for model: String?) -> String {
        guard let model, !model.isEmpty else { return defaultPath }
        if let entry = byKey[model] { return entry.path }
        // A path written out in full, for a model that has no table entry yet.
        if model.contains("/") { return model }
        Log.render("Character model '\(model)' is not in the catalogue — using '\(defaultKey)'")
        return defaultPath
    }

    /// The key a path came from, for the lab's captions.
    static func key(forPath path: String) -> String? {
        all.first { $0.path == path }?.key
    }
}
