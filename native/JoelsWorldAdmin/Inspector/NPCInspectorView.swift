import AppKit

/// Port of `#edit-npc-section` and its handlers (`admin.js:445-583`, `678-717`).
final class NPCInspectorView: NSView {
    weak var map: AdminMapViewController?

    private let idLabel = AdminUI.label("ID: —", bold: true)
    private let nameField = ValueField(placeholder: "NPC name", width: 150)
    private let rotationField = ValueField(width: 60)
    private let widthField = ValueField(width: 60)
    private let heightField = ValueField(width: 60)
    private let zField = ValueField(width: 60)
    private let radiusField = ValueField(width: 60)
    private let roamField = ValueField(placeholder: "none", width: 60)

    private let shirtWell = AdminUI.colorWell { _ in }
    private let pantsWell = AdminUI.colorWell { _ in }
    private let armWell = AdminUI.colorWell { _ in }

    private var hairPopUp: ActionPopUpButton!
    private var genderPopUp: ActionPopUpButton!
    private var headPopUp: ActionPopUpButton!
    private var emotePopUp: ActionPopUpButton!

    private let stack = AdminUI.verticalStack()

    /// "Random" is the blank option the JS puts at the top of the hair list.
    private static let randomHair = "Random"
    /// Blank clears `default_emote`.
    private static let noEmote = "None"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        let rotateLeft = HoldButton(title: "↺",
                                    onHold: { [weak self] in self?.nudge(\.rotation, by: -5, default: 0) },
                                    onRelease: { [weak self] in self?.sync("rotation") { $0.rotation ?? 0 } })
        let rotateRight = HoldButton(title: "↻",
                                     onHold: { [weak self] in self?.nudge(\.rotation, by: 5, default: 0) },
                                     onRelease: { [weak self] in self?.sync("rotation") { $0.rotation ?? 0 } })
        let widthDown = HoldButton(title: "−",
                                   onHold: { [weak self] in self?.nudge(\.width, by: -2, default: 40, minimum: 5) },
                                   onRelease: { [weak self] in self?.sync("width") { $0.width ?? 40 } })
        let widthUp = HoldButton(title: "+",
                                 onHold: { [weak self] in self?.nudge(\.width, by: 2, default: 40) },
                                 onRelease: { [weak self] in self?.sync("width") { $0.width ?? 40 } })
        let heightDown = HoldButton(title: "−",
                                    onHold: { [weak self] in self?.nudge(\.height, by: -2, default: 40, minimum: 5) },
                                    onRelease: { [weak self] in self?.sync("height") { $0.height ?? 40 } })
        let heightUp = HoldButton(title: "+",
                                  onHold: { [weak self] in self?.nudge(\.height, by: 2, default: 40) },
                                  onRelease: { [weak self] in self?.sync("height") { $0.height ?? 40 } })
        let zDown = HoldButton(title: "−",
                               onHold: { [weak self] in self?.nudge(\.z, by: -1, default: 0) },
                               onRelease: { [weak self] in self?.sync("z") { $0.z ?? 0 } })
        let zUp = HoldButton(title: "+",
                             onHold: { [weak self] in self?.nudge(\.z, by: 1, default: 0) },
                             onRelease: { [weak self] in self?.sync("z") { $0.z ?? 0 } })

