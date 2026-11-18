# Verifier report — WP-319a, lens R

| Field | Value |
|---|---|
| Package | WP-319a — Analysis thread: creation, scheduling (RT-9), parked while no session runs |
| Lens | R (the first lens of the row: R, S) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Simulator `ztdsp-27-va` (iOS 27.0, arm64) on the host of §3. `ZTD_DEVICE=ztdsp-27-va Scripts/xc.sh test ZTronDSPCoreTests` four times in Debug (three runs: 325 of 325 passed; the first run failed one test, `AnalysisThreadTests.aRealTimePullSourceTakesAsLongAsItsSignal`, see WP-319b) and once with `ZTD_CONFIG=Release` (325 of 325 passed). `Scripts/lint-bans.sh`: clean. A "probe" is a test the verifier wrote in the checkout with the package's own test doubles (`TestStages.swift`, `EngineSupport.swift`); its body is given under the finding it supports.

| Check | How it was run | Result |
|---|---|---|
| Idempotent start / stop | `AnalysisThreadTests.startAndStopAreIdempotent` | Debug ×3 and Release ×1: passed |
| No wake-up in one second while parked (probe counter) | `aThreadWithNothingToRunStaysParked` (turn and park counters over one second), `anEngineWithoutRunningSessionsCausesNoWakeUps` (no thread before the first start; parked again after `stop()`) | Debug ×3 and Release ×1: passed |
| RT-9: user-interactive, time constraint of the poll interval, refusal reported | Probe: from a `FeatureCallback` on the analysis thread of a `DSPEngine(blockSize: 512)` at 48 kHz, `ztd_thread_get_time_constraint(&period)` | Policy in force, period 5.333 ms = the poll interval; `engine.analysisScheduling == .timeConstrained` (Release) |
| RT-2 on the real thread | Probe: the allocation probe opened on the analysis thread from a callback; 3 000 blocks through a gain, a `FeatureStream` and the callback | 0 allocations, 0 deallocations (Debug and Release): the wake-up of the control context from the thread allocates nothing |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**

- RT-9: the thread is created at `.userInteractive` (`RunnerThread.swift:115`) and asks for the policy with period = constraint = poll interval and half of it as computation whenever its list of hubs changes (`:196-204`); a refusal is readable as `DSPEngine.analysisScheduling == .qualityOfServiceOnly`. After a list becomes empty the policy is cleared, which leaves the thread outside any quality-of-service class while it is parked (`ztd_thread.h` says so).
- The thread parks on a mutex and a condition variable, between turns only; in steady state it sleeps with `mach_wait_until` and takes no lock.
- The control context waits for the thread by polling with `usleep` (`ControlWait`, `Handoff.swift:109-124`); the thread never waits for it.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | RT-2 / RT-3 and §5.7 ("allocations and lock acquisitions on the analysis thread, steady state: 0"), in Debug as CR-002 asks | `Sources/ZTronDSPCore/Engine/Run/HubRunner.swift:97-108`; `Engine/RunnerThread.swift:174-176`; `Engine/Handoff.swift:76-80`; `Engine/EngineCore.swift:346-356` | The real analysis thread frees memory when a stage is handed over while a session runs: 4 deallocations across 3 000 hand-overs and 2 across 300 plan exchanges in one Debug run of three; 0 in the other two and in Release. With `usleep(300)` after `stage.refresh()` there are 2 940 deallocations in 3 000 hand-overs and 374 across 300 exchanges. | blocking |
| 2 | RT-9, "the engine reports it" | `Sources/ZTronDSPCore/Engine/EngineCore.swift:32` | `reportedScheduling` is declared and never used; a refusal is not logged and raises no event, it can only be read from `analysisScheduling`. | non-blocking |
| 3 | RT-9, after the first park | `Sources/CZTronDSP/ztd_thread.c` (`ztd_thread_clear_time_constraint`), `Engine/RunnerThread.swift:196-204` | A thread that was granted the policy, parked, and is refused the policy the second time runs at the default time-share priority while `analysisScheduling` says `.qualityOfServiceOnly`. Read, not run: the simulator grants every request. | non-blocking |
| 4 | RT-3 at teardown | `Sources/ZTronDSPCore/Engine/RunnerThread.swift:110-113, 122-130` | The thread's closure holds the `RunnerThread`; `stop()` returns once the loop has left, so the last reference to the thread object, its schedule and whatever that still holds can be dropped by the exiting thread. Read, not run; nothing is processed any more at that point. | non-blocking |
| 5 | Robustness of the hand-over | `Sources/ZTronDSPCore/Engine/EngineCore.swift:349-351` | When the thread does not take a new stage within five seconds the control context logs a fault and goes on as if it had (it then works on what the thread may still touch). | non-blocking |

**Finding 1, to reproduce or resolve.** Probe: the allocation probe of `ZTronDSPTesting` opened on the real analysis thread, from inside a `FeatureCallback`
(`ztdt_alloc_audit_begin()` on one block, `ztdt_alloc_audit_end(token)` on a later one; the test target needs
`CZTronDSPTesting`).

```swift
let engine = DSPEngine(blockSize: 64)
let source = ManualPushSource(format: SignalFormat(sampleRate: 48_000))
let a = try await engine.attach(Pipeline().emit(to: callback), to: source)   // callback opens and closes the audit
let b = try await engine.attach(Pipeline { TestGain(2) }, to: source)
try a.start()                       // … open the audit …
for _ in 0 ..< 1_500 { try b.start(); source.write(block); b.stop() }        // 3 000 stage hand-overs while `a` runs
                                    // … close the audit …
```

Debug: 0 allocations and 4 deallocations in one run of three (2 deallocations across 300 `update(_:)` exchanges in the
same run); Release: 0. With one line of schedule perturbation, `usleep(300)` after `stage.refresh()` at
`HubRunner.swift:98`, the same probe counts 2 940 deallocations in 3 000 hand-overs and 374 across 300 exchanges.
Cause: `HubRunner.current` keeps a strong local to the stage it replaces (`HubRunner.swift:97`) across `refresh()`, which
retires it; `settle` (`EngineCore.swift:346-356`) drains the retire list as soon as the pending stage is taken, so the
thread's local can be the last reference. The same shape is in `RunnerThread.turn` (`RunnerThread.swift:174-176`) and in
`ColumnStore.writing` (`ColumnStore.swift:325-337`). To resolve: compare identities without holding the object across
`refresh()`, or let the consumer hand the old value to the retire list only when it has dropped its own reference.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
