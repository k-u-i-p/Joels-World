# School Rush

An endless runner down a school path, in the style of Minion Rush. Joel asked for it: *"you run
like Minion Rush, it's 3D, and you dodge stuff like cars, people and bags."*

You run forwards on your own and never stop. Three lanes. Tap the left or right of the screen —
or swipe — to change lane; tap low in the middle, or swipe up, to jump.

**You can jump over everything except people.** That is Joel's rule and it is what sets the size
of the jump: a car is 3.9 m long and 1.42 m to the roof, so the leap has to peak at over three
metres and stay up for the best part of a second. A pupil standing in a lane is the one thing you
have to go *round*.

**Every ten coins makes the jump 1% higher**, shown as `JUMP +7%` on the counter. Height goes as
the square of the launch speed, so the boost is applied as a square root — see `jump()`.

Three hits and the run is over. **400 m earns the School Rush badge**, which is the eighth badge
and the first one this build added.

## Where everything is

| What | Where |
|---|---|
| The run: pace, lanes, jumping, collisions, course generation, camera | [SchoolRushGame.swift](Engine/World/Minigames/SchoolRush/SchoolRushGame.swift) |
| The track: lanes, scenery, and every obstacle's shape | [SchoolRushTrack.swift](Engine/World/Minigames/SchoolRush/SchoolRushTrack.swift) |
| Counters, banner, game-over panel, gestures | [SchoolRushView.swift](JoelsWorld/UI/Minigames/SchoolRushView.swift) |
| The map | `data/maps.json`, id 5, `import: /src/minigames/schoolrush.js` |
| The door onto it | `data/junior_school/objects.json`, object 90, near the tennis courts |
| The badge | `MenuDialogs.swift`, id `school rush` |

Everything Joel is likely to want to change is a constant in `SchoolRushGame.Tuning` or
`SchoolRushTrack`: how fast you start, how fast it gets, how high a jump goes, how far the badge
is, how often a second lane gets blocked, what colour the bins are.

## The three things worth knowing before changing it

**1. There is no static world.** The tennis court is eighty primitives built once, because a court
does not move. A runner's track never ends, so `SchoolRushTrack.scenery(aroundY:)` generates
around a hundred primitives every frame from the player's position, one six-metre tile at a time,
and tiles behind are simply not asked for again. `ScenePrimitiveRenderer` caches a GPU mesh per
**distinct size**, so every hedge must be the same hedge — a track that varied its sizes smoothly
would ask for a new mesh sixty times a second and get the app killed.

**2. The player really moves.** They travel down decreasing Y rather than standing still while the
world slides past, which costs nothing (the numbers stay small enough for a float for well over an
hour of running) and buys the whole of `CharacterMotor` for free: the legs run because the body is
actually moving, the jump is a real projectile, and a lane change is the same side-step the tennis
players use.

**3. `Tuning.lateralFraction` is secretly the run animation.** The motor caps a demand at
`profile.maxSpeed`, so the profile has to hold a full-pace run *and* a full-speed swerve at once —
and `Gait.intensity` is speed measured against that same cap. At 0.8 the runner was permanently at
78% of their own top speed and jogged. At 0.55 they are at 88% and sprint. If the runner ever
starts jogging again, this is why.

## Playing it without a thumb

`simctl` cannot inject touches, so there is a bot:

```bash
xcrun simctl launch --console-pty <device> com.allr.joelsworld -map 5 -schoolrushdemo -schoolrushtrace
```

`-schoolrushdemo` presses exactly what a thumb presses — `jump()` and `changeLane(by:)` — so it
proves the *controls* work, not merely the simulation. It restarts once when a run ends, to show
the panel's **Run again** leaves the game playable. `-schoolrushtrace` logs one line a second.
`-exitafter <s>` works too. A measured run on the bot: 1176 m, 3 lives, badge at 400 m, and the
`badge_earned` frame came back from the server.

## The sound

The one real bug found here is worth remembering: **`laser.mp3` is ten and a half seconds long.**
It was the coin pickup, and a hundred and fifty coins in a run meant a hundred and fifty
ten-second lasers stacked on top of each other — by thirty seconds the game was a wall of noise.
Check the length of anything in `assets/media/` before using it as a one-shot; most of the files
there are several seconds long and only `jump.mp3` (0.68 s) and `hit_tennis_ball2.mp3` (0.84 s)
are short enough to fire repeatedly.

Coins now use `hit_tennis_ball2.mp3` at better than double speed, **pitched up through an unbroken
chain** — the Sonic-ring trick, and most of why collecting a line of them is satisfying. A school
bell opens each run. Footsteps needed a new host call, `minigameSetFootsteps`: the overworld
drives its footstep loop off its own player, who is standing still somewhere else while a minigame
is on screen, so a sprinting character made no sound at all.

## Not done yet

- **The live server has to be redeployed before anyone can walk into it.** The server reads
  `data/maps.json` itself and `handleChangeMap` refuses a map id it does not know, so map 5 does
  not exist on `joels-world.com` until Ben deploys. Until then it is reachable with
  `-host localhost:<port> -map 5` against a local `npm run dev`.
- **No slide.** Minion Rush has a duck-under; this has jump and lane change only. A slide needs a
  crouch pose on the rig, which is real work in `CharacterRig` rather than a data change.
- **The school bus is scenery, not an obstacle.** It is 3 m to the roof: a jump that cleared it
  would also clear every row in the game and turn the jump button into a cheat code. Eleven metres
  of bus parked beside the path does more for the place than eleven metres of wall across it.
- **The graphics are as far as this renderer goes without engine work.** Mown stripes, kerbs,
  trees, a bus and a warmer palette are all scenery; there is no fog, no bloom and no
  post-processing, and adding any of them means `Shaders.metal`, which is Ben's.
- **The pupils just stand there.** Making them walk across the lanes would be the single biggest
  improvement to how alive the track feels, and it is a `CharacterMotor` per pupil plus a
  waypoint — the machinery is all there.
- **One course.** Every chunk is one row of obstacles with a gap. Themed stretches — a corridor, a
  car park, the playground — would be a second `appendTile` and a second obstacle table.
