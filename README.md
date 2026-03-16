# Joel's World

Welcome to **Joel's World**, a persistent, multiplayer top-down RPG map experience! This is a "vibe-coded" game focused on providing a smooth, responsive, and seamless interactive environment for players to hang out, explore, and chat.

## Features
- **Seamless Map Generation & Transitions:** Explore entirely different environments (Junior School, Detention, Main Building, and the Pool) without ever dropping your WebSocket connection. Map scaling, collision data, and NPCs stream dynamically!
- **Zero-Allocation Movement Loop:** The client-side chunk updates and trigonometric rendering routines have been hyper-optimized with broad-phase AABB collision checks, enabling dozens of characters to render side-by-side perfectly on mobile and desktop without GC stutter.
- **Vibe Emotes:** Break out into dances, cry, roll on the floor laughing, or even swim in the new pool map using a physics-driven, canvas-rendered emote system!
- **Event Callbacks:** Everything is interactive. Walk into trigger zones to teleport across maps, trigger sound effects, prompt question dialogs, or alter the world state through an interconnected JSON event tree.

## Installation

```bash
# Install dependencies
npm install

# Run the WebSocket server and Express client locally
npm run dev
```

Navigate to `http://localhost:5173` to join the world!

---

## Game Architecture 

Joel's World has been recently refactored to prioritize high-performance frame rates and smooth network synchronization.

### 1D Array Chunk Generation
The old canvas rendering system allocated massive objects and string dictionaries for drawing individual grid chunks. The game now pre-calculates map grids into a tightly-packed 1D Array, utilizing bitwise math to fetch rendering references directly. This ensures that even on the largest map ("Junior Campus"), the Javascript Garbage Collector is rarely invoked during movement.

### Map Layering
Environments are split into layered depths (`background`, `trees+overlay`, `foreground`). The renderer iterates over a `window.mapLayers` array, rendering characters at precise z-indexes to allow them to visually walk "behind" structures, trees, and other obstacles without requiring heavy real-time masking.

### Stateless Server Synchronization
The Node.js server acts strictly as a low-latency broadcaster. It does not tick an internal physics loop. It maintains a dictionary of connected `player_id`s and relays their calculated `x/y` coordinates, `rotation`, and active `emotes` across the WebSocket buffer to all clients concurrently.

---

## JSON Data Formats

The game world is governed by three primary descriptive JSON files for each map located in `server/data/[map_name]/`.

### 1. `maps.json`
The master file dictating the available explorable spaces and their visual properties.
- **`id`**: Unique identifier for the map.
- **`name`**: The display name of the map.
- **`width` / `height`**: The absolute dimensions of the map in pixels.
- **`layers`**: A 2D array representing layered arrays of background textures. The first dimension separates depths (e.g., floor vs trees), and the second dimension contains the chunk definition objects (defining `alpha`, `source_image`, `chunk_size`, rendering `grid_w`/`grid_h`, and `path_template` for pre-split chunk fetching).
- **`clip_mask`**: Optional path to an SVG/PNG to use as a global, pixel-perfect solid boundary.
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
- **`hairStyle`**: Modifies the hair rendering pass (`bald`, `long`, `ponytail`, `short`, `messy`, `spiky`).
- **`hairColor` / `shirtColor` / `pantsColor` / `shoeColor`**: Hex color codes for the different respective clothing/body rendering passes.
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