import Foundation

/// Getting the two characters, and their rackets, to where the ball is going to be.
///
/// `convergePhysics` is the heart of it: position, jump height and racket aim each ease
/// towards a target by a fixed fraction of a frame, which is what makes a late swing miss —
/// see the note on the one-frame racket lag on `TennisGame` itself.
extension TennisGame {
    // MARK: - Movement

    /// `moveCharacterTo` (`tennis.js:1026-1034`). Returns whether the character still has
    /// meaningful distance to cover.
    @discardableResult
    func moveCharacter(_ side: Side, toX x: Double, y: Double,
                               z: Double = TennisGame.restingZ) -> Bool {
        side.target.x = x
        side.target.y = y
        side.target.z = z
        return abs(x - side.current.x) > 10
            || abs(y - side.current.y) > 10
            || abs(z - side.current.z) > 10
    }

    /// The two-argument form the JS gets from a default parameter.
    @discardableResult
    func moveCharacter(_ side: Side, toX x: Double, toY y: Double) -> Bool {
        moveCharacter(side, toX: x, y: y, z: Self.restingZ)
    }

    /// `getOptimalInterceptPosition` (`tennis.js:1037-1072`). Where the *body* has to stand for
    /// the racket head to end up on the intercept point.
    func optimalInterceptPosition(for side: Side, intercept: Intercept)
        -> (x: Double, y: Double, z: Double) {
        let rotation = side.current.rotation * .pi / 180
        let racket = side.racket

        let armWorldX = racket.armX * cos(rotation) - racket.armY * sin(rotation)
        let armWorldY = racket.armX * sin(rotation) + racket.armY * cos(rotation)

        let maxReach: Double = 43

        let absoluteYaw = racket.yaw + rotation
        let handleWorldX = cos(absoluteYaw)
        let handleWorldY = sin(absoluteYaw)

        // An arm forced to tilt up or down covers less ground horizontally.
        let dz = intercept.z - side.current.z
        let planarScale = sqrt(max(0.1, 1 - pow(min(abs(dz), maxReach) / maxReach, 2)))

        var stringbedWorldX = (armWorldX + handleWorldX) * planarScale
        let stringbedWorldY = (armWorldY + handleWorldY) * planarScale

        if side === npc {
            stringbedWorldX -= maxReach / 2 * Self.gameScale
        } else {
            stringbedWorldX += maxReach / 2 * Self.gameScale
        }

        return (x: intercept.x - stringbedWorldX,
                y: intercept.y - stringbedWorldY,
                z: intercept.z)
    }

    /// `moveToIntercept` (`tennis.js:1454-1470`) — only re-targets when the prediction moves.
    func moveToIntercept(_ side: Side) {
        if side.lastIntercept == nil { setNewInterceptPoints() }
        guard let intercept = side.lastIntercept else { return }

        if let previous = side.previousMoveToIntercept,
           previous.x == intercept.x, previous.y == intercept.y {
            return
        }

        let target = optimalInterceptPosition(for: side, intercept: intercept)
        _ = moveCharacter(side, toX: target.x, y: target.y, z: Self.restingZ)
        side.previousMoveToIntercept = intercept
    }

