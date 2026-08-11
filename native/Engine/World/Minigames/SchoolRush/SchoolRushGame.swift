import Foundation
import simd

/// **School Rush** — an endless runner down a school path, in the style of Minion Rush.
///
/// You run forwards on your own and you never stop. Three lanes; swipe left and right to change
/// lane, swipe up to jump. Bags, cones and bins can be jumped; pupils standing about and parked
/// cars cannot, so those are a lane change and nothing else. Coins are worth collecting. Three
/// hits and the run is over, and getting past `Tuning.badgeDistance` metres earns the School
/// Rush badge.
///
/// The one structural difference from tennis, which shapes everything below: **a runner has no
/// static world.** A tennis court is eighty primitives built once. Here the ground, the hedges,
/// the buildings and the obstacles are all generated from where the player is, a chunk at a
/// time, and thrown away once they are behind. `SchoolRushTrack` holds the geometry; this file
/// holds the run.
///
/// The player really does travel down decreasing Y rather than standing still while the world
/// slides past. That costs nothing — the numbers stay small enough for a float for well over an
/// hour of running — and it buys the whole of `CharacterMotor` for free: the legs run because
/// the body is actually moving, the jump is a real projectile, and the side-step when you change
/// lane is the same side-step the tennis players use.
final class SchoolRushGame: WorldRenderedMinigame {

    // MARK: - Tuning

    enum Tuning {
        /// A jog to begin with. Fast enough to feel like running, slow enough to learn on.
        static let startSpeed = SchoolRushTrack.metres(7.5)
        /// Flat out, reached at about 600 m.
        static let topSpeed = SchoolRushTrack.metres(14)
        /// How much of that gap is closed per metre run.
        static let speedGain = (topSpeed - startSpeed) / SchoolRushTrack.metres(600)

        /// Sideways speed during a lane change, as a fraction of the forward speed. A lane is
        /// 1.75 m, so at 0.55 of a 9 m/s run a change takes about a third of a second — quick
        /// enough to be a reaction rather than a plan.
        ///
        /// It is also, indirectly, **how hard the legs look like they are working**. The motor
        /// caps a demand at `profile.maxSpeed`, so the profile has to be big enough to hold a
        /// full-pace run and a full-speed swerve at once — and `Gait.intensity` is speed measured
        /// against that same cap. At 0.8 the runner was permanently at 78% of their own top speed
        /// and jogged; at 0.55 they are at 88% and sprint.
        static let lateralFraction = 0.55
        /// How hard the runner is pulled towards the middle of the lane they picked, per second.
        static let laneGain = 9.0

        /// The jump, as a launch speed and a gravity rather than a drawn arc — the same way the
        /// overworld jump works.
        ///
        /// **These two numbers are set by the car**, because "you can jump over everything except
        /// people" is the rule and a car is the biggest thing you have to get over. A car is
        /// 3.9 m long and 1.42 m to the roof; add the runner's own depth and 10 cm of clearance
        /// and the feet have to stay above 1.52 m for about 4.5 m of ground. At a mid-run pace of
        /// 10 m/s that is 0.45 s spent above 1.52 m, which needs an apex of
        /// `1.52 + g·(0.45/2)² / 2` — a shade over 2.3 m. At 2.6 m there is margin at the slower
        /// pace cars start appearing at, and the whole jump lasts 0.83 s.
        ///
        /// It is a cartoon leap, and it is meant to be: this is a game about a ten-year-old
        /// vaulting a parked car on the way out of school.
        ///
        /// **And then Joel asked for it a quarter higher again**, so the apex is 3.25 m rather
        /// than 2.6. Height goes as the *square* of the launch speed, so a quarter more height is
        /// only √1.25 — about 12% — more speed: 12.5 m/s became 14.0. The whole jump now lasts
        /// 0.93 s and covers about nine metres of ground at a mid-run pace.
        static let gravity = SchoolRushTrack.metres(30)
        static let jumpSpeed = SchoolRushTrack.metres(14)

