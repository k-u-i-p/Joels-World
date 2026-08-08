import AppKit

/// The two modes that produce a file and never draw a frame: the clothing atlas, and the
/// measurements.
///
/// Both are pure CPU work — the atlas is painted by `ClothingAtlas.pixels()`, the report poses
/// the rig itself — so neither needs the app to finish launching. `main.swift` runs this first
/// and exits if it did anything.
enum CharacterLabHeadless {

    /// True if it handled the launch and the app should stop here.
    @discardableResult
    static func run() -> Bool {
        var did = false

        if let path = CharacterLabArguments.atlasPath {
            did = true
            let wrote = CharacterLabCapture.writeAtlas(to: path)
            print(wrote ? "Clothing atlas written to \(path)" : "Failed to write \(path)")
        }

        if let path = CharacterLabArguments.reportPath {
            did = true
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

        // A picture was asked for as well, so the window still has to come up; the files above
        // are written on the way past.
        return did && CharacterLabArguments.shotPath == nil && CharacterLabArguments.sheetPath == nil
    }
}

final class CharacterLabAppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: CharacterLabWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let controller = CharacterLabWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `main.swift` skips the storyboard, so the standard menu bar has to be built by hand.
    /// Without it the app has no ⌘Q — and the lab is a window people leave open all day.
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Joels World Character Lab",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // ⌘C so the sidebar's "Copy command" has the standard route to the pasteboard, and
        // so a value in a text field can be copied out of the readout.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
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
