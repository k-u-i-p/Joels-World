import AppKit

// An explicit `main.swift` rather than `@main`, matching the map editor: no storyboard, no scene
// manifest, and a launch path you can read top to bottom.
//
// The two headless modes — the clothing atlas and the measurement report — need neither a window
// nor a Metal device, so they run here and exit before an app is put on screen at all. That is
// what makes `-labreport` a fifth-of-a-second command rather than a window that flashes up.
let application = NSApplication.shared

if CharacterLabHeadless.run() {
    exit(0)
}

let appDelegate = CharacterLabAppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
