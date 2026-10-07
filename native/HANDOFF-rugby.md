# Rugby

Five a side, red against blue, first to **three tries**. Before the first whistle you pick a
class — **Royal** runs faster, **Challenger** tackles faster and is harder to bring down — and a
pass is **a tap on the pitch**: the ball is thrown to wherever you tapped.

This is the seventh minigame and the second with a whole team on your side. It is
`FootballGame`'s sibling and borrows its spine wholesale — read
[HANDOFF-football.md](HANDOFF-football.md) first; this note only covers what rugby changes.

```bash
# Play it, no server needed (the way in from the campus needs map 9 on the server — below)
xcrun simctl launch <udid> com.allr.joelsworld -rugby

# Watch a match play itself as Royal, with a line a second of what is happening
xcrun simctl launch --console-pty <udid> com.allr.joelsworld -rugby -rugbydemo -rugbytrace
```

## What Joel asked for

> "i want to make a rugby game at the start you chose royal or challenger royal is where you are
> faster challenger are when you can tackle people faster and you have higher strength — 5 v 5
> blue red — click where you pass — make it so there is two versions online and npc — put it at
> the pitch with mr savage — click on the player on the ball multiple times, the more you click
> the slower they get and strength you use; if you're challenger you use 40 strength, if you're
> royal you use 20; when you use 100 strength [you stop]; if you stop clicking them, after 2.50
> seconds the strength you use goes to 0; also other npcs are royal or challenger"

Everything is in except **online**. That needs the server to carry a shared ball, score and ten
players between phones, which is `server/**` — red zone, Ben's call, and a deploy that costs
money. The picker shows both kinds of match so the idea is not lost; the online line reads
"needs Dad's server first" until then.

## The files

| File | What is in it |
|---|---|
| [RugbyPitch.swift](Engine/World/Minigames/Rugby/RugbyPitch.swift) | Dimensions, try lines, in-goal, the H posts, the boards, and the egg-shaped ball. |
| [RugbyGame.swift](Engine/World/Minigames/Rugby/RugbyGame.swift) | State, the class, the frame, the ball in flight, tackles, tries, the scene and the camera. |
| [RugbyGame+Team.swift](Engine/World/Minigames/Rugby/RugbyGame+Team.swift) | The ten players: the support line, the defensive line, who passes and when, what a throw does. |
| [RugbyView.swift](JoelsWorld/UI/Minigames/RugbyView.swift) | The class picker, scoreboard, banner, thumbstick, the tap, the full-time panel. |

**Tap-to-pass was tested from the glass down**: real simulator taps on the view, through the
gesture recogniser, the unprojection in `handleTap` and into `tap(worldX:worldY:)`, with the
ball landing on the team mate tapped. In a DEBUG build every tap logs where it landed in metres.

Plus the usual wiring: map 9 in `data/maps.json`, **Mr Savage** (NPC id 8 in
`data/junior_school/npc.json`, who paces the grass rugby pitch at the west end of the campus)
asks "Fancy a game of rugby?" when you walk up to him — Joel: *"put it at the pitch with
Mr Savage"* — a `MinigameKind.rugby` case, a branch in `GameState.startMinigame`, the
`rugby` badge that was already in `MenuDialogs` — and `-rugby`, `-rugbydemo`, `-rugbytrace` in
the debug harness.

## What rugby changes

**A try is the carrier over the line.** `checkTry` looks at the carrier's feet, not the ball. A
loose ball in the in-goal is nothing — somebody has to pick it up and step over.

**A tackle puts both players down and the ball on the grass.** Football's tackle hands the ball
straight to the tackler. Here `tackle(_:by:)` drops the carrier for `downTime` (1.5 s), the
tackler for `tacklerDownTime` (0.8 s), and pops the ball `releaseDistance` behind the carrier
with a hop. Neither may pick it up for `releaseCooldown`. That half-second is the whole reason
the support line exists: whoever is running behind the carrier gets there first. Players on the
floor are drawn with a grey disc and never handed the stick.

**A pass is a tap, and it flies.** `tap(worldX:worldY:)` with the ball calls `passFromHuman`,
which throws to the tapped spot (clamped to `maxPassDistance` and inside the boards).
`throwBall` solves a lob: flight time is distance over `passSpeed` clamped to 0.3–1.4 s, and
the launch is worked out to come down exactly there from chest height. Whoever is within
`catchRadius` when it comes below `catchHeight` catches it — a red shirt included. **Forward
passes are allowed.** It is not real rugby; a ten-year-old told FORWARD PASS every time he
taps ahead of himself would stop playing. The AI only ever passes level or backwards.

**A tap on the red carrier is a grab.** Joel's second mechanic. Within `grabRadius` (3 m) of
the carrier's feet, each tap spends the class's `grabCost` — Royal 20, Challenger 40 — out of
`grabStrength` (100), and the carrier runs at `1 − 0.85 × used / 100` of their pace. All 100
spent is a carrier at 15%, which is a carrier your team mates catch. `grabReset` (2.5 s) after
the last tap the strength comes back and they run free; so does a pass or a tackle, because you
have let go of them. The **strength bar** bottom right shows what is left and what a tap costs;
an orange ring under the carrier grows with every grab. Challenger's two taps slow as much as
Royal's four — the strong one hits harder, and runs out sooner. Proved with `-rugbydemo`, whose
taps on the carrier logged `grab — 20 / 40 / 60 strength used`.

