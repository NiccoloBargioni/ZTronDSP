# Verifier report — WP-438b, lens N

| Field | Value |
|---|---|
| Package | WP-438b — `Interpolate(by:)` stage |
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
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes `interpolationIsZeroStuffingThenTheFilterWithGainTheFactor`, `theImagesOfAnInterpolatedToneAreEightyDecibelsDown`, `interpolationAfterDecimationRestoresABandLimitedSignal` and the allocation audit `aThousandBlocksOfTheRateChangersAllocateNothing` |
| Image rejection ≥ 80 dB | Probe `p436p438`: the kernel of `Interpolate(by: L)` for L = 2, 3, 4, 5, 8 at 48 kHz. The taps' response is computed here on a 2²⁰-point grid and read from the input's Nyquist frequency up, against the pass-band gain L. `VerifierA/run-probe.sh p436p438 && python3 VerifierA/wp436_438_rate.py` | K = 105, 157, 209, 261, 417, with K − 1 a multiple of 2L. The taps sum to 1 and the kernel applies the gain L. The images are 81.02, 80.23, 80.39, 80.49 and 80.65 dB down |
| ≡ zero-stuff, then filter with gain L | The same probe: 1 200 samples of seeded noise per factor, in blocks of 512 and of 37, and through `DSP.interpolate`. The input is zero-stuffed here and filtered with L times the taps in float64 | Every output agrees within 1.77e-7, 1.50e-7, 1.13e-7, 1.73e-7 and 1.67e-7 of the output's peak, at both block sizes and offline. There are N·L outputs. Environment after: rate fs·L exactly, and latency 26 input samples for every L, which is (K − 1)/2 output samples |
| `Interpolate` after `Decimate` restores a band-limited fixture to SNR ≥ 80 dB | My own fixture: five tones at 0.07, 0.31, 0.52, 0.66 and 0.78 of the low Nyquist frequency fs/2M, 0.18 each, 48 000 samples at 48 kHz, through `Decimate(by: M); Interpolate(by: M)` for M = 2, 3, 4 and 6 in blocks of 256. The output is compared with the input delayed by the reported latency, leaving out 4 000 samples at each end | SNR 85.42, 82.93, 82.62 and 82.33 dB. The reported latency (104, 156, 208 and 312 samples) is also the best alignment among ±3 samples. The rate is back at 48 kHz |
| STG-1 | `Scripts/order-matrix.sh --check`, `Scripts/compile-fixtures.sh --build`, `Stages/Fluent.swift`, `Tests/OrderMatrix/stages.txt`; `Sources/CZTronDSP/ztd_rate.c:192-193` | The matrix is current. The fixtures behave: `DesignRateChangerAfterASpectrum` with its sentence, and `Interpolate(by: 2, rejection: .decibels(90))` in `DesignStagesOnSampledSequences`. Fluent `interpolate(by:rejection:passband:isActive:)`. Latency (K − 1)/(2L) input samples; settling ⌈K/L⌉ − 1 input samples, the history of one polyphase branch |

## Lens checklist (§11.5)

- **N — numerical correctness.** The stage is its definition within Float32 rounding, measured against my own float64 reference. Both acceptance bounds are met for every factor tried. The smallest margins are 0.23 dB on the images (L = 3) and 2.3 dB on the round trip (M = 6). Edge cases: block size 37, L = 8, M = 6 in the round trip, a fixture reaching 0.78 of the pass band. `ALG`: the taps are those of `DSP.rateChangeTaps`, the tolerance scheme of WP-423. No tolerance was loosened.

## Findings (VER-4)

None.
