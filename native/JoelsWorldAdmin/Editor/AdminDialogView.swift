import AppKit

/// The yes/no prompt a `show_dialog` event raises — the doors between the maps — as the editor
/// shows it. Port of the iOS target's `DialogView` (`#action-dialog`, `index.html:77-86`).
///
/// **One deliberate difference:** the game dims the whole screen behind the prompt and takes
/// every touch outside it. The editor cannot afford that. A door prompt fires whenever the
/// camera is walked over its trigger, which happens constantly while framing a shot, and a
/// scrim would lock the map out from under the operator each time. So there is no scrim, and
/// only the panel itself takes the mouse — everything around it goes on editing.
final class AdminDialogView: NSView {
    /// Fired when the operator clicks Yes, with the action the event asked for.
    var onConfirm: ((DialogAction) -> Void)?

    private let panel = AdminTheme.glassPanel()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let yesButton = ActionButton(title: "Yes", target: nil, action: nil)
    private let noButton = ActionButton(title: "No", target: nil, action: nil)

    /// The request's own state — shared with the iOS dialog, which reads exactly the same
    /// rules off it.
    private var pending = PendingDialog.none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setup() {
        wantsLayer = true
        isHidden = true

        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // `.dialog-header`, sized for a sentence rather than a word.
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.font = AdminTheme.display(24)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.drawsBackground = false
        panel.addSubview(messageLabel)

        configure(yesButton, background: AdminTheme.success) { [weak self] in
            self?.confirm()
        }
        configure(noButton, background: AdminTheme.danger) { [weak self] in
            self?.dismiss()
        }

        // `index.html:81-84` puts Yes first, then No.
        let buttons = NSStackView(views: [yesButton, noButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 15
        panel.addSubview(buttons)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 380),

            messageLabel.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            messageLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 20),
            buttons.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
            buttons.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// `.btn-success` / `.btn-danger`: a tinted bezel with a white title, which on AppKit means
    /// setting the title as attributed text — `contentTintColor` does not reach a bezel button's
    /// label.
    private func configure(_ button: ActionButton, background: NSColor,
                           action: @escaping () -> Void) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.bezelColor = background
        button.handler = action
        button.target = button
        button.action = #selector(ActionButton.fire)
        setTitle(button.title, on: button)
    }

    private func setTitle(_ title: String, on button: ActionButton) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: AdminTheme.body(13, weight: .bold),
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }(),
        ])
    }

    func present(_ request: DialogRequest) {
        messageLabel.stringValue = request.text
        pending = PendingDialog(request)
        setTitle(pending.isActionable ? "Yes" : "OK", on: yesButton)
        noButton.isHidden = !pending.isActionable
        isHidden = false
    }

    func dismiss() {
        isHidden = true
        pending = .none
    }

    private func confirm() {
        let answer = pending.take()
        dismiss()
        if let action = answer.action { onConfirm?(action) }
        answer.handler?()
    }

    /// Only the panel takes the mouse; the rest of the view is a hole the map shows through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        guard panel.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}
