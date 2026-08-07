import UIKit

/// Name-entry screen. Replaces the `#name-dialog` overlay from `index.html`.
///
/// The server rejects anything but English letters (`ClientManager.js:112`), so the field
/// enforces that locally rather than round-tripping an error.
final class LobbyView: UIView {
    var onStart: ((String) -> Void)?

    private let panel = Theme.glassPanel()
    private let logoView = UIImageView()
    private let titleLabel = UILabel()
    private let nameField = UITextField()
    private let startButton = Theme.makePlainButton()
    private let errorLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

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

        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        // The `#name-dialog` logo (`index.html:110`).
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.contentMode = .scaleAspectFit
        panel.contentView.addSubview(logoView)
        ImageLoader.load(path: "/media/logo_128_128.png") { [weak self] image in
            self?.logoView.image = image
        }

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Welcome!"
        titleLabel.textColor = .white
        titleLabel.font = Theme.display(32)
        titleLabel.textAlignment = .center
        titleLabel.layer.shadowColor = UIColor.black.cgColor
        titleLabel.layer.shadowOpacity = 0.8
        titleLabel.layer.shadowRadius = 2
        titleLabel.layer.shadowOffset = CGSize(width: 1, height: 1)
        panel.contentView.addSubview(titleLabel)

        // `.glass-input`
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.attributedPlaceholder = NSAttributedString(
            string: "Enter your name...",
            attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.7)])
        nameField.textColor = .white
        nameField.tintColor = .white
        nameField.textAlignment = .center
        nameField.font = Theme.body(16)
        nameField.backgroundColor = UIColor(white: 1, alpha: 0.2)
        nameField.layer.cornerRadius = 8
        nameField.layer.borderWidth = 1
        nameField.layer.borderColor = Theme.glassBorder.cgColor
        nameField.autocorrectionType = .no
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .go
        nameField.delegate = self
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        panel.contentView.addSubview(nameField)

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = Theme.danger
        errorLabel.font = Theme.body(13)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        panel.contentView.addSubview(errorLabel)

        startButton.translatesAutoresizingMaskIntoConstraints = false
        startButton.setTitle("Start Game", for: .normal)
        startButton.titleLabel?.font = Theme.body(15, weight: .bold)
        startButton.setTitleColor(.white, for: .normal)
        startButton.backgroundColor = Theme.success.withAlphaComponent(0.4)
        startButton.tintColor = .white
        startButton.layer.cornerRadius = 8
        startButton.isEnabled = false
        startButton.alpha = 0.5
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        panel.contentView.addSubview(startButton)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.hidesWhenStopped = true
        panel.contentView.addSubview(spinner)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.85)
                .withPriority(.defaultHigh),

            logoView.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 24),
            logoView.centerXAnchor.constraint(equalTo: panel.contentView.centerXAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 128),
            logoView.heightAnchor.constraint(equalToConstant: 128),

            titleLabel.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),

            nameField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            nameField.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            nameField.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
            nameField.heightAnchor.constraint(equalToConstant: 44),

            errorLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            errorLabel.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),

            startButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 14),
            startButton.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 20),
            startButton.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -20),
            startButton.heightAnchor.constraint(equalToConstant: 48),
            startButton.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -24),

            spinner.centerXAnchor.constraint(equalTo: startButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),
        ])
    }

    func setBusy(_ busy: Bool) {
        if busy {
            spinner.startAnimating()
            startButton.setTitle("", for: .normal)
            startButton.isEnabled = false
        } else {
            spinner.stopAnimating()
            startButton.setTitle("Start Game", for: .normal)
            nameChanged()
        }
    }

    func showError(_ message: String) {
        errorLabel.text = message
    }

    @objc private func nameChanged() {
        let valid = isValid(nameField.text)
        startButton.isEnabled = valid
        startButton.alpha = valid ? 1 : 0.5
        if valid { errorLabel.text = nil }
    }

    private func isValid(_ name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return false }
        return name.allSatisfy { $0.isLetter && $0.isASCII }
    }

    @objc private func startTapped() {
        guard let name = nameField.text?.trimmingCharacters(in: .whitespaces), isValid(name) else {
            errorLabel.text = "Please use only English letters, with no spaces or symbols."
            return
        }
        endEditing(true)
        onStart?(String(name.prefix(15)))
    }
}

extension LobbyView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        startTapped()
        return true
    }
}
