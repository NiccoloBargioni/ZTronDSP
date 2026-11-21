# Verifier report — WP-431a, lens A

| Field | Value |
|---|---|
| Package | WP-431a — Response values `LowPass`, `HighPass`, `BandPass`, `BandStop` over an IIR family or an FIR method |
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
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the suite "Response values (WP-431a)": `anIIRFormResolvesToTheDesignItsArgumentsName`, `anFIRFormResolvesToTheDesignItsArgumentsName`, `aFrequencyIsResolvedAgainstTheRateTheStageIsResolvedAt`, `theStagesAreValues`, `theContinuousValuesAreTheFrequenciesInLogTwoHertz`, `theFluentSpellingAndTheBuilderGiveEqualPipelines` and `aResponseIsAnElementOfTheSystemItsDesignBelongsTo` |
| Each resolves to the design its arguments name | Probe `p431` at 48 kHz. Four values are resolved through a system and compared with `==` against the design type called directly: `LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)` against `IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 4, domain: .digital(sampleRate:))`; `BandStop(Chebyshev1Family(ripple: .decibels(0.5)), from: .hertz(300), to: .hertz(900), order: 3)` against its `IIRDesign`; `LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 101)` and `BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 101)` against their `FIRDesign`. `VerifierA/run-probe.sh p431 && python3 VerifierA/wp431_builders.py` | All four are equal, with the same second-order sections and the same taps, bit for bit. The tolerance-scheme form: `ParityTests/row07OrderEstimationThroughTheResponseStages()` designs 48 digital schemes through the `passband:stopband:maximumLoss:minimumAttenuation:` initialisers of the four stages. It gets the oracle's order, natural frequency and design, and fails when one line of the order strategy is broken (mutation P7, see WP-435) |
| Value semantics | The same probe: a value is copied and the copy reassigned. The digest `Docs/API/ZTronDSPDesign.txt` | The original still equals a freshly made `LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)` and differs from the reassigned copy. The four stages are structs, `Hashable` and `Sendable`, with no public stored `var` |
| Names and shapes (§6.3.2, §6.3.3) | The digest (lines 447–458, 481–486, 495–500) against the spellings of §6.3.2–6.3.3; `Scripts/api-digest.sh --check`; `Scripts/compile-fixtures.sh --build` | Each stage has six initialisers. Three take a family: `order:`, `rollOff:rounding:` and the tolerance scheme. Three take a method: `rollOff:stopband:`, `transition:length:` and the tolerance scheme. Each ends in `isActive: some ActivationSource = .active` (ACT-1). The design is the first argument, `some FilterFamily` or `some FIRDesignMethod`. The 10 digests equal the built modules, and 66 public initialisers of 43 stage types end in `isActive:`. 7 valid fixtures compile, and 133 invalid ones fail with their sentences |
| The owner's standing rules and the other gates | `Scripts/lint-bans.sh`; `Scripts/check-dependency-graph.sh`; a search of `Sources/ZTronDSPDesign` for `import Combine`, `AnyView`, `import UIKit` and `@unchecked Sendable` | lint-bans is clean (560 files), and the dependency graph equals §4.2. None of the four occurs in the target. A tolerance scheme is plain arguments, not a specification object (API-6, Appendix A row 7) |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes per §6.3.2–6.3.3, as above.
  - Strategy (§5.3): the family or the method is the first argument, and a tolerance scheme goes through the family's `FilterOrderStrategy`.
  - DEP, EXT and VIS: the gates pass, and the public surface is the committed digest.
  - IMM and API-6: immutable values; no options or configuration object.
  - Sendable: every value is `Sendable` and `Hashable`.
  - Availability: the floor is iOS 15 (`Package.swift:31`), and no declaration of this package needs `@available`.
  - No UIKit, and no approval-gated API.
  - Typed errors: all 157 throwing declarations of the target's digest throw `DSPError`.
  - Threading contract: all 60 public declarations of `Stages/ResponseStages.swift` and the 3 of `Stages/ResponseCore.swift` state theirs ("Usable on any thread" or "Control or background context").

## Findings (VER-4)

None.
