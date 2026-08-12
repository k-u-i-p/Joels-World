# Native iOS Rewrite — Progress Log

**Resume instructions for a fresh agent:** read `native/PLAN.md` first (architecture +
decisions), then this file (what is actually built). The JS client that every port was written
against **no longer exists** — `client/` was deleted in Phase 8. Where a table below says
"ported from `main.js:306-531`", read it as a citation into git history, not a live file:
`git show 8ff2a7c~1:client/public/src/main.js` (any commit before the deletion) still has it.

Last updated: 2026-08-08 · **Phases 1–10 complete and verified. The rewrite is done.** Tag was
deleted outright rather than ported (see below). Phase 8 retired the web client, and Phase 10
retired the server's HTTP surface with it: the assets and the authored world ship inside the
apps, and `server/` is a WebSocket relay with two dependencies.

Work since then is picked off the "Known gaps" list at the bottom rather than from a phase
plan; the most recent pass is under "Editor quality of life and glTF material extensions".

---

## Decisions already made (do not re-litigate)

- **Full Swift rewrite**, not a WebView shell. User chose this explicitly.
- **The web game is retired** — the iOS app is the only client. `client/` was deleted on
  2026-08-08, once every phase that needed it as a reference spec was done.
- **Renderer: Metal + a thin purpose-built renderer.** Rationale and rejected alternatives
  (SceneKit, RealityKit) in `PLAN.md` §2. SceneKit is the fallback if parity stalls — keep
  `Net`/`World`/`Entity` free of Metal types so that stays possible.
  - Verified: SceneKit is **not** API-deprecated in the iOS 27 SDK (only the usual legacy
    symbols in `SceneKitDeprecated.h`). It was rejected for being in maintenance, not for
    being removed.
- **Node server in `server/` stays** as the multiplayer backend. Protocol unchanged.
- **Coordinate system preserved exactly** from the JS (X right, Y **down**; render space
  negates Y; Z up; rotations in degrees). `PLAN.md` §3.
- **Map chunk tiles stay server-fetched** (137 MB); models/audio get bundled. `PLAN.md` §5.
- **`admin.js` becomes a native macOS app** — decided by the user on 2026-08-08, replacing
  the 2026-08-07 decision that it would stay a web page. *"The admin editor becomes a Mac
  Desktop app, then the Three.js renderer can be removed entirely."* Built as
  `JoelsWorldAdmin`, a second target in the same Xcode project sharing `native/Engine/`.
  AppKit rather than Mac Catalyst — rationale in `PLAN.md` §7.
- **`physics.js` lives in `server/`** (moved 2026-08-07), served to the browser at its old
  `/src/physics.js` URL. The Phase 8 blocker is cleared.
- **Tag is not being ported yet** — decided by the user on 2026-08-08: *"Tag was rubbish and
  needs reworking."* The game is being redesigned first, so porting `tag.js` as it stands
  would be wasted work. Phase 7 delivers Tennis only. `maps.json` id 5 still loads as an
  ordinary map (it has real layers and a clip mask), so it is walkable but has no rules.

## Phase status

| Phase | Scope | Status |
|---|---|---|
| 1 | Vertical slice: project, Metal renderer, map streaming, camera, physics, net, movement | **done, verified** |
| 2 | Characters: glTF loader, procedural rig, 2-bone IK, walk cycle, clip-mask shader | **done, verified** |
| 3 | Visual parity: spotlight + PCF shadow map, SSAO, 3D props, linear colour | **done, verified** |
| 4 | Game systems: event interpreter, NPC roaming/waypoints, interactions, map transitions | **done, verified** |
| 5 | UI + audio: chat, dialogs, nameplates, emote picker, minimap, AVAudioEngine | **done, verified** |
| 6 | Emotes (20, each poses the rig) | **done, verified** |
| 7 | Minigames: tennis (2160 ln) | **done, verified** |
| 7b | Minigames: tag (591 ln) | **deleted** — deferred as "rubbish", then removed with its map, art and door NPC |
| 9 | macOS admin editor (`admin.js`, 1464 ln) on the shared engine | **done, verified** |
| 8 | Retire web client: asset tree to `server/assets/`, `client/` deleted | **done, verified** |
| 10 | Bundle the assets and the world into the apps; strip the server to `node:http` + `ws` | **done, verified** |

Phase 9 is numbered after 8 because it was decided later; it runs *before* Phase 8, since
retiring the web client was blocked on the editor having somewhere else to live.

## What Phase 1 actually delivers

3,029 lines of Swift/Metal in `native/JoelsWorld/`. Verified on an iPhone 17 simulator
against the **live production server**: the Junior Campus map streams and renders, the
player walks, and collisions block and slide correctly.

| File | Ported from | Notes |
|---|---|---|
| `World/Physics.swift` | `physics.js` (whole file) | Faithful port: rotated-rect/circle overlap, NPC ellipse collision, wall sliding incl. rotated edges, map bounds |
| `World/ClipMask.swift` | `physics.js:147-243` | 1/10-scale raster; white + pure green walkable |
| `World/SVGRasterizer.swift` | *(new)* | Core Graphics SVG path rasteriser — see "Why" below |
| `World/MapManager.swift` | `maps.js:189-346` | Frustum→ground-plane chunk culling, layer Z ordering |
| `World/GameState.swift` | `main.js:306-531` | Movement, camera spring, run-after-2.5s, throttled sync |
| `Render/Camera.swift` | `main.js:545-621` | Orbit pitch/yaw, zoom-as-frustum-scale, map clamping w/ `camera_permitted_offset` |
| `Render/Renderer.swift` | `main.js` three.js setup | Forward renderer: ground pass → player → blended overlays |
| `Render/TextureCache.swift` | browser image loading | Dedup + 512 MB disk `URLCache`, negative caching |
| `Net/NetworkClient.swift` | `network.js` | `URLSessionWebSocketTask`, exp. backoff, `NWPathMonitor` reachability |
| `Net/SessionStore.swift` | Capacitor `Preferences` | Keychain |
| `Input/Joystick.swift` | `input.js:114-223` | Thumbstick; heading set directly from stick angle |

**Why the SVG rasteriser exists:** `junior_school/clip_mask.svg` (the default spawn map) is
true vector SVG, iOS cannot rasterise SVG natively, and no rasteriser (rsvg/inkscape/
cairosvg) is installed on this machine. Rather than add a build-time dependency or silently
lose collision on the main map, it parses `<path>`/`<style>` into `CGPath`. It handles the
SVG number-packing gotcha (`3.1.2` is two numbers). **Arc commands (`A`) are not supported**
— it logs and bails rather than producing a wrong collision map. Illustrator exports beziers,
so this has not been hit.

## What Phase 2 actually delivers

1,935 more lines, taking `native/JoelsWorld/` to 4,964. Characters are rendered by the
procedural rig, with glTF heads and shoes, animated by the ported walk cycle and IK, and
occluded by the clip-mask shader.

| File | Ported from | Notes |
|---|---|---|
| `Render/GLTFLoader.swift` | *(new)* | `.glb` reader: JSON+BIN chunks, accessors (all 6 component types, normalized + strided), node hierarchy baked into vertices, base-colour materials, embedded images, `KHR_texture_transform` |
| `Render/MeshFactory.swift` | `characters.js:791-901` | three.js `CapsuleGeometry`/`SphereGeometry`/`BoxGeometry`/`PlaneGeometry` equivalents, plus `applyTaper` and geometry-space scale |
| `Render/ModelStore.swift` | `loadHeadModel`/`loadSharedModels` | Dedup + in-flight coalescing; merges a head's ~40 primitives into ~5 draw groups by material slot |
| `Render/CharacterRenderer.swift` | render half of `characters.js` | Shared primitive meshes, head/shoe models, shadow blob, clip-mask texture upload |
| `Entity/CharacterRig.swift` | `characters.js:786-1079` | Rig layout, head/hair tables, deterministic appearance hash, walk cycle, idle sway/breathing, pose composition |
| `Entity/IKSolver.swift` | `characters.js:278-316` | 2-bone IK with locked bend plane, `pointLimbSegment`, `setFromUnitVectors` |
| `Render/Shaders.metal` | `characters.js:361-427` | `characterVertex`/`characterFragment` — the clip-mask raymarch discard, ported 1:1 from the injected GLSL |
| `World/Physics.swift` | `physics.js:479-540` | `processInterpolation` — remote characters now ease to their server target instead of snapping |
| `World/GameState.swift` | `network.js:215-240`, `main.js:500-506` | `CharacterVisual` targets per id; ticks set targets, the frame loop interpolates |

**The skinning assumption holds** — this was the gate on the whole Metal decision. All 40
shipping `.glb` files scanned: `skins=0 anims=0 morphTargets=0 sparseAccessors=0`, every
primitive mode 4 (triangles). Extensions in use are all material-level
(`KHR_texture_transform`, `KHR_materials_emissive_strength`/`_transmission`/`_specular`/`_ior`).
**Re-run that scan before adding any new model.**

### Parity verified numerically against the running web client

Rather than eyeballing screenshots, the JS was run locally, its live rig state read out of
three.js, and the Swift port checked against those exact numbers:

| Check | Method | Result |
|---|---|---|
| 2-bone IK | Fed the web client's own hand/ankle targets through `IKSolver`; compared every joint position and quaternion | All 6 segments match to ±0.01 / ±0.004 |
| Walk cycle | Called the real `characterManager.applyWalkCycle(npc, 3.0)` in the browser, compared the resulting targets | All 4 targets and the body-pivot bob match to 1e-4 |
| Deterministic appearance | Called the web client's `getConsistentRandom` + head tables for 8 ids | Head and hair choice identical for every id |
| Fixed model rotations | `euler(π/2,π/2,0)` and `euler(0,π/2,π/2)` vs three.js quaternions | Both `(0.5, 0.5, 0.5, 0.5)`, exact |
| Clip-mask sampling | Shader `clipUv × texture size` vs `ClipMask.isWalkable` pixel index | Algebraically the same texel; no false discards over 10 frames |

Harnesses are throwaway (they live in the session scratchpad, not the repo) but the method is
worth repeating: `import('/src/characters.js')` in the browser console exposes
`characterVisuals`, `characterManager` and `getConsistentRandom` for direct comparison.

### Verified behaviour (walk test, live server)

```
Map 'Junior Campus' loaded: 1 chunked layer(s), 4372.0x3841.0
World applied: map 'Junior Campus', 1 players, 24 NPCs, 24 objects
Clip mask loaded: junior_school/clip_mask.svg
walktest t=1.3s pos=(-1203.9, -258.1) heading=60°  moved=89.4px  mask=loaded blocked=no
walktest t=4.8s pos=(-1455.0, 110.2) heading=217° moved=0.0px   mask=loaded blocked=YES
walktest t=6.3s pos=(-1445.8, 96.2)  heading=285° moved=16.8px  mask=loaded blocked=no
```

Zero tile-load failures; no reconnects over a 35 s observation.

## What Phase 3 actually delivers

1,056 more lines, taking `native/JoelsWorld/` to 6,020. The renderer went from a single
forward pass to the five the web build effectively runs, and the whole chain now works in
**linear colour**.

| File | Ported from | Notes |
|---|---|---|
| `Render/Lighting.swift` | `main.js:47-61`, `main.js:613-616` | Ambient + spotlight rig, its per-frame tracking of the camera focus, the `SpotLightShadow` camera, and the `SSAOPass.generateSampleKernel` port (seeded, so the AO term is stable across runs) |
| `Render/PropRenderer.swift` | `maps.js:125-187`, `maps.js:348-383` | Places every `shape == '3d_model'` object; rebuilds only when the object set actually changes |
| `Render/Renderer.swift` | `main.js` composer chain | Shadow → scene (MRT colour + view normals + readable depth) → SSAO → blur → composite |
| `Render/Shaders.metal` | three.js `bsdfs.glsl.js`, `SSAOShader`, `SSAOBlurShader` | Lambert for ground layers, full Standard (diffuse × (1−metalness) + GGX) for characters and props, 3×3 PCF shadow lookup, 32-sample SSAO, 5×5 blur, multiply composite |
| `Core/Math.swift`, `TextureCache`, `ModelStore` | three.js `ColorManagement` | sRGB↔linear transfer functions; tile and glTF textures decode on sample |
| `Render/GLTFLoader.swift` | glTF `pbrMetallicRoughness` | Now reads `roughnessFactor`/`metallicFactor`, threaded through to the shader |

### The pass graph

Ground tiles are `MeshLambertMaterial` + `receiveShadow`; overlay layers are
`MeshBasicMaterial` and stay unlit (`maps.js:276`). Characters and props cast into the shadow
map; the ground does not (a flat plane casts nothing). Blended draws — overlays and the ground
shadow blobs — write neither depth nor normals, which keeps the two SSAO inputs consistent
with each other.

### Colour: the part that was silently wrong before

Phase 1/2 sampled textures raw and presented them raw — two errors that cancelled. They stop
cancelling the moment lighting is applied, so Phase 3 moved the whole chain to linear:
`ColorManagement` is on in the shipped client (checked on the live page — working space
`srgb-linear`, `outputColorSpace` `srgb`, `toneMapping` `NoToneMapping`), so hex colours are
linearised on parse, tile/glTF textures load `.SRGB: true`, and the render targets are
`_srgb` so the hardware does the single encode `OutputPass` does.

**One deliberate oddity:** the *background* clear colour is pre-encoded on the CPU, because
the web build encodes it twice. Measured on the live client, `#7bed9f` (linear 0.198) arrives
on screen as **185**, not the 123 a single encode gives. Scene geometry is unaffected — this
only shows outside the map, where nothing is drawn.

### Parity verified numerically against the running web client

The web client was driven at the same camera as the app (`-at -1015 -267 -zoom 1`), its
framebuffer read back with `gl.readPixels`, and the two images diffed. **Alignment came out at
dx=0, dy=0**, so the camera port needs no fudge.

