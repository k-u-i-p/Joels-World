# Handoff — the character lab

A standalone view for looking at a character properly: one pupil on a metre grid, every gait and
every emote as a named "take", a scrubbable clock, and a set of launch arguments that turn any of
it into a PNG or a table of numbers without a person at the keyboard.

It exists because **every character change so far has been checked by loading the whole game and
squinting at it.** The overworld camera is nearly overhead, the editor's is a map camera, and both
show a character 40 pixels tall next to a building. A knee, an elbow, a collar, the moment a foot
leaves the floor — none of those are visible from there, and none of them can be checked twice the
same way, because the game's clock is the wall clock and no two runs line up.

Zone note: this adds `Engine/World/Minigames/CharacterLab/**` (amber) and
`JoelsWorldAdmin/Lab/**`, and makes four small edits to red files — listed under "What it touched"
below. Ben asked for the tool directly. `server/**` and `JoelsWorld.xcodeproj/**` are untouched;
the project uses synchronised file groups, so the new files needed no `.pbxproj` edit.

---

## Using it

Build the Mac editor as usual, then:

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorldAdmin -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Map Editor.app/Contents/MacOS/Joels World Map Editor"
```

**Interactively** — a window with the scene on the left and controls on the right:

```bash
"$APP" -lab
```

space plays and pauses · ←→ step a frame, ⇧ ten · `[` `]` change take · 1–5 side/¾/front/back/top ·
0 back to the take's own · Q E swing the camera · R F tip it · − = zoom · G grid · H ruler.

"Copy command" in the sidebar puts the command line for exactly what is on screen on the
clipboard. That is the intended way to work: find the frame by hand, then ask for it again from a
script.

**Headless** — four things it will write and quit:

```bash
# One frame, side on, three seconds into the walk
"$APP" -lab -labtake walk -labtime 3 -labshot /tmp/walk.png

# Eight captioned frames spanning exactly one stride
"$APP" -lab -labtake run -labsheet /tmp/run.png -labframes 8

# One frame of all 31 takes, five pupils each — the whole character system at a glance
"$APP" -lab -labtake all -labcast school -labsheet /tmp/all.png -labsize 520 380

# The clothing atlas, with its three channels split out
"$APP" -lab -labatlas /tmp/atlas.png

# The numbers: foot contact, hip bounce, lean, travel, per take
"$APP" -lab -labreport /tmp/lab.json
```

Every flag is listed with its shape in
[CharacterLabArguments.swift](JoelsWorldAdmin/Lab/CharacterLabArguments.swift).
`-labquitafter <s>` runs the window for a while, prints what it ended up showing and quits, which
is how the interactive half gets smoke-tested from a script.

---

## The three ideas worth keeping

### 1. It draws through the real renderer

`CharacterLabScene` is a `WorldRenderedMinigame` — the same seam the 3D tennis court goes through.
It hands the renderer a cast, some ground and a camera, and gets the actual rigs, the actual
clothing atlas, the actual spotlight, shadow map and SSAO for free.

A separate viewer with its own shaders would have been easier to write and worthless within a
month: the first thing it would stop catching is a change to the renderer it was written to check.

`GameState.startToolScene` is how it gets on screen without a map — the normal route needs an
entry in `maps.json` and a minigame named by that map's `import`, and the lab is not a place in
the school.

### 2. It is deterministic, and that is the whole point

The simulation runs on a **fixed 1/120 s sub-step** off the lab's own clock, and `SceneClock` is
pinned to that clock while the lab is up — so the rig's idle breathing and every emote's age come
off the same timeline rather than off the wall clock. Seeking backwards rebuilds the cast and
replays from zero, which at a few thousand cheap steps is simpler than making every motor
reversible.

The consequence: **frame *n* of a take is the same picture every run**, whatever the frame rate.
A filmstrip taken today can be diffed against one taken before a change. Without that, a picture
of an animation is an anecdote.

### 3. A filmstrip spans one stride, not one take

Eight frames spread evenly over a six-second walk is eight pictures of nearly the same pose,
because the sampling interval and the cadence are unrelated numbers that happen to nearly agree.
`CharacterLabReport.strideWindow` runs the take, unwraps `Gait.phase` and returns the span of one
full 2π cycle; the filmstrip uses it for anything that walks, and the whole take for anything that
does not. That single change is the difference between a contact sheet and a walk cycle.

---

## What is in it

| File | What it is |
|---|---|
| `Engine/World/Minigames/CharacterLab/CharacterLabScene.swift` | The scene: cast, ground, grid, ruler, camera, clock |
| `…/CharacterLabTake.swift` | The catalogue — 11 movement takes and one per emote — and how each drives a motor |
| `…/CharacterLabCast.swift` | Who stands there: one pupil, five from Junior Campus, or five awkward colours and sizes |
| `…/CharacterLabReport.swift` | The measurements, and `strideWindow`. No Metal — it poses the rig itself |
| `JoelsWorldAdmin/Lab/CharacterLabViewController.swift` | The Metal surface, the readout, the keys, the capture runs |
| `…/CharacterLabControlsView.swift` | The sidebar |
| `…/CharacterLabCapture.swift` | Frames into a captioned sheet; the atlas into a channel-split PNG |
| `…/CharacterLabArguments.swift` | Every launch flag |
| `…/CharacterLabWindowController.swift` | The window, and the no-sidebar layout a capture uses |

### The takes

Eleven movement takes — standing, creeping, walking, sprinting, side-stepping, back-pedalling,
turning on the spot, running a circle, sprint-stop-sprint, cutting side to side, jumping — and one
per emote, its length taken from the emote's own duration. Each carries a **watch-for** line that
is printed under the filmstrip, so a picture arrives with its own caption.

Adding one is a `CharacterLabTake` in the array in `CharacterLabTake.swift`. Adding a new *kind* of
movement is a case in `CharacterLabMotion` and a branch in `drive`, which is a dozen lines.

### What the report measures

Per sample: position, height, facing, speed, the whole of `Gait`, both soles' height above the
floor, and hip, head and hand heights. Per take: the worst any foot floated, the deepest a sole
sank, how high the jump went, how far it travelled and the hip's range — the walk's bounce, as a
number.

A run of the whole catalogue takes about a fifth of a second and prints a digest:

```
walk             float -0.06  sink -0.65  height   0.0  hip range  0.8   21.4 m at    96 u/s
run              float  1.29  sink -2.68  height   0.0  hip range  4.6   47.2 m at   212 u/s
```

`float` is the contact promise from [HANDOFF-movement-and-rigs.md](HANDOFF-movement-and-rigs.md):
on a grounded gait it should stay near zero. A sprint's 1.29 is its flight phase, which is meant to
be there.

---

## Traps

1. **`SceneClock.pinned` is global while the lab is up.** It is `#if DEBUG`, and `stop()` clears
   it, but anything else drawing in the same process would see the lab's clock too.
