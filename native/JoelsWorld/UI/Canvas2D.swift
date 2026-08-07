import CoreGraphics
import UIKit

/// A `CanvasRenderingContext2D` work-alike over `CGContext`.
///
/// The tennis minigame is the one part of the game the web build draws in 2D rather than
/// through three.js, and its rendering code — the humanoid, the racket, the shadows — is a
/// dense sequence of canvas transform and gradient calls. Emulating the canvas API keeps those
/// ports line-for-line comparable with `tennis.js` and `characters.js`, which is what every
/// earlier phase's parity checking depended on.
///
/// Two canvas behaviours are reproduced deliberately, because the JS relies on both:
///
/// - **Path points are baked into canvas space as they are added**, not at paint time.
///   `drawStretchingLeg` (`tennis.js:1785`) issues a `moveTo` inside a rotate/translate/rotate,
///   restores, and then issues the `lineTo` — the line it gets spans two different transforms.
/// - **The pen is scaled by the transform in force when `stroke()` runs**, so `lineWidth` is in
///   user space at that moment. Both fall out of storing the path in canvas space and mapping
///   it back through the inverse transform when painting.
final class Canvas2D {
    private let ctx: CGContext

    /// The canvas CTM, tracked separately from the context's own so it starts at identity the
    /// way a fresh `<canvas>` does — a `UIView` draw context arrives with a flip already applied.
    private(set) var transform: CGAffineTransform = .identity

    var fillStyle: Paint = .color(CSS.black())
    var strokeStyle: Paint = .color(CSS.black())
    var lineWidth: CGFloat = 1
    var lineCap: CGLineCap = .butt
    var lineJoin: CGLineJoin = .miter
    var lineDash: [CGFloat] = []
    var font: UIFont = .systemFont(ofSize: 10)

    private var path = CGMutablePath()
    private var currentPoint: CGPoint?
    private var subpathStart: CGPoint?
    private var stack: [State] = []

    private struct State {
        var transform: CGAffineTransform
        var fillStyle: Paint
        var strokeStyle: Paint
        var lineWidth: CGFloat
        var lineCap: CGLineCap
        var lineJoin: CGLineJoin
        var lineDash: [CGFloat]
        var font: UIFont
    }

    // MARK: - Paint

    struct Gradient {
        enum Kind {
            case linear(from: CGPoint, to: CGPoint)
            case radial(from: CGPoint, startRadius: CGFloat, to: CGPoint, endRadius: CGFloat)
        }

        var kind: Kind
        var stops: [(offset: CGFloat, color: CGColor)] = []

        mutating func addColorStop(_ offset: CGFloat, _ color: CGColor) {
            stops.append((offset, color))
        }
    }

    enum Paint {
        case color(CGColor)
        case gradient(Gradient)
    }

    init(_ ctx: CGContext) {
        self.ctx = ctx
    }

    // MARK: - State

    func save() {
        stack.append(State(transform: transform,
                           fillStyle: fillStyle,
                           strokeStyle: strokeStyle,
                           lineWidth: lineWidth,
                           lineCap: lineCap,
                           lineJoin: lineJoin,
                           lineDash: lineDash,
                           font: font))
        ctx.saveGState()
    }

    func restore() {
        guard let state = stack.popLast() else { return }
        ctx.restoreGState()
        transform = state.transform
        fillStyle = state.fillStyle
        strokeStyle = state.strokeStyle
        lineWidth = state.lineWidth
        lineCap = state.lineCap
        lineJoin = state.lineJoin
        lineDash = state.lineDash
        font = state.font
    }

    // MARK: - Transform
    //
    // `translatedBy`/`scaledBy`/`rotated` pre-multiply, which is exactly what the canvas
    // methods do: a point added afterwards is mapped by the new transform first.

    func translate(_ x: CGFloat, _ y: CGFloat) {
        transform = transform.translatedBy(x: x, y: y)
        ctx.translateBy(x: x, y: y)
    }

    func scale(_ x: CGFloat, _ y: CGFloat) {
        transform = transform.scaledBy(x: x, y: y)
        ctx.scaleBy(x: x, y: y)
    }

    func rotate(_ radians: CGFloat) {
        transform = transform.rotated(by: radians)
        ctx.rotate(by: radians)
    }

    /// Canvas-space position of a point given in the current user space — the port of
    /// `ctx.getTransform().transformPoint(...)`, which `drawRacket` uses to recover where the
    /// racket head ended up.
    func transformPoint(_ point: CGPoint) -> CGPoint {
        point.applying(transform)
    }

    // MARK: - Path building
    //
    // Every point is mapped into canvas space as it is added, matching the canvas spec.

    func beginPath() {
        path = CGMutablePath()
        currentPoint = nil
        subpathStart = nil
    }

    func moveTo(_ x: CGFloat, _ y: CGFloat) {
        let point = CGPoint(x: x, y: y).applying(transform)
        path.move(to: point)
        currentPoint = point
        subpathStart = point
    }

