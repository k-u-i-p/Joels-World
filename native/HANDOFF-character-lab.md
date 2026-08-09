# Handoff — the character lab

**Its own app.** A standalone Mac tool for looking at a character properly: one pupil on a metre
grid, every gait and every emote as a named "take", a scrubbable clock, and a set of launch
arguments that turn any of it into a PNG or a table of numbers without a person at the keyboard.

It exists because **every character change so far has been checked by loading the whole game and
squinting at it.** The overworld camera is nearly overhead, the editor's is a map camera, and both
show a character 40 pixels tall next to a building. A knee, an elbow, a collar, the moment a foot
leaves the floor — none of those are visible from there, and none of them can be checked twice the
same way, because the game's clock is the wall clock and no two runs line up.

Zone note: this adds `CharacterLab/**` and `MacShared/**`, makes small edits to a few red files,
and **adds a third target to `JoelsWorld.xcodeproj`** — the reddest thing in the tree. Ben asked
for both the tool and the target directly. `server/**` is untouched. What the `.pbxproj` gained is
written out under "The target" below, because the next person to touch it should be able to check
it rather than trust it.

---

## Using it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme CharacterLab -destination 'platform=macOS' build
```

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/JoelsWorld-*/Build/Products/Debug/Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
```

**Interactively** — a window with the scene on the left and controls on the right:

```bash
"$APP"
```

space plays and pauses · ←→ step a frame, ⇧ ten · `[` `]` change take · 1–5 side/¾/front/back/top ·
0 back to the take's own · Q E swing the camera · R F tip it · − = zoom · G grid · H ruler.

"Copy command" in the sidebar puts the command line for exactly what is on screen on the
clipboard. That is the intended way to work: find the frame by hand, then ask for it again from a
script.

**Headless** — three things it will write and quit:

```bash
# One frame, side on, three seconds into the walk
"$APP" -labtake walk -labtime 3 -labshot /tmp/walk.png

# Eight captioned frames spanning exactly one stride
"$APP" -labtake run -labsheet /tmp/run.png -labframes 8

# One frame of all 31 takes, five pupils each — the whole character system at a glance
"$APP" -labtake all -labcast school -labsheet /tmp/all.png -labsize 520 380

# The numbers: foot contact, hip bounce, lean, travel, per take
"$APP" -labreport /tmp/lab.json
```

Every flag is listed with its shape in
[CharacterLabArguments.swift](CharacterLab/UI/CharacterLabArguments.swift).
`-labreport` needs neither a window nor a GPU: `main.swift` runs it and exits before an app is
put on screen, which is why `-labreport` is a fifth-of-a-second command.
`-labquitafter <s>` runs the window for a while, prints what it ended up showing and quits, which
is how the interactive half gets smoke-tested from a script.

---

## The three ideas worth keeping

### 1. It draws through the real renderer

`CharacterLabScene` is a `WorldRenderedMinigame` — the same seam the 3D tennis court goes through.
It hands the renderer a cast, some ground and a camera, and gets the actual rigs, the actual
bought model, the actual spotlight, shadow map and SSAO for free.

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
| `CharacterLab/App/main.swift` | The launch path, and the two modes that never open a window |
| `CharacterLab/App/CharacterLabAppDelegate.swift` | Menu bar, window, and `CharacterLabHeadless` |
| `CharacterLab/Scene/CharacterLabScene.swift` | The scene: cast, ground, grid, ruler, camera, clock |
| `…/CharacterLabTake.swift` | The catalogue — 11 movement takes and one per emote — and how each drives a motor |
| `…/CharacterLabCast.swift` | Who stands there: one pupil, five from Junior Campus, or five awkward colours and sizes |
| `…/CharacterLabReport.swift` | The measurements, and `strideWindow`. No Metal — it poses the rig itself |
| `CharacterLab/UI/CharacterLabViewController.swift` | The Metal surface, the readout, the keys, the capture runs |
| `…/CharacterLabControlsView.swift` | The sidebar |
| `…/CharacterLabCapture.swift` | Frames into a captioned sheet |
| `…/CharacterLabArguments.swift` | Every launch flag |
| `…/CharacterLabWindowController.swift` | The window, and the no-sidebar layout a capture uses |
| `MacShared/MacControls.swift` | `AdminUI` and friends — the AppKit helpers both Mac apps use. Moved here from the editor rather than copied |
| `MacShared/MetalCapture.swift` | Reading a drawable back as a `CGImage`. Was the first half of `AdminScreenshot` |

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
5. **A window nobody fronted draws nothing.** `MTKView` runs off a display link and AppKit stops
   the display link when a window is fully occluded — and an app launched from a terminal is not
   always allowed to come to the front, so "occluded" can mean "from launch, forever". A capture
   therefore pauses the view and calls `draw()` off its own 30 Hz timer, and the interactive window
   falls back to the same hand-crank whenever it is hidden (`chooseFrameSource`). Without the
   first of those, every scripted `-labshot` on a busy desktop writes nothing at all.
6. **Lineups are laid out across the camera**, using the yaw at the moment the cast is built — so
   changing the view rebuilds them. A row laid along a fixed axis is five characters wide from one
   view and one character wide from the view at right angles to it.

---

## The target, and what it touched outside its own folders

The lab is the project's **third target**, `CharacterLab`, building
`Joels World Character Lab.app` from bundle id `com.allr.joelsworld.characterlab`. It was added by
hand to `project.pbxproj`, following the ids and the shape the two existing targets already use —
if you need to check it rather than trust it, that is:

- a `PBXFileReference` for the product, and an entry in the Products group;
- two `PBXFileSystemSynchronizedRootGroup`s, `CharacterLab` and `MacShared`. The synchronised
  groups are why no file added under either needs a project edit ever again;
- a `PBXNativeTarget` whose groups are `Engine`, `CharacterLab` and `MacShared`, with the usual
  four phases — Sources, Frameworks, Resources, and the same **Stage assets** script the other two
  run, because the heads and shoes come out of `GameAssets`;
- Debug and Release configurations copied from the editor's, minus the app-icon setting (the lab
  has no asset catalogue) and minus the checkout-path stamping (it reads no `data/`);
- a shared scheme, `xcshareddata/xcschemes/CharacterLab.xcscheme`.

**The editor's target gained `MacShared` too**, and lost two files to it: the AppKit control
helpers and the frame-capture code, which both apps need and neither should own twice.

Four small edits to shared code, all in service of the two rules above — draw through the real
renderer, and be deterministic:

- **`Engine/Core/SceneClock.swift`** (new) — the pinnable clock.
- **`Engine/Render/Renderer.swift`** — one line: `preparePoses` reads `SceneClock.now` instead of
  `Date()`.
- **`Engine/World/EventInterpreter.swift`** — one line: `nowMilliseconds` reads `SceneClock`.
- **`Engine/World/GameState.swift`** — `startToolScene(_:)`, about fifteen lines.

Neither of the last two is `#if DEBUG`. They were, while the lab was a mode of the editor and
therefore always built in Debug; a target of its own can be built in Release, and a gated hook
would leave it unbuildable there.

All three targets build, Debug and Release, and all three were run: the lab interactively and in
every headless mode, the editor on its usual path, the game on the iOS simulator.

**Not caused by this work, but you will meet it:** the map editor crashes a few seconds after
launch with an AVFAudio `player did not see an IO cycle` exception when the map's background music
starts. A clean build of `3227ecb`, before any of the lab work, does the same. It is in
`SoundManager`, not here.

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
