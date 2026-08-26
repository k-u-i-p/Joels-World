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
        static let teacherSize: Double = 128

        /// Speeds are map pixels per second, scaled up from the overworld's 216 in the same
        /// ratio as the bodies. You can outrun him — just — and he never stops walking.
        static let playerSpeed: Double = 400
        static let chaseSpeed: Double = 355
        static let patrolSpeed: Double = 170
        static let investigateSpeed: Double = 250

        /// How far he can see, and how close counts as caught.
        static let sightRange: Double = 1000
        static let catchRadius: Double = 62
        static let keyRadius: Double = 80
        static let chestRadius: Double = 130

        /// Seconds without a sighting before a chase becomes "go and look where they were".
        static let loseSightAfter: Double = 2.6
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

    private(set) var elapsed: Double = 0
    private var caughtFor: Double = 0
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
        guard mask != nil else { return false }
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
            stepPlayer(dt: dt)
            stepTeacher(dt: dt)
            checkKeys()
            checkChest()
            checkCaught()
        case .caught:
            caughtFor += dt
            playerMotor.holdPosition()
            teacherMotor.holdPosition()
            teacherMotor.setFacing(270)
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
        playerMotor.driveCharacter(velocityX: moveInput.x * Tuning.playerSpeed,
                                   velocityY: moveInput.y * Tuning.playerSpeed)
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
                host.minigamePlayBackground(path: "/media/siren_head.mp3", volume: 0.5)
                host.minigamePlayEffect(path: "/media/ghostly.mp3", volume: 0.45, rate: 1.15)
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
        guard hypot(playerMotor.x - teacherMotor.x,
                    playerMotor.y - teacherMotor.y) < Tuning.catchRadius else { return }
        phase = .caught
        caughtFor = 0
        timesCaught += 1
        moveInput = .zero
        host.minigameStopBackground()
        sirenPlaying = false
        // The jumpscare: the ghostly sting slowed right down, and his laugh under it.
        host.minigamePlayEffect(path: "/media/ghostly.mp3", volume: 0.9, rate: 0.7)
        host.minigamePlayEffect(path: "/media/laugh.mp3", volume: 0.5, rate: 0.8)
        Log.world("[SchoolEscape] Caught by Mr Hardy at (\(Int(playerMotor.x)), \(Int(playerMotor.y))) with \(keysHeld) keys")
        onPresentationChanged?()
    }

    /// After the jumpscare: back to the spawn, minus the last key you took — it goes back to
    /// where it was, so being caught costs a trip rather than the whole run.
    private func respawn() {
        if let last = collectedOrder.popLast() {
            keys[last].collected = false
        }
        playerMotor.teleport(x: SchoolEscapeMap.spawn.x, y: SchoolEscapeMap.spawn.y, facing: 0)
        teacherMotor.teleport(x: SchoolEscapeMap.teacherSpawn.x,
                              y: SchoolEscapeMap.teacherSpawn.y, facing: 180)
        setTeacherState(.patrolling)
        patrolIndex = 0
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

        return [
            MinigameCharacter(character: teacher, gait: teacherMotor.gait,
                              poseOverride: teacherMotor.poseOverride()),
            MinigameCharacter(character: player, gait: playerMotor.gait,
                              poseOverride: playerMotor.poseOverride()),
        ]
    }

    var scenePrimitives: [ScenePrimitive] {
        var out: [ScenePrimitive] = []
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
    /// catch it dives to Mr Hardy's face, which *is* the jumpscare.
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        guard viewportWidth > 0, Double(viewport.y) > 0 else { return }

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

        var target = SchoolEscapeMap.chest
        if keysHeld < totalKeys {
            var best = Double.infinity
            for state in keys where !state.collected {
                let d = hypot(state.key.position.x - here.x, state.key.position.y - here.y)
                if d < best {
                    best = d
                    target = state.key.position
                }
            }
        }

        // Being hunted — or about to be — means the errand waits. Run for whichever landmark
        // is far from Mr Hardy without being miles from here, and come back for the key after.
        // Without this the bot re-fetched the green key down the corridor he investigates and
        // was caught head-on at the same spot every single life.
        let hardy = SIMD2(teacherMotor.x, teacherMotor.y)
        if isBeingChased || hypot(hardy.x - here.x, hardy.y - here.y) < 320 {
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
