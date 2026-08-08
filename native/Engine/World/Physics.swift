import Foundation

/// Result of a movement attempt.
struct MovementResult {
    var newX: Double
    var newY: Double
    var actuallyInObject: WorldObject?
    var isMoving: Bool
    var emoteCanceled: Bool
}

/// Direct port of `server/physics.js`, which the Node server still runs.
///
/// **Kept behaviourally identical to that file — any change here must be mirrored there.**
/// This is the one duplication the native rewrite leaves behind, and it is deliberate: the
/// server needs collision in JavaScript, the clients need it in Swift. See PLAN.md §8.
final class PhysicsEngine {
    var clipMask: ClipMask?

    private static let degToRadD = 0.017453292519943295

    // MARK: - Overlap tests

    /// Rotated-rect / circle overlap with a broad-phase AABB rejection.
    func checkObjectOverlap(_ obj: WorldObject,
                            x: Double,
                            y: Double,
                            radius: Double,
                            clipOverlapAllowed: Double = 0) -> Bool {
        let w = obj.width ?? 0
        let l = obj.length ?? 0
        let maxDimHalf = (w > l ? w : l) * 0.5

        let dx = x - obj.x
        let dy = y - obj.y

        let broadRadius = maxDimHalf * 1.415 + radius
        if dx > broadRadius || dx < -broadRadius || dy > broadRadius || dy < -broadRadius {
            return false
        }

        switch obj.shape {
        case "circle":
            var effectiveR = maxDimHalf - clipOverlapAllowed
            if effectiveR < 0 { effectiveR = 0 }
            effectiveR += radius
            return (dx * dx + dy * dy) <= (effectiveR * effectiveR)

        case "rect", "3d_model":
            var testX: Double
            var testY: Double

            if let rotation = obj.rotation, rotation != 0 {
                let angle = -rotation * Self.degToRadD
                let cosA = cos(angle)
                let sinA = sin(angle)
                testX = dx * cosA - dy * sinA
                testY = dx * sinA + dy * cosA
            } else {
                testX = dx
                testY = dy
            }

            var halfW = w * 0.5 - clipOverlapAllowed
            if halfW < 0 { halfW = 0 }
            var halfL = l * 0.5 - clipOverlapAllowed
            if halfL < 0 { halfL = 0 }

            let closestX = min(max(testX, -halfW), halfW)
            let closestY = min(max(testY, -halfL), halfL)

            let distX = testX - closestX
            let distY = testY - closestY

            return (distX * distX + distY * distY) <= (radius * radius)

        default:
            return false
        }
    }

    func findObjectsAt(_ objects: [WorldObject],
                       coords: [(x: Double, y: Double)],
                       radius: Double = 0) -> [WorldObject] {
        var found: [WorldObject] = []
        for obj in objects {
            for pt in coords where checkObjectOverlap(obj, x: pt.x, y: pt.y, radius: radius) {
                found.append(obj)
                break
            }
        }
        return found
    }

    /// Characters within their own `interaction_radius` of a point (default 150).
    func findCharacters(_ characters: [GameCharacter],
                        x: Double,
                        y: Double,
                        ignoreId: Int?) -> [GameCharacter] {
        var found: [GameCharacter] = []
        for c in characters {
            if let ignoreId, c.id == ignoreId { continue }
            let dx = x - c.x
            let dy = y - c.y
            let distSq = dx * dx + dy * dy
            let r = c.interaction_radius ?? 150
            if distSq <= r * r { found.append(c) }
        }
        return found
    }

    // MARK: - Movement

