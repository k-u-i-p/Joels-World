# Handoff — the corner that ate the drag, and a ball that stops running

Sixth in the series. [Part 1](HANDOFF-tennis3d.md) is the architecture, [part 2](HANDOFF-tennis3d-part2.md)
is why a serve could not be returned, [part 3](HANDOFF-tennis3d-part3.md) is the strike-zone bug,
[part 4](HANDOFF-tennis3d-part4.md) is the camera, [part 5](HANDOFF-tennis3d-part5.md) is the high
ball and the difficulty that means something. Read those first — the frames, the units and the
`Tuning` names all come from them.

**Status: work in progress.** Written as the session goes so it can be picked up mid-way.
Anything marked ⏳ has not been finished or measured yet.

---

## The oldest item on the list, and what it actually turned out to be

Part 5's item 1, unchanged for four sessions: *"Nobody has still played it with a thumb."*

The Claude Code simulator panel **attached** this time, and its `tap`/`touch_path` calls returned
success. So the first half hour of this session was spent playing the game with an injected
thumb, watching the trace, and concluding that **the drag gesture was completely broken** — a
full drag across the court produced `you=(1.5, 12.5)m … speed=0.0` for an entire point.

That conclusion was wrong, and the way it was wrong is worth writing down.

Instrumenting `panned` showed zero gesture callbacks. Instrumenting `hitTest` showed zero
hit-tests. That is not a broken gesture — that is no touch arriving at all. The control
experiment settled it: **the help button did not open the help dialog either, and the HOME button
did not go home.** The panel was in a crash loop (`screenshot` kept returning "restarting after a
crash") and its input injection was silently doing nothing while reporting success.

So: `simctl` still cannot inject a touch, `idb` and `cliclick` are not installed, and the panel
reports success while delivering nothing. **Do not trust a green result from the panel's `tap`
without a control that proves the app moved.** Press HOME first; if the springboard does not
appear, the injection is dead and every test you run through it is worthless.

## So the input path got tested from both ends instead

Being unable to inject a touch is not a reason for the logic behind the touch to go unexercised.
Two new flags split the problem in half, and between them they cover everything except UIKit's own
delivery of a `UITouch` to a view — which is Apple's code, and which the first half now proves is
wired correctly.

### `-tennis3dhittest` — is the court even reachable?

Once a second, asks the **real window** the question UIKit asks — `hitTest` this point — at four
places on the court, and reports which view wins. `Tennis3DView.debugHitTestReport(at:)`.

This is the half that no amount of driving the view from inside can answer, and it found a real
bug on its first run:

```
tennis3d hit-test · court centre        201,437 → Tennis3DView ✓
tennis3d hit-test · near baseline       201,694 → Tennis3DView ✓
tennis3d hit-test · bottom-right corner 342,784 → UIButton ✗ — this view is not reachable
tennis3d hit-test · Alex's half         201,305 → Tennis3DView ✓
```

**Part 5 did not fix the button-bar problem, it halved it.** Hiding badges and emotes left the
exit and help buttons sitting in the bottom-right corner — which is still exactly where the near
player stands when a deep ball has pushed them back onto the fence. A drag that *starts* there
never reaches the game. It is the drag you most need, because you are in trouble, and it did
nothing.

The fix is to move the row rather than thin it: `GameViewController.setButtonBarOutOfPlay(_:)`
swaps the bar's bottom constraint for a top one for the duration of any minigame, and
`ButtonBarView.setMinigameMode` turns the stack vertical so the two survivors are one button wide
and clear the right-hand end of the scoreboard. All four probes now report `Tennis3DView ✓`.

### `-tennis3ddrag` — does the drag itself work?

`-tennis3dtaps` covers the tap recogniser and nothing else. The drag has its own bookkeeping — the
1.8 m grab test, the offset held constant for the rest of the gesture, the `isDragging` flag that
stops the tap recogniser fighting it — and none of it had ever run, on any machine, in five
sessions.

It could not run, because a `UIPanGestureRecognizer` cannot be constructed with a chosen state and
location. So `panned`'s body moved into `handleDrag(_ phase: DragPhase, at: CGPoint)`, and
`debugDrag` enters at the same line UIKit would. The bot sends one `.began` **on the player**, so
the grab branch runs, then `.changed` at 30 Hz for the rest of the point, then `.ended` when the
point ends — a real gesture rather than a stream of separate grabs.

It plays. `DRAG grabbed, offset (0.00, -0.00)m`, then strikes with no misses.

---

## ⏳ Still to do this session

1. The ball carries too far — `bounceRestitution` (0.73) and the topspin `kick` in `bounce()`.
2. Rally length is skewed, not long.
3. No volley; Alex never comes to the net.

## What is left after this session

*(to be filled in)*