    func lineTo(_ x: CGFloat, _ y: CGFloat) {
        let point = CGPoint(x: x, y: y).applying(transform)
        ensureStart(point)
        path.addLine(to: point)
        currentPoint = point
    }

    func bezierCurveTo(_ c1x: CGFloat, _ c1y: CGFloat,
                       _ c2x: CGFloat, _ c2y: CGFloat,
                       _ x: CGFloat, _ y: CGFloat) {
        let end = CGPoint(x: x, y: y).applying(transform)
        ensureStart(end)
        path.addCurve(to: end,
                      control1: CGPoint(x: c1x, y: c1y).applying(transform),
                      control2: CGPoint(x: c2x, y: c2y).applying(transform))
        currentPoint = end
    }

    func quadraticCurveTo(_ cx: CGFloat, _ cy: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        let end = CGPoint(x: x, y: y).applying(transform)
        ensureStart(end)
        path.addQuadCurve(to: end, control: CGPoint(x: cx, y: cy).applying(transform))
        currentPoint = end
    }

    func arc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat,
             _ startAngle: CGFloat, _ endAngle: CGFloat, counterclockwise: Bool = false) {
        ellipse(x, y, radius, radius, 0, startAngle, endAngle, counterclockwise: counterclockwise)
    }

    func ellipse(_ x: CGFloat, _ y: CGFloat, _ radiusX: CGFloat, _ radiusY: CGFloat,
                 _ rotation: CGFloat, _ startAngle: CGFloat, _ endAngle: CGFloat,
                 counterclockwise: Bool = false) {
        var sweep = endAngle - startAngle
        if counterclockwise {
            if sweep > 0 { sweep -= 2 * .pi }
            if sweep < -2 * .pi { sweep = -2 * .pi }
        } else {
            if sweep < 0 { sweep += 2 * .pi }
            if sweep > 2 * .pi { sweep = 2 * .pi }
        }

        // Unit circle → ellipse → user rotation/offset → canvas space, all in one matrix, so the
        // arc bakes into canvas space like every other path point.
        let unitToCanvas = CGAffineTransform(scaleX: radiusX, y: radiusY)
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: x, y: y))
            .concatenating(transform)

        let steps = max(2, Int(ceil(abs(sweep) / (.pi / 16))))
        for step in 0...steps {
            let angle = startAngle + sweep * CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: cos(angle), y: sin(angle)).applying(unitToCanvas)
            if step == 0 {
                if currentPoint == nil {
                    path.move(to: point)
                    subpathStart = point
                } else {
                    path.addLine(to: point)
                }
            } else {
                path.addLine(to: point)
            }
            currentPoint = point
        }
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        moveTo(x, y)
        lineTo(x + width, y)
        lineTo(x + width, y + height)
        lineTo(x, y + height)
        closePath()
    }

    func roundRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
        let r = min(radius, min(width, height) / 2)
        moveTo(x + r, y)
        lineTo(x + width - r, y)
        quadraticCurveTo(x + width, y, x + width, y + r)
        lineTo(x + width, y + height - r)
        quadraticCurveTo(x + width, y + height, x + width - r, y + height)
        lineTo(x + r, y + height)
        quadraticCurveTo(x, y + height, x, y + height - r)
        lineTo(x, y + r)
        quadraticCurveTo(x, y, x + r, y)
        closePath()
    }

    func closePath() {
        guard currentPoint != nil else { return }
        path.closeSubpath()
        currentPoint = subpathStart
    }

    private func ensureStart(_ fallback: CGPoint) {
        if currentPoint == nil {
            path.move(to: fallback)
            currentPoint = fallback
            subpathStart = fallback
        }
    }

    // MARK: - Painting

    func fill(evenOdd: Bool = false) {
        guard let userPath = userSpacePath() else { return }
        paint(fillStyle) { context in
            context.addPath(userPath)
            context.clip(using: evenOdd ? .evenOdd : .winding)
        } solid: { context in
            context.addPath(userPath)
            context.fillPath(using: evenOdd ? .evenOdd : .winding)
        }
    }

    func stroke() {
        guard let userPath = userSpacePath() else { return }
        applyStrokeAttributes()
        paint(strokeStyle) { context in
            context.addPath(userPath)
            context.replacePathWithStrokedPath()
            context.clip()
        } solid: { context in
            context.addPath(userPath)
            context.strokePath()
        }
    }

    func clip(evenOdd: Bool = false) {
        guard let userPath = userSpacePath() else { return }
        ctx.addPath(userPath)
        ctx.clip(using: evenOdd ? .evenOdd : .winding)
    }

    func fillRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
        let saved = path
        let savedPoint = currentPoint
        let savedStart = subpathStart
        beginPath()
        rect(x, y, width, height)
        fill()
        path = saved
        currentPoint = savedPoint
        subpathStart = savedStart
    }

    /// `textAlign = 'center'`, `textBaseline = 'middle'` — the only alignment the tennis code
    /// uses, for the ball emoji.
    func fillTextCentered(_ text: String, _ x: CGFloat, _ y: CGFloat) {
        // A gradient fill style has no meaning for the one string this draws (a colour emoji),
        // so it falls back to black rather than skipping the glyph.
        var color = CSS.black()
        if case .color(let value) = fillStyle { color = value }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(cgColor: color),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()

        UIGraphicsPushContext(ctx)
        string.draw(at: CGPoint(x: x - size.width / 2, y: y - size.height / 2))
        UIGraphicsPopContext()
    }

    /// A square image centred on the origin, `size` units on a side. Stands in for
    /// `fillText` of an emoji where the platform cannot draw one.
    func drawImageCentered(_ image: UIImage, size: CGFloat) {
        guard let cgImage = image.cgImage else { return }
        let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)

        ctx.saveGState()
        // CoreGraphics draws images bottom-up; the surrounding context is UIKit's flipped one.
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - Gradients

    func createLinearGradient(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Gradient {
        Gradient(kind: .linear(from: CGPoint(x: x0, y: y0), to: CGPoint(x: x1, y: y1)))
    }

    func createRadialGradient(_ x0: CGFloat, _ y0: CGFloat, _ r0: CGFloat,
                              _ x1: CGFloat, _ y1: CGFloat, _ r1: CGFloat) -> Gradient {
        Gradient(kind: .radial(from: CGPoint(x: x0, y: y0), startRadius: r0,
                               to: CGPoint(x: x1, y: y1), endRadius: r1))
    }

    // MARK: - Internals

    /// The stored canvas-space path, mapped back into the current user space. The context then
    /// re-applies its own CTM, which puts it back exactly where it was — but with the pen and
    /// any gradient measured in user space, as the canvas spec requires.
    private func userSpacePath() -> CGPath? {
        guard !path.isEmpty else { return nil }
        var inverse = transform.inverted()
        return path.copy(using: &inverse)
    }

    private func applyStrokeAttributes() {
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(lineCap)
        ctx.setLineJoin(lineJoin)
        if lineDash.isEmpty {
            ctx.setLineDash(phase: 0, lengths: [])
        } else {
            ctx.setLineDash(phase: 0, lengths: lineDash)
        }
    }

    private func paint(_ style: Paint,
                       clipTo: (CGContext) -> Void,
                       solid: (CGContext) -> Void) {
        switch style {
        case .color(let color):
            ctx.setFillColor(color)
            ctx.setStrokeColor(color)
            solid(ctx)

        case .gradient(let gradient):
            guard let cgGradient = makeGradient(gradient) else { return }
            ctx.saveGState()
            clipTo(ctx)
            switch gradient.kind {
            case .linear(let from, let to):
                ctx.drawLinearGradient(cgGradient, start: from, end: to,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial(let from, let startRadius, let to, let endRadius):
                ctx.drawRadialGradient(cgGradient,
                                       startCenter: from, startRadius: startRadius,
                                       endCenter: to, endRadius: endRadius,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
        }
    }

    private func makeGradient(_ gradient: Gradient) -> CGGradient? {
        guard !gradient.stops.isEmpty else { return nil }
        let colors = gradient.stops.map(\.color) as CFArray
        let locations = gradient.stops.map(\.offset)
        return CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors,
                          locations: locations)
    }
}

// MARK: - Colour helpers

/// The CSS colour forms the ported drawing code writes, as `CGColor`s.
enum CSS {
    /// `rgba(r, g, b, a)` with 0–255 channels, matching the CSS strings the JS writes.
    static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static func black(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: 0, green: 0, blue: 0, alpha: alpha)
    }

    static func white(_ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
    }

    /// `#rrggbb`, the only form the character data uses.
    static func hex(_ value: String) -> CGColor {
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let bits = UInt32(hex, radix: 16) else { return black() }
        return CGColor(red: CGFloat((bits >> 16) & 0xFF) / 255,
                       green: CGFloat((bits >> 8) & 0xFF) / 255,
                       blue: CGFloat(bits & 0xFF) / 255,
                       alpha: 1)
    }

    /// Port of `shadeColor` (`characters.js:320`). Scales each channel by `100 + percent`
    /// percent and clamps — note it truncates, because the JS runs the result through
    /// `parseInt`.
    static func shade(_ value: String, _ percent: Double) -> CGColor {
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let bits = UInt32(hex, radix: 16) else { return black() }

        func channel(_ raw: UInt32) -> CGFloat {
            let scaled = Double(raw) * (100 + percent) / 100
            return CGFloat(min(255, max(0, scaled.rounded(.towardZero)))) / 255
        }

        return CGColor(red: channel((bits >> 16) & 0xFF),
                       green: channel((bits >> 8) & 0xFF),
                       blue: channel(bits & 0xFF),
                       alpha: 1)
    }
}
