import Foundation
import simd

/// The ten players: who they are, where they stand, how they decide, and what a pass does.
///
/// Everything positional is in **team space** — `u` towards the try line a side is attacking,
/// `v` across — so both sides share one formation, one support rule and one defensive line.
/// See `FootballGame+Team` for the reasoning; this file is its rugby cousin.
///
/// What rugby changes about the AI:
///
/// - **Nobody has a position to hold when their side has the ball.** All four team mates of the
///   carrier run in a line behind and beside them — `supportTarget` — because a pass can only go
///   to somebody who is there to catch it.
/// - **The defence is a line, not a shape.** Everyone who is not the designated tackler stands
///   between the ball and their own try line, spread across the pitch — `defensiveTarget`.
/// - **The AI only ever passes backwards or sideways**, like real rugby. You may throw it
///   wherever you like.
extension RugbyGame {

    // MARK: - Building the sides

    /// Five across the pitch, a little staggered: the wings sit deeper than the centre.
    static let formation: [(u: Double, v: Double)] = [
        (-0.30, -0.70),
        (-0.20, -0.35),
        (-0.15, 0),
        (-0.20, 0.35),
        (-0.30, 0.70),
    ]

    /// Which body wears Joel's own face and has the stick at the first whistle: the centre.
    static let humanSlot = 2

    /// **Every NPC is a Royal or a Challenger.** Fixed per slot so a side is the same mix every
    /// match: wings and centre quick, the two inside them strong — and red the other way round,
    /// so the two sides do not mirror each other.
    static let blueClasses: [PlayerClass] = [.royal, .challenger, .royal, .challenger, .royal]
    static let redClasses: [PlayerClass] = [.challenger, .royal, .challenger, .royal, .challenger]

    func buildTeams(npcs: [GameCharacter], myCharacter: GameCharacter?) {
        let models = ["boy", "girl", "stylized_boy", "boy", "girl",
                      "stylized_boy", "boy", "girl", "boy", "stylized_boy"]

        var built: [Player] = []
        built.reserveCapacity(Self.formation.count * 2)

        for team in [Team.blue, Team.red] {
            for (index, slot) in Self.formation.enumerated() {
                let wearsMyFace = team == .blue && index == Self.humanSlot

                var appearance: GameCharacter
                if wearsMyFace, let mine = myCharacter {
                    appearance = mine
                } else {
                    let pool = index + (team == .blue ? 0 : Self.formation.count)
                    appearance = pool < npcs.count
                        ? npcs[pool]
                        : GameCharacter(id: 0, name: nil, width: 40, height: 40)
                    appearance.model = appearance.model ?? models[index]
                }

                appearance.id = 9300 + built.count
                appearance.outfit = team.outfit
                appearance.holding = nil
                appearance.emote = nil
                appearance.default_emote = nil
                appearance.hide_nameplate = true
                appearance.z = 0

                built.append(Player(appearance: appearance,
                                    team: team,
                                    playerClass: (team == .blue ? Self.blueClasses
                                                                : Self.redClasses)[index],
                                    home: SIMD2(slot.u, slot.v),
                                    wearsMyFace: wearsMyFace,
                                    topSpeed: Tuning.topSpeed * team.skill.speed))
            }
        }

        players = built
        takeControl(of: Self.humanSlot)
    }

    // MARK: - Team space

    func worldPoint(u: Double, v: Double, for team: Team) -> SIMD2<Double> {
        SIMD2(team.attackDirection * v * RugbyPitch.halfWidth * 0.9,
              team.attackDirection * u * RugbyPitch.halfField * 0.94)
    }

    func teamSpace(x: Double, y: Double, for team: Team) -> SIMD2<Double> {
        SIMD2(team.attackDirection * x / RugbyPitch.halfWidth,
              team.attackDirection * y / RugbyPitch.halfField)
    }

