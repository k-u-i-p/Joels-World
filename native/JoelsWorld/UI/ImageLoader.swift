import UIKit

/// Reads the UI layer's images — NPC portraits and minimaps — out of the app bundle.
///
/// Separate from `TextureCache`, which produces `MTLTexture`s for the renderer. These are
/// small, few, and want to be `UIImage`s.
enum ImageLoader {
    private static var cache: [String: UIImage] = [:]

    /// Loads an asset path (`/avatars/mr_hardy.png`). The completion runs on the main queue,
    /// synchronously when the image is already resident.
    static func load(path: String, completion: @escaping (UIImage?) -> Void) {
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
            let image = UIImage(contentsOfFile: url.path)
            DispatchQueue.main.async {
                if let image {
                    cache[trimmed] = image
                } else {
                    Log.render("Image failed to decode: \(trimmed)")
                }
                completion(image)
            }
        }
    }
}