    /// Map bounds + clip mask + NPC ellipses + object hitboxes.
    func canMoveTo(_ objects: [WorldObject],
                   newX: Double,
                   newY: Double,
                   playerRadius: Double,
                   mapW: Double?,
                   mapH: Double?,
                   npcs: [GameCharacter]?,
                   entityId: Int?,
                   currentX: Double?,
                   currentY: Double?) -> Bool {
        if let mapW, let mapH, mapW > 0, mapH > 0 {
            let halfMapW = mapW * 0.5
            let halfMapH = mapH * 0.5
            if newX - playerRadius < -halfMapW || newX + playerRadius > halfMapW ||
               newY - playerRadius < -halfMapH || newY + playerRadius > halfMapH {
                return false
            }
        }

        if !checkClipMask(x: newX, y: newY) {
            return false
        }

        if let npcs {
            // Entities collide as ellipses — wider across the shoulders than front-to-back.
            for npc in npcs {
                if let entityId, npc.id == entityId { continue }
                let dx = newX - npc.x
                let dy = newY - npc.y

                let angle = -(npc.rotation ?? 0) * Self.degToRadD
                let cosA = cos(angle)
                let sinA = sin(angle)

                let localDx = dx * cosA - dy * sinA
                let localDy = dx * sinA + dy * cosA

                let npcWidthHalf = (npc.width ?? 40) / 2
                let npcHeightHalf = (npc.height ?? 40) / 2

                let rx = (npcHeightHalf * 0.8) + playerRadius
                let ry = (npcWidthHalf * 1.0) + playerRadius

                let chestRadiusSq = rx * rx
                let shoulderRadiusSq = ry * ry

                let newOverlap = (localDx * localDx) / chestRadiusSq
                    + (localDy * localDy) / shoulderRadiusSq

                if newOverlap < 1 {
                    if let currentX, let currentY {
                        let oldDx = currentX - npc.x
                        let oldDy = currentY - npc.y
                        let oldLocalDx = oldDx * cosA - oldDy * sinA
                        let oldLocalDy = oldDx * sinA + oldDy * cosA
                        let oldOverlap = (oldLocalDx * oldLocalDx) / chestRadiusSq
                            + (oldLocalDy * oldLocalDy) / shoulderRadiusSq
                        // Allow escaping if already overlapping and moving outwards.
                        if oldOverlap < 1 && newOverlap >= oldOverlap { continue }
                    }
                    return false
                }
            }
        }

        let testRadius = playerRadius - 0.0001
        for obj in objects {
            if obj.noclip == true { continue }
            let clipOverlapAllowed = obj.clip ?? 10
            if clipOverlapAllowed == -1 { continue }
            if checkObjectOverlap(obj, x: newX, y: newY,
                                  radius: testRadius,
                                  clipOverlapAllowed: clipOverlapAllowed) {
                return false
            }
        }

        return true
    }

    /// Attempts a move, sliding along rotated edges when blocked.
    func processMovement(entity: (x: Double, y: Double, id: Int?),
                         dx: Double,
                         dy: Double,
                         objects: [WorldObject],
                         mapData: MapData?,
                         isEmoteForced: Bool,
                         npcs: [GameCharacter]?) -> MovementResult {
        var result = MovementResult(newX: entity.x,
                                    newY: entity.y,
                                    actuallyInObject: nil,
                                    isMoving: false,
                                    emoteCanceled: false)

        if dx == 0 && dy == 0 { return result }
        result.isMoving = true

        let scale = mapData?.character_scale ?? 1
        let playerRadius = 15 * scale

        let coords: [(x: Double, y: Double)] = [
            (entity.x + dx, entity.y + dy),
            (entity.x + dx, entity.y),
            (entity.x, entity.y + dy),
        ]

        let possibleOverlaps = findObjectsAt(objects, coords: coords, radius: playerRadius)

        let mapW = mapData?.width
        let mapH = mapData?.height

        func canMove(_ tx: Double, _ ty: Double) -> Bool {
            canMoveTo(possibleOverlaps, newX: tx, newY: ty,
                      playerRadius: playerRadius, mapW: mapW, mapH: mapH,
                      npcs: npcs, entityId: entity.id,
                      currentX: entity.x, currentY: entity.y)
        }

        if isEmoteForced {
            if canMove(entity.x + dx, entity.y + dy) {
                result.newX += dx
                result.newY += dy
            } else {
                result.emoteCanceled = true
            }
        } else if canMove(entity.x + dx, entity.y + dy) {
            result.newX += dx
            result.newY += dy
        } else {
            var hitObj: WorldObject?
            for obj in possibleOverlaps {
                if obj.noclip != true, obj.clip != -1,
                   checkObjectOverlap(obj, x: entity.x + dx, y: entity.y + dy,
                                      radius: playerRadius,
                                      clipOverlapAllowed: obj.clip ?? 10) {
                    hitObj = obj
                    break
                }
            }

            if let hitObj,
               hitObj.shape == "rect" || hitObj.shape == "3d_model",
               let rotation = hitObj.rotation, rotation != 0 {
                // Slide along the rotated edge.
                let angle = -rotation * Self.degToRadD
                let cosA = cos(angle)
                let sinA = sin(angle)

                let localDx = dx * cosA - dy * sinA
                let localDy = dx * sinA + dy * cosA

                var slideWorldDx = localDx * cosA
                var slideWorldDy = -localDx * sinA

                if canMove(entity.x + slideWorldDx, entity.y + slideWorldDy) {
                    result.newX += slideWorldDx
                    result.newY += slideWorldDy
                } else {
                    slideWorldDx = localDy * sinA
                    slideWorldDy = localDy * cosA

                    if canMove(entity.x + slideWorldDx, entity.y + slideWorldDy) {
                        result.newX += slideWorldDx
                        result.newY += slideWorldDy
                    } else if canMove(entity.x + dx, entity.y) {
                        result.newX += dx
                    } else if canMove(entity.x, entity.y + dy) {
                        result.newY += dy
                    }
                }
            } else {
                // Axis-aligned sliding.
                if canMove(entity.x + dx, entity.y) {
                    result.newX += dx
                } else if canMove(entity.x, entity.y + dy) {
                    result.newY += dy
                }
            }
        }

        if !possibleOverlaps.isEmpty {
            let matched = findObjectsAt(possibleOverlaps,
                                        coords: [(result.newX, result.newY)],
                                        radius: 0)
            result.actuallyInObject = matched.first
        }

        return result
    }

