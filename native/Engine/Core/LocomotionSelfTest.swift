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
        check("the walking profile matches the old per-frame speed",
              near(LocomotionProfile.playerWalking.maxSpeed, 3 * 60),
              "maxSpeed \(LocomotionProfile.playerWalking.maxSpeed), expected 180")
        // `player` is now the whole range, walk to sprint, and its ceiling is the sprint — the
        // throttle asks for a fraction of it. Break this and every stride in the game rescales.
        check("the player's ceiling is the 1.2× sprint",
              near(LocomotionProfile.player.maxSpeed, 3 * 60 * 1.2),
              "maxSpeed \(LocomotionProfile.player.maxSpeed), expected 216")
        check("braking outruns acceleration",
              LocomotionProfile.player.braking > LocomotionProfile.player.acceleration,
              "a character that cannot stop faster than it starts feels like ice")
        check("a sprint reaches further per stride than the old walk-only profile",
              LocomotionProfile.player.strideLength > LocomotionProfile.playerWalking.strideLength)
        // Observed movers are measured against the same ceiling the local player is, or a remote
        // player sprinting past reads as intensity 1.4 and everyone ambles at a different scale.
        check("observed movers share the player's ceiling",
              near(LocomotionProfile.observed.maxSpeed, LocomotionProfile.player.maxSpeed))

        // MARK: The stick

        // The whole point of the analogue stick: the magnitude is the speed. A stick reporting a
        // corner-of-the-square 1.41 must not outrun one pushed straight along an axis.
        check("a centred stick asks for nothing",
              !InputState().isMoving && InputState().throttle == 0)
        check("throttle is the length of the vector",
              near(InputState(move: SIMD2(0.3, 0.4)).throttle, 0.5, 1e-9),
              "got \(InputState(move: SIMD2(0.3, 0.4)).throttle)")
        check("and is clamped at 1",
              near(InputState(move: SIMD2(1, 1)).throttle, 1),
              "got \(InputState(move: SIMD2(1, 1)).throttle)")
        check("a stick built from a heading reads that heading back",
              {
                  let stick = InputState.stick(headingDegrees: 135, throttle: 0.5)
                  return near(stick.angleDegrees, 135, 1e-9) && near(stick.throttle, 0.5, 1e-9)
              }(),
              "got \(InputState.stick(headingDegrees: 135, throttle: 0.5).angleDegrees)°")
        // World +Y is *down* the screen and so is UIKit's, which is why the touch offset needs
        // no sign flipping on the way in. Pin it: south is +y.
        check("a stick pushed south is world +y",
              InputState.stick(headingDegrees: 90, throttle: 1).move.y > 0.99)

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

        // MARK: Walk, run and sprint

        // The analogue stick's reason for existing. Asking for a third of top speed has to
        // *give* a third of top speed and read as a walk; asking for all of it has to read as a
        // sprint. Before this, `intensity` was pinned near 1 whatever the character was doing,
        // because the profile's ceiling moved with the demand instead of the demand moving
        // inside a fixed ceiling.
        func gaitHolding(throttle: Double, frames: Int = 180) -> Gait {
            var state = LocomotionState()
            let speed = LocomotionProfile.player.maxSpeed * throttle
            for _ in 0..<frames {
                _ = Locomotion.step(&state, desired: (speed, 0), facingIntent: nil,
                                    profile: .player, dt: 1.0 / 60)
            }
            return state.gait
        }
        let ambling = gaitHolding(throttle: 0.35)
        let sprinting = gaitHolding(throttle: 1.0)
        check("a third of a throttle is a third of top speed",
              near(ambling.intensity, 0.35, 0.01), "intensity \(ambling.intensity)")
        check("and reads as a walk, not as a run",
              ambling.run == 0, "run \(ambling.run)")
        check("a full throttle reads as a flat-out sprint",
              near(sprinting.run, 1, 0.001) && near(sprinting.intensity, 1, 0.001),
              "run \(sprinting.run), intensity \(sprinting.intensity)")
        check("the walk-to-run boundary is where the profile says it is",
              {
                  let below = gaitHolding(throttle: LocomotionProfile.player.runThreshold - 0.05)
                  let above = gaitHolding(throttle: LocomotionProfile.player.runThreshold + 0.05)
                  return below.run == 0 && above.run > 0 && above.run < 1
              }(),
              "the ramp has to start at runThreshold and still be climbing just past it")

        // A slower character takes shorter steps *as well as* slower ones. Scaling only the
        // cadence leaves it taking sprint-sized strides in slow motion, which is a moonwalk.
        //
        // Ground covered per full 2π of phase, at a given fraction of top speed. The phase wraps
        // at 4π, so the advance has to be accumulated a frame at a time rather than subtracted
        // across the loop — do it the other way and the fast case silently measures 600 frames.
        func strideCovered(throttle: Double) -> Double {
            var state = LocomotionState()
            let speed = LocomotionProfile.player.maxSpeed * throttle
            for _ in 0..<120 {
                _ = Locomotion.step(&state, desired: (speed, 0), facingIntent: nil,
                                    profile: .player, dt: 1.0 / 60)
            }
            var advanced: Double = 0
            var covered: Double = 0
            var previousPhase = state.gait.phase
            var frames = 0
            while advanced < 2 * .pi && frames < 2000 {
                // `step` produces a *demand*; nothing moves until `commit` accepts it, so the
                // ground covered is the demand, not a difference in `state.x`.
                let demand = Locomotion.step(&state, desired: (speed, 0), facingIntent: nil,
                                             profile: .player, dt: 1.0 / 60)
                var phaseStep = state.gait.phase - previousPhase
                if phaseStep < 0 { phaseStep += 4 * .pi }
                advanced += phaseStep
                previousPhase = state.gait.phase
                covered += (demand.dx * demand.dx + demand.dy * demand.dy).squareRoot()
                frames += 1
            }
            return covered
        }
        check("a walk's stride is shorter than a sprint's, not just slower",
              strideCovered(throttle: 0.35) < strideCovered(throttle: 1) * 0.85,
              "walk \(strideCovered(throttle: 0.35)) vs sprint \(strideCovered(throttle: 1))")
        // At full speed the stride is the profile's, un-shortened — that is the definition of
        // `strideLength`. The tolerance is one frame's worth of ground, because the loop above
        // can only stop on the frame *after* the one that crosses 2π.
        check("and a sprint's stride is the profile's",
              near(strideCovered(throttle: 1), LocomotionProfile.player.strideLength,
                   LocomotionProfile.player.maxSpeed / 60),
              "covered \(strideCovered(throttle: 1)) per stride, profile says \(LocomotionProfile.player.strideLength)")

        // MARK: Counteracting the inertia
        //
        // The signals the rig braces, counterweights and counter-rotates off. Every one of them
        // is a sign, which is exactly the kind of thing this file is for: get one backwards and
        // the character throws the wrong foot out and falls into the turn instead of out of it.

        // Cut hard to the character's left while facing straight ahead. Local +Y is their left,
        // and world −Y is where that lands at a 0° facing.
        var cutting = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
        for _ in 0..<20 {
            _ = Locomotion.step(&cutting,
                                desired: (0, -LocomotionProfile.player.maxSpeed),
                                facingIntent: 0, profile: .player, dt: 1.0 / 60)
        }
        check("accelerating towards the character's left is a positive lean",
              cutting.gait.leanLateral > 0.2,
              "leanLateral \(cutting.gait.leanLateral) — the rig braces on the wrong foot if this flips")

        // Braking from a sprint. `leanForward` going negative is what puts a foot out in front.
        var skidding = LocomotionState(vx: LocomotionProfile.player.maxSpeed, facing: 0)
        for _ in 0..<6 {
            _ = Locomotion.step(&skidding, desired: (0, 0), facingIntent: 0,
                                profile: .player, dt: 1.0 / 60)
        }
        check("braking is a negative forward lean",
              skidding.gait.leanForward < -0.1,
              "leanForward \(skidding.gait.leanForward)")
        check("and setting off is a positive one",
              {
                  var starting = LocomotionState(facing: 0)
                  for _ in 0..<6 {
                      _ = Locomotion.step(&starting,
                                          desired: (LocomotionProfile.player.maxSpeed, 0),
                                          facingIntent: 0, profile: .player, dt: 1.0 / 60)
                  }
                  return starting.gait.leanForward > 0.1
              }())

        // Turning on the spot: no velocity at all, so `leanLateral` has nothing to say and
        // `turning` is the only signal there is. This is the case the shoulders trail through.
        //
        // Held, not sampled at the end: at 540°/s a quarter turn is over in ten frames and the
        // smoothing has decayed most of the way back to zero by frame thirty. Spinning on the
        // spot means re-aiming the intent ahead of the body every frame.
        func spinPeak(clockwise: Bool) -> (peak: Double, intensity: Double) {
            var state = LocomotionState(facing: 0)
            var peak: Double = 0
            for _ in 0..<60 {
                let ahead = state.facing + (clockwise ? 45 : -45)
                _ = Locomotion.step(&state, desired: (0, 0), facingIntent: ahead,
                                    profile: .player, dt: 1.0 / 60)
                if abs(state.gait.turning) > abs(peak) { peak = state.gait.turning }
            }
            return (peak, state.gait.intensity)
        }
        let clockwiseSpin = spinPeak(clockwise: true)
        check("turning on the spot reports a turn even with no velocity",
              clockwiseSpin.peak > 0.1 && clockwiseSpin.intensity == 0,
              "turning \(clockwiseSpin.peak), intensity \(clockwiseSpin.intensity)")
        check("and turning the other way flips its sign",
              spinPeak(clockwise: false).peak < -0.1,
              "turning \(spinPeak(clockwise: false).peak)")
        check("a settled heading stops reporting a turn",
              {
                  var settled = LocomotionState(facing: 0)
                  for _ in 0..<240 {
                      _ = Locomotion.step(&settled, desired: (0, 0), facingIntent: 0,
                                          profile: .player, dt: 1.0 / 60)
                  }
                  return abs(settled.gait.turning) < 0.01
              }())

        // A heading that crosses the 0/360 wrap must not read as a 359° whip round.
        check("a turn across the wrap is small, not enormous",
              near(Locomotion.shortestTurn(from: 350, to: 10), 20),
              "got \(Locomotion.shortestTurn(from: 350, to: 10))")
        check("and is signed the short way in both directions",
              near(Locomotion.shortestTurn(from: 10, to: 350), -20),
              "got \(Locomotion.shortestTurn(from: 10, to: 350))")

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

        // `observe` is what gives remote players and NPCs a gait. Run one flat out, straight
        // ahead — a frame's worth of ground at the observed profile's top speed.
        let observedStep = LocomotionProfile.observed.maxSpeed / 60
        var walker = ObservedMotion()
        for _ in 0..<120 {
            Locomotion.observe(&walker, dx: observedStep, dy: 0, facing: 0, dt: 1.0 / 60)
        }
        check("an observed mover walking along its facing reads as forward",
              near(walker.gait.forward, 1, 0.02) && near(walker.gait.lateral, 0, 0.02),
              "forward \(walker.gait.forward), lateral \(walker.gait.lateral)")

        // The case that could not be expressed at all before: a patrolling NPC whose waypoint
        // rotation faces down the corridor while it walks across it.
        var crabbing = ObservedMotion()
        for _ in 0..<120 {
            Locomotion.observe(&crabbing, dx: 0, dy: observedStep, facing: 0, dt: 1.0 / 60)
        }
        check("an observed mover walking across its facing side-steps",
              near(crabbing.gait.lateral, -1, 0.02) && near(crabbing.gait.forward, 0, 0.02),
              "forward \(crabbing.gait.forward), lateral \(crabbing.gait.lateral)")

        // An NPC ambling at a third of a sprint must read as a walk, not as a sprint played
        // slowly. Before the profile ceiling meant the sprint, every mover came out at ~1.
        var ambler = ObservedMotion()
        for _ in 0..<120 {
            Locomotion.observe(&ambler, dx: observedStep * 0.3, dy: 0, facing: 0, dt: 1.0 / 60)
        }
        check("a slow observed mover is a walk, not a slow sprint",
              near(ambler.gait.intensity, 0.3, 0.02) && ambler.gait.run == 0,
              "intensity \(ambler.gait.intensity), run \(ambler.gait.run)")

        // A turn has to be differentiated out of the heading, because nothing upstream of an
        // NPC or a remote player ever forms one. Clockwise is a turn to the character's right.
        var pivoting = ObservedMotion()
        for frame in 1...60 {
            Locomotion.observe(&pivoting, dx: 0, dy: 0, facing: Double(frame) * 2,
                               dt: 1.0 / 60)
        }
        check("an observed mover turning clockwise reports a positive turn",
              pivoting.gait.turning > 0.1,
              "turning \(pivoting.gait.turning)")
        check("and it does not fire on the very first frame it is seen",
              {
                  var fresh = ObservedMotion()
                  Locomotion.observe(&fresh, dx: 0, dy: 0, facing: 250, dt: 1.0 / 60)
                  return fresh.gait.turning == 0
              }(),
              "a heading nobody has seen before is not a turn")

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

        // MARK: Arms, by angle

        // `armTarget` exists because an arm swung by pushing its hand through space is a
        // straight stick whose swing gets silently clamped by the IK. Two things have to hold
        // for the replacement to be worth having: the neutral angles must reproduce the neutral
        // hand exactly, and **nothing it produces may ever be out of reach**.
        let neutralByAngle = CharacterRig.armTarget(shoulder: CharacterRig.leftShoulder,
                                                    swing: CharacterRig.neutralArmSwing,
                                                    sideways: -CharacterRig.neutralArmSideways,
                                                    flex: CharacterRig.neutralArmFlex)
        check("the neutral arm angles rebuild the neutral hand",
              simd_length(neutralByAngle - CharacterRig.neutralLeftHand) < 0.01,
              "got \(neutralByAngle), wanted \(CharacterRig.neutralLeftHand)")
        check("and the mirrored ones rebuild the other hand",
              {
                  let other = CharacterRig.armTarget(shoulder: CharacterRig.rightShoulder,
                                                     swing: CharacterRig.neutralArmSwing,
                                                     sideways: CharacterRig.neutralArmSideways,
                                                     flex: CharacterRig.neutralArmFlex)
                  return simd_length(other - CharacterRig.neutralRightHand) < 0.01
              }())

        // The whole range, swept. Anything outside `2 · armBone` is a target `IKSolver.solve`
        // would quietly move somewhere else, and the drawn arm would stop matching the pose.
        check("no arm angle can put a hand out of reach",
              {
                  var worst: Float = 0
                  for swingStep in -12...12 {
                      for sideStep in -13...13 {
                          for flexStep in 0...24 {
                              let hand = CharacterRig.armTarget(
                                  shoulder: CharacterRig.leftShoulder,
                                  swing: Float(swingStep) * 0.15,
                                  sideways: Float(sideStep) * 0.1,
                                  flex: Float(flexStep) * 0.1)
                              worst = max(worst,
                                          simd_length(hand - CharacterRig.leftShoulder))
                          }
                      }
                  }
                  return worst <= CharacterRig.armBone * 2 + 0.001
              }(),
              "a swept arm reached past \(CharacterRig.armBone * 2)")

        // A bent elbow brings the hand in. This is the number the old formulation could not
        // control at all: the neutral hand sat at 96% of full extension, so every arm in the
        // game was a locked stick whatever the tables asked for.
        func armReach(flex: Float) -> Float {
            simd_length(CharacterRig.armTarget(shoulder: CharacterRig.leftShoulder,
                                               swing: 0, sideways: 0, flex: flex)
                        - CharacterRig.leftShoulder)
        }
        check("a locked elbow spans both bones",
              abs(armReach(flex: 0) - CharacterRig.armBone * 2) < 0.001,
              "reach \(armReach(flex: 0))")
        check("and a right angle pulls the hand in by nearly a third",
              abs(armReach(flex: .pi / 2) - CharacterRig.armBone * 2 * 0.7071) < 0.01,
              "reach \(armReach(flex: .pi / 2))")
        check("the neutral arm is bent, not locked",
              armReach(flex: CharacterRig.neutralArmFlex) < CharacterRig.armBone * 2 - 0.4,
              "reach \(armReach(flex: CharacterRig.neutralArmFlex)) of \(CharacterRig.armBone * 2)")

        // Positive swing is forward and positive sideways is the character's left — the same
        // frame everything else in this file is pinned against.
        check("positive swing puts the hand in front of the shoulder",
              CharacterRig.armTarget(shoulder: .zero, swing: 0.6, sideways: 0, flex: 0.5).x > 0)
        check("positive sideways puts it on the character's left",
              CharacterRig.armTarget(shoulder: .zero, swing: 0, sideways: 0.6, flex: 0.5).y > 0)
        check("and a hanging arm hangs down",
              CharacterRig.armTarget(shoulder: .zero, swing: 0, sideways: 0, flex: 0.5).z < 0)

        // MARK: Legs, by angle

        // The same contract as the arms, one session later, with one extra wrinkle: the leg's
        // two bones are different lengths, so the span is the law of cosines rather than the
        // arms' `2·b·cos(flex/2)`.
        let neutralLegByAngle = CharacterRig.legTarget(hip: CharacterRig.leftHip,
                                                       swing: CharacterRig.neutralLegSwing,
                                                       sideways: -CharacterRig.neutralLegSideways,
                                                       flex: CharacterRig.neutralLegFlex)
        check("the neutral leg angles rebuild the neutral foot",
              simd_length(neutralLegByAngle - CharacterRig.neutralLeftFoot) < 0.01,
              "got \(neutralLegByAngle), wanted \(CharacterRig.neutralLeftFoot)")
        check("and the mirrored ones rebuild the other foot",
              {
                  let other = CharacterRig.legTarget(hip: CharacterRig.rightHip,
                                                     swing: CharacterRig.neutralLegSwing,
                                                     sideways: CharacterRig.neutralLegSideways,
                                                     flex: CharacterRig.neutralLegFlex)
                  return simd_length(other - CharacterRig.neutralRightFoot) < 0.01
              }())

        // The whole range, swept, measured **at the ankle** — which is what `IKSolver.solve`
        // actually gets handed, and what it would silently move somewhere else.
        let legReachMax = CharacterRig.thighBone + CharacterRig.shinBone
        func legReach(swing: Float, sideways: Float, flex: Float) -> Float {
            var ankle = CharacterRig.legTarget(hip: CharacterRig.leftHip,
                                               swing: swing, sideways: sideways, flex: flex)
            ankle.z += CharacterRig.ankleLift
            return simd_length(ankle - CharacterRig.leftHip)
        }
        check("no leg angle can put a foot out of reach",
              {
                  var worst: Float = 0
                  for swingStep in -11...11 {
                      for sideStep in -6...6 {
                          for flexStep in 0...24 {
                              worst = max(worst, legReach(swing: Float(swingStep) * 0.1,
                                                          sideways: Float(sideStep) * 0.1,
                                                          flex: Float(flexStep) * 0.1))
                          }
                      }
                  }
                  return worst <= legReachMax + 0.001
              }(),
              "a swept leg reached past \(legReachMax)")

        // And never so folded that the IK's *minimum* separation kicks in either — that clamp is
        // just as silent as the far one, and a knee is the joint most likely to hit it.
        check("nor so folded that the knee collapses",
              legReach(swing: 0, sideways: 0, flex: 2.4)
                > abs(CharacterRig.thighBone - CharacterRig.shinBone) + 0.02,
              "reach \(legReach(swing: 0, sideways: 0, flex: 2.4))")

        check("a locked knee spans both bones",
              abs(legReach(swing: 0, sideways: 0, flex: 0) - legReachMax) < 0.001,
              "reach \(legReach(swing: 0, sideways: 0, flex: 0))")
        check("the neutral leg is very nearly straight — which is why it used to clamp",
              legReach(swing: 0, sideways: 0, flex: CharacterRig.neutralLegFlex) > legReachMax * 0.95,
              "reach \(legReach(swing: 0, sideways: 0, flex: CharacterRig.neutralLegFlex))")
        check("and a walk's mid-swing knee brings the foot up off the floor",
              {
                  let planted = CharacterRig.legTarget(hip: CharacterRig.leftHip, swing: 0,
                                                       sideways: 0,
                                                       flex: CharacterRig.neutralLegFlex)
                  let lifted = CharacterRig.legTarget(hip: CharacterRig.leftHip, swing: 0,
                                                      sideways: 0,
                                                      flex: CharacterRig.neutralLegFlex + 0.88)
                  return lifted.z - planted.z > 3 && lifted.z - planted.z < 9
              }(),
              "lift of \(CharacterRig.legTarget(hip: CharacterRig.leftHip, swing: 0, sideways: 0, flex: CharacterRig.neutralLegFlex + 0.88).z - CharacterRig.neutralLeftFoot.z)")

        // Same frame as everything else. A knee that bends the wrong way is the leg version of
        // the mirrored-animation bug this whole file exists to catch.
        check("positive swing puts the foot in front of the hip",
              CharacterRig.legTarget(hip: .zero, swing: 0.6, sideways: 0, flex: 0.5).x > 0)
        check("positive sideways puts it on the character's left",
              CharacterRig.legTarget(hip: .zero, swing: 0, sideways: 0.6, flex: 0.5).y > 0)
        check("and a standing leg stands under its hip",
              {
                  let foot = CharacterRig.legTarget(hip: .zero, swing: 0, sideways: 0, flex: 0.5)
                  return foot.z < 0 && abs(foot.x) < 0.001 && abs(foot.y) < 0.001
              }())

        // MARK: The stride, over a whole cycle

        // These are claims about the *whole* stride, which is why `strideLegs` is a function
        // rather than twenty lines inside `pose`. Walking one cycle at a time is the only way to
        // catch a foot that floats, a foot that sinks, or a knee that only misbehaves at one
        // phase — none of which shows up in a screenshot of one frame.
        func posed(phase: Float, forward: Float, lateral: Float = 0, run: Float, effort: Float)
            -> (left: SIMD3<Float>, right: SIMD3<Float>, angles: (right: CharacterRig.LegAngles,
                                                                  left: CharacterRig.LegAngles)) {
            let legs = CharacterRig.strideLegs(phase: phase, forward: forward, lateral: lateral,
                                               run: run, effort: effort)
            return (CharacterRig.legTarget(hip: CharacterRig.leftHip, swing: legs.right.swing,
                                           sideways: legs.right.sideways, flex: legs.right.flex),
                    CharacterRig.legTarget(hip: CharacterRig.rightHip, swing: legs.left.swing,
                                           sideways: legs.left.sideways, flex: legs.left.flex),
                    legs)
        }

        // **The contact promise.** `pose` sinks the body by `groundContactSink` so the lower foot
        // lands on the floor instead of riding up the arc a swinging leg sweeps. That correction
        // is capped at 3 units, and a cap that bites is a character floating or sinking — so the
        // real assertion is that it never gets close to biting anywhere in the range.
        check("the ground-contact sink never reaches its cap",
              {
                  var worst: Float = 0
                  for throttleStep in 1...12 {
                      let throttle = Float(throttleStep) * 0.1
                      for runStep in 0...4 {
                          for phaseStep in 0..<48 {
                              let legs = posed(phase: Float(phaseStep) * .pi / 24,
                                               forward: throttle,
                                               run: Float(runStep) * 0.25,
                                               effort: min(1.2, throttle))
                              let sink = CharacterRig.groundContactSink(leftFoot: legs.left,
                                                                       rightFoot: legs.right)
                              worst = max(worst, abs(sink))
                          }
                      }
                  }
                  return worst < 2.6
              }(),
              "the sink came within 0.4 of its 3-unit cap")

        // And in the range a character actually spends its time, the correction is a **bob**, not
        // a lurch: under a unit at a walk. That number is not tuned, it falls out of the leg's
        // geometry — which is the whole argument for deriving it rather than authoring it.
        check("a walk's pelvic drop is under a unit",
              {
                  var worst: Float = 0
                  for phaseStep in 0..<48 {
                      let legs = posed(phase: Float(phaseStep) * .pi / 24, forward: 0.5,
                                       run: 0, effort: 0.5)
                      worst = max(worst, abs(CharacterRig.groundContactSink(leftFoot: legs.left,
                                                                           rightFoot: legs.right)))
                  }
                  return worst < 1
              }())

        // A walk's knee and a sprint's knee are different knees. This is the whole point of the
        // rewrite: the old formulation moved a *height* and the knee was whatever fell out of it,
        // so there was no number in the game that could tell the two apart.
        func peakKnee(forward: Float, run: Float) -> Float {
            var peak: Float = 0
            for phaseStep in 0..<48 {
                let legs = posed(phase: Float(phaseStep) * .pi / 24, forward: forward,
                                 run: run, effort: min(1.2, forward))
                peak = max(peak, max(legs.angles.right.flex, legs.angles.left.flex))
            }
            return peak
        }
        let walkKnee = peakKnee(forward: 0.5, run: 0)
        let sprintKnee = peakKnee(forward: 1, run: 1)
        check("a walk's knee peaks around 60°",
              walkKnee > 0.85 && walkKnee < 1.25, "\(walkKnee) rad")
        check("a sprint's is nearly twice that",
              sprintKnee > 1.9 && sprintKnee < 2.4, "\(sprintKnee) rad")
        check("and standing still bends neither",
              peakKnee(forward: 0, run: 0) == CharacterRig.neutralLegFlex)

        // Left and right have to be the same stride half a cycle apart, or the character limps.
        check("the two legs are one stride, half a cycle apart",
              {
                  for phaseStep in 0..<24 {
                      let phase = Float(phaseStep) * .pi / 12
                      let here = CharacterRig.strideLegs(phase: phase, forward: 0.8, lateral: 0,
                                                         run: 0.4, effort: 0.8)
                      let opposite = CharacterRig.strideLegs(phase: phase + .pi, forward: 0.8,
                                                             lateral: 0, run: 0.4, effort: 0.8)
                      if abs(here.right.flex - opposite.left.flex) > 1e-5 { return false }
                      if abs(here.right.swing - opposite.left.swing) > 1e-5 { return false }
                  }
                  return true
              }())

        // The stride grows with the throttle. It could not before: `forward` was pinned at ~1
        // whatever speed the character was doing, so a walk was a sprint played slowly.
        func strideSpan(forward: Float, run: Float) -> Float {
            var lowest: Float = .greatestFiniteMagnitude, highest: Float = -.greatestFiniteMagnitude
            for phaseStep in 0..<48 {
                let legs = posed(phase: Float(phaseStep) * .pi / 24, forward: forward,
                                 run: run, effort: min(1.2, forward))
                lowest = min(lowest, legs.left.x)
                highest = max(highest, legs.left.x)
            }
            return highest - lowest
        }
        check("a full-throttle stride is longer than a dawdle's",
              strideSpan(forward: 1, run: 1) > strideSpan(forward: 0.3, run: 0) * 2.5,
              "\(strideSpan(forward: 1, run: 1)) against \(strideSpan(forward: 0.3, run: 0))")
        check("and a sprint's step is about twenty units",
              strideSpan(forward: 1, run: 1) > 17 && strideSpan(forward: 1, run: 1) < 26,
              "\(strideSpan(forward: 1, run: 1))")

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
            watched.observe(x: Double(frame) * observedStep, y: 0, z: 0, facing: 0, dt: 1.0 / 60)
        }
        check("an observed motor walking along its facing reads as forward",
              near(watched.gait.forward, 1, 0.02) && near(watched.gait.lateral, 0, 0.02),
              "forward \(watched.gait.forward), lateral \(watched.gait.lateral)")
        check("and its position is exactly where it was put",
              near(watched.x, observedStep * 120), "x \(watched.x)")

        Log.world("selftest — \(passed) passed, \(failed) failed")
        return failed == 0
    }
}
#endif
