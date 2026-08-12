import Foundation
import simd

/// **Football.** Five a side, red against blue, first to three.
///
/// You play **whichever blue shirt is nearest the ball**, FIFA-style — the stick follows the play
/// round your own team rather than sticking to one pupil. The button kicks: to the nearest team
/// mate, unless you are close enough to the goal, in which case it goes at the goal, because a
/// pass to a team mate from six yards out is not what anybody means by "kick". Everyone you are
/// not driving is AI, on both sides: your lot pass to each other and to you and shoot when they
/// can, and red does exactly the same thing in the opposite direction.
///
/// Four things are worth knowing before changing anything here.
///
/// **The ball is owned, not pushed.** A player within `Tuning.controlRadius` of a slow ball takes
/// possession, and from then on the ball is glued a stride in front of their boots until they
/// kick it or somebody takes it off them. The obvious alternative — a ball that is a physics
/// object players collide with — reads as twenty children failing to trap a beach ball, because
/// at 27 units to the metre a foot is about four units across and a pass arriving at 15 m/s
/// crosses that in a fiftieth of a second. Owning it is what makes a pass arrive.
///
/// **A tackle is time, not a dice roll.** An opponent inside `pressureRadius` of the carrier
/// builds up pressure, and when it passes the threshold the ball changes hands. So closing a
/// player down actually works, running away actually works, and neither is random — which
/// matters when the person playing is ten and would like to know why he lost the ball.
///
/// **There are no touchlines.** The pitch is boarded like a five-a-side cage (see
/// `FootballPitch`), so the ball never goes out and the game never stops for a restart it would
/// need a referee to take.
///
/// **You are not a player, you are the stick.** `updateControl(dt:)` decides which blue shirt the
/// thumb is driving, every frame, and `Player.isControlled` is the only thing `steer` asks. There
/// is no half-controlled state: the moment control leaves a player they are AI again on the same
/// frame, and the moment blue wins the ball you are whoever won it.
///
/// The simulation is split in two: this file holds the state, the frame, the ball, the scoring
/// and the scene; `FootballGame+Team` holds the ten players — where they stand, how they decide,
/// and what a kick does.
final class FootballGame: WorldRenderedMinigame {

    // MARK: - Teams

    enum Team {
        case blue
        case red

        /// **Which way this team kicks**, as a sign on world Y. Blue attacks −Y, away from the
        /// camera, so blue's own goal is the near one — the same framing tennis uses, where the
        /// player defends the bottom of the screen.
        var attackDirection: Double { self == .blue ? -1 : 1 }

        /// The texture the kit is painted into. See `GameCharacter.outfit`.
        var outfit: String { self == .blue ? "blue" : "red" }

        var other: Team { self == .blue ? .red : .blue }

        var name: String { self == .blue ? "BLUE" : "RED" }

        /// How good this side is. **You are always blue**, so this is the one place the game is
        /// unfair on purpose. See `Skill`.
        var skill: Skill { self == .blue ? Tuning.yourLot : Tuning.theOpposition }
    }

    enum Role {
        case keeper
        case defender
        case midfielder
        case forward
    }

    /// **How good a side is**, as a set of multipliers on the numbers in `Tuning`.
    ///
    /// Everything that decides whether a team is any good used to be a single global constant,
    /// which meant the only way to make the opposition worse was to make football worse. This is
    /// the difficulty knob instead: one struct per side, applied at the handful of places a
    /// decision is actually taken, so "red are easier" never turns into "the ball behaves
    /// differently for red".
    ///
    /// It only ever touches *decisions and bodies*. The pitch, the ball, the physics and the
    /// rules are the same for both sides, which is what stops an easy setting reading as cheating.
    struct Skill {
        /// Multiplier on top speed, for outfielders and keepers alike.
        var speed: Double
        /// Multiplier on how long a player dawdles on the ball before deciding what to do with
        /// it. Above 1 is a side that takes too long and gets closed down.
        var settle: Double
        /// Multiplier on how far out they will shoot. Below 1 is a side that walks it in.
        var shootRange: Double
        /// Multiplier on how wide of the target their shooting is.
        var shotSpread: Double
        /// Multiplier on the keeper's reach — the single biggest thing between a shot and a goal.
        var keeperReach: Double
        /// Multiplier on how long it takes an opponent to tackle them. Below 1 is a side that
        /// loses the ball as soon as anybody gets near.
        var holdOnToBall: Double
    }

    // MARK: - Tuning

    enum Tuning {
        /// **Your side, and they are meant to be good.** Joel asked for his team to be 20%
        /// quicker than the baseline and for the opposition to be mega easy, and both of those
        /// live here rather than in twenty scattered constants.
        static let yourLot = Skill(speed: 1.2, settle: 1, shootRange: 1, shotSpread: 1,
                                   keeperReach: 1, holdOnToBall: 1)