    /// `convergePhysics` (`tennis.js:1148-1226`).
    @discardableResult
    func convergePhysics(_ side: Side, dt: Double, isPlayer: Bool,
                                 speedMult: Double = 1.0) -> Bool {
        let prevX = side.current.x
        let prevY = side.current.y
        let speed = (isPlayer ? Self.playerSpeed : Self.npcSpeed) * dt * speedMult

        var mx: Double = 0
        let dx = side.target.x - side.current.x
        if abs(dx) > 1 {
            mx = (dx < 0 ? -1 : 1) * min(speed, abs(dx))
            side.current.x += mx
        } else {
            side.current.x = side.target.x
        }

        var my: Double = 0
        let dy = side.target.y - side.current.y
        if abs(dy) > 1 {
            my = (dy < 0 ? -1 : 1) * min(speed, abs(dy))
            side.current.y += my
        } else {
            side.current.y = side.target.y
        }

        let moveLen = sqrt(mx * mx + my * my)
        if moveLen > 0 {
            side.movementDirectionX = mx / moveLen
            side.movementDirectionY = my / moveLen
        }

        let dz = side.target.z - side.current.z
        if abs(dz) > 1 {
            side.current.z += (dz < 0 ? -1 : 1) * min(speed * 0.5, abs(dz))
        } else {
            side.current.z = side.target.z
        }

        // Only count as moved if it is visually significant, so sub-pixel target smoothing does
        // not leave the legs running on the spot.
        let charMoved = abs(side.current.x - prevX) > 0.5 || abs(side.current.y - prevY) > 0.5

        if charMoved {
            side.legTimer += speed * 0.1
            var targetRot = atan2(side.current.y - prevY, side.current.x - prevX) * 180 / .pi
            if targetRot < 0 { targetRot += 360 }

            if introPhase == .playing {
                // Never turn your back on the net.
                if isPlayer && targetRot > 0 && targetRot < 180 {
                    targetRot = 270
                } else if !isPlayer && targetRot > 180 && targetRot < 360 {
                    targetRot = 90
                }
            }

            side.target.rotation = targetRot
        } else if side.legTimer > 0 {
            // Finish the stride rather than snapping mid-step.
            let phase = side.legTimer.truncatingRemainder(dividingBy: .pi)
            if phase > 0.1 && phase < .pi - 0.1 {
                side.legTimer += speed * 0.1
            } else {
                side.legTimer = 0
            }
        }

        let diffRot = side.target.rotation - side.current.rotation
        side.current.rotation += ((diffRot + 540).truncatingRemainder(dividingBy: 360) - 180) * 0.1

        let target = side.racketTarget
        side.racket.pitch += (target.pitch - side.racket.pitch) * 0.1
        side.racket.roll += (target.roll - side.racket.roll) * 0.1
        side.racket.armX += (target.armX - side.racket.armX) * 0.2
        side.racket.armY += (target.armY - side.racket.armY) * 0.2

        let dYaw = target.yaw - side.racket.yaw
        side.racket.yaw += ((dYaw + .pi * 3).truncatingRemainder(dividingBy: .pi * 2) - .pi) * 0.1

        return charMoved
    }

    func resetRacketToNeutral(_ side: Side) {
        side.racketTarget.armX = Self.restingArmX
        side.racketTarget.armY = Self.restingArmY
        side.racketTarget.pitch = 0
        side.racketTarget.yaw = .pi * 0.25
        side.racketTarget.roll = Self.restingRacketRoll
    }

