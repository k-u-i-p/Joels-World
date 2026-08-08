import AppKit
import Metal
import MetalKit

/// `-shot <path> [seconds]` — renders one frame to a PNG and quits.
///
/// The iOS port is verified with `xcrun simctl io screenshot`; there is no equivalent for a
/// Mac app, and `screencapture` needs a Screen Recording grant that a build machine may not
/// have. So the editor grabs its own frame: the Metal drawable is blitted to a readable
/// texture, the AppKit overlay is cached into a bitmap, and the two are composited.
enum AdminScreenshot {
    static var path: String? {
        argument("-shot")
    }

    /// How long to wait after launch before grabbing, so map tiles and models have loaded.
    static var delay: Double {
        argument("-shotdelay").flatMap(Double.init) ?? 6
    }

    static var quitsAfterShot: Bool {
        ProcessInfo.processInfo.arguments.contains("-shot")
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Blits the drawable into a shared texture and reads it back once the GPU is done.
    static func capture(texture: MTLTexture,
                        commandBuffer: MTLCommandBuffer,
                        device: MTLDevice,
                        completion: @escaping (CGImage?) -> Void) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let readable = device.makeTexture(descriptor: descriptor),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return completion(nil) }

        blit.copy(from: texture, to: readable)
        blit.endEncoding()

        commandBuffer.addCompletedHandler { _ in
            let image = makeImage(from: readable)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private static func makeImage(from texture: MTLTexture) -> CGImage? {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(&bytes,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)

        // The drawable is BGRA; Core Graphics wants that spelled out rather than swizzled.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: texture.width,
                       height: texture.height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Composites the whole window: the AppKit chrome and sidebar from `cacheDisplay`, the
    /// captured Metal frame in the map's rectangle, then the editor overlay on top of it.
    ///
    /// Three layers rather than one because `cacheDisplay` renders every AppKit view but
    /// leaves the Metal view blank, and the overlay — an ordinary `NSView` — has to land
    /// *after* the world image that would otherwise paint over it.
    static func write(world: CGImage, overlay: NSView, to path: String) -> Bool {
        guard let content = overlay.window?.contentView else { return false }

        let scale = overlay.window?.backingScaleFactor ?? 2
        let pixelWidth = Int(content.bounds.width * scale)
        let pixelHeight = Int(content.bounds.height * scale)

        guard let ctx = CGContext(data: nil,
                                  width: pixelWidth,
                                  height: pixelHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.scaleBy(x: scale, y: scale)

        if let image = snapshot(of: content) {
            ctx.draw(image, in: content.bounds)
        }

        // The map view's rectangle in the content view's (Y-up) coordinate space.
        let mapRect = overlay.convert(overlay.bounds, to: content)
        ctx.draw(world, in: mapRect)
        if let overlayImage = snapshot(of: overlay) {
            ctx.draw(overlayImage, in: mapRect)
        }

        guard let composed = ctx.makeImage() else { return false }
        let bitmap = NSBitmapImageRep(cgImage: composed)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func snapshot(of view: NSView) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
