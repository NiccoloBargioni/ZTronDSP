# Verifier report — WP-330b, lens R

| Field | Value |
|---|---|
| Package | WP-330b — Activation at run time: bypass or suspension by stage kind, for kernels and nodes; cold resume (ACT-3, ACT-10) |
| Lens | R (the first lens of the row: R, N) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-15, after CR-015 |
| Fix cycle | 0 |
| Verdict | `pass` |

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
| A suspended branch runs no kernel and no node (probe) | `BindingTests.aSuspendedBranchRunsNoNodeAndStartsColdWhenItResumes` (probe counters of the framer and the magnitude node stand still), `aBoundStageThatChangesTheDomainSuspendsWhatFollowsIt`, `PlanLifetimeTests.sharedFramingRunsOnlyWhileAConsumerNeedsIt`, `RegionSwitchTests.aSwitchedNodeKeepsTheSignalAlignedAndMakesNoClick` (an inactive stage does no work) | Debug ×3 and Release ×1: passed |
| Flipping a binding compiles nothing | the same tests (`session.core.generation == 1`, one node made) | Debug ×3 and Release ×1: passed |
| No stale frame after a resume | `aSuspendedBranchRunsNoNodeAndStartsColdWhenItResumes` (what comes out equals a fresh run on the signal from the resume; one more reset) | Debug ×3 and Release ×1: passed |
| Bypass by stage kind | `BindingTests.aWriteOffTheMainThreadIsSeenBySyncBindings` (a gain: 10 ms fade), `StockKernelTests.aSwitchedFilterWithLatencyKeepsTheSignalAligned`, `RegionSwitchTests` (four tests) | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**

- RT-2: a switch is applied at a block boundary from the SPSC queue (`SessionRunner.swift:145-156, 254-268`); `setSwitch` flips a cell, resets kernels and nodes in place and recomputes liveness, all without allocating (`RegionSwitchTests.theSwitchAllocatesNothing`, 6 × 200 blocks, Debug and Release). The active path of a bound kernel is one pointer test (`ztd_entry_run`); the 5 ns budget is WP-324's.
- ACT-8: one copy of the block per block while a stage with latency is active (`ztd_delay_feed`; `RegionSlot.capture` for a region).
- ACT-10: a branch or a gate that resumes is reset before its cell is turned on (`PlanRunner.swift:140-150`).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | Acceptance "runs no kernel and no node (probe)" | `Tests/ZTronDSPCoreTests/BindingTests.swift:78-106` | The suspended branches of the tests hold nodes only; no test has a kernel in a suspended branch and counts its calls. Read: a suspended segment is not entered at all (`PlanRunner.swift:43`), whatever it holds; WP-220 shows it for a switched kernel of a C plan. | non-blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
