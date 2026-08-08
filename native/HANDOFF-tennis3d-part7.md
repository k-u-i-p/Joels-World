# Handoff — the court is in a stadium now

Seventh in the series. [Part 1](HANDOFF-tennis3d.md) is the architecture, [part 2](HANDOFF-tennis3d-part2.md)
is why a serve could not be returned, [part 3](HANDOFF-tennis3d-part3.md) is the strike-zone bug,
[part 4](HANDOFF-tennis3d-part4.md) is the camera, [part 5](HANDOFF-tennis3d-part5.md) is the high
ball and the difficulty that means something, [part 6](HANDOFF-tennis3d-part6.md) is the mishit and
how to run a measurement without wasting an afternoon. Read those first — the frames, the units and
the `Tuning` names all come from them.

**Status: done and seen on screen.** Both targets build, the overworld is unchanged, the game plays
at full speed with the stadium in it.

---

## The ask

> Add the court to the middle of `tennisstadium.glb`. Fix the lighting on the model if possible.

The model was sitting unused in `assets/models/`, committed but referenced by nothing. It is a Fab
export of a Wimbledon-like show court — bowl, stands, roof, press box, umpire chair — and it is
163 MB.

## What it looks like

The court, the net, the players and every line are still the game's own geometry, drawn exactly
where the ball physics believes they are. The stadium is scenery around them: concrete surround,
benches, the umpire chair, a backstop net, the arena's inner wall, the press box, and the stands
with their seats. Both players are legible, the whole playable rectangle is on screen, and the top
of the frame is a grandstand rather than a clip plane.

---

## The model had to be rebuilt before it could be used

`tools/assets/build_stadium.js`, run with `node build_stadium.js` from `tools/assets`:

```
original_images/Models/tennisstadium.glb  163.7 MB  →  assets/models/tennis_stadium.glb  17.9 MB
4435 nodes, 1731 meshes, 34 images        →          16 nodes, 15 meshes, 13 images
549,147 vertices                          →          367,522 vertices
```

**The raw export has moved out of `assets/`** and into `original_images/Models/`, which is the tree
that does not ship. `tools/assets/stage.sh` copies `assets/models` wholesale into the bundle, so
until this session every install carried all 163 MB of it and drew none of it. The app is 288 MB
now; it was heading for 420.

The script is re-runnable and deterministic. What it does, and why each step is not optional:

### 1. It takes the model's own court and net out

The export has its own grass slab, its own chalk lines and its own singles net, all at the origin
and all correct to the millimetre — which is exactly the problem, because so are the game's. Two
courts a centimetre apart is a z-fight, and the one that would win the argument is the one the game
does not know about. The lines the ball is tested against have to be the lines you can see.

Also dropped: **the near half of the retractable roof** (`Roof02_2682`). Both halves are parked
open, stacked eight metres thick, over the two ends of the court. The tennis camera sits behind the
player's baseline at about world y +43 m and 42 m up, and its sight line to the middle of the court
goes straight through that stack — the first run with the stadium in had the bottom two-thirds of
the frame filled with grey roof panel and truss, with the court showing through a slot. Its twin at
the far end is kept; up there it is scenery above the far stand, which is what a roof is for. It is
also 139,000 vertices, a quarter of the model.

### 2. It fixes the lighting, and the fix is a material fix

**A material whose metalness lives in an ORM texture has no `metallicFactor`, and glTF's default
for that is 1.** `GLTFLoader.swift` reads factors and base colour and nothing else, so the entire
stadium structure — `StadiumPartsShader`, 73,892 vertices, every wall and stair and railing you can
see — arrived *fully metallic*. A metal with no environment map to reflect has no diffuse lobe and
one specular highlight, which is to say it renders black.

So the script opens each ORM map, takes the mean of its green channel as roughness and its blue as
metalness, and multiplies those into whatever factors the material declared:

| | roughness | metalness |
|---|---|---|
| StadiumPartsShader | 0.24 | **0.05** (was 1) |
| GlassWindows | 0.14 | 0.83 |
| AsphaltBaseShader | 0.60 | 0.00 |
| SeatShader | 0.87 | 0.12 |

The mean is taken on a 64 px thumbnail. The average of a 4K map and the average of its thumbnail
agree to about a part in a thousand and one is four thousand times faster.

It also **multiplies the occlusion channel into the base colour texture**, which is the other half
of the lighting. The engine has no AO map input, and the stands are the one thing in the model that
is nothing but crevices: without it a grandstand is a flat green wall, with it the seats have
contact shadow under them and the stairs have depth. Only baked where both maps sample untransformed
UV 0 — `FabricShader` tiles its colour 4× and its occlusion would land somewhere else entirely.

### 3. Cut-outs, without touching the shader

The seats and the netting are alpha textures — a single seat with a silhouette, a mesh with 76% of
its pixels transparent. The loader does not read `alphaMode` and there is no alpha-test uniform to
set, so both would have drawn as opaque slabs.

`characterFragment` already discards at `color.a <= 0.001`. So the script **binarises the alpha**:
every texel the artist made even slightly see-through becomes 0, everything else 255. A texture
whose alpha is only ever 0 or 1 gets a correct cut-out through the ordinary opaque pipeline, with
no shader change, no blend state and no sorting problem. The stands read as rows of seats and you
can see the wall through the practice net.

### 4. Merging, which is a load-time fix rather than a looks fix

`GLTFLoader.readAccessor` walks an accessor element by element in Swift, and the export had 14,196
of them across 1731 meshes. The script bakes the node transforms into the vertices and merges every
primitive that shares a material, giving 15 meshes and 60 accessors. `ModelStore` merges to the
same 15 draw groups either way, so nothing on screen changes.

It throws rather than merging if any node carries a **non-uniform** world scale, because the normal
transform it uses is the upper 3×3 and that is only the inverse transpose when the scale is uniform.
Nothing in this export does; if a future one does, the error says so instead of shipping a stadium
lit with skewed normals.

### 5. Everything else

Normal and ORM maps stripped (the loader reads neither — 86 MB), tangents and the second UV set
stripped (13 MB), the 3436-channel animation dropped, every texture halved and re-encoded, and
`GlassShader` given a `KHR_materials_transmission` of 0.72 so the roof glazing is glass rather than
a black hole. The loader and the renderer already understand transmission.

---

## Placing it: what the engine gained

A minigame could hand the renderer characters and primitives. It can now hand it models too.

| File | What |
|---|---|
| `Engine/World/Minigames/Minigame.swift` | `SceneModel { path, transform, castsShadow }`, and `sceneModels` on `WorldRenderedMinigame`, defaulting to none. |
| `Engine/Render/PropRenderer.swift` | A second placement list, `sync(minigameModels:)`, and `drawShadowCasters` — the same draw path the server's props use. |
| `Engine/Render/Renderer.swift` | Syncs it each frame; the shadow pass now asks for casters rather than everything. |

**`castsShadow` defaults to false and the stadium leaves it false.** The shadow map is 1024² over a
3000-unit cone; drawing 367,000 vertices into it costs a second full pass over the model and buys a
shadow of a grandstand onto seats that already carry their own occlusion in the base colour.

### Where the stadium stands

`Tennis3DCourt.stadiumModel`. The model is metres, Y-up, court along Z; the world is 27 units to
the metre, Z-up, court along Y. So: `rotationX(π/2)` (the same tip `PropRenderer` gives every
placed prop), scale by `unitsPerMetre`, then **lift by 19 mm**, because that is where the model's
arena floor sits below its own origin and this puts it exactly on z = 0.

Nothing else is needed to line the two up. `rotationX(π/2)` takes glTF +Z to render −Y, and the
model's court is centred on its own origin, so the game's court and the stadium's footprint agree
without a single tuning constant.

### And what had to move on the game's side

