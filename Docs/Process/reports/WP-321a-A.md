# Verifier report — WP-321a, lens R

| Field | Value |
|---|---|
| Package | WP-321a — `AnalysisNode`, the node schedule in the plan, `FeatureSink` |
| Lens | R (the first lens of the row: R, A) |
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
| Nodes run in declared order at their tap position | `ExecutionTests.nodesRunInDeclaredOrderAtTheirTapPosition` (framer, magnitude, mean in a tap after a gain; values, indices and times of 99 frames), `aBranchLeavesTheMainLineBitIdentical`, `aSinkLearnsWhatItsRowsAre`, `sequenceStagesRunOnAFeatureRateSequence` | Debug ×3 and Release ×1: passed |
| Allocation-free | `ExecutionTests.aPlanWithKernelsNodesBranchesAndSinksRunsWithoutAllocating` (1 000 blocks: kernels, three node kinds, two taps, a rate changer, four sinks), `StockKernelTests.tenThousandBlocksOfALiveSessionAllocateNothing`, `RegionSwitchTests.theSwitchAllocatesNothing` | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**

- RT-2: `ExecutionPlan.run` (`PlanRunner.swift:14-114`) walks a `ContiguousArray` of steps with `while`; one existential call per node per frame (`NodeSlot.process`, `PlanStructures.swift:181-185`), one class dispatch per emitted frame (`FrameDelivery.deliver`); `FrameWriter` is a value over storage the `NodeBox` allocated at plan creation (RT-3, RT-5). No lock, no logging, no `await` in `Engine/Run/` (lint clean).
- RT-3: nodes and their storage live in `NodeBox`es owned by plans; plans are retired through the slot and released by the control context (`PlanLifetimeTests.nothingIsFreedOnTheThreadThatRunsThePlan`, with the engine driven by hand).
- Setups are created when the plan is compiled only: `AnalysisStep.make` runs in `ExecutionPlan.init` on the control context.
- The walk does atomic reference counting per step and per session (enum payloads, `stage.sessions[index]`); no allocation follows from it (audits pass in Debug).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | G-13 / §5.11.1 (a sink of your own loses nothing against the stock ones); the other lens of this package | `Sources/ZTronDSPCore/Feeds/FeatureSink.swift:27-56`; `Pipeline/Structure.swift:212-220` | The stock sinks are reached through the internal `PlanSink`, which gives them what a public `FeatureSink` cannot have: the shape of the frames at the claim, a call on the control context after a write (`connect(attention:)` / `service()`, how `FeatureStream` wakes its consumer without doing so on the analysis thread), `clearForNewBranch` (SWAP-3), liveness (ACT-11) and the memory trim. A stream written outside the package has to poll or to break RT-2. | non-blocking |
| 2 | CR-015 item 11 | `Docs/API/ZTronDSPCore.txt` | Public types this package's surface needs and neither the specification nor the change request names: `FrameFormat`, `AnalysisStep`, `ScopeChange`, `SinkDescription`. | non-blocking |
| 3 | COV-3 (lens T of the row; definition of done, item 3) | `xcrun llvm-cov report` on the profile of the core tests | `Nodes/AnalysisNode.swift` 84.8 % of 59 lines; `Feeds/FeatureSink.swift` 98.6 %. The coverage gate itself measures nothing in this snapshot (see WP-317, finding 3). | non-blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
