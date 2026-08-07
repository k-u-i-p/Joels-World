import UIKit

/// Fetches the UI layer's images — NPC portraits and minimaps — from the asset host.
///
/// Separate from `TextureCache`, which produces `MTLTexture`s for the renderer. These are
/// small, few, and want to be `UIImage`s.
enum ImageLoader {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                   diskCapacity: 64 * 1024 * 1024,
                                   diskPath: "joelsworld-ui-images")
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private static var cache: [String: UIImage] = [:]

    /// Loads an asset-relative path (`/avatars/mr_hardy.png`). The completion runs on the
    /// main queue, synchronously when the image is already resident.
    static func load(path: String, completion: @escaping (UIImage?) -> Void) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path

        if let image = cache[trimmed] {
            completion(image)
            return
        }

        let name = (trimmed as NSString).deletingPathExtension
        let ext = (trimmed as NSString).pathExtension
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext),
           let image = UIImage(contentsOfFile: bundled.path) {
            cache[trimmed] = image
            completion(image)
            return
        }

        guard let url = URL(string: trimmed, relativeTo: Config.assetBaseURL) else {
            completion(nil)
            return
        }

        session.dataTask(with: url) { data, _, error in
            let image = data.flatMap(UIImage.init(data:))
            if image == nil {
                Log.render("Image fetch failed: \(trimmed) — \(error?.localizedDescription ?? "no data")")
            }
            DispatchQueue.main.async {
                if let image { cache[trimmed] = image }
                completion(image)
            }
        }.resume()
    }
}
