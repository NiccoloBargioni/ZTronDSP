# WP-902 — implementer's report (coverage closure, the package as a whole)

| Field | Value |
|---|---|
| Package | WP-902 of §12, "Coverage closure: one package per target below its gate (`WP-902a`, `WP-902b`, …)", acceptance "COV-2 holds", lenses T, A. Split by CR-034 (§11.7) into WP-902a (`CZTronDSP`), WP-902b (`ZTronDSPDesign`), WP-902c (`ZTronDSPAnalysis`) and WP-902d (`ZTronDSPUI`, which takes "COV-2 holds" unchanged) |
| Implementer | Implementer M9-coverage (agent), on brief 66 (`ZTronDSP-handoff/briefs/66-wp-902-coverage-closure.md`) with the common rules of brief 60 |
| Date | 2026-11-22, 03:56 to 04:46; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `74d44f6` ("Checkpoint: m9-export — check passed (round 0)"), clean when the work began. Nothing committed, nothing added to the index |
| Simulator | `ztdsp-27` (iOS 27.0), already booted when the work began and left booted. Three other simulators are booted, none by this work and none named `ztdsp-*`: "iPhone 16 Pro" (iOS 18.0), `ztron-diag-18.6` and `ztron-parity-27.0-iPad-10th-generation` (their device files last changed at 03:15, 02:37 and 03:30, before this work began); left alone, as the rules ask |
| Ledger | WP-902 `Retired`; WP-902a, WP-902b, WP-902c, WP-902d `Verifying`, implementer `Implementer M9-coverage (agent)` |
| Change request | CR-034, the split (`Proposed`) |

The four part reports: `impl-WP-902a.md` (which also holds the measurement every part rests on: the method,
the denominator, the table of every production file of run 1), `impl-WP-902b.md`, `impl-WP-902c.md`,
`impl-WP-902d.md` (which also holds WP-902's own check, COV-2, with the gate's lines).

