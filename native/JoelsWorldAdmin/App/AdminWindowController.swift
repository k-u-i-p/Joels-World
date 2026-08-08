import AppKit

final class AdminWindowController: NSWindowController {
    /// The editor opens nearly full screen — a map editor is a whole-desktop tool, and the
    /// more of the map that is visible the less panning it takes to place anything.
    private static func defaultFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 1600, height: 1000)
        }
        // `visibleFrame` already excludes the menu bar and the Dock.
        return screen.visibleFrame.insetBy(dx: 24, dy: 24)
    }

    convenience init() {
        let frame = Self.defaultFrame()
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Joels World Map Editor"
        window.minSize = NSSize(width: 900, height: 600)
        window.contentViewController = AdminRootViewController()

        // Assigning a content view controller resizes the window to that view's fitting size,
        // which the sidebar's stack makes far too small — so the frame is set afterwards.
        // A frame the operator saved by moving or resizing the window wins over the default.
        window.setFrameAutosaveName("AdminWindow")
        if !window.setFrameUsingName("AdminWindow") {
            window.setFrame(frame, display: false)
        }
        self.init(window: window)
    }
}
