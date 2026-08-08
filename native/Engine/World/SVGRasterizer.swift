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

    // MARK: - Document parsing

    private enum Kind {
        case path, rect, circle, ellipse, groupOpen, groupClose
    }

    private struct Element {
        var kind: Kind
        var attributes: [String: String] = [:]
        /// `d` is left as a byte range rather than a String — it is most of the file.
        var pathData: Range<Int>?
        var transform: CGAffineTransform?

        func number(_ name: String) -> CGFloat? {
            guard let raw = attributes[name], let value = Double(raw) else { return nil }
            return CGFloat(value)
        }
    }

    private struct Document {
        var viewBox: CGRect?
        var elements: [Element] = []
        var classStyles: [String: [String: String]] = [:]

        init(bytes: [UInt8]) {
            var scanner = TagScanner(bytes: bytes)

            while let tag = scanner.nextTag() {
                switch tag.name {
                case "svg":
                    if let raw = tag.attributes["viewBox"] {
                        let parts = raw.split(whereSeparator: { $0 == " " || $0 == "," })
                            .compactMap { Double($0) }
                        if parts.count == 4, parts[2] > 0, parts[3] > 0 {
                            viewBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                        }
                    }

                case "style":
                    classStyles = Self.parseStyleClasses(scanner.text(until: "</style>"))

                case "g":
                    if tag.isClosing {
                        elements.append(Element(kind: .groupClose))
                    } else {
                        elements.append(make(.groupOpen, tag))
                        // `<g …/>` opens and closes in one tag.
                        if tag.isSelfClosing { elements.append(Element(kind: .groupClose)) }
                    }

                case "path" where !tag.isClosing:
                    var element = make(.path, tag)
                    element.pathData = tag.rawAttributes["d"]
                    if element.pathData != nil { elements.append(element) }

                case "rect" where !tag.isClosing: elements.append(make(.rect, tag))
                case "circle" where !tag.isClosing: elements.append(make(.circle, tag))
                case "ellipse" where !tag.isClosing: elements.append(make(.ellipse, tag))

                default:
                    break
                }
            }
        }

        private func make(_ kind: Kind, _ tag: TagScanner.Tag) -> Element {
            var element = Element(kind: kind, attributes: tag.attributes)
            if let raw = tag.attributes["transform"] {
                element.transform = SVGRasterizer.parseTransform(raw)
            }
            return element
        }

        /// `.className { fill: X; fill-rule: Y; }` rules out of the `<style>` block.
        private static func parseStyleClasses(_ body: String) -> [String: [String: String]] {
            var result: [String: [String: String]] = [:]
            var remainder = Substring(body)

            while let dot = remainder.firstIndex(of: "."),
                  let open = remainder[dot...].firstIndex(of: "{"),
                  let close = remainder[open...].firstIndex(of: "}") {

                let selector = remainder[remainder.index(after: dot)..<open]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var declarations: [String: String] = [:]

                for declaration in remainder[remainder.index(after: open)..<close].split(separator: ";") {
                    let pair = declaration.split(separator: ":", maxSplits: 1)
                    guard pair.count == 2 else { continue }
                    declarations[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                        pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }

                if !selector.isEmpty { result[selector] = declarations }
                remainder = remainder[remainder.index(after: close)...]
            }

            return result
        }
    }

    /// `transform="translate(a,b) rotate(c)"` — the only two functions these exports emit.
    /// Composed left to right, which for CoreGraphics means each new one pre-multiplies.
    private static func parseTransform(_ raw: String) -> CGAffineTransform? {
        var transform = CGAffineTransform.identity
        var remainder = Substring(raw)
        var matched = false

        while let open = remainder.firstIndex(of: "("),
              let close = remainder[open...].firstIndex(of: ")") {
            let name = remainder[remainder.startIndex..<open]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let values = remainder[remainder.index(after: open)..<close]
                .split(whereSeparator: { $0 == " " || $0 == "," })
                .compactMap { Double($0) }
            remainder = remainder[remainder.index(after: close)...]

            switch name {
            case "translate" where !values.isEmpty:
                transform = transform.translatedBy(x: values[0], y: values.count > 1 ? values[1] : 0)
                matched = true
            case "rotate" where !values.isEmpty:
                if values.count >= 3 {
                    transform = transform
                        .translatedBy(x: values[1], y: values[2])
                        .rotated(by: values[0] * .pi / 180)
                        .translatedBy(x: -values[1], y: -values[2])
                } else {
                    transform = transform.rotated(by: values[0] * .pi / 180)
                }
                matched = true
            case "scale" where !values.isEmpty:
                transform = transform.scaledBy(x: values[0], y: values.count > 1 ? values[1] : values[0])
                matched = true
            default:
                Log.world("SVG uses unsupported transform '\(name)' — ignoring it")
            }
        }

        return matched ? transform : nil
    }

    // MARK: - Tag scanning

    /// Single pass over the document bytes. Repeated `range(of:)` searches over a shrinking
    /// `Substring` are quadratic, which on a 2.4 MB file with 4,065 elements does not finish in
    /// any reasonable time.
    private struct TagScanner {
        struct Tag {
            var name: String
            var isClosing: Bool
            var isSelfClosing: Bool
            var attributes: [String: String] = [:]
            /// Byte ranges of the same values, for the ones too big to want as Strings.
            var rawAttributes: [String: Range<Int>] = [:]
        }

        private let bytes: [UInt8]
        private var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        private static let lessThan = UInt8(ascii: "<")
        private static let greaterThan = UInt8(ascii: ">")
        private static let slash = UInt8(ascii: "/")
        private static let equals = UInt8(ascii: "=")
        private static let bang = UInt8(ascii: "!")
        private static let question = UInt8(ascii: "?")

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private static func isNameByte(_ byte: UInt8) -> Bool {
            !isSpace(byte) && byte != greaterThan && byte != slash && byte != equals
        }

        mutating func nextTag() -> Tag? {
            while index < bytes.count {
                guard let open = seek(Self.lessThan) else { return nil }
                index = open + 1
                guard index < bytes.count else { return nil }

                // Skip comments, doctypes and processing instructions wholesale.
                if bytes[index] == Self.bang || bytes[index] == Self.question {
                    _ = seek(Self.greaterThan).map { index = $0 + 1 }
                    continue
                }

                var tag = Tag(name: "", isClosing: false, isSelfClosing: false)
                if bytes[index] == Self.slash {
                    tag.isClosing = true
                    index += 1
                }

                let nameStart = index
                while index < bytes.count, Self.isNameByte(bytes[index]) { index += 1 }
                tag.name = string(nameStart..<index)
                if tag.name.isEmpty { continue }

                readAttributes(into: &tag)
                return tag
            }
            return nil
        }

        private mutating func readAttributes(into tag: inout Tag) {
            while index < bytes.count {
                while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
                guard index < bytes.count else { return }

                if bytes[index] == Self.greaterThan {
                    index += 1
                    return
                }
                if bytes[index] == Self.slash {
                    tag.isSelfClosing = true
                    index += 1
                    continue
                }

                let nameStart = index
                while index < bytes.count, Self.isNameByte(bytes[index]) { index += 1 }
                let name = string(nameStart..<index)
                guard !name.isEmpty else {
                    index += 1     // Something unexpected; step over it rather than spinning.
                    continue
                }

                while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
                guard index < bytes.count, bytes[index] == Self.equals else {
                    tag.attributes[name] = ""
                    continue
                }
                index += 1
                while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }

                guard index < bytes.count else { return }
                let quote = bytes[index]
                guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { continue }
                index += 1

                let valueStart = index
                while index < bytes.count, bytes[index] != quote { index += 1 }
                let range = valueStart..<index
                if index < bytes.count { index += 1 }

                tag.rawAttributes[name] = range
                // `d` is most of the file's bytes and is only ever read by the path parser.
                if name != "d" { tag.attributes[name] = string(range) }
            }
        }

        /// Everything from the cursor up to `terminator`, as a String. Used for `<style>`.
        mutating func text(until terminator: String) -> String {
            let needle = [UInt8](terminator.utf8)
            let start = index
            while index + needle.count <= bytes.count {
                if bytes[index] == needle[0], Array(bytes[index..<index + needle.count]) == needle {
                    let body = string(start..<index)
                    index += needle.count
                    return body
                }
                index += 1
            }
            index = bytes.count
            return string(start..<bytes.count)
        }

        private mutating func seek(_ byte: UInt8) -> Int? {
            var cursor = index
            while cursor < bytes.count {
                if bytes[cursor] == byte { return cursor }
                cursor += 1
            }
            index = bytes.count
            return nil
        }

        private func string(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }
    }

    // MARK: - Colours

    private static var colorCache: [String: CGColor] = [:]

    private static func cgColor(named name: String) -> CGColor? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = colorCache[value] { return cached }

        var color: CGColor?

        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 {
                hex = hex.map { "\($0)\($0)" }.joined()
            }
            if hex.count == 6, let bits = UInt32(hex, radix: 16) {
                color = CGColor(red: CGFloat((bits >> 16) & 0xFF) / 255,
                                green: CGFloat((bits >> 8) & 0xFF) / 255,
                                blue: CGFloat(bits & 0xFF) / 255,
                                alpha: 1)
            }
        } else {
            // Only the named colours these files actually use.
            switch value {
            case "black": color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            case "white": color = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            case "gray", "grey": color = CGColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1)
            case "green": color = CGColor(red: 0, green: 128 / 255, blue: 0, alpha: 1)
            case "lime": color = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
            case "red": color = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            default:
                Log.world("SVG uses unsupported colour '\(value)' — treating it as black")
                color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            }
        }

        if let color { colorCache[value] = color }
        return color
    }

    // MARK: - Path data

    private static func buildPath(bytes: [UInt8], range: Range<Int>) -> CGPath? {
        let path = CGMutablePath()
        var scanner = NumberScanner(bytes: bytes, range: range)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: UInt8 = 0
        var hasGeometry = false

        while true {
            scanner.skipSeparators()
            guard let peek = scanner.peek() else { break }

            if NumberScanner.isLetter(peek) {
                command = peek
                scanner.advance()
            } else if command == 0 {
                break   // Data before any command — malformed.
            } else if command == UInt8(ascii: "M") {
                command = UInt8(ascii: "L")     // Implicit lineto after a moveto.
            } else if command == UInt8(ascii: "m") {
                command = UInt8(ascii: "l")
            }

            let relative = command >= UInt8(ascii: "a") && command <= UInt8(ascii: "z")
            let upper = relative ? command - 32 : command

            func point(_ x: Double, _ y: Double) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }

            switch Character(UnicodeScalar(upper)) {
            case "M":
                guard let x = scanner.next(), let y = scanner.next() else { return finish(path, hasGeometry) }
                current = point(x, y)
                subpathStart = current
                path.move(to: current)
                lastCubicControl = nil
                lastQuadControl = nil

            case "L":
                guard let x = scanner.next(), let y = scanner.next() else { return finish(path, hasGeometry) }
                current = point(x, y)
                path.addLine(to: current)
                hasGeometry = true
                lastCubicControl = nil
                lastQuadControl = nil

            case "H":
                guard let x = scanner.next() else { return finish(path, hasGeometry) }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                hasGeometry = true
                lastCubicControl = nil
                lastQuadControl = nil

            case "V":
                guard let y = scanner.next() else { return finish(path, hasGeometry) }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                hasGeometry = true
                lastCubicControl = nil
                lastQuadControl = nil

            case "C":
                guard let x1 = scanner.next(), let y1 = scanner.next(),
                      let x2 = scanner.next(), let y2 = scanner.next(),
                      let x = scanner.next(), let y = scanner.next()
                else { return finish(path, hasGeometry) }
                let c1 = point(x1, y1)
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                hasGeometry = true
                lastCubicControl = c2
                lastQuadControl = nil

            case "S":
                guard let x2 = scanner.next(), let y2 = scanner.next(),
                      let x = scanner.next(), let y = scanner.next()
                else { return finish(path, hasGeometry) }
                // Reflect the previous cubic control point about the current point.
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: c1, control2: c2)
                hasGeometry = true
                lastCubicControl = c2
                lastQuadControl = nil

            case "Q":
                guard let x1 = scanner.next(), let y1 = scanner.next(),
                      let x = scanner.next(), let y = scanner.next()
                else { return finish(path, hasGeometry) }
                let c = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                hasGeometry = true
                lastQuadControl = c
                lastCubicControl = nil

            case "T":
                guard let x = scanner.next(), let y = scanner.next() else { return finish(path, hasGeometry) }
                let c = lastQuadControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: c)
                hasGeometry = true
                lastQuadControl = c
                lastCubicControl = nil

            case "A":
                guard let rx = scanner.next(), let ry = scanner.next(),
                      let rotation = scanner.next(),
                      let largeArc = scanner.nextFlag(), let sweep = scanner.nextFlag(),
                      let x = scanner.next(), let y = scanner.next()
                else { return finish(path, hasGeometry) }
                let end = point(x, y)
                appendArc(to: path, from: current, to: end,
                          rx: rx, ry: ry, xAxisRotationDegrees: rotation,
                          largeArc: largeArc, sweep: sweep)
                current = end
                hasGeometry = true
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                Log.world("SVG uses unknown path command '\(Character(UnicodeScalar(command)))'")
                return finish(path, hasGeometry)
            }
        }

        return finish(path, hasGeometry)
    }

    private static func finish(_ path: CGMutablePath, _ hasGeometry: Bool) -> CGPath? {
        hasGeometry ? path.copy() : nil
    }

    /// SVG's endpoint-parameterised elliptical arc, appended as cubic Béziers.
    ///
    /// Written out rather than handed to `CGMutablePath.addArc(…, transform:)` because the
    /// `clockwise` flag there is interpreted after the transform, which makes the sweep flag's
    /// meaning depend on the handedness of the space the path ends up in. Béziers carry their
    /// own orientation and transform cleanly. Implements F.6.5 / F.6.6 of the SVG 1.1 spec,
    /// including the "scale the radii up until a solution exists" correction.
    private static func appendArc(to path: CGMutablePath,
                                  from start: CGPoint,
                                  to end: CGPoint,
                                  rx: Double, ry: Double,
                                  xAxisRotationDegrees: Double,
                                  largeArc: Bool, sweep: Bool) {
        if start == end { return }

        var rx = abs(rx)
        var ry = abs(ry)
        // Zero radii degenerate to a straight line, per the spec.
        if rx == 0 || ry == 0 {
            path.addLine(to: end)
            return
        }

        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = Double(start.x - end.x) / 2
        let dy2 = Double(start.y - end.y) / 2
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // F.6.6: grow the radii until the endpoints are reachable.
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var factor = denominator == 0 ? 0 : sqrt(numerator / denominator)
        if largeArc == sweep { factor = -factor }

        let cxp = factor * rx * y1p / ry
        let cyp = -factor * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + Double(start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + Double(start.y + end.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard len > 0 else { return 0 }
            var value = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var sweepAngle = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                               (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep && sweepAngle < 0 { sweepAngle += 2 * .pi }

        // A cubic approximates at most a quarter turn to within a fraction of a pixel.
        let segments = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / Double(segments)
        let alpha = 4.0 / 3.0 * tan(delta / 4)

        var theta = startAngle
        for _ in 0..<segments {
            let cosTheta1 = cos(theta), sinTheta1 = sin(theta)
            let theta2 = theta + delta
            let cosTheta2 = cos(theta2), sinTheta2 = sin(theta2)

            func map(_ ex: Double, _ ey: Double) -> CGPoint {
                CGPoint(x: cx + cosPhi * rx * ex - sinPhi * ry * ey,
                        y: cy + sinPhi * rx * ex + cosPhi * ry * ey)
            }

            let p1 = map(cosTheta1, sinTheta1)
            let p2 = map(cosTheta2, sinTheta2)
            let d1 = map(cosTheta1 - alpha * sinTheta1, sinTheta1 + alpha * cosTheta1)
            let d2 = map(cosTheta2 + alpha * sinTheta2, sinTheta2 - alpha * cosTheta2)

            _ = p1   // The current point already sits here; kept for clarity of the mapping.
            path.addCurve(to: p2, control1: d1, control2: d2)
            theta = theta2
        }
    }

    /// SVG path data packs numbers tightly — `3.1.2` is two numbers, and `-` doubles as a
    /// separator — so a plain split cannot handle it. Operates on raw bytes: this walks
    /// megabytes of path data and `Character` is far too slow for that.
    private struct NumberScanner {
        private let bytes: [UInt8]
        private let end: Int
        private var index: Int

        init(bytes: [UInt8], range: Range<Int>) {
            self.bytes = bytes
            self.index = range.lowerBound
            self.end = range.upperBound
        }

        static func isLetter(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        func peek() -> UInt8? {
            index < end ? bytes[index] : nil
        }

        mutating func advance() {
            index += 1
        }

        mutating func skipSeparators() {
            while index < end {
                let byte = bytes[index]
                guard byte == 0x20 || byte == 0x2C || byte == 0x0A || byte == 0x0D || byte == 0x09
                else { break }
                index += 1
            }
        }

        /// The `large-arc-flag` and `sweep-flag` are single characters, and may be written
        /// with no separator at all (`a1 1 0 011 1`).
        mutating func nextFlag() -> Bool? {
            skipSeparators()
            guard index < end else { return nil }
            let byte = bytes[index]
            if byte == UInt8(ascii: "0") || byte == UInt8(ascii: "1") {
                index += 1
                return byte == UInt8(ascii: "1")
            }
            return next().map { $0 != 0 }
        }

        mutating func next() -> Double? {
            skipSeparators()
            guard index < end else { return nil }

            var buffer = [UInt8]()
            buffer.reserveCapacity(16)
            var seenDot = false
            var seenDigit = false

            if bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                buffer.append(bytes[index])
                index += 1
            }

            while index < end {
                let byte = bytes[index]
                if Self.isDigit(byte) {
                    buffer.append(byte)
                    seenDigit = true
                    index += 1
                } else if byte == UInt8(ascii: ".") {
                    if seenDot { break }     // `3.1.2` — a second dot starts a new number.
                    seenDot = true
                    buffer.append(byte)
                    index += 1
                } else if (byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E")), seenDigit,
                          index + 1 < end,
                          Self.isDigit(bytes[index + 1]) || bytes[index + 1] == UInt8(ascii: "-")
                            || bytes[index + 1] == UInt8(ascii: "+") {
                    buffer.append(byte)
                    index += 1
                    buffer.append(bytes[index])
                    index += 1
                } else {
                    break
                }
            }

            guard seenDigit else { return nil }
            return Double(String(decoding: buffer, as: UTF8.self))
        }
    }
}
