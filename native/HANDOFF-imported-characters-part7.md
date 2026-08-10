# Imported characters, part 7 — the leg the character is actually wearing

Part 6 gave characters and props their normal maps. This one is about their feet, and it starts
from a complaint that turned out to be exactly right: **the shoes on the imported models aren't
correct.**

They weren't. Every bought character in the game was standing about a unit and a quarter off the
floor, and the machinery that was supposed to notice had been measuring a shoe nobody has worn
since part 4.

## What was wrong

`CharacterRig` poses an **abstract** leg. `thighBone` is 14.4, `shinBone` is 11.6, and every
number that decides where the floor is was derived from those two plus the old `slip_on_shoes.glb`:

- `bodyPivotHeight` — how high the body pivot rides.
- `groundContactSink` — how far the pelvis drops so the lower foot reaches the ground.
- the ankle handed to `shoeFrame` — which pitch keeps the sole out of the floor.

**Nothing draws that leg.** `HumanoidRetargeter` throws the lengths away and keeps the
*directions*: it takes the direction the rig's thigh points and steps the **model's own** thigh
length along it, then the same for the shin. So the ankle you can see is at
`hip + modelThigh·d₁ + modelShin·d₂`, and the rig was computing the floor for
`hip + 14.4·d₁ + 11.6·d₂`.

On this cast those are between 0.9 and 3.8 units apart. 3.8 units is most of a shoe.

| | thigh | shin | sole below ankle | drawn ankle | sole ended up at |
|---|---|---|---|---|---|
| the rig's own | 14.40 | 11.60 | 4.50 | 4.10 | −0.40 ✔ |
| son | 11.37 | 10.55 | 7.04 | 7.93 | **+0.89** |
| daughter | 10.98 | 11.09 | 6.94 | 7.78 | **+0.84** |
| father | 13.18 | 11.85 | 3.92 | 4.97 | **+1.05** |
| mother | 12.89 | 13.14 | 2.90 | 3.98 | **+1.08** |

`footSink` is 0.4 by design, so the error is the 1.24–1.48 between the two right-hand columns:
every character floating, with `shoeFrame` pitching a shoe against an ankle height that was up to
3.8 units out.

### Why the models come out short

