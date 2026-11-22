# WP-905d — implementer's report

| Field | Value |
|---|---|
| Package | WP-905d: audit of the algorithm and stability registers, rows 19 to 24 (§7.2, §7.3, §7.5) |
| Implementer | Implementer M9-registers (agent), brief 64 with the common rules of brief 60 |
| Date | 2026-11-21, and 2026-11-22 after midnight for the last runs; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `53a095d`. Everything below is unstaged or untracked. This work committed nothing and added nothing to the index |
| Ledger | WP-905d `Verifying`, implementer `Implementer M9-registers (agent)` (with WP-905a, b and c) |
| Change request | None from this package. CR-016 item 3 (Proposed) is cited for row 23, CR-020 items 6 and 7 for rows 20 and 19 |

The audit of rows 19–24, with every measured figure and every mutation, is in `Docs/Numerics/register-audit-2026-11.md`: the table, then "WP-905d: rows 19 to 24". The check and its self-test are WP-905a's (`impl-WP-905a.md`). With these six rows the table is complete: `Scripts/check-registers.sh` prints "registers: 24 rows, 53 ALG packages, 52 notes (0 supplementary), 213 tests and 139 files checked: OK".

## 1. Files

### Added

| File | What it is |
|---|---|
| `Docs/Process/reports/impl-WP-905d.md` | This report |

### Changed

| File | What changed |
|---|---|
| `Docs/Numerics/register-audit-2026-11.md` | Rows 19–24 of the table and the section "WP-905d: rows 19 to 24" |
| `Tests/ZTronDSPAnalysisTests/StabilityTests.swift` | New tests `theRealCepstrumOfTheStressSpectraIsItsDefinitionRoundedOnce` (row 19), `theTailOfAStressWindowIsJudgedAtEveryHeight` and `theNullOfATruncatedRectangleIsFoundBetweenThePointsOfTheGrid` (row 21). `theJumpsOfEveryStressWindowAreFoundWhereTheyAre` also asks whether each shape is a mirror image at every height (row 21). `whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal` holds every prediction to the rule of the note, computed in the test (row 22). The stress tests of rows 19, 21 and 22 print their tables ("measured WP-509", "WP-510", "WP-501d", "WP-501e", "WP-501f", "WP-537") |
| `Tests/ZTronDSPDesignTests/EqualizerTests.swift` | `BandBoostTests.orderOneIsTheCookbookSectionAndOrderNRunsAsNBiquads` also asks for b₁ = a₁ bit for bit (row 20) |
| `Tests/ZTronDSPMetalTests/HeatmapTextureTests.swift` | New test `aNotANumberIsReplacedInWhicheverBinItArrives` (row 23) |
| `Tests/ZTronDSPMetalTests/CalibrationTests.swift` | New tests `theFastestSampleCountsAndADisturbedOneDoesNot` and `theCandidatesTakeTurnsAtEverySize`, and the private test class `CallOrder` that records the order of the calls (row 24) |
| `Docs/Numerics/complex-cepstrum.md` | Two statements corrected: the value carried beside the frame is minus the delay (−64 for an impulse 64 samples in), and so is the number of half turns at the Nyquist bin; an audit paragraph |
| `Docs/Numerics/matched-peak.md` | Two bounds that had been rounded below what is measured now give it (within 3.42e-9 dB; at most 0.534); an audit paragraph |
| `Docs/Numerics/inversion-analysis.md` | Below the floor `silence` loses 0; `denormal` errs by up to 1.11 of its peak, not 1.1; an audit paragraph |
| `Docs/Numerics/crossover-search.md` | The GPU median's entry: `Calibration.report()` leaves it as it found it, and `AnalysisCalibration` sets it; an audit paragraph |
| `Docs/Numerics/cepstrum.md`, `band-boost.md`, `window-gains.md`, `window-smoothness.md`, `window-spectrum.md`, `heatmap-rendering.md` | An audit paragraph each |
| `Docs/Numerics/currency-2026-11.md` | The second pass (shared with WP-905a, b and c) |
| `Docs/Process/ledger.md` | WP-905a, WP-905b, WP-905c and WP-905d set to `Verifying`, implementer `Implementer M9-registers (agent)`, by `ledger_set.py` |

### Deleted

None. This package created no file outside the tree or the scratchpad. `git diff --stat -- Sources` is empty after the last mutation of the package (23:53, R24-interleave-2) and at the end, and `python3 .build/m9-registers/mut.py status` prints "nothing active".

## 2. Items

