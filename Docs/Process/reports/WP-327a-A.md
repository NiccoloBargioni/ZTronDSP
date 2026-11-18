# Verifier report — WP-327a, lens A

| Field | Value |
|---|---|
| Package | WP-327a — `DynamicPipeline`: `append` under the tier-2 rules (ORD-5, ORD-6) |
| Lens | A (the first lens of the row: A, T) |
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
| An invalid append is rejected with the stage's path | `DynamicPipelineTests.appendingAppliesTheOrderRules` (`invalidStageOrder(stage: TestGain[2], found: spectrum)`; the pipeline is unchanged) | Debug ×3 and Release ×1: passed |
| A forged description is rejected with the stage's path | `aForgedDescriptionAndAnInvalidBranchAreRejectedWithTheirPath` (`Pipeline(unchecked:)` that claims samples: refused by `DynamicPipeline(_:)` and by `process`) | Debug ×3 and Release ×1: passed |
| An invalid branch is rejected with the stage's path | the same test (the path names the tap and the step inside it; a sink after a domain it cannot hold; a valid branch leaves the main line) | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- CR-015 item 10 describes the code: an immutable `Hashable`, `Sendable` value with `let stages` and `let outputTag`; `appending(_:)` returns a new value, `append(_:)` is the mutating spelling (`self = try appending(…)`). Typed throws. Every public member is documented.
- ORD-6: tier 2 runs again at attach for every pipeline (`PlanCompiler.swift:163, 174`).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 | Shape of the API | `Sources/ZTronDSPCore/Pipeline/DynamicPipeline.swift:58-77` | `appending(contentsOf:)` has no mutating twin, the three others have; a reader of CR-015 item 10 expects the pairs to match. | non-blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