        nameField.onCommit = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespaces)
            self?.update({ $0.name = name }, updates: ["name": .string(name)])
        }

        // Not a port, matching the object inspector: the hold buttons step by 5°, so an exact
        // facing was previously unreachable.
        rotationField.onCommit = { [weak self] text in
            let value = Double(text) ?? 0
            self?.update({ $0.rotation = value }, updates: ["rotation": JSONValue(value)])
        }

        widthField.onCommit = { [weak self] text in
            let value = Double(text) ?? 40
            self?.update({ $0.width = value }, updates: ["width": JSONValue(value)])
        }
        heightField.onCommit = { [weak self] text in
            let value = Double(text) ?? 40
            self?.update({ $0.height = value }, updates: ["height": JSONValue(value)])
        }
        zField.onCommit = { [weak self] text in
            let value = Double(text) ?? 0
            self?.update({ $0.z = value }, updates: ["z": JSONValue(value)])
        }
        radiusField.onCommit = { [weak self] text in
            let value = Double(text) ?? 150
            self?.update({ $0.interaction_radius = value },
                         updates: ["interaction_radius": JSONValue(value)])
        }
        // A blank or non-positive roam radius clears the field; the JS sends an explicit null
        // so the server deletes the key rather than storing zero.
        roamField.onCommit = { [weak self] text in
            if let value = Double(text), value > 0 {
                self?.update({ $0.roam_radius = value }, updates: ["roam_radius": JSONValue(value)])
            } else {
                self?.update({ $0.roam_radius = nil }, updates: ["roam_radius": .null])
            }
        }

        shirtWell.handler = { [weak self] color in
            self?.update({ $0.shirt_color = color.hexString },
                         updates: ["shirt_color": .string(color.hexString)])
        }
        pantsWell.handler = { [weak self] color in
            self?.update({ $0.pants_color = color.hexString },
                         updates: ["pants_color": .string(color.hexString)])
        }
        armWell.handler = { [weak self] color in
            self?.update({ $0.arm_color = color.hexString },
                         updates: ["arm_color": .string(color.hexString)])
        }

        hairPopUp = AdminUI.popUp([Self.randomHair] + HairColors.map.keys.sorted()) { [weak self] title in
            let value = title == Self.randomHair ? "" : title
            self?.update({ $0.hair_color = value.isEmpty ? nil : value },
                         updates: ["hair_color": .string(value)])
        }

        headPopUp = AdminUI.popUp([]) { [weak self] title in
            self?.update({ $0.head = title }, updates: ["head": .string(title)])
        }

        // Changing gender also resets the head, because the head tables do not overlap.
        genderPopUp = AdminUI.popUp(["male", "female"]) { [weak self] gender in
            guard let self else { return }
            let defaultHead = gender == "female" ? "female_hair_long" : "male_hair_short"
            self.update({ npc in
                npc.gender = gender
                npc.head = defaultHead
            }, updates: ["gender": .string(gender), "head": .string(defaultHead)])
            self.reloadHeadList(gender: gender, selected: defaultHead)
        }

        emotePopUp = AdminUI.popUp([Self.noEmote] + Emotes.table.keys.sorted()) { [weak self] title in
            if title == Self.noEmote {
                self?.update({ $0.default_emote = nil }, updates: ["default_emote": .null])
            } else {
                let emote = EmoteState(name: title, startTime: EventInterpreter.nowMilliseconds())
                self?.update({ $0.default_emote = emote },
                             updates: ["default_emote": .object([
                                "name": .string(title),
                                "startTime": JSONValue(emote.startTime),
                             ])])
            }
        }

        let deleteButton = AdminUI.button("Delete NPC") { [weak self] in
            self?.map?.editorDeleteSelection()
        }
        deleteButton.contentTintColor = .systemRed

        let rows: [NSView] = [
            AdminUI.sectionTitle("NPC"),
            idLabel,
            AdminUI.row("Name", [nameField]),
            AdminUI.row("Rotate", [rotateLeft, rotationField, rotateRight]),
            AdminUI.row("Width", [widthDown, widthField, widthUp]),
            AdminUI.row("Height", [heightDown, heightField, heightUp]),
            AdminUI.row("Z", [zDown, zField, zUp]),
            AdminUI.row("Interact", [radiusField]),
            AdminUI.row("Roam", [roamField]),
            AdminUI.row("Shirt", [shirtWell]),
            AdminUI.row("Pants", [pantsWell]),
            AdminUI.row("Arms", [armWell]),
            AdminUI.row("Hair", [hairPopUp]),
            AdminUI.row("Gender", [genderPopUp]),
            AdminUI.row("Head", [headPopUp]),
            AdminUI.row("Emote", [emotePopUp]),
            deleteButton,
        ]
        for row in rows { stack.addArrangedSubview(row) }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Model → panel

    func refresh() {
        guard let npc = map?.selectedNPC else {
            isHidden = true
            return
        }
        isHidden = false

        idLabel.stringValue = "ID: \(npc.id)"
        nameField.reload(npc.name ?? "")
        rotationField.reload(String(Int((npc.rotation ?? 0).rounded())))
        widthField.reload(String(Int(npc.width ?? 40)))
        heightField.reload(String(Int(npc.height ?? 40)))
        zField.reload(String(Int(npc.z ?? 0)))
        radiusField.reload(String(Int(npc.interaction_radius ?? 150)))
        roamField.reload(npc.roam_radius.map { String(Int($0)) } ?? "")

        shirtWell.reload(hex: npc.shirt_color ?? "#3498db")
        pantsWell.reload(hex: npc.pants_color ?? "#2c3e50")
        armWell.reload(hex: npc.arm_color ?? "#f1c40f")
        hairPopUp.reload(selected: npc.hair_color ?? Self.randomHair)

        let gender = npc.gender ?? "male"
        genderPopUp.reload(selected: gender)
        reloadHeadList(gender: gender, selected: npc.head)
        emotePopUp.reload(selected: npc.default_emote?.name ?? Self.noEmote)
    }

    /// The head list follows gender, plus whatever the NPC already has — an authored head
    /// from the other table stays selectable rather than being silently replaced
    /// (`admin.js:695-707`).
    private func reloadHeadList(gender: String, selected: String?) {
        var heads = (gender == "female" ? HeadTables.female : HeadTables.male).map(\.name).sorted()
        if let selected, !selected.isEmpty, !heads.contains(selected) {
            heads.append(selected)
        }
        let fallback = gender == "female" ? "female_hair_long" : "male_hair_short"
        headPopUp.reload(items: heads, selected: selected?.isEmpty == false ? selected : fallback)
    }

    // MARK: - Edits

    private func update(_ mutate: @escaping (inout GameCharacter) -> Void,
                        updates: [String: JSONValue]) {
        map?.mutateSelectedNPC(mutate, message: { .updateNPC(id: $0.id, updates: updates) })
    }

    private func nudge(_ keyPath: WritableKeyPath<GameCharacter, Double?>,
                       by amount: Double,
                       default defaultValue: Double,
                       minimum: Double? = nil) {
        map?.mutateSelectedNPCLocally { npc in
            var value = (npc[keyPath: keyPath] ?? defaultValue) + amount
            if let minimum { value = max(minimum, value) }
            npc[keyPath: keyPath] = value
        }
    }

    private func sync(_ key: String, _ value: (GameCharacter) -> Double) {
        map?.syncSelectedNPC { .updateNPC(id: $0.id, updates: [key: JSONValue(value($0))]) }
    }
}
