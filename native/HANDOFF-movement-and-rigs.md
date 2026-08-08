# Handoff — deterministic character movement and the skeleton rigs

Part 1 of 2. Part 2 is [HANDOFF-tennis3d.md](HANDOFF-tennis3d.md), which is the first consumer
of everything here. This half is **engine work that the whole game uses**, including the
overworld.

Zone note: this touches `Engine/Core`, `Engine/Entity`, `Engine/Render` and `Engine/World` —
red under [AGENTS.md](../AGENTS.md). Ben asked for it directly ("maybe need a new character
movement system that could be shared with the rest of the game", then for the character models
to be modelled properly, joints and all, and then for **one shared set of classes to handle all
character movement in every minigame, with nothing else anywhere manipulating limbs or tracking
velocity**). `server/**` and `JoelsWorld.xcodeproj/**` are untouched.

**Three sessions so far.**
- Session 1 built `Locomotion` and the lateral stride.
- Session 2 pushed the gait out to every character, made NPCs deterministic, added `-selftest`,
  and rebuilt the character mesh.
- Session 3 — this one — built **`CharacterMotor`**, moved every character in the game onto it,
  gave the rig hands with thumbs and a waist that twists, and made the jump real.

Read "Where it stands" before picking anything up. **Read "Traps" before running anything.**

---

## Part A — `CharacterMotor`, the movement manager

### The one rule

> **`CharacterMotor` is the only thing in the game allowed to move a character or a limb, and
> the only thing that tracks a velocity.**

Everything else asks. If you find yourself writing `mutation.rightHandTarget = …` outside
`CharacterRig`, or remembering where something was last frame so you can work out how fast it is
going, that is the rule being broken and there is an API for it.

### What it replaced

Three separate systems, each with its own bookkeeping and its own bugs:

| Was | Where |
|---|---|
| A `LocomotionState` assembled by hand every frame out of loose fields on `Player`, then unpacked again | `GameState.update` |
| An `ObservedMotion` carried beside each remote player and NPC | `PhysicsEngine.processInterpolation` |
| A `LocomotionState` per side, a court clamp written out by hand, limb targets written straight into `RigMutation`, and a remembered racket-head position so the contact test could derive its speed | `Tennis3DGame` |

All three are now one class. `Player`'s movement fields are a **mirror** written at the end of
each step, kept only because the wire payload, the camera and the renderer read them.

### The API

```swift
motor.moveCharacterTo(x: 400, y: 120, targetSpeed: 180, facing: 270)  // go and stand there
motor.driveCharacter(velocityX: vx, velocityY: vy)                    // or: this way, this fast
motor.holdPosition()                                                  // brake and settle
motor.faceTowards(270)   /  motor.setFacing(90)                       // heading intent / outright
motor.jump(speed: 150)                                                // leave the ground
motor.moveHandTo(.rightHand, local: contactPose)                      // put that hand there
motor.moveFootTo(.leftFoot, local: step)
motor.releaseLimb(.rightHand)                                         // back to the walk cycle
motor.step(dt: dt, constrain: walls)                                  // one frame of all of it
```

and what actually happened comes back out:

```swift
motor.x / .y / .z / .facing / .speed / .gait / .isAirborne
motor.hasArrived()        motor.distanceToDestination
motor.limbPosition(.rightHand)   // where the hand IS, after reach and inertia
motor.limbVelocity(.rightHand)   // how fast, so nobody has to remember last frame
motor.strain(of: .rightHand)     // how far outside its reach the ask was. 0 means reachable.
motor.limbHasArrived(.rightHand)
motor.poseOverride(then: extra)  // hand this to CharacterRig.pose
```

**Everything is a request and the motor makes a best effort.** A wall eats the movement; a hand
target outside the arm's reach is clamped and the shortfall shows up as `strain`; a jump while
airborne is ignored. That is deliberate — see the trap below about silent clamping.

### `constrain` — the world's veto

`step`/`stepBody` take a closure handed the position the motor would *like* and returning the
one it is *allowed*. The overworld passes `PhysicsEngine.processMovement`; tennis passes a court
clamp. Whatever comes back is committed **and fed back into the velocity**, so a character shoved
into a wall sheds its speed into it instead of storing it up and firing sideways on release.

### `stepBody` vs `stepLimbs`

`step` does both. They are separable because a minigame running a fixed physics sub-step wants
the limbs stepped at *that* rate — a racket head crossing a ball in four milliseconds is the whole
contact test — while steering the body once a frame is plenty. Tennis calls `stepBody` in
`run(_:dt:)` and `stepLimbs` in `driveHands(for:dt:)`.

### `observe` — characters this client does not drive

