# WP-905b — implementer's report

| Field | Value |
|---|---|
| Package | WP-905b: audit of the algorithm and stability registers, rows 7 to 12 (§7.2, §7.3, §7.5) |
| Implementer | Implementer M9-registers (agent), brief 64 with the common rules of brief 60 |
| Date | 2026-11-21, and 2026-11-22 after midnight for the gate run of section 3; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `53a095d`. Everything below is unstaged or untracked. This work committed nothing and added nothing to the index |
| Ledger | WP-905b `Verifying`, implementer `Implementer M9-registers (agent)` |
| Change request | None |

The audit of rows 7–12, with every measured figure and every mutation, is in `Docs/Numerics/register-audit-2026-11.md`: the table, then "WP-905b: rows 7 to 12". The check and its self-test are WP-905a's (`impl-WP-905a.md`).

## 1. Files

### Added

| File | What it is |
|---|---|
| `Docs/Process/reports/impl-WP-905b.md` | This report |

### Changed

| File | What changed |
|---|---|
| `Docs/Numerics/register-audit-2026-11.md` | Rows 7–12 of the table and the section "WP-905b: rows 7 to 12" |
| `Tests/ZTronDSPDesignTests/PolynomialRootFinderTests.swift` | New test `stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic`. Kahan's quadratic added to `degreeTwoUsesTheClosedFormWithoutCancellation` |
| `Tests/CZTronDSPTests/PartitionedKernelTests.swift` | New test `PartitionedKernelTests.subnormalInputGivesExactZerosOnBothPaths` |
| `Docs/Numerics/polynomial-roots.md` | The mitigation of multiple roots stated as measured; the new tests and the mutations of 2026-11-21 |
| `Docs/Numerics/partitioned-processing.md` | The new test; the flush of the delay line recorded as equivalent at the output, with the reason |
| `Docs/Numerics/fir-direct.md`, `partitioned-structure.md`, `decimator.md`, `interpolator.md`, `autocorrelation.md`, `one-shot-convolution.md` | One paragraph each: the mutations of 2026-11-21 and what failed |
| `Docs/Numerics/currency-2026-11.md` | The second pass (shared with WP-905a, c and d) |

### Deleted

None. A temporary experiment file, `Tests/ZTronDSPDesignTests/M9ExperimentR12Tests.swift`, was written at 21:3x to survey clusters of roots with and without the test of the residual, and deleted before the new test was written. It appears in no run of the gates.

`git diff --stat -- Sources` is empty after the last mutation of the package.

## 2. Items

The mutation logs are `.build/logs/m9-registers/batch-row7-12.log`, `batch-row8-12b.log`, `batch-row8-12c.log` and `mut-R12-keep-2.log`, each restored by `cmp` against the saved copy.

