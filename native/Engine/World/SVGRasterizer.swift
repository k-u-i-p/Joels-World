import CoreGraphics
import Foundation

/// Minimal SVG rasteriser. Two callers, with very different needs:
///
/// - the Illustrator-exported **clip masks** (`junior_school/clip_mask.svg`) — `<path>` elements
///   with `fill` / `fill-rule`, either inline or through a `<style>` class block;
/// - the **tennis court** (`minigames/tennis/map.svg`) — a 2.4 MB tracer export: 3,446 paths,
///   296 ellipses, 270 rects, 53 circles, 26,825 elliptical arcs, half of them stroke-only
///   inside a single `<g>` that carries the stroke style, and per-element
///   `transform="translate(…) rotate(…)"`.
///
/// It exists so artwork stays authored as vectors and needs no offline conversion step. It
/// deliberately supports only what those files use — anything else is logged and skipped
/// rather than silently producing wrong output.
///
/// **Scanning is byte-oriented on purpose.** Swift's `Character` is a grapheme cluster, and
/// walking 2.4 MB of path data through `[Character]` costs seconds in a debug build; the same
/// walk over `[UInt8]` is milliseconds. Document order is preserved exactly, because it is what
/// decides which of two overlapping shapes wins.
enum SVGRasterizer {

    /// Renders the document into `ctx`, mapping its `viewBox` onto `rect`.
    /// - Returns: false when there is no `viewBox`, or nothing drawable.
    @discardableResult
    static func draw(svgData: Data, into ctx: CGContext, rect: CGRect) -> Bool {
        let bytes = [UInt8](svgData)
        return render(Document(bytes: bytes), bytes: bytes, into: ctx, rect: rect)
    }