A remote player's position comes off the wire; an NPC's comes from a waypoint. Nothing in either
path forms a velocity, so `observe(x:y:z:facing:dt:)` differentiates the position and resolves the
gait out of it. Call it **every frame, including frames where nothing moved** — that is what lets
the stride finish its step and settle instead of creeping.

Every character now has a motor: `CharacterVisual.motor`, one per id, a `let` on a struct so a
copy of the struct is a copy of the reference.

### The limb hand-over

`LimbState.blend` eases 0→1 over `engageTime` and back over `releaseTime`. At 0 the rig's own
animation owns the limb; at 1 the motor does; in between it crossfades. **And while it is 0 the
motor reads the rig's pose back in** (`observeRigPose`), so `moveHandTo` always starts from where
the hand visibly is rather than from wherever it was left. That read-back is why
`poseOverride()` returns a closure even when nothing is being driven — the cost when idle is four
vector reads, and without it the first frame of every swing whips the arm across the body.

### Jumping is real now

The `jump` emote used to draw its own arc onto the body pivot — `progress × (1 − progress) × 4 ×
30` — with the character never leaving the ground. `GameState.jumpSpeed` (150) and `jumpGravity`
(375) reproduce that arc exactly as a projectile, so it looks the same and now:

- it is integrated by the motor and lands in `player.z`;
- it goes out on the wire (`z` joined the sync change-test);
- the shadow blob stays on the floor (it used to hang off `meshGroup` and rose with the jumper).

The vertical integrator uses `z += v·dt − ½g·dt²`, not plain Euler. Euler loses ½g·dt² *every
frame* — 1.25 units off a 30-unit jump at 60 Hz and a **different** number at 120 Hz. Deterministic
animation means the same jump whatever the display is doing, and the self-test pins it.

---

## Part B — Frames and signs (get these wrong and everything mirrors)

Unchanged from session 2, and still the source of every "the animation is mirrored" bug:

- **World space is Y-down.** Render space negates Y.
- Rotation is degrees, `0° = +X`, increasing clockwise.
- The rig's local frame is **+X forward, +Y the character's left, +Z up**, origin at the body
  pivot, which stands `CharacterRig.bodyPivotHeight` = 15.5 off the ground.
- Local `(0, 1)` lands on world `(sin θ, −cos θ)` — the negation of the world right vector.
- The rig's *names* run the other way: `leftHip` is at local `y = −6`, which by that mapping is on
  the character's right. Nothing downstream cares and `Gait.lateral` is defined against the
  **axis**, not either limb's name.
- `CharacterMotor.localToWorld` / `localOffsetInWorld` are the converters. Use them rather than
  writing the rotation out again.

`LocomotionSelfTest` pins every one of these. If you are about to reason about them from first
principles, read the tests instead.

---

## Part C — The rig

### Session 2's model (still current)

Nineteen parts, up from eleven: hand-authored lathed torso and pelvis (so there is a shoulder
line and a waist), a neck, deltoids, elbow/knee joint spheres at *exactly* the limb's radius, and
tapered limbs whose capsule cylinder is the **length of the bone** so each hemisphere is centred
on a joint. `RigPart.isJointFiller` marks the seven that only smooth a joint over; the shadow
pass skips them.

Three things that took the longest and are worth not re-learning:

1. **A capsule's cylinder must be the length of its bone**, or the limb pinches before the joint.
2. **A joint sphere must be exactly the limb's radius**, not wider — wider reads as a balloon
   animal, not an elbow.
3. **`applyTaper` narrowed a cap without shortening it**, which at the wrist meant the forearm
   wore the hand like a bracelet. `MeshFactory.limb(domeEnd:)` replaced it.

### Session 3's additions

**Hands with thumbs.** `CharacterRig.Hand` — a wrist, a palm, a finger block and a thumb, four
ellipsoids merged into **one** mesh (`MeshFactory.merge`), because the rig is drawn twice per
character. The left is the right mirrored through YZ, winding reversed
(`MeshFactory.mirroredInX`) or it renders inside-out.

This was impossible until the forearm had a **basis** rather than a direction.
`IKSolver.quaternionFromUnitY` pins where a limb points and leaves the roll about it undefined —
fine for a capsule, useless for anything with a front and a back, which is why the hand was a
revolved mitt for a whole session. `IKSolver.basis(alongY:rolledTowards:)` fixes the roll against
the arm's own bending normal, so the palm faces the way the elbow bends.

**A waist that twists.** `RigMutation.chestTwist`, radians about the body's up axis. The chest,
neck, head, shoulders and both arms take it; the pelvis, legs and feet do not. Arms are solved in
the chest frame (`intoChest`), while **hand targets stay in the body frame** — so a caller aiming
a hand at a point in space never has to know the chest has moved, which is what lets
`CharacterMotor` stay ignorant of tennis. The tennis coil used to be `bodyPivotRotation.z`, which
turns the feet with the shoulders: a chess piece twisted on its base.

