import AppKit
import MetalKit
import simd

/// The map surface: a Metal view running the game renderer, an overlay drawing the editor's
/// boxes and rings over it, and the direct manipulation from `admin.js`'s window-level mouse
/// handlers (`admin.js:1023-1238`).
final class AdminMapViewController: NSViewController {
    private let session: AdminSession
    private var metalView: MTKView!
    private var renderer: Renderer?
    private let overlay = AdminOverlayView()
    /// The game's own UI, above the editor's: the HUD the world raises as the camera walks
    /// past its triggers, and the door prompts it puts up.
    private let hud = AdminHUDView()
    private let dialog = AdminDialogView()
    private var editorView: AdminEditorView { view as! AdminEditorView }

    /// The held-key set the frame loop polls. Exposed so `-selftest` can drive the real
    /// handlers, the way its mouse steps do.
    var keyboard: KeyboardMovement { editorView.keyboard }

    /// Raised whenever the inspectors need to re-read the selection.
    var onSelectionChanged: (() -> Void)?
    /// Raised when a drag or resize changed the selected entity's geometry, so open inspector
    /// fields track the shape on screen.
    var onSelectedEntityChanged: (() -> Void)?
    var onCursorMoved: ((Double, Double) -> Void)?

    private(set) var selection = EditorSelection()

    private enum DragMode {
        case none
        /// Panning the map by moving the camera focus.
        case panning(lastPoint: CGPoint)
        /// Moving every selected object, each from where it was when the drag began.
        case objects(startWorldX: Double, startWorldY: Double, origins: [Int: (x: Double, y: Double)])
        case npc(offsetX: Double, offsetY: Double)
        case resizing(anchorX: Double, anchorY: Double)
        case tracingImage(offsetX: Double, offsetY: Double)
    }

    private var dragMode = DragMode.none
    private var clipboard: EditorClipboard?
    private var backgroundImage: NSImage?
    private var backgroundOrigin: (x: Double, y: Double) = (0, 0)

    enum EditorClipboard {
        case object(WorldObject)
        case npc(GameCharacter)
    }

    init(session: AdminSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let container = AdminEditorView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        container.delegate = self
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = MTLCreateSystemDefaultDevice() else {
            presentFatal("This Mac does not support Metal.")
            return
        }

        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        view.addSubview(metalView)

        overlay.frame = view.bounds
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)

        installGameUI()

        guard let renderer = Renderer(view: metalView, state: session.state) else {
            presentFatal("Failed to initialise the renderer.")
            return
        }
        self.renderer = renderer

        // The editor's camera focus *is* its player (see `setCameraFocus`), so the keyboard
        // walks it: arrows or WASD, tank controls, through the shipped movement and collision
        // code. Dragging still pans freely — that path writes the focus directly and ignores
        // walls, which is what you want when framing a shot rather than testing one.
        let keyboard = editorView.keyboard
        renderer.inputProvider = { keyboard.inputState() }
        renderer.onFrame = { [weak self] _ in
            self?.applyCameraKeys()
            self?.refreshOverlay()
        }
        metalView.delegate = renderer

        if let pitch = AdminScreenshot.cameraPitch { session.state.camera.setPitch(delta: pitch) }
        if let yaw = AdminScreenshot.cameraYaw { session.state.camera.yaw = yaw }
        if let zoom = AdminScreenshot.cameraZoom { session.state.camera.zoom = min(max(0.1, zoom), 5) }

