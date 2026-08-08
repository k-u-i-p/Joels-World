import AppKit

/// Port of `#edit-obj-section` and its handlers (`admin.js:305-443`, `630-676`).
///
/// Every control writes the local record first and then sends one message, which is what
/// makes a dragged or nudged shape move on screen before the server answers.
final class ObjectInspectorView: NSView {
    weak var map: AdminMapViewController?

    private let idLabel = AdminUI.label("ID: —", bold: true)
    private let nameField = ValueField(placeholder: "Object name (optional)", width: 150)
    private let widthField = ValueField(width: 60)
    private let lengthField = ValueField(width: 60)
    private let clipField = ValueField(width: 60)
    private let scaleField = ValueField(width: 60)
    private let zField = ValueField(width: 60)
    private let modelField = ValueField(placeholder: "models/chair.glb", width: 150)

    private var modelOnlyRows: [NSView] = []
    private let stack = AdminUI.verticalStack()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        let rotateLeft = HoldButton(title: "↺",
                                    onHold: { [weak self] in self?.nudgeRotation(-1) },
                                    onRelease: { [weak self] in self?.syncRotation() })
        let rotateRight = HoldButton(title: "↻",
                                     onHold: { [weak self] in self?.nudgeRotation(1) },
                                     onRelease: { [weak self] in self?.syncRotation() })

        // `admin.js:391` steps by 2% of the current size, with a floor of one unit — so big
        // shapes resize fast and small ones stay controllable.
        let widthDown = HoldButton(title: "−",
                                   onHold: { [weak self] in self?.nudgeSize(widthDirection: -1) },
                                   onRelease: { [weak self] in self?.syncSize() })
        let widthUp = HoldButton(title: "+",
                                 onHold: { [weak self] in self?.nudgeSize(widthDirection: 1) },
                                 onRelease: { [weak self] in self?.syncSize() })
        let lengthDown = HoldButton(title: "−",
                                    onHold: { [weak self] in self?.nudgeSize(lengthDirection: -1) },
                                    onRelease: { [weak self] in self?.syncSize() })
        let lengthUp = HoldButton(title: "+",
                                  onHold: { [weak self] in self?.nudgeSize(lengthDirection: 1) },
                                  onRelease: { [weak self] in self?.syncSize() })
        let zDown = HoldButton(title: "−",
                               onHold: { [weak self] in self?.nudgeZ(-1) },
                               onRelease: { [weak self] in self?.syncZ() })
        let zUp = HoldButton(title: "+",
                             onHold: { [weak self] in self?.nudgeZ(1) },
                             onRelease: { [weak self] in self?.syncZ() })

