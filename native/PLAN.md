# Joel's World — Native iOS Rewrite

Full Swift rewrite of the game client. The Capacitor shell and the web client
(`client/`) are retired at the end of this effort; the iOS app becomes the only client.
The Node server in `server/` stays as the multiplayer backend.

---

## 1. What is being replaced

The existing client is ~10k lines of JavaScript:

| Area | File | Lines | Notes |
|---|---|---|---|
| Bootstrap, camera, main loop | `client/public/src/main.js` | 845 | three.js scene, SSAO composer, camera orbit, spring |
| Character rendering | `client/public/src/characters.js` | 1406 | Procedural rig, 2-bone IK, GLB heads/shoes, clip-mask shader |
| Admin tooling | `client/public/src/admin.js` | 1464 | Object/NPC editor — **out of scope**, see §7 |
| Tennis minigame | `client/public/src/minigames/tennis.js` | 2160 | 2D canvas game |
| Emotes | `client/public/src/emotes.js` | 914 | 20 emotes, each poses the 3D rig |
| Tag minigame | `client/public/src/minigames/tag.js` | 591 | |
| Physics | `client/public/src/physics.js` | 594 | Collision, clip mask, interpolation |
| Network | `client/public/src/network.js` | 410 | WebSocket protocol |
| Map streaming | `client/public/src/maps.js` | 386 | Chunked layers, GLB props |
| UI | `client/public/src/ui.js` + `index.html` + `style.css` | 390 + 247 | DOM overlays |
| Sound | `client/public/src/sound.js` | 258 | WebAudio + Capacitor NativeAudio |
| Events | `client/public/src/events.js` | 212 | JSON event tree interpreter |
| Input | `client/public/src/input.js` | 226 | Tank controls + touch joystick |

Capacitor itself is shallow — 3 plugins over ~10 call sites — and disappears with the web layer.

## 2. Renderer choice

The decision that constrains everything else. Three candidates were considered against
what the current renderer actually does:

1. Chunked textured quads streamed by camera frustum, explicit per-layer Z ordering
2. Static GLB props with **per-node material overrides matched by node name**
   (`name.includes('hair')` → hair material)
3. Procedural character rigs — capsules/spheres/boxes posed every frame by a 2-bone IK solver,
   with custom tapered geometry
4. A **raymarched clip-mask `discard`** injected into the fragment shader (`characters.js:361`)
5. Spotlight + PCF soft shadows, and an SSAO post-process pass
6. A deliberately flat look — `MeshBasicMaterial` for overlays, `MeshLambertMaterial` for ground

| Option | Verdict |
|---|---|
| **SceneKit** | Closest 1:1 map to three.js — `SCNNode` graph, `SCNShadable` shader modifiers are almost exactly three.js `onBeforeCompile`, `SCNTechnique` covers SSAO. Fastest route to parity. **But** Apple has signalled RealityKit as the forward path and SceneKit receives no new features. (Checked: it is *not* API-deprecated in the iOS 27 SDK — only the usual legacy symbols in `SceneKitDeprecated.h`.) Staking a multi-month rewrite on a maintenance-mode framework is the risk. |
| **RealityKit** | Apple's forward path, but a poor fit here: USDZ-only assets, a PBR-opinionated renderer that fights the flat look, and an opaque draw-order model — this game needs explicit layer Z and `renderOrder` control. Shader work goes through `CustomMaterial`. |
| **Metal (chosen)** | Full control, no framework risk, and the rendering needs are genuinely narrow — textured quads plus simply-lit static meshes. The existing GLSL clip-mask shader ports to MSL near 1:1. Cost is that shadow mapping, SSAO and glTF parsing are hand-written. |

**Chosen: Metal + a thin purpose-built renderer.**

The deciding factor is that no mesh *skinning* is required — characters are procedural rigs
of primitives, and heads/shoes/props are static meshes. That removes the single most
expensive part of writing a renderer and makes the glTF loader a bounded problem
(JSON + binary accessors, no animation, no skins).

