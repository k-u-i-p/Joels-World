# Handoff — bought characters, part 2: the hands, and which side they are on

> **Read [part 3](HANDOFF-imported-characters-part3.md) after this one.** It takes the fingers off
> "What is left" below — and they turned out not to need a driver each.

**Session 6.** Part 1 ([HANDOFF-imported-characters.md](HANDOFF-imported-characters.md)) got a
bought, rigged glTF character standing, walking and running on our own movement code. This session
took the top two items off its "What is left" and found that one of them was hiding the other.

Zone note: `Engine/Entity/HumanoidRig.swift` and `Engine/Render/ImportedCharacterBody.swift` only —
both red under [AGENTS.md](../AGENTS.md), both files part 1 added, and Ben asked for this work
directly. Nothing else in the engine changed. `server/**` untouched.

---

## The whole character was mirrored

`RigPart`'s sides are named for **the rig's mirror image, not the character's**.
`CharacterRig.leftShoulder` is `(3, -10, 26)`, and local −Y is the character's *right* — the file
says so itself, twice, and `LocomotionSelfTest` says "the character's right leg goes to `leftHip`".
A bought rig names its bones the way everything else does, for the character:
`mixamorig:LeftArm` sits at engine +Y.

So `HumanoidBone.leftUpperArm → RigPart.leftUpperArm` looked like the obviously right line and put
the model's left arm on the rig's right one. Every arm, every leg, the whole body.

**Nothing could see it.** Standing, the idle sway, the walk, the run, every measurement in part 1's
report — all symmetric, all identical under a mirror, all passing. It took `emote-wave`, which uses
one arm, before anything looked wrong at all: the boy waved with the wrong hand.

That is the kind of bug worth building a tripwire for, so there is one now.
`HumanoidSkeleton` does one line of arithmetic per limb at load — is this bone on the same side of
the centre line as the `RigPart` driving it? — and the loader says so loudly:

```
[Render]   MIRRORED — these bones are on the wrong side of the body: leftUpperArm, rightUpperArm
```

Both sides of that comparison are rest poses about the character's own centre line, so the sign of
Y is the entire test. Bones near the middle say nothing and are left out. It was checked by putting
the mirror back and watching it fire, which is the only way to trust an assertion.

## The palm — two bugs, one of them ten times bigger than the other

Part 1 named the palm as the next job and described the *smaller* half of it.

### The hand was being aimed down its own thumb

`boneAxis` is measured from each joint to the next one down the limb, and a hand has no named
successor — so it fell back to "the first child in the file". A hand's first child in file order is
`LeftHandThumb1`. The palm's long axis was the thumb, so aiming the hand along the forearm laid the
*thumb* along the forearm and stood the whole hand about a third of a turn out of true.

It takes the **centroid of its fingers** now, with the thumb left out where there is anything else
to use. A thumb leaves the palm's plane by design; the fingers are the hand's length.

### The roll, and the landmark that makes it possible

Part 1's rule — direction from the driver, roll from the parent — is still right, and the reason is
still the one written down there: the rig's parts are lathes, so their local axes and a bought
bone's local axes are not the same kind of quantity, and rolling one onto the other yawed the whole
character 90°.

The way past it is **not** to find a better axis convention. It is to name a *physical feature both
skeletons have* and turn one onto the other. For a hand that feature is the thumb, and it is
measurable at both ends:

- **On the model**, from its own thumb bone. Every rigged humanoid has one, and every naming scheme
  in `HumanoidNaming.aliases` spells it `thumb`.
- **On the rig**, it is `+Z` of the hand part's frame, and it is a constant. `CharacterRig.Hand`
  roots the thumb at `(-0.30, 1.30, 1.60)` and splays it "out towards +Z, the thumb side"; the
  other hand is that mesh mirrored in X, which leaves +Z alone. Both hands agree, and the
  `Hand.restRoll` quarter-turn is already inside the part transform — so a bought model's thumb
  lands exactly where the engine's own does, restRoll included, for free.

