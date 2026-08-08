import UIKit

/// The top-of-screen overlay: the NPC portrait, the map name, the chat field and the feed of
/// recent chat messages. Port of `#top-center-ui` (`index.html:59-75`) and the chat stack
/// behaviour in `ui.js:232-286`.
final class HUDView: UIView {
    /// Fired when the player submits a line of chat. `/emote` lines arrive here too, exactly
    /// as the `chatSubmit` event does in the JS.
    var onChatSubmit: ((String) -> Void)?

    private let wrapper = UIStackView()
    private let header = UIStackView()
    private let avatarView = UIImageView()
    private let mapNameLabel = UILabel()
    private let chatField = UITextField()
    private let chatStack = UIStackView()

    private var avatarWidth: NSLayoutConstraint!
    private var avatarHeight: NSLayoutConstraint!

    /// Which NPC the portrait belongs to, so only that NPC's exit clears it. The rule is
    /// shared with the editor's portrait; only the chrome around it differs.
    private var avatarOwner = PortraitOwner()
    /// The map's own name, restored when the portrait goes away
    /// (`dataset.originalName`, `ui.js:36`).
    private var mapName: String?

    /// A live chat row and the wall-clock time it should disappear.
    private struct ChatRow {
        let view: UIView
        var expiresAt: TimeInterval
    }
    private var chatRows: [ChatRow] = []
    private var sweepTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Layout

