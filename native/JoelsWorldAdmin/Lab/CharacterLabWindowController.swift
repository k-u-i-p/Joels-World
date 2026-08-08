#if DEBUG
import AppKit

/// The lab's window: the scene on the left, the controls on the right — the same split the map
/// editor uses, so the two feel like one tool.
///
/// A headless run (`-labshot`, `-labsheet`) sizes the window to `-labsize` and skips the
/// sidebar entirely, because the sidebar's width would otherwise decide how much of the
/// picture is character.
final class CharacterLabWindowController: NSWindowController {

    convenience init() {
        let capturing = CharacterLabArguments.quitsAfterCapture
        let size = CharacterLabArguments.captureSize
        let frame = capturing
            ? NSRect(x: 0, y: 0, width: size.width, height: size.height)
            : (NSScreen.main?.visibleFrame.insetBy(dx: 80, dy: 60)
               ?? NSRect(x: 0, y: 0, width: 1280, height: 800))

        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Joels World Character Lab"
        window.minSize = NSSize(width: 640, height: 480)
        window.contentViewController = CharacterLabRootViewController()
        if !capturing {
            window.setFrameAutosaveName("CharacterLabWindow")
            if !window.setFrameUsingName("CharacterLabWindow") { window.setFrame(frame, display: false) }
        } else {
            window.setFrame(frame, display: false)
        }
        self.init(window: window)
    }
}

/// Splits the lab surface from its controls, and keeps the controls in step with the clock.
private final class CharacterLabRootViewController: NSSplitViewController {
    private let lab = CharacterLabViewController()
    private var controls: CharacterLabControlsView?

    override func viewDidLoad() {
        super.viewDidLoad()

        let labItem = NSSplitViewItem(viewController: lab)
        labItem.minimumThickness = 400
        addSplitViewItem(labItem)

        // A capture wants the whole window to be the picture.
        guard !CharacterLabArguments.quitsAfterCapture else { return }

        let controls = CharacterLabControlsView(lab: lab)
        self.controls = controls

        let host = NSViewController()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = controls
        controls.translatesAutoresizingMaskIntoConstraints = false
        host.view = scroll
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            controls.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            controls.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let controlsItem = NSSplitViewItem(viewController: host)
        controlsItem.minimumThickness = 280
        controlsItem.maximumThickness = 340
        controlsItem.canCollapse = true
        addSplitViewItem(controlsItem)

        lab.onFrame = { [weak self] in self?.controls?.refresh() }
    }
}
#endif