### Envelope

The old torso was a capsule spanning z 7…33, half-width 10.35, half-depth 5.85. The torso and
pelvis profiles are built to sit inside that same envelope so a character still fits the doorways,
nameplates and clip mask. **Widen them and you will find the walls first.**

---

## Traps

**1. `xcrun simctl install` can silently install nothing.** There are three `JoelsWorld-*`
DerivedData directories on this machine, and `find … | head -1` does not reliably pick the one
`xcodebuild` just wrote. An hour of session 3 went into chasing a tennis "regression" that was
the simulator running an app built at 11:41. **Always verify the install:**

```bash
APP=/Users/ben/Library/Developer/Xcode/DerivedData/JoelsWorld-aexzipcdechfbeancoxhayadjudo/Build/Products/Debug-iphonesimulator/JoelsWorld.app
xcrun simctl install booted "$APP"
C=$(xcrun simctl get_app_container booted com.allr.joelsworld)
[ "$(md5 -q "$C/JoelsWorld")" = "$(md5 -q "$APP/JoelsWorld")" ] && echo VERIFIED || echo STALE
```

**2. `IKSolver.solve` clamps an out-of-reach target silently.** It moves the target in place and
says nothing, so a caller gets *something* back and no way to know it was refused. That is how the
tennis choreography came to be written 21.7 units from a shoulder on an arm 16.6 long: the swing
**drew** the arm at full stretch with the hand and the racket at the clamped position, while every
calculation in the game — where the toss goes, where the feet stand, where the strings are for the
contact test — used the position that had been asked for. *The strings you could see were never
the strings that hit the ball.* `Tennis3DGame+Players.reachable(_:from:)` clamps at the one place
the poses are written down, and `motor.strain(of:)` is how you find out.

**3. A limb chase has a time constant, and a moving target is trailed by `speed / approachGain`.**
The default `LimbProfile.arm.approachGain` of 14 trails a 230-units-per-second swing by 16 units
— 0.6 m, four times the sweet spot. Tennis sets it to 120 (≈7 cm). Any minigame whose limb has to
*meet* something moving needs a gain chosen the same way, not the default.

**4. `moveCharacterTo` / `driveCharacter` also set the facing intent** (nil = face the direction
of travel). Call `faceTowards` **after** them, not before. Tennis's `run(_:dt:)` gets this right.

---

## The files

| File | What it holds |
|---|---|
| `Engine/Core/CharacterMotor.swift` | **The movement manager.** Body, height, velocity, heading, gait and all four limbs. `moveCharacterTo`, `moveHandTo`, `jump`, `step`, `observe`, `poseOverride`, `localToWorld`. |
| `Engine/Core/LimbMotor.swift` | `Limb`, `LimbProfile` (speed, acceleration, approach gain, reach), `LimbState` (position, velocity, target, blend, strain). |
| `Engine/Core/Locomotion.swift` | `Gait`, `LocomotionProfile`, `LocomotionState`, `ObservedMotion`, `enum Locomotion`. Pure maths, no world knowledge. The motor is built on it. |
| `Engine/Core/Deterministic.swift` | `DeterministicRandom` — SplitMix64. |
| `Engine/Core/LocomotionSelfTest.swift` | The 67 assertions behind `-selftest`. |
| `Engine/Core/WalkTest.swift` | Every launch argument. |
| `Engine/Entity/CharacterRig.swift` | Anatomy (bones, joint radii, the lathed profiles, `Hand`), the neutral limb targets the motor starts from, and `pose(...)`. |
| `Engine/Entity/IKSolver.swift` | Two-bone IK, `segmentTransform`, and `basis(alongY:rolledTowards:)`. |
| `Engine/Entity/Emotes.swift` | `RigMutation`, including `chestTwist`. |
| `Engine/Render/MeshFactory.swift` | `revolved`, `limb`, and the new `merge` / `translated` / `mirroredInX`. |
| `Engine/Render/CharacterRenderer.swift` | One GPU mesh per part; `buildHand()` assembles the composite hand. |
| `Engine/World/Physics.swift` | `processInterpolation` (drives `visual.motor.observe`) and `CharacterVisual` (owns the motor). |
| `Engine/World/GameState.swift` | `playerMotor`, the input → motor block, the jump. |
| `Engine/World/Minigames/Tennis3D/**` | `Side.motor`; the swing drives `moveHandTo` and adds only `chestTwist` and the racket roll. |

## Looking at any of this

No test target — adding one means editing `project.pbxproj`, which is red. Launch arguments
instead, which is the pattern the rest of the tree uses.

