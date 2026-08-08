import AppKit

/// Port of the generic event editor (`admin.js:719-1021`) — `#admin-events-section`, plus
/// `renderEventUI` and the Save Events handler.
///
/// It edits a working copy and commits on Save, exactly as the JS does: selecting an entity
/// deep-clones its `on_enter` / `on_exit` into the editor, and nothing reaches the server
/// until the button is pressed.
final class EventEditorView: NSView {
    weak var map: AdminMapViewController?

    /// The eight action types the type dropdown offers (`admin.js:786`).
    private static let actionTypes = ["say", "emote", "play_sound", "log", "show_dialog",
                                      "avatar", "clear_emote", "player_emote"]

    private var onEnter: [JSONValue] = []
    private var onExit: [JSONValue] = []

    private let enterContainer = AdminUI.verticalStack()
    private let exitContainer = AdminUI.verticalStack()
    private let saveButton: NSButton
    private let stack = AdminUI.verticalStack()

    override init(frame frameRect: NSRect) {
        saveButton = AdminUI.button("Save Events") {}
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        (saveButton as? ActionButton)?.handler = { [weak self] in self?.save() }

        let addEnter = AdminUI.button("+ Add on_enter action") { [weak self] in
            self?.onEnter.append(.object(["say": .array([.string("")])]))
            self?.render()
        }
        let addExit = AdminUI.button("+ Add on_exit action") { [weak self] in
            self?.onExit.append(.object(["say": .array([.string("")])]))
            self?.render()
        }

        for view in [AdminUI.sectionTitle("Events"),
                     AdminUI.label("on_enter", bold: true), enterContainer, addEnter,
                     AdminUI.label("on_exit", bold: true), exitContainer, addExit,
                     saveButton] {
            stack.addArrangedSubview(view)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Loading

    /// Re-reads the selected entity. Called on every selection change, which is what discards
    /// unsaved edits — the same behaviour the web panel has.
    func refresh() {
        let entityEvents: (JSONValue?, JSONValue?)?
        if let object = map?.selectedObject {
            entityEvents = (object.on_enter, object.on_exit)
        } else if let npc = map?.selectedNPC {
            entityEvents = (npc.on_enter, npc.on_exit)
        } else {
            entityEvents = nil
        }

        guard let entityEvents else {
            isHidden = true
            return
        }
        isHidden = false
        onEnter = entityEvents.0?.arrayValue ?? []
        onExit = entityEvents.1?.arrayValue ?? []
        render()
    }

    private func render() {
        render(onEnter, into: enterContainer, isEnter: true)
        render(onExit, into: exitContainer, isEnter: false)
    }

    private func render(_ actions: [JSONValue], into container: NSStackView, isEnter: Bool) {
        for view in container.arrangedSubviews {
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !actions.isEmpty else {
            container.addArrangedSubview(AdminUI.label("No actions defined."))
            return
        }

        for (index, action) in actions.enumerated() {
            container.addArrangedSubview(card(for: action, at: index, isEnter: isEnter))
        }
    }

    // MARK: - One action card

    private func card(for action: JSONValue, at index: Int, isEnter: Bool) -> NSView {
        // Each action object carries exactly one key in this schema; the JS reads
        // `Object.keys(actionObj)[0]` and so does this.
        let typeKey = action.objectValue?.keys.sorted().first ?? "say"
        let payload = action.objectValue?[typeKey] ?? .null

        let box = NSBox()
        box.titlePosition = .noTitle
        box.boxType = .custom
        
        box.borderColor = .separatorColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let content = AdminUI.verticalStack()

        let typePopUp = AdminUI.popUp(Self.actionTypes) { [weak self] newType in
            self?.changeType(of: index, isEnter: isEnter, to: newType)
        }
        typePopUp.reload(selected: typeKey)

        let removeButton = AdminUI.button("✕") { [weak self] in
            self?.removeAction(at: index, isEnter: isEnter)
        }

        let header = NSStackView(views: [typePopUp, removeButton])
        header.orientation = .horizontal
        header.spacing = 6
        content.addArrangedSubview(header)

        for editor in payloadEditors(typeKey: typeKey, payload: payload, index: index, isEnter: isEnter) {
            content.addArrangedSubview(editor)
        }

        box.contentView = content
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        return box
    }

    private func payloadEditors(typeKey: String, payload: JSONValue,
                                index: Int, isEnter: Bool) -> [NSView] {
        switch typeKey {
        case "say":
            // One line per row, blank lines dropped — the JS textarea split on newlines.
            let lines = payload.arrayValue?.compactMap(\.stringValue) ?? [payload.stringValue ?? ""]
            let text = NSTextView.scrollableTextView()
            guard let textView = text.documentView as? NSTextView else { return [] }
            textView.string = lines.joined(separator: "\n")
            textView.font = .systemFont(ofSize: 11)
            textView.delegate = TextCommitProxy.attach(to: textView) { [weak self] string in
                let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                self?.setPayload(.array(lines.map { .string($0) }),
                                 forKey: typeKey, at: index, isEnter: isEnter)
            }
            text.translatesAutoresizingMaskIntoConstraints = false
            text.heightAnchor.constraint(equalToConstant: 54).isActive = true
            text.widthAnchor.constraint(equalToConstant: 220).isActive = true
            return [text]

        case "emote", "player_emote":
            let popUp = AdminUI.popUp(Emotes.table.keys.sorted()) { [weak self] name in
                self?.setPayload(.string(name), forKey: typeKey, at: index, isEnter: isEnter)
            }
            popUp.reload(selected: payload.stringValue)
            return [AdminUI.row("Emote", [popUp])]

        case "play_sound":
            let object = payload.objectValue ?? [:]
            let soundField = ValueField(placeholder: "media/x.mp3", width: 150)
            soundField.reload(object["sound"]?.stringValue ?? "")
            soundField.onCommit = { [weak self] text in
                self?.setNested(key: "sound", value: .string(text),
                                forKey: typeKey, at: index, isEnter: isEnter)
            }
            let volumeField = ValueField(width: 60)
            volumeField.reload(String(object["volume"]?.numberValue ?? 1.0))
            volumeField.onCommit = { [weak self] text in
                self?.setNested(key: "volume", value: JSONValue(Double(text) ?? 1.0),
                                forKey: typeKey, at: index, isEnter: isEnter)
            }
            return [AdminUI.row("Sound", [soundField]), AdminUI.row("Volume", [volumeField])]

        case "avatar":
            let field = ValueField(placeholder: "avatars/xxx.png", width: 220)
            field.reload(payload.stringValue ?? "")
            field.onCommit = { [weak self] text in
                self?.setPayload(.string(text), forKey: typeKey, at: index, isEnter: isEnter)
            }
            return [field]

        case "log":
            // The schema allows a bare string or `{message, rate_limit}`. Editing the rate
            // limit promotes a string to the object form, as `admin.js:914-923` does.
            let messageText = payload.stringValue ?? payload.objectValue?["message"]?.stringValue ?? ""
            let rateLimit = payload.objectValue?["rate_limit"]?.numberValue ?? 0

            let messageField = ValueField(placeholder: "Log message", width: 220)
            messageField.reload(messageText)
            messageField.onCommit = { [weak self] text in
                guard let self else { return }
                if self.action(at: index, isEnter: isEnter)?.objectValue?[typeKey]?.stringValue != nil {
                    self.setPayload(.string(text), forKey: typeKey, at: index, isEnter: isEnter)
                } else {
                    self.setNested(key: "message", value: .string(text),
                                   forKey: typeKey, at: index, isEnter: isEnter)
                }
            }

            let limitField = ValueField(width: 60)
            limitField.reload(String(Int(rateLimit)))
            limitField.onCommit = { [weak self] text in
                guard let self else { return }
                let message = self.action(at: index, isEnter: isEnter)?
                    .objectValue?[typeKey].flatMap { $0.stringValue ?? $0.objectValue?["message"]?.stringValue } ?? ""
                self.setPayload(.object(["message": .string(message),
                                         "rate_limit": JSONValue(Double(text) ?? 0)]),
                                forKey: typeKey, at: index, isEnter: isEnter)
            }
            return [messageField, AdminUI.row("Rate limit (s)", [limitField])]

        case "show_dialog":
            let object = payload.objectValue ?? [:]
            let descriptionField = ValueField(placeholder: "Dialog description", width: 220)
            descriptionField.reload(object["description"]?.stringValue ?? "")
            descriptionField.onCommit = { [weak self] text in
                self?.setNested(key: "description", value: .string(text),
                                forKey: typeKey, at: index, isEnter: isEnter)
            }
            let typeField = ValueField(width: 110)
            typeField.reload(object["type"]?.stringValue ?? "change_map")
            typeField.onCommit = { [weak self] text in
                self?.setNested(key: "type", value: .string(text),
                                forKey: typeKey, at: index, isEnter: isEnter)
            }
            let mapField = ValueField(width: 60)
            mapField.reload(String(Int(object["map"]?.numberValue ?? 1)))
            mapField.onCommit = { [weak self] text in
                self?.setNested(key: "map", value: JSONValue(Double(text) ?? 1),
                                forKey: typeKey, at: index, isEnter: isEnter)
            }
            return [descriptionField, AdminUI.row("Type", [typeField]), AdminUI.row("Map ID", [mapField])]

        default:
            // `clear_emote` carries no payload.
            return []
        }
    }

    // MARK: - Working-copy edits

    private func action(at index: Int, isEnter: Bool) -> JSONValue? {
        let list = isEnter ? onEnter : onExit
        return list.indices.contains(index) ? list[index] : nil
    }

    private func mutate(isEnter: Bool, _ body: (inout [JSONValue]) -> Void) {
        if isEnter { body(&onEnter) } else { body(&onExit) }
    }

    private func setPayload(_ value: JSONValue, forKey key: String, at index: Int, isEnter: Bool) {
        mutate(isEnter: isEnter) { list in
            guard list.indices.contains(index) else { return }
            list[index] = .object([key: value])
        }
    }

    private func setNested(key nestedKey: String, value: JSONValue,
                           forKey key: String, at index: Int, isEnter: Bool) {
        mutate(isEnter: isEnter) { list in
            guard list.indices.contains(index) else { return }
            var payload = list[index].objectValue?[key]?.objectValue ?? [:]
            payload[nestedKey] = value
            list[index] = .object([key: .object(payload)])
        }
    }

    /// Switching the type installs the same starter payload the JS does (`admin.js:796-806`).
    private func changeType(of index: Int, isEnter: Bool, to newType: String) {
        let starter: JSONValue
        switch newType {
        case "say": starter = .array([.string("")])
        case "play_sound": starter = .object(["sound": .string(""), "volume": JSONValue(1.0)])
        case "show_dialog": starter = .object(["description": .string(""),
                                               "type": .string("change_map"),
                                               "map": JSONValue(1)])
        case "log": starter = .object(["message": .string(""), "rate_limit": JSONValue(0)])
        default: starter = .string("")
        }
        setPayload(starter, forKey: newType, at: index, isEnter: isEnter)
        render()
    }

    private func removeAction(at index: Int, isEnter: Bool) {
        mutate(isEnter: isEnter) { list in
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
        }
        render()
    }

    // MARK: - Commit

    /// `admin.js:985-1018`: an empty array is sent as `undefined` so the key is dropped from
    /// the JSON rather than persisted as `[]`.
    private func save() {
        let enterValue: JSONValue = onEnter.isEmpty ? .null : .array(onEnter)
        let exitValue: JSONValue = onExit.isEmpty ? .null : .array(onExit)
        let updates: [String: JSONValue] = ["on_enter": enterValue, "on_exit": exitValue]

        if map?.selectedObject != nil {
            map?.mutateSelectedObject({ object in
                object.on_enter = onEnter.isEmpty ? nil : .array(onEnter)
                object.on_exit = onExit.isEmpty ? nil : .array(onExit)
            }, message: { .updateObject(id: $0.id, updates: updates) })
        } else if map?.selectedNPC != nil {
            map?.mutateSelectedNPC({ npc in
                npc.on_enter = onEnter.isEmpty ? nil : .array(onEnter)
                npc.on_exit = onExit.isEmpty ? nil : .array(onExit)
            }, message: { .updateNPC(id: $0.id, updates: updates) })
        } else {
            return
        }

        saveButton.title = "Saved!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.saveButton.title = "Save Events"
        }
    }
}

/// `NSTextView` has no "commit on end editing" callback shaped like `NSTextField`'s, so this
/// forwards `textDidEndEditing` and keeps itself alive as an associated object.
final class TextCommitProxy: NSObject, NSTextViewDelegate {
    private let onCommit: (String) -> Void
    private static var associationKey: UInt8 = 0

    private init(onCommit: @escaping (String) -> Void) {
        self.onCommit = onCommit
    }

    /// `NSTextView.delegate` is weak, so the proxy is retained by the text view itself and
    /// dies with the card it belongs to.
    @discardableResult
    static func attach(to textView: NSTextView, onCommit: @escaping (String) -> Void) -> TextCommitProxy {
        let proxy = TextCommitProxy(onCommit: onCommit)
        objc_setAssociatedObject(textView, &associationKey, proxy, .OBJC_ASSOCIATION_RETAIN)
        return proxy
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        onCommit(textView.string)
    }
}
