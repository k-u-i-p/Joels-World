import Foundation
import simd

/// **The character lab.** A room with a floor, a metre grid, a ruler and nobody in it but the
/// character you are looking at.
///
/// It is a `WorldRenderedMinigame` for one reason: that is the engine's existing seam for
/// "something that owns the screen and supplies its own cast, its own ground and its own
/// camera". Going in through it means the lab draws through the *real* renderer — the same
/// rigs, the same clothing atlas, the same spotlight, shadow map and SSAO the game ships — so
/// what it shows is what the game shows. A separate viewer with its own shaders would be a
/// second renderer to keep in step, and the first thing it would stop catching is a change to
/// the first one.
///
/// ## Why it is deterministic
///
/// The simulation runs on a **fixed 1/120 s sub-step** driven by the lab's own clock, and
/// `SceneClock` is pinned to that clock while the lab is up. So a take is a pure function of
/// time: `seek(to: 2.5)` produces the same frame whether it was scrubbed to, played to, or
/// captured headlessly at a different frame rate. That is the whole difference between a tool
/// that takes pictures and a tool whose pictures can be compared with yesterday's.
///
/// Seeking backwards rebuilds the cast and replays from zero, which at 120 steps a second over
/// a ten-second take is a few thousand cheap steps — far simpler than making every motor
/// reversible.
final class CharacterLabScene: WorldRenderedMinigame {

    // MARK: - Units

    /// The tennis court's scale, borrowed so measurements in the lab mean the same thing they
    /// mean in the only other place in the game that works in real units. A pupil is about
    /// 66 units, so roughly 2.4 m — a cartoon child.
    static let unitsPerMetre: Double = 27
    static func metres(_ value: Double) -> Double { value * unitsPerMetre }

    /// The instant the lab pretends it is, always. Emote start times are absolute epoch
    /// milliseconds, so they need an epoch, and a fixed one keeps them reproducible.
    private static let epoch: Double = 1_700_000_000

    // MARK: - What is being looked at

    private(set) var takeIndex: Int = 0
    var take: CharacterLabTake { CharacterLabTake.all[takeIndex] }

    private(set) var castKind: CharacterLabCast.Kind = .solo

    /// Overrides the take's own camera when set — the view buttons in the sidebar and `-labview`.
    ///
    /// Changing it re-lays a lineup, because which way the row runs depends on where the camera
    /// is standing: see `rebuildCast`.
    var viewOverride: CharacterLabView? {
        didSet { if viewOverride != oldValue, subjects.count > 1 { replayFromStart() } }
    }
    var view: CharacterLabView { viewOverride ?? take.view }

    /// Nudges off the chosen view, in radians. What the orbit keys and the mouse write, so a
    /// preset stays a preset and "a bit further round" does not have to become one.
    var yawTrim: Double = 0
    var pitchTrim: Double = 0

    var cameraYaw: Double { view.yaw + yawTrim }
    var cameraPitch: Double { min(max(0, view.pitch + pitchTrim), .pi / 2.1) }

    /// Multiplies whatever throttle the take asked for. The speed slider.
    var speedScale: Double = 1 {
        didSet { if speedScale != oldValue { replayFromStart() } }
    }

    /// Playback rate. Only affects how fast the clock runs, never what a given time looks like.
    var rate: Double = 1
    var isPaused: Bool = false

    var showsGrid: Bool = true
    var showsRuler: Bool = true
    /// How much of the world fits across the frame, in metres. A pupil is about 2.4 m tall, so
    /// six metres across a 3:2 frame is a whole character with room to stride into.
    var frameWidthMetres: Double = 6

    /// Where the subject's feet sit, as a fraction of the frame below the middle. See
    /// `updateCamera` — this is the number the composition is built around.
    private static let feetBelowCentre: Double = 0.18

    /// Seconds into the take. Loops at `take.seconds` while playing.
    private(set) var clock: Double = 0

    // MARK: - The cast