    /// A restart: the formation gathered round wherever the ball is (`restartBallU`, in the
    /// restarting side's space), the restarting side a few metres behind it and **the other side
    /// ten metres off**, as in real rugby — and so that a ten-year-old handed the ball has a
    /// couple of seconds to look up and tap a pass before a red shirt arrives, rather than being
    /// flattened where he stands. Nobody inside five metres of the ball.
    func kickoffSpot(for player: Player) -> SIMD2<Double> {
        let ballU = restartBallU
        let u: Double
        if player.team == kickoffTeam {
            // The formation, squeezed to half its depth, a stride behind the ball.
            u = ballU - 0.1 + (player.home.x + 0.15) * 0.5
        } else {
            // The ball sits at −ballU in this side's space; a line a third of a half off it.
            u = -ballU - 0.33 + (player.home.x + 0.3) * 0.5
        }
        var spot = worldPoint(u: min(max(u, -0.92), 0.9), v: player.home.y, for: player.team)

        let ballPoint = worldPoint(u: ballU, v: 0, for: kickoffTeam)
        let clearance = RugbyPitch.metres(5)
        let offset = spot - ballPoint
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        if distance < clearance {
            spot = distance < 0.001
                ? ballPoint + SIMD2(0, -player.team.attackDirection * clearance)
                : ballPoint + offset * (clearance / distance)
        }
        return spot
    }

    // MARK: - One player's frame

    func steer(_ index: Int) {
        let player = players[index]
        let hasBall = carrier == index

        // Pace: everybody's class, plus the control bonus on whoever the stick is on. Carrying
        // costs a little, and being grabbed costs a lot — see `carrierSlowFactor`.
        var top = player.baseSpeed * classOf(index).speed
        if player.isControlled { top += Tuning.controlSpeedBonus }
        player.motor.profile.maxSpeed = hasBall ? top * Tuning.carryFraction * carrierSlowFactor
                                                : top
        player.motor.profile.acceleration = Tuning.acceleration

        // On the floor: nothing moves until they are up.
        if player.isDown {
            player.motor.holdPosition()
            return
        }

        if player.lungeTimer > 0 {
            steerLunge(player)
            return
        }
        if player.isControlled {
            steerControlled(player)
            return
        }
        if startsDive(index) {
            steerLunge(player)
            return
        }
        if player.recoverTimer > 0 {
            player.motor.profile.maxSpeed = top * Tuning.recoverySpeedFraction
        }
        if hasBall {
            steerCarrier(index)
            return
        }
        steerOffTheBall(index)
    }

    private func steerControlled(_ player: Player) {
        let move = currentMoveInput
        let magnitude = (move.x * move.x + move.y * move.y).squareRoot()
        guard magnitude > 0.02 else {
            player.motor.holdPosition()
            return
        }
        player.motor.driveCharacter(velocityX: move.x * player.motor.profile.maxSpeed,
                                    velocityY: move.y * player.motor.profile.maxSpeed)
    }

    /// Whether this AI player dives now: at a carrier who is running, from within their side's
    /// dive range, and only one diver per side at a time.
    private func startsDive(_ index: Int) -> Bool {
        let player = players[index]
        guard let holder = carrier, players[holder].team != player.team,
              player.recoverTimer <= 0, player.catchCooldown <= 0
        else { return false }

        let runner = players[holder].motor
        guard runner.speed > Tuning.lungeWhenCarrierFasterThan else { return false }
        let range = Tuning.lungeRange * player.team.skill.dive
        guard hypot(ball.x - player.motor.x, ball.y - player.motor.y) < range else { return false }
        guard !players.contains(where: { $0.team == player.team && $0.lungeTimer > 0 })
        else { return false }

        return aimDive(player, at: runner)
    }

