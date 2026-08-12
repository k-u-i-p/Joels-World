import Foundation
import simd

/// The twenty players: who they are, where they stand, how they decide, and what a kick does.
///
/// Everything positional here is in **team space** rather than world space, and that one idea is
/// what keeps this file half the length it would otherwise be. A slot is written as `(u, v)`
/// where `u` runs from −1 at a team's own goal to +1 at the goal it is attacking, and `v` runs
/// across the pitch. Both teams therefore share a single formation table, a single "push up when
/// we have it" rule and a single "get between the ball and the goal" rule — and red is not a
/// mirrored special case with its own signs to get wrong.
///
/// The AI is deliberately shallow. There is no passing graph, no expected-goals model and no
/// look-ahead: a player asks a handful of questions about the ball, the goal and the nearest
/// opponent, and answers them the same way every time. What makes it look like football is not
/// the cleverness of any one decision, it is that all twenty are asking at once and they are
/// asking about the same ball.
extension FootballGame {

    // MARK: - Building the sides

    /// The shape both teams play, in team space. **Five a side: a keeper, two at the back, one
    /// in the middle and one up top** — 2-1-1, which is what every five-a-side team that has ever
    /// thought about it for ten seconds plays.
    static let formation: [(role: Role, u: Double, v: Double)] = [
        (.keeper, -0.95, 0),
        (.defender, -0.60, -0.42),
        (.defender, -0.60, 0.42),
        (.midfielder, -0.10, 0),
        (.forward, 0.44, 0),
    ]

    /// **Which body wears Joel's own face, and which one the stick starts on.** Centre midfield.
    ///
    /// Note what this is *not*, since control started moving around the team: it is not "the
    /// player you are". You drive whichever blue shirt is nearest the ball — see
    /// `FootballGame.updateControl(dt:)` — and this only decides which pupil on the pitch looks
    /// like the one you walk round the school as, and who has the stick at the first whistle.
    ///
    /// It matters much less than it did, and the history is worth keeping anyway. It was the
    /// centre forward, and that one choice lost blue every match played: a ten-year-old chases
    /// the ball rather than standing on the last defender holding a shape, so blue's
    /// centre-forward slot was permanently empty, blue attacked a striker short, and a measured
    /// match had the ball in blue's half for **82% of it**. Final scores 0–3, 1–3, 0–3. Moved to
    /// midfield, the same bot drew level twice and lost 2–3.
    static let humanSlot = 3

