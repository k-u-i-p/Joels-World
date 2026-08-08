import Foundation
import simd

/// The locally-controlled player. Mirrors the `player` object in `main.js:252`.
struct Player {
    var id: Int = 0
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var rotation: Double = 0
    var width: Double = 40
    var height: Double = 40
    var moveSpeed: Double = 3
    var rotationSpeed: Double = 3
    var name: String?

    var isRunning = false
    var runDirectionStart: TimeInterval?
    var legAnimationTime: Double = 0
    var activeBuilding: Int?
    var emote: EmoteState?
    /// Badges earned, carried on the session record and topped up by `badge_earned`.
    var badges: [String] = []

    /// Last values sent upstream, so sync only fires on change.
    var lastSentX: Double?
    var lastSentY: Double?
    var lastSentRotation: Double?
    var lastSentEmote: EmoteState??

    /// Colours and appearance arrive from the server; retained for Phase 2 rendering.
    var appearance: GameCharacter?
}

/// Everything the simulation needs from outside itself: the socket, and the UI and audio
/// layers.
protocol GameStateDelegate: AnyObject {
    func gameStateSyncPlayer(_ character: GameCharacter)
    func gameStateSendLog(message: String, npcId: Int)

    func gameStateShowDialog(_ request: DialogRequest)
    func gameStateHideDialog()
    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String)
    func gameStateHideAvatar()
    /// Walking out of an NPC's radius: its portrait animates away and any dialog it raised
    /// closes. Port of `cleanupNpcUI` (`ui.js:22`).
    func gameStateCleanupNPCUI(sourceId: Int)
    func gameStateDidSay(sourceId: Int, name: String?, message: String)
    func gameStatePlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool)
    func gameStateStopSound(sourceId: Int)
    func gameStateStopBackgroundSound()
    /// The footstep loop, re-rated when the player breaks into a run (`main.js:453-466`).
    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool)
    /// `clearEmoteAudio` — the emote's own sound fades out when the emote ends.
    func gameStateClearEmoteAudio()

    /// A pooled one-shot with a playback rate — the minigames' racket hits.
    func gameStatePlayEffect(path: String, volume: Double, rate: Double)
    func gameStateChangeMap(_ mapId: Int)
    func gameStateAwardBadge(_ badge: String)

    /// The map turned out to be a minigame: hand the screen over to it.
    func gameStateDidStartMinigame(_ minigame: Minigame)
    func gameStateDidEndMinigame()
}

extension GameStateDelegate {
    func gameStateShowDialog(_ request: DialogRequest) {}
    func gameStateHideDialog() {}
    func gameStateShowAvatar(sourceId: Int, name: String?, imagePath: String) {}
    func gameStateHideAvatar() {}
    func gameStateCleanupNPCUI(sourceId: Int) {}
    func gameStateDidSay(sourceId: Int, name: String?, message: String) {}
    func gameStatePlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool) {}
    func gameStateStopSound(sourceId: Int) {}
    func gameStateStopBackgroundSound() {}
    func gameStateSetWalkingAudio(active: Bool, isRunning: Bool) {}
    func gameStateClearEmoteAudio() {}
    func gameStatePlayEffect(path: String, volume: Double, rate: Double) {}
    func gameStateChangeMap(_ mapId: Int) {}
    func gameStateAwardBadge(_ badge: String) {}
    func gameStateDidStartMinigame(_ minigame: Minigame) {}
    func gameStateDidEndMinigame() {}
}

/// Owns all mutable game state and drives one simulation step per frame.
/// Port of `update()` in `main.js:306-531`.
final class GameState {
    private(set) var player = Player()
    private(set) var mapData: MapData?
    private(set) var objects: [WorldObject] = []
    private(set) var npcs: [GameCharacter] = []
    private(set) var characters: [GameCharacter] = []

    /// Per-character interpolation and animation state, keyed by character id.
    private(set) var visuals: [Int: CharacterVisual] = [:]

    var camera = Camera()
    let physics = PhysicsEngine()
    let map = MapManager()
    let events = EventInterpreter()

