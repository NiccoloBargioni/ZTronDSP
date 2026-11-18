# Verifier report — WP-330a, lens R

| Field | Value |
|---|---|
| Package | WP-330a — Activation in the plan compiler: constants resolved, fusion barrier (ACT-4, ACT-6) |
| Lens | R (the first lens of the row: R, N) |
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
| A `.bypassed` constant leaves no kernel | `PlanCompilerTests.aBypassedConstantLeavesNoKernel` (the neighbours fuse across the gap), `aBypassedConstantThatChangesTheDomainRemovesTheRestOfItsBranch`, `ExecutionTests.aConstantSwitchIsCompiledAway` (output, and the sink of a removed branch is not claimed) | Debug ×3 and Release ×1: passed |
| A bound stage is not fused with its neighbours | `PlanCompilerTests.aBoundStageIsNotFusedWithItsNeighbours`, `aBoundStageThatChangesTheDomainOrTheRateIsAGate` | Debug ×3 and Release ×1: passed |
| The content of a `Group(isActive:)` is | `theContentOfASwitchedGroupFusesInside` (two cascades in a switched group become one kernel with the switch; a kernel and an FIR become a region) | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **R — real-time safety and performance.**

- ACT-4 / SEL-3: constants are resolved in the walk; nothing of a constant reaches the plan, so the hot path pays nothing (`ztd_entry_run` tests the switch pointer only for bound stages, `ztd_plan.c`).
- Setups are created when the plan is compiled only; a bypassed stage is still lowered once for validation (its `lower` runs, its specs are dropped), which costs control-context time only.
- ACT-6: `fuse` never merges a kernel that carries a switch (`PlanCompiler.swift:239-246`).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | ACT-4 (".bypassed removes the stage"); REAL-5 | `Sources/ZTronDSPCore/Compiler/PlanCompiler.swift:101-103` | A constant bypass removes the stage's kernels and keeps what the stage did to the positional environment: its latency stays in every environment downstream (reported 37 frames, measured 0). The same finding as WP-322, finding 1; it lives in this package's code. | blocking |

**Finding 1, to reproduce or resolve.** Probe (fails in Debug and Release):

```swift
var impulse = [Float](repeating: 0, count: 1_000); impulse[0] = 1
let engine = DSPEngine(blockSize: 64)
let sink = CollectingSink<Samples>()
let session = try await engine.attach(Pipeline { TestDelay(37, isActive: false); TestGain(-1) }.emit(to: sink),
                                      to: BufferSource(impulse, sampleRate: 48_000))
let probe = OutputProbe(); engine.core.addProbe(probe, to: session.core)
try session.start(); _ = await session.reaches(.finished)
#expect(probe.samples.firstIndex { abs($0) > 0.5 } == 0)   // passes: the stage is gone
#expect(session.environment.latency == 0)                   // fails: 37 / 48 000
#expect(sink.environment?.latency == 0)                     // fails: 37 / 48 000
```

Cause: `PlanCompiler.walk` lowers a stage as if it were active, which moves the cursor past it, and for `.constant(false)`
(`PlanCompiler.swift:101-103`) drops its steps without putting the cursor back, so the latency (and anything else the stage
added to the environment) stays. To resolve: restore the cursor to `before` for a bypassed stage that keeps the signal.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
