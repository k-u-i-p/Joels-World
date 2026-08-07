import UIKit

/// Draws emoji when the platform cannot.
///
/// The UI carries 23 emoji — the button bar, the emote picker, the badge list, the help
/// headings, the map-change ❌, the `love` emote's ❤️ sprite and the tennis ball. Every
/// shipping iPhone draws those from `AppleColorEmoji` and this file never runs. **The iOS
/// Simulator runtimes ship a stripped font set** where every one of them comes out as a
/// `.notdef` box, which is not a cosmetic problem when screenshots are how the port gets
/// verified.
///
/// So: probe once whether the system can actually draw a colour emoji, and if it cannot,
/// substitute a bundled SVG rasterised through `SVGRasterizer`. Nothing changes on a real
/// device. The SVGs are Twemoji, CC-BY 4.0 — see `Resources/emoji/ATTRIBUTION.txt`.
enum EmojiImage {

    /// False on a simulator runtime with no usable emoji font.
    static let systemCanRenderEmoji: Bool = probeSystemEmoji()

    // MARK: - Images

    /// A rasterised emoji at `pointSize`, or nil when the platform can draw it itself (in
    /// which case the caller should just use the text) or no asset is bundled for it.
    static func image(_ emoji: String, pointSize: CGFloat) -> UIImage? {
        guard !systemCanRenderEmoji else { return nil }
        return fallbackImage(emoji, pointSize: pointSize)
    }

    /// The bundled artwork regardless of what the platform can do. Only for callers that need
    /// a bitmap either way — the ❤️ sprite texture, which is uploaded to the GPU.
    static func fallbackImage(_ emoji: String, pointSize: CGFloat) -> UIImage? {
        let scale = UIScreen.main.scale
        let pixels = Int((pointSize * scale).rounded())
        let key = "\(assetName(for: emoji))@\(pixels)"
        if let cached = cache[key] { return cached }

        guard let data = assetData(for: emoji),
              let cgImage = SVGRasterizer.makeImage(svgData: data, maxDimension: CGFloat(pixels))
        else { return nil }

        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        cache[key] = image
        return image
    }

    // MARK: - Text

    /// `text` with any emoji in it replaced by inline images, when the platform needs that.
    /// Returns nil when the plain string will render correctly, so callers can keep using
    /// `.text` and its layout behaviour.
    static func attributed(_ text: String, font: UIFont, color: UIColor) -> NSAttributedString? {
        guard !systemCanRenderEmoji else { return nil }

        let result = NSMutableAttributedString()
        var plain = ""
        var substituted = false

        func flush() {
            guard !plain.isEmpty else { return }
            result.append(NSAttributedString(string: plain,
                                             attributes: [.font: font, .foregroundColor: color]))
            plain = ""
        }

        for character in text {
            let piece = String(character)
            if isEmoji(character), let image = fallbackImage(piece, pointSize: font.pointSize) {
                flush()
                let attachment = NSTextAttachment()
                attachment.image = image
                // Sit the glyph on the text baseline the way a real emoji does.
                attachment.bounds = CGRect(x: 0, y: font.descender,
                                           width: font.pointSize, height: font.pointSize)
                result.append(NSAttributedString(attachment: attachment))
                substituted = true
            } else {
                plain.append(piece)
            }
        }
        flush()

        return substituted ? result : nil
    }

    // MARK: - Assets

    private static var cache: [String: UIImage] = [:]

    /// Twemoji names its files after the code points, joined by `-`, with the
    /// variation selector (U+FE0F) dropped.
    private static func assetName(for emoji: String) -> String {
        emoji.unicodeScalars
            .filter { $0.value != 0xFE0F }
            .map { String($0.value, radix: 16) }
            .joined(separator: "-")
    }

    private static func assetData(for emoji: String) -> Data? {
        let name = assetName(for: emoji)
        // Synchronized groups may or may not preserve the folder in the bundle.
        let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "emoji")
            ?? Bundle.main.url(forResource: name, withExtension: "svg")
        guard let url else {
            Log.render("No bundled emoji asset for '\(emoji)' (\(name).svg)")
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0x238C)
        }
    }

    // MARK: - Capability probe

    /// Draws an emoji black-on-transparent and looks for colour. A colour glyph paints its own
    /// palette and ignores the fill; a `.notdef` box comes out pure black. Checking the font
    /// is present is not enough — the simulator's font *is* present and still draws boxes.
    private static func probeSystemEmoji() -> Bool {
        let size = 16
        guard let ctx = CGContext(data: nil,
                                  width: size, height: size,
                                  bitsPerComponent: 8,
                                  bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return true }

        UIGraphicsPushContext(ctx)
        ("🎾" as NSString).draw(at: .zero, withAttributes: [
            .font: UIFont.systemFont(ofSize: CGFloat(size)),
            .foregroundColor: UIColor.black,
        ])
        UIGraphicsPopContext()

        guard let data = ctx.data else { return true }
        let pixels = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        for index in stride(from: 0, to: size * size * 4, by: 4) {
            let r = pixels[index], g = pixels[index + 1], b = pixels[index + 2]
            let alpha = pixels[index + 3]
            guard alpha > 0 else { continue }
            // Any channel spread at all means a colour glyph was painted.
            if Int(max(r, max(g, b))) - Int(min(r, min(g, b))) > 8 { return true }
        }

        Log.render("System cannot render colour emoji — falling back to the bundled SVG set")
        return false
    }
}

// MARK: - Convenience

extension UILabel {
    /// Sets `text`, routing through the emoji fallback when the platform needs it.
    func setEmojiText(_ text: String?) {
        guard let text else {
            self.text = nil
            attributedText = nil
            return
        }
        if let attributed = EmojiImage.attributed(text,
                                                  font: font ?? .systemFont(ofSize: 17),
                                                  color: textColor ?? .white) {
            attributedText = attributed
        } else {
            self.text = text
        }
    }
}

extension UIButton {
    func setEmojiTitle(_ title: String, font: UIFont, color: UIColor) {
        if let attributed = EmojiImage.attributed(title, font: font, color: color) {
            setAttributedTitle(attributed, for: .normal)
        } else {
            setTitle(title, for: .normal)
            titleLabel?.font = font
            setTitleColor(color, for: .normal)
        }
    }
}
