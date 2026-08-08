# Handoff — finishing the 3D tennis minigame

Continues [HANDOFF-tennis3d.md](HANDOFF-tennis3d.md), which is the architecture and the original
bug list. Read that first; this file is what happened next and what is left.

**Status: it is a game now.** Two full matches play out back to back with no crash, rallies run
to five shots, both players hold and break serve, the match-over panel appears, "Play again"
restarts cleanly and the badge is awarded once per match won.

The headline is that the original bug list was mostly not the real problem. Under it were three
defects that made the game unplayable and unwinnable, and none of them were visible without a
trace:

1. **The app was killed mid-match, every time.** The ball's shadow shrank smoothly with height,
   and `ScenePrimitiveRenderer` caches one GPU mesh per distinct `Shape` for ever — so it minted
   a fresh pair of Metal buffers sixty times a second and never freed one. iOS killed the app on
   memory somewhere between forty seconds and three minutes in, with no crash report. Fixed by
   quantising the shadow to the centimetre, plus a cache ceiling in the renderer that logs a
   warning rather than eating the device next time.
2. **Nobody could ever return a serve** — every game on both sides was a love game. Four separate
   causes, below.
3. **The opponent double-faulted every service game**, because she chased her own ball toss.

Note on shared files: another agent was working on `Locomotion`, `CharacterRig` and the overworld
at the same time. Nothing here touches those. Their commit `07fc5d6` swept up part of this work
in passing, which is harmless but explains why some of it is in a commit about gaits.

---

## Why a serve could not be returned

Worth reading even if you never touch this code again, because each one looked fine on its own
and only the combination was fatal.

- **`canHit` refused a swing until the serve had bounced.** A swing takes 0.285 s to bring the
  racket to the ball; a serve bounces about 0.4 s before it reaches the receiver. So the receiver
  could not *begin* to move the racket until it was nearly too late. Split into `canHit` (may the
  strings legally touch it *now*) and `isTheirBall` (is this mine to deal with at all). Preparing
  asks the second; `timeUntilInReach` only ever returns a moment after the bounce, so the strings
  still arrive legally.
- **Both players were sent to stand where the ball would be.** The racket head is 1.4 m forward
  and to the racket side of the body, so a player standing *on* the ball watches it go past
  inside their reach. `stance(toMeet:for:)` now converts a meeting point into where the feet go,
  derived from the swing choreography itself. The closest the strings had ever got was 1.00 m
  against a 0.33 m sweet spot — near enough to look like bad luck, and never once a hit.
- **The stance was measured from the wrong pose.** The swing is *timed* so the middle of the
  forward stroke lands on the ball, and `strike` scores quality against that midpoint — but the
  stance was computed from the swing's end pose, which is most of a metre further on. That left a
  beautifully consistent half-metre near miss on every single shot. `strikeHandLocal` is now the
  midpoint, and `groundstrokePoses` is the single definition both the animation and the geometry
  read.
- **The intercept picked the earliest playable moment, not a useful one.** It now scores every
  playable moment by how far the player must move and picks the cheapest reachable one — "let the
  ball come to you" — with a penalty for a ball at the wrong height for the racket. Cost is
  measured from a fixed **anchor** (where they stood when the shot was struck), because measuring
  from the live position is a feedback loop: step towards the ball and an earlier part of its
  path becomes cheaper, which pulls you a step further forward. Both players used to walk
  themselves to the service line during a serve and let it fly over their shoulder.

Two tuning changes came out of the same work: `bounceFriction` 0.76 → **0.64** (a serve's *second*
bounce was four and a half metres past the baseline) and `firstServeSpeed` 21 → **16.5** m/s.

---

## The original list

| # | Item | Outcome |
|---|---|---|
| 1 | Opponent too weak | **Done, and it was the opposite.** She could not serve (chasing her own toss) and could not return (above). `Tuning.difficulty` is the one knob, default 0.6. |
| 2 | Stray specks off the sideline | **Found and fixed.** Two causes: z-fighting between three ground planes 1.5 cm apart across a 290 m grass plane, and the ball freezing in mid-air at the end of a point with its shadow left on the lawn beneath it. |
| 3 | Match-over panel never seen | **Seen, and it lays out correctly.** Restart is clean; the badge fires once per match won. The banner no longer sits behind the panel. |
| 4 | `resolveDeadBall` only fires in `.rally` | **Done.** `Tuning.ballEventTimeout` (8 s since anything happened to the ball) abandons and replays the point rather than hanging. |
| 5 | Banner fade frame-rate dependent | **Done.** `Tennis3DView.step()` measures its own `dt` and eases in seconds. |
| 6 | No trace logging | **Done, and it found everything.** See below. |
| 7 | Hint fade frame-rate dependent, never returns | **Done.** Driven by `game.secondsSinceSteer`: up until the first touch, back after twelve seconds idle. |
| 8 | Wide-ball chases untested | **Observed.** The turn-and-run branch fires, rarely, and only on long walks between points — about 8 samples in 110. It looks right; kept. |

