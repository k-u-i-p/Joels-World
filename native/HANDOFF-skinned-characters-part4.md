# Handoff — hands, and the black crescent

**Session 4.** Continues [HANDOFF-skinned-characters-part3.md](HANDOFF-skinned-characters-part3.md).
Sessions 1–3 built the skinned body, painted a uniform onto it, and lit the folds. Every one of
them ended with the same line at the top of "what is left": **the hands.** This session does them,
and takes off the black gash across the waist that turned out to have been drawn there on purpose.

Zone note: `Engine/Render`, `Engine/Entity`, red under [AGENTS.md](../AGENTS.md). Same standing
instruction as sessions 1–3 — Ben asked for character-fidelity work directly, again this session.
`server/**` and `JoelsWorld.xcodeproj/**` untouched. This is the first character session with the
**character lab** to work in, and it changed how the work went: every claim below was checked
against a deterministic render before it was believed, and two of them were wrong first time.

---

## What changed

| File | What |
|---|---|
| `Engine/Render/MeshFactory.swift` | `loft(rings:capStart:capEnd:)` — new |
| `Engine/Render/CharacterRenderer.swift` | `buildHand`, rewritten |
| `Engine/Entity/CharacterRig.swift` | `Hand` rewritten; `pelvisProfile` top pulled in |
| `Engine/Render/SkinnedBody.swift` | hand and neck regions; `keepsMeshUV`; the arm's `tipInset` |
| `Engine/Render/ClothingAtlas.swift` | `hand` and `neck` rows; the shorts' hem marks and every `v` on them |
| `CharacterLab/Scene/CharacterLabScene.swift` | the drop is taken along the camera's axis |

Two commits: `cd30b96` the hands, `f392db8` the waist.

---

## 1. The hands

**It was three ellipsoids and a capsule merged**, and it read as a bunch of bananas from every
angle. Three closed surfaces pushed into each other crease everywhere they cross and share no
normals across it, so what a camera found was a stack of separate blobs.

It is now a **lofted palm**, **four tapered fingers rooted inside it**, and a thumb. 7136 triangles
for the whole body, up from about 6100; still one draw.

The interesting part is the attempt in between, because the next person will think of it too.
**One loft for the whole hand, with the fingers pressed into it as grooves, does not work.** The
grooves come out fine. The shape is still a **flipper**: a ring that tapers to nothing at the far
end is a paddle, and no depth of groove changes what the silhouette does. Four rounded tips at four
different heights is what a hand's outline *is*, and that needs four solids. The intersections are
not the problem they were in the ellipsoid version — a finger really does emerge from a palm and
really does crease where it does, and every root here is buried a unit and a half inside, so no
crease lands anywhere but at a knuckle.

The fingers **overlap on purpose**: centres 1.10 apart, radii adding to 1.40, so each pair fuses
and what shows between them is a groove rather than daylight. Four rods with air between them is a
skeleton hand.

### The wrist, which was a separate bug

The forearm is built `domeEnd: false` so it does not wear the hand like a bracelet — but `tipInset`
was `radii.tip * 0.9`, which is **2.1 units of tapering cone standing outside the wrist joint**,
more than the palm is wide. The palm could not cover it, and it cut out through the back of the
hand as a dark lens. It is `* 0.30` now: the arm ends bluntly 0.7 short of the joint, well inside
the hand, and the two cross in one clean ring.

`CharacterRig.Hand.palmProfile`'s bottom three rings exist only to manage that crossing, and the
comment there says so. Move one and check the wrist.

### A quarter-turn that was not wrong

`Hand.restRoll` was suspected — with real fingers the front view looked like the palms faced
forward. It was tried at +π/2 and −π/2 and **1.25 was right all along**: from the front the hand is
edge-on with the thumb towards the camera, which is a hand hanging with its palm against the thigh.
The 71° reading was a misread of a 40-pixel hand. Do not change it without a crop.

### The atlas rows

`ClothingRegion` gained `hand` and `neck`. They were `blank` for three sessions on the argument
that skin has no garment on it — true, and beside the point: the red channel has been standing in
for absent light since session 3, and a knuckle and the underside of a very large head are exactly
that. The neck row is one mark and it is the one that stops a head floating.

**`keepsMeshUV`** is new on `SkinnedBody.append`, with one caller. The hand's `u` folds about the
back of the hand — a ring angle — and a ring angle is knowable where the ring is made and nowhere
afterwards; recovering it from a position means inverting the curl. Every finger folds about its
own centre line, so the underside of each is the shaded side. Mirroring in X carries the UVs with
the vertices, so the left hand's palm is still its palm; nothing extra is needed.

---

## 2. The black crescent

**A hard black gash across every character's waist, from any camera at or below the hem.** It is in
every render in every earlier handoff. Nobody wrote it down, which is worth a moment: it was so
consistently there that it had stopped being visible.

Two causes on top of each other.

1. **The shorts were pushing through the shirt.** The torso closes from 7.2 to nothing over four
   tenths of a unit, so its underside is very nearly a flat disc; the pelvis ran up under that disc
   and crossed it at a glancing angle, in a wide band rather than at a line.
2. **The atlas then multiplied that band by 0.14** — `-0.30` and `-0.13`, chosen in session 3 for a
   surface assumed to be inside the shirt where nothing could see it. Something could.

