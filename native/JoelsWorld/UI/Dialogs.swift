import UIKit

// MARK: - Emotes

/// `#emotes-dialog`. The web build fetched the list from `/api/config` (`ui.js:145-205`);
/// `EmoteCatalog` reads `Emotes.table` instead, so the picker offers exactly the emotes that
/// can pose the rig.
final class EmotesDialogView: PanelDialogView {
    /// The chat line the tapped row submits, e.g. `/dance`.
    var onEmote: ((String) -> Void)?

    /// `emoteEmojis` (`ui.js:167`); anything not listed falls back to 💬.
    private static let emoji: [String: String] = [
        "dance": "🕺", "fart": "💨", "dead": "💀", "cry": "😭", "rugby": "🏉",
        "sit": "🪑", "jump": "🦘", "eat": "🍔", "lunch": "🥪", "tennis": "🎾",
    ]

    private var populatedCount = 0

    init() {
        super.init(title: "Emotes")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func present() {
        super.present()
        // Retries on every open until the list arrives, so a dropped request is not fatal.
        EmoteCatalog.load { [weak self] emotes in
            guard let self, emotes.count != self.populatedCount else { return }
            self.populate(emotes)
        }
    }

    private func populate(_ emotes: [String]) {
        populatedCount = emotes.count
        for view in content.arrangedSubviews { view.removeFromSuperview() }

        for emote in emotes {
            let row = EmoteRowView(value: emote,
                                   icon: Self.emoji[emote] ?? "💬",
                                   title: emote.prefix(1).uppercased() + emote.dropFirst())
            row.addTarget(self, action: #selector(emoteTapped), for: .touchUpInside)
            content.addArrangedSubview(row)
        }
    }

    @objc private func emoteTapped(_ sender: EmoteRowView) {
        dismiss()
        onEmote?("/" + sender.value)
    }
}

// MARK: - Badges

/// `#badges-dialog`. The seven badges are authored in `index.html:168-213`, not served, so
/// the list is hard-coded here too.
final class BadgesDialogView: PanelDialogView {
    private static let badges: [(id: String, icon: String, title: String)] = [
        ("rugby", "🏉", "Rugby"),
        ("tennis", "🎾", "Tennis"),
        ("swimming", "🏊", "Swimming"),
        ("tig", "🏃", "Tig"),
        ("good friend", "🫂", "Good Friend"),
        ("tower defence", "🏰", "Tower Defence"),
        ("detention", "🚫", "Detention"),
    ]

    private var rows: [EmoteRowView] = []

    init() {
        super.init(title: "Badges")

        for badge in Self.badges {
            let row = EmoteRowView(value: badge.id, icon: badge.icon, title: badge.title,
                                   showsStatus: true)
            row.isUserInteractionEnabled = false
            row.setEarned(false)
            rows.append(row)
            content.addArrangedSubview(row)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Case-insensitive, matching `populateBadgesList` (`ui.js:220`).
    func setEarned(_ earned: [String]) {
        let lowered = Set(earned.map { $0.lowercased() })
        for row in rows { row.setEarned(lowered.contains(row.value.lowercased())) }
    }
}

// MARK: - Help

/// `#help-dialog`, with the controls section rewritten for a device that has no arrow keys.
final class HelpDialogView: PanelDialogView {
    init() {
        super.init(title: "Help")

        content.spacing = 15
        content.addArrangedSubview(section(title: "🎮 Controls", lines: [
            "Move: drag the joystick — the direction you push is the way you face.",
            "Run: keep pushing for a couple of seconds.",
            "Interact: walk up to people and doors. Figure out how to escape school!",
        ]))
        content.addArrangedSubview(section(title: "💬 Chat", lines: [
            "Tap the chat box at the top to say something to other players.",
            "Tap ☺️ to pick an emote.",
        ]))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `.help-section` — a darker inset block with a heading and a short list.
    private func section(title: String, lines: [String]) -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 8
        container.isLayoutMarginsRelativeArrangement = true
        container.layoutMargins = UIEdgeInsets(top: 15, left: 15, bottom: 15, right: 15)
        container.backgroundColor = UIColor(white: 0, alpha: 0.2)
        container.layer.cornerRadius = 8

        let heading = UILabel()
        heading.font = Theme.body(17, weight: .semibold)
        heading.textColor = .white
        heading.setEmojiText(title)
        container.addArrangedSubview(heading)

        for line in lines {
            let label = UILabel()
            label.font = Theme.body(14)
            label.textColor = Theme.textMuted
            label.setEmojiText("• " + line)
            label.numberOfLines = 0
            container.addArrangedSubview(label)
        }
        return container
    }
}

// MARK: - Minimap

/// `#minimap-dialog`. The image is `/minimaps/<mapId>.png` and the red dot is the player's
/// position as a percentage of the map, with 0,0 at the centre (`ui.js:365-387`).
final class MinimapDialogView: UIView {
    var onClose: (() -> Void)?

    private(set) var isOpen = false

    private let wrapper = UIView()
    private let imageView = UIImageView()
    private let dot = UIView()
    private let closeButton = Theme.closeButton()
    private var mapId: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = Theme.overlayScrim
        isHidden = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
        addGestureRecognizer(tap)

        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.backgroundColor = Theme.glassTint
        wrapper.layer.cornerRadius = 12
        wrapper.layer.borderWidth = 1
        wrapper.layer.borderColor = Theme.glassBorder.cgColor
        wrapper.clipsToBounds = true
        addSubview(wrapper)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = 0.9
        wrapper.addSubview(imageView)

        dot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        dot.backgroundColor = Theme.danger
        dot.layer.cornerRadius = 6
        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.shadowColor = Theme.danger.cgColor
        dot.layer.shadowOpacity = 1
        dot.layer.shadowRadius = 8
        dot.layer.shadowOffset = .zero
        dot.isHidden = true
        wrapper.addSubview(dot)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            wrapper.centerXAnchor.constraint(equalTo: centerXAnchor),
            wrapper.centerYAnchor.constraint(equalTo: centerYAnchor),
            wrapper.widthAnchor.constraint(lessThanOrEqualToConstant: 512),
            wrapper.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
            wrapper.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor,
                                            constant: -80),

            imageView.topAnchor.constraint(equalTo: wrapper.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),

            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            closeButton.centerXAnchor.constraint(equalTo: wrapper.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: wrapper.topAnchor),
        ])
    }