| Row | Currency (2026-11-21) | Notes checked | Figures | Mutations | Tests added or strengthened | Findings |
|---|---|---|---|---|---|---|
| 7 FIR, short (WP-212) | current (read with row 1) | `fir-direct.md`: true | 0.46603 … 0.00032499 of the bound, 1 to 1 500 taps | 2 run, 2 killed | none needed | none |
| 8 FIR, long (WP-214, WP-215) | current: arXiv 2509.04390 (GPU, 2025), JAES 2025 | `partitioned-structure.md`, `partitioned-processing.md`: true | 1.3154e-7; −120.77 … −134.08 dB, the note's table | 6 run: 5 killed (one only by the new test), 1 equivalent | `subnormalInputGivesExactZerosOnBothPaths` | cited open: CR-013 item 6 |
| 9 Rate changes (WP-213, WP-223) | current | `decimator.md`, `interpolator.md`: true | alias −99.543 dB; images −99.584, −95.889, −98.189 dB | 5 run, 5 killed (the input cleaning is row 7's, shared) | none needed | cited open: A-27, A-28, A-31 (wave 3, WP-539) |
| 10 One-shot convolution (WP-513) | current: arXiv 2506.12718 | `one-shot-convolution.md`: true | 0.93535 ε; 6.5565e-7; 2.0048e-6; 281 and 1; 27 843; the STG-2 grid | 4 run: 3 killed, 1 survived (F-905b-1) | none | F-905b-1 (low); cited open: A-1, B-2, A-3, B-4, A-NB1, A-NB2, A-NB4, A-NB23 |
| 11 Autocorrelation (WP-515) | current (with row 10) | `autocorrelation.md`: true | 2.8278e-7, 2.4672e-7, 431, 2.4511e-8, 7.9473e-8, 0.99999994; 8.2187e-8, 7.0079e-7 | 4 run, 4 killed | none needed | cited open: A-5, B-6, A-NB3 |
| 12 Polynomial roots (WP-402) | current: nothing newer than Aurentz et al. 2015/2018 | `polynomial-roots.md`: corrected | 7.2066e-5, 3.8234e-6, 0.10574, 0, 1.6509, 8.41e-14, 9.9266e-3; new 6.2443e-6 and 6.368e-4 | 7 run, 7 killed (two only by the tests added and strengthened) | `stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic`; Kahan's quadratic in `degreeTwoUsesTheClosedFormWithoutCancellation` | cited open: A-4, B-1, A-NB1 (wave 1) |

What failed without each change:

- **`stressThePolishLeavesAMultipleRootAloneWhereNewtonsMethodIsErratic`.** The polish keeps a Newton step only when it lowers the residual. With every step kept (R12-keep), all 19 tests of the suite passed with every figure unchanged. The fixture `tripleRoot` is exact in binary, so Newton's method converges on it and never needs the guard. A survey (the deleted experiment) found where the guard matters: the triple root rescaled off the binary grid, which rounds its coefficients into a cluster. The new test rescales it by 0.1, 0.2, …, 4.0. With the guard removed it fails alone (R12-keep-2, 13 issues): at the scales 2.3, 2.7, 3.3 and 3.7 three roots each end with a larger residual than their eigenvalue, and at 3.3 the roots are off by 6.368e-4 against the fixture's 1e-4. With the guard the worst is 6.2443e-6. The test is deterministic (no seed is involved) and takes 16 ms.
- **Kahan's quadratic.** With the errors of the two products left out of the discriminant (R12-kahan), every test passed: the test's nearly double root has exact products. With Kahan's example added, the test fails (R12-kahan-2): the discriminant is 0, a double root 1.449e-8 from both roots, against 1e-15.
- **`subnormalInputGivesExactZerosOnBothPaths`.** With the input not cleaned (R8-clean), every test passed. The stress test's filter has its smallest taps in its head, so its products with the `denormal` signal are zero anyway. The new filter has its largest taps in the head. Without the cleaning the test fails (R8-clean-2, 6 issues): for the three cuts that take the direct head, a subnormal value comes out and the `denormal` signal no longer gives zeros. Whole partitions still give zeros, since their spectra are flushed.

## 3. Gates and test totals

The gates of brief 60 were run once, in order, on 2026-11-22 from 00:22:34 to 00:32:03 (`.build/m9-registers/run-gates.sh`), over the tree that holds all four packages, WP-905a to WP-905d. That was after the last change to a Swift file (2026-11-21, 23:52) and to the audit and its notes, and after the ledger was set. Every gate passed. Each log is in `.build/logs/m9-registers/gates/`. The final line of each, exactly:

| # | Gate | Time | Exit | Final line |
|---|---|---|---|---|
| 1 | `Scripts/lint-bans.sh` | 00:22:34–00:22:38 | 0 | `lint-bans: clean (parts 1, 2, 3, 4; 606 files)` |
| 2 | `Scripts/check-dependency-graph.sh` | 00:22:38–00:22:39 | 0 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| 3 | `Scripts/api-digest.sh --check` | 00:22:39–00:23:25 | 0 | `api-digest: ZTronDSPUI references public symbols only` |
| 4 | `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 00:23:25–00:23:35 | 0 | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| 5 | `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 00:23:35–00:23:39 | 0 | `order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current` |
| 6 | `Scripts/golden.sh --check` | 00:23:39–00:23:39 | 0 | `golden: 197 files of 27 generators match the manifest` |
| 7 | `Scripts/check-function-effects.sh` | 00:23:39–00:24:42 | 0 | `function effects: all checks passed` |
| 8 | `Scripts/ledger.sh --check` | 00:24:42–00:24:42 | 0 | `ledger: 289 rows, consistent with §12 and §11` |
| 9 | `Scripts/tests/run-all.sh` | 00:24:42–00:30:45 | 0 | `run-all: every self-test passed (882 checks in 15 suites, 2 skipped: see above)` |
| 10 | `Scripts/external-parity.sh` | 00:30:45–00:32:03 | 0 | `external-parity: passed` |
| 11 | `Scripts/check-registers.sh` (this audit's check, also inside run-all) | 00:32:03–00:32:03 | 0 | `registers: 24 rows, 53 ALG packages, 52 notes (0 supplementary), 213 tests and 139 files checked: OK` |

The two skips of gate 9 are the two checks that run only with `--slow`: gate 1 of `Scripts/ci.sh` with a real build and a seeded warning, and the parity tests on the simulator with a seeded violation. Brief 60 gives the gate without the flag. Gate 10 runs the parity tests on the simulator for real: 116 tests passed in Debug, the audits again in Release (19 tests passed, then the audit that opens before the first block, alone), and the speed check (3 tests passed). Each of its steps passed with only the known issues its script allows to stand: the audits' control case `theProbeCountsWhatAnAllocatingStageDoes()`, in Debug and in Release, and the bound of the gain written as a `SampleProcessor` in the speed check, `theGainAgainstTheStockGain()` (×1.056 against 5 %, CR-025 item 1). The self-test of this audit's check, `check-registers`, is one of the 15 suites of gate 9 (45 checks, 0 failed).

The Swift tests, the whole suite on the simulator `ztdsp-27` (iOS 27.0), both after the last change to a Swift file:

- `ZTD_CONFIG=Release Scripts/xc.sh test`: 2026-11-21 23:59:09 to 2026-11-22 00:01:50, exit 0, final line `** TEST EXECUTE SUCCEEDED **` (`.build/logs/m9-registers/full-release.log`).
- `Scripts/xc.sh test` (Debug): 2026-11-22 00:08:25 to 00:11:52, exit 0, final line `** TEST EXECUTE SUCCEEDED **` (`full-debug-2.log`).
- The Debug run before it, 2026-11-21 23:54:46 to 23:59:09, ended `** TEST EXECUTE FAILED **` (exit 65, `full-debug.log`). Its one failure was `CoverageConcurrencyTests.aSourceWhosePacingChangesMovesToTheThreadOfItsKind()` in `ZTronDSPCoreTests`, which this work did not touch: "✘ Test run with 511 tests in 60 suites failed after 65.408 seconds with 2 issues." Since then the test has passed every time it ran (F-905d-4, section 4 of `impl-WP-905d.md`).

| Bundle | Debug | Release |
|---|---|---|
| `ZTronDSPUITests` | ✔ Test run with 278 tests in 19 suites passed after 2.753 seconds. | ✔ Test run with 278 tests in 19 suites passed after 2.364 seconds. |
| `ZTronDSPTests` | ✔ Test run with 11 tests in 4 suites passed after 0.263 seconds. | ✔ Test run with 11 tests in 4 suites passed after 0.263 seconds. |
| `ZTronDSPTestingTests` | ━ Test run with 55 tests in 8 suites passed after 0.191 seconds with 3 known issues. | ━ Test run with 55 tests in 8 suites passed after 0.031 seconds with 3 known issues. |
| `ZTronDSPMetalTests` | ✔ Test run with 118 tests in 12 suites passed after 6.932 seconds. | ✔ Test run with 118 tests in 12 suites passed after 0.740 seconds. |
| `ZTronDSPIOTests` | ✔ Test run with 134 tests in 13 suites passed after 4.403 seconds. | ✔ Test run with 134 tests in 13 suites passed after 4.409 seconds. |
| `ZTronDSPDesignTests` | ✔ Test run with 338 tests in 41 suites passed after 59.630 seconds. | ✔ Test run with 338 tests in 41 suites passed after 1.740 seconds. |
| `ZTronDSPCoreTests` | ✔ Test run with 511 tests in 60 suites passed after 9.257 seconds. | ✔ Test run with 511 tests in 60 suites passed after 4.983 seconds. |
| `ZTronDSPAnalysisTests` | ✔ Test run with 431 tests in 41 suites passed after 102.797 seconds. | ✔ Test run with 431 tests in 41 suites passed after 12.013 seconds. |
| `CZTronDSPTests` | ✔ Test run with 232 tests in 31 suites passed after 6.445 seconds. | ✔ Test run with 232 tests in 31 suites passed after 1.029 seconds. |
| All | 2 108 tests, all passed | 2 108 tests, all passed |

The bundles that the four packages touched are `CZTronDSPTests`, `ZTronDSPAnalysisTests`, `ZTronDSPDesignTests` and `ZTronDSPMetalTests`. All pass in Debug and in Release. The three known issues of `ZTronDSPTestingTests` are its own `withKnownIssue` expectations, a target this work did not touch, and they are the same in both configurations.

COV-3: no production file changed (`git diff --stat -- Sources` prints nothing). Test files are outside the coverage gate's denominator (COV-4), so its changed-files mode has nothing to measure. The Python engine of the new check (`Scripts/lib/registers.py`) is exercised by its self-test, 45 checks. `python3 .build/m9-registers/mut.py status` prints "nothing active".

## 4. Open items

- F-905b-1 (this audit, low): no test exercises the refusal of a result longer than 2²⁸ values (`OneShotConvolution.run`). A test needs inputs of 2²⁸ values (a gibibyte), or a seam for the limit.
- R8-flush-spectra is recorded as equivalent at the output, with the reason in the row's section: with the input cleaned, the flush keeps the delay line clean (RT-6) without changing any output.
- Wave findings on rows 7–12, cited open and not fixed here:
  - CR-013 item 6 (Proposed).
  - Wave 3 (m5b): A-27, A-28 and A-31 (the subsampling report of WP-539); A-1, B-2, A-3 and B-4 (finite inputs near the largest float give NaN or ∞ by the transform methods); A-NB1, A-NB2, A-NB4 and A-NB23; A-5 and B-6 (lag 0 of very large frames); A-NB3 (the currency record of rows 10 and 11, which the second pass now gives a search).
  - Wave 1 (m4a): A-4, B-1 and A-NB1.

## 5. Change requests and owner decisions

- No change request.
- No owner decision was needed or taken. Decisions recorded here and in the audit:
  - R8-flush-spectra is recorded as equivalent rather than given a test, because no output can show it.
  - R10-cap is a finding rather than a test that allocates a gibibyte.
  - The note's 120-digit figures of row 12 (0.152, 4.8e-5) are reported as printed by no test, with A-NB1 cited, not recomputed: the package has no multiple-precision arithmetic, and none was installed.
  - The gates were run once, after WP-905d; section 3 quotes that run.
