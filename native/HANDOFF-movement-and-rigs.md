# Handoff — deterministic character movement and the skeleton rigs

Part 1 of 2. Part 2 is [HANDOFF-tennis3d.md](HANDOFF-tennis3d.md), which is the first consumer
of everything here. This half is **engine work that the whole game uses**, including the
overworld.

Zone note: this touches `Engine/Core`, `Engine/Entity`, `Engine/Render` and `Engine/World` —
red under [AGENTS.md](../AGENTS.md). Ben asked for it directly ("maybe need a new character
movement system that could be shared with the rest of the game i.e. the base map has inertia and
models sidestep etc", and then for the character models to be modelled properly, joints and
all), which is the say-so that rule wants. `server/**` and `JoelsWorld.xcodeproj/**` are
untouched.

**Two sessions so far.** Session 1 built `Locomotion` and the lateral stride. Session 2 pushed
the gait out to every character, made the NPCs deterministic, added a self-test, and rebuilt the
character mesh. Read "Where it stands" before picking anything up.

---

## Part A — Movement

### What changed and why

Before this, a character's whole animation state was **one number**: `legAnimationTime`, a walk
phase. That number can only describe a forward walk, which is why every character in Joel's
World used to turn on the spot and then walk in a straight line. And movement itself had no
memory — each frame the player was teleported `speed × dt` along their heading, so releasing the
joystick stopped them dead and a direction change was instant.

Two pieces fix both:

- **`Locomotion`** — velocity that carries between frames, bounded acceleration and braking, and
  a bounded turn rate. Position, heading and gait all come out of one step function.
- **`Gait`** — velocity resolved into the character's *own* axes, so "moving left while facing
  forward" is expressible. The rig reads it and side-steps.

### How it fits together

```
                        ┌─ the local player ─────────────────────────────┐
input ──▶ desired velocity ──▶ Locomotion.step ──▶ demanded delta        │
                                     │                   │               │
                                     │              PhysicsEngine.processMovement (walls)
                                     │                   │               │
                                     ▼             accepted delta        │
                                   Gait  ◀──── Locomotion.commit ────────┘
                                     │
                        ┌─ everyone else ────────────────────────────────┐
server / NPCBehaviour ──▶ interpolation target                           │
                                     │                                   │
                        PhysicsEngine.processInterpolation               │
                                     │                                   │
                          displacement this frame                        │
                                     │                                   │
                                     ▼                                   │
                            Locomotion.observe ──▶ Gait ◀────────────────┘
                                     │
                                     ▼
                            CharacterRig.pose ──▶ RigPose ──▶ Renderer
```

Two ways in, one `Gait` out. The player's comes from a controller and a wall test;
everyone else's is **read back out of the positions they were moved through**, because nothing
in the interpolation path ever forms a velocity. That is `Locomotion.observe`, and it is what
makes a patrolling NPC side-step across a corridor its waypoint rotation faces down.

`Locomotion.commit` is the important half of the player's path and easy to miss: it writes back
**what the world actually allowed**, so a player pushed into a wall sheds their velocity into it
instead of storing it up and firing sideways the moment they turn away.

### Frames and signs (get these wrong and everything mirrors)

- **World space is Y-down.** Render space negates Y.
- Rotation is degrees, `0° = +X`, increasing clockwise.
- The rig's local frame is **+X forward, +Y the character's left, +Z up**. The mesh group applies
  `rotationZ(-rotation)` and render space negates Y, so local `(0, 1)` lands on world
  `(sin θ, −cos θ)` — the negation of the world right vector.
- The rig's *names* run the other way: `leftHip` is at local `y = −6`, which by that mapping is
  on the character's right. Nothing downstream cares (the body is symmetric) and
  `Gait.lateral` is defined against the **axis**, not against either limb's name.

`LocomotionSelfTest` pins every one of these signs. If you are about to reason about them from
first principles, read the tests instead — `strafing world +Y reads as lateral −1` is the one
that settles most arguments.

### The lateral stride

In `CharacterRig.pose`, the walk cycle reads:

