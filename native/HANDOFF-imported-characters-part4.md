# Handoff — bought characters, part 4: the floor stops the foot, and the old character goes

**Session 8.** Two things, and the second one was Ben's, mid-session:

1. The ankle, which was the top item of [part 3](HANDOFF-imported-characters-part3.md)'s "What is
   left" — and which turned out to be hiding a bug part 3 introduced.
2. **The procedural character is gone.** Everything that generated a body in Swift, and everything
   that dressed one, has been removed. A character is one bought, rigged model and nothing else.

Zone note: `Engine/Entity/CharacterRig.swift`, `Engine/Render/CharacterRenderer.swift`,
`Engine/Render/Shaders.metal`, nine lines of `Engine/Render/Renderer.swift`, and the deletion of
`Engine/Render/SkinnedBody.swift` and `Engine/Render/ClothingAtlas.swift` — all red under
[AGENTS.md](../AGENTS.md). Ben asked for the removal directly and confirmed its scope. `server/**`
untouched, `JoelsWorld.xcodeproj/**` untouched, and **no asset file was deleted** — see "What was
*not* removed" at the end.

---

# The ankle

## Part 3 broke the standing foot, and no picture could have caught it

Part 3 gave the shoe frame the shin's own pitch, which was right, and checked it with the shot it
had: `stand`, front-on, "both soles flat and square, no roll". That shot cannot show a pitch. A
foot rotating about the axis that runs across the character is pointing straight at the camera.

The arithmetic says what the picture could not. The neutral leg swings 0.096 rad forward of the
hip on a 0.583 rad knee, which leaves the shin leaning **0.222 rad back** — a standing shin is not
vertical, and a rigid ankle square to it is 12.7° toe-down. With the ankle 4.10 above the floor
and the toe 10.8 in front of it, that put the toe of every standing shoe **2.66 units under the
ground** and lifted the heel 0.44 clear of it. Every character in the game had been standing on
its toes since part 3 landed.

## The lab could not see it either, and that was worth fixing first

`-labreport` prints a "float" and a "sink" per take, and both were computed as *the height of the
shoe's origin, minus how far the sole hangs below the origin*. That is the sole's height for a
**level** foot and for no other. The whole point of the previous session was to stop the foot
being level, so the one measurement that should have caught the regression had been made blind by
the same change that caused it.

It measures the **lowest corner of the shoe** now — `CharacterRig.soleClearance`, which is four
corners through the frame, because the body pivot banks as well as pitches. That needed two
numbers nothing had ever written down, so they are measured off `slip_on_shoes.glb` the way
`shoeSoleBelowAnkle` was: the mesh spans −0.083…0.269 on its own +Z under a node scaled 80, so the
shoe runs from **6.62 behind the ankle to 21.54 in front of it**. Scaled, that is a foot 14.1 long
with the ankle 23% of the way back from the toe, which is where a real ankle sits — a quiet piece
of evidence that `shoeScale` is right.

The number moved the moment it could see:

```
                     before          after the fix
stand      float -2.35  sink -3.97   float -0.40  sink -0.77
walk       float -2.22  sink -4.44   float -0.40  sink -0.65
run        float  0.44  sink -6.72   float  0.44  sink -2.68
```

**Every grounded take now reads −0.40**, which is `footSink` exactly — the deliberate sink that
hides the seam where a sole meets the floor. Not near it, not within a unit of it: it.

## The rule has no tuned number in it

Part 3 signed off with "a real ankle needs the gait to say when the foot is planted, and that is a
`CharacterRig` job". It does not, and the reason is worth keeping:

> Take the shin's pitch. If it buries a corner of the sole, wind it back — by the least that lifts
> that corner onto the floor, and never past level.

**The floor already knows which feet are planted.** A foot whose shin lean would drive its toe
through the ground *is* a foot on the ground; one with clearance under it is in the air. No plant
signal, no blend weight, no threshold to tune.

Everything a real ankle does falls out of it:

- **A planted foot is flat**, because level is where the floor stops it.
- **A foot in the air keeps the whole of its shin pitch**, because nothing is in its way. Heel
  strike stays toe-up and push-off stays toe-down — those are swing-phase poses and the sprint
  filmstrip still has both.
- **The release is smooth.** A 0.45 rad toe-down foot is level at the floor, 0.19 four units up,
  and its own pitch again by nine. Continuous, so nothing pops.
