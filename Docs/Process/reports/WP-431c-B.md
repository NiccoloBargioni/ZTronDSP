# Verifier report — WP-431c, lens N

| Field | Value |
|---|---|
| Package | WP-431c — `IIRSystem { }`: `Pole`, `Zero`, `Section`, `DifferenceEquation`, the IIR design values |
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
- `Scripts/compile-fixtures.sh`: 7 valid fixtures compile; 133 invalid fixtures fail with their sentences.

| Check | How it was run | Result |
|---|---|---|
| Builder fixtures | `IIRSystemTests`, 9 tests: `theSystemOfTheSpecificationIsTheProductOfItsElements()`, `sectionsAndDifferenceEquationsAreReadAsTheyAreWritten()`, `aDelayWrittenIntoASystemIsKept()`, `theBuilderTakesControlFlow()`, `whatIsNoElementOfAnIIRSystemIsReportedWithTheElementNamed()` and others. The compile fixtures `DesignTapsInAnIIRSystem` and `DesignStageInAnIIRSystem` fail with their sentences. In the verifier's `o431c.py`, the probe built four systems: the hum system of §6.3.7, points in the plane, a difference equation, and designs. For each, the response of the ZPK form and that of the sections equal the product of the elements' factors, evaluated by the verifier: within 1.12·10⁻¹⁴ and 9.1·10⁻¹³ relative (bound 10⁻⁹). For the designs, &#124;H&#124; agrees within 5.3·10⁻¹⁴ and 2.2·10⁻¹² relative (bound 10⁻⁸). The ZPK form and the sections agree. | pass |
| Conjugates completed | `conjugatesAreCompletedAndRealRootsStandAlone()`. In `o431c.py`, every complex zero and pole has its conjugate: 4, 4, 2 and 16 complex zeros; 6, 4, 0 and 18 complex poles. The roots away from the origin are where the elements put them, within 6.7·10⁻¹⁶. | pass |
| An element with a non-default `isActive` is rejected (ACT-1) | `anElementWithASwitchOfItsOwnIsRejected()`. In the probe, a design, a boost and a shelf with `isActive: false` are each `invalidParameter` `isActive`: "element 0 of the system … has an isActive of its own: a system is switched whole, through Filter(_:isActive:)". An explicit `isActive: true` equals the default and is accepted (ACT-12). An FIR design (`method`) and a zero above Nyquist (`frequency`) are rejected and named. | pass |

## Lens checklist (§11.5)

- **N — numerical correctness.**
  - **Against the definition.** The results match the definition of §6.3.7, elements cascaded, by the product of the factors: 32 checks, 0 failed. A pole and a zero away from the origin are the factors `1/(1 − p·z⁻¹)` and `(1 − q·z⁻¹)`, as their documentation says.
  - **Edge cases.**
    - Real roots at 0 Hz and at Nyquist stand alone.
    - A delay written as leading zero coefficients is kept.
    - A zero above Nyquist is rejected.
  - **Precision.** The system is held in ZPK form in double precision, and no polynomial is expanded.
  - **COV-3.** One file of the package is below 97.5 % (finding 1).
  - **A pole at the origin.** Its meaning differs between the two builders. That finding is raised against WP-431d, whose element it is in an FIR system.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (B-6) | COV-3 | `Sources/ZTronDSPDesign/Systems/IIRSystem.swift:118, 128, 143, 232–233` | `IIRSystem.swift` is at 96.88 % (155 of 160 lines). No test reaches three rejections: "this value is not an element of an IIR system" (118), "… is not a finite digital system" (128) and "the gains of the elements multiply to a number that is not finite" (143). Nor does any test reach the nested element in `replacingParameters` (232–233). These are the merged figures of two instrumented runs. Reproduce with `VerifierB/coverage.sh gate`. Neither lens of this row is T; the verifier attributes the file to the package. Resolution: tests for these lines, or COV-4(b) markers on branches that cannot be reached. | blocking |

## Change requests filed (FIX-4)

None by this verifier.
