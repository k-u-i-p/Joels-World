import Metal
import MetalKit

/// Async loader for map chunk tiles. Requests are deduplicated, and failures are remembered
/// so a missing tile is not re-requested every frame.
///
/// Tiles ship inside the app (PLAN.md §5), so a "load" is a file read and a decode. It stays
/// asynchronous because decoding a 512×512 tile is not something to do on the frame the
/// camera first sees it — but the work now runs on a queue instead of a `URLSession`, and a
/// failure means a packaging mistake rather than a flaky network.
final class TextureCache {
    private let device: MTLDevice
    private let loader: MTKTextureLoader
    private let queue = DispatchQueue(label: "com.allr.joelsworld.tiles",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    private var textures: [String: MTLTexture] = [:]
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []

    init(device: MTLDevice) {
        self.device = device
        self.loader = MTKTextureLoader(device: device)
    }

    func texture(for path: String) -> MTLTexture? {
        textures[path]
    }

    func hasFailed(_ path: String) -> Bool {
        failed.contains(path)
    }

    /// Kicks off a load if the tile is not already present, pending or known-bad.
    func requestTexture(path: String) {
        if textures[path] != nil || inFlight.contains(path) || failed.contains(path) { return }

        let trimmed = AssetLocator.relative(path)
        guard let url = AssetLocator.url(for: path) else {
            failed.insert(path)
            return
        }

        inFlight.insert(path)

        queue.async { [weak self] in
            guard let self else { return }

            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                DispatchQueue.main.async {
                    self.inFlight.remove(path)
                    self.failed.insert(path)
                    Log.render("Tile unreadable: \(trimmed)")
                }
                return
            }

            // Tiles are authored top-left origin, so flip to match Metal's UV convention.
            // `maps.js:303` tags chunk textures `SRGBColorSpace`, so they decode to linear on
            // sample and the render target encodes back on write.
            let options: [MTKTextureLoader.Option: Any] = [
                .origin: MTKTextureLoader.Origin.flippedVertically,
                .SRGB: true,
                .generateMipmaps: false,
            ]

            // `MTKTextureLoader` rejects **palette PNGs** — the deployed tiles for the Main
            // Building and parts of the Pool are colour-type 3, and every one of them came
            // back "Image decoding failed", leaving those maps' ground blank. Core Graphics
            // reads them happily, so a failed load falls through to a manual decode rather
            // than dropping the tile.
            if let texture = (try? self.loader.newTexture(data: data, options: options))
                ?? self.decodeWithCoreGraphics(data: data) {
                DispatchQueue.main.async {
                    self.inFlight.remove(path)
                    self.textures[path] = texture
                }
            } else {
                DispatchQueue.main.async {
                    self.inFlight.remove(path)
                    self.failed.insert(path)
                    Log.render("Tile decode failed: \(trimmed) — \(data.count) bytes")
                }
            }
        }
    }

    /// Manual PNG decode for the formats `MTKTextureLoader` will not take — in practice the
    /// palette PNGs the slicer writes. Core Graphics expands the palette to RGBA for us.
    ///
    /// The vertical flip matches `MTKTextureLoader.Origin.flippedVertically` on the fast path,
    /// and `.rgba8Unorm_srgb` matches its `.SRGB: true`, so a tile looks identical whichever
    /// route it took.
    private func decodeWithCoreGraphics(data: Data) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }

            // Row 0 of the buffer must be the image's *bottom* row.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb,
                                                                  width: width,
                                                                  height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: pixels,
                        bytesPerRow: width * 4)
        return texture
    }

    /// Drops everything on a map change.
    func purge() {
        textures.removeAll()
        failed.removeAll()
        inFlight.removeAll()
    }
}