    /// Points a dive at where the ball will be halfway through it. Returns false if there is
    /// nothing to aim at.
    @discardableResult
    private func aimDive(_ player: Player, at runner: CharacterMotor) -> Bool {
        let lead = Tuning.lungeTime * 0.5
        let aim = SIMD2(ball.x + runner.vx * lead - player.motor.x,
                        ball.y + runner.vy * lead - player.motor.y)
        let length = (aim.x * aim.x + aim.y * aim.y).squareRoot()
        guard length > 0.001 else { return false }
        player.lungeDirection = aim / length
        player.lungeTimer = Tuning.lungeTime
        return true
    }

    /// **Your dive**, from a tap with no ball. Challenger reaches further.
    func humanDive() {
        let player = players[humanIndex]
        guard let holder = carrier, players[holder].team != player.team,
              player.lungeTimer <= 0, player.recoverTimer <= 0, !player.isDown
        else { return }
        let range = Tuning.humanDiveRange * (playerClass?.tackling ?? 1)
        guard hypot(ball.x - player.motor.x, ball.y - player.motor.y) < range else { return }
        aimDive(player, at: players[holder].motor)
    }

    private func steerLunge(_ player: Player) {
        player.motor.profile.maxSpeed = Tuning.lungeSpeed
        player.motor.profile.acceleration = Tuning.lungeAcceleration
        player.motor.driveCharacter(velocityX: player.lungeDirection.x * Tuning.lungeSpeed,
                                    velocityY: player.lungeDirection.y * Tuning.lungeSpeed)
    }

    /// Everybody on their feet who is neither you nor on the ball.
    private func steerOffTheBall(_ index: Int) {
        let player = players[index]
        var target: SIMD2<Double>

        if let holder = carrier {
            if players[holder].team == player.team {
                target = supportTarget(for: index, around: holder)
            } else if index == chaser(for: player.team) {
                // Lead the carrier by a quarter second.
                let runner = players[holder].motor
                player.motor.moveCharacterTo(x: runner.x + runner.vx * 0.25,
                                             y: runner.y + runner.vy * 0.25,
                                             targetSpeed: player.motor.profile.maxSpeed)
                return
            } else if distanceBetween(index, holder) < RugbyPitch.metres(4.5) {
                // **The line tackles.** A defender the carrier runs at goes for them rather than
                // backing off to keep the shape — otherwise the line retreats at the carrier's
                // pace all the way to the try line and never lays a hand on anybody.
                let runner = players[holder].motor
                player.motor.moveCharacterTo(x: runner.x + runner.vx * 0.2,
                                             y: runner.y + runner.vy * 0.2,
                                             targetSpeed: player.motor.profile.maxSpeed)
                return
            } else {
                target = defensiveTarget(for: player)
            }
        } else if index == chaser(for: player.team) {
            player.motor.moveCharacterTo(x: ball.x + ball.vx * 0.25,
                                         y: ball.y + ball.vy * 0.25,
                                         targetSpeed: player.motor.profile.maxSpeed)
            return
        } else {
            target = defensiveTarget(for: player)
        }

        target += separation(for: index)
        player.motor.moveCharacterTo(x: target.x, y: target.y,
                                     targetSpeed: player.motor.profile.maxSpeed)
    }

    /// The AI carrier: run at the try line, round the nearest defender, and every
    /// `decisionInterval` ask whether to pass instead.
    private func steerCarrier(_ index: Int) {
        let player = players[index]

        if player.decisionTimer <= 0 {
            player.decisionTimer = Tuning.decisionInterval
            if decidePass(from: index) { return }
        }

        let direction = player.team.attackDirection
        let tryY = RugbyPitch.tryLineY(attackDirection: direction) + direction * RugbyPitch.metres(2)
        var target = SIMD2(player.motor.x * 0.7, tryY)

        if let blocker = nearestOpponentIndex(to: index) {
            let opponent = players[blocker]
            let ahead = (opponent.motor.y - player.motor.y) * direction
            let across = opponent.motor.x - player.motor.x
            if ahead > -RugbyPitch.metres(1), ahead < RugbyPitch.metres(7),
               abs(across) < RugbyPitch.metres(4) {
                target.x = player.motor.x - (across >= 0 ? 1 : -1) * RugbyPitch.metres(7)
            }
        }

        let edge = RugbyPitch.halfWidth - RugbyPitch.metres(1)
        target.x = min(max(target.x, -edge), edge)
        player.motor.moveCharacterTo(x: target.x, y: target.y,
                                     targetSpeed: player.motor.profile.maxSpeed)
    }