Also fixed along the way, neither of which was on the list:

- The **first point of a match was played from the wrong positions** — `.walkOn` fell straight
  through to `.toMarks` without ever calling `moveToServeMarks()`.
- A server could **drift off their mark during the toss**, which mis-solves the toss and blows the
  serve. Servers are now pinned from `.ready` until they have struck, and `atRest` requires them
  to be actually stopped, not merely near the mark.

---

## Debug flags

`simctl` cannot inject touches, so anything a finger would do is driven from `GameDebugHarness`.

| Flag | What |
|---|---|
| `-tennis3dtrace` | One line a second for the point and the two players, **plus an event line for every strike, bounce, miss, fault and point.** The events are the useful half — a point is over in three seconds, so a once-a-second sample only ever says "the score went up and I do not know why". |
| `-tennis3ddemo` | Plays the human's side by steering at `idealStance()`, through the same `steer(toWorldX:y:)` a finger lands in. Restarts once after the match ends, to exercise the panel. |
| `-tennisdifficulty <0…1>` | Overrides `Tuning.difficulty` for a balancing run. |

```bash
xcrun simctl launch --console-pty <udid> com.allr.joelsworld \
  -autojoin Joel -map 4 -tennis3ddemo -tennis3dtrace
```

Useful one-liners against the log:

```bash
grep -E "STRIKE|POINT to" run.log | awk '/POINT/{print n; n=0; next}{n++}' | sort -n | uniq -c
```

```bash
grep -o "POINT to [A-Za-z]*" run.log | sort | uniq -c
```

**Watch out for two DerivedData folders.** There are two `JoelsWorld-*` build directories and the
stale one still has a `maps.json` pointing at the superseded 2D game, so installing whichever
`find` happens to return first silently runs the wrong game. Pick by modification time:

```bash
ls -dt ~/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug-iphonesimulator/JoelsWorld.app | head -1
```

The Claude Code simulator panel would not attach in this session either; `xcrun simctl io <udid>
screenshot <path>` works and is how every image was checked.

---

## Where the balance sits

Measured against the `-tennis3ddemo` bot, which reads the ball perfectly and has no reaction time,
so it is a good deal better than a ten-year-old.

| Difficulty | Points to the bot | Rally lengths |
|---|---|---|
| 0.5 | 16 of 16 | mostly 1–2 shots |
| **0.6** (default) | **16 of 20** | 1–5 shots |
| 1.0 | 10 of 16 | 1–5 shots |

Joel should be able to win at 0.6 and be pushed at 0.8. Turn it up as he gets better — it is one
number in `Tuning`.

---

## What is left

1. **Nobody has played it with a thumb.** Everything above was verified through the demo bot and
   screenshots. The bot re-steers ten times a second at a point it computes exactly; a person
   drags a finger. The green X now marks *where to stand* rather than where the ball is, which
   should help, but whether the drag control is fast enough to reach a wide ball is unknown.
   **Do this first.**
2. **Rallies are still short** — a 5-shot rally is the longest seen. Once a return goes back, the
   next shot usually wins the point, because `planShot` aims away from where the opponent is
   standing and the opponent is not good enough to cover it. If longer rallies are wanted, the
   place to look is `planShot`'s depth and the opponent's recovery position between shots.
3. **`Tuning.difficulty` is not exposed to Joel.** It is a constant with a debug flag. A line in
   the badge screen or a three-way picker before the match would be the obvious next thing, and
   is squarely amber-zone UI work.
4. **The trace's `closestApproach` tracking runs even when tracing is off.** It is a `simd_length`
   per sub-step during a forward swing — perhaps thirty a stroke, so genuinely nothing — but if
   the swing code is ever reworked it can be moved behind the flag.
5. **The 2D game is still in the tree** behind `-tennis2d`. Nothing in this session touched it.
   Deleting it is a decision for Ben, not a tidy-up.
