import Foundation
import simd

/// Tennis, rebuilt on the real engine.
///
/// The 2D game this supersedes drew itself onto a `CGContext` and derived its physics from the
/// drawing: the racket's hitbox was whatever the renderer had painted a frame ago, the court was
/// 120 units wide with every velocity divided by a `gameScale` constant to compensate, and the
/// characters were stick figures. None of that survives here. This version:
///
/// - runs on the Metal renderer with the same rigs, heads and clothes as the rest of the school;
/// - uses a **real court in real units** with real gravity, drag and a bouncing ball
///   (`Tennis3DCourt`, `Tennis3DGame+Ball`);
/// - moves both players through `Locomotion`, the shared movement system the overworld also
///   uses now — so they carry momentum, take a moment to turn, and side-step;
/// - detects contact by sweeping the racket head against the ball's own path through a
///   fixed-rate sub-step, rather than by testing against last frame's drawing;
/// - is **deterministic**: every random number comes from a seed derived from the score, so the
///   same point plays out the same way twice.
///
/// The simulation is split across four files: this one holds the state, the frame and the
/// camera; `+Ball` the flight, the bounce and the serve; `+Players` the locomotion, the swing
/// and the opponent's brain; `+Rules` the scoring and what the scoreboard says.
final class Tennis3DGame: WorldRenderedMinigame {

    // MARK: - Tuning
    //
    // Real tennis, dialled back to something a ten-year-old can rally with. The ratios between
    // these are what matters: a serve outruns a groundstroke, a groundstroke outruns a player,
    // and a player can just about cover the court if they set off in time.

    enum Tuning {
        /// A groundstroke leaves the racket at about 15 m/s. A professional's is 25.
        static let rallySpeed = Tennis3DCourt.metres(15)
        /// A first serve. Fast enough to be worth getting right, slow enough to return.
        ///
        /// It was 21 m/s, and at that pace the point was over the moment the ball left the
        /// strings: every single game in a test match was a love game, on both sides, because
        /// the receiver had no time to do anything at all. A game whose only shot is the serve
        /// is not the game — the rally is. 16.5 leaves the server a real advantage and the
        /// receiver a real chance, which is the ratio worth having.
        static let firstServeSpeed = Tennis3DCourt.metres(16.5)
        /// A second serve is safer and slower, as it should be.
        static let secondServeSpeed = Tennis3DCourt.metres(14)
        /// Nothing leaves a racket faster than this, whatever the maths says.
        static let maxBallSpeed = Tennis3DCourt.metres(30)

        /// 9.81 m/s², converted. No fudge factor — the court is the right size, so it works.
        static let gravity = Tennis3DCourt.metres(9.81)

        /// Quadratic drag, per world unit. Derived from a real ball: ½·ρ·Cd·A ÷ m is 0.0201 per
        /// metre, and dividing by `unitsPerMetre` puts it in the units the integrator uses.
        static let drag = 0.0201 / Tennis3DCourt.unitsPerMetre

        /// How hard topspin pushes a ball down, as an acceleration per unit of horizontal
        /// speed. At full spin and rally pace this is about 0.7 g of extra dip — heavy topspin,
        /// which is exactly what lets a shot be hit hard and still land in.
        static let magnus = 0.45

        /// Hard court: a ball comes off at about three-quarters of the speed it arrived, and
        /// loses about a third of its pace along the ground.
        ///
        /// The friction figure was 0.76, and it was the single biggest reason nobody could
        /// return serve. A serve bouncing on the service line kept so much pace that its
        /// **second** bounce was four and a half metres past the baseline — the ball went by the
        /// receiver at chest height with a metre a second of closing speed to spare. At 0.64,
        /// which is what a real hard court does to a ball with this much topspin, the same serve
        /// dies around the baseline and can be met.
        static let bounceRestitution = 0.73
        static let bounceFriction = 0.64

        /// Players. 6.5 m/s flat out, and legs that can change that by 18 m/s² — which is what
        /// makes the difference between a lunge and a stroll feel like a decision.
        static let playerTopSpeed = Tennis3DCourt.metres(6.5)
        /// Alex's legs are the third thing `difficulty` moves. At 0 she is a plodder; at 1 she
        /// covers the court slightly faster than the player can.
        static var npcTopSpeed: Double { Tennis3DCourt.metres(5.4 + 1.4 * clampedDifficulty) }
        static let acceleration = Tennis3DCourt.metres(18)
        static let braking = Tennis3DCourt.metres(26)
        /// Degrees a second the body can re-aim. Low enough that a sudden change of direction
        /// is visibly a side-step rather than a pirouette.
        static let turnRate: Double = 420
        static let strideLength = Tennis3DCourt.metres(2.3)

        /// How far the racket head reaches from the shoulder, and how big its sweet spot is.
        /// A real head is 13 cm across; this is nearly seven times that, because a real one is
        /// unplayable with a thumb on a phone.
        ///
        /// 0.42 m rather than the 0.30 m it started at. With everything else fixed, a well-run
        /// return was landing between 0.44 m and 0.57 m of the strings — close enough that the
        /// difference between a hit and a miss was a rounding error in the run-up, which reads
        /// as the game cheating. At 0.42 the good ones go in and the ones half a metre out still
        /// do not, so where you stand still decides the point.
        static let racketLength = Tennis3DCourt.metres(0.62)
        static let sweetRadius = Tennis3DCourt.metres(0.42)

