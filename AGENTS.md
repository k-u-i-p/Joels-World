# Working on Joel's World

**Read this before touching anything.**

Joel (10) is the developer now. He understands Scratch — sequences, events, variables,
"when this happens, do that" — but he has not written Swift or JavaScript. Ben owns the
engine and is the person to ask when something here says "ask Ben".

## How to work with Joel

- Explain in Scratch terms where you can. `on_enter` is "when the player touches me".
  An event tree is a stack of blocks. A JSON file is a list of settings.
- Do the thing he asked for. Don't lecture, don't pad the answer, don't refuse a fun idea —
  see "Silly ideas" below for where the fun ones go.
- Show him the file you changed and what line, so he starts to recognise the shape of it.
- If he asks for something that would take a rewrite of the engine, say so plainly and offer
  the closest thing that's a data change instead.
- **Never** say a change works until you've actually built or run it. If you can't check,
  say "I haven't tested this."

## What the game is

A top-down multiplayer school. You play a pupil at St Peters. The loop:

**Play minigames → win badges → graduate (or escape) from school.**

The badges are fixed in code today —
[MenuDialogs.swift:63](native/JoelsWorld/UI/MenuDialogs.swift:63): rugby, tennis, swimming,
tig, good friend, tower defence, detention, school rush, football, five nights. **Four of the ten
are actually winnable**: tennis
([Tennis3DGame+Rules.swift:215](native/Engine/World/Minigames/Tennis3D/Tennis3DGame+Rules.swift:215)),
School Rush at 400 m, football by winning a match 3–x, and Five Nights by surviving all five.

Tennis is the 3D rebuild now; the old 2D one is still in the tree behind `-tennis2d`. Seven handoff
notes explain how it works, starting at
[HANDOFF-tennis3d.md](native/HANDOFF-tennis3d.md) — read them before changing it.
[Part 7](native/HANDOFF-tennis3d-part7.md) is the most recent — the court stands in a stadium now —
and [part 6](native/HANDOFF-tennis3d-part6.md)'s "Read this before you start a measured run"
section will save you an afternoon.

**Five Nights at St Peters** is the newest — Joel's own idea. You are the night guard, the
children are trying to escape, and there is **one door** out — on CAM 7, with seven seconds to
shut it once somebody reaches it. One handoff,
[HANDOFF-fivenights.md](native/HANDOFF-fivenights.md), and read the last section of it first:
**the map is in the app but not on the server yet**, so the security office door in the main
building needs a deploy before anyone but a developer can get in. Until then it is `-fivenights` on the simulator.

**Football** is the shortest read: one handoff,
[HANDOFF-football.md](native/HANDOFF-football.md). Five a side, first to three, and — unlike the
others — a whole team of AI on your side as well as against you.

The rest of the storyline is **not written yet**. Graduation and escape are the goal, but how
you get there is open. If Joel invents story, that's the point — it's his game. Write it down
in this file's "Story so far" section as it firms up, so it isn't lost.

Anything that doesn't serve *minigames → badges → graduate/escape* is a side quest. Build it,
but build it on a branch (below).

---

## The three zones

### 🟢 Green — Joel can change these freely, no permission needed

This is where nearly all game design lives. Breaking something here is cheap and reversible.

| What | Where |
|---|---|
| What NPCs say, their names, hair, clothes, where they stand and walk | `data/*/npc.json` |
| Trigger zones, doors, walls, spawn points | `data/*/objects.json` |
| Map names, camera angle and zoom, spawn area, entry music | `data/maps.json` |
| What the AI teachers know and how they behave | `data/*/agent_*.md` |
| New sounds and images, once they're the right size | `assets/` |
| Notes and docs | `README.md`, `native/PROGRESS.md`, this file |

**After editing any JSON, always check it's still valid:**

```bash
for f in data/maps.json data/*/*.json; do python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$f" || echo "BROKEN: $f"; done
```

One missing comma stops the whole game loading. Run it every time, before committing.

The Mac map editor is the friendlier way to move things around — it writes those same JSON
files. Build and run instructions are in the README.

**How the camera stands over each map** — how far it is tipped over, and how close in it is —
is set in the editor's sidebar: the **Camera angle** and **Zoom** sliders under MAP, then
**Save view**. That writes `camera_angle` (degrees off straight down; 0 is the old top-down
look, 52 is the default) and `default_zoom` onto that map's record in `data/maps.json`, and it
is what the game opens the map at. R/F tip the camera and the scroll wheel zooms; the sliders
follow both, so a view found by hand can be saved without touching them. **The game only picks
a saved view up on the next build**, because `maps.json` ships inside the app.

### 🟡 Amber — explain it to Joel first, then go ahead

Real code, but the kind you can read and undo. Before editing, tell him in one or two
sentences what the file does and what your change will do. Build afterwards.

- `native/JoelsWorld/UI/**` — dialogs, HUD, buttons, the badge list
- `native/JoelsWorld/UI/Minigames/**` and `native/Engine/World/Minigames/**` — tennis, and
  any new minigame
- `native/JoelsWorld/Audio/**`
- `tools/assets/**` — the slicing and minimap scripts

**To see a character close up**, build and run the **character lab** — the third app in the
project, `-scheme CharacterLab`. It is one pupil on a metre grid with every walk, run, jump and
emote as a take you can scrub through.
It is the right place to check anything about how a character looks or moves, and it can write a
strip of pictures out on its own: see
[HANDOFF-character-lab.md](native/HANDOFF-character-lab.md).