    /// Both sides, blue first, with **you in blue's `humanSlot`** above.
    ///
    /// Everybody who is not you is dressed from the same short list of models rather than from
    /// the map's NPCs, with one exception: your own appearance is kept, so the pupil in the
    /// yellow ring is recognisably the one you walk round the school as. The kit is one field —
    /// `outfit` — because a bought character's clothes are painted into its texture and a kit is
    /// therefore a whole finished texture rather than a colour. See `GameCharacter.outfit`.
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
                    // A map's own NPCs first, so a school that authors a crowd gets its own faces
                    // out on the pitch, and made-up pupils after that.
                    let pool = index + (team == .blue ? 0 : Self.formation.count)
                    appearance = pool < npcs.count
                        ? npcs[pool]
                        : GameCharacter(id: 0, name: nil, width: 40, height: 40)
                    appearance.model = appearance.model ?? models[index]
                }

                appearance.id = 9200 + built.count
                appearance.outfit = team.outfit
                appearance.holding = nil
                appearance.emote = nil
                appearance.default_emote = nil
                appearance.hide_nameplate = true
                appearance.z = 0

                // Everybody outfield on a side is the same pace: the baseline times that side's
                // `Skill.speed`, which is what makes your lot 20% quicker than red. The extra the
                // *player* gets is applied in `steer` to whoever is being driven, not baked into
                // one body — control moves round the team, so the advantage has to move with it.
                let base = slot.role == .keeper ? Tuning.keeperTopSpeed : Tuning.topSpeed
                let topSpeed = base * team.skill.speed

                built.append(Player(appearance: appearance,
                                    team: team,
                                    role: slot.role,
                                    home: SIMD2(slot.u, slot.v),
                                    wearsMyFace: wearsMyFace,
                                    topSpeed: topSpeed))
            }
        }

        players = built
        // Kick off in charge of your own body. From the first whistle `updateControl(dt:)` moves
        // the stick around the team as the ball does.
        takeControl(of: Self.humanSlot)
    }

    // MARK: - Team space

    /// A team-space slot as a point on the pitch.
    ///
    /// The 0.94 and 0.9 keep a formation inside the paint: a defender sitting at `u = −0.95`
    /// would otherwise be standing on his own goal line.
    func worldPoint(u: Double, v: Double, for team: Team) -> SIMD2<Double> {
        SIMD2(team.attackDirection * v * FootballPitch.halfWidth * 0.9,
              team.attackDirection * u * FootballPitch.halfLength * 0.94)
    }

    /// The inverse: where a world point sits in a team's own frame.
    func teamSpace(x: Double, y: Double, for team: Team) -> SIMD2<Double> {
        SIMD2(team.attackDirection * x / FootballPitch.halfWidth,
              team.attackDirection * y / FootballPitch.halfLength)
    }

    /// Where everybody stands for a restart: their own slot, pulled back into their own half —
    /// which is the only rule of a kick-off that matters.
    ///
    /// The striker steps off the centre line as well. Both teams play a midfielder and a striker
    /// down the middle, so pulling everyone back put four players — two of each — on `x = 0`
    /// within a couple of metres of each other, and a kick-off looked like a bus queue.
    ///
    /// **And everybody starts outside the centre circle**, which is a real rule of football and
    /// was the single worst bug this game has had.
    ///
    /// Without it, the defending midfielder's slot put him **3.4 m from the ball, between the
    /// taker and the goal he was running at**. Blue kicks off at the start and after every goal
    /// they concede, so blue kicked off every time, was tackled inside a second every time, and
    /// red attacked from the halfway line every time. The trace is unambiguous and identical at
    /// every restart: `BLUE midfielder (on the ball)` at (0, 0), then one second later
    /// `RED midfielder`, then the ball in blue's half until it goes in. Whole matches ran with
    /// the ball in blue's half for 27 samples out of 29, and the final score was 0–3 three times
    /// running. It read as "red's AI is better"; it was a kick-off nobody could take.
    ///
    /// Pushing radially keeps everyone in the shape they were in, only further out — and the
    /// taker is teleported onto the ball afterwards in `setUpKickoff`, so this applying to their
    /// side too is correct rather than a special case avoided.
    func kickoffSpot(for player: Player) -> SIMD2<Double> {
        let u = min(player.home.x, -0.08)
        let v = player.role == .forward && player.home.y == 0 ? 0.3 : player.home.y
        var spot = worldPoint(u: u, v: v, for: player.team)

        let clearance = FootballPitch.centreCircleRadius + FootballPitch.metres(1.5)
        let distance = hypot(spot.x, spot.y)
        if distance < clearance {
            if distance < 0.001 {
                // Standing exactly on the spot: back off towards their own goal.
                spot = SIMD2(0, -player.team.attackDirection * clearance)
            } else {
                spot *= clearance / distance
            }
        }
        return spot
    }

    // MARK: - One player's frame

    /// What player `index` does this frame. Called for all twenty before any of them move, so
    /// every decision is made against the same world.
    func steer(_ index: Int) {
        let player = players[index]
        let hasBall = carrier == index

        // Two adjustments to pace, in order. **The player you are driving is half a metre a
        // second quicker than the AI** — the one thing a human has over them is choosing where to
        // be, and being marginally faster is what turns that choice into a chance. It follows
        // control rather than living on one body, so handing the stick on hands the legs on too.
        // Then: running with the ball is slower than running without it, which is the whole
        // reason a pass beats a dribble.
        let top = player.isControlled && player.role != .keeper
            ? player.baseSpeed + Tuning.controlSpeedBonus
            : player.baseSpeed
        player.motor.profile.maxSpeed = hasBall ? top * Tuning.dribbleFraction : top

        if player.isControlled {
            steerControlled(player)
            return
        }
        if hasBall {
            steerCarrier(index)
            return
        }
        if player.role == .keeper {
            steerKeeper(index)
            return
        }
        steerOffTheBall(index)
    }

    /// You — whichever blue shirt that is this second. The stick is a direction and a throttle,
    /// handed straight to the motor, the same path the overworld player takes, so running here
    /// feels like running there.
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

    /// The keeper: off the line by a stride, tracking the ball across the goal, and out to
    /// smother anything loose inside the six-yard box.
    private func steerKeeper(_ index: Int) {
        let player = players[index]
        let direction = player.team.attackDirection
        let goalLineY = FootballPitch.ownGoalY(attackDirection: direction)

        // Anything loose and close is worth coming for. `carrier == nil` matters: a keeper who
        // charges out at a striker who has the ball under control just leaves the goal empty.
        // How far into the pitch the ball is, measured from this keeper's own goal line.
        let ballDepth = (ball.y - goalLineY) * direction
        let inTheBox = ballDepth < FootballPitch.sixYardDepth * 1.2
            && abs(ball.x) < FootballPitch.penaltyHalfWidth * 0.8
        if carrier == nil, inTheBox {
            player.motor.moveCharacterTo(x: ball.x, y: ball.y,
                                         targetSpeed: player.motor.profile.maxSpeed)
            return
        }

        // Otherwise: a stride off the line, shading towards whichever post the ball is nearer.
        // Only 0.55 of the way, so a shot into the far corner is a goal — a keeper who mirrors
        // the ball exactly is a keeper nobody scores past.
        let limit = FootballPitch.goalHalfWidth * 1.1
        let targetX = min(max(ball.x * 0.55, -limit), limit)
        let targetY = goalLineY + direction * FootballPitch.metres(1.3)
        player.motor.moveCharacterTo(x: targetX, y: targetY,
                                     targetSpeed: player.motor.profile.maxSpeed)
    }

    /// Everybody on the pitch who is neither you, nor on the ball, nor in goal.
    ///
    /// Three jobs, in order: chase the ball if you are the nearest and it is not ours; run into
    /// space ahead of the carrier if it is; hold your shape otherwise.
    private func steerOffTheBall(_ index: Int) {
        let player = players[index]
        let weHaveIt = carrier.map { players[$0].team == player.team } ?? false

        if !weHaveIt, index == chaser(for: player.team) {
            // Lead the ball rather than running at where it is now — a quarter of a second is
            // about how long it takes to cover the last stride, and a rolling ball moves a long
            // way in that.
            player.motor.moveCharacterTo(x: ball.x + ball.vx * 0.25,
                                         y: ball.y + ball.vy * 0.25,
                                         targetSpeed: player.motor.profile.maxSpeed)
            return
        }

        var target = formationTarget(for: player, weHaveIt: weHaveIt)

        // Somebody has to be available or the carrier has nothing to do but run into people. The
        // two nearest team mates to whoever has it make an angled run ahead of them.
        if weHaveIt, let holder = carrier, holder != index,
           supportRank(of: index, around: holder) < 1 {
            target = supportRun(for: index, around: holder)
        }

        target += separation(for: index)
        player.motor.moveCharacterTo(x: target.x, y: target.y,
                                     targetSpeed: player.motor.profile.maxSpeed)
    }

    /// The AI with the ball. Runs at the goal, goes round the nearest defender, and every
    /// `decisionInterval` asks whether to shoot or pass instead.
    private func steerCarrier(_ index: Int) {
        let player = players[index]

        if player.decisionTimer <= 0 {
            player.decisionTimer = Tuning.decisionInterval
            if decideKick(from: index) { return }
        }

        let direction = player.team.attackDirection
        let goalY = FootballPitch.targetGoalY(attackDirection: direction)

        var target = SIMD2(ball.x * 0.55, goalY)

        // Round the nearest opponent in front rather than through them: push the target sideways,
        // away from whichever side they are on.
        if let blocker = nearestOpponent(to: index) {
            let opponent = players[blocker]
            let ahead = (opponent.motor.y - player.motor.y) * direction
            let across = opponent.motor.x - player.motor.x
            if ahead > 0, ahead < FootballPitch.metres(7), abs(across) < FootballPitch.metres(4) {
                target.x = player.motor.x - (across >= 0 ? 1 : -1) * FootballPitch.metres(7)
            }
        }

        let edge = FootballPitch.halfWidth - FootballPitch.metres(1)
        target.x = min(max(target.x, -edge), edge)

        player.motor.moveCharacterTo(x: target.x, y: target.y,
                                     targetSpeed: player.motor.profile.maxSpeed)
    }

    // MARK: - Positioning

    /// A player's slot, shifted up and down the pitch with the ball. The whole team slides
    /// together, which is what stops a defence standing on its own goal line while the ball is in
    /// the opposite corner.
    private func formationTarget(for player: Player, weHaveIt: Bool) -> SIMD2<Double> {
        let ballSpace = teamSpace(x: ball.x, y: ball.y, for: player.team)

        // A shift up when we have it and back when we do not, on top of following the ball.
        let bias = weHaveIt ? 0.14 : -0.06
        var u = player.home.x + 0.5 * ballSpace.y + bias
        var v = player.home.y * 0.72 + 0.45 * ballSpace.x

        // Nobody camps on either goal line. The upper bound also does the job an offside rule
        // would: a forward who stood permanently on the last defender would make the whole game
        // a series of long balls.
        u = min(max(u, -0.9), 0.82)
        v = min(max(v, -0.95), 0.95)

        return worldPoint(u: u, v: v, for: player.team)
    }

    /// An angled run ahead of the player on the ball — the thing that gives a pass somewhere to
    /// go. Eight metres on, and out to the side the runner is already on.
    private func supportRun(for index: Int, around holder: Int) -> SIMD2<Double> {
        let player = players[index]
        let carrierMotor = players[holder].motor
        let direction = player.team.attackDirection
        let side: Double = player.motor.x >= carrierMotor.x ? 1 : -1

        var target = SIMD2(carrierMotor.x + side * FootballPitch.metres(5.5),
                           carrierMotor.y + direction * FootballPitch.metres(6.5))

        let edgeX = FootballPitch.halfWidth - FootballPitch.metres(1.5)
        let edgeY = FootballPitch.halfLength - FootballPitch.metres(1.5)
        target.x = min(max(target.x, -edgeX), edgeX)
        target.y = min(max(target.y, -edgeY), edgeY)
        return target
    }

    /// How near this player is to the carrier, as a rank among their own side. Cheaper than
    /// sorting, and only the top two are ever asked for.
    private func supportRank(of index: Int, around holder: Int) -> Int {
        let team = players[index].team
        let mine = distanceBetween(index, holder)
        var rank = 0
        for other in players.indices
        where other != index && other != holder && players[other].team == team
            && players[other].role != .keeper {
            if distanceBetween(other, holder) < mine { rank += 1 }
        }
        return rank
    }

    /// A nudge away from team mates standing too close.
    ///
    /// Without it, "run at the ball" and "hold your slot" both pull several players to the same
    /// square metre and the side plays as a clump. This is not collision — nobody is stopped from
    /// walking through anybody — it is a bias on where they *want* to be, which is enough.
    private func separation(for index: Int) -> SIMD2<Double> {
        let player = players[index]
        let reach = FootballPitch.metres(3.2)
        var push = SIMD2<Double>.zero

        for other in players.indices
        where other != index && players[other].team == player.team {
            let dx = player.motor.x - players[other].motor.x
            let dy = player.motor.y - players[other].motor.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance > 0.001, distance < reach else { continue }
            let strength = (reach - distance) / reach
            push += SIMD2(dx / distance, dy / distance) * strength * FootballPitch.metres(2.4)
        }
        return push
    }

    /// Which player on a team is going for the ball: the nearest outfielder, and **one and only
    /// one**, so the rest can get on with holding their shape.
    ///
    /// The one subtlety is what to do about the player you are driving, and both obvious answers
    /// are wrong in a measurable way.
    ///
    /// *Always count you*: back when the stick was bolted to one midfielder, any moment you were
    /// nearest the ball while running somewhere else left blue with nobody going for it. Red,
    /// whose whole side is AI, took the ball and kept it — worth about two goals a match.
    ///
    /// *Never count you*: fine while the stick was bolted to a midfielder, ruinous once control
    /// started following the ball. You are now, by construction, almost always the nearest — so
    /// blue sent the second nearest **as well**, permanently committed two players to the ball,
    /// and defended its own box with three. A measured match after the pitch grew had the ball in
    /// blue's half for 97 samples out of 102 and finished 0–3.
    ///
    /// So: nobody else is sent while you are genuinely closing the ball down, and the moment you
    /// are not — you have run off, or control has just jumped to somebody further away — cover
    /// goes back on. `closingRange` is what "genuinely" means.
    private func chaser(for team: Team) -> Int? {
        let closingRange = FootballPitch.metres(7)

        var best: Int?
        var bestDistance = Double.infinity
        var youAreClosing = false

        for index in players.indices
        where players[index].team == team && players[index].role != .keeper {
            let distance = hypot(players[index].motor.x - ball.x,
                                 players[index].motor.y - ball.y)
            if players[index].isControlled {
                youAreClosing = distance < closingRange
                continue
            }
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }

        return youAreClosing ? nil : best
    }

    // MARK: - Deciding to kick

    /// The AI carrier's one decision. Returns true if it kicked, in which case it is no longer
    /// carrying and this frame's steering is somebody else's problem.
    private func decideKick(from index: Int) -> Bool {
        let player = players[index]

        // A keeper never dribbles. They hold it for the moment `take(by:)` gives them and then
        // hoof it upfield, which is what a ten-year-old keeper does and is also correct.
        if player.role == .keeper {
            clear(from: index)
            return true
        }

        let direction = player.team.attackDirection
        let goal = SIMD2(0.0, FootballPitch.targetGoalY(attackDirection: direction))
        let goalDistance = hypot(goal.x - player.motor.x, goal.y - player.motor.y)

        let pressed = nearestOpponentDistance(to: index) < FootballPitch.metres(2.6)

        // How far out this side is willing to shoot from. Red walk it in; see `Skill`.
        let reach = player.team.skill.shootRange
        if goalDistance < Tuning.pointBlankRange * reach
            || (goalDistance < Tuning.shootRange * reach
                && !laneBlocked(from: index, toX: goal.x, toY: goal.y)) {
            shoot(from: index)
            return true
        }

        if let target = bestPassTarget(from: index) {
            // Under pressure, take any pass going. In space, only a clearly good one — otherwise
            // the ball never settles and the match is twenty players hot-potatoing.
            if target.score > (pressed ? -0.2 : 0.95) {
                pass(from: index, to: target.index)
                return true
            }
        }

        // Nothing on and somebody breathing down your neck: put it in the corner and chase it.
        if pressed, random.unit() < 0.25 {
            clear(from: index)
            return true
        }

        return false
    }

    /// The best team mate to give it to, scored on: does it gain ground, are they in space, is
    /// the lane clear, and is it too far. Plus a thumb on the scale for **you**, because a team
    /// that never passes to the person holding the phone is not much of a team.
    private func bestPassTarget(from index: Int) -> (index: Int, score: Double)? {
        let player = players[index]
        let mine = teamSpace(x: player.motor.x, y: player.motor.y, for: player.team)

        var best: (index: Int, score: Double)?

        for other in players.indices
        where other != index && players[other].team == player.team
            && players[other].role != .keeper {
            let mate = players[other]
            let distance = distanceBetween(index, other)
            guard distance > FootballPitch.metres(3.5),
                  distance < FootballPitch.metres(26) else { continue }

            let theirs = teamSpace(x: mate.motor.x, y: mate.motor.y, for: player.team)
            var score = (theirs.y - mine.y) * 2.2

            let openness = min(nearestOpponentDistance(to: other) / FootballPitch.metres(5), 1)
            score += openness * 0.9

            if laneBlocked(from: index, toX: mate.motor.x, toY: mate.motor.y) { score -= 1.4 }
            score -= max(0, distance - FootballPitch.metres(14)) / FootballPitch.metres(14) * 0.7

            // **There is deliberately no bonus for passing to the player you are driving.**
            //
            // There used to be, and it was right when the stick was bolted to one midfielder: a
            // team that never passes to the person holding the phone is not much of a team. Once
            // control started following the ball it inverted into a bug that only blue suffered
            // from — the player you are driving is by construction the one *nearest the ball*,
            // which is usually the shortest and most backwards pass on the pitch, and blue spent
            // whole matches recycling it sideways in its own half. Removing it took blue from
            // two samples out of twenty-six in red's half back to an even game.
            //
            // It costs nothing, either, because auto-switching already solves what the bonus was
            // for: every pass is a pass to you, the moment it arrives.

            if score > (best?.score ?? -.infinity) { best = (other, score) }
        }
        return best
    }

    /// Is somebody standing in the way? A pass is blocked if an opponent is within a stride and a
    /// half of the line it would travel along, and actually between the two ends of it.
    private func laneBlocked(from index: Int, toX: Double, toY: Double) -> Bool {
        let player = players[index]
        let dx = toX - player.motor.x
        let dy = toY - player.motor.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1 else { return false }

        for other in players.indices where players[other].team != player.team {
            // The keeper standing on his line does not count as blocking a shot — beating him is
            // the point, and counting him would mean the AI never shoots at all.
            if players[other].role == .keeper { continue }

            let ox = players[other].motor.x - player.motor.x
            let oy = players[other].motor.y - player.motor.y
            let along = (ox * dx + oy * dy) / lengthSquared
            guard along > 0.05, along < 0.95 else { continue }

            let acrossX = ox - dx * along
            let acrossY = oy - dy * along
            if (acrossX * acrossX + acrossY * acrossY).squareRoot() < FootballPitch.metres(1.7) {
                return true
            }
        }
        return false
    }

    // MARK: - Kicks

    /// **Your kick.** Near enough the goal and it is a shot; otherwise it goes to the nearest
    /// team mate, which is the rule Joel asked for and the reason the button needs no aiming.
    func kickFromHuman() {
        let player = players[humanIndex]
        let goalY = FootballPitch.targetGoalY(attackDirection: player.team.attackDirection)
        let goalDistance = hypot(player.motor.x, goalY - player.motor.y)

        if goalDistance < Tuning.shootRange {
            shoot(from: humanIndex)
            return
        }

        if let mate = nearestTeammate(to: humanIndex) {
            pass(from: humanIndex, to: mate)
        } else {
            shoot(from: humanIndex)
        }
    }

    /// The nearest team mate, keeper excluded — a pass back to your own keeper from the halfway
    /// line is not what anyone pressing a button labelled KICK is asking for.
    private func nearestTeammate(to index: Int) -> Int? {
        let team = players[index].team
        var best: Int?
        var bestDistance = Double.infinity
        for other in players.indices
        where other != index && players[other].team == team && players[other].role != .keeper {
            let distance = distanceBetween(index, other)
            if distance < bestDistance {
                bestDistance = distance
                best = other
            }
        }
        return best
    }

    /// A pass, weighted against the grass and aimed where the receiver is **going**.
    ///
    /// **The weight is solved, not guessed**, and this is the single most important number in the
    /// game. The obvious version — launch at `distance / someTime` — ignores friction entirely,
    /// and with friction in the physics it overshoots by a factor of three: an eight-metre ball
    /// to a midfielder left the pitch at 14 m/s and rolled twenty-five metres past him into his
    /// own penalty area, every single time. A rolling ball decelerating at `a` covers
    /// `(v² − v_end²) / 2a`, so the launch speed that *arrives* is
    /// `√(v_end² + 2·a·d)` — which is what this solves, twice, because the second pass over it
    /// knows how long the ball will be travelling and can lead the receiver by that much.
    private func pass(from index: Int, to receiver: Int) {
        let target = players[receiver].motor
        let arrival = Tuning.passArrivalSpeed
        let deceleration = Tuning.rollFriction

        func weight(toX: Double, toY: Double) -> (speed: Double, time: Double,
                                                  dx: Double, dy: Double, distance: Double) {
            let dx = toX - ball.x
            let dy = toY - ball.y
            let distance = max(hypot(dx, dy), 1)
            let solved = (arrival * arrival + 2 * deceleration * distance).squareRoot()
            let speed = min(max(solved, Tuning.minPassSpeed), Tuning.maxPassSpeed)
            return (speed, max(0, (speed - arrival) / deceleration), dx, dy, distance)
        }

        // First pass: how long a ball to where they are standing would take. Second: where they
        // will be by then. Leading at 0.8 rather than 1.0 because a receiver who is about to turn
        // is better served by a ball slightly behind than one slightly in front.
        let flight = weight(toX: target.x, toY: target.y).time
        let aimed = weight(toX: target.x + target.vx * flight * 0.8,
                           toY: target.y + target.vy * flight * 0.8)

        launch(from: index,
               vx: aimed.dx / aimed.distance * aimed.speed,
               vy: aimed.dy / aimed.distance * aimed.speed,
               vz: 0,
               rate: 1.05)
    }

    /// A shot. Aimed at the goal with a spread that depends on how far out it is — close in it
    /// goes where it is meant to, from range it is a hopeful thump, which is exactly the right
    /// way round.
    private func shoot(from index: Int) {
        let player = players[index]
        let goalY = FootballPitch.targetGoalY(attackDirection: player.team.attackDirection)
        let distance = max(hypot(ball.x, goalY - ball.y), 1)

        // Aim inside the post rather than at the middle: a shot at the middle is a shot at the
        // keeper, who is standing in the middle.
        //
        // **The mouth is narrower than the goal**, because `checkGoal` wants the whole ball
        // inside it and the ball is a beach ball — see `FootballPitch.ballRadius`. Aiming at
        // `goalHalfWidth` would put a good half of every shot against the inside of the post.
        let mouth = max(FootballPitch.goalHalfWidth - FootballPitch.ballRadius,
                        FootballPitch.metres(0.5))
        let side: Double = ball.x >= 0 ? -1 : 1
        var aimX = side * mouth * 0.62
        let spread = FootballPitch.metres(1.2) * (distance / Tuning.shootRange)
            * player.team.skill.shotSpread
        aimX += random.signed() * spread
        aimX = min(max(aimX, -mouth * 0.9), mouth * 0.9)

        let dx = aimX - ball.x
        let dy = goalY - ball.y
        let length = max(hypot(dx, dy), 1)

        launch(from: index,
               vx: dx / length * Tuning.shotSpeed,
               vy: dy / length * Tuning.shotSpeed,
               vz: Tuning.shotLift * (0.6 + random.unit() * 0.8),
               rate: 0.85)
    }

    /// A hoof upfield. What a keeper does with it, and what anybody does when there is nothing on.
    private func clear(from index: Int) {
        let player = players[index]
        let direction = player.team.attackDirection
        let aimX = min(max(player.motor.x + random.signed() * FootballPitch.metres(12),
                           -FootballPitch.halfWidth * 0.8), FootballPitch.halfWidth * 0.8)
        let aimY = direction * FootballPitch.halfLength * 0.25

        let dx = aimX - ball.x
        let dy = aimY - ball.y
        let length = max(hypot(dx, dy), 1)

        launch(from: index,
               vx: dx / length * Tuning.clearanceSpeed,
               vy: dy / length * Tuning.clearanceSpeed,
               vz: Tuning.clearanceLift,
               rate: 0.7)
    }

    /// The one place the ball actually leaves somebody's boot. Every kick above ends here, so
    /// there is one definition of "the ball is loose again" rather than four.
    private func launch(from index: Int, vx: Double, vy: Double, vz: Double, rate: Double) {
        ball.vx = vx
        ball.vy = vy
        ball.vz = vz
        // Only a lofted kick leaves the ground. A pass that was nudged into the air here would
        // stop obeying `rollFriction` for the first tenth of a second, which is exactly the
        // friction the weight above was solved against.
        if vz > 0 { ball.z = max(ball.z, FootballPitch.ballRadius * 1.5) }

        players[index].kickCooldown = Tuning.kickCooldown
        setCarrier(nil)
        playKickSound(volume: 0.3, rate: rate)
        onPresentationChanged?()
    }

    // MARK: - Small measurements

    func distanceBetween(_ a: Int, _ b: Int) -> Double {
        hypot(players[a].motor.x - players[b].motor.x,
              players[a].motor.y - players[b].motor.y)
    }

    private func nearestOpponent(to index: Int) -> Int? {
        let team = players[index].team
        var best: Int?
        var bestDistance = Double.infinity
        for other in players.indices where players[other].team != team {
            let distance = distanceBetween(index, other)
            if distance < bestDistance {
                bestDistance = distance
                best = other
            }
        }
        return best
    }

    private func nearestOpponentDistance(to index: Int) -> Double {
        guard let other = nearestOpponent(to: index) else { return .infinity }
        return distanceBetween(index, other)
    }
}
