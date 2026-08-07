import Foundation

/// The list of emote names the server considers valid, fetched once from `/api/config`.
///
/// The server builds it by regexing `emotes.js` at boot (`static.js:9-23`), so it is exactly
/// the set the web build's `/command` handler accepts. Phase 6 brings the definitions
/// themselves — poses, durations and sounds — over to the app; until then the names are all
/// that is needed to drive the picker and validate typed commands.
enum EmoteCatalog {
    private(set) static var names: [String] = []

    private static var loading = false
    private static var waiting: [([String]) -> Void] = []

    static func isValid(_ name: String) -> Bool {
        names.contains(name)
    }

    /// Fetches the list if it is not already resident. The completion runs on the main queue.
    static func load(completion: (([String]) -> Void)? = nil) {
        if !names.isEmpty {
            completion?(names)
            return
        }
        if let completion { waiting.append(completion) }
        guard !loading else { return }
        loading = true

        guard let url = URL(string: "api/config", relativeTo: Config.assetBaseURL) else {
            loading = false
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            struct ConfigResponse: Decodable { var validEmotes: [String]? }
            let emotes = data
                .flatMap { try? JSONDecoder().decode(ConfigResponse.self, from: $0) }?
                .validEmotes ?? []

            DispatchQueue.main.async {
                loading = false
                if emotes.isEmpty {
                    Log.net("Emote list unavailable: \(error?.localizedDescription ?? "empty response")")
                } else {
                    names = emotes
                    Log.net("Loaded \(emotes.count) emotes")
                }
                let callbacks = waiting
                waiting = []
                for callback in callbacks { callback(emotes) }
            }
        }.resume()
    }
}
