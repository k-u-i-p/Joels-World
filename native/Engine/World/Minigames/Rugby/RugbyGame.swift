import Foundation
import simd

/// **Rugby.** Five a side, red against blue, first to three tries.
///
/// Joel's brief: *"at the start you choose royal or challenger — royal is where you are faster,
/// challenger is when you can tackle people faster and you have higher strength. 5 v 5, blue
/// red. Click where you pass."*
///
/// It is `FootballGame`'s sibling and borrows its spine — the owned ball, the tackle that is
/// time rather than a dice roll, team space, boards instead of touchlines, and control that
/// follows the ball round your own side — so anything not explained here is explained there.
/// What is different is rugby:
///
/// - **You score by carrying the ball over the try line**, not by kicking it anywhere.
/// - **A tackle puts both players on the floor and the ball on the grass** behind the carrier,
///   and whoever gets there first has it. Support play — team mates running behind you — is
///   what wins a rugby match, and this is the rule that makes it matter.
/// - **A pass is a tap.** You tap the pitch where you want the ball to land and it is thrown
///   there, through the air, and whoever is standing there catches it — including a red shirt,
///   which is the risk. With no ball, a tap is a dive at the carrier.
/// - **You pick a class.** `PlayerClass` is three multipliers that follow the stick round the
///   team: Royal runs faster, Challenger tackles faster and takes longer to bring down.
///
/// Forward passes are **allowed**. It is not real rugby, and a ten-year-old who is told
/// "FORWARD PASS" every time he taps ahead of himself would stop playing. The AI never throws one.
final class RugbyGame: WorldRenderedMinigame {

    // MARK: - Teams

    enum Team {
        case blue
        case red

        /// Which way this team runs, as a sign on world Y. Blue attacks −Y, away from the camera.
        var attackDirection: Double { self == .blue ? -1 : 1 }
        var outfit: String { self == .blue ? "blue" : "red" }
        var other: Team { self == .blue ? .red : .blue }
        var name: String { self == .blue ? "BLUE" : "RED" }
        var skill: Skill { self == .blue ? Tuning.yourLot : Tuning.theOpposition }
    }

    /// **How good a side is**, as multipliers on `Tuning`. Decisions and bodies only — the ball,
    /// the pitch and the rules are identical for both sides. See `FootballGame.Skill`.
    struct Skill {
        /// Multiplier on top speed.
        var speed: Double
        /// Multiplier on how long a player holds the ball before deciding what to do with it.
        var settle: Double
        /// Multiplier on how quickly this side's tackles land. Below 1 is a side you run through.
        var tackling: Double
        /// Multiplier on how long it takes to bring one of this side down. Below 1 is a side that
        /// goes over at the first touch.
        var strength: Double
        /// Multiplier on how far away they will dive at a runner.
        var dive: Double
    }

    /// **The thing Joel designed.** Chosen once at the start, and it follows the stick: whichever
    /// blue shirt you are driving has these numbers, because control moves round the team and
    /// the class is *yours*, not one body's.
    enum PlayerClass: String, CaseIterable {
        case royal
        case challenger

        /// Multiplier on your top speed.
        var speed: Double { self == .royal ? 1.3 : 1.0 }
        /// Multiplier on how fast your tackles land, and how far out you can dive from.
        var tackling: Double { self == .royal ? 1.0 : 1.7 }
        /// Multiplier on how long a red shirt needs to bring you down.
        var strength: Double { self == .royal ? 1.0 : 1.6 }

        var title: String { self == .royal ? "ROYAL" : "CHALLENGER" }
        var blurb: String {
            self == .royal ? "Faster than anyone on the pitch"
                           : "Quick tackles and hard to bring down"
        }
        var icon: String { self == .royal ? "⚡" : "💪" }
    }

    // MARK: - Tuning

    enum Tuning {
        static let yourLot = Skill(speed: 1.1, settle: 1, tackling: 1, strength: 1, dive: 1)
        /// Red: a bit slow, slow to think, soft in the tackle and easy to knock over. Each dial
        /// is gentle so they look like a team you are beating rather than a broken one.
        static let theOpposition = Skill(speed: 0.8, settle: 1.6, tackling: 0.65,
                                         strength: 0.6, dive: 0.7)

        static let topSpeed = RugbyPitch.metres(6.4)
        /// On top of the class multiplier, whoever you are driving is a shade quicker still.
        static let controlSpeedBonus = RugbyPitch.metres(0.4)
        static let acceleration = RugbyPitch.metres(20)
        static let braking = RugbyPitch.metres(28)
        static let turnRate: Double = 480
        static let strideLength = RugbyPitch.metres(2.1)
        /// Running with the ball tucked under an arm is barely slower than running without it.
        static let carryFraction = 0.95