- **The heel lets go before the toe**, because it is 3.3 from the ankle against the toe's 10.8 and
  a short lever leaves the floor first. That is the real asymmetry, for free.

"Never past level" is what makes it safe when the floor cannot be satisfied at all — an ankle
dropped below its resting height by the pelvis sink has no pitch that lifts the sole clear, and
level is the best of a bad set. That is not a fudge: level is where the toe and the heel are at
the *same* height, which makes it where the **lower** of them is highest, and the same fact is
what makes "the least that lifts it" a single well-defined answer rather than a search.

The arithmetic runs on the columns of the composed frame rather than on rig-local numbers, so the
character's scale, the pelvis sink, the acceleration lean and the bank in a hard turn are all
already in it. Each corner's height is one sinusoid in the pitch and the floor is a line across
it, so the wind-back is an `acos`, not an iteration.

## What it still does not do

The foot is rigid **fore and aft only when it is free**, and level when it is down. It does not
roll through a stance the way a real foot does — heel, ball, toe — and it does not know about a
slope, because nothing in the engine says the ground is anything but z = 0. Both of those need
the gait to say more than it does. This one did not.

---

# The old character

Ben, mid-session: *"Don't work on the old model. Remove the old model."* Scope confirmed as all of
it, on the basis that the bought character is in good enough shape to stand alone.

## What went

| Gone | What it was |
|---|---|
| `Engine/Render/SkinnedBody.swift` | 691 lines that **generated a body**: one continuous tube per limb, swept from the rig's own joints and bone thicknesses, weighted so an elbow creased instead of seaming |
| `Engine/Render/ClothingAtlas.swift` | 634 lines that **painted the uniform** — collars, cuffs, sock rolls — as three channels of instructions rather than as colours |
| `CharacterRenderer.buildMeshes`, `buildHand` | The torso silhouette, a tapered capsule per limb segment, a sphere in every joint, and a lofted hand with a thumb |
| `drawSkinnedBody`, the twenty-part fallback loop | Two of the three rungs of the draw ladder |
| `drawHead` + `HeadTables` + `headEntry` | Fourteen head GLBs and the deterministic per-id pick between them |
| `drawShoes` + the box stand-in | The shoe GLB draw. **The shoe *frame* stays** — it drives the imported feet |
| The clothing branch of `characterFragment` | Texture 0 could be the atlas rather than an albedo; it cannot now |
| `-labatlas`, `CharacterLabCapture.writeAtlas` | The lab mode that painted the atlas out with its channels split |
| The editor's Head row | It picked from a table that no longer exists |

`CharacterRig` lost every number that existed only to be *generated from*: `torsoProfile`,
`pelvisProfile`, `pelvisSquash`, both neck radii, the six limb end-scales, the four limb radii,
the deltoid, the elbow and knee radii, and the whole of `Hand` except `restRoll`. What survived is
the skeleton — bone lengths, joint anchors, the three body placements, the shoe measurements —
because those are what the IK solves and what `HumanoidRig` aims a bought skeleton at.

**`RigPart` is unchanged and deliberately so.** They were body parts; they are aiming points now.
`.leftElbow` is still exactly where the elbow is, and a retargeter that is told that does not have
to work it out.

## Removing the fallback exposed a bug it had been hiding

The first render of the whole school cast came back as **one pupil and four spare shadows**.

Every character's joint matrices were written into one shared `MTLBuffer`. `setVertexBytes`
copies at encode time; a buffer does not — the GPU reads it when the draw actually runs, which is
after the entire frame has been encoded. So every character in a crowd drew with the *last*
character's matrices, and those matrices carry position, so a class of thirty drew thirty times in
one place.

It had been latent since the model was first imported in part 1, and invisible for the same reason
the ankle bug was: the procedural body was still the default, and it passed its bones the copying
way. **The lab's solo takes are the only shots any of these four sessions took**, and one
character is exactly the case this bug does not break.

Each character takes its own 256-byte-aligned slice of a ring now. The ring holds three frames'
worth of the busiest frame yet seen, and the cursor runs on across frames rather than resetting,
so by the time it comes back round to a slice the frame that wrote it is long retired.
`Renderer.draw` calls `characters.beginFrame()` once a frame, and that is the whole of the change
outside `CharacterRenderer`.

