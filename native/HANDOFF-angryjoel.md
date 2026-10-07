# Angry Joel

Joel's game: Angry Birds, with Joel in the slingshot. *"we are going to make a game called angry
joel its basically angry birds."* Every bird and every pig wears a photo of a real face, which is
why it lives on its own branch, **`sandbox/angry-joel`**, until Ben has looked at it.

Pull a bird back, let go, and knock every pig off its buildings. Four birds a level, twelve
levels, and the twelfth is the Pig King's palace.

## The birds

Four a level, in this order. Each one is three times as strong against one kind of block —
that rule is Joel's.

| Bird | Ring | Tap while flying | Strong against |
|---|---|---|---|
| **Joel** | red, drawn-on angry eyebrows | nothing — he just hits hard | — |
| **Chuck** | yellow | zooms off twice as fast | wood |
| **The Blues** | blue, small | splits into three | ice |
| **Bomb** | black, with a fizzing fuse | explodes (or does by himself just after he hits something) | stone |

Blocks come in **wood** (brown), **stone** (grey, tough) and **ice** (see-through blue, weak).

## Where everything is

| What | Where |
|---|---|
| The whole game: birds, pigs, blocks, levels, camera, slingshot | [AngryJoelView.swift](JoelsWorld/UI/Minigames/AngryJoelView.swift) |
| The faces | `assets/avatars/angry_joel.png`, `_chuck`, `_blues`, `_bomb`, `_pig` |
| The door on the Junior Campus playground | `data/junior_school/objects.json`, "Angry Joel" |
| What the door opens | `GameViewController.showAngryJoel` — map id 9 is intercepted, never sent to the server |
| The map record (so the door has a number to ask for) | `data/maps.json`, id 9 |

**Everything Joel is likely to want to change is a number in `AngryJoelScene.Tuning`**, or a line
in `AngryJoelScene.levels`: how big things are (`bigness`, `buildingSize`), how hard the slingshot
flings (`power`), how tough pigs are (`pigHealth`), how much crashes hurt (`hitDamage`), which
birds you get (`birds`), and how strong each bird is against its block (`strongHit`). How zoomed
out the camera is lives just below, in `viewSize` (sideways) and `uprightViewWidth` (upright).

A level is a list of pieces. `hut(x)` is the building block: two posts, a roof and a pig inside,
so `hut(0) + hut(100) + hut(200)` is three huts in a row. `hut(x, material: .stone)` makes it out
of stone.

## The three things worth knowing before changing it

**1. It is not one of the engine's minigames.** It is a SpriteKit scene, laid over the top of the
school, because SpriteKit already has the one thing this game is made of: blocks that fall over.
It never changes map, so **it works without a deploy** — say yes at the playground door and it
opens; **Exit** puts you back on the playground. The one thing it does send the server is the
**Angry Joel badge** 🐦, claimed when level 12 is beaten: the scene calls `onBadge`, and the
playground door hands that to `gameStateAwardBadge`. The server stores any badge id it is sent,
so the badge is just `"angry joel"` in the list in `MenuDialogs.swift`.

**2. Damage is measured from the speed *before* the crash.** SpriteKit tells you about a contact
after it has already bounced things apart, so their speed at that moment is no use — the first
version had pigs that would not die. `didSimulatePhysics` keeps every body's velocity from the
frame before, and a hit takes `speed × hitDamage` off the thing's health. Faster birds hit harder,
so whenever `power` goes up, `hitDamage` has to come down or everything turns to matchwood.

**3. A pulled-back bird must stay above the grass.** Zoomed right out, the slingshot stretches
further on screen (`pullScale`) so it is still a thumb-sized pull. That let the bird be dragged
under the ground; it started its flight there, fell out of the bottom of the world and was removed
— *"birds are disappearing"*. `keptAboveGround` stops it.

## Playing it without a thumb

```bash
xcrun simctl launch --console-pty <device> com.allr.joelsworld -angryjoel -angryjoeldemo
```

- `-angryjoel` opens the game straight away, with no server and no school.
- `-angryjoeldemo` is a robot that fires the shots and uses every bird's trick, logging each pig
  popped and why each shot ended.
- `-angryjoellevel 9` starts on level 9.
- `-angryjoelfullpower` makes the robot pull as far as it can, which is how the vanishing-bird bug
  was caught.
- `-angryjoelwin` pops every pig after two seconds — `-angryjoellevel 12 -angryjoelwin` logs
  `badge earned`. (With `-angryjoel` there's no school, so nothing is actually sent.)

**A simulator that is not showing in the panel does not draw**, and SpriteKit pauses with it — the
robot sits there doing nothing. Attach the panel to the one you are testing on.

Measured on the robot at the end: levels 1–3 cleared, level 11 got 5 of 6 pigs with all four birds,
and level 12 is the hard one it does not always finish.

## Not done yet

- **It's on a branch.** Real children's faces, so Ben looks before it goes anywhere near `main`.
- **The badge has not been claimed against the live server yet** — only checked as far as the
  game deciding it was earned. Beating level 12 through the real playground door is the test.
- **No sounds of its own.** It borrows `jump.mp3` and a pitched tennis-ball hit.
- **Rolling Blues.** The little ones can roll along the grass for a long time after landing, so
  the next bird waits up to eight seconds.
