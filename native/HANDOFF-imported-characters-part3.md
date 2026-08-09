# Handoff — bought characters, part 3: the hands close and the feet come off the shin

> **Read [part 4](HANDOFF-imported-characters-part4.md) after this one.** It takes the top item
> off "What is left" below — and finds that the shin pitch this session added had been putting the
> toe of every *standing* shoe 2.7 units under the floor, unseen because a foot's pitch is
> invisible from the front. Part 4 also removes the procedural character entirely.

**Session 7.** Part 2 ([HANDOFF-imported-characters-part2.md](HANDOFF-imported-characters-part2.md))
left two things at the top of its "What is left", and this session did both — plus a bug in
`CharacterRig` that the second one turned up.

> **The fingers never close.** … Curling them needs a driver per finger, and the rig has none.
>
> **The feet.** No `RigPart` reaches an ankle, so a foot rides the shin.

The fingers close, and it turned out **not** to need a driver per finger. The feet are driven now,
by the one frame the pose already had at the ankle — which is where the `CharacterRig` bug was
hiding.

Zone note: `Engine/Entity/HumanoidRig.swift`, `Engine/Render/ImportedCharacterBody.swift` and nine
lines of `Engine/Entity/CharacterRig.swift` — all red under [AGENTS.md](../AGENTS.md), and Ben
asked for all three directly. `server/**` untouched.

---

# The hands

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

---

# The feet

## First, the shoe frame was not turning

Part 2's plan for the feet was to drive them from `RigPose.leftShoeBox`, and its stated worry was
that the engine's own shoe stays level in flight, so a foot driven from it would too.

The shoe was staying level in rather more than flight. The frame is built in
[CharacterRig.swift:1461](Engine/Entity/CharacterRig.swift:1461), and its pitch was

```swift
Float4x4.rotationY(atan2(leftShin.y, -leftShin.z))
```

**`shin.y` is sideways.** In this frame — the character's own, +X forward, +Y left, +Z up — a leg
swinging fore and aft moves entirely in X and Z, so that angle came out **0 for the whole of every
gait**. The shoes were dead level from heel strike to push-off, and the only thing that ever moved
them was the small sideways component a hip abduction leaves, which is a shoe rolling for no
reason rather than pitching for a good one. It reads exactly like a faithful port of a three.js
expression whose Y *was* up; here it is not, and the comment above it — "the shoe yaws to follow
the shin's pitch" — was describing something the code had never done.

It reads `shin.x` now, negated: `rotationY` takes +X *down* as its angle grows, and a shin leaning
forward should take the toe *up*. Straight down is still 0, so a standing character's feet are
flat exactly as before, and everything that changed is inside a stride.

This is the whole of the `CharacterRig` change, and it moves the **procedural** character too —
that is what the `run` filmstrips below are for.

## Then the foot could be driven by it

`HumanoidBone.driver` used to be a `RigPart?`, and a foot has no part to name. It is a small enum
now:

```swift
enum Driver { case limb(RigPart); case shoe(rigLeft: Bool) }
```

with one property that matters, `alongBone` — **which column of the driver's frame runs down the
bone**. Every `RigPart` says +Y, because `IKSolver.segmentTransform` builds them that way. A shoe
frame says **+X**, because the shoe box is 11 long in X and 5 tall in Z. That one number is the
entire difference between the two kinds of driver; the aim, the roll and the forward kinematics
underneath are the same code they were.

The side inversion applies here like everywhere else — `leftShoeBox` is built from `leftAnkle`,
and `CharacterRig` says in its own comment that `leftFoot` (y = −6) is the character's *right* —
so `HumanoidBone.leftFoot` takes `shoe(rigLeft: false)`. **The side check catches this**: it now
covers the feet too, using `RigBindPose.leftLeg.tip` (the ankle) since there is no bind-pose bone
to look up for a shoe. Getting the sides backwards prints `MIRRORED` at load, which is how it was
checked.

## A foot needs a roll, and its landmark is easier than the thumb

Aim alone would leave a foot spinning about its own length with whatever the shin carried in —
an ankle that turns the sole outward through a stride. So a foot takes a roll, the second bone to
do so after the hand, and the landmark is far easier to find than a thumb:

- **On the rig**, it is +Z of the shoe frame, out of the top of the shoe.
- **On the model**, it is *up*, full stop. A humanoid is rigged standing on flat ground, so the top
  of its foot in the bind pose is engine +Z, and no bone hunting is needed at all.

Squaring that against the bone axis matters more here than it did for the thumb: most foot bones
run forward **and down**, so an unsquared "up" would re-aim the foot rather than roll it.

Toes stay undriven and ride the foot, which is what a toe does.

## What it looks like

Side-on through a sprint, the imported character's feet and the procedural character's shoes now
pitch together frame for frame — trailing foot toe-down through the drive, leading foot coming
through level. Front-on standing, both soles are flat and square, no roll.

**What it still does not do** is what part 2 warned about, and the warning was right: this is a
rigid ankle, so the foot stays square to the shin rather than flattening out to meet the ground.
It is level when the shin is vertical, which is most of a planted stance, and it does not know the
difference between a foot on the floor and a foot in the air. A real ankle needs the gait to say
when the foot is planted, and that is a `CharacterRig` job, not a retargeting one.

---

## What is left

- **The ankle does not flatten to the ground.** See just above — the foot is square to the shin,
  which is a rigid ankle and not a real one.
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

**`emote-tennis` is the take** for the hand, because it is the only one that puts anything in a
hand, and `threeQuarter` is the view — the hand is small in frame, so crop to it rather than
squinting. `stand` front-on is the other one, for the relaxed hand rather than the closed one.

**`run` side-on is the take for the feet**, and run it *both* ways — with `JW_CHARACTER_MODEL` and
without:

```bash
"$APP" -labtake run -labview side -labwidth 3 -labsize 900 900 \
  -labnogrid -labnoruler -labsheet /tmp/run.png -labframes 4
```

The imported character's feet and the procedural character's shoes should pitch **the same way in
the same frame**. They are driven by the same expression now, so if they disagree, one of the two
sides of that is wrong.

Both schemes build. This session's pictures: `emote-tennis` three-quarter before and after side by
side (open splayed palm against a closed fist round the handle), the same take front, back and
side, `stand` front-on with both hands hanging with a natural curl instead of flat, `run`
filmstrips side-on for both characters, the same frame of each cropped to the feet, and `stand`
front-on cropped to two flat, square soles.