The fix is the pelvis diving away from that disc instead of grazing it (`0.0` at y 4.0 now, not
5.0), the two marks at `0.18` and `0.05`, and — the odd one — the pocket under the hem being
**lit**. There is no bounce light in this scene at all, so a gap the spotlight cannot reach falls to
flat ambient and reads as a hole; `+0.09` in that band is the missing bounce, put back by hand.

What is left is a small dark arrowhead at the navel where the two lathes are closest. It reads as a
crease. Getting rid of it entirely means the shorts closing below the shirt's floor, which puts the
shirt's own unlit underside on show instead — a worse trade, and one that was rendered.

⚠️ **Pulling the pelvis in shortened its profile from 11.2 units to 10.2, and every `v` mark on the
shorts is in that span.** All of them were multiplied by 11.2/10.2. If you move that profile's floor
or ceiling again, they all move again, and `shirtHem` is derived from where the two *surfaces cross*
— not where either of them ends. The derivation is written out at the constant.

### Also tried, and rejected, and rendered

Taking the top of the pelvis **up** to meet the shirt and fill the gap. It fills it, and the two
surfaces then interpenetrate in a jagged band that would flicker as the waist twists. There is a
comment at `pelvisProfile` saying so, because it is the obvious idea.

---

## 3. The lab could not compose a shot

`CharacterLabScene.updateCamera` took its drop along world −Y whatever the camera's yaw. That is
"down the screen" only at yaw 0. At the front view's π/2 it is **sideways**, and every view but
`side` and `top` framed the character a fifth of the way in from the left edge with their head cut
off. It is taken along the camera's own axis now.

This was the first thing done and everything else depended on it. A tool for looking at characters
that cannot put one in the middle of the frame does not get used.

---

## Looking at it

The framing that produced every crop in this session:

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
"$APP" -labtake stand -labtime 2 -labview front -labwidth 2.6 -labnogrid -labnoruler -labsize 620 800 -labshot /tmp/front.png
```

`-labwidth 2.6` with a 620×800 frame puts a whole pupil in shot with a little air. Then **crop** —
a hand is 60 pixels of that and no amount of squinting substitutes:

```python
from PIL import Image
im = Image.open("/tmp/front.png"); W, H = im.size
box = (int(0.14*W), int(0.30*H), int(0.50*W), int(0.52*H))       # the character's right hand
im.crop(box).resize(((box[2]-box[0])*2, (box[3]-box[1])*2), Image.LANCZOS).save("/tmp/hand.png")
```

`-labtake all -labsheet /tmp/all.png -labsize 420 320` is the whole catalogue in one image and is
the check that a mesh change has not broken a pose. `-labreport` still prints the same numbers
part 3 quotes — walk float −0.06, sink −0.65, hip range 0.76, 21.4 m at 96 u/s; run float 1.29,
sink −2.68, hip 4.58, 47.2 m at 212 — none of this touched the motors.

All three targets build: `JoelsWorld` on the iOS simulator, `JoelsWorldAdmin` and `CharacterLab`
on the Mac.

---

## What is left

1. **The sock top is a blurred gradient, not a cuff.** Measured off a front render: the yellow of
   the shin fades into the white of the sock over about **4.8 units of leg**, where `legwear` asks
   for `rise(v, at: sockTop, over: 0.015)` — 0.63 units, and about one texel row. Something is
   smearing an authored one-row step across roughly seven. It is not mipmaps (there are none) and
   one row of bilinear does not do this. **This is now the loudest wrong thing on the character**
   and the next thing to chase. Start by writing the atlas out (`-labatlas`) and reading the leg
   row: if the step is crisp in the texture the fault is in sampling or in the leg's `v`, and if it
   is soft in the texture the fault is in `legwear`.
2. **The shorts' hem has the same shape of problem as the sock's**, one region up, and will
   probably fall out of the same answer.
3. **A hard line down the middle of a sleeve** on some frames, running along the arm rather than
   across it. Session 3's item 4, unchanged, still unexplained, still best-guessed as the shadow
   map. The lab can hold a frame still now, which is what chasing it was missing.
4. **Nothing distinguishes a teacher from a pupil.** Session 2's item 3, and the only one on this
   list that adds something to the game rather than fixing something in it: a second row set — long
   sleeves, long trousers, a tie — is a `ColorSlot`-sized change plus a `v` offset.
5. **`JW_RIGID_RIG` and the rigid part meshes.** Fourth session on the list. `CharacterRenderer`
   still builds `leftHandMesh`/`rightHandMesh` from `buildHand` for a path nothing renders, and the
   gap between the two paths is wider than ever now.
6. **A diff mode for the lab** (its own handoff's item 1) would have paid for itself twice this
   session. Every rejected attempt above was judged by holding two PNGs side by side by hand.

## Where the numbers live

- **The hand's shape** — `CharacterRig.Hand`: `palmProfile`, `fingers`, `fingerCurl`,
  `fingerSpread`, and the five `thumb*`.
- **Where the hand meets the arm** — `palmProfile`'s bottom three rings *and* `tipInset` in
  `SkinnedBody.appendArms`. They are one decision in two files.
- **What is painted on a hand or a neck** — `ClothingAtlas.skinOfHand` / `skinOfNeck`.
- **The waist** — `CharacterRig.pelvisProfile`'s top, `ClothingAtlas.shirtHem`, and the three marks
  at the top of `shorts`.
- **Everything about the rest of the body's shape** — still `CharacterRig`. See session 1.
