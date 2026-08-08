import Foundation

/// Resolves the asset paths the world data is written in — `/media/laser.mp3`,
/// `/junior_school/chunks/background_3_2.jpg`, `models/head_01.glb` — to files inside the app.
///
/// These used to be URLs on the Node server, and every loader carried its own "bundle first,
/// then the network" fallback plus a `URLCache` to stand in for the browser's. The server no
/// longer serves assets at all: `tools/assets/stage.sh` copies the shipped subset into
/// `GameAssets/` at build time, so resolution is now a synchronous path join and a miss is a
/// packaging bug rather than a network condition.
enum AssetLocator {
    /// The staged tree's root inside the bundle. Matches the destination `stage.sh` is given
    /// by the Xcode build phase.
    static let directoryName = "GameAssets"

    static let root: URL = {
        guard let resources = Bundle.main.resourceURL else {
            fatalError("AssetLocator: the bundle has no resource directory")
        }
        return resources.appendingPathComponent(directoryName, isDirectory: true)
    }()

    /// Strips the leading slash the authored data uses inconsistently — `maps.json` writes
    /// `"/detention/chunks/map_{x}_{y}.png"` for layers but `"avatars/mr_hardy.png"` for
    /// portraits, and both mean the same thing.
    static func relative(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// The file for an asset path, or `nil` if it was not staged into the bundle.
    static func url(for path: String) -> URL? {
        let trimmed = relative(path)
        guard !trimmed.isEmpty else { return nil }

        let url = root.appendingPathComponent(trimmed)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.render("Asset missing from bundle: \(trimmed)")
            return nil
        }
        return url
    }

    /// Convenience for the loaders that want bytes rather than a location.
    static func data(for path: String) -> Data? {
        guard let url = url(for: path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            Log.render("Asset unreadable: \(relative(path)) — \(error.localizedDescription)")
            return nil
        }
    }
}
