# Verifier report — WP-432b, lens A

| Field | Value |
|---|---|
| Package | WP-432b — `BandBoost`, `LowShelf`, `HighShelf` stages |
| Lens | A — API, architecture, platform (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/26-verifier-b-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced by this verifier: see `VerifierB/README.md`)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs on `ztdsp-27-vm4bb`:

- Debug, the whole design target: 334 tests, passed in two runs.
- Release with the verifier's probes: 344 tests, passed.

| Check | How it was run | Result |
|---|---|---|
| As WP-432a: the measured response is within 0.1 dB of the analysis | `EqualizerStageTests/theMeasuredResponseOfTheRunningPipelineIsTheAnalysis()`: worst 0.0021 dB. A forced `.single` where double is recommended deviates by 0.133 dB, which is recorded and not held. CR-018 item 2 describes exactly that. | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§6.3.5).**
    - The stages are `BandBoost(center:gain:bandwidth:order:…)` (or `rollOff:`), `LowShelf(midpoint:gain:slope:…)` and `HighShelf(midpoint:gain:slope:…)`, each with a trailing `isActive:`.
    - The fluent twins are `bandBoost`, `lowShelf` and `highShelf`.
    - `MatchedPeak`, with fluent `matchedPeak`, is a stage of its own, as CR-018 items 4 and 11 say.
  - **STG-1.**
    - Fluent modifiers and `isActive:`: the api-digest gate passes.
    - The order matrix is current.
    - `DesignEqualizerAfterASpectrum` fails with its sentence.
    - Latency 0.
    - Settling time: the cascade's, as WP-432a.
    - Allocation audits: `aThousandBlocksOfEachEqualiserAllocateNothing()` and `StockPipelineAuditTests`, in Debug and Release.
  - **Values.**
    - `aBoostAndItsCutInSeriesAreTheIdentity()`.
    - `theStagesEmitTheirDesignAndFollowTheRules()`.
    - `aGainAnimatedThroughZeroKeepsThePlanAndMakesNoClick()`: one plan, and CLICK-1 holds.
  - **VIS-2.** `Stages/EqualizerStages.swift` has 49 public declarations, all documented with their threading context.
  - **Gates.** `Scripts/check-dependency-graph.sh` and `Scripts/lint-bans.sh` pass.
  - **COV-3** (for information). `EqualizerStages.swift` is at 100 %.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | None | — |

## Change requests filed (FIX-4)

None by this verifier.
