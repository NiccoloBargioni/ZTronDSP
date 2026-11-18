# Verifier report — WP-428a, lens N

| Field | Value |
|---|---|
| Package | WP-428a — `LTISystem` analysis: zeros, poles, gain, for digital and analog systems |
| Lens | N (the first lens of the row: N, A) |
| Verifier | A (agent); not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 20:05, after CR-023 |
| Fix cycle | 0 |
| Verdict | `pass` |

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
| Fixtures including a pole on the unit circle and an analog system | `aPoleOnTheUnitCircleIsNotStable`, `anAnalogSystemIsJudgedByTheHalfPlane`, `aDesignReportsTheSameRootsFromEveryForm`, `coefficientsGiveTheirRootsThroughTheRootFinder` | Passed |
| Random systems | Probe: digital and analog systems from roots, sections and coefficients | Poles read from sections 8.7·10⁻¹⁶, zeros 2.6·10⁻¹⁶; poles from coefficients ≤ 0.055·κ·ε; `isStable`, `isMinimumPhase` never differ |

## Lens checklist (§11.5)

- **N — numerical correctness.** Result against the cited definition and the golden vectors within the row's tolerance; edge cases; precision; for `ALG` the currency record and the stability note against the code; no tolerance loosened.

  - Definitions read against the code: roots read in closed form per section, never expanded; for coefficients, the root finder of WP-402.
  - Edge cases: a system without poles is stable; a pole on the unit circle is not.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-NB3 | Non-finite input (NUM-1, lens N edge cases) | `Sources/ZTronDSPDesign/Systems/SecondOrderSections.swift:37`, `:79`; `Sources/ZTronDSPDesign/Math/QuadraticRoots.swift:18` | Sections accept NaN and infinite coefficients without a typed error. The poles and zeros read back are NaN, and so is `stabilityMargin`. `TransferFunction.poles` throws for the same input. A typed error at construction or at analysis would make the forms agree. | non-blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None.
