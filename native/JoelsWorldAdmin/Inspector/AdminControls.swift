import AppKit

/// A button that repeats while held and fires a second action on release.
///
/// Port of `bindHoldAction` (`admin.js:110-142`): the repeat mutates the local record every
/// 50 ms so the shape moves under the cursor, and the release sends one message to the server
/// rather than a hundred.
final class HoldButton: NSButton {
    private var onHold: () -> Void = {}
    private var onRelease: () -> Void = {}
    private var timer: Timer?
    private var didFire = false

    convenience init(title: String, onHold: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.onHold = onHold
        self.onRelease = onRelease
        bezelStyle = .rounded
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    override func mouseDown(with event: NSEvent) {
        didFire = true
        onHold()

        // AppKit's button tracking runs the run loop in `.eventTracking`, so a timer added
        // only to `.default` would never fire while the button is held.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.onHold() }
        RunLoop.current.add(timer, forMode: .default)
        RunLoop.current.add(timer, forMode: .eventTracking)
        self.timer = timer

        super.mouseDown(with: event)   // Blocks until the button is released.

        timer.invalidate()
        self.timer = nil
        if didFire { onRelease() }
        didFire = false
    }
}

/// A text field that reports edits, used for every numeric and string field in the panels.
final class ValueField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    /// Suppresses `onCommit` while the panel is writing the field from the model.
    private var isReloading = false

    convenience init(placeholder: String = "", width: CGFloat = 90) {
        self.init(frame: .zero)
        self.placeholderString = placeholder
        isBezeled = true
        bezelStyle = .roundedBezel
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    func reload(_ text: String) {
        guard stringValue != text else { return }
        isReloading = true
        stringValue = text
        isReloading = false
    }

    /// `change` in the DOM fires on blur or Return, not per keystroke — matched here so a
    /// half-typed number never reaches the server.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isReloading else { return }
        onCommit?(stringValue)
    }
}

enum AdminUI {
    static func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .systemFont(ofSize: 11, weight: .semibold) : .systemFont(ofSize: 11)
        field.textColor = bold ? .labelColor : .secondaryLabelColor
        return field
    }

    static func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text.uppercased())
        field.font = .systemFont(ofSize: 10, weight: .bold)
        field.textColor = .tertiaryLabelColor
        return field
    }

    /// One control row: a caption on the left, controls on the right.
    static func row(_ caption: String, _ controls: [NSView]) -> NSStackView {
        let stack = NSStackView(views: [label(caption)] + controls)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    static func verticalStack(_ views: [NSView] = []) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ActionButton(title: title, target: nil, action: nil)
        button.handler = action
        button.target = button
        button.action = #selector(ActionButton.fire)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 11)
        return button
    }

    static func checkbox(_ title: String, checked: Bool = false,
                         action: @escaping (Bool) -> Void) -> NSButton {
        let button = ActionButton(checkboxWithTitle: title, target: nil, action: nil)
        button.handler = { action(button.state == .on) }
        button.target = button
        button.action = #selector(ActionButton.fire)
        button.state = checked ? .on : .off
        button.font = .systemFont(ofSize: 11)
        return button
    }

    static func popUp(_ items: [String], action: @escaping (String) -> Void) -> ActionPopUpButton {
        let popUp = ActionPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: items)
        popUp.handler = action
        popUp.target = popUp
        popUp.action = #selector(ActionPopUpButton.fire)
        popUp.font = .systemFont(ofSize: 11)
        return popUp
    }

    static func colorWell(action: @escaping (NSColor) -> Void) -> ActionColorWell {
        let well = ActionColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 20))
        well.handler = action
        well.target = well
        well.action = #selector(ActionColorWell.fire)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        well.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return well
    }
}

final class ActionButton: NSButton {
    var handler: () -> Void = {}
    @objc func fire() { handler() }
}

final class ActionPopUpButton: NSPopUpButton {
    var handler: (String) -> Void = { _ in }
    /// Suppresses the handler while the panel is selecting an item from the model.
    private var isReloading = false

    @objc func fire() {
        guard !isReloading else { return }
        handler(titleOfSelectedItem ?? "")
    }

    func reload(items: [String], selected: String?) {
        isReloading = true
        if itemTitles != items {
            removeAllItems()
            addItems(withTitles: items)
        }
        if let selected, items.contains(selected) {
            selectItem(withTitle: selected)
        } else {
            selectItem(at: 0)
        }
        isReloading = false
    }

    func reload(selected: String?) {
        isReloading = true
        if let selected, itemTitles.contains(selected) {
            selectItem(withTitle: selected)
        } else {
            selectItem(at: 0)
        }
        isReloading = false
    }
}

final class ActionColorWell: NSColorWell {
    var handler: (NSColor) -> Void = { _ in }
    private var isReloading = false

    @objc func fire() {
        guard !isReloading else { return }
        handler(color)
    }

    func reload(hex: String?) {
        isReloading = true
        color = NSColor(hex: hex ?? "#000000") ?? .black
        isReloading = false
    }
}

extension NSColor {
    /// Parses `#rrggbb`. The colours in the map JSON are all in that form.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                  green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255,
                  alpha: 1)
    }

    /// Back to `#rrggbb`, which is what the map JSON stores.
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}
