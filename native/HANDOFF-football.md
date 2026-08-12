# Football

Five a side, red against blue, first to three. You play **whichever blue shirt is nearest the
ball** — control moves round the team the way it does in FIFA.

This is the third minigame, after tennis and School Rush, and it is the first one with **a whole
team on your side**. That one difference is what most of the code is about: nine other players
who have to look like they are playing football rather than nine players who happen to be running
about near a ball.

The pitch went 72 × 46 m → 50 × 34 when the squads went ten a side → five, and back to 72 × 46
when Joel asked for a bigger one. What makes both of those cheap is that **the size of the pitch
and how close the camera sits are separate decisions**: `FootballGame.updateCamera` frames a fixed
32 m of width whatever the pitch measures, and everything positional is normalised into team
space, so a resize is the pitch dimensions and nothing else. Players are drawn half again as big
on top of that (`character_scale` **1.95** on map 6 in `data/maps.json` — it was 1.5, and Joel
asked for another 30%), and the ball is a beach ball
you cannot lose.

```bash
# Play it
xcrun simctl launch <udid> com.allr.joelsworld -autojoin Joel -map 6

# Watch a match play itself, with a line a second of what is happening
xcrun simctl launch --console-pty <udid> com.allr.joelsworld \
  -autojoin Joel -map 6 -footballdemo -footballtrace
```

## What Joel asked for

> "each team has 10 players — click to kick — when you kick it will go to the nearest team mate —
> the team mates are AIs who pass to you and score — enemies are the opposite of your team, they
> will score into your goal, pass to their teammates — first team to 3 points wins — the teams are
> red and blue, you are blue"

All of that is in, except the squad size — **"make the team 5 players each"** came a few minutes
later and won. The kick button passes to your nearest team mate, except inside `Tuning.shootRange`
of the goal, where it shoots, because "pass to your nearest team mate" from six yards out is not
what anybody pressing a button marked KICK is asking for.

Then, after a match or two:

> "Control should automatically pass to the blue player closest to the ball, like FIFA. Make the
> pitch bigger again but keep it zoomed in."

Both are in, and the first one changed the shape of the code more than anything since the pass
weighting — see below.

## The files

| File | What is in it |
|---|---|
| [FootballPitch.swift](Engine/World/Minigames/Football/FootballPitch.swift) | Dimensions, markings, goals, boards, the ball and the marker discs. All static, built once. |
| [FootballGame.swift](Engine/World/Minigames/Football/FootballGame.swift) | State, the frame, ball physics, possession, scoring, the scene and the camera. |
| [FootballGame+Team.swift](Engine/World/Minigames/Football/FootballGame+Team.swift) | The ten players: building them, where they stand, what they decide, what a kick does. |
| [FootballView.swift](JoelsWorld/UI/Minigames/FootballView.swift) | Scoreboard, banner, thumbstick, KICK button, full-time panel. |

Plus the usual five lines of wiring: a map in `data/maps.json` (id 6), a trigger in
`data/junior_school/objects.json` (id 91), a `MinigameKind` case, a branch in
`GameState.startMinigame`, and a badge in `MenuDialogs`.

**The way in is the school's own all-weather pitch**, the big green one in the middle of the
campus — walk onto it and you get a Yes/No dialog, the same `show_dialog` + `change_map` shape
tennis (id 49) and School Rush (id 90) use. The trigger is the playing surface itself: centred on
(−361, 811), 1700 × 1050, **rotated 14°**, which is the angle of the whole site — the tennis
court next door is on the same 14°, and the pitch was measured off `background.jpg` by masking
the astroturf (a desaturated green, unlike the lush grass around it), taking the largest connected
blob and fitting the smallest rotated rectangle to it. It stops just inside the perimeter wall, so
the path round the outside is not a trigger.

Note `rotation` is clockwise in the world's Y-down space — `Physics.swift:53` rotates a point by
**−rotation** into the object's frame, so the object's local +X axis in world is
`(cos rot, sin rot)`. Getting that backwards puts the box across the pitch rather than along it.

## The five ideas the game rests on

