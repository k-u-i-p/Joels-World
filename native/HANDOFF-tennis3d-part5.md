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

And the aim ranges opened up with it — the player's from 0.38–0.78 of a half-court to 0.42–0.86,
Alex's to 0.34–0.70 at difficulty 0 and 0.49–0.98 at 1. Part 3's careful table of aim widths was
measured against players who could not reach a ball above their own shoulder; the same aim moves
nobody now.

## Making Easy easy, and Hard hard

`Tuning.difficulty` reached across four numbers, and all four were Alex. Three more now, and one
of them is on the player's side of the net:

| | Easy 0.35 | Normal 0.6 | Hard 0.9 |
|---|---|---|---|
| `playerReachScale` — **the player's sweet spot** | 1.19 → 0.50 m | 1.0 → 0.42 m | 0.775 → 0.33 m |
| `npcPaceScale` — how hard Alex hits | 0.92 | 1.00 | 1.11 |
| `npcAimRange` — how near the lines she aims | 0.39–0.80 | 0.43–0.87 | 0.48–0.95 |

All three are anchored so that **Normal is exactly the balance three previous sessions measured**.
Easy and Hard move away from it in opposite directions.

The sweet spot is the important one, and it is worth saying why the difficulty setting reaches
across the net at all. Part 4 measured 0.60 against 0.02 and found no difference, and concluded
that "the honest lever is probably on the player's side". It is: in twenty measured points at the
start of this session **not one ball went out or into the net**. Every point ended with somebody
failing to reach a ball. If reaching the ball is the whole game, the size of the target is the
whole difficulty. The green X is drawn the size of the sweet spot it stands for, so pressing Easy
visibly makes the target bigger rather than only making it bigger in the arithmetic.

## Measured

Four to five minutes each, `-tennis3dtaps -tennis3dtrace`, tap bot versus Alex, one run per
simulator. The bot reads the ball perfectly and has no reaction time, so it is a good deal better
than a ten-year-old — read it as an upper bound on Joel.

| | Bot – Alex | Mean rally | Median contact |
|---|---|---|---|
| **Before this session**, 0.35 | 5 – 6 | 4.9 | 14.0 m, ball 1.5 m up |
| **Before**, 0.90 | 1 – 8 | 5.1 | 14.0 m |
| Lift only, 0.35 | 0 – 0 | **59** | — |
| Lift + stretch penalty, 0.35 | 2 – 0 | 14 | — |
| **Shipped, Easy** 0.35 | 8 – 0 | 7.3 | 9.4 m |
| **Shipped, Normal** 0.6 | 4 – 3 | 11.7 (median 3) | 8.5 m, ball 1.0 m up |
| **Shipped, Hard** 0.9 | 0 – 5 | 4.6 | — |

**The three settings now produce three different games**, which is the biggest open item in part
4's list and the reason for most of this session. A perfect player is level with Alex on Normal
and loses to her on Hard.

The rally distribution is skewed rather than long — a median of three shots with the occasional
twenty or forty — which is a better shape than a flat mean suggests. A point takes about thirty
seconds, so a Short match is five or six minutes.

## Three things Joel can do that he could not

### Aim

**Tap Alex's half of the court and the next shot goes there.** One tap, no second finger, nothing
to learn — and it cannot be confused with steering, because you cannot stand on her half. A tap
over there previously meant nothing more useful than "run at the net".

- `Tennis3DGame.aimShot(atWorldX:y:)` clamps it inside the singles court with a 0.6 m margin, so
  choosing a target is never itself the error.
- Five gold posts mark it. It is spent by the next shot, hit or miss, and expires after eight
  seconds — keeping it would send every ball of the rest of the point to the same corner.
- `planShot` gives a chosen target outright: no away-from-Alex, no slide nudge, no random depth.
  It is still only a request, because `strike` drags a mistimed or stretched shot back towards
  the middle. Choosing the line and *then* reaching for the ball off balance gets you most of the
  way there and not all of it.
- The tap is unprojected on the **floor**, whereas a steer is unprojected at racket height. Those
  planes are more than a metre apart on screen at this camera angle.

### Choose how long the match is

`Tennis3DMatchLength` — Short (2 games) or Long (4) — with the same shape as the difficulty:
buttons under the scoreboard, persisted in `UserDefaults`, read fresh at the end of every game so
nothing caches it. `-tennisgames <n>` overrides it for a run that has to reach the badge quickly.

### Drag in the corner he is standing in

