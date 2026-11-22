# WP-905a — implementer's report

| Field | Value |
|---|---|
| Package | WP-905a: audit of the algorithm and stability registers, rows 1 to 6 (§7.2, §7.3, §7.5); the audit table `Docs/Numerics/register-audit-2026-11.md` and its mechanical check |
| Implementer | Implementer M9-registers (agent), brief 64 with the common rules of brief 60 |
| Date | 2026-11-21, and 2026-11-22 after midnight for the gate run of section 3; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `53a095d`. Everything below is unstaged or untracked. This work committed nothing and added nothing to the index |
| Ledger | WP-905a `Verifying`, implementer `Implementer M9-registers (agent)` (with WP-905b, c and d, at the end of the run) |
| Change request | None from this package (rows 1–6). CR-020 item 9 comes from row 13 (WP-905c) |

The audit itself, row by row, with every measured figure and every mutation, is `Docs/Numerics/register-audit-2026-11.md` (the table, then "WP-905a: rows 1 to 6"). This report gives what changed, what each change does, and how it was checked.

## 1. Files

### Added

| File | What it is |
|---|---|
| `Docs/Numerics/register-audit-2026-11.md` | The audit: a table of the 24 rows of §7.2 (columns `#`, Operation, Packages, Notes, Currency, Notes against the code, Stress tests, Mutations, Precision, Open), then the evidence of each row, one section per package. Rows 1–6 and their evidence are this package's |
| `Scripts/check-registers.sh` | The mechanical check of the table (no argument; `--audit FILE --spec FILE --root DIR` for the self-test) |
| `Scripts/lib/registers.py` | Its engine. It requires one row per row of §7.2, numbered and named as there, each with its twin in §7.5. No cell may be empty (`-`, `—`, `pending`, `tbd`, `todo` and `…` count as empty; `open: <id>` and `not searched` count as filled). The currency cell must carry a date. Every backticked path must exist. Every test is named with its file and declared there. Every `ALG` package of §12 must be in exactly one row. Every note of `Docs/Numerics` must be named by a row or listed as supplementary |
| `Scripts/tests/test-check-registers.sh` | Self-test, 45 checks. The good fixture passes and says what it checked (2 checks). 19 seeded defects each fail with their own sentence, 2 checks each: a missing row, rows out of order, a misnamed operation, a row without its twin in §7.5, an empty cell, a cell left `pending`, a currency without a date or with a date that does not exist, a missing file, a test the file does not declare (two forms), a test named without its file, an `ALG` package in two rows or in none, a package that is not `ALG`, a note named by no row, a row without a note, a note that does not exist, a header with a column missing. No audit at all (2 checks), a usage error (1), and the real tree, which must pass with its 24 rows (2) |
| `Tests/Fixtures/Registers/Good/` | The fixture of the self-test: a small specification, an audit, notes, sources and tests |
| `Docs/Process/reports/impl-WP-905a.md` | This report |

### Changed

