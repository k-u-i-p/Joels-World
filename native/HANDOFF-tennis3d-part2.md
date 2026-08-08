# Work log — finishing the 3D tennis minigame

Continues [HANDOFF-tennis3d.md](HANDOFF-tennis3d.md), which is the architecture and the
original bug list. Read that first. This file is the running record of the follow-up session:
what has been done, what it changed, and what is left.

**Another agent is working on `Engine/Core/Locomotion.swift`, `Engine/Entity/CharacterRig.swift`
and the overworld movement at the same time.** Nothing in this session touches those files —
tennis only reads `Locomotion` through `step`/`commit`/`teleport` and `CharacterRig` through
`RigOverride`, all of which are stable API. If a merge conflict shows up there, it is theirs.

## Status

_(updated as work lands)_

| Original item | State |
|---|---|
| 1. Opponent too weak | not started |
| 2. Stray specks off the sideline | not started |
| 3. Match-over panel unseen | not started |
| 4. `resolveDeadBall` only in `.rally` | not started |
| 5. Banner fade frame-rate dependent | not started |
| 6. No trace logging | not started |
| 7. Hint fade frame-rate dependent | not started |
| 8. Wide-ball chases untested | not started |

## How to run it

```bash
cd native && xcodebuild -project JoelsWorld.xcodeproj -scheme JoelsWorld -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
xcrun simctl launch --console-pty <device-udid> com.allr.joelsworld -autojoin Joel -map 4
```

`simctl` cannot inject touches, so anything reachable only by tapping has to be driven from
`GameDebugHarness`. See the flags section below once it is written.