**Confirmed in Phase 2** by scanning all 40 shipping `.glb` files: `skins=0 anims=0
morphTargets=0 sparseAccessors=0`, every primitive mode 4. The loader came in at ~430 lines.
Re-run that scan before adding any new model.

**Phase 3 settled the question — parity did not stall.** The hand-written renderer lands
within 3.5% mean pixel difference of the web build on a real frame. SceneKit is no longer
the fallback it was; the `Net`/`World`/`Entity` layers stay Metal-free anyway, so the door
remains open at no cost.

### 2.1 Colour pipeline (established in Phase 3)

Everything shades in **linear** space and encodes once on presentation, matching three.js with
`ColorManagement` enabled (verified on the live client: working space `srgb-linear`,
`outputColorSpace` `srgb`, `toneMapping` `NoToneMapping`):

- hex colours are linearised on parse (`parseHexColor`)
- tile and glTF base-colour textures load with `.SRGB: true` and decode on sample
- render targets are `bgra8Unorm_srgb`, so the hardware applies the single encode
- glTF `baseColorFactor` is already linear per spec and is **not** converted

The one exception is the background clear colour, which the web build encodes twice; it is
pre-encoded on the CPU to match. See `PROGRESS.md`.

## 3. Coordinate system

Preserved exactly from the JS so all gameplay constants, map JSON and server payloads carry over
without adjustment:

- World space is **X right, Y down** (HTML5 canvas convention). Map origin is the map centre.
- Render space negates Y: a world point `(x, y, z)` is drawn at `(x, -y, z)`. **Z is up.**
- Rotations are **degrees**, clockwise, 0° = +X.
- Camera is perspective, 30° FOV, near 1 / far 2000, orbiting the player at
  `distance = viewportHeight / (2·tan(fov/2))` with `up = (0,0,1)` — see `main.js:590-620`.

## 4. Module map

```
native/JoelsWorld/
  App/        AppDelegate, GameViewController (MTKView host), GameLoop
  Core/       Math (float4x4 helpers), Color, Log
  Net/        NetworkClient (URLSessionWebSocketTask), Protocol (Codable), SessionStore
  World/      GameState, MapManager, Physics, ClipMask, EventInterpreter, NPCBehaviour
  Render/     Renderer, Camera, TextureCache, ChunkLayer, Shaders.metal, GLTFLoader
  Entity/     CharacterRig, IKSolver, Emotes, EmoteProps
  World/Minigames/  Minigame (the map-`import` handover), TennisGame
  Input/      Joystick, KeyboardInput
  UI/         Lobby, Chat, Nameplates, Dialogs (UIKit over the Metal layer),
              Canvas2D + Character2D + Minigames/TennisView (the 2D surface tennis draws on),
              EmojiImage (bundled-SVG fallback where the platform cannot draw emoji)
  Audio/      SoundManager (AVAudioEngine)
```

Renderer-agnostic layers (`Net`, `World`, `Entity` logic, `Input`) hold no Metal types,
so they stay testable and portable if the renderer choice is revisited.

## 5. Asset pipeline

264 MB of assets today, served over HTTP by the Node server:

| Asset | Size | Plan |
|---|---|---|
| Map chunk tiles (`junior_school`, `main_building`, `pool`, `detention`) | 137 MB | **Keep server-fetched**, streamed per chunk with an on-disk `URLCache`. Bundling them would bloat the app for tiles most players never see. |
| `models/` GLB (props, heads, shoes, torso) | 104 MB | **Bundle.** Needed immediately at spawn; loading them over the network is the current startup bottleneck. Compress with Draco/meshopt during the port. |
| `media/` audio | 11 MB | **Bundle.** |
| `avatars/`, `minimaps/`, `icons/`, `fonts/` | ~1.4 MB | **Bundle.** |

Map/NPC/object JSON continues to arrive in the `init` WebSocket payload — no change.

Two additions from Phase 7:

- `minigames/tennis/map.svg` (2.4 MB) is fetched and rasterised on the device through
  `SVGRasterizer`, because iOS has no SVG decoder. `SVGImage` checks `Bundle.main` first, so
  pre-rasterising it to a PNG at build time is a packaging change with no code change.