    private func setup() {
        // The overlay itself must not swallow touches meant for the world — only its
        // controls do (`pointer-events: none` on `#top-center-ui`).
        backgroundColor = .clear
        isUserInteractionEnabled = true

        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.axis = .vertical
        wrapper.spacing = 10
        wrapper.alignment = .fill
        addSubview(wrapper)

        header.axis = .horizontal
        header.spacing = 15
        header.alignment = .bottom
        wrapper.addArrangedSubview(header)

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 8
        avatarView.layer.borderWidth = 2
        avatarView.layer.borderColor = Theme.portraitBorder.cgColor
        avatarView.alpha = 0
        avatarWidth = avatarView.widthAnchor.constraint(equalToConstant: 0)
        avatarHeight = avatarView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([avatarWidth, avatarHeight])
        header.addArrangedSubview(avatarView)

        let right = UIStackView()
        right.axis = .vertical
        right.spacing = 10
        right.alignment = .fill
        header.addArrangedSubview(right)

        mapNameLabel.font = Theme.display(36)
        mapNameLabel.textColor = .white
        mapNameLabel.textAlignment = .center
        mapNameLabel.adjustsFontSizeToFitWidth = true
        mapNameLabel.minimumScaleFactor = 0.5
        mapNameLabel.layer.shadowColor = UIColor.black.cgColor
        mapNameLabel.layer.shadowOpacity = 0.8
        mapNameLabel.layer.shadowRadius = 4
        mapNameLabel.layer.shadowOffset = CGSize(width: 2, height: 2)
        right.addArrangedSubview(mapNameLabel)

        // `.glass-input`
        chatField.translatesAutoresizingMaskIntoConstraints = false
        chatField.placeholder = "Tap to chat..."
        chatField.attributedPlaceholder = NSAttributedString(
            string: "Tap to chat...",
            attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.7)])
        chatField.textColor = .white
        chatField.tintColor = .white
        chatField.font = Theme.body(14)
        chatField.backgroundColor = UIColor(white: 1, alpha: 0.2)
        chatField.layer.cornerRadius = 8
        chatField.layer.borderWidth = 1
        chatField.layer.borderColor = Theme.glassBorder.cgColor
        chatField.returnKeyType = .send
        chatField.autocorrectionType = .yes
        chatField.autocapitalizationType = .sentences
        chatField.delegate = self
        chatField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        chatField.leftViewMode = .always
        chatField.heightAnchor.constraint(equalToConstant: 38).isActive = true
        right.addArrangedSubview(chatField)

        chatStack.axis = .vertical
        chatStack.spacing = 5
        chatStack.alignment = .fill
        wrapper.addArrangedSubview(chatStack)

        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            wrapper.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            wrapper.centerXAnchor.constraint(equalTo: centerXAnchor),
            wrapper.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 30),
            wrapper.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -30),
            wrapper.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            wrapper.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -60)
                .withPriority(.defaultHigh),
        ])
    }

    /// Only the chat field and the live chat rows are hit-testable; everything else falls
    /// through to the Metal view underneath.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for subview in [chatField] where !subview.isHidden {
            if subview.convert(subview.bounds, to: self).contains(point) { return true }
        }
        return false
    }

    // MARK: - Map name and portrait

    func setMapName(_ name: String?) {
        mapName = name
        // A portrait currently owns the title bar; it restores this name when it goes.
        if avatarOwner.isVacant { mapNameLabel.text = name }
    }

    /// The `avatar` event handler (`events.js:5-51`): the portrait slides in and the title
    /// bar takes the NPC's name.
    func showAvatar(sourceId: Int, name: String?, imagePath: String) {
        avatarOwner.claim(sourceId)
        mapNameLabel.text = name ?? "NPC"

        ImageLoader.load(path: imagePath) { [weak self] image in
            guard let self, self.avatarOwner.sourceId == sourceId, let image else { return }
            self.avatarView.image = image
            self.avatarWidth.constant = 128
            self.avatarHeight.constant = 128
            UIView.animate(withDuration: 0.3) {
                self.avatarView.alpha = 1
                self.layoutIfNeeded()
            }
        }
    }

    /// `cleanupNpcUI` — only the NPC that owns the portrait can dismiss it.
    func hideAvatar(sourceId: Int?) {
        guard avatarOwner.release(sourceId) else { return }
        mapNameLabel.text = mapName

        avatarWidth.constant = 0
        avatarHeight.constant = 0
        UIView.animate(withDuration: 0.3, animations: {
            self.avatarView.alpha = 0
            self.layoutIfNeeded()
        }, completion: { _ in
            if self.avatarOwner.isVacant { self.avatarView.image = nil }
        })
    }

    // MARK: - Chat feed

    /// Port of `addServerChatMessage` (`ui.js:232`). Newest on top, five at a time, thirty
    /// seconds each.
    ///
    /// **Reproduced quirk:** every existing row loses ten seconds when a new one arrives. The
    /// JS compares an absolute epoch timestamp against `20000` (`ui.js:241`), which is always
    /// true, so the `-2500` branch it looks like it has is unreachable. Older messages
    /// therefore clear faster the busier the chat gets, which is the behaviour players see.
    func addChatMessage(sender: String, message: String) {
        let now = Date.timeIntervalSinceReferenceDate

        for index in chatRows.indices {
            chatRows[index].expiresAt -= 10
        }

        let row = makeChatRow(sender: sender, message: message)
        chatStack.insertArrangedSubview(row, at: 0)
        chatRows.insert(ChatRow(view: row, expiresAt: now + 30), at: 0)

        row.alpha = 0
        row.transform = CGAffineTransform(translationX: 0, y: -10)
        UIView.animate(withDuration: 0.3) {
            row.alpha = 1
            row.transform = .identity
        }

        while chatRows.count > 5 {
            let last = chatRows.removeLast()
            last.view.removeFromSuperview()
        }

        startSweepIfNeeded()
    }

    /// Drops every row without animating — used when the map changes.
    func clearChat() {
        for row in chatRows { row.view.removeFromSuperview() }
        chatRows.removeAll()
    }

    private func makeChatRow(sender: String, message: String) -> UIView {
        let label = PaddedLabel()
        label.numberOfLines = 0
        label.backgroundColor = Theme.chatRowBackground
        label.layer.cornerRadius = 8
        label.layer.borderWidth = 1
        label.layer.borderColor = Theme.glassBorder.cgColor
        label.clipsToBounds = true

        let text = NSMutableAttributedString(
            string: "\(sender): ",
            attributes: [.font: Theme.body(14, weight: .bold),
                         .foregroundColor: Theme.primaryHover])
        text.append(NSAttributedString(
            string: message,
            attributes: [.font: Theme.body(14),
                         .foregroundColor: UIColor.black]))
        label.attributedText = text
        return label
    }

    private func startSweepIfNeeded() {
        guard sweepTimer == nil else { return }
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = Date.timeIntervalSinceReferenceDate

            let expired = self.chatRows.filter { $0.expiresAt <= now }
            guard !expired.isEmpty else {
                if self.chatRows.isEmpty {
                    timer.invalidate()
                    self.sweepTimer = nil
                }
                return
            }

            self.chatRows.removeAll { $0.expiresAt <= now }
            // `.fade-out` — opacity, a small lift and a height collapse over half a second.
            UIView.animate(withDuration: 0.5, animations: {
                for row in expired {
                    row.view.alpha = 0
                    row.view.transform = CGAffineTransform(translationX: 0, y: -10)
                    row.view.isHidden = true
                }
                self.layoutIfNeeded()
            }, completion: { _ in
                for row in expired { row.view.removeFromSuperview() }
            })
        }
    }

    // MARK: - Chat entry

    var isChatFocused: Bool { chatField.isFirstResponder }

    func dismissKeyboard() {
        chatField.resignFirstResponder()
    }
}

extension HUDView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let message = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        textField.text = ""
        textField.resignFirstResponder()
        // `maxlength="80"` on the input.
        if !message.isEmpty { onChatSubmit?(String(message.prefix(80))) }
        return true
    }
}

/// A label with the chat row's 10 px padding — `UILabel` has no content insets of its own.
private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    /// `intrinsicContentSize` is derived from `textRect(forBounds:)`, so the outset below is
    /// already in the measurement — adding the insets again here doubled every row's padding.
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets),
                                  limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left,
                                           bottom: -insets.bottom, right: -insets.right))
    }
}

extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
