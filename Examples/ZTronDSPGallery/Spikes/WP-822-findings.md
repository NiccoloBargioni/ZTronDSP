# WP-822 — How a hosted `MTKView` moves through an animated frame change and a rotation (SZ-4)

Spike of milestone M8. Written by the implementer of the Examples project (brief 19), 2026-11-16 and 2026-11-17.

**Result in one paragraph.** The two signals of SZ-4 exist and each stands for one kind of transition: SwiftUI moves
a hosted view's *own* bounds, once per display frame, and tells the size probe; UIKit, in a rotation, gives the view
its final bounds at once and animates the layer. So the *detection* rule stands. Two things that are built on it do
not. (A) The frame of a transition is made on the display-link tick, which comes *before* SwiftUI lays the view out
in the same frame, so the drawable is one step behind the bounds it is shown with, and on iOS 18.6 and 27.0 a resize
without animation costs two draws. (B) The drawable's size is computed with the layer's `contentsScale`, which
`MTKView` rewrites whenever its drawable is sized by hand, so in a rotation the drawable shrinks to 1 × 1 px, is left
at a wrong size, and on the way back grows until, on two of the three runtimes, Metal ends the application. A third
thing, smaller and seen on simulators only: (C) the scheduler's frame-rate cap now and then refuses a tick of a
transition, and the frame of that tick is not made. A corrected rule was prototyped beside the package, without
changing it, and meets the acceptance of §8.9 on iOS 17.5, 18.6 and 27.0.

Nothing of the package was changed. What follows is (1) what was done, (2) what was observed, (3) the defects,
(4) the corrected rule in the wording of the specification, (5) the lines of `Sources/ZTronDSPUI` that would change,
(6) the evidence for the corrected rule, (7) what could not be observed.

---

## 1. What was done

| | |
|---|---|
| Where | In the gallery application, by tests that run inside it: `GalleryTests/SizeTransitionSpike.swift` (the spike), `GalleryTests/SizeTransitionAcceptanceTests.swift` (the acceptance WP-824, which uses the same instrument). |
| Instrument | `GalleryTests/Support/TransitionRecorder.swift`. It reads; it decides nothing. |
| From outside | `GalleryUITests/SizeSpikeUITests.swift` turns the *device* (a hosted test cannot) while `Gallery/Spikes/SizeSpikeScreen.swift` writes down what a size probe is handed. |
| Runtimes | iOS 27.0 (`ztdsp-27-m8b`, iPhone 17, 3×), iOS 18.6 (`ztdsp-18-m8b`, iPhone 16, 3×), iOS 17.5 (`ztdsp-175-m8b`, iPhone 15, 3×). Simulators only. |
| Raw logs | `Spikes/logs/ios-<runtime>/wp822-*.log`, `wp824-*.log`, `size-spike-device.log`, and the two `rotation-as-built-crash.txt`. For iOS 27.0 the folder holds the run of 19:09 on 2026-11-17, the last in which the as-built component stayed in the window while the interface turned back, and `three-runs-21h18/run-3/` holds a later run, made after the recorder had learnt to write down the ticks the scheduler passes by. For iOS 18.6 the folder holds the run of 19:38 and `final-run/` the run with the final test code. `wp824-verdicts.log` has the verdicts of every run of the day on its simulator. |

**What the recorder writes down**, in order, with the time since it started:

- `surface.tick begin` / `surface.tick end`: on every tick of the surface's own display link, what the layer of the
  Metal view says before the surface looks, and after the surface has dealt with the tick: the layer's bounds
  (`model`), the bounds of its presentation layer (`shown`), its animation keys, the drawable's size, the layer's
  `contentsScale`, whether the view resizes its drawable by itself (`auto`), whether the layer presents with its
  transaction, and the animated layers above it.
- `view.drawableSizeWillChange`: every drawable size the view announces to its delegate.
- `view.draw.begin` / `view.draw.end`: every frame the view is asked for.
- `probe.set` / `probe.body`: every size an `Animatable` view is handed that is built like the package's size probe
  (a `GeometryReader` that gives its size to an `Animatable` view), laid behind the component.
- `frame N end`: for every frame of the display, what stands when the run loop is about to wait and Core Animation is
  about to commit the transaction: this is what the frame on the display is made of. `mismatch` is the distance, in
  pixels of the display, between the drawable and the size the layer is shown at.
- `surface.tick passed by`: the surface's display link ticked and its scheduler did not call the surface. `ticks`
  and `handled` on a `frame N end` line count the ticks the scheduler was given and those it let through. (The
  recorder learnt these two late: logs recorded before 21:00 on 2026-11-17 do not have them.)

**Stimuli.** A `.frame` change from 200 × 120 to 320 × 300 points inside `withAnimation` (linear, ease-in-out and a
spring, half a second) and back; the same change without animation; a component whose size follows an animated
neighbour; a rotation of the interface, portrait to landscape and back, asked of the scene with
`UIWindowScene.requestGeometryUpdate`, which animates as a turn of the device does (the UI test turns the device
itself and sees the probe handed the same thing).