- `Resources/emoji/` — 23 Twemoji SVGs, 104 KB, **CC-BY 4.0**. A fallback only: used where the
  platform cannot draw a colour emoji, which today means the simulator. See
  `Resources/emoji/ATTRIBUTION.txt`.

## 6. Network protocol (unchanged)

`wss://joels-world.com?state=<new|running>&token=<session>`

Client → server: `create_character`, `update`, `chat`
Server → client: `init`, `session_token`, `tick`, `update`, `chat`, `disconnect`,
`objects_update`, `npcs_update`, `badge_earned`, `map_change_rejected`, `error`

The session token moves from Capacitor `Preferences` to the **Keychain**.

## 7. Phased roadmap

| Phase | Scope | Status |
|---|---|---|
| **1. Vertical slice** | Xcode project, Metal renderer, chunked map streaming, camera, physics port, WebSocket client, joystick movement, placeholder player capsule | **done** |
| **2. Characters** | glTF loader, procedural rig, 2-bone IK, walk cycle, materials, clip-mask shader, shadow blobs, remote interpolation | **done** (nameplates moved to Phase 5 with the rest of the UI) |
| **3. Visual parity** | Spotlight + PCF shadow map, SSAO, 3D props, linear colour pipeline | **done** (mean pixel difference against the web client: 8.9/255) |
| **4. Game systems** | Event interpreter, NPC roaming/waypoints, interactions, map transitions, badges | **done** (avatar/say/sound handlers land on `GameStateDelegate` for Phase 5 to present) |
| **5. UI + audio** | Lobby, chat, dialogs, emote picker, minimap, badges; AVAudioEngine sound | **done** (nameplates and speech bubbles landed here too, as planned) |
| **6. Emotes** | 20 emotes posing the rig, their props, sounds and chat lines | **done** (limb targets and prop transforms match `emotes.js` to 4 dp) |
| **7. Minigames** | Tennis (2160 lines) | **done** (a 2D canvas game, so it brought a `CanvasRenderingContext2D` work-alike and an extended SVG rasteriser rather than renderer work) |
| **7b. Tag** | Tag (591 lines) | **deferred** — decided by the user on 2026-08-08: the game is being reworked first. See `PROGRESS.md` for what a future port needs |
| **8. Retire web** | Delete `client/`, move `physics.js` server-side (see below), strip static hosting | |

**Not being ported:** `admin.js` (1464 lines). It is a desktop authoring tool driven by
mouse and keyboard, not gameplay. **Decided (2026-08-07): it stays a web page** served by
the Node server, which keeps the object/NPC editor working without an iPad-sized native
editor. Phase 8 deletes the *game* client only — the admin page and whatever it needs
survive.

## 8. Phase 8 decoupling (physics.js — done)

`server/websocket.js` used to import the client's physics engine across the directory
boundary, so deleting `client/` would have broken the server. **Resolved: `physics.js` now
lives at `server/physics.js`** and is the single source of truth for both runtimes:

- Node imports it directly (`websocket.js`, `managers/NPCManager.js`,
  `managers/AIAgentManager.js`).
- The browser imports it at the unchanged URL `/src/physics.js`, which `static.js` routes
  to the server-side file ahead of the `/src` static mount. No client file changed.

The module keeps no imports and touches no DOM at module scope; `loadClipMask` is
browser-only and no-ops under Node.

`native/JoelsWorld/World/Physics.swift` is a port of this file — the two must be kept
behaviourally identical while both exist.

### Remaining `server/` → `client/` couplings (for Phase 8)

| Reference | What it needs | Resolution |
|---|---|---|
| `static.js:13`, `AIAgentManager.js:46` | parses `client/public/src/emotes.js` for the valid-emote list | **unblocked** — `Entity/Emotes.swift` is now the native source of truth. Move the list into `server/` when `client/` is deleted; until then the two must not drift |
| `scripts/slice_maps.js`, `create_overlays.js`, `generate_minimaps.js` | `client/public` as the asset root | move the asset tree under `server/` |
| `static.js:45-54` | serves the web client | deleted with the client, except what `admin.html` needs |
