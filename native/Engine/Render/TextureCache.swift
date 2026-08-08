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
                ?? ImageDecoder.texture(from: data, device: self.device, flipped: true) {
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

    /// Drops everything on a map change.
    func purge() {
        textures.removeAll()
        failed.removeAll()
        inFlight.removeAll()
    }
}
