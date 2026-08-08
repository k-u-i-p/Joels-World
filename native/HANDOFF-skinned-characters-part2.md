# Handoff — clothes on the skinned body

**Session 2.** Continues [HANDOFF-skinned-characters.md](HANDOFF-skinned-characters.md), which built
the body as one skinned mesh. That gave the characters continuous limbs and real joints and left
them wearing four flat fields of colour. This session gives them **clothes**: a collar, a button
placket, short sleeves with bare arms, shorts with bare legs, and white school socks.

Zone note: `Engine/Render` and the Mac editor, red under [AGENTS.md](../AGENTS.md). Same
standing instruction as session 1 — Ben asked for the character-fidelity work directly.
`server/**` and `JoelsWorld.xcodeproj/**` untouched. (The project uses Xcode's synchronised file
groups, so the two new files needed no `.pbxproj` edit.)

---

## What it looks like now

Every character wears the same school uniform, in their own colours:

- a **white collar** over the shoulders, opening into a V on the chest
- a **button placket** down the front, four buttons, a seam either side
- **short sleeves** — the shirt stops a little over half way down the upper arm and the rest of
  the arm is the character's skin
- **shorts** with a turn-up, a hip seam and a fly, and **bare legs** below them
- **white socks** from below the knee into the shoe
- soft shading in the creases: under the shirt hem, under the sleeve, at the sock roll

Verified by rendering, not by reasoning: the Mac editor at `-campitch 1.35 -camzoom 5` on Junior
Campus, and the 3D tennis court in the iPhone 17 simulator. Both build clean.

**This changes how every character in the game looks.** Session 1's list called short sleeves
"Ben's call" because of exactly that. It is done, and it is three numbers to undo — see
`sleeveEnd`, `shortsEnd` and `sockTop` in `ClothingAtlas`. Set `sleeveEnd` to 1 and everybody is
back in long sleeves; set `shortsEnd` to 1 and back in trousers.

---

## The idea

**The texture is not a picture of clothes. It is instructions about a colour.**

An albedo map would have to be repainted per character, because shirt and shorts colours are
per-character data in `data/*/npc.json` and there are dozens of them. So the atlas stores three
control channels instead, and the shader applies them to whatever colour the palette already
handed that vertex:

| channel | what it says |
|---|---|
| **red** | **shade** — multiply by `2 × r`, so 0.5 means "leave it alone". Seams, folds, the shadow a sleeve casts. |
| **green** | **trim** — mix towards `ClothingAtlas.trimColor`. Collars and socks. |
| **blue** | **bare** — mix towards *this character's own skin colour*. Below a sleeve, between the shorts and the sock. |

One 256×320 texture dresses every character in the game, inside the one draw call the body
already cost. Nothing was authored by hand: every mark is a band or a bump in `(u, v)`.

The blue channel is the interesting one. A per-part colour can only say "this whole arm is shirt
colour"; that is why arms used to run one colour from shoulder to wrist. The texture can say
"shirt down to here, then skin", and that single sentence is most of what makes these read as
dressed rather than painted.

### The files

| File | What changed |
|---|---|
| `Engine/Render/ClothingAtlas.swift` | **New.** Region layout, the UV contract, and the painter. |
| `Engine/Render/SkinnedBody.swift` | Real UVs for every surface (`facing`, arc-length `v`); `ColorSlot.trim`; `paletteCount` 4 → 5. |
| `Engine/Render/Shaders.metal` | `CharacterInOut.bare` / `.trim`; the clothing branch in `characterFragment`. |
| `Engine/Render/CharacterRenderer.swift` | Builds and binds the atlas; the trim palette entry; `clothed:` on `CharacterUniforms`. |
| `JoelsWorldAdmin/Editor/AdminScreenshot.swift` | `-campitch` / `-camyaw` / `-camzoom`. |
| `JoelsWorldAdmin/Editor/AdminMapViewController.swift` | Applies them at launch. |
| `tools/clothing_atlas.swift` | **New.** Dumps the atlas to a PNG. |

