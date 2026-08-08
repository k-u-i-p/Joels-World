import AppKit

/// The control column: server connection, map picker, the create buttons, and the three
/// inspectors. Port of `#admin-panel` (`admin.js:84-106`, `305-331`) plus the panels the map
/// selection drives.
final class AdminSidebarView: NSView {
    private weak var session: AdminSession?
    private weak var map: AdminMapViewController?

    private let statusLabel = AdminUI.label("Not connected")
    private let cursorLabel = AdminUI.label("Cursor: —")
    private var hostField: ValueField!
    private var keyField: ValueField!
    private var mapPopUp: ActionPopUpButton!

    private let objectInspector = ObjectInspectorView()
    private let npcInspector = NPCInspectorView()
    private let eventEditor = EventEditorView()

    private let stack = AdminUI.verticalStack()
    /// `id → title`, so the picker can map a selected title back to a map id.
    private var mapTitles: [String: Int] = [:]

    /// A flipped document view lays out from the top and makes the scroll view open at the
    /// top rather than scrolled to the bottom.
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(session: AdminSession, map: AdminMapViewController) {
        self.session = session
        self.map = map
        objectInspector.map = map
        npcInspector.map = map
        eventEditor.map = map

        let settings = session.serverSettings
        hostField.reload(settings.host)
        keyField.reload(settings.adminKey)
        refreshAll()
    }

    private func build() {
        hostField = ValueField(placeholder: "joels-world.com", width: 190)
        // A key is always required. On a loopback server without `ADMIN_KEY` set, any
        // non-empty value is accepted — see `grantsAdmin` in `server/websocket.js`.
        keyField = ValueField(placeholder: "ADMIN_KEY (any value on localhost)", width: 190)

        let connectButton = AdminUI.button("Connect") { [weak self] in
            guard let self else { return }
            self.session?.connect(using: AdminServerSettings(host: self.hostField.stringValue,
                                                             adminKey: self.keyField.stringValue))
        }

        mapPopUp = AdminUI.popUp([]) { [weak self] title in
            guard let self, let mapId = self.mapTitles[title] else { return }
            self.session?.changeMap(mapId)
            self.map?.select(objectId: nil)
            self.map?.select(npcId: nil)
        }

        // The four create buttons drop their entity at the camera focus, the way the JS drops
        // one at the player's feet.
        let createRect = AdminUI.button("+ Rect") { [weak self] in
            self?.create(shape: "rect")
        }
        let createCircle = AdminUI.button("+ Circle") { [weak self] in
            self?.create(shape: "circle")
        }
        let create3D = AdminUI.button("+ 3D Model") { [weak self] in
            guard let self, let point = self.map?.creationPoint else { return }
            self.session?.send(.createObject(shape: "3d_model", x: point.x, y: point.y,
                                             fields: ["model": .string("models/chair.glb"),
                                                      "scale": JSONValue(1.0),
                                                      "z": JSONValue(0),
                                                      "width": JSONValue(100),
                                                      "length": JSONValue(100)]))
        }
        let createNPC = AdminUI.button("+ NPC") { [weak self] in
            guard let self, let point = self.map?.creationPoint else { return }
            self.session?.send(.createNPC(x: point.x, y: point.y))
        }

        let createRow = NSStackView(views: [createRect, createCircle, create3D, createNPC])
        createRow.orientation = .horizontal
        createRow.spacing = 4

        for view in [AdminUI.sectionTitle("Server"),
                     AdminUI.row("Host", [hostField]),
                     AdminUI.row("Key", [keyField]),
                     connectButton,
                     statusLabel,
                     separator(),
                     AdminUI.sectionTitle("Map"),
                     mapPopUp as NSView,
                     cursorLabel,
                     createRow,
                     separator(),
                     objectInspector,
                     npcInspector,
                     eventEditor] {
            stack.addArrangedSubview(view)
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func create(shape: String) {
        guard let point = map?.creationPoint else { return }
        session?.send(.createObject(shape: shape, x: point.x, y: point.y,
                                    fields: ["width": JSONValue(100), "length": JSONValue(100)]))
    }

    // MARK: - Updates

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    func setCursor(x: Double, y: Double) {
        cursorLabel.stringValue = "Cursor: x \(Int(x.rounded())), y \(Int(y.rounded()))"
    }

    func reloadMaps() {
        guard let session else { return }
        mapTitles.removeAll()
        var titles: [String] = []
        for entry in session.maps {
            let title = entry.name ?? "Map \(entry.id)"
            titles.append(title)
            mapTitles[title] = entry.id
        }
        let currentId = session.state.mapData?.id
        let selected = titles.first { mapTitles[$0] == currentId }
        mapPopUp.reload(items: titles, selected: selected)
    }

    /// A selection change reloads everything, including the event editor's working copy.
    func refreshAll() {
        objectInspector.refresh()
        npcInspector.refresh()
        eventEditor.refresh()
    }

    /// A drag or a nudge only moves geometry, so the event editor's unsaved working copy is
    /// left alone.
    func refreshInspectors() {
        objectInspector.refresh()
        npcInspector.refresh()
    }
}