| Check | Method | Result |
|---|---|---|
| Lighting model | Built the identical light rig in a throwaway three.js scene and read the centre pixel for known albedos | Lambert `#808080` → **131**, Standard r0.8/m0.0 → **135**, r0.6/m0.1 → **136** — the Swift shader's formulas predict 131 / 134.7 / 135.8 |
| Unlit round trip | `MeshBasicMaterial` `#808080` | **128** — overlays pass through untouched |
| Whole-frame difference | Mean absolute RGB difference, UI strips excluded | **8.9 / 255 (3.5%)**; 84% of pixels within 16 levels, 93% within 32 |
| Tone distribution | Luminance percentiles | web p25/p50/p75/p95 = 77 / 115.8 / 156.1 / 179.7 against 79.2 / 114.9 / 158.2 / 180.1 |
| Shadow map is real | Same frame with `-noshadows` | mean difference against the web jumps **8.9 → 42.4**; the spotlight shadow is doing the work |
| SSAO | Same frame with `-nossao` | ~3 levels of mean darkening, difference essentially unchanged (8.32 vs 8.40) |

**Two real bugs this caught**, neither visible without the diff:

- **glTF textures were being flipped vertically.** glTF puts UV (0,0) at the image's top-left,
  which is already Metal's sampling origin, so the flip mirrored V. Every surface of
  `junior_school_buildings.glb` packs a sub-rectangle of an atlas through
  `KHR_texture_transform` (UVs run 0–1500, scaled by ~0.00023), so mirroring V sampled a
  completely different region — the building roofs rendered as pale wrong texture. Map tiles
  **do** still need the flip; their quad UVs are built bottom-up.
- **`KHR_texture_transform` was composed in the wrong order** (rotate-then-scale, and with the
  opposite rotation sign). Invisible today because no shipping asset rotates its UVs, and it
  would have stayed invisible until one did.

Back-face culling was also added to match three.js's default `FrontSide`. It did not move the
numbers measurably, but rendering both sides was simply wrong.

### Residual difference (3.5%)

Concentrated in the shed-door recesses and roof edges: 0.25% of pixels are near-black in the
app where the web build is not. Likely causes, in order — our shadow map fully shadows
recesses that three.js's PCF softens; `KHR_materials_emissive_strength` / `_transmission` /
`_specular` / `_ior` are parsed but ignored; and SSAO reconstructs from an MRT normal buffer
that excludes blended draws, where three.js re-renders the whole scene with
`MeshNormalMaterial`.

## What Phase 4 actually delivers

1,025 more lines, taking `native/JoelsWorld/` to 7,045. The world stopped being scenery: NPCs
walk their routes, walking near one makes it talk, doors ask whether to go through them and
the map changes when you say yes. **No renderer work at all** — this phase is entirely over
the `World`/`Net` layers, as predicted.

| File | Ported from | Notes |
|---|---|---|
| `World/EventInterpreter.swift` | `events.js` (whole file) | All eight handlers, the numeric "use that object's tree" reference, `{name}`/`{player_id}`/`{npc_name}`/`{npc_id}` substitution, and per-source per-message log rate limiting |
| `World/NPCBehaviour.swift` | `characters.js:1315-1406` | `roam_radius` wander (turn first, walk second) and cumulative-offset waypoint patrols including the two extra cycle steps |
| `World/Physics.swift` | `physics.js:569-609` | `processInteractions` — proximity enter/exit over players and NPCs |
| `World/GameState.swift` | `main.js:306-531`, `main.js:668-828` | Trigger-zone enter/exit, emote state and cancel rules, map-change teardown, badges, `EventInterpreterDelegate` |
| `UI/DialogView.swift` | `#dialog-overlay` | Minimal yes/no prompt — Phase 5 restyles it, but map transitions need it now |
| `Net/Protocol.swift` | `network.js` senders | `change_map`, `log`, `award_badge`; `waypoints`, `move_time`, `default_emote`, `badges`; JS-truthiness helpers on `JSONValue` |

### Things this phase settled

- **NPC movement is entirely client-side.** The server ships the roster once and never sends
  positions for it — `network.js:189-215` deliberately drops position fields for NPC ids and
  keeps only `emote` and `interaction_radius`. Every client simulates NPCs independently, so
  two players do *not* see an NPC in the same place. That is existing behaviour, not a gap.
- **`applyTick` was overwriting NPC targets.** It called `setTarget` for every id in the frame,
  including NPCs, which would have stomped each roam target the moment Phase 4 set one. Fixed
  to match the JS early-return.
- **`isNpc` is dead.** `physics.js:575` filters interaction candidates on
  `c.isNpc || c.on_enter || c.on_exit`, and nothing in the client, the server or the data ever
  sets `isNpc`. The port implements the filter as "has an event tree".
- **Handler order within one action is fixed, not JSON order.** Swift dictionaries do not
  preserve key order, so handlers run in the order `events.js` declares them. No shipping tree
  has two handlers whose effects interact, so this is unobservable today.
- **`isEmoteForced` never reaches physics from the main loop.** `main.js:341-349` zeroes `dx`
  and `dy` while jumping, so `processMovement` is not called at all and its `emoteCanceled`
  result is unreachable from this path. The Swift port keeps the same structure.

### Verified behaviour (live server, iPhone 17 simulator)

Waypoints — Mr Savage's four steps, `+50,+150` → `rotate 120` → `-100,0` → `rotate 110`, then
the two implicit steps that walk him home and unwind the rotation:

```
npc 8 Mr Savage pos=(-1984.0, -411.0) rot=70  target=(-1934.0, -261.0) idx=1
npc 8 Mr Savage pos=(-1934.0, -261.0) rot=190 target=(-1934.0, -261.0) idx=2
npc 8 Mr Savage pos=(-2034.0, -261.0) rot=190 target=(-2034.0, -261.0) idx=3
npc 8 Mr Savage pos=(-2034.0, -261.0) rot=300 target=(-2034.0, -261.0) idx=4
npc 8 Mr Savage pos=(-1991.3, -389.2) rot=300 target=(-1984.0, -411.0) idx=5
npc 8 Mr Savage pos=(-1984.0, -411.0) rot=70  target=(-1984.0, -411.0) idx=0
```

Roaming — Tommy turns to face the destination and only commits to walking a beat later, and
every destination stays inside his 300 px radius.

Interactions, substitution and log rate limiting (`rate_limit: 60`, four approaches):

```
Avatar: Mr Hardy (1) /avatars/mr_hardy.png
Say: Mr Hardy (1): Hello Tester, I'm Mr Hardy
Say: Mr Hardy (1): Be Good Tester!          ← on_exit
Log → npc 1: Tester (256) approached Mr Hardy (1)   ← sent once for four approaches
```

Map transition, end to end — trigger zone → dialog → confirm → `change_map` → fresh `init`:

```
Dialog: 'Enter the Pool building?' — auto-confirming
Map 'Pool' loaded: 2 chunked layer(s), 2752.0x1536.0
World applied: map 'Pool', 1 players, 4 NPCs, 3 objects
Sound (background): /media/pool_sound_effect.mp3 @ 0.25 (source 3)
```

Emote state, walking in and out of the pool's water — including the subtle rule that walking
does *not* cancel an emote set by the zone you are standing in:

```
Sound: /media/splash.mp3 @ 1.00 (source 3)
Player emote: swim
…four seconds of continuous walking inside the water, emote intact…
Sound: /media/wet_footprints.mp3 @ 1.00 (source 3)
Player emote: wet
```

### What Phase 4 deliberately leaves stubbed

The three handlers that are really UI or audio work log instead of presenting, behind
`GameStateDelegate` so Phase 5 only has to fill in the methods:

- `avatar` — the NPC portrait and the title-bar name swap.
- `say` — speech bubbles and the chat feed.
- `play_sound` — background music, pooled one-shots, and the per-source stop on exit. The
  *stop* calls are already wired at every point the JS makes them (zone exit, NPC out of
  range, map change), so Phase 5 gets working lifecycle for free.

`badge_earned` updates `player.badges` but has no dialog yet, and `map_change_rejected` is
logged without the buzzer or the on-screen notice. **`map_change_rejected` is the one path in
this phase not exercised on a device** — reaching it needs a `can_leave: false` map, i.e.
being put in Detention.

## What Phase 5 actually delivers

2,243 more lines, taking `native/JoelsWorld/` to 9,288. The game got its face and its voice:
every DOM overlay in `index.html` is now a UIKit layer over the Metal view, and every sound
`events.js` asks for actually plays.

| File | Ported from | Notes |
|---|---|---|
| `Audio/SoundManager.swift` | `sound.js` (whole file) | One `AVAudioEngine` graph replaces both JS backends (Web Audio and Capacitor `NativeAudio`). Per-sound `AVAudioPlayerNode` → `AVAudioUnitVarispeed` → main mixer; `pause`/`fadeOut`/`setRate` keep the JS handle's shape. Buffers cache by path, bundle first then the asset host |
| `Audio/GameAudio.swift` | `events.js:96-112`, `main.js:291-303` | Routes the three channels the JS keeps: one effect per source id (`sourceObj.activeAudio`), the footstep loop, and the active emote |
| `UI/Theme.swift` | `style.css` `:root` + components | Palette, the glass panel as a `UIVisualEffectView`, and Pricedown registered at runtime from the bundled `.otf` |
| `UI/HUDView.swift` | `#top-center-ui`, `ui.js:232-286` | NPC portrait, map-name display, chat field, and the chat feed with its decay rules |
| `UI/CharacterOverlayView.swift` | `characters.js:1240-1290`, `.character-nameplate` / `-chat-bubble` | Nameplates and speech bubbles, pooled per character and repositioned every frame |
| `UI/Dialogs.swift` | `#emotes-`/`#badges-`/`#help-`/`#minimap-dialog`, `ui.js:288-316` | The four panels, the minimap with its live dot, the ❌ flash and the disconnect dialog |
| `UI/PanelDialogView.swift`, `UI/ButtonBarView.swift` | `_bindDialog`, `#ui-buttons-container` | Shared panel chrome; the four round buttons |
| `UI/EmoteCatalog.swift` | `ui.js:151-163` | Fetches `/api/config` once — the same list the web picker uses |
| `UI/DialogView.swift`, `UI/LobbyView.swift` | `#action-dialog`, `#name-dialog` | Restyled from the Phase 1/4 placeholders onto the glass theme, logo and all |
| `Render/Camera.swift` | `THREE.Vector3.project` | `project(worldX:worldY:z:viewport:)`, so the UI layer can place things over the world |
| `World/GameState.swift` | `main.js:453-466`, `network.js:246-268`, `ui.js:22` | Walking-audio and emote-audio hooks, `applyChat`, and the per-frame `overlaySubjects` feed |

### Faithfully reproduced quirks

- **Chat messages lose ten seconds each time a new one arrives.** `ui.js:241` compares an
  absolute epoch timestamp against `20000`, which is always true, so the `-2500` branch it
  appears to have is unreachable. Busy chat therefore clears older lines faster. Ported as-is.
- **Only three speech bubbles draw per frame** (`currentFrameChatCount`), and a bubble lives
  five seconds from the moment the message arrived.
- **An NPC leaving your radius closes whatever dialog is open**, because `cleanupNpcUI` hides
  the dialog overlay unconditionally (`ui.js:47-49`). Watch for a door prompt vanishing while
  you stand still — that is an NPC wandering off, not a bug.
- **The portrait is owned by one NPC at a time** (`data-npc-id`), and only that NPC's exit
  clears it and restores the map name.

### Three real bugs this phase caught

None of them are Phase 5 code; all three were sitting in the earlier phases.

- **Palette PNGs never rendered.** `MTKTextureLoader` cannot decode colour-type 3 PNGs, and
  that is what the asset host serves for the Main Building and part of the Pool — every tile
  came back "Image decoding failed" and those maps drew as flat background colour. Phases 1–4
  never caught it because they were verified on Junior Campus, whose tiles are truecolor.
  `TextureCache` now falls back to a Core Graphics decode (same vertical flip, same sRGB), and
  those maps render. **Anything else that loads images — `ModelStore`'s glTF textures — has the
  same blind spot if a palette PNG ever ships in a model.**
- **A player last seen in a minigame could not load at all.** `MapData.width` was
  non-optional, the Tennis map (`maps.json` id 4) carries no dimensions because it is an
  imported script, and the whole `init` frame failed to decode — leaving a black screen with
  one line in the log. `MapData` now decodes missing dimensions as zero and logs that minigame
  maps wait for Phase 7.
- **A button's title could not be changed after creation.** System buttons carry a default
  `UIButton.Configuration` on current iOS, and a configuration takes precedence over
  `setTitle(_:for:)` — so the dialog's "Yes" never became "OK" and the lobby's spinner state
  would not have restored its label. `Theme.makePlainButton()` opts out; every button here is
  hand-styled and wanted nothing from the configuration system.

### Verified behaviour (live server, iPhone 17 simulator)

`-uidemo` walks the whole UI on a timer, since `simctl` cannot inject touches. Screenshotted
at each step: chat feed (newest on top, five max), the emote picker populated with the
server's 20 emotes, the badges list with `tennis` ticked after a `badge_earned`, help, the
minimap with the player dot on the corridor it should be, the ❌ rejection flash, and the door
prompt. Speech bubbles and nameplates track their characters, and the NPC portrait swaps the
title bar to "MR HARDY" when you walk up to him and restores "Junior Campus" when you leave.

```
Audio engine running at 48000 Hz
World applied: map 'Junior Campus', 1 players, 24 NPCs, 24 objects
Sound (background): /media/the_wall.mp3 @ 0.30 (source 0)
Sound: /media/school_bell.mp3 @ 1.00 (source 9)
uidemo: emote command
Player emote: dance
```

Zero tile decode failures, zero audio load failures, zero frame decode failures over the run.

## What Phase 6 actually delivers

1,567 more lines, taking `native/JoelsWorld/` to 10,855. Every emote poses the rig, spawns its
props and plays its sound, and the chat line each one broadcasts finally gets sent.

**There are 20 emotes, not the ~30 this file previously estimated.** `emotes.js` is 914 lines
because the poses are long, not because there are many of them.

