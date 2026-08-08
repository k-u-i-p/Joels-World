# Handoff — the camera, and what a finger is pointing at

Fourth in the series. [Part 1](HANDOFF-tennis3d.md) is the architecture, [part 2](HANDOFF-tennis3d-part2.md)
is why a serve could not be returned, [part 3](HANDOFF-tennis3d-part3.md) is the strike-zone bug.
Read those first — the frames, the units and the `Tuning` names all come from them.

**Status: it looks like a tennis game now, and the controls point at the right thing.** Two
defects, both reported by Ben from a screenshot, and both turned out to be the same kind of
mistake: the game and the person looking at it disagreeing about what was on screen.

> **Note on shared files.** Another agent is working on `CharacterMotor`, `CharacterRig` and
> `Locomotion`. Nothing here touches them — everything below is in `Minigames/Tennis3D/**`,
> `Tennis3DView.swift`, `GameDebugHarness.swift` and `WalkTest.swift`.

---

## "It should be the character's hand that moves to that point"

Tapping the green X sent the **feet** there. The X marks where the ball has to meet the strings,
and the racket head is 1.1 m to the side of the body and 0.3 m in front of it — so tapping the
marker planted the chest exactly where the strings needed to be and the ball went past inside the
reach. That is the *precise* mistake `stance(toMeet:for:)` was written in part 2 to stop the
opponent making, and the human's control scheme had been making it all along.

The fix is `steer(racketToWorldX:y:)`. A touch is now a target for the **racket head**, and the
game subtracts `contactHeadWorldOffset` to get the feet — the same sum, from the same swing
choreography, that the opponent's brain uses. `steer(toWorldX:y:)` still exists and still means
feet; the demo bot uses it to recover between points, because recovering is about where to stand.

Two things came out of the same change:

- **A tap is read at racket height, not on the floor.** `Camera.unprojectToGroundPlane` only
  intersects z = 0, so a marker floating a metre up unprojected to the patch of court *behind* it
  — about 0.5 m at the old camera angle and **1.1 m at the new one**, which is two and a half
  sweet spots. `Tennis3DView.worldPoint(for:height:)` re-cuts the ray: from `camera.eye` through
  the floor hit, stopped at `game.playerContactHeight` on the way. It does not touch
  `Camera.swift`, which is red-zone.
- **The grab-drag now holds its offset against the racket anchor** (`playerRacketAnchor`) rather
  than the body, so putting a thumb on your own player and moving it still moves them by exactly
  the distance the thumb moved. Work it through: at `.began` the offset is
  `anchor − stringsUnderFinger`, so the first `steer` asks for `anchor` and the player does not
  budge; every later one asks for `anchor + Δfinger`.

## "The old game was more zoomed in with no unrendered outer bounds"

The unrendered outer bound was real and it was the **edge of the apron**: the hard court stopped
a couple of metres outside the tramlines and flat grass ran from there to the edge of the screen,
top and bottom, with nothing on it. The camera was also framing 16.6 m of width for a 11 m court,
so a third of the frame was ground nobody could stand on.

Then Ben asked: *"Maybe the camera should be tilted behind the player so both characters are
visible?"* — and that turned out to be the whole answer. The numbers now:

| | Was | Now |
|---|---|---|
| Camera pitch | 0.52 rad | **0.80 rad** — behind the baseline, where a television camera sits |
| Screen width in court | 16.6 m | **14.8 m** |
| Apron (drawn) | 2.2 m / 4.2 m outside the lines, symmetric | 6 m wide, **off-centre** by 1.5 m towards the near baseline |
| Playable (walkable) | 7.2 m × 15.6 m half | 7.1 m × 14.7 m half |
| Background | grass green | **sky blue** |

**The drawn apron and the playable rectangle are now separate numbers.** They used to be the same
one, which is what forced the framing: the playable area was 32 m long against a 23.77 m court, so
fitting the court on screen meant letting a player walk off the bottom of it. `playableHalfWidth`
and `playableHalfLength` are what anybody can walk to; `surfaceHalfWidth`, `surfaceHalfLength` and
`apronCentreY` are what gets drawn, and the drawn one is bigger and deliberately off-centre,
because the camera is.

### The green band at the top was the far clip plane

Worth writing down, because two rounds of making the apron bigger did nothing at all and the
reason is not obvious. `Camera.far` is 2000 units and the camera orbits at 1631, so tipped over at
0.80 rad **the ground simply stops about 18 m past the far baseline** — everything beyond that is
the clear colour, whatever geometry is drawn there. Matching the clear colour to the grass does not
work either: the clear colour goes to a linear target and the same hex comes back noticeably paler
than the shaded plane beside it.

So the clear colour is a **sky** now, the lawn fills the few metres between the apron and the clip,
and the straight line between them is a horizon — which is the one thing a straight line across the
top of a tipped-over camera is allowed to be. Raising `Camera.far` would remove the need for any of
this, and would be a one-constant change in a red-zone file that halves the depth precision for
the whole game. Ask Ben before trying it.

**`runBack` is 2.8 m, not 2.2 m**, and that is not a rounding. At 2.2 m a measured match
produced two misses and both were the player standing on the back fence with the ball still
climbing through 1.6 m over their head. A topspin reply that carries past the baseline needs a step
and a half behind it before it drops to racket height; pinning the player is not the same thing as
beating them.

---

