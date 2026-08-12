import AppKit

/// The whole editor: the map on the left, a control column on the right.
///
/// `admin.js` floats two draggable panels over the game canvas (`#admin-panel` and
/// `#edit-obj-section`). A docked sidebar is the Mac equivalent and removes the panel-drag
/// bookkeeping — and the "was this click on a panel?" filtering every mouse handler in the JS
/// has to do — entirely.
final class AdminRootViewController: NSSplitViewController {
    private let session = AdminSession()
    private lazy var mapController = AdminMapViewController(session: session)
    private let sidebar = AdminSidebarView()

    private var mapItem: NSSplitViewItem!
    private var sidebarItem: NSSplitViewItem!
    private var selfTest: AdminSelfTest?

    override func viewDidLoad() {
        super.viewDidLoad()

        session.delegate = self

        mapItem = NSSplitViewItem(viewController: mapController)
        mapItem.minimumThickness = 400

        let sidebarController = NSViewController()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = sidebar
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarController.view = scroll
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        sidebarItem = NSSplitViewItem(viewController: sidebarController)
        sidebarItem.minimumThickness = 300
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true

        addSplitViewItem(mapItem)
        addSplitViewItem(sidebarItem)

        sidebar.configure(session: session, map: mapController)

        mapController.onSelectionChanged = { [weak self] in self?.sidebar.refreshAll() }
        mapController.onSelectedEntityChanged = { [weak self] in self?.sidebar.refreshInspectors() }
        mapController.onCursorMoved = { [weak self] x, y in
            self?.sidebar.setCursor(x: x, y: y)
        }
        mapController.onOverlayVisibilityChanged = { [weak self] visible in
            self?.sidebar.setOverlaysVisible(visible)
        }
        mapController.onCameraChanged = { [weak self] pitch, zoom in
            self?.sidebar.setCameraView(radians: pitch, zoom: zoom)
        }
        sidebar.setCameraView(radians: session.state.camera.pitch, zoom: session.state.camera.zoom)
        // The map's view loads before this wiring exists, so `-nooverlays` has already been
        // applied by now and the checkbox has to be caught up rather than told.
        sidebar.setOverlaysVisible(mapController.showsOverlays)

        session.connect()
    }
}

/// ⌘O with the keyboard in an inspector field.
///
/// The responder chain from a sidebar text field runs up its own column and reaches this
/// controller without ever passing the map's, so the map controller's copy of the action is out
/// of reach and the menu item would be greyed out mid-edit. Answering here too puts it back.
extension AdminRootViewController: NSMenuItemValidation {
    @objc func toggleEditorOverlays(_ sender: Any?) {
        mapController.setOverlaysVisible(!mapController.showsOverlays)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleEditorOverlays(_:)) else { return true }
        menuItem.state = mapController.showsOverlays ? .on : .off
        return true
    }
}

extension AdminRootViewController: AdminSessionDelegate {
    func adminSessionDidLoadWorld() {
        sidebar.reloadMaps()
        mapController.worldDidChange()
        sidebar.refreshAll()
        // A map change loads that map's own angle and zoom, so the sliders are caught up.
        sidebar.setCameraView(radians: session.state.camera.pitch, zoom: session.state.camera.zoom)
        applySelectionArgument()
        startSelfTestIfNeeded()
    }

    /// `-select object|npc <id>` — picks an entity on the way in, so a scripted `-shot` can
    /// frame an inspector or an NPC's rings and route. Selection is otherwise only reachable
    /// by clicking, which nothing can do from a script.
    private func applySelectionArgument() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-select"), index + 2 < arguments.count,
              let id = Int(arguments[index + 2])
        else { return }

        switch arguments[index + 1] {
        case "object": mapController.select(objectId: id)
        case "npc": mapController.select(npcId: id)
        default: Log.world("-select expects 'object' or 'npc'")
        }
        sidebar.refreshAll()
    }

    private func startSelfTestIfNeeded() {
        guard AdminSelfTest.isEnabled, selfTest == nil else { return }
        let test = AdminSelfTest(map: mapController, session: session)
        selfTest = test
        test.run()
    }

    func adminSessionDidReplaceEntities() {
        mapController.worldDidChange()
        sidebar.refreshAll()
    }

    func adminSession(didChangeStatus status: String) {
        sidebar.setStatus(status)
    }
}