    final class Subject {
        var character: GameCharacter
        let motor: CharacterMotor
        /// Where this one stands at t = 0, so a lineup stays in its lanes.
        let lane: SIMD2<Double>

        init(character: GameCharacter, lane: SIMD2<Double>) {
            self.character = character
            self.lane = lane
            var profile = LocomotionProfile.player
            // A teacher is bigger but not faster; the profile is the pupil's for everybody, so
            // a lineup's strides stay comparable.
            profile.maxSpeed = LocomotionProfile.player.maxSpeed
            self.motor = CharacterMotor(profile: profile)
        }
    }

    private(set) var subjects: [Subject] = []

    /// How far the simulation has actually been stepped, which trails `clock` by less than one
    /// sub-step.
    private var simulated: Double = 0
    private static let subStep: Double = 1.0 / 120

    // MARK: - Lifecycle

    init(take: String? = nil, cast: CharacterLabCast.Kind = .solo) {
        castKind = cast
        if let take, let index = CharacterLabTake.all.firstIndex(where: { $0.id == take }) {
            takeIndex = index
        }
    }

    func start() {
        rebuildCast()
        pinClock()
        Log.world("Character lab: take '\(take.id)', cast '\(castKind.rawValue)'")
    }

    func stop() {
        SceneClock.pinned = nil
    }

    func update(dt: Double) {
        if !isPaused {
            var next = clock + dt * rate
            if next >= take.seconds {
                // Loop. Replaying from zero rather than wrapping keeps the take a pure function
                // of its own clock — a second lap looks exactly like the first.
                next = next.truncatingRemainder(dividingBy: take.seconds)
                replayFromStart()
            }
            clock = next
        }
        simulate(to: clock)
        pinClock()
    }

    // MARK: - Controls

    func select(takeIndex index: Int) {
        guard CharacterLabTake.all.indices.contains(index) else { return }
        takeIndex = index
        clock = 0
        replayFromStart()
    }

    func select(takeId: String) {
        guard let index = CharacterLabTake.all.firstIndex(where: { $0.id == takeId }) else { return }
        select(takeIndex: index)
    }

    func select(cast: CharacterLabCast.Kind) {
        guard cast != castKind else { return }
        castKind = cast
        replayFromStart()
    }

    func step(frames: Int, at frameRate: Double = 60) {
        seek(to: clock + Double(frames) / frameRate)
    }

    /// Moves the clock, replaying from the start if it went backwards.
    func seek(to time: Double) {
        clock = min(max(0, time), take.seconds)
        if clock < simulated { replayFromStart() }
        simulate(to: clock)
        pinClock()
    }

    // MARK: - Simulation

    private func replayFromStart() {
        rebuildCast()
        simulate(to: clock)
    }

    private func rebuildCast() {
        let characters = CharacterLabCast.characters(castKind)
        // **The row runs across the camera, not across the world.** A lineup laid out along a
        // fixed axis is a lineup that is five characters wide from one view and one character
        // wide from the view at right angles to it — and the second one is a picture of the
        // nearest pupil with four shadows behind him. The camera's own right vector in world
        // terms is `(cos yaw, −sin yaw)`, world Y being the negated one.
        let spacing = Self.metres(1.5)
        let offset = Double(characters.count - 1) / 2
        let laneAxis = SIMD2(cos(cameraYaw), -sin(cameraYaw))

        subjects = characters.enumerated().map { index, character in
            var subject = character
            let lane = laneAxis * ((Double(index) - offset) * spacing)
            subject.x = lane.x
            subject.y = lane.y
            subject.z = 0
            subject.rotation = 0
            if let emote = take.emote {
                subject.emote = EmoteState(name: emote, startTime: (Self.epoch * 1000).rounded())
            } else {
                subject.emote = nil
            }
            let built = Subject(character: subject, lane: lane)
            built.motor.teleport(x: lane.x, y: lane.y, z: 0, facing: 0)
            return built
        }
        simulated = 0
    }

