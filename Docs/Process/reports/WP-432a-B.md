# Verifier report — WP-432a, lens A

| Field | Value |
|---|---|
| Package | WP-432a — IIR filter stages: `LowPass` … `BandStop` as sequence stages, lowered to the cascade |
| Lens | A — API, architecture, platform (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

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
| The running pipeline's measured response is within 0.1 dB of the analysis | `IIRFilterStageTests/theMeasuredResponseOfTheRunningPipelineIsTheAnalysis()`: 240 comparisons, of 5 families × 4 orders × 4 responses × 3 precisions; worst 0.039 dB. `aLiveSessionMeasuresAsTheAnalysisPredictsOnSines()`: a session fed sines block by block; worst 0.00063 dB. | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§5, §6.3).**
    - The four values of WP-431a are `SequenceStage`s (`ResponseStages.swift:49, 246, 445, 649`), each with a `lower(_:)` that emits one cascade with its gain spread (REAL-1; `theStageEmitsOneCascadeWithItsGainSpreadAndNoLatency()`).
    - The fluent twins `lowPass`, `highPass`, `bandPass` and `bandStop` take the same labels (`theFluentSpellingAndTheBuilderGiveEqualPipelines()`).
  - **STG-1.**
    - Fluent modifier: present.
    - Trailing `isActive:`: `Scripts/api-digest.sh --check` reports "66 public initialisers of 43 stage types end in `isActive:`".
    - Order rules: `Scripts/order-matrix.sh --check` reports "52 stages on 21 domains, 110 cells accepted; the committed matrix is current". `DesignFilterAfterASpectrum` and its fluent twin fail with their sentences, and `theOrderRulesHoldInBothTiers()` passes.
    - Latency 0 (REAL-5).
    - Settling time: the 100 dB decay of the slowest pole (`ztd_biquad.c:16`). The verifier's exchange and restore of a `LowPass(10 Hz)` on a constant show no transient (`o434_alphabeta.py`, the control rows).
    - Allocation audits: `aThousandBlocksOfEachResponseAllocateNothing()` and `StockPipelineAuditTests`, in Debug and Release.
  - **Typed errors at attach time, with the stage path (O-16).**
    - `anEdgeIsCheckedAgainstTheNyquistFrequencyAtTheStagesPosition()`.
    - `aPoleOnOrOutsideTheUnitCircleDoesNotCompile()` (REAL-2).
    - The probe's `schemeBehindDecimate` is rejected "at LowPass[1]".
  - **Values and animation (ANI-2).**
    - `aCutoffAnimatedOverAnOctaveKeepsThePlanAndMakesNoClick()`.
    - `aBoundSwitchBypassesTheFilterWithoutAClick()`.
    - Fusion F2: `adjacentFiltersOfOnePrecisionFuseAndStayBitIdentical()`.
  - **VIS-2.** `Stages/ResponseStages.swift` (60) and `Stages/ResponseCore.swift` (3 public declarations): all are documented with their threading context.
  - **Gates.** `Scripts/check-dependency-graph.sh` and `Scripts/lint-bans.sh` pass.
  - **COV-3.** The package changes `ResponseStages.swift` and `ResponseCore.swift` (the stage conformances and `lower`), and both are below 97.5 % (finding 1).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (B-5) | COV-3 | `Sources/ZTronDSPDesign/Stages/ResponseCore.swift:103, 108, 124, 140`; `Sources/ZTronDSPDesign/Stages/ResponseStages.swift:396, 789–791, 804` | The files are at 97.33 % (146 of 150 lines) and 97.25 % (177 of 182 lines). The lines missed are rejections in the resolution of a value, and the members `HighPass.dependsOnSampleRate`, `BandStop.zeroPoleGain(sampleRate:)` and `BandStop.dependsOnSampleRate`. COV-3 counts per file, and this package changes both files. These are the merged figures of two instrumented runs. Reproduce with `VerifierB/coverage.sh gate`. The same finding stands against WP-431a and WP-432c. Neither lens of this row is T; the attribution is the verifier's. Resolution: tests for these lines, or COV-4(b) markers on branches that cannot be reached. | blocking |

## Change requests filed (FIX-4)

None by this verifier.