The measurement is one vector per hand, taken at load and held in the joint's own frame the same
way `boneAxis` is. Per frame it costs a second `shortestArc`, and that arc comes out a **pure spin
about the bone rather than a re-aim**, which is worth knowing because it is not obvious: both
vectors are already square to the bone. `rollAxis` was squared up against `boneAxis` at load
(a thumb that sits 20° forward of the palm would otherwise re-aim the hand), the aim puts `boneAxis`
exactly on the driver's +Y, and `rollTarget` is square to that +Y by construction.

**Do not reach for the obvious alternative**, which is to take the driver's whole rotation relative
to both rest poses — `model = driverNow × driverRest⁻¹ × modelBind`. The offset does cancel the axis
conventions, honestly and exactly, and it still does not work here: it says "when the driver is at
rest, the model is in *its* bind pose", and this model's bind pose is a T-pose while the rig's rest
hangs the arms by the thighs. The arms would stay out sideways forever. Aiming is what lets two
skeletons that have never agreed on a rest pose drive each other, and this is a roll bolted onto
aiming, not a replacement for it.

## What is left

- **The feet.** Unchanged from part 1: no `RigPart` reaches an ankle, so a foot rides the shin.
  Looked at again this session and it is better than it sounds — the planted foot is flat and the
  trailing one is toe-down through a sprint. If it is ever worth doing, the material is there:
  `RigPose.leftShoeBox` is a real frame at the ankle with its +X along the foot, so the imported
  foot could do exactly what the engine's own shoe does. That is the argument for it and also the
  limit of it — the engine's shoe stays level in flight, and so would the foot.
- **The fingers never close.** They ride the hand rigidly, which is what gives a bought model
  articulated fingers for nothing, and it means a held racket sits in an open palm. The grip is in
  the right place and at the right angle now; the fingers just do not curl around it. Curling them
  needs a driver per finger, and the rig has none.
- **Normal maps**, **48,728 triangles**, and **limb reach** — all exactly as part 1 left them.

### And one thing to check that is not about imported characters at all

While working out which way the rig's hand frame faces, this fell out: **the procedural body's two
hand meshes look like they are on the wrong arms.**

`CharacterRenderer.buildHand` builds a hand with its fingers along +Y, its thumb at +Z and — its
own comment says so — "+X, the back of the hand", so the palm faces −X. Point your right hand's
fingers north with the palm down and the thumb goes west: `fingers × palm = thumb` is the right
hand's relation, and `(0,1,0) × (-1,0,0) = (0,0,1)` satisfies it. So `buildHand` is a **right**
hand — and `SkinnedBody` puts it on `RigPart.rightHand`, which by the naming above is the
character's **left**, and the mirrored copy on the character's right.

This is arithmetic off two source comments, not a picture, and nothing here is claimed on the
strength of arithmetic alone — so it has not been changed. It is also nearly invisible: mirroring a
hand in X moves the palm and the back but leaves the thumb exactly where it was, which is why a
cartoon hand looks much the same either way and why the imported character's hands are unaffected
(the roll above targets the thumb, and the thumb is the mirror-invariant part). **Worth Ben's eye
before anyone touches it.**

## Checking it

The lab, from `native/`:

```bash
xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
JW_CHARACTER_MODEL=models/characters/stylized_boy.glb "$APP" \
  -labtake emote-wave -labview front -labwidth 6 -labsize 700 700 \
  -labnogrid -labnoruler -labsheet /tmp/wave.png -labframes 4
```

**`emote-wave` is the take to use**, and the reason is the whole first half of this document: it is
the shortest thing in the lab that is not symmetric. Run it without `JW_CHARACTER_MODEL` too and
put the two side by side — the same arm should come up.

Both schemes build. This session's pictures: the wave (right arm, palm to camera, thumb up, matching
the procedural character frame for frame), `stand` front-on at 2400px with both hands hanging
palm-to-thigh, `walk` and `run` filmstrips over one stride, and `emote-tennis` with the racket
landing in the hand at a grip angle that reads.
