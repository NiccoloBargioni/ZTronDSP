# WP-902d — implementer's report (coverage closure, part d: `ZTronDSPUI`, and WP-902's check)

| Field | Value |
|---|---|
| Package | WP-902d, the fourth and last part of WP-902 (split by CR-034, §11.7): every file of `ZTronDSPUI` at 97.5 % or more, or named with its reason; and WP-902's own acceptance, unchanged: **COV-2 holds**; lenses T, A |
| Implementer | Implementer M9-coverage (agent), brief 66 with the common rules of brief 60 |
| Date | 2026-11-22; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `74d44f6`; nothing of this part changes a file of the target |
| Ledger | WP-902d `Verifying`, implementer `Implementer M9-coverage (agent)`; its backlog names the file, its lines and the device run |
| Change request | CR-034, the split (`Proposed`) |

The measurement (how, the denominator, the table of every file) is in `impl-WP-902a.md`, section 1; the
gates and tests of the package in `impl-WP-902.md`.

## 1. The target

`ZTronDSPUI` is at **99.64 %** (2 238 of 2 246 lines) in run 1 and in run 2, above the 95 % of COV-2. One of
its 30 files is below 97.5 %, `Pinch/PinchGestureModifier.swift`, at 92.86 % (104 of 112 lines). Its eight
lines not run, read from the per-line report of run 2 (`xcrun xccov view --archive`):

