# Verifier report — WP-428b, lens A

| Field | Value |
|---|---|
| Package | WP-428b — Stability, minimum and linear phase; the numerical figures of §6.3.8 |
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

- Debug, the whole design target: 334 tests, passed in two runs.
- Release with the verifier's probes: 344 tests, passed.

| Check | How it was run | Result |
|---|---|---|
| Figures for the stress fixtures (WP-016) equal recorded values | `SystemAnalysisFigureTests/theFiguresOfTheStressFixturesEqualTheirRecordedValues()`, with `theRootConditionsOfThePolynomialFixturesAreReported()`, `linearPhaseIsReadFromTheTaps()` and `theRoundOffGainIsTheEnergyOfWhatFollowsEachSummingNode()` | pass |
| Analog criteria use the half plane | `theAnalogCriteriaUseTheHalfPlane()` and `aPoleOnTheUnitCircleIsNotStableInEveryForm()` | pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - **Names and shapes (§6.3.8).** Every member of the table is present (digest 672–681, 864–879), the stored ones as `let`:
    - `zeros`, `poles`, `gain`, `isStable`, `stabilityMargin`, `isMinimumPhase`, `isLinearPhase`, `order`, `kind`, `sections`, `rootConditions`, `singleVersusDoubleDeviation`, `recommendedPrecision`;
    - the methods `frequencyResponse(at:)`, `magnitudeResponse(at:in:)`, `phaseResponse(at:unwrapped:)`, `groupDelay(at:)`, `impulseResponse(count:)`, `stepResponse(count:)` and `roundOffNoiseGain(precision:)`.

    `groupDelay` returns `nil` where the delay is undefined, as §6.3.8 says. `SystemKind` and `RootConditions` are named in CR-018 item 11.
  - **Immutability and Sendable (IMM, BG-2).** `SystemAnalysis` stores `let`s only (`SystemAnalysis.swift:59–118`) and is `Sendable`, `Hashable` and `LTISystem` (digest 338–343).
  - **Typed errors.** Every throwing member is `throws(DSPError)`.
  - **VIS-2.** `Systems/SystemAnalysis.swift` has 32 public declarations, all documented. One names no threading context: `SystemKind` (line 5) (finding 1).
  - **Public additions** named in neither §6.3.8 nor a change request (finding 2):
    - `SystemAnalysis.sampleRate` and `SystemAnalysis.taps` (digest 874, 878).
    - The `[Double]` overloads of `frequencyResponse(at:)` and `groupDelay(at:)` (digest 672, 674).
  - **Gates.** `Scripts/api-digest.sh --check`, `Scripts/check-dependency-graph.sh` and `Scripts/lint-bans.sh` pass.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| 1 (BL-1) | Public API documented with its threading contract | `Sources/ZTronDSPDesign/Systems/SystemAnalysis.swift:5` | The doc of `SystemKind`, "Whether the impulse response of a system ends", names no threading context. It is a `Sendable` enum, so the contract can be inferred. | non-blocking |
| 2 (BL-2) | Public API per §4–§8 | `Docs/API/ZTronDSPDesign.txt:672, 674, 874, 878` | `sampleRate`, `taps` and two `[Double]` overloads are public and named neither in §6.3.8 nor in CR-018 item 11. Each is an addition: nothing of the specification is missing or changed. | non-blocking |

## Change requests filed (FIX-4)

None by this verifier.
