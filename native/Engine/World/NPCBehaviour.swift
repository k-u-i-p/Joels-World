import Foundation

/// Port of `updateLocalNPCs` (`characters.js:1315-1406`).
///
/// NPC movement is **entirely client-side**: the server ships the roster once and never sends
/// positions for it (`network.js:189-215` deliberately drops position fields for NPC ids), so
/// every client runs this simulation independently and NPCs are not in sync between players.
/// That is the existing behaviour, not an omission.
///
/// This only ever sets interpolation *targets*; `PhysicsEngine.processInterpolation` does the
/// actual moving, which means roaming NPCs walk through walls exactly as they do on the web.
enum NPCBehaviour {
    private static let degToRad = 0.017453292519943295

    /// Advances every NPC's roam or patrol timer by `dt` seconds.
    ///
    /// Roaming used to draw from `Double.random`, which meant the school arranged itself
    /// differently on every run and differently again on every player's screen. Each NPC now
    /// has its own stream seeded from its id (`CharacterVisual.roamNoise`), so a given NPC walks
    /// the same route every time and a misbehaving one can be watched twice.
    static func update(npcs: [GameCharacter],
                       visuals: inout [Int: CharacterVisual],
                       dt: Double) {
        for npc in npcs {
            var visual = visuals[npc.id] ?? CharacterVisual()

            if let roamRadius = npc.roam_radius {
                roam(npc: npc, radius: roamRadius, visual: &visual, dt: dt)
            } else if let waypoints = npc.waypoints, !waypoints.isEmpty {
                patrol(npc: npc, waypoints: waypoints, visual: &visual, dt: dt)
            }

            visuals[npc.id] = visual
        }
    }

    /// Wander inside a circle centred on where the NPC was first seen.
    ///
    /// The cycle is deliberately two-stage: on the first expiry it only *turns* to face the
    /// destination and waits half a second, and on the next it commits to walking there. That
    /// is what stops NPCs from sliding sideways towards a target they have not turned to yet.
    private static func roam(npc: GameCharacter,
                             radius: Double,
                             visual: inout CharacterVisual,
                             dt: Double) {
        func random() -> Double { visual.roamNoise(seed: npc.id) }

        if visual.waitTimer == nil {
            visual.startX = npc.x
            visual.startY = npc.y
            visual.startRotation = npc.rotation ?? 0
            visual.waitTimer = 1.0 + random() * 3.0
        }

        if let timer = visual.waitTimer, timer > 0 {
            visual.waitTimer = timer - dt
        }

        guard let timer = visual.waitTimer, timer <= 0 else { return }

        if let pendingX = visual.pendingRoamX, let pendingY = visual.pendingRoamY {
            visual.targetX = pendingX
            visual.targetY = pendingY
            visual.pendingRoamX = nil
            visual.pendingRoamY = nil
            visual.waitTimer = 2.0 + random() * 3.0
        } else {
            let angle = random() * 2 * .pi
            let distance = random() * radius
            let destX = (visual.startX ?? 0) + cos(angle) * distance
            let destY = (visual.startY ?? 0) + sin(angle) * distance

            let dx = destX - npc.x
            let dy = destY - npc.y
            var destRotation = atan2(dy, dx) / degToRad
            destRotation = (destRotation + 360).truncatingRemainder(dividingBy: 360)

            visual.targetRotation = destRotation.rounded()
            visual.pendingRoamX = destX
            visual.pendingRoamY = destY
            visual.waitTimer = 0.5
        }
    }

    /// Walk a fixed route. Waypoints are *cumulative offsets* from the start pose, and the
    /// cycle runs two steps longer than the list: `waypoints.count + 1` returns to the start
    /// position, and index 0 undoes the accumulated rotation.
    private static func patrol(npc: GameCharacter,
                               waypoints: [Waypoint],
                               visual: inout CharacterVisual,
                               dt: Double) {
        if visual.waitTimer == nil {
            visual.startX = npc.x
            visual.startY = npc.y
            visual.startRotation = npc.rotation ?? 0
            visual.moveIndex = 0
            visual.waitTimer = 0
        }

        if let timer = visual.waitTimer, timer > 0 {
            visual.waitTimer = timer - dt
        }

        guard let timer = visual.waitTimer, timer <= 0 else { return }

        visual.moveIndex = (visual.moveIndex + 1) % (waypoints.count + 2)

        var offsetX: Double = 0
        var offsetY: Double = 0
        var offsetRotation: Double = 0
        var nodeWaitMilliseconds = npc.move_time ?? 3000

        if visual.moveIndex > 0 && visual.moveIndex <= waypoints.count {
            let step = waypoints[visual.moveIndex - 1]
            offsetX = step.x ?? 0
            offsetY = step.y ?? 0
            offsetRotation = step.rotation ?? 0
            if let stepWait = step.move_time { nodeWaitMilliseconds = stepWait }
        } else if visual.moveIndex == waypoints.count + 1 {
            // Retrace the whole route back to the starting position.
            offsetX = -visual.currentOffsetX
            offsetY = -visual.currentOffsetY
        }
        // moveIndex == 0 unwinds the rotation, handled by the reset below.

        visual.currentOffsetX += offsetX
        visual.currentOffsetY += offsetY
        visual.currentOffsetRotation += offsetRotation

        if visual.moveIndex == 0 {
            visual.currentOffsetX = 0
            visual.currentOffsetY = 0
            visual.currentOffsetRotation = 0
        }

        visual.targetX = (visual.startX ?? 0) + visual.currentOffsetX
        visual.targetY = (visual.startY ?? 0) + visual.currentOffsetY
        visual.targetRotation = (visual.startRotation ?? 0) + visual.currentOffsetRotation

        visual.waitTimer = nodeWaitMilliseconds / 1000
    }
}
