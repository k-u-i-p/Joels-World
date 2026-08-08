import UIKit

/// Reads the UI layer's images — NPC portraits and minimaps — out of the app bundle.
///
/// A `UIImage` over the shared `AssetImageCache`; the editor's `AdminImageLoader` is the same
/// cache over `NSImage`.
enum ImageLoader {
    private static let images = AssetImageCache<UIImage> { url in
        UIImage(contentsOfFile: url.path)
    }

    /// Loads an asset path (`/avatars/mr_hardy.png`). The completion runs on the main queue,
    /// synchronously when the image is already resident.
    static func load(path: String, completion: @escaping (UIImage?) -> Void) {
        images.load(path: path, completion: completion)
    }
}