**If you take a picture of a crowd, take it of a crowd.** Five pupils walking is now a shot worth
keeping in the rotation.

## Every pupil is the same boy

This is the visible cost and it is not a bug. The fourteen head GLBs were what made a corridor of
NPCs look like different children; there is one bought model, so there is one child. Hair colour,
shirt colour, skin colour and the rest are still on every NPC in `npc.json`, still editable, and
now read by nothing.

That is the shape of the next job: a **model per character** rather than a head per character.
`CharacterRenderer.importedModelPath` is already a `var` with a store keyed by path and one
retargeter per model, so the machinery for several models at once is there — what is missing is
the field on `GameCharacter` that chooses, and more than one model to choose from.

## What was *not* removed

**No asset file was deleted.** `assets/models/heads/*.glb` and `assets/models/slip_on_shoes.glb`
are still in the tree, still in git, and now referenced by nothing.
[AGENTS.md](../AGENTS.md) singles out deleting art as the one red thing that cannot be undone, and
"nothing loads them" is a much easier state to reverse than "they are gone". Bin them in one
command when a second character model has landed and the decision is settled.

The server still assigns a `head` field to every NPC it generates
(`server/managers/MapManager.js:189`) and `GameCharacter.head` still parses. Nothing reads either.
That is a `server/**` change, which is out of bounds here, and it is harmless — an ignored string.

---

## What is left

- **A model per character.** The one above. It is the largest thing on this list and the only one
  a player would notice.
- **The ankle does not roll through a stance**, and knows nothing about a slope. See the end of
  the ankle section.
- **Fingers do not adduct.** Unchanged from part 3 — they close but stay fanned.
- **Nothing curls a hand except holding something.** Unchanged from part 3.
- **Normal maps.** The file ships one and it is ignored; the fragment shader still has no tangent
  frame. Now that the base colour map is the *only* thing dressing a character, this is worth more
  than it was when it was one of two paths.
- **48,728 triangles**, against the 7,344 the procedural body used to be. There is no longer a
  cheap body to fall back on for a crowd, so decimating in Blender has gone from a nice-to-have to
  the thing that decides whether a full classroom runs.
- **Limb reach.** Unchanged from part 1: the model's limb lengths win over the rig's, so a hand
  asked to reach the edge of the rig's own reach stops short. Tennis is where it shows.

## Checking it

The lab, from `native/` — and **no `JW_CHARACTER_MODEL` any more**, because there is only one
character. The variable still overrides the path if a second model needs a look.

```bash
xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
"$APP" -labreport /tmp/lab.json
```

**Read the `float` column first.** Every grounded take should say `-0.40`. It is the lowest corner
of a real shoe now, so anything else means a foot is off the floor or through it, and the number
is the one thing in this project that would have caught either of this session's two bugs on its
own.

For the ankle, `walk` side-on cropped to the feet:

```bash
"$APP" -labtake walk -labview side -labwidth 1.2 -labsize 900 500 \
  -labnogrid -labnoruler -labsheet /tmp/feet.png -labframes 6
```

**`-labwidth 1.2` is the whole trick** — the character is 40 pixels of shoe in a normal frame and
a foot's pitch is invisible at that size, which is how it went wrong twice. `run` at `-labwidth
1.6` is the one that shows a foot keeping its pitch in the air.

And for the crowd, which is new and which nobody had rendered before this session:

```bash
"$APP" -labtake walk -labcast school -labview front -labwidth 9 -labsize 1100 620 -labnogrid -labnoruler -labshot /tmp/school.png
```

Five pupils, five positions, five phases of the stride. One pupil and four shadows means the joint
ring has regressed.

All three schemes build — `CharacterLab`, `JoelsWorld` (iOS simulator) and `JoelsWorldAdmin`.
This session's pictures: `walk` cropped to the feet before and after (a toe in the floor against a
flat sole), `stand` side-on flat, `run` side-on with the airborne foot still toe-down, the school
cast broken and then fixed, `emote-tennis` with the racket in a closed fist and both feet flat,
and the 31-take contact sheet.

**Not checked in the game itself.** The iOS simulator control panel was down this session, so the
game was built and launched as far as its lobby and no further; every picture above is the
character lab, which draws through the real renderer — the actual rig, spotlight, shadow map and
SSAO — but is not the school.
