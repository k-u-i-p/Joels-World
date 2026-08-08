# Handoff — the standing pose, and what a character does while nothing is happening

**A thread of its own**, running alongside the skinned-character handoffs rather than after them.
[Part 1](HANDOFF-skinned-characters.md) built the body as one skinned mesh, [part 2](HANDOFF-skinned-characters-part2.md)
dressed it and [part 3](HANDOFF-skinned-characters-part3.md) lit it — all three are about **what a
character is made of**. This one is about **how it stands**: the resting pose, the idle behaviour,
and the proportions of the limbs, the shoes and the body. Read part 1 first for the mesh; nothing
here changes it.

Zone note: `Engine/Entity` and `Engine/World/Minigames/Tennis3D` — red and amber under
[AGENTS.md](../AGENTS.md). Ben asked for this directly ("work on the standing pose… natural
resting hand positions and movements with some randomisation… proportions of limbs, shoes and
body"). `server/**` and `JoelsWorld.xcodeproj/**` untouched. A second agent was working on
textures and lighting in the same tree throughout (that is part 3); nothing here touches
`SkinnedBody`, `ClothingAtlas` or `Shaders.metal`.

---

## What changed, in the order you would notice it

1. **The shoes were three sizes too big.** The slip-on GLB drawn at 0.65 is **18.3 units** from
   heel to toe on a character 66 units tall — 28% of its own height in foot, against about 15% for
   a real one. `shoeScale` is 0.50.
2. **The legs were a toddler's.** The hip joint sat at **38.6%** of total height; a ten-year-old's
   is near 48%. The bones are 20% longer (`thighBone` 12 → 14.4, `shinBone` 9.7 → 11.6) and the hip
   is now at 41.7%.
3. **The arms were held out in front.** `neutralArmSwing` was 0.405 rad and `neutralArmSideways`
   0.375 — **23° of shoulder flexion and 21° of abduction, permanently.** From the side it read as
   sleepwalking. They are 0.13 and 0.17 now, and the hands hang by the hips.
4. **The palms faced backwards.** `Hand.restRoll` turns the hand a quarter turn about the forearm,
   so the thumb points forward and the palm lies against the thigh.
5. **Nothing stood still interestingly.** `IdleBehaviour` — the new file, and the bulk of the
   session.

The head is **not** part of any of this. It is an authored GLB scaled to match the web version and
it is 31% of the character's height on its own, which is most of why the proportions read young.
Everything above works around it.

---

## `IdleBehaviour` — the idea

A standing character used to do two things: breathe, and sway its arms by 0.025 rad. Both are
periodic, both are tiny, and **both run identically on every character in the scene**, so a
playground full of pupils read as a shelf of ornaments.

What gives a standing person away as alive is not smoothness, it is **irregularity**. So this is a
scheduler rather than an animation:

- Time is cut into **beats** of 3.6 s. Each beat either gets a gesture or does not (42%).
- Underneath, a **weight shift** wanders from one leg to the other on its own 7–13 s period.
- Six gestures: `lookAround`, `adjustFoot`, `rockOnFeet`, `stretchNeck`, `wipeNose`, `scratchHead`.

Everything is drawn from `DeterministicRandom` seeded off the character id, which buys three things
at once:

- **different per character** — two pupils standing together are not in unison;
- **no state between frames** — the whole thing is a pure function of (seed, time), so nothing
  jitters when a frame is dropped and there is nothing to keep or tear down;
- **the same on every client** — `pose` is handed `Date().timeIntervalSince1970` and the seed is
  the character id, so two players watching the same NPC see it wipe its nose at the same moment.

### The one rule it follows

**It never writes a limb target.** Everything is a joint angle, or a body-pivot offset. A gesture
that pushed a hand through space would be silently clamped by the IK, which is the trap that has
cost this rig two sessions (trap 2 in [HANDOFF-movement-and-rigs.md](HANDOFF-movement-and-rigs.md)).

Gestures that reach for the face are the exception worth understanding. They are written as an
**absolute** arm pose with a crossfade weight, not as an offset, because reaching for your own nose
is not "the hanging arm, plus a bit" — it is somewhere else entirely. `Offsets.rightArm` /
`.leftArm` carry those; everything else adds.

### The weight shift is the valuable half

A gesture is on screen for under two seconds every eight or so. The weight shift is on *all the
time*, and a person standing with their weight evenly on both feet is a person standing to
attention.

The hips translate towards the loaded foot **and both legs are given the counter-angle that keeps
their feet where they were**. Without that second half the feet slide along with the hips and it
reads as the character being dragged sideways. The loaded knee straightens, the free one softens,
and `groundContactSink` then lifts the body by however far the straightening leg pushes it — on its
own, because that is what a straightening leg does.

---

## Everything now derives from something

The session's other theme, and the one that caused the only real bug in it.

- **`bodyPivotHeight` is derived**, not chosen: it is whatever puts the sole of the shoe `footSink`
  under the floor with the legs at rest. Change a bone length or a shoe scale and the character
  still stands on the ground.
- **`neutralLeftHand` / `neutralRightHand` / `neutralLeftFoot` / `neutralRightFoot` are derived**
  from the neutral angles through `armTarget` / `legTarget`. They used to be four hand-typed
  vectors that had to agree with the angles to within 0.01, with a self-test assertion standing
  over them to check that two constants still matched.
- **`neutralLegSpan`** is the hip-to-ankle distance at rest, for anything that wants to move a hip
  sideways by a distance and needs an angle.
- **`Emotes.groundedFoot`** replaced **twelve** literal `-13`s in the emote table, which was the
  old neutral foot height. Nine emotes would otherwise have stood an inch above the floor.
- **`RigRuntime`'s two literal `15.5`s** became `CharacterRig.bodyPivotHeight`, or every emoting
  character would have sunk into the ground.

### The one that got away, and what it cost

`Tennis3DGame+Players.headHeight` computed the height of the strings as
`contactHeadLocal(lift:).z + 15.5` — a literal — while `worldPoint` went through `CharacterMotor`,
which reads `CharacterRig.bodyPivotHeight`. **The moment that stopped being 15.5 the two disagreed
by 3.4 units, which is 0.13 m.**

Measured, not guessed:

| Build | STRIKE | MISS |
|---|---|---|
| `HEAD`, old rig | 32 | 1 |
| new rig, `headHeight` still a literal | 59 | **13** |
| new rig, `headHeight` reading the constant | 34 | 1 |

The fingerprint in the log is worth memorising, because **this is the fourth handoff in a row to be
written about two pieces of code disagreeing about where the strings are**: a run of misses whose
`closest the strings got` clusters just past the sweet spot — 0.46 to 0.60 m against 0.45 — on balls
between 0.3 and 0.6 m off the court. Systematic size, one kind of ball. That is never bad luck.

The comment above `headHeight` had *already* been written about the previous instance of the same
bug. A comment saying "these must agree" is not a mechanism.

---

## Testing it

`-selftest` is **129 assertions, all passing** (118 before this session). Eleven are new, and they
are the ones worth knowing about, because `IdleBehaviour` is the one thing in the rig that is
*supposed* to be irregular — which makes it the one thing a screenshot cannot check.

```bash
xcrun simctl launch booted com.allr.joelsworld -selftest
```

- **determinism** — same character, same second, same pose; and different between characters.
- **no jumps** — a 60 Hz sweep over four minutes of a character's life, crossing every seam in the
  scheduler. Each quantity gets its own ceiling in its own units; the first draft used one scaled
  number and could not tell a hand reaching for a face in half a second from one teleporting there.
- **one foot stays planted** however the weight moves. Deliberately *one* and not both, because
  `adjustFoot` picks one up on purpose — the first draft asserted both and failed on working code.
- **no gesture reaches somewhere a hand cannot go** — absolute poses are the only thing here not
  bounded by construction.
- **the character fidgets, and not constantly** — a weighting table with a typo in it fails
  silently, and the character simply never scratches its head again.
- **proportions**, as ranges: hip at 39–46% of height, foot under a quarter of it, the sole under
  the floor rather than in it, the resting arm hanging, and the hand clearing the hips.

### Looking at it

The Mac editor, as sessions 1 and 2. One thing changed: **`-campitch` / `-camyaw` / `-camzoom` are
now reasserted every frame in `-shot` mode.** They were applied once at launch, and loading a map
applies that map's own zoom — so a reconnect, which happens on its own if a second editor is open,
quietly put the camera back overhead somewhere in the delay before the grab. Every headless shot
came out top-down, which looks exactly like the flags being ignored.

Two traps that cost time and are not written down anywhere else:

- **`script -q` does not work here.** The handoff-2 recipe (`script -q /dev/null <app>`) fails with
  `tcgetattr/ioctl: Operation not supported on socket` when there is no tty. Run the binary
  directly — the PNG is written regardless of whether stdout is buffered.
- **The editor's player faces whatever the server last remembered**, not the camera. Two runs an
  hour apart at the same `-camyaw` gave a front view and a profile. Vary `-camyaw` to find the
  angle; do not assume it is stable between runs.

For tennis, `HANDOFF-tennis3d-part6.md`'s warning is real and load-bearing: with no display client
the simulator throttles to about a twelfth of real time, and a screenshot loop is what keeps it
honest. `scratchpad/tennisrun.sh` in this session's notes is that loop plus the install-verify from
trap 1.

---

## Traps

Sessions 1 and 2's traps all still apply. These are new.

1. **`bindPose()` and `pose()` must still agree** — session 1's trap 1, and this session moved a
   lot of what they agree *about*. Both now read the derived neutrals, so the usual way of breaking
   it is closed. `Hand.restRoll` is the deliberate exception: it is applied in `pose` and **not** in
   `bindPose`, so the hand is built unrolled and turned at draw time. That is the correct side to
   put it on — bake it into both and the two cancel and nothing rotates.

2. **The hand roll is on the hand mesh, not on the hand anchor.** The racket and every emote prop
   ride on `rightHandAnchor`, and their placement was tuned against the unrolled frame. Rolling the
   anchor would turn the tennis racket a quarter turn edge-on.

3. **`restRoll` applies in every pose, not just at rest.** It is right for standing and walking,
   which is nearly all of the time. The emotes have not been checked against it — see open item 2.

4. **A gesture must fit inside its beat.** `applyGesture` starts one no later than
   `beatLength − duration` so it finishes before the next beat's draw. Lengthen a gesture past 3.6 s
   without lengthening `beatLength` and it will be cut off mid-reach, which is a hand snapping back
   from a face.

5. **`bodyPivotRotation.x` is assigned, not accumulated**, in the lean block. The idle behaviour's
   roll is applied *after* it for that reason. Anything written earlier is thrown away silently.

6. **The idle runs off the wall clock**, around 1.75e9 seconds. That is fine in `Double` and it is
   what makes the behaviour agree between clients, but do not pass it through a `Float`.

7. **`groundContactSink` reads the lower foot**, which is what makes `adjustFoot` safe: lifting one
   foot leaves the body where it is. A gesture that lifted *both* would drop the character.

---

## What is left

1. **The hands are still four merged ellipsoids.** They were the top item in session 1 and in
   session 2, and they still are. The roll makes them sit correctly; it does not make them a hand.
   Sweeping them the way the limbs are swept is the same trick again.
2. **The emotes have not been watched since any of this.** They were already open item 5 of the
   movement handoff; this session added three reasons to look — `restRoll` turns the hand in every
   emote pose, the legs are longer, and `groundedFoot` moved twelve foot targets. All three are
   *more* correct than what was there, and none has been seen on screen. `-emotedemo -map 0`.
3. **The head is the proportion problem now.** At 31% of the character's height, no amount of leg
   fixes the silhouette. It is an authored GLB matched to the web version, so shrinking it is Ben's
   call and a wider change than it looks — `HeadTables` scales are copied verbatim from
   `characters.js`.
4. **A teacher stands like a pupil.** `IdleBehaviour` is seeded per character but its *table* is one
   table. A second weighting per role — adults fold their arms and shift less — is a
   `gestureWeights` -sized change.
5. **Nobody has seen two characters interact while idling.** They look at nothing in particular;
   `lookAround` picks a side, not a target. Looking at whoever is nearest, or at the player, would
   be a large gain for a small change, and it is the first thing a ten-year-old will notice is
   missing.
6. **The waist seam** — part 2's open item 3 — is unchanged and still an accident.

---

## Where the numbers live

- **How often anybody does anything** — `IdleBehaviour.beatLength`, `gestureChance`,
  `gestureWeights`. Turn `gestureChance` down for a calmer playground; there is no other pacing
  number.
- **How far the weight shifts** — `IdleBehaviour.weightShiftAngle`, as an angle at the hip so it
  survives a change of leg length.
- **What each gesture does** — the one `switch` in `applyGesture`, one case each.
- **The resting pose** — `CharacterRig.neutralArmSwing` / `neutralArmSideways` / `neutralArmFlex`,
  and `Hand.restRoll`.
- **Proportions** — `thighBone`, `shinBone`, `shoeScale`, `footSink`. `bodyPivotHeight` follows
  from them and should not be set by hand again.