        /// **Red, and they are meant to be beatable by a ten-year-old.**
        ///
        /// Six things at once, because making a side easy through any single one of them makes
        /// them look broken rather than bad: a team that is *only* slow still passes it about
        /// neatly, and a team that *only* misses looks like the goal is cursed. Together these
        /// read as a side that is a bit slow, dwells on the ball, gets robbed, rarely shoots and
        /// misses when it does — which is what a school team you are beating looks like.
        ///
        /// `holdOnToBall` at 0.55 is the sharpest of them: it takes about a third of a second to
        /// rob a red shirt, so red can only do anything at all when nobody is near them.
        static let theOpposition = Skill(speed: 0.8, settle: 1.8, shootRange: 0.55,
                                         shotSpread: 2.6, keeperReach: 0.55, holdOnToBall: 0.55)

        /// Outfield pace, before `Skill.speed`. A pupil is not a professional, but this is a game
        /// — 6.4 m/s is a fast child, and the ball still outruns everybody, which is what makes a
        /// pass worth playing.
        static let topSpeed = FootballPitch.metres(6.4)
        /// **However quick the body you are driving is, you are this much quicker still.**
        ///
        /// It used to be an absolute top speed for the human, which broke the moment your own
        /// side got a speed multiplier: your team mates ran at 7.7 m/s and the instant control
        /// switched to one of them they *slowed down* to 7.0. A bonus rather than a ceiling keeps
        /// the rule that made it worth having — the one thing a human has over the AI is choosing
        /// where to be, and being marginally faster is what turns that choice into a chance.
        static let controlSpeedBonus = FootballPitch.metres(0.6)
        /// Keepers stay near their line and do not need to sprint; a keeper as quick as a winger
        /// is a keeper who sweeps up everything and makes the game unwinnable.
        static let keeperTopSpeed = FootballPitch.metres(4.8)

        static let acceleration = FootballPitch.metres(20)
        static let braking = FootballPitch.metres(28)
        static let turnRate: Double = 480
        static let strideLength = FootballPitch.metres(2.1)
        /// Running with the ball is slower than running without it — but only just.
        ///
        /// It was 0.86, which sounds modest and is not: a defender closing at full pace gains a
        /// metre a second on the carrier, so **every** attack ended in a tackle about four
        /// seconds after it started and a measured minute and a half of match produced no shots
        /// at all. At 0.94 a defender still catches a dribbler, but has to work for it.
        static let dribbleFraction = 0.94

        /// How close counts as being on the ball, and where the ball sits while you have it.
        static let controlRadius = FootballPitch.metres(1.05)
        /// Keepers reach further, because that is what hands are. Not much further, though —
        /// a keeper who covers two metres of a seven-metre goal saves everything.
        static let keeperControlRadius = FootballPitch.metres(1.3)
        static let dribbleOffset = FootballPitch.metres(0.65)
        /// The highest a ball can be and still be brought under control on the way past. Above
        /// this it sails over everybody, which is what makes a lofted shot worth taking.
        static let receiveHeight = FootballPitch.metres(1.5)

        /// A tackle: how close, and for how long.
        static let pressureRadius = FootballPitch.metres(1.25)
        static let pressureToSteal: Double = 0.6
        /// **Longer when it is you being closed down.** Losing the ball the instant a red shirt
        /// arrives is the fastest way to make a ten-year-old put the game down.
        static let pressureToStealFromHuman: Double = 0.85

        /// How long after kicking it a player cannot take the ball back. Without this a pass is
        /// instantly re-collected by the passer and nothing ever moves.
        static let kickCooldown: Double = 0.4

        /// **How fast a pass should still be going when it arrives.** This, not a launch speed,
        /// is what a pass is weighted to — see `pass(from:to:)`. Enough pace that the receiver
        /// does not have to wait for it, slow enough that it can be taken.
        static let passArrivalSpeed = FootballPitch.metres(4)
        static let minPassSpeed = FootballPitch.metres(7)
        static let maxPassSpeed = FootballPitch.metres(24)

        static let shotSpeed = FootballPitch.metres(21)
        static let shotLift = FootballPitch.metres(2.4)
        /// How far out the AI — and the kick button — start shooting rather than passing. Back
        /// up with the pitch: on a 72 m one, 16 m is inside the six-yard box of a full attack.
        static let shootRange = FootballPitch.metres(20)
        /// **Inside this, shoot anyway** — through the defender, over them, off them, whatever.
        /// Requiring a clear sight of goal from twelve yards means never shooting, because in a
        /// box with six players in it there is never a clear sight of goal.
        static let pointBlankRange = FootballPitch.metres(12)
        /// A keeper's clearance, which is a hoof and not a pass.
        static let clearanceSpeed = FootballPitch.metres(17)
        static let clearanceLift = FootballPitch.metres(4.5)

        /// Ball physics, in real units, because the pitch is in real units.
        static let gravity = FootballPitch.metres(9.81)
        /// How hard grass slows a rolling ball. Real turf is about 0.4 g; this is a shade more so
        /// a heavy pass does not run the length of the pitch. **Everything a kick does is solved
        /// against this number** — change it and every pass in the game is reweighted, which is
        /// the point.
        static let rollFriction = FootballPitch.metres(6.0)
        /// Off the turf, and off the boards.
        static let bounce = 0.48
        static let bounceFriction = 0.74
        static let boardBounce = 0.62

