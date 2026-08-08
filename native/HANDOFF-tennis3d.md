# Handoff — the 3D tennis minigame

Part 2 of 2. Part 1 is [HANDOFF-movement-and-rigs.md](HANDOFF-movement-and-rigs.md), the shared
movement and rig work this is built on. Read that first — the frames, signs and `Gait` semantics
are defined there and everything below assumes them.

**Status: playable.** It builds, runs, serves, rallies, scores, and awards the badge. It is not
balanced and there is a cosmetic rendering bug. Details at the bottom.

---

## The ask

> Rewrite the tennis minigame from the ground up. It currently uses an alternate 2D rendering
> system; the new version should use the real 3D engine with the existing 3D character rigs.
> Players should be able to drag their character around to move it, or click to move. Characters
> should have inertia, side-step, and make realistic deterministic movements. New collision
> detection, scoring, all from the ground up. Keep the general aesthetic. Keep the original game
> in place for now, but supersede it.

Later: *"Show the ideal intercept point like the original game."* Done — the green X.

---

## How it is reached

`data/maps.json` map 4's `import` changed from `/src/minigames/tennis.js` to
`/src/minigames/tennis3d.js`. **The server never reads `import`** (verified in
`server/managers/MapManager.js`), so this is a client-only data change — no new map id, no server
redeploy. A new map id *would* have needed one.

The old game is still in the tree and still compiles. Reach it with the launch argument
`-tennis2d`, which `GameState.startMinigame` honours in DEBUG builds.

```bash
xcrun simctl launch <device> com.allr.joelsworld -autojoin Joel -map 4
xcrun simctl launch <device> com.allr.joelsworld -autojoin Joel -map 4 -tennis2d   # the old one
```

---

## Architecture

A minigame used to have exactly one option: draw itself on a 2D canvas over a blank Metal view.
`WorldRenderedMinigame` is the second option — a minigame drawn by the **real renderer**, which
gets the lighting, shadows, SSAO and character rigs for free. It hands over three things a
frame:

```swift
protocol WorldRenderedMinigame: Minigame {
    var sceneCharacters: [MinigameCharacter] { get }   // posed by CharacterRig
    var scenePrimitives: [ScenePrimitive] { get }      // court, net, ball
    func updateCamera(_ camera: inout Camera, viewport: SIMD2<Float>)
    var backgroundColor: String? { get }
}
```

### Files

| File | What |
|---|---|
| `Engine/World/Minigames/Minigame.swift` | *(modified)* `WorldRenderedMinigame`, `MinigameCharacter`, `ScenePrimitive`, `MinigameKind.tennis3d`. |
| `Engine/Render/ScenePrimitiveRenderer.swift` | *(new)* Turns primitives into draw calls, caching one GPU mesh per distinct `Shape`. |
| `Engine/Render/Renderer.swift` | *(modified)* Draws primitives in the shadow pass, the opaque pass and a blended pass. |
| `Engine/World/GameState.swift` | *(modified)* Starts tennis3d; forwards the camera to a world-rendered minigame inside the early-return branch. |
| `Tennis3D/Tennis3DCourt.swift` | Dimensions, bounds tests, court geometry. |
| `Tennis3D/Tennis3DGame.swift` | State, `Tuning`, the frame, the camera, input. |
| `Tennis3D/Tennis3DGame+Ball.swift` | `Ball`, the integrator, bounce, net, serve, the shot solver, the markers. |
| `Tennis3D/Tennis3DGame+Players.swift` | Body geometry, swing choreography, contact, the NPC. |
| `Tennis3D/Tennis3DGame+Rules.swift` | `MatchScore`, every point outcome, the scoreboard. |
| `JoelsWorld/UI/Minigames/Tennis3DView.swift` | Scoreboard, banner, match panel, drag/tap. |

### Real units

The court is a **real tennis court**: 23.77 m × 10.97 m, a 0.914 m net, 9.81 m/s² gravity. The
conversion is `unitsPerMetre = 27`, pinned to the rig (a rig is ~50 units tall ≈ 1.85 m). The 2D
game shrank its court to 120 units and divided every velocity by a `gameScale` constant to
compensate; none of that is needed once the court is the right size.

### The ball

Fixed 240 Hz sub-step, with gravity, quadratic drag (derived from a real ball's
`½·ρ·Cd·A ÷ m`) and a vertical Magnus term for topspin. The net is tested as a **crossing of the
y = 0 plane**, not a proximity check, so a 500 unit/s ball cannot tunnel through it.

The physics being honest is what makes the shot solver honest: `launchBall(to:speed:topspin:)`
does not compute a parabola, it **simulates candidate launches and adjusts**. Two knobs — launch
angle for net clearance, pace for range — alternated four times. A ball hit too flat clips the
net and a ball hit too hard sails long, and neither had to be special-cased.

