# Verifier report — WP-431d, lens A

| Field | Value |
|---|---|
| Package | WP-431d — `FIRSystem { }`: `Taps`, `Zero`, `LeastSquares`, the FIR design values |
| Lens | A (the first lens of "A, N") |
| Verifier | A, an independent agent session: not the implementer, not Verifier B, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 22:50, after CR-027 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief (`briefs/25-verifier-a-m4b.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output: this verifier produced it in the checkout (first rows below); coverage is not part of this lens
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

| Check | How it was run | Result |
|---|---|---|
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the 6 tests of the suite "FIRSystem (WP-431d)", among them `eachElementGivesTheTapsItStates`, `theLeastSquaresElementIsTheGeneralFit`, `aPoleAwayFromTheOriginIsRejected` and `theBuilderTakesControlFlow` |
| Builder fixtures | `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 7 valid fixtures compile, and 133 invalid ones fail with their sentences. In `valid/DesignStagesOnSampledSequences.swift`, an `FIRSystem` takes `Taps`, `LowPass(.windowedSinc(), cutoff:length:)`, a `Zero(onUnitCircleAt:)` under `if`, `Taps` in a `for` loop and `LeastSquares(length:bands:desired:)`. `Filter(comb, isActive: shown)` with a `Binding` and `.filter(comb, isActive: false)` run it. `invalid/DesignIIRSystemInAnFIRSystem.swift` and `invalid/DesignEqualizerInAnFIRSystem.swift` fail with "An FIRSystem holds FIR elements" |
| A pole away from the origin is rejected | Probe `p431` at 48 kHz: one-element systems resolved with `taps(sampleRate:)`. `VerifierA/run-probe.sh p431 && python3 VerifierA/wp431_builders.py` | Rejected with `DSPError.invalidParameter`: `Pole(at: 0.5)`, with the message "element 0 of the system (Pole): an FIR system has no pole away from the origin, and this one lies at 0.5 + 0.0j: put it in an IIRSystem"; `Pole(at: 1e-300)`, likewise; `Section(b: [1], a: [1, -0.5])` on `a` ("this section has the denominator 1, -0.5, 0.0"); `DifferenceEquation(b: [1], a: [1, 0.3])` on `a` ("this difference equation feeds its output back"); `LowPass(…, isActive: false)` on `isActive` (ACT-1). Accepted: `Pole(at: 0)`, whose taps [0, 1] are a delay of one sample; `Section(b: [1, 0.5])`, taps [1, 0.5, 0]; `Zero(at: 0.5 + 0.5j)`, taps [1, −1, 0.5], with the conjugate added |
| Names and shapes (§6.3.3, §6.3.7) | The digest `Docs/API/ZTronDSPDesign.txt` (lines 475, 493, 514, 519–521, 984–990, conformances 106–385); `Scripts/api-digest.sh --check` | `Taps(_:)`; `LeastSquares(length:bands:desired:weights:)` with `weights = []`; `Zero` as in `IIRSystem`; `FIRSystem(@FIRSystemBuilder _:)`, whose builder has the same six build functions as the IIR one. `Taps` and `LeastSquares` are FIR elements only. The four response stages, `Zero`, `Pole`, `Section` and `DifferenceEquation` are elements of both systems. The last three are accepted in an `FIRSystem` only while every pole they place lies at the origin, which is the rule of §6.3.7 ("rejects anything that would place a pole away from the origin"). The equalisers are IIR elements only. The digests equal the built modules |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes per §6.3.3 and §6.3.7, as above.
  - Strategy: the FIR forms take their `FIRDesignMethod` as the first argument.
  - DEP, EXT and VIS: the gates pass. Two members are not named anywhere (A-B8).
  - IMM and API-6: immutable structs; no configuration object.
  - Sendable.
  - Availability: iOS 15 floor; `if #available` works inside the block.
  - No UIKit, Combine or `AnyView`.
  - Typed errors: every rejection is `DSPError.invalidParameter`, naming the element and what to do.
  - Threading contract: the public declarations of `Systems/FIRSystem.swift` state theirs. The exceptions are the caseless builder enum, whose members carry the contract, and the unavailable overload that produces the fixture's sentence.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-B8 | VIS-3; CR-018 item 11 | `Sources/ZTronDSPDesign/Systems/FIRSystem.swift:86, 199`; `Docs/API/ZTronDSPDesign.txt:749, 751` | `FIRSystem.elementCount` and `FIRSystem.isLinearPhase` are public. §6.3.7 does not name them, and §6.3.8 names `isLinearPhase` only for the analysis. CR-018 item 11 lists types only. Both are in the committed digest and documented with their context | non-blocking (backlog): CR-018 should name them |
