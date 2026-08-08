import CoreGraphics
import ImageIO
import Metal

/// Core Graphics decode for the PNG flavours `MTKTextureLoader` refuses.
///
/// It refuses more than one: the map slicer writes **palette** PNGs (colour type 3) for the
/// Main Building and part of the Pool, and `desk.glb` — the most-placed prop in the game —
/// carries a **1-bit greyscale** emissive map. Both come back "Image decoding failed" from
/// `MTKTextureLoader` and both read fine here, because Core Graphics expands them to RGBA.
///
/// A failed decode is never harmless: a dropped tile leaves the ground blank, and a dropped
/// emissive map leaves an `emissiveFactor` unmodulated, which is the difference between a
/// desk and a white rectangle.
enum ImageDecoder {
    /// `flipped` matches `MTKTextureLoader.Origin.flippedVertically`, so whichever route an
    /// image takes it samples the same way. Map tiles need the flip (their quads are built
    /// bottom-up); glTF textures do not (glTF UVs are already top-left origin).
    static func texture(from data: Data,
                        device: MTLDevice,
                        flipped: Bool,
                        srgb: Bool = true) -> MTLTexture? {
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

            if flipped {
                // Row 0 of the buffer must be the image's *bottom* row.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
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
}
