# Audit of Verifier B — milestone M4, first half (WP-401 … WP-421, WP-428a, WP-429, WP-430)

| Field | Value |
|---|---|
| Audited | Verifier B's verification of the 25 packages: `Docs/Process/reports/WP-<id>-B.md`, `VerifierB/`, the run outputs it left under `.build/` |
| Auditor | Claude (agent). Took no part in the verification. Read nothing Verifier A wrote (no other `v-…` folder, no `WP-4*-A.md`) |
| Revision | The verifier's checkout: main tree snapshot 2026-11-17 20:05, after CR-023 |
| Simulator | `ztdsp-27-vm4ab` only |
| Date | 2026-11-17 |
| Result | B-1 **confirmed, blocking** (WP-402, WP-410), reproduced. Two gaps, both in the lens-A reports; neither changes a verdict (§2). Five spot checks of `pass` verdicts: all hold (§3) |

## 1. Blocking findings (duty 1)

| Finding | Packages | Verdict | Severity (§11.6) | Reproduced by the auditor | Evidence |
|---|---|---|---|---|---|
| B-1 — `DoubleDouble.swift` below COV-3 | WP-402, WP-410 | **confirmed** | **blocking**: coverage is below COV-3 | yes | I ran a fresh instrumented build in a derived-data folder of my own. The whole design test target, 332 tests in 39 suites, passed. The gate printed `DoubleDouble.swift 92.11 % (70 of 76 lines), needs 97.50 %: FAIL`. The only missed lines are 65-70, the operator `+ (DoubleDouble, Double)`, which nothing calls. Details below. |

**The rule.**
- COV-3 (§10.2, line 1727): "the files a package adds or changes are at ≥ 97.5 %, or the package is not done".
- Its one exception, E-17, covers a branch tied to an OS version the simulator matrix cannot host. It does not apply: lines 65-70 run on any simulator once something calls them. The ledger rows of WP-402 and WP-410 (164 and 172) list no E-17 entry and no backlog item. The ledger's only E-17 row is WP-338's.
- COV-4 (b) does not apply either. `Sources/ZTronDSPDesign` holds no `coverage:ignore` mark, and an operator that nothing calls is dead code, not an unreachable defensive branch.
- §11.6 (line 1805) makes "coverage is below COV-3" blocking.

The finding quotes both rules correctly. It rests on COV-3 alone; no acceptance statement of a row is involved.

**Change requests.** None describes the deviation. `grep -i` over CR-001 … CR-023 for `DoubleDouble`, `double-double`, `ExtendedHorner`, `COV-3` and `coverage` finds six lines:
- CR-014 item 7: the root polish evaluates in double-double arithmetic. It says nothing about coverage.
- Five lines about other things:
  - CR-010 and CR-013: coverage turned off for a benchmark and for C loops;
  - CR-021 and CR-023: test counts;
  - CR-022: the constant-Q packages of M5c, whose coverage is left to WP-902.

**Pristine sources.**
- These three files are byte-identical (`cmp`) to `/Users/admin/Documents/ZTronDSP`:
  - `Math/DoubleDouble.swift` (SHA-256 `96855a7b…`);
  - `Math/PolynomialRootFinder.swift` (`8237a83a…`);
  - `Prototypes/BesselPolynomial.swift` (`76b28722…`).
- The whole of `Sources/ZTronDSPDesign` equals the owner's tree (`diff -rq`, exit 0). `Tests/ZTronDSPDesignTests` differs only by `CoverageDoubleDoubleTests.swift`, which exists only in the owner's tree (see below).
- In the checkout, `Sources/`, `Tests/`, `Scripts/` and `Package.swift` each equal the verifier's own pristine copy `.build/pristine` (`diff -rq`, exit 0).
- Outside the reports and `VerifierB/`, 54 files differ between the checkout and the owner's tree. Another 29 entries exist only in the owner's tree, and none exists only in the checkout.
  - All 83 have an owner-side ctime between 2026-11-17 20:45:21 and 22:32:47. The files inside the two folders that exist only in the owner's tree date from 21:09:30 to 22:25:39.
  - So every difference comes after the 20:05 snapshot: the merge at 20:45, then later edits to the live tree.
- The verifier left nothing behind.