The mutation logs are `.build/logs/m9-registers/batch-row19-24.log` (69 mutations, 23:26–23:38) and `batch-row19-24-2.log` (9 mutations spelled again against the new and strengthened tests, 23:52–23:53). The baselines are `base-row19-24.log` (the twelve suites of the six rows, unmutated) and `base-row19-24-2.log` (the four changed suites: "Heat-map texture", "Calibration", "High-order band-boost (WP-421)", "Numerical stability", all passed, 23:52:00–23:52:20). Every mutation was restored by `cmp` against the saved copy.

| Row | Currency (2026-11-21) | Notes checked | Figures | Mutations | Tests added or strengthened | Findings |
|---|---|---|---|---|---|---|
| 19 Cepstrum (WP-509, WP-510) | current; CR-020 item 7 stands | `cepstrum.md`: true; `complex-cepstrum.md`: corrected (the sign of the delay) | all reproduced: the real cepstrum against its definition at four floors, 0.199 … 5.64e-8 of the frame maximum; 23.025850 and 530.19; round trips 3.53e-7, 6.83e-7, 1.82e-7, 8.94e-7 and 2.03e-7 against a predicted 10⁻⁵; the delayed impulse 2.79e-14, with −64 beside it (the sign corrected); the new test 0.998 of its bound over 9 234 values | 10 run, 10 killed (one only by the new test) | one new | F-905d-3 (low); cited open: A-12, B-14, B-15 (wave 2, m5a) |
| 20 Band-boost (WP-421) | current (the 2025 multi-shelf equaliser is not a band-boost design); CR-020 item 6 stands | `band-boost.md`: true; `matched-peak.md`: corrected (two bounds) | all reproduced: properties 1 to 6, 7.774e-11 dB … 9.286e-14; the stress fixture 5.983e-11 dB, 7.261e-9 dB, 0.954 dB and 0.237; the matched peak 2.276e-11 dB … 2.715e-15; under stress 3.412e-9 dB, 4.193e-10 and 0.534 (two bounds corrected to these) | 12 run: 6 killed (one only by the strengthened test), 6 equivalent | one strengthened | F-905d-2 (an observation); cited open: A-NB6, B-BL-4 (wave 1, m4a), A-B3, B-4 (wave 2, m4b) |
| 21 Window analysis (WP-501d, WP-501e, WP-501f) | current (searched for the first time) | three notes: true | all reproduced: the sums −4.58e-16 … 2.24e-15, and 0 for `nyquist`; 1 bin; jumps 44, 1 025, 2, 2 and 2; −13.262 dB and 2.0 bins; −400 dB; the new test's widths 2.04974 … 3.99245 bins, numpy's | 22 run, 22 killed (three only by the new and strengthened tests) | two new, one strengthened | cited open: A-3, A-4, B-10, B-11 (wave 2, m5a) |
| 22 Inversion analysis (WP-537) | current (searched for the first time) | `inversion-analysis.md`: corrected | all reproduced: B/A 1 to 10⁸, errors 3.58e-7 … 1.91e-3, 138.88 … 84.00 dB, predictions 1.907e-5 … 1; `denormal` 1 to 71 units, up to 1.11 of its peak (corrected); below the floor 0.994, 1.0 and 0.999, and 0 for `silence` (corrected) | 9 run, 9 killed (one only by the strengthened test) | one strengthened | cited open: A-11, B-3 (wave 2, m5a), A-NB9, A-NB10, A-NB11, A-NB12 (wave 3, m5b) |
| 23 Heat-map rendering (WP-605) | current (searched for the first time) | `heatmap-rendering.md`: true | all reproduced: 4.07e-4; 0.0308 dB; 68.7 dB, six fixtures equal pixel for pixel; the warp table 8.06e-4, 5.20e-4 and 6.10e-5 of a row, and half of each | 8 run, 8 killed (one only by the new test) | one new | cited open: CR-016 item 3 |
| 24 Implementation selection (WP-611a) | current (searched for the first time) | `crossover-search.md`: corrected | five synthetic pairs, exactly; the real pair found at 1 024 (128.7 ns … 86.5 µs against 2.71 µs in Debug); `Calibration.report()` 0.47 s alone, 3.36 s with the suite; the host table not reproduced (an optimised build), the Debug crossovers recorded; the GPU median's entry 69 768 | 8 run: 7 killed (two only by the new tests), 1 equivalent | two new | F-905d-1 (low) |

Row 24 also needed SEL-6 shown per primitive. The audit lists one passing test per primitive that a crossover chooses for: element-wise and reduction (`ToolkitTests`), lane exchange (`LaneExchangeTests`), gain kernel (`GainKernelTests`), biquad kernel (`BiquadKernelTests`), FIR (`SystemStageTests`), mel projection (`MelTests`), median (`MetalMedianFilterTests`) and one-shot convolution (`ConvolutionTests`). Polynomial roots need none, because their entry decides nothing (F-905d-1).

