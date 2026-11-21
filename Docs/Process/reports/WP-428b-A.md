# Verifier report — WP-428b, lens N

| Field | Value |
|---|---|
| Package | WP-428b — Stability, minimum and linear phase; the numerical figures of §6.3.8 |
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
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass |
| Figures for the stress fixtures (WP-016) equal the recorded values | Probe `p428b` analysed the seven Butterworth stress fixtures (`StressFixture.filtersNearZero` + `filtersNearNyquist`) with `analysis(sampleRate:)`. `VerifierA/run-probe.sh p428b && python3 VerifierA/wp428b_figures.py` recomputes each figure independently: the margin from SciPy's `butter`; the round-off level as Σ over sections of the power gain from the section's node to the output times the rounding unit squared; and single against double with a float32 cascade of my own. It also compares them with the values recorded in `SystemAnalysisTests.swift:20-28` | The margin equals SciPy's to all 11 printed digits on all 7. The round-off level equals my node-injection sum on all 7: −82.647, −54.058, −34.746, −63.613, −124.122, −127.894 and −112.569 dB in single, and 174.6 dB lower in double. Single against double equals the recorded figures, and the recommended precision is the recorded one on all 7. My float32 model is a transposed direct form II, which is a different kernel from `vDSP_biquad`. It gives −29.8 to −121.5 dB, so it is not used as evidence for this figure; WP-433 measures the chosen path directly |
| Analog criteria use the half plane | Same probe: four analog designs (Chebyshev I low-pass, Butterworth high-pass, Chebyshev II low-pass, elliptic band-stop), a system with a right-half-plane zero, and poles on the imaginary axis | Margin −max Re p equal to mine on all six; stable and minimum-phase verdicts as the half plane gives them. The poles on the axis give margin 0 and not stable; the right-half-plane zero gives not minimum phase |

## Lens checklist (§11.5)

- **N — numerical correctness.** Every figure was recomputed independently and agrees. Edge cases: poles on the stability boundary, a right-half-plane zero, fixtures near 0 Hz and near Nyquist. The round-off figure is a level, as CR-018 item 7 describes. `isLinearPhase` for FIR systems was exercised through WP-432c (symmetric, antisymmetric and non-symmetric taps). No tolerance was loosened.

## Findings (VER-4)

None.