**Reproduction.**
- Build. It went into a derived-data folder of my own, so nothing rested on the verifier's build state: `ZTD_DEVICE=ztdsp-27-vm4ab ZTD_DERIVED=$ROOT/.build/xcode-cov-aud ZTD_XCARGS="-enableCodeCoverage YES -only-testing:ZTronDSPDesignTests" Scripts/xc.sh build`. Result: TEST BUILD SUCCEEDED.
- Test.
  - First I removed any earlier profile data and result bundle. Then I ran `ZTD_DEVICE=ztdsp-27-vm4ab ZTD_DERIVED=… ZTD_XCARGS="-enableCodeCoverage YES -resultBundlePath $ROOT/.build/cov-AUD.xcresult" Scripts/xc.sh test-only ZTronDSPDesignTests`.
  - The log records it as `xcodebuild … -configuration Debug … -enableCodeCoverage YES … test-without-building -only-testing:ZTronDSPDesignTests`.
  - Result: 332 tests in 39 suites passed.
- Line report: `python3 .build/covtools/cov.py export <derived data> .build/covtools/export-AUD.json`, then `cov.py convert … .build/covtools/lines-AUD.json llvm`. The tools in `.build/covtools/` (`cov.py`, `run.sh`, `uncovered.py`, `final.sh`, `all-files.txt`) are byte-identical to `ZTronDSP-handoff/tools/coverage/`.
- Gate: `TMPDIR=$ROOT/.build/tmp python3 Scripts/lib/coverage_gate.py --report .build/covtools/lines-AUD.json --mode changed-files < VerifierB/cov-files.txt`.
  - It prints `DoubleDouble.swift 92.11 % (70 of 76 lines), needs 97.50 %: FAIL`.
  - The other 22 files with executable lines are at or above 97.5 %. The lowest is `SystemAnalysis.swift`, at 98.29 %. `Bandwidth.swift` has no executable lines.
  - `python3 .build/covtools/uncovered.py .build/covtools/lines-AUD.json -- Sources/ZTronDSPDesign/Math/DoubleDouble.swift` lists lines 65-70 and nothing else.
- My figures equal the verifier's. For all 23 files with figures, my gate's numbers are identical to its B2 gate (`.build/cov-gate-B2.txt`). Its B1 line report (`lines-B1.json`) gives the same 70 of 76 lines for `DoubleDouble.swift`, missing 65-70.

**Static check: nothing can reach the operator.**
- `DoubleDouble` is `internal`. Outside its own file, the module uses it only in two places:
  - `PolynomialRootFinder.swift`, lines 153, 175, 178 and 184;
  - `BesselPolynomial.swift`, lines 29, 34-41, 84, 92 and 129-130.
- Those lines use only `DoubleDouble(_:)`, `.value`, `DD · Double` and `DD / Double` (the Bessel recurrence, line 41) and `ExtendedHorner.evaluate`. Every addition inside `ExtendedHorner.evaluate` (DoubleDouble.swift:120-125) adds a double-double to a double-double.
- No test names `DoubleDouble`, `.hi`, `.lo`, `ExtendedHorner` or `extendedCoefficients` (grep over `Tests/`). So a run of every test target would leave lines 65-70 unrun too.

**Attribution to both packages is supported.**
- The file's own header names both uses: the Newton polish of the root finder ("§7.5, row 12") and the roots of the reverse Bessel polynomial ("row 4").
- Each package's stability note relies on it: `polynomial-roots.md:35` for WP-402 and `bessel-roots.md:24` for WP-410.
- Neither package depends on the other (WP-402: Dep 401; WP-410: Dep 107). Under WP-R4 each must therefore deliver what it uses.

**Corroboration, and context for the integrator.**
- The integrator's own coverage-closure brief already lists `Sources/ZTronDSPDesign/Math/DoubleDouble.swift 92.11` (`ZTronDSP-handoff/briefs/11-core-coverage-closure.md:30`, file last modified 2026-11-15).
- The test that work produced, `Tests/ZTronDSPDesignTests/CoverageDoubleDoubleTests.swift`, exists only in the owner's tree. It calls exactly `DoubleDouble + Double`, in `addingADoubleKeepsWhatARoundedSumLoses` and `addingADoubleIsAddingTheDoubleDoubleWithNoLowWord`.
- Its mtime is 2026-11-16 03:36:14 and its ctime 2026-11-17 20:45:22. It entered the main tree with the 20:45 merge, after the 20:05 snapshot this verification reviewed.
- So B-1 stands for the revision reviewed. The current main tree very probably resolves it. Lens T must confirm that on the new revision (FIX-1), and both packages stay blocked until both lenses report no blocking finding on one revision (FIX-2).

## 2. Gaps in the verification (duty 2)

All 25 report files exist.
- Each uses the second lens of its row: T for 20 packages, and A for WP-403, 418a, 418b, 419 and 428a, whose rows are "N, A".
- Each states the revision reviewed and the verdict that was returned.
- Where I checked the evidence the reports cite, it holds (see below).

