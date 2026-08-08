import AppKit

// An explicit `main.swift` rather than `@main`: the admin app has no storyboard and no
// scene manifest, and this keeps the launch path readable.
let application = NSApplication.shared
let appDelegate = AdminAppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
