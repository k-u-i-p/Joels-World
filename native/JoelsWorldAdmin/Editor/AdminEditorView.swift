import AppKit

protocol AdminEditorViewDelegate: AnyObject {
    func editorMouseDown(at point: CGPoint, shiftHeld: Bool)
    func editorMouseDragged(to point: CGPoint)
    func editorMouseUp(at point: CGPoint)
    func editorMouseMoved(to point: CGPoint)
    /// Two-finger scroll pans; the same gesture with ⌃ or ⌘ zooms.
    func editorScroll(deltaX: CGFloat, deltaY: CGFloat, zooming: Bool)
    func editorMagnify(by factor: CGFloat)
    func editorDropImage(_ image: NSImage, at point: CGPoint)
    func editorDeleteSelection()
    func editorCopySelection()
    func editorPaste(at point: CGPoint)
}

/// The container the Metal view and the overlay live in, and the only view that takes input.
///
/// `admin.js` binds its handlers to `window` and filters out clicks that landed on the panels;
/// here the panels are siblings in a split view, so anything that reaches this view is a
/// click on the map.
final class AdminEditorView: NSView {
    weak var delegate: AdminEditorViewDelegate?

    /// Held arrow/WASD keys, polled by the frame loop. Owned here because this is the view
    /// that receives key events; a text field in the sidebar takes first responder while it is
    /// being typed into, which is what stops an inspector edit from walking the camera.
    let keyboard = KeyboardMovement()

    /// Screen coordinates run Y-down, matching the canvas maths the editor is ported from.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var lastMousePoint = CGPoint.zero
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    /// The cursor position is what a paste anchors to, so it has to be tracked even when no
    /// button is down — `admin.js` gets this from its window-level `mousedown` bookkeeping.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// The game's own UI — the HUD and the door dialog — layered above the map. Each one is
    /// click-through except for the single control that has to take a mouse, and each decides
    /// that for itself in its own `hitTest`, so they are asked first and the editor takes
    /// whatever they turn down.
    var interactiveOverlays: [NSView] = []

    /// The Metal view and the editor's overlay are passive layers; every event that the game's
    /// UI does not claim belongs to the editor.
    ///
    /// Answering `self` for *everything* — which is what this did before — meant the chat
    /// field could never be clicked, because AppKit stops at the first view that claims the
    /// point and never reaches the HUD underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard bounds.contains(local) else { return nil }
        // Topmost first, which is the order they are drawn in reverse.
        for overlay in interactiveOverlays.reversed() {
            // The overlays are direct subviews, so `local` is already the space their own
            // `hitTest` expects.
            if let hit = overlay.hitTest(local) { return hit }
        }
        return self
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        return point
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        delegate?.editorMouseDown(at: point(for: event),
                                  shiftHeld: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        delegate?.editorMouseDragged(to: point(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        delegate?.editorMouseUp(at: point(for: event))
    }

    override func mouseMoved(with event: NSEvent) {
        delegate?.editorMouseMoved(to: point(for: event))
    }

    override func scrollWheel(with event: NSEvent) {
        let zooming = event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command)
        delegate?.editorScroll(deltaX: event.scrollingDeltaX,
                               deltaY: event.scrollingDeltaY,
                               zooming: zooming)
    }

    override func magnify(with event: NSEvent) {
        delegate?.editorMagnify(by: event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete, 117 = forward delete.
        if event.keyCode == 51 || event.keyCode == 117 {
            delegate?.editorDeleteSelection()
            return
        }
        // Swallowed rather than passed on: `super.keyDown` would hand the arrows to AppKit,
        // which beeps at them here.
        if keyboard.keyDown(event) { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if keyboard.keyUp(event) { return }
        super.keyUp(with: event)
    }

    /// ⌘-tabbing away mid-stride would otherwise leave the key held forever.
    override func resignFirstResponder() -> Bool {
        keyboard.releaseAll()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(windowDidResignKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: window)
    }

    @objc private func windowDidResignKey() {
        keyboard.releaseAll()
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        delegate?.editorCopySelection()
    }

    @objc func paste(_ sender: Any?) {
        delegate?.editorPaste(at: lastMousePoint)
    }

    @objc func delete(_ sender: Any?) {
        delegate?.editorDeleteSelection()
    }

    // MARK: - Dropped tracing reference

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImageURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedImageURL(from: sender),
              let image = NSImage(contentsOf: url) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        delegate?.editorDropImage(image, at: point)
        return true
    }

    private func droppedImageURL(from sender: NSDraggingInfo) -> URL? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                              options: nil) as? [URL],
              let url = urls.first
        else { return nil }
        // The JS accepts PNG and JPEG only; anything else is warned about and ignored.
        let allowed: Set<String> = ["png", "jpg", "jpeg"]
        return allowed.contains(url.pathExtension.lowercased()) ? url : nil
    }
}
