# Handoff — part 6: normal maps

**The models shipped with normal maps and the renderer was throwing them away.** All five
characters have one, and so do nine of the props — `antique_desk.glb`, the most-placed prop in
the game, has fourteen. Between them that is several megabytes of 2048² maps that never reached
the GPU. This reads them, for characters and for props.

The characters came first and are most of this document. **The props are at the bottom**, under
"And then the same for the props" — read the characters first, because the props reuse every idea
in them.

Read [part 5](HANDOFF-imported-characters-part5.md) first for how a character gets on screen at
all. This changes one thing about that: the fragment normal.

---

## What a normal map is, in Scratch terms

The mesh gives the shader **one direction per vertex** — which way the surface faces — and the
lighting is worked out from it. So a sleeve is a smooth tube, a shoe is a smooth blob, and every
crease, seam, stitch and strand of hair is *painted into the colour texture* and lit as though it
were flat. It looks painted on because it is.

A normal map is a second picture, the same shape as the colour one, where each pixel says **"the
surface here actually tilts this way"** — an amount left/right in the red channel, up/down in
green, and out in blue. The shader reads it per *pixel* rather than per vertex, and lights that
tilted direction instead. The bumps are not in the geometry and never will be: the silhouette is
identical, the triangle count is identical, and nothing moves. Only the light changes, and the
light is what your eye reads as shape.

Same character, same frame, off and on:

| off | on |
|---|---|
| flat shirt, flat shorts, hair as smooth lumps | woven shirt, seamed shorts, strands with edges |

---

## The three pieces

### 1. Tangents — the part that is actually work

A normal map's directions are stored **relative to the surface**, not to the world. "Left" in the
map means "left across the texture as it lies on the skin", which is a different world direction
on the front of an arm than on the back of it. To use the map at all you need, at every vertex, a
frame: which way is +u across the surface (the *tangent*), which way is +v (the *bitangent*), and
the normal. glTF has an optional `TANGENT` attribute for exactly this.

**Four of the five characters don't have one.** Only `stylized_boy.glb` was exported with
tangents; `son`, `daughter`, `father` and `mother` were not — while all five have the map the
tangents are for. So `GLTFLoader.generateTangents` derives them: for each triangle, solve the two
edges against their UV deltas to get the direction the texture's u axis points in space; average
that at each vertex so it varies smoothly instead of faceting; make it perpendicular to the vertex
normal.

The fourth component, `w`, is **handedness**, and it is the part that is easy to skip and painful
to debug. A character atlas is mirrored down the middle — the left arm and the right arm share one
patch of texture to halve its size. On the mirrored side the frame is flipped, and without `w` to
say so, every bump on that half of the body comes out as a *dent*. It is symmetrical and subtle
and reads as "the lighting is a bit odd on that side".

The log line says which route a model took:

```
[Render]   normal map: 2048×2048, scale 1.00, tangents generated from the UVs
```

`from the file` means the exporter provided them. If a model ever looks wrong, that line is the
first thing to read.

### 2. The map is not a colour, so it is not loaded as one

`ImportedCharacterStore` loads the base colour with `.SRGB: true`, because a colour texture is
sRGB-encoded and shading has to happen in linear space. The normal map is loaded with
**`.SRGB: false`**, because its three channels are not a colour at all — they are the x, y and z
of a direction, stored linearly around 0.5.

Getting this wrong is the classic normal-map bug and it does not look like a bug. sRGB-decoding
bends every channel down towards zero, which tilts every fragment on the character consistently
away from the light. The result is a character who looks *grubby* — flat, dull, slightly dirty —
with nothing obviously broken to point at.

### 3. Skinning the tangent

The tangent lies in the surface, so when a bone moves the surface the tangent has to go with it.
`characterSkinnedVertex` blends it through the same four weighted bone matrices as the normal. Skip
this and a straight arm looks right while a bent elbow lights its map as though the arm were still
straight — worst exactly where a crease most wants to show.

---

## Where it lives