I found two gaps, both in lens A.

| # | Package | Gap | What I found when I checked |
|---|---|---|---|
| G-1 | WP-419 | The report does not show Strategy conformance (§5.3, a lens-A item of §11.5). It names `rounding: RollOffRounding = .exact()` under names and shapes and calls it a Core type of WP-103, but does not check it against §5.3. | §5.3 lists `RollOffRounding` as the strategy for "Order from a slope". It says every strategy sits behind a public protocol that a conformer outside the package can adopt, and VIS-1 makes extension points `public protocol`. `RollOffRounding` is a `public enum` (`Sources/ZTronDSPCore/Units/RollOff.swift:4`), so no outside conformer can be passed. No change request records this (grep of CR-001 … CR-023 for `RollOffRounding`). By contrast, CR-023 item 8 records `ConvolutionStrategy` as an enum. The type belongs to WP-103 (ledger: Verifying), so any finding belongs there. WP-419's own initialiser takes the value where the design is declared, as §5.3 asks. I would not change WP-419's verdict for it. |
| G-2 | WP-403, 418a, 418b, 419, 428a | Some lens-A items go unnamed: Decorator conformance in all five reports, Strategy conformance in WP-418b, and API-6 in WP-428a. | Nothing to find. Decorators belong to stages, which decorate a description (§5.5.2, line 650), and these packages add design values, not stages. WP-418b's strategy is the `FilterFamily` that WP-418a checked. WP-428a's `LTISystem` takes no options. A documentation gap only. |

| Package | Lens | Verdict | Acceptance checks of the row: run, how, result | Lens duties shown |
|---|---|---|---|---|
| 401, 402, 404 … 417, 420, 421, 429, 430 | T | pass (402 and 410: blocking, B-1) | Every clause of each acceptance statement is matched to named tests. Those tests ran in each run listed: Debug; five iterations, instrumented; Release, three iterations; after the mutations | The changed line or lines and the tests that then failed: 55 mutations in 56 runs, every one killed, every restore `cmp`-identical. COV-3 per file. Determinism (grep for generators, clocks and sleeps). Negative paths. Each of the 20 reports has all four |
| 403, 418a, 418b, 419, 428a | A | pass | Named tests, run in the same runs | Names and shapes against §6.3, Appendix A and the digest. Strategy conformance (403, 418a, 428a; see G-1 and G-2). DEP-1, EXT-1, VIS-2. IMM, and API-6 except 428a. `Sendable`. Typed throws. PLAT-1. No UIKit, Combine or `AnyView` |

**The verifier's run claims, checked against the logs it left.**
- `.build/run1.out`: 178 tests in 16 suites pass.
- `flaky-iter5.full.log`: `-configuration Debug -enableCodeCoverage YES -test-iterations 5`, over the 17 suites. Each of the 181 tests started five times, 905 executions in all, and no issue was recorded.
- `release-test.full.log`: `-configuration Release -test-iterations 3`. Each of the 181 tests started three times, 543 executions in all, and no issue was recorded.
- `covtest-B1.out` and `covtest-B2.out`: 178 tests in 16 suites, and 332 tests in 39 suites, pass.
- `final-test.out`: 181 tests in 17 suites pass after the restore.
- Gates.
  - In `gates-final.out`, `lint-bans.sh` is clean (480 files) and `check-dependency-graph.sh` equals §4.2.
  - In the same file, `api-digest.sh --check`, `golden.sh --check` and `ledger.sh --check` stopped with exit 127 on a quoting error ("no such file or directory: Scripts/api-digest.sh --check").
  - The re-run, `gates-final-2.out`, passes all three: 10 digests equal the built modules, 197 files of 27 generators match the manifest, and the ledger's 289 rows are consistent with §12 and §11.
- Golden reproduction (`.build/tmp/golden-reproduce.out`): the batch's seven generators reproduce their committed files bit for bit under numpy 2.2.6 and scipy 1.15.3. The seven are `analog_prototypes`, `cookbook_equalizers`, `elliptic_functions`, `frequency_transformations`, `iir_design`, `iir_order` and `section_pairing`.
- Mutations.
  - `VerifierB/mutation-results/summary.tsv` holds 56 runs of 55 mutations. Every row built, failed its suite (`test=65`) and was restored identical, except one. The exception is the first attempt at `WP-430.2`, which did not compile and was run again, as `VerifierB/README.md` says.
  - I checked all 25 reports with a script of my own: 0 mismatches. The per-test issue counts of all 55 "Killed:" lines equal the test outputs kept in `VerifierB/mutation-results/*.test.out`, and their sums equal the totals in `summary.tsv`.