Not the models' fault, and not the artist's. `HumanoidProfile.ScaleMode.hips` sizes a model so its
**straight** hip-to-sole matches `engineHipHeight` — and `engineHipHeight` is the rig's hip height
with its knee **bent** at rest. Two different poses, one number. The models come out about 5% short
in the leg, and a chunky child with a deep shoe (the son's sole is 7.0 below his ankle against the
slip-on's 4.5) loses more of his leg to the shoe than the rig ever did.

## The fix: `WornLeg`

A new type in [HumanoidRig.swift](Engine/Entity/HumanoidRig.swift) — two bone lengths and the shoe
on the end of them, measured off the mesh at load, in the same normalised engine units the
retargeter steps along. It carries two derived numbers, computed once:

- `restAnkleZ` — where the **drawn** ankle sits with the legs at rest.
- `rideHeight` — what the body pivot has to be for *this* leg to stand *its own* sole `footSink`
  under the floor.

`FootShapes` became `WornLegs`, the same registry keyed by model path, and everywhere the rig used
to reason about the floor in `thighBone` / `shinBone` / `slipOn` it now reasons in these:

- `CharacterRig.pose` rides at `worn.rideHeight`, not `bodyPivotHeight`.
- `groundContactSink` measures the foot that is drawn, via the new `CharacterRig.wornAnkle`.
- `shoeFrame` is given the worn ankle, so the pitch that keeps a sole off the floor is computed
  where the foot really is.

**The fallback is the whole safety net.** `WornLeg.rig` is the old constants, so a character whose
`.glb` has not landed yet — or a rig with no measurable leg — poses exactly as it always did, and
every correction above is arithmetically a no-op. `CharacterRig.bodyPivotHeight` still exists and
is still 18.90; it is just no longer the height a bought character stands at.

## Two things this dragged out of the undergrowth

**The report could not see the models at all.** `-labreport` poses without drawing, on purpose —
no window, no GPU. But `WornLegs` was filled in by `ImportedCharacterStore` as it uploaded a model,
so a report loaded nothing, measured every character as the slip-on, and returned *the same numbers
to the centimetre for all five*. Nothing said so; the digest just looked stable. `warmUp` now does
the half of the load a number actually needs — `GLTFLoader.load` and `HumanoidSkeleton.init` are
both plain CPU.

**`JW_CHARACTER_MODEL` was a draw-time swap.** It lived in `CharacterRenderer` and changed the body
on screen while leaving `RigPose.model` saying something else — and the pose is what `WornLegs` is
keyed by. So every lab picture ever taken of a model other than the default was of a character
posed as a different one: the woman drawn standing in the boy's ride height, sink and shoe pitch.
It is `CharacterModels.override` now, resolved in the one function both sides call.

**And the report could not tell a flat sole from a tilted one.** A character up on its heels scores
exactly as well as one standing properly, because both have a lowest corner at −0.4. There is a
`tilt` column now (`CharacterRig.soleTilt`), toe height minus heel height, counted only while the
foot is actually down.

## Tennis

`CharacterMotor.localToWorld` folded in `CharacterRig.bodyPivotHeight`, and tennis's `headHeight`
read the same constant — so the two agreed with each other and would now both have been 1.3 units
above where the racket is drawn. That is 0.05 m against a 0.45 m sweet spot, and it is the same
fingerprint the last four handoffs each opened with.

So the motor carries a `model` and a `rideHeight`, `localToWorld` uses it, and `headHeight` asks
the motor rather than reading a constant that used to be right. `headHeight`, `lift(forBallHeight:)`
and `contactHeadHeight` all take a `Side` now; every call site already had one.

## What this did **not** change

The gait cycle. It was the first suspect and it is not guilty: `strideLegs` is written in angles,
the knee-straightening term that fixes the compass problem is sound, and the stride measures the
same before and after. What was wrong was every conversion from those angles to a height. The angles
stayed; the conversions moved onto the worn leg.

## Checking it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
for m in son daughter father mother stylized_boy; do
  JW_CHARACTER_MODEL=models/characters/$m.glb "$APP" -labreport /tmp/$m.json | grep -E '^(stand|walk)'
done
```

`stand` and `walk` should read `float -0.40` on all five — the sole planted at exactly `footSink`
— with `tilt` near zero and **different numbers in the other columns per model**, which is the
thing that was impossible before `warmUp`.

Then look at one:

```bash
JW_CHARACTER_MODEL=models/characters/son.glb "$APP" -labtake stand -labtime 1 -labview side \
  -labshot /tmp/side.png -labsize 1400 900 -labwidth 2.2
```

The sole should sit on the grid line with the shadow under it, not a shoe's depth above it.

The 129 checks in `LocomotionSelfTest` still pass — they assert against the rig's own geometry,
which is unchanged, so they say nothing about a worn model. That is what the report is for.

## Still not done

- **`RigRuntime.bodyPivotPosition` starts at `CharacterRig.bodyPivotHeight`.** The first walking or
  standing frame replaces it with the worn ride height, but a character that spawns *mid-emote*
  keeps the rig's value until the emote ends, because an emote deliberately leaves the pivot where
  it found it. A 1.3-unit settle, on a case nothing currently produces.
- **Emote foot targets are absolute rig-space positions** (`SIMD3(-4, -6, -20)` and friends in
  `EmoteTable`). A worn leg shorter than the rig's cannot reach them, so an emote's feet land
  wherever the model's bones end up. Unchanged by this session, and the reason `sit` and `dead`
  still report the sole a long way from the floor.
- **The one-frame tilt spike in `stand`.** `-2.66` at t=1.15 on a planted foot, during the idle
  weight-shift; flat before and after. Small, and probably a foot rolling rather than a bug, but
  it is the only number in a grounded take that is not near zero.
- **`ScaleMode.hips` still measures a straight leg against a bent-knee hip height.** The ride
  height now absorbs that, which is the right place to absorb it — but it is worth knowing that the
  models are ~5% shorter in the leg than the rig, and that is why.
