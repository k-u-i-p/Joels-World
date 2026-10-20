# Destroy the World

Joel's idea, built on the `sandbox/destroy-the-world` branch because it's a side quest, not part
of *minigames → badges → graduate*:

> *"you are on a moving train shooting with a flamethrower add fires tree falling animation and
> if you shoot fire it turns into ice and you can melt the ice make it 3d out the eyes with a
> lowpoly style make it say ultimate combo and stuff"*

You stand on the roof of a train rolling through low-poly countryside, looking out of your own
eyes, holding a flamethrower. **Hold FIRE** to shoot; **drag** anywhere (or drag the FIRE button
while holding it) to look round and aim up and down.

Everything goes **fire → ice → melt**:

1. Flame something and it **catches fire**. Leave it and it burns down: a tree **falls over**
   (TIMBER!), a cottage **falls in** (KABOOM!), a haystack goes POOF.
2. Flame something that's **already burning** and the fire **turns to ice** — Joel's rule.
   Campfires are already burning, so they go straight to ice.
3. Flame the ice and it **melts** into a puddle, and whatever was inside falls down.

Doing things quickly one after another is a **combo**: COMBO (3), SUPER COMBO (5), MEGA COMBO (8),
**ULTIMATE COMBO** (12), HYPER ULTIMATE COMBO (16), WORLD DESTROYER (20), and ULTIMATE COMBO xN
every five after that. Points multiply with the combo, up to x10. Destroy 100 things and
**YOU DESTROYED THE WORLD**.

## Where everything is

| What | Where |
|---|---|
| The rules: train, flames, fire/ice/melt, falling trees, combos, camera | [DestroyWorldGame.swift](Engine/World/Minigames/DestroyWorld/DestroyWorldGame.swift) |
| The shapes: trees, cottages, haystacks, campfires, train, flamethrower, fields, mountains | [DestroyWorldKit.swift](Engine/World/Minigames/DestroyWorld/DestroyWorldKit.swift) |
| Score, combo box, banners, pop-ups, crosshair, FIRE button | [DestroyWorldView.swift](JoelsWorld/UI/Minigames/DestroyWorldView.swift) |

The numbers Joel is most likely to want to change are all in `DestroyWorldGame.Tuning`: how fast
the train goes, how long it takes to light / freeze / melt something, the points, how long a combo
lasts, and how big the world is.

## How to play it

There is **no door into it from the school yet**. A door needs a map in `data/maps.json` *and* a
new line in `GameState.swift`, which is engine (red zone — Ben's call). Until then:

- In Xcode: **Product → Scheme → Edit Scheme… → Run → Arguments**, add `-destroyworld`, then Run.
- Or from the terminal, after a build: `xcrun simctl launch <device> com.allr.joelsworld -destroyworld`

Debug switches (debug builds only):

- `-destroyworlddemo` — a bot holds the trigger and aims at the nearest thing, sticking with it
  through fire → ice → melt. It calls the same `aim` and `setFiring` a thumb does.
- `-destroyworldtrace` — one log line a second: distance, score, combo, how many things are
  burning / frozen, particle count.
- `-destroyworldice` — puts a frozen pine, oak, cottage and campfire beside the line at the start,
  so the ice can be looked at without catching it.

## How it's built (for whoever changes it next)

- **Same shape as School Rush.** A `WorldRenderedMinigame` that hands the renderer a list of
  boxes every frame. The train really moves (towards +Y), the countryside is generated from where
  it is, and things behind are thrown away.
- **First person is School Escape's trick.** The camera can only orbit a point on the ground, so
  that point is put exactly one orbit-distance in front of you and the pitch is solved so the
  camera's height is your eye height. See `updateCamera`.
- **The flames are the hit test.** Every flame particle that touches something heats it up, so
  what you see burning is exactly what's burning. Flames that hit ice fizzle into steam instead of
  passing through, which is what keeps the ice visible while you melt it.
- **Low-poly is just boxes.** A pine is four stacked cubes twisted 45°; a mountain, a far-off
  treetop and an oak's canopy are cubes stood on a corner (`DestroyWorldKit.onCorner`); every
  flame and puff of smoke is a tumbling cube.
- **Mind the mesh cache.** The renderer keeps one mesh per distinct size and stops at 256. Every
  size that changes over time (flames, ice melting, puddles) moves in whole steps.
- **The ice is unlit.** Lit by the warm sun, pale blue came out cream.

## Not done / not checked

- **No door from the school** (above).
- **No badge.** The badge list is fixed in `MenuDialogs.swift` and this isn't one of the ten.
- **Sounds are borrowed.** There's no fire, ice or train sound in `assets/media/`, so it uses the
  tennis-ball hits pitched up and down, `splash.mp3` for melting and `chase_music.mp3` as music.
  A real whoosh for the flamethrower would help most.
- **Only checked on an iPhone 17 simulator in portrait.** Landscape should give a wider view but
  hasn't been looked at, and it hasn't been on a real phone.
