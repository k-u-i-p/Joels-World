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

### What is and is not now proven about the controls

Worth being exact, because "nobody has played it with a thumb" has been carried forward four
times and should not be carried forward a fifth without saying what it still means.

| | |
|---|---|
| A touch on the court reaches `Tennis3DView` | **Proven**, all four probes, live hierarchy |
| Screen point → ray cast → racket offset → court | **Proven**, `-tennis3dtaps` |
| The aiming tap on Alex's half | **Proven**, `-tennis3daim` |
| The drag's grab test, held offset and `.began`/`.changed` | **Proven**, `-tennis3ddrag` |
| UIKit delivering a `UITouch` to the recogniser | **Not proven.** Apple's code, and the hit-test probe shows the view it would be delivered to |

The remaining gap is small and it is not where a bug is likely to be. It is also, for now,
untestable on this machine: `simctl` cannot inject a touch, `idb` and `cliclick` are not
installed, and the panel's injection reports success while doing nothing.

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

### And a mishit can go wide, which was the piece that made it work

With only pace and loft, `aimX` was honoured *exactly* on every ball ever struck. Going down the
line was free, no shot was ever wide, and every mistake looked like the same mistake. The racket
face now swings off line too (`Tuning.mishitFace`, in radians), and **the very first point of the
first run with it in ended `OUT`** after five sessions of nothing.

### Measured

Against the `-tennis3ddrag` bot, which reads the ball perfectly and has no reaction time — so it
is a good deal better than a ten-year-old. Read it as an upper bound on Joel.

| | You – Alex | Ended in an error | Rally median | Rally mean / max |
|---|---|---|---|---|
| **Easy** 0.35 | 19 – 9 | 14% | 7 | 8.9 / 27 |
| **Normal** 0.6 | 10 – 12 | **23%** | 8 | 10.9 / 44 |
| **Hard** 0.9 | 10 – 26 | 11% | 4 | 6.6 / 24 |

Against a flat **0% across every session since part 4**. A perfect player is now level with Alex
on Normal, beats her comfortably on Easy and is beaten badly on Hard, which is the curve part 5
was aiming at, and points end in more than one way at all three settings.

The final numbers: `mishitPace` 0.76, `mishitLoft` 0.92, `mishitFace` 0.14, `mishitThreshold`
0.20, depth `0.76–0.96 + 0.10 × attack`, and the `strike` depth-drift down from 0.35 to 0.10.

**Every error so far is an `OUT`** — a first bounce outside the legal half, which covers both wide
and long. No `INTO THE NET` has been seen yet: the solver guarantees 0.18 m of cord clearance and
a downward loft error apparently does not often eat it. Worth a look if you want the third kind of
mistake, and the lever is `netMargin` in `launchBall` rather than a bigger mishit.

### The badge still fires, exactly once per match

`-tennis3ddemo -tennisgames 1` played two matches out (the demo bot restarts once). Two
`BADGE tennis awarded — match won 1—0` lines, one per match, and a clean restart from `toMarks`
between them. `winMatch` now writes that line into the trace file, so this is checkable after the
fact instead of needing a live console.

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
- **`--console-pty` is why measurement has been miserable for six sessions. Stop using it.**
  Every measured run this session died part-way through — mid-rally, no crash report, the log
  simply stopping. Sometimes the pipe took the app with it. Worse, sometimes it did not: the app
  played happily on while the log stopped growing, so a run that looks finished after two points
  has really played twenty and thrown eighteen away. Every balance number in parts 2 to 6 was
  measured through that pipe, which is worth bearing in mind before trusting any of them.

**So `-tennis3dtrace` now writes to a file inside the app's container as well**
(`Tennis3DTraceFile`), which survives both the pipe and the shell. Launch **without**
`--console-pty` — that detaches properly and the app runs for as long as you like — and read the
file whenever you want, during or after:

