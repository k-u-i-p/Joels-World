import Foundation
import simd

/// **School Escape** — Joel's game. Detention ran late, the school is locked and dark, and the
/// four keys that open the chest by the south corridor are scattered across the building. Mr
/// Hardy is still here, doing his rounds — and if he sees you, he comes for you.
///
/// The rules, exactly as drawn on Joel's map:
///
/// - **Ms Crosbie starts the game** — you spawn in her classroom, next to the orange key.
/// - **Four keys**: orange (her classroom), white (the east classroom), blue (the kitchen), and
///   green — in **Mr Hardy's own office**, where taking it slams the door behind you.
/// - **Collect all keys and open the chest to win.** The badge is `detention`, because that is
///   the story: you were given detention, and you got out of it.
/// - **The teacher jumpscares you.** Caught means the camera in your face, the ghostly sting,
///   and the last key you picked up goes back to where it was.
///
/// How Mr Hardy works: he walks a corridor patrol; picking up any key makes a noise he comes to
/// investigate; and if there is a clear line through the building from him to you — walls block
/// sight, and sight is tested against the same clip mask that blocks walking — he chases. He is
/// a touch slower than your sprint, so running works, but he does not give up until he has not
/// seen you for a while.
///
/// Structurally this is `FootballGame`'s twin: a `WorldRenderedMinigame` with a thumbstick, a
/// `CharacterMotor` per body and a camera that follows the player. The world is the real main
/// building — see `SchoolEscapeMap`.
final class SchoolEscapeGame: WorldRenderedMinigame {

    // MARK: - Tuning

    enum Tuning {
        /// Characters draw at 2.5× the rig, matching how big pupils look on the main building
        /// overworld — carried on `width`/`height` (2.5 × the 40 baseline) rather than on the
        /// map's `character_scale`, so `-schoolescape` with no map looks the same as map 8.
        static let characterSize: Double = 100
        /// Joel: "make everything bigger" — Mr Hardy most of all. He towers now.
        static let teacherSize: Double = 150

        /// Speeds are map pixels per second, scaled up from the overworld's 216 in the same
        /// ratio as the bodies. You can outrun him — just — and he never stops walking.
        /// 440 — Joel asked for 10% faster on top of the original 400.
        static let playerSpeed: Double = 440
        /// Degrees per second the stick turns your head at full deflection. Joel tried 170
        /// and 300 and asked for slower both times — a slow, deliberate look round is the
        /// horror-game feel he is after.
        static let turnSpeed: Double = 120
        static let chaseSpeed: Double = 345
        static let patrolSpeed: Double = 170
        static let investigateSpeed: Double = 250

        /// How far he can see, and how close counts as caught.
        ///
        /// The hunt is deliberately softer than it first was (sight 1000 → 850, chase 355 →
        /// 345, give-up 2.6 s → 1.8 s): measured with `-schoolescapedemo`, the original
        /// numbers meant an alerted Mr Hardy converted nearly every chase into a catch by
        /// cutting corridor corners, and four runs in a row died on the final key. A game a
        /// robot can never finish is not one a ten-year-old will love either.
        static let sightRange: Double = 850
        static let catchRadius: Double = 62
        static let keyRadius: Double = 80
        static let chestRadius: Double = 130

        /// Seconds without a sighting before a chase becomes "go and look where they were".
        static let loseSightAfter: Double = 1.8
        /// How long the office door stays locked after the green key is taken. Deliberately
        /// *shorter* than Mr Hardy's walk to it (~6 s at `investigateSpeed`), so the trap is a
        /// head start you have to use, not a cell you are caught in — at 6 s he was standing
        /// in the doorway when it opened, and nobody (the demo bot included) ever got out.
        static let doorLocked: Double = 4.5
        static let doorTravel: Double = 0.35
        /// The jumpscare, from catch to being put back at the spawn.
        static let jumpscare: Double = 1.9

        static let badgeId = "detention"
    }

    // MARK: - Phase

    enum Phase {
        case playing
        /// Mr Hardy has you. The camera is in his face and the view is flashing.
        case caught
        /// The chest is open. Panel up, badge claimed.
        case escaped
    }

    private(set) var phase: Phase = .playing

    // MARK: - The teacher

    enum TeacherState {
        case patrolling
        /// Heading to a noise — a key pickup, or your last known position after a lost chase.
        case investigating(SIMD2<Double>)
        case chasing
    }

    private(set) var teacherState: TeacherState = .patrolling
    private var patrolIndex = 0
    /// Seconds since the teacher last actually saw the player, while chasing.
    private var sinceSeen: Double = 0
    /// Seconds the teacher has been stuck against a wall, to skip an unreachable waypoint.
    private var stuckFor: Double = 0
    private var sirenPlaying = false

    // MARK: - State

    struct KeyState {
        var key: SchoolEscapeMap.Key
        var collected = false
    }

    private(set) var keys: [KeyState] = SchoolEscapeMap.keys.map { KeyState(key: $0) }
    /// The order keys were picked up, so being caught hands back the most recent one.
    private var collectedOrder: [Int] = []
    var keysHeld: Int { keys.filter(\.collected).count }
    var totalKeys: Int { keys.count }

    /// **Joel's ask: "3d as eyes so your looking out the eyes."** True is first-person: the
    /// camera rides in your character's head, the stick turns and walks, and your own body is
    /// not drawn (you cannot see yourself from inside your eyes). False is the top-down night
    /// camera. The VIEW button on screen flips it.
    private(set) var eyesMode = true

