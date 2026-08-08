import AppKit

/// Reads the UI layer's images — the NPC portraits — out of the staged `GameAssets` tree.
///
/// An `NSImage` over the shared `AssetImageCache`; the iOS target's `ImageLoader` is the same
/// cache over `UIImage`.
enum AdminImageLoader {
    private static let images = AssetImageCache<NSImage> { url in
        NSImage(contentsOf: url)
    }

    /// Loads an asset path (`avatars/mr_hardy.png`). The completion runs on the main queue,
    /// synchronously when the image is already resident.
    static func load(path: String, completion: @escaping (NSImage?) -> Void) {
        images.load(path: path, completion: completion)
    }
}