| File | Ported from | Notes |
|---|---|---|
| `Entity/Emotes.swift` | `emotes.js` (whole file) | The 20-entry table — duration, message, `message_when_near`, sound, pose and `onEnd` — plus the `getEmoteMessage` port with its nearest-target resolution |
| `Entity/EmoteProps.swift` | the three.js objects each pose builds | `PropMesh` (22 geometries), `PropAnchor` (the six rig nodes props hang off), `PropDraw`, and `RigRuntime` — the state three.js keeps on its retained `Object3D`s |
| `Entity/CharacterRig.swift` | `updateCharacter3D:1081-1210` | Now stateful: emote teardown, the walk/idle/emote precedence, the `emoji` fallback pose, head rotation, held models, and composing each prop's world matrix after the IK settles |
| `Render/MeshFactory.swift` | three.js `CylinderGeometry`/`CircleGeometry`/`TorusGeometry` | Plus `applyRotation`, for the geometry-space rotations the props bake in |
| `Render/CharacterRenderer.swift` | the render half | One shared GPU mesh per prop geometry, the ❤️ sprite texture, the opaque/transparent split, and the tennis racket in the right hand |
| `Render/Renderer.swift` | three.js opaque→transparent sort | Per-character `RigRuntime` store, the camera basis sprites billboard against, and a third blended sub-pass for transparent props |
| `World/GameState.swift` | `updateCharacter3D:1090-1133` | Emote expiry, `default_emote` as an NPC's resting pose, and `onEnd` |
| `App/GameViewController.swift` | `main.js:219-247` | The `/emote` path now posts the emote's chat line and plays its sound |

### Parity verified numerically against the real JS

Same method as Phases 2 and 3, but run against `emotes.js` itself rather than a browser: the
module is loaded in Node with its four imports replaced by a stub three.js (Vector3, Group,
Mesh, the five geometries, the three materials), `Date.now` pinned, and every `updateLimbs3D`
called on a hand-built rig. `-emotedump` does the same on device with the same pinned inputs.

| Check | Result |
|---|---|
| Body pivot position and rotation, head rotation, all four limb targets, for all 20 emotes | **identical to 4 decimal places, every field** |
| Prop transforms — position, scale, opacity | identical for all 71 props across the 20 emotes |
| Shared-material opacity aliasing (below) | reproduced; `cry`'s six tears all report 0.306 in both |
| `sleep`'s cloned `Z` groups | Swift bakes the group transform into each bar: 20.2833 ± 2 × 1.271 against the JS's group-at-20.2833, children-at-±2 |
| Sprite scale (`love`) | 8.766 / 8.266 / 9.766 / 9.266 in both |

### Two JS behaviours reproduced rather than fixed

- **Props within one emote share a single three.js material.** Where a pose assigns
  `mesh.material.opacity` inside a loop with a per-mesh value, every mesh in that group ends up
  with the *last* value written. It affects `cry` (6 tears), `love` (4 hearts), `swim` (3
  ripples), `sleep` (3 letters), `eat` (3 crumbs) and `wet` (16 footprints) — they fade in
  lockstep instead of individually. `Emotes.sharedOpacity` does the same.
- **`swim`'s ripple rings stand up vertically.** `ripGeo.rotateX(π/2)` takes a torus that
  already lies flat in this game's Z-up render space and turns it on its side. Ported as
  written; it is visible on screen as a blue bar rather than a ring.

Also carried over exactly: the body pivot is *not* reset to its resting height while an emote
is running, so an emote started mid-stride keeps the last frame's walk bob until it ends.

### Rendering decisions

- **Emote props are not clip-mask injected.** `injectClipMask` only runs over
  `buildSkeletonMaterials`, so a laser beam or a dropped footprint stays visible through a wall
  while the limbs behind it still vanish. `drawMesh(masked:)` switches the raymarch off.
- **Emote props cast no shadow; the held model does.** `ensureThreeSetup`'s `castShadow`
  traverse runs once at rig creation, before any prop exists — but `loadHoldingModel` sets
  `castShadow` on its own clone. The shadow pass takes `includeProps: false`.
- **Transparent props draw in a third blended sub-pass** after the opaque rig, matching
  three.js's opaque-then-transparent sort. Opaque props (the apple, plate, book, notes, balls)
  go through the normal character pass and contribute to the SSAO normal buffer.
- **`THREE.Sprite` billboarding** is done by substituting the camera basis for the anchor's
  rotation while keeping its world position and inherited scale — which is what three.js's
  sprite renderer does.

### One bug this phase caught

**The local player's emote never reached the renderer.** `drawableCharacters` built the local
character from `player.appearance`, the roster record the session arrived with, and copied
position, heading and name onto it — but not `emote`, which lives on `player`. Nothing rendered
emotes before Phase 6, so it had never mattered; it would have made the player the one
character whose poses did not work.

### Verified behaviour (live server, iPhone 17 simulator)

`-emotedemo` walks the player through all 20 emotes, and `-emote <name>` holds one for a
screenshot. Photographed and confirmed rendering: `laser`'s two 300-unit beams tracking the
head, `love`'s four camera-facing ❤️ sprites fading as they drift, `sleep`'s three green `Z`s
shrinking away from the reclining body, `swim`'s ripples and its flat-on-the-stomach pose,
`tennis`'s racket GLB held in the right hand, `laugh` rolling on its back, and `wet` — three
blue drops shedding off the body plus a footprint left behind at a fixed world position.

```
emotedemo: /jump
Player emote: jump
Player emote: none          ← expired on its own 800 ms duration
Chat — FinalTest: FinalTest is firing backwards lasers!
```

All 20 fired with zero errors over a 50 s run. Six of the twenty chat lines were dropped by the
server, not the client: `ChatManager.js:37` discards a line sent within 2000 ms of the previous
one, and the demo fires exactly every 2000 ms.

## What Phase 7 actually delivers

3,668 more lines, taking `native/JoelsWorld/` to 14,523. Tennis is playable end to end: the
walk-on and handshake, serves with faults and double faults, rallies, tennis scoring through
deuce and advantage, the badge on a set win, and the run back out to Junior Campus.

**Tennis is the one screen the web build does not draw with three.js.** It is a 2D canvas
game — background bitmap, hand-drawn humanoids, a racket built out of `ctx` calls. So this
phase is not more Metal work; it is a canvas emulator and a physics port.

| File | Ported from | Notes |
|---|---|---|
| `UI/Canvas2D.swift` | `CanvasRenderingContext2D` | The API the JS drawing code is written against: save/restore, transforms, path building, gradients, clipping, text. Two canvas behaviours reproduced deliberately — see below |
| `World/Minigames/TennisGame.swift` | `tennis.js` (simulation half) | Ball physics, the 60 Hz intercept search, arm reach and racket aim, serve/fault/scoring, the intro sequence, the NPC |
| `UI/Minigames/TennisView.swift` | `tennis.js` (rendering half) | The court transform, both characters with their shadows, the racket, the ball, the intercept crosshair, the scoreboard |
| `UI/Character2D.swift` | `characters.js:483-756` | `drawShoe2D` and `drawHumanoidUpperBody2D`, including the five hair styles |
| `World/SVGRasterizer.swift` | *(extended)* | Elliptical arcs, `<rect>`/`<circle>`/`<ellipse>`, stroking, `<g>` style inheritance, per-element `transform`, and a single-pass byte tokenizer |
| `UI/SVGImage.swift` | `new Image(); img.src = '…svg'` | Fetch + rasterise once, cached |
| `World/Minigames/Minigame.swift` | `main.js:668-734` | The handover: a map with an `import` takes the whole frame, and the overworld stops simulating |
| `UI/EmojiImage.swift` | *(new)* | Emoji fallback for platforms that cannot draw them — see below |

### The court is 2.4 MB of vector art, and iOS has no SVG decoder

`minigames/tennis/map.svg` is a tracer export: 3,446 paths, 296 ellipses, 270 rects, 53
circles and **26,825 elliptical arcs**, with half the paths stroke-only inside one `<g>` that
carries the stroke style. The Phase 1 rasteriser handled `<path>` fills and explicitly bailed
on arcs. Phase 7 extended it to cover all of that, and two things about the rewrite matter:

- **The scanner is byte-oriented now.** The old one called `range(of: "<path")` on a shrinking
  `Substring`, which is quadratic; on this file that does not finish. Walking `[UInt8]` once
  parses the whole document in milliseconds. `Character` is a grapheme cluster and is far too
  slow for megabytes of path data, especially in a debug build.
- **Arcs are decomposed into cubic Béziers by hand** rather than handed to
  `CGMutablePath.addArc(…, transform:)`, whose `clockwise` flag is interpreted *after* the
  transform — which makes the SVG sweep flag's meaning depend on the handedness of the space
  the path lands in. Béziers carry their own orientation.

The result is rasterised once into a bitmap (2493×1260) and shown in a `UIImageView` under
the canvas, rather than re-blitted every frame as the JS does. Same picture, no per-frame cost.

**The clip masks go through the same code**, so this was a regression risk. Re-verified with
`-walktest` on Junior Campus: mask loads, the player is blocked on the first frame and walks
freely after — the Phase 1 numbers.

### Two canvas behaviours `Canvas2D` reproduces on purpose

Both are load-bearing in `tennis.js`, and neither falls out of just wrapping `CGContext`:

- **Path points bake into canvas space as they are added.** `drawStretchingLeg`
  (`tennis.js:1785`) issues its `moveTo` inside a rotate/translate/rotate, restores, and then
  issues the `lineTo` — one line spanning two transforms. That is how a jumping character's
  legs stretch from a hovering hip down to a planted shoe.
- **The pen is scaled by the transform in force when `stroke()` runs.** Both fall out of
  storing the path in canvas space and mapping it back through the inverse transform at paint
  time, which is what the implementation does.

### The racket hitbox is a by-product of drawing the racket

This is the strangest thing in the file and it is reproduced exactly. `drawRacket` reads the
racket head's position back out of the canvas transform (`tennis.js:1641-1656`) and stores it
on `racketCurrentPosition`; the **next** frame's `processRacketDeflections` tests the ball
against that. The one-frame lag is not incidental — the aim eases towards its target 10% a
frame, so testing against the racket as *drawn* rather than as *intended* is what makes a
mistimed swing miss. `TennisView.draw` writes `side.racket` for the same reason, and
`TennisGame`'s doc comment says so, because it looks like a layering violation and is not.

### The one deliberate deviation: tap-to-move

`tennis.js:630-659` converts the touch through `screenToWorld`, which raycasts against
`threeCamera` — but **`threeCamera` is never configured while a minigame runs**. `main.js`'s
`draw` is unregistered from the game loop on the way in, so the camera still holds the
*previous map's* position and zoom. A tap therefore lands hundreds or thousands of units from
a court that spans x ±135, y 75–300, and only the bounds clamp in `processCharacter` salvages
it into "you moved vaguely left" or "vaguely right".

`TennisView` inverts its own court transform instead, which is the mapping the handler is
plainly reaching for. Reproducing the bug faithfully would have made the game unplayable
rather than merely different.

Worth knowing: **tapping is the entire control scheme on a phone, in both builds.** The web
version's other input is the arrow keys, and it hides the joystick on the way in
(`tennis.js:675`). No keyboard support was added here.

### Emoji: the simulator cannot draw them

The UI carries 23 emoji — the button bar, the emote picker, the badge list, the help headings,
the map-change ❌, `love`'s ❤️ sprite and the tennis ball. **The iOS Simulator runtimes ship a
stripped font set that renders every one of them as a `.notdef` box.** It is not a code
problem (the plain `setTitle("🏅")` buttons from Phase 5 are boxes too, and erasing the device
does not help), but screenshots are how this port gets verified, so unreadable screenshots
are a real problem.

`UI/EmojiImage.swift` probes once whether the system can draw a colour emoji — it renders one
black-on-transparent and looks for colour, since a `.notdef` box comes out monochrome while a
colour glyph paints its own palette — and if it cannot, substitutes a bundled SVG through
`SVGRasterizer`. **Nothing changes on a real device.**

The 23 SVGs in `Resources/emoji/` (104 KB) are **Twemoji, CC-BY 4.0**. The attribution
obligation is recorded in `Resources/emoji/ATTRIBUTION.txt`; if this ever becomes the primary
rendering path rather than a fallback, that attribution has to become visible to players.

### Faithfully reproduced quirks

- **`target.z` is double-scaled.** `tennis.js:1319` sets the aim point's height to
  `NET_HEIGHT * GAME_SCALE + 5`, but `NET_HEIGHT` is already `45 * GAME_SCALE`. Kept.
- **The intercept search double-counts bounces.** `simBounces` starts from `state.bounceCount`
  and the prune test is `simBounces + state.bounceCount > 1`. That is what actually limits the
  search depth, so changing it would change how far ahead a character looks.
- **`canCharacterHit` has redundant clauses.** Several of its fourteen early-returns are
  implied by earlier ones. Ported statement for statement rather than simplified.
- **The ball keeps bouncing while the players walk back.** `processBallMovement` runs during
  the reset, so `bounceCount` climbs into the teens as the ball rolls off court. Cosmetic, and
  what the JS does.

### Left out

- **The whole admin diagnostics layer** — the side-profile trajectory graph, the racket-stance
  widget, the bounce/NPC-intercept/toss crosshairs, the hitbox ellipses, the court-bounds and
  service-box overlays. All gated on `window.isAdmin`, and `admin.js` stays a web page
  (PLAN.md §7). The `trajectoryPoints` sampling that only fed the graph is gone with it.
- `state.player.hasTarget`, which the JS sets and never reads.

### Verified behaviour (live server, iPhone 17 simulator)

`-map 4` jumps straight to the court (the door is halfway across Junior Campus and `simctl`
cannot walk there). `-tennisdemo` plays the player's side through the **real** `handleTap`
path, and `-tennistrace` logs the point once a second.

```
Map 'Tennis' loaded: 0 chunked layer(s), 0.0x0.0
[Tennis] Initialising minigame
Sound (background): /media/hushed_crowd.mp3 @ 0.50 (source -1)
SVG rasterised: minigames/tennis/map.svg at 2493×1260
tennis walkToNet    …  player pos=(0.0, 239.8) rot=-91
tennis shakeHands   …  player rot=270 → 279          ← the oscillating handshake
tennis walkToBaseline… player pos=(48.0, 300.0) | npc pos=(-48.0, 75.0)
tennis playing serve=npcServe/idle       ball=(-36.1, 73.4, 10.0)   ← ball in the NPC's hand
tennis playing serve=npcServe/justThrown ball=(-49.9, 75.8, 56.1)   ← the toss
tennis playing serve=npcServe/live       ball=(-47.9, 143.8, 108.0) rally=1
tennis playing serve=inPlay/live         ball=(-23.1, 247.3, 37.4)  bounces=1
-exitafter: pressing the exit button
Map 'Junior Campus' loaded: 1 chunked layer(s), 4372.0x3841.0
```