    func toggleView() {
        eyesMode.toggle()
        cameraSettled = false
        onPresentationChanged?()
    }

    private(set) var elapsed: Double = 0
    private var caughtFor: Double = 0
    /// Seconds after a respawn in which Mr Hardy neither sees nor catches — he has just
    /// marched you back and is feeling pleased with himself. Without it he lingered near the
    /// spawn after a catch and took the rest of your keys one by one as you appeared.
    private var graceFor: Double = 0
    private(set) var timesCaught = 0
    private(set) var chestOpen = false
    private var chestHintAt: Double = -10

    /// Office door: seconds of lock left, and where the door visibly is (0 open, 1 shut).
    private var doorLockTimer: Double = 0
    private var doorPosition: Double = 0

    /// The best escape, in seconds, remembered like School Rush remembers its best run.
    private(set) var bestTime: Double = UserDefaults.standard.double(forKey: bestKey)
    private static let bestKey = "schoolescape.best"

    private var badgeClaimed = false
    private var active = false
    private var mask: ClipMask?

    private let playerMotor = CharacterMotor(profile: LocomotionProfile(
        maxSpeed: Tuning.playerSpeed, acceleration: 2200, braking: 3200,
        turnRate: 540, strideLength: 185))
    private let teacherMotor = CharacterMotor(profile: LocomotionProfile(
        maxSpeed: Tuning.chaseSpeed, acceleration: 1400, braking: 2000,
        turnRate: 420, strideLength: 200))

    private var playerAppearance: GameCharacter
    private var teacherAppearance: GameCharacter

    private var moveInput = SIMD2<Double>(0, 0)

    struct Announcement {
        var text: String
        var subtitle: String?
        var remaining: Double
    }

    private(set) var announcement: Announcement?
    var onPresentationChanged: (() -> Void)?

    unowned let host: MinigameHost

    // MARK: - Lifecycle

    init(host: MinigameHost, npcs: [GameCharacter], myCharacter: GameCharacter?) {
        self.host = host
        _ = npcs

        var player = myCharacter ?? GameCharacter(id: 0, name: nil, width: 40, height: 40)
        player.id = 9400
        player.model = player.model ?? "boy"
        player.width = Tuning.characterSize
        player.height = Tuning.characterSize
        player.hide_nameplate = true
        player.emote = nil
        player.default_emote = nil
        player.holding = nil
        player.z = 0
        playerAppearance = player

        // Mr Hardy: the man model in his sold outfit, bigger than you.
        var teacher = GameCharacter(id: 9401, name: "Mr Hardy",
                                    width: Tuning.teacherSize, height: Tuning.teacherSize)
        teacher.model = "man"
        teacher.hide_nameplate = true
        teacher.z = 0
        teacherAppearance = teacher

        playerMotor.model = playerAppearance.model
        teacherMotor.model = "man"
    }

    func start() {
        active = true
        Log.world("[SchoolEscape] Lights out — find \(totalKeys) keys, open the chest")
        beginRun()

        // The same clip mask the overworld walks the main building with. Until it arrives —
        // well under a second — nothing clips and the teacher cannot see, which no one has
        // ever noticed.
        ClipMask.load(path: "main_building/clip_mask.png",
                      mapW: SchoolEscapeMap.mapWidth,
                      mapH: SchoolEscapeMap.mapHeight) { [weak self] mask in
            self?.mask = mask
        }
    }

    /// Everything a fresh run resets. The Play-again button calls it too.
    func beginRun() {
        phase = .playing
        elapsed = 0
        timesCaught = 0
        chestOpen = false
        badgeClaimed = false
        doorLockTimer = 0
        doorPosition = 0
        collectedOrder = []
        for index in keys.indices { keys[index].collected = false }

        playerMotor.teleport(x: SchoolEscapeMap.spawn.x, y: SchoolEscapeMap.spawn.y, facing: 0)
        teacherMotor.teleport(x: SchoolEscapeMap.teacherSpawn.x,
                              y: SchoolEscapeMap.teacherSpawn.y, facing: 180)
        teacherState = .patrolling
        patrolIndex = 0
        sinceSeen = 0
        sirenPlaying = false

        host.minigamePlayBackground(path: "/media/ticking_clock.mp3", volume: 0.35)
        announce("ESCAPE THE SCHOOL",
                 subtitle: "Find \(totalKeys) keys · open the chest · don't get caught",
                 duration: 3.2)
        onPresentationChanged?()
    }

    func stop() {
        active = false
        host.minigameSetFootsteps(active: false, isRunning: false)
        host.minigameStopBackground()
    }

    /// The exit button in the button bar. Back to the main building, where the way in is.
    func requestExit() {
        host.minigameShowDialog("Give up and sneak back to bed?") { [weak self] in
            self?.host.minigameChangeMap(2)
        }
    }

    /// The Play-again button on the escape panel.
    func restartRun() {
        guard active else { return }
        beginRun()
    }

    // MARK: - Input

    /// The thumbstick, sampled by `SchoolEscapeView.step()` every rendered frame — with zero
    /// when nothing touches it, which is why the demo latch below exists (see Football's
    /// statue bug).
    func setMoveInput(_ move: SIMD2<Double>) {
        #if DEBUG
        if debugDrivesInput { return }
        #endif
        moveInput = move
    }

    // MARK: - Walkability

