# Handoff — making the 3D tennis game playable

Third in the series. [Part 1](HANDOFF-tennis3d.md) is the architecture, [part 2](HANDOFF-tennis3d-part2.md)
is why a serve could not be returned. Read those first — the frames, the units and the
`Tuning` names all come from them. This file is what happened next.

**Status: it plays properly now.** The headline is one defect that had been in the game since it
was written and that nothing in the previous two sessions had looked for.

> **Note on shared files.** Another agent is working on `CharacterMotor`, `CharacterRig`,
> `Locomotion` and the overworld at the same time, and their in-flight refactor is what the tennis
> code now sits on (`side.motor` rather than `side.locomotion`, hands driven through `moveHandTo`).
> Nothing here touches those files — everything below is in `Minigames/Tennis3D/**` and
> `JoelsWorld/UI/Minigames/Tennis3DView.swift`.
>
> Their work does mean the whole tree spent parts of this session not compiling
> (`chestTwist` redeclared, `InputState` mid-refactor). If a build fails in `Engine/Core` or
> `Engine/Entity`, check `git status` before assuming it is tennis — and wait rather than fixing
> it, because they are still in there.

---

## Both players were swinging at balls over their heads

A twenty-point measured match produced **fourteen misses**, and every one of them looked like
this:

```
MISS you at (2.8, 15.3)m — closest the strings got was 0.66m,
     with the ball at (1.7, 14.1, 1.7)m (sweet spot is 0.45m)
```

Thirteen of the fourteen had the ball between **1.7 m and 1.8 m** off the court. The racket head,
which the swing choreography holds at a fixed height, passes through **0.99 m**. Nobody was out of
position: the closest-approach figures cluster between 0.63 m and 0.95 m because that is simply how
far below the ball the strings were, every time.

The cause is that the game asked two different questions about the same strike zone:

| | Where to stand | When to swing |
|---|---|---|
| | `intercept(for:)` | `timeUntilInReach` |
| Height band | strings ±0.6 m | **0.15 m – 2.6 m** |
| Distance | 3D, on the ball's path | **ground plane only** |

So the feet sensibly waited for the ball to drop to racket height, and the arm fired the moment
the ball was anywhere overhead. A topspin rally ball lands mid-court, climbs back to about 1.7 m
and passes *directly above* the receiver on its way to the baseline — which triggered a full
0.63 s stroke into thin air, after which the cooldown made the real shot impossible too.

The fix is `verticalReach` in `Tennis3DGame+Players.swift`: one definition of how far above or
below the strings a ball may be, read by both. `timeUntilInReach` now tests it before anything
else. Misses in the same measured match went **14 → 6**.

This is the third time in three handoffs that the bug has been "two pieces of code disagreeing
about where the racket is". It is worth being suspicious of any new number that describes the
strike zone and is written down twice.

---

## Alex could not have returned a serve if she had wanted to

Two more, both found in the same traces.

- **She stood behind the entire strike window.** `moveToServeMarks` put the receiver 2.0 m behind
  their baseline. A serve here lands about a metre inside the service line, comes off the court at
  5.5 m/s upward, peaks around 1.55 m at mid-court and is back to knee height about a metre past
  the baseline — so the window in which it can be hit ends *in front of* where she was standing.
  She never swung, and the trace showed no miss because there was nothing to miss. Now 0.9 m back.
- **Her positioning error was bigger than the sweet spot.** `npcPositionError` was 1.5 m falling to
  0.4 m with difficulty — 0.84 m in *each* axis at the default, against a 0.42 m sweet spot. An
  error deliberately larger than the target is not "a bit worse", it is a coin toss on whether she
  can play the ball at all. Now 0.62 m falling to 0.15 m. Difficulty is expressed through her
  reaction time, her legs and her aim instead, which is where it belongs.

And for rally length, `planShot` aimed 0.45–0.80 of a half-court away from a player who recovers to
the middle — a 3.3 m sprint on every single ball, which is why the point was over by the third
shot whoever hit it. Now 0.30–0.68, and Alex recovers to 1.2 m behind her baseline rather than
0.6 m, because that is where the reply is at racket height.

---

## What Joel can now do that he could not

- **Grab himself and drag.** A drag that starts within 1.8 m of the player keeps the offset
  between finger and character for the rest of the gesture, instead of snapping the character
  under the middle of the thumb. A drag anywhere else still steers straight at the finger, and a
  tap still means "run there". `Tennis3DView.panned`.