**Case counts and tolerances the reports cite, checked against the committed files.**
- Case counts:
  - `analog_prototypes.json`, 275 cases:
    - Butterworth 20 (orders 1-20);
    - Chebyshev I 36 and Chebyshev II 36;
    - elliptic 108;
    - Bessel 75 (orders 1-25 in three normalisations).
  - `frequency_transformations.json`: 270 (45 low-pass, 45 high-pass, 90 band-pass, 90 band-stop).
  - `iir_order.json`: 96 (4 families × 24).
  - `iir_design.json`: 160 designs (16 analog and 16 digital per family), beside its frequency grid.
  - `cookbook_equalizers.json`: 156 (36 peaking, 60 low shelf, 60 high shelf).
  - `elliptic_functions.json`: 25.
  - `section_pairing.json`: 27.
  - `buttap.json`: 20, which no test reads, as B-BL-5 says.
- The tests' tolerances equal the rows:
  - 10⁻¹² for the elliptic tables (`EllipticFunctionTests.tolerance`);
  - 10⁻¹² for the Bessel residual;
  - 10⁻¹² absolute for the Cookbook coefficients;
  - 10⁻¹⁰ with κ ≤ 10⁴ for the root finder's well-conditioned fixtures.

**Lens-A claims, checked by grep over the 24 files of `VerifierB/cov-files.txt`.** I first checked each pattern against a file of positive controls.
- No `@available` or `#available`.
- No Combine, UIKit, SwiftUI or `AnyView`. The imports are `ZTronDSPCore` (24 files) and `Accelerate` (9).
- No `@unchecked` and no `nonisolated(unsafe)`.
- No untyped `throws` and no `rethrows`. `throws(DSPError)` appears 121 times.
- No `@_spi`, `package` or `@testable`.
- No `fatalError`, `precondition`, `assert` or `try!` at all, so nothing of the kind §9.3 forbids can be reached from public API.
- I re-ran `VerifierB/vis2_scan.py`. It reports one declaration: `SystemKind`, which is B-BL-1, passed on to WP-428b.
- A stricter check of my own, on the package's contract phrasings, adds only `analysis(sampleRate:)` (SystemAnalysis.swift:443, WP-428b). Its documentation states its context in other words: "The work runs on `BackgroundWork`, never on the main thread and never on an audio thread (BG-1)".

## 3. Spot checks: five `pass` verdicts, where the evidence was thinnest

**Choice.**
- WP-403, 418a, 419 and 428a have no lens T, so nobody had shown that their acceptance tests fail when the code breaks.
- For WP-401, the verifier mutated evaluation and the derivative (`Polynomial.swift` lines 71, 81 and 93), not the product or the constructors from roots.

**Method.** Each check changes one line, builds into `.build/xcode-cov-aud` and runs the suite on `ztdsp-27-vm4ab`. It then restores the file and compares it with `cmp` against both `.build/pristine` and the owner's tree.
- The harness is `.build/audit/spot.sh`, using `spot.tsv`. Both are removed with `.build`; the five rows of `spot.tsv` are the table below (file, line, old text, new text, suite).
- It applies each line with `VerifierB/apply_mutation.py`, unchanged.
- All five rows built (exit 0), failed their suite (exit 65) and were restored identical.