```bash
xcrun simctl launch <udid> com.allr.joelsworld -autojoin Joel -map 4 -tennis3dtrace -tennis3ddrag
DIR=$(xcrun simctl get_app_container <udid> com.allr.joelsworld data)
cp "$DIR/Documents/tennis3d-trace.log" run.log
```

`scratchpad/pull.sh` is that last pair of lines. The file is truncated once per launch, so it is
one run per file with no bleed from the last match.

### And the simulator throttles to a twelfth of real time with nothing watching it

The last and worst of them. **`Simulator.app` is not present in this Xcode install** — only
`SimulatorTrampoline` — so there is no window, no display client, and the app is throttled down
to about fifteen trace lines a minute instead of the ~93 per thirty seconds it manages at full
speed. A four-minute match takes fifty minutes and looks, from the log, exactly like a match that
is playing normally but slowly.

`xcrun simctl io <udid> screenshot` forces a frame, so a screenshot once a second keeps it at
roughly 70% of real time:

```bash
for i in $(seq 1 900); do
  xcrun simctl io <udid> screenshot /tmp/keepalive.png >/dev/null 2>&1; sleep 1
done &
```

**Sanity-check every run before you wait on it.** Two line counts thirty seconds apart, and expect
about 60–93. A run at 10 lines a minute is a run you will draw conclusions from twelve times too
slowly, and it looks exactly like a run that is working. Several of the intermediate numbers in
this session's tuning table came from runs that were quietly starved this way, which is why they
have small sample sizes next to them.

## A mechanic that is always 0 is as broken as one that is always 1

Worth its own heading because it is the second time the same thing has happened to the same
number, from the opposite direction, and nobody noticed either time until they went looking for
something else.

`attack` — "how far inside your own baseline are you standing" — drives the pace bonus, the wider
target and now the deeper one. Part 5 zeroed it a stride and a half *inside* the line, because the
median contact then sat at 8.5 m and measuring from the line pinned it at **1** for every ball of
every rally. Since then the median contact has swung out to **11.1 m** — a deeper ball pushes the
receiver back — which pinned it at **0** instead, and the whole short-ball attack had been
silently inert.

It is back on the line with the full three metres to run over. The median ball is now played at
about 0.26 of it and a genuine short ball reaches 1.

**If you change how deep the ball is hit, re-measure the median contact point and check `attack`
still varies.** It is the one number in this game that quietly depends on every other one.

## What is left

1. **A finger has still never touched it**, in the narrow sense set out above: everything from
   `Tennis3DView`'s touch entry point down is now exercised, and the hit-test probe shows a court
   touch resolves to the right view, but UIKit's own delivery is unverified. Needs `idb`, a
   working simulator panel, or a person. **Check the panel's injection with a control — press
   HOME and see if the springboard appears — before trusting a single tap.**
2. **No `INTO THE NET`.** See above; `netMargin` in `launchBall` is the lever.
3. **Alex never comes to the net, and neither can the player usefully.** There is no volley: the
   choreography is one groundstroke, `steer` clamps the player to 0.6 m from the net, and nothing
   rewards being there. Alex's recovery target is hard-coded to the middle of her baseline in
   `steerOpponent`. This is the obvious next feature and it is a real one — `intercept` already
   allows a ball that has not bounced, so the physics side is half done.
4. **Rally length is skewed, not long** — median 8 at Normal with the occasional 44. Better than
   it was, and the mishit gives long points a way to end that is not chance.
5. **`Camera.far` is still 2000**, and nothing may lie flat on Alex's half of the court. See part
   5 and part 4. Red zone.
6. **The 2D game is still in the tree** behind `-tennis2d`. Ben's call.
7. Cosmetic: the difficulty panel sits over Alex at the far baseline between points, and
   `-tennisdifficulty` does not update which button is highlighted (it overrides `Tuning` without
   touching the persisted `Tennis3DDifficulty`), which is confusing mid-measurement.