        /// How often an AI player reconsiders. Every frame would be both wasteful and twitchy —
        /// a carrier that re-picks its pass sixty times a second never commits to one.
        static let decisionInterval: Double = 0.28

        /// **How long a player takes a touch for before they may kick.** The single biggest thing
        /// separating a football match from a pinball table.
        ///
        /// Without it — it was 0.12 s — every AI player kicked on the same frame they got the
        /// ball, so nobody ever ran with it and the ball spent the whole match in transit between
        /// people who had already let it go. A measured minute had it loose for something like
        /// four fifths of the time. Half a second is a touch and a look up, and it is comfortably
        /// inside `pressureToSteal` so a settling player is not simply robbed while they think.
        static let settleTime: Double = 0.5
        static let keeperSettleTime: Double = 0.6

        /// **How much nearer the ball a team mate has to be before the stick jumps to them**, and
        /// how long it stays put afterwards. See `updateControl(dt:)` — without both of these,
        /// two players a hair apart trade you back and forth several times a second.
        static let switchMargin = FootballPitch.metres(1.8)
        static let switchCooldown: Double = 0.35
        /// How long the disc under your feet is drawn fat for after control jumps, so a switch is
        /// something you see rather than something you work out by pushing the stick.
        static let switchFlash: Double = 0.45

        /// The match.
        static let goalsToWin = 3
        static let badgeId = "football"

        /// How long the banner sits up for a goal before the restart, and the count-in on a
        /// kick-off.
        static let celebration: Double = 2.6
        static let kickoffCountdown: Double = 1.4
    }

    // MARK: - State

    enum Phase {
        /// Everyone in their own half, ball on the spot, banner counting in.
        case kickoff
        case playing
        /// A goal has just gone in. Nobody moves and the banner says so.
        case celebrating
        /// Somebody reached three.
        case over
    }

    private(set) var phase: Phase = .kickoff
    private(set) var blueScore = 0
    private(set) var redScore = 0
    /// Which way the next kick-off goes — the team that just conceded takes it. Readable from
    /// `FootballGame+Team`, because `kickoffSpot(for:)` has to know who is defending the restart.
    private(set) var kickoffTeam: Team = .blue
    private var phaseTimer: Double = Tuning.kickoffCountdown

    var players: [Player] = []
    /// Index into `players` of whoever has the ball, or nil for a loose one.
    private(set) var carrier: Int?
    /// Who is closing the carrier down, and for how long they have been at it.
    private var pressure: Double = 0
    private var pressureFrom: Int?

    var ball = Ball()

    /// **Which blue player the stick is driving right now.** Not fixed: it moves round the team,
    /// FIFA-style, to whoever is nearest the ball. See `updateControl(dt:)`.
    private(set) var humanIndex = 0
    /// Seconds before control may jump again, and how long the marker under your feet stays fat
    /// after it did.
    private var switchTimer: Double = 0
    private var switchFlash: Double = 0
    /// What the stick is asking for, as a vector no longer than 1.
    private var moveInput = SIMD2<Double>.zero

    var random = DeterministicRandom(seed: 0xF007BA11)
    private var matchNumber = 0
    private var badgeClaimed = false
    private var elapsed: Double = 0