        if AdminScreenshot.quitsAfterShot {
            // A blit source has to be readable; the default drawable is write-only.
            metalView.framebufferOnly = false
            scheduleScreenshot(device: device)
        }
    }

    /// **R and F tip the camera over; Q and E swing it round; 0 puts it back.**
    ///
    /// Applied per frame off the held-key set rather than on the keystroke, the same way the
    /// movement keys are, so holding one turns smoothly instead of stuttering on key repeat.
    /// This is the editor's own control and nothing the game ships — it exists so a character
    /// can be looked at from the side, which is the only angle a rig can be judged from.
    private func applyCameraKeys() {
        let nudge = editorView.keyboard.cameraNudge()
        if nudge.reset {
            session.state.camera.pitch = 0
            session.state.camera.yaw = 0
            return
        }
        guard nudge.pitch != 0 || nudge.yaw != 0 else { return }
        session.state.camera.setPitch(delta: nudge.pitch)
        session.state.camera.yaw += nudge.yaw
    }

    /// Grabs one frame once the map has had time to stream in, writes it, and quits.
    private func scheduleScreenshot(device: MTLDevice) {
        guard let path = AdminScreenshot.path else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + AdminScreenshot.delay) { [weak self] in
            guard let self else { return }
            var captured = false
            self.renderer?.captureHandler = { [weak self] texture, commandBuffer in
                guard !captured else { return }
                captured = true
                AdminScreenshot.capture(texture: texture,
                                        commandBuffer: commandBuffer,
                                        device: device) { image in
                    guard let self else { return }
                    self.renderer?.captureHandler = nil
                    if let image, AdminScreenshot.write(world: image,
                                                        map: self.overlay,
                                                        overlays: [self.overlay, self.hud, self.dialog],
                                                        to: path) {
                        Log.render("Screenshot written to \(path)")
                    } else {
                        Log.render("Screenshot failed")
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(editorView)
    }

    // MARK: - The game's UI

    /// Puts the HUD and the door prompt above the editor's overlay.
    ///
    /// Both are click-through except for the one control in each that has to take a mouse —
    /// the chat field and the prompt's panel — so neither can take the map away from the
    /// operator while it is up.
    ///
    /// `session.ui` is wired from here rather than from the root controller because it only
    /// means anything once these two views exist.
    private func installGameUI() {
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)

        dialog.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dialog)

        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.topAnchor),
            hud.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hud.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dialog.topAnchor.constraint(equalTo: view.topAnchor),
            dialog.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dialog.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dialog.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Without this the container view claims every click and neither the chat field nor
        // the dialog's buttons can be reached.
        editorView.interactiveOverlays = [hud, dialog]

        hud.onChatSubmit = { [weak self] message in
            self?.session.submitChat(message)
        }

        // The same wiring `GameViewController` gives its dialog: Yes on a door prompt is the
        // only route to a map change.
        dialog.onConfirm = { [weak self] action in
            switch action {
            case .changeMap(let mapId):
                Log.world("Requesting map change to \(mapId)")
                self?.session.changeMapThroughDoor(mapId)
            }
        }

        session.ui = self
    }

    // MARK: - What a click would land on

    /// The three things a point in the map view can belong to. Only ever asked by `-selftest`:
    /// the container view claiming every point, and so swallowing every click meant for the
    /// chat field, is a regression that leaves no other trace.
    enum ClickTarget: String {
        case map, chatField, dialog, nothing
    }

    func clickTarget(at point: CGPoint) -> ClickTarget {
        // `hitTest` takes a point in the *superview's* space.
        let fromSuperview = view.superview.map { view.convert(point, to: $0) } ?? point
        guard let hit = view.hitTest(fromSuperview) else { return .nothing }
        if hit.isDescendant(of: dialog) { return .dialog }
        if hit.isDescendant(of: hud) { return .chatField }
        return .map
    }

    /// Where the chat field sits in the map view's coordinates.
    var chatFieldPoint: CGPoint { hud.convert(hud.chatFieldCentre, to: view) }

    var chatRowWidths: [CGFloat] { hud.chatRowWidths }

    private func presentFatal(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.frame = view.bounds
        label.alignment = .center
        view.addSubview(label)
    }

    // MARK: - Overlay feed

    private func refreshOverlay() {
        var snapshot = AdminOverlayView.Snapshot(camera: session.state.camera)
        snapshot.objects = session.state.objects
        snapshot.npcs = session.state.npcs
        snapshot.selection = selection
        snapshot.backgroundImage = backgroundImage
        snapshot.backgroundOrigin = backgroundOrigin

        // Projected against the overlay's own bounds, which is the space it draws in.
        let viewport = SIMD2<Float>(Float(overlay.bounds.width), Float(overlay.bounds.height))
        if viewport.x > 0, viewport.y > 0 {
            snapshot.characters = CharacterOverlay.entries(in: session.state, viewport: viewport)
        }

        // The roam circle is centred on where the NPC was authored, not where it has wandered
        // to. `NPCBehaviour` seeds `startX`/`startY` the first time it moves one.
        if let npcId = selection.npcId, let npc = selectedNPC {
            let visual = session.state.visuals[npcId]
            if let startX = visual?.startX, let startY = visual?.startY {
                snapshot.roamOrigins[npcId] = (startX, startY)
            }
            snapshot.waypointRoute = Self.waypointRoute(
                for: npc,
                start: (visual?.startX ?? npc.x, visual?.startY ?? npc.y))
        }

        overlay.snapshot = snapshot
    }

    /// Resolves an NPC's authored waypoints — which are *cumulative* offsets from wherever it
    /// started — into the world positions `NPCBehaviour.patrol` actually walks, closed by the
    /// implicit step that takes it home.
    static func waypointRoute(for npc: GameCharacter,
                              start: (x: Double, y: Double)) -> [(x: Double, y: Double)] {
        guard let waypoints = npc.waypoints, !waypoints.isEmpty else { return [] }

        var route = [start]
        var x = start.x
        var y = start.y
        for step in waypoints {
            x += step.x ?? 0
            y += step.y ?? 0
            route.append((x, y))
        }
        route.append(start)
        return route
    }

    /// Called when the world is replaced, so a selection that no longer exists is dropped.
    func worldDidChange() {
        selection = EditorSelection(keeping: selection, in: session.state)
        onSelectionChanged?()
        refreshOverlay()
    }

    // MARK: - Coordinates

    /// The editor's `screenToWorld` (`main.js:106-115`): a ray through the cursor intersected
    /// with the ground plane. `Camera.unprojectToGroundPlane` works in render space, where Y
    /// is negated relative to the world.
    private func worldPoint(at point: CGPoint) -> (x: Double, y: Double)? {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1,
                               -Float(point.y / size.height) * 2 + 1)
        guard let hit = session.state.camera.unprojectToGroundPlane(ndc: ndc) else { return nil }
        return (Double(hit.x), Double(-hit.y))
    }

    // MARK: - Selection helpers

    var selectedObject: WorldObject? { selection.object(in: session.state.objects) }
    var selectedNPC: GameCharacter? { selection.npc(in: session.state.npcs) }

    func select(objectId: Int?) {
        selection.setObject(objectId)
        if objectId != nil { selection.setNPC(nil) }
        onSelectionChanged?()
        refreshOverlay()
    }

    func select(npcId: Int?) {
        selection.setNPC(npcId)
        if npcId != nil { selection.setObject(nil) }
        onSelectionChanged?()
        refreshOverlay()
    }

    /// Where a newly created entity lands. `admin.js` uses the player's position; the editor's
    /// "player" is the camera focus, which is the middle of what the operator is looking at.
    var creationPoint: (x: Double, y: Double) {
        (session.state.player.x.rounded(), session.state.player.y.rounded())
    }

    // MARK: - Mutations that the inspectors share

    /// Applies a change locally and tells the server, in that order — the same shape every
    /// handler in `admin.js` has.
    func mutateSelectedObject(_ mutate: (inout WorldObject) -> Void,
                              message: (WorldObject) -> AdminMessage) {
        guard let id = selection.objectIds.first else { return }
        mutateObject(id: id, mutate, message: message)
    }

    func mutateSelectedNPC(_ mutate: (inout GameCharacter) -> Void,
                           message: (GameCharacter) -> AdminMessage) {
        guard let id = selection.npcId else { return }
        mutateNPC(id: id, mutate, message: message)
    }

    /// The same edit addressed by id rather than by the selection, so a panel can commit to
    /// the entity it was *editing* even after the selection has moved on — which is what the
    /// event editor's "save before switching" prompt needs.
    func mutateObject(id: Int, _ mutate: (inout WorldObject) -> Void,
                      message: (WorldObject) -> AdminMessage) {
        guard let updated = session.state.editObject(id: id, mutate) else { return }
        session.send(message(updated))
        onSelectedEntityChanged?()
        refreshOverlay()
    }

    func mutateNPC(id: Int, _ mutate: (inout GameCharacter) -> Void,
                   message: (GameCharacter) -> AdminMessage) {
        guard let updated = session.state.editNPC(id: id, mutate) else { return }
        session.send(message(updated))
        onSelectedEntityChanged?()
        refreshOverlay()
    }

    /// Local-only edit, for a hold-to-repeat button that syncs once on mouse-up.
    func mutateSelectedObjectLocally(_ mutate: (inout WorldObject) -> Void) {
        guard let id = selection.objectIds.first else { return }
        session.state.editObject(id: id, mutate)
        onSelectedEntityChanged?()
        refreshOverlay()
    }

    func mutateSelectedNPCLocally(_ mutate: (inout GameCharacter) -> Void) {
        guard let id = selection.npcId else { return }
        session.state.editNPC(id: id, mutate)
        onSelectedEntityChanged?()
        refreshOverlay()
    }

    func syncSelectedObject(_ message: (WorldObject) -> AdminMessage) {
        guard let object = selectedObject else { return }
        session.send(message(object))
    }

    func syncSelectedNPC(_ message: (GameCharacter) -> AdminMessage) {
        guard let npc = selectedNPC else { return }
        session.send(message(npc))
    }
}

