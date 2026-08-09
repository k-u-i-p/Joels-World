# Handoff — bought characters, part 5: five of them, and a word in `npc.json` that picks one

**Session 9.** One job, the one [part 4](HANDOFF-imported-characters-part4.md) left at the top of
its list: *every pupil is the same boy*. There are five bought models now, all five load and draw
at the same time, and which one a character wears is a single string in `npc.json`.

Zone note: `Engine/Net/Protocol.swift`, `Engine/Entity/CharacterRig.swift`, the new
`Engine/Entity/CharacterModels.swift` and `Engine/Render/CharacterRenderer.swift` are red under
[AGENTS.md](../AGENTS.md). Ben asked for this work directly. `server/**` untouched,
`JoelsWorld.xcodeproj/**` untouched, nothing deleted.

---

## The five

Four of them arrived as one family set and share a build; the fifth is the original from part 1.

| Key | File | Triangles | Joints |
|---|---|---|---|
| `boy` | `models/characters/son.glb` | 49,260 | 65 |
| `girl` | `models/characters/daughter.glb` | 47,554 | 65 |
| `man` | `models/characters/father.glb` | 47,540 | 65 |
| `woman` | `models/characters/mother.glb` | 47,185 | 65 |
| `stylized_boy` | `models/characters/stylized_boy.glb` | 48,728 | 52 |

**All five matched 22/22 bones on the first run, with no profile written for any of them.** No
`.rig.json`, no bone overrides, no axis fiddling, nothing mirrored, and 30 finger joints curling on
both hands of all five. That is `HumanoidSkeleton` doing exactly what four sessions of work said it
would do, and it is worth saying plainly because it is the first time it has been tested against a
file it was not built against. The one measurable difference between the family set and the
original — 65 joints against 52 — cost nothing, because the retargeter reads the skeleton it is
given rather than a skeleton it remembers.

Keeping `stylized_boy` in the lineup is deliberate for that reason. Four models that came out of
the same exporter agreeing with each other proves less than a fifth one from somewhere else
agreeing with them.

## Where the model comes from

One field. `CharacterModels` is the table, `npc.json` names a key, and the pose carries the path:

```
npc.json "model": "man"
  → CharacterModels.path(for:)      "models/characters/father.glb"
  → RigPose.model                   (set in CharacterRig.pose, alongside colours)
  → CharacterRenderer.drawImportedBody
```

**It goes on the pose, and that is the whole design decision.** The pose is the only thing that
reaches the renderer per character; everything else about a draw is a global, and a global is
precisely what made every pupil the same boy. Once it rides the pose, `importedBodies`,
`retargeters` and the new `profiles` cache were already keyed by path from part 1 — the store
supported several models the whole time, and nothing ever asked it for a second one.

An unknown key logs and falls back to the default rather than drawing nothing. That matters more
than it used to: there is no procedural body behind an imported one any more, so "model not found"
is an invisible character, and a typo in a data file should not cost you a whole pupil.

A path with a `/` in it is taken as a path, so a model can be tried before it is in the table.
`JW_CHARACTER_MODEL` still works and now means "draw the **whole cast** with this one", which is
the useful shape for looking at a new file.

## Who wears what

39 of the 42 NPCs across the four maps got a model. Teachers and parents are `man`/`woman`;
pupils are `boy`, `girl` or `stylized_boy`, with the two boy models alternating so a corridor is
not a row of twins. The three that were left alone are **Dancing Toilet**, **Farting Snake** and
**Talking Poop** — a human body is the wrong answer for all three, and leaving the field off says
that better than picking one would.

**The default is `boy`**, so the player and anything the server invents are a pupil. That is a
change: it used to be `stylized_boy`, because that was the only model. One line in
`CharacterModels` if it should go back.

## Sizing is still `npc.json`'s job, and it has to be

Every model is scaled on load so its **hips** sit at the rig's hip height — that is what puts its
soles on the floor, and it is `HumanoidProfile.ScaleMode.hips`. The consequence is worth writing
down because it looks wrong until you see why:

```
              file height   scale    engine height at width/height 40
boy              4.894      ×15.89        77.8
girl             4.899      ×15.32        75.0
man              4.905      ×12.74        62.5
woman            4.902      ×11.82        57.9
stylized_boy     4.906      ×16.19        79.5
```

**The adults come out shorter than the children.** They are not smaller people — they are people
whose legs are a bigger fraction of them, so hanging them from the same hip height leaves less
above it. An adult looks like an adult because `npc.json` gives them a bigger `width`/`height`:
Mr Hardy's 52 × 58 is ×1.45, which puts him a head over a pupil.

Do not fix this by baking a height into a model. `width`/`height` scale the *whole* rig, pelvis
height included, so the soles still land; a model scaled past its hip match has legs longer than
the rig's hip height and stands shin-deep in the floor. `width`/`height` are used for nothing but
this scale — `halfWidth`/`halfHeight` on `GameCharacter` are read by nothing — so they are free to
tune purely by eye.

## What is new to look at things with

- **`-labcast models`** — one of every catalogue entry, all at the same size, nothing else
  different between them. Left to right in catalogue order: boy, girl, man, woman, stylized_boy.
  It is the shot that proves five load at once, and the one that shows what each model's own
  proportions do with a shared hip height.
- **Every capture now prints what was resident when the shutter went.** A model that had not
  landed yet is a shadow with nothing above it, which at a lineup's zoom reads as a gap in the row
  rather than as a failure. `-labwarmup 8` is enough for five; the default 2.5 is not.
- **The map editor has a Model row** in the NPC inspector, where the head picker used to be —
  which is what part 4's comment in that file said the replacement would be.

## It was checked in the game this time

Part 4 could not get past the lobby. This one did: `-autojoin Joel -at 1400 -160 -pitch 0.95`
drops the player among Tommy, Sarah, Billy, Emily and Mr Ferguson, and the frame has a girl, a
boy, a stylized boy and a man in it at once, with all five models reported loaded. The simulator
control panel is still down, so it was driven with `xcrun simctl` — install, launch, screenshot —
rather than through the panel.

The lab's floor numbers are unchanged from part 4: **every grounded take still reads
`float -0.40`**, which is `footSink` exactly. Five models did not move the feet.

All three schemes build: `CharacterLab`, `JoelsWorld` (iOS simulator) and `JoelsWorldAdmin`.

---

## What is left

- **48,000 triangles each, and now five of them resident.** Part 4 called decimation a
  nice-to-have that had become the thing deciding whether a classroom runs; five models is
  ~240,000 triangles of vertex buffers before a single character is drawn twice for its shadow.
  This is now the top item on this list.
- **Nothing pre-warms.** A model loads the first frame a character asks for it, and that character
  is a shadow blob until it lands. On a map where a `woman` walks into view for the first time
  that is a visible fade-up. A `prewarm` over the models a map's NPCs name would fix it.
- **The `head`, `hair_color`, `shirt_color` and the rest are still read by nothing.** Five models
  is variety by *model*, not by colour; a bought model's clothes are its texture. Either the
  fields go, or a model grows a way to be tinted.
- **The adults are short at scale 1.** See the sizing section — it is correct behaviour, but it
  means every teacher and parent in the game depends on someone having typed a good `height`. The
  ones in `data/` were sized for a boy model and have not been retuned.
- **Server-side NPCs have no model.** `server/**` still assigns `head` and knows nothing about
  `model`, so anything the server invents falls back to the default. Out of bounds here, and
  harmless.
- **The ankle does not roll through a stance**, fingers do not adduct, nothing curls a hand except
  holding something, and the model's limb lengths win over the rig's.
  All unchanged from parts 3 and 4.
  (*Normal maps were on this list too. Part 6 did them.*)

## Checking it

```bash
xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
"$APP" -labtake walk -labcast models -labview front -labwidth 9 -labsize 1400 700 \
  -labnogrid -labnoruler -labwarmup 8 -labshot /tmp/models.png
```

Five different characters, five phases of the stride. Read the "N model(s) resident" line the run
prints at the end before you read the picture — four in a row and a gap is a slow load, not a bug.