        /// **How far the racket hand may be raised or dropped from the waist-high groundstroke**,
        /// in rig units. The one thing that decides which balls exist as shots at all.
        ///
        /// The choreography used to hold the strings at 0.99 m and nothing moved them, which made
        /// a ball at 1.5 m — an ordinary shoulder-high forehand — a ball you could only duck
        /// under. Seven of the eleven player misses in a measured pair of matches were exactly
        /// that, every one of them with the player already flat against the back fence with
        /// nowhere left to retreat to. A deep topspin ball kicks on six metres past the baseline
        /// and there are only 2.8 m of run-back, so retreating was never going to be the answer:
        /// the racket had to go up.
        ///
        /// Twelve units of hand is about 2.1 m of strings, because the arm rotates as it rises
        /// and the racket amplifies the rotation roughly two and a half times. Six units down is
        /// 0.61 m, which is a ball at the ankles. See `lift(forBallHeight:)`.
        static let strikeLiftUp: Double = 12
        static let strikeLiftDown: Double = 6

        /// Swing timings, in seconds.
        static let backswingTime: Double = 0.22
        static let forwardSwingTime: Double = 0.13
        static let followThroughTime: Double = 0.28
        /// The soonest a player can start another swing after finishing one.
        static let swingCooldown: Double = 0.12

        /// How long the ball may do nothing at all — no bounce, no bat, no net — before the
        /// point is abandoned and replayed. A ball in play bounces every second or so, so this
        /// only ever fires on a bug: a toss that strayed off court, or a shot that somehow left
        /// the world without `resolveDeadBall` catching it. Without it the game simply hangs,
        /// with no timer running and nothing to press.
        static let ballEventTimeout: Double = 8

        /// How good Alex is, from 0 (a friendly hit-up) to 1 (as good as the simulation allows).
        ///
        /// One knob rather than three, because "make her harder" is the only thing anyone will
        /// ever actually want. `Tennis3DDifficulty` is the three named notches on it that the
        /// buttons under the scoreboard set, and `-tennisdifficulty <0…1>` overrides it outright
        /// for a balancing run.
        ///
        /// Measured against the `-tennis3ddemo` bot, which reads the ball perfectly and has no
        /// reaction time, so it is a good deal better than a ten-year-old: at 0.5 it won 16
        /// points out of 16, at 1.0 it won 10 out of 16. 0.6 leaves Joel a match he can win
        /// while Alex still takes points off him. Turn it up as he gets better.
        static var difficulty: Double = 0.6

        /// How long the opponent takes to react to a shot before it starts moving.
        static var npcReaction: Double { 0.34 - 0.24 * clampedDifficulty }

        /// How far off perfect the opponent positions itself, at most — in **each** of x and y,
        /// so the diagonal is worse again.
        ///
        /// It was 1.5 m falling to 0.4 m, which at the default difficulty put her feet up to
        /// 0.84 m out in each axis against a sweet spot of 0.42 m. An error deliberately set
        /// larger than the target is not "slightly worse", it is a coin toss on whether she can
        /// play the ball at all — and it is why a service game was a run of aces she never
        /// swung at. She should reliably *get* to the ball at every level, and the level should
        /// decide how good the reply is: how quickly she sets off, how fast she runs, and how
        /// well she aims.
        static var npcPositionError: Double {
            Tennis3DCourt.metres(0.62 - 0.47 * clampedDifficulty)
        }

        /// **How much bigger the player's sweet spot is than Alex's**, which is the one lever
        /// `difficulty` has on the player's own side of the net.
        ///
        /// Everything else the setting touches is Alex — her reactions, her legs, her positioning,
        /// her aim — and a measured pair of matches said that was not enough. A bot that reads the
        /// ball perfectly and has no reaction time came out *level* with her on Easy, which means
        /// a ten-year-old loses every match on the setting whose whole job is to let him win. And
        /// in twenty points not one ball went out or into the net: every single point ended with
        /// somebody failing to reach a ball. So the strike zone is the only thing worth making
        /// easier, because it is the only thing the game is made of.
        ///
        /// Anchored at 1.0 on Normal, so the balance measured across three previous sessions is
        /// exactly the balance that ships. Easy is a 0.50 m sweet spot, Hard is 0.33 m.
        static var playerReachScale: Double { 1 + (0.6 - clampedDifficulty) * 0.75 }

        /// How hard Alex hits a groundstroke, relative to the player. More pace is less time to
        /// get there, which is the difference a difficulty setting ought to make and did not.
        static var npcPaceScale: Double { 0.80 + 0.34 * clampedDifficulty }

        /// How far off centre Alex aims, as a fraction of her half-court. The player's is a fixed
        /// 0.38–0.78 — see the table in `planShot`, where that range was measured. Hers is that
        /// range on Normal, pulled in on Easy and pushed towards the lines on Hard.
        static var npcAimRange: (Double, Double) {
            (0.34 + 0.15 * clampedDifficulty, 0.70 + 0.28 * clampedDifficulty)
        }