// MARK: - The game's UI

/// `AdminSession` forwards the simulation's presentation calls here. The views do the rest of
/// the work — in particular, which NPC owns the portrait, so that walking out of one NPC's
/// radius cannot clear a portrait another has since raised.
extension AdminMapViewController: AdminGameUI {
    func showDialog(_ request: DialogRequest) {
        dialog.present(request)
    }

    func hideDialog() {
        dialog.dismiss()
    }

    func showAvatar(sourceId: Int, name: String?, imagePath: String) {
        hud.showAvatar(sourceId: sourceId, name: name, imagePath: imagePath)
    }

    func hideAvatar(sourceId: Int?) {
        hud.hideAvatar(sourceId: sourceId)
    }

    func setMapName(_ name: String?) {
        hud.setMapName(name)
    }

    func addChatMessage(sender: String, message: String) {
        hud.addChatMessage(sender: sender, message: message)
    }

    func clearChat() {
        hud.clearChat()
    }
}

// MARK: - Direct manipulation

extension AdminMapViewController: AdminEditorViewDelegate {
    /// Port of the `mousedown` handler (`admin.js:1023-1112`).
    ///
    /// The order matters and is preserved: the resize handle wins over everything, then NPCs
    /// beat objects, and a second click on something already selected starts a drag rather
    /// than re-selecting it.
    func editorMouseDown(at point: CGPoint, shiftHeld: Bool) {
        guard let world = worldPoint(at: point) else { return }
        onCursorMoved?(world.x, world.y)

        if let object = selectedObject,
           EditorGeometry.hitsResizeHandle(object: object,
                                           worldX: world.x, worldY: world.y,
                                           zoom: session.state.camera.zoom) {
            let anchor = EditorGeometry.topLeftAnchor(of: object)
            dragMode = .resizing(anchorX: anchor.x, anchorY: anchor.y)
            return
        }

        let previousObjectIds = selection.objectIds
        let previousNpcId = selection.npcId

        if let npc = EditorGeometry.npc(at: world.x, worldY: world.y, in: session.state.npcs) {
            if !shiftHeld { selection.setObject(nil) }
            selection.setNPC(npc.id)
            if previousNpcId == npc.id {
                dragMode = .npc(offsetX: npc.x - world.x, offsetY: npc.y - world.y)
            }
        } else if let object = EditorGeometry.object(at: world.x, worldY: world.y,
                                                     in: session.state.objects) {
            selection.setNPC(nil)
            if shiftHeld {
                if previousObjectIds.contains(object.id) {
                    selection.removeObject(object.id)
                } else {
                    selection.addObject(object.id)
                }
            } else if previousObjectIds.contains(object.id) {
                var origins: [Int: (x: Double, y: Double)] = [:]
                for selected in selection.objects(in: session.state.objects) {
                    origins[selected.id] = (selected.x, selected.y)
                }
                dragMode = .objects(startWorldX: world.x, startWorldY: world.y, origins: origins)
            } else {
                selection.setObject(object.id)
            }
        } else if !shiftHeld {
            selection.setObject(nil)
            selection.setNPC(nil)
        }

        if case .none = dragMode, selection.objectIds.isEmpty, selection.npcId == nil {
            if shiftHeld, backgroundImage != nil {
                dragMode = .tracingImage(offsetX: backgroundOrigin.x - world.x,
                                         offsetY: backgroundOrigin.y - world.y)
            } else {
                dragMode = .panning(lastPoint: point)
            }
        }

        onSelectionChanged?()
        refreshOverlay()
    }