Rallies reached **15 shots** and the score walked through Love–15, 15–15, 15–30 over a 55 s
run. Screenshotted and confirmed rendering: the rasterised court with its net and service
lines, both characters with racket, shoes, stretched legs and soft shadows, the ball in
flight with its ground shadow, the green intercept crosshair, the Pricedown scoreboard, the
🏃 exit button in place of the map button, and the badge list with every emoji drawn.

Zero errors over the run. The exit path was driven end to end: button → dialog → confirm →
`change_map 0` → Junior Campus reloads, and the 3D world, joystick, chat HUD and map button
all come back.

## What Phase 9 actually delivers

3,009 lines of Swift in `native/JoelsWorldAdmin/`, plus a restructure of the existing code
into `native/Engine/` — taking the whole tree to 17,654 lines. `admin.js` is now a native Mac
app: the map renders through the same Metal renderer the game uses, objects and NPCs are
dragged, resized and rotated on it, and the object, NPC and event-tree inspectors write to
the same `server/admin.js` endpoints the web panel did.

**The engine moved, and nothing else had to.** `Core`, `Net`, `World`, `Render` and `Entity`
are now `native/Engine/`, a filesystem-synchronized group belonging to *both* targets;
`JoelsWorld/` keeps `App`, `UI`, `Input`, `Audio`, `Resources`. That split was almost free —
the whole engine compiled for macOS after **four** changes:

| Change | Why |
|---|---|
| `World/ClipMask.swift` | `UIImage(data:)?.cgImage` → `CGImageSourceCreateWithData`. Cross-platform, and no branch |
| `Render/CharacterRenderer.swift` | The ❤️ sprite painted a glyph through `UIGraphicsImageRenderer`. The iOS path is untouched under `#if canImport(UIKit)`, with a Core Text equivalent for macOS |
| `Core/InputState.swift` | Lifted out of `Input/Joystick.swift`. `GameState.update` takes one; the editor passes a standing "not moving" value |
| `Core/WalkTest.swift` | Moved out of `App/`. `GameState` reads `-zoom` and `-at` from it, so it was never really iOS-only |

`Net`, `World` and `Entity` needed **nothing** — the Phase 1 rule about keeping them free of
renderer and UI types paid for itself here.

| File | Ported from | Notes |
|---|---|---|
| `Editor/AdminMapViewController.swift` | `admin.js:1023-1238` | The `mousedown`/`mousemove`/`mouseup` handlers: hit-test order, click-then-drag, shift multi-select, corner resize, panning, paste-at-cursor |
| `Editor/AdminOverlayView.swift` | `adminDraw` (`admin.js:1311-1464`) | The object quads and circles projected through the live camera, the colour rules, the resize handle, and the selected NPC's three rings |
| `Editor/EditorSelection.swift` | `window.selectedObject` / `selectedNpc` (`admin.js:144-237`) | Selection by id resolved against the live world, plus `findObjectAtXY`, `checkResizeHandleHit` and the top-left resize anchor |
| `Editor/AdminEditorView.swift` | the window-level listeners | Mouse, scroll, magnify, ⌘C/⌘V, delete, and the PNG/JPEG drop target |
| `Inspector/ObjectInspectorView.swift` | `#edit-obj-section` (`admin.js:305-443`, `630-676`) | Name, rotate, width/length with the 2 % step, clip, and the 3D-only scale/Z/model rows |
| `Inspector/NPCInspectorView.swift` | `#edit-npc-section` (`admin.js:445-583`, `678-717`) | Name, rotate, size, Z, both radii, three colour wells, hair/gender/head/default-emote pickers |
| `Inspector/EventEditorView.swift` | `renderEventUI` (`admin.js:741-1021`) | All eight action types, the starter payload each one installs, and Save Events |
| `Inspector/AdminControls.swift` | `bindHoldAction` (`admin.js:110-142`) | The 50 ms repeat-while-held button that syncs once on release |
| `App/AdminSession.swift`, `App/AdminMessage.swift` | `networkClient.send(...)` calls | The twelve editor verbs `server/admin.js` understands, `cloneData` included |
| `Engine/Net/NetworkClient.swift` | *(new)* | `sendAdmin(_:)` — the payloads are heterogeneous, so they go as loose JSON rather than a struct per verb |
| `Engine/World/GameState.swift` | *(new)* | `editObject` / `editNPC` / `setCameraFocus`: the editor mutates locally first and tells the server after, which is what makes a dragged shape follow the cursor |

### The editor has no player, so the camera focus *is* the player

`admin.js` pans by writing to `player.x/y`, because the game camera follows the player. The
Mac editor keeps that exactly — `setCameraFocus` writes the same two fields — so the camera
clamping, the `camera_permitted_offset` handling and the map-bounds behaviour are all the
shipped code rather than a second implementation. The joystick is simply never consulted:
`inputProvider` returns a standing `InputState()`.

One consequence worth knowing: the editor's avatar is a real character on the server, so
walking the camera across a trigger zone fires its events. The `GameStateDelegate` methods
for `say`, `avatar`, sounds and door dialogs all have no-op defaults and the editor
implements none of them, so nothing is presented — but the server does see an "Admin" player
moving around, exactly as it did with the web page.

### Authenticating as admin

`ws.isAdmin` came from an Express session flag that `/admin.html?admin=true` set in a
browser. A native app has no such session, so `grantsAdmin` in `server/websocket.js` accepts
an `?adminKey=` on the handshake:

- with `ADMIN_KEY` set on the server, the key must match (compared with `timingSafeEqual`);
- with no `ADMIN_KEY` set, only **loopback** connections are granted.

So `npm run dev` needs no configuration and production has to opt in. A key is always
required — a blank field means no admin, on any host. The editor's host and key live in the
sidebar and persist in `UserDefaults`.

**The `init` payload now carries `isAdmin`**, and the sidebar turns red with an explanation
when it is false. Without it a refused key is invisible: the editor connects, renders the
map, accepts every drag, and the server silently discards all of it.

