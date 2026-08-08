# Handoff — the skinned character body

> **Continued in [HANDOFF-skinned-characters-part2.md](HANDOFF-skinned-characters-part2.md)** —
> clothes. Items 4 and 5 of "What is left" below are done there, and by texture rather than by
> geometry. Read this one first; it is where the mesh comes from.
>
> A separate thread runs off this one:
> **[HANDOFF-standing-pose.md](HANDOFF-standing-pose.md)** — the resting pose, what a character
> does while nothing is happening, and the proportions of the limbs, shoes and body. Item 1 of
> "What is left" below, the hands, is still open after it.

**Session 1.** This is the first step of a longer piece of work: raising character fidelity
towards a proper modelled character. Ben asked for **Route A** of three options put to him — the
one that can be done automatically, in the engine, with no artist and no bought asset.

Zone note: this touches `Engine/Entity`, `Engine/Render` and the Mac editor —
red under [AGENTS.md](../AGENTS.md). Ben asked for it directly ("Do route A"). `server/**` and
`JoelsWorld.xcodeproj/**` are untouched.

Read **"Traps"** before changing any of the numbers.

---

## The question this answers

Ben showed a reference render — a stylised cartoon boy, sculpted, with a collar, buttons,
folded socks and a painted face — and asked: *how much work to get characters to that fidelity,
and could the limbs be generated automatically?*

The estimate given, and still the plan:

| | What it is | Cost | What it buys |
|---|---|---|---|
| **A** ← *this session* | Auto-generate one skinned mesh from the rig the game already has | ~4–7 days | Continuous limbs, real joints, one draw call. Not the reference image. |
| **B** | Import an authored, rigged glTF character | 2–4 weeks + the asset | The reference image, near enough |
| **cheap wins** | Face texture, silhouette detail | ~1 day | *Turned out to be already done* — see below |

**Correction to the estimate as given:** the heads are already textured. Every head GLB in
`assets/models/heads/` carries two images and named `Eyebrow` / `EyeLashes2` / `EyeSocket`
materials, and `GLTFLoader` already loads and binds them. The "paint a face texture" cheap win
does not exist; that work is done.

---

## What Route A actually is

The body used to be **twenty separate rigid solids** — a lathed torso, a lathed pelvis, a
tapered capsule per limb segment, and a sphere stuffed into every elbow, knee and shoulder to
hide the seam where two capsules crossed. From overhead it reads as a body. Up close, in a
minigame camera, the joints are visibly balls and the limbs are visibly three pieces.

Now it is **one skinned mesh**. An arm is a single continuous tube swept from the shoulder
through the elbow to the wrist, and the vertices near the elbow are moved by a blend of the
upper arm's bone and the forearm's rather than by one or the other. The joint stops being a gap
that needs filling and becomes a crease.

**Nothing was modelled by hand.** The rig already knew where every joint sits and how thick a
limb is at each end; the geometry *and* the skin weights are both generated from that. That is
the whole trick, and it is why this is a few hundred lines rather than an art commission.

---

## Where it stands

Builds clean for the iPhone 17 simulator and for the Mac editor. Runs on both.

**Looked at, from the side, at 4× zoom in the Mac editor, against the rigid rig.** It works. An
arm now runs from the shoulder to the wrist as one continuous tapering tube with a crease at the
elbow; a leg does the same from hip to ankle. Side by side with `JW_RIGID_RIG=1` the difference
is obvious — the old rig has a visible ball at the knee and a limb in three pieces.

3,746 vertices, 7,096 triangles, one draw call.

Two things the eye goes to now, in order:

1. **The hands.** Still the old four-ellipsoid blob, still visibly a cluster of balls, and now
   the least finished thing on the body — the limbs used to hide it. Deliberately left rigid;
   see "What is left", item 3.
2. **The shoulder line.** The sleeve starts a little low on the chest, leaving a wedge of
   shirt above it. Pre-existing, but more noticeable now the arm is smooth. A ring or two more
   at the top of `appendArms` with a wider radius would read as a yoke.

Not yet checked: emotes and the tennis swing. See "What is left", item 2.

### The files