        /// **How far a badly struck ball misses by** — the pace error and the launch-angle error
        /// applied to a shot of the worst possible quality, as fractions.
        ///
        /// Every previous session measured the same thing and none of them acted on it: across
        /// twenty points, *not one ball went out or into the net*. Every single point ended with
        /// somebody failing to reach one. That is because `launchBall` solves the launch to land
        /// on the target whatever the swing was like, so `quality` could only ever take pace off
        /// and drag the aim towards the middle — a bad shot was a weak shot, never a miss.
        ///
        /// A real mishit is not "I aimed somewhere safer", it is "I meant to hit it there and I
        /// did not". So the error goes on **after** the solver has done its work, which is also
        /// what makes it interesting: aiming deep is now genuinely risky, because the margin
        /// between the target and the baseline is what a mishit eats. Position and timing decide
        /// how much you can get away with.
        /// `random.spread` averages three signed samples, so it is triangular about zero and its
        /// useful width is about a third of the number given to it. These are the full width, and
        /// a first pass at 0.10/0.13 produced a measured error rate of exactly zero — a 1% pace
        /// error cannot miss a target with two metres of margin behind it.
        static let mishitPace = 0.76
        static let mishitLoft = 0.92

        /// How far the racket face swings off line on the worst shot, in **radians**. A ball
        /// travels about eighteen metres, so 0.09 full width — a third of that in practice — is
        /// roughly half a metre of sideways error, against an `aimX` clamped half a metre inside
        /// the singles line. Enough to go wide when you were already going for the line.
        static let mishitFace = 0.14

        /// How badly a ball has to be struck before it starts to go astray at all. Below this,
        /// contact is exact — see the note in `strike`.
        static let mishitThreshold = 0.20

        /// A clean shot is never a mishit, so this scales with how badly it was struck — and with
        /// difficulty, on both sides of the net. Easy forgives the player and punishes Alex.
        static var playerMishitScale: Double { 0.45 + 0.92 * clampedDifficulty }
        static var npcMishitScale: Double { 1.30 - 0.95 * clampedDifficulty }

        private static var clampedDifficulty: Double { min(max(difficulty, 0), 1) }

        /// Games needed to win the match, and so the badge. Two or four, chosen by the buttons
        /// under the scoreboard — see `Tennis3DMatchLength`. Read fresh every time a game ends,
        /// so switching mid-match simply changes how many more are needed.
        static var gamesToWinMatch: Int {
            #if DEBUG
            if let override = WalkTest.tennisGamesToWin { return override }
            #endif
            return Tennis3DMatchLength.current.games
        }

        /// Physics sub-step. Fixed, so the simulation does not change with the frame rate —
        /// which determinism requires, and which also stops a fast ball tunnelling through the
        /// net on a dropped frame.
        static let physicsStep: Double = 1.0 / 240.0
    }

    // MARK: - State

    /// One of the two players. A class because both the frame and the AI hold on to it.
    final class Side {
        let isPlayer: Bool
        var appearance: GameCharacter

        /// **Everything about how this player moves**, body and arms alike — the same
        /// `CharacterMotor` the overworld player and every NPC in the school run on.
        ///
        /// It used to be a bare `LocomotionState` plus a `moveTarget` tuple plus, in the swing
        /// code, a remembered racket-head position so the contact test could work out how fast
        /// the strings were going. All three are the motor's now: it holds the destination, it
        /// holds the hand, and it holds the hand's velocity.
        let motor: CharacterMotor
        var swing = SwingState()

        /// Counts down before the opponent reacts to a shot.
        var reactionDelay: Double = 0

        /// Where this player was standing when the ball was last put in play against them.
        ///
        /// `intercept(for:)` scores candidate meeting points by how far the player has to move
        /// to reach them, and it has to measure that from a **fixed** point. Measuring from
        /// where they are right now is a feedback loop: step towards the ball and the earlier,
        /// shallower part of its path becomes the cheaper option, which pulls you a step further
        /// forward, which makes an earlier part cheaper still. Both players used to walk
        /// themselves all the way to the service line during a serve and let it fly over their
        /// shoulder, which is why nobody could break.
        var anchor: (x: Double, y: Double) = (0, 0)
        /// Deterministic positioning error for this shot, so it does not jitter every frame.
        var positionBias: (x: Double, y: Double) = (0, 0)

        /// The sign of the Y half this player defends: +1 for the near player, −1 for the
        /// opponent. Almost every rule in the game is expressed against it.
        var half: Double { isPlayer ? 1 : -1 }

        init(isPlayer: Bool, appearance: GameCharacter) {
            self.isPlayer = isPlayer
            self.appearance = appearance
            motor = CharacterMotor(profile: LocomotionProfile(
                maxSpeed: isPlayer ? Tuning.playerTopSpeed : Tuning.npcTopSpeed,
                acceleration: Tuning.acceleration,
                braking: Tuning.braking,
                turnRate: Tuning.turnRate,
                strideLength: Tuning.strideLength))
            // The court is measured in metres, not in school corridors: a character the motor
            // would happily call "arrived" at 4 units away is a third of a metre off the ball.
            motor.arrivalRadius = Tennis3DCourt.metres(0.12)
            motor.arrivalGain = 4.5
            // A swing throws the hand thirty units in a tenth of a second, and the ball is hit
            // where the strings **actually are**. So the arm has to track the choreography
            // tightly, and `approachGain` is the number that decides how tightly: it is a
            // first-order chase with a time constant of `1 / gain` seconds, and a hand chasing a
            // target moving at 230 units a second trails it by exactly `speed / gain`.
            //
            // At the default gain of 14 that trail is 16 units — 0.6 m — and every serve in the
            // match was a double fault, the racket passing 0.6 m under a ball tossed to where
            // the choreography said the strings would be. At 120 it is 2 units, seven
            // centimetres, comfortably inside a 0.45 m sweet spot and still visibly an arm with
            // some weight in it rather than a teleport.
            var arm = LimbProfile.arm
            arm.maxSpeed = 1400
            arm.acceleration = 40_000
            arm.approachGain = 120
            arm.engageTime = 0.05
            arm.releaseTime = 0.12
            motor.setLimbProfile(.rightHand, arm)
            motor.setLimbProfile(.leftHand, arm)
        }

