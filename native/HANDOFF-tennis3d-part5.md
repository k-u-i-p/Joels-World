# Handoff — the high ball, and a difficulty that means something

Fifth in the series. [Part 1](HANDOFF-tennis3d.md) is the architecture, [part 2](HANDOFF-tennis3d-part2.md)
is why a serve could not be returned, [part 3](HANDOFF-tennis3d-part3.md) is the strike-zone bug,
[part 4](HANDOFF-tennis3d-part4.md) is the camera and what a finger points at. Read those first —
the frames, the units and the `Tuning` names all come from them.

**Status: work in progress.** This file is written as the session goes, so that it can be picked
up mid-way. Anything marked ⏳ has not been finished or measured yet.

---

## Where it stood at the start of this session

Two four-minute measured matches, `-tennis3dtaps -tennis3dtrace`, one per simulator, tap bot
against Alex. Logs in this session's scratchpad as `base-easy.log` and `base-hard.log`.

| Difficulty | Bot – Alex | Misses | Rally lengths |
|---|---|---|---|
| 0.35 (Easy) | 5 – 6 | 7 | 1 5 10 3 7 7 3 4 3 3 4 7 2 |
| 0.90 (Hard) | 1 – 8 | 4 | 2 6 4 6 9 9 6 3 3 |

Two things fall out of it, and they replace item 4 of part 4's list ("Easy, Normal and Hard play
the same" — they no longer do, between 0.35 and 0.90):

1. **Easy is not easy.** A bot that reads the ball perfectly and has no reaction time is *level*
   with Alex on Easy. A ten-year-old would lose every match. Every lever `difficulty` pulls is on
   Alex's side; none of them make the game more forgiving to the person holding the phone.
2. **Nobody ever hits the ball out.** Not one `OUT`, `INTO THE NET`, `LONG` or `DOUBLE FAULT` in
   twenty points. Every single point ended with somebody failing to *reach* a ball. The launch
   solver is honest to a fault: whatever the timing quality, the ball lands in. So positioning is
   the entire game, which makes the strike zone the only thing worth tuning.

### And the misses have one cause

```
MISS you at (0.2, 14.7)m — closest 0.65m, ball at (-1.2, 13.8, 1.6)m
MISS you at (2.8, 14.6)m — closest 0.65m, ball at ( 1.7, 14.9, 1.6)m
MISS you at (0.9, 14.1)m — closest 0.62m, ball at (-0.4, 13.9, 1.6)m
MISS you at (2.8, 14.6)m — closest 0.47m, ball at ( 1.6, 13.9, 1.5)m
```

Seven of the eleven player misses across both runs are at **y ≥ 14.1 m with the ball at 1.4–1.6 m**.
`playableHalfLength` is 14.7 m. That is the player standing flat against the back fence, with a
kicking topspin ball passing over their head, exactly as part 4 predicted when `runBack` was set to
2.8 m — except the answer is not more run-back.

The strings pass through **0.99 m and nothing moves them**. A ball at 1.5 m is a normal shoulder-high
forehand that any tennis player takes; this one could only duck under it. Part 3 fixed the reverse
of this bug — swinging at a ball overhead you cannot reach — by pinning the strike zone to the
racket height. The correct completion of that fix is to let the racket go up.

---

## The racket goes up now

`SwingState.lift` is how far above the waist-high groundstroke a particular swing is played, in
rig units, and it is set **once**, at `beginSwing`, from the height the ball is predicted to be at
when the strings arrive. Everything downstream reads it: the poses the arm animates through, the
head the contact test sweeps, and the racket the renderer draws.

The pieces, all in `Tennis3DGame+Players.swift`:

| | |
|---|---|
| `Tuning.strikeLiftUp / strikeLiftDown` | 12 units up, 6 down — the range the hand may move. |
| `headHeight(lift:)` | Where the strings pass, for a given lift. 0.61 m at the bottom, 0.99 m at rest, 2.09 m at the top. |
| `lift(forBallHeight:)` | The inverse, by bisection. **The only place a ball height becomes a racket height.** |
| `strikeBand(for:)` | Every height that is a shot: the whole lift range plus the tolerance either end. |

Twelve units of hand is a metre of strings, because the arm rotates about the shoulder as it
rises and the racket, a rigid extension of that line, amplifies the rotation about two and a half
times. That non-linearity is why `lift(forBallHeight:)` bisects rather than doing algebra — and
bisecting is also why there is only one copy of the sum. Every one of the last three handoffs
contains a bug that was two pieces of code disagreeing about where the strings were.