        /// Where the ball sits while carried: a little in front, at chest height. Drawing only.
        static let carryOffset = RugbyPitch.metres(0.45)
        static let carryHeight = RugbyPitch.metres(1.9)

        /// **A tackle is time spent close.** An opponent inside `tackleRadius` builds grip; when it
        /// passes the threshold the carrier goes down. You get longer than the AI does.
        static let tackleRadius = RugbyPitch.metres(1.4)
        static let tackleTime: Double = 0.5
        static let tackleTimeOnHuman: Double = 0.8

        /// **The dive** — the tackle that catches a runner. The direction is fixed when they go,
        /// so a swerve beats it, and a dive that misses leaves them on the floor for
        /// `lungeRecovery`. See `FootballGame.Tuning.lungeRange` for why pressure alone cannot
        /// catch somebody who keeps moving.
        static let lungeRange = RugbyPitch.metres(2.8)
        static let lungeTime: Double = 0.32
        static let lungeSpeed = RugbyPitch.metres(11)
        static let lungeAcceleration = RugbyPitch.metres(80)
        static let lungeReach = RugbyPitch.metres(1.1)
        static let lungeRecovery: Double = 1.0
        static let recoverySpeedFraction = 0.3
        static let lungeWhenCarrierFasterThan = RugbyPitch.metres(2.5)
        /// How far from the carrier a tap still counts as a dive when you have no ball.
        static let humanDiveRange = RugbyPitch.metres(4.5)

        /// **After a tackle both players are on the floor** — the tackled one for longer. The ball
        /// pops out `releaseDistance` behind the carrier, and neither of them may pick it up for
        /// `releaseCooldown`, which is the window the support runners have.
        static let downTime: Double = 1.5
        static let tacklerDownTime: Double = 0.8
        static let releaseDistance = RugbyPitch.metres(1.6)
        static let releaseCooldown: Double = 0.5

        /// Catching: how close, how high, and how long after throwing it you may not take it back.
        static let catchRadius = RugbyPitch.metres(1.4)
        static let catchHeight = RugbyPitch.metres(3.0)
        static let catchCooldown: Double = 0.45

        /// A pass flies through the air to where it was aimed. The flight time is the distance
        /// over `passSpeed`, clamped, and the throw is solved to land there.
        static let passSpeed = RugbyPitch.metres(15)
        static let minFlight: Double = 0.3
        static let maxFlight: Double = 1.4
        static let maxPassDistance = RugbyPitch.metres(24)

        static let gravity = RugbyPitch.metres(9.81)
        static let rollFriction = RugbyPitch.metres(5.0)
        /// A rugby ball bounces oddly. The random nudge in `integrateBall` is the oddly.
        static let bounce = 0.45
        static let bounceFriction = 0.7
        static let boardBounce = 0.55

        static let decisionInterval: Double = 0.28
        /// A moment with the ball in both hands before deciding. Shorter than football's — a
        /// rugby pass is caught and gone.
        static let settleTime: Double = 0.35

        static let switchMargin = RugbyPitch.metres(1.8)
        static let switchCooldown: Double = 0.35
        static let switchFlash: Double = 0.45

        static let triesToWin = 3
        static let badgeId = "rugby"

        static let celebration: Double = 2.6
        static let kickoffCountdown: Double = 1.4
        /// How long the ring where you tapped stays on the grass.
        static let passMarkerTime: Double = 0.7
    }

    // MARK: - State

    enum Phase {
        /// The class picker is up. Nobody moves until Royal or Challenger is chosen.
        case choosing
        case kickoff
        case playing
        case celebrating
        case over
    }

    private(set) var phase: Phase = .choosing
    private(set) var blueScore = 0
    private(set) var redScore = 0
    private(set) var kickoffTeam: Team = .blue
    private var phaseTimer: Double = Tuning.kickoffCountdown

    /// What you picked. Nil until the picker has been answered.
    private(set) var playerClass: PlayerClass?

    var players: [Player] = []
    private(set) var carrier: Int?
    private var grip: Double = 0
    private var gripFrom: Int?

    var ball = Ball()

    private(set) var humanIndex = 0
    private var switchTimer: Double = 0
    private var switchFlash: Double = 0
    private var moveInput = SIMD2<Double>.zero

    /// Where the last tap landed, for the ring on the grass.
    private var passMarker: (x: Double, y: Double, remaining: Double)?

