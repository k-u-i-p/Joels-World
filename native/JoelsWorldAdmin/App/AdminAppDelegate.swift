import AppKit

final class AdminAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        #if DEBUG
        // `-lab` opens the character lab instead of the map editor: the same engine, no server,
        // and one character on a metre grid. See `CharacterLabArguments` for the whole flag set.
        if CharacterLabArguments.isEnabled {
            if CharacterLabArguments.isHeadlessOnly { return runHeadlessLab() }
            let controller = CharacterLabWindowController()
            controller.showWindow(nil)
            windowController = controller
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        #endif

        let controller = AdminWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    /// The lab's two GPU-free modes — the clothing atlas and the measurement report — done and
    /// dusted before a window is ever put on screen.
    private func runHeadlessLab() {
        if let path = CharacterLabArguments.atlasPath {
            let wrote = CharacterLabCapture.writeAtlas(to: path)
            print(wrote ? "Clothing atlas written to \(path)" : "Failed to write \(path)")
        }
        if let path = CharacterLabArguments.reportPath {
            let reports = CharacterLabReport.measureAll(cast: CharacterLabArguments.cast,
                                                        speedScale: CharacterLabArguments.speedScale ?? 1,
                                                        samples: CharacterLabArguments.reportSamples)
            print(CharacterLabReport.digest(reports))
            if let data = CharacterLabReport.json(reports),
               (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                print("Report written to \(path)")
            } else {
                print("Failed to write \(path)")
            }
        }
        NSApp.terminate(nil)
    }
    #endif

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