    // MARK: - Positioning

    /// **The support line.** Team mates fan out either side of the carrier, each a little
    /// further back than the last, so there is always somebody behind to pass to. Which side a
    /// player takes is decided by their home slot, so the line never crosses itself.
    private func supportTarget(for index: Int, around holder: Int) -> SIMD2<Double> {
        let player = players[index]
        let carrierPlayer = players[holder]
        let direction = player.team.attackDirection

        // Which side of the carrier, and how many team mates are between.
        var side: Double = player.home.y < carrierPlayer.home.y ? -1 : 1
        if player.home.y == carrierPlayer.home.y { side = index < holder ? -1 : 1 }
        var rank = 1
        for other in players.indices
        where other != index && other != holder && players[other].team == player.team {
            let otherSide: Double = players[other].home.y < carrierPlayer.home.y ? -1
                : players[other].home.y > carrierPlayer.home.y ? 1
                : (other < holder ? -1 : 1)
            guard otherSide == side else { continue }
            // Closer to the carrier's slot than this player: they sit between.
            if abs(players[other].home.y - carrierPlayer.home.y)
                < abs(player.home.y - carrierPlayer.home.y) { rank += 1 }
        }

        let across = side * direction * Double(rank) * RugbyPitch.metres(5.5)
        let behind = RugbyPitch.metres(2.5 + 1.3 * Double(rank))
        var target = SIMD2(carrierPlayer.motor.x + across,
                           carrierPlayer.motor.y - direction * behind)

        let edgeX = RugbyPitch.halfWidth - RugbyPitch.metres(1.5)
        let edgeY = RugbyPitch.halfLength - RugbyPitch.metres(1.5)
        target.x = min(max(target.x, -edgeX), edgeX)
        target.y = min(max(target.y, -edgeY), edgeY)
        return target
    }

    /// **The defensive line.** Between the ball and our own try line, spread across the pitch
    /// and shaded towards the ball.
    private func defensiveTarget(for player: Player) -> SIMD2<Double> {
        let ballSpace = teamSpace(x: ball.x, y: ball.y, for: player.team)
        var u = ballSpace.y - 0.14
        var v = player.home.y * 0.8 + 0.3 * ballSpace.x
        u = min(max(u, -0.92), 0.6)
        v = min(max(v, -0.95), 0.95)
        return worldPoint(u: u, v: v, for: player.team)
    }

    private func separation(for index: Int) -> SIMD2<Double> {
        let player = players[index]
        let reach = RugbyPitch.metres(3.0)
        var push = SIMD2<Double>.zero
        for other in players.indices
        where other != index && players[other].team == player.team {
            let dx = player.motor.x - players[other].motor.x
            let dy = player.motor.y - players[other].motor.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > 0.001, distance < reach else { continue }
            let strength = (reach - distance) / reach
            push += SIMD2(dx / distance, dy / distance) * strength * RugbyPitch.metres(2.2)
        }
        return push
    }

