# Verifier report — WP-431c, lens A

| Field | Value |
|---|---|
| Package | WP-431c — `IIRSystem { }`: `Pole`, `Zero`, `Section`, `DifferenceEquation`, the IIR design values |
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
| The package's tests | `ZTD_DEVICE=ztdsp-27-vm4ba ZTD_XCARGS="-test-iterations 3" Scripts/xc.sh test ZTronDSPDesignTests` and the same with `ZTD_CONFIG=Release` | Debug: 334 tests in 40 suites pass, three repetitions each. Release: 334 pass. That includes the 9 tests of the suite "IIRSystem (WP-431c)", among them `conjugatesAreCompletedAndRealRootsStandAlone`, `theBuilderTakesControlFlow` and `anElementWithASwitchOfItsOwnIsRejected` |
| Builder fixtures | `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 7 valid fixtures compile, and 133 invalid ones fail with their sentences. In `valid/DesignStagesOnSampledSequences.swift`, an `IIRSystem` takes zeros and poles, a `HighPass` under `if`, a `for` loop of roots, `if … else` between a `Section` and a `DifferenceEquation`, a `BandBoost` under `if #available`, a `LowShelf` and a `MatchedPeak`. A system is an element of another system (`IIRSystem { hum; Pole(…) }`), and `Filter(hum)` and `.filter(hum)` run it. `invalid/DesignTapsInAnIIRSystem.swift` and `invalid/DesignStageInAnIIRSystem.swift` (a `Gain`) fail with "An IIRSystem holds poles, zeros, sections" |
| Conjugates completed | Probe `p431`: `IIRSystem { Zero(at: Complex(0.3, 0.4)); Pole(at: Complex(0.5, -0.2)); Zero(at: Complex(-0.5, 0)) }`, its `zeros` and `poles` read. `VerifierA/run-probe.sh p431 && python3 VerifierA/wp431_builders.py` | Zeros 0.3 ± 0.4j and −0.5: the conjugate is added, and the real zero stands alone. Poles 0.5 ∓ 0.2j and 0: the conjugate is added, plus the pole at the origin that makes three zeros a causal filter |
| An element with a non-default `isActive` is rejected (ACT-1) | The same probe: `LowPass(…, isActive: false)` and `BandBoost(…, isActive: <a Binding>)` inside an `IIRSystem`, resolved with `secondOrderSections(sampleRate:)`; `LowPass(…, isActive: true)` | Both are rejected when the system is resolved, with `DSPError.invalidParameter` on `isActive`: "element 0 of the system (LowPass) has an isActive of its own: a system is switched whole, through Filter(_:isActive:)" (and the same naming `BandBoost`). `isActive: true` is accepted: it equals the default (ACT-12) |
| Names and shapes (§6.3.7) | The digest `Docs/API/ZTronDSPDesign.txt` (lines 469, 491, 504–505, 512, 519–521, 995–1000); `Scripts/api-digest.sh --check` | `Pole(at:)` and `Pole(radius:frequency:)`; `Zero(at:)`, `Zero(onUnitCircleAt:)` and `Zero(radius:frequency:)`; `Section(b:a:)` with `a = [1]`; `DifferenceEquation(b:a:rootFinder:)` with `rootFinder: some PolynomialRootFinder = .companionQR`, the root-finding strategy of §5.3; `IIRSystem(@IIRSystemBuilder _:)`. The builder has `buildExpression(some IIRSystemElement)`, `buildBlock`, `buildOptional`, `buildEither`, `buildArray` and `buildLimitedAvailability`. An unavailable generic `buildExpression` exists only to give the sentence above, and it is not public surface. `IIRSystem` is a struct and an `IIRSystemElement`, `LTISystem`, `Hashable` and `Sendable`. Its content is an immutable list of type-erased elements. The digests equal the built modules |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes per §6.3.7, as above.
  - Strategy: a `DifferenceEquation` takes its root finder as an argument.
  - DEP, EXT and VIS: the gates pass. Two members are not named anywhere (A-B8).
  - IMM and API-6: immutable values; no configuration object.
  - Sendable.
  - Availability: iOS 15 floor; `if #available` works inside the block.
  - No UIKit, Combine or `AnyView`.
  - Typed errors: every throwing member throws `DSPError`, and an element that does not belong is named in the message.
  - Threading contract: all 57 public declarations of `Systems/SystemElements.swift`, and those of `Systems/IIRSystem.swift`, state theirs. The exceptions are the caseless builder enum, whose members carry the contract, and the unavailable overload.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-B8 | VIS-3; CR-018 item 11 | `Sources/ZTronDSPDesign/Systems/IIRSystem.swift:96, 189`; `Docs/API/ZTronDSPDesign.txt:585, 787` | `IIRSystem.secondOrderSections(sampleRate:)` and `IIRSystem.elementCount` are public. §6.3.7 does not name them. CR-018 item 11, "Additions to the public surface the specification does not name", lists types only. Both are in the committed digest and documented with their context. The same holds for members of WP-431d, WP-439 and WP-440 (see their reports) | non-blocking (backlog): CR-018 should name them |