The button bar is five 44-point circles across the bottom right, which is exactly where the near
player stands when a deep ball has pushed them back. They sat on top of the character and ate the
first centimetre of any drag starting there — the drag you most need, because you are in trouble.
Badges and emotes are hidden for the duration of any minigame now (`ButtonBarView.setMinigameMode`),
leaving the exit and the help button. Neither does anything a minigame can use.

## A rule about the far end of the court

Worth writing down, because it cost an hour and the symptom is silence rather than an error.

**Nothing may lie flat on Alex's half of the court.** The aim marker was first a flat gold square
and then a square outline of thin bars, both a couple of units above the surface, and *neither
appeared on screen at all* — while a small post standing in the middle of them, from the same
array, in the same blended pass, drew perfectly every frame.

It is the depth buffer. The camera orbits at 1631 units with `Camera.far` at 2000, so the far
baseline is right out at the end of the range, where the depth value cannot separate two surfaces
two units apart. Near the player the same trick is fine — the ball's shadow lies 1.6 units up and
has never flickered — because precision at the bottom of the screen is a different world from
precision at the top. Part 1 recorded "z-fighting between three ground planes 1.5 cm apart" as a
solved mystery; this is the same mystery at a different distance.

So the aim marker is five little posts, and it reads better than the square would have: from a
camera tipped 46° over, something standing up is something you can see. Raising `Camera.far` is
still the real fix and is still a red-zone change — see part 4's note.

## New debug flags

| Flag | What |
|---|---|
| `-tennis3daim` | The tap bot picks a corner of Alex's court before each shot, **by tapping it**. The only thing that exercises the aiming gesture end to end, since its ordinary taps are all on its own half. |
| `-tennisgames <n>` | Games needed to win. `-tennisgames 1` reaches the match panel and the badge in about three minutes. |

## Seen on screen, not just in a log

Screenshots, `xcrun simctl io <udid> screenshot`, since the Claude Code panel would not attach:

- The **settings panel** lays out as two rows — `ALEX [Easy][Normal][Hard]` over
  `MATCH [Short][Long]` — with the live choice highlighted. It only shows between points, so catch
  it in the first three seconds of a launch; at seven seconds a rally is already going and it has
  faded out.
- The **aim target** is five gold posts on Alex's court, clearly legible from the near baseline.
- The **match panel** reads "YOU WIN! You beat Alex 1—0. The tennis badge is yours. Your longest
  rally was 7 shots." over Play again / Back to school.
- The **button bar** is down to the exit and the help button during a match.

## The badge path still works

`-tennis3ddemo -tennisgames 1 -tennisdifficulty 0.2` played a match out, and the trace has it in
order: four points, `Claiming badge: tennis` **once**, `matchOver`, the demo bot's restart, and
then a clean second match from `toMarks` with the score back to Love. So the panel lays out, "Play
again" restarts, and the badge fires once per match won and not twice.

## What is left

1. **Nobody has still played it with a thumb.** Four handoffs now. `-tennis3dtaps` covers
   everything downstream of the CGPoint and `-tennis3daim` now covers the aiming tap as well, so
   what is untested is `panned`'s `.began`/`.changed` bookkeeping and the 1.8 m grab radius. The
   Claude Code simulator panel would not attach in this session either — it reported repeated
   crashes and asked for the panel to be reopened — and `simctl` still cannot inject a touch.
   **If the panel attaches for you, this is the first thing to do.**
2. **The ball carries too far.** A topspin ball kicks on five or six metres past its bounce, which
   is why `intercept` has to be bribed to take it early at all, and why both players stand a
   couple of metres inside the baseline rather than on it. `bounceRestitution` (0.73) and the
   topspin `kick` in `bounce()` are where to look. It is the honest version of the positioning
   fix, where the behind-baseline cost is the cheap one.
3. **Rally length is skewed, not long.** A median of three shots with occasional forty-shot
   points. The long ones are two well-positioned players exchanging from the same spot; whatever
   ends them is chance. Watch one before tuning anything.
4. **Alex never comes to the net, and neither can the player usefully.** There is no volley: the
   choreography is one groundstroke, and `steer` clamps the player to 0.6 m from the net but
   nothing rewards being there. A net game is the obvious next feature and it is a real one.
5. **`Camera.far` is still 2000.** See part 4, and the z-fighting note above. Red zone.
6. **The 2D game is still in the tree** behind `-tennis2d`. Deleting it is Ben's call.
