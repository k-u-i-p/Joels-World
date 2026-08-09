# Handoff — bought characters, driven by our own movement code

> **Read [part 2](HANDOFF-imported-characters-part2.md) after this one.** It takes the top two
> items off "What is left" below — and finds that the character was mirrored the whole time.

**Session 5** of the character work, and a change of approach rather than a continuation.
Sessions 1–4 ([HANDOFF-skinned-characters.md](HANDOFF-skinned-characters.md) onward) built a
humanoid body by generating its vertices in Swift. This session stops doing that and imports one
instead, without changing the rig, the gaits, the IK, the emotes or any minigame.

Zone note: `Engine/Render`, `Engine/Entity`, red under [AGENTS.md](../AGENTS.md). Ben asked for
this directly. `server/**` untouched. `JoelsWorld.xcodeproj/**` untouched — the project uses
file-system synchronised groups, so new files under `native/Engine/` are picked up with no
project edit at all.

---

## What this is

`CharacterRig.pose` produces what it always produced: a world transform per `RigPart`. A new
layer turns those into one skinning matrix per joint of **somebody else's skeleton**. Nothing
upstream of it knows it exists.

| File | What |
|---|---|
| `Engine/Render/GLTFLoader.swift` | reads skins — `JOINTS_0`, `WEIGHTS_0`, `skins[]`, `inverseBindMatrices` |
| `Engine/Entity/HumanoidRig.swift` | **new** — canonical bones, name matching, the retargeter |
| `Engine/Render/ImportedCharacterBody.swift` | **new** — GPU buffers, texture, the async store |
| `Engine/Render/CharacterRenderer.swift` | `drawImportedBody`, and skipping the head/shoe GLBs when one draws |
| `assets/models/characters/stylized_boy.glb` | the first bought model |

Switch it on with an environment variable, which is how the lab does it:

```bash
JW_CHARACTER_MODEL=models/characters/stylized_boy.glb
```

Unset, everything behaves exactly as before.

## The idea, in one paragraph

Every transform the rig emits has its **+Y along the bone** — `IKSolver.segmentTransform` builds
the limbs that way and the torso, pelvis and neck take a `rotationX(π/2)` to match. So the
*direction* each bone should point is knowable. The retargeter aims the model's bones along those
directions and gets their positions from forward kinematics down the model's **own** skeleton.
That is what makes the rest-pose mismatch a non-problem: this model is a T-pose and the rig's rest
hangs the arms by the thighs, and because we aim bones rather than replay a delta from a rest
pose, the two never have to agree.

Bones with no driver ride their parent rigidly. That is why a 52-joint model gets **articulated
fingers for free** — the hand is aimed and fifteen finger bones follow it as one piece, after two
sessions spent lofting four fingers by hand.

## No new shader, no new pipeline

`characterSkinnedVertex` already blends four weighted bone matrices and `characterFragment`
already has a textured branch. An imported character is the same pipeline with different buffers
bound: `clothed: false` is what sends the fragment past the clothing-atlas branch to the textured
one. The only genuinely new thing is that the bone matrices go in an `MTLBuffer` — `setVertexBytes`
tops out at 4 KB, which is 64 matrices, and a bought rig will exceed that as soon as one has twist
bones.

## Four bugs, because the next model will hit all four

**1. The inverse-bind matrices carry the exporter's scale.** This file came through FAB's FBX
converter with a 0.01 on the root, so every `inverseBindMatrix` has a 100 in it. `solve` builds
joint transforms from a rotation and a position with no scale, so `jointWorld × bind⁻¹` came out
part-inverse-scale and part-not: **joints in the right places, flesh around them six times too
big.** `HumanoidSkeleton` orthonormalises the bind pose now. Per-bone scale in a bind pose is an
exporter artefact, never something an artist meant.

**2. `RigPart.pelvis` is not the hip joint.** It is the centre of the pelvis *lathe*, several
units lower, and anchoring the model's root on it buries the character to the thigh. The real hip
is recoverable exactly, and this trick is worth remembering because it gives you **every joint in
the rig**: a limb's transform sits at the *midpoint* of its two joints, and the joint fillers
(`.leftKnee`, `.leftElbow`, `.leftShoulder`) sit on the joint itself. So `hip = 2 × midpoint −
knee`, and likewise for wrists and ankles.

