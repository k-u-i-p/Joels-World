import UIKit

/// One character's screen-space furniture for this frame.
struct OverlayEntry {
    var id: Int
    var name: String?
    /// Screen position of the character's origin, in points.
    var screen: CGPoint
    /// True when the character passed the JS frustum test and should be drawn at all.
    var isVisible: Bool
    var chatMessage: String?
    var showsNameplate: Bool
}

/// Nameplates and speech bubbles. These are DOM elements in the web build
/// (`.character-nameplate` / `.character-chat-bubble`, positioned every frame at
/// `characters.js:1240-1290`), so they stay a UIKit layer here rather than becoming Metal
/// geometry — the text stays crisp and the styling matches `style.css` directly.
final class CharacterOverlayView: UIView {
    /// The web build refuses to draw more than three bubbles in a frame
    /// (`currentFrameChatCount`, `characters.js:1262`).
    private static let maxBubblesPerFrame = 3
    /// A bubble lives five seconds from the moment the message arrived.
    private static let bubbleLifetime: TimeInterval = 5

    private var nameplates: [Int: UILabel] = [:]
    private var bubbles: [Int: ChatBubbleView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    /// Repositions everything for this frame. `zoom` scales the offsets above the head
    /// exactly as the JS does (`45 * cameraZoom`, `55 * cameraZoom`).
    func update(entries: [OverlayEntry], zoom: Double) {
        var liveNameplates: Set<Int> = []
        var liveBubbles: Set<Int> = []
        var bubblesDrawn = 0

        let nameOffset = CGFloat(45 * zoom)
        let chatOffset = CGFloat(55 * zoom)

        for entry in entries {
            guard entry.isVisible else { continue }

            if entry.showsNameplate, let name = entry.name, !name.isEmpty {
                let label = nameplates[entry.id] ?? makeNameplate(for: entry.id)
                if label.text != name {
                    label.attributedText = Theme.outlinedText(name, size: 12)
                    label.sizeToFit()
                }
                label.center = CGPoint(x: entry.screen.x, y: entry.screen.y - nameOffset)
                label.isHidden = false
                liveNameplates.insert(entry.id)
            }

            if let message = entry.chatMessage, bubblesDrawn < Self.maxBubblesPerFrame {
                bubblesDrawn += 1
                let bubble = bubbles[entry.id] ?? makeBubble(for: entry.id)
                bubble.setMessage(message, maxWidth: bounds.width - 40)
                // `transform: translate(-50%, -100%)` — the bubble sits *above* the point.
                bubble.frame.origin = CGPoint(x: entry.screen.x - bubble.bounds.width / 2,
                                              y: entry.screen.y - chatOffset - bubble.bounds.height)
                bubble.isHidden = false
                liveBubbles.insert(entry.id)
            }
        }

        // Anything not touched this frame is off-screen, silent, or gone.
        for (id, label) in nameplates where !liveNameplates.contains(id) {
            label.isHidden = true
        }
        for (id, bubble) in bubbles where !liveBubbles.contains(id) {
            bubble.isHidden = true
        }
    }

    /// Drops every pooled view — the character set is about to be replaced wholesale.
    func reset() {
        for (_, label) in nameplates { label.removeFromSuperview() }
        for (_, bubble) in bubbles { bubble.removeFromSuperview() }
        nameplates.removeAll()
        bubbles.removeAll()
    }

    func removeCharacter(id: Int) {
        nameplates.removeValue(forKey: id)?.removeFromSuperview()
        bubbles.removeValue(forKey: id)?.removeFromSuperview()
    }

    /// Whether a message posted at `time` is still inside the bubble's five-second window.
    static func isBubbleLive(chatTime: TimeInterval?) -> Bool {
        guard let chatTime else { return false }
        return Date.timeIntervalSinceReferenceDate - chatTime < bubbleLifetime
    }

    private func makeNameplate(for id: Int) -> UILabel {
        let label = UILabel()
        label.textAlignment = .center
        addSubview(label)
        nameplates[id] = label
        return label
    }

    private func makeBubble(for id: Int) -> ChatBubbleView {
        let bubble = ChatBubbleView()
        addSubview(bubble)
        bubbles[id] = bubble
        return bubble
    }
}

/// `.character-chat-bubble` plus its `::after`-style arrow: white, rounded, drop shadow, with
/// a small triangle pointing down at the character's head.
private final class ChatBubbleView: UIView {
    private let label = UILabel()
    private let arrow = CAShapeLayer()
    private var currentMessage: String?

    private let padding = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    private let arrowHeight: CGFloat = 8
    private let arrowWidth: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isUserInteractionEnabled = false

        label.font = Theme.body(14)
        label.textColor = Theme.panelDark
        label.textAlignment = .center
        label.numberOfLines = 0
        addSubview(label)

        arrow.fillColor = UIColor.white.cgColor
        // Below the label: this layer fills the whole bubble body, so adding it on top would
        // paint over the text.
        layer.insertSublayer(arrow, at: 0)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 3)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setMessage(_ message: String, maxWidth: CGFloat) {
        guard message != currentMessage else { return }
        currentMessage = message
        label.text = message

        let available = CGSize(width: max(60, maxWidth - padding.left - padding.right),
                               height: .greatestFiniteMagnitude)
        var size = label.sizeThatFits(available)
        size.width = max(50, min(size.width, available.width))
        label.frame = CGRect(x: padding.left, y: padding.top,
                             width: size.width, height: size.height)

        bounds = CGRect(x: 0, y: 0,
                        width: size.width + padding.left + padding.right,
                        height: size.height + padding.top + padding.bottom + arrowHeight)

        let path = bubblePath(bodyHeight: bounds.height - arrowHeight)
        arrow.path = path.cgPath
        arrow.frame = bounds
        // Without an explicit path the shadow is traced from the layer's composited alpha,
        // which picks out the arrow's edges as if it were a separate view.
        layer.shadowPath = path.cgPath
    }

    /// The body and the arrow as one continuous outline. Two subpaths that merely overlap
    /// cancel each other along the seam under the non-zero fill rule, which leaves a hairline
    /// gap where the arrow meets the bubble.
    private func bubblePath(bodyHeight: CGFloat) -> UIBezierPath {
        let radius: CGFloat = 8
        let width = bounds.width
        let midX = bounds.midX
        let half = arrowWidth / 2

        let path = UIBezierPath()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addArc(withCenter: CGPoint(x: width - radius, y: radius), radius: radius,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: width, y: bodyHeight - radius))
        path.addArc(withCenter: CGPoint(x: width - radius, y: bodyHeight - radius), radius: radius,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: midX + half, y: bodyHeight))
        path.addLine(to: CGPoint(x: midX, y: bodyHeight + arrowHeight))
        path.addLine(to: CGPoint(x: midX - half, y: bodyHeight))
        path.addLine(to: CGPoint(x: radius, y: bodyHeight))
        path.addArc(withCenter: CGPoint(x: radius, y: bodyHeight - radius), radius: radius,
                    startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addArc(withCenter: CGPoint(x: radius, y: radius), radius: radius,
                    startAngle: .pi, endAngle: -.pi / 2, clockwise: true)
        path.close()
        return path
    }
}
