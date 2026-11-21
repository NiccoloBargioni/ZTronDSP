# Verifier report — WP-418c, lens N

| Field | Value |
|---|---|
| Package | WP-418c — Order from a tolerance scheme: the `passband:stopband:maximumLoss:minimumAttenuation:` initialisers (§6.3.2) |
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
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` (one iteration) | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass |
| Golden: `buttord`, `cheb1ord`, `cheb2ord`, `ellipord`; order equal, natural frequency within 1e-9 | The package's golden tests in `FilterOrderTests` (in the runs above). My own check: probe `p418c` ran 640 schemes off the golden grid: four families; low-pass, high-pass, band-pass and band-stop; digital at 44.1 kHz and analog; transition ratios 1.25 to 2.2; four loss/attenuation pairs. `VerifierA/run-probe.sh p418c && python3 VerifierA/wp418c_schemes.py` compares them with SciPy 1.15.3 | Order equal in 640 of 640. Natural frequency: worst relative difference 1.6e-15 (bound 1e-9). The package rejected none |
| The resulting filter meets its scheme | Same script: the response of each designed ZPK, evaluated on a dense grid over the pass and stop bands | Pass band: worst excess over the maximum loss 2.3e-12 dB. Stop band: worst shortfall −6.0e-13 dB, so every scheme is met |

## Lens checklist (§11.5)

- **N — numerical correctness.** The result matches the definition (SciPy's order functions) and the golden vectors within 1e-9. Edge cases: analog and digital, both band forms, and narrow and wide transitions. Every scheme passes. The design runs in double, so there is no precision choice. No tolerance was loosened: the golden test holds the natural frequency to the oracle table's 1e-9. Not an `ALG` row.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-B5 | Tests | `Tests/ZTronDSPDesignTests/FilterOrderTests.swift:174` | The comment above it says "The order is the minimum: one less does not meet the scheme". The line asserts only `design.order >= 1`. The test that follows, `theOrderIsTheSmallestThatMeetsTheScheme`, checks minimality for one Butterworth scheme only. Over the golden schemes the loop asserts nothing about minimality, although the orders do equal SciPy's in my 640 schemes | non-blocking (backlog) |