    var random = DeterministicRandom(seed: 0x5CBA11)
    private var matchNumber = 0
    private var badgeClaimed = false
    private var elapsed: Double = 0

    var onPresentationChanged: (() -> Void)?

    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
    }

    private(set) var announcement: Announcement?

    unowned let host: MinigameHost
    private var active = false

    private var cameraPoint = SIMD2<Double>.zero
    private var cameraSettled = false
    /// The camera as last placed, so a tap on the glass can be turned into a spot on the grass.
    private(set) var lastCamera = Camera()

    // MARK: - The ball

    struct Ball {
        var x: Double = 0
        var y: Double = 0
        var z: Double = RugbyPitch.ballRadius
        var vx: Double = 0
        var vy: Double = 0
        var vz: Double = 0
        /// Which way the egg points, in world radians.
        var axis: Double = .pi / 2

        var speed: Double { (vx * vx + vy * vy).squareRoot() }

        mutating func place(x: Double, y: Double) {
            self.x = x
            self.y = y
            z = RugbyPitch.ballRadius
            vx = 0
            vy = 0
            vz = 0
        }
    }

    // MARK: - One player

    final class Player {
        var appearance: GameCharacter
        let motor: CharacterMotor
        let team: Team
        /// Where this player stands when nothing is happening, in team space (`u` towards the
        /// try line they attack, `v` across).
        let home: SIMD2<Double>
        var isControlled = false
        let wearsMyFace: Bool
        let baseSpeed: Double

        var decisionTimer: Double = 0
        /// Seconds this player may not catch the ball for — after throwing it, or after a tackle.
        var catchCooldown: Double = 0
        /// Seconds left on the floor after a tackle, given or taken. A player who is down does
        /// not move and cannot catch.
        var downTimer: Double = 0
        var lungeTimer: Double = 0
        var lungeDirection = SIMD2<Double>.zero
        var recoverTimer: Double = 0

        var isDown: Bool { downTimer > 0 }

        init(appearance: GameCharacter, team: Team, home: SIMD2<Double>,
             wearsMyFace: Bool, topSpeed: Double) {
            self.appearance = appearance
            self.team = team
            self.home = home
            self.wearsMyFace = wearsMyFace
            baseSpeed = topSpeed
            motor = CharacterMotor(profile: LocomotionProfile(
                maxSpeed: topSpeed,
                acceleration: RugbyGame.Tuning.acceleration,
                braking: RugbyGame.Tuning.braking,
                turnRate: RugbyGame.Tuning.turnRate,
                strideLength: RugbyGame.Tuning.strideLength,
                lean: 1,
                runThreshold: 0.5))
            motor.model = appearance.model
            motor.arrivalRadius = RugbyPitch.metres(0.35)
            motor.arrivalGain = 3.2
        }
    }

    // MARK: - Lifecycle

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host
        buildTeams(npcs: npcs, myCharacter: myCharacter)
    }

    func start() {
        active = true
        Log.world("[Rugby] Waiting for a class — first to \(Tuning.triesToWin) tries")
        phase = .choosing
        setUpKickoff(countIn: false)
        host.minigamePlayBackground(path: "/media/hushed_crowd.mp3", volume: 0.24)
        onPresentationChanged?()
    }

    /// The picker's answer. Starts the match.
    func choose(_ chosen: PlayerClass) {
        guard active, phase == .choosing else { return }
        playerClass = chosen
        Log.world("[Rugby] You are \(chosen.title)")
        beginMatch()
    }

    /// Back to the picker, from the full-time panel.
    func returnToChoosing() {
        guard active else { return }
        phase = .choosing
        playerClass = nil
        blueScore = 0
        redScore = 0
        announcement = nil
        setUpKickoff(countIn: false)
        onPresentationChanged?()
    }

    func beginMatch() {
        matchNumber += 1
        random.reseed(0x5CBA11 &+ UInt64(matchNumber) &* 7919)
        blueScore = 0
        redScore = 0
        badgeClaimed = false
        kickoffTeam = .blue
        elapsed = 0
        setUpKickoff(countIn: true)
        announce("GO!", subtitle: "Stick to run · tap the pitch to pass", duration: 1.8)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        host.minigameSetFootsteps(active: false, isRunning: false)
        host.minigameStopBackground()
    }

    func requestExit() {
        host.minigameShowDialog("Leave the match and head back to school?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    func restartMatch() {
        guard active, playerClass != nil else { return }
        beginMatch()
    }

    // MARK: - Input

    /// The thumbstick. `RugbyView` calls this every rendered frame — see `debugDrivesInput`.
    func setMoveInput(_ move: SIMD2<Double>) {
        #if DEBUG
        if debugDrivesInput { return }
        #endif
        moveInput = move
    }

    /// **A tap on the pitch.** With the ball: throw it there. Without: dive at the carrier, if
    /// they are close enough to reach.
    func tap(worldX: Double, worldY: Double) {
        guard active, phase == .playing else { return }
        if let carrier, carrier == humanIndex {
            passFromHuman(toX: worldX, y: worldY)
            passMarker = (worldX, worldY, Tuning.passMarkerTime)
            return
        }
        humanDive()
    }

    /// Turns a point on the glass into a point on the grass, using the camera as last placed.
    /// `ndc` is −1…1 both ways with +Y up, the way `Camera.unprojectToGroundPlane` wants it.
    func groundPoint(ndc: SIMD2<Float>) -> (x: Double, y: Double)? {
        guard let hit = lastCamera.unprojectToGroundPlane(ndc: ndc) else { return nil }
        // Render space negates Y.
        return (x: Double(hit.x), y: -Double(hit.y))
    }

    // MARK: - Frame

    func update(dt: Double) {
        guard active else { return }
        elapsed += dt

        if var current = announcement {
            current.remaining -= dt
            if current.remaining <= 0 {
                announcement = nil
                onPresentationChanged?()
            } else {
                announcement = current
            }
        }
        if var marker = passMarker {
            marker.remaining -= dt
            passMarker = marker.remaining > 0 ? marker : nil
        }

        for player in players {
            player.catchCooldown = max(0, player.catchCooldown - dt)
            player.decisionTimer = max(0, player.decisionTimer - dt)
            player.recoverTimer = max(0, player.recoverTimer - dt)
            player.downTimer = max(0, player.downTimer - dt)
            if player.lungeTimer > 0 {
                player.lungeTimer -= dt
                if player.lungeTimer <= 0 {
                    player.lungeTimer = 0
                    player.recoverTimer = Tuning.lungeRecovery
                }
            }
        }

        switch phase {
        case .choosing:
            steerEveryone(dt: dt, live: false)
        case .kickoff:
            phaseTimer -= dt
            steerEveryone(dt: dt, live: false)
            if phaseTimer <= 0 {
                phase = .playing
                onPresentationChanged?()
            }
        case .playing:
            updateControl(dt: dt)
            steerEveryone(dt: dt, live: true)
            resolvePossession(dt: dt)
            stepBall(dt: dt)
            checkTry()
        case .celebrating:
            phaseTimer -= dt
            steerEveryone(dt: dt, live: false)
            stepBall(dt: dt)
            if phaseTimer <= 0 { afterCelebration() }
        case .over:
            steerEveryone(dt: dt, live: false)
            stepBall(dt: dt)
        }

        stepMotors(dt: dt)

        let me = players[humanIndex].motor
        host.minigameSetFootsteps(active: me.speed > RugbyPitch.metres(0.4),
                                  isRunning: me.speed > Tuning.topSpeed * 0.5)
    }

    // MARK: - Who you are driving

    /// Control follows the ball round your own side — see `FootballGame.updateControl`. One
    /// rugby addition: **a player on the floor is never handed to you**, because a stick that
    /// drives nobody for a second and a half reads as broken.
    private func updateControl(dt: Double) {
        switchTimer = max(0, switchTimer - dt)
        switchFlash = max(0, switchFlash - dt)

        if let carrier, players[carrier].team == .blue {
            takeControl(of: carrier)
            return
        }

        guard switchTimer <= 0 else { return }

        var best: Int?
        var bestDistance = Double.infinity
        for index in players.indices
        where players[index].team == .blue && !players[index].isDown {
            let distance = hypot(players[index].motor.x - ball.x,
                                 players[index].motor.y - ball.y)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }

        guard let best, best != humanIndex else { return }
        let mine = hypot(players[humanIndex].motor.x - ball.x,
                         players[humanIndex].motor.y - ball.y)
        // A player on the floor loses the stick at once; otherwise it needs a clear winner.
        guard players[humanIndex].isDown || bestDistance < mine - Tuning.switchMargin else { return }
        takeControl(of: best)
    }

    func takeControl(of index: Int) {
        guard index != humanIndex, players.indices.contains(index) else { return }
        players[humanIndex].isControlled = false
        players[humanIndex].motor.holdPosition()
        humanIndex = index
        players[index].isControlled = true
        switchTimer = Tuning.switchCooldown
        switchFlash = Tuning.switchFlash
        onPresentationChanged?()
    }

    private func steerEveryone(dt: Double, live: Bool) {
        guard live else {
            for player in players { player.motor.holdPosition() }
            return
        }
        for index in players.indices { steer(index) }
    }

    private func stepMotors(dt: Double) {
        for player in players {
            player.motor.step(dt: dt) { proposedX, proposedY in
                let edgeX = RugbyPitch.boardX - RugbyPitch.metres(0.6)
                let edgeY = RugbyPitch.boardY - RugbyPitch.metres(0.6)
                return (x: min(max(proposedX, -edgeX), edgeX),
                        y: min(max(proposedY, -edgeY), edgeY))
            }
        }
    }

    // MARK: - Ball

    private func stepBall(dt: Double) {
        if let carrier, phase == .playing {
            holdBall(by: players[carrier])
            return
        }
        let steps = max(1, min(8, Int((dt * 240).rounded(.up))))
        let step = dt / Double(steps)
        for _ in 0..<steps { integrateBall(step) }
    }

    /// Tucked under the arm: a little in front, chest high, pointing the way they are running.
    private func holdBall(by player: Player) {
        let radians = player.motor.facing * .pi / 180
        ball.x = player.motor.x + cos(radians) * Tuning.carryOffset
        ball.y = player.motor.y + sin(radians) * Tuning.carryOffset
        ball.z = Tuning.carryHeight
        ball.vx = player.motor.vx
        ball.vy = player.motor.vy
        ball.vz = 0
        ball.axis = radians
    }

    private func integrateBall(_ dt: Double) {
        let onGround = ball.z <= RugbyPitch.ballRadius + 0.01 && ball.vz <= 0

        if onGround {
            let speed = ball.speed
            if speed > 0 {
                let drop = min(speed, Tuning.rollFriction * dt)
                ball.vx -= ball.vx / speed * drop
                ball.vy -= ball.vy / speed * drop
            }
            ball.z = RugbyPitch.ballRadius
            ball.vz = 0
        } else {
            ball.vz -= Tuning.gravity * dt
        }

        ball.x += ball.vx * dt
        ball.y += ball.vy * dt
        ball.z += ball.vz * dt

        if ball.speed > RugbyPitch.metres(0.5) {
            ball.axis = atan2(ball.vy, ball.vx)
        }

        if ball.z < RugbyPitch.ballRadius {
            ball.z = RugbyPitch.ballRadius
            if ball.vz < -RugbyPitch.metres(0.4) {
                ball.vz = -ball.vz * Tuning.bounce
                ball.vx *= Tuning.bounceFriction
                ball.vy *= Tuning.bounceFriction
                // An egg does not bounce straight. A nudge sideways, a different one each time.
                let kick = RugbyPitch.metres(1.2)
                ball.vx += random.signed() * kick
                ball.vy += random.signed() * kick
            } else {
                ball.vz = 0
            }
        }

        bounceOffBoards()
    }

    private func bounceOffBoards() {
        let edgeX = RugbyPitch.boardX - RugbyPitch.ballRadius
        if abs(ball.x) > edgeX {
            ball.x = ball.x > 0 ? edgeX : -edgeX
            ball.vx = -ball.vx * Tuning.boardBounce
            ball.vy *= 0.9
        }
        let edgeY = RugbyPitch.boardY - RugbyPitch.ballRadius
        if abs(ball.y) > edgeY {
            ball.y = ball.y > 0 ? edgeY : -edgeY
            ball.vy = -ball.vy * Tuning.boardBounce
            ball.vx *= 0.9
        }
    }

    // MARK: - Tries

    /// A try is **the carrier** over the try line. A loose ball over it is nothing.
    private func checkTry() {
        guard let carrier else { return }
        let player = players[carrier]
        let direction = player.team.attackDirection
        guard player.motor.y * direction > RugbyPitch.halfField else { return }
        award(to: player.team)
    }

    private func award(to team: Team) {
        if team == .blue { blueScore += 1 } else { redScore += 1 }
        carrier = nil
        grip = 0
        gripFrom = nil
        kickoffTeam = team.other

        Log.world("[Rugby] \(team.name) try — \(blueScore)–\(redScore)")

        if blueScore >= Tuning.triesToWin || redScore >= Tuning.triesToWin {
            endMatch(winner: team)
        } else {
            phase = .celebrating
            phaseTimer = Tuning.celebration
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.45)
            announce("TRY!",
                     subtitle: team == .blue ? "That's yours — \(blueScore)–\(redScore)"
                                             : "Red score — \(blueScore)–\(redScore)",
                     duration: Tuning.celebration)
        }
        onPresentationChanged?()
    }

    private func endMatch(winner: Team) {
        phase = .over
        if winner == .blue {
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.6)
            announce("BLUE WIN!", subtitle: "\(blueScore)–\(redScore)", duration: 4)
            claimBadge()
        } else {
            host.minigamePlayEffect(path: "/media/buzzer.mp3", volume: 0.45)
            announce("RED WIN", subtitle: "\(blueScore)–\(redScore)", duration: 4)
        }
        Log.world("[Rugby] Full time — \(blueScore)–\(redScore)")
        onPresentationChanged?()
    }

    private func claimBadge() {
        guard !badgeClaimed else { return }
        badgeClaimed = true
        host.minigameAwardBadge(Tuning.badgeId)
    }

    private func afterCelebration() {
        setUpKickoff(countIn: true)
        onPresentationChanged?()
    }

    /// Everybody in their own half, the restarting side's centre on the ball at halfway.
    /// `countIn` false leaves the phase alone — the picker is up and nobody is going anywhere.
    func setUpKickoff(countIn: Bool) {
        if countIn {
            phase = .kickoff
            phaseTimer = Tuning.kickoffCountdown
        }
        carrier = nil
        grip = 0
        gripFrom = nil
        ball.place(x: 0, y: 0)

        for player in players {
            let spot = kickoffSpot(for: player)
            player.motor.teleport(x: spot.x, y: spot.y, z: 0,
                                  facing: player.team == .blue ? 270 : 90)
            player.motor.holdPosition()
            player.lungeTimer = 0
            player.recoverTimer = 0
            player.downTimer = 0
            player.catchCooldown = 0
        }

        let taker = players.firstIndex { $0.team == kickoffTeam && $0.home.y == 0 }
            ?? players.firstIndex { $0.team == kickoffTeam }
        if let taker {
            let player = players[taker]
            let facing: Double = kickoffTeam == .blue ? 270 : 90
            let radians = facing * .pi / 180
            player.motor.teleport(x: -cos(radians) * Tuning.carryOffset,
                                  y: -sin(radians) * Tuning.carryOffset,
                                  z: 0, facing: facing)
            carrier = taker
            holdBall(by: player)
            if kickoffTeam == .blue { takeControl(of: taker) }
        }

        if countIn {
            announce(kickoffTeam == .blue ? "YOUR BALL" : "RED'S BALL",
                     subtitle: "\(blueScore)–\(redScore)",
                     duration: Tuning.kickoffCountdown)
        }
    }

    // MARK: - Presentation

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.6) {
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration)
        onPresentationChanged?()
    }

    var humanHasBall: Bool { carrier == humanIndex }

    var backgroundColor: String? { RugbyPitch.skyHex }

    // MARK: - Scene

    var sceneCharacters: [MinigameCharacter] {
        players.map { player in
            var appearance = player.appearance
            appearance.x = player.motor.x
            appearance.y = player.motor.y
            appearance.z = player.motor.z
            appearance.rotation = player.motor.facing
            return MinigameCharacter(character: appearance,
                                     gait: player.motor.gait,
                                     poseOverride: player.motor.poseOverride())
        }
    }

    var scenePrimitives: [ScenePrimitive] {
        var out = RugbyPitch.staticPrimitives

        // The yellow disc under you. See `FootballGame.scenePrimitives`.
        let me = players[humanIndex].motor
        let flash = switchFlash / Tuning.switchFlash
        out.append(RugbyPitch.markerPrimitive(x: me.x, y: me.y,
                                              radius: RugbyPitch.metres(1.0 + 0.7 * flash),
                                              color: parseHexColor("#ffe14d"),
                                              opacity: Float(0.85 + 0.15 * flash)))

        if let carrier, carrier != humanIndex {
            let holder = players[carrier]
            out.append(RugbyPitch.markerPrimitive(
                x: holder.motor.x, y: holder.motor.y,
                radius: RugbyPitch.metres(0.9),
                color: parseHexColor(holder.team == .blue ? RugbyPitch.blueHex : RugbyPitch.redHex),
                opacity: 0.6))
        }

        // A grey disc under anybody on the floor, so a tackle is something you can see happened.
        for player in players where player.isDown {
            out.append(RugbyPitch.markerPrimitive(
                x: player.motor.x, y: player.motor.y,
                radius: RugbyPitch.metres(1.1),
                color: parseHexColor("#3a3a3a"),
                opacity: Float(0.45 * min(1, player.downTimer / 0.4))))
        }

        // The ring where you tapped, fading.
        if let marker = passMarker {
            let life = marker.remaining / Tuning.passMarkerTime
            out.append(RugbyPitch.markerPrimitive(
                x: marker.x, y: marker.y,
                radius: RugbyPitch.metres(0.8 + 0.6 * (1 - life)),
                color: parseHexColor("#ffffff"),
                opacity: Float(0.55 * life)))
        }

        out += RugbyPitch.ballPrimitives(x: ball.x, y: ball.y, z: ball.z, axis: ball.axis)
        return out
    }

    // MARK: - Camera

    /// Follows the ball, well back and tipped over — the same camera football uses.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        guard viewportWidth > 0, Double(viewport.y) > 0 else { return }

        camera.zoom = max(0.3, viewportWidth / RugbyPitch.metres(32))
        camera.pitch = 0.82
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0

        let me = players[humanIndex].motor
        var wanted = SIMD2(ball.x * 0.72 + me.x * 0.28, ball.y * 0.72 + me.y * 0.28)

        let limitX = RugbyPitch.metres(9)
        let limitY = RugbyPitch.halfLength * 0.85
        wanted.x = min(max(wanted.x, -limitX), limitX)
        wanted.y = min(max(wanted.y, -limitY), limitY)

        if cameraSettled {
            let blend = 1 - exp(-3.4 * min(0.1, max(0, dt)))
            cameraPoint += (wanted - cameraPoint) * blend
        } else {
            cameraPoint = wanted
            cameraSettled = true
        }

        let bias = Double(viewport.y) / camera.zoom * 0.15
        camera.update(playerX: cameraPoint.x,
                      playerY: cameraPoint.y * 0.85 + bias,
                      viewport: viewport,
                      mapData: nil)
        lastCamera = camera
    }

    // MARK: - Possession

    /// Who has the ball, who is about to knock them over, and who picks up a loose one.
    private func resolvePossession(dt: Double) {
        if let holder = carrier {
            let carrierPlayer = players[holder]

            // A dive that reaches the ball is a tackle, there and then.
            for index in players.indices
            where players[index].team != carrierPlayer.team && players[index].lungeTimer > 0 {
                let distance = hypot(players[index].motor.x - ball.x,
                                     players[index].motor.y - ball.y)
                guard distance < Tuning.lungeReach else { continue }
                players[index].lungeTimer = 0
                tackle(holder, by: index)
                return
            }

            // Otherwise grip builds while somebody is close.
            var closest: Int?
            var closestDistance = Double.infinity
            for index in players.indices where players[index].team != carrierPlayer.team {
                let player = players[index]
                guard !player.isDown, player.recoverTimer <= 0 else { continue }
                let distance = hypot(player.motor.x - carrierPlayer.motor.x,
                                     player.motor.y - carrierPlayer.motor.y)
                if distance < closestDistance {
                    closestDistance = distance
                    closest = index
                }
            }

            if let closest, closestDistance < Tuning.tackleRadius {
                if gripFrom != closest {
                    gripFrom = closest
                    grip = 0
                }
                grip += dt
                let base = carrierPlayer.isControlled ? Tuning.tackleTimeOnHuman : Tuning.tackleTime
                let needed = base * strength(of: holder) / tackling(of: closest)
                if grip >= needed { tackle(holder, by: closest) }
            } else {
                grip = 0
                gripFrom = nil
            }
            return
        }

        // A loose ball goes to whoever is nearest it, if it is low enough to reach and they are
        // on their feet and allowed to.
        guard ball.z < Tuning.catchHeight else { return }
        var best: Int?
        var bestDistance = Double.infinity
        for index in players.indices {
            let player = players[index]
            guard player.catchCooldown <= 0, !player.isDown else { continue }
            let distance = hypot(player.motor.x - ball.x, player.motor.y - ball.y)
            guard distance < Tuning.catchRadius, distance < bestDistance else { continue }
            bestDistance = distance
            best = index
        }
        if let best { take(by: best) }
    }

    /// How hard this player is to bring down: their class if you are driving them, their side's
    /// skill otherwise.
    func strength(of index: Int) -> Double {
        let player = players[index]
        if player.isControlled, let playerClass { return playerClass.strength }
        return player.team.skill.strength
    }

    /// How quickly this player's tackles land.
    func tackling(of index: Int) -> Double {
        let player = players[index]
        if player.isControlled, let playerClass { return playerClass.tackling }
        return player.team.skill.tackling
    }

    /// **The tackle.** Both players go down, the tackled one for longer, and the ball pops out
    /// behind the carrier for whoever gets there first. Neither of the two may take it straight
    /// away, which is the window the support runners have.
    private func tackle(_ holder: Int, by tackler: Int) {
        let carrierPlayer = players[holder]
        let tacklerPlayer = players[tackler]
        let robbedYou = carrierPlayer.isControlled
        let yourHit = tacklerPlayer.isControlled

        carrierPlayer.downTimer = Tuning.downTime
        carrierPlayer.catchCooldown = Tuning.downTime + Tuning.releaseCooldown
        tacklerPlayer.downTimer = Tuning.tacklerDownTime
        tacklerPlayer.catchCooldown = Tuning.tacklerDownTime + Tuning.releaseCooldown
        tacklerPlayer.lungeTimer = 0
        tacklerPlayer.recoverTimer = 0
        carrierPlayer.motor.holdPosition()
        tacklerPlayer.motor.holdPosition()

        // The ball goes backwards — towards the carrier's own line — and hops.
        let back = -carrierPlayer.team.attackDirection
        ball.x = carrierPlayer.motor.x + random.signed() * RugbyPitch.metres(0.6)
        ball.y = carrierPlayer.motor.y + back * Tuning.releaseDistance
        ball.z = RugbyPitch.metres(1.0)
        ball.vx = random.signed() * RugbyPitch.metres(1.5)
        ball.vy = back * RugbyPitch.metres(2.0)
        ball.vz = RugbyPitch.metres(2.0)
        setCarrier(nil)

        host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: 0.3, rate: 0.5)
        if robbedYou {
            announce("TACKLED!", duration: 0.9)
        } else if yourHit {
            announce("BIG HIT!", duration: 0.9)
        }
        Log.world("[Rugby] \(tacklerPlayer.team.name) tackle"
                  + (robbedYou ? " on you" : yourHit ? " by you" : ""))
        onPresentationChanged?()
    }

    private func take(by index: Int) {
        carrier = index
        grip = 0
        gripFrom = nil
        players[index].decisionTimer = Tuning.settleTime * players[index].team.skill.settle
        onPresentationChanged?()
    }

    // MARK: - Playing it without a thumb

    #if DEBUG
    var debugTraceLine: String {
        let holder = carrier.map { "\(players[$0].team.name) #\($0)" } ?? "loose"
        let down = players.filter { $0.isDown }.count
        return String(format: "rugby %@ %d–%d ball (%.1f, %.1f, %.1f) m · %@ · driving #%d %@ · %d down",
                      String(describing: phase), blueScore, redScore,
                      ball.x / RugbyPitch.unitsPerMetre,
                      ball.y / RugbyPitch.unitsPerMetre,
                      ball.z / RugbyPitch.unitsPerMetre,
                      holder, humanIndex,
                      humanHasBall ? "(on the ball)" : "",
                      down)
    }

    /// Set by `-rugbydemo`. See `FootballGame.debugDrivesInput` for the statue bug it exists for.
    var debugDrivesInput = false

    /// What a bot does: run at the try line with the ball, pass to a supporter when a red shirt
    /// gets close, chase the ball without it and dive when near enough. It drives the same two
    /// entry points a thumb does — `setMoveInput` and `tap(worldX:y:)`.
    func debugStep() {
        guard phase == .playing else {
            moveInput = .zero
            return
        }

        let me = players[humanIndex].motor
        let tryY = RugbyPitch.tryLineY(attackDirection: Team.blue.attackDirection)

        if humanHasBall {
            let dx = -me.x * 0.4
            let dy = tryY - me.y
            let length = max(hypot(dx, dy), 1)
            moveInput = SIMD2(dx / length, dy / length)

            // A red shirt within three metres in front: pass to the nearest team mate behind.
            if let threat = nearestOpponentIndex(to: humanIndex),
               distanceBetween(humanIndex, threat) < RugbyPitch.metres(3),
               let mate = bestSupportBehind(humanIndex) {
                let target = players[mate].motor
                tap(worldX: target.x, worldY: target.y)
            }
            return
        }

        let dx = ball.x - me.x
        let dy = ball.y - me.y
        let length = max(hypot(dx, dy), 1)
        moveInput = SIMD2(dx / length, dy / length)

        // A dive now and then, not twenty times a second — a thumb could never tap that fast,
        // and a bot that could turned every red catch into an instant pile-up.
        if let carrier, players[carrier].team == .red, length < RugbyPitch.metres(3),
           random.unit() < 0.12 {
            tap(worldX: ball.x, worldY: ball.y)
        }
    }
    #endif

    // MARK: - Bridges to `RugbyGame+Team`

    var currentMoveInput: SIMD2<Double> { moveInput }

    func setCarrier(_ index: Int?) {
        carrier = index
        grip = 0
        gripFrom = nil
    }

    func playThrowSound(volume: Double, rate: Double) {
        host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: volume, rate: rate)
    }
}