    /// Steps every motor forward to `target` on the fixed sub-step.
    private func simulate(to target: Double) {
        // A very long seek — dragging the scrubber across a twelve-second take — is still only a
        // few thousand steps, but the cap keeps a runaway from locking the UI up.
        var guardRail = 4000
        while simulated + Self.subStep <= target + 1e-9, guardRail > 0 {
            guardRail -= 1
            let time = simulated
            for subject in subjects {
                take.drive(subject.motor, at: time, speedScale: speedScale)
                subject.motor.step(dt: Self.subStep)
            }
            simulated += Self.subStep
        }

        for subject in subjects {
            subject.character.x = subject.motor.x
            subject.character.y = subject.motor.y
            subject.character.z = subject.motor.z
            subject.character.rotation = subject.motor.facing
        }
    }

    /// Points `SceneClock` — and so the rig's idle breathing and every emote's age — at the
    /// lab's clock rather than at the wall.
    private func pinClock() {
        SceneClock.pinned = Self.epoch + clock
    }

    // MARK: - What the renderer asks for

    var sceneCharacters: [MinigameCharacter] {
        subjects.map {
            MinigameCharacter(character: $0.character,
                              gait: $0.motor.gait,
                              poseOverride: $0.motor.poseOverride())
        }
    }

    var backgroundColor: String? { "#8d949b" }

    var scenePrimitives: [ScenePrimitive] {
        var out: [ScenePrimitive] = []
        let focus = focusPoint

        // The floor. Render space negates Y, so everything below flips the sign of the world
        // coordinate rather than pretending the two frames are the same one.
        out.append(ScenePrimitive(
            shape: .plane(width: Float(Self.metres(40)), height: Float(Self.metres(40))),
            transform: .translation(SIMD3(Float(focus.x), Float(-focus.y), 0)),
            color: SIMD3(0.42, 0.44, 0.42),
            roughness: 1,
            castsShadow: false))

        if showsGrid { out.append(contentsOf: grid(around: focus)) }
        if showsRuler { out.append(contentsOf: ruler(at: focus)) }
        return out
    }

    /// A metre grid, snapped to whole metres and re-centred on the camera each frame, so it
    /// reads as an infinite floor while still sliding past a character who is travelling —
    /// which is the only way to see, from a still picture, that they moved at all.
    private func grid(around focus: SIMD2<Double>) -> [ScenePrimitive] {
        let metre = Self.unitsPerMetre
        let half = 8
        let length = Float(metre * Double(half * 2))
        let thin = Float(metre * 0.03)
        let centreX = (focus.x / metre).rounded() * metre
        let centreY = (focus.y / metre).rounded() * metre

        var out: [ScenePrimitive] = []
        for step in -half...half {
            let offset = Double(step) * metre
            // Every fifth line is brighter, so distance can be counted off a still frame.
            let major = step % 5 == 0
            let colour = major ? SIMD3<Float>(0.80, 0.82, 0.80) : SIMD3<Float>(0.52, 0.55, 0.52)
            let width = major ? thin * 2 : thin

            // Along X — a line of constant Y.
            out.append(ScenePrimitive(
                shape: .plane(width: length, height: width),
                transform: .translation(SIMD3(Float(centreX), Float(-(centreY + offset)), 0.4)),
                color: colour,
                unlit: true,
                castsShadow: false))
            // Along Y — a line of constant X.
            out.append(ScenePrimitive(
                shape: .plane(width: width, height: length),
                transform: .translation(SIMD3(Float(centreX + offset), Float(-centreY), 0.4)),
                color: colour,
                unlit: true,
                castsShadow: false))
        }
        return out
    }