The horizontal reach barely changes across the range (a couple of centimetres), which is worth
knowing rather than assuming — but `contactHeadWorldOffset(for:lift:)` takes the lift anyway, so
the day somebody widens the range nothing quietly breaks.

### It works, and on its own it broke the game

The first measured run with the lift in and nothing else changed:

| Difficulty | Bot – Alex | Misses | Rallies |
|---|---|---|---|
| 0.35 | 0 – 0 | 0 | one point in four minutes, **59 shots** |
| 0.90 | 2 – 0 | 2 | 17, 37 |

Nobody missed anything, ever, because being out of position had stopped costing anything at all:
the racket simply went to wherever the ball was. This is the same overcorrection part 3 hit from
the other direction, and the fix is the same shape — position has to buy something.

## So a stretched shot is a worse shot

`strike` folds the stretch into `quality`, squared, so half a stretch is nearly free and full
stretch costs 40% of the shot. It arrives through machinery that already existed: less pace, and
the aim dragged back towards the middle of the court. **Position now decides how good the shot is
rather than whether there is a shot**, which is a better game to be ten years old and losing at.

`intercept`'s off-height penalty went 1.5 → 1.3 in the same breath — still "walk 1.3 m rather than
take a ball a metre off the waist", which is what a tennis player does.

That pulled contact heights down from 1.6–2.1 m to 1.2–1.5 m. It did **not** bring the points
back: a measured pair at 0.35 and 0.90 gave rallies of 19 and 9, and one point about every ninety
seconds. A "short" match of two games needs eight points, so that is a twelve-minute match.

## And a short ball can be attacked

The missing piece, and the one that makes the rally a shape rather than a metronome:
`planShot` now reads how far **inside their own baseline** the striker is standing, 0 on the line
to 1 three metres in, and widens the target by 0.22 of a half-court and adds 14% of pace across
that range.

Everything needed for it was already in place and unconnected: a stretched shot lands short, a
short ball pulls the other player in, and now being in pays. Move somebody forward, then hit past
them — which is how tennis points actually end.

Except **nobody was ever pulled forward**, because both players were living two metres behind
their own baselines. That is where the carry puts you: a topspin ball kicks on five or six metres
past its bounce, its path crosses racket height twice, and the second crossing — the one behind
you — is always nearer to where you were already standing. So `intercept` costs it now. A metre
behind your own baseline costs 0.45 m of running, which is what a coach says and which is the
cheapest way to give the court a front half back.

That number was measured rather than picked. At 0.8 it worked far too well: median contact went
from **14.0 m — flat against the fence — to 8.5 m**, which is standing on the service line for
every ball of every rally, and which also pins `attack` at 1 so it stops being something a short
ball earns you. 0.45 puts the median just inside the baseline.

## Measured

Four minutes each, `-tennis3dtaps -tennis3dtrace`, tap bot versus Alex. The bot reads the ball
perfectly and has no reaction time, so it is a good deal better than a ten-year-old.

| | Bot – Alex | Misses | Mean rally | Median contact |
|---|---|---|---|---|
| **Before this session**, 0.35 | 5 – 6 | 7 | 4.9 | 14.0 m, 1.5 m high |
| **Before**, 0.90 | 1 – 8 | 4 | 5.1 | 14.0 m |
| Lift only, 0.35 | 0 – 0 | 0 | **59** | — |
| Lift + stretch penalty, 0.35 | 2 – 0 | 1 | 14 | — |
| **Shipped**, 0.35 | 8 – 0 | 0 | 11.3 | 8.5 m, 1.0 m high |
| **Shipped**, 0.90 | 2 – 5 | — | 9.0 | — |

The two rows that matter are the last two. **Easy and Hard now produce opposite results** — a
walkover for the bot on Easy, a defeat on Hard — where at the start of the session they were 5–6
and 1–8, which is to say Easy was the harder half of a coin toss. That was the biggest open item
in part 4's list and it is closed.

Rallies are twice as long as part 4's 5.1, and that is the honest number rather than a
regression: most of the old short points ended on the over-the-head miss, which was a hole in the
strike zone rather than anybody's skill. A point now takes about thirty seconds, so a Short match
is five or six minutes.