**Rules.** Every stimulus was recorded three times (`SizeRule`): with the package as built; with the package's rule
but the display's scale handed to the layer adapter (`DisplayScaleLayer`); and with a prototype of the corrected
rule (`EndOfTurnFollower`). Both prototypes are in `GalleryTests/Support/CorrectedRule.swift`. They use the seams the
package already has (`SurfaceCoordinator.layer`, the coordinator's renderer).

---

## 2. What was observed

### 2.1 A frame that SwiftUI animates

(`wp822-frame-linear-asBuilt.log`, and the ease-in-out and spring logs beside it. The same on all three runtimes.)

- **SwiftUI steps the view's own bounds.** On every display frame of the animation the bounds of the Metal view's
  layer are *set* to the interpolated size. The layer never carries an animation (`keys=[]`) and its presentation
  bounds equal its bounds at every moment. The layer's half of SZ-4 never fires.
- **The size probe is handed one interpolated size per display frame** (`probe.set`, then `probe.body`), in the same
  turn of the run loop in which the bounds move, a tenth of a millisecond before them.
- **The view announces every step.** With automatic resizing on, `MTKView` calls `drawableSizeWillChange` at the
  moment its bounds are set, with the new size times the display's scale.
- **The order inside one frame of the display** is: (1) the surface's display-link tick; (2) SwiftUI's step of the
  animation: probe, then bounds; (3) the run loop goes to wait and the transaction is committed. SwiftUI's step
  follows the display too, and comes later in the same turn of the run loop than the surface's tick: in every frame
  of every run, on all three runtimes (60 of 60 frames in the linear animation, 192 of 192 in the spring). So on its
  tick the surface always finds the layer at the size of the *previous* frame.

  ```
  surface.tick begin model=(208,132) shown=(208,132) keys=[] drawable=(612,378)      <- tick: the layer is where the last frame left it
  surface.tick end   model=(208,132) shown=(208,132) keys=[] drawable=(624,396) ...  <- the surface sizes the drawable for it and draws
  probe.set  size=(212,138)                                                          <- then SwiftUI steps: the probe ...
  probe.body size=(212,138)
  frame 11 end model=(212,138) shown=(212,138) keys=[] drawable=(624,396) mismatch=18.00   <- ... and the bounds: committed 18 px apart
  ```

### 2.2 A frame that is changed without animation

(`wp822-frame-plain-asBuilt.log`.) Here the runtimes differ.

**iOS 18.6 and 27.0.** SwiftUI evaluates the view with the new size at once (the probe is handed it in the turn of
the state change), but gives the Metal view its new bounds with the *next frame of the display*, after the surface's
tick of that frame:

```
stimulus set frame (320,300)
probe.body size=(320,300)                                              <- at once: the probe reports, the surface asks for a tick
surface.tick begin model=(200,120) ... drawable=(600,360) auto=1       <- next frame, tick: the layer still has its old size
surface.tick end   model=(200,120) ... drawable=(600,360) auto=0 withTransaction=1 inTransition=1 draws=2   <- draw no. 1, at the OLD size
frame 2 end model=(320,300) shown=(320,300) drawable=(600,360) mismatch=540.00    <- then the bounds change: old picture, new bounds
surface.tick end   model=(320,300) ... drawable=(960,900) auto=1 inTransition=0 draws=3   <- next tick ends the transition: draw no. 2
```

**iOS 17.5.** SwiftUI gives the view its new bounds in the turn of the state change itself: the view announces its
new drawable size 0.4 ms after the probe is handed the size, and the surface's next tick finds the layer at the new
size and draws once, at the right size. Between the two the turn of the state change ends: its transaction carries
the new bounds and nothing drawn at the new size, so until the frame of the next tick is presented the old picture
is stretched over the new bounds. (That is what a Metal view shows when a resize is not drawn in the turn it happens
in. The recorder cannot see the display: its `mismatch` reads the view's `drawableSize`, which has already followed
the bounds, and says 0 here.)

```
stimulus set frame (320,300)
probe.body size=(320,300)
view.drawableSizeWillChange size=(960,900)                             <- same turn: the bounds have changed
surface.tick begin model=(320,300) ... drawable=(960,900) auto=1       <- next frame, tick: one draw, at the new size
```

### 2.3 A size that follows an animated neighbour

(`wp822-neighbour-asBuilt.log`.) The same as 2.1: the bounds are stepped once per frame, no animation on the layer,
the probe handed every step.

### 2.4 A rotation of the interface

(`wp822-rotation-asBuilt.log`, `size-spike-device.log`. The same on all three runtimes.)

- **UIKit gives the view its final bounds at once and animates the layer.** In the first turn the bounds of the Metal
  view's layer become the final ones (322 × 794 → 794 × 322 points), the layer gets two animations, `position` and
  `bounds.size`, and so do the layers above it (the platform-view host, the hosting view). The presentation bounds
  then run from the old size to the new one for the length of the rotation. This is the layer's half of SZ-4.
- **The size probe is handed the final size, once**, at the start. It is not handed sizes on the way. A turn of the
  device, made by a UI test with `XCUIDevice.shared.orientation`, hands a probe in the application's own scene the
  same: the final size and no size on the way (`size-spike-device.log` of the three runtimes). On iOS 17.5 and 18.6
  the turn back hands it two sizes within two milliseconds, a layout in between and the final one. On iOS 17.5 the
  gallery ended in three of the six runs of this test (see 3 (B)); the log is of a run in which it did not.
- **The view announces the final drawable size, once**, at the start (automatic resizing is on then).

### 2.5 When a presentation value is for

(`wp822-presentation-clock.log`: a layer with a linear animation of one point per millisecond, so that the width it
is shown at is the time Core Animation evaluated the animation for.)

- On a display-link tick, a layer that nobody has asked since the tick before is shown as it is *now*, on all three
  runtimes: `tick now=0.6997 … shown=0.6997` (iOS 27.0).
- Core Animation keeps the answer it has given. On iOS 18.6 and 27.0 it works the value out anew once per frame of
  the display, in a pass of its own that comes after the application's display-link callbacks, and gives that answer
  to every reading until its next pass. A layer that was asked at the end of a frame therefore answers the next tick
  with the value of a frame ago: `tick now=0.0330 … shown=0.0165`, and then, at the end of the same turn,
  `turn.end now=0.0331 shown=0.0331` (iOS 27.0). On iOS 17.5 the answer is kept only until the run loop next goes
  to wait: there the tick is answered with what the turn before it was told, one to two milliseconds old.

Two consequences. A reading on the tick is only as fresh as nobody else's reading lets it be; a reading at the end of
the turn in which the display ticked is fresh on all three runtimes. And an instrument must not ask at the end of a
frame when the rule under test asks on the tick: the recorder does not (it did at first, and made the package's rule
look a frame late in a rotation).

### 2.6 What `MTKView` does with a drawable size that is set by hand

With automatic resizing off, setting `drawableSize` to a size that is not the bounds times the scale makes `MTKView`
rewrite the layer's `contentsScale` to *drawable width ÷ bounds width*. In the rotation log the scale goes from
3.0000 to 1.2166 with the first frame of the transition (966 px ÷ 794 points), and on from there.

---

## 3. The defects

### (A) The frame of a transition is made a step too early

`SurfaceCoordinator.tick()` calls `stepSizeTransition()` first (`Surface/SurfaceCoordinator.swift`, line 268), and
`stepSizeTransition()` gives the drawable the size the layer is shown at *then* (line 248). By 2.1 that is the size of
the previous frame: SwiftUI has not stepped yet. The frame is presented with the transaction (lines 292–298), and
into the same transaction SwiftUI then puts the next bounds.

- **Animated change:** every frame of the transition is committed with a drawable one step of the animation smaller
  (or larger) than the bounds it is shown in: 12 × 18 px in the linear test animation, in every frame, on all three
  runtimes; up to 31 px with the ease-in-out curve and 69 px with the spring. Core Animation stretches it to fit.
  Section 8.9 forbids exactly this ("must not show stretched or late content at any moment of the transition").
- **Change without animation** (2.2), on iOS 18.6 and 27.0: two draws instead of the one that §8.4 asks for ("View
  resized without animation: 1 draw per changed size"). **The spare draw is the first.** It is made on the tick that
  follows the probe's report (`reportSize`, lines 199–207, sets `sizeMoved`; the branch `moved || geometry.isMoving`,
  line 240, starts a transition and line 249 marks the size as changed), at the size the layer still has, the old
  one, and is shown stretched over the new bounds for one frame (540 px apart in the test). The second draw, on the
  tick that ends the transition (lines 250–258), is the right one. On iOS 17.5 the resize is one draw, but the
  bounds are committed in the turn of the state change and the draw waits for the next tick: until then the old
  picture is stretched over the new bounds (2.2). On iOS 27.0 two draws are the rule, not a law: of the 66 resizes
  the stability suite made there in eleven runs, one was a single draw (that suite has no recorder, so the order of
  that one case is not known); every resize the spike recorded on iOS 18.6 and 27.0 was two draws.
- The acceptance of §8.9 as it is worded does not see this. Read on the surface's own tick, the drawable equals the
  presentation size (0.00 px), and the frame at the midpoint, stretched by one step, still scores 36.8 dB against a
  direct rendering, above the bar of 35 dB.
- Whether the surface's tick or SwiftUI's step comes first in a frame is not something the package decides. A rule
  must not depend on the order.

### (B) The scale is read from a place `MTKView` writes to

`MetalLayerAdapter.geometry` takes `scale: layer.contentsScale` (`Surface/MetalSurface.swift`, line 149). In a
rotation the surface sets the drawable to *presentation size × scale* while the layer's own bounds are already the
final ones. By 2.6 `MTKView` then rewrites `contentsScale` to *drawable width ÷ model width*, the next tick
multiplies the presentation size by that smaller scale, and so on: the drawable shrinks by the same factor with every
tick.

```
surface.tick end model=(794,322) shown=(322.00,794.00) keys=[position+bounds.size] drawable=(966,2382) scale=1.2166
surface.tick end model=(794,322) shown=(322.09,793.91) ...                          drawable=(392,966)  scale=0.4937
surface.tick end model=(794,322) shown=(333.43,782.57) ...                          drawable=(165,386)  ...
 ...                                                                                drawable=(1,1)
```

- During the rotation the picture is a handful of pixels, stretched over the view.
- **After the rotation the drawable stays 1 × 1 px** (the transition ends with `setDrawableSize(geometry.modelPixels)`,
  line 255, computed with the same broken scale): the component shows one colour until something else resizes it.
- Turning back multiplies the other way: on iOS 27.0 the drawable grew to 4 651 × 11 469 px and, in another run,
  to 116 million pixels for a view of 322 × 794 points (it should be 966 × 2 382): several hundred megabytes for
  one drawable (`ios-27.0/wp822-rotation-asBuilt.log`, `wp824-rotation-asBuilt.log`).
- **Where the growing drawable passes the largest texture the device allows, the application ends.** On the iOS
  18.6 simulator, whose limit is 8 192 pixels, the way back ended the application both times it was tried:
  `MTLTextureDescriptor has height (8388) greater than the maximum allowed size of 8192`
  (`ios-18.6/rotation-as-built-crash.txt`). On the iOS 17.5 simulator, same limit, the gallery itself ended that
  way when a UI test turned the device to landscape and back with the size-spike screen open, in the application's
  own scene and with nothing of the tests in it, in three runs of six: "com.zombietron.ztrondsp.gallery crashed in
  MetalViewHost.draw(in:)" (`ios-17.5/ui-tests-summary.txt`; the system's crash report has
  `-[MTLTextureDescriptorInternal validateWithDevice:]` under `-[CAMetalLayer nextDrawable]`, called from
  `MetalViewHost.draw(in:)` on `SurfaceCoordinator.tick()`: `ios-17.5/rotation-as-built-crash.txt`). On iOS 27.0
  the limit is 16 384 pixels and was not reached in the runs made.
  Since then the hosted tests take the component away before the interface turns back when the package runs as
  built; the two logs of iOS 27.0 named above were recorded before that.
