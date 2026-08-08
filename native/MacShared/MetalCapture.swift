import AppKit
import Metal

/// **Reading a rendered frame back off the GPU.** Shared by both Mac apps: the map editor's
/// `-shot` and the character lab's filmstrips.
///
/// The iOS port is verified with `xcrun simctl io screenshot`; there is no equivalent for a Mac
/// app, and `screencapture` needs a Screen Recording grant that a build machine may not have —
/// and grabs whatever else is on the desktop besides. So a Mac app grabs its own frame: the
/// Metal drawable is blitted into a readable texture and turned into a `CGImage`.
enum MetalCapture {

    /// Blits the drawable into a shared texture and reads it back once the GPU is done.
    ///
    /// The completion lands on the main queue, because everything either caller does with the
    /// image afterwards — composite it, write it, quit — is main-queue work.
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
}
