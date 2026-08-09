# Joel's World

Welcome to **Joel's World**, a persistent, multiplayer top-down RPG map experience! This is a "vibe-coded" game focused on providing a smooth, responsive, and seamless interactive environment for players to hang out, explore, and chat.

## Features
- **Seamless Map Generation & Transitions:** Explore entirely different environments (Junior School, Detention, Main Building, and the Pool) without ever dropping your WebSocket connection. Map scaling, collision data, and NPCs stream dynamically!
- **Vibe Emotes:** Break out into dances, cry, roll on the floor laughing, or even swim in the new pool map — twenty emotes, each posing the character rig and spawning its own props.
- **Event Callbacks:** Everything is interactive. Walk into trigger zones to teleport across maps, trigger sound effects, prompt question dialogs, or alter the world state through an interconnected JSON event tree.

## Layout

| Directory | What it is |
|---|---|
| `server/` | The Node WebSocket server, plus its Cloud Run scripts (`deploy.sh`, `stream_logs.sh`). Two dependencies: `ws`, and `@anthropic-ai/sdk` for the NPC agents |
| `data/` | The authored world — `maps.json`, and each map's `objects.json` and `npc.json`. Read by the server, bundled into the apps, edited by the macOS editor |
| `assets/` | Art and audio. A working tree: the full-size map layers are slicer input, and the apps ship only what `tools/assets/stage.sh` selects |
| `native/` | Swift. `Engine/` is the shared game engine, `JoelsWorld/` the iOS game, `JoelsWorldAdmin/` the macOS map editor, `CharacterLab/` the macOS character lab, `MacShared/` the AppKit bits the two Mac apps share |
| `tools/assets/` | The offline asset pipeline — slicing, overlays, minimaps — and the staging script the Xcode builds run |

Inside `native/`, each target is grouped by role: `Engine/` splits into `Core` `Net` `Entity`
`Render` `World` `UI`, the iOS app into `App` `UI` `Input` `Audio`, the editor into `App`
`Data` `Editor` `Inspector`, and the lab into `App` `Scene` `UI`. Every one of those is a
file-system-synchronised Xcode group, so a new file in any of those directories is in the build
with no project edit.

Three targets share them: `JoelsWorld` takes `Engine` + `JoelsWorld`, `JoelsWorldAdmin` takes
`Engine` + `JoelsWorldAdmin` + `MacShared`, and `CharacterLab` takes `Engine` + `CharacterLab` +
`MacShared`.

`Engine/UI` holds no views — UIKit and AppKit share no view type, so the two apps' chrome
cannot be one file. What it holds is the *rules* the two copies must agree on
(`PendingDialog`, `PortraitOwner`) and the policy they share (`AssetImageCache`), so a change
lands once rather than twice.

The browser client was retired in favour of the native apps — see `native/PROGRESS.md`.

## What the server does, and does not

It is a WebSocket relay and nothing else. It serves no assets and no world: both ship inside
the apps. The only HTTP it answers is a health check on `/`.

Over the socket it sends who else is on your map and what they are doing, plus
`objects_update` / `npcs_update` when it notices a `data/` file change on disk. Sessions are
unchanged — the token you present on the handshake is what resumes your character.

## Running the server

```bash
cd server && npm install && npm run dev
```

It binds port 80 unless `PORT` is set. Point an app at it with `-host 127.0.0.1:80` on the
launch arguments, or by setting `Config.useLocalServer` in `native/Engine/Core/Config.swift`.

## Building the assets

The apps bundle ~155 MB of art. The map tiles in it are generated, not committed, so a fresh
checkout needs one pass before Xcode can stage them:

```bash
cd tools/assets && npm install && npm run build
```

That slices the full-size layers into chunks, derives the clip-mask overlays and generates the
minimaps. It is only needed again when a source layer changes.

## Building the apps

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorldAdmin -destination 'platform=macOS' build
```

Each build runs `tools/assets/stage.sh`, which copies `assets/` and `data/` into the app.

The map editor writes `data/**/objects.json` and `npc.json` directly. An ordinary build opens
the checkout it was built from — the build records that path in the app — and `-data <path>`
overrides it, which is what a scripted run should use:

```bash
"Joels World Map Editor.app/Contents/MacOS/Joels World Map Editor" -data "$PWD/data" -host 127.0.0.1:80
```

A server running against the same checkout notices the write and broadcasts the change to
everyone connected, editor included. There is no admin key any more — the editor's connection
is an ordinary one, and exists only to show live players on the map being edited.

### The character lab

The third app in the project — its own target and scheme — is a character lab: one pupil on a metre
grid, no server, every gait and every emote as a named take, and a scrubbable clock. It is where
character, clothing, animation and movement work gets looked at, because the game's own cameras are
too far away and too near-overhead to show a knee or a collar.

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
"Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
```

It also writes what it shows, which is how a change gets checked without a person at the keyboard —
a captioned filmstrip spanning one stride, a contact sheet of every take, the numbers split
into its channels, or a JSON table of foot contact and hip bounce:

```bash
"Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab" -labtake run -labsheet /tmp/run.png
```