**In short.** COV-2 holds on a fresh instrumented run: aggregate 99.55 % (25 716 of 25 831 lines), every
production target that has executable lines at 98.70 % or more. It held before the work as well. Seven of the 265 measured production
files were below 97.5 %; one is closed (`ztd_thread.c`, by a mark of COV-4 b on a branch no input reaches), and
the other six are named with their reason in the ledger: five Design files and one Analysis file by findings
of the verification waves, whose fix cycles rewrite those lines (the brief's rule), and one UI file by COV-3's
exception (a real touch or an older OS; the device run). One production line changed (a comment); no test
was added; no public symbol changed. The scripts' own self-test counted the ledger's rows as §12's packages
and failed on the split's rows; its count now leaves the parts of a split aside (section 2.2).

## 1. Files added, changed, deleted

Changed:

- `Sources/CZTronDSP/ztd_thread.c`: one line added, line 44, the mark
  `// coverage:ignore(the kernel refuses a thread that is gone, a flavour it does not know or a short count; the calling thread asking with its own count is none of these)`
  above the `if` of `ztd_thread_base_priority`. No code changed.
- `Docs/Process/ledger.md`: the row of WP-902 `Retired`, its backlog naming CR-034; four rows WP-902a…d
  directly under it (section 2.2).
- `Scripts/tests/test-process-files.sh` (the self-test of the process files, WP-008), lines 68–82: its count of
  the ledger's rows leaves out the rows of a split's parts. It pinned every row at 289 and failed once the
  split was in the ledger (section 2.2).

Added:

- `Docs/Process/changes/CR-034.md`, the split (`Proposed`).
- `Docs/Process/reports/impl-WP-902.md` (this report), `impl-WP-902a.md`, `impl-WP-902b.md`, `impl-WP-902c.md`,
  `impl-WP-902d.md`.

Deleted: none.

Outside the tracked files: the logs, `.build/logs/m9-coverage/`; the per-line reports of both runs and of the
llvm-cov cross-check, `.build/tmp/m9-coverage/` (32 MB, kept as the reports' evidence); the result bundle of
run 2, `.build/ci-results/Debug.xcresult` (24 MB, kept: gate 6 reads it). The instrumented derived data this
work made at 03:56, `.build/ci` (721 MB), was deleted at 04:22, after the runs. The notes:
`ZTronDSP-handoff/agent-states/m9-coverage-notes.md`.

## 2. Item by item (brief 66, "Design")

### 2.1 Measure first

The specified path, COV-1: one instrumented build and one run of every test target in Debug on `ztdsp-27`,
read with `xccov` by the gate. The commands are those gate 5 of `Scripts/ci.sh` runs for its result bundle:

```
ZTD_DERIVED=$PWD/.build/ci ZTD_XCARGS="-enableCodeCoverage YES" Scripts/xc.sh build
ZTD_DERIVED=$PWD/.build/ci ZTD_CONFIG=Debug \
  ZTD_XCARGS="-enableCodeCoverage YES -resultBundlePath .build/ci-results/Debug.xcresult" Scripts/xc.sh test-only
TMPDIR=$PWD/.build/tmp/m9-coverage Scripts/coverage-gate.sh --xcresult .build/ci-results/Debug.xcresult \
  --mode aggregate --mode per-target
```

`xccov` listed every production file of the main tree, so the llvm-cov helpers of
`ZTronDSP-handoff/tools/coverage/` served only as a cross-check. Run 1 on `74d44f6`, 04:00–04:04; run 2, the
fresh run after the closure, 04:10–04:15. Both: 2 118 tests passed. By target (per file: `impl-WP-902a.md`,
section 1, and the notes):

| Target | Files | Run 1 | Files below 97.5 %, run 1 | Run 2 | Files below 97.5 %, run 2 |
|---|---:|---|---:|---|---:|
| `CZTronDSP` | 20 | 99.70 % (2 344 of 2 351) | 1 | 99.79 % (2 344 of 2 349) | 0 |
| `ZTronDSPCore` | 78 | 99.69 % (8 415 of 8 441) | 0 | the same | 0 |
| `ZTronDSPDesign` | 44 | 98.70 % (4 703 of 4 765) | 5 | the same | 5 |
| `ZTronDSPMetal` | 17 | 100.00 % (1 445 of 1 445) | 0 | the same | 0 |
| `ZTronDSPAnalysis` | 63 | 99.85 % (5 418 of 5 426) | 1 | the same | 1 |
| `ZTronDSPIO` | 13 | 99.48 % (1 153 of 1 159) | 0 | the same | 0 |
| `ZTronDSPUI` | 30 | 99.64 % (2 238 of 2 246) | 1 | the same | 1 |
| `ZTronDSP` (the facade) | 0 | no executable lines | 0 | the same | 0 |
| **aggregate** | 265 | **99.55 %** (25 716 of 25 833) | 7 | **99.55 %** (25 716 of 25 831) | 6 |

**The denominator** (COV-1, COV-6), checked on run 1 file by file against the disk: exactly the production
targets of §4.2, Swift and C (`CZTronDSP`: 19 `.c` files and `ztd_sink_node.m`). Outside it: `ZTronDSPTesting`
and `CZTronDSPTesting`, all of `Tests/` (the benchmarks among them), `Examples/` and `ExternalParity/` (projects
of their own, and no path of theirs is `Sources/<production target>/…`). Of the production files, 22 are not in
`xccov`'s report: 4 with no function body, the 5 files of `Order/OrderDiagnostics…` (56 functions, each
`@available(*, unavailable, message:)`, never compiled to code), and the 13 C headers, of which four hold
executable lines (45 in all, `static inline` functions and macro expansions). llvm-cov sees those four
headers and runs every one of their lines. Compared line by line, llvm-cov and `xccov` disagree on 24 lines
of production files, and on each of them `xccov` is the stricter. Details: `impl-WP-902a.md`, "The denominator".

### 2.2 The split

One part per target that holds a file below 97.5 % (no target is below 95 %), lettered in the order of §4.2
without a gap, as brief 66 asks ("letter only the targets that need a part, in that order"): WP-902a
`CZTronDSP`, WP-902b `ZTronDSPDesign`, WP-902c `ZTronDSPAnalysis`, WP-902d `ZTronDSPUI`. CR-034 (Kind "Split
(§11.7)", `Proposed`) partitions the acceptance: each part takes its target's per-file closure, and WP-902d
takes WP-902's one check, "COV-2 holds", unchanged. In the ledger the row of WP-902 is `Retired` and the four
parts stand directly under it, each with the lenses `T, A`, the dependencies `all`, status `Verifying`,
implementer `Implementer M9-coverage (agent)` and its backlog. `Scripts/ledger.sh --check` accepts parts that
are not in §12 when their package is `Retired` (`Scripts/lib/ledger.py`), and re-deriving the ledger changes
nothing (`--update` on a copy).

The self-test of the process files did not accept it. It counted every row of the ledger as one of the 289
packages of §12, and the first `Scripts/tests/run-all.sh` of this work (04:25–04:33) failed on the split's four
rows: "FAIL  it has one row for each of the 289 packages (293 rows)", "run-all: FAILED: process-files (1 of 1033
checks failed)". §11.7 and `ledger.py` make a split add rows to the ledger, so the count was what was wrong, not
the ledger. I changed it to leave out a row whose `WP-nnn` row is `Retired` (the parts, which `--check`, the
check just above it in the test, vouches for) and kept the 289. A part that §12 itself lists (WP-110a, WP-431c,
…) has no retired row above it and is still counted. The count, before and after, on scratch copies
(`.build/tmp/m9-coverage/count-check/`):

| Ledger | Old count | New count | The new check |
|---|---:|---:|---|
| at `74d44f6`, before the split | 289 | 289 | passes, as the old one did |
| today's, with the split | 293 | 289 | passes (the old one failed) |
| today's without the row of WP-517 | 292 | 288 | fails: a package without a row is still caught |
| today's with WP-902 `Verifying`, not `Retired` | 293 | 293 | fails: parts of a package that is not retired are counted |
| today's with an escaped `\|` in the cell of WP-902's package | 293 | 289 | passes: the status is still read from its column |

The self-test alone after the change: "ok    it has one row for each of the 289 packages, the parts of a split
aside", "45 checks, 0 failed", exit 0. CR-034 says so under "Sections affected".

### 2.3 Closing the parts

| Part | File below 97.5 % (run 1) | What was done | Tests added | Line mutated |
|---|---|---|---|---|
| WP-902a | `ztd_thread.c` 96.88 % (62 of 64), the refusal branch of `ztd_thread_base_priority` | A COV-4 b mark: `thread_info` asked about the calling thread, with its own flavour and count, has no refusal any input can reach (the function ran 492 times in run 2, the branch never). After: 100.00 % (62 of 62) | none: no input reaches the branch | The mark's line removed, on the same per-line report: the gate fails, "Sources/CZTronDSP/ztd_thread.c … 96.88 % (62 of 64 lines), needs 97.50 %: FAIL", exit 1; restored byte for byte, exit 0 |
| WP-902b | five files, 91.94 % to 97.33 % | Named: every line not run is the subject of a confirmed blocking finding of wave 2 (m4b, lens B): B-4, B-5, B-6, B-7. Brief 66: where a finding touches the uncovered lines, leave them, name the finding; fix cycle 1 of M4b covers them | none | none |
| WP-902c | `ConstantQ/ConstantQProjection.swift` 96.15 % (50 of 52), lines 41 and 44 | Named: finding B-8 of wave 3 (m5c, lens B, WP-523), exactly these lines; fix cycle 1 of M5c | none | none |
| WP-902d | `Pinch/PinchGestureModifier.swift` 92.86 % (104 of 112), lines 95–96, 215–217, 225–227 | Named: COV-3's exception, as brief 66 says for UI lines that need a real touch or an older OS; in the ledger's backlog of WP-820 (since 2026-11-21) and of WP-902d, measured in the device run (WP-904b) | none | none |

The rest of the brief's step 3:

- **IO through the seams of COV-5**: no file of `ZTronDSPIO` is below 97.5 % (the lowest,
  `Session/MicrophoneAuthorizing.swift`, 97.96 %), so no decision needed moving behind a seam.
- **Marks of COV-4 b**: one added (it excuses two lines, 46 and 47). In all: 17 lines of 25 831, 0.07 %, below
  0.5 %. The 15 before it are in `Nodes/CepstralCoefficientNodes.swift`, `Nodes/LevelAndWaveformNodes.swift`,
  `Nodes/TransformPlans.swift`, `Steps/FramingSupport.swift`, `ConstantQ/ConstantQKernel.swift` (Analysis),
  `File/FileReader.swift` and `Session/AudioSessionControlling.swift` (IO); the gate checks each excuses a line.
- **Dead code**: none deleted. The one unreachable line found (`ztd_plan.c` 287–288, `case ZTD_SWITCH_ACTIVE: break;`,
  which line 249 never lets an active entry reach) is the label an exhaustive switch needs under `-Wswitch` with
  warnings as errors, in a file at 98.75 %.
- **Defects a new test exposes**: no test was added. Seen while reading, not run, and not this package's:
  `HostedPinchTests.everyPathInstallsItsGesturesAndHearsAPinch` expects iOS 18 or later, while CI's gate 5 also
  runs every test target on iOS 17.5 (`impl-WP-902d.md`, section 5).

### 2.4 Shader coverage (COV-4 a)

`Sources/ZTronDSPMetal/Shaders/` holds five `.metal` files with nine functions: the entry points
`ztd_screen_vertex`, `ztd_heatmap_fragment`, `ztd_median_kernel`, `ztd_probe_fragment`, `ztd_waveform_fragment`
and the helpers `ztd_heatmap_range_max`, `ztd_heatmap_row`, `ztd_heatmap_between`, `ztd_waveform_range`.
`Docs/Process/shader-coverage.md` has one row for each, every one naming a test that exists under `Tests/` and
renders or computes through it (the pipelines bind the entry points by name, `MetalContext.swift` lines
212–230). Nothing to add; `Scripts/lint-bans.sh` (its part 4) keeps the register equal to the code, and
passes.

### 2.5 The gate

On run 2, `Scripts/coverage-gate.sh` in the aggregate and per-target modes passes, and so does gate 6 of
`Scripts/ci.sh`. The lines are in section 3.

### "Done means", item by item

| Brief 66 asks | Where it stands |
|---|---|
| COV-2 holds on a fresh instrumented run, with the gate's final lines | Yes: run 2, section 3 |
| Every file of every production target at 97.5 % or more, or named with its reason | 259 of the 265 measured files at 97.5 % or more; the other 6 named in the ledger's backlog of WP-902b (B-4…B-7), WP-902c (B-8) and WP-902d (COV-3's exception, also at WP-820); none of the 22 files `xccov` does not list hides a line that does not run |
| Each part's report lists the tests added per file and one line mutated per file | Each says so: no test was added in any part; part a shows the gate failing without its mark |
| All gates of the common rules | Section 3 |
| Every test target in Debug and Release | 2 118 tests each, section 3 |
| Ledger: the split, each part `Verifying`, implementer `Implementer M9-coverage (agent)`; `Scripts/ledger.sh --check` | Yes; section 3 |

