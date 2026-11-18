# Verifier report — WP-319b, lens T

| Field | Value |
|---|---|
| Package | WP-319b — Polling wake against an injected clock (§4.3); a thread of its own for an offline session |
| Lens | T — tests and coverage (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (the task statement of the integrator; no separate brief file exists for the package)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: tests, lint, compile fixtures; coverage as stated below)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| Wake-ups every half I/O buffer and never under 1 ms | `AnalysisThreadTests/pollingComesRoundEveryHalfBlockAndNeverUnderAMillisecond()`, `aPacedPullSourceIsAskedOncePerBlockDuration()`; two one-line changes of the code that computes the interval | tests pass; both changes survive (finding 1). Verifier's `VBScratchTests2/vb319b_…` through the engine: 5.333 ms for 512 frames at 48 kHz, 46.44 ms for 4 096 at 44.1 kHz, 1.000 ms for 64 at 48 kHz and for 16 at 192 kHz: the product is right |
| An offline session does not run on the analysis thread | `anOfflineSessionDoesNotRunOnTheAnalysisThread()` (thread identifiers seen by two callbacks) | pass; the change at `EngineCore.swift:301` is killed by it |

## Lens checklist (§11.5)

- **T — tests and coverage.** One line changed at a time, behind a switch compiled into the verifier's checkout and turned on for one test process (`TEST_RUNNER_ZTD_MUTANT=<n>`); with the switch off the suite gives the baseline result. A change is "killed" when a test of the unmodified suite fails, "survives" when all 325 tests pass.
  - The line changed to confirm: (1) `Sources/ZTronDSPCore/Engine/SourceHub.swift:61`, `max(0.001, Double(maximumFrames) / max(format.sampleRate, 1) / 2)` → `Double(maximumFrames) / max(format.sampleRate, 1) / 8`: **survives**. (2) `Engine/RunnerThread.swift:192`, `role == .analysis ? max(deadline, now + 0.001) : deadline` → `deadline`: **survives**. (3) `Engine/EngineCore.swift:301`, `if hub.isFreeRunning {` → never: killed by `anOfflineSessionDoesNotRunOnTheAnalysisThread`. (4) `Engine/Run/HubRunner.swift:127`, `return now + stage.interval` → `… * 2`: killed by `pollingComesRound…`. (5) `HubRunner.swift:144`, the paced step doubled: killed by `aPacedPullSourceIsAskedOncePerBlockDuration`. All restored.
  - COV-3 (line coverage of each file the package adds or changes, as the gate's changed-files mode applies it). `xccov`'s report of the package scheme lists no production file (`Scripts/coverage-gate.sh` ends with "nothing to measure" and `Scripts/ci.sh` records gate 6 as skipped), so the figures are read from the same profile with `llvm-cov`; its line counts equal `xccov`'s on every file both list. Three Debug runs of `ZTronDSPCoreTests` and `CZTronDSPTests` on an untouched copy of the tree, merged. No file of the tree carries a `coverage:ignore` mark. `RunnerThread.swift` 99.3 % (139 of 140 lines), `SourceHub.swift` 100.0 % (24 of 24 lines), `HubRunner.swift` 98.5 % (136 of 138 lines).
  - Seeded, deterministic, no synchronisation by sleep: the two clock tests are deterministic (a `TestClock`). `aRealTimePullSourceTakesAsLongAsItsSignal` is not: finding 2.
  - Negative paths: none specific to the package.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | T: the acceptance check exercises the code ("Wake-ups every half I/O buffer and never under 1 ms") | `Tests/ZTronDSPCoreTests/AnalysisThreadTests.swift:64-85`; `Sources/ZTronDSPCore/Engine/SourceHub.swift:60-62`; `Engine/RunnerThread.swift:192` | The test computes the interval itself (`let interval = max(0.001, Double(blockSize) / sampleRate / 2)`, line 72) and hands it to a `HubStage` and a `HubList` it builds by hand; it then checks that the thread sleeps for the interval it was given. The engine's own computation, `SourceHub.pollInterval`, is never called by an assertion: replaced by an eighth of a block without a floor, all 325 tests pass. The floor in `RunnerThread.turn` is not exercised either: every interval the test passes is already ≥ 1 ms, and removed, all tests pass. Reproduce: edit either line, run `ZTD_DEVICE=ztdsp-27-vb Scripts/xc.sh test ZTronDSPCoreTests`. Resolve: assert on the sleeps of an injected clock for a session attached through the engine (`EngineCore(blockSize:crossovers:clock:)` exists for this), for a block whose half is below 1 ms and one whose half is above; `VBScratchTests2/vb319b_theEnginePollsAtHalfABlockAndNeverUnderAMillisecond` does so and fails for change (1). | blocking |
| 2 | T: deterministic, no synchronisation by sleep | `Tests/ZTronDSPCoreTests/AnalysisThreadTests.swift:136-146` | `aRealTimePullSourceTakesAsLongAsItsSignal` asserts on wall-clock time (`elapsed > 0.25 && elapsed < 1.5` for 0.3 s of signal). It failed in 2 of 15 Debug runs of unmodified code, on a busy host: the first full run ("0.3 s of signal at real-time pacing took 2.4002299308776855 s") and the second of three coverage runs (`elapsed > 0.25 && elapsed < 1.5` at line 144). Its upper bound measures the load on the machine. Resolve: pace against the injected clock, as the two tests above do. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