    /// Port of the `mousemove` handler (`admin.js:1114-1193`).
    func editorMouseDragged(to point: CGPoint) {
        switch dragMode {
        case .none:
            return

        case .panning(let lastPoint):
            // `admin.js:1186-1189` moves the camera focus by the cursor delta in world units.
            let zoom = session.state.camera.zoom == 0 ? 1 : session.state.camera.zoom
            session.state.setCameraFocus(x: session.state.player.x + (lastPoint.x - point.x) / zoom,
                                         y: session.state.player.y + (lastPoint.y - point.y) / zoom)
            dragMode = .panning(lastPoint: point)

        case .resizing(let anchorX, let anchorY):
            guard let world = worldPoint(at: point),
                  let object = selectedObject else { return }

            let dx = world.x - anchorX
            let dy = world.y - anchorY
            let angle = -(object.rotation ?? 0) * .pi / 180
            let localX = dx * cos(angle) - dy * sin(angle)
            let localY = dx * sin(angle) + dy * cos(angle)

            let width: Double
            let length: Double
            if object.shape == "circle" {
                // A circle stays a circle: the larger axis drives both.
                let size = max(10, max(localX, localY).rounded())
                width = size
                length = size
            } else {
                width = max(10, localX.rounded())
                length = max(10, localY.rounded())
            }

            session.state.editObject(id: object.id) {
                EditorGeometry.applyResize(to: &$0, width: width, length: length,
                                           anchorX: anchorX, anchorY: anchorY)
            }
            onSelectedEntityChanged?()

        case .objects(let startX, let startY, let origins):
            guard let world = worldPoint(at: point) else { return }
            let dx = world.x - startX
            let dy = world.y - startY
            for (id, origin) in origins {
                session.state.editObject(id: id) {
                    $0.x = (origin.x + dx).rounded()
                    $0.y = (origin.y + dy).rounded()
                }
            }
            onSelectedEntityChanged?()

        case .npc(let offsetX, let offsetY):
            guard let world = worldPoint(at: point), let npc = selectedNPC else { return }
            session.state.editNPC(id: npc.id) {
                $0.x = (world.x + offsetX).rounded()
                $0.y = (world.y + offsetY).rounded()
            }
            onSelectedEntityChanged?()

        case .tracingImage(let offsetX, let offsetY):
            guard let world = worldPoint(at: point) else { return }
            backgroundOrigin = ((world.x + offsetX).rounded(), (world.y + offsetY).rounded())
        }

        refreshOverlay()
    }

