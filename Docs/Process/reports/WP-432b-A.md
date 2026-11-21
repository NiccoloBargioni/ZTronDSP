# Verifier report — WP-432b, lens N

| Field | Value |
|---|---|
| Package | WP-432b — `BandBoost`, `LowShelf`, `HighShelf` stages |
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
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the allocation audit `aThousandBlocksOfEachEqualiserAllocateNothing`, which covers a band boost, both shelves and the matched peak |
| As WP-432a: the running pipeline's measured response is within 0.1 dB of the analysis | Probe `p432` at 44.1 kHz ran each stage through the compiled plan in `.automatic`, `.single` and `.double`, with a 16 384-sample impulse: `BandBoost` of order 1 (+9 dB, one octave at 1 kHz), order 4 (−12 dB) and order 7 (+15 dB, 60 Hz wide at 150 Hz); `LowShelf` (300 Hz, −8 dB); `HighShelf` (6 kHz, +5 dB, `.q(0.9)`); and the `MatchedPeak` stage of WP-422 (15 kHz, +10 dB, half an octave). `python3 VerifierA/wp432_stages.py` compares the measured response with the analysis at 1 025 frequencies | `.automatic` and `.double`: worst 0.0001 dB. `.single`: worst 0.061 dB (order 7, where the measurement recommends double), so within 0.1 dB everywhere. The analysis agrees with NumPy's evaluation of the stages' zeros and poles within 2.6e-11 dB. The bandwidth forms behind these designs were measured independently under WP-431b |
| STG-1 | `Scripts/order-matrix.sh --check` and `Scripts/compile-fixtures.sh --build`; reading `Stages/Fluent.swift` and `Tests/OrderMatrix/stages.txt`; latency from the probe | The matrix is current and the fixtures behave, among them `DesignEqualizerAfterASpectrum` and `DesignEqualizerInAnFIRSystem`. Fluent `bandBoost` (two forms), `lowShelf`, `highShelf` and `matchedPeak`, each with a trailing `isActive:`. Latency 0 |

## Lens checklist (§11.5)

- **N — numerical correctness.** The measured responses agree with the analysis in every precision, including forced single. Edge cases: a narrow, low, high-order boost (60 Hz at 150 Hz, order 7), a cut, and a shelf given by Q. No tolerance was loosened.

## Findings (VER-4)

None. (The forced-single figure of CR-018 item 2 is A-B2, reported under WP-432a.)