    /// One question for both feet and eyes: can you be here / see through here? The clip mask
    /// answers for the building, and the office door answers for itself while it is shut.
    private func isOpen(_ x: Double, _ y: Double) -> Bool {
        if doorPosition > 0.5, SchoolEscapeMap.officeDoor.contains(x, y) { return false }
        guard let mask else { return true }
        return mask.isWalkable(worldX: x, worldY: y)
    }

    /// Wall sliding: the proposed step, then each axis alone, so running diagonally into a wall
    /// walks you along it instead of gluing you to it.
    private func constrain(_ motor: CharacterMotor)
        -> (Double, Double) -> (x: Double, y: Double) {
        { [weak self] proposedX, proposedY in
            guard let self else { return (proposedX, proposedY) }
            if self.isOpen(proposedX, proposedY) { return (proposedX, proposedY) }
            if self.isOpen(proposedX, motor.y) { return (proposedX, motor.y) }
            if self.isOpen(motor.x, proposedY) { return (motor.x, proposedY) }
            return (motor.x, motor.y)
        }
    }

    private var escapeRotation = 0

    /// A way out of a corner pocket: an open direction, trying backwards and sideways before
    /// forwards — leaving a pocket means backing out of it, not pushing on. Used by Mr Hardy
    /// and the demo bot whenever the wall-slide leaves them wedged; a thumb does this without
    /// being taught.
    ///
    /// Two details bought with an hour of watching a frozen teacher: **every step of the way
    /// out is tested**, not just the far end — a probe that jumps 140 px skips clean over the
    /// wall it is standing against and picks a direction that goes nowhere; and **each attempt
    /// starts the search somewhere new**, so a failed escape tries a different way out instead
    /// of the same dead one forever.
    private func openDirection(from x: Double, _ y: Double,
                               toward target: SIMD2<Double>) -> SIMD2<Double> {
        let base = atan2(target.y - y, target.x - x)
        let offsets: [Double] = [.pi, 2.4, -2.4, 1.7, -1.7, 0.9, -0.9, 0]
        escapeRotation += 1
        for index in offsets.indices {
            let angle = base + offsets[(index + escapeRotation) % offsets.count]
            let direction = SIMD2(cos(angle), sin(angle))
            if isOpen(x + direction.x * 45, y + direction.y * 45),
               isOpen(x + direction.x * 90, y + direction.y * 90),
               isOpen(x + direction.x * 140, y + direction.y * 140) {
                return direction
            }
        }
        // Nothing fully clear: any adjacent open cell beats standing still.
        for offset in offsets {
            let angle = base + offset
            let direction = SIMD2(cos(angle), sin(angle))
            if isOpen(x + direction.x * 45, y + direction.y * 45) { return direction }
        }
        return SIMD2(-cos(base), -sin(base))
    }

    /// Can the teacher see the player? A straight line sampled every 25 px against the same
    /// mask that blocks walking — so walls, and the shut office door, block sight too.
    private func teacherSeesPlayer() -> Bool {
        guard graceFor <= 0, mask != nil else { return false }
        let dx = playerMotor.x - teacherMotor.x
        let dy = playerMotor.y - teacherMotor.y
        let distance = hypot(dx, dy)
        guard distance < Tuning.sightRange else { return false }
        let steps = max(1, Int(distance / 25))
        for step in 1..<steps {
            let t = Double(step) / Double(steps)
            if !isOpen(teacherMotor.x + dx * t, teacherMotor.y + dy * t) { return false }
        }
        return true
    }

    // MARK: - Frame

    func update(dt: Double) {
        guard active else { return }

        if var current = announcement {
            current.remaining -= dt
            announcement = current.remaining > 0 ? current : nil
            if announcement == nil { onPresentationChanged?() }
        }

        stepDoor(dt: dt)

        switch phase {
        case .playing:
            elapsed += dt
            graceFor = max(0, graceFor - dt)
            stepPlayer(dt: dt)
            stepTeacher(dt: dt)
            checkKeys()
            checkChest()
            checkCaught()
        case .caught:
            caughtFor += dt
            playerMotor.holdPosition()
            teacherMotor.holdPosition()
            // He looks straight at you, and in eyes mode you are made to look straight at
            // him — the camera does that half of it.
            teacherMotor.setFacing(atan2(playerMotor.y - teacherMotor.y,
                                         playerMotor.x - teacherMotor.x) * 180 / .pi)
            stepMotors(dt: dt)
            if caughtFor >= Tuning.jumpscare { respawn() }
        case .escaped:
            playerMotor.holdPosition()
            teacherMotor.holdPosition()
            stepMotors(dt: dt)
        }

        host.minigameSetFootsteps(active: phase == .playing && playerMotor.speed > 30,
                                  isRunning: playerMotor.speed > Tuning.playerSpeed * 0.55)
    }

