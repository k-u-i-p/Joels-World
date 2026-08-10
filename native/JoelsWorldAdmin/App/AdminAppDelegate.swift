import AppKit

final class AdminAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: AdminWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = AdminWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `main.swift` skips the storyboard, so the standard menu bar has to be built by hand.
    /// Without it the app has no ⌘Q, and — more importantly for the editor — no ⌘C/⌘V, since
    /// AppKit routes those through the menu's key equivalents.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Joels World Map Editor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // ⌘O is free here — this app has nothing to open — and "O for overlays" is easier to
        // remember than the modifier pile-up the unused shortcuts would need. The action has no
        // target: AppKit walks the responder chain to `AdminMapViewController`, which also ticks
        // the item in `validateMenuItem`.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let overlaysItem = viewMenu.addItem(
            withTitle: "Show Overlays",
            action: #selector(AdminMapViewController.toggleEditorOverlays(_:)),
            keyEquivalent: "o")
        overlaysItem.state = .on
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