    /// A quarter-metre banded post beside the subject. A jump's height, a knee's height and
    /// how tall the character is are all things you can only argue about until there is
    /// something in the frame to measure them against.
    private func ruler(at focus: SIMD2<Double>) -> [ScenePrimitive] {
        let metre = Self.unitsPerMetre
        let band = Float(metre * 0.25)
        let side = Float(metre * 0.08)
        let x = Float(focus.x - metre * 1.2)
        let y = Float(-(focus.y + metre * 0.9))

        return (0..<12).map { index in
            ScenePrimitive(
                shape: .box(width: side, height: side, depth: band),
                transform: .translation(SIMD3(x, y, band * (Float(index) + 0.5))),
                color: index % 2 == 0 ? SIMD3(0.92, 0.92, 0.90) : SIMD3(0.18, 0.20, 0.22),
                roughness: 0.8)
        }
    }

    /// The middle of the cast, on the ground.
    var focusPoint: SIMD2<Double> {
        guard !subjects.isEmpty else { return .zero }
        let sum = subjects.reduce(SIMD2<Double>.zero) { $0 + SIMD2($1.motor.x, $1.motor.y) }
        return sum / Double(subjects.count)
    }

    // MARK: - Camera

    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>, dt: Double) {
        let viewportWidth = Double(viewport.x)
        let viewportHeight = Double(viewport.y)
        guard viewportWidth > 0, viewportHeight > 0 else { return }

        let wanted = castKind == .solo ? frameWidthMetres : max(frameWidthMetres, 9)
        // No 5× ceiling here, unlike the editor's camera: the overworld never wants to be
        // closer than that and the lab is nothing but close-ups. Framing five metres across a
        // 900-point window already asks for 6.7.
        camera.zoom = min(40, max(0.1, viewportWidth / Self.metres(wanted)))
        camera.pitch = cameraPitch
        camera.yaw = cameraYaw
        camera.springX = 0
        camera.springY = 0

        // **Composing the shot, given a camera that can only look at the floor.**
        //
        // `Camera.update` always aims at z = 0, so a character standing at the focus has their
        // *feet* in the middle of the frame and grows upwards out of it. The only handle on
        // that is where the focus sits on the ground — and moving it does two things at once,
        // because the eye is positioned relative to the focus and travels with it. Pulling the
        // focus towards the camera slides the shot down the screen by `cos(pitch)` of the
        // distance moved, and dollies in by `sin(pitch)` of it. Near the horizontal the second
        // term swamps the first: the character is magnified about their own feet and their head
        // leaves the top of the frame faster than the shot comes down. That is why the pitches
        // in `CharacterLabView` are three-quarter angles rather than the ground-level ones a
        // rig looks most dramatic at.
        //
        // So the drop is scaled by `tan(pitch)` — the inverse of the term that produces it —
        // and `feetBelowCentre` then means what it says at any angle.
        let visibleHeight = viewportHeight / camera.zoom
        let drop = Self.feetBelowCentre * visibleHeight * tan(camera.pitch)
        // `Camera.update` applies a 15% drop of its own for the overworld's headroom; this is
        // the whole drop, so its share is handed back.
        let focus = focusPoint
        camera.update(playerX: focus.x,
                      playerY: focus.y - drop + visibleHeight * 0.15,
                      viewport: viewport,
                      mapData: nil)
    }

    // MARK: - Readout

    /// One line per subject of what the motor currently believes, for the HUD. Rig-derived
    /// measurements — foot clearance, hand reach — are `CharacterLabReport`'s job, because they
    /// need a pose and a pose needs a runtime.
    func readout() -> [String] {
        subjects.map { subject in
            let gait = subject.motor.gait
            return String(format: "%@  speed %5.0f  intensity %.2f  run %.2f  lean %+.2f  turn %+.2f  z %5.1f%@",
                          subject.character.name ?? "#\(subject.character.id)",
                          subject.motor.speed,
                          gait.intensity,
                          gait.run,
                          gait.leanForward,
                          gait.turning,
                          subject.motor.z,
                          subject.motor.isAirborne ? "  airborne" : "")
        }
    }
}