    private func stepDoor(dt: Double) {
        let wasLocked = doorLockTimer > 0
        doorLockTimer = max(0, doorLockTimer - dt)
        if wasLocked, doorLockTimer <= 0, phase == .playing,
           hypot(playerMotor.x - SchoolEscapeMap.officeDoor.centre.x,
                 playerMotor.y - SchoolEscapeMap.officeDoor.centre.y) < 600 {
            // The moment that makes the trap a game: the door lifts with Mr Hardy still on
            // his way, and the head start is yours to spend.
            host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.5, rate: 0.7)
            announce("The door is open", subtitle: "GO! He's coming!", duration: 1.6)
        }
        let target: Double = doorLockTimer > 0 ? 1 : 0
        let step = dt / Tuning.doorTravel
        doorPosition += max(-step, min(step, target - doorPosition))
    }

    private func stepPlayer(dt: Double) {
        // The demo bot thinks in world directions; only a thumb gets the tank controls.
        var tankControls = eyesMode
        #if DEBUG
        if debugDrivesInput { tankControls = false }
        #endif
        if tankControls {
            // First-person controls: push up to walk where you are looking, pull back to
            // back away, push sideways to turn your head. The stick's Y is screen-down, so
            // forward is its negative.
            let facing = playerMotor.facing + moveInput.x * Tuning.turnSpeed * dt
            playerMotor.setFacing(facing)
            let radians = facing * .pi / 180
            let throttle = -moveInput.y
            playerMotor.driveCharacter(
                velocityX: cos(radians) * throttle * Tuning.playerSpeed,
                velocityY: sin(radians) * throttle * Tuning.playerSpeed,
                facing: facing)
        } else {
            playerMotor.driveCharacter(velocityX: moveInput.x * Tuning.playerSpeed,
                                       velocityY: moveInput.y * Tuning.playerSpeed)
        }
        stepMotors(dt: dt)
    }

    private func stepMotors(dt: Double) {
        playerMotor.step(dt: dt, constrain: constrain(playerMotor))
        teacherMotor.step(dt: dt, constrain: constrain(teacherMotor))
    }

    // MARK: - Mr Hardy

    private func stepTeacher(dt: Double) {
        // Mid-escape from a corner: hold the course out of the pocket before thinking again.
        if teacherEscapeFor > 0 {
            teacherEscapeFor -= dt
            teacherMotor.driveCharacter(velocityX: teacherEscape.x * Tuning.investigateSpeed,
                                        velocityY: teacherEscape.y * Tuning.investigateSpeed)
            return
        }

        let sees = teacherSeesPlayer()

        switch teacherState {
        case .chasing:
            if sees {
                sinceSeen = 0
            } else {
                sinceSeen += dt
                if sinceSeen > Tuning.loseSightAfter {
                    // Lost you. Go and stand where you were last seen, then shrug back to
                    // the rounds.
                    setTeacherState(.investigating(SIMD2(playerMotor.x, playerMotor.y)))
                    break
                }
            }
            teacherMotor.profile.maxSpeed = Tuning.chaseSpeed
            // A quarter second of lead, the same trick the football chasers use.
            teacherMotor.moveCharacterTo(x: playerMotor.x + playerMotor.vx * 0.25,
                                         y: playerMotor.y + playerMotor.vy * 0.25,
                                         targetSpeed: Tuning.chaseSpeed)
            // A chase can wedge on a desk corner too; the escape keeps him coming.
            _ = teacherStuck(dt: dt)

        case .investigating(let spot):
            if sees {
                setTeacherState(.chasing)
                break
            }
            teacherMotor.profile.maxSpeed = Tuning.investigateSpeed
            teacherMotor.moveCharacterTo(x: spot.x, y: spot.y,
                                         targetSpeed: Tuning.investigateSpeed)
            if teacherMotor.hasArrived(within: 60) || teacherStuck(dt: dt) {
                setTeacherState(.patrolling)
            }

        case .patrolling:
            if sees {
                setTeacherState(.chasing)
                break
            }
            let target = SchoolEscapeMap.patrol[patrolIndex]
            teacherMotor.profile.maxSpeed = Tuning.patrolSpeed
            teacherMotor.moveCharacterTo(x: target.x, y: target.y,
                                         targetSpeed: Tuning.patrolSpeed)
            if teacherMotor.hasArrived(within: 60) || teacherStuck(dt: dt) {
                patrolIndex = (patrolIndex + 1) % SchoolEscapeMap.patrol.count
            }
        }
    }

    private var teacherEscapeFor: Double = 0
    private var teacherEscape = SIMD2<Double>(0, 0)

    /// A teacher pinned on a corner for a second gives up on that target — and *backs out of
    /// the pocket* before taking the next one, because a fresh waypoint through the same corner
    /// is the same corner. A statue teacher is a broken game.
    private func teacherStuck(dt: Double) -> Bool {
        if teacherMotor.speed < 20 {
            stuckFor += dt
        } else {
            stuckFor = 0
        }
        if stuckFor > 1.0 {
            stuckFor = 0
            teacherEscape = openDirection(from: teacherMotor.x, teacherMotor.y,
                                          toward: SIMD2(playerMotor.x, playerMotor.y))
            teacherEscapeFor = 0.7
            return true
        }
        return false
    }

    private func setTeacherState(_ state: TeacherState) {
        switch state {
        case .chasing:
            sinceSeen = 0
            if !sirenPlaying {
                sirenPlaying = true
                // Joel's picks: the Hello Neighbor chase music while he hunts, konkonse as
                // the "he's seen you" sting over the top.
                host.minigamePlayBackground(path: "/media/chase_music.mp3", volume: 0.55)
                host.minigamePlayEffect(path: "/media/konkonse.mp3", volume: 0.7)
                announce("HE'S SEEN YOU", subtitle: "RUN!", duration: 1.6)
            }
        case .patrolling, .investigating:
            if sirenPlaying {
                sirenPlaying = false
                host.minigamePlayBackground(path: "/media/ticking_clock.mp3", volume: 0.35)
                if case .investigating = state {
                    announce("He lost you…", subtitle: "keep moving", duration: 1.4)
                }
            }
        }
        teacherState = state
    }

    // MARK: - Keys, chest, catch

    private func checkKeys() {
        for index in keys.indices where !keys[index].collected {
            let key = keys[index].key
            guard hypot(playerMotor.x - key.position.x,
                        playerMotor.y - key.position.y) < Tuning.keyRadius else { continue }
            keys[index].collected = true
            collectedOrder.append(index)

            // The pickup blip rises a step per key, School Rush's coin trick.
            host.minigamePlayEffect(path: "/media/hit_tennis_ball2.mp3", volume: 0.5,
                                    rate: 1.4 + 0.18 * Double(keysHeld))

            if key.name == "GREEN" {
                // Joel's rule: Mr Hardy tries to lock you in. The door slams, and he knows
                // exactly where you are.
                doorLockTimer = Tuning.doorLocked
                host.minigamePlayEffect(path: "/media/clap.mp3", volume: 0.6, rate: 0.4)
                announce("MR HARDY IS LOCKING YOU IN!",
                         subtitle: "The door opens in \(Int(Tuning.doorLocked)) seconds",
                         duration: 2.6)
                setTeacherState(.investigating(SchoolEscapeMap.officeDoor.centre))
            } else {
                announce("\(key.name) KEY!", subtitle: "\(keysHeld) of \(totalKeys)",
                         duration: 1.6)
                // Keys make noise. If he is not already on you, he comes to look.
                if case .chasing = teacherState {} else {
                    setTeacherState(.investigating(key.position))
                }
            }
            onPresentationChanged?()
        }
    }

    private func checkChest() {
        guard !chestOpen else { return }
        guard hypot(playerMotor.x - SchoolEscapeMap.chest.x,
                    playerMotor.y - SchoolEscapeMap.chest.y) < Tuning.chestRadius else { return }

        if keysHeld == totalKeys {
            escape()
        } else if elapsed - chestHintAt > 4 {
            chestHintAt = elapsed
            host.minigamePlayEffect(path: "/media/hit_tennis_ball.mp3", volume: 0.3, rate: 0.6)
            announce("The chest is locked",
                     subtitle: "\(totalKeys - keysHeld) more key\(totalKeys - keysHeld == 1 ? "" : "s") to find",
                     duration: 1.8)
        }
    }

    private func checkCaught() {
        guard graceFor <= 0 else { return }
        guard hypot(playerMotor.x - teacherMotor.x,
                    playerMotor.y - teacherMotor.y) < Tuning.catchRadius else { return }
        phase = .caught
        caughtFor = 0
        timesCaught += 1
        moveInput = .zero
        // The jumpscare: Joel's horror scare in your face, the siren head screaming behind it
        // — as the *background* track, so the respawn's ticking clock cuts it off cleanly.
        sirenPlaying = false
        host.minigamePlayBackground(path: "/media/siren_head.mp3", volume: 0.7)
        host.minigamePlayEffect(path: "/media/horror_scare.mp3", volume: 0.95)
        host.minigamePlayEffect(path: "/media/ghostly.mp3", volume: 0.5, rate: 0.7)
        Log.world("[SchoolEscape] Caught by Mr Hardy at (\(Int(playerMotor.x)), \(Int(playerMotor.y))) with \(keysHeld) keys")
        onPresentationChanged?()
    }

    /// After the jumpscare: back to the spawn, minus the last key you took — it goes back to
    /// where it was, so being caught costs a trip rather than the whole run.
    ///
    /// Mr Hardy does *not* teleport. He marched you back, he is pleased with himself, and he
    /// picks his rounds up from wherever he is — which also means the far side of the school
    /// is now genuinely far from him, and going there is a real strategy.
    private func respawn() {
        if let last = collectedOrder.popLast() {
            keys[last].collected = false
        }
        playerMotor.teleport(x: SchoolEscapeMap.spawn.x, y: SchoolEscapeMap.spawn.y, facing: 0)
        setTeacherState(.patrolling)
        var nearest = 0
        var nearestDistance = Double.infinity
        for (index, point) in SchoolEscapeMap.patrol.enumerated() {
            let d = hypot(point.x - teacherMotor.x, point.y - teacherMotor.y)
            if d < nearestDistance {
                nearestDistance = d
                nearest = index
            }
        }
        patrolIndex = nearest
        graceFor = 6
        phase = .playing
        host.minigamePlayBackground(path: "/media/ticking_clock.mp3", volume: 0.35)
        announce("He put you back in detention",
                 subtitle: collectedOrder.isEmpty && keysHeld == 0
                       ? "Start again — quieter this time"
                       : "He took a key back too", duration: 2.4)
        onPresentationChanged?()
    }

    private func escape() {
        chestOpen = true
        phase = .escaped
        host.minigameStopBackground()
        host.minigamePlayEffect(path: "/media/school_bell.mp3", volume: 0.45)
        host.minigamePlayEffect(path: "/media/crowd_cheering.mp3", volume: 0.4)
        if bestTime == 0 || elapsed < bestTime {
            bestTime = elapsed
            UserDefaults.standard.set(elapsed, forKey: Self.bestKey)
        }
        if !badgeClaimed {
            badgeClaimed = true
            host.minigameAwardBadge(Tuning.badgeId)
        }
        Log.world(String(format: "[SchoolEscape] Escaped in %.1f s, caught %d time(s)",
                         elapsed, timesCaught))
        onPresentationChanged?()
    }

    // MARK: - Presentation

    func announce(_ text: String, subtitle: String? = nil, duration: Double = 1.6) {
        announcement = Announcement(text: text, subtitle: subtitle, remaining: duration)
        onPresentationChanged?()
    }

    var clockText: String {
        String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60)
    }

    var endDetail: String {
        var lines = [String(format: "Out in %d:%02d, caught %d time%@.",
                            Int(elapsed) / 60, Int(elapsed) % 60,
                            timesCaught, timesCaught == 1 ? "" : "s")]
        lines.append("Detention badge earned — you escaped it.")
        if bestTime > 0 {
            lines.append(String(format: "Best escape: %d:%02d",
                                Int(bestTime) / 60, Int(bestTime) % 60))
        }
        return lines.joined(separator: "\n")
    }

    /// True while Mr Hardy is actively after the player — the view tints the screen edges.
    var isBeingChased: Bool {
        if case .chasing = teacherState, phase == .playing { return true }
        return false
    }

    var isCaught: Bool { phase == .caught }

    /// Nearly black. The clear colour is sRGB-encoded twice (see the FiveNights handoff), so
    /// this lands on screen around `#0a0a12` — an actual night sky rather than the grey-purple
    /// that `#07070c` came out as.
    var backgroundColor: String? { "#010103" }

    // MARK: - Scene

    var sceneModels: [SceneModel] { SchoolEscapeMap.sceneModels }

    var sceneCharacters: [MinigameCharacter] {
        var player = playerAppearance
        player.x = playerMotor.x
        player.y = playerMotor.y
        player.z = playerMotor.z
        player.rotation = playerMotor.facing

        var teacher = teacherAppearance
        teacher.x = teacherMotor.x
        teacher.y = teacherMotor.y
        teacher.z = teacherMotor.z
        teacher.rotation = teacherMotor.facing

        // In eyes mode your body is not drawn except for the win shot — the camera is inside
        // its head, and a rig seen from within is an eyeful of hair. During the jumpscare the
        // camera stays in your eyes with Mr Hardy filling them, so the body stays hidden then
        // too.
        if eyesMode, phase != .escaped {
            return [MinigameCharacter(character: teacher, gait: teacherMotor.gait,
                                      poseOverride: teacherMotor.poseOverride())]
        }
        return [
            MinigameCharacter(character: teacher, gait: teacherMotor.gait,
                              poseOverride: teacherMotor.poseOverride()),
            MinigameCharacter(character: player, gait: playerMotor.gait,
                              poseOverride: playerMotor.poseOverride()),
        ]
    }

    var scenePrimitives: [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        // The painted furniture's 3D bodies, and the roof — the roof only over your eyes,
        // never over the win camera, which looks down from above it.
        out += SchoolEscapeFurniture.primitives
        if eyesMode, phase != .escaped {
            out += SchoolEscapeMap.roof
        }
        for (index, state) in keys.enumerated() where !state.collected {
            let bob = sin(elapsed * 2.4 + Double(index) * 1.7)
            out += SchoolEscapeMap.keyPrimitives(state.key, bob: bob)
        }
        out += SchoolEscapeMap.chestPrimitives(armed: keysHeld == totalKeys && !chestOpen,
                                               open: chestOpen)
        out += SchoolEscapeMap.doorPrimitives(closed: doorPosition)
        if isBeingChased {
            let pulse = 0.5 + 0.5 * sin(elapsed * 7)
            out.append(SchoolEscapeMap.alarmPrimitive(x: teacherMotor.x, y: teacherMotor.y,
                                                      pulse: pulse))
        }
        return out
    }

    // MARK: - Camera

    private var cameraPoint = SIMD2<Double>(0, 0)
    private var cameraSettled = false
    private var cameraWidth: Double = 1300
    private var cameraPitch: Double = 0.8

    /// Follows the player, tipped well over so the school reads as a 3D building — and on a
    /// catch it dives to Mr Hardy's face, which *is* the jumpscare. In eyes mode it is
    /// first-person instead: see below.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        guard viewportWidth > 0, Double(viewport.y) > 0 else { return }

        if eyesMode, phase != .escaped {
            // **First person, out of an orbit camera.** This camera cannot be placed — it
            // orbits a ground-level focus at a fixed distance (`viewport.h / 2·tan(fov/2)`)
            // and at `maxPitch` its eye happens to hang at ~122 units up: head height for
            // these 2.5× characters. So the trick is to put the *focus* one orbit-distance
            // ahead of the player along their facing — the eye then lands inside their head,
            // looking out at a ground point far down the corridor. Zoom scales the frustum,
            // not the distance, so 0.6 just widens the view to a proper first-person field.
            let orbitDistance = Double(viewport.y) / (2 * tan(Double(camera.fovDegrees)
                * .pi / 180 / 2))
            let pitch = Double.pi / 2.1
            // The jumpscare is first-person too: your head is snapped round to face him —
            // he is inside arm's reach, so he *fills* your eyes — and the world shakes,
            // hardest at the moment of the grab.
            let radians = phase == .caught
                ? atan2(teacherMotor.y - playerMotor.y, teacherMotor.x - playerMotor.x)
                : playerMotor.facing * .pi / 180
            let ahead = sin(pitch) * orbitDistance
            // Back to a wide lens — "make it so you can see more". The bigness comes from
            // the stretched walls and roof now, not from zooming in.
            camera.zoom = 0.62
            camera.pitch = pitch
            camera.yaw = atan2(-cos(radians), -sin(radians))
            camera.springX = 0
            camera.springY = 0
            cameraSettled = false
            // `Camera.update` biases its focus up the screen by 15% of visible height for
            // followed players; added back so the gaze stays level.
            let headroom = Double(viewport.y) / camera.zoom * 0.15
            var focusX = playerMotor.x + cos(radians) * ahead
            var focusY = playerMotor.y + sin(radians) * ahead + headroom
            if phase == .caught {
                let shake = 55 * sin(caughtFor * 52) * max(0, 1 - caughtFor / 1.2)
                focusX += -sin(radians) * shake
                focusY += cos(radians) * shake
            }
            camera.update(playerX: focusX, playerY: focusY, viewport: viewport, mapData: nil)
            return
        }

        var wanted: SIMD2<Double>
        var wantedWidth: Double
        var wantedPitch: Double

        switch phase {
        case .caught:
            wanted = SIMD2(teacherMotor.x, teacherMotor.y)
            wantedWidth = 330
            wantedPitch = 1.25
        case .escaped:
            wanted = SIMD2(SchoolEscapeMap.chest.x, SchoolEscapeMap.chest.y - 80)
            wantedWidth = 800
            wantedPitch = 1.0
        case .playing:
            wanted = SIMD2(playerMotor.x, playerMotor.y)
            wantedWidth = 1300
            wantedPitch = 0.8
        }

        // Keep the frame on the school rather than the void past its edges.
        wanted.x = min(max(wanted.x, -SchoolEscapeMap.mapWidth / 2 + wantedWidth / 2),
                       SchoolEscapeMap.mapWidth / 2 - wantedWidth / 2)
        wanted.y = min(max(wanted.y, -SchoolEscapeMap.mapHeight / 2 + 320),
                       SchoolEscapeMap.mapHeight / 2 - 320)

        if cameraSettled {
            // The catch cut is fast on purpose — that is the scare — and everything else eases.
            let rate: Double = phase == .caught ? 14 : 4.2
            let blend = 1 - exp(-rate * min(0.1, max(0, dt)))
            cameraPoint += (wanted - cameraPoint) * blend
            cameraWidth += (wantedWidth - cameraWidth) * blend
            cameraPitch += (wantedPitch - cameraPitch) * blend
        } else {
            cameraPoint = wanted
            cameraWidth = wantedWidth
            cameraPitch = wantedPitch
            cameraSettled = true
        }

        camera.zoom = max(0.2, viewportWidth / cameraWidth)
        camera.pitch = cameraPitch
        camera.yaw = 0
        camera.springX = 0
        camera.springY = 0
        camera.update(playerX: cameraPoint.x, playerY: cameraPoint.y, viewport: viewport,
                      mapData: nil)
    }

    // MARK: - Debug

    #if DEBUG
    /// `-schoolescapedemo` owns the stick — see Football's statue bug for why the latch exists.
    var debugDrivesInput = false

    var debugTraceLine: String {
        let state: String
        switch teacherState {
        case .patrolling: state = "patrol[\(patrolIndex)]"
        case .investigating: state = "investigate"
        case .chasing: state = "CHASE"
        }
        return String(format: "schoolescape %@ t=%@ you=(%.0f, %.0f) hardy=(%.0f, %.0f) %@ keys=%d/%d caught=%d door=%.1f",
                      "\(phase)", clockText, playerMotor.x, playerMotor.y,
                      teacherMotor.x, teacherMotor.y, state, keysHeld, totalKeys,
                      timesCaught, doorLockTimer)
    }

    private var demoStuckFor: Double = 0
    private var demoEscapeUntil: Double = 0
    private var demoEscape = SIMD2<Double>(0, 0)
    private var demoPath: [SIMD2<Double>] = []
    private var demoPathTarget = SIMD2<Double>(0, 0)
    private var demoPathAt: Double = -10

    /// Breadth-first flood over the clip-mask grid (one cell per 10 world px), from `from` to
    /// `to`, returned as world-space cell centres. A beeline is not a route when there is a
    /// building in the way: the first demo spent four minutes head-butting the classroom's
    /// north wall on its way to a key two rooms over. The teacher deliberately does *not* get
    /// this — a hunter you can shake off round a corner is the game.
    private func findPath(from: SIMD2<Double>, to: SIMD2<Double>) -> [SIMD2<Double>] {
        guard let mask else { return [to] }
        let cell = 1.0 / ClipMask.scale
        let cols = mask.pixelWidth
        let rows = mask.pixelHeight
        func cellOf(_ p: SIMD2<Double>) -> (Int, Int) {
            (min(cols - 1, max(0, Int((p.x + SchoolEscapeMap.mapWidth / 2) / cell))),
             min(rows - 1, max(0, Int((p.y + SchoolEscapeMap.mapHeight / 2) / cell))))
        }
        func worldOf(_ cx: Int, _ cy: Int) -> SIMD2<Double> {
            SIMD2((Double(cx) + 0.5) * cell - SchoolEscapeMap.mapWidth / 2,
                  (Double(cy) + 0.5) * cell - SchoolEscapeMap.mapHeight / 2)
        }
        func open(_ cx: Int, _ cy: Int) -> Bool {
            let p = worldOf(cx, cy)
            return isOpen(p.x, p.y)
        }
        // Nudge either end onto the nearest open cell — a key sits mid-cell, a spawn can
        // straddle a wall edge at this resolution.
        func nearestOpen(_ c: (Int, Int)) -> (Int, Int)? {
            if open(c.0, c.1) { return c }
            for radius in 1...6 {
                for dy in -radius...radius {
                    for dx in -radius...radius where max(abs(dx), abs(dy)) == radius {
                        let n = (c.0 + dx, c.1 + dy)
                        if n.0 >= 0, n.0 < cols, n.1 >= 0, n.1 < rows, open(n.0, n.1) {
                            return n
                        }
                    }
                }
            }
            return nil
        }
        guard let start = nearestOpen(cellOf(from)), let goal = nearestOpen(cellOf(to)) else {
            return [to]
        }

        var cameFrom = [Int32](repeating: -1, count: cols * rows)
        let startIndex = start.1 * cols + start.0
        let goalIndex = goal.1 * cols + goal.0
        cameFrom[startIndex] = Int32(startIndex)
        var queue = [startIndex]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            if current == goalIndex { break }
            let cx = current % cols
            let cy = current / cols
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = cx + dx
                let ny = cy + dy
                guard nx >= 0, nx < cols, ny >= 0, ny < rows else { continue }
                let next = ny * cols + nx
                guard cameFrom[next] == -1, open(nx, ny) else { continue }
                cameFrom[next] = Int32(current)
                queue.append(next)
            }
        }
        guard cameFrom[goalIndex] != -1 else { return [to] }

        var path: [SIMD2<Double>] = []
        var current = goalIndex
        while current != startIndex {
            path.append(worldOf(current % cols, current / cols))
            current = Int(cameFrom[current])
        }
        return path.reversed()
    }

    /// The demo's route brain: head for the nearest missing key, then the chest, driving the
    /// same `setMoveInput` a thumb does. It knows nothing about Mr Hardy — getting caught and
    /// losing a key simply re-routes it, which exercises the whole loop. When a desk corner
    /// wedges it, it backs out the way a thumb would (`openDirection`).
    func debugStep() {
        guard phase == .playing else { return }
        let here = SIMD2(playerMotor.x, playerMotor.y)

        let hardy = SIMD2(teacherMotor.x, teacherMotor.y)

        // Which key? Not simply the nearest: the one that is *near me and far from him*.
        // Nearest-first sent every life straight back for the key Mr Hardy was standing
        // guard beside, down the corridor he was walking up — the same catch, forever.
        var target = SchoolEscapeMap.chest
        if keysHeld < totalKeys {
            var best = -Double.infinity
            for state in keys where !state.collected {
                let p = state.key.position
                let score = 0.6 * hypot(p.x - hardy.x, p.y - hardy.y)
                    - hypot(p.x - here.x, p.y - here.y)
                if score > best {
                    best = score
                    target = p
                }
            }
        }

        // The errand waits if it must: being hunted, him closing in (550 px, because head-on
        // in a corridor closes at 750 px/s and 320 left half a second to react), or the target
        // itself being guarded — when the green key is the last one and he is stood beside it,
        // the move is to lurk somewhere safe until his rounds take him away, not to walk in.
        let guarded = hypot(target.x - hardy.x, target.y - hardy.y) < 700
        if isBeingChased || guarded || hypot(hardy.x - here.x, hardy.y - here.y) < 550 {
            var bestScore = -Double.infinity
            for spot in [SchoolEscapeMap.spawn, SchoolEscapeMap.chest]
                + keys.map(\.key.position) {
                let score = hypot(spot.x - hardy.x, spot.y - hardy.y)
                    - 0.4 * hypot(spot.x - here.x, spot.y - here.y)
                if score > bestScore {
                    bestScore = score
                    target = spot
                }
            }
        }

        // Mid-escape from a pocket: keep backing out.
        if elapsed < demoEscapeUntil {
            moveInput = demoEscape
            return
        }

        // A route through the corridors, replanned when the target changes or twice a second —
        // being caught moves the player and hands a key back, and a stale path walks into walls.
        if target != demoPathTarget || elapsed - demoPathAt > 0.5 {
            demoPath = findPath(from: here, to: target)
            demoPathTarget = target
            demoPathAt = elapsed

            // The school has one central corridor and every key grab summons him down it, so
            // "the shortest route" is regularly "straight through Mr Hardy". If the next
            // stretch of the route brushes past him, go somewhere clear instead and let him
            // stomp by — the classroom-doorway wait every child discovers in round two.
            func clear(_ path: [SIMD2<Double>]) -> Bool {
                path.prefix(80).allSatisfy { hypot($0.x - hardy.x, $0.y - hardy.y) > 260 }
            }
            if !clear(demoPath) {
                let spots = ([SchoolEscapeMap.spawn, SchoolEscapeMap.chest]
                    + keys.map(\.key.position))
                    .sorted { hypot($0.x - hardy.x, $0.y - hardy.y)
                            > hypot($1.x - hardy.x, $1.y - hardy.y) }
                for spot in spots {
                    let alternative = findPath(from: here, to: spot)
                    if clear(alternative) {
                        demoPath = alternative
                        demoPathTarget = spot
                        break
                    }
                }
            }
        }
        while let next = demoPath.first, hypot(next.x - here.x, next.y - here.y) < 60 {
            demoPath.removeFirst()
        }
        let waypoint = demoPath.first ?? target

        // Called at 20 Hz by the harness; a stationary half second under full throttle means
        // wedged despite the route — back out and let the replan pick it up.
        if playerMotor.speed < 30 {
            demoStuckFor += 0.05
        } else {
            demoStuckFor = 0
        }
        if demoStuckFor > 0.5 {
            demoStuckFor = 0
            demoEscape = openDirection(from: here.x, here.y, toward: waypoint)
            demoEscapeUntil = elapsed + 0.55
            moveInput = demoEscape
            return
        }

        var direction = waypoint - here
        let distance = hypot(direction.x, direction.y)
        if distance > 1 { direction /= distance }
        moveInput = direction
    }
    #endif
}