## 3. Gates and test totals

Each line below is copied from the log named, under `.build/logs/m9-coverage/`.

**COV-2, run 2** (`gate-run2.txt`), `TMPDIR=$PWD/.build/tmp/m9-coverage Scripts/coverage-gate.sh --xcresult .build/ci-results/Debug.xcresult --mode aggregate --mode per-target`, exit 0:

```
coverage-gate: 17 lines marked coverage:ignore (0.07 % of the production lines, below 0.50 %)
coverage-gate: aggregate      99.55 % (25716 of 25831 lines), needs 97.50 %: ok
coverage-gate: CZTronDSP        99.79 % (2344 of 2349 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPCore     99.69 % (8415 of 8441 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPDesign   98.70 % (4703 of 4765 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPMetal    100.00 % (1445 of 1445 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPAnalysis 99.85 % (5418 of 5426 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPIO       99.48 % (1153 of 1159 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPUI       99.64 % (2238 of 2246 lines), needs 95.00 %: ok
coverage-gate: ZTronDSP         no executable lines (0 of 0 lines), needs 95.00 %: ok
coverage-gate: pass (aggregate, per-target)
```

**Gate 6**, `Scripts/ci.sh --gate 6` (`ci-gate6-run2.txt`), exit 0: the same lines, then
"ci: [gate 6] ok: coverage: aggregate and per target", "ci: gate 6  coverage                             passed",
"ci: no gate failed". With `ZTD_CI_CHANGED_FILES=Sources/CZTronDSP/ztd_thread.c` (`ci-gate6-changed-run2.txt`):
"coverage-gate: Sources/CZTronDSP/ztd_thread.c                     100.00 % (62 of 62 lines), needs 97.50 %: ok",
"coverage-gate: pass (changed-files)", "ci: no gate failed" — COV-3 for the one source this package changes.