    /// The game that has taken over the frame, when the map is a minigame map.
    private(set) var minigame: Minigame?

    /// Whether NPCs run their roam and waypoint routines. Always on in the game; the editor
    /// turns it off so an NPC cannot wander out from under the cursor mid-drag. See
    /// `setSimulateNPCs(_:)`, which is what actually brings them to a stop.
    private(set) var simulateNPCs = true

    /// Freezes or resumes NPC movement.
    ///
    /// Skipping `NPCBehaviour` alone is not enough: an NPC part-way to a target keeps easing
    /// towards it, so freezing also parks every target on the NPC's current pose. Resuming
    /// costs nothing — each one picks its route back up from the timer it was holding, and a
    /// roamer still wanders around its authored origin because `startX`/`startY` are untouched.
    func setSimulateNPCs(_ enabled: Bool) {
        guard enabled != simulateNPCs else { return }
        simulateNPCs = enabled
        guard !enabled else { return }

        for npc in npcs {
            guard var visual = visuals[npc.id] else { continue }
            visual.targetX = npc.x
            visual.targetY = npc.y
            visual.targetRotation = npc.rotation
            visuals[npc.id] = visual
        }
    }

    /// True while a minigame is drawing itself instead of the Metal renderer, so the renderer
    /// can stop drawing a world that is not there.
    var suppressesWorldRendering: Bool {
        guard let minigame else { return false }
        return !minigame.usesWorldRenderer
    }

    /// True once an `init` payload has been applied.
    private(set) var hasWorld = false
    /// Raised for one frame when a new map is applied, so the renderer can drop tiles.
    private(set) var mapDidChange = false

    private let maxSpring: Double = 150
    private let springSpeed: Double = 0.75

    private var lastSyncTime: TimeInterval = 0

    /// Ids whose `on_enter` has fired and whose `on_exit` is still pending.
    private var activeNpcIds: [Int] = []

    weak var delegate: GameStateDelegate?

    init() {
        events.delegate = self
    }

    // MARK: - World loading

    func apply(initPayload: InitPayload) {
        let previousMapId = mapData?.id
        let isMapChange = hasWorld

        // Everything tied to the outgoing map goes quiet: pending exit events, portrait,
        // door dialog and any object audio (`main.js:668-696`).
        // `handleInitData` calls the outgoing minigame's `cleanupMinigame` before anything else
        // (`main.js:670-675`).
        if let minigame {
            minigame.stop()
            self.minigame = nil
            delegate?.gameStateDidEndMinigame()
        }

        for id in activeNpcIds { delegate?.gameStateStopSound(sourceId: id) }
        for object in objects { delegate?.gameStateStopSound(sourceId: object.id) }
        activeNpcIds = []
        events.reset()
        player.activeBuilding = nil
        delegate?.gameStateHideDialog()
        delegate?.gameStateHideAvatar()

        // The server names a map; the app already has it. `objects` and `npcs` come from the
        // same bundled `data/` tree the server reads, so both ends agree without either
        // sending the other a copy.
        let incomingMap = initPayload.mapId.flatMap { WorldData.map(id: $0) }
        if initPayload.mapId != nil, incomingMap == nil {
            Log.world("Server put us on map \(initPayload.mapId!), which is not in the bundled maps.json")
        }

        characters = initPayload.characters ?? []
        npcs = incomingMap.map { WorldData.npcs(mapId: $0.id) } ?? []
        objects = incomingMap.map { WorldData.objects(mapId: $0.id) } ?? []

        visuals.removeAll()
        for character in characters { setTarget(for: character) }
        for npc in npcs { setTarget(for: npc) }

        if let newMap = incomingMap {
            mapData = newMap
            map.load(mapData: newMap)
            camera.zoom = newMap.default_zoom ?? 1
            #if DEBUG
            if let override = WalkTest.zoomOverride { camera.zoom = override }
            #endif
            mapDidChange = previousMapId != newMap.id

            physics.clipMask = nil
            if let maskPath = newMap.clip_mask, !maskPath.isEmpty {
                ClipMask.load(path: maskPath, mapW: newMap.width, mapH: newMap.height) { [weak self] mask in
                    DispatchQueue.main.async { self?.physics.clipMask = mask }
                }
            }
        }

        if let mine = initPayload.myCharacter {
            player.id = mine.id
            player.x = mine.x
            player.y = mine.y
            player.z = mine.z ?? 0
            player.rotation = mine.rotation ?? 0
            player.width = mine.width ?? 40
            player.height = mine.height ?? 40
            player.name = mine.name
            player.emote = mine.emote
            player.badges = mine.badges ?? player.badges
            player.appearance = mine
            #if DEBUG
            if let at = WalkTest.positionOverride {
                player.x = at.x
                player.y = at.y
            }
            #endif
        }

        hasWorld = true
        Log.world("World applied: map '\(mapData?.name ?? "?")', \(characters.count) players, \(npcs.count) NPCs, \(objects.count) objects")

        // A minigame map has no world of its own: the JS clears the game loop and hands every
        // frame to the imported module instead (`main.js:721-734`).
        if let mapData, let importPath = mapData.import {
            startMinigame(importPath: importPath, mapName: mapData.name)
        }

        // A map's own `on_enter` runs on arrival — it is what starts the background music.
        // Arriving somewhere with no tree silences whatever the last map was playing
        // (`main.js:820-827`).
        if let mapData {
            if let onEnter = mapData.on_enter, onEnter.hasRunnableActions, mapData.import == nil {
                events.process(source: .map(mapData),
                               actions: onEnter,
                               event: .onEnter,
                               objects: objects,
                               player: player)
            } else if isMapChange {
                delegate?.gameStateStopBackgroundSound()
            }
        }
    }