---

## UVs, and the seam — read this before touching the mapping

The body had no usable UVs. `MeshFactory.lathe` writes a plain revolve parameterisation and says
in as many words that the rig's flat-coloured materials never read it, and `appendTube` wrote
`v = 0` on every ring. Both are replaced with something anatomical:

- **Torso and shorts.** `u` from the **bind-space** angle (`SkinnedBody.facing`), not the lathe's
  own revolve angle, so the middle of the chest is the middle of the chest whatever `MeshFactory`
  and the bind rotation do between them. `v` from the profile height, hem to neck.
- **Arms and legs.** `v` is **arc length along the centre line**, not the ring index — the caps
  are five rings over two units and the shaft is eight rings over ten, so an index would put the
  cuff of a sleeve up by the shoulder. `u` from the ring segment.
- **Neck and hands.** The `blank` region, which is neutral everywhere, so skin renders exactly as
  it did before there was a texture.

**`u` is folded: 0 at the front, 1 at the back, the same going round either way.** This is not
economy, it is the fix for a real bug. A surface revolved all the way round has to come back to
where it started, and a UV running 0…1 round it does not — the last quad carries `u` from 0.96
back to 0 and renders the whole texture row squeezed into one strip down the character's spine.
Folding turns the parameter round instead of wrapping it, so there is no jump anywhere. A limb
folds its ring index the same way.

The price: **nothing on a character can be left-right asymmetric.** A badge on one pocket comes
out on both. If that is ever wanted, the fix is a full wrap with a duplicated seam column, not
un-folding this.

## Looking at the atlas

Every mark is a number, and reading numbers is a poor way to find out that a button has come out
as a dash or a collar has slid into a guard row. So:

```bash
swiftc -O -parse-as-library tools/clothing_atlas.swift native/Engine/Render/ClothingAtlas.swift -o /tmp/atlas && /tmp/atlas /tmp/atlas.png
```

It compiles `ClothingAtlas.swift` itself, so what it draws is what the game uploads. The PNG is
lurid false colour — it is a control map, not clothes — and rows run blank, torso, pelvis, arm,
leg, with `v` increasing downwards.

## Looking at a character

The game's camera looks straight down, so the Mac editor is still the way (session 1 explains
why). It now takes the camera on the command line, which is what makes a headless shot useful:

```bash
"$DERIVED/Debug/Joels World Map Editor.app/Contents/MacOS/Joels World Map Editor" -shot /tmp/shot.png -shotdelay 6 -campitch 1.35 -camzoom 5
```

**Run it under `script -q`, or through Xcode.** Swift's `print` is block-buffered onto a pipe, so
a plain `cmd > log &` shows nothing at all and looks exactly like a hang. Half an hour went into
that.

---

## Traps

The session-1 traps all still apply. These are new.

1. **The collar is not where a collar is.** It sits at `v` 0.795 rather than at the neck root at
   0.98, and dips to 0.66 at the front. That is deliberate: from 0.83 upwards the torso profile is
   the trapezius sloping into the neck, which faces almost straight up and is hidden by the head
   from every camera this game has. The first attempt put the collar where a collar goes and it
   was invisible from every angle. Anything painted above 0.83 is painted for nobody.

2. **Marks are drawn wider than life.** The front of a chest is about eleven units across and a
   character in the overworld is forty pixels tall — a placket at true scale is one pixel, which
   is not a placket, it is a stray. Placket, buttons and seams are all a little fatter and darker
   than they should be. They still read as cloth close up, which is the test.

3. **The atlas is `rgba8Unorm`, not sRGB, and does not go through `MTKTextureLoader`.** These are
   instructions, not colours. A gamma curve applied to "multiply by 1" quietly stops meaning 1.

