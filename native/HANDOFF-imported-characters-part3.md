# Handoff — bought characters, part 3: closing the hand

**Session 7.** Part 2 ([HANDOFF-imported-characters-part2.md](HANDOFF-imported-characters-part2.md))
got the palm aimed and rolled correctly and left the fingers as the next job:

> **The fingers never close.** They ride the hand rigidly, which is what gives a bought model
> articulated fingers for nothing, and it means a held racket sits in an open palm. The grip is in
> the right place and at the right angle now; the fingers just do not curl around it. Curling them
> needs a driver per finger, and the rig has none.

They close now, and it turned out **not** to need a driver per finger.

Zone note: `Engine/Entity/HumanoidRig.swift` and `Engine/Render/ImportedCharacterBody.swift` only —
both red under [AGENTS.md](../AGENTS.md), both files part 1 added, and Ben asked for this work
directly. Nothing else in the engine changed, `CharacterRig` included. `server/**` untouched.

---

## The rig does not need fifteen new bones. It needs one number.

Part 2's "needs a driver per finger" is what the retargeter's own shape suggests: everything else
on the body is *aimed*, and aiming needs something to aim at. Fifteen finger drivers per hand,
posed by the gait code, animated by nothing, is a lot of engine for a hand.

But a finger is not like an arm. An arm has to arrive somewhere — at a ball, at a face, at a
racket — and that is why it needs a target. A finger only ever does one thing, which is close, and
how far it has closed is **one number between an open hand and a fist**. So the fingers are posed
from a scalar rather than aimed at anything, and the whole question becomes where the scalar comes
from.

It comes from something the rig already says: `RigPose.holding`. If there is a racket in the hand,
the hand is shut round it; if there is not, it hangs relaxed. That is a field
`CharacterRig` has set since long before any of this, so **nothing outside these two files
changed** — no new `RigPart`, no new emote data, no new anything.

## The axis is measured off the hand, not assumed

Which way a finger bends is the part that could quietly have been wrong, so it is derived from
things already measured at load rather than written down.

Two directions are known about a hand: `boneAxis`, along the fingers, and `rollAxis`, out towards
the thumb and square to it — part 2 put both there. Call them **`f`** and **`t`**, and their cross
product **`n = t × f`**.

- For a **right** hand, `n` is the way the palm faces, and closing a finger is a rotation about
  **`+t`**. Check it on your own hand: fingers north, palm down, thumb west; curling takes the
  fingertips downward, the way the palm faces.
- A **left** hand is that mirrored, so `n` lands on the *back* of the hand and the same closure is
  a rotation about **`−t`**.
- The **thumb** is the odd one, and comes out the same on both hands. It does not close alongside
  the fingers, it comes *across* to meet them, which is a rotation about **`n`** either way.

Two vectors and a cross product, no new landmark, and it works on any rig whose thumb `rollAxis`
was found. A hand with **no thumb bone gets no curl at all** rather than a guessed one — the same
rule the palm roll already follows, and the loader says which hands are curling so a silent
half-open hand cannot hide:

```
[Render]   30 finger joints curl, on leftHand and rightHand
```

## The bends compound for free

Each joint's angle is its *own* share, not the total: 0.90 rad at the knuckle, 1.15 at the middle
joint, 0.70 at the last one. They add up down the finger because they are applied in `order`,
which visits a parent before its children — so a child inherits its parent's bend as its rest and
then adds its own. A closed fingertip has been through about 2.75 rad, a bit under a half turn,
which is a fist. Anything deeper than the third joint is an exporter's `_end` marker and gets
nothing.

The same `order` pass is what makes the classification cheap: which joints are fingers, how deep
each sits under its hand, and which are thumb all fall out of one walk **down** the tree, instead
of a walk back up to the wrist per joint.

## A relaxed hand is not a bind pose

The open value is deliberately **not zero**. A model is rigged in a T-pose with its fingers
straight out and slightly splayed, so a hand left at its bind pose hangs off the wrist as a flat
paddle — which is what every standing shot in parts 1 and 2 has, once you look for it. So there
are two tables, not one: a relaxed hand with a bend in every knuckle is the pose the character
stands in, and the grip is what it closes *from*.

This is the one part of this session that changes how the character looks when it is doing nothing
at all, and it is worth Ben's eye for that reason rather than because it is risky.

## It snaps rather than blends, and that is the right call

A hand that took a quarter of a second to close would be gripping air on the way in and clutching
nothing on the way out — the racket it is closing around appears and disappears in a single frame,
because it is drawn only while `pose.holding` is set. Matching the prop exactly is what looks
right. `solve` has no timestep to smooth over in any case.

## `RigPart.rightHand` is the character's left, again

The racket goes in the hand `CharacterRig` composes `holdingTransform` off, which is
`rightHandAnchor` — and by part 2's naming inversion that is the character's **left** hand. So the
grip test names the *part*, not the bone, and stays right if that anchor ever moves. Whether a
left-handed tennis player is what anyone intended is a separate question and not one this session
touched.

## What is left

- **The feet.** Unchanged from parts 1 and 2, and worth reading part 2's note on it before
  starting: the material is there in `RigPose.leftShoeBox`, and so is the argument against, which
  is that the engine's own shoe stays level in flight and a foot driven from it would too. Looking
  at the shoe frame this session, it is level in rather more than flight — `atan2(shin.y, -shin.z)`
  reads the shin's *sideways* component, not its pitch, so a leg swinging fore and aft turns that
  frame not at all. That is a `CharacterRig` question, not an imported-character one.
- **Fingers do not adduct.** They close, but they stay fanned as the bind pose splayed them; a real
  grip brings them together as well as round. Another table if it ever matters.
- **Nothing curls a hand except holding something.** A pocket, a fist thrown in an emote, a hand
  flat against a wall — all of those would want the scalar to come from somewhere else, and the
  scalar is the only wire that would need moving.
- **Normal maps**, **48,728 triangles**, and **limb reach** — all exactly as part 1 left them.

## Checking it

The lab, from `native/`:

```bash
xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
JW_CHARACTER_MODEL=models/characters/stylized_boy.glb "$APP" \
  -labtake emote-tennis -labview threeQuarter -labwidth 4 -labtime 6 -labsize 1000 1000 \
  -labnogrid -labnoruler -labshot /tmp/grip.png
```

**`emote-tennis` is the take**, because it is the only one that puts anything in a hand, and
`threeQuarter` is the view — the hand is small in frame, so crop to it rather than squinting.
`stand` front-on is the other one to look at, for the relaxed hand rather than the closed one.

Both schemes build. This session's pictures: `emote-tennis` three-quarter before and after side by
side (open splayed palm against a closed fist round the handle), the same take front, back and
side, and `stand` front-on with both hands hanging with a natural curl instead of flat.
