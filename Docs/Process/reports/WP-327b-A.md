# Verifier report — WP-327b, lens A

| Field | Value |
|---|---|
| Package | WP-327b — `attach` and `update` for a `DynamicPipeline` |
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
| Equal stages give equal plans, typed or dynamic | `DynamicPipelineTests.equalStagesGiveEqualPlansTypedOrDynamic` (descriptions equal; lowered steps equal; the session's output equals the offline run) | Debug ×3 and Release ×1: passed |
| An update follows §5.5.4 | `aDynamicPipelineUpdatesLikeATypedOne` (equal: the plan stays; other values: the plan stays, generation 1; another topology: generation 2; a typed update equal to the dynamic one: no new plan) | Debug ×3 and Release ×1: passed |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**

- `DSPEngine.attach(_:to:)` and `PipelineSession.update(_:)` have the overload for `DynamicPipeline` that §4.5 writes; both hand `pipeline.stages` to the same internal path as the typed ones (`DSPEngine.swift:61-69, 136-143`), so there is one implementation.
- The compile fixture `valid/OrderRulesOfTheCore.swift` updates a session with a dynamic pipeline through public API.

## Findings (VER-4)

None.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None.
