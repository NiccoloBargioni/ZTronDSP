# Verifier report — WP-418a, lens A

| Field | Value |
|---|---|
| Package | WP-418a — `IIRDesign`, analog: family × response × order → ZPK and coefficient forms |
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
| Golden over the matrix, analog (STG-2: 5 families × 4 responses × orders 1, 2, 5, 8 = 80 cases against `scipy.signal.iirfilter(…, analog=True)`, 10⁻⁹ relative) | `IIRDesignTests.analogDesignsMatchTheOracleInZeroPoleForm` (poles, zeros, gain, pole count 2n for a band) and `analogDesignsMatchTheOracleInCoefficientForm` (`b`, `a`); the 80 cases counted in the golden file the tests load | Pass, in every run listed above |
| An analog design has no sections (CR-014 item 4) | `IIRDesignTests.anAnalogDesignHasNoSections` | Pass |
| A design is a value; a family written outside the package designs the same way; invalid designs are typed errors | `IIRDesignTests.aDesignIsAValue`, `aFamilyWrittenOutsideThePackageIsDesignedTheSameWay`, `invalidDesignsAreTypedErrors` | Pass |
| The gates the package can affect | `Scripts/api-digest.sh --check` (10 digests equal the build), `Scripts/lint-bans.sh` (clean, 480 files), `Scripts/check-dependency-graph.sh` (equals §4.2), `Scripts/golden.sh --check` (197 files of 27 generators match the manifest) | Pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes (Appendix A row "`newLowPass` … on `ButterWorth`, `Chebyshev1`, `Chebyshev2`, `Elliptic`, `Bessel`"): `IIRDesign(family, response, order:, domain: .analog)` is `IIRDesign.init(_:_:order:domain:)` (IIRDesign.swift:73), read as `.zeroPoleGain` (a stored `let`, :60) or `.transferFunction` (a computed `get throws(DSPError)`, :146). `IIRDesign.Domain` is `.analog` / `.digital(sampleRate:)` (:31), as CR-014 item 6 describes. `FilterResponse` (FilterResponse.swift:12) is listed in CR-018 item 11.
  - Strategy conformance (§5.3, the §5 table row "IIR family"): the family is a `some FilterFamily` argument, boxed in `AnyStrategy` for equality (:48); the static values `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`, `.elliptic(ripple:stopband:)`, `.bessel(normalization:)` are constrained protocol extensions (FilterFamily.swift:179-207), so they read as the table spells them. The family supplies its prototype only; the transformation is shared (FilterFamily.swift:13-15, IIRDesign.swift:191-199), which is what lets a conformer from outside the package design the same way (EXT-1, shown by the test above).
  - The design chain stays in zero-pole form (REAL-1; §7.5, row 4: "Never expanded"): prototype → `transformed(by:)` (IIRDesign.swift:199); the coefficient form is expanded only on request.
  - IMM-1/IMM-2: `public struct` with `let` stored properties only. API-6: response, order and domain are plain arguments; no configuration object (lint part 4 clean). `Hashable`, `Sendable`, no `@unchecked`. Every throwing member is `throws(DSPError)`.
  - VIS-2: every public declaration of IIRDesign.swift, FilterFamily.swift and FilterResponse.swift carries its threading contract (`VerifierB/vis2_scan.py`, 0 findings in each). DEP-1: Core and Accelerate (the C maths library only). PLAT-1: no `@available` above the floor; no UIKit, Combine or `AnyView`.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No finding. | — |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
