# Verifier report — WP-428a, lens A

| Field | Value |
|---|---|
| Package | WP-428a — `LTISystem` analysis: zeros, poles, gain, for digital and analog systems |
| Lens | A (API, architecture, platform): the second lens of the package's row in §12 |
| Verifier | B — Claude (agent). Not the implementer, not Verifier A, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-17 20:05, after CR-023 |
| Fix cycle | 0 |
| Verdict | `pass` |

## What was received (VER-2)

- [x] The brief
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified
- [x] The test, lint and coverage output (produced again by the verifier in that checkout)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

Runs, all on the simulator `ztdsp-27-vm4ab` through `Scripts/xc.sh` (commands in `VerifierB/README.md`): (1) the tree as received, Debug: the batch's 16 suites, 178 tests, pass; (2) five repetitions (`-test-iterations 5`) of those suites and `SystemAnalysisTimeResponseTests`, 181 tests, on an instrumented Debug build: no failure; (3) the two instrumented runs for COV-3, B1 (the 16 suites) and B2 (the whole design test target, 332 tests in 39 suites): both pass; (4) Release, `-test-iterations 3`, the 181 tests: pass, 543 executions (each of the 181 tests three times), no failure; (5) after the 56 mutation runs (55 mutations, every one killed; one row run twice, see `VerifierB/README.md`), the restored tree (`diff -r` against the pristine copy: identical) rebuilt and the 181 tests run again in Debug: pass, no failure. Gates, run last on the restored tree: `Scripts/lint-bans.sh` (clean, 480 files), `Scripts/api-digest.sh --check` (10 digests equal the build), `Scripts/golden.sh --check` (197 files of 27 generators match the manifest), `Scripts/check-dependency-graph.sh` (equals §4.2), `Scripts/ledger.sh --check` (289 rows): all pass. The batch's seven golden generators, rerun from the pinned oracles (numpy 2.2.6, scipy 1.15.3) in a scratch copy, reproduce their committed vectors bit for bit (`Scripts/golden.sh --reproduce`).

| Check | How it was run | Result |
|---|---|---|
| Fixture: a pole on the unit circle (digital) | `LTISystemRootsTests.aPoleOnTheUnitCircleIsNotStable`: one pole at 1 among poles inside (margin exactly 0, not stable), the accumulator z/(z − 1) in all three forms, an undamped resonator (a₂ = 1) at four angles, poles at −1 and ±j, a pole at 0.999 (stable, margin 10⁻³) and a pair outside | Pass, in every run listed above |
| Fixture: an analog system | `LTISystemRootsTests.anAnalogSystemIsJudgedByTheHalfPlane`: (s² + 9)/((s + 0.5)(s² + 2s + 5)) stable with margin 0.5 and minimum phase (zeros on the axis), the same roots misread as digital are neither; its coefficient form and roots from coefficients to 10⁻¹⁴ | Pass |
| Zeros, poles and gain read from every form; roots of a coefficient form through the root finder | `LTISystemRootsTests.aDesignReportsTheSameRootsFromEveryForm` (sections against ZPK, 10⁻¹²), `coefficientsGiveTheirRootsThroughTheRootFinder` (analog and digital, orders 1-2, 10⁻⁹) | Pass |
| A conformer needs only its roots; minimum phase; no poles | `LTISystemRootsTests.aConformerOnlyNeedsItsRoots`, `minimumPhaseLooksAtTheZeros`, `aSystemWithoutPolesIsStable` | Pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes (§6.3.8 row "`zeros`, `poles`, `gain`"; Appendix A row "`ZeroPoleGain`, `TransferFunction`: poles, zeros, evaluation, magnitude, phase → the same-named types and `LTISystem` analysis"): `public protocol LTISystem: Sendable` (LTISystem.swift:67) requires `domain`, `zeros`, `poles`, `gain` (:70-84); everything else is supplied by its extension (:126 on), so the three representations of §6.3.1 adopt it (ZeroPoleGain.swift:15, TransferFunction.swift:24, SecondOrderSections.swift:20) and so can a conformer from outside the package (EXT-1, shown by the test above). `SystemDomain` (:8) is listed in CR-018 item 11.
  - The sources of the roots are those of §6.3.8: read from the stored ZPK form, in closed form per section (SecondOrderSections.swift:131-140), and through the injected `PolynomialRootFinder` strategy (§5.3, default `.companionQR`) only for a system given as coefficients (TransferFunction.swift:85-108).
  - Digital and analog: the domain is part of every value, and the criteria choose by it (LTISystem.swift:206-223: unit circle versus half plane).
  - The root members are `get throws(DSPError)` (the coefficient form's root finder can fail); every throwing member of LTISystem.swift is typed. IMM: the conformers are `struct`s with `let` stored properties. `Sendable` on the protocol; no `@unchecked`.
  - VIS-2: every public declaration of LTISystem.swift, ZeroPoleGain.swift and TransferFunction.swift carries its threading contract (`VerifierB/vis2_scan.py`, 0 findings each). DEP-1: Core and Accelerate. PLAT-1: nothing above the iOS 15 floor; no UIKit, Combine or `AnyView`.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No finding. | — |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