| File | What changed |
|---|---|
| `Engine/Render/GLTFLoader.swift` | `GLTFSkinVertex.tangent`; reads `TANGENT`, or `generateTangents` from the UVs; reads `normalTexture.scale`. |
| `Engine/Render/ImportedCharacterBody.swift` | `tangent` on the GPU vertex; loads the normal map with sRGB **off**; the log line above. |
| `Engine/Render/Shaders.metal` | `SkinVertex.tangent`, `CharacterInOut.tangent`, tangent skinning, and the TBN rebuild in `characterFragment`. |
| `Engine/Render/CharacterRenderer.swift` | `surface.y`/`surface.z` carry the flag and the scale; binds the map at texture 4. |
| `Engine/Render/ProceduralTextures.swift` | `makeFlatNormalTexture` — the 1×1 stand-in. |
| `Engine/Render/Renderer.swift` | Binds that stand-in once per pass. |

### Two things about the plumbing

**`SkinVertex` grew, and `tangent` went last on purpose.** That struct is hand-matched between
Swift and Metal with nothing checking it — part 4's handoff flags this as the standing hazard. The
existing `pad` field is what makes the first five fields land on identical offsets in both
languages; the struct without the tangent is 80 bytes, which is a multiple of 16, so appending a
16-byte-aligned `float4` keeps that agreement instead of shifting everything after it. **Do not
insert a field in the middle of that struct.**

**Texture 4 is bound even when nothing samples it.** `characterFragment` is shared by characters,
props, the map and scene primitives, and Metal wants every texture a shader declares to be bound.
`Renderer` binds a 1×1 flat normal — `(128, 128, 255)`, which decodes to straight-out and perturbs
nothing — once per pass, and a character overrides it with its own. The white stand-in used for
the other slots would decode to a 45° tilt, so this one is worth the four bytes.

---

## What this does *not* do

- **Metallic-roughness and occlusion maps are still ignored** on everything. Roughness and
  metalness remain single numbers per material.
- **`KHR_texture_transform` on a normal map is not honoured**, and a skinned character's normal
  map on a `texCoord` other than 0 logs a warning and samples set 0 anyway. Neither happens on any
  character. (Props *do* handle a second UV set — see below.)
- **Cost**: one extra 2048² texture per resident model, and one texture sample plus a handful of
  ALU per character fragment. Not measured on device. The triangle budget from part 5 is still the
  thing to worry about, not this.

---

# And then the same for the props

Nine of the twenty-one `.glb` files that are not characters carry a normal map:
`ac_unit_2`, `antique_desk`, `banquet_table`, `chair`, `church_pew_bench`,
`classic_park_bench_low_poly`, `low_poly_kids_playground`, `old_building` and `tennis_racquet`.

The shader work was already done — a prop draws through the same `characterFragment`. What the
props needed was somewhere to put a tangent, and four differences from the character case.

## The four differences

### 1. `MeshVertex` grew, and a second UV set came free

Rigid geometry rides `MeshVertex`, which had no room for a tangent. It has one now, plus a second
UV — and **the second UV costs nothing**. `uv` ends at byte 40 and a `float4` must start on a
16-byte boundary, so bytes 40–48 were already dead space. `normalUV` lives there.

The whole struct goes from 48 bytes to 64. Across every `.glb` on disk that is 832,000 vertices,
so **13 MB if every model were resident at once** — they are not, but it is the honest ceiling and
it is the one real cost of this change. Models with no normal map carry a zero tangent and are
lit exactly as before.

### 2. Most props already had tangents; two do not

Seven of the nine were exported with `TANGENT`. `chair.glb` and `tennis_racquet.glb` were not, and
fall through to the same generator the characters use — `generateTangents` is now generic over
both vertex types rather than written twice, because the two things it gets quietly wrong (the
Gram–Schmidt and the handedness) are exactly what would drift between two copies.

Generation only runs when the material actually has a normal map. On the twelve models without
one it would be a few hundred thousand vertices of arithmetic nothing ever reads.

### 3. A prop's vertices are baked, so its tangents are baked too

`GLTFPrimitive` bakes each node's transform into the vertices. The tangent is baked with them —
by the plain upper-left 3×3, *not* the inverse transpose the normal uses, because a tangent lies
in the surface rather than perpendicular to it. And if that transform has a negative determinant
the node is mirrored, which flips the handedness of every UV shell in it; miss that and the bumps
on a mirrored prop come out as dents.

### 4. `banquet_table.glb` samples its normal map from a different UV set

