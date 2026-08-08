import Foundation

/// What the ball does: its flight and bounce, the two ways it is put into play, and what
/// happens when a racket catches it.
///
/// The fault and point-reset paths live here too, because in `tennis.js` they are what a
/// bounce in the wrong place turns into — the rules are expressed as outcomes of the ball's
/// own physics rather than as a separate rules engine.
extension TennisGame {
    // MARK: - Ball physics

    func moveBall(x: Double, y: Double, z: Double) {
        ball.x = x
        ball.y = y
        ball.z = z
        ball.vx = 0
        ball.vy = 0
        ball.vz = 0
    }

    /// `processBallMovement` (`tennis.js:447-503`).
    ///
    /// The web build also samples the flight into `trajectoryPoints` here, for the side-profile
    /// graph in the admin diagnostics overlay. That overlay is gated on `window.isAdmin`, and
    /// the native client has no admin mode (`admin.js` stays a web page — PLAN.md §7), so the
    /// sampling is left out along with the graph.
    func processBallMovement(dt: Double) {
        let previousBallY = ball.y

        if servePhase == .idle { return }   // Ball in hand.

        ball.z += ball.vz * dt
        ball.vz -= Self.gravity * dt
        ball.x += ball.vx * dt
        ball.y += ball.vy * dt

        // Net collision: did the ball cross the centre line this frame, and how high was it?
        if (previousBallY < Self.netY && ball.y >= Self.netY)
            || (previousBallY >= Self.netY && ball.y < Self.netY) {
            if ball.z < Self.netHeight {
                ball.vy *= -0.3
                ball.vx *= 0.3
                ball.y = Self.netY + (ball.vy < 0 ? -5 : (ball.vy > 0 ? 5 : 0))
            }
        }

        if ball.z < 0 {
            ball.z = 0
            bounceCount += 1
            ball.vz = abs(ball.vz) * Self.dampingMultiplier
            onBounce()
        }
    }

    /// The bounce handler passed into `processBallMovement` (`tennis.js:1397-1452`).
    func onBounce() {
        setNewInterceptPoints()

        if bounceCount == 1 && !resetting {
            guard let hitter = lastHitter else {
                // The serve toss hit the floor before the racket found it.
                triggerFault(playerServing: isServe == .playerServe)
                return
            }

            let minX = Self.courtX
            let maxX = Self.courtX + Self.courtWidth
            let minY = Self.courtY
            let maxY = Self.courtY + Self.courtHeight
            let inBoundsX = ball.x >= minX && ball.x <= maxX
            var validBounce = false

            if isServe != .inPlay {
                if let box = activeServiceBox,
                   ball.x >= box.minX, ball.x <= box.maxX,
                   ball.y >= box.minY, ball.y <= box.maxY {
                    validBounce = true
                    isServe = .inPlay    // The serve landed; the rally is open.
                }
            } else {
                switch hitter {
                case .player: validBounce = inBoundsX && ball.y >= minY && ball.y <= Self.netY
                case .npc: validBounce = inBoundsX && ball.y >= Self.netY && ball.y <= maxY
                }
            }

            if !validBounce {
                if isServe != .inPlay {
                    triggerFault(playerServing: hitter == .player)
                } else {
                    triggerPointReset(nextPlayerServing: hitter == .player)
                }
            }
        }

        // Two valid bounces means whoever should have returned it lost the point.
        if bounceCount == 2 && !resetting {
            triggerPointReset(nextPlayerServing: ball.y > Self.netY)
        }
    }