**1. The ball is owned, not pushed.** A player within `Tuning.controlRadius` of a slow ball takes
possession, and the ball is then glued a stride in front of their boots until they kick it or
somebody takes it. A ball that was a physics object players collided with would read as ten
children failing to trap a beach ball: at 27 units to the metre a foot is about four units across
and a 15 m/s pass crosses that in a fiftieth of a second.

**2. A tackle is time, not a dice roll.** An opponent inside `pressureRadius` of the carrier
builds pressure; past the threshold the ball changes hands. Closing someone down works, running
away works, and neither is random — which matters when the person playing is ten and would like to
know why he lost the ball. You get longer than the AI does (`pressureToStealFromHuman`).

**3. Everything positional is in team space.** A slot is `(u, v)`: `u` from −1 at your own goal to
+1 at theirs, `v` across. Both teams share one formation table, one "push up when we have it" rule
and one "get goal-side" rule, and red is not a mirrored special case with its own signs to get
wrong. `worldPoint(u:v:for:)` and `teamSpace(x:y:for:)` are the only two places the sign lives.

**4. There are no touchlines.** The pitch is boarded like a five-a-side cage, so the ball never
goes out and the match never stops for a restart that would need a referee.

**5. You are not a player, you are the stick.** `FootballGame.updateControl(dt:)` hands the
thumbstick to whichever blue outfielder is nearest the ball, and to whichever one wins it the
instant they do. `Player.isControlled` is the only thing `steer` asks — everyone you are not
driving is AI on the same frame, with no half-controlled state to get wrong — and it is written in
exactly one place, `takeControl(of:)`, so it can never disagree with `humanIndex`.

Three details make it work rather than thrash:

- **Winning the ball beats everything.** No cooldown, no margin. If a pass arrives at somebody you
  are not steering, the whole idea reads as broken.
- **Otherwise a switch needs a clear winner**: a team mate has to be `Tuning.switchMargin` *nearer*
  the ball, and switches are `switchCooldown` apart. Without both, two players a hair apart hand
  you back and forth several times a second and the stick does nothing at all.
- **The disc under your feet swells for `switchFlash` after a jump.** A marker that silently
  teleports to another player is one you notice a second late, having run the wrong pupil into a
  hedge.

Keepers are never handed to you: a keeper you are driving is a keeper out of his goal. And the
half-metre-a-second the player gets over the AI now follows *control* rather than living on one
body — `steer` applies it, so handing the stick on hands the legs on too.

## Numbers that were wrong, and what fixed them

These are the ones that cost a measured run each. If a change makes the match feel wrong, suspect
one of these first.

**Passes were launched at `distance / time` and overshot by a factor of three.** With friction in
the physics, an 8 m ball to a midfielder left the boot at 14 m/s and rolled 25 m past him into his
own box, every single time. A rolling ball decelerating at `a` covers `(v² − v_end²) / 2a`, so the
launch speed that *arrives* is `√(v_end² + 2·a·d)`. `pass(from:to:)` solves that, twice — the
second pass knows the flight time and leads the receiver by it. **Everything is solved against
`Tuning.rollFriction`; change that one number and every pass in the game is reweighted.**

**Players kicked on the frame they received.** The ball spent about four fifths of a measured
minute in transit between people who had already let it go — a pinball table, not a match.
`Tuning.settleTime` gives them half a second of touch first, chosen to sit comfortably inside
`pressureToSteal` so a settling player is not simply robbed while they think.

**Nobody shot.** The AI required a clear sight of goal, and in a box with six players in it there
is never a clear sight of goal: ninety seconds of match, twenty of them with the ball in a penalty
area, no shots at all. `Tuning.pointBlankRange` — inside nine metres, shoot anyway, through
whoever is in the way.

**Dribbling was hopeless at `dribbleFraction` 0.86.** A defender closing at full pace gained a
metre a second, so every attack ended in a tackle four seconds after it started. 0.94 leaves the
defender a job to do.

