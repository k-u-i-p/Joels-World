import CoreGraphics
import CoreText
import Metal
import MetalKit
#if canImport(UIKit)
import UIKit
#endif

/// The textures the renderer paints for itself rather than loading out of `assets/`.
///
/// All three are small, fixed and built once at startup: the ❤️ sprite the `love` emote
/// scatters, the soft blob every character stands on, and the 1×1 white the fragment shader
/// binds when a draw has no texture of its own. They were inline in `CharacterRenderer`, whose
/// job is posing and drawing a rig — Core Graphics and Core Text are a different one.
///
/// The heart is why this is not a single function: the glyph has a UIKit path and an AppKit
/// path, and on the iOS Simulator's stripped font set it has a third, through `EmojiImage`.
enum ProceduralTextures {
    /// `emotes.js:675-682` paints ❤️ at 100 px into a 128² canvas and uses it as a sprite map.
    static func makeHeartTexture(device: MTLDevice) -> MTLTexture? {
        guard let cgImage = makeHeartImage(size: CGSize(width: 128, height: 128)) else { return nil }
        return try? MTKTextureLoader(device: device).newTexture(
            cgImage: cgImage,
            options: [.SRGB: true, .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)])
    }

#if canImport(UIKit)
    private static func makeHeartImage(size: CGSize) -> CGImage? {
        // On a simulator runtime with no usable emoji font the glyph comes out as a black box,
        // which makes `love` spawn four black squares. Fall back to the bundled artwork.
        if !EmojiImage.systemCanRenderEmoji,
           let fallback = EmojiImage.fallbackImage("❤️", pointSize: 100) {
            let composed = UIGraphicsImageRenderer(size: size).image { _ in
                fallback.draw(in: CGRect(x: 14, y: 14, width: 100, height: 100))
            }
            if let cgImage = composed.cgImage { return cgImage }
        }

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 100),
                .paragraphStyle: paragraph,
            ]
            let text = "❤️" as NSString
            let bounds = text.boundingRect(with: size,
                                           options: .usesLineFragmentOrigin,
                                           attributes: attributes,
                                           context: nil)
            // `textBaseline = 'middle'` centres the glyph box on the canvas centre.
            text.draw(in: CGRect(x: 0, y: (size.height - bounds.height) / 2,
                                 width: size.width, height: bounds.height),
                      withAttributes: attributes)
        }
        return image.cgImage
    }
#else
    /// macOS has no `UIGraphicsImageRenderer` and no missing-emoji problem, so the glyph goes
    /// straight through Core Text. Same 100 pt ❤️ centred in the same 128² canvas.
    private static func makeHeartImage(size: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil,
                                  width: Int(size.width),
                                  height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }

        let font = CTFontCreateUIFontForLanguage(.system, 100, nil)
            ?? CTFontCreateWithName("AppleColorEmoji" as CFString, 100, nil)
        let attributed = NSAttributedString(string: "❤️",
                                            attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        ctx.textPosition = CGPoint(x: (size.width - bounds.width) / 2 - bounds.minX,
                                   y: (size.height - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }
#endif

    /// The soft ground blob: a flat 25%-black disc, exactly as `buildShadowBlob` paints it.
    static func makeShadowTexture(device: MTLDevice) -> MTLTexture? {
        let size = 30
        var pixels = [UInt8](repeating: 0, count: size * size * 4)

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.25)
            ctx.fillEllipse(in: CGRect(x: 1, y: 1, width: 28, height: 28))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: size, height: size,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return texture
    }

    static func makeWhiteTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var white: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &white, bytesPerRow: 4)
        return texture
    }
}
