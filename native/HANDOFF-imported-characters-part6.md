# Handoff — imported characters, part 6: normal maps

**Every one of the five characters shipped with a normal map, and the renderer was throwing it
away.** Between them the five `.glb` files carry 2 MB of 2048² normal maps — roughly a third of
their total size — and none of it reached the GPU. This reads them.

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

- **Rigid models still ignore normal maps.** `MeshVertex` has no room for a tangent and
  `ModelStore` merges primitives into draw groups by material. Several props ship maps that are
  still unread. Doing them is a bigger change than this was, and it is a fair next job.
- **Metallic-roughness and occlusion maps are still ignored** on everything. Roughness and
  metalness remain single numbers per material.
- **`KHR_texture_transform` on a normal map is not honoured**, and a normal map on a `texCoord`
  other than 0 logs a warning and samples set 0 anyway. Neither happens in any shipping asset.
- **Cost**: one extra 2048² texture per resident model, and one texture sample plus a handful of
  ALU per character fragment. Not measured on device. The triangle budget from part 5 is still the
  thing to worry about, not this.

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
