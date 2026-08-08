#if DEBUG
import Foundation
import simd

/// Assertions over the pure movement maths: `Locomotion`, `Gait` and `DeterministicRandom`.
///
/// There is no test target in this project, and adding one means editing `project.pbxproj` —
/// red under `AGENTS.md`. So this follows the same route every other check in the tree takes:
/// a launch argument (`-selftest`), a run that logs pass/fail, and a summary line to grep for.
/// Everything under test is a pure function with no world, no Metal and no network, so the
/// whole thing runs in well under a millisecond and can be left switched on.
///
/// ```bash
/// xcrun simctl launch --console booted com.allr.joelsworld -selftest
/// ```
///
/// **What is worth adding here**: anything with a sign in it. The rig's local frame, the
/// world's Y-down frame and render space's negated Y are three different conventions and the
/// bugs they produce all look like "the animation is mirrored". A test that pins a sign down is
/// worth more than one that pins a magnitude down.
enum LocomotionSelfTest {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-selftest")
    }

    /// Runs every case. Returns true if they all passed.
    @discardableResult
    static func run() -> Bool {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                passed += 1
                Log.world("selftest PASS  \(name)")
            } else {
                failed += 1
                Log.world("selftest FAIL  \(name) — \(detail())")
            }
        }

        func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
            abs(a - b) <= tolerance
        }

        // MARK: Profiles

        // The old formulation moved the player `moveSpeed` units every 1/60 s frame. If this
        // ever stops matching, the overworld silently changes pace.
        check("player profile matches the old per-frame speed",
              near(LocomotionProfile.player.maxSpeed, 3 * 60),
              "maxSpeed \(LocomotionProfile.player.maxSpeed), expected 180")
        check("braking outruns acceleration",
              LocomotionProfile.player.braking > LocomotionProfile.player.acceleration,
              "a character that cannot stop faster than it starts feels like ice")
        check("running reaches further per stride",
              LocomotionProfile.playerRunning.strideLength > LocomotionProfile.player.strideLength)

        // MARK: Heading

        // 350° → 10° is 20° clockwise, not 340° anticlockwise. Limited to 5° it must step *up*
        // through the wrap to 355, never down to 345.
        check("turn takes the short way round the wrap",
              near(Locomotion.turn(350, towards: 10, limit: 5), 355),
              "got \(Locomotion.turn(350, towards: 10, limit: 5))")
        check("turn arrives exactly when inside the limit",
              near(Locomotion.turn(10, towards: 20, limit: 30), 20))
        check("turn clamps to the limit when outside it",
              near(Locomotion.turn(0, towards: 170, limit: 45), 45),
              "got \(Locomotion.turn(0, towards: 170, limit: 45))")
        // A dead 180° reversal is a tie — both ways round are the same distance — so which way
        // it goes is arbitrary. What matters is that it commits to one and moves the full limit.
        check("turn breaks a 180° tie without stalling",
              {
                  let result = Locomotion.turn(0, towards: 180, limit: 45)
                  return near(result, 45) || near(result, 315)
              }(),
              "got \(Locomotion.turn(0, towards: 180, limit: 45))")
        check("turn normalises below zero",
              near(Locomotion.turn(10, towards: 340, limit: 5), 5),
              "got \(Locomotion.turn(10, towards: 340, limit: 5))")

        // MARK: Inertia

        // A released stick must brake to a stop, and must actually reach zero rather than
        // asymptote at it — `Gait.isMoving` and the walking audio both key off that.
        var released = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
        var releasedFrames = 0
        for _ in 0..<120 {
            _ = Locomotion.step(&released, desired: (0, 0), facingIntent: nil,
                                profile: .player, dt: 1.0 / 60)
            releasedFrames += 1
            if released.speed == 0 { break }
        }
        check("a released stick brakes to a dead stop",
              released.speed == 0 && released.vx == 0 && released.vy == 0,
              "speed \(released.speed) after \(releasedFrames) frames")
        check("and stops inside a quarter second",
              releasedFrames <= 15,
              "took \(releasedFrames) frames")

        // The velocity reaching zero does not end the animation: the stride deliberately finishes
        // the step it is mid-way through rather than snapping, so the character plants a foot
        // instead of freezing on one leg. It must still reach a settled stand, and quickly.
        check("a stopped character is still mid-stride for a moment",
              released.gait.phase != 0,
              "the stride snapped to 0 instead of finishing its step")
        var settleFrames = 0
        while released.gait.phase != 0 && settleFrames < 60 {
            _ = Locomotion.step(&released, desired: (0, 0), facingIntent: nil,
                                profile: .player, dt: 1.0 / 60)
            settleFrames += 1
        }
        check("and then settles into a stand",
              released.gait.phase == 0 && !released.gait.isMoving && settleFrames < 60,
              "phase \(released.gait.phase) after \(settleFrames) frames")
        check("finishing the step takes under a fifth of a second",
              settleFrames <= 12,
              "took \(settleFrames) frames")

        // Held on, it should reach and hold top speed rather than overshoot it.
        var held = LocomotionState()
        for _ in 0..<120 {
            _ = Locomotion.step(&held, desired: (LocomotionProfile.player.maxSpeed, 0),
                                facingIntent: nil, profile: .player, dt: 1.0 / 60)
        }
        check("a held stick settles at top speed and no faster",
              near(held.speed, LocomotionProfile.player.maxSpeed, 0.001),
              "speed \(held.speed)")
        check("a demand beyond top speed is clamped, not honoured",
              {
                  var fast = LocomotionState()
                  for _ in 0..<120 {
                      _ = Locomotion.step(&fast, desired: (10_000, 10_000), facingIntent: nil,
                                          profile: .player, dt: 1.0 / 60)
                  }
                  return fast.speed <= LocomotionProfile.player.maxSpeed + 0.001
              }())

        // MARK: The compatibility guarantee

        // Running dead ahead has to reproduce the pre-`Gait` animation exactly: `forward` 1 and
        // `lateral` 0, so every term the lateral stride added to `CharacterRig.pose` falls away.
        check("running dead ahead is forward-only",
              near(held.gait.forward, 1, 0.001) && near(held.gait.lateral, 0, 0.001),
              "forward \(held.gait.forward), lateral \(held.gait.lateral)")
        check("Gait.walking is the pre-Gait walk",
              {
                  let walk = Gait.walking(phase: 1)
                  return walk.forward == 1 && walk.lateral == 0 && walk.intensity == 1
              }())
        check("Gait.walking(0) is standing still",
              !Gait.walking(phase: 0).isMoving)

        // MARK: Side-stepping

        // The whole point of `Gait`. Reverse a character at full tilt: while the body is still
        // coming round, the velocity is off to one side of the facing and the gait must say so.
        var reversing = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
        var peakLateral: Double = 0
        for _ in 0..<180 {
            _ = Locomotion.step(&reversing, desired: (-LocomotionProfile.player.maxSpeed, 0),
                                facingIntent: nil, profile: .player, dt: 1.0 / 60)
            peakLateral = max(peakLateral, abs(reversing.gait.lateral))
        }
        check("a 180° reversal side-steps on the way round",
              peakLateral > 0.3,
              "peak lateral only \(peakLateral)")
        check("and settles facing the new direction",
              near(Locomotion.turn(reversing.facing, towards: 180, limit: 0), 180, 0.5),
              "facing \(reversing.facing)")

        // Strafing: hold a heading and demand movement across it. This is the tennis case, and
        // the one that decides which way the feet shuffle.
        var strafing = LocomotionState(facing: 0)
        for _ in 0..<60 {
            _ = Locomotion.step(&strafing, desired: (0, LocomotionProfile.player.maxSpeed),
                                facingIntent: 0, profile: .player, dt: 1.0 / 60)
        }
        check("facingIntent holds the heading while the body strafes",
              near(strafing.facing, 0, 0.001), "facing \(strafing.facing)")
        // World +Y with a 0° facing resolves to local −Y, which is the character's right.
        check("strafing world +Y reads as lateral −1",
              near(strafing.gait.lateral, -1, 0.01) && near(strafing.gait.forward, 0, 0.01),
              "forward \(strafing.gait.forward), lateral \(strafing.gait.lateral)")

        // Backpedalling: demand movement straight backwards while facing forwards.
        var backing = LocomotionState(facing: 0)
        for _ in 0..<60 {
            _ = Locomotion.step(&backing, desired: (-LocomotionProfile.player.maxSpeed, 0),
                                facingIntent: 0, profile: .player, dt: 1.0 / 60)
        }
        check("backpedalling reads as forward −1",
              near(backing.gait.forward, -1, 0.01) && near(backing.gait.lateral, 0, 0.01),
              "forward \(backing.gait.forward), lateral \(backing.gait.lateral)")

        // MARK: Walls

        // `commit` is the half that is easy to miss. A character shoved into a wall must shed
        // its velocity into it rather than store it up and fire sideways on release.
        var blocked = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
        let demand = Locomotion.step(&blocked, desired: (LocomotionProfile.player.maxSpeed, 0),
                                     facingIntent: nil, profile: .player, dt: 1.0 / 60)
        check("a full demand is produced before the wall test", demand.dx > 0)
        Locomotion.commit(&blocked, actualDx: 0, actualDy: 0, dt: 1.0 / 60)
        check("a wall sheds the velocity it blocked",
              blocked.vx == 0 && blocked.vy == 0,
              "vx \(blocked.vx)")
        check("and does not move the character",
              blocked.x == 0 && blocked.y == 0)

        // A wall taken at an angle should keep the component that slid along it.
        var sliding = LocomotionState(facing: 45)
        _ = Locomotion.step(&sliding, desired: (100, 100), facingIntent: nil,
                            profile: .player, dt: 1.0 / 60)
        Locomotion.commit(&sliding, actualDx: 0, actualDy: 1, dt: 1.0 / 60)
        check("sliding along a wall keeps the unblocked component",
              sliding.vx == 0 && near(sliding.vy, 60, 0.001),
              "vx \(sliding.vx), vy \(sliding.vy)")

        // MARK: Stride

        // Phase advances with ground covered, not with time — a character easing to a halt takes
        // shorter steps rather than moonwalking. Two runs over the same distance at different
        // frame rates must land on the same phase.
        func phaseAfter(frames: Int, dt: Double) -> Double {
            var state = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
            for _ in 0..<frames {
                _ = Locomotion.step(&state, desired: (LocomotionProfile.player.maxSpeed, 0),
                                    facingIntent: nil, profile: .player, dt: dt)
            }
            return state.gait.phase
        }
        check("stride is frame-rate independent",
              near(phaseAfter(frames: 60, dt: 1.0 / 60), phaseAfter(frames: 120, dt: 1.0 / 120), 0.02),
              "60 Hz \(phaseAfter(frames: 60, dt: 1.0 / 60)) vs 120 Hz \(phaseAfter(frames: 120, dt: 1.0 / 120))")

        check("one stride length is one full 2π cycle",
              {
                  var state = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
                  // Exactly one stride's worth of ground at top speed.
                  let seconds = LocomotionProfile.player.strideLength / LocomotionProfile.player.maxSpeed
                  _ = Locomotion.step(&state, desired: (LocomotionProfile.player.maxSpeed, 0),
                                      facingIntent: nil, profile: .player, dt: seconds)
                  return near(state.gait.phase, 2 * .pi, 0.001)
              }())

        // MARK: Observed movers

        // `observe` is what gives remote players and NPCs a gait. Walk one straight ahead.
        var walker = ObservedMotion()
        for _ in 0..<120 {
            Locomotion.observe(&walker, dx: 3, dy: 0, facing: 0, dt: 1.0 / 60)
        }
        check("an observed mover walking along its facing reads as forward",
              near(walker.gait.forward, 1, 0.02) && near(walker.gait.lateral, 0, 0.02),
              "forward \(walker.gait.forward), lateral \(walker.gait.lateral)")

        // The case that could not be expressed at all before: a patrolling NPC whose waypoint
        // rotation faces down the corridor while it walks across it.
        var crabbing = ObservedMotion()
        for _ in 0..<120 {
            Locomotion.observe(&crabbing, dx: 0, dy: 3, facing: 0, dt: 1.0 / 60)
        }
        check("an observed mover walking across its facing side-steps",
              near(crabbing.gait.lateral, -1, 0.02) && near(crabbing.gait.forward, 0, 0.02),
              "forward \(crabbing.gait.forward), lateral \(crabbing.gait.lateral)")

        // Standing still must settle, or every idle NPC in the school jogs on the spot.
        var halting = walker
        for _ in 0..<120 {
            Locomotion.observe(&halting, dx: 0, dy: 0, facing: 0, dt: 1.0 / 60)
        }
        check("an observed mover that stops settles to still",
              !halting.gait.isMoving && halting.gait.phase == 0,
              "intensity \(halting.gait.intensity), phase \(halting.gait.phase)")

        var teleported = walker
        teleported.reset()
        check("a teleport reset drops the carried velocity",
              teleported.vx == 0 && teleported.vy == 0 && !teleported.gait.isMoving)

        // MARK: Determinism

        check("the same seed replays the same sequence",
              {
                  var a = DeterministicRandom(seed: 1234)
                  var b = DeterministicRandom(seed: 1234)
                  return (0..<64).allSatisfy { _ in a.next() == b.next() }
              }())
        check("different seeds diverge",
              {
                  var a = DeterministicRandom(seed: 1)
                  var b = DeterministicRandom(seed: 2)
                  return (0..<8).contains { _ in a.next() != b.next() }
              }())
        check("unit stays inside [0, 1)",
              {
                  var source = DeterministicRandom(seed: 0)
                  return (0..<10_000).allSatisfy { _ in
                      let value = source.unit()
                      return value >= 0 && value < 1
                  }
              }())
        check("seed zero is not a dead state",
              {
                  var source = DeterministicRandom(seed: 0)
                  let first = source.unit()
                  return (0..<8).contains { _ in source.unit() != first }
              }())

        // An NPC's roam stream is keyed off its id, so the same NPC wanders the same way on
        // every client and in every run.
        check("an NPC's roam stream is a function of its id",
              {
                  var first = CharacterVisual()
                  var second = CharacterVisual()
                  return (0..<16).allSatisfy { _ in
                      first.roamNoise(seed: 42) == second.roamNoise(seed: 42)
                  }
              }())
        check("two NPCs do not roam in lockstep",
              {
                  var first = CharacterVisual()
                  var second = CharacterVisual()
                  return (0..<8).contains { _ in
                      first.roamNoise(seed: 42) != second.roamNoise(seed: 43)
                  }
              }())

        // MARK: The movement manager
        //
        // `CharacterMotor` is the thing every character in the game now moves through, so what
        // is worth pinning here is the *contract*: an ask is a best effort, and what comes back
        // out is what really happened.

        // Walk to a mark and stop on it, rather than skidding past and coming back.
        let marcher = CharacterMotor(profile: .player)
        marcher.teleport(x: 0, y: 0, facing: 0)
        marcher.moveCharacterTo(x: 300, y: 0)
        var walkFrames = 0
        while !marcher.hasArrived() && walkFrames < 600 {
            marcher.step(dt: 1.0 / 60)
            walkFrames += 1
        }
        check("moveCharacterTo arrives at its mark",
              marcher.hasArrived() && walkFrames < 600,
              "stopped at \(marcher.x) after \(walkFrames) frames")
        check("and does not overshoot it",
              marcher.x <= 300 + marcher.arrivalRadius,
              "x \(marcher.x)")
        check("and is stopped when it gets there",
              marcher.speed < 20, "speed \(marcher.speed)")

        // A target speed below the profile's top speed has to be honoured, or "walk over there"
        // and "sprint over there" are the same instruction.
        let stroller = CharacterMotor(profile: .player)
        stroller.moveCharacterTo(x: 5000, y: 0, targetSpeed: 60)
        var peakStroll: Double = 0
        for _ in 0..<180 {
            stroller.step(dt: 1.0 / 60)
            peakStroll = max(peakStroll, stroller.speed)
        }
        check("a target speed caps the walk",
              peakStroll <= 60.001, "peaked at \(peakStroll)")

        // The world's veto. A motor walked into a wall must shed the velocity into it.
        let walled = CharacterMotor(profile: .player)
        walled.driveCharacter(velocityX: LocomotionProfile.player.maxSpeed, velocityY: 0)
        for _ in 0..<30 { walled.step(dt: 1.0 / 60) }
        check("a motor reaches top speed against no constraint",
              near(walled.speed, LocomotionProfile.player.maxSpeed, 0.001),
              "speed \(walled.speed)")
        let hit = walled.step(dt: 1.0 / 60) { _, _ in (x: walled.x, y: walled.y) }
        check("a constraint that refuses the move is reported as blocked", hit.blocked)
        check("and the refused velocity is shed, not stored",
              walled.speed == 0, "speed \(walled.speed)")

        // Jumping. The overworld's arc is a launch speed against a gravity, and it has to come
        // back down in the 800 ms the emote lasts or the pose and the height drift apart.
        let jumper = CharacterMotor(profile: .player)
        jumper.gravity = 375
        check("a jump only starts from the ground", jumper.jump(speed: 150))
        check("and cannot be started again mid-air", !jumper.jump(speed: 150))
        var apex: Double = 0
        var airborneFrames = 0
        while jumper.isAirborne && airborneFrames < 300 {
            jumper.step(dt: 1.0 / 60)
            apex = max(apex, jumper.z)
            airborneFrames += 1
        }
        check("the jump peaks at exactly 30 units", near(apex, 30, 0.001), "apex \(apex)")
        check("and lands inside 800 ms",
              airborneFrames <= 49 && airborneFrames >= 44,
              "\(airborneFrames) frames")
        check("and finishes flat on the ground",
              jumper.z == 0 && !jumper.isAirborne, "z \(jumper.z)")

        // Deterministic animation means the same jump on a 60 Hz phone and a 120 Hz one.
        check("the jump is the same height at any frame rate",
              {
                  func apex(dt: Double) -> Double {
                      let motor = CharacterMotor(profile: .player)
                      motor.gravity = 375
                      motor.jump(speed: 150)
                      var peak: Double = 0
                      var frames = 0
                      while motor.isAirborne && frames < 2000 {
                          motor.step(dt: dt)
                          peak = max(peak, motor.z)
                          frames += 1
                      }
                      return peak
                  }
                  return near(apex(dt: 1.0 / 60), apex(dt: 1.0 / 120), 0.001)
              }())

        // MARK: Limbs

        // `moveHandTo` is a request, and one outside the arm's reach has to be clamped **and
        // reported**. `IKSolver` clamps silently, which is exactly the failure that had the
        // tennis game missing every ball for a session: something is always returned, and
        // nothing says it was not what you asked for.
        let reacher = CharacterMotor(profile: .player)
        let farAway = CharacterRig.rightShoulder + SIMD3<Float>(0, 500, 0)
        reacher.moveHandTo(.rightHand, local: farAway)
        for _ in 0..<120 { reacher.stepLimbs(dt: 1.0 / 60) }
        let reachDistance = simd_length(reacher.limbPosition(.rightHand) - CharacterRig.rightShoulder)
        check("a hand cannot go further than the arm is long",
              reachDistance <= LimbProfile.arm.maxReach + 0.01,
              "reached \(reachDistance) against a maximum of \(LimbProfile.arm.maxReach)")
        check("and the shortfall is reported as strain",
              reacher.strain(of: .rightHand) > 400,
              "strain \(reacher.strain(of: .rightHand))")

        // A reachable ask has to actually be reached, and reported as reached.
        let pointer = CharacterMotor(profile: .player)
        let nearby = CharacterRig.rightShoulder + SIMD3<Float>(6, 4, -8)
        pointer.moveHandTo(.rightHand, local: nearby)
        var handFrames = 0
        while !pointer.limbHasArrived(.rightHand) && handFrames < 120 {
            pointer.stepLimbs(dt: 1.0 / 60)
            handFrames += 1
        }
        check("a reachable hand target is reached",
              pointer.limbHasArrived(.rightHand) && handFrames < 120,
              "\(handFrames) frames, \(simd_length(pointer.limbPosition(.rightHand) - nearby)) short")
        check("and there is no strain in reaching it",
              pointer.strain(of: .rightHand) == 0)
        check("a driven hand has a velocity while it travels",
              {
                  let mover = CharacterMotor(profile: .player)
                  mover.moveHandTo(.rightHand, local: nearby)
                  mover.stepLimbs(dt: 1.0 / 60)
                  return simd_length(mover.limbVelocity(.rightHand)) > 0
              }())

        // The hand-over. A limb nobody is driving must leave the rig's own animation alone, and
        // one being driven must win outright. Anything in between is a crossfade, which is what
        // stops a swing from snapping out of a walk cycle.
        func handTarget(after motor: CharacterMotor, rigPose: SIMD3<Float>) -> SIMD3<Float> {
            var mutation = RigMutation(bodyPivotPosition: .zero,
                                       bodyPivotRotation: .zero,
                                       headRotation: .zero,
                                       leftHandTarget: .zero,
                                       rightHandTarget: rigPose,
                                       leftFootTarget: .zero,
                                       rightFootTarget: .zero,
                                       holding: nil)
            motor.poseOverride()?(&mutation)
            return mutation.rightHandTarget
        }

        let idle = CharacterMotor(profile: .player)
        let walkCyclePose = SIMD3<Float>(4, 18, 9)
        check("an undriven limb keeps whatever the rig gave it",
              handTarget(after: idle, rigPose: walkCyclePose) == walkCyclePose)
        check("and the motor tracks it, so taking over starts from where it is",
              idle.limbPosition(.rightHand) == walkCyclePose,
              "motor thinks the hand is at \(idle.limbPosition(.rightHand))")

        let engaged = CharacterMotor(profile: .player)
        engaged.moveHandTo(.rightHand, local: nearby)
        for _ in 0..<60 { engaged.stepLimbs(dt: 1.0 / 60) }
        check("a fully engaged limb overrides the rig",
              simd_length(handTarget(after: engaged, rigPose: walkCyclePose) - nearby) < 0.6,
              "posed at \(handTarget(after: engaged, rigPose: walkCyclePose))")

        engaged.releaseLimb(.rightHand)
        engaged.stepLimbs(dt: 1.0 / 60)
        let midRelease = handTarget(after: engaged, rigPose: walkCyclePose)
        check("releasing crossfades rather than snapping",
              midRelease != walkCyclePose && simd_length(midRelease - nearby) > 0.01,
              "posed at \(midRelease)")
        for _ in 0..<60 { engaged.stepLimbs(dt: 1.0 / 60) }
        check("and finishes back on the rig's own animation",
              handTarget(after: engaged, rigPose: walkCyclePose) == walkCyclePose)

        // MARK: Frames, once more with the motor

        // The same sign convention the rig uses, now going through the motor's own converter.
        // Facing 0° is +X; the character's left is local +Y, which lands on world −Y.
        let framed = CharacterMotor(profile: .player)
        framed.teleport(x: 100, y: 200, facing: 0)
        let ahead = framed.localToWorld(SIMD3<Double>(10, 0, 0))
        check("localToWorld puts local +X in front of the character",
              near(ahead.x, 110) && near(ahead.y, 200),
              "got (\(ahead.x), \(ahead.y))")
        let toTheLeft = framed.localToWorld(SIMD3<Double>(0, 10, 0))
        check("and local +Y on the character's left, which is world −Y",
              near(toTheLeft.x, 100) && near(toTheLeft.y, 190),
              "got (\(toTheLeft.x), \(toTheLeft.y))")
        check("and lifts by the body pivot's height",
              near(ahead.z, Double(CharacterRig.bodyPivotHeight)),
              "z \(ahead.z)")

        // The observed path, through the motor this time: every character in the game that this
        // client does not drive goes through here.
        let watched = CharacterMotor(profile: .observed)
        watched.teleport(x: 0, y: 0, facing: 0)
        for frame in 1...120 {
            watched.observe(x: Double(frame) * 3, y: 0, z: 0, facing: 0, dt: 1.0 / 60)
        }
        check("an observed motor walking along its facing reads as forward",
              near(watched.gait.forward, 1, 0.02) && near(watched.gait.lateral, 0, 0.02),
              "forward \(watched.gait.forward), lateral \(watched.gait.lateral)")
        check("and its position is exactly where it was put",
              near(watched.x, 360), "x \(watched.x)")

        Log.world("selftest — \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
#endif