- **The lawn slab is gone.** It was four times the apron, at z = 0, standing in for the world
  outside the court. The stadium's arena floor is that now, and it is at z = 0 too. Two coplanar
  planes forty metres across is the one thing a depth buffer cannot arbitrate. The apron stays at
  z = 2 and the paint at z = 6, the separations that have always worked.
- **The court is grass.** `surfaceColor` and `insideColor` were a blue-grey hard court, which is
  right for a court on its own in a field and wrong in the middle of Centre Court. Two hex strings
  in `Tennis3DCourt`; reverting is those two strings and nothing else.
- **The net is drawn to the singles sticks**, `netEdge` = 5.03 m, not to the doubles posts at
  6.4 m. The stadium's umpire chair stands at 6.2–7.8 m from the centre line and a doubles post at
  6.4 m is planted inside it. `netPostOffset` is untouched, because `netHeight(atX:)` is the sag
  curve the ball is tested against; only the drawing moved. Nothing legal crosses the net past
  4.1 m anyway.
- **`Camera.far` is 2000 → 4000**, which is part 5's item 5 and part 4's before it. The stadium is
  54 m of bowl in every direction, so its far stand is nearly 2900 units from the eye and at 2000 it
  simply was not there. It costs almost nothing: depth is `depth32Float` and the precision of
  `1 − near/z` depends on **near**, not far — one float32 step at 2000 units out is about 0.24
  units, against the 2-unit separations the court's planes use.

---

## The camera, and a number that has been wrong for five sessions

Part 5 recorded that at `desiredWidth = doublesWidth + 3.8 m`, "the visible half-width down at the
near baseline works out at 7.1 m against a `playableHalfWidth` of 7.085 m — exactly on the edge."

It is **6.29 m**. A player pinned against the side fence at their own baseline has been three
quarters of a metre off the bottom corner of the screen since part 5 tightened the zoom, and since
being in the wrong place is the only way to miss a ball, that is a corner you cannot steer to
because you cannot see it.

Measure it rather than deriving it. Screenshot the court, find the near baseline (the lowest long
horizontal run of white), count the pixels between the doubles sidelines it ends at, and scale the
half-frame by the metres those pixels are worth:

```js
// node, needs tools/assets/node_modules — run it from there
import sharp from 'sharp';
const DOUBLES = 10.97, isWhite = (d, i) => d[i] > 200 && d[i+1] > 200 && d[i+2] > 200;
for (const file of process.argv.slice(2)) {
    const { data, info } = await sharp(file).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
    const { width: w, height: h, channels: c } = info;
    for (let y = h - 1; y > h * 0.3; y--) {
        let run = 0, longest = 0, first = -1, last = -1;
        for (let x = 0; x < w; x++) {
            if (isWhite(data, (y*w + x)*c)) { run++; if (first < 0) first = x; last = x; }
            else { longest = Math.max(longest, run); run = 0; }
        }
        if (Math.max(longest, run) > w * 0.5) {
            console.log(file, ((w/2) * DOUBLES / (last - first)).toFixed(2), 'm visible half-width');
            break;
        }
    }
}
```

### Measured, iPhone 17, one screenshot per setting

