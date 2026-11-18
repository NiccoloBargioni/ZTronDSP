# Verifier report — WP-418b, lens A

| Field | Value |
|---|---|
| Package | WP-418b — `IIRDesign`, digital: pre-warp, bilinear, section pairing → SOS |
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
| Golden over the matrix, digital (STG-2: 5 families × 4 responses × orders 1, 2, 5, 8 = 80 cases in `iir_design.json`, counted, against `iirfilter(…, analog=False)`, 10⁻⁹ relative) | `IIRDesignTests.digitalDesignsMatchTheOracleInZeroPoleForm`, `digitalDesignsMatchTheOracleSectionForSection` (against `output='sos'`, ⌈poles/2⌉ sections, 5 coefficients each), `digitalDesignsMatchTheOracleInCoefficientForm` | Pass, in every run listed above |
| Pre-warp: the edges land where they were asked for; a sample rate of 1 means cycles per sample; filters at the edges of the band keep their poles | `IIRDesignTests.aDigitalEdgeLandsExactlyWhereItWasAskedFor`, `aSampleRateOfOnePutsTheEdgesInCyclesPerSample`, `stressTheFiltersAtTheEdgesOfTheBandKeepTheirPoles` | Pass |
| Invalid digital designs (edge at or above Nyquist, bad sample rate) are typed errors | `IIRDesignTests.invalidDesignsAreTypedErrors` | Pass |
| The gates the package can affect | `Scripts/api-digest.sh --check`, `Scripts/lint-bans.sh`, `Scripts/check-dependency-graph.sh`, `Scripts/golden.sh --check` | Pass |

## Lens checklist (§11.5)

- **A — API, architecture, platform.**
  - Names and shapes (Appendix A, the `IIRDesign` row: "`domain: .digital` for the real-time path"): `IIRDesign.Domain.digital(sampleRate:)` (IIRDesign.swift:36) carries the rate, as CR-014 item 6 describes; its edges are in hertz (doc, :34-35). `secondOrderSections` (:154) is the form the kernel runs (REAL-1), a computed `get throws(DSPError)` that throws `unsupportedConfiguration` for an analog design (CR-014 item 4).
  - The chain of §6.3.2 is the one implemented, all in zero-pole form: the edges are pre-warped in double precision onto the oracle's internal rate of 2 (:183, `4·tan(π·(2f/fs)/2)`), transformed (:199), mapped by `ZeroPoleGain.bilinear(sampleRate: 2)` (:202) and paired by the nearest rule (`secondOrderSections()`, SectionPairing.swift). No polynomial is expanded on the way (§7.5, row 4).
  - IMM-1/IMM-2, API-6, `Hashable`/`Sendable`, typed `throws(DSPError)`: as for WP-418a (the same type); no configuration object, the sample rate is a plain associated value.
  - VIS-2: IIRDesign.swift, SectionPairing.swift, SecondOrderSections.swift and Bilinear.swift, 0 findings each (`VerifierB/vis2_scan.py`). EXT-1 / VIS-1: nothing `@_spi` or `package`. DEP-1: Core and Accelerate. PLAT-1: nothing above the iOS 15 floor; no UIKit, Combine or `AnyView`.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| — | — | — | No finding. | — |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: first verification.

## Change requests filed (FIX-4)

None filed with this report.