    private func startMinigame(importPath: String, mapName: String?) {
        guard let kind = MinigameKind(importPath: importPath) else {
            Log.world("Map '\(mapName ?? "?")' imports '\(importPath)', which is not a known minigame")
            return
        }

        switch kind {
        case .tennis:
            let game = TennisGame(host: self, npcs: npcs, myCharacter: player.appearance)
            minigame = game
            game.start()
            delegate?.gameStateDidStartMinigame(game)
        }
    }

    /// A badge the server says the player has earned.
    func addBadge(_ badge: String) {
        guard !player.badges.contains(badge) else { return }
        player.badges.append(badge)
    }

    func clearMapChangedFlag() {
        mapDidChange = false
    }

    /// Server positions become interpolation *targets*; the rendered character eases towards
    /// them in `update`. Port of the tick handler at `network.js:215-240`.
    func applyTick(_ updates: [GameCharacter]) {
        for updated in updates where updated.id != player.id {
            // NPCs are simulated locally (`NPCBehaviour`), so a server frame for one only
            // carries its emote and interaction radius — never its position, or the roam
            // targets would be stomped every tick (`network.js:189-215`).
            if let npcIndex = npcs.firstIndex(where: { $0.id == updated.id }) {
                npcs[npcIndex].emote = updated.emote
                if let radius = updated.interaction_radius {
                    npcs[npcIndex].interaction_radius = radius
                }
                continue
            }

            if let index = characters.firstIndex(where: { $0.id == updated.id }) {
                let previous = characters[index]
                characters[index] = updated
                // Keep the eased position; only the target jumps.
                characters[index].x = previous.x
                characters[index].y = previous.y
                characters[index].z = previous.z
                characters[index].rotation = previous.rotation
            } else {
                characters.append(updated)
            }
            setTarget(for: updated)
        }
    }

    /// Records where a character is heading, without moving it there.
    private func setTarget(for character: GameCharacter) {
        var visual = visuals[character.id] ?? CharacterVisual()
        visual.targetX = character.x
        visual.targetY = character.y
        if character.z != nil { visual.targetZ = character.z }
        visual.targetRotation = character.rotation
        visuals[character.id] = visual
    }

    func removeCharacter(id: Int) {
        characters.removeAll { $0.id == id }
        visuals[id] = nil
    }

    func replaceObjects(_ newObjects: [WorldObject]) {
        objects = newObjects
    }