```swift
leftFoot.x += legSwing * legStrideX * forward
leftFoot.y += legSwing * legStrideY * lateral
...
leftFoot.y  += lateral * 2.5          // both feet lead the shuffle
rightFoot.y += lateral * 2.5
```

`legStrideY` is 5.5, comfortably inside the hips' 12-unit separation, so the legs never cross.
**Running dead ahead reproduces the old animation exactly** — `forward` is 1 and `lateral` is 0,
so every added term falls away. That is the compatibility guarantee worth preserving if you
touch this, and `LocomotionSelfTest` asserts it.

### The lean

`gait.leanForward` / `leanLateral` are smoothed accelerations. In `pose`:

- `bodyPivotRotation.y += leanForward × 0.22` — positive tips "up" toward +X, i.e. forward.
- `bodyPivotRotation.x = −leanLateral × 0.22` — banks into a change of direction.

An emote sets `bodyPivotRotation.y = 0` before posing, so a lean does not survive into a wave.
That is deliberate.

### `RigOverride`

```swift
typealias RigOverride = (inout RigMutation) -> Void
```

Applied after the walk cycle *and* after any emote, so it composes rather than fights. It exists
because a minigame needs to aim a limb at a moving object and the pose tables cannot describe
that. See the tennis swing in `Tennis3DGame+Players.swift` for the worked example.

---

## Part B — The character model

### The problem

The head GLBs are modelled down to individual strands of hair. The body under them was eleven
primitives: one capsule squashed in two axes for the torso, six capsules for the limbs, and a
sphere for each hand. No neck, no shoulders, no waist, no hips, no hands. That mismatch, not the
lighting or the textures, was what gave the characters away.

### What it is now

Nineteen parts. The additions are all **joints** — the places where two capsules met at an angle
and, before this, simply crossed through one another.

| Part | What it is |
|---|---|
| `torso` | A hand-authored lathed silhouette (`CharacterRig.torsoProfile`): hem, waist, chest, shoulder yoke, trapezius slope into the neck. In shirt colour. |
| `pelvis` | Its own lathe, in trouser colour. Splitting it off the torso is what gives a character a waistline instead of one shirt-coloured tube from neck to knee. |
| `neck` | A short taper from the shoulders up into the head model, hinged at its base and taking 45% of the head's rotation. |
| `leftShoulder` / `rightShoulder` | Deltoids: spheres stretched along the humerus and turned to follow it. |
| `leftElbow` / `rightElbow` / `leftKnee` / `rightKnee` | Spheres at **exactly** the limb's radius there. |
| `leftHand` / `rightHand` | Mitts revolved about the forearm (`CharacterRig.handProfile`). |
| the eight limb segments | Tapered, with matching radii at every shared joint. |

### The three things that took the longest to get right

Every one of these produced a visibly wrong character before it produced a correct one. They are
worth knowing before touching any number in `CharacterRig`'s anatomy block.

**1. A capsule's cylinder must be the length of its bone.** A capsule is a cylinder of `length`
with a hemisphere of `radius` on each end. Make the cylinder the length of the bone and each
hemisphere is centred precisely on a joint, so the limb's cross-section at the joint is a full
`radius`. Make it shorter and the cap is centred short of the joint, the limb pinches in before
it gets there, and anything you put at the joint sits proud of it. `armBone`, `thighBone` and
`shinBone` are now the single source for both `IKSolver.solve` and `MeshFactory.limb`.

**2. A joint sphere must be exactly the limb's radius, not wider.** The first attempt made them
deliberately wider, on the theory that a bulge reads as a joint. It does not: it reads as a
balloon animal, three separate blobs stacked up an arm. Matched to the limb they are invisible on
a straight limb — which is the point — and on a bent one they fill the notch the two capsule caps
would otherwise leave on the inside of the bend.

**3. `applyTaper` narrowed a cap without shortening it.** That is fine at a shoulder, elbow, hip
or knee, where the overshoot buries itself in the neighbouring segment and the surfaces blend.
At the **wrist** — the one end of one limb that nothing else covers — it meant the forearm
reached a full 3.3 units past the hand and wore it like a bracelet, with an orange thumb poking
out the end. `MeshFactory.limb` replaces `applyTaper` and takes a `domeEnd:` flag: `true`
overshoots the joint, `false` closes flush on it. The forearm is the only limb built with
`false`.

