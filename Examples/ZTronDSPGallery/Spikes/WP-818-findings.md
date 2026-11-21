# WP-818 — What the pinch-related gestures report together (PINCH-8)

Spike of milestone M8. Written by the implementer of the Examples project (brief 19), 2026-11-17.

**Result in one paragraph.** The first row of the table of PINCH-8 is confirmed: `SpatialEventGesture` reports both
touches from the moment they land, and the package's path for iOS 18 scales as specified under synthesised touches.
The rows for iOS 17 and for iOS 15 and 16 are confirmed in one half and corrected in the other. The pinch half of
each pair reports what the table assumes: the centroid as start location (iOS 17), the ratio of the finger distances
as scale. But when the two fingers land together, the drag half reports nothing for the whole gesture, on every
runtime that could be run, so the finger line of the table cannot be formed. As the package is built, it then scales
nothing when both axes are enabled: **on iOS 17.5 a pinch on a component with `.pinchScaling([.horizontal,
.vertical])` does nothing.** What the drag reports when the first finger lands before the second, which is the case
the two rows were written for, cannot be produced by a test and stays an assumption.

Nothing of the package was changed.

---

## 1. What was done

| | |
|---|---|
| In the application | `Gallery/Spikes/PinchSpikeScreen.swift`: one rectangle that catches touches and carries the gestures a launch argument names, built exactly as `ZTronDSPUI` builds them for its three paths (`Pinch/PinchGestureModifier.swift`, lines 199–224). It writes down every callback with what it reports. SwiftUI only. |
| From outside | `GalleryUITests/PinchSpikeUITests.swift` plays the same five gestures into every arrangement, at three sizes of the rectangle, a mark between each two. `PinchScreenUITests` (same file) pinches the gallery's own pinch screen, where the package's gestures are installed. |
| Runtimes | iOS 27.0 (`ztdsp-27-m8b`, iPhone 17), iOS 18.6 (`ztdsp-18-m8b`, iPhone 16), iOS 17.5 (`ztdsp-175-m8b`, iPhone 15). Simulators only. iOS 15 and 16 do not run on this host. |
| Raw logs | `Spikes/logs/ios-<runtime>/pinch-<arrangement>-<width>x<height>.log` (on iOS 17.5 without the three arrangements that need `SpatialEventGesture`), and `ui-tests-summary.txt` beside them for the package's own paths (section 4). |

The arrangements (`-SpikeGesture`): `spatial` (`SpatialEventGesture`), `magnify` (`MagnifyGesture` with a simultaneous
`DragGesture(minimumDistance: 0)`), `legacy` (`MagnificationGesture` with the same drag), `spatialMagnify` and
`spatialLegacy` (a pair together with the touches on the same view, as ground truth), `separate` (the pinch and the
drag as two gestures with callbacks of their own), `cells` (a grid of 6 × 6 small drag gestures: each finger is
reported by the cell it lands in, on any OS).

---

## 2. What a test can synthesise

The same on iOS 17.5, 18.6 and 27.0.

