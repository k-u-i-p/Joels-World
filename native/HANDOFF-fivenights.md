# Five Nights at St Peters

Joel's idea: FNAF, but at school, and **nobody gets hurt** — you are the night security guard and
the children are trying to *escape*. Survive 12 AM → 6 AM five nights running and the
**`five nights`** badge is yours.

**There is one door.** It is the school's front entrance, at the end of the main entrance hall,
and you watch it on **CAM 7**. No office doors, no lights, no torch. When a child steps up to it
you have **seven seconds** to get the shutter down; miss it and they are out and the night is
lost. That is Joel's rule and the `Tuning.exitWait` constant is literally his number.

Three files, plus the usual six lines of wiring:

| File | What it is |
|---|---|
| [FiveNightsGame.swift](Engine/World/Minigames/FiveNights/FiveNightsGame.swift) | The night: children, doors, power, clock |
| [FiveNightsSchool.swift](Engine/World/Minigames/FiveNights/FiveNightsSchool.swift) | The building — every box and where it stands |
| [FiveNightsView.swift](JoelsWorld/UI/Minigames/FiveNightsView.swift) | The security desk: clock, power, buttons, monitor |

Wired in exactly where School Rush and Football are: `MinigameKind.fivenights`, a case in
`GameState.startMinigame`, a view on `GameViewController`, a badge row in `MenuDialogs.swift`,
map id 7 in `data/maps.json`, and a trigger (`id 92`) on the junior campus.

## How to play it right now

**The trigger on the campus will not work until the server is redeployed** — see "The one thing
left" below. Until then:

```bash
xcrun simctl launch <device> com.allr.joelsworld -fivenights
```

`-fivenights` starts the night with no socket, no lobby and no map, through the same
`GameState.startToolScene` door the character lab uses. Add `-fivenightsdemo` and it flips
through all seven cameras, three seconds each, then the office, then drops the shutter and looks
at it — `simctl` cannot press a button, so that is the only way to photograph a feed.

## The rules that make it a game

- **Two buttons.** The shutter over the front door, and the monitor. Everything else on screen is
  information.
- **A child you are watching does not move.** The monitor is not just information; pointing it at
  somebody freezes them where they stand — including in the entrance hall, one step from the door.
  It also burns power like the shutter does, which is why you cannot leave it up.
- **Sneaky Sam is the opposite.** He charges whenever nobody is looking at the playground and then
  goes straight for the entrance. Checking CAM 6 is the only brake.
- **A shut door buys distance, not safety.** A child who finds it shut waits three seconds, bangs
  on it, and goes back two rooms.
- **Balloon Barry is meant to get in.** He is the fifth child and the only one who does not end the
  night: he walks into the office, pulls the camera fuse, and for fifteen seconds you have no
  monitor at all while the other four keep walking.
- **Everything costs power.** Doing nothing uses about a third of a night; the shutter and the
  monitor together run you dry at about 4 AM. `FiveNightsGame.Tuning` holds all of it.
- **The seven seconds are never shown for free.** Arriving at the door bangs it and puts a banner
  up, so you always know somebody is there. The *countdown* only appears while the monitor is
  pointed at CAM 7 — that is what makes spending the power to look worth it.

Nights get harder through `aggressionByNight` and `sprintChargeByNight` — two tables, one row per
night. The seven seconds never change. Tuning the difficulty means editing those and nothing else.
The furthest night survived is remembered in `UserDefaults` (`fivenights.survived`), so you start on
the night after your best.

## Two things about the rendering worth knowing before you change it

**Every room is a dollhouse.** The camera in this engine orbits a focus point and looks at it from
above; it cannot sit inside a room at head height, because the eye would end up outside the
building looking at the back of a wall. So each room has full-height walls on its three far sides
and an ankle-high rail on the side the camera looks from.

**Which is why the front doors are in the far wall and the shutter hangs on its inside face.**
Every camera looks down −Y, so anything in a north-south wall is edge-on: the first version put the
doors in the end wall and they came out as a two-pixel sliver, and the shutter behind them was
invisible entirely — the button said DOOR SHUT and the picture said nothing. Both are now square to
the camera. If you move that door, keep it facing south.

**`Camera.update`'s headroom bias has to be cancelled.** It shifts focus up the screen by 15% of
the visible height so a followed player has room to see ahead. Nothing is followed here — the
subject is a room — and on a phone that bias is five metres, which put the office at the bottom of
the frame and the assembly hall in the middle of it. `updateCamera` adds it back.

And one trap: the **clear colour is encoded to sRGB twice** (`Renderer` does it by hand, then the
drawable does it again), so `FiveNightsSchool.nightHex` is `#010103` to land on screen at about
`#0a0a12`. Do not "fix" it by reading it as a colour — check it on a device.

## Where the look came from

Joel sent reference for an abandoned school: green fire doors, rusted lockers in four colours, a
chalkboard nobody washed, smashed chairs, tiled toilets, a crashed bus. Everything in
`FiveNightsSchool` follows it. Two of them are real models rather than boxes — `crashedBus` and
`playgroundModel`, both already in `assets/models/` and both scaled by copying a placement that
already looked right. The rest is boxes and a deterministic decay pass (damp, fallen ceiling
tiles, rubble, broken chairs) seeded per room so the mess never moves between camera cuts.

**If more models arrive**, that is the cheap way to improve this: add a `SceneModel` to
`FiveNightsGame.sceneModels` and delete the boxes it replaces.

## The one thing left

`data/maps.json` ships **inside the app**, but the server keeps its own copy and will not let a
client onto a map it has never heard of. Map 7 therefore needs `server/deploy.sh` running before
the door on the junior campus works — which costs money and is Ben's call, not something to run
from here. Everything else is done and checked in the simulator.