**How the characters themselves work** — a **bought, rigged model**, driven by our own walk cycle,
IK and emotes — is seven handoffs starting at
[HANDOFF-imported-characters.md](native/HANDOFF-imported-characters.md).
[Part 7](native/HANDOFF-imported-characters-part7.md) is the most recent — every character stands
on its **own** legs now, rather than on the abstract ones the rig poses — and
[part 5](native/HANDOFF-imported-characters-part5.md)'s "What is left" is still the list to pick
the next job off.

**If a character looks like it is floating or sunk, read part 7 first.** The rig and the model have
different leg bones, and everything that decides where the floor is goes through `WornLeg`.

**There are five characters now** — `boy`, `girl`, `man`, `woman` and `stylized_boy`. Which one an
NPC wears is one word in `npc.json`, which makes it a green-zone change:

```json
{ "name": "Mr Hardy", "model": "man" }
```

The list lives in [CharacterModels.swift](native/Engine/Entity/CharacterModels.swift), and the map
editor has a **Model** row in the NPC inspector that writes the same field.

Four earlier handoffs starting at
[HANDOFF-skinned-characters.md](native/HANDOFF-skinned-characters.md) describe the character we
used to *generate* in Swift — the skinned body, the uniform painted onto it, the hands. **That
character was removed** in part 4 above. Read them for the reasoning, not for the code; the code
is only in `git log` now.

**A new minigame is the single best thing to build here**, because it feeds the badge loop
directly. Copy how tennis works: a map in `data/maps.json` marked as a minigame, a
`Minigame` class in `native/Engine/World/Minigames/`, and a call to
`host.minigameAwardBadge("...")` when you win. The badge id has to match one in the list in
`MenuDialogs.swift` or the badge screen won't tick it off.

### 🔴 Red — do not change these unless Ben has said yes in this conversation

Not because they're secret — because a mistake here breaks the whole game, costs money, or
loses work, and Joel can't yet tell a good change from a bad one.

| What | Why |
|---|---|
| `native/Engine/Core`, `Net`, `Render`, `Entity`, `World` (except `Minigames/`) | The engine. Metal renderer, physics, networking. A bad edit here means a black screen or a game nobody can join. |
| `native/JoelsWorld.xcodeproj/**` | Break this and Xcode won't open the project at all. |
| `server/**` | Every player shares one server. A crash here kicks everyone off. |
| `server/deploy.sh`, `server/stream_logs.sh` | Deploys to Google Cloud Run. **Costs real money.** Never run these. |
| `server/claude-key.txt`, `server/gemini_key` | API keys. Never open, never print, never commit. They're gitignored — keep it that way. |
| `.gitignore`, `Dockerfile`, `.dockerignore` | Quiet breakage: secrets leaking, or 155 MB of art committed by accident. |
| Deleting anything in `assets/`, `original_images/` or `data/` | Art that isn't in git can't come back. Move it, don't delete it. |

If Joel asks for something red, don't just say no. Say what it would break, and offer the
green or amber version of the same idea. Most "I want the game to do X" wishes turn out to be
a `data/` change.

---

## Silly ideas → their own branch

Joel is 10 and will have brilliant, ridiculous ideas. **Build them — but not on `main`.**

Put it on a branch if it is:

- Not part of *minigames → badges → graduate/escape* (flying cars, jetpacks, a pet dragon)
- Toilet or fart humour, or anything he'd giggle at showing a teacher
- A big experiment that might not work out
- Rude or unkind about a real person — a real teacher's name on an unflattering NPC goes on a
  branch every time, and mention to him that Ben should see it first

How:

```bash
git checkout -b sandbox/flying-cars && git push -u origin sandbox/flying-cars
```

Name it `sandbox/<the-idea>`. Commit and push it like anything else, so Ben can look at it
and it can't get lost. Then `git checkout main` before doing anything else.

Say it positively — *"That's a great one. Let's build it on its own branch so we can go wild
without breaking the main game, and your dad can take a look."* Never make him feel told off
for the idea. One fart joke in the game is funny; the branch is where the other twenty live.

---

## Git

Work on `main`. No branch needed for ordinary work — only for the sandbox ideas above.

**Commit often.** After each thing that works, not at the end of the day:

```bash
git add -A && git commit -m "Make Mr Hardy say something new" && git pull --rebase && git push
```

- Pull before you start and before you push. Two people work on this repo.
- Push to `origin` (Ben's repo). The `fork` remote is Joel's own copy — leave it alone unless
  he asks.
- **Never** run `git push --force`, `git reset --hard`, `git rebase -i`, or `git clean -fd`.
  Those throw away work permanently. If the repo gets into a mess, stop and ask Ben.
- If a commit would include a key, a `.txt` log, or hundreds of megabytes of images, stop and
  check what's staged.

## Before you commit code

Green-zone JSON edits: run the JSON check above.

Amber-zone Swift edits: build it.

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

If it doesn't build, fix it or revert it — don't commit a broken build and don't say it's
done. Running it in the simulator to actually see the change is better still.

## Story so far

*Fill this in as Joel decides things. Right now: the badges exist, tennis is winnable, and
graduation is undesigned.*
