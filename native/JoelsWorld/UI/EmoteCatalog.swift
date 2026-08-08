import Foundation

/// The emote names the picker offers and `/command` validates against.
///
/// This used to be fetched from the server's `/api/config`, which built the list by regexing
/// the web client's `emotes.js`. Both ends of that are gone: the server has no HTTP surface
/// left, and the app compiles in the definitions themselves. `Emotes.table` is now the list —
/// a name in the picker is by construction a name that can pose the rig.
///
/// `server/emotes.js` holds the same 20 names for the AI agents' prompt and for rejecting
/// nonsense from the wire. **The two must be kept in step.**
enum EmoteCatalog {
    static let names: [String] = Emotes.table.keys.sorted()

    static func isValid(_ name: String) -> Bool {
        Emotes.table[name] != nil
    }

    /// Kept as a callback for the two call sites that were written against the fetch. There is
    /// nothing to wait for now, so the completion runs immediately, on the caller's queue.
    static func load(completion: (([String]) -> Void)? = nil) {
        completion?(names)
    }
}