## Somebody has finally played it with a thumb

Sort of, and it is the item that has survived three handoffs. The Claude Code simulator panel would
not attach in this session either, and `simctl` still cannot inject a touch.

`-tennis3dtaps` is the way round it. It plays the human's side **through the screen**: it takes the
same intercept `-tennis3ddemo` uses, projects it back through the live camera to a pixel, and pushes
that pixel into `Tennis3DView` at the line the tap recogniser enters. So the ray cast, the height
plane it is cut on, and the racket offset all have to be right or the player misses everything.
The UIKit recognisers themselves are still untested, and they are not the risk.

```bash
xcrun simctl launch --console-pty <udid> com.allr.joelsworld \
  -autojoin JoelTap -map 4 -tennis3dtaps -tennis3dtrace > run.log 2>&1
```

### Measured

Four minutes each, difficulty 0.6, against the tap bot rather than the direct-steer one.

| | Points | To the bot | Mean rally | Longest | Misses |
|---|---|---|---|---|---|
| Part 3's shipped run (direct steer) | 14 | 11 | 5.4 | 11 | 5 |
| Racket-aimed taps, camera at 0.34 rad | 15 | 7 | 5.3 | 17 | 4 |
| **Racket-aimed taps, camera at 0.80 rad** | **12** | **6** | **5.1** | **9** | **1** |

The even split is the number that matters: the bot taps a marker it can see, exactly as a person
would, and it wins half its points. Rally length held up across a 2.4× change in camera pitch,
which is the evidence that the unprojection is right — at 0.80 rad an error in the height plane
would be over a metre and every rally would collapse to two shots.

Two matches were played out to the end. Alex won both 2–1, the match panel lays out over the new
camera, and with `gamesToWinMatch` temporarily set to 1 the win path reaches
`Claiming badge: tennis` — so the badge still fires and `restartMatch()` still starts a clean one.

### `Tuning.difficulty` barely moves the result

Not something this session set out to measure, and it fell out anyway:

| Difficulty | Points, tap bot vs Alex |
|---|---|
| 0.60 | 6 – 6 |
| **0.02** | **13 – 14** |

Turning Alex down to almost nothing changes nothing. The reason is visible in the traces: most
points end on the **player's** error — a ball into the net, a ball long, a miss — rather than on
anything Alex does or fails to do, and `difficulty` only touches her reaction time, her legs, her
positioning error and her aim. A ten-year-old pressing "Easy" and finding it identical to "Hard" is
a worse problem than the game being slightly hard, so this is worth a session of its own. The
honest lever is probably on the player's side: a bigger sweet spot or a more forgiving aim on Easy,
rather than a worse opponent.

## New debug flags

| Flag | What |
|---|---|
| `-tennis3dtaps` | Plays the player's side by tapping the screen. See above. |
| `-tennispitch <radians>` | Camera pitch. 0 is straight down, 0.55 is the most you get before the far clip shows, 0.80 is the default. |
| `-tenniswidth <metres>` | How many metres of court the screen is wide. Sweeps the zoom without a rebuild. |

The two camera flags exist because framing is a dozen screenshots of trial and error and each
rebuild is half a minute. Sweep with them, then write the answer into `updateCamera`.

---

## What is left

1. **The gesture recognisers have still never seen a real finger.** `-tennis3dtaps` covers
   everything downstream of the CGPoint, which is where the maths is, but not `panned`'s
   `.began`/`.changed` bookkeeping or the grab radius. The grab-drag offset is reasoned through
   above and is believed right; it is not measured.
2. **The near player is under the button bar when pinned against the back fence.** The court fills
   the frame now, so the bottom of the screen is where somebody is standing rather than spare
   apron. Moving the button bar is a global-HUD change, not a tennis one.
3. **The far player stands close to the horizon.** She is 1900 units from the eye against a 2000
   unit far plane. She will not clip today; anything that raises the camera or lengthens the court
   would. See the note on `Camera.far`.
4. **Easy, Normal and Hard play the same.** Measured, above. This is the biggest open item in the
   game now, because it is a button Joel will press.
5. **`Tuning.gamesToWinMatch` is still 2.** Fine for a first badge, short for a game. A "long
   match" toggle next to the Easy/Normal/Hard buttons is the obvious next thing.
6. **The player still cannot aim.** Their shot goes away from Alex, nudged by which way they are
   sliding. A flick at contact is the obvious second gesture if Joel asks for one.
7. **The 2D game is still in the tree** behind `-tennis2d`. Deleting it is Ben's call.

## Running it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
xcrun simctl install <udid> "$(ls -dt ~/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug-iphonesimulator/JoelsWorld.app | head -1)"
```

Two gotchas that cost time in this session, both from earlier handoffs and both still true: pick
the DerivedData folder by modification time, and give each run a different `-autojoin` name so the
server does not put two sessions in one. A third to add: `--console-pty` streams into the file you
redirect it to, and a second launch while the first stream is still attached interleaves both into
the same log and then stops. `pkill -f "simctl launch"` before each run.

Reading a run — the second one is the one that matters, because a column of near-identical
closest-approach figures is a systematic error rather than bad luck:

```bash
grep -oE "after [0-9]+ shot" run.log | grep -oE "[0-9]+" | sort -n | tr '\n' ' '
```

```bash
grep "MISS" run.log | sed 's/.*MISS //'
```
