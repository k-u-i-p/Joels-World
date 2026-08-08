import UIKit

/// Fetches an SVG from the asset host and rasterises it once, through `SVGRasterizer`.
///
/// The web build gets this for free — `new Image(); img.src = '/minigames/tennis/map.svg'` and
/// the browser decodes it. iOS has no SVG decoder, so the court is rasterised here into a
/// bitmap and reused, rather than being re-parsed every frame: `minigames/tennis/map.svg` is
/// 2.4 MB and 4,065 elements.
enum SVGImage {
    private static var cache: [String: UIImage] = [:]
    private static var inFlight: Set<String> = []
    private static var waiting: [String: [(UIImage?) -> Void]] = [:]

    /// - Parameters:
    ///   - path: asset-relative, e.g. `/minigames/tennis/map.svg`.
    ///   - maxDimension: cap on the longest side of the bitmap, in pixels.
    ///   - completion: always on the main queue; synchronous when the image is already resident.
    static func load(path: String,
                     maxDimension: CGFloat = 2560,
                     completion: @escaping (UIImage?) -> Void) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path

        if let image = cache[trimmed] {
            completion(image)
            return
        }

        waiting[trimmed, default: []].append(completion)
        guard !inFlight.contains(trimmed) else { return }
        inFlight.insert(trimmed)

        fetch(trimmed) { data in
            DispatchQueue.global(qos: .userInitiated).async {
                let image = data
                    .flatMap { SVGRasterizer.makeImage(svgData: $0, maxDimension: maxDimension) }
                    .map { UIImage(cgImage: $0) }

                DispatchQueue.main.async {
                    inFlight.remove(trimmed)
                    if let image {
                        cache[trimmed] = image
                        Log.render("SVG rasterised: \(trimmed) at \(Int(image.size.width))×\(Int(image.size.height))")
                    } else {
                        Log.render("SVG failed to rasterise: \(trimmed)")
                    }
                    let callbacks = waiting.removeValue(forKey: trimmed) ?? []
                    for callback in callbacks { callback(image) }
                }
            }
        }
    }

    /// The tennis court's 2.4 MB `map.svg` ships with the app like everything else; iOS has no
    /// SVG decoder, so `SVGRasterizer` still does the work.
    private static func fetch(_ trimmed: String, completion: @escaping (Data?) -> Void) {
        completion(AssetLocator.data(for: trimmed))
    }
}