    // MARK: - Proximity interactions

    /// Runs `on_enter` / `on_exit` for everything the player has just walked into or out of
    /// range of. Port of `processInteractions` (`physics.js:569-609`).
    ///
    /// Returns the new set of in-range ids, which the caller carries to the next frame.
    ///
    /// The JS filters on `c.isNpc || c.on_enter || c.on_exit`; `isNpc` is never set anywhere in
    /// the client, the server or the data, so the filter is just "has an event tree".
    func processInteractions(player: Player,
                             characters: [GameCharacter],
                             npcs: [GameCharacter],
                             activeIds: [Int],
                             onEnter: (GameCharacter) -> Void,
                             onExit: (GameCharacter) -> Void) -> [Int] {
        let inRange = (findCharacters(characters, x: player.x, y: player.y, ignoreId: player.id)
                       + findCharacters(npcs, x: player.x, y: player.y, ignoreId: player.id))
            .filter { ($0.on_enter?.isTruthy ?? false) || ($0.on_exit?.isTruthy ?? false) }

        let inRangeIds = inRange.map(\.id)

        for oldId in activeIds where !inRangeIds.contains(oldId) {
            guard let previous = characters.first(where: { $0.id == oldId })
                    ?? npcs.first(where: { $0.id == oldId })
            else { continue }
            onExit(previous)
        }

        for character in inRange where !activeIds.contains(character.id) {
            onEnter(character)
        }

        return inRangeIds
    }

    // MARK: - Clip mask

    func checkClipMask(x: Double, y: Double) -> Bool {
        clipMask?.isWalkable(worldX: x, worldY: y) ?? true
    }

    // MARK: - Remote interpolation

