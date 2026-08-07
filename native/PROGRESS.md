# Native iOS Rewrite — Progress Log

**Resume instructions for a fresh agent:** read `native/PLAN.md` first (architecture +
decisions), then this file (what is actually built). The JS client in `client/public/src/`
is the reference spec for every port — **keep it until Phase 8.**

Last updated: 2026-08-08 · Phases 1–6 complete and verified on simulator; Phase 7 is Tennis
only — Tag is deferred at the user's request.

---

## Decisions already made (do not re-litigate)

- **Full Swift rewrite**, not a WebView shell. User chose this explicitly.
- **The web game is being retired** — the iOS app becomes the only client. `client/` gets
  deleted in Phase 8, not before (it is the reference spec).
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
- **`admin.js` is not being ported and stays a web page** — decided by the user on
  2026-08-07. No native editor, no move; it keeps being served by the Node server.
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
| 7b | Minigames: tag (591 ln) | **deferred** — the user is reworking the game first |
| 8 | Retire web client | not started |

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

## Build / run

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

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

**Reproducing the Phase 6 parity check.** `emotes.js` only needs three.js for its props, so it
can be driven under Node rather than in a browser: read the file, strip its four `import`
lines, prepend a stub `THREE` (`Vector3` with `set`/`copy`/`setScalar`, an `Object3D` with
`position`/`rotation`/`scale`/`material`/`children`/`add`/`clone`, the five geometry
constructors and the three material constructors — all as `function`s, since they are called
with `new`), a `getCharacterProxy` returning a fake mesh group, and a `document.createElement`
stub for `love`'s canvas. Pin `Date.now`, build a rig with the neutral targets
`updateCharacter3D` restores, and call `emotes[name].updateLimbs3D`. Then diff against
`-emotedump`. The harness is throwaway and lives in the session scratchpad.

**Reproducing the Phase 3 parity check** (the method is worth repeating; the harness itself is
throwaway and lives in the session scratchpad):

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
`JoelsWorld/Core/Config.swift` to point at a local `npm run dev`.

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
  under `native/JoelsWorld/` join the target automatically, no pbxproj editing needed.
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

**Phase 8 is the natural next chunk** — retiring the web client. The remaining `server/` →
`client/` couplings are listed under "Phase 8 decoupling" below and none of them is a blocker.

**Tag is the outstanding gameplay work**, and it is waiting on a design decision, not on
engineering: the user is reworking the game. `minigames/tag.js` (591 lines) is a much smaller
port than Tennis was and reuses the existing 3D renderer rather than needing a 2D one — it
draws through `characterManager.drawCharacter`, walks on the real clip mask, and uses
`physicsEngine.processMovement`. The plumbing it needs is already in place: `Minigame`,
`MinigameHost`, the exit button, and `usesWorldRenderer: true` is the branch it would take.
Two things to know before starting it:

- **Tag renders with `renderer.render()`, not `composer.render()`** — no SSAO — and it never
  repositions the spotlight, so the light stays wherever the previous map's last frame left
  it. That is a JS bug, not a style: what the map looks like depends on where you were
  standing before you walked in.
- **Tag's own camera** uses `pitch + 0.60`, zoom 1.2, no map clamping and no Y bias, unlike
  the overworld camera. `Camera` would need a free-focus variant.

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
- **`EmoteCatalog` still fetches `/api/config`** for the picker's list, even though the table
  is now local. Leaving it means the picker keeps matching whatever the server considers
  valid; the `/command` path gates on the local table, as `main.js:222` does.

Carried forward from Phase 5:

- **Audio session category is `.playback`**, matching what Capacitor's `NativeAudio` gave the
  old build: the music keeps playing with the ring switch on silent. Change to `.ambient` if
  that turns out to be the wrong call for a kids' game.
- **The minimap image and the NPC portraits stream over HTTP**, like the models — the minimaps
  are ~200 KB each. `ImageLoader` checks `Bundle.main` first, so bundling is a packaging step.
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

- **glTF material extensions are parsed but ignored.** `KHR_materials_emissive_strength`,
  `_transmission`, `_specular` and `_ior` all appear in the shipping models. They are the
  likeliest cause of the residual difference on glass and trim.
- **SSAO runs at full resolution with 32 samples**, as the JS does. It is the most expensive
  pass by far and the obvious first lever if a device drops frames; half-resolution AO with an
  upsample is the standard fix and would be invisible at this blur radius.
- **Non-chunked single-image map layers** are still parsed and skipped. No shipping map uses
  them, so this stayed out of Phase 3 despite being listed under it.

Carried forward from Phase 2, deliberately:

- **Models stream over HTTP rather than being bundled** (PLAN.md §5 wants them bundled).
  `ModelStore.fetch` already checks `Bundle.main` first, so bundling is a packaging step with
  no code change. Heads are ~2.6 MB each, 37 MB for all 17.
- **`female_hair_short_2` has no `.glb` on the asset host.** The table entry is kept
  deliberately — deleting it would shift every other female character's deterministic head
  choice. Characters that hash onto it render headless, exactly as they do on the web.

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

## Phase 8 decoupling

**`physics.js` is moved — blocker cleared.** It now lives at `server/physics.js` as the
single source of truth for both runtimes:

- Node imports it directly: `websocket.js:6`, `managers/NPCManager.js:4`,
  `managers/AIAgentManager.js:5`.
- The browser still imports the unchanged URL `/src/physics.js`; `static.js:35-42` routes
  that URL to the server-side file, ahead of the `/src` static mount. **No client file
  changed** — `main.js`, `characters.js`, `emotes.js` and `minigames/tag.js` keep their
  `./physics.js` / `../physics.js` imports and resolve to the same URL.
- `loadClipMask` (canvas/`Image`) now no-ops under Node instead of throwing; the server
  never mask-tests. Everything else is byte-identical to the old file.

`World/Physics.swift` and `server/physics.js` must stay behaviourally identical while both
exist.

Caveat: the legacy Capacitor shell (`client/ios`) bundles `client/public` as its `webDir`,
so a fresh `npx cap sync` would produce a bundle without `physics.js`. That shell is retired
by this rewrite and was not patched.

Still coupling `server/` to `client/` (Phase 8 work, not blockers today): `static.js:13` and
`AIAgentManager.js:46` parse `client/public/src/emotes.js` for the valid-emote list, and the
three `scripts/*.js` asset generators use `client/public` as the asset root.

The emote-list coupling is **unblocked but not resolved**: `Entity/Emotes.swift` is now the
native source of truth, so Phase 8 can move the list into `server/` when `client/` goes. It
was left alone because the web client still imports `emotes.js` until then, and the two must
not drift while both exist.

**`admin.js` decision made (user, 2026-08-07): it stays a web page.** Not ported, not moved.
Phase 8 deletes the game client only — the admin editor and its serving path survive.

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
