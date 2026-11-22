# WP-905c — implementer's report

| Field | Value |
|---|---|
| Package | WP-905c: audit of the algorithm and stability registers, rows 13 to 18 (§7.2, §7.3, §7.5) |
| Implementer | Implementer M9-registers (agent), brief 64 with the common rules of brief 60 |
| Date | 2026-11-21, and 2026-11-22 after midnight for the gate run of section 3; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `53a095d`. Everything below is unstaged or untracked. This work committed nothing and added nothing to the index |
| Ledger | WP-905c `Verifying`, implementer `Implementer M9-registers (agent)` |
| Change request | CR-020 item 9 added (Proposed; nothing adopted) |

The audit of rows 13–18, with every measured figure and every mutation, is in `Docs/Numerics/register-audit-2026-11.md`: the table, then "WP-905c: rows 13 to 18". The check and its self-test are WP-905a's (`impl-WP-905a.md`).

## 1. Files

### Added

| File | What it is |
|---|---|
| `Docs/Process/reports/impl-WP-905c.md` | This report |

### Changed

| File | What changed |
|---|---|
| `Docs/Numerics/register-audit-2026-11.md` | Rows 13–18 of the table and the section "WP-905c: rows 13 to 18" |
| `Tests/ZTronDSPAnalysisTests/ConstantQStabilityTests.swift` | New tests `everyKeptEntryIsItsValueRoundedOnceAtEveryCornerOfTheStressLibrary` and `theTransformOfTheNonFiniteFixtureIsThatOfTheSignalWithItsValuesReplaced`; prints ("measured WP-518 … WP-523") in the stress tests |
| `Tests/ZTronDSPAnalysisTests/ConstantQKernelTests.swift` | New test `aKernelForAnotherTransformLengthIsRefusedBeforeAProductIsMadeOfIt`; a print of the kernel table |
| `Tests/ZTronDSPAnalysisTests/ConstantQScheduleTests.swift`, `ConstantQTests.swift`, `ConstantQScaleTests.swift` | Prints of the figures the row 13 notes quote; no assertion changed |
| `Tests/ZTronDSPAnalysisTests/FrameSupport.swift` | New test stage `CurveAsNovelty` (and its node), which hands a step a curve of values as written, NaN and infinities included, keyed by their bit patterns |
| `Tests/ZTronDSPAnalysisTests/OnsetStrengthTests.swift` | New test `aLevelThatIsNotFiniteNeverGivesAValueThatIsNot` |
| `Tests/ZTronDSPAnalysisTests/TempogramTests.swift` | New test `aValueOfTheCurveThatIsNotFiniteIsTakenAsZero` |
| `Tests/ZTronDSPAnalysisTests/RhythmSeparationStabilityTests.swift` | The onset stress test also prints the full-scale mean of white noise |
| `Tests/ZTronDSPAnalysisTests/StabilityTests.swift` | New tests `theCentroidOfTheStressLibraryScaledUpToTheLargestFloatIsAFrequencyOrNothing` and `theEdgesEndOnTheRangeItselfAtEveryRateOfTheLibrary`; the row 17 and row 18 stress tests print their tables (the row 1 prints are WP-905a's) |
| `Tests/ZTronDSPAnalysisTests/SpectralCentroidTests.swift` | New test `theFrequencyOfABinIsItsIndexTimesTheWidthRoundedOnce` |
| `Docs/Numerics/constant-q-kernel.md`, `constant-q-transform.md`, `sparse-kernel-product.md` | Figures corrected (0.81 %, 0.0112 dB, 2.4 units of the least subnormal; one ε measured, not a bound; finiteness qualified) and an audit paragraph each |
| `Docs/Numerics/half-band-decimator.md`, `constant-q-scale.md` | An audit paragraph each |
| `Docs/Numerics/onset-strength.md` | What gives a mean that is not finite, corrected; an audit paragraph |
| `Docs/Numerics/tempogram.md` | "Not finite" for "not a number"; an audit paragraph |
| `Docs/Numerics/separation-masks.md` | The stress paragraph corrected (the zero-denominator rule removed gives shares of one half, not NaN); an audit paragraph |
| `Docs/Numerics/lane-exchange.md`, `median-network.md`, `median-lanes.md`, `harmonic-percussive.md`, `median-metal.md` | An audit paragraph each |
| `Docs/Numerics/spectral-centroid.md` | "Not finite" for "not a number"; "at most 2.1 ε" for "one to two ε"; an audit paragraph |
| `Docs/Numerics/mel-filter-bank.md` | The round trip qualified (HTK below 1 Hz, wave 2 A-5); an audit paragraph |
| `Docs/Numerics/mel-projection.md` | An audit paragraph |
| `Docs/Process/changes/CR-020.md` | Item 9 (row 13: the exact factorisation of the invertible constant-Q transform, arXiv 2609.29119); "Nine things" for "Seven things", the count the list now has |
| `Docs/Numerics/currency-2026-11.md` | The second pass (shared with WP-905a, b and d) |

### Deleted

Two files that commands of mine created outside the tree, both empty, both removed:

- `/Users/admin/Documents-handoff-placeholder-check`, created at 22:19 by a mistyped `cat >>` with no input, which hung; the command was stopped and the file removed at 22:2x.
- `/Users/admin/Documents-placeholder-never`, created at 22:53 the same way (a command that began with a stray `cat >>`); stopped with TaskStop and removed at 22:55:33.

Nothing else was written outside the tree or the scratchpad. `git diff --stat -- Sources` is empty after the last mutation of the package (22:58).

## 2. Items

The mutation logs are `.build/logs/m9-registers/batch-row13.log`, `batch-row13b-15.log`, `batch-row14-18.log`, `batch-row17-18b.log` and `batch-row16c.log`, and the baselines of the new tests `base-row17-18.log` and the row 13–15 runs before them; every mutation was restored by `cmp` against the saved copy.

| Row | Currency (2026-11-21) | Notes checked | Figures | Mutations | Tests added | Findings |
|---|---|---|---|---|---|---|
| 13 Constant-Q (WP-518 … WP-523) | current; arXiv 2609.29119 recorded as CR-020 item 9 | five notes; three corrected | reproduced: 383, 383 and 364 entries kept, at least 0.999 9539 of a row's energy; the half-band 53 taps, 0.000 8417 dB, 80.376 dB; tones −92.09 … −118.92 dB; the product 0.7807 ε·T at most; latency 18 919, 36 263, 39 335 samples; three figures corrected (0.0112 dB over the 252 bins, 0.82 % with nothing dropped, 2.4 units of the least subnormal); the new test 0.499 69 of an ulp | 24 run, 24 killed (three only by new tests) | three | cited open: A-6, B-7, A-11, B-10, A-4, A-5, B-5, A-10, B-9, B-8, backlog B-4, B-6, B-8, BL-4, BL-6 (wave 3, m5c) |
| 14 Onset envelope (WP-525) | current | `onset-strength.md`: corrected | 4.768e-8 dB; 1.3454 dB; 0 in every frame 180 dB down; 0.8010 dB; 1.598e-7 | 6 run, 6 killed (one only by the new test) | one | cited open: A-10, A-11, B-9 (wave 3, m5b) |
| 15 Tempogram (WP-526, WP-527) | current (dPLP, ISMIR 2025, builds on the Fourier tempogram) | `tempogram.md`: corrected | 3.7193e-5; 0.98402; lag 48; exact zeros, 641 columns each; 0.99999999998682; 6.363e-7 | 5 run, 5 killed (one only by the new test) | one, and the stage `CurveAsNovelty` | cited open: A-12, A-14, A-13, A-15, B-10, B-11 (wave 3, m5b) |
| 16 Median filtering (WP-219, WP-528, WP-529, WP-530, WP-531a, WP-610) | current | six notes; `separation-masks.md` corrected | 741 312, 14 288 and 6 739 medians; 1 074 960; 228 120 on the GPU; 1 071 144 pairs, 2.2504e-7; 5.51e-5 and 100.0 % of 85 454 bins; 7.9976e-8, 1.3704e-7; 138.647 … 139.311 dB (the host timings of `lane-exchange.md` not measured again) | 19 run, 19 killed | none needed | cited open: wave 3 m5b A-16 … A-26, B-12 … B-21, backlog; wave 2 m5a backlog B-12 |
| 17 Spectral centroid (WP-507) | current (searched for the first time) | `spectral-centroid.md`: corrected | 1.7496e-3 Hz (1.4220e-7) … 1.2289e-6 Hz for the six signals; 146 and 115 frames; at most 2.1 ε (corrected) | 5 run, 5 killed (two only by the new tests) | two | cited open: wave 2 m5a backlog B-14 |
| 18 Mel conversion (WP-508, WP-535) | current (searched for the first time) | `mel-filter-bank.md`: qualified; `mel-projection.md`: true | 9 banks of 21; the note's table of empty bands; 7.5587e-15; 62 bins, 7.3910e-6; 2.2918e-7 and 1.5569e-7 at most | 8 run, 8 killed (one only by the new test) | one | cited open: A-5 (wave 2, m5a), backlog B-14 |

No production code changed: every mitigation is in place, and the defects found are wave findings already open, or statements of the notes, which were corrected.

What failed without each change (the new tests all pass unmutated: `base-row17-18.log` ends "Test run with 41 tests in 4 suites passed", and the row 13–15 tests passed in their own runs before the mutations):

- **`everyKeptEntryIsItsValueRoundedOnceAtEveryCornerOfTheStressLibrary`** (row 13). With the kernel rounded twice, to single precision before its scaling by 1/N (R13-double), every test passed: a unit in the last place lies under their tolerances of 10⁻⁶. The new test compares every part of every kept entry with the value by the definition, a direct DFT of the atom summed in double precision in the test, at every corner of `StressFixture.filtersNearZero`: unmutated, within half a unit in the last place (worst 0.49969, 2 876 parts); with the mutation, 198 of 752 and 163 of 720 parts are not their value rounded once (R13-double-2, 2 issues).
- **`aKernelForAnotherTransformLengthIsRefusedBeforeAProductIsMadeOfIt`** (row 13). With the node's refusal of a kernel for another transform length removed (R13-kernel-length), every test passed: the strategy only makes kernels for the transform it runs. The new test builds the node with a kernel for 480 points on a transform of 240, and the mutation fails it (R13-kernel-length-2).
- **`theTransformOfTheNonFiniteFixtureIsThatOfTheSignalWithItsValuesReplaced`** (row 13). With the replacement of non-finite samples in `OfflineRunner` removed (R13-num1), every constant-Q test passed, since none fed the transform such a sample. On `StressFixture.nonFiniteSignal` the new test finds every coefficient a number and every frame that of the signal with its three values replaced, bit for bit; the mutation fails both (R13-num1-2, 2 issues).
- **`aLevelThatIsNotFiniteNeverGivesAValueThatIsNot`** (row 14). With a mean that is not finite written as it is, with confidence 1 (R14-nan), every test passed: none handed the step a level that is not finite. The new test hands it the non-finite fixture read as levels through `FrameSequence`, with lag 1 and with lag 2 and a maximum over three bands. A first version expected the floor to raise a NaN, and failed: `vDSP_vthr` passes a NaN through, so the frame holding it and the frame `lag` later carry no value. The test now says so; unmutated, frames 9, 10 and 21 (lag 1) and 9, 11 and 21 (lag 2) carry 0 with confidence 0 and no other value differs from that of the levels at the floor. With the mutation: "frame 9: nan dB, confidence 1.0", "frame 21: inf dB, confidence 1.0" (R14-nan-2, 4 issues).
- **`aValueOfTheCurveThatIsNotFiniteIsTakenAsZero`** and **`CurveAsNovelty`** (row 15). With the replacement of a value that is not finite removed from `TempogramNode` (R15-nan), every test passed: the entry of a pipeline replaces non-finite samples, so `SamplesAsNovelty` never hands the step one. `CurveAsNovelty` hands it a curve as written. Unmutated, four tempograms of the non-finite fixture give 2 948 columns, every value finite, every column that of the curve with its three values at 0, bit for bit; with the mutation 51 465 and 37 449 values are not finite and 705 and 513 columns differ (R15-nan-2, 6 issues).
- **`theCentroidOfTheStressLibraryScaledUpToTheLargestFloatIsAFrequencyOrNothing`** (row 17). With a centroid that is not finite written with confidence 1 (R17-nonfinite), every test passed: no test overflowed a sum. The new test scales the library, read as spectra, by powers of two up to 2¹²⁶: unmutated, every value is finite, 35 of 35 centroids are those of the unscaled weights bit for bit, and 10 frames have a weighted sum past the largest float with a finite sum of weights; with the mutation they come out as +∞ with confidence 1 (R17-nonfinite-2, 22 issues).
- **`theFrequencyOfABinIsItsIndexTimesTheWidthRoundedOnce`** (row 17). With the ramp rounded twice (R17-ramp), every test passed: every bin width the tests used is a float, and there the two roundings agree. The new test uses 361 bins, 66.67 Hz apart: unmutated, 361 of 361 centroids are their bin's frequency rounded once; with the mutation bins 5, 10, 13, 15, … are not (R17-ramp-2); 151 of the 361 would move.
- **`theEdgesEndOnTheRangeItselfAtEveryRateOfTheLibrary`** (row 18). With the ends of the edges left to the round trip through the formula (R18-ends), every test passed. The new test builds 84 banks at the rates and corners of the stress library with both formulas: unmutated, each ends on its range and no band owns the Nyquist bin or bin 0 where the range ends or starts there, while the round trip alone misses 85 of the 168 ends; with the mutation it fails 103 times, for example an upper edge of 95 999.9999999999 Hz at 96 kHz and one of 24 000.000000000004 Hz that gives the Nyquist bin a weight (R18-ends-2).
- **Prints.** The row 13 tests, the onset stress test and the row 17 and row 18 stress tests print the figures the notes quote ("measured WP-518" … "measured WP-535", "measured stability row 17"); no assertion was loosened, and every tolerance is as it was.

Every new test is deterministic: the fixtures are WP-016's, seeded, and no test sleeps.

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

- Wave findings on rows 13–18, cited open and not fixed here (each row's "Open" in the audit names them):
  - Wave 3, m5c (row 13): A-6, B-7, A-11, B-10 (finite input near the largest float gives NaN or ∞); A-4, A-5, B-5 (the rule of the hop); A-10, B-9 (the scale's arithmetic on a bin count); B-8 (coverage of `ConstantQProjection.swift`); backlog B-4, B-6, B-8 (CR-022 item 2), BL-4, BL-6.
  - Wave 3, m5b (rows 14–16): A-10 (onset floor beyond the float range); A-12, A-14 (tempograms of curves near the largest float); A-16, B-13 (`MedianOracle` traps); A-18, A-20, B-20 (parameters narrowed to Float32); A-21, B-17 (overflow near the largest float); B-18; A-24, A-25 (the `HPSS` recipe); B-15 (RT-7); B-16 (§5.11.1); the VIS-2 findings A-11, A-13, A-15, A-17, A-19, A-22, A-23, A-26, B-9, B-10, B-11, B-12, B-14, B-19, B-21; backlog A-NB5, A-NB6, A-NB18, BL-1, BL-3, BL-4, BL-5, BL-11, BL-14.
  - Wave 2, m5a (rows 16–18): A-5 (the HTK round trip below 1 Hz); backlog B-12 of lens B (the pruning test's comment) and B-14 (no benchmark of WP-507 and WP-535).
- The timings of `lane-exchange.md` and `sparse-kernel-product.md` are host figures and were not measured again.

## 5. Change requests and owner decisions

- CR-020 item 9, added to the Proposed CR-020: the exact factorisation of the invertible constant-Q transform (Franchino, Moliner & Välimäki, arXiv 2609.29119) as a faster computation of row 13's registered alternative. Nothing is adopted.
- No owner decision was needed or taken. Decisions recorded here and in the audit:
  - Where a note was wrong and the code right, the note was corrected (each row's "Notes against the code" in the audit lists the statements); no code changed.
  - The NaN that `vDSP_vthr` passes through (row 14) is not a defect: the guard after it writes no value, which NUM-1 asks for, and the note now says which frames carry none.
  - The reflection mutation of row 16 was run a second time with the masks' tests, because `median-lanes.md` names them among the tests that fail; they do.
  - The gates were run once, after WP-905d; section 3 quotes that run.