    /// `npcs_update` — the server re-read `npc.json` (an admin edited it live).
    func replaceNPCs(_ newNPCs: [GameCharacter]) {
        npcs = newNPCs
        for npc in npcs {
            // Clearing the wait timer re-seeds the roam/patrol origin from the NPC's new
            // authored position, which is what the JS gets for free by keeping the timer on
            // the record it just replaced.
            visuals[npc.id]?.waitTimer = nil
            setTarget(for: npc)
        }
    }

    // MARK: - Editing (macOS admin app)

    /// The editor mutates the local record first and tells the server afterwards, exactly as
    /// `admin.js` does — a dragged object has to follow the cursor before the round trip.
    /// The server's `objects_update` / `npcs_update` broadcast then replaces the whole array.
    @discardableResult
    func editObject(id: Int, _ mutate: (inout WorldObject) -> Void) -> WorldObject? {
        guard let index = objects.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&objects[index])
        return objects[index]
    }

    @discardableResult
    func editNPC(id: Int, _ mutate: (inout GameCharacter) -> Void) -> GameCharacter? {
        guard let index = npcs.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&npcs[index])
        // Roaming and patrol origins are seeded from the authored position, so a moved NPC
        // has to re-seed or it walks back to where it used to live.
        visuals[npcs[index].id]?.waitTimer = nil
        setTarget(for: npcs[index])
        return npcs[index]
    }

    /// Where the editor camera looks. The web admin drags `player.x/y` around because the
    /// camera follows the player; the editor has no player to walk, so it moves the focus
    /// directly through the same field.
    func setCameraFocus(x: Double, y: Double) {
        player.x = x
        player.y = y
    }

    // MARK: - Rendering feed

    /// Everything that should be drawn as a character this frame: the local player first,
    /// then remote players, then NPCs — each with the walk phase its rig should use.
    var drawableCharacters: [(character: GameCharacter, legAnimationTime: Double)] {
        // A minigame owns the screen; the overworld roster is not on it.
        if minigame != nil { return [] }

        var out: [(GameCharacter, Double)] = []

        if var mine = player.appearance {
            mine.x = player.x
            mine.y = player.y
            mine.z = player.z
            mine.rotation = player.rotation
            mine.name = player.name
            // The live emote lives on `player`, not on the appearance record the roster
            // arrived with — without this the local player is the one character whose emote
            // never poses the rig.
            mine.emote = player.emote
            out.append((mine, player.legAnimationTime))
        }

        for character in characters where character.id != player.id {
            out.append((character, visuals[character.id]?.legAnimationTime ?? 0))
        }
        for npc in npcs {
            out.append((npc, visuals[npc.id]?.legAnimationTime ?? 0))
        }

        return out
    }

    /// What the nameplate/bubble layer needs about one character. Kept free of UIKit types so
    /// the `World` layer stays renderer- and UI-agnostic.
    struct OverlaySubject {
        var id: Int
        var name: String?
        var hideNameplate: Bool
        var x: Double
        var y: Double
        var z: Double
        var chatMessage: String?
        var chatTime: TimeInterval?
    }

    /// In the same order the JS draws them, which decides which three bubbles win when more
    /// than three characters are talking at once.
    var overlaySubjects: [OverlaySubject] {
        // Nameplates and bubbles are DOM nodes the minigames never create.
        if minigame != nil { return [] }

        var out: [OverlaySubject] = []
        out.reserveCapacity(characters.count + npcs.count + 1)

        func append(_ character: GameCharacter, x: Double, y: Double, z: Double, name: String?) {
            let visual = visuals[character.id]
            out.append(OverlaySubject(id: character.id,
                                      name: name,
                                      hideNameplate: character.hide_nameplate ?? false,
                                      x: x, y: y, z: z,
                                      chatMessage: visual?.chatMessage,
                                      chatTime: visual?.chatTime))
        }

        if let mine = player.appearance {
            append(mine, x: player.x, y: player.y, z: player.z, name: player.name)
        }
        for character in characters where character.id != player.id {
            append(character, x: character.x, y: character.y, z: character.z ?? 0, name: character.name)
        }
        for npc in npcs {
            append(npc, x: npc.x, y: npc.y, z: npc.z ?? 0, name: npc.name)
        }
        return out
    }

    // MARK: - Simulation

    func update(dt: Double, input: InputState, viewport: SIMD2<Float>) {
        // A minigame replaces the whole frame — the JS unregisters `updateLocalNPCs`, `update`
        // and `draw` from the game loop before importing it, so none of what follows runs.
        // Notably nothing is synced upstream either: the minigames pass `null` where the
        // overworld passes `syncPlayerToJSON` (`tag.js:520`, and tennis never draws through
        // `characterManager` at all).
        if let minigame {
            minigame.update(dt: dt)
            return
        }

        let timeScale = dt * 60
        let decay = pow(0.001 * springSpeed, dt)

        // The JS registers `updateLocalNPCs` ahead of `update` in the game loop, so NPC
        // targets for this frame are set before anything interpolates towards them.
        if simulateNPCs {
            NPCBehaviour.update(npcs: npcs, visuals: &visuals, dt: dt)
        }

        // Rotation (tank controls), `main.js:314-321`. The JS gates this on the minimap being
        // shut; there is no minimap on the surface that sends `turn`.
        if input.turn != 0 {
            player.rotation += input.turn * player.rotationSpeed * timeScale
        }

        if input.isMoving {
            // The joystick drives heading directly, matching `input.js:188`.
            player.rotation = input.angleDegrees
        }

        // `getDemandedMovementVector`: a thumbstick takes the whole branch and always drives
        // forward, so the keys only count when there is no stick input.
        let forward = input.isMoving ? 1.0 : input.forward

        var dx: Double = 0
        var dy: Double = 0

        // A jump pins the player in place for its first 800 ms, and is cancelled outright if
        // it would land them inside something (`main.js:340-349`).
        var emoteForcedMove = false
        if let emote = player.emote, emote.name == "jump" {
            emoteForcedMove = EventInterpreter.nowMilliseconds() - emote.startTime < 800
        }

        if forward != 0 && !emoteForcedMove {
            if player.runDirectionStart == nil {
                player.runDirectionStart = Date.timeIntervalSinceReferenceDate
            }
            let heldFor = Date.timeIntervalSinceReferenceDate - (player.runDirectionStart ?? 0)
            player.isRunning = heldFor >= 2.5

            let speed = player.isRunning ? player.moveSpeed * 1.2 : player.moveSpeed
            let scaledSpeed = speed * timeScale * forward
            let angle = player.rotation * .pi / 180
            dx = cos(angle) * scaledSpeed
            dy = sin(angle) * scaledSpeed
        } else {
            player.runDirectionStart = nil
            player.isRunning = false
        }

        var isMoving = false

        if dx != 0 || dy != 0 {
            let result = physics.processMovement(
                entity: (x: player.x, y: player.y, id: player.id),
                dx: dx,
                dy: dy,
                objects: objects,
                mapData: mapData,
                isEmoteForced: false,
                npcs: npcs
            )

            let actualDx = result.newX - player.x
            let actualDy = result.newY - player.y
            let blockedDx = dx - actualDx
            let blockedDy = dy - actualDy

            // Push the camera back when walking into a wall, then let it decay.
            if abs(blockedDx) > 0.01 {
                camera.springX += blockedDx * springSpeed
            } else {
                camera.springX *= decay
            }
            if abs(blockedDy) > 0.01 {
                camera.springY += blockedDy * springSpeed
            } else {
                camera.springY *= decay
            }

            let dist = sqrt(camera.springX * camera.springX + camera.springY * camera.springY)
            if dist > maxSpring {
                camera.springX = (camera.springX / dist) * maxSpring
                camera.springY = (camera.springY / dist) * maxSpring
            }

            isMoving = result.isMoving
            player.x = result.newX
            player.y = result.newY

            applyBuildingTransition(to: result.actuallyInObject)
        }

        if isMoving {
            let legRate = player.isRunning ? 0.26 : 0.2
            player.legAnimationTime += legRate * timeScale
            // A jump zeroes `dx`/`dy` above, so `isMoving` is already false while one is in
            // flight — the JS `clearWalkingAudio()` on that branch has nothing left to do.
            delegate?.gameStateSetWalkingAudio(active: true, isRunning: player.isRunning)
            cancelEmoteIfWalkingOutOfIt()
        } else {
            camera.springX *= decay
            camera.springY *= decay
            player.legAnimationTime = 0
            delegate?.gameStateSetWalkingAudio(active: false, isRunning: false)
        }

        interpolateRemotes(timeScale: timeScale)
        updateEmoteLifecycles()
        updateProximityInteractions()

        camera.update(playerX: player.x,
                      playerY: player.y,
                      viewport: viewport,
                      mapData: mapData)

        syncIfNeeded()
    }

    // MARK: - Triggers

    /// Fires `on_exit` for the trigger zone the player just left and `on_enter` for the one
    /// they just entered. Port of `main.js:422-447`.
    ///
    /// Zones nest — the pool's water sits inside the pool building — and the JS tracks only
    /// the innermost one, so entering a nested zone runs the outer zone's `on_exit`.
    private func applyBuildingTransition(to newObject: WorldObject?) {
        let newBuilding = newObject?.id
        guard player.activeBuilding != newBuilding else { return }

        if let previousId = player.activeBuilding,
           let previous = objects.first(where: { $0.id == previousId }) {
            delegate?.gameStateStopSound(sourceId: previousId)
            if let onExit = previous.on_exit, onExit.hasRunnableActions {
                events.process(source: .object(previous),
                               actions: onExit,
                               event: .onExit,
                               objects: objects,
                               player: player)
            }
        }

        player.activeBuilding = newBuilding

        if let newObject {
            if let onEnter = newObject.on_enter, onEnter.hasRunnableActions {
                events.process(source: .object(newObject),
                               actions: onEnter,
                               event: .onEnter,
                               objects: objects,
                               player: player)
            }
        } else {
            // Walking away from a door dismisses its dialog rather than leaving it up.
            delegate?.gameStateHideDialog()
        }
    }

    /// Retires emotes that have outlived their duration, and gives an idle NPC its resting
    /// pose. Port of `updateCharacter3D:1090-1133`.
    ///
    /// The JS runs this inside the draw call, so an off-screen character's emote does not
    /// expire until it comes back into view. Doing it here covers every character every frame
    /// instead — the only difference is an NPC that finishes an emote while off-screen, which
    /// the JS would have shown mid-pose on its first visible frame.
    private func updateEmoteLifecycles() {
        let now = EventInterpreter.nowMilliseconds()

        /// - Returns: the emote the character should be left with, if it changed.
        func retire(_ character: inout GameCharacter, isNPC: Bool) {
            if isNPC, character.emote == nil, let resting = character.default_emote {
                character.emote = resting
            }

            guard let emote = character.emote,
                  let definition = Emotes.definition(emote.name),
                  // A zero start time is the "hold this pose" convention `default_emote` uses.
                  emote.startTime != 0,
                  now - emote.startTime > definition.duration
            else { return }

            definition.onEnd?(&character)
            character.emote = isNPC ? character.default_emote : nil
        }

        for index in npcs.indices { retire(&npcs[index], isNPC: true) }
        for index in characters.indices where characters[index].id != player.id {
            retire(&characters[index], isNPC: false)
        }

        if let emote = player.emote,
           let definition = Emotes.definition(emote.name),
           emote.startTime != 0,
           now - emote.startTime > definition.duration {
            delegate?.gameStateClearEmoteAudio()
            setPlayerEmote(nil)
        }
    }

    /// Walking cancels an emote, unless the emote is one that survives movement or the zone
    /// the player is standing in is the thing that set it — otherwise the pool would clear
    /// the swim pose on the first stroke (`main.js:466-490`).
    private func cancelEmoteIfWalkingOutOfIt() {
        guard let emote = player.emote else { return }

        if emote.name == "jump" || emote.name == "wet" { return }

        if let buildingId = player.activeBuilding,
           let building = objects.first(where: { $0.id == buildingId }),
           let actions = resolveActions(building.on_enter, event: .onEnter),
           actions.contains(where: { $0["emote"]?.stringValue == emote.name }) {
            return
        }

        delegate?.gameStateClearEmoteAudio()
        setPlayerEmote(nil)
    }

    /// A chat frame from the server. Parks the text on the sender so the bubble renderer
    /// picks it up, and hands back the display name for the chat feed (`network.js:246-268`).
    @discardableResult
    func applyChat(id: Int, message: String) -> String {
        var visual = visuals[id] ?? CharacterVisual()
        visual.chatMessage = message
        visual.chatTime = Date.timeIntervalSinceReferenceDate
        visuals[id] = visual

        if id == player.id { return player.name ?? "User \(id)" }
        return characters.first(where: { $0.id == id })?.name
            ?? npcs.first(where: { $0.id == id })?.name
            ?? "User \(id)"
    }

    /// The local echo of something the player just typed, before the server bounces it back.
    func setLocalChat(_ message: String) {
        var visual = visuals[player.id] ?? CharacterVisual()
        visual.chatMessage = message
        visual.chatTime = Date.timeIntervalSinceReferenceDate
        visuals[player.id] = visual
    }

    /// Resolves an event tree that may be a bare reference to another object's tree.
    private func resolveActions(_ tree: JSONValue?, event: EventKey) -> [JSONValue]? {
        guard let tree else { return nil }
        if case .number(let referencedId) = tree {
            guard let parent = objects.first(where: { $0.id == Int(referencedId) }) else { return nil }
            let parentTree = event == .onEnter ? parent.on_enter : parent.on_exit
            return parentTree?.arrayValue
        }
        return tree.arrayValue
    }

    /// `on_enter` / `on_exit` for NPCs and players the local player walks near.
    private func updateProximityInteractions() {
        // The JS tears the portrait down *after* the whole interaction sweep, so an `on_exit`
        // that raises an avatar still gets cleaned up on the same frame (`main.js:509-516`).
        var exited: [Int] = []

        activeNpcIds = physics.processInteractions(
            player: player,
            characters: characters,
            npcs: npcs,
            activeIds: activeNpcIds,
            onEnter: { [weak self] character in
                guard let self, let onEnter = character.on_enter, onEnter.hasRunnableActions
                else { return }
                self.events.process(source: .character(character),
                                    actions: onEnter,
                                    event: .onEnter,
                                    objects: self.objects,
                                    player: self.player)
            },
            onExit: { [weak self] character in
                guard let self else { return }
                exited.append(character.id)
                self.delegate?.gameStateStopSound(sourceId: character.id)
                guard let onExit = character.on_exit, onExit.hasRunnableActions else { return }
                self.events.process(source: .character(character),
                                    actions: onExit,
                                    event: .onExit,
                                    objects: self.objects,
                                    player: self.player)
            })

        for id in exited { delegate?.gameStateCleanupNPCUI(sourceId: id) }
    }

    /// The chat line an emote broadcasts when the local player triggers it, with the nearest
    /// character resolved as its target (`emotes.js:18-62`). Empty when the emote is silent.
    func emoteMessage(for name: String) -> String? {
        let text = Emotes.message(for: name,
                                  sourceName: player.name,
                                  sourceX: player.x,
                                  sourceY: player.y,
                                  sourceId: player.id,
                                  hasWorld: hasWorld,
                                  characters: characters,
                                  npcs: npcs,
                                  physics: physics)
        // The JS guards on `if (msgText)`, so an empty string posts nothing.
        return (text?.isEmpty ?? true) ? nil : text
    }

    /// Sets the local player's emote and pushes it upstream immediately, the way every
    /// `syncPlayerToJSON()` call after an emote change does in the JS.
    func setPlayerEmote(_ emote: EmoteState?) {
        guard player.emote != emote else { return }
        player.emote = emote
        #if DEBUG
        Log.world("Player emote: \(emote?.name ?? "none")")
        #endif
        syncPlayerNow()
    }

    /// Eases every remote player and NPC towards its server target.
    /// Port of the interpolation sweep at `main.js:500-506`, which skips the local player.
    private func interpolateRemotes(timeScale: Double) {
        for index in characters.indices where characters[index].id != player.id {
            guard var visual = visuals[characters[index].id] else { continue }
            physics.processInterpolation(character: &characters[index],
                                         visual: &visual,
                                         timeScale: timeScale)
            visuals[characters[index].id] = visual
        }

        for index in npcs.indices {
            guard var visual = visuals[npcs[index].id] else { continue }
            physics.processInterpolation(character: &npcs[index],
                                         visual: &visual,
                                         timeScale: timeScale)
            visuals[npcs[index].id] = visual
        }
    }

    /// Sends at most 10 updates a second, and only when something changed.
    private func syncIfNeeded() {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastSyncTime > 0.1 else { return }

        guard player.x != player.lastSentX
                || player.y != player.lastSentY
                || player.rotation != player.lastSentRotation
                || player.lastSentEmote.map({ $0 != player.emote }) ?? true
        else { return }

        lastSyncTime = now
        syncPlayerNow()
    }

    /// Builds the character payload and hands it to the delegate. `NetworkClient` throttles
    /// the wire itself, so calling this off the back of an event is safe.
    private func syncPlayerNow() {
        player.lastSentX = player.x
        player.lastSentY = player.y
        player.lastSentRotation = player.rotation
        player.lastSentEmote = .some(player.emote)

        guard var payload = player.appearance else { return }
        payload.x = player.x
        payload.y = player.y
        payload.z = player.z
        payload.rotation = player.rotation
        payload.name = player.name
        payload.emote = player.emote
        delegate?.gameStateSyncPlayer(payload)
    }
}