- With the display's scale handed in from outside (the prototype `DisplayScaleLayer`, nothing else changed) the
  drawable follows the presentation size within half a pixel on every tick and ends at the exact size.

### (C) The frame-rate cap refuses a tick of a transition (seen on the simulators)

`FrameScheduler.tick(at:)` passes a tick by when it comes less than 0.95 ÷ 60 s after the last one it let through
(`Scheduling/FrameScheduler.swift`, line 124; `minimumInterval`, lines 112–114). It compares the times the display
link gives its ticks (`timestamp`). On a simulator those times are not evenly spaced when the main thread is late:
after a tick that was delivered late, the next one comes sooner by the link's own clock too. The recorder writes it
down when the scheduler is ticked and does not call the surface:

```
frame 17 end ... shown=(640.57,444.43) ... drawable=(1922.00,1333.00) ... mismatch=0.28 ... ticks=13 handled=13
surface.tick passed by: the scheduler was ticked and did not call the surface; by the clock's own time this tick came 12.8 ms after the last one that reached it
frame 18 end ... shown=(671.15,413.85) ... drawable=(1922.00,1333.00) ... mismatch=91.45 ... ticks=14 handled=13
```

The surface is not called in that frame of the display although its transition goes on, and the drawable keeps the
size of the frame before. In a rotation under the rule "display scale" that one frame stood 91 px from the size the
layer was shown at (`ios-17.5/wp824-rotation-displayScale.log`, frame 18; 104 px and 7 px in the two runs before
it, 8 px in `ios-17.5/wp822-rotation-displayScale.log`, and 28 px in `ios-27.0/wp822-rotation-displayScale.log`,
frame 5, recorded before the recorder wrote the reason down). As built the same ticks are passed by; in a rotation
(B) hides it.

