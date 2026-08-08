import AppKit

/// Nameplates and speech bubbles, drawn into the editor's overlay.
///
/// The iOS build pools a `UILabel` and a bubble view per character because they are DOM nodes
/// in the web original and the styling ports across directly. The editor already draws every
/// other piece of screen furniture — object boxes, roam rings, waypoint routes — into one Core
/// Graphics pass, so these go in the same pass rather than bringing a view pool with them.
///
/// Which characters are drawn, and where, comes from `CharacterOverlay`, shared with iOS.
enum AdminCharacterOverlay {
    private static let bubblePadding = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    private static let arrowHeight: CGFloat = 8
    private static let arrowWidth: CGFloat = 12
    private static let cornerRadius: CGFloat = 8
    private static let maxBubbleWidth: CGFloat = 260

    /// `entries` is already frustum-culled and projected; `bounds` is the overlay's, used only
    /// to keep a wide bubble from running off the side of the map.
    static func draw(entries: [OverlayEntry], zoom: Double, bounds: CGRect, in ctx: CGContext) {
        let nameOffset = CharacterOverlay.nameOffset(zoom: zoom)
        let chatOffset = CharacterOverlay.chatOffset(zoom: zoom)
        var bubblesDrawn = 0

        for entry in entries {
            if entry.showsNameplate, let name = entry.name, !name.isEmpty {
                drawNameplate(name, at: CGPoint(x: entry.screen.x, y: entry.screen.y - nameOffset))
            }

            guard let message = entry.chatMessage,
                  bubblesDrawn < CharacterOverlay.maxBubblesPerFrame else { continue }
            bubblesDrawn += 1
            drawBubble(message,
                       tip: CGPoint(x: entry.screen.x, y: entry.screen.y - chatOffset),
                       bounds: bounds,
                       in: ctx)
        }
    }

    // MARK: - Pieces

    /// `.character-nameplate`: white, bold, with the CSS text shadow standing in as a stroke —
    /// `AdminTheme.outlinedText`, the same recipe `Theme.outlinedText` uses on iOS.
    private static func drawNameplate(_ name: String, at centre: CGPoint) {
        let text = AdminTheme.outlinedText(name, size: 12)
        let size = text.size()
        text.draw(at: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2))
    }

    /// `.character-chat-bubble` and its arrow: white, rounded, dropped shadow, pointing down at
    /// the character's head.
    private static func drawBubble(_ message: String, tip: CGPoint, bounds: CGRect,
                                   in ctx: CGContext) {
        let text = NSAttributedString(string: message, attributes: [
            .font: AdminTheme.body(13),
            .foregroundColor: AdminTheme.panelDark,
        ])

        let available = min(maxBubbleWidth, max(60, bounds.width - 40))
            - bubblePadding.left - bubblePadding.right
        var textSize = text.boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        textSize.width = max(50, min(textSize.width.rounded(.up), available))
        textSize.height = textSize.height.rounded(.up)

        let bodyWidth = textSize.width + bubblePadding.left + bubblePadding.right
        let bodyHeight = textSize.height + bubblePadding.top + bubblePadding.bottom
        // `transform: translate(-50%, -100%)` — the body sits above the tip it points at.
        let body = CGRect(x: tip.x - bodyWidth / 2,
                          y: tip.y - arrowHeight - bodyHeight,
                          width: bodyWidth,
                          height: bodyHeight)

        let path = outline(body: body, tipY: tip.y)

        ctx.saveGState()
        // The context is flipped, so a positive height drops the shadow downwards.
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 6,
                      color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        text.draw(with: CGRect(x: body.minX + bubblePadding.left,
                               y: body.minY + bubblePadding.top,
                               width: textSize.width,
                               height: textSize.height),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// The body and the arrow as one continuous outline. Two subpaths that merely overlap
    /// cancel along the seam under the non-zero fill rule, leaving a hairline gap where the
    /// arrow meets the bubble — and the shadow traces that gap.
    ///
    /// Wound for a flipped context, so "down" is increasing Y and the arrow hangs below the
    /// body at `tipY`.
    private static func outline(body: CGRect, tipY: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let radius = cornerRadius
        let midX = body.midX
        let half = arrowWidth / 2

        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.maxY), radius: radius)
        path.addLine(to: CGPoint(x: midX + half, y: body.maxY))
        path.addLine(to: CGPoint(x: midX, y: tipY))
        path.addLine(to: CGPoint(x: midX - half, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY),
                    tangent2End: CGPoint(x: body.minX, y: body.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY),
                    tangent2End: CGPoint(x: body.maxX, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}
