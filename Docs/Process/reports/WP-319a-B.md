# Verifier report — WP-319a, lens S

| Field | Value |
|---|---|
| Package | WP-319a — Analysis thread: creation, scheduling (RT-9), parked while no session runs |
| Lens | S — system integration (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (the task statement of the integrator; no separate brief file exists for the package)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: tests, lint, compile fixtures; coverage as stated below)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| Idempotent start / stop | `AnalysisThreadTests/startAndStopAreIdempotent()`; and the verifier's `VBScratchTests/vb319a_startTwiceMakesOneThread` (three `start()` calls, the loop observed through an injected clock: one thread ran it) | pass |
| No wake-up in one second while parked (probe counter) | `aThreadWithNothingToRunStaysParked()` (turn and park counters over one second), `anEngineWithoutRunningSessionsCausesNoWakeUps()` (0.5 s after `stop()`); verifier's `vb319a_theThreadIsParkedWhileItsSessionIsInterruptedOrFinished`: 0 turns in 0.3 s while interrupted, after the stream ended, after `detach()` | pass |
| Scheduling (RT-9) | verifier's `vb319_theAnalysisThreadInSteadyState` (on the thread itself: a time-constraint policy is in force, period 5.000 ms for a poll interval of 5 ms) and `VBScratchTests2/vb319a_aRefusedTimeConstraintKeepsTheQualityOfService` (a period the kernel cannot hold: `.qualityOfServiceOnly`, `qos_class_self()` = user-interactive, no policy) | pass |

## Lens checklist (§11.5)

- **S — system integration.**
  - Idempotent start, stop and detach: `RunnerThread.start()` and `stop()` are guarded by a lock and a nil check; started three times, one thread runs the loop; `stop()` joins it. `PipelineSession.start()`, `stop()` and `detach()` are idempotent (`SessionStateTests/idle`, `detached`).
  - Session ownership and parking: the engine makes the thread with the first session that starts and never before (`engine.analysisScheduling == .notStarted` after `attach`); it publishes an idle stage when the last session stops, when the source is interrupted, when the stream ends and when the last attachment is detached, and the thread then parks on a condition variable: 0 turns in every 0.3 s window measured.
  - Behaviour when the system refuses (RT-9): a refused time-constraint request leaves the thread at user-interactive quality of service and `DSPEngine.analysisScheduling` reads `.qualityOfServiceOnly`. That property is the whole of "the engine reports it": there is no session event and no log line.
  - CAP and MIC rules, permission paths, the table of §4.6: not applicable to this package.
  - Two seeded defects were tried against the unmodified suite: the thread created at utility quality of service (`RunnerThread.swift:115`) and a refused policy reported as granted (`:203`). Both survive; see findings 1 and 2.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | S / RT-9: created at user-interactive quality of service | `Sources/ZTronDSPCore/Engine/RunnerThread.swift:115`; `Tests/ZTronDSPCoreTests/AnalysisThreadTests.swift` | No test reads the thread's quality of service: with `.userInteractive` replaced by `.utility` all 325 tests pass. The behaviour is right in the reviewed tree (verifier's check: 0x21 on a thread whose policy was refused). | non-blocking |
| 2 | S / RT-9: a refused request is reported | `Sources/ZTronDSPCore/Engine/RunnerThread.swift:203`, `Engine/EngineCore.swift:32` | `.qualityOfServiceOnly` is asserted by no test (with the refusal reported as `.timeConstrained` all 325 tests pass), and `EngineCore.reportedScheduling` is declared and never read. The refusal path works (verifier's `vb319a_aRefusedTimeConstraintKeepsTheQualityOfService`). | non-blocking |
| 3 | S: idempotent start | `Tests/ZTronDSPCoreTests/AnalysisThreadTests.swift:16-30` | `startAndStopAreIdempotent` asserts `isRunning` only. With the guard of `RunnerThread.start()` removed (`RunnerThread.swift:107`: a second `start()` makes a second thread) this test still passes when run alone; the full suite notices through other tests. | non-blocking |
| 4 | S: tests do not synchronise with sleeps | `Tests/ZTronDSPCoreTests/AnalysisThreadTests.swift:38, 59` | Two fixed sleeps (1 s and 0.5 s). They are the measurement the acceptance asks for (no wake-up *in one second*), not a synchronisation; noted for completeness. | non-blocking |

## Notes

Line coverage of the package's main files, for the integrator (COV-3 belongs to lens T, which is not the lens of this report; measured as WP-315-B describes; the attribution of files to packages is the verifier's, the ledger records none): `RunnerThread.swift` 99.3 % (139 of 140 lines).

## Change requests filed (FIX-4)

None by this verifier.
