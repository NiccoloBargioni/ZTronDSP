# Verifier report — WP-418b, lens N

| Field | Value |
|---|---|
| Package | WP-418b — `IIRDesign`, digital: pre-warp, bilinear, section pairing → SOS |
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
| Golden over the matrix | `digitalDesignsMatchTheOracleInZeroPoleForm`, `…SectionForSection`, `…InCoefficientForm` against `iirfilter(output='sos')` and `sosfreqz`; recompute of `iir_design` | Passed (sections 9.1·10⁻¹⁵, poles 9.0·10⁻¹⁵); recompute: sections, roots and gain 0 deviation, committed group delay 2.8·10⁻⁷ samples from the root sum (bound 10⁻⁶) |
| Random matrix | Probe: other edges, orders and rates | 0 outside 10⁻⁹ (sections 6.0·10⁻¹⁴) |
| Edges where they were asked for | `aDigitalEdgeLandsExactlyWhereItWasAskedFor`, `stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles` | Passed |
| `ALG` stability note: "fails when the zero-pole transform is routed through coefficients" | M9 (shared with WP-414) | `stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles` fails (29 issues); restored byte-identical; Sources pristine afterwards |
| High orders | Repro: Butterworth and Chebyshev I order 512 at 10 kHz / 48 kHz; Butterworth order 256 at 100 Hz | Gain 0, ‖H‖ = 0, no error: A-2 and A-3 |

## Lens checklist (§11.5)

- **N — numerical correctness.** Result against the cited definition and the golden vectors within the row's tolerance; edge cases; precision; for `ALG` the currency record and the stability note against the code; no tolerance loosened.

  - Definitions read against the code: pre-warp at the internal rate 2 (4·tan(π·f/f_s)), transformation and bilinear transform in ZPK, pairing by WP-404.
  - Currency: `iir-design-digital.md` first lines say offline, then row 4 (dated, outcome current).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-2 | A result is wrong (§11.4): a representable gain is lost in the bilinear transform (§6.3.2 design path; accepted orders up to `AnalogPrototype.maximumOrder` = 512) | `Sources/ZTronDSPDesign/Transformations/Bilinear.swift:53-58` | Π(2f_s − z)/Π(2f_s − p) is formed as a running product before it meets the gain. Butterworth low-pass, order 512, 10 kHz at 48 kHz: the analog gain is 10^249.4 and the digital gain 10^−161.6 (both representable), but the product, 10^−411, underflows to 0. The design is returned with gain 0 and ‖H‖ = 0 in ZPK and in sections, and no error is thrown. Chebyshev I 1 dB at the same order and edge (exact 10^−239.9) also returns 0, and so does the direct `bilinear(sampleRate: 2)` of the analog system. SciPy's `bilinear_zpk` gives NaN here, so the golden vectors cannot catch it. | blocking |
| A-3 | A result is wrong (§11.4): a gain that underflows comes back as a filter of gain 0 instead of the typed error the same guard gives on overflow ("…or its gain out of range"; a prototype of gain 0 is refused, `AnalogPrototype.swift:226-228`) | `Sources/ZTronDSPDesign/Transformations/FrequencyTransformation.swift:52`, `:69` (gain·cutoffⁿ, gain·bandwidthⁿ) and `:83-84` (the guard tests `isFinite` only); `Bilinear.swift:58-59` (the same) | See "A-3 in full" below | blocking |
| A-NB5 | Stated limits (§6.3.9) | `Sources/ZTronDSPDesign/IIR/IIRDesign.swift` (digital design), `SectionPairing.swift` | Edges very close to 0 Hz or to Nyquist meet the rounding of the biquad coefficients. A Butterworth order 8 at 10⁻³ Hz / 48 kHz: the sections' ‖H(0)‖ is 0.99578 (ZPK: 1). At 23 999.99 Hz the sections' ‖H‖ at the edge is 0.70691 instead of 0.70711 (2.8·10⁻⁴ relative). No such limit is documented. | non-blocking |

**A-3 in full.**

Through the public API, each of the following returns gain 0 and ‖H‖ = 0, with no error:

- `butterworth(order: 128).transformed(by: .lowPass(cutoff: 0.001))` (exact gain 10^−384).
- `.bandPass(center: 1000, bandwidth: 0.001)` of the same prototype.
- The bilinear transform of order 512 at 0.4 rad/s. Its analog gain, 10^−203.7, is representable; its digital gain, 10^−526.1, is not.
- `IIRDesign(.butterworth, .lowPass(cutoff: 100), order: 256, domain: .digital(sampleRate: 48_000))` (exact 10^−559.6).
- The analog order-128 design at 0.001 rad/s.

The control, cutoff 1 000 at order 128 (gain 10^384), throws `invalidParameter`. A gain that becomes subnormal loses digits silently: Chebyshev I, order 128, at 100 Hz returns 3.137·10⁻³¹⁸, and ‖H(0)‖ is off by 7.3·10⁻⁸ relative, against a golden tolerance of 10⁻⁹.

**A-2, to reproduce or resolve.** `VerifierA/scripts/run-repro.sh 2`: `a2ARepresentableDigitalGainIsNotLostToUnderflow` and `a2DirectTheBilinearTransformKeepsARepresentableGain` fail (gain 0). Resolve by interleaving the factors with the gain, or by keeping the exponent apart (frexp/scalbn, or a sum of logarithms) and forming the gain once. Add a test at order 512.

**A-3, to reproduce or resolve.** `VerifierA/scripts/run-repro.sh 2`: `a3AnUnrepresentableGainIsATypedErrorNotAZeroFilter` and `a3DirectTheTransformationsRefuseAGainThatUnderflows` fail, and `a3ControlTheOverflowingAnalogGainIsATypedError` passes. Resolve by refusing a gain that becomes 0 or subnormal from a normal one, as the prototype does, in both transformations and in the bilinear transform. Computing the gain with its exponent kept apart (A-2) means only unrepresentable results are refused. Add tests for both directions.

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None.