    /// `processCharacter` (`tennis.js:1240-1346`) — bounds, leaps, aim, then convergence.
    @discardableResult
    func processCharacter(_ side: Side, isPlayer: Bool, dt: Double) -> Bool {
        side.target.x = min(max(side.target.x, -Self.playableHalfWidth), Self.playableHalfWidth)
        if isPlayer {
            side.target.y = min(max(side.target.y, Self.netY + 10),
                                Self.playerBaseY + Self.playableOvershootY - 10)
        } else {
            side.target.y = min(max(side.target.y, Self.npcBaseY - Self.playableOvershootY + 10),
                                Self.netY - 10)
        }

        let now = EventInterpreter.nowMilliseconds()
        let distanceXY = distanceToBallXY(side)

        if canCharacterHit(isPlayer: isPlayer),
           let intercept = side.lastIntercept, intercept.t >= 0, distanceXY < 100 {

            /// True while the racket is still in front of the oncoming ball — once it is more
            /// than 10 units behind, the swing has been missed and the character tracks the
            /// prediction instead of the ball itself.
            func isRacketInRange(racketX: Double, racketY: Double) -> Bool {
                let speed = sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
                if speed == 0 { return true }
                let nx = ball.vx / speed
                let ny = ball.vy / speed
                let dot = (racketX - ball.x) * nx + (racketY - ball.y) * ny
                return dot <= 10
            }

            let rotation = side.current.rotation * .pi / 180
            let armWorldX = side.racketTarget.armX * cos(rotation)
                - side.racketTarget.armY * sin(rotation)
            let armWorldY = side.racketTarget.armX * sin(rotation)
                + side.racketTarget.armY * cos(rotation)
            let racketWorldX = side.current.x + armWorldX
            let racketWorldY = side.current.y + armWorldY
            let inRange = isRacketInRange(racketX: racketWorldX, racketY: racketWorldY)

            var reach = inRange
                ? armReach(for: side, towards: ball.x, ball.y, ball.z)
                : armReach(for: side, towards: intercept.x, intercept.y, intercept.z)
            reach.z = min(max(reach.z, Self.minCrouch), Self.maxJump)

            let lastZChange = now - side.lastZChangeTime
            if lastZChange > 150 {
                if intercept.t < 0.3 && (now - side.lastJumpTime > 500)
                    && side.current.z <= Self.jumpZ {
                    side.lastJumpTime = now
                    side.target.z = reach.z      // Jump — only from the ground.
                    side.lastZChangeTime = now
                } else if intercept.t < 0.25 && (now - side.lastJumpTime > 500)
                            && reach.z < Self.restingZ {
                    side.target.z = reach.z      // Crouch.
                    side.lastZChangeTime = now
                } else if reach.z >= Self.restingZ && reach.z < Self.jumpZ {
                    side.target.z = reach.z
                    side.lastZChangeTime = now
                } else {
                    side.target.z = Self.restingZ
                    side.lastZChangeTime = now
                }
            }

            side.racketTarget.armX = reach.x
            side.racketTarget.armY = reach.y

            let flat = returnBallHitTarget(isPlayer: isPlayer, racket: side.racket)
            let target = (x: flat.x, y: flat.y, z: Self.netHeight * Self.gameScale + 5)
            side.lastHitTarget = target

            let aim = inRange
                ? racketReturnAim(from: ball.vx, ball.vy, ball.vz,
                                  at: ball.x, ball.y, ball.z,
                                  side: side, target: target)
                : racketReturnAim(from: intercept.vx, intercept.vy, intercept.vz,
                                  at: intercept.x, intercept.y, intercept.z,
                                  side: side, target: target)

            side.racketTarget.pitch = aim.pitch
            side.racketTarget.yaw = aim.yaw
            side.racketTarget.roll = aim.roll
        } else {
            side.target.z = Self.restingZ
            resetRacketToNeutral(side)
        }

        return convergePhysics(side, dt: dt, isPlayer: isPlayer)
    }

    /// `handleIntroSequence` (`tennis.js:1078-1133`) — walk to the net, shake hands, walk back,
    /// then serve.
    func handleIntroSequence(dt: Double) {
        switch introPhase {
        case .walkToNet:
            let pMoving = moveCharacter(player, toX: 0, toY: Self.netY + 25)
            let nMoving = moveCharacter(npc, toX: 0, toY: Self.netY - 25)

            convergePhysics(player, dt: dt, isPlayer: true, speedMult: 0.5)
            convergePhysics(npc, dt: dt, isPlayer: false, speedMult: 0.5)

            // Override whatever the convergence decided; they face each other.
            player.target.rotation = 270
            npc.target.rotation = 90

            if !pMoving && !nMoving {
                introPhase = .shakeHands
                introTimer = 2.0
                player.legTimer = 0
                npc.legTimer = 0
            }

        case .shakeHands:
            introTimer -= dt
            player.current.rotation = 270 + sin(introTimer * 20) * 10
            npc.current.rotation = 90 - sin(introTimer * 20) * 10
            if introTimer <= 0 { introPhase = .walkToBaseline }

        case .walkToBaseline:
            let serveOffset = Self.courtWidth * 0.4
            let targetPX = nextServerIsPlayer ? serveSide * serveOffset : serveSide * -serveOffset
            let targetNX = nextServerIsPlayer ? serveSide * -serveOffset : serveSide * serveOffset

            let pFar = moveCharacter(player, toX: targetPX, toY: Self.playerBaseY)
            let nFar = moveCharacter(npc, toX: targetNX, toY: Self.npcBaseY)

            convergePhysics(player, dt: dt, isPlayer: true, speedMult: 0.6)
            convergePhysics(npc, dt: dt, isPlayer: false, speedMult: 0.6)

            if !pFar { player.target.rotation = 270 }
            if !nFar { npc.target.rotation = 90 }

            let finishedRotating = player.current.rotation.rounded() == player.target.rotation.rounded()
                && npc.current.rotation.rounded() == npc.target.rotation.rounded()

            if !pFar && !nFar && finishedRotating {
                player.legTimer = 0
                npc.legTimer = 0
                introPhase = .playing
                serveBall(nextServerIsPlayer ? player : npc)
            }

        case .playing:
            break
        }
    }
}
