import Foundation

/// A JSON value that remembers the order its object keys were written in, and re-serialises
/// them the way `JSON.stringify(value, replacer, 2)` does.
///
/// The editor writes `data/**/objects.json` and `npc.json` itself now; `server/admin.js` used
/// to. Those files are authored content under version control, so a save has to change only
/// the fields that were edited — `Foundation`'s `JSONSerialization` would reorder every key in
/// the file (its objects are `Dictionary`s) and turn a two-line change into a whole-file diff.
///
/// It is also deliberately lossless. The editor's `WorldObject` and `GameCharacter` model the
/// fields the *game* reads; the JSON carries more than that — AI agent blocks, authored
/// comments-by-convention, fields added since. Round-tripping through this type keeps
/// everything it does not understand exactly as it found it.
enum OrderedJSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.object(let a), .object(let b)):
            return a.count == b.count
                && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    // MARK: - Accessors

    var arrayValue: [OrderedJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let entries) = self else { return nil }
            return entries.first { $0.key == key }?.value
        }
        set {
            guard case .object(var entries) = self else { return }
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    // Editing in place keeps the key where the author put it — and
                    // `reordered(like:)` extends that to the keys *inside* the new value.
                    entries[index].value = newValue.reordered(like: entries[index].value)
                } else {
                    entries.remove(at: index)
                }
            } else if let newValue {
                entries.append((key: key, value: newValue))
            }
            self = .object(entries)
        }
    }

    /// Merges `updates` in, `Object.assign` style: existing keys keep their position, new ones
    /// land at the end.
    mutating func assign(_ updates: [(key: String, value: OrderedJSON)]) {
        for update in updates { self[update.key] = update.value }
    }

    /// Rewrites this value's object keys to follow the order of the value it is replacing.
    ///
    /// Only the *top-level* keys of a record keep their place on their own, because those are
    /// edited in place. A nested value arrives rebuilt from a `[String: JSONValue]`, which has
    /// no order, so the editor's `ordered(_:)` sorts it alphabetically — and saving one event
    /// on an object rewrote every `show_dialog` payload in its tree from
    /// `type, map, description` to `description, map, type`. Nothing read differently; the
    /// diff was just noise in authored, version-controlled content, which is precisely what
    /// this type exists to avoid.
    ///
    /// Keys the previous value did not have keep their incoming order, appended after the
    /// ones it did. Arrays recurse element-wise as far as they line up, which covers an event
    /// list whose actions stayed put.
    func reordered(like previous: OrderedJSON) -> OrderedJSON {
        switch (self, previous) {
        case (.object(let entries), .object(let previousEntries)):
            var remaining = entries
            var ordered: [(key: String, value: OrderedJSON)] = []
            for previousEntry in previousEntries {
                guard let index = remaining.firstIndex(where: { $0.key == previousEntry.key }) else { continue }
                let entry = remaining.remove(at: index)
                ordered.append((key: entry.key, value: entry.value.reordered(like: previousEntry.value)))
            }
            return .object(ordered + remaining)

        case (.array(let elements), .array(let previousElements)):
            return .array(elements.enumerated().map { index, element in
                previousElements.indices.contains(index)
                    ? element.reordered(like: previousElements[index])
                    : element
            })

        default:
            return self
        }
    }

    // MARK: - Parsing

    /// Parses with `JSONSerialization` and then re-reads the raw bytes to recover key order,
    /// which the Foundation object graph has already thrown away.
    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw Error.trailingContent(offset: parser.offset) }
        return value
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case unexpectedEnd
        case unexpected(byte: UInt8, offset: Int)
        case invalidNumber(offset: Int)
        case invalidEscape(offset: Int)
        case trailingContent(offset: Int)

        var description: String {
            switch self {
            case .unexpectedEnd: return "unexpected end of JSON"
            case .unexpected(let byte, let offset):
                return "unexpected byte 0x\(String(byte, radix: 16)) at \(offset)"
            case .invalidNumber(let offset): return "invalid number at \(offset)"
            case .invalidEscape(let offset): return "invalid escape at \(offset)"
            case .trailingContent(let offset): return "trailing content at \(offset)"
            }
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func skipWhitespace() {
            while offset < bytes.count {
                switch bytes[offset] {
                case 0x20, 0x09, 0x0A, 0x0D: offset += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> OrderedJSON {
            skipWhitespace()
            guard offset < bytes.count else { throw Error.unexpectedEnd }

            switch bytes[offset] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default: return .number(try parseNumber())
            }
        }

        private mutating func expect(_ literal: String) throws {
            for character in literal.utf8 {
                guard offset < bytes.count, bytes[offset] == character else {
                    throw Error.unexpected(byte: offset < bytes.count ? bytes[offset] : 0,
                                           offset: offset)
                }
                offset += 1
            }
        }

        private mutating func parseObject() throws -> OrderedJSON {
            offset += 1 // {
            var entries: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
                offset += 1
                return .object(entries)
            }
            while true {
                skipWhitespace()
                let key = try parseString()
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else {
                    throw Error.unexpected(byte: offset < bytes.count ? bytes[offset] : 0,
                                           offset: offset)
                }
                offset += 1
                entries.append((key: key, value: try parseValue()))
                skipWhitespace()
                guard offset < bytes.count else { throw Error.unexpectedEnd }
                if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                if bytes[offset] == UInt8(ascii: "}") { offset += 1; break }
                throw Error.unexpected(byte: bytes[offset], offset: offset)
            }
            return .object(entries)
        }

        private mutating func parseArray() throws -> OrderedJSON {
            offset += 1 // [
            var items: [OrderedJSON] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
                offset += 1
                return .array(items)
            }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                guard offset < bytes.count else { throw Error.unexpectedEnd }
                if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                if bytes[offset] == UInt8(ascii: "]") { offset += 1; break }
                throw Error.unexpected(byte: bytes[offset], offset: offset)
            }
            return .array(items)
        }

        private mutating func parseString() throws -> String {
            guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else {
                throw Error.unexpected(byte: offset < bytes.count ? bytes[offset] : 0,
                                       offset: offset)
            }
            offset += 1
            var scalars: [UInt8] = []
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == UInt8(ascii: "\"") {
                    offset += 1
                    return String(decoding: scalars, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    offset += 1
                    guard offset < bytes.count else { throw Error.unexpectedEnd }
                    let escape = bytes[offset]
                    offset += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): scalars.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): scalars.append(UInt8(ascii: "/"))
                    case UInt8(ascii: "b"): scalars.append(0x08)
                    case UInt8(ascii: "f"): scalars.append(0x0C)
                    case UInt8(ascii: "n"): scalars.append(0x0A)
                    case UInt8(ascii: "r"): scalars.append(0x0D)
                    case UInt8(ascii: "t"): scalars.append(0x09)
                    case UInt8(ascii: "u"):
                        let scalar = try parseUnicodeEscape()
                        scalars.append(contentsOf: Array(String(scalar).utf8))
                    default: throw Error.invalidEscape(offset: offset - 1)
                    }
                    continue
                }
                scalars.append(byte)
                offset += 1
            }
            throw Error.unexpectedEnd
        }

        /// `\uXXXX`, including the surrogate pair a non-BMP character arrives as. The offset is
        /// already past the `u`.
        private mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let high = try parseHex4()
            if high >= 0xD800, high <= 0xDBFF,
               offset + 1 < bytes.count,
               bytes[offset] == UInt8(ascii: "\\"), bytes[offset + 1] == UInt8(ascii: "u") {
                let mark = offset
                offset += 2
                let low = try parseHex4()
                if low >= 0xDC00, low <= 0xDFFF {
                    let combined = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
                    if let scalar = Unicode.Scalar(combined) { return scalar }
                }
                offset = mark
            }
            guard let scalar = Unicode.Scalar(high) else {
                throw Error.invalidEscape(offset: offset)
            }
            return scalar
        }

        private mutating func parseHex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard offset < bytes.count else { throw Error.unexpectedEnd }
                let byte = bytes[offset]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a")) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A")) + 10
                default: throw Error.invalidEscape(offset: offset)
                }
                value = value << 4 | digit
                offset += 1
            }
            return value
        }

        private mutating func parseNumber() throws -> Double {
            let start = offset
            while offset < bytes.count, isNumberByte(bytes[offset]) { offset += 1 }
            guard offset > start else {
                throw Error.unexpected(byte: offset < bytes.count ? bytes[offset] : 0,
                                       offset: offset)
            }
            let text = String(decoding: bytes[start..<offset], as: UTF8.self)
            guard let value = Double(text) else { throw Error.invalidNumber(offset: start) }
            return value
        }

        private func isNumberByte(_ byte: UInt8) -> Bool {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"),
                 UInt8(ascii: "+"), UInt8(ascii: "-"):
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Serialising

    /// `JSON.stringify(value, null, 2)`, byte for byte: two-space indent, `": "` between key
    /// and value, `",\n"` between entries, `[]`/`{}` for empty containers, and no trailing
    /// newline. The server wrote these files that way for years and the diffs in git are that
    /// shape; matching it means an edit shows up as the fields that changed.
    func serialized() -> Data {
        var out = ""
        write(into: &out, indent: 0)
        return Data(out.utf8)
    }

    private func write(into out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)

        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let value):
            out += Self.format(value)
        case .string(let value):
            out += Self.quote(value)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.write(into: &out, indent: indent + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let entries):
            if entries.isEmpty { out += "{}"; return }
            out += "{\n"
            for (index, entry) in entries.enumerated() {
                out += inner + Self.quote(entry.key) + ": "
                entry.value.write(into: &out, indent: indent + 1)
                out += index == entries.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    /// JavaScript prints a `Number` in its shortest round-tripping form and drops the fraction
    /// on a whole number — `40`, not `40.0`. Swift's `description` is also shortest
    /// round-tripping, so only the integral case needs handling.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }  // JSON.stringify(NaN) === "null"
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return value.description
    }

    /// JSON string escaping as `JSON.stringify` does it: quote, backslash and the control
    /// characters only. Anything else — including every non-ASCII character — is written
    /// through as UTF-8, which is what the existing files contain.
    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
