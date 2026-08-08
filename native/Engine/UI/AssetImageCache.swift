import Foundation

/// Loads the UI layer's images out of the staged `GameAssets` tree, once each.
///
/// The same reasoning as `PendingDialog` and `PortraitOwner`: `ImageLoader` on iOS and
/// `AdminImageLoader` on macOS cannot be one type, because one vends `UIImage`s and the other
/// `NSImage`s and `Engine/` has neither framework. The *policy* is one policy, though —
/// resolve through `AssetLocator`, decode off the main queue, keep the result forever, hand a
/// resident image back synchronously — and it is worth having in one place.
///
/// Separate from `TextureCache`, which produces `MTLTexture`s for the renderer. These are
/// small, few, and want to be platform images: NPC portraits, and the minimaps.
///
/// **Main-queue only.** The dictionary is unsynchronised; `load` is called from view code and
/// completes back on the main queue, so the only two touches of it are already serialised.
/// Calling it off the main queue would race.
final class AssetImageCache<Image> {
    private var cache: [String: Image] = [:]
    private let decode: (URL) -> Image?

    /// - Parameter decode: Turns a file URL into a platform image, on a background queue.
    init(decode: @escaping (URL) -> Image?) {
        self.decode = decode
    }

    /// Loads an asset path (`avatars/mr_hardy.png`, with or without the leading slash the
    /// world files still carry from their URL days).
    ///
    /// The completion runs on the main queue — synchronously when the image is already
    /// resident, so a portrait that has been shown before appears in the same frame it is
    /// asked for rather than a flicker later.
    func load(path: String, completion: @escaping (Image?) -> Void) {
        let trimmed = AssetLocator.relative(path)

        if let image = cache[trimmed] {
            completion(image)
            return
        }

        guard let url = AssetLocator.url(for: path) else {
            completion(nil)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.decode(url)
            DispatchQueue.main.async {
                if let image {
                    self.cache[trimmed] = image
                } else {
                    Log.render("Image failed to decode: \(trimmed)")
                }
                completion(image)
            }
        }
    }
}