**The human counted as their team's ball-chaser.** Each side sends exactly one player at a loose
ball. With you in the running, any moment you were nearest while running somewhere else left blue
with *nobody* going for it — worth about two goals a match to red. `chaser(for:)` skips whoever
you are driving, which since auto-switching means blue's designated chaser is the *second* nearest
— so your side always has a runner going for it whatever you do with the stick.

**At 40 m of camera width the whole 72 m pitch fitted the frame.** Which is a fine way to watch a
match and a poor way to play one: nothing is ever near you, the camera never moves, and there is
no sense of running anywhere. 32 m is about two thirds of the width and rather less than half the
length, so the camera has to follow — which is also what makes the auto-switching read, because
control jumping to somebody off-screen would be a mystery.

**The kick-off was a bus queue.** Both sides play a midfielder and a striker down the middle, and
pulling everyone into their own half put four players on `x = 0` within a couple of metres of each
other. `kickoffSpot(for:)` steps the strikers off the centre line.

**Nobody had to stand outside the centre circle.** A real rule of football, skipped, and it cost
three matches: the defending midfielder's slot put him 3.4 m from the ball and *between the taker
and the goal*. Blue kicks off at the start and after every goal conceded, so blue kicked off every
time, was tackled inside a second every time, and red attacked from the halfway line every time —
`BLUE midfielder (on the ball)` at (0, 0), then one second later `RED midfielder`, identical at
every restart. It read as "red's AI is better". `kickoffSpot(for:)` pushes everyone out radially
now, and the taker is put back on the ball afterwards.

**The test harness was lying, and this is the important one.** `FootballView.step()` writes the
on-screen joystick into the game on **every rendered frame**, and an untouched joystick reads
zero — so `-footballdemo`'s input, set twenty times a second, was overwritten sixty times a
second. The player the demo was "driving" stood still for entire matches. Once control started
following the ball, that statue was *by construction always blue's nearest player to it*, which is
about as bad as a handicap gets. Three consecutive 0–3 defeats and an hour of hunting for an AI
asymmetry that did not exist. `Tuning`-level lesson: **a harness that shares an input path with
the UI has to say so** — `debugDrivesInput` now makes the demo win, and the same match finished
blue 3–0.

**The ball was invisible.** A correctly-sized size-4 ball, from a camera fitting a whole pitch
across a phone, is three pixels. `FootballPitch.ballRadius` is six times a real one now — Joel
asked for it bigger twice — which is what every arcade football game has always done, only more
so. It is *not* free: `checkGoal` wants the whole ball over the line and between the posts, so a
beach ball narrows a 5 m goal to 3.7 m of scorable mouth, and `shoot(from:)` aims inside that
rather than at the post.

**The top third of the screen was a flat blue band.** It was not sky — it was the edge of the
ground plane, which only reached eight metres past the boards. The surround is 300 m now, with a
hedge for a horizon.

## Difficulty lives in one struct

`FootballGame.Skill` is six multipliers, one set per side (`Tuning.yourLot` and
`Tuning.theOpposition`), applied at the handful of places a decision is actually taken. **You are
always blue**, so this is the one place the game is deliberately unfair.

| | speed | settle | shootRange | shotSpread | keeperReach | holdOnToBall |
|---|---|---|---|---|---|---|
| Blue (`yourLot`) | 1.2 | 1 | 1 | 1 | 1 | 1 |
| Red (`theOpposition`) | 0.8 | 1.8 | 0.55 | 2.6 | 0.55 | 0.55 |

Joel asked for his side 20% quicker and the opposition **mega easy**, and those are the two rows.
Six dials rather than one because a side made bad through any single dial looks *broken* rather
than bad: one that is only slow still passes it about neatly, one that only misses looks like the
goal is cursed. Together they read as a team that dwells on the ball, gets robbed, rarely shoots
and misses when it does. `holdOnToBall` is the sharpest — a red shirt is robbed in about a third
of a second, so red can only do anything when nobody is near them.

It touches **decisions and bodies only**. The pitch, the ball, the physics and the rules are
identical for both sides, which is what stops an easy setting reading as cheating.

Two knock-ons worth knowing:

