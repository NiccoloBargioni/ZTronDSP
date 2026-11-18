# Verifier report — WP-330a, lens N

| Field | Value |
|---|---|
| Package | WP-330a — Activation in the plan compiler: constants resolved, fusion barrier (ACT-4, ACT-6) |
| Lens | N — numerical correctness (the second lens of the row in §12) |
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
| A `.bypassed` constant leaves no kernel | `PlanCompilerTests/aBypassedConstantLeavesNoKernel()`, `aBypassedConstantThatChangesTheDomainRemovesTheRestOfItsBranch()`, `ExecutionTests/aConstantSwitchIsCompiledAway()` | pass |
| A bound stage is not fused with its neighbours | `PlanCompilerTests/aBoundStageIsNotFusedWithItsNeighbours()` | pass |
| The content of a `Group(isActive:)` is | `PlanCompilerTests/theContentOfASwitchedGroupFusesInside()` | pass |
| The same constant one level down, and on the main line (verifier's own check) | `VBScratchTests/vb330a_constantOffInsideAGroupOrAReader`, `vb330a_constantOffRateChangerOnTheMainLine`, Debug and Release; `VBRiskyTests` three times | **fail**: findings 1 and 2 |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - The result matches the definition for a constant on a stage that keeps the domain and the rate: the stage is gone, its neighbours fuse across the gap, the output is that of the pipeline without it (bit-equal in `aConstantSwitchIsCompiledAway`).
  - It does not for a constant on a stage that changes the domain or the rate, in two places the suite does not visit: nested in a `Group` or produced by an `EnvironmentReader` (finding 1), and on the main line (finding 2). In both the plan runs stages on frames of a domain, a rate or a block size other than the one they were compiled for.
  - Edge cases of the lens (empty, one sample, silence, full scale, non-finite) do not bear on a compile-time decision; the two findings are independent of the signal.
  - No tolerance is involved.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | ACT-3, ACT-4: `.bypassed` removes "the remainder of its branch"; a result is wrong | `Sources/ZTronDSPCore/Compiler/PlanCompiler.swift:74, 103` (`suspended` is local to one call of `walk`), `:143` (reader), `:156` (group) | The flag that removes what follows a bypassed domain-changing stage lives in the `walk` that holds the stage. When that stage sits in a `Group`, or is what an `EnvironmentReader` produces, the flag ends with the inner walk; the stages after the group or reader stay in the plan and receive the frames of the point *before* the bypassed stage. `Pipeline { Tap { Group { TestFramer(frame: 64, hop: 16, isActive: false) }; Emit(to: sink); TestMagnitude() } }` with a sink of `Spectrum<LinearFrequency, ComplexValues>`, 2 560 samples in blocks of 64: lowered to `branch[emit, node:TestMagnitude]`; the sink is claimed for a linear-frequency axis of 33 bins and receives 40 blocks of raw samples (2 560 values); a `TestMagnitude` node is made and fed blocks of samples. The same with `EnvironmentReader { _ in TestFramer(…, isActive: false) }`: `branch[emit]`, sink claimed, 40 blocks of samples. With the stage written directly in the tap the branch is removed and the sink is not claimed (the committed tests cover only that). Reproduce: `VBScratchTests/vb330a_constantOffInsideAGroupOrAReader` in the verifier's checkout (it uses only the committed test stages), or the pipeline above through `run(on:format:)` with a `CollectingSink`. Resolve: carry the suspension out of a group and a reader into the enclosing walk (and out of nothing else: a tap ends it). | blocking |
| 2 | ACT-3: "everything after the stage when it sits on the main line"; a result is wrong; the plan's declared output contradicts what it delivers | `Sources/ZTronDSPCore/Compiler/PlanCompiler.swift:62, 93-103`; `Engine/ExecutionPlan.swift:86` (`.output` appended unconditionally); `Engine/EngineCore.swift:216-226`; `Engine/Run/PlanStructures.swift:81-85` | `Pipeline { TestGain(0.5); TestSubsample(by: 2, isActive: false); TestGain(3) }` lowers to `[gain]` and the plan ends in `.output` as always. (a) `process` returns 2 560 samples for 2 560 in, equal to the input × 0.5: the signal before the bypassed stage, at the old rate. The same pipeline with the switch bound and off returns 0 samples (the gate stops the main line), which is what ACT-3 says for both. (b) The lowered pipeline declares the output it would have had: 24 000 Hz and at most 33 frames per block. As a processed source — `source.processed(by: Pipeline { TestSubsample(by: 2, isActive: false) })` — the source reports 24 000 Hz, the session behind it is compiled for blocks of 33 frames (`session.environment.blockSize == 33`) and is handed blocks of 64 frames at 48 000 Hz (2 560 of 2 560 samples delivered, largest block 64). (c) A kernel behind that source is called with 64 frames on buffers allocated for 33 (48 after rounding to 16): `KernelRun.process` passes `block.frameCount` to `ztd_plan_run_range` and clamps only the view it returns (`VBRiskyTests`: 1 320 = 40 × 33 samples come out of a gain and a cascade; the 16 frames per block beyond the allocation are written past its end). Reproduce: `VBScratchTests/vb330a_constantOffRateChangerOnTheMainLine`, `VBRiskyTests/vb330a_aKernelBehindAProcessedSourceWhoseFormatIsWrong`. Resolve: a main line suspended by a constant delivers nothing, as one suspended by a binding does (no `.output`, or a closed gate), and the output position is the one before the suspension. | blocking |

## Notes

Line coverage of the package's main files, for the integrator (COV-3 belongs to lens T, which is not the lens of this report; measured as WP-315-B describes; the attribution of files to packages is the verifier's, the ledger records none): `PlanCompiler.swift` 97.4 % (375 of 385 lines) — **below 97.5 %**.

## Change requests filed (FIX-4)

None by this verifier.
