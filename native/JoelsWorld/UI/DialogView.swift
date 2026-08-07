import UIKit

/// The yes/no prompt a `show_dialog` event raises — the doors into the other maps.
/// Replaces `#action-dialog` from `index.html:77-86`: a glass panel with a Pricedown question
/// and the green/red button pair.
final class DialogView: UIView {
    /// Fired when the player taps Yes, with the action the event asked for.
    var onConfirm: ((DialogAction) -> Void)?

    private let panel = Theme.glassPanel()
    private let messageLabel = UILabel()
    private let yesButton = Theme.makePlainButton()
    private let noButton = Theme.makePlainButton()

    private var pendingAction: DialogAction?
    private var pendingHandler: (() -> Void)?

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

        // `.dialog-header` styling, but sized down: door prompts are whole sentences, and
        // Pricedown at 32 pt wraps to three lines on a phone.
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.textColor = .white
        messageLabel.font = Theme.display(24)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.layer.shadowColor = UIColor.black.cgColor
        messageLabel.layer.shadowOpacity = 0.8
        messageLabel.layer.shadowRadius = 2
        messageLabel.layer.shadowOffset = CGSize(width: 1, height: 1)
        panel.contentView.addSubview(messageLabel)

        configure(yesButton, title: "Yes", background: Theme.success)
        configure(noButton, title: "No", background: Theme.danger)
        noButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        yesButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)

        // `index.html:81-84` puts Yes first, then No.
        let buttons = UIStackView(arrangedSubviews: [yesButton, noButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 15
        panel.contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9)
                .withPriority(.defaultHigh),

            messageLabel.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 24),
            messageLabel.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),
            buttons.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func configure(_ button: UIButton, title: String, background: UIColor) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = Theme.body(15, weight: .bold)
        // `.btn-success` / `.btn-danger` are translucent over the panel's blur.
        button.backgroundColor = background.withAlphaComponent(0.4)
        button.tintColor = .white
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 6
    }

    func present(_ request: DialogRequest) {
        messageLabel.text = request.text
        pendingAction = request.confirmAction
        pendingHandler = request.onConfirm
        // An informational dialog has nothing to confirm, so Yes just dismisses it.
        let isActionable = request.confirmAction != nil || request.onConfirm != nil
        yesButton.setTitle(isActionable ? "Yes" : "OK", for: .normal)
        noButton.isHidden = !isActionable
        isHidden = false
    }

    func dismiss() {
        isHidden = true
        pendingAction = nil
        pendingHandler = nil
    }

    @objc private func dismissTapped() {
        dismiss()
    }

    @objc private func confirmTapped() {
        let action = pendingAction
        let handler = pendingHandler
        dismiss()
        if let action { onConfirm?(action) }
        handler?()
    }
}