### Also fixed: the calf was on upside down

`applyTaper(topScale: 1.0, bottomScale: 0.6)` on the calf tapered it to 60% at the **knee** and
left it full width at the **ankle**. `+Y` runs from a limb's start joint to its end joint, and
for a calf that is knee → ankle, so `bottomScale` was the knee. This is the one place the rig
deliberately departs from `characters.js`.

### Cost

Each character is drawn twice — once into the shadow map, once into the scene. Nineteen parts
would have made that 38 body draws where it used to be 22. `RigPart.isJointFiller` marks the
seven parts that only smooth a joint over; they sit inside the silhouette the limbs and body
already cast, so `CharacterRenderer.draw` skips them in the shadow pass. The shadow map is
identical either way. Net cost is **+8 scene draws and +1 shadow draw** per character.

### Envelope

The old torso was a capsule spanning z 7…33 with a half-width of 10.35 and a half-depth of 5.85.
The new torso and pelvis profiles are built to sit inside that same envelope, so a character
still fits the doorways, nameplates and clip mask it always did. **Widen them and you will find
the walls first.**

---

## The files

| File | What it holds |
|---|---|
| `Engine/Core/Locomotion.swift` | `Gait`, `LocomotionProfile`, `LocomotionState`, `ObservedMotion`, `enum Locomotion`. Pure maths, no world knowledge — `step` produces a *demanded* delta and the caller decides what the world does with it; `observe` reads a gait back out of movement that already happened. |
| `Engine/Core/Deterministic.swift` | `DeterministicRandom` — SplitMix64. Replaces `Double.random` wherever a result should be reproducible. |
| `Engine/Core/LocomotionSelfTest.swift` | The 39 assertions behind `-selftest`. |
| `Engine/Core/WalkTest.swift` | Reads every launch argument. `-pitch` and `-selftest` are the new ones. |
| `Engine/Entity/CharacterRig.swift` | The anatomy block (bone lengths, joint radii, the three lathed profiles) and `pose(...)`, which emits every part transform. |
| `Engine/Render/MeshFactory.swift` | `revolved(profile:)` for the body silhouettes and `limb(...)` for the limb segments, alongside the three.js primitive ports. |
| `Engine/Render/CharacterRenderer.swift` | Builds one GPU mesh per part and maps each part to a colour and a material. Skips `isJointFiller` parts in the shadow pass. |
| `Engine/World/Physics.swift` | `processInterpolation` (now emits a gait) and `CharacterVisual` (now carries `motion` and `roamNoise`). |
| `Engine/World/NPCBehaviour.swift` | Roam and patrol, on the per-NPC deterministic stream. |
| `Engine/World/GameState.swift` | The player's movement block, on `Locomotion`. |
| `Engine/World/GameState+Rendering.swift` | `drawableCharacters` — character + gait + pose override, for everyone. |

## Looking at any of this

There is no test target — adding one means editing `project.pbxproj`, which is red. Everything
below is a launch argument instead, which is the pattern the rest of the tree already uses.
`WalkTest` reads them; `GameDebugHarness` acts on them.

```bash
# 39 assertions over Locomotion, Gait and DeterministicRandom. Needs no world.
xcrun simctl launch booted com.allr.joelsworld -selftest

# The overworld camera is near-overhead: from above you can see a hat and a pair of shoes and
# nothing about whether the body has a neck. -pitch tips it over. 0 is straight down, π/2.1 is
# the flattest it goes, 1.25 is a good side-on view of the rig.
xcrun simctl launch booted com.allr.joelsworld -autojoin Rig -map 0 -zoom 6 -pitch 1.25

# Sweeps the joystick through a full circle, logging position and heading twice a second.
xcrun simctl launch booted com.allr.joelsworld -autojoin Rig -map 0 -walktest -npctrace
```