// MARK: - Event effects

extension GameState: EventInterpreterDelegate {
    func eventShowAvatar(sourceId: Int, name: String?, imagePath: String) {
        delegate?.gameStateShowAvatar(sourceId: sourceId, name: name, imagePath: imagePath)
    }

    func eventSay(sourceId: Int, message: String) {
        var visual = visuals[sourceId] ?? CharacterVisual()
        visual.chatMessage = message
        visual.chatTime = Date.timeIntervalSinceReferenceDate
        visuals[sourceId] = visual

        let name = npcs.first(where: { $0.id == sourceId })?.name
            ?? characters.first(where: { $0.id == sourceId })?.name
        delegate?.gameStateDidSay(sourceId: sourceId, name: name, message: message)
    }

    func eventShowDialog(_ request: DialogRequest) {
        delegate?.gameStateShowDialog(request)
    }

    func eventPlaySound(sourceId: Int, path: String, volume: Double, isBackground: Bool) {
        delegate?.gameStatePlaySound(sourceId: sourceId,
                                     path: path,
                                     volume: volume,
                                     isBackground: isBackground)
    }

    func eventSetEmote(_ emote: EmoteState?, sourceId: Int, targetsPlayer: Bool) {
        if targetsPlayer {
            setPlayerEmote(emote)
        } else if let index = npcs.firstIndex(where: { $0.id == sourceId }) {
            npcs[index].emote = emote
        } else if let index = characters.firstIndex(where: { $0.id == sourceId }) {
            characters[index].emote = emote
        }
    }

    func eventLog(message: String, npcId: Int) {
        delegate?.gameStateSendLog(message: message, npcId: npcId)
    }
}

// MARK: - Minigame host

extension GameState: MinigameHost {
    func minigameShowDialog(_ text: String, onConfirm: @escaping () -> Void) {
        delegate?.gameStateShowDialog(DialogRequest(text: text,
                                                    confirmAction: nil,
                                                    onConfirm: onConfirm))
    }

    func minigameChangeMap(_ mapId: Int) {
        delegate?.gameStateChangeMap(mapId)
    }

    func minigameAwardBadge(_ badge: String) {
        delegate?.gameStateAwardBadge(badge)
    }

    func minigamePlayBackground(path: String, volume: Double) {
        delegate?.gameStatePlaySound(sourceId: -1, path: path, volume: volume, isBackground: true)
    }

    func minigamePlayEffect(path: String, volume: Double, rate: Double) {
        delegate?.gameStatePlayEffect(path: path, volume: volume, rate: rate)
    }

    func minigameStopBackground() {
        delegate?.gameStateStopBackgroundSound()
    }
}