    func present(mapId: Int?) {
        isOpen = true
        isHidden = false

        guard let mapId, mapId != self.mapId else { return }
        self.mapId = mapId
        imageView.image = nil
        dot.isHidden = true
        ImageLoader.load(path: "/minimaps/\(mapId).png") { [weak self] image in
            guard let self, self.mapId == mapId else { return }
            self.imageView.image = image
            // Match the wrapper to the image so the dot's percentages land on the picture.
            if let image, image.size.height > 0 {
                self.wrapper.removeConstraints(self.wrapper.constraints.filter {
                    $0.firstAttribute == .height && $0.secondAttribute == .width
                })
                self.wrapper.heightAnchor.constraint(
                    equalTo: self.wrapper.widthAnchor,
                    multiplier: image.size.height / image.size.width).isActive = true
                self.layoutIfNeeded()
            }
        }
    }

    func dismiss() {
        isOpen = false
        isHidden = true
        onClose?()
    }

    /// `updateMinimapDot` — clamped so a player standing outside the bounds still shows on
    /// the edge rather than off the image.
    func updateDot(playerX: Double, playerY: Double, mapWidth: Double, mapHeight: Double) {
        guard isOpen, imageView.image != nil, mapWidth > 0, mapHeight > 0 else { return }

        let pctX = (playerX + mapWidth / 2) / mapWidth
        let pctY = (playerY + mapHeight / 2) / mapHeight
        let safeX = min(max(0, pctX), 1)
        let safeY = min(max(0, pctY), 1)

        dot.isHidden = false
        dot.center = CGPoint(x: wrapper.bounds.width * CGFloat(safeX),
                             y: wrapper.bounds.height * CGFloat(safeY))
    }

    @objc private func closeTapped() { dismiss() }

    @objc private func scrimTapped(_ gesture: UITapGestureRecognizer) {
        if !wrapper.frame.contains(gesture.location(in: self)) { dismiss() }
    }
}

// MARK: - Transient overlays

/// `showMapChangeRejected` (`ui.js:288`) — a big red ❌ for two seconds. Reached by trying to
/// leave a map with `can_leave: false`, i.e. Detention.
final class MapChangeRejectedView: UIView {
    private let label = UILabel()
    private var hideWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        alpha = 0

        label.font = .systemFont(ofSize: 160)
        label.setEmojiText("❌")
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 20
        label.layer.shadowOffset = .zero
        addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func flash() {
        hideWork?.cancel()
        UIView.animate(withDuration: 0.2) { self.alpha = 1 }

        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.2) { self?.alpha = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// `#disconnect-dialog` — shown when reconnection has been given up on.
final class DisconnectDialogView: UIView {
    var onReconnect: (() -> Void)?

    private let panel = Theme.glassPanel(cornerRadius: 12)
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = Theme.overlayScrim
        isHidden = true

        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let header = Theme.headerLabel("Connection Lost")
        header.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.text = "Please check your internet connection."
        messageLabel.font = Theme.body(15)
        messageLabel.textColor = Theme.textMuted
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = Theme.button(title: "Reconnect", color: Theme.success)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(reconnectTapped), for: .touchUpInside)

        panel.contentView.addSubview(header)
        panel.contentView.addSubview(messageLabel)
        panel.contentView.addSubview(button)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85)
                .withPriority(.defaultHigh),

            header.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 24),
            header.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),

            button.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),
            button.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            button.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
            button.heightAnchor.constraint(equalToConstant: 46),
            button.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -24),
        ])
    }

    func present(message: String?) {
        if let message, !message.isEmpty { messageLabel.text = message }
        isHidden = false
    }

    func dismiss() {
        isHidden = true
    }

    @objc private func reconnectTapped() {
        dismiss()
        onReconnect?()
    }
}