2. **Composition is fought by the camera, not chosen.** `Camera.update` always aims at z = 0, and
   the eye is positioned relative to the focus — so moving the focus dollies as well as pans, by
   `sin(pitch)` against `cos(pitch)`. Near the horizontal the dolly swamps the pan and the shot
   cannot be brought down at all. That is why the view pitches are three-quarter angles rather than
   the ground-level ones a rig looks most dramatic at, and why the drop in `updateCamera` is scaled
   by `tan(pitch)`. Read the note there before changing a pitch.
3. **A slider written from the model can come back as a drag.** AppKit delivered the scrubber's
   action a runloop pass after `refresh()` set its value, which paused the lab a few seconds into
   every session. `pushedClock` in `CharacterLabControlsView` is the guard; `isSyncing` alone is
   not enough because it only covers the synchronous case.
4. **A capture needs its warm-up.** Heads and shoes are glTF read off disk on a background queue.
   `-labwarmup` defaults to 2.5 s; grabbing sooner photographs a headless character, which looks
   exactly like a bug in the rig.
5. **Lineups are laid out across the camera**, using the yaw at the moment the cast is built — so
   changing the view rebuilds them. A row laid along a fixed axis is five characters wide from one
   view and one character wide from the view at right angles to it.

---

## What it touched outside its own folders

Four small edits, all in service of the two rules above — draw through the real renderer, and be
deterministic:

- **`Engine/Core/SceneClock.swift`** (new) — the pinnable clock.
- **`Engine/Render/Renderer.swift`** — one line: `preparePoses` reads `SceneClock.now` instead of
  `Date()`.
- **`Engine/World/EventInterpreter.swift`** — one line: `nowMilliseconds` reads `SceneClock`.
- **`Engine/World/GameState.swift`** — `startToolScene(_:)`, `#if DEBUG`, about fifteen lines.
- **`JoelsWorldAdmin/App/AdminAppDelegate.swift`** — `-lab` opens the lab window instead of the
  editor, and the two GPU-free modes run and quit before any window exists.

Both builds are clean and both were run: the Mac editor still opens on its usual path, and the iOS
game builds.

---

## Worth doing next

1. **A diff mode.** Two runs of the same take, same frames, side by side with the changed pixels
   marked. Everything needed is already deterministic; it is an image comparison and a third panel.
2. **Wire it to `-selftest`.** `CharacterLabReport` produces exactly the numbers
   `LocomotionSelfTest` asserts on by hand. The contact promise could be a test over every take at
   every throttle rather than a number a person reads off a digest.
3. **A texture take.** The atlas is written as a flat sheet; what it does not show is which part of
   a *character* each mark lands on. A take that draws the UV regions onto the body in flat colour
   would close that loop.
4. **Props and holdables.** `holding` is only ever set by the tennis emote. A take per entry in
   `HOLDABLE_OBJECTS` would make the racket-in-the-hand transform checkable.
