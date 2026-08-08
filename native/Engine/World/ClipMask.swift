import CoreGraphics
import Foundation
import ImageIO

/// Pixel-perfect walkability mask. Port of the `clip_mask` handling in `physics.js:147-243`.
///
/// The mask is rasterised at 1/10 scale (matching the JS `clipMaskScale`) into an RGBA
/// buffer. Only pure white and pure green pixels are walkable; everything else is a wall.
final class ClipMask {
    /// Must match `physics.js` `clipMaskScale`.
    static let scale: Double = 0.1

    private let pixels: [UInt8]
    private let width: Int
    private let height: Int
    private let mapW: Double
    private let mapH: Double

    /// Raw RGBA rows (top-left origin) for the GPU copy the character shader marches through.
    var rgba: [UInt8] { pixels }
    var pixelWidth: Int { width }
    var pixelHeight: Int { height }
    var worldWidth: Double { mapW }
    var worldHeight: Double { mapH }

    private init(pixels: [UInt8], width: Int, height: Int, mapW: Double, mapH: Double) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.mapW = mapW
        self.mapH = mapH
    }

    /// World coordinates are centred on the map; the mask is indexed from its top-left.
    func isWalkable(worldX: Double, worldY: Double) -> Bool {
        let pixelX = Int(floor((worldX + mapW / 2) * Self.scale))
        let pixelY = Int(floor((worldY + mapH / 2) * Self.scale))

        if pixelX < 0 || pixelX >= width || pixelY < 0 || pixelY >= height {
            return false
        }

        let index = (pixelY * width + pixelX) * 4
        let r = pixels[index]
        let g = pixels[index + 1]
        let b = pixels[index + 2]

        return (r == 255 && g == 255 && b == 255) || (r == 0 && g == 255 && b == 0)
    }

    // MARK: - Loading

    /// Fetches and rasterises a mask. `path` is relative to the asset host, e.g.
    /// `junior_school/clip_mask.svg`.
    static func load(path: String,
                     mapW: Double,
                     mapH: Double,
                     completion: @escaping (ClipMask?) -> Void) {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: trimmed, relativeTo: Config.assetBaseURL) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data, error == nil else {
                Log.world("Failed to load clip mask at \(url): \(error?.localizedDescription ?? "no data")")
                completion(nil)
                return
            }

            let mask = rasterize(data: data,
                                 isSVG: trimmed.lowercased().hasSuffix(".svg"),
                                 mapW: mapW,
                                 mapH: mapH)
            if mask != nil {
                Log.world("Clip mask loaded: \(trimmed)")
            } else {
                Log.world("Clip mask failed to rasterise: \(trimmed)")
            }
            completion(mask)
        }.resume()
    }

    private static func rasterize(data: Data, isSVG: Bool, mapW: Double, mapH: Double) -> ClipMask? {
        let width = Int((mapW * scale).rounded())
        let height = Int((mapH * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let rasterized: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else { return false }

            // Default to walkable, exactly as the JS pre-fills the canvas white.
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            // Core Graphics is Y-up; the mask is authored Y-down. Flip so row 0 is the top.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)

            let rect = CGRect(x: 0, y: 0, width: width, height: height)

            if isSVG {
                return SVGRasterizer.draw(svgData: data, into: ctx, rect: rect)
            } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                ctx.draw(image, in: rect)
                return true
            }
            return false
        }

        guard rasterized else { return nil }
        return ClipMask(pixels: buffer, width: width, height: height, mapW: mapW, mapH: mapH)
    }
}