### Contact detection

The old game read the racket hitbox back out of the renderer's canvas transform, one frame late.
This one simulates the racket: the head is a fixed distance along the line from the shoulder
through the hand, the hand follows a four-pose arc through the swing, and contact is the
**closest approach between the head's swept segment and the ball's**, solved per sub-step. A
point-in-sphere test at 4 ms would miss most contacts outright.

### Swing triggering

Every frame, a player who is allowed to hit asks "when will the ball be inside my reach?"
(`timeUntilInReach`, which runs the ball forward through the same integrator) and starts the
backswing exactly early enough to arrive. **Being in the wrong place is the only way to miss**,
which is right, because position is the only thing the player controls.

The serve is the exception: the server is standing still and chose where the ball goes, so
`tossBall()` solves the toss **backwards from the contact point** and `serveStrikeTime` says when
to swing. (This was broken in the first pass — the toss went up from the off hand and the racket
swung 17 units away from it, so every serve was a double fault. Fixed.)

### Determinism

No `Double.random` anywhere. `DeterministicRandom` is re-seeded from the scoreline at the start
of every point, so a given point in a given game always plays out the same way — which is what
makes a rally bug reproducible.

### Controls

Drag or tap, both landing in `steer(toWorldX:y:)`, which sets a point on the court to head for.
`Locomotion` does the rest, which is why a drag feels like dragging rather than teleporting — the
character is *accelerating towards* the finger, not being placed under it. Screen-to-court is a
ray cast via `Camera.unprojectToGroundPlane`.

Both players are told to keep facing the net, so nearly everything they do comes out of `Gait`
as a side-step. They only turn and run when the ball has put them more than 3 m out of position
*and* there is time to get back (`run(_:dt:profile:)` in `+Players`).

### Rules

Every bounce arrives at `onBounce()` and becomes exactly one of: nothing, a fault, a let, or a
point. Nothing else in the game decides a point. Standard scoring including deuce and advantage;
a match is `Tuning.gamesToWinMatch` games (currently **2**, kept short for a ten-year-old);
winning awards the `tennis` badge.

---

## Known bugs and open work

Ordered by how much they matter.

1. **Balance: the opponent is too weak.** In every run so far the player wins most points on
   serve. Alex either does not reach the ball or does not return it. Start with
   `Tuning.npcReaction` (0.20 s), `Tuning.npcPositionError` (0.9 m), `Tuning.npcTopSpeed`, and
   the stand-off offsets in `steerOpponent`. Worth adding a difficulty constant while you are in
   there — Joel will want to turn it up.

2. **Stray green and white specks near the right-hand edge of the court**, visible in some
   frames a few metres outside the doubles sideline. Unexplained. Suspects, in order:
   `interceptMarker()` (two rotated boxes — check `idealIntercept` cannot return a point off
   court), the net horizontal segments, or z-fighting between the three stacked ground planes at
   z = 0 / 0.4 / 0.8. Reproduce by watching mid-rally rather than at the serve.

3. **The match-over panel has never been seen.** No run has reached two games. Check the panel
   lays out, that "Play again" (`restartMatch()`) actually restarts cleanly, and that the badge
   fires once and not twice.

4. **`resolveDeadBall()` only fires in `.rally`.** A toss that somehow flew off court during
   `.toss` would leave the game hanging with no timer. Add a phase timeout as a backstop.

5. **`Tennis3DView.step()`'s banner fade is frame-rate dependent** (`alpha += (wanted - alpha) *
   0.2` per frame, no `dt`). Cosmetic, one line.

6. **No trace logging.** The existing `-tennistrace` debug flag only understands the old
   `TennisGame`. A `-tennis3dtrace` printing phase, ball state, both players' positions and the
   score once a second would have saved most of the debugging above — worth adding before the
   next session.

7. **The hint text retires on `game.phase == .rally`** by fading 0.01 per frame. Frame-rate
   dependent again, and it never comes back if the player forgets.

8. **Untested: wide-ball chases.** The turn-and-run branch (`distance > 3 m && !ballIsClose`)
   has not been observed. It may look wrong — a player turning their back mid-rally — in which
   case delete the branch and always face the net.

---

## Verifying it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Then install onto a booted simulator and launch straight onto the court:

```bash
xcrun simctl launch --console-pty <device-udid> com.allr.joelsworld -autojoin Joel -map 4
```

The Claude Code simulator panel would not attach during this session; `xcrun simctl io <device>
screenshot <path>` works fine as a substitute and is how every screenshot here was taken.

After any `data/` edit:

```bash
for f in data/maps.json data/*/*.json; do python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" || echo "BROKEN: $f"; done
```
