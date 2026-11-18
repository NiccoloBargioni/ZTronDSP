# Verifier report — WP-320b, lens T

| Field | Value |
|---|---|
| Package | WP-320b — `DSPEngine.attach`; independent state per attachment (ATT-1); sink claims (ATT-5); re-plan on a format change (ATT-4) |
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
| One pipeline on three sources: three independent states | `EngineTests/onePipelineOnThreeSourcesKeepsThreeStates()` (a delay line of 5 on three different signals, each against its offline result) | pass |
| A second live writer of one sink is `sinkInUse` and attaches once the first detaches | `EngineTests/aSinkHasOneLiveWriter()` (also: one sink named twice, in a branch and on the main line); `ExecutionTests/aSinkHasOneWriter`, `aSinkThatRefusesItsClaimFailsTheAttachmentAndReleasesTheOthers`; `SessionUpdateTests/aBranchThatGoesTakesItsSinkAlong` | pass |
| A format change is survived | `SessionUpdateTests/aFormatChangeIsSurvived()`, `aPullSourceChangesFormatInTheMiddleOfItsStream()`, `aPipelineThatCannotRunAtTheNewFormatFails()` | pass |
| A sink that refuses its claim, through the engine (verifier's own check) | `VBScratchTests3/vb320b_aSinkThatRefusesItsClaimThroughTheEngine`, `vb320b_whatARefusedUpdateLeavesBehind`: `attach`, and `update` of a running session, with a sink whose `claim` throws | at `attach`: right (the sinks claimed before it are released, the registry is free). At `update`: **fails** when the new pipeline also moves a sink of the running plan (finding 1) |
| Other paths the suite does not execute (verifier's own check) | `vb320b_aFormatChangeToAFormatThatIsNotValid` (a running session, the source announces 0 Hz, then 44 100 Hz, then `start()`), `vb320a_aStartThatThrowsBehindAProcessedSource` (also: an engine with blocks of 0 frames) | pass: `failed` with the adapter's error; after the valid format and `start()` the source is prepared again, the session re-plans and runs at 44 100 Hz; a block size of 0 is a typed error |

## Lens checklist (§11.5)

- **T — tests and coverage.** One line changed at a time, behind a switch compiled into the verifier's checkout and turned on for one test process (`TEST_RUNNER_ZTD_MUTANT=<n>`); with the switch off the suite gives the baseline result. A change is "killed" when a test of the unmodified suite fails, "survives" when all 325 tests pass.
  - The line changed to confirm: `Sources/ZTronDSPCore/Feeds/FeatureSink.swift:134`, `if set.contains(sink.identity) || …` → the registry never refuses a claimed sink: killed by `aSinkHasOneLiveWriter`, `aSinkHasOneWriter`, `aPipelineThatDoesNotCompileLeavesTheRunningOne`. Also: `FeatureSink.swift:144` claims never released: killed (13 tests); `Engine/EngineCore.swift:244` no re-compilation on a format change: killed (`aFormatChangeIsSurvived` and three more); `:151` every source served by the first hub: killed (`onePipelineOnThreeSourcesKeepsThreeStates`, with a hang); `:948` no `.replanned(.formatChanged)`: killed. All restored.
  - COV-3 (line coverage of each file the package adds or changes, as the gate's changed-files mode applies it). `xccov`'s report of the package scheme lists no production file (`Scripts/coverage-gate.sh` ends with "nothing to measure" and `Scripts/ci.sh` records gate 6 as skipped), so the figures are read from the same profile with `llvm-cov`; its line counts equal `xccov`'s on every file both list. Three Debug runs of `ZTronDSPCoreTests` and `CZTronDSPTests` on an untouched copy of the tree, merged. No file of the tree carries a `coverage:ignore` mark. `EngineCore.swift` 92.0 % (1123 of 1220 lines) — **below 97.5 %**, `DSPEngine.swift` 93.3 % (42 of 45 lines) — **below 97.5 %**, `ControlContext.swift` 99.2 % (123 of 124 lines).
  - Seeded, deterministic, no synchronisation by sleep: yes; waits are bounded polls.
  - Negative paths: `sinkInUse` three ways and a pipeline that does not compile at the new format: tested. A sink that refuses its claim is tested off line only (`run(on:format:)`); the engine's own handling, at `attach` and at `update`, is executed by no test, and at `update` it is wrong (finding 1). An engine with a block size below 1 and a format the source cannot be adopted at: not tested (finding 2).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | ATT-5 on `update(_:)`; the documented contract of `update` ("a pipeline that does not compile leaves the running one as it is"); a result is wrong; T: negative paths are covered | `Sources/ZTronDSPCore/Engine/EngineCore.swift:869-872` (the running plan's slot is retired before the new plan's sinks are claimed), `:883-889` (the failure path does not bring it back) | `adoptSinks` marks every sink that the running plan writes and the new plan writes from another place as retired in the *running* plan, and only then claims the new plan's sinks. When a claim throws, the catch gives back what was claimed and rethrows; the running plan's slot stays retired. The update has failed, the session is `running` on its old plan, and one of that plan's sinks receives nothing any more. Verifier's `VBScratchTests3/vb320b_whatARefusedUpdateLeavesBehind`: running `Pipeline { Emit(to: keep); TestGain(2); Emit(to: good) }`; `update(Pipeline { Emit(to: keep); TestGain(3); Emit(to: Refusing()); TestDelay(1); Emit(to: good) })` throws `resourceAllocationFailed` from the refusing sink's `claim`. Afterwards, block by block: `keep` 128 → 192 → 256 samples, `good` 128 → 128 → 128; state `running`, installed generation 1. Only a later update that succeeds brings the sink back. The suite is green because no test sends a refused claim through the engine: `aSinkThatRefusesItsClaimFailsTheAttachmentAndReleasesTheOthers` runs off line, and `:883-889` are not executed. Resolve: retire the running plan's slots once every claim has succeeded, or clear `isRetired` for the moved sinks in the catch; a test of a refused claim through `attach` and through `update`. | blocking |
| 2 | T: COV-3 | `Sources/ZTronDSPCore/Engine/EngineCore.swift:65, 102-103, 158-159, 679-681, 883-889, 994-996` (this package's part of 97 lines), `Engine/DSPEngine.swift:40, 43, 99` | `EngineCore.swift` is at 92.0 % (1 123 of 1 220 lines) and `DSPEngine.swift` at 93.3 % (42 of 45); `ControlContext.swift` (99.2 %) and `FeatureSink.swift` (98.6 %) hold. Not executed, of what this package delivers: `:65` `attach` on an engine whose block size is below 1; `:102-103`, `:158-159` failures while the hub and the session are made; `:679-681` the format moved while the bindings were read; `:883-889` a refused claim (finding 1); `:994-996` a format change the source cannot be adopted at. The rest of the 97 lines belong to neighbours that share the file: restarts (WP-320a-B), a processed source whose pipeline cannot feed it (`:181-186`, `:219`), an update that is superseded or abandoned (`:733-750`), a full value queue (`:796-804`), new values for a gain cascade and for FIR taps (`:827-836`), the memory-pressure handler (`:1153-1155`). The verifier ran `:65` and `:994-996`: they behave. | blocking |

## Change requests filed (FIX-4)

None by this verifier.