    /// The one player on a side going for the ball — or the carrier. Nobody else is sent while
    /// you are genuinely closing it down. See `FootballGame.chaser(for:)`.
    private func chaser(for team: Team) -> Int? {
        let closingRange = RugbyPitch.metres(7)
        var best: Int?
        var bestDistance = Double.infinity
        var youAreClosing = false

        for index in players.indices
        where players[index].team == team && !players[index].isDown {
            let distance = hypot(players[index].motor.x - ball.x,
                                 players[index].motor.y - ball.y)
            if players[index].isControlled {
                // **Near is not enough — you have to be moving.** Control follows the ball to
                // whichever blue shirt is nearest, so a thumb that is off the stick leaves the
                // nearest player standing still; counting that as "closing it down" sent nobody
                // else, and a red carrier once strolled the length of the pitch past a blue
                // side that was all waiting for you.
                youAreClosing = distance < closingRange
                    && players[index].motor.speed > RugbyPitch.metres(1.5)
                continue
            }
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return youAreClosing ? nil : best
    }

    // MARK: - Deciding to pass

    /// The AI carrier's one decision. Pass when a defender is about to arrive and somebody is
    /// behind in space; otherwise keep running.
    private func decidePass(from index: Int) -> Bool {
        let player = players[index]
        let direction = player.team.attackDirection

        var pressed = false
        if let threat = nearestOpponentIndex(to: index) {
            let opponent = players[threat]
            let ahead = (opponent.motor.y - player.motor.y) * direction
            let distance = distanceBetween(index, threat)
            pressed = distance < RugbyPitch.metres(3.6) && ahead > -RugbyPitch.metres(1.5)
                || opponent.lungeTimer > 0 && distance < RugbyPitch.metres(5)
        }

        // Within reach of the line, nobody passes — they go for it.
        let toLine = (RugbyPitch.tryLineY(attackDirection: direction) - player.motor.y) * direction
        if toLine < RugbyPitch.metres(6) { return false }

        // **And nobody passes from inside their own 22.** Every AI pass goes backwards, so a
        // side under pressure near its own line passed its way into its own in-goal, where the
        // chasing red shirt touched it down — a measured match lost two tries exactly that way.
        // Deep in your own half you run, and take the tackle if it comes.
        let mine = teamSpace(x: player.motor.x, y: player.motor.y, for: player.team)
        if mine.y < -0.37 { return false }

        guard pressed || random.unit() < 0.04,
              let mate = bestSupportBehind(index) else { return false }

        let target = players[mate].motor
        throwBall(from: index, toX: target.x, y: target.y, leading: true)
        return true
    }

    /// The best team mate who is level or behind: in space, not too far, lane not blocked.
    func bestSupportBehind(_ index: Int) -> Int? {
        let player = players[index]
        let mine = teamSpace(x: player.motor.x, y: player.motor.y, for: player.team)
        var best: (index: Int, score: Double)?

        for other in players.indices
        where other != index && players[other].team == player.team && !players[other].isDown {
            let mate = players[other]
            let distance = distanceBetween(index, other)
            guard distance > RugbyPitch.metres(2.5),
                  distance < RugbyPitch.metres(18) else { continue }
            let theirs = teamSpace(x: mate.motor.x, y: mate.motor.y, for: player.team)
            // Behind or level only — a real rugby pass.
            guard theirs.y <= mine.y + 0.02 else { continue }

            var score = min(nearestOpponentDistance(to: other) / RugbyPitch.metres(6), 1) * 1.2
            score -= max(0, distance - RugbyPitch.metres(10)) / RugbyPitch.metres(10) * 0.6
            // Not too far back: a pass to the 22 is a pass that loses twenty metres.
            score -= max(0, (mine.y - theirs.y) - 0.1) * 2
            if laneBlocked(from: index, toX: mate.motor.x, toY: mate.motor.y) { score -= 1.5 }
            if score > (best?.score ?? -.infinity) { best = (other, score) }
        }
        return best.map { $0.score > -0.4 ? $0.index : nil } ?? nil
    }

    private func laneBlocked(from index: Int, toX: Double, toY: Double) -> Bool {
        let player = players[index]
        let dx = toX - player.motor.x
        let dy = toY - player.motor.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1 else { return false }

        for other in players.indices where players[other].team != player.team {
            let ox = players[other].motor.x - player.motor.x
            let oy = players[other].motor.y - player.motor.y
            let along = (ox * dx + oy * dy) / lengthSquared
            guard along > 0.05, along < 0.95 else { continue }
            let acrossX = ox - dx * along
            let acrossY = oy - dy * along
            if (acrossX * acrossX + acrossY * acrossY).squareRoot() < RugbyPitch.metres(1.5) {
                return true
            }
        }
        return false
    }

    // MARK: - Passes

    /// **Your pass**: to the spot you tapped, no further than `maxPassDistance` away and never
    /// into the boards.
    func passFromHuman(toX x: Double, y: Double) {
        let player = players[humanIndex]
        var dx = x - player.motor.x
        var dy = y - player.motor.y
        let distance = hypot(dx, dy)
        if distance > Tuning.maxPassDistance {
            dx *= Tuning.maxPassDistance / distance
            dy *= Tuning.maxPassDistance / distance
        }
        let edgeX = RugbyPitch.boardX - RugbyPitch.metres(1)
        let edgeY = RugbyPitch.boardY - RugbyPitch.metres(1)
        let targetX = min(max(player.motor.x + dx, -edgeX), edgeX)
        let targetY = min(max(player.motor.y + dy, -edgeY), edgeY)
        throwBall(from: humanIndex, toX: targetX, y: targetY, leading: false)
    }

    /// A throw through the air that lands at the target. Flight time is distance over
    /// `passSpeed`, clamped; the launch is then solved so it comes down there. `leading` aims
    /// ahead of a moving receiver by most of the flight.
    private func throwBall(from index: Int, toX: Double, y toY: Double, leading: Bool) {
        var targetX = toX
        var targetY = toY
        var distance = max(hypot(targetX - ball.x, targetY - ball.y), 1)
        var flight = min(max(distance / Tuning.passSpeed, Tuning.minFlight), Tuning.maxFlight)

        if leading, let receiver = players.indices.first(where: {
            hypot(players[$0].motor.x - toX, players[$0].motor.y - toY) < 1
        }) {
            let motor = players[receiver].motor
            targetX += motor.vx * flight * 0.8
            targetY += motor.vy * flight * 0.8
            distance = max(hypot(targetX - ball.x, targetY - ball.y), 1)
            flight = min(max(distance / Tuning.passSpeed, Tuning.minFlight), Tuning.maxFlight)
        }

        let dx = (targetX - ball.x) / distance
        let dy = (targetY - ball.y) / distance
        let horizontal = distance / flight
        // Launched from chest height to land at the ground: solve the drop.
        let drop = ball.z - RugbyPitch.ballRadius
        let vz = (0.5 * Tuning.gravity * flight * flight - drop) / flight

        ball.vx = dx * horizontal
        ball.vy = dy * horizontal
        ball.vz = max(vz, RugbyPitch.metres(1))
        ball.axis = atan2(dy, dx)

        players[index].catchCooldown = Tuning.catchCooldown
        setCarrier(nil)
        playThrowSound(volume: 0.25, rate: 1.2)
        onPresentationChanged?()
    }

    // MARK: - Small measurements

    func distanceBetween(_ a: Int, _ b: Int) -> Double {
        hypot(players[a].motor.x - players[b].motor.x,
              players[a].motor.y - players[b].motor.y)
    }

    func nearestOpponentIndex(to index: Int) -> Int? {
        let team = players[index].team
        var best: Int?
        var bestDistance = Double.infinity
        for other in players.indices where players[other].team != team && !players[other].isDown {
            let distance = distanceBetween(index, other)
            if distance < bestDistance {
                bestDistance = distance
                best = other
            }
        }
        return best
    }

    private func nearestOpponentDistance(to index: Int) -> Double {
        guard let other = nearestOpponentIndex(to: index) else { return .infinity }
        return distanceBetween(index, other)
    }
}
