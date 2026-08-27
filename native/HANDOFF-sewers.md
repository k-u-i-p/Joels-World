# The Sewers — the /flush secret

Joel's idea: stand in the main building **Toilets** and type **`/flush`** in chat, and you
are teleported to a secret sewer world under the school. This branch
(`sandbox/sewer-world`) is the whole of it.

## How it works

- **The command** — `submitChat` in
  [GameViewController.swift](JoelsWorld/App/GameViewController.swift) checks for `flush`
  before the emote table. It only fires when `player.activeBuilding` is a zone named
  `Toilets` (there are two, both in `data/main_building/objects.json`); anywhere else it
  logs and stays quiet, which is what keeps it a secret. It plays
  `media/toilet_flush.mp3` (Joel's own sound) and sends the same `sendChangeMap` the
  yes/no door dialogs send — map **9**.

- **The map** — id 9, "The Sewers", in `data/maps.json`. No ground image: like Detention
  it is a `background_color` plus an extruded 3D room. The plan is
  [data/sewers/room.json](../data/sewers/room.json) —
  `python3 tools/maps/extrude_room.py data/sewers/room.json` regenerates
  `assets/sewers/room.glb` + `clip_mask.png` together. One chamber with a green water
  channel, a dead-end tunnel north, a ladder room east. The ladder zone offers the
  change-map dialog back to the Main Building (map 2).

- **The props** — from a bought pack in Ben's Downloads (`~/Downloads/Sewer`, .blend +
  textures). Exported per-prop to `assets/models/sewers/*.glb` with Blender headless;
  the pack's image links were broken, so the export script re-points every image at the
  pack's `Textures/` folder first (script preserved in the session scratchpad, easily
  rewritten: open blend, relink images by basename, per-object apply transforms, floor
  the bbox, export selection as GLB).

- **The rat** — `rat_multi_animations_textured.glb` was a *skinned* model, and
  `PropRenderer` draws only static meshes (it loaded as "0 primitives"). It is baked to
  a statue: armature driven to `IdelAnimation` frame 10, meshes converted, armature
  deleted, re-exported without animations (29 MB → 1.4 MB). Deliberately huge at scale
  100 — it's a boss rat.

- **Staging** — `tools/assets/stage.sh` now lists `sewers` in `MAP_DIRS`, and a map
  directory without `chunks/` is allowed for `sewers` only (it has no ground tiles to
  stage). Everything else (models, media, data JSON) staged already.

- **NPC** — Gurgle (`data/sewers/npc.json`), simple `say` lines, no AI agent.

## What is tested

Built and run on the iPhone 17 simulator against a **local server** (`PORT=8321 node
server.js`, app launched with `-host localhost:8321 -autojoin Joel -map 9`). Verified by
screenshot: room, walls, water, props, rat, Gurgle, spawn. The server-side map change to
9 works (that is how the test run gets there), so the `/flush` teleport uses a proven
path — but nobody has yet *typed* `/flush` in the chat box on a device; that last link is
untested.

## What still needs Ben

- **Deploy** — the production server needs the new `data/` before anyone can actually
  enter map 9 (same situation as Five Nights / School Escape).
- **On-enter sound** — Joel vetoed `ghostly.mp3`, so arriving is currently silent; the
  `on_enter` block on map 9 is the place to put whatever he picks.
- No badge is awarded yet. If the sewers should feed the badge loop, that's a design
  conversation with Joel.
