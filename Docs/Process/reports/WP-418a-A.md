# Verifier report — WP-418a, lens N

| Field | Value |
|---|---|
| Package | WP-418a — `IIRDesign`, analog: family × response × order → ZPK and coefficient forms |
| Lens | N (the first lens of the row: N, A) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 20:05, after CR-023 |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`23-verifier-a-m4a.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output (none was handed over; every figure below is from the verifier's own runs)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed (the stability notes, the currency record and CR-014 were read as deliverables of the packages)

## Acceptance checks run by the verifier (VER-3)

Simulator `ztdsp-27-vm4aa` (iOS 27.0), created for this review. Whole target, `ZTD_DEVICE=ztdsp-27-vm4aa Scripts/xc.sh test ZTronDSPDesignTests`:

- Debug: 332 of 332 passed (39 suites).
- Release (`ZTD_CONFIG=Release`): 332 of 332 passed.
- Debug with `ZTD_XCARGS="-test-iterations 3"`: every one of the 332 tests ran three times and passed (188 s; no issue recorded); no measured figure exceeds its bound except the recorded hazards, which are meant to.

`Scripts/golden.sh --check`: "197 files of 27 generators match the manifest".

The independent evidence is in `VerifierA/`; its README says how to run it:

- **Recompute.** The committed golden vectors were recomputed from their parameters with SciPy 1.15.3, by the oracle definitions and not by the project's generators (`recompute_golden.py`).
- **Probes.** A seeded grid that is not the golden one (`make_probe_input.py`, `probes/VerifierAProbeTests.swift`, `check_probes.py`).
- **Mutations.** For the ALG rows, the change that each stability note says breaks the design was applied and the named tests were run. The file was then restored and compared byte for byte with `.build/pristine/` (`run-mutation.sh`).
- **Reproductions.** The findings, reproduced through the public API (`repro/VerifierAReproTests.swift`, `run-repro.sh`, `check_repro.py`).

| Check | How it was run | Result |
|---|---|---|
| Golden over the matrix | `analogDesignsMatchTheOracleInZeroPoleForm`, `analogDesignsMatchTheOracleInCoefficientForm` against `iirfilter(analog=True)` and `freqs` (family × response × orders 1, 2, 5, 8; 512 frequencies, as STG-2); recompute of `iir_design` | Passed (poles 1.4·10⁻¹¹, gain 5.4·10⁻¹⁵); recompute 1 242 comparisons within their bounds |
| Random matrix | Probe: other edges and orders | 2 of 720 outside 10⁻⁹, both one Chebyshev II band-stop of order 1: SciPy's `lp2bs` is off by 2.5·10⁻⁷ there, and ours agrees with the exact value to 1.9·10⁻¹⁵ |
| `ALG` stability note: "fails when the smaller image is formed by subtraction" | M10 | `stressAWideBandKeepsItsAccuracy` fails (8 issues); restored byte-identical; Sources pristine afterwards |
| A gain out of range | Repro: `IIRDesign(.butterworth, .lowPass(cutoff: 0.001), order: 128, domain: .analog)` | Gain 0, no error: A-3 |

## Lens checklist (§11.5)

- **N — numerical correctness.** Result against the cited definition and the golden vectors within the row's tolerance; edge cases; precision; for `ALG` the currency record and the stability note against the code; no tolerance loosened.

  - Currency: `iir-design-analog.md` first lines say offline, then row 4 (dated, outcome current); see A-NB8.
  - CR-014 items 4 and 6 (no analog sections; the domain carries its rate) are what the code does.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-3 | A result is wrong (§11.4): a gain that underflows comes back as a filter of gain 0 instead of the typed error the same guard gives on overflow ("…or its gain out of range"; a prototype of gain 0 is refused, `AnalogPrototype.swift:226-228`) | `Sources/ZTronDSPDesign/Transformations/FrequencyTransformation.swift:52`, `:69` (gain·cutoffⁿ, gain·bandwidthⁿ) and `:83-84` (the guard tests `isFinite` only); `Bilinear.swift:58-59` (the same) | See "A-3 in full" below | blocking |
| A-NB8 | `ALG`: the currency record covers the note's method (§7.3) | `Docs/Numerics/currency-2026-11.md`, rows 3 and 4 | The record exists, is dated 2026-11-15, names what was searched and states an outcome. But row 4, which the notes of 405–411, 414, 418a and 418b cite, searched only alternatives to the pre-warped bilinear transform near Nyquist. Row 3, cited by `section-pairing.md`, searched the stability of moving coefficients. Neither search concerns the prototypes, the elliptic functions, the Bessel roots or the pairing. The literature was not checked (no network). | non-blocking |

**A-3 in full.**

Through the public API, each of the following returns gain 0 and ‖H‖ = 0, with no error:

- `butterworth(order: 128).transformed(by: .lowPass(cutoff: 0.001))` (exact gain 10^−384).
- `.bandPass(center: 1000, bandwidth: 0.001)` of the same prototype.
- The bilinear transform of order 512 at 0.4 rad/s. Its analog gain, 10^−203.7, is representable; its digital gain, 10^−526.1, is not.
- `IIRDesign(.butterworth, .lowPass(cutoff: 100), order: 256, domain: .digital(sampleRate: 48_000))` (exact 10^−559.6).
- The analog order-128 design at 0.001 rad/s.

The control, cutoff 1 000 at order 128 (gain 10^384), throws `invalidParameter`. A gain that becomes subnormal loses digits silently: Chebyshev I, order 128, at 100 Hz returns 3.137·10⁻³¹⁸, and ‖H(0)‖ is off by 7.3·10⁻⁸ relative, against a golden tolerance of 10⁻⁹.

**A-3, to reproduce or resolve.** `VerifierA/scripts/run-repro.sh 2`: `a3AnUnrepresentableGainIsATypedErrorNotAZeroFilter` and `a3DirectTheTransformationsRefuseAGainThatUnderflows` fail, and `a3ControlTheOverflowingAnalogGainIsATypedError` passes. Resolve by refusing a gain that becomes 0 or subnormal from a normal one, as the prototype does, in both transformations and in the bilinear transform. Computing the gain with its exponent kept apart (A-2) means only unrepresentable results are refused. Add tests for both directions.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None.