        /// Where this player is being sent, or nil if they are holding position. Reads through
        /// to the motor, which owns it.
        var moveTarget: (x: Double, y: Double)? {
            get { motor.destination }
            set {
                if let newValue {
                    motor.moveCharacterTo(x: newValue.x, y: newValue.y)
                } else {
                    motor.holdPosition()
                }
            }
        }
    }

    /// A swing in progress. See `Tennis3DGame+Players` for how it poses the rig and where the
    /// racket head ends up.
    struct SwingState {
        enum Stage { case idle, backswing, forward, follow }

        var stage: Stage = .idle
        /// Seconds into the current stage.
        var elapsed: Double = 0
        var isServe = false
        /// True when the ball is on the far side of the body and the arm has to cross it.
        var isBackhand = false
        /// **How high this particular swing is played**, in rig units above the waist-high
        /// default. Set once, at `beginSwing`, from the height the ball is predicted to be at
        /// when the strings arrive; read by the choreography, so what is drawn and what the
        /// contact test sees are the same racket. 0 is a waist-high forehand.
        var lift: Double = 0
        /// Where the shot is aimed, in world XY.
        var aim: (x: Double, y: Double) = (0, 0)
        /// 0…1 — how hard, and how much topspin comes with it.
        var power: Double = 1
        var topspin: Double = 0.6
        /// Set once contact is made, so a single swing cannot hit the ball twice.
        var hasStruck = false
        var cooldown: Double = 0
        /// The closest the head ever got to the ball during the forward swing, and where the
        /// ball was at that moment. Diagnostic only — it is the difference between "you were
        /// nowhere near" and "you were four centimetres out", which is not a distinction any
        /// other number in the game makes.
        var closestApproach: Double = .infinity
        var closestBall: SIMD3<Double> = .zero

        var isSwinging: Bool { stage != .idle }
    }

    /// What the point is doing. Everything that is not `rally` is a pause of some kind, which
    /// is where the game gets its rhythm.
    enum Phase {
        /// The cinematic walk-on at the start of a match.
        case walkOn
        /// Both players moving to their marks before a serve.
        case toMarks
        /// The server has the ball in hand, about to toss.
        case ready
        /// The ball is up; the serve has not been struck yet.
        case toss
        /// Live.
        case rally
        /// The point is decided; the banner is up and the clock is running down.
        case pointOver
        /// The match is decided.
        case matchOver
    }

    var phase: Phase = .walkOn
    /// Seconds left in whatever pause `phase` describes.
    var phaseTimer: Double = 0

    /// True from the moment a serve is struck until it either lands in its box or is called a
    /// fault. It is what makes the return rules different from the rally rules.
    var isServeInFlight = false
    /// The next serve continues the point rather than starting a new one — a second serve, or
    /// a let being replayed.
    var serveIsReplay = false

    /// Seconds since the ball left the server's hand, and the moment the racket is meant to
    /// meet it. A serve is the one shot where the player is standing still and the ball is
    /// going exactly where it was put, so the timing is solved outright rather than searched
    /// for — see `tossBall()`.
    var tossElapsed: Double = 0
    var serveStrikeTime: Double = 0

    let player: Side
    let npc: Side

    var ball = Ball()
    var score = MatchScore()

    /// Which side serves this point, and from which court.
    var serverIsPlayer = false
    var deuceCourt = true
    var faults = 0

    /// The banner text the HUD shows. Set by the rules, cleared on its own timer.
    var announcement: Announcement?

    /// Which of the three named levels is in force, and the one place anything outside the
    /// simulation sets it. Writing it moves `Tuning.difficulty` — which is what Alex's reactions,
    /// her positioning and her legs are all derived from — and remembers the choice for next
    /// time. Safe to change mid-match: nothing caches a value off it.
    var difficulty: Tennis3DDifficulty = .normal {
        didSet {
            Tennis3DDifficulty.current = difficulty
            Tuning.difficulty = difficulty.value
            onPresentationChanged?()
        }
    }

    /// How long the match is. Same shape as `difficulty`: the buttons write it, it remembers
    /// itself, and `Tuning.gamesToWinMatch` reads it back out rather than caching a copy.
    var matchLength: Tennis3DMatchLength = .short {
        didSet {
            Tennis3DMatchLength.current = matchLength
            onPresentationChanged?()
        }
    }

    /// Seconds since the player last told anyone where to stand. Starts at infinity — nobody has
    /// touched the screen yet — which is what puts the controls hint up in the first place and
    /// brings it back if they stop playing.
    private(set) var secondsSinceSteer: Double = .infinity

    /// Shots in the point so far, the serve included, and the best of the match.
    ///
    /// It is on the screen because a ten-year-old counting his own rally out loud is most of the
    /// fun of the game, and it is in the trace because "how long are the rallies" was the one
    /// question every balancing run has had to answer with `awk`.
    var rallyShots = 0
    var longestRally = 0