It is not rare. In three runs in a row on iOS 27.0 (21:18 to 21:27) the scheduler passed nine ticks by, each 12.5 to 15.6 ms after
the one before by the link's own time (the last of these is one millisecond early). One of them fell into a frame
that SwiftUI animated, under the rule "display scale": that transition then had two draws fewer than frames of the
display, which fails the acceptance's "at least the number of ticks minus one", and one frame 54 px off
(`ios-27.0/three-runs-21h18/run-3/wp824-frame-displayScale.log`). The same happened as built in an earlier run,
and ticks were passed by on iOS 18.6 too (`ios-18.6/final-run/wp824-rotation-displayScale.log`). The hosted acceptance
test marks it as a known issue that comes and goes.

- A tick is late when the main thread is busy in the frame before: with the layout of a rotation, or, in the
  acceptance test, with the copy of the frame that is captured at the midpoint. So the acceptance test brings the
  late tick about itself; the spike's logs, which capture nothing, show it too, less often.
- On a device the times of a 60 Hz display link should be a whole number of frames apart, and the cap should then
  never refuse a tick at its own rate. That could not be observed here (section 7).
- SZ-2 asks for one frame "on every display frame" of a transition, and the cap is the one place where a frame of
  a transition is refused. A transition should not go through it. The prototype of the corrected rule does not (it
  steps on every tick of the display) and has no such frame in any run.

---

## 4. The corrected rule, in the wording of the specification

**§8.9, SZ-2** (changed sentences in *italics*):

> **SZ-2** During a transition the drawable follows the size the layer is shown at: on every display frame the
> drawable size is set to the presentation bounds times the display scale, and one draw is made. *The size is read
> and the frame is made at the end of the run-loop turn of that frame, when SwiftUI and UIKit have laid the view out
> and before the transaction is committed, not on the display-link tick: SwiftUI moves a view's bounds after the tick
> of the same frame, and a frame made on the tick is shown one step late. The display scale is the one SwiftUI
> reports (`\.displayScale`), never the layer's `contentsScale`, which `MTKView` rewrites whenever its drawable is
> given a size by hand.* Automatic drawable resizing is off for the duration, because it would jump to the final size
> at once and let Core Animation stretch that image through the transition.

**§8.9, SZ-4:**

> **SZ-4 Detecting a transition.** Two signals, either of which starts it, *each standing for one kind of
> transition*. *A change of size that SwiftUI makes, animated or not, moves the view's own bounds, once per display
> frame while it is animated: the layer carries no animation and is shown at its own size throughout, and* an
> `Animatable` probe in the SwiftUI wrapper *is handed every size, in the turn in which the bounds move or, for a
> change without animation on iOS 18 and later, a frame before them.* *A rotation of the interface gives the view its
> final bounds at once and animates* the layer itself (its presentation bounds differ from its model bounds, or it
> has animation keys); *the probe is handed the final size once.* The transition ends when the presentation size
> equals the model size and neither signal *was active in the frame*; *a frame at the exact size follows only if the
> last one was drawn at another size.* *(Confirmed by WP-822 on the simulators of iOS 17.5, 18.6 and 27.0. Not
> observable there: a device, iOS 15 and 16.)*

**§8.3**, the cause "drawable size changed": add *"A frame that is due to a change of size is made at the end of the
run-loop turn in which the size changed (SZ-2), not on the next tick."*

