# Joel's World

Welcome to **Joel's World**, a persistent, multiplayer top-down RPG map experience! This is a "vibe-coded" game focused on providing a smooth, responsive, and seamless interactive environment for players to hang out, explore, and chat.

## Features
- **Seamless Map Generation & Transitions:** Explore entirely different environments (School Grounds, Detention, Main Building, and the Pool) without ever dropping your WebSocket connection. Map scaling, collision data, and NPCs stream dynamically!
- **Zero-Allocation Movement Loop:** The client-side chunk updates and trigonometric rendering routines have been hyper-optimized with broad-phase AABB collision checks, enabling dozens of characters to render side-by-side perfectly on mobile and desktop without GC stutter.
- **Vibe Emotes:** Break out into dances, cry, roll on the floor laughing, or even swim in the new pool map using a physics-driven, canvas-rendered emote system!
- **Event Callbacks:** Everything is interactive. Walk into trigger zones to teleport across maps, trigger sound effects, prompt question dialogs, or alter the world state through an interconnected JSON event tree.

## Installation

```bash
# Install dependencies
npm install

# Run the WebSocket server and Vite client locally
npm run dev
```

Navigate to `http://localhost:5173` to join the world!