No production code changed. Every mitigation is in place. The defects found are wave findings already open, statements of the notes (which were corrected), or this audit's F-905d-1 to F-905d-3, which need a design decision or a documentation change in Sources, which this brief does not allow.

What failed without each change. The new tests all pass unmutated: `base-row19-24-2.log` ends "** TEST EXECUTE SUCCEEDED **". Every survivor of the first batch was spelled again against them.

- **`theRealCepstrumOfTheStressSpectraIsItsDefinitionRoundedOnce`** (row 19). With the logarithm rounded to `Float` (R19-single), only `CepstrumTests.theNodesRunWithoutAllocating` failed, because the conversion allocated. Spelled again without allocating (R19-single-2: `vDSP_vdpsp` and `vDSP_vspdp` through the node's output buffer), every test as it was passed. The new test hands the node the single-precision spectra of the nine stress signals, at floors of 10⁻¹⁰ and 10⁻². It holds each of the 9 234 values to half a unit in its last place, plus 10⁻¹³ of the largest logarithm, of the definition in double precision. Unmutated, the largest error is 0.998 of that bound. With R19-single-2 it fails for 11 of the 18 pairs of signal and floor ("not the definition rounded once: ["dc, floor 0.01", "dc, floor 1e-10", "decaying-tail, floor 1e-10", …]").
- **The symmetry in `theJumpsOfEveryStressWindowAreFoundWhereTheyAre`** (row 21). With the symmetry judged against an absolute tolerance (R21-mirror), every test passed. The strengthened test asks its four shapes at five heights whether they are mirror images. With R21-mirror-2 it fails 6 times: the Hann and sin⁴ windows at 10²⁰ and 10³⁰ are judged not symmetric, and the step at 9e-44 and at 10⁻²⁰ is judged symmetric.
- **`theTailOfAStressWindowIsJudgedAtEveryHeight`** (row 21). With the tail judged at a scale of 1 instead of the window's peak (R21-tail-scale), every test passed. Unmutated, five functions give the verdicts zero, 1, 1.000000953673407, zero and 0.01 at every height, with the same integrability. With R21-tail-scale-2 it fails 6 times, for example "constant × 8.96831017167883e-44: zero, not value 1.0 scaled".
- **`theNullOfATruncatedRectangleIsFoundBetweenThePointsOfTheGrid`** (row 21). With the null placed on the nearest point of the padded transform (R21-null), every test passed: every null the tests saw lay on a point. Unmutated, the widths are 2.04974, 2.05182, 2.27655, 2.92697 and 3.99245 bins, which are numpy's, against 2.04800, 2.05005, 2.27556, 2.92571 and 3.99220. With R21-null-2 it fails 5 times ("999 samples: 2.0 bins between the nulls, not 2.05005005005005").
- **The prediction in `whatAWindowAmplifiesStaysUnderThePredictionOnEveryStressSignal`** (row 22). With the head-room of 16 cut to 1 (R22-headroom), every test passed. Every measured error still lay under the smaller prediction, and the tests took the prediction from the function under test. The strengthened test computes min(16·ε·log₂ 1 024 · B/A, 1) itself. With R22-headroom-2 it fails 24 times ("white-noise, B/A 1.0: … value is 1.1920928955078131e-06 where 1.907348632812501e-05 was expected").
- **b₁ = a₁ in `orderOneIsTheCookbookSectionAndOrderNRunsAsNBiquads`** (row 20). With order 1 designed as a paired section instead of the Cookbook's (R20-order1), every test passed: the two agree within 10⁻¹³. With R20-order1-2 the strengthened test fails for each of the six order-one bands ("order 1, 6.0 dB at 1000.0 Hz, q(4.0): b1 -1.9602475241289579, a1 -1.9602475241289576").
- **`aNotANumberIsReplacedInWhicheverBinItArrives`** (row 23). With the check for a NaN summed over half the bins (R23-sve), every test passed, because the stress test's NaNs sit in the lower half. The new test makes the NaN arrive in each of 64 bins in turn. Unmutated, every texel is finite and the NaN's bin holds −65 504. With R23-sve-2 it fails 33 times ("column 63: its NaN, in bin 63, is stored as nan").
- **`theFastestSampleCountsAndADisturbedOneDoesNot`** (row 24). With the slowest sample taken (R24-fastest), every test passed. With R24-fastest-2 the new test fails: "the fastest sample, 6701250.0 ns, and not the disturbed one, 6700334.0 ns". The times it compares differ by five orders of magnitude, so it does not depend on the load of the machine.
- **`theCandidatesTakeTurnsAtEverySize`** (row 24). With every size of one candidate timed before the other's (R24-interleave), every test passed. With R24-interleave-2 the new test fails with the recorded order ["loop 8", "loop 16", "loop 32", "loop 64", "library 8", "library 16", "library 32", "library 64"].
- **Equivalent mutations.** Seven are recorded with their reasons in the audit instead of being forced into a test: R20-radicand, R20-pairing (killed in row 4), R20-expm1, R20-detune, R20-sines, R20-zero and R24-escape.
- **Prints.** The stress tests print the figures the notes quote. No assertion was loosened, and every tolerance is as it was.

Every new test is deterministic. The fixtures are WP-016's and seeded, and no test sleeps. The one timed test compares times five orders of magnitude apart.

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

- F-905d-1 (this audit, low): `CrossoverTable.polynomialClosedForm` decides nothing. It is read only in `implementation(for:size:requested:)`, case `.polynomialRoots` (`Sources/ZTronDSPCore/Toolkit/Implementation.swift`, line 139). No caller in Sources asks for that primitive: `CompanionQRRootFinder` takes the closed form by degree (`switch degree`, cases 0, 1 and 2), and no calibration measures the entry. SEL-6 is therefore moot for polynomial roots. The owner decides whether to wire the root finder to the table or remove the entry.
- F-905d-2 (this audit, an observation): the matched peak's gap and detune are the prototype's, not those of the poles as stored. From the stored poles, the stress bandwidth error would fall from 4.19e-10 to 7.93e-11. Nothing was changed: WP-422 is optional, and the error is 10⁴ under its bound.
- F-905d-3 (this audit, low, VIS-2): the documentation of `Cepstrum(.complex)` in `Sources/ZTronDSPAnalysis/Steps/Cepstrum.swift` says that the delay travels with the frame, but not its sign or unit. The value is minus the delay, as a fraction of the transform length, and past the middle of the frame it reads as an advance. The note now says so. The source comment is left to a package that may change Sources.
- F-905d-4 (this audit, not a register matter): an intermittent hang in a target this work did not touch. In the first full Debug run (2026-11-21, 23:54:46–23:59:09, `.build/logs/m9-registers/full-debug.log`), `CoverageConcurrencyTests.aSourceWhosePacingChangesMovesToTheThreadOfItsKind()` (`Tests/ZTronDSPCoreTests/CoverageConcurrencyTests.swift`) waited 60 s in its third phase (lines 43 and 44: the source paced in real time again never reached 1 920 frames and `.finished`, or still owned its thread). It failed after 63.521 s with 2 issues, the only failure of that run. Afterwards it passed:
  - in 10 of 10 repetitions alone (`-test-iterations 10`, 2.6 s);
  - with the whole core target alone (511 tests, 9.3 s);
  - in the full Release run;
  - in the second full Debug run of section 3.

  It may be a race in the engine's move between the analysis thread and a source's own thread. No Sources or Core test file was changed by this audit, and the cause was not looked for further: that is engine work, outside brief 64.
- Wave findings on rows 19–24, cited open and not fixed here (each row's "Open" in the audit names them):
  - Wave 2, m5a: A-12, B-14, B-15 (row 19); A-3, A-4, B-10, B-11 (row 21); A-11, B-3 (row 22).
  - Wave 1, m4a: A-NB6, B-BL-4. Wave 2, m4b: A-B3, B-4 (row 20).
  - Wave 3, m5b: A-NB9, A-NB10, A-NB11, A-NB12 (row 22).
  - CR-016 item 3 (row 23, Proposed).
- The host table of `crossover-search.md` comes from an optimised build with the suite run alone, and was not reproduced in Debug. The Debug crossovers of two runs are in the note's audit paragraph.

## 5. Change requests and owner decisions

- No change request from rows 19–24. Cited: CR-016 item 3 (row 23), CR-020 items 6 and 7 (rows 20 and 19), all Proposed.
- Decisions for the owner, none blocking: F-905d-1 (wire `polynomialClosedForm` or remove it), F-905d-3 (the sign of the delay in the documentation of `Cepstrum(.complex)`), and F-905d-4 (a look at the pacing test's third phase).
- Decisions recorded here and in the audit:
  - Where a note was wrong and the code right, the note was corrected. The audit lists every statement in each row's "Notes against the code". No code changed.
  - Seven mutations are recorded as equivalent, each with its reason: R20-radicand, R20-pairing, R20-expm1, R20-detune, R20-sines, R20-zero and R24-escape. The six of row 20 move no figure past its bound by more than round-off, and R20-pairing is killed in row 4.
  - Two bounds rounded below what is measured (`matched-peak.md`, `inversion-analysis.md`) were made exact instead of being left as two-digit roundings.
  - The gates were run once, after WP-905d, over the tree that holds all four packages; section 3 quotes that run.