The clock is pinned while the lab is up, so the same frame comes out the same every run.
[native/HANDOFF-character-lab.md](native/HANDOFF-character-lab.md) has the whole flag set.

---

## Game Architecture

### Map Layering
Environments are split into layered depths (`background`, `trees+overlay`, `foreground`). The renderer draws each layer at its own Z, so characters visually walk "behind" structures, trees, and other obstacles without requiring heavy real-time masking.

### Physics
`native/Engine/World/Physics.swift` owns collision, wall sliding, clip masks and proximity
interactions. It began as a port of the server's `physics.js`, which the retired browser
client shared; since the clients simulate their own movement and the server only relays the
result, that copy had nothing left calling it and is gone. All the server still asks of the
world is which NPCs a player is standing near, which is `server/proximity.js`.

### Stateless Server Synchronization
The Node.js server acts strictly as a low-latency broadcaster. It does not tick an internal physics loop. It maintains a dictionary of connected `player_id`s and relays their calculated `x/y` coordinates, `rotation`, and active `emotes` across the WebSocket buffer to all clients concurrently.

The `init` frame it sends is three fields — `mapId`, `characters`, `myCharacter`. The map, the
map list, the objects and the NPCs used to ride along with it; they ship in the app now, and
`mapId` is what selects them.

---

## JSON Data Formats

The game world is governed by three primary descriptive JSON files for each map located in `data/[map_name]/`.

### 1. `maps.json`
The master file dictating the available explorable spaces and their visual properties.
- **`id`**: Unique identifier for the map.
- **`name`**: The display name of the map.
- **`width` / `height`**: The absolute dimensions of the map in pixels.
- **`layers`**: A 2D array representing layered arrays of background textures. The first dimension separates depths (e.g., floor vs trees), and the second dimension contains the chunk definition objects (defining `alpha`, `source_image`, `chunk_size`, rendering `grid_w`/`grid_h`, and `path_template` for pre-split chunk fetching).
- **`clip_mask`**: Optional path to an SVG/PNG to use as a global, pixel-perfect collision mask. Players can only walk/clip through pure white (`RGB 255,255,255`) or pure green (`RGB 0,255,0`) pixels; all other colors act as solid boundaries.
- **`npcs` / `objects`**: Path pointers mapping to the respective data configurations for this specific map.
- **`character_scale` / `default_zoom`**: Multipliers adjusting how large entities and the viewport appear natively.
- **`spawn_area`**: The ID of an object (from the `objects.json`) dictating where the player should spawn.
- **`can_leave`**: Boolean flag indicating if the map allows transition exits.
- **`on_enter`**: An array of event hooks triggered as soon as the map loads (e.g., initiating background music via `play_sound`).

### 2. `npc.json`
Defines the AI, interactive characters, and standard wandering NPCs for the specific map.
- **`id`**: Unique identifier for the character.
- **`name`**: The display name appearing on their name tag.
- **`x` / `y`**: The starting coordinates.
- **`width` / `height`**: Base physical dimensions of their sprite.
- **`rotation`**: Initial rotation in degrees.
- **`gender`**: Defines the body and face rendering type (`male` or `female`).
- **`head`**: Modifies the hair rendering pass (`bald`, `long`, `ponytail`, `short`, `messy`, `spiky`).
- **`hair_color` / `shirt_color` / `pants_color` / `shoe_color`**: Hex color codes for the different respective clothing/body rendering passes.
- **`interaction_radius`**: How close the player must be to trigger the character's `on_enter` event array.
- **`roam_radius`**: (Optional) Pixel radius around their starting point they are allowed to randomly wander.
- **`waypoints`**: (Optional) Array of objects dictating a sequential patrol route. The `x`, `y`, and `rotation` values in these objects are **relative offsets/deltas** applied consecutively from the character's original spawn coordinates, not absolute global map positions. Also takes a `move_time` in milliseconds.
- **`on_enter` / `on_exit`**: Triggered when the player physically walks up to the character or leaves their radius. Often used to trigger speech dialog (`say`), logging events (`log`), or rendering a UI pop-up `avatar`.
- **`agent`**: (Optional) Connects the character to the server-side LLM backend (requiring a `prompt_file` and `log_file`).
- **`emoji`**: (Optional) Overrides the 3D model entirely and renders an emoji character instead.

### 3. `objects.json`
Defines invisible structural barriers and interactive trigger zones scattered across the map.
- **`id`**: Unique identifier.
- **`name`**: (Optional) Readable internal name.
- **`shape`**: Defines the hitbox type (usually `rect`).
- **`x` / `y`**: Coordinates defining the center of the bounding box.
- **`width` / `length`**: Depth and length of the bounding box.
- **`rotation`**: Rotation of the bounding box in degrees.
- **`clip`**: Allows characters to clip into the bounding box slightly by the given amount in pixels. `0` denotes a completely solid, impenetrable obstacle. `-1` denotes a trigger zone that the player can walk through entirely without collision.
- **`on_enter` / `on_exit`**: Event hook pools triggered when the player's collision bounds physically enter or leave the object's area. Used for teleporting maps (`show_dialog` with `change_map`), playing sounds, or applying status effects.