**The tests**, every test target, the instrumented run 2 (`test-ci-2.log`, 04:10–04:15), Debug
(`Scripts/xc.sh test`, `test-debug.log`, 04:16–04:19) and Release (`ZTD_CONFIG=Release Scripts/xc.sh test`,
`test-release.log`, 04:19–04:22); each ended "** TEST EXECUTE SUCCEEDED **", exit 0:

| Target | Debug | Release |
|---|---|---|
| `ZTronDSPUITests` | ✔ Test run with 278 tests in 19 suites passed after 2.847 seconds. | ✔ Test run with 278 tests in 19 suites passed after 2.327 seconds. |
| `ZTronDSPTests` | ✔ Test run with 20 tests in 5 suites passed after 3.172 seconds. | ✔ Test run with 20 tests in 5 suites passed after 0.775 seconds. |
| `ZTronDSPTestingTests` | ━ Test run with 55 tests in 8 suites passed after 0.209 seconds with 3 known issues. | ━ Test run with 55 tests in 8 suites passed after 0.027 seconds with 3 known issues. |
| `ZTronDSPMetalTests` | ✔ Test run with 118 tests in 12 suites passed after 7.898 seconds. | ✔ Test run with 118 tests in 12 suites passed after 0.712 seconds. |
| `ZTronDSPIOTests` | ✔ Test run with 134 tests in 13 suites passed after 4.491 seconds. | ✔ Test run with 134 tests in 13 suites passed after 4.540 seconds. |
| `ZTronDSPDesignTests` | ✔ Test run with 339 tests in 41 suites passed after 58.217 seconds. | ✔ Test run with 339 tests in 41 suites passed after 1.861 seconds. |
| `ZTronDSPCoreTests` | ✔ Test run with 511 tests in 60 suites passed after 9.170 seconds. | ✔ Test run with 511 tests in 60 suites passed after 4.863 seconds. |
| `ZTronDSPAnalysisTests` | ✔ Test run with 431 tests in 41 suites passed after 97.806 seconds. | ✔ Test run with 431 tests in 41 suites passed after 11.994 seconds. |
| `CZTronDSPTests` | ✔ Test run with 232 tests in 31 suites passed after 7.115 seconds. | ✔ Test run with 232 tests in 31 suites passed after 1.519 seconds. |

