import CoreGraphics
import Foundation

/// The `d="…"` grammar: the twenty path commands, the elliptical-arc conversion Core Graphics
/// has no primitive for, and the byte-level number scanner all of it runs on.
///
/// Split out from the rasteriser because it is the one part with nothing SVG-document-shaped
/// about it — hand it a byte range and it hands back a `CGPath`. The tennis court alone puts
/// 26,825 arcs through here, which is why none of it allocates a `String`.
extension SVGRasterizer {
    // MARK: - Path data

    static func buildPath(bytes: [UInt8], range: Range<Int>) -> CGPath? {
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
