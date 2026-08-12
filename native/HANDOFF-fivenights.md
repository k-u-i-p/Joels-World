# Five Nights at St Peters

Joel's idea: FNAF, but at school, and **nobody gets hurt** — you are the night security guard and
the children are trying to *escape*. You block the doors. If one gets past you the school is a
pupil short in the morning and the night is lost. Survive 12 AM → 6 AM five nights running and
the **`five nights`** badge is yours.

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
through all seven cameras, three seconds each, then the lights and the doors — `simctl` cannot
press a button, so that is the only way to photograph a feed.

## The rules that make it a game

- **A child you are watching does not move.** The monitor is not just information; pointing it at
  somebody freezes them. It also burns power like a shut door, which is why you cannot leave it up.
- **Sneaky Sam is the opposite.** He charges whenever nobody is looking at the playground and then
  runs. The only thing that holds him back is checking CAM 6.
- **A shut door buys distance, not safety.** A child who finds one shut waits three seconds, bangs
  on it, and goes back two rooms.
- **Balloon Barry is meant to get in.** He is the fifth child and the only one who does not end the
  night: he sits on the desk, laughs, and takes both doorway lights away for twenty seconds while
  the other four keep coming.
- **Everything costs power.** Doing nothing uses about a third of a night; two doors and the camera
  runs you dry just before 5 AM. `FiveNightsGame.Tuning` holds all of it.

Nights get harder through `aggressionByNight`, `breachWindowByNight` and `sprintChargeByNight` —
three tables, one row per night. Tuning the difficulty means editing those and nothing else. The
furthest night survived is remembered in `UserDefaults` (`fivenights.survived`), so you start on
the night after your best.

## Two things about the rendering worth knowing before you change it

**Every room is a dollhouse.** The camera in this engine orbits a focus point and looks at it from
above; it cannot sit inside a room at head height, because the eye would end up outside the
building looking at the back of a wall. So each room has full-height walls on its three far sides
and an ankle-high rail on the side the camera looks from. That is also why the office view shows
you both doorways at once instead of swivelling.

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
