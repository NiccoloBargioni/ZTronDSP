# Verifier report — WP-438a, lens N

| Field | Value |
|---|---|
| Package | WP-438a — `Subsample(by:)` and `Upsample(by:)` stages |
| Lens | N (the first lens of "N, A") |
| Verifier | A, an independent agent session: not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/25-verifier-a-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output: this verifier produced it in the checkout (first row below); coverage is not part of this lens
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes `subsampleAndUpsampleAreTheToolkitFunctions`, `aRateChangerThatIsSwitchedOffSuspendsWhatFollows` and the allocation audit `aThousandBlocksOfTheRateChangersAllocateNothing` |
| ≡ the toolkit functions | Probe `p436p438`: 1 001 samples of seeded noise, in blocks of 37. `Subsample(by: M, phase: p)` for M = 1, 2, 3, 7 and p = 0, ⌊M/2⌋, M − 1; `Upsample(by: L)` for L = 1, 2, 3, 7. Each output is compared with `subsampled(_:by:phase:)` and `upsampled(_:by:)`. `VerifierA/run-probe.sh p436p438 && python3 VerifierA/wp436_438_rate.py` | Equal, bit for bit, in all 9 subsample runs and all 4 upsample runs. The counts are right: 501 and 500 for M = 2; 334, 334 and 333 for M = 3; 143 for M = 7; 1 001·L for an upsampler. `Upsample(by: L)` followed by `Subsample(by: L)` gives back the input bit for bit. A factor of 1 lowers to no kernel |
| The rates in the environment follow | The same probe: the environment after each stage | fs/M and fs·L exactly, including 6 857.142857… Hz for M = 7 and 336 kHz for L = 7 |
| Factors and phases at the edges | The same probe: `Subsample(by: 3, phase: 3)`, `(by: 3, phase: −1)`, `(by: 0)` and `(by: 5 000)`, lowered | The two phases outside 0 ..< 3 are accepted. The stage wraps them into range, as its documentation (`Stages/RateStages.swift:146`) and the toolkit function (`ZTronDSPCore/Toolkit/RateChange.swift:2-6`) both do; §6.12 sets no other rule. Factors 0 and 5 000 are rejected with a typed error: "a rate changes by a whole factor between 1 and 4096, not 0" |
| STG-1 | `Scripts/order-matrix.sh --check`, `Scripts/compile-fixtures.sh --build`, `Stages/Fluent.swift`, `Tests/OrderMatrix/stages.txt`; `Sources/CZTronDSP/ztd_rate.c:251-252, 297-298` | The matrix is current. The fixtures behave: `DesignRateChangerAfterASpectrum` with its sentence, and both stages in `DesignStagesOnSampledSequences`. Fluent `subsample(by:phase:isActive:)` and `upsample(by:isActive:)`. Latency 0, settling 0 |

## Lens checklist (§11.5)

- **N — numerical correctness.** Both stages are their toolkit functions exactly, across block boundaries that do not line up with the factor, and they undo each other exactly. Edge cases: factor 1, factor 7 (a rate that is not a whole number of hertz), the last phase, phases out of range, factors out of range. No tolerance was loosened.

## Findings (VER-4)

None.