- `Tuning.controlSpeedBonus` replaced the old absolute `humanTopSpeed`. A fixed ceiling broke the
  moment your side got a multiplier: your team mates ran at 7.7 m/s and control switching to one
  of them made them *slow down* to 7.0. It is a bonus on whatever body you are driving now.
- The keeper's reach is per side, so red's is 0.72 m against blue's 1.3 m. That is the single
  biggest reason shots go in, and the first dial to reach for if red is now too easy.

## The players are taller than the goal

At `character_scale` 1.95 the rig — which is about 1.85 m at scale 1, not the 1.4 m a pupil would
be — draws roughly **3.6 m tall**, against a 2.2 m goal. So a keeper stands head and shoulders
above his own crossbar.

**This is drawing only.** `checkGoal`, `controlRadius`, `dribbleOffset`, `pressureRadius` and the
ball are all in world units and take no notice of `character_scale`, so the match plays exactly
the same as it did at 1.5 — a measured run at 1.95 finished 3–0 to blue, same as before. What has
changed is that the goals now *look* like toys.

If that wants fixing, the honest fix is to scale the goal with the players rather than to shrink
the players back: at 1.5 the goal was 0.79 player-heights, so keeping that means about
**2.9 m × 8.5 m** in `FootballPitch`. Be aware that is a gameplay change and not a cosmetic one —
a bigger mouth is easier to score into for *both* sides, and `shoot(from:)` aims inside
`goalHalfWidth − ballRadius`, so widening it widens the aim spread too. Rerun the balance table
after.

## Things not built

- **No offside, no throw-ins, no corners, no fouls.** The boards make all four unnecessary.
- **No kick animation.** The ball leaves the boot, the leg does not swing. The rig can do it —
  tennis aims a whole racket arm through `RigOverride` — but a swing that misses the ball by a
  frame looks worse than no swing at all, so it wants doing properly or not at all.
- **No aiming.** A kick goes to the nearest team mate or at the goal. Joel asked for exactly that,
  and it is the right first version; a drag-to-aim pass is the obvious second one.
- **No half time, no clock.** First to three, and that is the whole match.

## Before you can play it on the real server

**`data/maps.json` ships inside the app *and* is read by the server**, and the server decides
whether a map change is allowed. The deployed server does not know about map 6 yet, so on
production `-map 6` is silently refused and you stay where you are. It needs a deploy — which is
Ben's call and costs money (`server/deploy.sh`, red zone, do not run it).

Until then, test against a local server:

```bash
cd server && PORT=8099 node server.js
xcrun simctl launch <udid> com.allr.joelsworld -host localhost:8099 -autojoin Joel -map 6
```

## Balance, measured

Full matches played by `-footballdemo`, which chases the ball, runs at goal and shoots. It is a
worse footballer than a ten-year-old — it never holds a position and never defends — but it is a
*consistent* one, which is what makes it useful.

| Change | Result | Territory (samples in blue's half) |
|---|---|---|
| Before the settle time | red 3–0 | — |
| After settling and point-blank shooting | red 3–1 | — |
| Human moved centre forward → centre midfield | red 3–2, level twice | 82% → roughly even |
| Auto-switching + the bigger pitch | red 3–0, three times | 97 of 102 |
| **After the statue bug** (below) | **blue 3–0, badge claimed** | 29 of 62 |
| Red set to `theOpposition`, blue to `yourLot` | blue 3–0 **in about 50 seconds** | 6 of 19 |

**Everything above the last row was measured on a blue side playing four against five**, because
the demo's player never actually moved — see the statue bug in the section above. Only the last
row means anything, and it says the bot now beats the AI comfortably. That was already the right side of the line for
a badge a ten-year-old is meant to win, and the difficulty settings above then went a good deal
further: **a match is now over in under a minute.** If that turns out to be too quick to be fun,
raise `theOpposition`'s `holdOnToBall` and `keeperReach` first — those two do most of it.

A match takes roughly two to four minutes. **Rerun this if you change anything** — three of the
five rows above turned out to be measuring the harness rather than the game.
