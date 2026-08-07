import UIKit

/// The shape every secondary dialog shares in `index.html`: a dimmed full-screen scrim, a
/// glass panel with a Pricedown header, and the round × hanging off its top-right corner.
/// Tapping the scrim closes it, matching `_bindDialog` (`ui.js:114-127`).
class PanelDialogView: UIView {
    var onClose: (() -> Void)?

    let panel = Theme.glassPanel()
    /// Vertical stack the subclasses fill.
    let content = UIStackView()

    private let closeButton = Theme.closeButton()

    init(title: String) {
        super.init(frame: .zero)
        setup(title: title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(title: String) {
        backgroundColor = Theme.overlayScrim
        isHidden = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 8
        content.alignment = .fill

        let header = Theme.headerLabel(title)
        header.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(content)

        panel.contentView.addSubview(header)
        panel.contentView.addSubview(scroll)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 350),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.8)
                .withPriority(.defaultHigh),
            panel.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 40),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -40),

            header.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 15),
            header.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 15),
            header.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -15),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 15),
            scroll.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 15),
            scroll.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -15),
            scroll.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -15),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            scroll.heightAnchor.constraint(equalTo: content.heightAnchor).withPriority(.defaultLow),

            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),
            closeButton.centerXAnchor.constraint(equalTo: panel.trailingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: panel.topAnchor),
        ])
    }

    func present() {
        isHidden = false
        alpha = 0
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
    }

    func dismiss() {
        isHidden = true
        onClose?()
    }

    @objc private func closeTapped() {
        dismiss()
    }

    @objc private func scrimTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // Only a tap *outside* the panel closes it (`e.target === dialog`).
        if !panel.frame.contains(point) { dismiss() }
    }
}

/// `.emote-row` / `.badge-row`: an emoji, a Pricedown name, and optionally a status glyph on
/// the right.
final class EmoteRowView: UIControl {
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()

    /// The value handed back when the row is tapped — an emote name, or a badge id.
    let value: String

    init(value: String, icon: String, title: String, showsStatus: Bool = false) {
        self.value = value
        super.init(frame: .zero)

        backgroundColor = UIColor(white: 1, alpha: 0.1)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous

        iconLabel.font = .systemFont(ofSize: 24)
        iconLabel.setEmojiText(icon)
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconLabel)

        nameLabel.text = title
        nameLabel.font = Theme.display(16)
        nameLabel.textColor = .white
        nameLabel.layer.shadowColor = UIColor.black.cgColor
        nameLabel.layer.shadowOpacity = 0.8
        nameLabel.layer.shadowRadius = 2
        nameLabel.layer.shadowOffset = CGSize(width: 1, height: 1)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        statusLabel.font = .systemFont(ofSize: 16)
        statusLabel.isHidden = !showsStatus
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 15),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Locked or earned — `populateBadgesList` (`ui.js:211`).
    func setEarned(_ earned: Bool) {
        statusLabel.setEmojiText(earned ? "✅" : "🔒")
        statusLabel.alpha = earned ? 1 : 0.5
    }

    override var isHighlighted: Bool {
        didSet {
            transform = isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
            backgroundColor = UIColor(white: 1, alpha: isHighlighted ? 0.2 : 0.1)
        }
    }
}
