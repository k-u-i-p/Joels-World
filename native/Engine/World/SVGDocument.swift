import CoreGraphics
import Foundation

/// Turning the bytes of an SVG file into a flat, document-ordered list of drawable elements.
///
/// There is no DOM: `<g>` open and close are elements in the same list as the shapes, so the
/// renderer can keep a style stack and walk once. Document order is preserved exactly, because
/// it is what decides which of two overlapping shapes wins.
extension SVGRasterizer {
    // MARK: - Document parsing

    enum Kind {
        case path, rect, circle, ellipse, groupOpen, groupClose
    }

    struct Element {
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

    struct Document {
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

    static func cgColor(named name: String) -> CGColor? {
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
}