**§8.9, the acceptance (WP-824):** *"… at every display tick of the transition, when the frame's transaction is
committed, the drawable's size equals the presentation size within one pixel …"*. Read on the surface's own tick the
sentence is true of a drawable that is a step late.

**§8.4**, the row "View resized without animation: 1 draw per changed size" stays as it is: with the corrected rule
it holds in real hosting on all three runtimes (one draw), where it now fails on two (two draws).

---

## 5. The lines of `Sources/ZTronDSPUI` that would change

| File, lines | Now | Change |
|---|---|---|
| `Surface/MetalSurface.swift` 145–150, `MetalLayerAdapter.geometry` | `scale: layer.contentsScale` | The scale is handed in: `LayerGeometry.scale` is the display's. Either `MetalLayerAdapter` keeps a scale its owner sets, or `SurfaceLayer.geometry` becomes a function of the scale. |
| `Surface/MetalSurface.swift` 13–35, `SurfaceInput` | no scale | A field `displayScale: CGFloat`. |
| `Components/SurfaceHost.swift` 78–101, `SurfaceFrame`; 19–75, `SurfaceHost` | reads `\.scenePhase` and the probes | Also reads `@Environment(\.displayScale)` (UB-4 names it as the substitute for `UIScreen.main.scale`) and passes it on in `SurfaceInput`. |
| `Surface/SurfaceCoordinator.swift` 151–169, `update(_:)`; 285–291, `render(to:presenting:)` | makes `MetalLayerAdapter(drawable.layer)` | Keeps the display scale and gives it to the adapter; a changed scale is a size cause. |
| `Surface/SurfaceCoordinator.swift` 266–280, `tick()`, line 268 | `stepSizeTransition()` at the start of every tick | The tick no longer steps a transition. While the layer is animated it only says that this frame needs a step at the end of the turn. |
| `Surface/SurfaceCoordinator.swift` 199–207, `reportSize(_:)`; 211–216, `drawableSizeWillChange(to:)` | set `sizeMoved`, mark the cause, ask for a tick | Ask for a step at the end of the *current* turn instead of a tick. |
| `Surface/SurfaceCoordinator.swift` 227–260, `stepSizeTransition()` | runs on the tick | Runs when the run loop is about to wait: a `CFRunLoopObserver` for `.beforeWaiting` in the common modes with an order below Core Animation's (2 000 000), installed when a step is asked for and removed when the transition has ended, so that a resting view keeps nothing on the run loop. It reads the geometry, sets the drawable (`setDrawableSize`), marks the cause, and draws through `surface.draw()` with `isInSizeTransition` true, so that `render(to:presenting:)` presents with the transaction (292–298, unchanged). The end of a transition (250–258) draws only when the last frame had another size. |
| `Scheduling/FrameScheduler.swift` 116–130, `tick(at:)`, line 124 | every tick is held against the frame-rate cap | It still decides when the display link runs, and during a rotation the link runs (the layer moves) and each tick asks for the end-of-turn step. A tick of a size transition is not held against the cap (3 (C)): the coordinator tells the scheduler that a transition is under way, or the cap moves from the tick to the draw of content. |
| `Tests/ZTronDSPUITests/SizeTransitionTests.swift`, `Support.swift` (`ScriptedLayer`, `Stage.report(size:)`) | script a step on `tick()` | Script the end of a turn instead; the scripted layer is given the scale explicitly, which it already is. |

`Bridge/MetalViewRepresentable.swift` does not change, and no member outside UB-3 is needed: the observer is Core
Foundation, the scale comes from SwiftUI.

A smaller alternative for (A) was considered and not prototyped: draw inside `update(_:)` when the probe reports a
size, with the probe's size times the display scale. It does not need an observer, but it draws in the middle of
SwiftUI's update, it rests on the probe's size being the size the bounds get, and on iOS 18 and later it would draw a
frame before the bounds move when the change is not animated.

---

## 6. Evidence for the corrected rule

`GalleryTests/SizeTransitionAcceptanceTests.swift` runs the acceptance of §8.9 for each rule. "At commit" is the
largest distance between the drawable and the size the layer is shown at over all frames of the transition, when the
transaction is committed; "on the tick" is the same after the surface dealt with its own tick. The numbers are in
`Spikes/logs/ios-<runtime>/wp824-verdicts.log`.

**A frame animated from 200 × 120 to 320 × 300 points, linear, half a second** (the numbers of every run on iOS
17.5 and 18.6 and of the undisturbed runs on iOS 27.0; see the note below the table):

| Rule | Frames of the display | Draws | Uploads | At commit | On the tick | Frame at the midpoint | PSNR | After |
|---|---|---|---|---|---|---|---|---|
| As built | 31 | 30 | 0 | **18.00 px** | 0.00 px | 780 × 630 px, shown at 792 × 648 | 36.8 dB | 960 × 900, exact |
| Display scale | 31 | 30 | 0 | **18.00 px** | 0.00 px | 780 × 630 px, shown at 792 × 648 | 36.8 dB | exact |
| End of turn (corrected rule) | 30 | 30 | 0 | 0.00 px | — | 780 × 630 px, shown at 780 × 630 | ∞ | exact |

Note. On iOS 27.0 the frame after the captured one was often late: reading the captured frame back takes time, and
other work loaded the machine. In six of eleven runs the as-built drawable then stood two or three steps behind in
that frame, 36 px (five runs) or 54 px (one run, in which the scheduler had also passed a tick by, (C)); under
"display scale" 37 to 54 px in three runs of eleven. The corrected rule stayed within 0.49 px in all eleven, with
as many draws as frames.

