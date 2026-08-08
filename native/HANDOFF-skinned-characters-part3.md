# Handoff — light and cloth on the school uniform

**Session 3.** Continues [HANDOFF-skinned-characters-part2.md](HANDOFF-skinned-characters-part2.md),
which put the characters in a school uniform painted rather than modelled. That gave them a collar,
a placket, short sleeves and socks, and left them lit as though nothing on the body ever got in the
way of anything else. This session is about **light**: where one part of a body shadows another,
what material each texel is made of, and why a shirt is not one flat field of one colour.

Zone note: `Engine/Render`, red under [AGENTS.md](../AGENTS.md). Same standing instruction as
sessions 1 and 2 — Ben asked for the character-fidelity work directly. `server/**` and
`JoelsWorld.xcodeproj/**` untouched.

⚠️ **Where the commits are.** Another agent was working in the same tree and its `git add -A`
swept up this session's `Shaders.metal` and `CharacterRenderer.swift` changes, so they landed
inside **`ed5eefc` ("A mishit can go wide too")**, whose message is about tennis and says nothing
about any of this. If you go looking for the roughness change in the history, that is where it is.
Only the `ClothingAtlas.swift` half is under a commit of its own.

---

## What changed

Same texture, same one draw call, same three channels. What is *in* the red channel is different.

1. **The shirt and the shorts are two garments now.** They were one unbroken field of colour on
   most characters, because shirt and shorts colours are both per-character data in `npc.json` and
   plenty of characters have them the same — the Admin's are both teal. A shirt hanging over a
   pair of shorts throws a shadow on them, and a shadow is the same shadow whatever colour it
   falls on. This is the single biggest change in the session and it costs two lines.
2. **The armpits.** `limbRings` domes the top of an arm back past the shoulder on purpose, so the
   deltoid is buried in the chest and the ribs beside it are in a pocket the spotlight never
   reaches — and were coming out exactly as bright as the middle of the chest.
3. **The collar has a shadow under it**, which is what makes it read as a collar rather than as a
   white area. See the trap below about where its V ended up.
4. **Contact shadows under the sleeve and the shorts hem**, longer and deeper than before, and a
   little shade at the wrist and the ankle where a separate mesh butts onto the limb.
5. **Cloth grain.** Two octaves of very shallow value noise on the shirt and the shorts only.
6. **The material follows the texture, not the vertex.** A bare forearm below a short sleeve is
   lit as skin now, not as cotton. This was item 4 on session 2's "what is left".

Verified by rendering, not by reasoning: the Mac editor on Junior Campus at `-campitch 1.2…1.35`
and several `-camyaw` values, front, side and back. Both targets build clean (`JoelsWorld` for the
iOS simulator, `JoelsWorldAdmin` for the Mac).

### The files

| File | What changed |
|---|---|
| `Engine/Render/ClothingAtlas.swift` | `shirtHem`; occlusion in all four painters; the collar's V; `cloth`/`valueNoise`/`corner`. |
| `Engine/Render/Shaders.metal` | `CharacterInOut.detailSurface`; `surfaceParams` as a fragment local. |
| `Engine/Render/CharacterRenderer.swift` | `SurfaceMaterial.trim`; the trim palette slot uses it. |

---

## The idea: the red channel is standing in for light that is not there

The scene has one spotlight and a flat ambient term, and without an environment map
`shadeStandard` contributes no indirect specular and the ambient is a constant. So a surface
facing away from the spotlight is lit **exactly** as brightly whether it is out in the open or
wedged under an arm. Nothing in the renderer knows that the deltoid is buried in the chest or
that the shirt hangs over the shorts.

A body with no shadow anywhere it folds reads as a painted cylinder however good the silhouette
underneath is. There is nowhere for that occlusion to come from, so it is painted by hand, in the
same `(u, v)` bands and bumps everything else in this file is made of.

**The price is that it is baked.** The shadow under an arm is there when the arm is raised. Every
one of these marks is kept shallow enough to read as a crease in cloth when it is wrong, which is
why none of them is as dark as the real occlusion would be — the armpit wedge is 0.22 where the
truth is nearer 0.5.

### The numbers, and where they came from

`shirtHem = 0.82` is the one number in this session that is derived rather than tuned, and the
derivation is written out at the constant. Both lathes stand on the body pivot, the shirt's at
`torsoCentreZ` 20 and the shorts' at `pelvisCentreZ` 11; the shirt closes at its own y −6.4 with
its last full ring at −6.0, which is rig z 14.0; that is the shorts' y 3.0, and their profile runs
−6.2…5.0. **Move either lathe and this moves.** Everything else — 0.30 for the cast shadow, 0.22
for the armpit, 0.20 for the shorts hem — was picked by looking.

---

## Traps

Sessions 1 and 2's traps all still apply. These are new.

1. **The front of the collar cannot be seen, and no amount of moving it will fix that.** These
   characters carry a big stylised head on a short neck and it overhangs the chest. Measured off a
   render: at the centre line the highest shirt texel anything can see is around **v 0.52**. The
   V was drawn at 0.63, then at 0.56 chasing it, and neither put a single white pixel on the front
   of anybody. It sits at 0.60 now, where it is a collar if a camera gets low or a head tips back
   (the tennis chase camera does both) and is honestly invisible from the overworld. Going deeper
   means painting white down the middle of the chest, which stops being a collar and starts being
   a bib. **If the front of a collar is ever really wanted, the fix is at the head — a longer neck
   or a smaller skull — not in this file.** The shoulders are the whole collar, and they read.