2 118 tests in each configuration, as in both instrumented runs. The three known issues are the
`withKnownIssue` self-tests of `ZTronDSPTestingTests` (`AllocationAuditTests.swift:124`,
`ClosenessTests.swift:78`, `PipelineAuditTests.swift:92`: a harness shown to catch a failure), in every run.

**The gates of the common rules**:

| Gate | When | Final lines | Exit |
|---|---|---|---|
| `Scripts/lint-bans.sh` | 04:43:33–04:43:37 | "lint-bans: clean (parts 1, 2, 3, 4; 609 files)" | 0 |
| `Scripts/check-dependency-graph.sh` | 04:43:37–04:43:38 | "check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)" | 0 |
| `Scripts/api-digest.sh --check` | 04:23:14–04:24:04 | "api-digest: 10 digests equal the built modules", "api-digest: 66 public initialisers of 43 stage types end in `isActive:`", "api-digest: Docs/API/spec-map.tsv lists every public symbol of 10 digests in 712 lines (555 at the specification, 157 at 12 change requests)", then "… references public symbols only" for Design, Metal, Analysis, IO and UI. No public symbol added, changed or removed | 0 |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 04:33:18–04:34:37 | "compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences" | 0 |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 04:24:04–04:24:09 | "order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current" | 0 |
| `Scripts/golden.sh --check` | 04:43:38 | "golden: 199 files of 29 generators match the manifest", "golden: 11 golden MATLAB scripts pass the static check (Scripts/lib/matlab_check.py, MAT-2)" | 0 |
| `Scripts/check-function-effects.sh` | 04:24:09–04:25:43 | "ok    the package builds: all 19 sources of CZTronDSP compiled with -Werror=function-effects", "ok    the target builds clean: no diagnostic names a file of CZTronDSP", "function effects: all checks passed" | 0 |
| `Scripts/ledger.sh --check` | 04:43:38 | "ledger: 293 rows, consistent with §12 and §11" | 0 |
| `Scripts/tests/run-all.sh`, before the change of 2.2 | 04:25:43–04:33:18 | "  FAIL  it has one row for each of the 289 packages (293 rows)", "run-all: FAILED: process-files (1 of 1033 checks failed)" | 1 |
| `Scripts/tests/run-all.sh`, after it | 04:36:23–04:43:33 | "run-all: every self-test passed (1033 checks in 16 suites, 2 skipped: see above)"; the two skips are the suites' own, "gate 1 with a real build and a seeded warning (run this test with --slow)" and "the parity tests on the simulator with a seeded violation (run this test with --slow)" | 0 |
| `Scripts/external-parity.sh` | 04:34:37–04:36:03 | "external-parity: passed", every step passed (rules, guide, build, test, fixtures, release, audits, speed); the known issues it names are the probe's self-test (`AllocationAuditTests.swift:42`) and the gain written as a `SampleProcessor` (`SpeedTests.swift:284`, CR-025 item 1) | 0 |

