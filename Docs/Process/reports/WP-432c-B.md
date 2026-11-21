# Verifier report — WP-432c, lens A

| Field | Value |
|---|---|
| Package | WP-432c — `Filter(_:)` for an `IIRSystem` or an `FIRSystem`; the FIR response stages; FIR lowering (REAL-4) and latency |
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
| Measured response within 0.1 dB | `FilterStageTests/theMeasuredResponseOfAnIIRSystemIsItsAnalysis()`: worst 0.00018 dB. `theMeasuredResponseOfAnFIRFilterIsItsAnalysis()`: worst 0.016 dB. | pass |
| The direct and partitioned paths agree within −100 dB | `theDirectAndThePartitionedPathAgree()`. At 255, 257, 1 025 and 2 001 taps the worst disagreement is −120.9 dB. Both paths ran, and the plan chose each by length (REAL-4). | pass |
| Latency reported | `theLatencyOfALinearPhaseFilterIsReported()` passes. It asserts 49 samples for 100 taps, against the (K − 1)/2 = 49.5 of REAL-5. The verifier's probe (`pLensA.json`, `latencies`) gives: `LowPass(…, length: 101)` 50 samples; `length: 100` 48.99999999999999 samples, while its design states a delay of 49.5; `Filter(FIRSystem { Taps(100 values) })` also 48.99999999999999. | fails REAL-5 for an even length (finding 1) |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§6.3.7).**
    - `Filter(_:isActive:)` takes an `IIRSystem` or an `FIRSystem`, as in `Pipeline { Filter(hum); Filter(antiAlias) }`.
    - The fluent twin is `filter`.
    - The FIR response stages share the four names of §6.3.3.
  - **STG-1.**
    - Fluent modifier and `isActive:`: present.
    - The order matrix is current.
    - `DesignSystemFilterAfterASpectrum` fails with its sentence.
    - Latency: finding 1.
    - Settling time: K − 1 for the direct and the partitioned FIR (`ztd_fir.c:148`, `ztd_partitioned.c:285`).
    - Allocation audits: `aThousandBlocksOfEachFilterAllocateNothing()` and `StockPipelineAuditTests`, in Debug and Release.
  - **Typed errors at plan compile.**
    - `whatMakesNoFilterIsRejectedWhenThePlanIsCompiled()`.
    - `aTapChangeAtOneLengthKeepsThePlanAndIsCrossFaded()`.
    - `aSwitchedFilterWithLatencyKeepsTheSignalAligned()`.
  - **VIS-2.** `Stages/Filter.swift` (7) and `Systems/Realization.swift` (3 public declarations): all are documented with their threading context.
  - **Gates.** `Scripts/api-digest.sh --check`, `Scripts/check-dependency-graph.sh` and `Scripts/lint-bans.sh` pass.
  - **COV-3.** The package changes `FIRSystem.swift` (`latency(of:)`), `ResponseStages.swift` and `ResponseCore.swift` (the FIR response stages), and all three are below 97.5 % (findings 2 and 3).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (B-3) | REAL-5: "Each stage reports its latency: (K − 1)/2 for a linear-phase FIR … The sum is the environment's `latency`" | `Sources/ZTronDSPDesign/Systems/FIRSystem.swift:264–272` (`latency(of:)`, "rounded down for an even `K`"); used at `Sources/ZTronDSPDesign/Systems/Realization.swift:240`; asserted at `Tests/ZTronDSPDesignTests/SystemStageTests.swift:273–275` | An even-length linear-phase FIR reports (K − 1)/2 rounded down: 49 samples for K = 100 against a delay of 49.5. That puts the environment's `latency` half a sample short. The test comment at line 273 says the same: "An even length has a delay of half a sample more than its latency says". No change request covers it, whereas CR-019 item 3 recorded the corresponding departure for the STFT. Reproduce: `latencies.fir100` (48.99999999999999) against `latencies.fir100designDelay` (49.5) in `.build/vb/probe-out/pLensA.json`, after `VerifierB/run-probes.sh`; or `ZTD_DEVICE=ztdsp-27-vm4bb Scripts/xc.sh test ZTronDSPDesignTests/FilterStageTests/theLatencyOfALinearPhaseFilterIsReported()`, which asserts 49. Resolution: report (K − 1)/2 exactly in the environment's latency, which is a `TimeInterval`; or a change request that states the rounding. | blocking |
| 2 (B-7) | COV-3 | `Sources/ZTronDSPDesign/Systems/FIRSystem.swift:107, 117, 120, 125, 149–150, 232–235` | 91.94 % (114 of 124 lines). See WP-431d-B, finding 2. Reproduce with `VerifierB/coverage.sh gate`. | blocking |
| 3 (B-5) | COV-3 | `Sources/ZTronDSPDesign/Stages/ResponseCore.swift:103, 108, 124, 140`; `Sources/ZTronDSPDesign/Stages/ResponseStages.swift:396, 789–791, 804` | 97.33 % and 97.25 %. See WP-432a-B, finding 1. Neither lens of this row is T; the attribution is the verifier's. | blocking |

## Change requests filed (FIX-4)

None by this verifier.