4. **Neutral is 128/255, not exactly a half**, so an untouched surface comes out 0.4% bright. That
   is below the quantisation of the frame buffer. Do not "fix" it by rescaling the channel — you
   would lose the exactness of 0 and 1 at the ends, which the bare and trim mixes do rely on.

5. **Guard rows.** Each region reserves two texel rows top and bottom that no `v` maps into,
   because the sampler is bilinear and the regions are stacked touching. Without them the collar
   at the bottom of the torso row bleeds into the shorts. `pixels()` clamps `v`, so a guard row is
   a copy of the edge it guards; the inverse mapping in `pixels()` and the forward one in `uv` have
   to agree, and nothing checks that they do.

6. **`SKIN_PALETTE_COUNT` is 5 in the shader and `paletteCount` is 5 in Swift**, and the
   roughness/metalness block starts at that offset. Change one and the shader reads roughness out
   of a colour.

7. **The fifth palette slot, `ColorSlot.trim`, is carried by no vertex.** It is in the palette
   because the *texture* chooses it per texel and the fragment shader needs somewhere to read it
   from. Do not "tidy" it out for being unused.

8. **`characterFragment` now has three branches at texture 0**: the clothing atlas (skinned body),
   an ordinary base-colour map (heads, the racket), and neither. `in.bare.a` picks the first, and
   only `characterSkinnedVertex` ever sets it. A new vertex function that leaves it at zero gets
   the old behaviour, which is the right default.

---

## What is left

1. **The hands.** Still the four-ellipsoid blob, still the weakest thing on the body, still the
   single biggest remaining win, and now the *only* part of the body with no detail on it at all.
   It was next in session 1 and it is next now. Sweeping them the way the limbs are swept — one
   tube down the palm with a thumb branch — is the same trick again.
2. **Check the extremes.** Still not done. `wave` folds an elbow hard and the tennis swing coils
   the waist; watch for a collapsing "candy wrapper" at the elbow. The clothing texture does not
   change this either way — it is skinning, not shading — but the sleeve edge is now a visible
   landmark on the arm and will make any stretch obvious.
3. **The waist seam.** There is a two-pixel line of *shorts colour* inside the shirt, just above
   the hem, on every character. It is the pelvis lathe showing through where the torso lathe
   pinches shut, and it predates this session — a shade multiplier cannot turn green into navy.
   It happens to read as a belt and is not unattractive, but it is an accident. Either close it
   (lift the torso's bottom profile point) or commit to it and paint a real belt.
4. **Roughness does not follow the texture.** A bare arm below a sleeve is lit with the sleeve's
   roughness, because `surfaceParams` comes from the vertex's slot and the bare mix happens in the
   fragment. Skin is 0.6 and cotton 0.8; the difference is small and nobody has noticed. Fixing it
   means carrying the skin's roughness into an interpolant and mixing by `detail.b`.
5. **Nothing distinguishes a teacher from a pupil.** Everyone is in the same uniform now, which is
   only right for the children. A second atlas row set — long sleeves, long trousers, a tie —
   selected per character would be a `ColorSlot`-sized change plus a `v` offset in the UVs.
6. **Delete `JW_RIGID_RIG` and the rigid part meshes** once this is trusted. Still true, and the
   rigid path now looks *much* worse than the skinned one, which makes the A/B less useful than it
   was.
7. **Route B is still Route B.** This does not get to the reference image, but it is a good deal
   closer than four flat fields of colour were.

---

## Where the numbers live

- **What the clothes are and where they stop** — `ClothingAtlas`: `sleeveEnd`, `shortsEnd`,
  `sockTop`, `trimColor`, and the individual painters `shirt` / `shorts` / `sleeve` / `legwear`.
- **How big the atlas is** — `width`, `rowHeight`, `guardRows`. `height` follows from the region
  count.
- **What `v` means on each surface** — written at the top of each painter, in the rig's own units.
- **Everything about the body's shape** — unchanged, and still in `CharacterRig`. See session 1.