    /// `hitBallToTarget` (`tennis.js:513-575`).
    func hitBallToTarget(x targetX: Double, y targetY: Double, velocity: Double) {
        var boundedVelocity = min(velocity, Self.maximumBallSpeed)
        bounceCount = 0

        let dx = targetX - ball.x
        let dy = targetY - ball.y
        let dist = sqrt(dx * dx + dy * dy)

        var timeToTarget = dist / boundedVelocity

        // Cap the flight time so nothing turns into a moonball; a target further away than that
        // gets driven harder and flatter instead.
        let maxFlightTime = 1.3
        if timeToTarget > maxFlightTime {
            timeToTarget = maxFlightTime
            boundedVelocity = dist / timeToTarget
        }

        var vZ = (0.5 * Self.gravity * timeToTarget * timeToTarget - ball.z) / timeToTarget

        let crossesNet = (ball.y < Self.netY && targetY > Self.netY)
            || (ball.y > Self.netY && targetY < Self.netY)

        if crossesNet {
            let timeToNet = (abs(Self.netY - ball.y) / abs(dy)) * timeToTarget
            let requiredClearanceHeight = Self.netHeight + Self.ballRadius + 5
            let minVZ = (requiredClearanceHeight - ball.z
                         + 0.5 * Self.gravity * timeToNet * timeToNet) / timeToNet

            // A flat stroke that would hit the net gets an upward assist — but a hard, fast or
            // very low shot resists it, which is what lets a ball find the net at all.
            if vZ < minVZ {
                var assist = 1.0
                if boundedVelocity > 250 { assist -= 0.2 }
                if ball.z < 20 { assist -= 0.4 }
                assist = min(max(assist + (Double.random(in: 0..<1) * 0.2 - 0.1), 0), 1)
                vZ = vZ + (minVZ - vZ) * assist
            }
        }

        ball.vz = vZ
        ball.vx = (dx / dist) * boundedVelocity
        ball.vy = (dy / dist) * boundedVelocity
    }

    // MARK: - Serving

    /// `generateReturnBallHitCords` (`tennis.js:712-748`).
    func returnBallHitTarget(isPlayer: Bool, racket: Racket?) -> (x: Double, y: Double) {
        if isServe != .inPlay {
            return serveTarget(isPlayer: isPlayer)
        }

        let courtCenterX = Self.courtX + Self.courtWidth / 2
        var targetX: Double
        var targetY: Double

        if isPlayer {
            // Deep into the NPC's half, diagonally away from where it is standing.
            targetY = Self.courtY + Self.courtHeight * (0.1 + Double.random(in: 0..<1) * 0.25)
            targetX = npc.current.x > courtCenterX
                ? Self.courtX + Self.courtWidth * (0.1 + Double.random(in: 0..<1) * 0.2)
                : Self.courtX + Self.courtWidth * (0.8 + Double.random(in: 0..<1) * 0.1)

            // How cleanly the racket met the ball skews the shot.
            if let racket { targetX += (ball.x - racket.x) * 1.5 }
        } else {
            targetY = Self.courtY + Self.courtHeight * (0.6 + Double.random(in: 0..<1) * 0.3)
            targetX = Self.courtX + Self.courtWidth * (0.15 + Double.random(in: 0..<1) * 0.7)
        }

        targetX = min(max(targetX, Self.courtX + 10), Self.courtX + Self.courtWidth - 10)
        return (x: targetX, y: targetY)
    }

    /// `calculateServeTarget` (`tennis.js:750-773`) — 90% aimed inside the box, 10% a fault.
    func serveTarget(isPlayer: Bool) -> (x: Double, y: Double) {
        guard let box = activeServiceBox else { return (0, 0) }

        if Double.random(in: 0..<1) < 0.9 {
            let aimWide = Double.random(in: 0..<1) > 0.5
            let safeLeft = box.minX + 15
            let safeRight = box.maxX - 15
            let safeY = isPlayer ? box.minY + 20 : box.maxY - 20

            var tx = aimWide ? safeLeft : safeRight
            var ty = safeY
            tx += Double.random(in: 0..<1) * 10 - 5
            ty += Double.random(in: 0..<1) * 10 - 5
            return (x: tx, y: ty)
        }

        return (x: box.minX + Double.random(in: 0..<1) * (box.maxX - box.minX)
                    + (Double.random(in: 0..<1) * 60 - 30),
                y: box.minY + Double.random(in: 0..<1) * (box.maxY - box.minY)
                    + (isPlayer ? -40 : 40))
    }

