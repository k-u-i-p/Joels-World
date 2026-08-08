# Handoff — deterministic character movement and the skeleton rigs

Part 1 of 2. Part 2 is [HANDOFF-tennis3d.md](HANDOFF-tennis3d.md), which is the first consumer
of everything here. This half is **engine work that the whole game uses**, including the
overworld.

Zone note: this touches `Engine/Core`, `Engine/Entity`, `Engine/Render` and `Engine/World` —
red under [AGENTS.md](../AGENTS.md). Ben asked for it directly ("maybe need a new character
movement system that could be shared with the rest of the game i.e. the base map has inertia and
models sidestep etc"), which is the say-so that rule wants. `server/**` and
`JoelsWorld.xcodeproj/**` are untouched.

---

## What changed and why

Before this, a character's whole animation state was **one number**: `legAnimationTime`, a walk
phase. That number can only describe a forward walk, which is why every character in Joel's
World turns on the spot and then walks in a straight line. And movement itself had no memory —
each frame the player was teleported `speed × dt` along their heading, so releasing the joystick
stopped them dead and a direction change was instant.

Two new pieces fix both:

- **`Locomotion`** — velocity that carries between frames, bounded acceleration and braking, and
  a bounded turn rate. Position, heading and gait all come out of one step function.
- **`Gait`** — velocity resolved into the character's *own* axes, so "moving left while facing
  forward" is expressible. The rig reads it and side-steps.

---

## New files

| File | What it holds |
|---|---|
| `Engine/Core/Locomotion.swift` | `Gait`, `LocomotionProfile`, `LocomotionState`, `enum Locomotion`. Pure maths, no world knowledge — it produces a *demanded* delta and the caller decides what the world does with it. |
| `Engine/Core/Deterministic.swift` | `DeterministicRandom` — SplitMix64. Replaces `Double.random` wherever a result should be reproducible. |

## Modified files

| File | Change |
|---|---|
| `Engine/Entity/CharacterRig.swift` | `pose(...)` takes `gait: Gait` instead of `legAnimationTime: Double`, plus an optional `override: RigOverride`. The walk cycle gained a lateral stride and an acceleration lean. `RigOverride` typealias added. |
| `Engine/Entity/Emotes.swift` | `RigMutation.holdingRotation` — an extra rotation for the held model, in the hand's frame. |
| `Engine/World/Player.swift` | `velocityX`, `velocityY`, `gait`. |
| `Engine/World/GameState.swift` | The player's movement block rewritten onto `Locomotion`. |
| `Engine/World/GameState+Rendering.swift` | `drawableCharacters` returns `[DrawableCharacter]` (character + gait + pose override) instead of a tuple pair. |
| `Engine/Render/Renderer.swift` | `preparePoses` passes the gait and the override through. |

---

## How it fits together

```
input ──▶ desired velocity ──▶ Locomotion.step ──▶ demanded delta
                                     │                   │
                                     │              PhysicsEngine.processMovement (walls)
                                     │                   │
                                     ▼             accepted delta
                                   Gait  ◀──── Locomotion.commit
                                     │
                                     ▼
                            CharacterRig.pose ──▶ RigPose ──▶ Renderer
```

`Locomotion.commit` is the important half and easy to miss: it writes back **what the world
actually allowed**, so a player pushed into a wall sheds their velocity into it instead of
storing it up and firing sideways the moment they turn away.

### Frames and signs (get these wrong and everything mirrors)

- **World space is Y-down.** Render space negates Y.
- Rotation is degrees, `0° = +X`, increasing clockwise.
- The rig's local frame is **+X forward, +Y the character's left, +Z up**. The mesh group applies
  `rotationZ(-rotation)` and render space negates Y, so local `(0, 1)` lands on world
  `(sin θ, −cos θ)` — the negation of the world right vector.
- The rig's *names* run the other way: `leftHip` is at local `y = −6`, which by that mapping is
  on the character's right. Nothing downstream cares (the body is symmetric) and
  `Gait.lateral` is defined against the **axis**, not against either limb's name.

### The lateral stride

In `CharacterRig.pose`, the walk cycle now reads:

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
touch this.

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

## Known issues and open work

1. **The overworld has not been play-tested.** Every screenshot in this work was taken on the
   tennis map. The school map compiles and the code path is exercised, but nobody has walked
   around it with the new inertia. **Do this first.** Things to look at:
   - `LocomotionProfile.player` is `maxSpeed: 180`, derived from `player.moveSpeed × 60` (the old
     per-frame 3 units at 60 fps). Sanity-check that against how it used to feel.
   - `acceleration: 900`, `braking: 1400`, `turnRate: 540°/s` are first guesses. The turn rate
     is what decides how long the side-step window lasts — lower is more visible, and more
     sluggish.
   - The run-after-2.5 s threshold is preserved but now switches profile mid-run; check it does
     not jolt.

2. **Remote players and NPCs never side-step.** `drawableCharacters` gives them
   `Gait.walking(phase:)`, which is the old forward-only behaviour. They are interpolated
   towards server or waypoint targets rather than driven by a controller, so there is no
   velocity to resolve. Fixing it properly means having `PhysicsEngine.processInterpolation` and
   `NPCBehaviour` emit a velocity and building the gait from that. Worth doing — it is the
   difference between the player looking special and the whole school looking alive.

3. **`player.legAnimationTime` is now just `gait.phase`.** It is kept in sync only so anything
   still reading the old field does not break. Grep and retire it when convenient.

4. **The lean is frame-rate smoothed with `min(1, dt * 8)`**, which is correct, but the banner
   fade in `Tennis3DView.step()` is *not* — that one eases by a fixed fraction per frame. Same
   class of bug, different file; noted here so it is not lost.

5. **No unit tests.** `Locomotion.step` is a pure function with no dependencies and would be
   trivial to test (does a released stick decelerate? does a 180° reversal produce a lateral
   gait?). There is no test target in the project today.

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