```bash
# 67 assertions over Locomotion, Gait, CharacterMotor, limbs and DeterministicRandom. No world.
xcrun simctl launch booted com.allr.joelsworld -selftest

# The overworld camera is near-overhead. -pitch tips it over; 1.25 is a good side-on rig view.
xcrun simctl launch booted com.allr.joelsworld -autojoin Rig -map 0 -zoom 6 -pitch 1.25

# The 3D tennis game, played by a bot, with one line per event.
xcrun simctl launch booted com.allr.joelsworld -autojoin Rig -map 4 -tennis3ddemo -tennis3dtrace
```

`Log.world` goes to os_log at **info**, which the simulator does *not* persist — `log show` after
the fact returns nothing. It has to be streamed live:

```bash
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.allr.joelsworld"' --style compact
```

---

## Where it stands

### Done

- `Locomotion` / `Gait` / the lateral stride / the lean (session 1).
- Remote players and NPCs have a real gait; `legAnimationTime` is retired; NPC roaming is
  deterministic per id (session 2).
- The nineteen-part character model (session 2).
- **`CharacterMotor`**, and every character in the game moved onto it: the overworld player
  (`GameState.playerMotor`), remote players and NPCs (`CharacterVisual.motor`), and both tennis
  players (`Side.motor`).
- **No file outside `CharacterRig` writes a limb target or tracks a velocity any more.** The
  tennis swing drives `moveHandTo` and contributes only `chestTwist` and the racket roll.
- **The racket is where the hand is.** `racketHead` reads `motor.limbPosition(.rightHand)`, so
  the contact test and the drawing agree — see trap 2 for how far apart they used to be.
- **Jumping is real**, integrated exactly, frame-rate independent, on the wire, with the shadow
  left on the floor.
- **Hands with thumbs**, on a forearm with a defined roll.
- **A waist that twists** independently of the hips.
- `-selftest`: **67 assertions, all passing.** Both targets build.

### Open

1. **Tennis has not been A/B'd against `main`.** Session 3 ran the bot on the new build and saw
   serves connect, rallies of three and four shots, and points decided both ways — it plays. But
   the baseline comparison was never completed (the run was cut short), so *how often* a
   groundstroke is missed now versus before is unmeasured. Misses of 0.65–0.80 m against a 0.45 m
   sweet spot showed up in the new build's log; whether `main` shows the same is the open
   question. `grep -c STRIKE` / `grep -c MISS` over a 100-second `-tennis3ddemo` run on each is
   the measurement. **Do this before trusting the tennis tuning.**

2. **The hand has not been looked at up close in the tennis camera.** It reads correctly in the
   overworld at `-pitch 1.25` — wrist, palm, fingers, thumb, mirrored the right way. The thumbs
   splay outward rather than forward, which is not quite what a hanging arm does; the fix would
   be the roll reference in `CharacterRig.bendNormalArmL/R`, not the mesh.

3. **The racket's roll changed.** It rides on `rightHandAnchor`, whose rotation went from
   `quaternionFromUnitY` (arbitrary roll) to `basis` (roll fixed to the bend normal). It has not
   been inspected close up. If the strings look edge-on, this is why, and `holdingRotation` is
   the knob.

4. **The neck is still invisible on every head that has been looked at.** The head GLBs swallow
   it. Kept because `female_hair_ponytail` is placed at scale 32 where every other head is 85 or
   90, and because an emote that turns the head far enough could open a gap at the collar.
   Neither has been verified.

5. **The emote poses have had a spot check, not a full one.** Eight of twenty were watched on the
   session-2 mesh. None have been watched since `chestTwist` and the new hands landed. They move
   limb targets into positions the walk cycle never reaches, so they are the likeliest place for a
   joint to come apart. Note: the server remembers which map a name was last on, so always pass
   `-map 0` with `-emotedemo`.

6. **Nobody has profiled the part count on a real device.** The hand is still one draw (merged),
   so the count is unchanged from session 2's +8 scene draws per character. A playground with
   twenty characters on an old iPad is the case to check.

7. **The legacy 2D tennis game still eases per frame.** `TennisGame+Movement.swift`, reachable
   with `-tennis2d`, is a deliberate faithful port kept for comparison. Left alone on purpose.

8. **`Gait.walking(phase:)` has no callers.** Kept because it names the compatibility guarantee
   and the self-test uses it. Do not delete it without moving that assertion somewhere.

9. **`moveFootTo` has no callers.** The machinery is identical to a hand and it is there so a
   minigame can plant a foot; nothing does yet.

---

## Build

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The macOS editor target shares `GameState`, so build it too:

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorldAdmin -destination 'platform=macOS' build
```

Both were passing at the time of writing. New files are picked up automatically — the target uses
`PBXFileSystemSynchronizedRootGroup`, so **no `project.pbxproj` edit is needed** for a file
dropped into an existing source directory.
