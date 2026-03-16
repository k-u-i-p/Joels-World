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
```json
{
  "id": 0,
  "name": "Junior Campus",
  "width": 4372,
  "height": 3840,
  "layers": [
    [
      {
        "alpha": 1, 
        "chunked": true, 
        "source_image": "/junior_school/background.png",
        "chunk_size": 512,
        "grid_w": 9,
        "grid_h": 8,
        "path_template": "/junior_school/chunks/background_{x}_{y}.png"
      }
    ]
  ],
  "clip_mask": "junior_school/clip_mask.svg", // Optional vector/png solid boundary
  "npcs": "junior_school/npc.json", // Reference to the NPC file
  "objects": "junior_school/objects.json", // Reference to the zones/collision file
  "character_scale": 1.5,
  "default_zoom": 1.0,
  "spawn_area": 19, // Object ID to drop the player into upon connection
  "can_leave": true, 
  "on_enter": [
    { "play_sound": { "sound": "media/music.mp3", "volume": 0.3 } }
  ]
}
```

### 2. `npc.json`
Defines the AI, interactive characters, and standard wandering NPCs for the specific map.
```json
{
  "id": 1,
  "name": "Mr Hardy",
  "x": -869,
  "y": -389,
  "width": 52,
  "height": 58,
  "rotation": 140,
  "gender": "male", // Determines the body/face sprite base
  "hairStyle": "messy", // Modifies the rendering style (bald, long, ponytail, short, messy)
  "shirtColor": "#1c2833",
  "pantsColor": "#2c3e50",
  "interaction_radius": 150, // How close the player must be to trigger on_enter
  "roam_radius": 300, // Optional: Range they will randomly wander
  "waypoints": [
    { "x": 50, "y": 150, "move_time": 3000 }, // Optional: specific patrol route
    { "rotation": 120, "move_time": 1000 }
  ],
  "on_enter": [
    {
      "avatar": "avatars/mr_hardy.png", // Optional UI popup portrait
      "say": [
        "Hello {name}, I'm Mr Hardy",
        "Two schools are better than three!"
      ],
      "log": { // Optional event logging (for AI history)
        "message": "{name} ({player_id}) approached {npc_name}",
        "rate_limit": 60
      }
    }
  ],
  "agent": { // Optional: Connects the character to the LLM backend
    "log_file": "junior_school/agent_mr_hardy_logs.txt",
    "prompt_file": "junior_school/agent_mr_hardy.md"
  }
}
```

### 3. `objects.json`
Defines invisible structural barriers and interactive trigger zones scattered across the map.
```json
{
  "id": 12,
  "name": "Pool Entrance",
  "shape": "rect",
  "x": -2095, "y": -1254,
  "width": 759, "length": 202,
  "rotation": 90,
  "clip": -1, // -1 means solid collision. 50+ means a walkable zone
  "on_enter": [
    {
      "show_dialog": {
        "type": "change_map",
        "map": 3, 
        "description": "Do you want to enter the Pool building?"
      }
    }
  ],
  "on_exit": [
    { "clear_emote": true } // Event to trigger upon leaving the zone's AABB
  ]
}
```