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

        session.connect()
    }
}

extension AdminRootViewController: AdminSessionDelegate {
    func adminSessionDidLoadWorld() {
        sidebar.reloadMaps()
        mapController.worldDidChange()
        sidebar.refreshAll()
        startSelfTestIfNeeded()
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
