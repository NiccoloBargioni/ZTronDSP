# Verifier report — WP-327a, lens T

| Field | Value |
|---|---|
| Package | WP-327a — `DynamicPipeline`: `append` under the tier-2 rules (ORD-5, ORD-6) |
| Lens | T — tests and coverage (the second lens of the row in §12) |
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
| An invalid append is rejected with the stage's path | `DynamicPipelineTests/appendingAppliesTheOrderRules()` (`invalidStageOrder(stage: TestGain[2], found: linear-frequency complex spectrum)`; the pipeline is left as it was) | pass |
| A forged description is rejected with the stage's path | `aForgedDescriptionAndAnInvalidBranchAreRejectedWithTheirPath()` (`Pipeline(unchecked:)` through `DynamicPipeline(_:)` and through `process`) | pass |
| An invalid branch is rejected with the stage's path | the same test (a `Tap` whose branch starts with a step its tap point cannot feed; the path leads into the branch) | pass |

## Lens checklist (§11.5)

- **T — tests and coverage.** One line changed at a time, behind a switch compiled into the verifier's checkout and turned on for one test process (`TEST_RUNNER_ZTD_MUTANT=<n>`); with the switch off the suite gives the baseline result. A change is "killed" when a test of the unmodified suite fails, "survives" when all 325 tests pass.
  - The line changed to confirm: `Sources/ZTronDSPCore/Pipeline/DynamicPipeline.swift:96`, the rule's refusal ignored (`stage.rule(tag) ?? tag`): killed by both tests. Also `:86` the path counted from 0 instead of from the stages already held: killed (`appendingAppliesTheOrderRules`); `:90` a branch not checked: killed (`aForgedDescription…`). Two more survive and are outside the three checks of the row: `:92` the content of a `Group` not checked, `:94` the content of an `EnvironmentReader` not checked (finding 1). All restored.
  - COV-3 (line coverage of each file the package adds or changes, as the gate's changed-files mode applies it). `xccov`'s report of the package scheme lists no production file (`Scripts/coverage-gate.sh` ends with "nothing to measure" and `Scripts/ci.sh` records gate 6 as skipped), so the figures are read from the same profile with `llvm-cov`; its line counts equal `xccov`'s on every file both list. Three Debug runs of `ZTronDSPCoreTests` and `CZTronDSPTests` on an untouched copy of the tree, merged. No file of the tree carries a `coverage:ignore` mark. `DynamicPipeline.swift` 98.0 % (50 of 51 lines).
  - Seeded, deterministic, no synchronisation by sleep: yes.
  - Negative paths: the package is its negative paths; three of five are tested.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | T: negative paths are covered | `Sources/ZTronDSPCore/Pipeline/DynamicPipeline.swift:91-94`; `Tests/ZTronDSPCoreTests/DynamicPipelineTests.swift:53-56` | An invalid stage inside a `Group` or produced by an `EnvironmentReader` that is appended to a `DynamicPipeline` is checked by the code and by no test: with either check removed all 325 tests pass. The test's comment "a sink after a domain it cannot hold (O-11), inside a group" appends a valid group and then an invalid sink on its own. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