**A rotation, portrait to landscape** (the component goes from 322 × 794 to 794 × 322 points on iOS 27.0, from
313 × 772 to 772 × 313 on the other two):

| Runtime | Rule | Frames | Draws | Uploads | At commit | On the tick | Frame at the midpoint | PSNR | After the rotation | After turning back |
|---|---|---|---|---|---|---|---|---|---|---|
| 27.0 | As built | 19 | 18 | 0 | **2 379 px** | **2 379 px** | 5 × 4 px, shown at 1 807 × 1 541 | 10.8 dB | **3 × 1 px** | **4 651 × 11 469 px** |
| 27.0 | Display scale | 17 | 17 | 0 | 0.49 px | 0.49 px | 1 706 × 1 642, shown at the same | ∞ | 2 382 × 966, exact | 966 × 2 382, exact |
| 27.0 | End of turn | 17 | 17 | 0 | 0.42 px | — | 1 796 × 1 552, shown at the same | ∞ | exact | exact |
| 18.6 | As built | 20 | 20 | 0 | **2 315 px** | **2 315 px** | 1 × 1 px, shown at 1 635 × 1 620 | 9.1 dB | **1 × 1 px** | **the application ended** |
| 18.6 | Display scale | 19 | 20 | 0 | 0.49 px | 0.49 px | 1 763 × 1 492 (see the note) | — | 2 316 × 939, exact | 939 × 2 316, exact |
| 18.6 | End of turn | 18 | 19 | 0 | 0.50 px | — | 1 636 × 1 619, shown at the same | ∞ | exact | exact |
| 17.5 | As built | 19 | 19 | 0 | **2 313 px** | **2 313 px** | 5 × 4 px, shown at 1 741 × 1 514 | 10.8 dB | **3 × 1 px** | not taken in the hosted test (the gallery ended this way under the UI test) |
| 17.5 | Display scale | 18 | 17 | 0 | 0.49 px, and **91 px** in one frame (C) | 0.49 px | 1 655 × 1 600, shown at the same | ∞ | 2 316 × 939, exact | 939 × 2 316, exact |
| 17.5 | End of turn | 19 | 20 | 0 | 0.47 px | — | 1 631 × 1 624, shown at the same | ∞ | exact | exact |

Notes. "On the tick" has no meaning for the corrected rule, which does not size the drawable on the tick. For a layer
that Core Animation animates, "at commit" is judged against the size the layer was last told to be shown at in that
frame; what the render server shows a moment later is not visible to the application (section 7). In the run of iOS
18.6 under "display scale" the surface ticked twice in the turn of the captured frame, so the captured frame belongs
to the first tick and the recorded size to the second: no figure is given. In the run of iOS 17.5 under "display
scale" the scheduler passed the tick of one frame by (3 (C)); the other frames of that rotation are within 0.49 px.
The as-built numbers of a rotation differ a little from run to run (the collapse depends on the ticks): on iOS 17.5
the frame at the midpoint was 1 × 1 to 6 × 6 px in seven runs (`ios-17.5/wp824-verdicts.log`).