`Log.world` goes to os_log at **info** level, and `print` to stdout is block-buffered, so
`--console` shows nothing useful. Read it with:

```bash
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.allr.joelsworld"' --style compact
```

The tennis court (`-map 4`) is the best place to judge the model: the camera sits at pitch 0.52,
which is a three-quarter view, and both players bend their arms hard through a swing.

---

## Where it stands

### Done

- `Locomotion` / `Gait` / the lateral stride / the lean (session 1).
- **Remote players and NPCs have a real gait.** `Locomotion.observe` differentiates the positions
  the interpolator walks them through. `CharacterVisual.motion` replaces `legAnimationTime`.
- **`legAnimationTime` is retired** from both `Player` and `CharacterVisual`.
- **NPC roaming is deterministic.** Each NPC has its own `DeterministicRandom` seeded from its id
  (`CharacterVisual.roamNoise`), so it wanders the same way on every client and in every run.
  Verified end to end: two runs pick the same roam destinations in the same order.
- **`updateCamera` takes `dt`.** The tennis camera's follow was easing a fixed fraction per
  frame, so it ran at half speed on a 120 Hz display. (`Tennis3DView.fade` was already correct.)
- **`-selftest`**, 39 assertions, all passing.
- **The overworld play-test session 1 asked for.** A full-circle heading sweep holds 107.3 px per
  half-second — 214.6 units a second, which is `playerRunning.maxSpeed` of 216 — constant to
  0.1 px across the whole sweep. The run-profile switch at 2.5 s does not jolt.
- **The character model**, as above.

### Open

1. **The neck is currently invisible on every head that has been looked at.** The head GLBs
   reach far enough down to swallow it. It is kept for two reasons, neither yet verified:
   `female_hair_ponytail` is placed at scale 32 where every other head is 85 or 90 (which may
   just mean the model was exported in different units, or may mean it sits differently), and an
   emote that turns the head far enough could open a gap at the collar. Render the ponytail head
   and run `-emotedemo` past `no` and `yes` before deciding whether the neck earns its draw call.

2. **The hand has no roll.** `IKSolver.quaternionFromUnitY` pins the direction a limb points and
   nothing else, so anything with a front and a back would spin freely about the wrist. That is
   why the hand is a revolved mitt. Giving it a thumb means building a full basis for the
   forearm — the bend normal is already there and would serve — but the racket rides on
   `rightHandAnchor` and uses the same rotation, so it would move too. Check the tennis swing
   before and after if you try it.

3. **The legacy 2D tennis game still eases per frame.** `TennisGame+Movement.swift` is reachable
   with `-tennis2d` and is a deliberate faithful port of the JS, kept for comparison. Left alone
   on purpose. Do not "fix" it without deciding the old game is no longer a reference.

4. **`Gait.walking(phase:)` has no callers.** Kept because it names the compatibility guarantee
   and the self-test uses it. Do not delete it without moving that assertion somewhere.

5. **Nobody has profiled the new part count on a real device.** Everything above was run in the
   simulator. The arithmetic says +8 scene draws per character and the frame looked smooth, but
   a playground with twenty characters on an old iPad is the case to check.

6. **The emote poses have had a spot check, not a full one.** `-emotedemo 5` was watched through
   `bounce`, `cry`, `dance`, `dead`, `eat`, `fart`, `gritty` and `wave` on the new mesh and none
   of them broke a joint. The other twelve have not been looked at. They move limb targets into
   positions the walk cycle never reaches, so they are the most likely place for a joint to come
   apart.

   Note when you run it: the server remembers which map a player name was last on, so
   `-autojoin <name>` without `-map 0` can drop you straight into the tennis court, where a
   minigame owns the screen and no emote will ever be posed. Always pass `-map 0` for this.

---

## Build

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The macOS editor target shares `GameState`, so build it too:

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorldAdmin -destination 'platform=macOS' build
```

Both were passing at the time of writing. New files are picked up automatically — the target
uses `PBXFileSystemSynchronizedRootGroup`, so **no `project.pbxproj` edit is needed** for a file
dropped into an existing source directory.