**3. Scale by the hips, not by total height.** `bodyPivotHeight` is derived from leg length so the
soles land on the floor, so a model whose hips are at the rig's hip height has legs that reach the
ground. Matching total height instead leaves a big-headed model on tiptoe or shin-deep, because
the head is a different fraction of the whole in every stylised character. `HumanoidProfile.scaleMode`
can still ask for `height` if something has to fit a doorway.

**4. `LeftShoulder` in a bought rig is the clavicle, not `RigPart.leftShoulder`.** That part is a
deltoid ball aligned *down the humerus*; a clavicle runs sideways from the spine. Aiming one down
the arm swings the whole shoulder girdle inward and buries the arms in the chest. The clavicle
rides the spine now, which is nearly what a real one does.

### And the one that cost the most

**Do not take the driver's roll.** The obvious move is to take the whole rotation for bones whose
spin looks meaningful — the spine, whose roll is the character's heading, and the hands, whose
transform `IKSolver.basis` builds as a real orthonormal basis. It aligns two quantities that are
not the same quantity: the rig's parts are lathes, so the torso's +Z means "the way the lathe's
seam faces", while a bought bone's local axes mean whatever the rigger's software chose. It yawed
the entire character 90°, and the arithmetic looks completely reasonable. The **root** takes the
driver's rotation whole because its roll genuinely is the heading; everything below takes direction
only and inherits roll from its parent.

## Modularity — what a second model needs

Probably nothing. `HumanoidNaming` matches Mixamo, Blender/Rigify, Unity humanoid and VRM names,
strips the `mixamorig:` namespace and the `_010` suffixes an FBX converter adds, and matched
**22/22** bones on this file with no configuration. Scale, bone directions and the skeleton tree
are all measured on load.

Where a rig will not name-match, drop a `<model>.rig.json` beside the `.glb`. Every key optional:

```json
{
  "upAxis": [0, 1, 0],
  "forwardAxis": [0, 0, 1],
  "scaleMode": "hips",
  "targetHeight": 66,
  "boneOverrides": { "spine_03": "spine2", "clavicle_l": "leftShoulder" }
}
```

The log line on load says how many bones matched and names the ones that did not. An unmatched
arm is why a character came out in a heap.

## What is left

- **The palm.** The hands hang at whatever roll the forearm carries them to, because dropping the
  driver's roll dropped `IKSolver.basis`'s too. The fix is to measure, at load, which of the model
  bone's own axes corresponds to the driver's — a constant per bone, computed once. This is the
  next job and it is the most visible thing remaining.
- **The feet.** No `RigPart` reaches an ankle, so a foot rides the shin and the toes point as the
  shin swings. Fine for a walk, stiff in a sprint's foot-plant.
- **Normal maps.** The file ships one and it is ignored; the shared fragment shader has no tangent
  frame. The base colour is doing all the work.
- **48,728 triangles**, against 7,344 for the procedural body. One character is fine. A classroom
  of thirty is not — decimate in Blender before this goes near a crowded map.
- **Limb reach.** The model's limb lengths win over the rig's, so where the rig asks a hand to
  reach a point its own arm could reach and the model's arm is shorter, the hand stops short.
  Tennis is where this will show first.
- **Left and right.** Not yet verified against an asymmetric action. Hold a racket in the lab and
  check it lands in the right hand before trusting it.

## Checking it

```bash
JW_CHARACTER_MODEL=models/characters/stylized_boy.glb \
  "Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab" \
  -labtake walk -labsheet /tmp/walk.png -labframes 4 -labwidth 5
```

Both schemes build. `stand`, `walk` and `run` were rendered and looked at — feet on the floor,
arms swinging, the model facing the camera in `-labview front`. Nothing here is claimed on the
strength of the arithmetic alone; every one of the five bugs above was found by looking at a
picture.