    /// Eases a remote character towards the position the server last reported.
    /// Port of `processInterpolation` (`physics.js:479-540`).
    ///
    /// The visual's `motion` is advanced here, which is what drives the walk cycle for everyone
    /// but the local player. It used to be a single walk phase, and so could only ever describe
    /// a forward walk; now the frame's actual displacement is differentiated back into a
    /// velocity and `Locomotion.observe` resolves it into the body's own frame. A patrolling NPC
    /// whose waypoint rotation faces down the corridor side-steps across it, which is what it is
    /// really doing.
    func processInterpolation(character: inout GameCharacter,
                              visual: inout CharacterVisual,
                              timeScale: Double,
                              dt: Double) {
        guard let targetX = visual.targetX, let targetY = visual.targetY else {
            // Nothing is driving this one. Let the stride finish its step and settle.
            visual.motor.observe(x: character.x, y: character.y, z: character.z ?? 0,
                                 facing: character.rotation ?? 0, dt: dt)
            return
        }

        let cdx = targetX - character.x
        let cdy = targetY - character.y
        let cdz = (visual.targetZ ?? 0) - (character.z ?? 0)
        let distSq = cdx * cdx + cdy * cdy + cdz * cdz
        var teleported = false

        if distSq > 25_000_000 {
            // Teleported — snap rather than sprinting across the map.
            character.x = targetX
            character.y = targetY
            if let targetZ = visual.targetZ { character.z = targetZ }
            character.rotation = visual.targetRotation
            teleported = true
        } else if distSq > 0.1 {
            let distance = sqrt(distSq)
            let baseSpeed = character.moveSpeed ?? 3

            // Boost when a long way behind so a lagging client catches up seamlessly.
            let catchupMultiplier = distance > 1000 ? 1.5 : 1.0
            var stepDist = baseSpeed * catchupMultiplier * timeScale
            if stepDist > distance { stepDist = distance }

            let ratio = stepDist / distance
            character.x += cdx * ratio
            character.y += cdy * ratio
            if visual.targetZ != nil { character.z = (character.z ?? 0) + cdz * ratio }
        } else {
            character.x = targetX
            character.y = targetY
            if let targetZ = visual.targetZ { character.z = targetZ }
        }

        // Shortest-angle rotation, applied even when standing still.
        if let targetRotation = visual.targetRotation {
            var rotDiff = targetRotation - (character.rotation ?? 0)
            while rotDiff > 180 { rotDiff -= 360 }
            while rotDiff < -180 { rotDiff += 360 }

            if abs(rotDiff) > 1 {
                let rotSpeed = character.rotationSpeed ?? 5
                let rotStep = min(abs(rotDiff), rotSpeed * timeScale)
                character.rotation = (character.rotation ?? 0) + (rotDiff < 0 ? -rotStep : rotStep)
            } else {
                character.rotation = targetRotation
            }
        }

        if teleported {
            // A jump across the map is not a stride. Feeding it in would read as a sprint at a
            // few thousand units a second and throw the torso flat on its face.
            visual.motor.teleport(x: character.x, y: character.y, z: character.z ?? 0,
                                  facing: character.rotation ?? 0)
            return
        }

        // Resolve against the heading the character has *now* — the interpolator has just turned
        // it, and the walk this frame belongs to where the body ended up pointing. The motor
        // remembers where it left the character last frame and differentiates from there, which
        // is why the "nothing is driving this one" branch above still has to call it: a frame
        // that is skipped is a frame the stride never gets to finish.
        visual.motor.observe(x: character.x,
                             y: character.y,
                             z: character.z ?? 0,
                             facing: character.rotation ?? 0,
                             dt: dt)
    }
}

/// Per-character view state, the port of the `characterVisuals` proxy (`characters.js:344`).
/// The server's last-known position is the *target*; the rendered character eases towards it.
struct CharacterVisual {
    var targetX: Double?
    var targetY: Double?
    var targetZ: Double?
    var targetRotation: Double?

    /// **This character's movement.** The same `CharacterMotor` the local player and the tennis
    /// players run on, in its observed mode: the position arrives from somewhere else — the
    /// server for a remote player, `NPCBehaviour` for an NPC — and the motor reads the velocity
    /// and the gait back out of it. `motor.gait` is what poses this character's rig, and its
    /// limbs are there for anything that wants to pose one.
    ///
    /// A class, so a copy of this struct is a copy of the *reference*: there is one motor per
    /// character id and it lives as long as the character does.
    let motor = CharacterMotor(profile: .observed)

    /// The most recent thing this character said, and when — drawn as a chat bubble in
    /// Phase 5. `chatMessage` / `chatTime` on the JS character record.
    var chatMessage: String?
    var chatTime: TimeInterval?

    // MARK: NPC roaming and patrol state (`NPCBehaviour`)

    /// Seconds left before the next roam or waypoint step. `nil` means "not started yet",
    /// which is what re-seeds the start pose — `characters.js` gets the same effect from the
    /// timer living on the NPC record, which `npcs_update` replaces wholesale.
    var waitTimer: Double?
    var startX: Double?
    var startY: Double?
    var startRotation: Double?
    /// Where a roaming NPC has turned to face but not yet started walking to.
    var pendingRoamX: Double?
    var pendingRoamY: Double?
    var moveIndex: Int = 0
    var currentOffsetX: Double = 0
    var currentOffsetY: Double = 0
    var currentOffsetRotation: Double = 0

    /// This NPC's own random stream, seeded from its id the first time it is asked for a
    /// number. `Double.random` draws from the system generator, so the school used to be laid
    /// out differently on every run and on every player's screen at once — and a roaming NPC
    /// that misbehaved could never be watched twice. Seeding per id fixes all three: the same
    /// NPC wanders the same way every time, and every client agrees on it.
    private var roamRandom: DeterministicRandom?

    /// The next number in this NPC's stream, in `[0, 1)`.
    mutating func roamNoise(seed: Int) -> Double {
        if roamRandom == nil {
            roamRandom = DeterministicRandom(seed: UInt64(bitPattern: Int64(seed)))
        }
        return roamRandom!.unit()
    }
}