| pitch | desiredWidth | visible half-width at the near baseline |
|---|---|---|
| 0.80 (part 5's) | doubles + 3.8 m | 6.29 m — **clipped** |
| 0.86 | + 3.8 m | 6.32 m |
| 0.88 | + 3.8 m | 6.26 m |
| 0.88 | + 5.0 m | 6.35 m |
| 0.88 | + 5.6 m | 6.99 m |
| **0.88** | **+ 5.9 m** | **7.10 m — fits** |

Two things fall out of that table, and the first is the useful one:

**Tilt is free in the dimension that constrains it.** 0.80 → 0.88 moves the near baseline's visible
half-width by three centimetres, because tipping the camera also walks the eye further away from
the near baseline and the two cancel almost exactly. Five sessions of treating pitch as expensive
were treating the wrong cost as the binding one.

**Width is what was clipping the corners**, and part 5 gave it up for a reason that no longer
holds: it cut 5.6 m to 3.8 m because "half the frame was ground nobody could stand on — grey apron,
then grass, then more grass". That frame is now stadium, so the width buys scenery instead of
costing it.

So: **pitch 0.88, `desiredWidth = doublesWidth + 5.9 m`.** The playable rectangle is all on screen
and the stand rises into the top of the frame with its seats in it.

### How far the tilt can go, and why

Not much further, and the reason is worth writing down because it looks like a rendering bug. The
camera orbits at a **fixed distance set by the viewport height**, so tilt trades height for
distance. At 0.95 the eye has dropped to 37 m and slid back to 52 m, which is inside the near
stand, and the bottom half of the frame is the roof of it. At 1.05 it is worse — a grey wall with
seats along the top edge. `-tennispitch` sweeps it without a rebuild; do that before believing any
of this.

---

## Verifying

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcrun simctl install <udid> ~/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug-iphonesimulator/JoelsWorld.app
xcrun simctl launch <udid> com.allr.joelsworld -autojoin Joel -map 4
```

Part 6's rules all still apply, and the one that matters most is still the first: **launch without
`--console-pty`**, and keep a screenshot loop running or the simulator throttles to a twelfth of
real time with nothing watching it.

Checked this session:

- The scene, on screen, on both an iPhone 17 and a 17 Pro Max.
- **The overworld is unchanged** — map 0 renders its ground, its buildings, its props and its
  shadows exactly as before, which is the regression `Camera.far` and the shadow-pass change could
  have caused.
- **Both targets build**, including the macOS `JoelsWorldAdmin`.
- **Speed.** Part 6's proxy — trace lines per thirty seconds, expect 60–93 — gives **131** with the
  stadium in and a rally going. The extra 254,000 triangles have not cost anything measurable.

---

## What is left

Carried forward from part 6, minus what this session closed:

1. **A finger has still never touched it.** Everything from `Tennis3DView`'s touch entry point down
   is exercised by `-tennis3dtaps`, `-tennis3ddrag`, `-tennis3daim` and `-tennis3dhittest`; UIKit's
   own delivery of a `UITouch` is not. Needs `idb`, a working simulator panel, or a person. **Check
   the panel's injection with a control — press HOME and see if the springboard appears — before
   trusting a single tap.**
2. **No `INTO THE NET`.** `netMargin` in `launchBall` is the lever.
3. **Alex never comes to the net, and neither can the player usefully.** Still the obvious next
   feature, and still a real one — `intercept` already allows a ball that has not bounced.
4. **The 2D game is still in the tree** behind `-tennis2d`. Ben's call.
5. The difficulty panel still sits over Alex at the far baseline between points, and
   `-tennisdifficulty` still does not update which button is highlighted.

New, from this session:

6. **The backstop net reads as a white picket fence** rather than a mesh from this distance. It is
   the binarisation in step 3 thickening thin strands at 1024. Give `NettingShader` its own larger
   size in `build_stadium.js` if it bothers you; it is 18 m behind the far baseline and it did not
   bother me.
7. **The near roof is gone and the far one is not**, which is fine from behind the near baseline
   and would not be from anywhere else. If a future camera ever looks the other way — a replay, a
   celebration, the far player's point of view — `Roof01_1351` will be in front of it. The fix is
   the same one: drop it in `DROP_NODES`.
8. **`sideRun` could now be honest.** The playable half-width fits the frame at last, so the 1.6 m
   side run is real ground the player can actually be steered to. Worth re-measuring whether wide
   balls are now retrievable that were not, which would shift the balance in the player's favour
   for the first time since part 5's `playerReachScale`.
9. **The stadium is 17.9 MB and loads in one go.** On a device rather than a simulator that is a
   pause of unknown length between tapping the tennis map and seeing the court. Nobody has timed
   it. `ModelStore` parses off the main queue and the renderer draws what has arrived, so the
   failure mode is a court with no stadium for a moment rather than a hang — but it is untimed.
