import AppKit

/// The game's top-of-screen overlay, as the editor shows it: the NPC portrait, the map name,
/// the chat field and the feed of recent messages. The AppKit twin of `HUDView`, port of
/// `#top-center-ui` (`index.html:59-75`) and the chat stack in `ui.js:232-286`.
///
/// The chrome is a straight translation — same palette, same Pricedown map name, same 128 pt
/// portrait with its `#ecf0f1` frame, same five-rows-of-thirty-seconds feed with the quirk
/// intact. What differs is hit testing: in the game the HUD floats over a world you can only
/// walk through, whereas here it floats over one you are editing, so only the chat field takes
/// the mouse and everything else falls through to the map.
final class AdminHUDView: NSView {
    /// Fired when the operator submits a line. `/emote` lines arrive here too, exactly as the
    /// `chatSubmit` event does in the JS.
    var onChatSubmit: ((String) -> Void)?

    private let wrapper = NSStackView()
    private let header = NSStackView()
    private let portrait = NSImageView()
    private let mapNameLabel = NSTextField(labelWithString: "")
    private let chatField = NSTextField()
    private let chatFieldBox = NSView()
    private let chatStack = NSStackView()

    private var portraitWidth: NSLayoutConstraint!
    private var portraitHeight: NSLayoutConstraint!

    /// Which NPC the portrait belongs to. Shared with the iOS HUD.
    private var avatarOwner = PortraitOwner()

    /// The map's own name, restored when the portrait goes away
    /// (`dataset.originalName`, `ui.js:36`).
    private var mapName: String?

