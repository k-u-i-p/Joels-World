import UIKit

// The three `PanelDialogView` menus the button bar opens. They are one file because they are
// one thing: a titled glass panel of `EmoteRowView`s, differing only in what fills it.

// MARK: - Emotes

/// `#emotes-dialog`. The web build fetched the list from `/api/config` (`ui.js:145-205`);
/// `Emotes.names` is compiled in instead, so the picker offers exactly the emotes that can
/// pose the rig.
final class EmotesDialogView: PanelDialogView {
    /// The chat line the tapped row submits, e.g. `/dance`.
    var onEmote: ((String) -> Void)?

    /// `emoteEmojis` (`ui.js:167`); anything not listed falls back to 💬.
    private static let emoji: [String: String] = [
        "dance": "🕺", "fart": "💨", "dead": "💀", "cry": "😭", "rugby": "🏉",
        "sit": "🪑", "jump": "🦘", "eat": "🍔", "lunch": "🥪", "tennis": "🎾",
    ]

    private var isPopulated = false

    init() {
        super.init(title: "Emotes")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func present() {
        super.present()
        // The list is a compile-time constant now, so the first open is the only one that
        // builds rows — the web build re-tried here until its `/api/config` fetch landed.
        guard !isPopulated else { return }
        isPopulated = true
        populate(Emotes.names)
    }

    private func populate(_ emotes: [String]) {
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

/// `#badges-dialog`. The badges are authored in `index.html:168-213`, not served, so the
/// list is hard-coded here too. The eighth, School Rush, is the first one this build added —
/// the server stores whatever id it is sent, so a new badge is a line here and a call to
/// `minigameAwardBadge` in the game that awards it.
final class BadgesDialogView: PanelDialogView {
    private static let badges: [(id: String, icon: String, title: String)] = [
        ("rugby", "🏉", "Rugby"),
        ("tennis", "🎾", "Tennis"),
        ("swimming", "🏊", "Swimming"),
        ("tig", "🏃", "Tig"),
        ("good friend", "🫂", "Good Friend"),
        ("tower defence", "🏰", "Tower Defence"),
        ("detention", "🚫", "Detention"),
        ("school rush", "🎒", "School Rush"),
        ("football", "⚽", "Football"),
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