Testing the refused path caught a bug that would have shipped. The editor asked for a
character with a *blank* name, relying on the server's `if (!playerName && ws.isAdmin)
playerName = 'Admin'`. On a connection the server had **not** promoted, that fell through to
the letters-only name check, which rejected it and closed the socket — so the editor
reconnected, was rejected again, and looped forever with no world and no way to say why. It
now sends `"Admin"` explicitly. `Renderer.presentBlank` also fires `captureHandler` for the
same reason: a `-shot` of a session that never got a world is exactly the frame worth having,
and it used to wait forever.

### Three deliberate deviations from `admin.js`

Each one is a case where copying the JS faithfully would have produced something worse:

- **The dropped tracing image is anchored in world space.** The JS drags it by a *world*
  delta but draws it at those numbers in *screen* space, so it is pinned to the window and
  slides out of alignment the moment the map is panned or zoomed — it only lines up at
  zoom 1, having never been moved. Here the origin is a world position projected like
  everything else.
- **Every object in a multi-selection is highlighted.** The JS colours only
  `selectedObject.get()`, the first id, so a shift-click selection is invisible even though
  dragging moves all of it.
- **Plain two-finger scroll pans.** `admin.js` zooms on ⌃-scroll and has no scroll gesture
  otherwise. Both of its behaviours are kept (drag to pan, ⌃/⌘-scroll to zoom, and pinch);
  plain scroll panning is added because a trackpad Mac app that ignores two-finger scroll
  reads as broken.

The floating draggable panels are also gone, replaced by a docked sidebar in an
`NSSplitViewController`. That removes the panel-drag bookkeeping and the "was this click on a
panel?" test every mouse handler in the JS has to run.

### Verified behaviour (local server, `-selftest`)

`simctl` cannot inject a touch, and neither can anything drive a Mac app's mouse from a
script — so, following the pattern of `-walktest` and `-tennisdemo`, `-selftest` calls the
*real* handlers a click would have called and logs each result. Run against
`PORT=8099 node server.js`:

```
selftest  1: world objects=24 npcs=24 selectedObject=[] selectedNpc=nil
selftest  2: clicked object 12 at world (-2095, -1254) → selection [12]
selftest  3: dragged object 12 by dx=60 (expected 60) → (-2035, -1254)
selftest  4: restored object 12 to (-2095, -1254)
selftest  5: resized object 12 from 759×202 to 799×162
selftest  6: restored object 12 to 759×202
selftest  7: clicked NPC 1 'Mr Hardy' → selection Optional(1)
selftest  8: dragged NPC 1 by dx=30 (expected 30)
selftest  9: restored NPC 1 to (-936, -376)
selftest 10: NPC 1 'Mr Hardy' on_enter=1 actions ["avatar"], on_exit=1
selftest 11: created object 80 → count 24 → 25
selftest 12: selected created object → [80], inspector sees id Optional(80)
selftest 13: event tree round-tripped: 2 actions ["say", "log"], say=["selftest line one", …]
selftest 14: deleted object 80 → present=false count=24
selftest 15: left object 12 selected for inspection
```

`objects.json` comes out **byte-identical** afterwards — create, edit and delete round-trip
cleanly. `npc.json` does not, because dragging rounds Mr Hardy's authored float position to
an integer; the web admin does exactly the same (`Math.round` in its `mousemove` handler).

Step 5 is worth reading twice: pulling the handle out by (+40, +40) in world space grows the
width by 40 and *shrinks* the length by 40, because object 12 is rotated 90°. That is the
local-frame resize maths behaving correctly, not a sign error.

### Screenshots without a Screen Recording grant

`-shot <path> [-shotdelay <s>]` writes a PNG of the whole window and quits. It exists because
`screencapture` needs a TCC grant this machine's terminal does not have, and neither
`cacheDisplay` nor `CGWindowListCreateImage` captures Metal content anyway. The frame is
composited from three layers: the AppKit chrome and sidebar via `cacheDisplay`, the Metal
drawable blitted to a shared texture and read back, then the editor overlay on top — in that
order, because the overlay is an ordinary `NSView` that the world image would otherwise
cover. `Renderer.captureHandler` is the one engine hook this needed; the view has to be
created with `framebufferOnly = false` for the drawable to be a legal blit source.

Photographed and confirmed: the Junior Campus map with its walk-through zones in green,
unnamed collision volumes in purple and 3D-model objects in sky blue; the selected NPC's
cyan hitbox and dashed interaction radius; the NPC inspector fully populated for Mr Hardy
(head `male_hair_messy`, interact 150, roam none); and the object inspector for object 12
"Pool" showing its `on_enter` `show_dialog` card — description "Enter the Pool building?",
type `change_map`, map ID 3 — read straight out of the authored JSON.

## What Phase 8 actually delivers

The web client is gone. 264 MB of assets moved from `client/public` to **`server/assets/`**,
the three generator scripts and the one remaining static mount were repointed at it, and
`client/` was deleted — 302 tracked files, plus 26 GB of untracked Xcode DerivedData belonging
to the retired Capacitor shell.

**Not one asset URL changed.** The tree is still mounted at the root, so
`/media/laser.mp3`, `/minimaps/0.png`, `/models/heads/female_hair_bun.glb` and
`/junior_school/chunks/background_0_0.jpg` resolve exactly as before. No Swift file needed
editing for this phase — which was the point of doing the emote and physics moves first.

| Change | Detail |
|---|---|
| `server/assets/` | The whole tree, moved as a git rename so history follows it |
| `static.js` | Four mounts and routes became one. The `/src` mount (the web client's JavaScript), the `/public` mount (unused — the `public/` prefix in `sound.js` was a Capacitor *bundle* path, never an HTTP one), the `/src/physics.js` route and the `admin.html` EJS render are all gone |
| `server.js`, `server/views/` | The EJS view engine and `views/index.ejs` deleted; `ejs` dropped from `package.json` and the lockfile regenerated, or `npm ci` in the Docker build would have failed on the mismatch |
| `scripts/*.js` | `basePath` → `../assets` in `slice_maps.js`, `create_overlays.js`, `generate_minimaps.js` |
| `.gitignore` | The chunk rule follows the tree (`server/assets/**/chunks/`); the `client/ios` Capacitor exclusions are gone. It also had a pasted terminal transcript in the middle of it and a second copy of itself after that — removed |
| `.dockerignore`, `Dockerfile` | The `client/*` exclusions replaced by `native/`, which has no business in the server image |
| Root `package.json` + lockfile | Existed only to hold `@capacitor/ios`. Deleted with the shell |
| Eight root codemods | `fix_closure*.js`, `inject_imports.js`, `cache_draw_proxies.js`, `clean_main_ui.js`, `fix_shadows.patch` — one-off scripts that read `client/public/src/*.js`, dead the moment it stopped existing |

### Verified behaviour (local server, both apps)

The server boots, slices and finds every asset at the new root, and serves them:

```
[OverlayGen] Finished generating overlays!     ← found all five clip masks under server/assets
/junior_school/chunks/background_0_0.jpg  200  82141b  image/jpeg
/models/heads/female_hair_bun.glb         200  2605052b
/minigames/tennis/map.svg                 200  2367959b  image/svg+xml
/media/laser.mp3                          200  85817b    audio/mpeg
/api/config                               200  166b
/src/main.js  /src/physics.js  /admin.html      404       ← the web surface is closed
```

Both targets build. `-walktest` on the simulator against it: tiles stream, the clip mask
rasterises, the player walks and is blocked, zero errors — the Phase 1 numbers.

```
Map 'Junior Campus' loaded: 1 chunked layer(s), 4372.0x3841.0
Clip mask loaded: junior_school/clip_mask.svg
walktest t=1.8s pos=(-908.0, -224.8) heading=79°  moved=89.4px mask=loaded blocked=no
walktest t=3.8s pos=(-954.0, -37.4)  heading=169° moved=0.8px  mask=loaded blocked=YES
```

Screenshotted on device: tiles, the 3D props, the character with its glTF head and shoes,
shadows, nameplates and the button bar all render from the new root. The macOS editor's
`-selftest` passes all its steps against it, and `objects.json` comes back byte-identical.

### Keyboard movement in the macOS editor (2026-08-08, user's request)

The editor could only pan by dragging. It now walks with the keyboard, through the shipped
movement code rather than a second implementation.

| File | Notes |
|---|---|
| `Engine/Core/InputState.swift` | Gained `turn` and `forward`. The two input styles are the two branches of `getDemandedMovementVector` (`input.js:33-56`): a thumbstick sets the heading directly and always walks forward, and it suppresses the keys entirely — exactly as `TouchMove` takes the whole branch in the JS |
| `Engine/World/GameState.swift` | Applies `turn × rotationSpeed × timeScale` (`main.js:314-321`) and scales the movement vector by `forward`, so ↓ drives astern the way `getDemandedMovementVector`'s `dx -= cos(...)` branch does |
| `JoelsWorldAdmin/Editor/KeyboardMovement.swift` | The held-key set. `keyDown`/`keyUp` only maintain it; the frame loop polls — a held key gives smooth motion instead of the OS's key-repeat stutter, which is what the JS's `isPressed` polling bought |
| `AdminEditorView` | Key events, and the two places a key gets stuck: resigning first responder and the window losing key. `input.js` clears on `window`'s `blur` for the same reason |

Worth knowing:

- **Dragging still pans through walls; the keyboard does not.** Drag writes the camera focus
  directly, which is what you want when framing a shot. The keyboard goes through
  `processMovement`, so the editor's avatar is blocked by the real clip mask — which is what
  you want when testing one.
- **Typing in an inspector field does not walk the camera.** The sidebar's text field takes
  first responder while it is being typed into, so key events never reach the editor view.
  This is the AppKit equivalent of the JS's `isChatFocused` guard, and it is free.
- **WASD is an addition, not a port.** The browser build only ever bound the arrows. Codes are
  matched physically (`NSEvent.keyCode`), so WASD stays under the same three fingers on a
  non-QWERTY layout.
- The turn rate is the JS one: `rotationSpeed` 3 × `timeScale` per frame, i.e. 180°/s at 60 fps.

Verified by two new `-selftest` steps, which drive the real handlers with synthesised
`NSEvent`s — there is no way to inject a keystroke into a Mac app without an Accessibility
grant, the same constraint that produced `-walktest`:

```
selftest 14: held ← 1.0s: rotation 0° → -189° (Δ-189°, expected negative)
selftest 17: held ↑ 1.0s on heading -189°: moved 189px to (-1202, -111)
```

**Both steps need the editor window to be frontmost**, because a background window drops its
keys on purpose. A run launched behind the terminal reports Δ0° and 0 px — so each step now
reads the key back before releasing it and appends *"key released early: the window was not
frontmost"* when that is what happened. A silent Δ0 reads like a broken key handler and is
not.

### One bug this caught

**The editor scattered cache directories into whatever folder it was launched from.**
`URLCache(memoryCapacity:diskCapacity:diskPath:)` takes a *relative* path; on iOS that lands
in the app's caches directory, but an unsandboxed macOS process resolves it against the
current working directory. Running the editor from the repository left `joelsworld-tiles/`
and `joelsworld-models/` — a `Cache.db` and its tile blobs — in the repo root, in `native/`
and in `server/`. `Engine/Core/DiskCache.swift` now anchors both explicitly under the caches
directory, so the two platforms agree.

## Build / run

The iOS game:

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

The macOS admin editor:

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorldAdmin -destination 'platform=macOS' build
```

**Both targets must keep building.** They share `native/Engine/`, so an engine change that
compiles for one can fail on the other — the platform-conditional spots are listed under
Phase 9 above.

Install and launch on a booted simulator:

```bash
xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/JoelsWorld.app && xcrun simctl launch booted com.allr.joelsworld
```

**DEBUG launch arguments** (added for automated verification — no GUI simulator was
available to inject touches):
- `-autojoin <Name>` — skip the lobby and create a character straight away.
- `-walktest` — drive synthetic joystick input sweeping 360° and log position/collision
  every 0.5 s.
- `-zoom <n>` — pin the camera zoom, so a screenshot can be framed the same way the web
  client frames one (`window.camera.zoom = n` in the browser) for side-by-side comparison.
- `-at <x> <y>` — drop the player at a fixed world position on spawn, so both clients can be
  framed identically and the two images diffed.
- `-noshadows` / `-nossao` — switch the Phase 3 passes off to isolate which stage a parity
  difference comes from.
- `-npctrace` — log every roaming/patrolling NPC once a second (position, target, wait timer,
  waypoint index), so the Phase 4 behaviour port can be checked from the log.
- `-autoconfirm` — answer yes to any `show_dialog` a second after it appears. `simctl` cannot
  inject touches, and this is the only path to a map change.
- `-emotedemo [seconds]` — steps the player through all 20 emotes in turn, via the same
  `/command` path the picker uses, so the pose, the chat line and the sound are all exercised.
- `-emote <name>` — holds one emote from spawn, re-issuing it as it expires, so a single pose
  and its props can be framed for a screenshot.
- `-emotedump` — poses every emote once at a pinned instant (elapsed 1234 ms, `Date.now`
  1700000000000, heading 45°) and logs the limb targets, body pivot and every prop. Exists to
  be diffed against the same numbers out of `emotes.js`; see below.
- `-map <id>` — requests a map change as soon as the first world arrives. The way into a
  minigame without walking to its door.
- `-tennistrace` — logs the tennis point once a second: ball, serve state, both rackets, score.
- `-tennisdemo` — plays the player's side by "tapping" the predicted intercept four times a
  second, through the same `handleTap` the touch handler calls. Rallies do not happen without
  it, because nothing else moves the player.
- `-exitafter <seconds>` — presses the minigame's exit button on a timer, so the dialog and
  the map change back out can be driven with `-autoconfirm`.
- `-uidemo` — walks the Phase 5 UI through every surface on a timer (chat feed, bubble, each
  dialog, minimap, rejection flash, an emote command, the door prompt), logging each step so
  screenshots line up with the log. Also the only way to open a dialog without touch input.

**macOS admin launch arguments** (`-map`, `-zoom` and `-at` are shared with the iOS build,
since they live in `Engine/Core/WalkTest.swift`):
- `-selftest` — drives selection, dragging, resizing, creation, an event-tree round trip and
  deletion through the real mouse handlers, then a keyboard turn and walk through the real key
  handlers, logging each step. Leaves the map as it found it.
- `-select object|npc <id>` — selects an entity on the way in, so a scripted `-shot` can frame
  an inspector, or an NPC's rings and patrol route. Clicking is the only other way in, and
  nothing can click from a script.
- `-shot <path>` — writes a PNG of the whole window and quits.
- `-shotdelay <seconds>` — how long to wait first, so tiles and models have loaded. Default 6.
- `-map <id>` — open straight onto a map. The server remembers the last map a session was on,
  so this is the only way to make a scripted run deterministic.
- `-zoom <n>` — pin the camera zoom; `0.3` frames most of Junior Campus at once.

Reading the editor's log — it goes to stdout when launched from a terminal:

```bash
"/path/to/Joels World Map Editor.app/Contents/MacOS/Joels World Map Editor" -selftest -map 0 -zoom 0.3
```

**Reproducing the Phase 6 parity check.** `emotes.js` only needs three.js for its props, so it
can be driven under Node rather than in a browser: read the file, strip its four `import`
lines, prepend a stub `THREE` (`Vector3` with `set`/`copy`/`setScalar`, an `Object3D` with
`position`/`rotation`/`scale`/`material`/`children`/`add`/`clone`, the five geometry
constructors and the three material constructors — all as `function`s, since they are called
with `new`), a `getCharacterProxy` returning a fake mesh group, and a `document.createElement`
stub for `love`'s canvas. Pin `Date.now`, build a rig with the neutral targets
`updateCharacter3D` restores, and call `emotes[name].updateLimbs3D`. Then diff against
`-emotedump`. The harness is throwaway and lives in the session scratchpad.

**Reproducing the Phase 3 parity check — no longer possible.** It needed a running web client
to diff against, and Phase 8 deleted it. Recorded because the *method* is the thing worth
keeping: if a future parity question needs it, check the client out of git history
(`git worktree add ../old-client <commit-before-deletion>`) and serve `client/public` from a
throwaway static server rather than trying to resurrect it in the tree.

1. `cd server && PORT=8099 node server.js`, and point the app at it with
   `Config.useLocalServer = true` / `localHost = "localhost:8099"`.
2. Open the client at 402×874 — **the browser window must be under ~1070 px tall**, or the web
   camera's `far = 2000` clips the ground plane entirely (`orbitDistance = height × 1.866`)
   and you get a blank green frame. That is a real quirk of the web build, not a setup mistake.
3. In the console, `import('/src/main.js')` and `import('/src/characters.js')`, set the camera
   the way `draw()` does, call `characterManager.drawCharacters(...)`, then `composer.render()`
   and `gl.readPixels` in the same tick. Do **not** rely on the page's own rAF loop — a
   backgrounded tab throttles it to nothing and the canvas stays blank.
4. Serve the simulator screenshot from `client/public/` so the page can load it, and diff in a
   2D canvas. Delete it afterwards.

Reading logs (note `--level info`, or `os.Logger` entries are invisible):

```bash
xcrun simctl spawn booted log stream --level info --predicate 'subsystem == "com.allr.joelsworld"' --style compact
```

The app targets `wss://joels-world.com`. Set `Config.useLocalServer = true` in
`Engine/Core/Config.swift` to point at a local `npm run dev` (and `localHost` if it is not on
port 80). The macOS editor takes its host and key from the sidebar instead, persisted in
`UserDefaults` — the compile-time flag does not affect it.

## Environment gotchas (cost real time — read these)

- **Metal toolchain is a separate download in Xcode 27.** A clean machine fails with
  `cannot execute tool 'metal'`. Fix: `xcodebuild -downloadComponent MetalToolchain`
  (839 MB). Already installed here.
- **iOS 27 requires UIScene lifecycle adoption.** The classic window-based
  `UIApplicationDelegate` traps at launch (`EXC_BREAKPOINT` in
  `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`). Handled via
  `SceneDelegate.swift` + `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`.
- **Do not name a model type `Character`** — it shadows Swift's `Character` and breaks any
  string parsing in the module. The model is `GameCharacter` for this reason.
- **BSD `sed` has no `\b`.** Use `[[:<:]]` / `[[:>:]]` for word boundaries.
- The Xcode project uses `objectVersion 77` **filesystem-synchronized groups** — new files
  under `native/Engine/`, `native/JoelsWorld/` or `native/JoelsWorldAdmin/` join the right
  target automatically, no pbxproj editing needed. `Engine` is listed in *both* targets'
  `fileSystemSynchronizedGroups`, which is why the split is by folder and not by a list of
  membership exceptions: a new engine file is shared without anyone remembering to say so.
- **`window.contentViewController = …` resizes the window to that view's fitting size.** Set
  the frame *after* assigning it, or the editor opens at whatever the sidebar's stack asks
  for. `setFrameAutosaveName` then restores a frame the operator saved, which is why
  `AdminWindowController` calls `setFrameUsingName` and only falls back to the default.
- **Timers do not fire during AppKit button tracking.** `NSButton.mouseDown` runs the run
  loop in `.eventTracking`, so `HoldButton` adds its repeat timer to that mode as well as
  `.default`. Without it, holding − or + fires exactly once.
- **Restarting the local server is the only way to reload `server/data`.** The maps are read
  into memory at boot and written back from memory, so `git checkout -- server/data` while a
  server is running desynchronises the two and the next write puts the stale copy back.
- No `xcodegen`/`tuist` installed; the pbxproj is hand-written.
- The iOS-simulator MCP panel crashed repeatedly and became unusable — still true in Phase 7,
  including its headless `tap`. Screenshots via `xcrun simctl io <udid> screenshot out.png`
  work fine, but **there is no way to inject a touch**, which is why every interactive path
  needs a `-…demo` launch argument to drive it.
- **The simulator cannot render emoji.** Every emoji comes out as a `.notdef` box, on a fresh
  `simctl erase` too. Handled in-app by `UI/EmojiImage.swift`; do not spend time on it again.
- **The server remembers the last map.** A session that ended in Tennis resumes into Tennis,
  so `-walktest` on a fresh launch may find itself in a minigame with nothing to walk in.
  Pass `-map 0` alongside it.
- Watch out for the simulator switching to another app mid-run — a backgrounded app stops its
  `MTKView` display link, which freezes the simulation and makes a trace look like a hang.

## Known gaps / next steps

**Every phase is done.** What follows is the standing list of known gaps, none of them
blocking; items struck off it since are written up in their own sections above.

**The deployed server still speaks the pre-Phase-10 protocol**, so the shipped apps can only
reach a local one until `server/deploy.sh` is run. That is the one outstanding *operational*
item, and it needs a decision to deploy rather than any more engineering.

Phase 8 and 10 leave these open:

- **`assets/` is 247 MB, of which `tools/assets/stage.sh` ships 155 MB inside each app.**
  Moving the map chunk tiles to a bucket is the obvious win, and a bigger one now that the
  tiles are the only large thing left.
- **The chunk, overlay and minimap generators write into `assets/`.** They always wrote into
  the asset tree; it is just worth knowing that the tree is no longer purely authored content,
  and that `assets/**/chunks/` is gitignored for that reason.
- **`server/emotes.js` is still a second copy of the emote *names*.** With the web client's
  `emotes.js` deleted there is no drift risk left between JS files, but the names now have to
  stay in step with `Engine/Entity/Emotes.swift`, which owns the poses. A new emote is two
  edits.

Phase 9 leaves these open (four others were closed on 2026-08-08 — see "Four editor gaps
closed"):

- **There is no undo.** Every edit writes the map JSON immediately, as `admin.js` did — the
  delete confirmation is the only safety net. A local undo stack would have to model the file
  writes to be honest about what it can take back.
- **`AdminOverlayView` redraws on every frame.** Twenty-odd projected quads through Core
  Graphics at 60 Hz is nothing today, but it is the obvious first thing to throttle if a map
  ever carries hundreds of objects.
- **Only the selected NPC's route is drawn.** Showing every patrol at once would make a busy
  map unreadable, but a "show all routes" toggle would help when laying several out together.
- **A null in an update writes `"key": null` rather than removing the key.** The inspectors
  send an explicit null to *clear* `roam_radius` and `default_emote`, and their comments say
  the server used to delete the key. `server/admin.js` is gone, so which it really did cannot
  be checked — and `main_building/npc.json` carries one authored `"default_emote": null`,
  which is weak evidence that it stored them. Left as it is rather than changed on a guess.

**Tag was deleted, not deferred** (user's direction, 2026-08-08) — the map, its art, its
`maps.json` entry, the `MinigameKind` case and Archie, the NPC whose only content was its door.
The minigame plumbing it would have used is still in place if a redesigned Tag ever arrives:
`Minigame`, `MinigameHost`, the exit button, and the `usesWorldRenderer: true` branch. The old
`tag.js` is in git history (any commit before the deletion) if its rules are wanted as a
reference; two things about it were worth writing down at the time:

- **Tag rendered with `renderer.render()`, not `composer.render()`** — no SSAO — and it never
  repositioned the spotlight, so the light stayed wherever the previous map's last frame left
  it. What the map looked like depended on where you had been standing before you walked in.
- **Tag's camera** used `pitch + 0.60`, zoom 1.2, no map clamping and no Y bias, unlike the
  overworld camera. `Camera` would need a free-focus variant.

Phase 7 leaves these open:

- **The court bitmap is rasterised at every launch** (~2.4 MB of SVG, once, off the main
  thread). Caching the PNG on disk — or bundling it, since `SVGImage` already checks
  `Bundle.main` first — would remove the wait, during which the court shows as flat grass.
  The JS has the same gap; it draws nothing until the image decodes.
- **`Canvas2D` transforms the whole path through the inverse CTM on every fill and stroke.**
  Correct, and the only way to get canvas semantics, but it allocates a `CGPath` per paint
  call. Fine for two characters; it would matter if this surface ever drew a crowd.
- **The tennis map's `character_scale` is ignored**, because the 2D drawing path has its own
  fixed `camera.zoom × COURT_SCALE`. Matches the JS.
- **`-tennisdemo` taps the intercept point directly rather than a screen coordinate**, so it
  exercises `handleTap` but not the screen→game inversion in `TennisView.courtTapped`. That
  one line is still only verified by reading it; injecting a real touch needs the simulator
  panel to work again.

Phase 6 leaves these open:

- **`emoteProps` is rebuilt every frame rather than retained.** three.js keeps the meshes and
  mutates them; the port re-emits `PropDraw`s each frame and the renderer looks up a shared
  GPU mesh per geometry. Equivalent output, and the allocation is a few dozen structs per
  emoting character — but it is the one place the port's shape differs from the JS.
- **`-emote`'s re-issue timer restarts a held emote on its duration**, which clears the
  footprint pool with it. That is `resetForEmoteChange` doing its job, but it means a long
  `wet` screenshot shows one or two prints rather than a trail.
- **Emote expiry runs for every character, not just visible ones.** The JS expires inside its
  draw call, so an off-screen NPC keeps a finished pose until it comes back into view. The
  difference is not observable in normal play.

Carried forward from Phase 5:

- **Audio session category is `.playback`**, matching what Capacitor's `NativeAudio` gave the
  old build: the music keeps playing with the ring switch on silent. Change to `.ambient` if
  that turns out to be the wrong call for a kids' game.
- **The chat feed has no scrollback.** Five messages, thirty seconds, gone — the JS behaviour.
  Nothing keeps a history.

Carried forward from Phase 4:

- **`say` does not reach the chat feed, by design.** The JS `say` handler only sets
  `chatMessage` / `chatTime` on the source, which the bubble renderer reads — an NPC talking to
  you gets a bubble, not a line in the feed. Phase 5 draws that bubble.
- **Object trigger zones nest and only the innermost counts.** Standing in the pool's water is
  standing in the pool building too, and `actuallyInObject` returns one object, so entering the
  water fires the building's `on_exit`. That is the JS behaviour, reproduced deliberately.

Carried forward from Phase 3:

- **glTF material extensions no longer explain the residual difference.** All four are
  implemented (2026-08-08, see above); transmission is approximated without a backdrop pass,
  and `specularTexture` is still ignored. Whatever is left on glass and trim is elsewhere.
- **SSAO runs at full resolution with 32 samples**, as the JS does. It is the most expensive
  pass by far and the obvious first lever if a device drops frames; half-resolution AO with an
  upsample is the standard fix and would be invisible at this blur radius.
- **Non-chunked single-image map layers** are still parsed and skipped. No shipping map uses
  them, so this stayed out of Phase 3 despite being listed under it.

Carried forward from Phase 2, deliberately:

- **`female_hair_short_2` has no `.glb`.** The table entry is kept deliberately — deleting it
  would shift every other female character's deterministic head choice. Characters that hash
  onto it render headless, exactly as they did on the web.

Smaller known gaps:

- Overlay layers ignore the `spring` parallax flag (the JS passes spring into `drawLayer`
  but never uses it — dead parameter, safe to keep ignoring).
- Characters are drawn one `drawIndexedPrimitives` per part (~16 per character, plus ~5 per
  head). Fine for the 25 characters on screen today; instancing is the obvious lever if a
  crowded map ever stutters.
- `MapManager` rebuilds the visible-chunk list every frame and allocates a fresh array.
  Fine at current scale; revisit if profiling shows it.
- Nameplates and bubbles are pooled `UIView`s repositioned each frame — the same approach the
  JS takes with DOM nodes. Fine for the ~25 characters a map holds; if a crowd ever makes this
  show up in a trace, they become Metal-drawn quads.
- The `Resources/` folder holds one file (`pricedown.otf`). It joins the bundle automatically
  through the synchronized group, and the font is registered at runtime because the target
  generates its `Info.plist` and there is no `INFOPLIST_KEY_` for `UIAppFonts`.

## Phase 8 decoupling — how it was unpicked

All three couplings are cleared and `client/` is deleted. Kept as a record of what the
dependency actually was, since none of it is visible in the tree any more.

**1. `physics.js` (2026-08-07).** `server/websocket.js` imported the client's physics engine
across the directory boundary. It moved to `server/physics.js` as the single source of truth
— Node imports it directly (`websocket.js:6`, `managers/NPCManager.js:4`,
`managers/AIAgentManager.js:5`), and the browser was served the same file at its unchanged
`/src/physics.js` URL until the client went. `loadClipMask` no-ops under Node rather than
throwing; the server never mask-tests.

**`Engine/World/Physics.swift` and `server/physics.js` must stay behaviourally identical.**
This is the one live duplication the rewrite leaves behind, and it is deliberate: the server
needs collision in JavaScript, the clients need it in Swift.

**2. The emote list (2026-08-08).** `static.js` and `AIAgentManager.js` used to scrape the 20
names out of `client/public/src/emotes.js` with a regular expression. `server/emotes.js` holds
them now. The names have to stay in step with `Engine/Entity/Emotes.swift`, which owns the
poses — a new emote is an edit to both.

**3. The asset tree (2026-08-08).** 264 MB moved from `client/public` to `server/assets/`,
and `static.js` mounts it at the root so no URL changed. Details in "What Phase 8 actually
delivers" above.

**`admin.js` decision superseded (user, 2026-08-08): it became a macOS app.** The 2026-08-07
decision that it would stay a web page is what had been keeping `client/` alive; reversing it
is what let Phase 8 delete the directory outright rather than keep a page served for the
editor.

Historical caveat, now moot: the legacy Capacitor shell bundled `client/public` as its
`webDir`, so a fresh `npx cap sync` after the physics move would have produced a bundle
without `physics.js`. The shell was never patched, and was deleted with everything else.

## Work log

### 2026-08-07
- Read and mapped the whole JS client; wrote `PLAN.md` (renderer trade-off, coordinate
  system, module map, asset pipeline, 8-phase roadmap).
- Hand-wrote `JoelsWorld.xcodeproj` (objectVersion 77, synchronized groups).
- Implemented Phase 1: net, physics, clip mask + SVG rasteriser, map streaming, camera,
  Metal renderer, joystick, lobby.
- Fixed: Metal toolchain missing, UIScene lifecycle trap, `Character` name collision.
- Verified end-to-end on iPhone 17 simulator against the live server — map renders, tiles
  stream, player moves, collisions block and slide, clip mask rasterised from SVG.
- Moved `physics.js` from `client/public/src/` to `server/` and repointed the three server
  imports; added the `/src/physics.js` route so the web client is untouched. Verified: all
  server modules import cleanly, a local server boots, `/src/physics.js` serves 200
  (`application/javascript`, 25 KB) alongside the rest of `/src`, and a real WebSocket
  session created a character and received `init` (24 NPCs, 24 objects) with a bogus
  99999,99999 move rejected server-side.
- Recorded the user's `admin.js` decision: stays a web page.
- **Phase 2 complete.** Scanned all 40 GLBs to confirm the no-skinning assumption before
  writing anything. Wrote the glTF loader, procedural mesh factory, model store, character
  rig, 2-bone IK, walk cycle, clip-mask MSL shader and remote interpolation; replaced the
  Phase 1 placeholder box.
- Verified Phase 2 numerically against the live web client rather than by eye — ran the JS
  locally, read its three.js rig state and called its own functions, and diffed the Swift
  output (IK joints, walk-cycle targets, appearance hash, model rotations). All match.
- Added the `-zoom` debug argument to make that side-by-side framing possible.
- Fixed `Config.localHost`, which pointed at port 5173; `npm run dev` binds port 80.
- **Phase 3 complete.** Spotlight + PCF shadow map, SSAO, 3D map props, and the move to a
  linear colour pipeline. The renderer is now five passes.
- Verified against the live web client by pixel diff rather than by eye: framing aligns
  exactly (dx=0, dy=0) and the whole-frame mean absolute difference is 8.9/255. Confirmed the
  lighting model separately by rendering known albedos through an identical three.js light rig
  and matching the numbers (131 / 135 / 136).
- That diff caught two real bugs: glTF textures were being flipped vertically (glTF UVs are
  already top-left origin, so this mirrored V and made every atlas-packed building surface
  sample the wrong region — the reported "roofs aren't rendering"), and
  `KHR_texture_transform` was composed rotate-then-scale instead of scale-then-rotate.
- Added `-at <x> <y>`, `-noshadows` and `-nossao` debug arguments, and `ModelStore.request`,
  which stops the render loop queueing a callback per frame while a model is in flight.
- **Phase 4 complete.** Event interpreter, NPC roaming and waypoints, proximity and trigger-zone
  interactions, emote state, map transitions, and badge tracking. No renderer changes.
- Fixed `applyTick`, which set interpolation targets for NPC ids too — the server never sends
  NPC positions, and doing so would have overridden every roam target the moment Phase 4
  started setting them.
- Verified on device against the live server rather than by reading the diff: waypoint indices
  and offsets stepped through Mr Savage's full six-step cycle exactly as authored, roam
  destinations stayed inside the radius, `on_enter`/`on_exit` fired with all four placeholders
  substituted, a `rate_limit: 60` log fired once across four approaches, and walking into the
  pool's water set `swim`, held it through four seconds of swimming, then swapped it for `wet`
  on the way out.
- Drove a full map transition end to end (trigger zone → dialog → `change_map` → fresh `init`
  → Pool map, NPCs, clip mask and background audio), using two new debug arguments,
  `-npctrace` and `-autoconfirm`, since `simctl` cannot inject touches.
- **Phase 5 complete.** `AVAudioEngine` sound, the chat feed and field, NPC portraits,
  nameplates and speech bubbles, the emote/badges/help/minimap dialogs, the button bar, the
  rejection flash and the disconnect dialog. Restyled the lobby and door dialog onto the glass
  theme and bundled Pricedown so the native UI reads as the same game.
- Added `-uidemo`, which opens every UI surface on a timer — the only way to photograph a
  dialog when `simctl` cannot tap and the simulator MCP panel is unusable.
- That verification pass caught three bugs from earlier phases: palette PNGs never decoded (so
  the Main Building and part of the Pool rendered as blank colour — `TextureCache` now falls
  back to Core Graphics), a player last seen in the Tennis map could not load at all (its
  `mapData` has no `width` and the whole `init` frame threw), and a `UIButton` title could not
  be changed after creation on current iOS.
- Corrected a wrong first diagnosis on the way: the tile failures looked like concurrent
  decoding, and serialising `MTKTextureLoader` did nothing. Dumping the bytes showed valid
  PNGs, and reading their headers showed colour-type 3. The serialisation was reverted.

### 2026-08-08
- **Phase 6 complete.** All 20 emotes (not ~30 — that estimate was wrong) pose the rig, spawn
  their props and play their sounds; the `/command` path now posts the chat line each emote
  broadcasts, with the nearest character resolved as its target.
- Made the rig stateful (`RigRuntime`), since three.js keeps the body pivot, head rotation and
  the dance notes' accumulated spin on retained `Object3D`s between frames.
- Added the prop system: 22 shared geometries (three new `MeshFactory` primitives — cylinder,
  circle, torus — plus geometry-space rotation baking), six anchor spaces, a ❤️ sprite texture,
  camera-facing billboards, and a third blended sub-pass so transparent props sort after the
  opaque rig.
- Wired the lifecycle `GameState` owns: emote expiry, `default_emote` as an NPC's resting pose,
  and `onEnd` — which is what puts the tennis racket down.
- Verified numerically rather than by eye, by running the real `emotes.js` under Node against a
  stub three.js with the clock pinned, and diffing against a new `-emotedump`. Every body
  pivot, rotation, head rotation and limb target matches to 4 decimal places across all 20
  emotes, and so does every one of the 71 props' position, scale and opacity.
- Reproduced two JS behaviours deliberately: props within an emote share one material, so their
  opacities alias to the last value written (visible on `cry`, `love`, `swim`, `sleep`, `eat`,
  `wet`); and `swim`'s ripple rings stand on their side, because `rotateX(π/2)` is applied to a
  torus that was already flat in this game's Z-up space.
- That work caught one real bug: `drawableCharacters` never copied `player.emote` onto the
  local player's appearance record, so the player would have been the one character whose
  emotes did not pose.
- Added `-emotedemo`, `-emote <name>` and `-emotedump`; screenshotted `laser`, `love`, `sleep`,
  `swim`, `tennis`, `laugh` and `wet` on device to confirm every prop anchor actually renders.
- Noted for later: the "no chat line" observation during the demo was the server, not the port
  — `ChatManager.js:37` drops any line sent within 2 s of the last, and the demo fires every 2 s.
- **Phase 7 (Tennis) complete.** The minigame handover, a `CanvasRenderingContext2D`
  work-alike, the tennis simulation and its 2D renderer, the 2D humanoid, and the SVG
  rasteriser extensions the court art needed.
- Recorded the user's decision to defer Tag: *"Tag was rubbish and needs reworking."* Not
  ported; the plumbing it will need is in place.
- Extended `SVGRasterizer` from "path fills only" to arcs, `<rect>`/`<circle>`/`<ellipse>`,
  stroking and `<g>` inheritance, and replaced its quadratic `range(of:)` scan with a
  single-pass byte tokenizer — without which the 2.4 MB court never finishes parsing.
- Deviated from the JS in exactly one place, deliberately: tap-to-move inverts the court
  transform instead of raycasting a `threeCamera` that a minigame never configures. The
  faithful behaviour is a bug that makes the game unplayable.
- Found and worked around the simulator's missing emoji font, which turns all 23 of the UI's
  emoji — and `love`'s heart sprites, back in Phase 6 — into `.notdef` boxes. Bundled a
  Twemoji SVG fallback behind a one-time capability probe; real devices are unaffected.
- Re-verified the clip mask after the rasteriser rewrite (`-walktest`): loads, blocks, slides,
  same as Phase 1.
- Added `-map`, `-tennistrace`, `-tennisdemo` and `-exitafter`. Without touch injection —
  the simulator MCP panel is still unusable — a demo argument is the only way to reach any
  interactive path.
- **Recorded the user's change of plan on `admin.js`:** it becomes a Mac desktop app, which
  then allows the three.js renderer to be removed entirely. This reverses the previous day's
  decision that it would stay a web page.
- **Phase 9 complete.** Split the tree into `native/Engine/` (shared), `native/JoelsWorld/`
  (iOS) and `native/JoelsWorldAdmin/` (macOS), and added a second app target to the
  hand-written pbxproj with `Engine` listed in both targets' synchronized groups.
- The whole engine — renderer, glTF loader, physics, event interpreter, emotes, tennis
  simulation, SVG rasteriser — compiled for macOS after four small changes. `Net`, `World`
  and `Entity` needed none, which is what the Phase 1 "no renderer or UI types in those
  layers" rule was for.
- Ported `admin.js` in full: the overlay, the mouse handlers with their exact hit-test order
  and click-then-drag rule, the object and NPC inspectors, and the generic event-tree editor
  with all eight action types. Floating panels became a docked `NSSplitViewController`
  sidebar.
- Added `grantsAdmin` to `server/websocket.js` so a native client can present an `?adminKey=`
  on the handshake: it must match `ADMIN_KEY`, or come from loopback when the server has none
  set. The browser's session-flag path is untouched.
- Verified with `-selftest`, which drives the real handlers: hit testing, a 60-unit drag, a
  rotated-object resize, NPC select-then-drag, and a create → set-event-tree → delete round
  trip. `objects.json` comes back byte-identical. Run against a server with `ADMIN_KEY` both
  matching and deliberately wrong.
- Added `isAdmin` to the `init` payload and a red read-only banner in the sidebar, because a
  refused key is otherwise invisible — the editor renders and accepts edits that the server
  throws away. Testing that path found a real bug: the blank name the editor asked for is
  only substituted for a *promoted* connection, so a refused key failed name validation and
  the app reconnect-looped forever with no world.
- Built `-shot` on a new `Renderer.captureHandler`, because `screencapture` needs a Screen
  Recording grant this machine does not have and no view-snapshot API captures Metal. It
  composites AppKit chrome, the blitted drawable, and the overlay, in that order.
- **Phase 8 partly done:** moved the valid-emote list to `server/emotes.js` and repointed
  `static.js` and `AIAgentManager.js` at it. No code in `server/` reads `client/` any more.
- Corrected a wrong diagnosis along the way: a self-test run that "failed to create an
  object" was actually the local server holding stale in-memory map data after a
  `git checkout -- server/data` mid-session. The server reads the maps once at boot and
  writes them back from memory; restarting it fixed the run, and the self-test now matches
  the created object by unseen id rather than by name.
- **Phase 8 complete — the web client is retired.** Moved the 264 MB asset tree to
  `server/assets/` (as a git rename, so history follows it), repointed the three generator
  scripts and collapsed four static mounts and routes into one, and deleted `client/`.
- Deleted with it: `views/index.ejs` and the EJS view engine, the `ejs` dependency (with the
  lockfile regenerated — `npm ci` in the Docker build would otherwise have failed on the
  mismatch), the root `package.json` that existed only to hold `@capacitor/ios`, and eight
  root codemods that read `client/public/src/*.js` and were dead the moment it went.
- Dropped the `/public` mount rather than repointing it. Nothing fetches it: the `public/`
  prefix in `sound.js` was a *Capacitor bundle* path, not an HTTP one.
- Tidied `.gitignore` on the way past — its chunk rule now points at `server/assets`, the
  Capacitor exclusions are gone, and a pasted terminal transcript plus a second full copy of
  the file (58 stray lines) were removed.
- Verified nothing moved from the clients' point of view: the server boots and finds every
  asset at the new root, every URL the native code fetches still serves, the three retired
  web URLs 404, both targets build, `-walktest` reproduces the Phase 1 numbers on device, and
  the editor's `-selftest` passes with `objects.json` byte-identical.
- **Connected keyboard movement in the macOS editor** at the user's request. Extended
  `InputState` with the tank controls the web client had (`turn`, `forward`) and taught
  `GameState.update` to apply them, so the editor's camera-as-player walks through the shipped
  movement and collision code; dragging still pans freely through walls, which is the right
  split for framing a shot versus testing one. Arrows plus WASD, matched on physical key code.
- Added two `-selftest` steps that drive the real key handlers with synthesised `NSEvent`s:
  ← turned the heading 189° in a second (3°/frame, the JS rate), ↑ walked 189 px.
- That caught a bug older than this phase: the editor wrote its `URLCache` to a *relative*
  `diskPath`, which an unsandboxed Mac app resolves against its working directory — so every
  run left `joelsworld-tiles/` and `joelsworld-models/` wherever it was launched from,
  including three places in this repository. Both caches are anchored under the caches
  directory now (`Engine/Core/DiskCache.swift`).
- Read a Δ0° self-test result correctly on the second try rather than chasing it: the app had
  been launched behind the terminal, and a background window drops its held keys by design.
  The step now says so instead of reporting a silent zero.

## What Phase 10 actually delivers

**The server stops serving.** It hosted 264 MB of assets and put the whole authored world in
every `init` frame. It now does neither: both ship inside the apps, and it is a WebSocket relay
with two dependencies.

### The three trees

`server/` was holding content that was no longer its own. It is now code only:

| Tree | What it is | Who reads it |
|---|---|---|
| `assets/` | Art and audio, plus the full-size map layers the slicer consumes | `tools/assets/` writes it, `stage.sh` ships a subset |
| `data/` | `maps.json` and each map's `objects.json` / `npc.json` | The server reads and watches it; the apps bundle it; the editor writes it |
| `server/` | The relay, the managers, `physics.js`, `emotes.js` | Node |

`tools/assets/stage.sh` runs from a build phase in **both** targets and copies the shipped
subset into `GameAssets/` inside the app — 155 MB out of a 247 MB working tree. A script phase
rather than a folder reference: the ship-list is explicit and reviewable in one place, and
nothing is duplicated on disk.

### What each end lost

Server: `express`, `cookie-parser`, `sharp`, `static.js`, `admin.js`, `/api/config`, the HTTP
session middleware, `grantsAdmin`/`ADMIN_KEY`, and `isAdmin` in three places. `server.js` went
from 55 lines of middleware to 35 lines that answer a health check and hand the socket to `ws`.

Client: `DiskCache`, four `URLCache`s, `Config.assetBaseURL`, `Config.httpScheme`, and the
"bundle first, then the network" fallback in all six loaders. `AssetLocator` replaced the lot —
resolution is a path join, and a miss is a packaging bug rather than a network condition.

### The session middleware was leaking

`server.js` ran a session middleware on every HTTP request, and created a session for any
request without a cookie. Native clients send no cookies, so **every asset fetch minted a
session file**: 269 files containing `{}` were sitting in `server/sessions/`. Nothing read
`req.session` — the socket handshake does its own token lookup. It went with Express.

Sessions themselves are untouched, and are still how play state resumes.

### `init` is 650 bytes

It was the whole world. It is now `mapId`, `characters`, `myCharacter`; `WorldData` reads the
map, the map list, the objects and the NPCs out of the bundled `data/`, selected by `mapId`.

`objects_update` and `npcs_update` survive and now matter more. The server already watched
`data/**/objects.json` and `npc.json` (`MapManager.js:50`, `NPCManager.js:101`) and broadcast
on change — so the editor writing a file *is* the update path. That is the whole of "the server
only sends updates".

### The editor writes the files, and had to learn to write them properly

`WorldFileStore` applies the same fourteen operations `server/admin.js` did, to `data/` on
disk. It finds the checkout from `-data <path>`, then a remembered folder, then by walking up
from the app bundle; with none of those it says so in the status line and saves nothing.

The hard part was the serialiser, not the operations. These files are authored content under
version control and Node wrote them with `JSON.stringify(value, replacer, 2)`.
`JSONSerialization` would reorder every key — its objects are `Dictionary`s — turning a
two-line edit into a whole-file diff. `OrderedJSON` is an order-preserving JSON model with its
own parser and a writer that matches `JSON.stringify` byte for byte: two-space indent, `": "`,
`[]`/`{}` for empties, no trailing newline, `40` rather than `40.0` for a whole number, and JS
escaping rules. It is also lossless — records round-trip through it rather than through
`WorldObject`/`GameCharacter`, so fields the game does not model (an NPC's `agent` block) are
not quietly dropped by an edit, and a clone keeps them.

## Environment gotchas (Phase 10)

**A Mac app's `print` never reaches a pipe.** `-selftest` produced an empty log for four
attempts. The app was running fine; Swift block-buffers stdout when it is not a TTY and the run
was being `kill`ed before anything flushed. `os_log` did not help either — `Log` writes at
`.info`, which `log stream` does not show without `--level info`. What works is letting the app
*exit*: `-shot <path> -shotdelay <n>` quits after the shot, which flushes. Run it that way.

**`log` is a zsh builtin.** `log stream …` gives "too many arguments"; `/usr/bin/log` works.

### 2026-08-08 (continued)
- **Phase 10 complete — the server serves nothing.** Moved `server/assets` to `assets/` and
  `server/data` to `data/`, added `tools/assets/stage.sh` and a build phase in both targets,
  and deleted `static.js`, `admin.js`, Express, `cookie-parser` and `sharp` from the server.
- Wrote `AssetLocator` and made all six loaders bundle-only, which retired `DiskCache` and four
  `URLCache`s along with them. `EmoteCatalog` reads `Emotes.table` instead of `/api/config`.
- Found the session leak while reading `server.js` for the Express removal: the HTTP session
  middleware created a session per cookie-less request, so every asset fetch left a file behind.
  269 of them, all `{}`. Nothing read `req.session`.
- Cut `npcs`, `objects`, `mapData`, `mapsList` and `isAdmin` out of `init` at the user's
  direction; `WorldData` reads them from the bundle by `mapId`. The frame went from the whole
  world to 650 bytes. Kept the `fs.watch` broadcasts, which are what makes a local edit reach
  connected clients.
- Ported the fourteen admin operations into `WorldFileStore` and wrote `OrderedJSON` to write
  the files the way `JSON.stringify(x, null, 2)` does. Verified by diff against git rather than
  by eye: after a full `-selftest` run — create, event-tree write, delete, and three
  drag-and-restore cycles — all eight `objects.json`/`npc.json` files are byte-identical to
  `HEAD`.
- That check caught a pre-existing flaw in the self-test rather than in the serialiser: the NPC
  step restored its subject by *dragging back*, which lands within a pixel but not on the same
  `Double`, and had rewritten Mr Hardy's `-935.8839997696498` as `-936`. It restores by value
  now, like the object steps always did.
- **Deleted the Tag game outright** at the user's direction, having first flagged that the
  earlier "delete its assets" decision was based on a wrong claim of mine — map 5 was reachable
  from an NPC and `GameState` deliberately loaded it as a plain world. Removed the art, the
  `maps.json` entry, the `MinigameKind` case, the `startMinigame` branch, and Archie, the NPC
  whose only content was the door to it.
- Deleted `junior_school/buildings_model/` (17 MB, 110 textures, referenced nowhere),
  `server/database.sqlite` (tracked, 0 bytes), `server/migrate.js` and `assets/favicon.png`.
- Added `-host <host[:port]>` to `Config` and to the editor's settings, so a scripted run can
  point at a local server without editing `useLocalServer` and rebuilding. Needed immediately:
  the deployed server still speaks the old protocol.
- Verified end to end. The iOS app loads 5 maps, 23 NPCs and 24 objects from the bundle, with
  zero asset misses in the log, the clip mask blocking on the first `-walktest` sample, and
  every model and tile resolving locally. Both targets build; the editor's `-selftest` passes
  all 21 steps.
- **Implemented the four glTF material extensions**, and `emissiveFactor` with them — it was
  not being read at all, which mattered for the three models that carry one. Emission is added
  after the lighting, `KHR_materials_ior` / `_specular` now drive F0 and F90 instead of the
  hard-coded 0.04 and 1, and transmission gets a premultiplied blended sub-pass that composites
  to `mix(diffuse, backdrop, transmission) + specular` without a backdrop render.
- That work walked into the blind spot this file has warned about since Phase 5: `ModelStore`
  had no Core Graphics fallback, `desk.glb`'s emissive map is a 1-bit greyscale PNG that
  `MTKTextureLoader` will not decode, and the first build rendered 27 solid white desks.
  `ImageDecoder` is now shared with `TextureCache`, and an `emissiveFactor` whose declared map
  fails to decode is zeroed rather than left unmodulated.
- Verified by diffing the app against itself on device rather than by eye: every changed pixel
  is on the antique desk (14.9 % of that region, the lamp bulb going 0 → 251, the magnifier
  turning see-through), and **zero** pixels changed anywhere else in the frame — map,
  character and HUD identical.
- **Closed four editor gaps**, all improvements over the web panel rather than ports: a Freeze
  NPCs toggle, a typed rotation field in both inspectors, the selected NPC's patrol route drawn
  on the map, and a Save / Discard prompt for unsaved event edits — which committed to the
  entity it loaded from, not to whatever is selected now.
- That caught a diff-noise bug in the serialiser: saving an event tree rebuilt every nested
  payload with its keys alphabetised, because the working copy passes through `JSONValue`.
  `OrderedJSON.reordered(like:)` makes an incoming value take the key order of the value it
  replaces; `-selftest` now re-saves an unchanged tree and asserts the file is byte-identical.
- Added `-select object|npc <id>` and five `-selftest` steps. The run is 29 steps and both
  entity files come back byte-identical. The Save / Discard alert itself is not covered —
  nothing can answer a modal from a script — so the step drives the commit-by-id mechanism
  underneath it instead.

## Editor quality of life and glTF material extensions

Two items off the standing gaps list, done together on 2026-08-08 after the phases were
finished. No new phase — the rewrite is complete; this is the list at the bottom of this file
getting shorter.

### The four glTF material extensions are implemented

`KHR_materials_emissive_strength`, `_transmission`, `_specular` and `_ior` were parsed and
ignored, and were the leading suspects for Phase 3's residual difference on glass and trim.
They are all in use, though only just — a scan of every shipping model:

| Extension | Where | Effect |
|---|---|---|
| `_emissive_strength` | `antique_desk.glb`'s Lamp — `emissiveStrength: 8` | The bulb glows |
| `_transmission` | `antique_desk.glb`'s Magnifier — `transmissionFactor: 1` | The lens is see-through |
| `_specular` | 8 materials across `snake`, `stylized_bush`, `tennis_racquet`, `torso`, `banquet_table` | Moves F0 off the 0.04 default; `snake`'s head and body ask for `specularFactor: 0` |
| `_ior` | `tennis_racquet.glb`'s two materials — `ior: 1000` | With their `specularColorFactor` of 0.02 and 0, F0 lands at ~0.02 and 0 |

**`emissiveFactor` itself was not being read either**, which matters more than any of the
extensions: `desk.glb` — placed 27 times, the most common prop in the game — carries
`emissiveFactor [1,1,1]`, and so do `banquet_table.glb` (at 0.229) and the lamp.

| File | Change |
|---|---|
| `Engine/Render/GLTFLoader.swift` | Reads `emissiveFactor`, `emissiveTexture` and the four extensions, and pre-composes three.js's dielectric F0 — `min(pow2((ior−1)/(ior+1)) · specularColorFactor, 1) · specularFactor` |
| `Engine/Render/ModelStore.swift` | `SurfaceExtensions` on each draw group, a second texture slot for the emissive map, and image uploads deduplicated (a material often points both maps at one image) |
| `Engine/Render/Shaders.metal` | Emission added after the lighting; `shadeStandard` takes F0 and F90 instead of hard-coding 0.04 and 1; `fresnelSchlick` gained its `f90` argument |
| `Engine/Render/Renderer.swift`, `PropRenderer.swift` | A premultiplied-blend pipeline and a third sub-pass for transmissive prop materials |
| `Engine/Render/ImageDecoder.swift` | *(new)* the Core Graphics PNG fallback, lifted out of `TextureCache` so `ModelStore` gets it too |

**The defaults are exactly `MeshStandardMaterial`.** A material with none of these extensions
sends emissive 0, F0 0.04 and F90 1, which is what the shader hard-coded before — so nothing
that does not use them can move. The pixel diff below is what confirms it.

#### Transmission without a backdrop pass

three.js renders the scene to a second target and refracts it; there is no such target here.
What the port does instead: scale the diffuse lobe by `1 − transmission`, leave the specular
lobe alone, and blend **premultiplied**, so the composite is
`mix(diffuse, backdrop, transmission) + specular`. That is three.js's result for an
unrefracted, unblurred backdrop — the see-through is real, the distortion is not. Thickness
and attenuation are not modelled either. The transmissive draw is also left out of the shadow
pass, so a glass lens casts nothing.

Two other knowing gaps: `specularTexture` / `specularColorTexture` are ignored (only
`banquet_table.glb` has one, and only the factor is read), and `alphaMode: BLEND` still does
not route a material into the blended pass — no shipping material needs it, since they all
have a base-colour alpha of 1.

#### The bug this uncovered: `MTKTextureLoader` rejects more than palette PNGs

Phase 5 found that `MTKTextureLoader` cannot decode colour-type 3 PNGs and gave `TextureCache`
a Core Graphics fallback, and this file has warned since then that **`ModelStore` has the same
blind spot**. It does, and the emissive work walked straight into it: `desk.glb`'s emissive
map is a **1-bit greyscale** PNG, 207 bytes, and entirely black. The first build of this change
rendered 27 solid white desks — factor with no map to cancel it.

`ImageDecoder` is the shared fallback. `ModelStore` also zeroes an `emissiveFactor` whose
declared map failed to decode, because glTF multiplies the two: absent and undecodable are not
the same thing, and an unmodulated factor is much more wrong than no emission.

A scan of all 40 models found **9 images across 7 models** that `MTKTextureLoader` refuses.
Only `desk.glb`'s is in a slot the renderer samples; the rest are occlusion, metallic-roughness
and normal maps. **Normal maps are read now**, on props as well as characters — see
[HANDOFF-imported-characters-part6.md](HANDOFF-imported-characters-part6.md). Occlusion and
metallic-roughness are still ignored everywhere.

#### Verified by pixel diff, on device

The Phase 3 harness is gone with the web client, so this is a before/after of the app against
itself: same map, same `-at`, same `-zoom`, one build with the change and one without. Detention
at (−6, −600) frames the antique desk, its lamp and its magnifier.

| Region | Mean difference | Pixels changed > 8 |
|---|---|---|
| Whole frame | 0.775 / 255 | 2.97 % |
| Above the desk — map, lockers, **the NPC** | 0.006 | **0** |
| The antique desk | 3.880 | 14.9 % |
| Below the desk — floor, HUD | 0.000 | **0** |

**Every changed pixel is on the one prop that uses the extensions.** The lamp's brightest
pixels go `(0,0,0) → (251,251,251)`, and the magnifier stops being an opaque grey disc — the
open book underneath it is legible through the lens. Characters, ground and UI are identical,
which is the regression check that matters.

The Main Building was photographed separately to confirm the 27 desks render as brown wood
rather than the white rectangles the first build produced.

### Four editor gaps closed

All four were listed under "Phase 9 leaves these open", and all four are improvements *over*
the web panel rather than ports — `admin.js` had none of them.

| Gap | What it does now |
|---|---|
| NPCs roam while you edit | A **Freeze NPCs** checkbox in the sidebar. `GameState.setSimulateNPCs(_:)` skips `NPCBehaviour` *and* parks every interpolation target on the NPC's current pose — skipping the behaviour alone leaves one part-way to a target still gliding. Resuming picks each route up from the timer it was holding |
| Rotation has no numeric field | A field between the ↺ / ↻ buttons in both inspectors, live-updating as the buttons are held |
| Waypoint routes are invisible | The selected NPC's patrol route, drawn as an amber dashed polyline with numbered stops and the implicit closing leg home. Waypoints are *cumulative offsets*, so the authored list tells you very little about where the NPC actually goes — this is the harder of the two to author blind, and the web panel drew only the roam circle |
| Unsaved event edits vanish on selection change | A Save / Discard prompt, and the working copy is committed to the entity it was **loaded from** rather than to whatever is selected now (`EventEditorView.commit()` via the new `AdminMapViewController.mutateObject(id:)`). A background `objects_update` for the entity being edited also no longer reloads over the top of it |

`-select object|npc <id>` was added alongside, because selection was otherwise only reachable
by clicking and nothing can click from a script — it is how the route screenshot was framed.

#### One bug this caught: saving an event tree reordered JSON keys

Pressing **Save Events** without changing anything rewrote the file. The editor's working copy
travels through `JSONValue`, whose objects are Swift `Dictionary`s, so every nested payload was
rebuilt with its keys sorted: `{type, map, description}` came back as
`{description, map, type}`. Nothing read differently — but these are authored files under
version control, and not turning a two-line edit into a whole-file diff is the entire reason
`OrderedJSON` exists.

`OrderedJSON.reordered(like:)` fixes it at the one place a value is written over another: an
incoming object takes the key order of the value it replaces, recursively, with unknown keys
appended after. Arrays recurse element-wise as far as they line up, which covers an event list
whose actions stayed put.

It is a partial repair by nature — order that was never on disk cannot be recovered, so
replacing an action with a different one and then restoring the original does not round-trip.
`-selftest` writes to a throwaway object for exactly that reason.

#### Verified by `-selftest`, which grew five steps

```
selftest 20: waypoint route for NPC 8 'Mr Savage': 4 authored steps → 6 points
             (-1984, -411) → (-1934, -261) → (-1934, -261) → (-2034, -261) → (-2034, -261) → (-1984, -411)