| Lines | What they are | What runs them | Why the coverage run does not |
|---|---|---|---|
| 95 | `PinchPath.current` on iOS 17: `return .magnify` | any surface with a pinch enabled and no path forced, on iOS 17 | The coverage run is on iOS 27.0 (COV-1's run; in CI, gate 6 runs in the job of iOS 27.0 only), where line 94 returns first. iOS 17.5 is in the simulator matrix, but no coverage is taken there. |
| 96 | `PinchPath.current` on iOS 15 and 16: `return .legacy` | iOS 15 or 16 | E-17: the matrix hosts neither; the device run. |
| 215–217 | The change handler of the iOS 17 gestures (`MagnifyGesture` with a simultaneous `DragGesture`): the `PinchSample` it makes of a moving pinch | a real two-finger pinch on the iOS 17 path | The hosted tests force each path (`.environment(\.dspPinchPath, path)`, `HostedPinchTests.everyPathInstallsItsGesturesAndHearsAPinch`), so the gestures are built here (lines 211–214 and 218 ran 6 times), and then feed the samples a gesture would make through the module's seam, `PinchScript` (WP-819), which hands them to the modifier past the gesture. SwiftUI calls a gesture's handlers only for a touch. The gallery's UI tests on 17.5 drive this path with a pinch, without coverage (integration of 2026-11-21, its 2.5 and 2.6). |
| 225–227 | The change handler of the iOS 15 and 16 gestures (`MagnificationGesture` with a simultaneous `DragGesture`) | a real two-finger pinch on the legacy path | As 215–217; the OS's own path only on iOS 15 and 16 (E-17); the gallery cannot force a path (the environment value is internal). |

What the line count does not show, from the same report's sub-ranges: the handlers that share a line with the
call that installs them did not run either. Lines 206 and 207 (the `SpatialEventGesture` of iOS 18 and later,
the OS's own path here) ran 35 times as lines, and their closures `{ events in events.forEach { touched(…) } }`
and `{ _ in lifted() }` 0 times; the same for the `onEnded` closures of lines 218 and 228. The gate counts
lines (COV-1), so these are covered for it; a real touch alone reaches them, as it does 215–217 and 225–227.
What the handlers hand on (`sampled`, `touched`, `lifted`, lines 184–199) runs through the seam, and the session,
the tracker and the scaling behind it are at 100 % (`PinchTracker.swift` 104 of 104, `PinchScaling.swift` 97 of 97).

The digests (`ZTronDSP-handoff/digests/`) name this file in no finding of any wave.

## 2. What this part did, and why

Nothing in the target. Brief 66, step 3, UI: "lines that need a real touch or an OS the simulator matrix
cannot host go to the ledger backlog as COV-3's exception says (measured in the device run), not to
`coverage:ignore`". The ledger's row of WP-820 already held these eight lines (the integration of 2026-11-21,
its 2.5, 2.8 and section 4, where the integrator chose not to mark them: "the lines are the gestures' whole
behaviour"). The row of WP-902d names them again, with the device run (WP-904b) that measures them and the
integrator as owner, and CR-034 says so ("Open blocking findings carried").

**Tests added**: none, so no line was mutated to see one fail. A hosted test has no way to put a touch on a
SwiftUI gesture: the seam the module gives it (`PinchScript`) is the way past the gesture, by design, and the
gestures' handlers are each one line from the gesture's value to a sample. **Marks added**: none (the brief
forbids them here). **Dead code deleted**: none (each line is a path of PINCH-8).

COV-3's exception, read to the letter, is for "a branch that can run only on an OS version the simulator
matrix cannot host (E-17)": that fits 96 and 225–227; line 95 runs on the 17.5 simulator, and 215–217 need
iOS 17 and a touch. Whether the exception holds for those two is the owner's decision 8 of the integration of
2026-11-21 ("accept it, or ask for a run that covers those lines"), still open; I did not take it. A run
that covers 95 and 215–217: the gallery's UI tests on 17.5 with `-enableCodeCoverage YES`, the per-line
report merged with the iOS 27.0 one (`Scripts/coverage-gate.sh` takes several `--report` files). I did not
run it here: the owner's decision is not taken, and the disk had 3.1 to 3.8 GB free.

## 3. WP-902's check: COV-2 holds

Run 2, the fresh instrumented run after part a's change: every test target in Debug on `ztdsp-27`
(iOS 27.0), 2026-11-22 04:10–04:15, `ZTD_DERIVED=$PWD/.build/ci ZTD_XCARGS="-enableCodeCoverage YES" Scripts/xc.sh build`,
then `ZTD_CONFIG=Debug ZTD_XCARGS="-enableCodeCoverage YES -resultBundlePath .build/ci-results/Debug.xcresult" Scripts/xc.sh test-only`
with the same derived data: 2 118 tests passed in nine targets, "** TEST EXECUTE SUCCEEDED **".

`TMPDIR=$PWD/.build/tmp/m9-coverage Scripts/coverage-gate.sh --xcresult .build/ci-results/Debug.xcresult --mode aggregate --mode per-target`,
the gate's own lines, exit 0:

```
coverage-gate: 17 lines marked coverage:ignore (0.07 % of the production lines, below 0.50 %)
coverage-gate: aggregate      99.55 % (25716 of 25831 lines), needs 97.50 %: ok
coverage-gate: CZTronDSP        99.79 % (2344 of 2349 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPCore     99.69 % (8415 of 8441 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPDesign   98.70 % (4703 of 4765 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPMetal    100.00 % (1445 of 1445 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPAnalysis 99.85 % (5418 of 5426 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPIO       99.48 % (1153 of 1159 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPUI       99.64 % (2238 of 2246 lines), needs 95.00 %: ok
coverage-gate: ZTronDSP         no executable lines (0 of 0 lines), needs 95.00 %: ok
coverage-gate: pass (aggregate, per-target)
```

`Scripts/ci.sh --gate 6` on the same bundle (it finds `.build/ci-results/Debug.xcresult`), exit 0, the same ten
lines of the gate between "ci: [gate 6] coverage: aggregate and per target (COV-2)" and
"ci: [gate 6] ok: coverage: aggregate and per target", then "ci: gate 6  coverage                             passed"
and "ci: no gate failed". Without a list of changed files it says "COV-3 was not checked"; with
`ZTD_CI_CHANGED_FILES=Sources/CZTronDSP/ztd_thread.c` (the one source this package changes) it prints
"coverage-gate: Sources/CZTronDSP/ztd_thread.c                     100.00 % (62 of 62 lines), needs 97.50 %: ok",
"coverage-gate: pass (changed-files)" and "ci: no gate failed".

COV-3's exception says the device run "is merged before COV-2 is evaluated". It has not been made (WP-904b).
No production source has a branch for the simulator (`targetEnvironment`, `TARGET_OS_SIMULATOR`: none under
`Sources/`), so a device run adds no executable line of its own and merging it can only add covered lines:
COV-2 holds after the merge too. That is a reading, not a measurement.

## 4. Every file of the target, run 2

| File | Executable lines | Covered | Line coverage | Lines not run |
|---|---:|---:|---:|---|
| `Sources/ZTronDSPUI/Analysis/AnalysisEnvironment.swift` | 6 | 6 | 100.00 % |  |
| `Sources/ZTronDSPUI/Analysis/AnalysisModifiers.swift` | 15 | 15 | 100.00 % |  |
| `Sources/ZTronDSPUI/Analysis/SourceRecipes.swift` | 33 | 33 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/AppearanceEnvironment.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/AppearanceModifiers.swift` | 39 | 39 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/FeedShape.swift` | 36 | 36 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/RowLayout.swift` | 119 | 119 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/SurfaceAppearance.swift` | 124 | 124 | 100.00 % |  |
| `Sources/ZTronDSPUI/Axes/AxisTicks.swift` | 88 | 88 | 100.00 % |  |
| `Sources/ZTronDSPUI/Axes/AxisViews.swift` | 131 | 131 | 100.00 % |  |
| `Sources/ZTronDSPUI/Axes/FeedShapeWatcher.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPUI/Bridge/MetalViewRepresentable.swift` | 46 | 46 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/HeatmapSurface.swift` | 67 | 67 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/HeatmapViews.swift` | 54 | 54 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/SourceFedSurface.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/SurfaceHost.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/WaveformView.swift` | 64 | 64 | 100.00 % |  |
| `Sources/ZTronDSPUI/Environment/DSPEnvironmentBridge.swift` | 50 | 50 | 100.00 % |  |
| `Sources/ZTronDSPUI/Hosting/AnimatableParameters.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPUI/Hosting/PipelineHost.swift` | 185 | 185 | 100.00 % |  |
| `Sources/ZTronDSPUI/Pinch/ComponentPinch.swift` | 46 | 46 | 100.00 % |  |
| `Sources/ZTronDSPUI/Pinch/PinchGestureModifier.swift` | 112 | 104 | 92.86 % **below 97.5 %** | 95–96, 215–217, 225–227 |
| `Sources/ZTronDSPUI/Pinch/PinchScaling.swift` | 97 | 97 | 100.00 % |  |
| `Sources/ZTronDSPUI/Pinch/PinchTracker.swift` | 104 | 104 | 100.00 % |  |
| `Sources/ZTronDSPUI/Scheduling/FrameClock.swift` | 26 | 26 | 100.00 % |  |
| `Sources/ZTronDSPUI/Scheduling/FrameScheduler.swift` | 76 | 76 | 100.00 % |  |
| `Sources/ZTronDSPUI/Scheduling/TurnEnd.swift` | 38 | 38 | 100.00 % |  |
| `Sources/ZTronDSPUI/Surface/MetalSurface.swift` | 38 | 38 | 100.00 % |  |
| `Sources/ZTronDSPUI/Surface/SurfaceCoordinator.swift` | 300 | 300 | 100.00 % |  |
| `Sources/ZTronDSPUI/Surface/SurfaceRenderer.swift` | 104 | 104 | 100.00 % |  |

## 5. Open

- `Pinch/PinchGestureModifier.swift`, the eight lines above, until the device run (WP-904b) or the owner's
  decision 8 of the integration of 2026-11-21 (backlog of WP-902d and of WP-820; owner: the integrator).
- Seen while reading the file's tests, not run: `HostedPinchTests.everyPathInstallsItsGesturesAndHearsAPinch`
  ends with `#expect(PinchPath.current == .touches, "this run is on iOS 18 or later")`, and CI's gate 5 runs every
  test target on iOS 17.5 too (`.github/workflows/ci.yml`, the matrix `iOS-17-5, iOS-18-6, iOS-26-5, iOS-27-0`).
  There `PinchPath.current` is `.magnify`, so the expectation would fail, three times (one per argument). The
  package's tests were run on 27.0 only, here and at the integration of 2026-11-21 (its 17.5 runs were the
  gallery's). Not this package's file (WP-819, WP-820); for the integrator.

## 6. Change requests and decisions

CR-034 (the split): the owner's approval is asked (§11.7). The exception for the lines of section 1 is the
owner's decision 8 of the integration of 2026-11-21, which this part repeats and does not take.