        /// How big the runner is for the purposes of hitting something.
        static let bodyHalfWidth = SchoolRushTrack.metres(0.32)
        static let bodyHalfDepth = SchoolRushTrack.metres(0.30)
        /// How far above an obstacle's top the feet have to be to have cleared it. Slightly
        /// generous, because clipping the very top of a bin and being stopped dead reads as the
        /// game cheating.
        static let clearance = SchoolRushTrack.metres(0.10)

        /// How close a coin has to be to be collected.
        static let coinReach = SchoolRushTrack.metres(0.75)
        static let coinVerticalReach = SchoolRushTrack.metres(1.0)

        /// Hits before the run ends.
        static let lives = 3
        /// How long after a hit you cannot be hit again, and how long the runner flashes for.
        static let invulnerable: Double = 1.5
        /// What a hit does to the pace, as a fraction of the speed you were running at.
        static let hitSpeedFactor = 0.4
        /// How fast the pace eases back to full — and how fast it eases up from a standing start
        /// at the beginning of a run.
        static let speedRecovery = 1.9

        /// One piece of generated track. Every obstacle in a chunk sits at the same distance, so
        /// each one reads as a single wall with a gap in it rather than a scatter.
        static let chunkLength = SchoolRushTrack.metres(11)
        /// Nothing at all before here, so a run always starts with somewhere to look.
        static let warmUpDistance: Double = 32
        /// How far ahead chunks are generated. Comfortably past `drawAhead`.
        static let generateAhead = SchoolRushTrack.metres(120)

        /// **Every ten coins makes the jump one per cent higher**, which is Joel's rule and the
        /// only thing coins do besides count.
        ///
        /// It is a *height* percentage, not a speed one, and those are not the same number:
        /// height goes as the square of the launch speed, so the speed is multiplied by the
        /// square root of the boost. Getting that backwards would make a hundred coins worth
        /// twice as much as asked for.
        static let jumpBoostPerCoins = 10
        /// A ceiling at +100%, which is a thousand coins. Nobody has been near it and it is not
        /// meant to be reachable — it is there so a very long run cannot end up jumping over the
        /// whole course.
        static let maxJumpBoostSteps = 100

        /// The run that earns the badge.
        static let badgeDistance: Double = 400
        static let badgeId = "school rush"
    }

    // MARK: - State

    enum Phase {
        /// The first second and a bit, while the banner says GO and the pace winds up.
        case running
        /// Out of lives. The runner brakes to a halt and the panel comes up.
        case over
    }

    private(set) var phase: Phase = .running

    /// Everything about how the runner moves — the same motor the overworld player and both
    /// tennis players use.
    let motor = CharacterMotor(profile: LocomotionProfile(
        maxSpeed: Tuning.topSpeed,
        acceleration: SchoolRushTrack.metres(45),
        braking: SchoolRushTrack.metres(30),
        turnRate: 720,
        strideLength: SchoolRushTrack.metres(2.4),
        lean: 1,
        // Low, because the runner is never asked to walk: everything from the first stride on is
        // meant to read as a sprint. See the note on `Tuning.lateralFraction`.
        runThreshold: 0.15))

    private var appearance: GameCharacter

    /// Which lane the runner is heading for. The body eases across rather than snapping, so this
    /// and where they actually are disagree for a quarter of a second after every swipe.
    private(set) var lane = 1

    /// Pace as a fraction of what the distance says it should be. Starts at zero so a run winds
    /// up rather than launching, and is knocked back down by every hit.
    private var speedScale: Double = 0

    private(set) var lives = Tuning.lives
    private(set) var coins = 0
    /// Seconds of grace left after a hit.
    private(set) var invulnerability: Double = 0
    /// Total time on this run, which is what the flashing after a hit is measured against.
    private var elapsed: Double = 0

    /// How many coins have been collected without a gap, and how long since the last one. Only
    /// the pickup sound reads them — see `checkCoins`.
    private var coinChain = 0
    private var timeSinceCoin: Double = 0

    private var obstacles: [Obstacle] = []
    private var coinsOnTrack: [SchoolRushTrack.Coin] = []
    /// The next chunk of track to generate. Chunk `n` covers the metres from `n × chunkLength`.
    private var nextChunk = 0
    /// Re-seeded at the start of every run from the run counter, so a run is reproducible while
    /// two runs in a row are not the same course.
    private var random = DeterministicRandom(seed: 1)
    private var runNumber = 0

