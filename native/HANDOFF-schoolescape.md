# School Escape

Joel's game, from a plan he drew on the night version of the main building map: you got
detention, the school is locked and dark, and there is a chest by the south corridor that
opens with **four keys** — orange (Ms Crosbie's classroom, where you start), white (the
first east classroom), blue (the kitchen), and green, which is in **Mr Hardy's own office**
and slams the door behind you when you take it. Mr Hardy walks the corridors all night. If
he sees you, he chases; if he catches you, you get the jumpscare — camera straight into his
face, the ghostly sting — and he puts you back at the start minus the last key you took.

Open the chest and the **`detention`** badge is yours. That badge had sat on the badge
screen since the web build with nothing able to award it; escaping detention is what it
turned out to mean. It makes five of the ten badges winnable.

```bash
# Play it, no server needed
xcrun simctl launch <device> com.allr.joelsworld -schoolescape

# Watch it play itself, with a line a second of what is happening
xcrun simctl launch --console-pty <device> com.allr.joelsworld \
  -schoolescape -schoolescapedemo -schoolescapetrace
```

## The files

| File | What is in it |
|---|---|
| [SchoolEscapeMap.swift](Engine/World/Minigames/SchoolEscape/SchoolEscapeMap.swift) | Where everything stands: keys, chest, patrol, the office door, and the three `SceneModel`s |
| [SchoolEscapeGame.swift](Engine/World/Minigames/SchoolEscape/SchoolEscapeGame.swift) | The night: Mr Hardy's brain, keys, door, jumpscare, win, camera |
| [SchoolEscapeView.swift](JoelsWorld/UI/Minigames/SchoolEscapeView.swift) | Thumbstick, key counter, banner, chase vignette, jumpscare flash, escape panel |

Plus the usual wiring: map id 8 in `data/maps.json`, `MinigameKind.schoolescape`, a branch in
`GameState.startMinigame`, the view in `GameViewController`, `-schoolescape` in
`GameDebugHarness`, and trigger id 71 in `data/main_building/objects.json` — a rect next to
Ms Crosbie, who gives you the detention.

## The one idea everything else hangs off

**The world is the real main building, not a rebuild.** Five Nights modelled its school out
of boxes; this game stands the overworld's own `walls.glb` on a single textured quad of the
night background (`assets/main_building/night_ground.glb`, built by
`tools/assets/build_escape_ground.py` — rerun it if the night painting changes), and reads
the overworld's own `clip_mask.png` for collision. One consequence does most of the design
work: **the same mask that blocks feet blocks eyes.** `teacherSeesPlayer()` samples a
straight line through the mask every 25 px, so hiding behind a wall genuinely hides you,
and the shut office door blocks sight the same way it blocks walking, with no separate
line-of-sight data to keep in step.

All coordinates are **map pixels**, the same numbers the map editor shows for the main
building — a key can be moved by reading a position off the editor into
`SchoolEscapeMap.keys`.

## Things that cost an afternoon each, so you do not spend yours

- **The clip mask in the game is coarser than the PNG.** `ClipMask` rasterises to one cell
  per 10 world px. A position that looks walkable when you sample the 1396×768 PNG can be
  wall in-game if it is within ~10 px of one. Keep keys and patrol points a character-width
  clear of walls.
- **A wedged AI needs every step of its way out tested.** The corner-escape
  (`openDirection`) originally probed 140 px ahead and froze Mr Hardy solid on a classroom
  corner: the probe point was open, the wall he was standing against was skipped, and he
  drove into it forever while the patrol index span round behind him. It now tests 45/90/140
  px and starts the search from a different direction each attempt.
- **Primitive shapes must not animate their size.** The renderer builds one GPU mesh per
  distinct `ScenePrimitive.Shape`, so the office door *drops from above* rather than growing,
  and the chase ring pulses its opacity, not its radius.
- **The clear colour is sRGB-encoded twice** (see the Five Nights handoff), so
  `backgroundColor` is `#010103` to land on screen as a night sky. `#07070c` came out
  grey-purple.
- **Character size is carried on `width`/`height` (100 and 128 against the 40 baseline), not
  on the map's `character_scale`** — a `startToolScene` launch has no map and would fall back
  to scale 1, so this is what makes `-schoolescape` and the real map 8 look identical.
- **The HUD font has no colour-emoji fallback.** A 🔑 in the key counter drew as a
  question-mark box; it says KEYS now.

## Mr Hardy

Three states — patrol, investigate, chase — in `stepTeacher`:

- **Patrol** walks `SchoolEscapeMap.patrol`, corridor waypoints that follow the corridors
  rather than cutting corners (the south leg goes through the junction at (-1430, 250) for
  exactly that reason).
- **Any key pickup sends him to it** — keys make noise. The green key instead sends him to
  his own office door, which you are locked behind.
- **Chase** needs line of sight inside `Tuning.sightRange`, leads the runner by a quarter
  second (football's trick), and gives up to *investigate your last position* after
  `loseSightAfter` seconds unseen. Chase speed 366 against your 400: you can outrun him,
  you cannot stop.

The sounds carry the states: ticking clock while he patrols, **`siren_head.mp3` replaces
the background the moment he sees you** (swapping the background track is what makes it
stop cleanly when he loses you), `ghostly.mp3` slowed to 0.7 for the catch itself. Both
new files came from Joel's downloads.

Being caught costs **the last key you picked up** and a walk back from the spawn — enough
to sting, not enough to end a run. `timesCaught` is reported on the escape panel, and best
time is `schoolescape.best` in `UserDefaults`.

## The deer thing

`assets/models/deer_thing.glb` is a Sketchfab model Joel supplied (30 MB → 6.5 MB through
`tools/assets/optimise_glb.py` at a 512 px texture cap). It stands in Mr Hardy's office
watching the green key. If it looks wrong, its placement is one transform in
`SchoolEscapeMap.sceneModels`.

## Before anyone but a developer can play it

Same as Five Nights and Football: **the server keeps its own `data/maps.json` and rejects
maps it has never heard of.** Map 8 and trigger 71 need `server/deploy.sh` — Ben's call,
costs money, never run it yourself. Until then `-schoolescape` is the way in.
