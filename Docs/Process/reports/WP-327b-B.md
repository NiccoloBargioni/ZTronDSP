# Verifier report — WP-327b, lens T

| Field | Value |
|---|---|
| Package | WP-327b — `attach` and `update` for a `DynamicPipeline` |
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
| Equal stages give equal plans, typed or dynamic | `DynamicPipelineTests/equalStagesGiveEqualPlansTypedOrDynamic()` (equal descriptions, equal lowered steps, and the engine's output of the dynamic pipeline against the offline output of the typed one) | pass |
| An update follows §5.5.4 | `aDynamicPipelineUpdatesLikeATypedOne()` (equal: the plan stays; other values: the plan stays, generation 1; another topology: generation 2; then a typed update equal to it: nothing) | pass |

## Lens checklist (§11.5)

- **T — tests and coverage.** One line changed at a time, behind a switch compiled into the verifier's checkout and turned on for one test process (`TEST_RUNNER_ZTD_MUTANT=<n>`); with the switch off the suite gives the baseline result. A change is "killed" when a test of the unmodified suite fails, "survives" when all 325 tests pass.
  - The line changed to confirm: `Sources/ZTronDSPCore/Engine/DSPEngine.swift:68`, `attach(_: DynamicPipeline…)` drops the last stage: killed by both tests. `:142`, `update(_: DynamicPipeline)` does nothing: killed by `aDynamicPipelineUpdatesLikeATypedOne`. Restored.
  - COV-3 (line coverage of each file the package adds or changes, as the gate's changed-files mode applies it). `xccov`'s report of the package scheme lists no production file (`Scripts/coverage-gate.sh` ends with "nothing to measure" and `Scripts/ci.sh` records gate 6 as skipped), so the figures are read from the same profile with `llvm-cov`; its line counts equal `xccov`'s on every file both list. Three Debug runs of `ZTronDSPCoreTests` and `CZTronDSPTests` on an untouched copy of the tree, merged. No file of the tree carries a `coverage:ignore` mark. `DSPEngine.swift` 93.3 % (42 of 45 lines) — **below 97.5 %**, `DynamicPipeline.swift` 98.0 % (50 of 51 lines).
  - Seeded, deterministic, no synchronisation by sleep: yes; the update test runs on the hand-driven engine.
  - Negative paths: `SessionStateTests/detached` (`update` on a detached session throws); an invalid dynamic pipeline cannot be built, so it cannot reach `update`.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | T: COV-3 | `Sources/ZTronDSPCore/Engine/DSPEngine.swift:40, 43, 99` | `DSPEngine.swift`, which holds this package's two methods (`attach(_: DynamicPipeline, to:)` at line 68, `update(_: DynamicPipeline)` at line 142), is at 93.3 % (42 of 45 lines). The three lines are one-line accessors no test reads: `DSPEngine.blockSize`, `DSPEngine.crossovers`, `PipelineSession.id`. Both methods of the package are executed and `DynamicPipeline.swift` is at 98.0 %. COV-3 is a rule about the files a package changes, so it does not hold here; this is the only finding. Resolve: three assertions (an engine reports the block size and the crossover table it was made with; two sessions have different `id`s). | blocking (COV-3 only; the lines are WP-320a's and WP-320b's) |

## Change requests filed (FIX-4)

None by this verifier.