    /// Port of the `mouseup` handler (`admin.js:1195-1229`): whatever moved gets committed.
    func editorMouseUp(at point: CGPoint) {
        switch dragMode {
        case .resizing:
            if let object = selectedObject {
                session.send(.resizeObject(id: object.id,
                                           width: object.width ?? 0,
                                           length: object.length ?? 0,
                                           x: object.x, y: object.y))
            }

        case .objects:
            for object in selection.objects(in: session.state.objects) {
                session.send(.moveObject(id: object.id, x: object.x, y: object.y))
            }

        case .npc:
            if let npc = selectedNPC {
                session.send(.moveNPC(id: npc.id, x: npc.x, y: npc.y))
            }

        case .none, .panning, .tracingImage:
            break
        }

        dragMode = .none
    }

    func editorMouseMoved(to point: CGPoint) {
        guard let world = worldPoint(at: point) else { return }
        onCursorMoved?(world.x, world.y)
    }

    /// `admin.js` zooms only on ⌃-scroll and has no pan gesture at all — it pans by dragging
    /// the map. Both are kept, and plain scrolling pans as well, because a trackpad Mac app
    /// that ignores two-finger scroll feels broken.
    func editorScroll(deltaX: CGFloat, deltaY: CGFloat, zooming: Bool) {
        if zooming {
            applyZoom(delta: -Double(deltaY) * 0.01)
            return
        }
        let zoom = session.state.camera.zoom == 0 ? 1 : session.state.camera.zoom
        session.state.setCameraFocus(x: session.state.player.x - Double(deltaX) / zoom,
                                     y: session.state.player.y - Double(deltaY) / zoom)
        refreshOverlay()
    }