| File | What changed |
|---|---|
| `Engine/Entity/CharacterRig.swift` | **New** `bindPose()` and `RigBindPose` / `RigChain`. Everything else untouched. |
| `Engine/Render/SkinnedBody.swift` | **New file.** The whole mesh and weight generator. |
| `Engine/Render/Shaders.metal` | `SkinVertex`, `characterSkinnedVertex`, `shadowSkinnedVertex`; tint and roughness/metalness moved into interpolants so one fragment shader serves both paths. |
| `Engine/Render/CharacterRenderer.swift` | Builds the skinned mesh, `drawSkinnedBody`, `CharacterPipelines`. `buildHand()` lost its `private`. |
| `Engine/Render/Renderer.swift` | Two new pipeline states, handed to the character renderer. |
| `JoelsWorldAdmin/Editor/KeyboardMovement.swift` | Camera pitch/yaw keys. |
| `JoelsWorldAdmin/Editor/AdminMapViewController.swift` | Applies them per frame. |

### The one idea worth understanding

**The pose code did not change at all.** Not the walk cycle, not the emote table, not the IK,
not the tennis override. `CharacterRig.pose` still produces a world transform per body part
exactly as it did.

What changed is how those transforms are *spent*. A bone's skinning matrix is

```
M = thisFrame'sTransform × inverse(bindTransform)
```

which is the identity for a character standing exactly in the bind pose and departs from it as
the pose does. So every existing transform is reused verbatim as a bone. This is why a 2,000-line
pile of pose maths did not have to be rewritten, and it is the property to protect.

### The bones

Thirteen, in `SkinnedBody.boneOrder`, each sourced from an existing `RigPart`:

```
pelvis  torso  neck
leftUpperArm  leftLowerArm  leftHand
rightUpperArm rightLowerArm rightHand
leftUpperLeg  leftLowerLeg
rightUpperLeg rightLowerLeg
```

The shoulders, elbows and knees are **not** bones. They were never joints — only the plaster
over one. `pose()` still emits them and the skinned path simply ignores them.

### What is generated versus reused

- **Arms and legs are new geometry.** `SkinnedBody.limbRings` sweeps rings along the two-bone
  chain, `appendTube` stitches them. Radii come from the same `shoulderEndScale` /
  `elbowEndScale` / `wristEndScale` constants the old capsules used, so the limbs are the
  thickness they always were.
- **Torso, pelvis, neck and hands keep their existing meshes.** A lathe with a waistline and a
  hem that overhangs the shorts is already the right shape; what it lacked was any way to bend.
  All that was added is weights.

### Colour

One mesh means colour cannot come from the draw call. Each vertex carries a `ColorSlot`
(skin / shirt / arm / pants) indexing a four-entry palette uploaded with the joint matrices.
Roughness and metalness ride the same palette. Slot assignment matches the old per-part colours
exactly, so no character changes appearance.

### Cost

One draw call for the body instead of nineteen, twice per character (scene + shadow). About
3,000 vertices. The joint matrix and palette blocks are ~1.2 KB via `setVertexBytes`.

### Fallback

If the mesh fails to build, or the pipelines have not been handed over, `drawSkinnedBody`
returns `false` and the old rigid path draws instead. It is still there and still works.

`SIMCTL_CHILD_JW_RIGID_RIG=1` (or any `JW_RIGID_RIG` in the environment) forces the rigid path.
**This is a debugging aid for A/B comparison and should probably be deleted once the skinned rig
is trusted** — it is a live branch nobody will exercise.

---

## Testing it — read this first, it is where a session gets lost

The game's camera looks **straight down**. From overhead a rig could have no elbows at all and
nobody would know. Two ways to get a usable angle:

**The Mac editor (best).** It runs the same `Renderer` and now has camera controls:

