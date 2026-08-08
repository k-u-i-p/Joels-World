import UIKit

// The two overlays a server message raises over the top of play, rather than anything the
// player opened: the map refused to let them leave, and the connection went away.

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