selftest 21: typed rotation on object 12: 90° → 137° (expected 137)
selftest 23: re-saved object 12's unchanged on_enter ["show_dialog"] — the file check below is the assertion
selftest 24: commit-by-id: wrote an event tree to object 80 while 12 was selected → 80 has 1 action(s)
selftest 26: freeze on:  0 NPC(s) moved 0.00px over 2.0s
selftest 27: freeze off: 5 NPC(s) moved 526px over 3.0s
selftest 28: junior_school/npc.json is byte-identical (16518 bytes)
selftest 29: junior_school/objects.json is byte-identical (5337 bytes)
```

Step 20's route has six points from four authored steps because two of Mr Savage's waypoints
only rotate: they resolve onto the point before them, and the overlay stacks their markers.
That is honest — he does stand still for those steps.

**The Save / Discard prompt itself is not covered.** It is a modal `NSAlert`, and nothing can
answer one from a script; step 24 drives the mechanism underneath it instead, which is the part
that could silently write to the wrong record.

Screenshotted with `-select npc 8`: the amber route with its numbered stops inside Mr Savage's
cyan hitbox and dashed interaction ring, and the sidebar showing both the Freeze NPCs checkbox
and the NPC inspector's new rotation field reading 70.

## Environment gotchas (2026-08-08 follow-up)

- **`MTKTextureLoader` rejects 1-bit greyscale PNGs as well as palette PNGs.** Both now go
  through `Engine/Render/ImageDecoder.swift`. Any *new* image path must use it too.
- **A session that ended in Detention cannot be moved with `-map`** — `maps.json` marks it
  `can_leave: false`, so the change is rejected and the app stays put. **Uninstalling the app
  does not help**: the session token is in the Keychain and survives. Clear the server's
  session file, or run the shot on a map you can reach.
- **The editor's overlay hides the props.** A `3d_model` object draws as a 60 %-opaque sky-blue
  box on top of the model, so `-shot` is the wrong tool for a rendering comparison — the first
  before/after of this pass diffed two pictures of the overlay. Use the iOS build and
  `xcrun simctl io booted screenshot`.
- `xcodebuild` has to run from `native/`; the project is not at the repository root.

## Football (2026-08-11)

The third minigame, and the first with a whole AI team on the player's side: five a side, red
against blue, first to three, on a 50 × 34 m pitch. Map 6, trigger id 91 on the big green pitch in
the middle of the junior campus, badge `football`. The map record carries
`"character_scale": 1.5`, so the players are drawn half again as big as they are in the school —
which is the whole of how "make the players bigger" was done.

Four new files under `Engine/World/Minigames/Football/` and `JoelsWorld/UI/Minigames/`, plus the
usual wiring: a `MinigameKind` case, a branch in `GameState.startMinigame`, a `FootballView` in
`GameViewController`, and a ninth badge in `MenuDialogs`. The whole design and every number that
had to be re-derived is in [HANDOFF-football.md](HANDOFF-football.md).

Two things from it are worth repeating here because they are not football-specific:

- **A kick weighted as `distance / time` overshoots by a factor of three** once there is rolling
  friction in the physics. The launch speed that *arrives* is `√(v_end² + 2·a·d)`. Anything else
  in this engine that throws a ball at a target on the ground has the same problem waiting.
- **The "sky" at the top of a minigame frame is usually the edge of the ground plane**, not the
  horizon. Football's surround only reached eight metres past the boards and spent a third of
  every frame on the clear colour.

### Verified behaviour (local server, `-footballdemo -footballtrace`)

`simctl` cannot inject touches, so `-footballdemo` drives `setMoveInput` and `kick()` — the same
two entry points the thumbstick and the button reach — and `-footballtrace` logs a line a second.
Full matches played out end to end: goals detected at both ends, the score advancing, full time
at three, and the demo pressing Play again to check the panel leaves a playable match behind.

**Map 6 does not exist on the deployed server**, which validates map changes against its own copy
of `data/maps.json`. On production the change is refused and nothing happens; testing was against
`PORT=8099 node server.js` with `-host localhost:8099`. It needs a deploy, which is Ben's call.

### Football: control that follows the ball (2026-08-11, later)

Joel: *"Control should automatically pass to the blue player closest to the ball, like FIFA. Make
the pitch bigger again but keep it zoomed in."*

Both done. `FootballGame.updateControl(dt:)` hands the stick to whichever blue outfielder is
nearest the ball — and to whoever wins it, the instant they do — with a distance margin and a
cooldown so two players a hair apart do not trade you back and forth. The pitch went back to
72 × 46 m while the camera stayed put at a fixed 32 m of frame, which is what makes "bigger but
still zoomed in" a coherent request rather than a contradiction: pitch size and camera distance
are independent, and everything positional is normalised into team space.

Three bugs came out of it, two of them the game's and one of them mine:

- **Nobody had to start outside the centre circle.** The defending midfielder's slot put him 3.4 m
  from the ball and between the taker and the goal. Blue kicks off at the start and after every
  goal conceded, so blue lost the ball inside a second at every restart, all match, every match.
- **The pass-to-the-human bonus inverted.** Worth having when the stick was bolted to one
  midfielder; a bug once control follows the ball, because the player you are driving is by
  construction the one nearest it — i.e. the shortest, most backwards pass available. Removed:
  auto-switching already delivers what the bonus was for, since every pass is now a pass to you.
- **`FootballView.step()` writes the on-screen joystick into the game every rendered frame**, and
  an untouched joystick reads zero — so `-footballdemo`'s twenty-times-a-second input was
  overwritten at sixty, and the player it was driving stood still. Blue had been playing four
  against five in *every measured match to date*, and once control followed the ball the statue
  was always blue's nearest player to it. Three straight 0–3s and a long hunt for an AI asymmetry
  that did not exist. **A harness that shares an input path with the UI has to win it explicitly**
  — `FootballGame.debugDrivesInput`, set by `-footballdemo`.

With that fixed the same bot won 3–0 and claimed the badge, which is the first end-to-end
confirmation of the badge path: `minigameAwardBadge` → `sendAwardBadge` → `Claiming badge:
football` in the log.
