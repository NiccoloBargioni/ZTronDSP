# Verifier report — WP-431b, lens N

| Field | Value |
|---|---|
| Package | WP-431b — Equaliser values `BandBoost`, `LowShelf`, `HighShelf` |
| Lens | N — numerical correctness (the second lens of the row in §12) |
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
| Each resolves to its design | `EqualizerValueTests/eachResolvesToItsDesign()`. In the verifier's `o431b.py`, five band boosts of order 1 given by Q equal the Cookbook peaking section: roots within 3.3·10⁻¹⁴, gains equal, centres from 20 Hz to 21 600 Hz. Five shelves, in the S and the Q forms, equal the Cookbook shelves: roots within 4.6·10⁻¹⁵, gains equal. | pass |
| The bandwidth forms of §6.3.5 | `theThreeBandwidthFormsMeanWhatTheySay()`. In `o431b.py`, the `.hertz` and `.octaves` forms of orders 1 to 8 equal the Orfanidis Butterworth closed form within 1.73·10⁻¹² relative (the bound is 10⁻⁸). The half-gain width, measured by bisection, is the requested one within 1.4·10⁻¹³ relative, for example 2 000.000000 Hz against 2 000 Hz. `.octaves(b)` is the width in hertz of b octaves around the centre: 57.832685 Hz for a third of an octave at 250 Hz. | pass |
| A band past the limit is rejected | `aBandPastTheLimitIsRejected()`: the value rejects the band, and so does attach time, with the stage path `BandBoost[1]`. `BandBoostTests/aBandThatReachesFortyNineHundredthsOfTheSampleRateIsRejected()` checks the rule at 0.999 and 1.001 of the limit width. The verifier's probe placed six bands near the limit: they reach an upper half-gain frequency of 23 447.9 Hz, below 0.49·fs = 23 520 Hz, and all six are accepted, as the rule computed independently says. | pass |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - **Against the definition.** `o431b.py` ran 124 checks, 0 failed:
    - the Cookbook sections and shelves, root by root;
    - the Orfanidis magnitude;
    - properties 1 to 5 of §6.3.5 on every band: gain at the centre; half the gain a bandwidth apart; 0 dB at 0 Hz and at Nyquist (largest deviation 2.2·10⁻¹³ dB); monotonic sides; poles strictly inside the unit circle (largest radius 0.999967 at 20 Hz, Q 10).
  - **Edge cases.**
    - Cuts and boosts from −12 to +24 dB.
    - Centres from 20 Hz to 21 600 Hz (0.45·fs), and up to 23 400 Hz at the 0.49·fs limit.
    - The tests' rejections: a centre above Nyquist, a gain of 0, order 0, a negative shelf slope and a shelf at 0 Hz.
  - **Precision.** Designs are made in double precision.
  - **Tolerances.** No tolerance is loosened.
  - **COV-3** (for information; this lens has no T). `Equalizers/EqualizerDesign.swift` is at 99.32 %. `Stages/EqualizerStages.swift` is at 100 %.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | None | — |

## Change requests filed (FIX-4)

None by this verifier.