    /// Seconds since anything happened to the ball: a toss, a bounce, a net cord, a strike.
    /// The watchdog in `advancePhase` reads it. Not the length of the point — a twenty-shot
    /// rally resets it on every shot — so a legitimately long point never trips it.
    var timeSinceBallEvent: Double = 0

    /// Deterministic randomness. Re-seeded from the score at the start of every point, so the
    /// same scoreline always produces the same rally — which is what makes a bug reproducible.
    var random = DeterministicRandom(seed: 1)

    /// The court geometry, built once. Around eighty primitives that never move.
    private var staticGeometry: [ScenePrimitive] = []

    /// Where the camera is looking, eased rather than snapped.
    private var cameraFocus = SIMD2<Double>(0, Tennis3DCourt.halfLength * 0.35)
    private var cameraSettled = false

    unowned let host: MinigameHost
    private var active = false

    /// Raised whenever the score or the banner changes, so the HUD can refresh without
    /// polling every frame.
    var onPresentationChanged: (() -> Void)?

    /// The last camera the game drove, so the HUD can turn a finger into a point on the court.
    private(set) var lastCamera = Camera()

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host

        var mine = myCharacter ?? GameCharacter(id: 1, name: "You", width: 40, height: 40,
                                                gender: "male", shirt_color: "#2ecc71")
        mine.holding = "tennis_racket"
        mine.emote = nil
        mine.default_emote = nil
        mine.hide_nameplate = true
        player = Side(isPlayer: true, appearance: mine)

