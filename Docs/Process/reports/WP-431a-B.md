# Verifier report — WP-431a, lens N

| Field | Value |
|---|---|
| Package | WP-431a — Response values `LowPass`, `HighPass`, `BandPass`, `BandStop` over an IIR family or an FIR method |
| Lens | N — numerical correctness (the second lens of the row in §12) |
| Verifier | B, an agent; not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `blocking` |

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
| Each resolves to the design its arguments name | `ResponseValueTests`: `anIIRFormResolvesToTheDesignItsArgumentsName()`, `anFIRFormResolvesToTheDesignItsArgumentsName()` and `aFrequencyIsResolvedAgainstTheRateTheStageIsResolvedAt()`. The verifier's probe dumped the values' designs, and `o431a.py` recomputed them with SciPy 1.15.3 (129 checks, 0 failed; see below). | pass |
| Value semantics | `theStagesAreValues()` and `theContinuousValuesAreTheFrequenciesInLogTwoHertz()`. In `o431a.py`, `replacingParameters` leaves the original unchanged, and a wrong parameter count returns the value itself. The parameter of `LowPass(cutoff: 1 000 Hz)` is 9.965784284662087 = log₂ 1 000. | pass |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - **Against the definition.** In `o431a.py`:
    - **IIR designs.** 23 of them: 15 by order or roll-off, across the five families and four responses, and 8 by scheme. The orders are equal, the roots are within 1.8·10⁻¹⁵, and the responses are within 5.4·10⁻¹³ relative.
    - **FIR taps.** 9 designs. They equal `firwin` within 6.7·10⁻¹⁶ (five windows; the bound is 10⁻¹²) and `firls` within 1.35·10⁻¹⁴ (four fits; the bound is 10⁻⁹).
    - **FIR schemes and roll-offs.** Four schemes (two windowed-sinc, two least-squares) and two roll-offs are met when measured, for example 81.125 ≥ 80 dB with a pass-band deviation of 0.0008 ≤ 0.1 dB. The lengths of the windowed-sinc schemes and of the roll-offs (247, 1 743, 81 and 81 taps) equal the verifier's re-run of the search.
  - **Edge cases and rejections.**
    - A least-squares scheme that no length up to 4 095 taps meets is `unsupportedConfiguration`: "needs about 4865 taps …; `.windowedSinc()` reaches such a scheme". This is CR-018 item 6.
    - `anEdgeIsCheckedAgainstTheNyquistFrequencyAtTheStagesPosition()` passes.
  - **Precision.** Designs are made in double precision.
  - **Tolerances.** No tolerance is loosened.
  - **COV-3.** Two files of the package are below 97.5 % (finding 1).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (B-5) | COV-3 | `Sources/ZTronDSPDesign/Stages/ResponseCore.swift:103, 108, 124, 140`; `Sources/ZTronDSPDesign/Stages/ResponseStages.swift:396, 789–791, 804` | `ResponseCore.swift` is at 97.33 % (146 of 150 lines). No test reaches the four rejections in `resolve` and in the IIR and FIR resolutions: no method or no family; a length or an order of the wrong kind. `ResponseStages.swift` is at 97.25 % (177 of 182 lines). No test reaches `HighPass.dependsOnSampleRate`, `BandStop.zeroPoleGain(sampleRate:)` or `BandStop.dependsOnSampleRate`. These are the merged figures of two instrumented runs: the design target, then every target that reaches it. Reproduce with `VerifierB/coverage.sh gate`. Neither lens of this row is T; the verifier attributes the files to the package because they hold its values, and the ledger records no attribution. Resolution: tests for these lines, or COV-4(b) markers on branches that cannot be reached. | blocking |

## Change requests filed (FIX-4)

None by this verifier.
