# Handoff — the corner that ate the drag, and a ball that stops running

Sixth in the series. [Part 1](HANDOFF-tennis3d.md) is the architecture, [part 2](HANDOFF-tennis3d-part2.md)
is why a serve could not be returned, [part 3](HANDOFF-tennis3d-part3.md) is the strike-zone bug,
[part 4](HANDOFF-tennis3d-part4.md) is the camera, [part 5](HANDOFF-tennis3d-part5.md) is the high
ball and the difficulty that means something. Read those first — the frames, the units and the
`Tuning` names all come from them.

**Status: work in progress.** Written as the session goes so it can be picked up mid-way.
Anything marked ⏳ has not been finished or measured yet.

---

## The oldest item on the list, and what it actually turned out to be

Part 5's item 1, unchanged for four sessions: *"Nobody has still played it with a thumb."*

The Claude Code simulator panel **attached** this time, and its `tap`/`touch_path` calls returned
success. So the first half hour of this session was spent playing the game with an injected
thumb, watching the trace, and concluding that **the drag gesture was completely broken** — a
full drag across the court produced `you=(1.5, 12.5)m … speed=0.0` for an entire point.

That conclusion was wrong, and the way it was wrong is worth writing down.

Instrumenting `panned` showed zero gesture callbacks. Instrumenting `hitTest` showed zero
hit-tests. That is not a broken gesture — that is no touch arriving at all. The control
experiment settled it: **the help button did not open the help dialog either, and the HOME button
did not go home.** The panel was in a crash loop (`screenshot` kept returning "restarting after a
crash") and its input injection was silently doing nothing while reporting success.

So: `simctl` still cannot inject a touch, `idb` and `cliclick` are not installed, and the panel
reports success while delivering nothing. **Do not trust a green result from the panel's `tap`
without a control that proves the app moved.** Press HOME first; if the springboard does not
appear, the injection is dead and every test you run through it is worthless.

## So the input path got tested from both ends instead

Being unable to inject a touch is not a reason for the logic behind the touch to go unexercised.
Two new flags split the problem in half, and between them they cover everything except UIKit's own
delivery of a `UITouch` to a view — which is Apple's code, and which the first half now proves is
wired correctly.

### `-tennis3dhittest` — is the court even reachable?

Once a second, asks the **real window** the question UIKit asks — `hitTest` this point — at four
places on the court, and reports which view wins. `Tennis3DView.debugHitTestReport(at:)`.

This is the half that no amount of driving the view from inside can answer, and it found a real
bug on its first run:

```
tennis3d hit-test · court centre        201,437 → Tennis3DView ✓
tennis3d hit-test · near baseline       201,694 → Tennis3DView ✓
tennis3d hit-test · bottom-right corner 342,784 → UIButton ✗ — this view is not reachable
tennis3d hit-test · Alex's half         201,305 → Tennis3DView ✓
```

**Part 5 did not fix the button-bar problem, it halved it.** Hiding badges and emotes left the
exit and help buttons sitting in the bottom-right corner — which is still exactly where the near
player stands when a deep ball has pushed them back onto the fence. A drag that *starts* there
never reaches the game. It is the drag you most need, because you are in trouble, and it did
nothing.

The fix is to move the row rather than thin it: `GameViewController.setButtonBarOutOfPlay(_:)`
swaps the bar's bottom constraint for a top one for the duration of any minigame, and
`ButtonBarView.setMinigameMode` turns the stack vertical so the two survivors are one button wide
and clear the right-hand end of the scoreboard. All four probes now report `Tennis3DView ✓`.

### `-tennis3ddrag` — does the drag itself work?

`-tennis3dtaps` covers the tap recogniser and nothing else. The drag has its own bookkeeping — the
1.8 m grab test, the offset held constant for the rest of the gesture, the `isDragging` flag that
stops the tap recogniser fighting it — and none of it had ever run, on any machine, in five
sessions.

It could not run, because a `UIPanGestureRecognizer` cannot be constructed with a chosen state and
location. So `panned`'s body moved into `handleDrag(_ phase: DragPhase, at: CGPoint)`, and
`debugDrag` enters at the same line UIKit would. The bot sends one `.began` **on the player**, so
the grab branch runs, then `.changed` at 30 Hz for the rest of the point, then `.ended` when the
point ends — a real gesture rather than a stream of separate grabs.

It plays. `DRAG grabbed, offset (0.00, -0.00)m`, then strikes with no misses.

---

## The ball does not carry too far, and never did

Part 5's item 2 said a topspin ball "kicks on five or six metres past its bounce" and pointed at
`bounceRestitution` and the topspin `kick`. Measured across 130 shots before anything was changed
this session:

| | |
|---|---|
| Carry, bounce to contact | median **2.85 m**, max 6.4 m |
| Contact height | median **1.20 m** — a waist-high groundstroke |
| Contact distance from the net | median **11.0 m**, against an 11.9 m baseline |

That is a player standing just inside their own baseline taking a waist-high ball a bit under
three metres after it pitches, which is what tennis looks like. The five-or-six-metre figure is
the tail, not the norm, and part 5's own behind-the-baseline cost in `intercept` is what fixed it.
**No change made. Do not go tuning `bounceRestitution` on the strength of the old note.**

## Why nobody ever hit the ball out — it was not the physics

The finding every session since part 4 has recorded and none has acted on: across twenty points,
not one `OUT`, `INTO THE NET`, `LONG` or `DOUBLE FAULT`. Every single point ended with somebody
failing to *reach* a ball.

The obvious culprit is `launchBall`, which solves the launch by simulation until the ball lands on
the target — so whatever the swing was like, the ball lands in. `quality` could only ever take
pace off and drag the aim towards the middle. A bad shot was a weak shot, never a miss.

So the first attempt was to put the error **after** the solver: a real mishit is not "I aimed
somewhere safer", it is "I meant to hit it there and I did not". `launchBall(…, mishit:)` now
perturbs pace and launch angle once the solve is done.

**It changed nothing — still 0% of points ended in an error.** Two measurements explain why, and
the second is the one that matters:

1. `random.spread(x)` averages three signed samples, so it is triangular about zero and its useful
   width is about `x/3`. The first pass at `mishitPace = 0.10` was really a ±1% pace error.
2. Far more important — **the aim was never near the lines**. Measured over 228 shots:

   | | |
   |---|---|
   | Landing error from the target | median 0.10 m, p90 0.40 m, **max 1.53 m** |
   | Aim depth from the net | median 7.6 m |
   | Margin from the aim to the baseline | **median 4.29 m** |

   `planShot`'s depth was `random.range(0.58, 0.82)` of a half-court, so the deepest ball in the
   game landed two metres inside the line and the typical one over four. Nothing could go out
   because nothing was ever aimed near enough to the line to go out. Scaling the mishit up cannot
   fix that: a shot aimed at the service line does not go out, it lands short.

### So depth is the risk, and only bad shots miss

Two changes, and they are a pair:

- **Depth** is now `random.range(0.60, 0.84) + 0.06 * attack`. `attack` is already "how far inside
  your own baseline you are standing", so the reward for good position and the risk that comes
  with it are the same number — stand in, hit through the ball, aim nearer the line, and a mishit
  now costs a point.
- **The mishit is shaped**, so only a genuinely bad shot goes astray:
  `sloppy = max(0, (1 - quality) - 0.25) / 0.75`. A flat `1 - quality` puts an error on every ball
  in the game — median quality is 0.70, so the typical rally shot would carry a third of the
  maximum error and the game would read as random rather than as demanding. Clean contact is
  exact; a full-stretch scramble is not.

⏳ **Being measured now.** `Tuning.mishitPace` 0.46, `mishitLoft` 0.56, `mishitThreshold` 0.25, and
the two difficulty scales `playerMishitScale` / `npcMishitScale`. The target is somewhere around a
quarter to a third of points ending in an actual error; the rest should still end by somebody not
getting there.

## Measuring three difficulties at once

`scratchpad/run3.sh` boots the app on **three simulators** — iPhone 17, 17 Pro, 17 Pro Max — and
plays Easy, Normal and Hard simultaneously, one per device, with `-tennis3ddrag -tennis3dtrace`.
Four minutes of wall clock instead of twelve. `scratchpad/analyse.py` reads the logs and reports
who won, how the points ended, rally lengths, and the quality/mishit distribution.

### Read this before you start a measured run

Five things cost most of an afternoon between them. All five look like "the game is behaving
oddly" and none of them is.

- A point that ends in one stroke logs "after 1 **shot**", singular. A regex expecting `shots`
  silently reports "no completed points yet" on a log full of them.
- The app stages 256 MB of assets on install, so a run takes about a minute to reach the court.
  Do not read the log until it has some `POINT to` lines in it.
- **Three simulators at once starve each other.** Running Easy, Normal and Hard in parallel looked
  like a three-times speed-up and delivered about two points in eight minutes per device. One
  device on its own runs at real time — check it with `wc -l` twice thirty seconds apart, and
  expect about **93 lines per 30 s** (two trace lines a second plus events). Anything much less
  and the run is not worth waiting for. Measure one difficulty at a time.
- A rally now runs 7–15 shots at Normal against the drag bot, so a point takes the best part of a
  minute and twenty-four points is twenty minutes of wall clock. Budget for it.
- **`--console-pty` ties the app's life to the shell that launched it.** Every measured run died
  part-way through — mid-rally, no crash report, the log just stopping with the PID line — because
  the launching shell was reaped and took the app with it. Launch it detached:

  ```bash
  nohup xcrun simctl launch --console-pty <udid> com.allr.joelsworld \
      -autojoin Joel -map 4 -tennis3dtrace -tennis3ddrag > run.log 2>&1 & disown
  ```

**Sanity-check every run before you wait on it.** Two `wc -l` thirty seconds apart, and expect
about 93. A run at 10 lines a minute is a run you will draw conclusions from twelve times too
slowly, and it looks exactly like a run that is working.

## ⏳ Still to do this session

1. Land the mishit numbers on measured evidence.
2. Rally length is skewed, not long.
3. No volley; Alex never comes to the net.

## What is left after this session

*(to be filled in)*