        nameField.onCommit = { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespaces)
            self?.map?.mutateSelectedObject({ $0.name = name.isEmpty ? nil : name },
                                            message: { .renameObject(id: $0.id, name: $0.name) })
        }

        // A field that will not parse falls back to the JS default of 100, as `parseInt`'s
        // NaN branch does at `admin.js:435`.
        widthField.onCommit = { [weak self] text in self?.commitSize(width: Double(text) ?? 100) }
        lengthField.onCommit = { [weak self] text in self?.commitSize(length: Double(text) ?? 100) }

        clipField.onCommit = { [weak self] text in
            let value = Double(text) ?? 10
            self?.map?.mutateSelectedObject({ $0.clip = value },
                                            message: { .updateObject(id: $0.id,
                                                                     updates: ["clip": JSONValue(value)]) })
        }

        scaleField.onCommit = { [weak self] text in
            let value = Double(text) ?? 1.0
            self?.map?.mutateSelectedObject({ $0.scale = value },
                                            message: { .updateObject(id: $0.id,
                                                                     updates: ["scale": JSONValue(value)]) })
        }

        zField.onCommit = { [weak self] text in
            let value = Double(text) ?? 0
            self?.map?.mutateSelectedObject({ $0.z = value },
                                            message: { .updateObject(id: $0.id,
                                                                     updates: ["z": JSONValue(value)]) })
        }

        modelField.onCommit = { [weak self] text in
            // `admin.js:430` ignores an empty string rather than clearing the model.
            let path = text.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return }
            self?.map?.mutateSelectedObject({ $0.model = path },
                                            message: { .updateObject(id: $0.id,
                                                                     updates: ["model": .string(path)]) })
        }

        let scaleRow = AdminUI.row("Scale", [scaleField])
        let zRow = AdminUI.row("Z", [zDown, zField, zUp])
        let modelRow = AdminUI.row("Model", [modelField])
        modelOnlyRows = [scaleRow, zRow, modelRow]

        let deleteButton = AdminUI.button("Delete Object") { [weak self] in
            self?.map?.editorDeleteSelection()
        }
        deleteButton.contentTintColor = .systemRed

        let rows: [NSView] = [
            AdminUI.sectionTitle("Object"),
            idLabel,
            AdminUI.row("Name", [nameField]),
            AdminUI.row("Rotate", [rotateLeft, rotateRight]),
            AdminUI.row("Width", [widthDown, widthField, widthUp]),
            AdminUI.row("Length", [lengthDown, lengthField, lengthUp]),
            AdminUI.row("Clip", [clipField]),
            scaleRow, zRow, modelRow,
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
        guard let object = map?.selectedObject else {
            isHidden = true
            return
        }
        isHidden = false

        idLabel.stringValue = "ID: \(object.id)"
        nameField.reload(object.name ?? "")
        widthField.reload(String(Int((object.width ?? 100).rounded())))
        lengthField.reload(String(Int((object.length ?? 100).rounded())))
        clipField.reload(String(Int(object.clip ?? 10)))

        let is3D = object.shape == "3d_model"
        for row in modelOnlyRows { row.isHidden = !is3D }
        if is3D {
            scaleField.reload(String(object.scale ?? 1.0))
            zField.reload(String(Int(object.z ?? 0)))
            modelField.reload(object.model ?? "")
        }
    }

    // MARK: - Edits

    private func nudgeRotation(_ delta: Double) {
        map?.mutateSelectedObjectLocally { $0.rotation = ($0.rotation ?? 0) + delta }
    }

    private func syncRotation() {
        map?.syncSelectedObject { .rotateObject(id: $0.id, rotation: $0.rotation ?? 0) }
    }

    private func nudgeSize(widthDirection: Double = 0, lengthDirection: Double = 0) {
        map?.mutateSelectedObjectLocally { object in
            let anchor = EditorGeometry.topLeftAnchor(of: object)
            var width = object.width ?? 0
            var length = object.length ?? 0
            if widthDirection != 0 {
                width = max(5, width + max(1, (width * 0.02).rounded()) * widthDirection)
            }
            if lengthDirection != 0 {
                length = max(5, length + max(1, (length * 0.02).rounded()) * lengthDirection)
            }
            EditorGeometry.applyResize(to: &object, width: width, length: length,
                                       anchorX: anchor.x, anchorY: anchor.y)
        }
    }

    private func syncSize() {
        map?.syncSelectedObject {
            .resizeObject(id: $0.id, width: $0.width ?? 0, length: $0.length ?? 0, x: $0.x, y: $0.y)
        }
    }

    /// Typing a size commits immediately, and — unlike the − / + buttons — leaves the centre
    /// where it is. That is what `admin.js:437` does: the field path skips the anchor logic.
    private func commitSize(width: Double? = nil, length: Double? = nil) {
        map?.mutateSelectedObject({ object in
            if let width { object.width = width }
            if let length { object.length = length }
        }, message: {
            .resizeObject(id: $0.id, width: $0.width ?? 0, length: $0.length ?? 0, x: $0.x, y: $0.y)
        })
    }

    private func nudgeZ(_ delta: Double) {
        map?.mutateSelectedObjectLocally { object in
            guard object.shape == "3d_model" else { return }
            object.z = (object.z ?? 0) + delta
        }
    }

    private func syncZ() {
        map?.syncSelectedObject { .updateObject(id: $0.id, updates: ["z": JSONValue($0.z ?? 0)]) }
    }
}