    /// A live chat row and the wall-clock time it should disappear.
    private struct ChatRow {
        let view: NSView
        var expiresAt: TimeInterval
    }
    private var chatRows: [ChatRow] = []
    private var sweepTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        sweepTimer?.invalidate()
    }

    // MARK: - Layout

    private func setup() {
        wantsLayer = true

        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.orientation = .vertical
        wrapper.spacing = 10
        // Every row is the full width of the column, which is what `UIStackView`'s `.fill`
        // gives the iOS HUD for free (`HUDView.swift:57`). `NSStackView.alignment = .width`
        // reads like the equivalent and is not: it left the rows sized to their own text, so
        // the feed zig-zagged, a one-word reply floating off the end of the line above it.
        // Each width is pinned to the column explicitly instead.
        wrapper.alignment = .width
        addSubview(wrapper)

        header.orientation = .horizontal
        header.spacing = 15
        header.alignment = .bottom
        header.distribution = .fill
        wrapper.addArrangedSubview(header)

        portrait.translatesAutoresizingMaskIntoConstraints = false
        portrait.imageScaling = .scaleProportionallyUpOrDown
        portrait.wantsLayer = true
        portrait.layer?.cornerRadius = 8
        portrait.layer?.masksToBounds = true
        portrait.layer?.borderWidth = 2
        portrait.layer?.borderColor = AdminTheme.portraitBorder.cgColor
        portrait.alphaValue = 0
        portraitWidth = portrait.widthAnchor.constraint(equalToConstant: 0)
        portraitHeight = portrait.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([portraitWidth, portraitHeight])
        header.addArrangedSubview(portrait)

        let right = NSStackView()
        right.orientation = .vertical
        right.spacing = 10
        right.alignment = .width
        // The portrait keeps its 128 pt; the column beside it takes whatever is left, so the
        // chat field lines up with the feed below whether a portrait is up or not.
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(right)

        mapNameLabel.font = AdminTheme.display(36)
        mapNameLabel.textColor = .white
        mapNameLabel.alignment = .center
        mapNameLabel.lineBreakMode = .byTruncatingTail
        mapNameLabel.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = .black
            shadow.shadowBlurRadius = 4
            shadow.shadowOffset = NSSize(width: 2, height: -2)
            return shadow
        }()
        right.addArrangedSubview(mapNameLabel)

        right.addArrangedSubview(makeChatField())

        chatStack.orientation = .vertical
        chatStack.spacing = 5
        chatStack.alignment = .width
        wrapper.addArrangedSubview(chatStack)

        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: wrapper.widthAnchor),
            chatStack.widthAnchor.constraint(equalTo: wrapper.widthAnchor),
            mapNameLabel.widthAnchor.constraint(equalTo: right.widthAnchor),
            chatFieldBox.widthAnchor.constraint(equalTo: right.widthAnchor),
        ])

        // The view itself spans the map, as `#top-center-ui` spans the screen, and the wrapper
        // sits at the top middle of it. Sizing the view to its content instead would leave it
        // with no height at all — nothing here pins a bottom edge.
        //
        // The column is 400 pt wide rather than *at most* 400 pt, which is what the iOS HUD
        // does (`HUDView.swift:127-129`). A column that resizes to its widest row is a column
        // whose left edge moves every time somebody speaks.
        let width = wrapper.widthAnchor.constraint(equalToConstant: 400)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            wrapper.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            wrapper.centerXAnchor.constraint(equalTo: centerXAnchor),
            wrapper.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 30),
            wrapper.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            width,
        ])
    }

    /// `.glass-input`. The field lives inside the styled box rather than being styled itself,
    /// which is how it gets the CSS padding without a custom `NSTextFieldCell`.
    private func makeChatField() -> NSView {
        chatFieldBox.translatesAutoresizingMaskIntoConstraints = false
        chatFieldBox.wantsLayer = true
        chatFieldBox.layer?.backgroundColor = NSColor(white: 1, alpha: 0.2).cgColor
        chatFieldBox.layer?.cornerRadius = 8
        chatFieldBox.layer?.borderWidth = 1
        chatFieldBox.layer?.borderColor = AdminTheme.glassBorder.cgColor

        chatField.translatesAutoresizingMaskIntoConstraints = false
        chatField.isBordered = false
        chatField.drawsBackground = false
        chatField.focusRingType = .none
        chatField.font = AdminTheme.body(14)
        chatField.textColor = .white
        chatField.placeholderAttributedString = NSAttributedString(
            string: "Type to chat…",
            attributes: [.foregroundColor: NSColor(white: 1, alpha: 0.7),
                         .font: AdminTheme.body(14)])
        chatField.delegate = self
        chatField.target = self
        chatField.action = #selector(chatSubmitted)
        chatFieldBox.addSubview(chatField)

        NSLayoutConstraint.activate([
            chatFieldBox.heightAnchor.constraint(equalToConstant: 38),
            chatField.leadingAnchor.constraint(equalTo: chatFieldBox.leadingAnchor, constant: 10),
            chatField.trailingAnchor.constraint(equalTo: chatFieldBox.trailingAnchor, constant: -10),
            chatField.centerYAnchor.constraint(equalTo: chatFieldBox.centerYAnchor),
        ])
        return chatFieldBox
    }

    /// The middle of the chat field, in this view's own coordinates. `-selftest` aims a hit
    /// test at it — a click that lands anywhere else means the field cannot be typed into.
    var chatFieldCentre: CGPoint {
        chatFieldBox.convert(CGPoint(x: chatFieldBox.bounds.midX, y: chatFieldBox.bounds.midY),
                             to: self)
    }

    /// Only the chat field takes the mouse. Everything else — the portrait, the map name, the
    /// chat rows — is a hole the map shows through, so the HUD never eats a click meant for an
    /// object underneath it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard chatFieldBox.convert(chatFieldBox.bounds, to: self).contains(local) else { return nil }
        return super.hitTest(point)
    }

    // MARK: - Map name and portrait

    func setMapName(_ name: String?) {
        mapName = name
        // A portrait currently owns the title; it restores this name when it goes.
        if avatarOwner.isVacant { mapNameLabel.stringValue = name ?? "" }
    }

    /// The `avatar` event handler (`events.js:5-51`): the portrait grows in and the title takes
    /// the NPC's name.
    func showAvatar(sourceId: Int, name: String?, imagePath: String) {
        avatarOwner.claim(sourceId)
        mapNameLabel.stringValue = name ?? "NPC"

        AdminImageLoader.load(path: imagePath) { [weak self] image in
            guard let self, self.avatarOwner.sourceId == sourceId else { return }
            // Unlike the game, a portrait whose file was never staged still opens — with the
            // name and an empty well. A missing `avatars/…` is exactly the authoring mistake
            // this app exists to catch, so it should be visible rather than silently skipped.
            self.portrait.image = image
            self.portraitWidth.constant = 128
            self.portraitHeight.constant = 128
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                self.portrait.animator().alphaValue = 1
                self.layoutSubtreeIfNeeded()
            }
        }
    }

    /// `cleanupNpcUI` — only the NPC that owns the portrait can dismiss it.
    func hideAvatar(sourceId: Int?) {
        guard avatarOwner.release(sourceId) else { return }
        mapNameLabel.stringValue = mapName ?? ""

        portraitWidth.constant = 0
        portraitHeight.constant = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            portrait.animator().alphaValue = 0
            layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            // Another NPC may have raised its own portrait inside the 0.3 s.
            guard let self, self.avatarOwner.isVacant else { return }
            self.portrait.image = nil
        })
    }

    // MARK: - Chat feed

    /// Port of `addServerChatMessage` (`ui.js:232`). Newest on top, five at a time, thirty
    /// seconds each.
    ///
    /// **Reproduced quirk,** same as the iOS HUD: every existing row loses ten seconds when a
    /// new one arrives, because the JS compares an absolute epoch timestamp against `20000`
    /// (`ui.js:241`), which is always true. Older messages therefore clear faster the busier
    /// the chat gets.
    func addChatMessage(sender: String, message: String) {
        let now = Date.timeIntervalSinceReferenceDate

        for index in chatRows.indices {
            chatRows[index].expiresAt -= 10
        }

        let row = makeChatRow(sender: sender, message: message)
        chatStack.insertArrangedSubview(row, at: 0)
        row.widthAnchor.constraint(equalTo: chatStack.widthAnchor).isActive = true
        chatRows.insert(ChatRow(view: row, expiresAt: now + 30), at: 0)

        row.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            row.animator().alphaValue = 1
        }

        while chatRows.count > 5 {
            let last = chatRows.removeLast()
            chatStack.removeArrangedSubview(last.view)
            last.view.removeFromSuperview()
        }

        startSweepIfNeeded()
    }

    /// The live rows' widths. `-selftest` asserts they are all the same — a feed whose rows
    /// each shrink to their own text is the misalignment this column was built to avoid.
    var chatRowWidths: [CGFloat] { chatRows.map { $0.view.frame.width } }

    /// Drops every row without animating — used when the map changes.
    func clearChat() {
        for row in chatRows {
            chatStack.removeArrangedSubview(row.view)
            row.view.removeFromSuperview()
        }
        chatRows.removeAll()
    }

    private func makeChatRow(sender: String, message: String) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.backgroundColor = AdminTheme.chatRowBackground.cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = AdminTheme.glassBorder.cgColor

        let text = NSMutableAttributedString(
            string: "\(sender): ",
            attributes: [.font: AdminTheme.body(14, weight: .bold),
                         .foregroundColor: AdminTheme.primaryHover])
        text.append(NSAttributedString(
            string: message,
            attributes: [.font: AdminTheme.body(14),
                         .foregroundColor: NSColor.black]))

        let label = NSTextField(labelWithAttributedString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        // The column's 400 pt, less the row's two 10 pt insets.
        label.preferredMaxLayoutWidth = 380
        box.addSubview(label)

        // The row's 10 px padding, which `NSTextField` has no insets of its own for. The row's
        // width comes from the stack — every row is the full width of the column.
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        return box
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
            // `.fade-out` — half a second of opacity, then the row leaves the stack.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                for row in expired { row.view.animator().alphaValue = 0 }
            }, completionHandler: {
                for row in expired {
                    self.chatStack.removeArrangedSubview(row.view)
                    row.view.removeFromSuperview()
                }
            })
        }
    }

    // MARK: - Chat entry

    var isChatFocused: Bool { window?.firstResponder === chatField.currentEditor() }

    /// Hands the keyboard back to the map, so WASD walks the camera again.
    func resignChat() {
        guard isChatFocused else { return }
        window?.makeFirstResponder(superview)
    }

    @objc private func chatSubmitted() {
        let message = chatField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        chatField.stringValue = ""
        resignChat()
        // `maxlength="80"` on the input.
        if !message.isEmpty { onChatSubmit?(String(message.prefix(80))) }
    }
}

extension AdminHUDView: NSTextFieldDelegate {
    /// ⎋ abandons the line and gives the keys back, which a Mac window needs and the phone
    /// does not — there the keyboard has its own dismissal.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        chatField.stringValue = ""
        resignChat()
        return true
    }
}