| Who | What | Could it be produced? |
|---|---|---|
| A UI test (XCUITest, out of process) | `pinch(withScale:velocity:)`, `rotate(_:withVelocity:)`, `twoFingerTap()`, `tap(withNumberOfTaps:numberOfTouches:)`: two or more fingers that land **in the same event** | Yes. |
| A UI test | One finger: `press(forDuration:thenDragTo:)`, the swipes, taps | Yes. |
| A UI test | The path of each finger of a two-finger gesture; a second finger that lands **after** the first | **No.** XCUITest has no public way to describe it. (It can be done with the private event-synthesis classes of XCTest; they were not used.) |
| A UI test | Where the fingers of a pinch land | Only through the size of the element that is pinched: see below. |
| A hosted test (in the application's process) | Any touch | **No.** There is no touch input, and `XCUIDevice` / `XCUIApplication` refuse to work in a unit-test bundle ("Device is not configured for UI testing"). Gestures are scripted through the package's seam there (`PinchScript`). |

**Where XCUITest puts the fingers**, measured on iOS 27.0 with `SpatialEventGesture` and with the grid of cells
(coordinates in the rectangle; the two fingers were reported within 0.1 ms of each other every time; iOS 18.6 gives
the same within a point or two, and the grid of cells gives the same on iOS 17.5):

| Gesture | 300 × 300 | 340 × 140 | 140 × 340 |
|---|---|---|---|
| `pinch(withScale: 2, velocity: 2)` | Lands 6.6 points apart at the centre, on a line at 45°; ends 28.3 apart (ratio 4.3) | Lands 7.2 apart, line at **68°**; ends 27.9 apart (3.9) | Lands 7.8 apart, line at **20°**; ends 27.6 apart (3.5) |
| `pinch(withScale: 0.5, velocity: -2)` | Lands in two opposite corners, 402.6 apart, line at 45°; ends 205.3 apart (0.51) | Corners, line at **24°** (0.51) | Corners, line at **68.5°** (0.51) |
| `rotate(.pi / 3, withVelocity: 2)` | Lands 94.9 apart on a line at 18.4°, turns to about 48°, ends 89.7 apart (0.95) | The same | The same |
| `twoFingerTap()` | Two fingers at the ends of the longer side, 5 points inside | The same | The same |

So the line through the fingers of a synthesised pinch can be steered only by the shape of the element: a pinch that
closes runs along the element's diagonal, a pinch that opens across it. The scale XCUITest is asked for is not the
ratio of the finger distances.

---

## 3. What the gestures report

### 3.1 `SpatialEventGesture` (iOS 18 and later)

On iOS 18.6 and 27.0:

- `onChanged` is handed both touches from the moment they land, each with an identifier that stays the same, the
  phase `active` and its location in the view; then both again with every move. `onEnded` is handed both with the
  phase `ended` and their last locations.
- The line through the two first locations is the finger line when the pinch begins; the ratio of the distances is
  the scale; the middle is the centroid. A single finger is reported the same way, alone.

### 3.2 `MagnifyGesture` with a simultaneous `DragGesture` (the path of iOS 17)

The same on iOS 17.5, 18.6 and 27.0. In a gesture of two fingers that land together (pinch, rotation):

- **The pinch half has a value from the first callback to the last.** `startLocation` is the middle of the two
  fingers when they land (the centroid), `startAnchor` the same as a unit point, `magnification` the ratio of the
  finger distances (it ends at the ratio the touches show, 3.89 for 3.895).
- **The drag half has no value, from the first callback to the last** (`value.second == nil`), `onEnded` included.
- Beside the touches of `SpatialEventGesture` on the same view the pair reports the same.

In a drag of one finger the pinch half has no value and the drag half reports the finger: its start location, its
location and its translation. A two-finger tap calls nothing.

### 3.3 `MagnificationGesture` with a simultaneous `DragGesture` (the path of iOS 15 and 16)

The same on iOS 17.5, 18.6 and 27.0, and the same as 3.2 with less: the pinch half is the scale alone (no
location), and in a gesture of two fingers that land together the drag half has no value at any time. In a drag of
one finger the drag half reports the finger.

### 3.4 The pinch and the drag as two gestures

With callbacks of their own (`.gesture` and `.simultaneousGesture`), on all three runtimes: in a two-finger gesture
only the pinch calls, in a one-finger drag only the drag. There is no order of callbacks to speak of, and nothing to
say about "both recognising": when the fingers land together the two never report in the same gesture.

### 3.5 What stays unobserved

What the drag half reports **when the first finger lands before the second**, which is what a hand does most of the
time: whether the drag goes on with the first finger's start location, as the table of PINCH-8 assumes, or ends when
the second finger lands. No public API of XCUITest produces it.

---

## 4. The package's own paths under synthesised touches

`PinchScreenUITests` pinches the spectrogram of the gallery's pinch screen, on which `.pinchScaling([.horizontal,
.vertical])` is set and the time span and the frequency range are bound to the screen's state.

| Runtime | Path the package installs | `pinch(withScale: 2, velocity: 2)` | `pinch(withScale: 0.5, velocity: -2)` |
|---|---|---|---|
| iOS 27.0 | `SpatialEventGesture` | Time span 4 s → 0.9947 s; range unchanged | Range 40 … 20 000 Hz → 20 … 24 000 Hz, its limit; span unchanged |
| iOS 18.6 | `SpatialEventGesture` | Time span 4 s → 0.9987 s; range unchanged | Range 40 … 20 000 Hz → 20 … 24 000 Hz; span unchanged |
| iOS 17.5 | `MagnifyGesture` with a `DragGesture` | **Nothing**: span 4 s → 4 s, range unchanged | **Nothing** |

- **iOS 18.6 and 27.0.** The view is taller than wide, so the fingers of the pinch that opens land on a flat line
  and those of the pinch that closes on a steep one (section 2). The first scales the time span alone, by the ratio
  of the finger distances; the second scales the frequency range alone, and the range stops at the feed's axis when
  the fingers lift. That is PINCH-3, PINCH-4 and PINCH-6 as written, through real gestures.
- **iOS 17.5.** The pinch reaches the tracker as `.magnification(scale:start:firstFingerStart: nil)`: the drag half
  has no value (3.2). `PinchTracker.update` then has no finger line; with one axis enabled it would take that axis,
  with two it returns `nil` (`Pinch/PinchTracker.swift`, lines 110 to 116), and nothing scales, for the whole pinch.
  The test records this as an expected failure on iOS 17.

The path of iOS 15 and 16 (`MagnificationGesture`) is never installed on the runtimes that could be run, and a UI
test cannot ask for it. Given what the gesture reports (3.3), it would behave as the path of iOS 17 does: the tracker
waits for a travel of the first finger that never comes (lines 122 to 133).

---

## 5. The table of PINCH-8

| Row | Verdict |
|---|---|
| iOS 18 and later: `SpatialEventGesture`, both touch locations | **Confirmed** on iOS 18.6 and 27.0 (3.1, 4). |
| iOS 17: `MagnifyGesture` with a simultaneous `DragGesture`; from the pinch's start location (the centroid) to the first finger's start location | **The first half confirmed, the second corrected for one case and unobserved for the other.** The pinch's start location is the centroid. The first finger's start location is not to be had when the two fingers land together: the drag reports nothing. When the first finger lands first: not observable (3.5). |
| iOS 15 and 16: `MagnificationGesture` with a simultaneous `DragGesture`; the direction the first finger travels in its first 8 points | **Not confirmed.** On iOS 17.5, 18.6 and 27.0 the drag reports nothing when the two fingers land together, so there is no travel to read. When the first finger lands first: not observable. iOS 15 and 16 themselves: not observable. |

**The table, corrected** (changes in *italics*):

| OS | Gestures | The finger line |
|---|---|---|
| iOS 18 and later | `SpatialEventGesture` | Both touch locations |
| iOS 17 | `MagnifyGesture` with a simultaneous `DragGesture` | From the pinch's start location (the centroid) to the first finger's start location, *which the drag reports only when the first finger lands before the second. When both land together the drag reports nothing for the whole pinch, and the finger line is not known.* |
| iOS 15 and 16 | `MagnificationGesture` with a simultaneous `DragGesture` | The direction the first finger travels in its first 8 points; nothing scales until then. With one axis enabled, that axis is used at once. *When both fingers land together the drag reports nothing, and the finger line is not known.* |

*A pinch whose finger line is not known scales every enabled axis.*

*(WP-818: the first row was confirmed on iOS 18.6 and 27.0. For iOS 17.5, 18.6 and 27.0 it was confirmed that the pinch
half of each pair reports the centroid and the scale, and found that the drag half reports nothing when the fingers
land together. What the drag reports when the first finger lands first could not be produced by a test and remains an
assumption. iOS 15 and 16 could not be run.)*

The sentence about a pinch whose finger line is not known is a proposal, and the owner's to decide. The other reading
of PINCH-3 is the one the package has now, "such a pinch scales nothing", which leaves a component with both axes
enabled without a pinch whenever two fingers land in the same moment. A line between 30° and 60° already scales both
axes; treating an unknown line the same way keeps the pinch alive at the price of scaling an axis the fingers did
not mean.

---

## 6. The lines of `Sources/ZTronDSPUI` that would change

| File, lines | Now | Change |
|---|---|---|
| `Pinch/PinchTracker.swift` 108–120, `case .magnification` | Without a first finger (`firstFingerStart == nil`) the pinch takes the one enabled axis, or, with both enabled, returns `nil` for good (110–116) | Without a first finger at the first report, the pinch takes every enabled axis (`decided = enabled`). |
| `Pinch/PinchTracker.swift` 122–137, `case .legacy` | Without a travel of the first finger (`firstFingerTravel == nil`) the pinch takes the one enabled axis, or waits for a travel of 8 points that never comes (124–133) | When the drag reports nothing (`firstFingerTravel == nil`), the pinch takes every enabled axis at once, with a reference scale of 1. A travel that is there but shorter than 8 points is waited for, as now. |
| `Pinch/PinchTracker.swift` 48–52, the table in the type's documentation; `Pinch/PinchGestureModifier.swift` 103–107, the same | State the two rows as assumptions | State them as corrected above. |
| `Pinch/PinchGestureModifier.swift` 206–214 `magnifyGesture`, 216–224 `legacyGesture` | Hand `value.second?.startLocation` and `value.second?.translation` on, which are `nil` | Unchanged. |
| `Tests/ZTronDSPUITests/PinchTrackerTests.swift` | Scripted samples with a first finger for both paths | Add the samples the gestures really deliver when the fingers land together: no first finger, both axes enabled. |

If the owner decides that an unknown finger line scales nothing, no line changes, and the documentation of
`.pinchScaling(_:)` has to say that before iOS 18 a pinch with both axes enabled needs the first finger to land first.

---

## 7. What could not be observed

- **A second finger that lands after the first**, and fingers that move on paths of their own (section 2). A hand on
  a device, or private event synthesis, is needed.
- **iOS 15 and 16.** What `MagnificationGesture` with a `DragGesture` reports there is taken from iOS 17.5, 18.6 and
  27.0, where the gesture still exists.
- **A device.** Simulators only.

---

## 8. What was changed in the package afterwards

Written on 2026-11-17, after the spike, when the correction was made (change request CR-027, proposed). Sections 1
to 7 are left as they were written: they describe the package before the change.

**The reading that was taken** is the proposal of section 5: *a pinch whose finger line is not known scales every
enabled axis*. Where the first finger does land first, the rows of the table stand as they were written.

| File | What changed |
|---|---|
| `Sources/ZTronDSPUI/Pinch/PinchTracker.swift`, `case .magnification` (lines 120 to 138) | A report without a first finger (`firstFingerStart == nil`: the drag is silent) decides at once: the pinch takes every enabled axis. A first finger that is known decides by the line from the centroid to it, as before; one that lies on the centroid still names no line. |
| `Sources/ZTronDSPUI/Pinch/PinchTracker.swift`, `case .legacy` (lines 140 to 163) | A drag that is silent from the first report of a pinch on (`firstFingerTravel == nil`, and none was heard before in this pinch) decides at once: every enabled axis, with a reference scale of 1. A travel that is there but shorter than 8 points is waited for, as before, and a drag that has spoken once and falls silent decides nothing (`heardTheFirstFinger`). |
| `Sources/ZTronDSPUI/Pinch/PinchTracker.swift`, the type's documentation; `Pinch/PinchGestureModifier.swift`, the table (lines 103 to 112) | The table of PINCH-8 as corrected in section 5, and the paragraph on a finger line that is not known. |
| `Sources/ZTronDSPUI/Appearance/AppearanceModifiers.swift`, `.pinchScaling(_:)` | The documentation says what a pinch does before iOS 18 when both fingers land in the same moment: it scales every axis named. |
| `Tests/ZTronDSPUITests/PinchTrackerTests.swift` | `aPinchWhoseFingersLandTogetherScalesEveryEnabledAxisOnIOS17`, `aFirstFingerOnTheCentroidGivesNoLineOnIOS17`, `aPinchWhoseFingersLandTogetherScalesEveryEnabledAxisOnTheLegacyPath`: the samples the gestures really deliver when the fingers land together, beside those of the table. |
| `Tests/ZTronDSPUITests/HostedPinchTests.swift` | `aPinchWhoseFingerLineIsNotKnownScalesEveryEnabledAxis`, on the `MagnifyGesture` path and on the `MagnificationGesture` path: with both axes enabled the time span and the frequency range are both scaled. |
| `Examples/ZTronDSPGallery/GalleryUITests/PinchSpikeUITests.swift`, `PinchScreenUITests` | No expected failure any more: on iOS 17 a synthesised pinch on the pinch screen has to scale both the time span and the range. |

`Pinch/PinchGestureModifier.swift` hands on what the gestures report, as before: no line of the gesture code changed.

What stays as it was: what the drag reports when the first finger lands before the second is still unobserved
(section 3.5), and iOS 15 and 16 could not be run. What the gallery's pinch screen does on each runtime after the
change is in `Spikes/logs/after-correction/`.