| File | What changed |
|---|---|
| `Scripts/tests/run-all.sh` | `check-registers` added to `SUITES`, after `process-files` |
| `Tests/ZTronDSPAnalysisTests/StabilityTests.swift` | Printing only (row 1): the worst forward and round-trip errors per length, the error by depth under the frame maximum, the worst decibel error. No expectation changed |
| `Tests/CZTronDSPTests/RingTests.swift` | New test `RingStorageTests.aSessionLongerThanTwoToThe32FramesKeepsEveryFrameAndEveryCount(storage:)` (row 2) |
| `Tests/ZTronDSPDesignTests/SavitzkyGolayTests.swift` | New test `SavitzkyGolayCoefficientTests.stressAWindowWhosePowersLeaveADoubleIsFitOnTheScaledAbscissa` (row 6) |
| `Docs/Numerics/mirrored-ring.md` | Hazard 3 qualified (a 32-bit position would wrap harmlessly: the ring's counts are differences modulo 2³² and its indices masks; 64 bits protect the absolute counts); the new test and the mutations of 2026-11-21 recorded |
| `Docs/Numerics/savitzky-golay.md` | What the scaled abscissa is for (range, not accuracy, on the existing fixture) and the new test |
| `Docs/Numerics/fir-design.md` | Four rows of the second table marked as the implementer's measurement of 2026-11-15 that no test prints (F-905a-2), with what the tests do print |
| `Docs/Numerics/currency-2026-11.md` | The second pass of 2026-11-21, appended; the first pass is unchanged (shared by the four packages) |

### Deleted

None in the tree. A stray empty file that a mistyped command of mine created outside the tree (`/Users/admin/Documents-placeholder`, 0 bytes) was removed at 21:21; nothing else outside the tree was touched.

`git diff --stat -- Sources` is empty after the last mutation of every package: no production source was changed.

## 2. Items

For each row: what was searched, which notes were checked against the code, which figures were reproduced, which mutations were made and what failed, which tests were added, and what was found. A mutation was made in the tree, one at a time, from a saved copy, and the file was restored byte for byte (`cmp` against the copy, never git). The runner is `.build/m9-registers/run-mut.sh`; the logs are `.build/logs/m9-registers/batch-row2.log`, `batch-row3.log`, `batch-row4.log`, `batch-row56.log` and `mut-<id>.log`.

| Row | Currency (2026-11-21) | Notes checked | Figures | Mutations | Tests added or strengthened | Findings |
|---|---|---|---|---|---|---|
| 1 Real FFT (WP-502) | current: iOS 27 notes and security content, arXiv 2603.29129 (107–1 315 times slower), arXiv 2506.12718, MPSGraph | `real-fft.md`: true | all reproduced: forward 4.98e-8 … 1.668e-7, round trip ≤ 6.56e-7, depth table 3.714e-6 … 67.33, decibels 7.273e-4 | 4 run, 4 killed (floor, halving, Nyquist bin, admission) | printing only in `StabilityTests` | cited open: A-24, A-NB20 (wave 3) |
| 2 Framing (WP-203) | current: double-mapped rings in current use; the copy on wrap stays the alternative | `mirrored-ring.md`: corrected (hazard 3) | the new test: 4.297·10⁹ frames, overrun 8.5899·10⁹; residency by `mincore` | 8 run: 6 killed (one, the 32-bit overrun count, only by the new test), 2 equivalent (32-bit positions; the proof's comparisons with the remap kept) | `aSessionLongerThanTwoToThe32FramesKeepsEveryFrameAndEveryCount` (both storages) | F-905a-1 (low): the proof of the mirror cannot be exercised by a test |
| 3 IIR filtering (WP-208, WP-211) | current: nothing peer-reviewed on biquad round-off since 2025; state-variable filters stay CR-020 item 4 | `biquad-single.md`, `biquad-double.md`, `biquad-precision.md`: true | all reproduced (impulse 1.5482e-6, 2.4192e-7; noise orders 2–8; blocks; single against double −98.352 … −120.79 dB; 3.4033e-5 dB; the grid −100.2053 dB) | 9 run, 9 killed | none needed | cited open: A-B1 (wave 2), CR-013 items 4 and 5 |
| 4 IIR design (11 packages) | current: s-to-z mappings, elliptic functions, Bessel zeros | eleven notes: true | all reproduced (e.g. 1.651e-13 against 0.01683; 7.76e-18; 9.45e-13 against 0.01755) | 15 run, 15 killed | none needed | cited open: A-2, A-3, A-NB2, A-NB4, A-NB5 (wave 1) |
| 5 FIR design (WP-423, WP-425) | current | `fir-design.md`: corrected (four rows marked unreproduced) | what the tests print is reproduced (1.11e-15, 5.55e-16, 3.47e-18, 2.74e-14, 2.386, 2.75e-5, 1.71e-14) | 4 run, 4 killed | none | F-905a-2 (low); cited open: A-1 (wave 2) |
| 6 Savitzky–Golay (WP-426) | current: nothing newer than CR-020 item 1 | `savitzky-golay.md`: corrected (what the scaling is for) | 4.4569e-13, 8.8834e-16, 8.9495e-16, 8.4686e-8, 7.2099e-8; the new test 6.2359e-15 | 2 run, 2 killed (the scaling only by the new test) | `stressAWindowWhosePowersLeaveADoubleIsFitOnTheScaledAbscissa` | none |

What failed without each change:

- **Row 2, the new test.** Two mutations show what it holds. With the overrun count narrowed to 32 bits (R2-dropped32), it fails on both storages ("every dropped frame is counted: 4294967294"), and no other test of the target fails. With the remap and its proof removed (R2-noremap), it fails with five other tests. With the two positions narrowed to 32 bits (R2-counter32) it passes, and so does every other test: the arithmetic of the ring is modular. The note now says so, and the mutation is recorded as equivalent. The test is seeded (the non-finite fixture of WP-016), has no sleeps, and takes 2.5 s for both cases in Debug.
- **Row 6, the new test.** The abscissa left unscaled (R6-noscale) passed every test as they were, because the existing check of order 150 accepts a typed error from either route. The new test then fails alone, with `numericalFailure(routine: "dgels")` on the raw abscissa (R6-noscale-2).
- **Row 1, printing.** No expectation changed, so nothing fails differently. The four mutations of the row fail the tests as they were (R1-floor: 40 tests, 22 issues; R1-halving: 298 issues in 24 tests; R1-nyquist: 112 issues; R1-admit: 10 cases).
- **The check.** `Scripts/tests/test-check-registers.sh` seeds 19 defects into copies of the fixture, and each fails `check-registers.sh` with its own sentence. Its last two checks failed until the audit had all 24 rows.

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

- F-905a-1 (this audit, low): the proof of the mirror (`ztd_ring.c`, the loop after `vm_remap`) is exercised by no test that could fail. A test would need a way to make the remap report success for something that is not a mirror. A seam is a design decision, not a few-line fix, so none was added.
- F-905a-2 (this audit, low): four rows of the second table of `fir-design.md` are figures that no test prints. The remedy is a test that measures them, or their removal from the note.
- Wave findings on rows 1–6, cited open and not fixed here: A-24 and A-NB20 (wave 3, m5b: no upper bound on transform lengths); A-B1 (wave 2: CR-018 item 1 understates the miss on unseen noise); A-2, A-3, A-NB2, A-NB4, A-NB5 (wave 1, m4a); A-1 (wave 2, m4b: the ill-conditioned FIR fixture held to 1e-4).
- The figures of this audit are from the iOS 27.0 simulator, Debug, unless a row says otherwise; Release is the gate run of section 3.

## 5. Change requests and owner decisions

- No change request from rows 1–6. CR-013 items 4 and 5 (Proposed) are cited for row 3.
- No owner decision was needed or taken. Decisions recorded here and in `Docs/Numerics/register-audit-2026-11.md`:
  - Two mutations of row 2 are recorded as equivalent, each with its reason, instead of being forced into a test: 32-bit positions, and the proof's comparisons removed with the remap kept.
  - Rows 1–6 were audited and their mutations run before rows 7–12. The gates of brief 60 were run once, after WP-905d, over the tree that holds all four packages; section 3 quotes that run. Four separate full gate runs would have tested the same production code four times (none of it changed).