The logs: `gate-<name>.log` for each (`gate-run-all.log` the first self-test run, `gate-run-all-2.log` the
second), `test-process-files-after.log` for the self-test alone. The Debug and Release runs, `api-digest.sh`,
`compile-fixtures.sh`, `order-matrix.sh`, `check-function-effects.sh` and `external-parity.sh` ran before the
change to the self-test; none of them reads the file it changed. The others ran after it.

## 4. Open

- **WP-902b** (`ZTronDSPDesign`): the five files of B-4…B-7, until fix cycle 1 of M4b; then a fresh run and
  `Scripts/coverage-gate.sh … --mode changed-files` on the five paths. Owner: that cycle's implementer.
- **WP-902c** (`ZTronDSPAnalysis`): `ConstantQ/ConstantQProjection.swift`, B-8, until fix cycle 1 of M5c. Owner:
  that cycle's implementer.
- **WP-902d** (`ZTronDSPUI`): `Pinch/PinchGestureModifier.swift`, eight lines that run only on iOS 17, on iOS 15
  and 16, or under a real two-finger touch; measured in the device run (WP-904b), or covered by a coverage run of
  the gallery's UI tests on 17.5, as the owner decides (decision 8 of the integration of 2026-11-21). Owner: the
  integrator. COV-3's exception has the device run "merged before COV-2 is evaluated"; it has not been made.
  No production source branches on the simulator, so merging it can only add covered lines: a reading, not a
  measurement.
- **What line coverage does not see** (measured, from the per-line report's sub-ranges): the gesture handlers
  that share a line with the call installing them (lines 206, 207, 218, 228 of `PinchGestureModifier.swift`,
  the iOS 18 path among them) count as run, and their closures ran 0 times; a real touch reaches them.
  COV-1 counts lines, so the gate is right by its rule. For the device run.
- **Read, not run**: on CI's iOS 17.5 job, `HostedPinchTests.everyPathInstallsItsGesturesAndHearsAPinch` would
  fail its last expectation (`PinchPath.current == .touches`). The package's tests have been run on 27.0 only.
  For the integrator (WP-819, WP-820).
- **The C headers** with executable lines (four, 45 lines) are not in `xccov`'s report, so not in the
  denominator; llvm-cov shows every one of their lines run. COV-1 names `xccov`, so the gate is unchanged.
- **Not run here**: `Scripts/ci.sh --gate 5` as one command, which also runs the gallery's hosted suites
  (`Examples/`, outside the denominator) and the Release allocation-audit filters (a subset of the full
  Release run above); the other runtimes of the matrix (17.5, 18.6, 26.5); the device run.

## 5. Change requests and decisions for the owner

1. **CR-034**, the split of WP-902 into WP-902a…d (§11.7, the owner approves a split): approve it, or say how
   the parts should be cut. Until then the ledger carries the parts as the brief asked, and §12 is unchanged.
2. **Decision 8 of the integration of 2026-11-21**, repeated here because WP-902d depends on it: accept COV-3's
   exception for the eight lines of `PinchGestureModifier.swift` until the device run, or ask for a coverage run
   of the gallery's UI tests on 17.5, which would cover lines 95 and 215–217 (96 and 225–227 need iOS 15 or 16).
3. **Recorded, not asked**: the change to the self-test of the process files (section 2.2), so that a split
   the ledger records as §11.7 says does not fail the scripts' own tests. If the owner would rather a split wait
   until §12 lists its parts, the four rows of the parts go, and with them the reason for the change.