- **Choose how good Alex is.** Three buttons under the scoreboard — Easy / Normal / Hard — shown
  between points and faded out during a rally so they are never under the ball. The choice is
  remembered across matches and across launches (`Tennis3DDifficulty`, `UserDefaults`).
  `-tennisdifficulty <0…1>` still overrides it outright for a balancing run.
- **See his rally.** "RALLY 4" appears from the third shot of a point, and the match panel says
  what the longest one was. Nothing in the rules turns on it.

---

## Measured

Against the `-tennis3ddemo` bot, which reads the ball perfectly and has no reaction time, so it is
a good deal better than a ten-year-old. Four minutes of play each, difficulty 0.6. Logs are in
this session's scratchpad as `baseline.log` … `fix3.log` if anyone wants to re-derive these.

| | Points | Misses | Points to the bot | Mean rally | Longest |
|---|---|---|---|---|---|
| Before | 20 | 14 | 14 | 2.8 | 5 |
| Strike zone fixed | 20 | 6 | 16 | 2.7 | 5 |
| Plus receiver position and Alex's error | 16 | 7 | 6 | 2.6 | 4 |
| Plus flatter shots (`stretched` fixed) | 2 | 1 | 2 | 4.0 | **15+** |
| **Aim put back to 0.38–0.78 — shipped** | **14** | **5** | **11** | **5.4** | **11** |

The fourth row is the overcorrection: with flat, controlled shots and pulled-in aim, two perfect
players rallied for four minutes and produced two points. The aim range was put back most of the
way to land between the two, on the reasoning that a thumb will end points a great deal sooner
than the bot does.

The shipped run played a full match out to 2–0, showed the match panel, restarted cleanly on
"Play again" and started a fresh match — so the badge path is intact.

**Mean rally length doubled, and it doubled because of the strike-zone bug, not the tuning.**
Every number in `planShot` was being asked to compensate for players who could not hit a ball
that was in front of them.

**Every row above is a whole-match measurement, not an impression.** The loop is four minutes long
and it has now caught three separate defects that looked fine on screen; use it before changing a
number in `Tuning`.

---

## What is left

1. **Still nobody has played it with a thumb.** Everything here was measured through the demo bot
   and screenshots; `simctl` cannot inject touches. The grab-drag is a code change nobody has felt.
   This is now the oldest item on the list — it has survived two handoffs.
2. **`Tuning.gamesToWinMatch` is 2.** Fine for a first badge, short for a game. Worth a "long
   match" option next to the difficulty buttons once those have been used in anger.
3. **The player cannot aim.** Their shot is aimed automatically away from Alex, nudged by which
   way they are sliding when they hit. That is the right default for one thumb; a second gesture
   (a flick at contact?) is the obvious next thing if Joel asks for it.
4. **`closestApproach` tracking still runs when tracing is off.** It is a `simd_length` per
   sub-step during a forward swing and it has now found the bug in two consecutive sessions, so
   it is earning the thirty multiplications a stroke.
5. **The 2D game is still in the tree** behind `-tennis2d`. Deleting it is Ben's call.

---

## Running it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

New files in `native/Engine/**` are picked up automatically — the project uses synchronised file
groups, so adding one does **not** mean touching `JoelsWorld.xcodeproj`.

```bash
xcrun simctl install <udid> "$(ls -dt ~/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug-iphonesimulator/JoelsWorld.app | head -1)"
xcrun simctl launch --console-pty <udid> com.allr.joelsworld \
  -autojoin Joel -map 4 -tennis3ddemo -tennis3dtrace > run.log 2>&1
```

macOS has no `timeout`, so background the launch and `xcrun simctl terminate` it afterwards.

**Two simulators are booted and the other agent is using one of them.** Their installs killed
three of this session's runs part way through, which shows up as a console log that simply stops
mid-rally with no crash report and a different PID next time you look. Check
`xcrun simctl list devices booted`, pick the one they are not on, and give the two runs different
`-autojoin` names so the server does not put them in the same session.

Reading a run:

```bash
grep -E "STRIKE|POINT to" run.log | awk '/POINT/{print n; n=0; next}{n++}' | sort -n | uniq -c
```

```bash
grep "MISS" run.log | sed 's/.*MISS //'
```

The second one is the one that matters. A column of near-identical closest-approach figures means
a systematic error somewhere, not bad luck — and the ball's z in that line is where to look first.