- **R / F** — tip the camera towards the horizon and back
- **Q / E** — swing it round the focus
- **0** — put it back overhead
- scroll to pan, ⌃-scroll to zoom (up to 5×)
- arrows or WASD walk the focus, through the real movement and collision code

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorldAdmin -destination 'platform=macOS' build
```

`AdminScreenshot` can also grab a frame headlessly and quit — see `AdminScreenshot.path` and
`.delay` — which is the way to script a before/after.

**The simulator.** `WalkTest` already has `-pitch <radians>`, `-zoom <n>`, `-at <x> <y>` and
`-walktest`, reapplied every frame in `GameState.swift:546`. So:

```bash
xcrun simctl launch <udid> com.allr.joelsworld -walktest -pitch 1.2 -zoom 3
```

What **does not** work: launching plainly and hoping to land in the tennis scene. Which map the
app opens depends on shared server state, and `-tennis3ddemo` on its own did not get there in
this session. A whole hour went into fighting that. Use the Mac editor.

---

## What is left

1. **The hands.** Now the weakest thing on the body. They are four merged ellipsoids and they
   read as a cluster of balls at any close camera. Sweeping them the way the limbs are swept —
   one tube down the palm with a thumb branch — is the same trick again and is the single
   biggest remaining win. This is the next job.
2. **Check the extremes.** An emote is where linear blend skinning fails: `wave` folds an elbow
   hard, and the tennis swing coils the waist. Watch for a collapsing "candy wrapper" at the
   elbow and for the deltoid tearing off the chest. Not yet done.
3. **The wrist is deliberately not blended.** The forearm bone's roll is the shortest arc onto
   the arm's direction; the hand bone's is pinned to the elbow's bending plane. The two can
   differ by most of a turn, and blending across that is the classic wrist-screws-shut failure.
   If the wrist looks pinched, the fix is *not* to blend it — it is to give the forearm bone the
   hand's basis.
4. **Short sleeves.** The arm is one colour from shoulder to wrist because `arm_color` defaults
   to `shirt_color`. A sleeve line partway down the upper arm — one extra colour slot and a
   ring-index threshold in `appendArms` — would be a real step towards the reference image and
   is close to free now the geometry is continuous. It changes every existing character's
   appearance, so it is Ben's call.
5. **Collar, cuff, sock roll.** Extra points in `torsoProfile` and in the limb radius table.
   Cheap, and the next-biggest visual step after this one.
6. **Delete the `JW_RIGID_RIG` escape hatch and the rigid part meshes** once this is trusted.
7. **Route B is still Route B.** This does not get to the reference image and was never going to.

---

## Traps

1. **`bindPose()` must agree with `pose()` at rest.** Same constants, same order, same IK. It is
   written out separately because `pose()` needs a `GameCharacter`, a `RigRuntime` and a clock,
   and bakes in breathing and idle sway. Getting it wrong is *not* fatal — the mesh is built in
   whatever space it returns and skinned back out of it — so a disagreement shows up as a body
   that is subtly the wrong shape everywhere, not as a crash. Which makes it hard to spot. If
   anyone changes an anatomy constant in `CharacterRig`, check both.

2. **Weights must sum to 1.** `SkinWeights.fill` exists for this: it hands a bone the
   *remainder*, not a fixed share. Weights that do not sum to 1 shrink or inflate the surface as
   it moves, and the bug reads as a limb quietly deflating mid-stride.

3. **Winding.** `appendTube` reproduces `MeshFactory.lathe`'s vertex order and index pattern
   exactly — including its left-handed `(r·sinφ, y, r·cosφ)` revolve. Deviate and the tubes come
   out lit from the inside while every other mesh in the game is fine, which looks like a shader
   bug and is not.

4. **Frames are carried forward, not rebuilt.** Each ring squares the previous ring's cross-axis
   against its own tangent. Rebuilding from a fixed reference per ring makes the tube twist as it
   turns a corner — a spiral crease down the inside of an arm.

5. **`SkinVertex` layout is hand-matched between Swift and Metal.** Nothing checks it. The joint
   indices are floats rather than `ushort4` specifically to keep every field 4- or 16-byte
   aligned in both languages. If you add a field, add it to both and keep the alignment.

6. **`characterFragment` now reads `in.tint` and `in.surfaceParams`, not the uniforms.** Both
   vertex shaders fill them. A new vertex function that forgets to will render black.

7. **`drawSkinnedBody` leaves the encoder on the rigid pipeline**, because the head, shoes,
   racket and props drawn immediately after it are all rigid meshes. Do not "tidy" that away.

---

## Where the numbers live

Everything tunable is a named constant, and most of it is shared with the old rig:

- **Anatomy** — `CharacterRig`: `torsoProfile`, `pelvisProfile`, the `*EndScale` radii,
  `shoulderRadius`, joint anchors, bone lengths.
- **How wide the joint crease is** — `blend` in the `limbRings` calls in `appendArms` /
  `appendLegs`. Larger is smoother and softer; smaller is a sharper fold.
- **How far a limb holds onto the body** — the `anchor` tuple, same calls. 0.5 at the shoulder
  means the top of the deltoid is half chest.
- **Ring counts** — `segments` and `capSteps`, same calls. `radial: 16` in `appendTube`.
- **Where the torso hands over to the pelvis and the neck** — the profile heights in
  `appendBody`, read on the lathe's own axis where `-6.4` is the shirt hem and `13.6` is where
  the neck leaves it.