    /// Raised whenever something the HUD shows changes, so it can refresh without polling.
    var onPresentationChanged: (() -> Void)?

    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
    }

    private(set) var announcement: Announcement?

    unowned let host: MinigameHost
    private var active = false

    /// Where the camera is looking, eased towards the ball rather than snapped to it.
    private var cameraPoint = SIMD2<Double>.zero
    private var cameraSettled = false

    // MARK: - The ball

    /// Position and velocity, in world units. `z` is height above the turf, as everywhere else
    /// in this engine.
    struct Ball {
        var x: Double = 0
        var y: Double = 0
        var z: Double = FootballPitch.ballRadius
        var vx: Double = 0
        var vy: Double = 0
        var vz: Double = 0

        var speed: Double { (vx * vx + vy * vy).squareRoot() }

        mutating func place(x: Double, y: Double) {
            self.x = x
            self.y = y
            z = FootballPitch.ballRadius
            vx = 0
            vy = 0
            vz = 0
        }
    }

    // MARK: - One player

    /// One of the ten. `motor` is the same `CharacterMotor` the overworld player and both
    /// tennis players use, so everybody accelerates, carries momentum, turns at a bounded rate
    /// and side-steps for free.
    final class Player {
        var appearance: GameCharacter
        let motor: CharacterMotor
        let team: Team
        let role: Role
        /// Where this player stands when nothing is happening, in **team space**: `u` runs from
        /// −1 at their own goal to +1 at the one they are attacking, `v` across the pitch. See
        /// `FootballGame.worldPoint(u:v:for:)`.
        let home: SIMD2<Double>
        /// **True for the one player the stick is currently driving**, which moves around the
        /// team — see `FootballGame.updateControl(dt:)`. Only ever set in one place,
        /// `takeControl(of:)`, so it cannot disagree with `humanIndex`.
        var isControlled = false
        /// Whether this is the pupil Joel walks round the school as. Fixed for the match; it
        /// decides which body wears his appearance and nothing else. Control is `isControlled`.
        let wearsMyFace: Bool
        /// Top speed with nothing at their feet. `steer` knocks it down while they are dribbling,
        /// and puts it up while you are driving them.
        let baseSpeed: Double

        /// Seconds before this player may touch the ball again after kicking it.
        var kickCooldown: Double = 0
        /// Seconds left of thinking time before the AI reconsiders.
        var decisionTimer: Double = 0

        init(appearance: GameCharacter, team: Team, role: Role,
             home: SIMD2<Double>, wearsMyFace: Bool, topSpeed: Double) {
            self.appearance = appearance
            self.team = team
            self.role = role
            self.home = home
            self.wearsMyFace = wearsMyFace
            baseSpeed = topSpeed
            motor = CharacterMotor(profile: LocomotionProfile(
                maxSpeed: topSpeed,
                acceleration: FootballGame.Tuning.acceleration,
                braking: FootballGame.Tuning.braking,
                turnRate: FootballGame.Tuning.turnRate,
                strideLength: FootballGame.Tuning.strideLength,
                lean: 1,
                runThreshold: 0.5))
            motor.model = appearance.model
            motor.arrivalRadius = FootballPitch.metres(0.35)
            motor.arrivalGain = 3.2
        }

        var controlRadius: Double {
            role == .keeper
                ? FootballGame.Tuning.keeperControlRadius * team.skill.keeperReach
                : FootballGame.Tuning.controlRadius
        }
    }

    // MARK: - Lifecycle

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host
        buildTeams(npcs: npcs, myCharacter: myCharacter)
    }

    func start() {
        active = true
        Log.world("[Football] Kick off — first to \(Tuning.goalsToWin)")
        beginMatch()
        host.minigamePlayBackground(path: "/media/hushed_crowd.mp3", volume: 0.24)
    }

    /// Everything a fresh match resets. Separate from `start()` because the Play again button
    /// calls it too.
    func beginMatch() {
        matchNumber += 1
        random.reseed(0xF007BA11 &+ UInt64(matchNumber) &* 7919)
        blueScore = 0
        redScore = 0
        badgeClaimed = false
        kickoffTeam = .blue
        elapsed = 0
        setUpKickoff()
        announce("GO!", subtitle: "Stick to run · button to kick", duration: 1.8)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        host.minigameSetFootsteps(active: false, isRunning: false)
        host.minigameStopBackground()
    }

    /// The exit button in the button bar.
    func requestExit() {
        host.minigameShowDialog("Leave the match and head back to school?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    /// The Play again button on the full-time panel.
    func restartMatch() {
        guard active else { return }
        beginMatch()
    }

    // MARK: - Input

    /// The thumbstick, as a world-space direction whose length is the throttle. Handed straight
    /// through to the motor, exactly as the overworld does it.
    ///
    /// **`FootballView` calls this every rendered frame**, with zero when nothing is touching the
    /// stick — which is correct for a thumb and was fatal for the test harness. See
    /// `debugDrivesInput`.
    func setMoveInput(_ move: SIMD2<Double>) {
        #if DEBUG
        // `-footballdemo` wins. Without this the demo's twenty-times-a-second input was
        // overwritten with zero by the view at sixty, so the player it was "driving" stood still
        // for whole matches — and since control now follows the ball, the statue was always
        // blue's nearest player to it. Every balance number measured before this was found was
        // measured on a blue side playing four against five.
        if debugDrivesInput { return }
        #endif
        moveInput = move
    }

    /// The kick button.
    ///
    /// **It only does anything when you actually have the ball**, which is worth being firm
    /// about: a kick button that swings at thin air invites mashing, and mashing is how a player
    /// ends up never in position. Having the ball is the whole reward.
    func kick() {
        guard active, phase == .playing, let carrier, carrier == humanIndex else { return }
        kickFromHuman()
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

        for player in players {
            player.kickCooldown = max(0, player.kickCooldown - dt)
            player.decisionTimer = max(0, player.decisionTimer - dt)
        }

        switch phase {
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
            checkGoal()
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

        // Feet on the ground make a noise, and during a minigame the overworld player — whose
        // gait normally drives this — is standing still in a car park somewhere.
        let me = players[humanIndex].motor
        host.minigameSetFootsteps(active: me.speed > FootballPitch.metres(0.4),
                                  isRunning: me.speed > Tuning.topSpeed * 0.5)
    }

    // MARK: - Who you are driving

    /// **Control follows the ball round your own team, the way FIFA does it.**
    ///
    /// You drive whichever blue outfielder is nearest the ball, and the moment one of them wins it
    /// you are that player. Everyone you are not driving goes back to being AI on the same frame —
    /// there is no "half controlled" state, because `steer` asks `isControlled` and nothing else.
    ///
    /// Two rules keep it from being a mess:
    ///
    /// - **Winning the ball beats everything.** No cooldown, no margin: if blue takes possession,
    ///   that player is yours immediately. Anything else means the ball arrives at somebody you
    ///   are not steering, which is the one thing that would make the whole idea feel broken.
    /// - **Otherwise it needs a clear winner.** A team mate has to be `switchMargin` *nearer* the
    ///   ball than the player you already have, and switches are `switchCooldown` apart. Without
    ///   both, two players a hair apart hand you back and forth several times a second and the
    ///   stick does nothing at all.
    ///
    /// Keepers are never handed to you. A keeper you are driving is a keeper out of his goal.
    private func updateControl(dt: Double) {
        switchTimer = max(0, switchTimer - dt)
        switchFlash = max(0, switchFlash - dt)

        if let carrier, players[carrier].team == .blue, players[carrier].role != .keeper {
            takeControl(of: carrier)
            return
        }

        guard switchTimer <= 0 else { return }

        var best: Int?
        var bestDistance = Double.infinity
        for index in players.indices
        where players[index].team == .blue && players[index].role != .keeper {
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
        guard bestDistance < mine - Tuning.switchMargin else { return }
        takeControl(of: best)
    }

    /// Hands the stick to `index`. The one place `isControlled` and `humanIndex` are written, so
    /// they cannot drift apart.
    func takeControl(of index: Int) {
        guard index != humanIndex, players.indices.contains(index) else { return }
        players[humanIndex].isControlled = false
        // Whoever you just let go of stops obeying a stick they can no longer feel. `steer` will
        // give them an AI destination on the same frame; this only stops them coasting on the
        // last velocity the thumb asked for if anything ever returns early before then.
        players[humanIndex].motor.holdPosition()

        humanIndex = index
        players[index].isControlled = true
        switchTimer = Tuning.switchCooldown
        switchFlash = Tuning.switchFlash
        onPresentationChanged?()
    }

    /// Asks every player what it wants to do, then steps all twenty motors together.
    ///
    /// Split from the stepping so that every decision this frame is made against the *same*
    /// world — otherwise player 3 decides where to run based on where player 2 has already moved
    /// to this frame, and the two sides of the pitch are simulated a step apart.
    private func steerEveryone(dt: Double, live: Bool) {
        guard live else {
            for player in players {
                player.motor.holdPosition()
            }
            return
        }
        for index in players.indices {
            steer(index)
        }
    }

    private func stepMotors(dt: Double) {
        for player in players {
            player.motor.step(dt: dt) { proposedX, proposedY in
                // Nobody leaves the cage. A stride inside the boards, so a player pinned against
                // one is still visibly on grass.
                let edgeX = FootballPitch.boardX - FootballPitch.metres(0.6)
                let edgeY = FootballPitch.boardY - FootballPitch.metres(0.6)
                return (x: min(max(proposedX, -edgeX), edgeX),
                        y: min(max(proposedY, -edgeY), edgeY))
            }
        }
    }

    // MARK: - Ball

    /// Flight, roll, bounce and boards, sub-stepped.
    ///
    /// The sub-step is not decoration: the ball travels up to 26 m/s — 700 units a second — and a
    /// frame at 60 Hz is 12 units of travel, which is bigger than the ball and comparable to a
    /// player's control radius. Integrated once a frame, a hard pass can be on one side of a
    /// player at the start of the frame and the far side at the end, having been "caught" by
    /// nobody. At 240 Hz the step is 3 units and the ball is always somewhere sensible.
    private func stepBall(dt: Double) {
        if let carrier, phase == .playing {
            holdBall(by: players[carrier])
            return
        }

        let steps = max(1, min(8, Int((dt * 240).rounded(.up))))
        let step = dt / Double(steps)
        for _ in 0..<steps { integrateBall(step) }
    }

    /// The ball while somebody is running with it: a stride in front of their boots, moving at
    /// their speed. Not simulated, because a dribble that came out of the physics would be a
    /// player kicking the ball away from themselves once a second.
    private func holdBall(by player: Player) {
        let radians = player.motor.facing * .pi / 180
        ball.x = player.motor.x + cos(radians) * Tuning.dribbleOffset
        ball.y = player.motor.y + sin(radians) * Tuning.dribbleOffset
        ball.z = FootballPitch.ballRadius
        ball.vx = player.motor.vx
        ball.vy = player.motor.vy
        ball.vz = 0
    }

    private func integrateBall(_ dt: Double) {
        let onGround = ball.z <= FootballPitch.ballRadius + 0.01 && ball.vz <= 0

        if onGround {
            // Rolling: friction opposes the direction of travel and stops the ball dead rather
            // than reversing it, which is what `min` on the speed is doing.
            let speed = ball.speed
            if speed > 0 {
                let drop = min(speed, Tuning.rollFriction * dt)
                ball.vx -= ball.vx / speed * drop
                ball.vy -= ball.vy / speed * drop
            }
            ball.z = FootballPitch.ballRadius
            ball.vz = 0
        } else {
            ball.vz -= Tuning.gravity * dt
        }

        ball.x += ball.vx * dt
        ball.y += ball.vy * dt
        ball.z += ball.vz * dt

        if ball.z < FootballPitch.ballRadius {
            ball.z = FootballPitch.ballRadius
            if ball.vz < -FootballPitch.metres(0.4) {
                ball.vz = -ball.vz * Tuning.bounce
                ball.vx *= Tuning.bounceFriction
                ball.vy *= Tuning.bounceFriction
            } else {
                ball.vz = 0
            }
        }

        bounceOffBoards()
    }

    /// The cage. Behind the goal the ball still rebounds — off the back of the net, which is
    /// what a ball in a goal does anyway.
    private func bounceOffBoards() {
        let edgeX = FootballPitch.boardX - FootballPitch.ballRadius
        if abs(ball.x) > edgeX {
            ball.x = ball.x > 0 ? edgeX : -edgeX
            ball.vx = -ball.vx * Tuning.boardBounce
            ball.vy *= 0.9
        }

        let edgeY = FootballPitch.boardY - FootballPitch.ballRadius
        if abs(ball.y) > edgeY {
            ball.y = ball.y > 0 ? edgeY : -edgeY
            ball.vy = -ball.vy * Tuning.boardBounce
            ball.vx *= 0.9
        }
    }

    // MARK: - Goals

    private func checkGoal() {
        // A goal is the whole ball over the line, between the posts, under the bar. `direction`
        // is the attacking direction of whoever scored.
        for direction in [-1.0, 1.0] {
            guard ball.y * direction > FootballPitch.halfLength + FootballPitch.ballRadius,
                  abs(ball.x) < FootballPitch.goalHalfWidth - FootballPitch.ballRadius,
                  ball.z < FootballPitch.goalHeight
            else { continue }

            let scorer: Team = direction < 0 ? .blue : .red
            award(to: scorer)
            return
        }
    }

    private func award(to team: Team) {
        if team == .blue { blueScore += 1 } else { redScore += 1 }
        carrier = nil
        pressure = 0
        pressureFrom = nil
        kickoffTeam = team.other

        Log.world("[Football] \(team.name) score — \(blueScore)–\(redScore)")

        if blueScore >= Tuning.goalsToWin || redScore >= Tuning.goalsToWin {
            endMatch(winner: team)
        } else {
            phase = .celebrating
            phaseTimer = Tuning.celebration
            host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.45)
            announce("GOAL!",
                     subtitle: team == .blue ? "That's yours — \(blueScore)–\(redScore)"
                                             : "Red pull one back — \(blueScore)–\(redScore)",
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
        Log.world("[Football] Full time — \(blueScore)–\(redScore)")
        onPresentationChanged?()
    }

    private func claimBadge() {
        guard !badgeClaimed else { return }
        badgeClaimed = true
        host.minigameAwardBadge(Tuning.badgeId)
    }

    private func afterCelebration() {
        setUpKickoff()
        onPresentationChanged?()
    }

    /// Everybody back in their own half, ball on the spot, and a count-in.
    func setUpKickoff() {
        phase = .kickoff
        phaseTimer = Tuning.kickoffCountdown
        carrier = nil
        pressure = 0
        pressureFrom = nil
        ball.place(x: 0, y: 0)

        for player in players {
            let spot = kickoffSpot(for: player)
            player.motor.teleport(x: spot.x, y: spot.y, z: 0,
                                  facing: player.team == .blue ? 270 : 90)
            player.motor.holdPosition()
            player.kickCooldown = 0
        }

        // The side kicking off puts its midfielder on the ball, so the first touch of every
        // restart is a real one rather than a race from the halfway line. **You take blue's** —
        // control is handed to the taker, because a kick-off you are handed is a kick-off you can
        // do something with, and because it is the one moment where "nearest the ball" would
        // otherwise pick somebody at random out of five players standing the same distance away.
        let taker = players.firstIndex { $0.team == kickoffTeam && $0.role == .midfielder }
            ?? players.firstIndex { $0.team == kickoffTeam && $0.role == .forward }
        if let taker {
            let player = players[taker]
            let facing: Double = kickoffTeam == .blue ? 270 : 90
            let radians = facing * .pi / 180
            player.motor.teleport(x: -cos(radians) * Tuning.dribbleOffset,
                                  y: -sin(radians) * Tuning.dribbleOffset,
                                  z: 0, facing: facing)
            carrier = taker
            if kickoffTeam == .blue { takeControl(of: taker) }
        }

        announce(kickoffTeam == .blue ? "YOUR BALL" : "RED'S BALL",
                 subtitle: "\(blueScore)–\(redScore)",
                 duration: Tuning.kickoffCountdown)
    }

    // MARK: - Presentation

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.6) {
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration)
        onPresentationChanged?()
    }

    /// True while the human has the ball — the kick button lights up for it.
    var humanHasBall: Bool { carrier == humanIndex }

    var backgroundColor: String? { FootballPitch.skyHex }

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
        var out = FootballPitch.staticPrimitives

        // The disc under you. Bright yellow and always drawn, because "which one am I?" has to
        // be answerable in the half second before a pass arrives — and now that control moves
        // around the team it is the *only* answer: the shirt you are driving changes, so nothing
        // about the character itself can tell you.
        //
        // **It swells for `Tuning.switchFlash` after control jumps.** A disc that silently
        // teleports to another player is a disc you notice about a second late, by which point
        // you have run the wrong pupil into a hedge.
        let me = players[humanIndex].motor
        let flash = switchFlash / Tuning.switchFlash
        out.append(FootballPitch.markerPrimitive(x: me.x, y: me.y,
                                                 radius: FootballPitch.metres(1.0 + 0.7 * flash),
                                                 color: parseHexColor("#ffe14d"),
                                                 opacity: Float(0.85 + 0.15 * flash)))

        // And a fainter one under whoever has the ball, in their own colour, so the state of the
        // game — who is on it, which way it is going — reads without following the ball itself.
        if let carrier, carrier != humanIndex {
            let holder = players[carrier]
            out.append(FootballPitch.markerPrimitive(
                x: holder.motor.x, y: holder.motor.y,
                radius: FootballPitch.metres(0.9),
                color: parseHexColor(holder.team == .blue ? FootballPitch.blueHex
                                                          : FootballPitch.redHex),
                opacity: 0.6))
        }

        out.append(FootballPitch.ballPrimitive(x: ball.x, y: ball.y, z: ball.z))
        return out
    }

    // MARK: - Camera

    /// Follows the ball, well back and tipped over.
    ///
    /// It follows the **ball** rather than the player, which is the right choice for a game where
    /// most of what matters is happening away from you: with a player-locked camera the ball
    /// spends half the match off screen and a pass arrives from nowhere. The cost is that you
    /// have to be told where you are, which is what the yellow disc in `scenePrimitives` is for.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        guard viewportWidth > 0, Double(viewport.y) > 0 else { return }

        // Zoom by width, as tennis and School Rush both do — this camera orbits at a fixed
        // distance set by the viewport and narrows its field of view instead of moving in, so the
        // width asked for here is the only thing that decides how big a player is.
        //
        // **32 m, and it stays 32 m however big the pitch gets.** That is the whole trick behind
        // "bigger pitch, still zoomed in": the two are separate decisions now, so the pitch grew
        // to 72 × 46 m and the frame did not. You see about two thirds of its width and rather
        // less than half its length, and the camera follows the ball over the rest.
        //
        // At 40 m the whole pitch fitted the frame at once, which is a fine way to watch a match
        // and a poor way to play one: nothing is ever near you, the camera never moves, and there
        // is no sense of running anywhere. Widen this and every player on screen shrinks.
        camera.zoom = max(0.3, viewportWidth / FootballPitch.metres(32))
        // **0.88, not 1.02.** Past about 0.95 this camera spends the top half of the frame on
        // empty sky: the pitch is flat, so everything above the far touchline is nothing at all.
        // Tipping back up trades a little of the sideways view for a frame that is all pitch.
        camera.pitch = 0.82
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0

        // Halfway between the ball and you, biased to the ball. Following the ball alone means a
        // long clearance leaves you off the bottom of the screen with no idea where you are;
        // this keeps both in frame for anything short of the whole pitch.
        let me = players[humanIndex].motor
        var wanted = SIMD2(ball.x * 0.72 + me.x * 0.28, ball.y * 0.72 + me.y * 0.28)

        // Keep the view on the pitch. Without this the camera sails off behind the goal every
        // time somebody hoofs it, and the frame is half field.
        //
        // Both ways it has to travel properly now: the frame is 32 m against a 46 m width and a
        // 72 m length, so there is real pitch off every edge of the screen.
        let limitX = FootballPitch.metres(10)
        let limitY = FootballPitch.halfLength * 0.85
        wanted.x = min(max(wanted.x, -limitX), limitX)
        wanted.y = min(max(wanted.y, -limitY), limitY)

        if cameraSettled {
            // Exponential ease in seconds, so it runs the same on a 60 Hz and a 120 Hz display.
            let blend = 1 - exp(-3.4 * min(0.1, max(0, dt)))
            cameraPoint += (wanted - cameraPoint) * blend
        } else {
            cameraPoint = wanted
            cameraSettled = true
        }

        // **`Camera.update` biases its focus 15% of the screen up the world**, so that a followed
        // *player* sits low in frame with room to see ahead. That is the wrong bias for a ball on
        // a pitch — it spends the top of the frame on the field beyond the boards — so it is
        // added back here to cancel it, and what is left is a plain follow.
        //
        // 0.85 rather than 1.0: the camera lags the play slightly towards the middle of the
        // pitch, so a long ball forward opens up in front of you instead of arriving at the top
        // edge of the screen.
        let bias = Double(viewport.y) / camera.zoom * 0.15
        camera.update(playerX: cameraPoint.x,
                      playerY: cameraPoint.y * 0.85 + bias,
                      viewport: viewport,
                      mapData: nil)
    }

    // MARK: - Possession

    /// Who has the ball, and who is about to take it off them. Run once a frame, before the ball
    /// is stepped.
    private func resolvePossession(dt: Double) {
        if let holder = carrier {
            // A tackle is time spent close, not a dice roll. See the note at the top of the file.
            let carrierPlayer = players[holder]
            var closest: Int?
            var closestDistance = Double.infinity
            for index in players.indices where players[index].team != carrierPlayer.team {
                guard players[index].kickCooldown <= 0 else { continue }
                let distance = hypot(players[index].motor.x - ball.x,
                                     players[index].motor.y - ball.y)
                if distance < closestDistance {
                    closestDistance = distance
                    closest = index
                }
            }

            if let closest, closestDistance < Tuning.pressureRadius {
                if pressureFrom != closest {
                    pressureFrom = closest
                    pressure = 0
                }
                pressure += dt
                let base = carrierPlayer.isControlled ? Tuning.pressureToStealFromHuman
                                                      : Tuning.pressureToSteal
                let needed = base * carrierPlayer.team.skill.holdOnToBall
                if pressure >= needed {
                    take(by: closest)
                    host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3",
                                            volume: 0.16, rate: 0.7)
                }
            } else {
                pressure = 0
                pressureFrom = nil
            }
            return
        }

        // A loose ball goes to whoever is nearest it, provided it is low enough to be played and
        // they have not just kicked it themselves.
        guard ball.z < Tuning.receiveHeight else { return }
        var best: Int?
        var bestDistance = Double.infinity
        for index in players.indices {
            let player = players[index]
            guard player.kickCooldown <= 0 else { continue }
            let distance = hypot(player.motor.x - ball.x, player.motor.y - ball.y)
            guard distance < player.controlRadius, distance < bestDistance else { continue }
            bestDistance = distance
            best = index
        }
        if let best { take(by: best) }
    }

    private func take(by index: Int) {
        carrier = index
        pressure = 0
        pressureFrom = nil
        // A touch before a decision, so the ball is played rather than deflected. A keeper takes
        // a moment longer, because a keeper who catches it and hoofs it in the same instant looks
        // like the ball bounced off them.
        let settle = players[index].role == .keeper ? Tuning.keeperSettleTime : Tuning.settleTime
        players[index].decisionTimer = settle * players[index].team.skill.settle
        onPresentationChanged?()
    }

    // MARK: - Playing it without a thumb

    #if DEBUG
    /// One line a second for `-footballtrace`: the score, who has it, and where the ball is.
    var debugTraceLine: String {
        let holder = carrier.map { "\(players[$0].team.name) \(players[$0].role)" } ?? "loose"
        // Which shirt the stick is on, so a run of these shows control moving round the team —
        // the only way to see `updateControl` working without a thumb on the screen.
        let driving = "\(players[humanIndex].role)#\(humanIndex)"
        return String(format: "football %@ %d–%d ball (%.1f, %.1f, %.1f) m · %@ · driving %@ %@",
                      String(describing: phase), blueScore, redScore,
                      ball.x / FootballPitch.unitsPerMetre,
                      ball.y / FootballPitch.unitsPerMetre,
                      ball.z / FootballPitch.unitsPerMetre,
                      holder,
                      driving,
                      humanHasBall ? "(on the ball)" : "")
    }

    /// Set by `-footballdemo`, and the reason the demo works at all: while it is on, the view's
    /// per-frame `setMoveInput` is ignored and only `debugStep` moves the player. See
    /// `setMoveInput(_:)`.
    var debugDrivesInput = false

    /// What a bot should do, for `-footballdemo`: chase the ball, run at goal with it, and shoot
    /// when it is close enough that a kick is a shot.
    ///
    /// `simctl` cannot inject touches, so this is the only way to find out whether a match plays
    /// out — and it drives the same two entry points a thumb does, `setMoveInput` and `kick()`,
    /// rather than reaching into the simulation.
    func debugStep() {
        guard phase == .playing else {
            moveInput = .zero
            return
        }

        let me = players[humanIndex].motor
        let goalY = FootballPitch.targetGoalY(attackDirection: Team.blue.attackDirection)

        if humanHasBall {
            // Head for goal, cutting towards the middle, and shoot once a kick would be a shot.
            let dx = -me.x * 0.5
            let dy = goalY - me.y
            let length = max(hypot(dx, dy), 1)
            moveInput = SIMD2(dx / length, dy / length)

            if hypot(me.x, goalY - me.y) < Tuning.shootRange * 0.9 { kick() }
            return
        }

        let dx = ball.x - me.x
        let dy = ball.y - me.y
        let length = max(hypot(dx, dy), 1)
        moveInput = SIMD2(dx / length, dy / length)
    }
    #endif

    // MARK: - Bridges to `FootballGame+Team`

    /// The stick, read by `steer` for the human player.
    var currentMoveInput: SIMD2<Double> { moveInput }

    func setCarrier(_ index: Int?) {
        carrier = index
        pressure = 0
        pressureFrom = nil
    }

    func playKickSound(volume: Double, rate: Double) {
        host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: volume, rate: rate)
    }
}
