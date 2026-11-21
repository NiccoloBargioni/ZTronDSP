# Verifier report — WP-418c, lens A

| Field | Value |
|---|---|
| Package | WP-418c — Order from a tolerance scheme: the `passband:stopband:maximumLoss:minimumAttenuation:` initialisers (§6.3.2) |
| Lens | A — API, architecture, platform (the second lens of the row in §12) |
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

- Debug `Scripts/xc.sh test ZTronDSPDesignTests`: 334 tests in 40 suites, passed in two runs.
- Release with the verifier's probes (`VerifierB/release-runs.sh`): 344 tests in 41 suites, passed.

| Check | How it was run | Result |
|---|---|---|
| Golden | `FilterOrderTests`, 14 tests, among them `theDesignFromASchemeMatchesTheOraclesDesign()` (poles within 8.4·10⁻¹⁵ relative, bound 10⁻⁹). `Scripts/golden.sh --check`: 197 files of 27 generators match the manifest. `PYTHONPATH=VerifierB/pyshim Scripts/golden.sh --reproduce --only iir_order`: the generator reproduces its committed files bit for bit with SciPy 1.15.3. | pass |
| The resulting filter meets its scheme | `theDesignFromASchemeMeetsItsScheme()` (worst stop-band shortfall −5.8·10⁻⁸ dB, bound 10⁻⁶). The verifier's `o431a.py` ran eight schemes through the response values, across four families and four responses. The orders (5 to 27) equal those of SciPy's `buttord`, `cheb1ord`, `cheb2ord` and `ellipord`, and the roots are within 5.7·10⁻¹⁶. Each design meets its scheme measured on 200 001 points: for example, loss 0.9994 ≤ 1 dB and attenuation 42.597 ≥ 40 dB; 40.080 ≥ 40 dB at order 27; 80.000 ≥ 80 dB for the elliptic high-pass. | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§6.3.2).**
    - The four response values take `(_ family:, passband:, stopband:, maximumLoss:, minimumAttenuation:, isActive:)`, spelled as in §6.3.2 (digest `Docs/API/ZTronDSPDesign.txt:451, 457, 485, 499`).
    - So does `IIRDesign.init(_:passband:stopband:maximumLoss:minimumAttenuation:domain:)` (digest 490).
    - These are plain arguments, with no options object (API-6).
  - **Strategy.**
    - `FilterOrderStrategy` is a protocol with one stock conformer per family except Bessel (digest 59, 69, 79, 118). `theStockFamiliesNameTheirStrategies()` passes.
    - A conformer written outside the package gets the same mapping (`aStrategyWrittenOutsideThePackageGetsTheSameMapping()`).
    - Bessel rejects a scheme with `unsupportedConfiguration`, as §6.3.2 says (`besselRejectsAToleranceScheme()`). The probe's rejection names the remedy: "give an order or a roll-off instead of a tolerance scheme (at LowPass[0])".
  - **Typed errors at attach time, with the stage path.** The probe (`pLensA.json`, `rejections`) shows three:
    - A pass band above the stop band is `invalidParameter` `stopband`.
    - A loss at or above the attenuation is `invalidParameter` `minimumAttenuation`.
    - A stop-band edge at or beyond the Nyquist frequency behind a `Decimate` names 6 000 Hz "at this position (at LowPass[1])".
  - **Immutability and Sendable.** The strategies and the stages are values and are `Sendable` (digest 169–172).
  - **VIS-2.** `IIR/FilterOrderStrategy.swift` has 26 public declarations. Each is documented and names its threading context (`VerifierB/vis2.py`).
  - **DEP, EXT, VIS and the platform.**
    - `Scripts/api-digest.sh --check`: the 10 digests equal the built modules, and `ZTronDSPDesign` references public symbols only.
    - `Scripts/check-dependency-graph.sh`: the graph equals §4.2.
    - `Scripts/lint-bans.sh`: clean, which covers the UIKit boundary and the approval-gated API.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | None | — |

## Change requests filed (FIX-4)

None by this verifier.