**A tap with no ball anywhere else is a dive** at the carrier, if they are within
`humanDiveRange` (4.5 m, × the class's `tackling`). Same mechanics as football's slide:
direction fixed on launch, a miss costs `lungeRecovery` on the floor.

**Everybody has a class, and yours follows the stick.** `PlayerClass` is three multipliers —
`speed`, `tackling`, `strength` — plus `grabCost`. Every slot has one (`blueClasses`,
`redClasses` in `RugbyGame+Team`: wings and centre Royal, the two inside Challenger, red the
other way round), and `classOf(_:)` returns the one *you* chose for whichever body the stick is
on, so your class is yours, not one body's — control moves round the team, the way it does in
football. `strength(of:)` and `tackling(of:)` are class × the team's `Skill`, and `steer` runs
everybody at `baseSpeed × class.speed`.

| | speed | tackling | strength | grab cost |
|---|---|---|---|---|
| Royal | 1.3 | 1.0 | 1.0 | 20 |
| Challenger | 1.0 | 1.7 | 1.6 | 40 |

A red shirt needs 0.8 s on a standing Royal and 1.28 s on a standing Challenger. Royal's extra
pace means they rarely stand still long enough for either.

**The support line.** `supportTarget` fans the four team mates out either side of the carrier,
each 5.5 m further across and a little further back than the last, sides decided by home slot
so the line never crosses itself. There is no formation to hold when your side has the ball.

**The defensive line.** `defensiveTarget` puts everyone who is not the designated chaser
between the ball and their own try line, spread across. Two things make it a line rather than
a retreat, and both were found by watching a match:

- **The chaser only stands down while you are actually moving at the ball.** Control follows
  the ball to the nearest blue shirt; a thumb off the stick leaves them standing still, and
  counting that as "you are closing it down" sent nobody. A red carrier walked 20 m through a
  blue side that was all waiting for you. `chaser(for:)` now wants `speed > 1.5 m/s` too.
- **A defender the carrier runs at tackles.** Within 4.5 m of the carrier, a line player goes
  for them instead of backing off to keep the shape.

**The ball is an egg.** `RugbyPitch.ballPrimitives` is five spheres along an axis — a stretched
sphere would light wrongly, see `ScenePrimitive`. It points the way the carrier faces and the
way it is flying. Bounces get a random sideways kick, because rugby balls do.

## Difficulty

`RugbyGame.Skill` has five dials per side: `speed`, `settle`, `tackling`, `strength`, `dive`.

| | speed | settle | tackling | strength | dive |
|---|---|---|---|---|---|
| Blue (`yourLot`) | 1.1 | 1 | 1 | 1 | 1 |
| Red (`theOpposition`) | 0.85 | 1.6 | 0.75 | 0.7 | 0.7 |

**Measured** with `-rugbydemo` as Royal, before red was softened to the row above (it was
0.85 / 1.6 / 0.75 / 0.7 / 0.7): **blue 3–2 in about three minutes, from 0–2 down**, badge
claimed, 15 tackles. The bot is a bad rugby player — it passes sideways under any pressure and
never holds a line — so a real thumb will do better, and red was then made a shade softer still.
If it is too easy, raise red's `strength` and `tackling` first; if red never score, lower them.

**Kick-off** gives you a moment: the side without the ball stands ten metres back
(`kickoffSpot`), so a Royal has about two seconds and a Challenger about three before the first
red shirt arrives. A carrier who stands still gets tackled where he stands — that is the rule
working, not a bug. Rerun the demo after changing any of this.

## Things not built

- **Online.** Red zone, above.
- **No kicking.** No conversions, no penalties, no drop goals. The posts are scenery.
- **No knock-on, no line-out, no scrum.** The boards and the loose-ball rule stand in for all
  three.
- **The AI never grabs.** Only you tap; red's defence is tackles and dives. Giving red a grab
  would want its own bar on screen or it would read as the carrier slowing for no reason.
- **No tackle animation.** Both players stand still on a grey disc for the duration. The rig
  could lie down; nobody has asked it to.
- **Change player mid-match.** The class is picked once; the full-time panel has a
  "Change player" button that goes back to the picker.

## Before you can play it from the campus

`data/maps.json` ships inside the app *and* is read by the server, and the deployed server does
not know map 9. Until Ben deploys, saying Yes to Mr Savage is refused on production and
`-rugby` on the simulator is the way in. Tested against a local server: walk up to him, Yes,
and the class picker comes up on map 9. To test the way in locally:

```bash
cd server && PORT=8099 node server.js
# -at drops you next to Mr Savage, so his dialog comes straight up
xcrun simctl launch <udid> com.allr.joelsworld -host localhost:8099 -autojoin Joel -at -1984 -300
```
