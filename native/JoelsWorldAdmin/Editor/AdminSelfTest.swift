import AppKit
import simd

/// `-selftest` — drives selection, dragging, resizing and creation through the *real* mouse
/// handlers and logs what happened at each step.
///
/// The iOS port has `-walktest`, `-uidemo` and `-tennisdemo` for the same reason: there is no
/// way to inject a click from a script, so every interactive path needs a driver that calls
/// the handler a click would have called. Each step here goes through `editorMouseDown` /
/// `editorMouseDragged` / `editorMouseUp`, so a regression in hit testing or in the
/// screen↔world mapping shows up as a failed step rather than a silently different pixel.
final class AdminSelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-selftest")
    }

    private unowned let map: AdminMapViewController
    private unowned let session: AdminSession
    private var step = 0

    init(map: AdminMapViewController, session: AdminSession) {
        self.map = map
        self.session = session
    }

    func run() {
        schedule(1.0) { self.reportInitialState() }
        schedule(1.5) { self.testObjectSelectAndDrag() }
        schedule(3.0) { self.testObjectResize() }
        schedule(4.5) { self.testNPCSelectAndDrag() }
        schedule(6.0) { self.testEventTreeRead() }
        schedule(6.5) { self.testCreateEditDelete() }
    }

    private func schedule(_ delay: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
    }

    private func log(_ message: String) {
        step += 1
        Log.world("selftest \(step): \(message)")
    }

    // MARK: - Steps

    private func reportInitialState() {
        log("world objects=\(session.state.objects.count) npcs=\(session.state.npcs.count) " +
            "selectedObject=\(map.selection.objectIds) selectedNpc=\(String(describing: map.selection.npcId))")
    }

    /// Click an object at its own centre, then click again and drag it 60 world units right.
    private func testObjectSelectAndDrag() {
        guard let target = session.state.objects.first(where: { $0.shape != "3d_model" }),
              let screen = screenPoint(worldX: target.x, worldY: target.y, z: target.z ?? 0)
        else { return log("no object to drag") }

        map.editorMouseDown(at: screen, shiftHeld: false)
        map.editorMouseUp(at: screen)
        let selected = map.selection.objectIds
        log("clicked object \(target.id) at world (\(Int(target.x)), \(Int(target.y))) → selection \(selected)")
        guard selected == [target.id] else { return log("FAIL: hit test picked \(selected)") }

        guard let destination = screenPoint(worldX: target.x + 60, worldY: target.y, z: target.z ?? 0)
        else { return }

        map.editorMouseDown(at: screen, shiftHeld: false)
        map.editorMouseDragged(to: destination)
        map.editorMouseUp(at: destination)

        let moved = session.state.objects.first { $0.id == target.id }
        let dx = (moved?.x ?? 0) - target.x
        log("dragged object \(target.id) by dx=\(Int(dx.rounded())) (expected 60) → " +
            "(\(Int(moved?.x ?? 0)), \(Int(moved?.y ?? 0)))")

        // Put it back, so a self-test run does not rewrite the map.
        map.editorMouseDown(at: destination, shiftHeld: false)
        map.editorMouseDragged(to: screen)
        map.editorMouseUp(at: screen)
        let restored = session.state.objects.first { $0.id == target.id }
        log("restored object \(target.id) to (\(Int(restored?.x ?? 0)), \(Int(restored?.y ?? 0)))")
    }

    /// Grab the corner handle of the selected object and drag it out, then back.
    private func testObjectResize() {
        guard let object = map.selectedObject else { return log("no selection to resize") }

        let handle = EditorGeometry.handleOffset(for: object)
        let angle = (object.rotation ?? 0) * .pi / 180
        let handleWorldX = object.x + handle.x * cos(angle) - handle.y * sin(angle)
        let handleWorldY = object.y + handle.x * sin(angle) + handle.y * cos(angle)

        guard let handleScreen = screenPoint(worldX: handleWorldX, worldY: handleWorldY, z: object.z ?? 0),
              let pulled = screenPoint(worldX: handleWorldX + 40, worldY: handleWorldY + 40, z: object.z ?? 0)
        else { return }

        let originalWidth = object.width ?? 0
        let originalLength = object.length ?? 0

        map.editorMouseDown(at: handleScreen, shiftHeld: false)
        map.editorMouseDragged(to: pulled)
        map.editorMouseUp(at: pulled)

        let resized = session.state.objects.first { $0.id == object.id }
        log("resized object \(object.id) from \(Int(originalWidth))×\(Int(originalLength)) " +
            "to \(Int(resized?.width ?? 0))×\(Int(resized?.length ?? 0))")

        // Restore through the same path a typed size takes.
        session.state.editObject(id: object.id) { restored in
            let anchor = EditorGeometry.topLeftAnchor(of: restored)
            EditorGeometry.applyResize(to: &restored, width: originalWidth, length: originalLength,
                                       anchorX: anchor.x, anchorY: anchor.y)
        }
        if let restored = session.state.objects.first(where: { $0.id == object.id }) {
            session.send(.resizeObject(id: restored.id, width: originalWidth, length: originalLength,
                                       x: restored.x, y: restored.y))
            log("restored object \(object.id) to \(Int(originalWidth))×\(Int(originalLength))")
        }
    }

    /// NPCs need two clicks: the first selects, the second starts the drag.
    private func testNPCSelectAndDrag() {
        guard let npc = session.state.npcs.first,
              let screen = screenPoint(worldX: npc.x, worldY: npc.y, z: 0)
        else { return log("no NPC to drag") }

        map.editorMouseDown(at: screen, shiftHeld: false)
        map.editorMouseUp(at: screen)
        log("clicked NPC \(npc.id) '\(npc.name ?? "?")' → selection \(String(describing: map.selection.npcId))")
        guard map.selection.npcId == npc.id else { return log("FAIL: NPC hit test missed") }

        guard let destination = screenPoint(worldX: npc.x + 30, worldY: npc.y, z: 0) else { return }
        map.editorMouseDown(at: screen, shiftHeld: false)
        map.editorMouseDragged(to: destination)
        map.editorMouseUp(at: destination)
        let moved = session.state.npcs.first { $0.id == npc.id }
        log("dragged NPC \(npc.id) by dx=\(Int(((moved?.x ?? 0) - npc.x).rounded())) (expected 30)")

        map.editorMouseDown(at: destination, shiftHeld: false)
        map.editorMouseDragged(to: screen)
        map.editorMouseUp(at: screen)
        log("restored NPC \(npc.id) to (\(Int(session.state.npcs.first { $0.id == npc.id }?.x ?? 0)), " +
            "\(Int(session.state.npcs.first { $0.id == npc.id }?.y ?? 0)))")
    }

    /// Create a rect at the camera focus, select it by clicking, give it an event tree, read
    /// the tree back off the server's reply, and delete it. Exercises the whole round trip
    /// through `server/admin.js` without leaving anything behind or touching authored data.
    private func testCreateEditDelete() {
        // The server hands out `max(id) + 1`, so the new object is whatever id is not already
        // present. Matching on that rather than on the name means a leftover from an
        // interrupted run cannot be mistaken for this run's object.
        let existingIds = Set(session.state.objects.map(\.id))
        let before = session.state.objects.count
        let point = map.creationPoint
        session.send(.createObject(shape: "rect", x: point.x, y: point.y,
                                   fields: ["name": .string("selftest"),
                                            "width": JSONValue(200), "length": JSONValue(200)]))

        schedule(1.0) {
            guard let created = self.session.state.objects.first(where: { !existingIds.contains($0.id) }) else {
                return self.log("FAIL: create produced nothing (count \(before) → \(self.session.state.objects.count))")
            }
            self.log("created object \(created.id) → count \(before) → \(self.session.state.objects.count)")

            // Select it the way a user would, so the inspectors are driven too.
            if let screen = self.screenPoint(worldX: created.x, worldY: created.y, z: 0) {
                self.map.editorMouseDown(at: screen, shiftHeld: false)
                self.map.editorMouseUp(at: screen)
            }
            self.log("selected created object → \(self.map.selection.objectIds), " +
                     "inspector sees id \(String(describing: self.map.selectedObject?.id))")

            // The payload the event editor's Save button builds.
            let tree = JSONValue.array([.object(["say": .array([.string("selftest line one"),
                                                               .string("selftest line two")])]),
                                        .object(["log": .object(["message": .string("selftest log"),
                                                                 "rate_limit": JSONValue(60)])])])
            self.session.send(.updateObject(id: created.id, updates: ["on_enter": tree]))

            self.schedule(1.2) {
                let reloaded = self.session.state.objects.first { $0.id == created.id }
                let actions = reloaded?.on_enter?.arrayValue ?? []
                let types = actions.compactMap { $0.objectValue?.keys.sorted().first }
                let lines = actions.first?.objectValue?["say"]?.stringArray ?? []
                self.log("event tree round-tripped: \(actions.count) actions \(types), say=\(lines)")

                // Bypasses the confirmation sheet, which would block this run.
                self.session.send(.deleteObject(id: created.id))
                self.schedule(1.2) {
                    let stillThere = self.session.state.objects.contains { $0.id == created.id }
                    self.log("deleted object \(created.id) → present=\(stillThere) " +
                             "count=\(self.session.state.objects.count)")
                    self.reselectFirstObject()
                }
            }
        }
    }

    /// Leaves an object selected, so a `-shot` taken after the run photographs the object
    /// inspector rather than the NPC one.
    private func reselectFirstObject() {
        guard let target = session.state.objects.first(where: { $0.shape != "3d_model" }),
              let screen = screenPoint(worldX: target.x, worldY: target.y, z: target.z ?? 0)
        else { return }
        map.editorMouseDown(at: screen, shiftHeld: false)
        map.editorMouseUp(at: screen)
        log("left object \(target.id) selected for inspection")
    }

    /// The event editor reads `on_enter` / `on_exit` off whatever is selected; this confirms
    /// the trees survive the round trip through `JSONValue` rather than arriving empty.
    private func testEventTreeRead() {
        let withEvents = session.state.npcs.first { $0.on_enter?.hasRunnableActions == true }
        guard let npc = withEvents else { return log("no NPC carries an on_enter tree") }
        let enterCount = npc.on_enter?.arrayValue?.count ?? 0
        let exitCount = npc.on_exit?.arrayValue?.count ?? 0
        let types = (npc.on_enter?.arrayValue ?? []).compactMap { $0.objectValue?.keys.sorted().first }
        log("NPC \(npc.id) '\(npc.name ?? "?")' on_enter=\(enterCount) actions \(types), on_exit=\(exitCount)")
    }

    // MARK: - Helpers

    /// World → view coordinates, the inverse of the editor's `screenToWorld`.
    private func screenPoint(worldX: Double, worldY: Double, z: Double) -> CGPoint? {
        let bounds = map.view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let viewport = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        let projected = session.state.camera.project(worldX: worldX, worldY: worldY, z: z,
                                                     viewport: viewport)
        return CGPoint(x: CGFloat(projected.screen.x), y: CGFloat(projected.screen.y))
    }
}