Its base colour is on `TEXCOORD_0` and its normal map on `TEXCOORD_1`, with `scale: 0.571`. That
is what `normalUV` is for, and why the tangent frame is built from `normalUV` rather than `uv` —
glTF ties tangent space to the normal texture's UV set, so an authored `TANGENT` is already in
that set. It is the only asset in the tree that does this.

## The merge key

`ModelStore` collapses primitives into one draw group per (slot, colour, texture, …). The normal
map and its scale had to join that key. Without them `antique_desk.glb`'s fourteen normal-mapped
materials would collapse into whichever group they matched on colour, and thirteen of them would
be drawn wearing the fourteenth's map.

The texture cache is keyed by image **and colour space** for the same reason the character loader
passes `.SRGB: false` — the same image could in principle be a base colour on one material and a
normal map on another, and the two are different textures.

## Where it lives

| File | What changed |
|---|---|
| `Engine/Render/GLTFLoader.swift` | `MeshVertex.normalUV` / `.tangent`; `TangentFramed` so the generator serves both paths; `normalTextureInfo`; baking and mirror handling in `buildPrimitive`. |
| `Engine/Render/ModelStore.swift` | Normal map and scale on `ModelGroup` and in the merge key; sRGB-off texture load; the per-model report. |
| `Engine/Render/PropRenderer.swift` | Binds the map, sets the flag and the scale. |
| `Engine/Render/CharacterRenderer.swift` | `drawMesh` takes a normal map, so the held racket gets one too. |
| `Engine/Render/ScenePrimitiveRenderer.swift`, `Renderer.swift` | Thread the flat stand-in through to texture 4. |

## What was checked, and what was not

Verified by rendering, in the Mac map editor with `-shot`:

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Map Editor.app/Contents/MacOS/Joels World Map Editor"
"$APP" -shot /tmp/props.png -shotdelay 12 -at 1741 -620 -camzoom 3.2 -campitch 0.95
```

That frames the playground on Junior Campus. Off versus on, the roof ribs stand proud, the blue
panels gain relief, the slide's segment rings shade and the climbing net gains depth — and nothing
is inverted. `classic_park_bench_low_poly`, `ac_unit_2` and `old_building` are in the same frame.
All four load with tangents from the file.

**Five of the nine were not rendered.** `chair`, `banquet_table` and `church_pew_bench` are on
Main Building, `antique_desk` on Detention, and no character on Junior Campus was holding a
racket. The editor's `-map <id>` sends a change-map the server did not act on, so this harness
reaches Junior Campus only. That leaves two code paths implemented but unseen: **generated
tangents on a rigid mesh** (`chair`, `tennis_racquet`) and **the second UV set**
(`banquet_table`). Both build; neither has been looked at. If a prop on those two maps looks
wrong, start there.

The load report says which route each model took, which is the quickest way in:

```
[Render] Model 'models/low_poly_kids_playground.glb': 2 primitives → 2 draw groups in 17 ms
[Render]   normal maps on 2 of 2 groups, scale 1.00, tangents from the file
```

## Still not done

- **Metallic-roughness and occlusion maps.** Unread on props as well as characters.
- **No mipmaps on prop textures.** `ModelStore` has always loaded with `generateMipmaps: false`,
  and the normal map follows suit. A prop seen from the overworld camera is small on screen, so
  its map will alias. The base colour has the same problem and always has; fixing one should fix
  both.
- **`KHR_texture_transform` on a normal map** logs and is ignored. No asset does it.

## Checking it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
JW_CHARACTER_MODEL=models/characters/son.glb "$APP" -labtake idle -labtime 1 -labshot /tmp/boy.png -labsize 900 1200
```

Look at the shirt weave, the seams on the shorts and the edges of the hair strands. To see it as a
difference rather than a still, set `normalTextured:` to `false` in
[CharacterRenderer.swift](Engine/Render/CharacterRenderer.swift)'s `drawImportedBody`, rebuild and
shoot the same frame.

Then a stride, because tangent skinning is what a still cannot check:

```bash
"$APP" -labtake run -labsheet /tmp/run.png -labframes 4
```

Bent knees and bent elbows should light like the rest of the body. Patchy or inverted shading on a
flexed limb is the tangent blend, not the map.