    /// Rasterises a whole document to its own bitmap, at the `viewBox`'s aspect ratio and no
    /// larger than `maxDimension` on its longest side. Used for the tennis court, which is a
    /// static backdrop: parsing 2.4 MB per frame is not an option, and the web build gets the
    /// same effect for free by handing the SVG to the browser's image decoder once.
    static func makeImage(svgData: Data, maxDimension: CGFloat) -> CGImage? {
        let bytes = [UInt8](svgData)
        let document = Document(bytes: bytes)
        guard let viewBox = document.viewBox else {
            Log.world("SVG has no viewBox — cannot rasterise it")
            return nil
        }

        let scale = min(1, maxDimension / max(viewBox.width, viewBox.height))
        let width = Int((viewBox.width * scale).rounded())
        let height = Int((viewBox.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Core Graphics is Y-up; SVG is Y-down.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setAllowsAntialiasing(true)

        guard render(document, bytes: bytes, into: ctx,
                     rect: CGRect(x: 0, y: 0, width: width, height: height))
        else { return nil }

        return ctx.makeImage()
    }

    private static func render(_ document: Document,
                               bytes: [UInt8],
                               into ctx: CGContext,
                               rect: CGRect) -> Bool {
        guard let viewBox = document.viewBox else {
            Log.world("SVG has no viewBox — cannot scale it")
            return false
        }
        guard !document.elements.isEmpty else {
            Log.world("SVG contained no drawable elements")
            return false
        }

        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / viewBox.width, y: rect.height / viewBox.height)
        ctx.translateBy(x: -viewBox.minX, y: -viewBox.minY)

        var stack: [Style] = [Style()]
        var drew = false

        for element in document.elements {
            switch element.kind {
            case .groupOpen:
                var style = stack[stack.count - 1]
                style.inherit(from: element, classes: document.classStyles)
                stack.append(style)

            case .groupClose:
                if stack.count > 1 { stack.removeLast() }

            case .path, .rect, .circle, .ellipse:
                var style = stack[stack.count - 1]
                style.inherit(from: element, classes: document.classStyles)

                guard var path = geometry(of: element, bytes: bytes) else { continue }
                if var transform = element.transform {
                    path = path.copy(using: &transform) ?? path
                }

                if let fill = style.fill {
                    ctx.addPath(path)
                    ctx.setFillColor(fill)
                    ctx.fillPath(using: style.fillRule)
                    drew = true
                }
                if let stroke = style.stroke, style.strokeWidth > 0 {
                    ctx.addPath(path)
                    ctx.setStrokeColor(stroke)
                    ctx.setLineWidth(style.strokeWidth)
                    ctx.setLineCap(style.lineCap)
                    ctx.setLineJoin(style.lineJoin)
                    ctx.strokePath()
                    drew = true
                }
            }
        }

        ctx.restoreGState()
        return drew
    }

    // MARK: - Painting style

    /// The subset of the SVG presentation attributes these files use. Inherited down through
    /// `<g>`, then overridden by the element's own attributes — which is what makes the tennis
    /// export's single stroke group work.
    private struct Style {
        /// nil means `fill="none"`. SVG's initial value is opaque black.
        var fill: CGColor? = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        var fillRule: CGPathFillRule = .winding
        var stroke: CGColor?
        var strokeWidth: CGFloat = 1
        var lineCap: CGLineCap = .butt
        var lineJoin: CGLineJoin = .miter

        mutating func inherit(from element: Element, classes: [String: [String: String]]) {
            // A `class` is resolved first, so an inline attribute still wins over it.
            if let name = element.attributes["class"], let declarations = classes[name] {
                apply(declarations)
            }
            apply(element.attributes)
        }

        private mutating func apply(_ declarations: [String: String]) {
            if let value = declarations["fill"] { fill = paint(value) }
            if let value = declarations["fill-rule"] {
                fillRule = value == "evenodd" ? .evenOdd : .winding
            }
            if let value = declarations["stroke"] { stroke = paint(value) }
            if let value = declarations["stroke-width"], let width = Double(value) {
                strokeWidth = CGFloat(width)
            }
            if let value = declarations["stroke-linecap"] {
                switch value {
                case "round": lineCap = .round
                case "square": lineCap = .square
                default: lineCap = .butt
                }
            }
            if let value = declarations["stroke-linejoin"] {
                switch value {
                case "round": lineJoin = .round
                case "bevel": lineJoin = .bevel
                default: lineJoin = .miter
                }
            }
        }

        private func paint(_ value: String) -> CGColor? {
            value == "none" ? nil : cgColor(named: value)
        }
    }

    // MARK: - Geometry

    private static func geometry(of element: Element, bytes: [UInt8]) -> CGPath? {
        switch element.kind {
        case .path:
            guard let range = element.pathData else { return nil }
            return buildPath(bytes: bytes, range: range)

        case .rect:
            let x = element.number("x") ?? 0
            let y = element.number("y") ?? 0
            let width = element.number("width") ?? 0
            let height = element.number("height") ?? 0
            guard width > 0, height > 0 else { return nil }
            let box = CGRect(x: x, y: y, width: width, height: height)
            // SVG mirrors a missing rx/ry onto the other axis.
            let rx = element.number("rx") ?? element.number("ry") ?? 0
            let ry = element.number("ry") ?? element.number("rx") ?? 0
            if rx > 0 || ry > 0 {
                return CGPath(roundedRect: box,
                              cornerWidth: min(rx, width / 2),
                              cornerHeight: min(ry, height / 2),
                              transform: nil)
            }
            return CGPath(rect: box, transform: nil)

        case .circle:
            let r = element.number("r") ?? 0
            guard r > 0 else { return nil }
            let cx = element.number("cx") ?? 0
            let cy = element.number("cy") ?? 0
            return CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2),
                          transform: nil)

        case .ellipse:
            let rx = element.number("rx") ?? 0
            let ry = element.number("ry") ?? 0
            guard rx > 0, ry > 0 else { return nil }
            let cx = element.number("cx") ?? 0
            let cy = element.number("cy") ?? 0
            return CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2),
                          transform: nil)

        case .groupOpen, .groupClose:
            return nil
        }
    }
}