Over every run of the day (`wp824-verdicts.log` of each folder), in a rotation: as built 2 313 to 2 380 px at commit
in 21 runs of 21; "display scale" within half a pixel in 12 runs of 20 and one frame not made in the other eight
(7 to 114 px in that frame; where the recorder already wrote the reason down, the scheduler's cap, (C)); the
corrected rule 0.35 to 0.50 px in 19 runs of 19. In the animated frame the corrected rule stayed within 0.49 px
in 21 runs of 21, and as built the drawable was never within a pixel at commit.

**The other stimuli** (largest distance at commit over all frames, in pixels; iOS 17.5 / 18.6 / 27.0):

| Stimulus | As built | End of turn (corrected rule) |
|---|---|---|
| Frame, linear, there and back | 18 / 18 / 18 | 0.00 / 0.00 / 0.00 |
| Frame, ease-in-out | 31 / 31 / 31 | 0.48 / 0.48 / 0.48 |
| Frame, spring | 67 / 68 / 69 | 0.66 / 0.50 / 0.50 |
| Frame without animation | none in a frame with a tick, one draw (2.2) / 540 / 540 | 0.00 / 0.00 / 0.00 |
| Size that follows a neighbour | 18 / 18 / 18 | 0.00 / 0.00 / 0.00 |
| Rotation | 2 313 / 2 315 / 2 379 (the collapse; 10 874 on the way back on iOS 27.0) | 0.45 / 0.50 / 0.49, there and back |

With the prototype of the corrected rule a resize without animation is one draw, at the new size, in the turn in
which the bounds change, on all three runtimes: the turn of the state change on iOS 17.5, the next frame of the
display on iOS 18.6 and 27.0 (`wp822-frame-plain-endOfTurn.log`: `view.draw.begin` follows
`view.drawableSizeWillChange` within the turn, `mismatch=0.00`, `draws` rises by one per size).

The lag of (A) is one step of the animation, and a step grows when a frame is late. In the run of iOS 17.5 whose
logs are kept, under the rule "display scale" (which leaves (A) as it is), drawing several frames of the linear
animation took longer than a frame of the display (other work loaded the machine); SwiftUI's animation moved on by
the time that had passed, and the drawable, sized on the tick, stood up to 63 px behind
(`ios-17.5/wp822-frame-linear-displayScale.log`, frames 4, 18 and 21). The corrected rule has no such frame in any
run.

---

## 7. What could not be observed

- **A device.** Everything above is from simulators. On the simulators of iOS 18.6 and 27.0 a display-link callback
  runs at about the time its frame is shown (`now` ≈ `targetTimestamp` in `wp822-presentation-clock.log`); on the
  simulator of iOS 17.5 it runs a frame earlier (`now` ≈ `timestamp`), as it is meant to on a device. For a layer
  that Core Animation animates (a rotation) the size read in the application is then older than the size the render
  server shows, by up to a frame of the animation, whichever rule reads it. Whether that is visible has to be looked
  at on a device.
- **iOS 15 and 16.** Their runtimes do not run on this host.
- **A display faster than 60 Hz.** The simulators tick at 60 Hz.
- **A frame in which SwiftUI steps before the surface ticks.** In every frame of every run SwiftUI stepped after
  the tick. The corrected rule does not depend on the order; the rule as built does.
- **Other animated containers** (a sheet being dragged, a navigation transition, a keyboard). They move a view
  without resizing it; none was recorded.

---

## 8. What was changed in the package afterwards

Written on 2026-11-17 and 18, after the spike, when the corrections were made (change request CR-027, proposed).
Sections 1 to 7 are left as they were written: they describe the package before the change, and the logs they
name are the logs of that package. The logs of the corrected package are under `Spikes/logs/after-correction/`.

### 8.1 The rule as it is built now

A frame that is due to a size is made at the end of the run-loop turn, never on the display-link tick, and is
presented with the turn's transaction.

- **The end of a turn** is a seam of its own, `TurnEnd` (`Sources/ZTronDSPUI/Scheduling/TurnEnd.swift`), as the
  display link is (`FrameClock`). In an application it is a Core Foundation run-loop observer, `RunLoopTurnEnd`: for
  "before waiting" and "exit", in the common modes, at order 1 900 000, ahead of Core Animation's commit at
  2 000 000. It is on the run loop only from a request to the call that answers it. A request also tells the run
  loop to turn once more instead of sleeping (`CFRunLoopWakeUp`): UIKit lays views out while the transaction is being
  committed, after the observer's place in the turn, and a request made there is answered in a turn of its own right
  after, not when something next wakes the run loop.
- **What asks for the end of the turn**: the size probe reporting another size, the view announcing another drawable
  size, another display scale, the view coming back on screen, and, while a transition is under way, every tick of
  the display. All of them only once there is a layer to look at: before the first drawable the tick draws, as
  before, and a sign of another size asks for nothing (`SurfaceCoordinator.sizeMayHaveMoved`).
- **What is done there** (`SurfaceCoordinator.stepSizeTransition`, `Surface/SurfaceCoordinator.swift`). The layer
  is asked how it is shown, with the scale SwiftUI reports. (1) A layer that Core Animation animates
  (a rotation): one frame per tick of the display, at the size the layer is shown at. (2) A layer that rests at
  another size, in whole pixels, than the one the surface last drew for: one frame at that size; this is a step of
  an animated SwiftUI change, or the one frame of a resize without animation. (3) A layer that rests where the last
  frame left it: nothing is drawn for the size; a frame of the display in which nothing announced another size
  either ends the transition. What is pending for another cause (new columns) is drawn there too: during a
  transition, and in any turn in which a step was asked for before the tick, nothing is drawn on the tick, and
  what was due on it is drawn at the end of the turn (`drawIfDue`; a frame that finds no drawable there is tried
  again on the next two ticks, as one that a tick makes is).
- **The size** is the size the layer is shown at times the display scale that SwiftUI reports (`\.displayScale`,
  handed down in `SurfaceInput.displayScale`), rounded to whole pixels, and cut to the largest texture of the device
  each way (`SurfaceCoordinator.fitted`). The layer's `contentsScale` is not read anywhere. The surface compares the
  layer with its own reckoning of the size it last drew for (`followedSize`), never with the size of the drawable,
  which the view rounds its own way when it sizes it itself.
- **The frame-rate cap** does not apply while a transition is under way (`FrameScheduler.setFollowsDisplay` and
  `tick(at:)`, `Scheduling/FrameScheduler.swift`): every tick reaches the surface, and the clock is asked for up to
  120 ticks a second, which a 60 Hz display answers with its 60.

### 8.2 Where this differs from sections 4 and 5

- Section 5 put the step at the end of the turn and kept the tick as the thing that asks for it. As built, the
  tick asks only while a transition is under way; a resize without animation never waits for a tick.
- Section 5 named "before waiting"; the observer is also called on "exit", as Core Animation's is, and a request
  wakes the run loop (8.1).
- Section 4's SZ-4 says the probe "is handed every size". The probe is now only one of the things that ask for a
  look at the layer; the decision is made from what the layer says at the end of the turn. On iOS 18 and later the
  probe's report of a change without animation comes a frame before the bounds move, and nothing is drawn for it.
- The bound on the drawable's size and the comparison in the surface's own rounding are new. A first version
  compared within a pixel and left a spring's steps of less than a pixel undrawn (1.4 px seen); it was replaced.
- Proposed wording that follows from this is in the report of the correction (the change request's text), not here.

### 8.3 Files

| File | What changed |
|---|---|
| `Sources/ZTronDSPUI/Scheduling/TurnEnd.swift` (new) | `TurnEnd`, `RunLoopTurnEnd`. |
| `Sources/ZTronDSPUI/Surface/SurfaceCoordinator.swift` | The size rule of 8.1; the one-time notice about the scene phase (not part of this spike). |
| `Sources/ZTronDSPUI/Surface/MetalSurface.swift` | `SurfaceInput.displayScale`; `SurfaceLayer.geometry(scale:)` in place of `geometry`; `MetalLayerAdapter` no longer reads `contentsScale`. |
| `Sources/ZTronDSPUI/Components/SurfaceHost.swift` | `SurfaceFrame` reads `@Environment(\.displayScale)` and hands it down. |
| `Sources/ZTronDSPUI/Scheduling/FrameScheduler.swift` | `setFollowsDisplay(_:)`, `displayRate`; the cap is not applied while it is on. |
| `Tests/ZTronDSPUITests/SizeTransitionTests.swift` | Rewritten: the scripted order is tick, then SwiftUI's move, then the end of the turn. |
| `Tests/ZTronDSPUITests/TurnEndTests.swift` (new) | The observer on the real run loop. |
| `Tests/ZTronDSPUITests/Support.swift`, `SurfaceCoordinatorTests.swift`, `FrameSchedulerTests.swift` | `ManualTurn`, `Stage.endTurn()`, a scripted layer without a scale of its own; the adapter's scale; the cap. |
| `Examples/ZTronDSPGallery/GalleryTests/` | The prototypes are gone (`Support/CorrectedRule.swift`, `SizeRule`); the spike and the acceptance record and judge the package as built; no known issue is left. |

### 8.4 What the hosted tests measure now

Package as corrected, Debug, in the gallery application, in the main tree as integrated on 2026-11-21: on iOS 27.0
three hosted runs in a row (each cell gives the three runs in order), on 18.6 and 17.5 one; the UI tests once on each
(`Spikes/logs/after-correction/ios-<runtime>/`, and `Docs/Process/reports/impl-integration-2026-11-21.md`). The runs
of 2026-11-17 and 18, made before the integration, are in `before-integration-2026-11-18/` of the folders of 17.5 and
27.0 (none was filed for 18.6). Where a cell gives a distance, those runs measured the same within
0.05 px. A PSNR below ∞ is that of a captured frame in which the layer moved on, and it differs from run to run
(17.5 then: 41.2 dB there, 40.6 dB back).
"At commit" and "when drawn" are the largest distance between the drawable and the size the layer is shown at, in
pixels: read when the frame's transaction is about to be committed, and read when the surface drew the frame.

| | iOS 17.5 | iOS 18.6 | iOS 27.0 |
|---|---|---|---|
| Animated frame (WP-824): at commit | 0.00 px | 0.00 px | 0.00 / 0.00 / 0.00 px |
| Animated frame: PSNR at the midpoint, draws for frames, uploads | ∞; 30 draws for 30 frames; no upload | ∞; 30 draws for 30 frames; no upload | ∞; 30 draws for 30 frames; no upload |
| Rotation there (WP-824): when drawn; PSNR | 0.49 px; 40.2 dB | 0.46 px; ∞ | 0.45 / 0.49 / 0.46 px; ∞ |
| Rotation back (WP-824): when drawn; PSNR | 0.43 px; 41.9 dB | 0.50 px; 40.6 dB | 0.49 / 0.47 / 0.49 px; ∞ |
| Drawable after the rotation, and after turning back | 2316 × 939 px, then 939 × 2316 px; 0.00 px, 0.00 px from the layer | 2316 × 939 px, then 939 × 2316 px; 0.00 px, 0.00 px from the layer | 2382 × 966 px, then 966 × 2382 px; 0.00 px, 0.00 px from the layer |
| Frame with ease-in-out, spring (spike): at commit | 0.48 and 0.50 px | 0.48 and 0.50 px | 0.48 and 0.50 / 0.48 and 0.50 / 0.48 and 0.50 px |
| Frame without animation, three sizes: draws; commits without a frame for their bounds | 3 draws; none (one draw per size: [1, 2, 3]) | 3 draws; none (one draw per size: [1, 2, 3]) | 3 draws; none (one draw per size: [1, 2, 3]) |
| Size that follows a neighbour: at commit | 0.00 px | 0.00 px | 0.00 / 0.00 / 0.00 px |
| A turn of the device and back, twice (UI test) | passed, the application lives through both turns there and back; the probe is handed the final size of each turn, and on each turn back also one layout in between, 0.7 and 0.8 ms before the final size (6 sizes for 4 turns) | passed, the application lives through both turns there and back; the probe is handed the final size of each turn, and on each turn back also one layout in between, 0.8 and 0.8 ms before the final size (6 sizes for 4 turns) | passed, the application lives through both turns there and back; the probe is handed the final size once per turn (4 sizes for 4 turns) |

The application lives through every rotation, there and back, on all three runtimes: the crash of finding (B) is
gone.

**One thing the recorder learnt on the way.** For a layer that Core Animation animates, the size the layer reports
can move on within one turn of the run loop, between the moment the surface makes the frame and the moment the
transaction is committed, two or three milliseconds later: Core Animation works the value out for a time of its
own. On iOS 27.0 the two readings agree unless the main thread was held up across a frame of the display; on iOS
18.6 they agreed until one such hold-up and differed in every frame after it; on iOS 17.5 they differ in most
frames of a rotation (on 2026-11-21: on 27.0 in no frame of the three runs; on 18.6 in none of the 19 frames there
and in 13 of the 19 back; on 17.5 in 17 of 19 there and 17 of 19 back). A surface can size its drawable only for what the layer says when the frame
is made, so the hosted tests judge such frames by the reading at the draw and count them (`movedOn` in the logs).
Before the correction the recorder asked on the tick as well, which on iOS 17.5 fixed the value for the whole turn
and hid this; the figures of section 6 for a rotation are readings of that kind. What the display shows at the
next refresh is later still, as section 7 says of a device: for a rotation the drawable can be behind the layer by
what the layer moves in the time it takes to make and commit a frame.

