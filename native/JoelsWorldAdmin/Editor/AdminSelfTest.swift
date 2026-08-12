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

    /// The bytes of the two entity files before anything was edited. Every step that changes
    /// something is expected to put them back, so the run leaves the checkout clean —
    /// `testFilesRestored` is what checks it.
    private var baselines: [String: Data] = [:]

    func run() {
        schedule(1.0) { self.reportInitialState() }
        schedule(1.1) { self.testOverlaySwitch() }
        schedule(1.2) { self.testGameUIIsClickable() }
        schedule(1.3) { self.testChatFeedAlignment() }
        schedule(1.5) { self.testObjectSelectAndDrag() }
        schedule(3.0) { self.testObjectResize() }
        schedule(4.5) { self.testNPCSelectAndDrag() }
        schedule(6.0) { self.testEventTreeRead() }
        schedule(6.5) { self.testCreateEditDelete() }
        schedule(9.0) { self.testKeyboardTurn() }
        schedule(10.5) { self.testKeyboardWalk() }
        schedule(11.7) { self.testCameraOrbitDrag() }
        schedule(12.0) { self.testWaypointRoute() }
        schedule(12.5) { self.testRotationField() }
        schedule(13.5) { self.testEventResaveIsClean() }
        schedule(14.0) { self.testEventCommitByID() }
        schedule(17.5) { self.testFreezeNPCs() }
        schedule(18.5) { self.testCameraViewSave() }
        schedule(25.0) { self.testFilesRestored() }
        // After the byte-identity check, because it leaves the editor on a different map for
        // three seconds and the baselines were taken against this one.
        schedule(26.0) { self.testMapPicker() }
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

        guard let directory = session.files.dataDirectory else {
            return log("FAIL: no data/ directory — pass -data <path>; every edit step will fail")
        }
        log("editing \(directory.path)")

        baselines = [:]
        for path in entityFilePaths() {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(path)) {
                baselines[path] = data
            } else {
                log("FAIL: could not read \(path) to take a baseline")
            }
        }
        log("baselined \(baselines.count) files (\(baselines.values.map(\.count).reduce(0, +)) bytes)")
    }

    /// View ▸ Show Overlays (⌘O), driven the way the menu drives it.
    ///
    /// The menu item has no target and relies on the responder chain finding an object that
    /// answers `toggleEditorOverlays:`. When nothing does, AppKit simply greys the item out —
    /// there is no error, no log line, and the shortcut goes quiet. So the lookup is asked for
    /// explicitly, and then the switch is worked through whatever it found.
    private func testOverlaySwitch() {
        let action = #selector(AdminMapViewController.toggleEditorOverlays(_:))
        let item = NSMenuItem(title: "Show Overlays", action: action, keyEquivalent: "o")
        guard let target = NSApp.target(forAction: action, to: nil, from: item) as? NSObject else {
            return log("overlay switch: FAIL: nothing in the responder chain answers \(action) — " +
                       "the menu item is greyed out")
        }

        let before = map.showsOverlays
        target.perform(action, with: item)
        let flipped = map.showsOverlays
        target.perform(action, with: item)
        let restored = map.showsOverlays

        log("overlay switch: \(type(of: target)) answers the menu; " +
            "\(before) → \(flipped) → \(restored)" +
            (flipped == !before && restored == before ? "" : "  FAIL: the switch did not toggle"))
    }

    /// The game's UI floats over the map, and the map view used to answer for every point in
    /// itself — so the chat field was drawn, and could never be clicked. There is no way to
    /// send a real click from a script, so this asks the hit test what a click *would* find.
    private func testGameUIIsClickable() {
        let chat = map.chatFieldPoint
        let onChat = map.clickTarget(at: chat)
        // Low and to the left, well clear of the HUD's 400 pt column at the top middle.
        let mapPoint = CGPoint(x: map.view.bounds.midX / 2, y: map.view.bounds.maxY - 60)
        let onMap = map.clickTarget(at: mapPoint)

        log("hit test: chat field at (\(Int(chat.x)), \(Int(chat.y))) → \(onChat.rawValue)" +
            (onChat == .chatField ? "" : "  FAIL: the chat field cannot be clicked") +
            "; map at (\(Int(mapPoint.x)), \(Int(mapPoint.y))) → \(onMap.rawValue)" +
            (onMap == .map ? "" : "  FAIL: the map cannot be clicked"))
    }

    /// Three lines of very different lengths through the feed's own entry point. Every row is
    /// the width of the column, so the sender names line up down the left edge; rows that each
    /// shrank to fit their own text left the feed zig-zagging.
    private func testChatFeedAlignment() {
        session.ui?.addChatMessage(sender: "Admin", message: "Hi")
        session.ui?.addChatMessage(
            sender: "Mr Hardy",
            message: "Hello there! Come to see our marvellous new campus? Ask me anything!")
        session.ui?.addChatMessage(sender: "Frank", message: "I've got more detentions than anyone")
        map.view.layoutSubtreeIfNeeded()

        let widths = map.chatRowWidths.map { Int($0.rounded()) }
        let ragged = Set(widths).count > 1
        log("chat feed: \(widths.count) rows at widths \(widths)" +
            (ragged ? "  FAIL: the rows are not all the same width" : ""))
    }

    /// The sidebar's map picker, through the same call it makes.
    ///
    /// Going *to* Detention is allowed from anywhere; coming back out is what the server
    /// refuses, because it is authored `can_leave: false`. The editor forces both, so the step
    /// that matters is the return leg. `can_leave` is server-side only — the client never sees
    /// it — so the locked map is found by name, and any other map will do if it is renamed.
    private func testMapPicker() {
        guard let origin = session.state.mapData?.id else { return log("map picker: no map loaded") }
        let others = session.maps.filter { $0.id != origin }
        guard let target = others.first(where: { $0.name == "Detention" }) ?? others.first else {
            return log("map picker: the map list has nothing else to switch to")
        }

        log("map picker: leaving map \(origin) for '\(target.name ?? "map \(target.id)")'")
        session.changeMap(target.id)

        schedule(3.0) {
            let arrived = self.session.state.mapData?.id
            self.log("map picker: now on map \(arrived.map(String.init) ?? "none")" +
                     (arrived == target.id ? "" : "  FAIL: the map did not change"))

            self.session.changeMap(origin)
            self.schedule(3.0) {
                let back = self.session.state.mapData?.id
                self.log("map picker: back on map \(back.map(String.init) ?? "none")" +
                         (back == origin ? "" : "  FAIL: could not leave '\(target.name ?? "")' again"))
            }
        }
    }

    /// **The camera view round-trip.** Tip the camera over, zoom in, save, and read `maps.json`
    /// back off the disk to see both numbers land on *this* map's record and no other — the
    /// sidebar's Save view button, minus the click. The file is put back from the baseline
    /// afterwards, so `testFilesRestored` still expects it byte-identical.
    private func testCameraViewSave() {
        guard let directory = session.files.dataDirectory,
              let mapId = session.state.mapData?.id,
              let baseline = baselines["maps.json"]
        else { return log("camera view: skipped, no baseline for maps.json") }

        let startPitch = session.state.camera.pitch
        let startZoom = session.state.camera.zoom
        let startAngle = session.state.mapData?.camera_angle
        let startDefaultZoom = session.state.mapData?.default_zoom
        let degrees = 34.0
        let zoom = 1.25

        session.setCameraPitch(degrees * .pi / 180)
        session.setCameraZoom(zoom)
        let saved = session.saveCameraView()

        let url = directory.appendingPathComponent("maps.json")
        let records = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        let mine = records.first { $0["id"] as? Int == mapId }
        let others = records.filter { $0["id"] as? Int != mapId }
        let writtenAngle = mine?["camera_angle"] as? Double
        let writtenZoom = mine?["default_zoom"] as? Double
        let leaked = others.contains { $0["camera_angle"] as? Double == degrees }

        let angleText: String = writtenAngle == nil ? "nothing" : String(Int(writtenAngle!))
        let zoomText: String = writtenZoom == nil ? "nothing" : String(writtenZoom!)
        let readBack: String = angleText + "°, zoom " + zoomText
        var failures = ""
        if !saved { failures += "  FAIL: the save was refused" }
        if writtenAngle != degrees { failures += "  FAIL: maps.json does not carry the angle" }
        if writtenZoom != zoom { failures += "  FAIL: maps.json does not carry the zoom" }
        if leaked { failures += "  FAIL: the angle landed on another map too" }

        log("camera view: saved \(Int(degrees))°, zoom \(zoom) to map \(mapId); "
            + "read back \(readBack)\(failures)")

        try? baseline.write(to: url, options: .atomic)
        session.state.setMapCameraView(angle: startAngle, zoom: startDefaultZoom)
        session.state.camera.pitch = startPitch
        session.state.camera.zoom = startZoom
    }

    /// Every file the run may write: the current map's two entity files, as `maps.json` names
    /// them, and `maps.json` itself, which the camera-angle step saves into.
    private func entityFilePaths() -> [String] {
        guard let mapId = session.state.mapData?.id, let map = WorldData.map(id: mapId) else {
            return []
        }
        return [map.objects, map.npcs].compactMap { $0 } + ["maps.json"]
    }

    /// The run creates an object, rewrites its event tree, deletes it again, and drags three
    /// things back to where it found them. If the serialiser is faithful, the files on disk
    /// end up byte-for-byte as they started.
    ///
    /// This assertion used to be free: the server did the writing, in Node, with the same
    /// `JSON.stringify` that produced the file in the first place. The editor writes them now,
    /// so key order, number formatting and indentation are all `OrderedJSON`'s to get right —
    /// which makes this the step that matters most in the run.
    private func testFilesRestored() {
        guard let directory = session.files.dataDirectory, !baselines.isEmpty else {
            return log("files restored: skipped, no baseline")
        }

        for (path, baseline) in baselines.sorted(by: { $0.key < $1.key }) {
            guard let now = try? Data(contentsOf: directory.appendingPathComponent(path)) else {
                log("FAIL: \(path) could not be re-read")
                continue
            }
            if now == baseline {
                log("\(path) is byte-identical (\(now.count) bytes)")
            } else {
                log("FAIL: \(path) changed — \(baseline.count) → \(now.count) bytes; " +
                    "first difference at \(Self.firstDifference(baseline, now).map(String.init) ?? "?")")
            }
        }
    }

    private static func firstDifference(_ lhs: Data, _ rhs: Data) -> Int? {
        for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
            return index
        }
        return lhs.count == rhs.count ? nil : min(lhs.count, rhs.count)
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

        // Restored by value, not by dragging back, so a self-test run does not rewrite the map.
        // The inverse screen→world mapping rounds, so a return drag lands within a pixel of the
        // original but not on the same number — enough to rewrite an authored -2095 as -2096 and
        // leave the run with a diff. `testNPCSelectAndDrag` restores the same way.
        session.send(.moveObject(id: target.id, x: target.x, y: target.y))
        let restored = session.state.objects.first { $0.id == target.id }
        log("restored object \(target.id) to (\(restored?.x ?? 0), \(restored?.y ?? 0))")
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
        let originalX = object.x
        let originalY = object.y

        map.editorMouseDown(at: handleScreen, shiftHeld: false)
        map.editorMouseDragged(to: pulled)
        map.editorMouseUp(at: pulled)

        let resized = session.state.objects.first { $0.id == object.id }
        log("resized object \(object.id) from \(Int(originalWidth))×\(Int(originalLength)) " +
            "to \(Int(resized?.width ?? 0))×\(Int(resized?.length ?? 0))")

        // Restore through the same path a typed size takes, but put the centre back by value:
        // `applyResize` back-solves it from the anchor and rounds, which is a pixel away from an
        // authored fraction and would leave the same one-pixel diff a return drag does.
        session.state.editObject(id: object.id) { restored in
            let anchor = EditorGeometry.topLeftAnchor(of: restored)
            EditorGeometry.applyResize(to: &restored, width: originalWidth, length: originalLength,
                                       anchorX: anchor.x, anchorY: anchor.y)
            restored.x = originalX
            restored.y = originalY
        }
        if session.state.objects.contains(where: { $0.id == object.id }) {
            session.send(.resizeObject(id: object.id, width: originalWidth, length: originalLength,
                                       x: originalX, y: originalY))
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

        // Restored by value, not by dragging back. A return drag lands wherever the inverse
        // screen mapping puts it, which is within a pixel but not on the same Double — enough
        // to rewrite an authored coordinate like -935.8839997696498 as -936 and leave the run
        // with a diff. The object steps above already restore this way.
        session.send(.moveNPC(id: npc.id, x: npc.x, y: npc.y))
        let restored = session.state.npcs.first { $0.id == npc.id }
        log("restored NPC \(npc.id) to (\(restored?.x ?? 0), \(restored?.y ?? 0))")
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

    // MARK: - Editor additions (not ports — see PROGRESS.md)

    /// The patrol route the overlay draws. Waypoints are cumulative offsets, so the check that
    /// matters is that the resolved points walk away from the start and come back to it.
    private func testWaypointRoute() {
        // Prefer a route that actually goes somewhere: a rotation-only waypoint resolves to
        // the same point as its predecessor, which is correct but proves nothing.
        let patrols = session.state.npcs.filter { !($0.waypoints ?? []).isEmpty }
        let walks = patrols.first { ($0.waypoints ?? []).contains { ($0.x ?? 0) != 0 || ($0.y ?? 0) != 0 } }
        guard let npc = walks ?? patrols.first else {
            return log("waypoint route: no NPC on this map patrols")
        }

        let visual = session.state.visuals[npc.id]
        let start = (x: visual?.startX ?? npc.x, y: visual?.startY ?? npc.y)
        let route = AdminMapViewController.waypointRoute(for: npc, start: start)
        let points = route.map { "(\(Int($0.x.rounded())), \(Int($0.y.rounded())))" }.joined(separator: " → ")

        let closes = route.count > 1 && route.first! == route.last!
        log("waypoint route for NPC \(npc.id) '\(npc.name ?? "?")': " +
            "\(npc.waypoints?.count ?? 0) authored steps → \(route.count) points \(points)" +
            (closes ? "" : "  FAIL: route does not close back to the start"))
    }

    /// The typed rotation field, which the web panel does not have. Driven through the same
    /// call the field's `onCommit` makes, and restored to the authored value so the file check
    /// at the end of the run still passes.
    private func testRotationField() {
        guard let target = session.state.objects.first(where: {
            $0.shape != "3d_model" && ($0.rotation ?? 0) != 0
        }) else { return log("rotation field: no rotated object on this map") }

        let original = target.rotation ?? 0
        map.select(objectId: target.id)
        map.mutateSelectedObject({ $0.rotation = 137 },
                                 message: { .rotateObject(id: $0.id, rotation: $0.rotation ?? 0) })
        let typed = session.state.objects.first { $0.id == target.id }?.rotation ?? 0
        log("typed rotation on object \(target.id): \(Int(original))° → \(Int(typed))° (expected 137)")

        map.mutateSelectedObject({ $0.rotation = original },
                                 message: { .rotateObject(id: $0.id, rotation: $0.rotation ?? 0) })
        let restored = session.state.objects.first { $0.id == target.id }?.rotation ?? 0
        log("restored object \(target.id) rotation to \(restored)°")
    }

    /// The event editor now commits to the entity it *loaded* rather than to whatever is
    /// selected, which is what makes "save before switching" land on the right record. The
    /// prompt itself is modal and cannot be driven from a script; this drives the mechanism
    /// underneath it — an edit addressed by id while something else is selected.
    /// Pressing Save Events without changing anything must not change the file.
    ///
    /// It used to. The working copy travels through `JSONValue`, whose objects are unordered,
    /// so the editor rebuilt every nested payload with its keys sorted — re-saving an
    /// untouched tree rewrote `{type, map, description}` as `{description, map, type}`. The
    /// file check at the end of this run is what asserts the repair; this step is what makes
    /// it fire.
    private func testEventResaveIsClean() {
        let nested = session.state.objects.first { object in
            (object.on_enter?.arrayValue ?? []).contains { action in
                (action.objectValue?.values.first?.objectValue?.count ?? 0) > 1
            }
        }
        guard let object = nested, let tree = object.on_enter else {
            return log("event re-save: no object carries a multi-field action payload")
        }

        let keys = (tree.arrayValue ?? []).compactMap { $0.objectValue?.keys.sorted().first }
        map.mutateObject(id: object.id, { _ in },
                         message: { .updateObject(id: $0.id, updates: ["on_enter": tree]) })
        log("re-saved object \(object.id)'s unchanged on_enter \(keys) — the file check below is the assertion")
    }

    /// It writes to a throwaway object rather than an authored one on purpose. Overwriting an
    /// authored tree and putting it back cannot be byte-clean: the working copy travels
    /// through `JSONValue`, whose objects are `Dictionary`s, so a restored `show_dialog`
    /// payload comes back alphabetised. `OrderedJSON.reordered(like:)` repairs that against
    /// the value being *replaced*, which covers a real edit — but not a round trip that
    /// replaced the tree with something else first.
    private func testEventCommitByID() {
        let existingIds = Set(session.state.objects.map(\.id))
        let point = map.creationPoint
        session.send(.createObject(shape: "rect", x: point.x, y: point.y,
                                   fields: ["name": .string("commit-by-id"),
                                            "width": JSONValue(100), "length": JSONValue(100)]))

        schedule(1.0) {
            guard let subject = self.session.state.objects.first(where: { !existingIds.contains($0.id) }),
                  let other = self.session.state.objects.first(where: {
                      $0.id != subject.id && $0.shape != "3d_model"
                  })
            else { return self.log("commit-by-id: FAIL: no throwaway object to write to") }

            self.map.select(objectId: other.id)
            let tree = JSONValue.array([.object(["say": .array([.string("commit-by-id")])])])
            self.map.mutateObject(id: subject.id, { $0.on_enter = tree },
                                  message: { .updateObject(id: $0.id, updates: ["on_enter": tree]) })

            self.schedule(1.0) {
                let edited = self.session.state.objects
                    .first { $0.id == subject.id }?.on_enter?.arrayValue?.count ?? 0
                self.log("commit-by-id: wrote an event tree to object \(subject.id) while " +
                         "\(other.id) was selected → \(subject.id) has \(edited) action(s)" +
                         (edited == 1 ? "" : "  FAIL: the edit did not land"))

                self.session.send(.deleteObject(id: subject.id))
                self.schedule(1.0) {
                    let gone = !self.session.state.objects.contains { $0.id == subject.id }
                    self.log("commit-by-id: deleted the throwaway object \(subject.id) → gone=\(gone)")
                }
            }
        }
    }

    /// Freeze NPCs, and check that nothing on the roster moves while it is on.
    ///
    /// This only touches local simulation state — nothing is written to `data/` — so it runs
    /// after the edit steps without disturbing the byte-identity check.
    private func testFreezeNPCs() {
        let before = positions()
        session.state.setSimulateNPCs(false)

        schedule(2.0) {
            let frozen = self.travelled(from: before)
            self.log(String(format: "freeze on: %d NPC(s) moved %.2fpx over 2.0s%@",
                            frozen.moved, frozen.total,
                            frozen.total < 0.01 ? "" : "  FAIL: something is still simulating"))

            let resumed = self.positions()
            self.session.state.setSimulateNPCs(true)
            self.schedule(3.0) {
                let after = self.travelled(from: resumed)
                self.log(String(format: "freeze off: %d NPC(s) moved %.0fpx over 3.0s%@",
                                after.moved, after.total,
                                after.moved > 0 ? "" : "  (none was due a step — routes wait 1–5s)"))
            }
        }
    }

    private func positions() -> [Int: (x: Double, y: Double)] {
        Dictionary(uniqueKeysWithValues: session.state.npcs.map { ($0.id, ($0.x, $0.y)) })
    }

    private func travelled(from previous: [Int: (x: Double, y: Double)]) -> (moved: Int, total: Double) {
        var moved = 0
        var total = 0.0
        for npc in session.state.npcs {
            guard let was = previous[npc.id] else { continue }
            let distance = ((npc.x - was.x) * (npc.x - was.x) + (npc.y - was.y) * (npc.y - was.y)).squareRoot()
            if distance > 0.01 { moved += 1 }
            total += distance
        }
        return (moved, total)
    }

    // MARK: - Keyboard movement

    /// Hold ← for a beat and check the heading swung the way tank controls say it should.
    /// The frame loop is what turns a held key into motion, so each of these presses, waits
    /// for real frames to run, and releases.
    private func testKeyboardTurn() {
        let before = session.state.player.rotation
        guard press(123) else { return log("could not synthesise a key event") }
        schedule(1.0) {
            let stillHeld = self.map.keyboard.inputState().turn
            self.release(123)
            let after = self.session.state.player.rotation
            let delta = after - before
            self.log("held ← 1.0s: rotation \(Int(before.rounded()))° → \(Int(after.rounded()))° " +
                     "(Δ\(Int(delta.rounded()))°, expected negative)\(Self.focusNote(stillHeld))")
        }
    }

    /// ⌃-drag orbits the camera instead of selecting or panning: right swings the yaw round,
    /// down tips the pitch towards the horizon, and neither the selection nor the focus point
    /// may move while it happens.
    private func testCameraOrbitDrag() {
        let startPitch = session.state.camera.pitch
        let startYaw = session.state.camera.yaw
        let startSelection = map.selection.objectIds
        let focusX = session.state.player.x

        // Deliberately started on an object: ⌃ has to win over the hit test.
        let origin = map.selectedObject
            .flatMap { screenPoint(worldX: $0.x, worldY: $0.y, z: $0.z ?? 0) }
            ?? CGPoint(x: map.view.bounds.midX, y: map.view.bounds.midY)
        let dragged = CGPoint(x: origin.x + 120, y: origin.y + 60)

        map.editorMouseDown(at: origin, shiftHeld: false, controlHeld: true)
        map.editorMouseDragged(to: dragged)
        map.editorMouseUp(at: dragged)

        let pitch = session.state.camera.pitch
        let yaw = session.state.camera.yaw
        log("⌃-dragged (+120, +60): pitch \(Int((startPitch * 180 / .pi).rounded()))° → " +
            "\(Int((pitch * 180 / .pi).rounded()))°, yaw \(Int((startYaw * 180 / .pi).rounded()))° → " +
            "\(Int((yaw * 180 / .pi).rounded()))°" +
            (pitch > startPitch && yaw > startYaw ? "" : "  FAIL: the camera did not orbit") +
            (map.selection.objectIds == startSelection ? "" : "  FAIL: the orbit changed the selection") +
            (abs(session.state.player.x - focusX) < 0.5 ? "" : "  FAIL: the orbit panned the camera"))

        session.state.camera.pitch = startPitch
        session.state.camera.yaw = startYaw
    }

    /// A background window drops its keys on purpose (`resignFirstResponder` /
    /// `didResignKey`), which shows up here as a step that did nothing. Say so, rather than
    /// leaving a Δ0 that reads like a broken key handler.
    private static func focusNote(_ stillHeld: Double) -> String {
        stillHeld == 0 ? "  ← key released early: the window was not frontmost" : ""
    }

    /// Hold ↑ and check the camera focus actually walked. Distance is left unasserted: the
    /// editor's avatar walks the real clip mask, so a spawn point facing a wall legitimately
    /// moves nothing — the log says which happened.
    private func testKeyboardWalk() {
        let startX = session.state.player.x
        let startY = session.state.player.y
        let heading = session.state.player.rotation
        guard press(126) else { return log("could not synthesise a key event") }
        schedule(1.0) {
            let stillHeld = self.map.keyboard.inputState().forward
            self.release(126)
            let dx = self.session.state.player.x - startX
            let dy = self.session.state.player.y - startY
            let moved = (dx * dx + dy * dy).squareRoot()
            self.log("held ↑ 1.0s on heading \(Int(heading.rounded()))°: moved \(Int(moved.rounded()))px " +
                     "to (\(Int(self.session.state.player.x)), \(Int(self.session.state.player.y)))" +
                     Self.focusNote(stillHeld))
            // Never leave a key stuck down for whatever runs after this.
            self.map.keyboard.releaseAll()
        }
    }

    /// Builds the event AppKit would have delivered and hands it to the real handler. There is
    /// no way to inject a keystroke into a Mac app from a script without an Accessibility
    /// grant, which is the same reason `-walktest` fakes joystick input on iOS.
    private func press(_ keyCode: UInt16) -> Bool {
        guard let event = keyEvent(keyCode, down: true) else { return false }
        return map.keyboard.keyDown(event)
    }

    @discardableResult
    private func release(_ keyCode: UInt16) -> Bool {
        guard let event = keyEvent(keyCode, down: false) else { return false }
        return map.keyboard.keyUp(event)
    }

    private func keyEvent(_ keyCode: UInt16, down: Bool) -> NSEvent? {
        NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
                         location: .zero,
                         modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: map.view.window?.windowNumber ?? 0,
                         context: nil,
                         characters: "",
                         charactersIgnoringModifiers: "",
                         isARepeat: false,
                         keyCode: keyCode)
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