2. **The atlas has no mipmaps and cannot have them**, because the regions are stacked two guard
   rows apart and a mip level would fold the collar into the waistband. That is the constraint on
   `cloth`: its coarse octave is about 26 texels across and its fine one 13, and anything
   approaching one cycle per texel would crawl as a character walks away from the camera. Do not
   raise the frequency without solving the mip problem first.

3. **`corner` is an integer hash, not a random number.** The atlas has to be the same texture on
   every machine and in every run — it is compiled into the game's look, and a shirt that mottles
   differently each launch is a bug, not a feature.

4. **`u` is not anatomical on a limb.** It is the ring index, and the ring frame is
   parallel-transported along the tube (`SkinnedBody.appendTube`), so nothing in `sleeve` or
   `legwear` can tell the inside of an arm from the outside. The elbow mark is a ring right round
   for that reason and is kept faint enough to read as the arm narrowing at the joint. On the
   **torso and the shorts** `u` *is* anatomical — 0 is the chest, 0.5 the side seam, 1 the spine —
   which is the only reason the armpit wedge can be put where an armpit is.

5. **Buttons are multiplied by `along`.** Without it the top one is painted onto the collar, which
   is a dark spot on a white point rather than a button on a shirt. There are three of them now,
   at 0.24/0.34/0.44, because the collar's V comes down far enough to swallow a fourth.

6. **The shorts above `shirtHem` are painted nearly black on purpose.** They are inside the shirt.
   This also happens to bury session 2's "waist seam" (its remaining-work item 3) — the two-pixel
   line of shorts colour showing through where the torso lathe pinches shut is now a dark line in
   a cast shadow, which is what it should have looked like all along. It is *hidden*, not fixed:
   the geometry still overlaps, and lifting the torso's bottom profile point is still the real fix.

7. **`surfaceParams` is a fragment local now, not `in.surfaceParams`.** A new branch in
   `characterFragment` that changes the colour and forgets to change the material gets the
   vertex's material, which for a bare arm is cotton. `in.detailSurface` is zero on every rigid
   draw, so the rigid path cannot be affected by any of it.

---

## What is left

Session 2's list, minus what this session did, plus what it found.

1. **The hands.** Still the four-ellipsoid blob, still the weakest thing on the body, still the
   biggest single remaining win. Third session running. Sweeping them the way the limbs are swept
   — one tube down the palm with a thumb branch — is the same trick again. They are also still
   `region: .blank`, so they are the only part of the body with no detail on them at all; a
   `hand` region with knuckles and a wrist would be worth having the moment the mesh is worth
   putting them on.
2. **The neck is `region: .blank` too**, and takes no shadow from the head or the collar. It is
   mostly hidden, which is why it has not mattered, but it is a free win alongside the hands.
3. **Nothing distinguishes a teacher from a pupil.** Unchanged from session 2: a second row set —
   long sleeves, long trousers, a tie — selected per character would be a `ColorSlot`-sized change
   plus a `v` offset in the UVs.
4. **There is a hard line down the middle of a sleeve** on some frames, running along the arm
   rather than across it. It is not from this file — the arm painter has no `u`-varying marks —
   and it predates the clothes. Best guess is the shadow map. Somebody should chase it.
5. **The waist seam is hidden, not closed.** See trap 6.
6. **Delete `JW_RIGID_RIG` and the rigid part meshes** once this is trusted. Still true, and the
   gap between the two paths is wider than ever.

---

## Looking at it

The atlas, unchanged from session 2 — it compiles `ClothingAtlas.swift` itself, so what it draws
is what the game uploads:

```bash
swiftc -O -parse-as-library tools/clothing_atlas.swift native/Engine/Render/ClothingAtlas.swift -o /tmp/atlas && /tmp/atlas /tmp/atlas.png
```

A character. The game's camera looks straight down, so the Mac editor is still the way, and
**run it under `script -q`** — Swift's `print` is block-buffered onto a pipe and a plain
`cmd > log &` shows nothing at all and looks exactly like a hang:

```bash
script -q /dev/null "$DERIVED/Debug/Joels World Map Editor.app/Contents/MacOS/Joels World Map Editor" -shot /tmp/shot.png -shotdelay 8 -campitch 1.3 -camzoom 4 -camyaw 1.0
```

Two things about that, learned the hard way this session. The editor connects to the **live**
server, so the player is wherever it actually is and the framing changes between runs — take four
shots at different `-camyaw` and keep the one that is front-on, rather than trying to make one
shot reproducible. And kill any editor still running first (`pkill -f "Joels World Map Editor"`),
or the second one gets "Session already active in another window" and never takes its shot.

## Where the numbers live

- **What the clothes are and where they stop** — `ClothingAtlas`: `sleeveEnd`, `shortsEnd`,
  `sockTop`, `shirtHem`, `trimColor`, and the painters `shirt` / `shorts` / `sleeve` / `legwear`.
- **How strong the baked shadows are** — the coefficients in those four painters. Every one of
  them is a `detail.shade -=` and they are independent of each other.
- **How much grain cloth has** — `cloth`, two amplitudes and two cell counts.
- **What each material is made of** — `SurfaceMaterial` in `CharacterRenderer.swift`, and the
  palette loop that uploads skin/shirt/arm/pants/trim.
- **Everything about the body's shape** — still `CharacterRig`. See session 1.