| Package (lens, verdict) | Line changed | Suite | Result |
|---|---|---|---|
| WP-401 (T, pass): product and from-roots | `Math/Polynomial.swift:124`, in `multiply`: `where a != 0` → `where a > 0` (the product skips negative coefficients) | PolynomialTests | **Killed**: 4 of 11 tests fail, 34 issues. `theProductEvaluatesToTheProductOfTheValues` (18), `aPolynomialFromRealRootsVanishesAtThem` (3), `aPolynomialFromConjugateRootsHasRealCoefficientsAndVanishesAtThem` (6), `theDerivativeFollowsThePowerRuleAndTheProductRule` (7). The verdict holds |
| WP-403 (A, pass): round trips | `Systems/ZeroPoleGain.swift:72` `-2 * pair.real` → `2 * pair.real` (ZPK → coefficients) | RepresentationTests | **Killed**: 3 of 15 tests fail, 8 issues. `zerosPolesGainToCoefficientsAndBack` (3), `coefficientsToZerosPolesGainAndBack` (3), `theThreeFormsDescribeTheSameSystem` (2). The verdict holds |
| WP-418a (A, pass): analog golden over the matrix | `IIR/IIRDesign.swift:196`, band-stop: `bandwidth: edges[1] - edges[0]` → `edges[1] + edges[0]` | IIRDesignTests | **Killed**: 6 of 12 tests fail, 664 issues. `analogDesignsMatchTheOracleInZeroPoleForm` (26) and `analogDesignsMatchTheOracleInCoefficientForm` (164). Also `aDigitalEdgeLandsExactlyWhereItWasAskedFor` (8) and WP-418b's three digital golden tests (46, 80 and 340). The verdict holds |
| WP-419 (A, pass): slope ±0.5 dB/oct, band-stop takes the order | `IIR/IIRDesign.swift:108`: the order from the roll-off `+ 1` | RollOffTests | **Killed**: 7 of 8 tests fail, 204 issues. They include every slope test: `theAnalogSkirtOfAnAllPoleFamilyHasExactlyTheSlope` (40), `aDigitalHighPassFallsTowardsZeroHertzByExactlyTheSlope` (20), `aDigitalLowPassHasTheSlopeInOctavesThatEndBelowAThirtySecondOfTheSampleRate` (20) and `aBandPassHasTheSlopeOnEachSkirtAndTwiceTheOrder` (90). They also include `aBandStopTakesTheOrderOnly` (12). `aDigitalLowPassSteepensTowardsNyquist` passes. The verdict holds |
| WP-428a (A, pass): fixtures with a pole on the unit circle, and an analog system | `Systems/SecondOrderSections.swift:56`: poles read as the roots of `x² − a1·x + a2` | LTISystemRootsTests | **Killed**: 2 of 7 tests fail, 65 issues. `aDesignReportsTheSameRootsFromEveryForm` (60), `aPoleOnTheUnitCircleIsNotStable` (5). The verdict holds. See observation 3 |

**Control.** With every file restored, I rebuilt the derived data and ran the whole design test target again: 332 tests in 39 suites passed.
- The SHA-256 of each of the four touched files is the same before and after.
- Each touched file is `cmp`-identical to `.build/pristine` and to the owner's tree.
- `Sources`, `Tests`, `Scripts` and `Package.swift` equal `.build/pristine`.

## 4. Observations for the integrator (not gaps)

1. **Severity of B-BL-2 (WP-414).** `DSP.prewarpedAngularFrequency(hertz:sampleRate:)` is public (`Bilinear.swift:14`; digest line 974).
   - It is listed nowhere: not in §4–§8, not in Appendix A, which names only the two `bilinear(sampleRate:)`, not in CR-018 item 11, and in no change request (grep for `prewarp`).
   - VIS-3 makes a change of the public surface a change request. §11.6 makes "public API differs … without a change request" blocking.
   - The report rates it non-blocking. Its reading is that the WP-414 row names pre-warping, and the change request's list is only incomplete.
   - WP-414's lenses are N and T, so no verifier owns this check. A one-line amendment to CR-018 item 11, or making the function internal, settles it either way.
   - The same applies to `Bandwidth` and `SecondOrderSections.Section` (B-BL-4), with less weight: §6.3.5 implies `Bandwidth` through its three forms, and §6.3.1 leaves the members of `SecondOrderSections` open.
2. **COV-3 for the files of the lens-A packages** is owned by neither lens of those rows. It falls under item 3 of the definition of done (§11.8), the integrator's check. In my run:
   - `IIRDesign.swift`, `FilterFamily.swift` and `FilterResponse.swift`: 100 %;
   - `ZeroPoleGain.swift`, `SecondOrderSections.swift` and `LTISystem.swift`: 100 %;
   - `TransferFunction.swift`: 98.61 %.
3. **The analog fixture of WP-428a.** Under the spot-check mutation, `anAnalogSystemIsJudgedByTheHalfPlane` still passes, for three reasons:
   - it checks its analog cascade's poles only by count (LTISystemTests.swift:129);
   - the cascade's stability and margin come from `poleExtents()` (SecondOrderSections.swift:151-160), not from the roots;
   - the oscillator has `a1 = 0`.

   The digital fixtures catch the mutation, and the reading has no domain branch, so the acceptance is still exercised. Comparing the analog cascade's poles by value would let the analog fixture stand on its own. Backlog, non-blocking.
4. **Evidence held only under `.build`.** The clean-up removes these:
   - the verifier's golden-reproduction log (`.build/tmp/golden-reproduce.out`);
   - the full logs of its mutation runs (`.build/mutation-*.test.log`);
   - its report generators (`.build/tmp/*.py`);
   - my own harness and outputs (`.build/audit/`, `.build/covtools/*-AUD.json`).

   Their results are quoted above, and `VerifierB/mutation-results/` keeps every mutation's diff and test summary.