    /// `serveBall` (`tennis.js:781-845`).
    func serveBall(_ side: Side) {
        let isPlayer = side === player
        resetting = false
        isServe = isPlayer ? .playerServe : .npcServe
        servePhase = .idle
        player.lastIntercept = nil
        npc.lastIntercept = nil
        player.previousMoveToIntercept = nil
        npc.previousMoveToIntercept = nil

        // Put the ball in the server's left hand.
        let server = isPlayer ? player : npc
        let rotation = server.current.rotation * .pi / 180
        let limbs = Self.limbs(for: server, rightArmX: 0, rightArmY: 0)

        let leftArmX = Double(limbs.leftArmX)
        let leftArmY = Double(limbs.leftArmY)
        let armWorldX = (leftArmX * cos(rotation) - leftArmY * sin(rotation))
            * Self.cameraZoom * Self.courtScale
        let armWorldY = (leftArmX * sin(rotation) + leftArmY * cos(rotation))
            * Self.cameraZoom * Self.courtScale

        moveBall(x: server.current.x + armWorldX,
                 y: server.current.y + armWorldY,
                 z: server.current.z)

        // Service boxes, cross-court, inside the singles lines (12.5% doubles alleys a side).
        let centerX = Self.courtX + Self.courtWidth / 2
        let serviceBoxDepth = Self.courtHeight * 0.245
        let doublesAlleyWidth = Self.courtWidth * 0.125
        let singlesMinX = Self.courtX + doublesAlleyWidth
        let singlesMaxX = Self.courtX + Self.courtWidth - doublesAlleyWidth

        if isPlayer {
            activeServiceBox = ServiceBox(
                minX: serveSide == -1 ? centerX : singlesMinX,
                maxX: serveSide == -1 ? singlesMaxX : centerX,
                minY: Self.netY - serviceBoxDepth,
                maxY: Self.netY)
        } else {
            activeServiceBox = ServiceBox(
                minX: serveSide == 1 ? centerX : singlesMinX,
                maxX: serveSide == 1 ? singlesMaxX : centerX,
                minY: Self.netY,
                maxY: Self.netY + serviceBoxDepth)
        }

        lastHitter = isPlayer ? .player : .npc

        // A one-second beat before the toss.
        throwDeadline = Date.timeIntervalSinceReferenceDate + 1.0
    }

    /// `throwBall` (`tennis.js:861-904`) — the toss, timed so the ball is at its apex when the
    /// server is allowed to strike it.
    func throwBall(_ side: Side) {
        let isPlayer = side === player
        servePhase = .justThrown

        let startX = ball.x
        let startY = ball.y

        tossTarget = (x: startX + (isPlayer ? 85 * Self.gameScale : -85 * Self.gameScale),
                      y: startY + (isPlayer ? -15 * Self.gameScale : 15 * Self.gameScale),
                      z: 125 * Self.gameScale)
        guard let toss = tossTarget else { return }

        let dz = max(1, toss.z - ball.z)
        let vZ = sqrt(2 * Self.gravity * dz)
        let tApex = vZ / Self.gravity
        let tFall = sqrt((2 * toss.z) / Self.gravity)
        let tTotalFlight = tApex + tFall

        ball.vx = (toss.x - startX) / tTotalFlight
        ball.vy = (toss.y - startY) / tTotalFlight
        ball.vz = vZ

        bounceCount = 0
        rallyCount = 0

        apexDeadline = Date.timeIntervalSinceReferenceDate + tApex
    }

    /// `triggerFault` (`tennis.js:926-944`).
    func triggerFault(playerServing: Bool) {
        if resetting { return }
        faults += 1

        if faults >= 2 {
            triggerPointReset(nextPlayerServing: !playerServing)
        } else {
            resetting = true
            resetDelayTimer = 1.0
            nextServerIsPlayer = playerServing    // Same server, second serve.
        }

        player.lastIntercept = nil
        npc.lastIntercept = nil
    }

