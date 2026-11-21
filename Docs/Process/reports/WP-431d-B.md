# Verifier report — WP-431d, lens N

| Field | Value |
|---|---|
| Package | WP-431d — `FIRSystem { }`: `Taps`, `Zero`, `LeastSquares`, the FIR design values |
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
- `Scripts/compile-fixtures.sh`: all fixtures pass. `DesignEqualizerInAnFIRSystem` and `DesignIIRSystemInAnFIRSystem` fail with their sentences.

| Check | How it was run | Result |
|---|---|---|
| Builder fixtures | `FIRSystemTests`, 6 tests: `theSystemOfTheSpecificationIsTheConvolutionOfItsElements()`, `eachElementGivesTheTapsItStates()`, `theLeastSquaresElementIsTheGeneralFit()`, `theBuilderTakesControlFlow()` and others. In the verifier's `o431d.py`, three systems give the convolution of their elements within 1.79·10⁻¹⁵ relative (bound 10⁻¹²). The specification's `antiAlias` system gives the design convolved with [0.25, 0.5, 0.25] (remainder 9.3·10⁻¹⁷); its design part has 81 taps, is symmetric, and equals the stand-alone `LowPass` within 1.6·10⁻¹⁵. Two `Taps` of 3 000 give 5 999 taps, which are accepted. | pass, except the pole at the origin (finding 1) |
| A pole away from the origin is rejected | `aPoleAwayFromTheOriginIsRejected()`. In the probe, each of the following is `invalidParameter` and names the element: a pole pair at radius 0.5; a real pole at 0.1; a section with the denominator 1, −0.5; a difference equation with feedback; an IIR design; an element with `isActive: false`; empty taps; a NaN tap. | pass |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - **Against the definition.** §6.3.7 says "Elements inside one builder are cascaded", and the convolutions match it. The exception is `Pole(at: 0)`, which is not the factor its documentation states (finding 1): `o431d.py`, 18 checks, 2 failed.
  - **Edge cases.**
    - Empty and non-finite taps are rejected.
    - A long system (5 999 taps) is accepted, below `FIRSystem.maximumLength` = 1 048 576.
  - **Precision.** Taps are held in double precision. The kernel runs them in single precision (Realization).
  - **COV-3.** `FIRSystem.swift` is at 91.94 % (finding 2).

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (B-2) | Result matches the cited definition (§6.3.7: elements are cascaded; `Pole` is documented as "the factor `1 / (1 − p·z⁻¹)`") | `Sources/ZTronDSPDesign/Systems/SystemElements.swift:185` (doc 141–154, 178); asserted at `Tests/ZTronDSPDesignTests/SystemBuilderTests.swift:350` | The same element means two things. In an `FIRSystem`, `Pole(at: 0)` is a one-sample delay: `taps` returns `[0, 1]`, so `FIRSystem { Taps([1, 2]); Pole(at: 0) }` has the taps [0, 1, 2]. In an `IIRSystem`, it is the documented factor `1/(1 − 0·z⁻¹)` = 1: `IIRSystem { Section(b: [1, 2]); Pole(at: 0) }` is 1 + 2z⁻¹ (ZPK: zero −2, pole 0, gain 1), and `IIRSystem { Pole(at: 0) }` is the identity (no zeros, no poles, gain 1). At ω = 0.3 and 1.1 rad/sample, the FIR system's response is 2.606008 − 1.424805j and −0.723406 − 2.508200j; the IIR system's is 2.910673 − 0.591040j and 1.907192 − 1.782415j. The package's own IIR test says the factor reading holds for every element: "A pole and a zero as elements bring no delay: each is a factor in z⁻¹" (`SystemBuilderTests.swift:151`). The `Pole` doc says both: the factor (line 141), and "In an `FIRSystem` … it is a delay of one sample" (153–154). Reproduce with `python3 VerifierB/oracles/o431d.py`, on the probe output of `VerifierB/run-probes.sh`. Resolution: one meaning in both builders, with the documentation and the test at line 350 made to agree; or a change request that states the two meanings. | blocking |
| 2 (B-7) | COV-3 | `Sources/ZTronDSPDesign/Systems/FIRSystem.swift:107, 117, 120, 125, 149–150, 232–235` | `FIRSystem.swift` is at 91.94 % (114 of 124 lines). No test reaches four rejections: "not an element of an FIR system" (107), "has no finite taps" (117), "convolve to more than `maximumLength` taps" (120) and "a number that is not finite" (125). Nor does any test reach the nested element in `replacingParameters` (149–150) or the zeros of taps that are all zero (232–235). These are the merged figures of two instrumented runs. Reproduce with `VerifierB/coverage.sh gate`. The file is also changed by WP-432c (`latency(of:)`). Neither lens of this row is T; the verifier attributes the file to the package. Resolution: tests for these lines, or COV-4(b) markers on branches that cannot be reached. | blocking |

## Change requests filed (FIX-4)

None by this verifier.
