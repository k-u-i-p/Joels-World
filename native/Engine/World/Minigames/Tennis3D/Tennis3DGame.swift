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
        /// ever actually want. `-tennisdifficulty <0…1>` overrides it for a balancing run, and
        /// it is a `var` for exactly that reason — nothing in the game changes it mid-match.
        ///
        /// Measured against the `-tennis3ddemo` bot, which reads the ball perfectly and has no
        /// reaction time, so it is a good deal better than a ten-year-old: at 0.5 it won 16
        /// points out of 16, at 1.0 it won 10 out of 16. 0.6 leaves Joel a match he can win
        /// while Alex still takes points off him. Turn it up as he gets better.
        static var difficulty: Double = 0.6

        /// How long the opponent takes to react to a shot before it starts moving.
        static var npcReaction: Double { 0.34 - 0.24 * clampedDifficulty }
        /// How far off perfect the opponent positions itself, at most.
        static var npcPositionError: Double {
            Tennis3DCourt.metres(1.5 - 1.1 * clampedDifficulty)
        }

        private static var clampedDifficulty: Double { min(max(difficulty, 0), 1) }

        /// Games needed to win the match, and so the badge.
        static let gamesToWinMatch = 2

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
        var locomotion = LocomotionState()
        var swing = SwingState()

        /// Where the controller wants them to stand. Nil means "hold position".
        var moveTarget: (x: Double, y: Double)?
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
        /// Where the shot is aimed, in world XY.
        var aim: (x: Double, y: Double) = (0, 0)
        /// 0…1 — how hard, and how much topspin comes with it.
        var power: Double = 1
        var topspin: Double = 0.6
        /// Set once contact is made, so a single swing cannot hit the ball twice.
        var hasStruck = false
        var cooldown: Double = 0
        /// Where the racket head was on the previous sub-step, for the swept contact test.
        var previousHead: SIMD3<Double>?
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

    /// Seconds since the player last told anyone where to stand. Starts at infinity — nobody has
    /// touched the screen yet — which is what puts the controls hint up in the first place and
    /// brings it back if they stop playing.
    private(set) var secondsSinceSteer: Double = .infinity

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
        #if DEBUG
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
        random.reseed(0xA11CE)

        // Walk on from behind the baselines, as the 2D game did — it is the one bit of
        // stagecraft that version had and it is worth keeping.
        player.locomotion.teleport(x: -Tennis3DCourt.metres(2),
                                   y: Tennis3DCourt.surfaceHalfLength - 4,
                                   facing: 270)
        npc.locomotion.teleport(x: Tennis3DCourt.metres(2),
                                y: -Tennis3DCourt.surfaceHalfLength + 4,
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
        guard side.locomotion.speed < Tennis3DCourt.metres(0.4) else { return false }
        guard let target = side.moveTarget else { return true }
        return hypot(target.x - side.locomotion.x, target.y - side.locomotion.y)
            < Tennis3DCourt.metres(0.35)
    }

    /// Puts both players on their serving marks and starts the countdown to the toss.
    func moveToServeMarks() {
        let serveX = Tennis3DCourt.serveStanceX(isPlayer: serverIsPlayer, deuceCourt: deuceCourt)
        let baseline = Tennis3DCourt.halfLength + Tennis3DCourt.metres(0.6)

        server.moveTarget = (x: serveX, y: server.half * baseline)

        // The receiver stands well behind their own baseline, on the diagonal the serve is
        // coming down — two metres back, which is where a returner actually stands for a first
        // serve and, more to the point, where this one is still travelling when it gets there.
        let box = Tennis3DCourt.serviceBox(receiverHalf: receiver.half, deuceCourt: deuceCourt)
        let boxCentreX = (box.minX + box.maxX) / 2
        receiver.moveTarget = (x: boxCentreX * 1.15,
                               y: receiver.half * (baseline + Tennis3DCourt.metres(2.0)))

        phase = .toMarks
        phaseTimer = 0.5
    }

    // MARK: - Input

    /// A tap or a drag on the court, already converted to a point on the ground plane.
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
        Log.world("tennis3d · \(message())")
        #endif
    }

    var backgroundColor: String? { Tennis3DCourt.grassHex }

    // MARK: - Scene

    var sceneCharacters: [MinigameCharacter] {
        [drawable(npc), drawable(player)]
    }

    private func drawable(_ side: Side) -> MinigameCharacter {
        var character = side.appearance
        character.x = side.locomotion.x
        character.y = side.locomotion.y
        character.z = 0
        character.rotation = side.locomotion.facing

        return MinigameCharacter(character: character,
                                 gait: side.locomotion.gait,
                                 poseOverride: swingPose(for: side))
    }

    var scenePrimitives: [ScenePrimitive] {
        var out = staticGeometry
        out.append(contentsOf: ballPrimitives())
        return out
    }

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
        // Wide enough that the grass shows outside the apron on both sides, which is what keeps
        // the court reading as a court rather than as the whole world being hard standing.
        let desiredWidth = Tennis3DCourt.doublesWidth + Tennis3DCourt.metres(5.6)
        camera.zoom = max(0.35, viewportWidth / desiredWidth)
        camera.pitch = 0.52
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0

        // Follow the midpoint of the two things worth watching, damped hard and clamped so the
        // court never slides off the bottom of the screen.
        let ballWeight = ball.inFlight ? 0.35 : 0.0
        let target = SIMD2(
            (player.locomotion.x * 0.5 + ball.x * ballWeight) / (0.5 + ballWeight),
            (player.locomotion.y * 0.5 + ball.y * ballWeight) / (0.5 + ballWeight)
        )
        // Barely follows at all, and never far: the whole court has to stay on screen, with
        // both players inside it. Drifting with the action past that point loses the far
        // baseline off the top, which is the one edge that matters.
        let clamped = SIMD2(
            min(max(target.x * 0.35, -Tennis3DCourt.metres(1.6)), Tennis3DCourt.metres(1.6)),
            min(max(target.y * 0.18, -Tennis3DCourt.metres(0.8)), Tennis3DCourt.metres(1.8))
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
