import AppKit

/// **Turning frames into something worth looking at once.**
///
/// A single screenshot of an animation is nearly useless: a walk cycle looked at one frame at a
/// time is twelve separate arguments about whether the foot was down. A strip of eight frames
/// across one stride, captioned with the time and what to watch for, is one picture that
/// answers the question — and, because the lab's clock is deterministic, the same strip taken
/// tomorrow is diffable against today's.
///
/// So this composes: frames into a grid, captions under each, a title across the top. It is
/// also where the clothing atlas is written out, split into the three channels the shader reads
/// separately, because a control map viewed as an RGB image is unreadable — the collar and the
/// sock are in different channels and land on top of each other as a colour nobody chose.
enum CharacterLabCapture {

    struct Frame {
        let image: CGImage
        let caption: String
    }

    /// The widest a single frame is drawn in a sheet.
    private static let maxCellWidth: CGFloat = 560

    // MARK: - Sheets

    /// Lays the frames out in a grid, captions each, and writes a PNG.
    ///
    /// `columns` defaults to something close to square, which is what suits a whole-catalogue
    /// sheet; a filmstrip of one take reads better in a wide grid, so callers pass their own.
    @discardableResult
    static func writeSheet(_ frames: [Frame],
                           title: String,
                           subtitle: String?,
                           columns requested: Int? = nil,
                           to path: String) -> Bool {
        guard let first = frames.first else { return false }

        let columns = max(1, requested ?? Int(ceil(sqrt(Double(frames.count)))))
        let rows = Int(ceil(Double(frames.count) / Double(columns)))

        // The frames arrive at the window's backing resolution, which on a Retina Mac is 1800
        // across — eight of those side by side is a 15,000-pixel sheet nobody can look at, and
        // every viewer that opens it scales it back down anyway. Capped so the sheet is read at
        // the size it was composed at.
        let scale = min(1, maxCellWidth / CGFloat(first.image.width))
        let cellWidth = (CGFloat(first.image.width) * scale).rounded()
        let cellHeight = (CGFloat(first.image.height) * scale).rounded()
        let captionHeight: CGFloat = 34
        let gap: CGFloat = 12
        let headerHeight: CGFloat = subtitle == nil ? 46 : 66
        let margin: CGFloat = 16

        let width = margin * 2 + CGFloat(columns) * cellWidth + CGFloat(columns - 1) * gap
        let height = margin * 2 + headerHeight
            + CGFloat(rows) * (cellHeight + captionHeight) + CGFloat(rows - 1) * gap

        guard let ctx = context(width: Int(width), height: Int(height)) else { return false }

        // Flipped, so the sheet is laid out top-down the way it is read.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(NSColor(white: 0.11, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        inFlippedContext(ctx) {
            draw(title, at: CGRect(x: margin, y: margin, width: width - margin * 2, height: 24),
                 size: 18, weight: .semibold, colour: .white)
            if let subtitle {
                draw(subtitle,
                     at: CGRect(x: margin, y: margin + 26, width: width - margin * 2, height: 34),
                     size: 12, weight: .regular, colour: NSColor(white: 0.72, alpha: 1))
            }
        }

        for (index, frame) in frames.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = margin + CGFloat(column) * (cellWidth + gap)
            let y = margin + headerHeight + CGFloat(row) * (cellHeight + captionHeight + gap)

            let imageRect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
            ctx.saveGState()
            // The frame images are upright; the context is flipped, so each one is flipped back
            // over its own rectangle rather than the whole sheet being drawn upside down.
            ctx.translateBy(x: 0, y: imageRect.maxY + imageRect.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(frame.image, in: imageRect)
            ctx.restoreGState()

            inFlippedContext(ctx) {
                draw(frame.caption,
                     at: CGRect(x: x + 4, y: y + cellHeight + 6,
                                width: cellWidth - 8, height: captionHeight - 8),
                     size: 11, weight: .regular, colour: NSColor(white: 0.85, alpha: 1))
            }
        }

        return write(ctx.makeImage(), to: path)
    }

    @discardableResult
    static func write(_ image: CGImage?, to path: String) -> Bool {
        guard let image else { return false }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - Drawing

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// AppKit text drawing needs an `NSGraphicsContext`, and the sheet's context is already
    /// flipped — so the wrapper hands AppKit a flipped one to match rather than every caller
    /// working out its own baseline.
    private static func inFlippedContext(_ ctx: CGContext, _ body: () -> Void) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.current = previous
    }

    private static func draw(_ text: String,
                             at rect: CGRect,
                             size: CGFloat,
                             weight: NSFont.Weight,
                             colour: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
        ]).draw(with: rect, options: [.usesLineFragmentOrigin])
    }
}