    func editorMagnify(by factor: CGFloat) {
        applyZoom(delta: Double(factor))
    }

    private func applyZoom(delta: Double) {
        // Same clamp as `admin.js:1236`.
        session.state.camera.zoom = min(max(0.1, session.state.camera.zoom + delta), 5)
        refreshOverlay()
    }

    func editorDropImage(_ image: NSImage, at point: CGPoint) {
        backgroundImage = image
        backgroundOrigin = worldPoint(at: point) ?? (0, 0)
        refreshOverlay()
    }

    func editorDeleteSelection() {
        if let object = selectedObject {
            confirmDelete(name: object.name ?? "\(object.id)") { [weak self] in
                self?.session.send(.deleteObject(id: object.id))
                self?.select(objectId: nil)
            }
        } else if let npc = selectedNPC {
            confirmDelete(name: npc.name ?? "\(npc.id)") { [weak self] in
                self?.session.send(.deleteNPC(id: npc.id))
                self?.select(npcId: nil)
            }
        }
    }

    func confirmDelete(name: String, then delete: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Delete \(name)?"
        alert.informativeText = "This rewrites the map's JSON on the server and cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { delete() }
    }

    func editorCopySelection() {
        if let object = selectedObject {
            clipboard = .object(object)
        } else if let npc = selectedNPC {
            clipboard = .npc(npc)
        }
    }

    /// `admin.js:1280-1307` pastes at the cursor, sending the whole record as `cloneData` so
    /// the server copies every authored field onto a fresh id.
    func editorPaste(at point: CGPoint) {
        guard let clipboard, let world = worldPoint(at: point) else { return }
        let x = world.x.rounded()
        let y = world.y.rounded()

        switch clipboard {
        case .object(let object):
            session.send(.cloneObject(x: x, y: y, source: object))
        case .npc(let npc):
            session.send(.cloneNPC(x: x, y: y, source: npc))
        }
    }
}

private extension EditorSelection {
    /// Drops ids that the server's replacement arrays no longer contain — a delete elsewhere,
    /// or a map change, must not leave the inspectors pointed at a ghost.
    init(keeping previous: EditorSelection, in state: GameState) {
        self.init()
        for id in previous.objectIds where state.objects.contains(where: { $0.id == id }) {
            addObject(id)
        }
        if let npcId = previous.npcId, state.npcs.contains(where: { $0.id == npcId }) {
            setNPC(npcId)
        }
    }
}