        // The tennis map authors no NPCs, so the opponent is built here — deterministically, so
        // it is the same person every time you walk onto the court.
        var opponent = npcs.first ?? GameCharacter(id: 9001, name: "Alex", width: 40, height: 40,
                                                   gender: "female", shirt_color: "#e74c3c")
        opponent.id = opponent.id == mine.id ? opponent.id + 1 : opponent.id
        opponent.holding = "tennis_racket"
        opponent.emote = nil
        opponent.default_emote = nil
        opponent.hide_nameplate = true
        opponent.pants_color = opponent.pants_color ?? "#ecf0f1"
        npc = Side(isPlayer: false, appearance: opponent)
    }

    // MARK: - Lifecycle

    func start() {
        difficulty = Tennis3DDifficulty.current
        matchLength = Tennis3DMatchLength.current
        #if DEBUG
        // The launch argument wins, so a balancing run is not at the mercy of whatever was last
        // pressed on the device.
        if let override = WalkTest.tennisDifficulty { Tuning.difficulty = override }
        #endif
        Log.world("[Tennis3D] Starting on a \(Int(Tennis3DCourt.length))-unit court, "
                  + "difficulty \(String(format: "%.2f", Tuning.difficulty))")
        active = true
        staticGeometry = Tennis3DCourt.staticPrimitives()

        score = MatchScore()
        faults = 0
        serverIsPlayer = true
        deuceCourt = true
        rallyShots = 0
        longestRally = 0
        random.reseed(0xA11CE)

        // Walk on from behind the baselines, as the 2D game did — it is the one bit of
        // stagecraft that version had and it is worth keeping.
        // Measured from the *playable* edge, not the painted one: the apron is now barely wider
        // than the frame, and a walk-on that starts outside the fence spends its first second
        // being shoved back in by the clamp in `run`.
        player.motor.teleport(x: -Tennis3DCourt.metres(2),
                                   y: Tennis3DCourt.playableHalfLength,
                                   facing: 270)
        npc.motor.teleport(x: Tennis3DCourt.metres(2),
                                y: -Tennis3DCourt.playableHalfLength,
                                facing: 90)
        player.moveTarget = (x: 0, y: Tennis3DCourt.halfLength - Tennis3DCourt.metres(1.2))
        npc.moveTarget = (x: 0, y: -Tennis3DCourt.halfLength + Tennis3DCourt.metres(1.2))

        ball.parkOffCourt()
        phase = .walkOn
        phaseTimer = 0
        cameraSettled = false

        announce("St Peters Open", subtitle: "First to \(Tuning.gamesToWinMatch) games", duration: 2.6)
        host.minigamePlayBackground(path: "/media/hushed_crowd.mp3", volume: 0.45)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        staticGeometry = []
        host.minigameStopBackground()
    }

    /// The exit button in the button bar.
    func requestExit() {
        host.minigameShowDialog("Leave the match and head back to school?") { [weak self] in
            self?.host.minigameChangeMap(0)
        }
    }

    // MARK: - Frame

    func update(dt: Double) {
        guard active else { return }

        secondsSinceSteer += dt

        // An aim the player never got to use goes away on its own, rather than being spent on
        // some ball two rallies later that they have long forgotten choosing a target for.
        if playerAim != nil {
            playerAimAge += dt
            if playerAimAge > 8 { clearAim() }
        }

        if var current = announcement {
            current.remaining -= dt
            if current.remaining <= 0 {
                announcement = nil
                onPresentationChanged?()
            } else {
                announcement = current
            }
        }

        advancePhase(dt: dt)

        // Both players are steered every frame, whatever the phase — walking to their marks
        // between points is the same code as chasing a ball down.
        steerPlayer(dt: dt)
        steerOpponent(dt: dt)

        // The ball, the swings and the contact test all run on a fixed sub-step so the result
        // does not depend on the frame rate. `dt` is already clamped to 100 ms upstream, so the
        // loop is bounded at 24 iterations.
        if phase == .toss { tossElapsed += dt }

        var remaining = dt
        while remaining > 1e-6 {
            let step = min(Tuning.physicsStep, remaining)
            remaining -= step
            advanceSwing(player, dt: step)
            advanceSwing(npc, dt: step)
            advanceBall(dt: step)
        }
    }

    /// The pauses between points, and the walk-on at the start.
    private func advancePhase(dt: Double) {
        switch phase {
        case .walkOn:
            if atRest(player) && atRest(npc) {
                // Onto the serving marks, the same as between every other point. This used to
                // fall straight through to `.toMarks` with the walk-on positions still in place,
                // so the very first point of a match was played from the wrong end of the court
                // — the receiver stood two and a half metres inside their baseline.
                moveToServeMarks()
            }

        case .toMarks:
            phaseTimer -= dt
            if phaseTimer <= 0 && atRest(server) {
                beginServe()
            }

        case .ready:
            phaseTimer -= dt
            if phaseTimer <= 0 { tossBall() }

        case .toss, .rally:
            // The watchdog. Every phase but these two has a timer counting down to the next
            // thing; a live ball has nothing, so a ball that stops mattering — off the map, or
            // stuck — used to leave the game with no way forward at all.
            timeSinceBallEvent += dt
            if timeSinceBallEvent > Tuning.ballEventTimeout {
                Log.world("[Tennis3D] Nothing has happened to the ball for "
                          + "\(Int(Tuning.ballEventTimeout))s — abandoning the point")
                abandonPoint()
            }

        case .pointOver:
            phaseTimer -= dt
            if phaseTimer <= 0 { setUpNextPoint() }

        case .matchOver:
            break
        }
    }

    var server: Side { serverIsPlayer ? player : npc }
    var receiver: Side { serverIsPlayer ? npc : player }

    /// On their mark **and stopped**. The speed test matters more than it looks: the serve is
    /// solved from where the server is standing, so one that begins while they are still
    /// drifting onto the mark puts the ball where they no longer are.
    private func atRest(_ side: Side) -> Bool {
        guard side.motor.speed < Tennis3DCourt.metres(0.4) else { return false }
        guard let target = side.moveTarget else { return true }
        return hypot(target.x - side.motor.x, target.y - side.motor.y)
            < Tennis3DCourt.metres(0.35)
    }

    /// Puts both players on their serving marks and starts the countdown to the toss.
    func moveToServeMarks() {
        let serveX = Tennis3DCourt.serveStanceX(isPlayer: serverIsPlayer, deuceCourt: deuceCourt)
        let baseline = Tennis3DCourt.halfLength + Tennis3DCourt.metres(0.6)

        server.moveTarget = (x: serveX, y: server.half * baseline)

        // The receiver stands just behind their own baseline, on the diagonal the serve is
        // coming down.
        //
        // Two metres back, which is what this was, is behind the **whole** window in which the
        // serve is at racket height. A serve here lands about a metre inside the service line,
        // comes off the court at 5.5 m/s upward, peaks a metre and a half up around mid-court
        // and is back down to knee height a metre past the baseline. So the receiver stood
        // watching it die at her feet, never swung, and every service game was a run of aces
        // that no amount of tuning her legs or her reactions could have fixed — she was in the
        // wrong place before the ball was struck.
        let box = Tennis3DCourt.serviceBox(receiverHalf: receiver.half, deuceCourt: deuceCourt)
        let boxCentreX = (box.minX + box.maxX) / 2
        receiver.moveTarget = (x: boxCentreX * 1.15,
                               y: receiver.half * (baseline + Tennis3DCourt.metres(0.9)))

        phase = .toMarks
        phaseTimer = 0.5
    }

    // MARK: - Input

    /// **Where the player wants their strings**, which is what a finger on this game is
    /// actually pointing at.
    ///
    /// Everything on the court worth aiming at is a *contact* point — the green X is where the
    /// ball has to meet the racket — and the racket head hangs more than a metre in front of and
    /// to the side of the body. So steering the **feet** to the tapped point put the chest where
    /// the strings needed to be and let the ball go past inside the reach, which is the exact
    /// mistake the marker exists to prevent. Tapping the X used to be the wrong move.
    ///
    /// The offset is `contactHeadWorldOffset`, the same one `stance(toMeet:for:)` derives from
    /// the swing choreography, so "tap the X" and "stand on the faint ground mark" are now one
    /// instruction rather than two that disagree by a metre.
    func steer(racketToWorldX x: Double, y: Double) {
        let offset = contactHeadWorldOffset(for: player, lift: playerStrikeLift)
        steer(toWorldX: x - offset.x, y: y - offset.y)
    }

    /// Where the player's strings will pass if they stand exactly where they are. The point a
    /// grab-drag holds its offset from, so both gestures are spoken in the same units.
    var playerRacketAnchor: (x: Double, y: Double) {
        let offset = contactHeadWorldOffset(for: player, lift: playerStrikeLift)
        return (x: player.motor.x + offset.x, y: player.motor.y + offset.y)
    }

    /// **How high the player's next shot is going to be played.** Read off whatever ball is
    /// actually on the way; zero — the waist-high default — when there is nothing to play.
    ///
    /// The controls have to agree with the stroke about this. The green X floats at the height
    /// the strings will meet the ball, and a tap on it is unprojected onto that same plane, so a
    /// shot lifted to head height moves the marker, the plane the touch is read on and the racket
    /// offset all together. Getting one of the three wrong is worth about a metre of court from
    /// this camera angle.
    var playerStrikeLift: Double {
        guard let intercept = idealIntercept() else { return 0 }
        return lift(forBallHeight: intercept.z)
    }

    /// How high off the court a tap should be read at: the height the strings pass through.
    /// A finger aiming at a marker floating a metre up is not aiming at the ground under it —
    /// from this camera those are more than half a metre apart.
    var playerContactHeight: Double { headHeight(lift: playerStrikeLift) }

    /// A tap or a drag, already converted to a point on the court — **where the feet go**.
    ///
    /// Both gestures land here and mean the same thing — "be there". A tap sets it once; a drag
    /// keeps setting it as the finger moves, which is what turns it into steering. The
    /// difference between the two is entirely in `Tennis3DView`.
    func steer(toWorldX x: Double, y: Double) {
        guard active, phase != .matchOver else { return }
        secondsSinceSteer = 0
        player.moveTarget = (
            x: min(max(x, -Tennis3DCourt.playableHalfWidth), Tennis3DCourt.playableHalfWidth),
            // The player may not cross the net, and may not stand on the grass behind it.
            y: min(max(y, Tennis3DCourt.metres(0.6)), Tennis3DCourt.playableHalfLength)
        )
    }

    /// Drops the move target, so the player coasts to a halt where they are.
    func releaseSteering() {
        player.moveTarget = nil
    }

    /// **Where the player has asked their next shot to go**, or nil for the automatic aim.
    ///
    /// The one thing the control scheme could not say. A shot goes away from wherever Alex is
    /// standing, nudged by which way the player is sliding when they hit it, and that is a fine
    /// default for one thumb — but it means the player never chooses anything, and choosing where
    /// to put the ball is most of what tennis is.
    ///
    /// The gesture costs nothing to learn because it uses a part of the screen that could not
    /// mean anything else: **the far half of the court**. You cannot walk there — `steer` clamps
    /// the feet to your own side of the net — so a tap over there was previously just "run at the
    /// net". Now it is "put it there", it is one tap, and it needs no second finger.
    private(set) var playerAim: (x: Double, y: Double)?
    /// Seconds since the aim was set. It expires, so a target picked during a long point does not
    /// still be sitting there two rallies later.
    private var playerAimAge: Double = 0

    /// A tap on the opponent's half. Clamped inside the singles court with a margin, so choosing
    /// a target is never itself the error — miss it by enough and the shot still lands in.
    func aimShot(atWorldX x: Double, y: Double) {
        guard active, phase != .matchOver else { return }
        let margin = Tennis3DCourt.metres(0.6)
        playerAim = (
            x: min(max(x, -Tennis3DCourt.halfSingles + margin),
                   Tennis3DCourt.halfSingles - margin),
            y: min(max(y, -Tennis3DCourt.halfLength + margin), -Tennis3DCourt.metres(2.0))
        )
        playerAimAge = 0
        secondsSinceSteer = 0
    }

    /// Forgets the target. Called when the shot is played, and between points.
    func clearAim() {
        playerAim = nil
        playerAimAge = 0
    }

    // MARK: - Presentation

    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
    }

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.8) {
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration)
        onPresentationChanged?()
    }

    /// One line per thing that actually happens — a strike, a bounce judgement, a point — when
    /// `-tennis3dtrace` is on.
    ///
    /// The once-a-second sample that came with the flag turned out to be far too coarse to
    /// answer the question that mattered: a whole point is over in three seconds, so "the score
    /// went up and I do not know why" was all it ever said. Events are what a rally is made of.
    func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard WalkTest.traces3DTennis else { return }
        let line = "tennis3d · \(message())"
        Log.world(line)
        // And to a file in the container, which outlives the pipe. See `Tennis3DTraceFile`.
        Tennis3DTraceFile.write(line)
        #endif
    }

    /// The once-a-second sample, which the debug harness owns rather than the game. Here so that
    /// it lands in the same file as the events; a log with the events and not the positions is
    /// half a measurement.
    func traceSample(_ message: String) {
        #if DEBUG
        guard WalkTest.traces3DTennis else { return }
        Log.world(message)
        Tennis3DTraceFile.write(message)
        #endif
    }

    var backgroundColor: String? { Tennis3DCourt.skyHex }

    // MARK: - Scene

    var sceneCharacters: [MinigameCharacter] {
        [drawable(npc), drawable(player)]
    }

    private func drawable(_ side: Side) -> MinigameCharacter {
        var character = side.appearance
        character.x = side.motor.x
        character.y = side.motor.y
        character.z = side.motor.z
        character.rotation = side.motor.facing

        // The motor poses the limbs; the swing adds the shoulder coil and the roll of the
        // strings, which are not limbs. Nothing in this file writes a limb target.
        return MinigameCharacter(character: character,
                                 gait: side.motor.gait,
                                 poseOverride: side.motor.poseOverride(then: swingPose(for: side)))
    }

    var scenePrimitives: [ScenePrimitive] {
        var out = staticGeometry
        out.append(contentsOf: ballPrimitives())
        return out
    }

    var sceneModels: [SceneModel] { [Tennis3DCourt.stadiumModel] }

    // MARK: - Camera

    /// Frames the court from behind the player's baseline.
    ///
    /// The 2D game looked straight down. This keeps that reading — the whole court is on screen
    /// and the ball's position is unambiguous — but tips the camera over far enough to see that
    /// the players are solid and the net has depth. It follows the action gently rather than
    /// tracking the ball, because a camera that chases a 15 m/s ball is unwatchable.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        let viewportHeight = Double(viewport.y)
        guard viewportWidth > 0, viewportHeight > 0 else { return }

        // Zoom is set by width: the doubles court plus a stride of run-off either side has to
        // fit, whatever the device.
        //
        // **5.9 m, back up from 3.8, and the reason is measured rather than argued.**
        //
        // Part 5 cut this from 5.6 m to 3.8 m because "half the frame was ground nobody could
        // stand on — grey apron, then grass, then more grass". That is no longer what is out
        // there: the frame past the court is now the stadium's concrete surround, its benches,
        // its umpire chair and its stands, so the width buys scenery instead of costing it.
        //
        // Part 5 also recorded that at 3.8 m "the visible half-width down at the near baseline
        // works out at 7.1 m against a `playableHalfWidth` of 7.085 m — exactly on the edge".
        // **That number is wrong.** Measured off a screenshot — find the near baseline, count the
        // pixels between the doubles sidelines, scale the half-frame by the metres those pixels
        // are worth — it is **6.29 m**, and a player pinned against the side fence at their own
        // baseline has been three-quarters of a metre off the bottom corner of the screen for
        // five sessions. The ten-line script that measures it is in HANDOFF-tennis3d-part7.md,
        // which is also where the numbers below come from.
        //
        //   3.8 m → 6.26 m visible   5.9 m → 7.09 m visible   (playable half-width 7.085 m)
        //
        // So this is the width at which the playable rectangle is actually all on screen, which
        // matters more than it sounds: being in the wrong place is the only way to miss a ball,
        // and you cannot steer to a corner you cannot see.
        var desiredWidth = Tennis3DCourt.doublesWidth + Tennis3DCourt.metres(5.9)
        var pitch = 0.88
        #if DEBUG
        if let override = WalkTest.tennisCameraWidth { desiredWidth = Tennis3DCourt.metres(override) }
        if let override = WalkTest.tennisCameraPitch { pitch = override }
        #endif
        camera.zoom = max(0.35, viewportWidth / desiredWidth)
        // **Behind the player's shoulder, not overhead.** About where a television camera sits
        // behind the baseline, and it is the single biggest change to how the game reads: at
        // 0.34 both players were legible but tiny, two hats on a diagram of a court. Tipped
        // over, the near player is a person with a racket in their hand, the far one is
        // recognisably a person too, and the net has a front and a back.
        //
        // **0.88 rather than 0.80, because there is now something up there to see.** At 0.80 the
        // top of the frame stops at the inner wall of the arena and the stadium reads as a dark
        // green fence; eight hundredths further over and the stand rises into shot with its
        // seats in it. The tilt is nearly free in the dimension that constrains it — the near
        // baseline's visible half-width moves 6.29 → 6.26 m across 0.80 to 0.88, because tipping
        // the camera also walks the eye further away from the near baseline and the two cancel.
        //
        // It does not go much further. The camera orbits at a fixed distance set by the viewport
        // height, so tilt trades height for distance: by 0.95 the eye has dropped to 37 m and
        // slid back to 52 m, which is **inside the near stand**, and the bottom half of the
        // frame is the roof of it. 1.05 is worse. `-tennispitch` sweeps this without a rebuild.
        //
        // The cost is that a tap in the far half is worth much more court than a tap in the near
        // half, and that a marker floating a metre up sits well over a metre up-screen of the
        // ground beneath it. The second one would have been fatal to "tap the green X"; it is why
        // `Tennis3DView.worldPoint` cuts its ray at racket height rather than on the floor.
        // `-tennispitch` sweeps this without a rebuild.
        camera.pitch = pitch
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0

        // **Y does not follow anything.** It used to drift up to 1.8 m with the player, which was
        // worth it when a third of the frame was spare grass; now that the playable rectangle
        // only just fits the screen, every centimetre the court slides costs a player at one end
        // or the other. Parked 0.4 m towards the far baseline, which is the offset that keeps the
        // far player clear of the notch without standing the near one on the button bar.
        //
        // X still follows, gently, because the court is only a stride wider than the frame and a
        // player chasing a ball into the tramlines needs that stride to exist.
        let ballWeight = ball.inFlight ? 0.35 : 0.0
        let targetX = (player.motor.x * 0.5 + ball.x * ballWeight) / (0.5 + ballWeight)
        let clamped = SIMD2(
            min(max(targetX * 0.35, -Tennis3DCourt.metres(1.2)), Tennis3DCourt.metres(1.2)),
            Tennis3DCourt.metres(-0.4)
        )

        if cameraSettled {
            // Exponential ease in seconds, not in frames. 0.06 a frame at 60 Hz is the ~3.7/s
            // rate below, and now it is that rate whatever the display is running at.
            let step = 1 - exp(-3.7 * min(0.1, max(0, dt)))
            cameraFocus += (clamped - cameraFocus) * step
        } else {
            cameraFocus = clamped
            cameraSettled = true
        }

        // `Camera.update` biases the focus upward to leave headroom above the player's head,
        // which is right for the overworld and wrong for a court that has to stay centred.
        // Undoing it here is cheaper than making the bias configurable for one caller.
        let headroomBias = viewportHeight / camera.zoom * 0.15
        camera.update(playerX: cameraFocus.x,
                      playerY: cameraFocus.y + headroomBias,
                      viewport: viewport,
                      mapData: nil)
        lastCamera = camera
    }
}