    /// `triggerPointReset` (`tennis.js:952-993`). The loser of the rally serves next, which is
    /// also how the point is attributed.
    func triggerPointReset(nextPlayerServing: Bool) {
        if resetting { return }
        resetting = true
        player.previousMoveToIntercept = nil
        npc.previousMoveToIntercept = nil
        player.lastHitTarget = nil
        npc.lastHitTarget = nil

        if nextPlayerServing { npc.score += 1 } else { player.score += 1 }
        faults = 0

        var wonSet = false
        let scoreData = Self.score(player: player.score, npc: npc.score)
        if let winner = scoreData.winner {
            if winner == .player {
                host.minigameAwardBadge("tennis")
                wonSet = true
            }
            player.score = 0
            npc.score = 0
        }
        onScoreChanged?()

        self.nextServerIsPlayer = nextPlayerServing
        // Deuce court (-1) on an even total, advantage court (1) on an odd one.
        serveSide = (player.score + npc.score) % 2 == 0 ? -1 : 1
        resetDelayTimer = 1.5

        if wonSet {
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 1.0)
        } else if rallyCount >= 4 {
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.7)
        }
    }

    // MARK: - Contact

    /// `processRacketDeflections` (`tennis.js:1001-1021`) and the hit handler that follows it
    /// (`tennis.js:1504-1540`). The hitbox is the ellipse the racket head was *drawn* as.
    func processRacketDeflections(visualBallY: Double) {
        if resetting { return }

        func evaluateHit(_ racket: Racket) -> Bool {
            let dx = ball.x - racket.x
            let dy = visualBallY - racket.y
            let localDx = dx * cos(-racket.angle) - dy * sin(-racket.angle)
            let localDy = dx * sin(-racket.angle) + dy * cos(-racket.angle)

            return pow(localDx, 2) / pow(racket.w + Self.ballRadius, 2)
                + pow(localDy, 2) / pow(racket.h + Self.ballRadius, 2) <= 1
        }

        if canCharacterHit(isPlayer: true) && evaluateHit(player.racket) {
            processHit(isPlayer: true)
        } else if canCharacterHit(isPlayer: false) && evaluateHit(npc.racket) {
            processHit(isPlayer: false)
        }
    }

    func processHit(isPlayer: Bool) {
        let side = isPlayer ? player : npc
        let payload = side.lastHitTarget.map { (x: $0.x, y: $0.y) }
            ?? returnBallHitTarget(isPlayer: isPlayer, racket: side.racket)

        var returnSpeed = sqrt(ball.vx * ball.vx + ball.vy * ball.vy) * (isPlayer ? 1.05 : 1.1)
        if isServe != .inPlay {
            returnSpeed = Self.ballSpeed * (isPlayer ? 0.8 : 0.65)
        }

        rallyCount += 1
        lastHitter = isPlayer ? .player : .npc
        bounceCount = 0
        hitBallToTarget(x: payload.x, y: payload.y, velocity: returnSpeed)

        let soundFile = isPlayer ? "/media/hit_tennis_ball.mp3" : "/media/hit_tennis_ball2.mp3"
        host.minigamePlayEffect(path: soundFile,
                                volume: 0.7 + Double.random(in: 0..<1) * 0.5,
                                rate: 0.85 + Double.random(in: 0..<1) * 0.3)

        ball.z = max(10, ball.z)    // Lift a ball scooped off the deck.

        setNewInterceptPoints()

        if isPlayer {
            if isServe == .playerServe {
                // Chase the serve down where it is going to land.
                let spot = landingSpot()
                _ = moveCharacter(npc,
                                  toX: spot.x + 40 * Self.gameScale,
                                  toY: spot.y - 220 * Self.gameScale * 0.7)
            } else {
                _ = moveCharacter(npc,
                                  toX: Self.courtX + (Self.courtWidth / 2)
                                       * (0.5 + Double.random(in: 0..<1)),
                                  toY: Self.npcBaseY + 50 * Self.gameScale
                                       * (0.5 + Double.random(in: 0..<1)))
            }
        }
    }

}