    /// Set once the badge has been claimed this run, so passing 400 m does not claim it again on
    /// every subsequent frame.
    private var badgeClaimed = false

    /// One obstacle on the track. `SchoolRushTrack.Obstacle` holds everything about *what* it is;
    /// this adds the two things only the run knows.
    private struct Obstacle {
        var body: SchoolRushTrack.Obstacle
        /// True once it has been run into, so a single bin cannot cost two lives.
        var consumed = false
        /// Which of the pupil appearances this one wears, for `kind == .pupil`.
        var pupilIndex = 0
    }

    /// The pupils standing in the way, built once. A small pool rather than a fresh character per
    /// obstacle because the renderer keeps rig state per character id — a new id for every pupil
    /// on a ten-minute run is a lot of rigs to build and throw away.
    private var pupilPool: [GameCharacter] = []
    private var pupilCounter = 0

    /// The banner text. Same shape as the tennis one and for the same reason: something has to
    /// say GO, say OUCH, and say when a badge has been won.
    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
    }

    private(set) var announcement: Announcement?

    /// Raised whenever something the HUD shows changes, so it can refresh without polling.
    var onPresentationChanged: (() -> Void)?

    unowned let host: MinigameHost
    private var active = false

    /// Where the camera is looking across the track, eased rather than snapped to the lane.
    private var cameraX: Double = 0
    private var cameraSettled = false

    // MARK: - Numbers the HUD reads

    /// How far this run has gone, in metres. The score.
    var distance: Double { max(0, SchoolRushTrack.metresTravelled(fromY: motor.y)) }

    /// The best run so far, remembered between sessions.
    private(set) var best: Double = SchoolRushGame.storedBest

    private static let bestKey = "schoolrush.best"
    private static var storedBest: Double { UserDefaults.standard.double(forKey: bestKey) }

    /// How fast the runner is going right now, in metres per second — for the HUD's speedometer.
    var speedInMetresPerSecond: Double { motor.speed / SchoolRushTrack.unitsPerMetre }

    /// How much higher than standard the jump is, as a fraction — 0.07 is "seven per cent
    /// higher". Earned a percent at a time, ten coins each. See `Tuning.jumpBoostPerCoins`.
    var jumpBoost: Double {
        0.01 * Double(min(coins / Tuning.jumpBoostPerCoins, Tuning.maxJumpBoostSteps))
    }

    // MARK: - Lifecycle

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host

        var mine = myCharacter ?? GameCharacter(id: 1, name: "You", width: 40, height: 40,
                                                gender: "male", shirt_color: "#2ecc71")
        mine.holding = nil
        mine.emote = nil
        mine.default_emote = nil
        mine.hide_nameplate = true
        appearance = mine

        motor.model = mine.model
        motor.gravity = Tuning.gravity

        pupilPool = Self.buildPupils(from: npcs, avoiding: mine.id)
    }

    /// The people in the way. Any NPC the map happens to carry is used first, so a school that
    /// authors its own crowd gets it; the rest are made up here.
    private static func buildPupils(from npcs: [GameCharacter], avoiding playerId: Int) -> [GameCharacter] {
        let models = ["boy", "girl", "stylized_boy", "girl", "boy", "man", "woman", "girl"]
        let outfits = ["red", "blue", "green", "yellow", "ginger", "blue", "green", "red"]

        return (0..<8).map { index in
            var pupil = index < npcs.count ? npcs[index]
                : GameCharacter(id: 0, name: nil, width: 40, height: 40)
            pupil.id = 9100 + index
            if pupil.id == playerId { pupil.id += 100 }
            pupil.model = pupil.model ?? models[index]
            pupil.outfit = pupil.outfit ?? outfits[index]
            pupil.holding = nil
            pupil.emote = nil
            pupil.default_emote = nil
            pupil.hide_nameplate = true
            // Facing +Y is facing the camera, which is also facing whoever is running at them.
            pupil.rotation = 90
            pupil.z = 0
            return pupil
        }
    }

    func start() {
        active = true
        Log.world("[SchoolRush] Starting — badge at \(Int(Tuning.badgeDistance)) m")
        beginRun()
        host.minigamePlayBackground(path: "/media/playground_sound_effect.mp3", volume: 0.22)
    }

    /// Everything a fresh run resets. Called by `start()` and by the Run again button, which is
    /// why it is separate from either.
    private func beginRun() {
        runNumber += 1
        random.reseed(0x5C_400_1 &+ UInt64(runNumber) &* 7919)

        motor.teleport(x: SchoolRushTrack.laneX(1), y: 0, z: 0, facing: 270)
        motor.driveCharacter(velocityX: 0, velocityY: 0, facing: 270)
        lane = 1
        speedScale = 0
        lives = Tuning.lives
        coins = 0
        invulnerability = 0
        elapsed = 0
        obstacles.removeAll()
        coinsOnTrack.removeAll()
        nextChunk = 0
        pupilCounter = 0
        badgeClaimed = false
        best = Self.storedBest
        phase = .running
        cameraSettled = false

        coinChain = 0
        timeSinceCoin = 0

        announce("GO!", subtitle: "Swipe to dodge · swipe up to jump", duration: 1.8)
        // A school bell to start a race out of school. It is nine seconds long, which is exactly
        // right for one at the start of a run and would have been a disaster anywhere else.
        host.minigamePlayEffect(path: "/media/school_bell.mp3", volume: 0.30)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        obstacles.removeAll()
        coinsOnTrack.removeAll()
        host.minigameSetFootsteps(active: false, isRunning: false)
        host.minigameStopBackground()
    }

    /// The exit button in the button bar.
    func requestExit() {
        host.minigameShowDialog("Stop running and head back to school?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    /// The Run again button on the game-over panel.
    func restartRun() {
        guard active else { return }
        beginRun()
    }

    // MARK: - Input

    /// A swipe left or right, or a tap on that side of the screen. Both mean the same thing.
    func changeLane(by delta: Int) {
        guard active, phase == .running else { return }
        let wanted = min(max(lane + delta, 0), SchoolRushTrack.laneCount - 1)
        guard wanted != lane else { return }
        lane = wanted
    }

    /// A swipe up. Ignored in the air, which is what stops a flurry of swipes from flying.
    func jump() {
        guard active, phase == .running else { return }
        // Height scales as the square of the launch speed, so a boost stated as a percentage of
        // *height* becomes its square root here.
        if motor.jump(speed: Tuning.jumpSpeed * (1 + jumpBoost).squareRoot()) {
            host.minigamePlayEffect(path: "/media/jump.mp3", volume: 0.35)
        }
    }

    // MARK: - Frame

    func update(dt: Double) {
        guard active else { return }

        elapsed += dt
        if invulnerability > 0 { invulnerability = max(0, invulnerability - dt) }

        // A chain of coins is a chain only while they keep arriving.
        timeSinceCoin += dt
        if timeSinceCoin > 1.2 { coinChain = 0 }

        if var current = announcement {
            current.remaining -= dt
            if current.remaining <= 0 {
                announcement = nil
                onPresentationChanged?()
            } else {
                announcement = current
            }
        }

        stepRunner(dt: dt)

        if phase == .running {
            generateTrackAhead()
            pruneBehind()
            checkCoins()
            checkObstacles()
            checkBadge()
        }
    }

    /// The runner: pace, lane and the motor step.
    private func stepRunner(dt: Double) {
        // One variable does two jobs — winding the pace up at the start of a run, and winding it
        // back after a hit — because they are the same thing seen from different starting points.
        let target: Double = phase == .running ? 1 : 0
        speedScale += (target - speedScale) * (1 - exp(-Tuning.speedRecovery * dt))

        let paceFromDistance = min(Tuning.topSpeed,
                                   Tuning.startSpeed + distance * SchoolRushTrack.unitsPerMetre
                                       * Tuning.speedGain)
        let forward = paceFromDistance * speedScale
        let maxLateral = paceFromDistance * Tuning.lateralFraction

        // The demand is clipped to `profile.maxSpeed` before it is used, so the profile has to be
        // able to hold a full-pace run *and* a full-speed lane change at the same time. Without
        // this the runner slows down every time they swerve, which reads as the swerve being
        // punished.
        motor.profile.maxSpeed = (forward * forward + maxLateral * maxLateral).squareRoot() + 1

        let wanted = SchoolRushTrack.laneX(lane)
        let lateral = min(max((wanted - motor.x) * Tuning.laneGain, -maxLateral), maxLateral)

        if phase == .running {
            // Facing is pinned down the track rather than left to follow the velocity, so a lane
            // change is a side-step at full pace and not a turn.
            motor.driveCharacter(velocityX: lateral, velocityY: -forward, facing: 270)
        } else {
            motor.holdPosition()
            motor.faceTowards(270)
        }

        let edge = SchoolRushTrack.pathHalfWidth - Tuning.bodyHalfWidth
        motor.step(dt: dt) { proposedX, proposedY in
            (x: min(max(proposedX, -edge), edge), y: proposedY)
        }

        // Feet on the ground make a noise; feet in the air do not. The overworld drives this off
        // its own player, who is standing still in a car park somewhere while this is on screen,
        // so the minigame has to ask for it. `GameAudio.setWalking` already ignores a repeat, so
        // calling it every frame is what the overworld does too.
        host.minigameSetFootsteps(active: !motor.isAirborne && motor.speed > 1, isRunning: true)
    }

    // MARK: - Generating the track

    /// Builds chunks until there are enough of them ahead of the runner.
    ///
    /// Each chunk is one row of obstacles at a single distance with **at least one lane left
    /// open**, plus some coins. That is the whole design of the course: a wall with a gap in it,
    /// arriving faster and faster.
    private func generateTrackAhead() {
        let horizon = distance * SchoolRushTrack.unitsPerMetre + Tuning.generateAhead

        while Double(nextChunk) * Tuning.chunkLength < horizon {
            generateChunk(nextChunk)
            nextChunk += 1
        }
    }

    private func generateChunk(_ chunk: Int) {
        let chunkStart = Double(chunk) * Tuning.chunkLength
        let metresIn = chunkStart / SchoolRushTrack.unitsPerMetre
        guard metresIn >= Tuning.warmUpDistance else { return }

        // Where in the chunk the row sits. Jittered, so the rhythm is not a metronome.
        let offset = SchoolRushTrack.metres(3) + random.unit() * (Tuning.chunkLength
                                                                 - SchoolRushTrack.metres(6))
        let rowY = -(chunkStart + offset)

        // How many lanes are blocked. One for the first hundred metres; after that a second lane
        // appears more and more often. Never three — there is always a way through.
        var blocked = 1
        if metresIn > 110 && random.unit() < 0.45 { blocked = 2 }
        if metresIn > 260 && random.unit() < 0.45 { blocked = 2 }

        var lanes = [0, 1, 2]
        // Fisher–Yates, so which lanes get blocked is uniform rather than biased towards the
        // middle the way "pick two at random and hope they differ" is.
        for index in stride(from: lanes.count - 1, to: 0, by: -1) {
            let swap = Int(random.unit() * Double(index + 1))
            lanes.swapAt(index, min(swap, index))
        }
        let blockedLanes = Array(lanes.prefix(blocked))
        let freeLanes = lanes.dropFirst(blocked)

        var jumpableLane: Int?
        for blockedLane in blockedLanes {
            let kind = pickKind(metresIn: metresIn)
            var body = SchoolRushTrack.Obstacle(kind: kind,
                                                x: SchoolRushTrack.laneX(blockedLane),
                                                y: rowY,
                                                lane: blockedLane)
            // A car is four metres long, so its centre goes further up the track than a bin's —
            // otherwise its nose arrives a full car-length before the row it belongs to.
            if kind == .car { body.y = rowY - SchoolRushTrack.metres(1.4) }

            var obstacle = Obstacle(body: body)
            if kind == .pupil {
                obstacle.pupilIndex = pupilCounter % pupilPool.count
                pupilCounter += 1
            }
            obstacles.append(obstacle)

            if SchoolRushTrack.Obstacle.isJumpable(kind) { jumpableLane = blockedLane }
        }

        // Coins. Usually a line down a lane you can just run along; sometimes an arc over
        // something you have to jump, which is the only thing in the game that rewards jumping
        // when a side-step would also have worked.
        if let jumpableLane, random.unit() < 0.45 {
            appendCoinArc(lane: jumpableLane, centreY: rowY)
        } else if let coinLane = freeLanes.randomElement(using: &random) {
            appendCoinLine(lane: coinLane, startY: rowY - SchoolRushTrack.metres(1.5))
        }
    }

    /// Which obstacle goes in a lane. Bags and cones early, everything by two hundred metres —
    /// so the first minute teaches "jump" before it starts insisting on "dodge".
    private func pickKind(metresIn: Double) -> SchoolRushTrack.Obstacle.Kind {
        let roll = random.unit()
        if metresIn < 80 {
            return roll < 0.55 ? .bag : .cone
        }
        if metresIn < 200 {
            if roll < 0.30 { return .bag }
            if roll < 0.50 { return .cone }
            if roll < 0.70 { return .bin }
            return .pupil
        }
        if roll < 0.20 { return .bag }
        if roll < 0.35 { return .cone }
        if roll < 0.55 { return .bin }
        if roll < 0.78 { return .pupil }
        return .car
    }

    private func appendCoinLine(lane: Int, startY: Double) {
        let x = SchoolRushTrack.laneX(lane)
        for step in 0..<5 {
            coinsOnTrack.append(SchoolRushTrack.Coin(
                x: x,
                y: startY - Double(step) * SchoolRushTrack.metres(1.6),
                z: SchoolRushTrack.metres(0.95)))
        }
    }

    /// Five coins along the arc a jump actually follows, so collecting the top one is only
    /// possible if the jump was timed right.
    private func appendCoinArc(lane: Int, centreY: Double) {
        let x = SchoolRushTrack.laneX(lane)
        let heights = [0.75, 1.20, 1.45, 1.20, 0.75]
        for (step, height) in heights.enumerated() {
            coinsOnTrack.append(SchoolRushTrack.Coin(
                x: x,
                y: centreY + SchoolRushTrack.metres(2.4) - Double(step) * SchoolRushTrack.metres(1.2),
                z: SchoolRushTrack.metres(height)))
        }
    }

    /// Drops everything the runner has gone past. Without this a long run accumulates every
    /// obstacle it ever saw and the frame spends its time drawing a school two kilometres behind.
    private func pruneBehind() {
        let cutoff = motor.y + SchoolRushTrack.metres(12)
        obstacles.removeAll { $0.body.y > cutoff }
        coinsOnTrack.removeAll { $0.y > cutoff || $0.collected }
    }

    // MARK: - Hitting things

    private func checkObstacles() {
        guard invulnerability <= 0 else { return }

        for index in obstacles.indices where !obstacles[index].consumed {
            let body = obstacles[index].body
            guard abs(motor.x - body.x) < body.halfWidth + Tuning.bodyHalfWidth,
                  abs(motor.y - body.y) < body.halfDepth + Tuning.bodyHalfDepth
            else { continue }
            // Over the top of it is not a hit. This is the whole of what jumping is for.
            guard motor.z < body.top - Tuning.clearance else { continue }

            obstacles[index].consumed = true
            takeHit()
            return
        }
    }

    private func checkCoins() {
        for index in coinsOnTrack.indices where !coinsOnTrack[index].collected {
            let coin = coinsOnTrack[index]
            guard abs(motor.x - coin.x) < Tuning.coinReach,
                  abs(motor.y - coin.y) < Tuning.coinReach,
                  abs(motor.z + SchoolRushTrack.metres(0.9) - coin.z) < Tuning.coinVerticalReach
            else { continue }

            coinsOnTrack[index].collected = true
            coins += 1

            // **A short sound, pitched up through a run of coins.** This was `laser.mp3`, which
            // is *ten and a half seconds long*: a hundred and fifty coins in a run meant a
            // hundred and fifty ten-second lasers layered on top of each other, and by thirty
            // seconds in the game was a wall of noise. Nothing else was wrong with the audio.
            // `hit_tennis_ball2.mp3` is 0.84 s, and played at better than double speed it is a
            // blip.
            //
            // The rising pitch is the Sonic-ring trick: each coin in an unbroken chain is a
            // semitone or so above the last, which turns a line of coins into a phrase and is
            // most of why collecting them is satisfying at all.
            coinChain = min(coinChain + 1, 8)
            timeSinceCoin = 0
            host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3",
                                    volume: 0.16,
                                    rate: 1.9 + 0.09 * Double(coinChain))
            onPresentationChanged?()
        }
    }

    private func takeHit() {
        lives -= 1
        invulnerability = Tuning.invulnerable
        speedScale = min(speedScale, Tuning.hitSpeedFactor)

        if lives <= 0 {
            endRun()
        } else {
            host.minigamePlayEffect(path: "/media/fail.mp3", volume: 0.45)
            announce("OUCH!", subtitle: "\(lives) \(lives == 1 ? "life" : "lives") left",
                     duration: 1.2)
        }
        onPresentationChanged?()
    }

    private func endRun() {
        phase = .over
        host.minigamePlayEffect(path: "/media/buzzer.mp3", volume: 0.45)

        if distance > best {
            best = distance
            UserDefaults.standard.set(best, forKey: Self.bestKey)
        }
        Log.world("[SchoolRush] Run over — \(Int(distance)) m, \(coins) coins, best \(Int(best)) m")
        onPresentationChanged?()
    }

    /// The badge, the moment it is earned rather than at the end of the run — a ten-year-old who
    /// has just run four hundred metres should be told so while he is still running.
    private func checkBadge() {
        guard !badgeClaimed, distance >= Tuning.badgeDistance else { return }
        badgeClaimed = true
        host.minigameAwardBadge(Tuning.badgeId)
        host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.5)
        announce("BADGE!", subtitle: "\(Int(Tuning.badgeDistance)) m — School Rush", duration: 2.6)
    }

    // MARK: - Playing it without a finger

    #if DEBUG
    /// What a bot should do next, for `-schoolrushdemo`.
    ///
    /// `simctl` cannot inject touches, so the only way to find out whether swiping works — whether
    /// a jump clears a bin, whether a lane change beats a car, whether the badge fires and the
    /// game-over panel comes up — is to have something press the same buttons a thumb would. This
    /// reports the situation; the harness turns it into calls to `jump()` and `changeLane(by:)`,
    /// so the code being tested is the code a player uses.
    enum DebugAction: Equatable {
        case carryOn
        case jump
        case moveTo(lane: Int)
    }

    func debugNextAction() -> DebugAction {
        guard phase == .running else { return .carryOn }

        // The nearest thing in this lane that is still in front.
        let ahead = obstacles
            .filter { !$0.consumed && $0.body.lane == lane && $0.body.y < motor.y }
            .min { abs($0.body.y - motor.y) < abs($1.body.y - motor.y) }
        guard let ahead else { return .carryOn }

        let gap = motor.y - ahead.body.y - ahead.body.halfDepth
        // How far the run covers between deciding and arriving. A jump takes about 0.47 s to
        // reach its apex, so it has to be started that far out — plus the length of the thing
        // being jumped, because a car has to be cleared from its near end, not its middle.
        let reach = max(motor.speed, 1) * 0.47 + ahead.body.halfDepth

        if ahead.body.isJumpable {
            return gap < reach ? .jump : .carryOn
        }

        // Not jumpable: find the nearest lane with nothing in it anywhere near this row.
        guard gap < reach * 3.5 else { return .carryOn }
        let clearance = SchoolRushTrack.metres(6)
        for candidate in [lane - 1, lane + 1, lane - 2, lane + 2]
        where candidate >= 0 && candidate < SchoolRushTrack.laneCount {
            let blocked = obstacles.contains {
                !$0.consumed && $0.body.lane == candidate
                    && abs($0.body.y - ahead.body.y) < clearance + $0.body.halfDepth
            }
            if !blocked { return .moveTo(lane: candidate) }
        }
        return .carryOn
    }

    /// One line a second for `-schoolrushtrace`: where the runner is, how fast, and what is next.
    var debugTraceLine: String {
        let next = obstacles
            .filter { !$0.consumed && $0.body.y < motor.y }
            .min { abs($0.body.y - motor.y) < abs($1.body.y - motor.y) }
        let described = next.map {
            "\($0.body.kind) lane \($0.body.lane) in "
                + String(format: "%.1f", (motor.y - $0.body.y) / SchoolRushTrack.unitsPerMetre) + "m"
        } ?? "clear"
        return String(format: "schoolrush %@ %.0fm lane %d speed %.1fm/s lives %d coins %d · next %@",
                      phase == .running ? "running" : "over",
                      distance, lane, speedInMetresPerSecond, lives, coins, described)
    }
    #endif

    // MARK: - Presentation

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.6) {
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration)
        onPresentationChanged?()
    }

    var backgroundColor: String? { SchoolRushTrack.skyHex }

    // MARK: - Scene

    var sceneCharacters: [MinigameCharacter] {
        var out: [MinigameCharacter] = []

        for obstacle in obstacles where obstacle.body.kind == .pupil {
            var pupil = pupilPool[obstacle.pupilIndex]
            pupil.x = obstacle.body.x
            pupil.y = obstacle.body.y
            pupil.z = 0
            pupil.rotation = 90
            out.append(MinigameCharacter(character: pupil, gait: .still))
        }

        // The runner goes last so they draw over the crowd, and blinks after a hit — which is
        // the cheapest honest way to say "you cannot be hit again just now". One frame off in
        // three rather than half of them: a character that is missing as often as it is there
        // reads as a rendering fault rather than as a warning.
        let blinking = invulnerability > 0 && Int(elapsed * 14) % 3 == 0
        if !blinking {
            var mine = appearance
            mine.x = motor.x
            mine.y = motor.y
            mine.z = motor.z
            mine.rotation = motor.facing
            out.append(MinigameCharacter(character: mine,
                                         gait: motor.gait,
                                         poseOverride: motor.poseOverride()))
        }

        return out
    }

    var sceneModels: [SceneModel] { SchoolRushTrack.sceneryModels(aroundY: motor.y) }

    var scenePrimitives: [ScenePrimitive] {
        var out = SchoolRushTrack.scenery(aroundY: motor.y)
        for obstacle in obstacles {
            out.append(contentsOf: SchoolRushTrack.primitives(for: obstacle.body))
        }
        for coin in coinsOnTrack where !coin.collected {
            out.append(SchoolRushTrack.primitive(for: coin))
        }
        return out
    }

    // MARK: - Camera

    /// Behind and above the runner, looking down the track.
    ///
    /// It follows X only part of the way, so changing lane visibly moves the runner across the
    /// screen instead of the whole world sliding under a runner who never appears to move. That
    /// is the difference between a lane change reading as a decision and reading as a camera pan.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        guard viewportWidth > 0, Double(viewport.y) > 0 else { return }

        // Zoom by width, the way tennis does. **9.5 m, which is the paving and barely a metre of
        // hedge either side.** It was 12.5 m and the runner came out a thumbnail two-thirds of
        // the way up the screen: this camera does not move closer when it zooms — it orbits at a
        // fixed distance set by the viewport and narrows its field of view instead — so the width
        // asked for here is the only thing that decides how big the character is.
        camera.zoom = max(0.3, viewportWidth / SchoolRushTrack.metres(9.5))
        // Well over, because a runner needs to see what is coming rather than what they are
        // standing on. `Camera.maxPitch` is 1.496, and past about 1.2 the near stand of any
        // scenery starts eating the bottom of the frame.
        camera.pitch = 1.16
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0

        let wanted = motor.x * 0.45
        if cameraSettled {
            // Exponential ease in seconds, so it runs the same on a 60 Hz and a 120 Hz display.
            cameraX += (wanted - cameraX) * (1 - exp(-6 * min(0.1, max(0, dt))))
        } else {
            cameraX = wanted
            cameraSettled = true
        }

        // Look up the track rather than at the feet. `Camera.update` adds a bias of its own in
        // the same direction, which is exactly what is wanted here — between them the runner sits
        // in the lower third of the frame with the course laid out above.
        camera.update(playerX: cameraX,
                      playerY: motor.y - SchoolRushTrack.metres(7),
                      viewport: viewport,
                      mapData: nil)
    }
}
