# Implementer report — WP-906, the release checklist of 0.1.0

Implementer M9-release (agent), 2026-11-22, Europe/Rome. Brief 67 (WP-906) under brief 60, in the
main tree on branch `handover-chain` at HEAD 4c54d23. Nothing committed, staged, stashed or tagged.

**In short.** The checklist, `Scripts/release-check.sh` and its self-test exist; the self-test is in
`run-all.sh`. The script ran once today, 12:05–14:06, over all 39 items: **it exited 1, without
`--allow-open`: 20 passed, 6 failed, 13 open. The acceptance of WP-906, "every gate of §10.3 green", is
not met.** Seven of the nine gates passed; gate 5 failed (the UI tests on iOS 17.5, 18.6 and 26.5; 27.0
is green) and gate 8 is open for the owner (no benchmark baseline for a pinned runner). The run found
two defects of the scripts, both repaired with a self-test case (sections 2 and 3); a third, in
`ci.sh`, was found and repaired before the run. The failing UI tests were run again alone: most fail
alone too, on the runtimes before 27.0; five on 17.5 fail only in the full bundle and pass alone twice
in a row. None of them is this package's to repair. Every gate of the common rules passes after the
changes, and every test target passes in Debug and in Release (2 118 tests each). Ledger row WP-906:
`Verifying`, the open items in its backlog.

## (1) Files

Added:
- `Docs/Release/0.1.0-checklist.md` — the checklist
- `CHANGELOG.md` — the entry of 0.1.0, undated ("Unreleased")
- `Scripts/release-check.sh` — runs the checklist on one machine
- `Scripts/tests/test-release-check.sh` — its self-test
- `Docs/Process/reports/impl-WP-906.md` — this report

Changed:
- `Scripts/ci.sh` — a simulator of `--matrix` / `--runtime` that the run boots is shut down after its
  runs; the verdict line of `--strict` only when a skip failed the run
- `Scripts/tests/test-ci.sh` — 13 checks of those two (189 in all)
- `Scripts/lib/ledger.py`, `Scripts/ledger.sh` — `--release`: every row that is not Done
- `Scripts/tests/test-process-files.sh` — 22 checks of `--release`
- `Scripts/tests/run-all.sh` — the suite `release-check`
- `Docs/Process/ledger.md` — the row of WP-906

Deleted: none. No Swift file is added or changed, so COV-3 and the API digest are untouched.

## (2) Per item of the brief

### The checklist, `Docs/Release/0.1.0-checklist.md`

39 tickable lines in five tables, each with the item's name, what it proves, the command and the last
line that command prints when the item holds:

1. The gates and the checks beside them (20 lines): the nine gates as `Scripts/ci.sh --strict --gate N`
   (gate 5 with `--matrix --tsan`); then what M9 and the specification add to a release and no gate
   runs: the scripts' self-tests with the slow ones (`run-all.sh --slow`), `check-function-effects.sh`,
   `check-perf-annotations.sh`, `spec-crosscheck.sh` (§13.1's first risk), the documentation build
   (`docs.sh --build`, WP-901b), the golden vectors made again by the pinned oracles
   (`golden.sh --reproduce`; gate 7 runs `--check` and `--octave`), the gallery's UI tests on the matrix
   (`ci.sh --strict --nightly --matrix`), the register audit of the release month
   (`check-registers.sh --audit Docs/Numerics/register-audit-YYYY-MM.md`), the registers of
   `Docs/Process` against the code (`lint-bans.sh --part 3 --part 4`: approvals, mutable by design,
   open declarations, unchecked Sendable, shader coverage), the ledger's consistency
   (`ledger.sh --check`) and every row Done (`ledger.sh --release`).
2. PLAT-3 (5 lines): iOS 17.5, the newest 18.x, the newest 26.x and 27.0, each "installed or not" and
   what ran there, read from the log of gate 5; the iOS 15 floor, read from the ledger (WP-338, WP-904a,
   WP-904b), since iOS 15 and 16 cannot be simulated on this host (E-17).
3. The device runs (9 lines): WP-338, WP-708, WP-903a, WP-903b, WP-904a, WP-904b and the crossovers
   WP-611b…d, read from the ledger; a second table gives for each the devices (OD-8's tiers), what runs
   there and where its result is recorded (`Docs/Release/device-runs/WP-nnn.md`, a record whose fields
   the checklist lists, linked from the implementer report; the ledger row turns Done after both lenses),
   with the xcodebuild command for a device.
4. Change requests (1 line): every CR decided, none Proposed; an Approved one carries the owner's name
   and date.
5. Version and metadata (4 lines): `Package.swift` carries no version (checked: it has none), so the
   tag is the version; the CHANGELOG entry with its date; the README's install snippet if there is a
   README (there is none); a tree equal to HEAD throughout the run; no tag 0.1.0 on another commit.

Also there: how to run it (with today's measured time and disk use), the release steps for the owner
after a green run (date the entry, commit, run again, `git tag -a 0.1.0`, push the tag; no agent tags,
commits or pushes), and what the script does not run (the workflow's own strict dispatch, which needs
the pinned runner of gate 8).

### `CHANGELOG.md`

New, Keep-a-Changelog style, with `## [0.1.0] - Unreleased` drafted from M0–M9 (one paragraph per
milestone, from §12's milestone table and the package titles) and a comment saying that the owner dates
it in the commit that is tagged. Not tagged, not committed.

### `Scripts/release-check.sh`

Runs the 39 items of the checklist in its order, always all of them (`--keep-going` is accepted and is
what it always does), and ends each in one line, `PASS`, `FAIL` or `OPEN (device | owner | not
installed)` with its reason and, for a command, the minutes it took; then a tally and a verdict. Exit 0
only when every item passed; with `--allow-open`, exit 0 when none failed; 1 otherwise; 2 on a usage
error. `--list` prints each item and its command and runs nothing. It calls the existing scripts and
re-implements none:

- The 20 command items run in the package, each into a log of its own (`NN-<item>.log`) in the run's
  folder (`ZTD_RELEASE_LOGS`, default `.build/release-check/<date>-<time>`), which also holds
  `summary.txt` and `git status` at the start and at the end. Before each command it reads the free
  space of the disk (`df -g`); below 6 GiB (`ZTD_RELEASE_MIN_FREE_GIB`) the command is not started and
  its item fails, so a run on a full disk never stands as a verdict on the package.
- A gate is read from its own line in ci.sh's summary (`ci: gate N  <name> <result> — <notes>`), not
  from the exit status alone. Every gate runs under `--strict`, and each skip in the notes is
  classified: a PLAT-3 runtime or Octave not installed → `OPEN (not installed)`; gate 8 with no
  baseline for the runner → `OPEN (owner)`; any other skip → `FAIL`, as one this machine could close.
  A skip's own words may hold "; " (gate 8's do): the notes are split on "; skipped: " only.
- `run-all.sh` and `golden.sh --reproduce` exit 0 when they skipped something (a check with no build to
  read; a generator whose oracle is not installed); release-check reads their skips the same way.
  `spec-crosscheck.sh` ends in its notes, so its line shows the tallies (`DEFECTS (0), NOTES (9)`).
- PLAT-3 is read from gate 5's log: for each runtime, "not installed", "no simulator could be made",
  or what the tests in Debug and the gallery's hosted suites did on `ztdsp-ci-<version>`.
- The ledger items read `Scripts/ledger.sh --release` (below): a row not Done that is a device run is
  `OPEN (device)`; any other row not Done fails `ledger-done`. A device run whose package has no row in
  the ledger fails (a package left out is no package Done).
- `change-requests` reads the `Status`, `Approved by` and `Approved on` fields of each CR's table.
  `changelog`, `readme`, `clean-tree` and `tag` check what a tag of 0.1.0 needs: an absent tag passes
  (the tag follows a green run); a tag 0.1.0 on another commit fails.

**The self-test**, `Scripts/tests/test-release-check.sh`, registered in `run-all.sh` (17 suites), runs
the script in a scratch tree with the real `Scripts/ci.sh` among the stand-ins of `test-ci.sh`
(xc, xcodebuild, simctl with the four runtimes, the gallery), stand-ins for every other script, git and
df: **169 checks, 0 failed**, from the green run (39 PASS, the order of the items, the logs,
`summary.txt`) through each kind of result — a failing gate and the gates after it, a skip that is the
owner's, one that is not installed, one this machine could close (alone, and beside a runtime that is
not installed), each PLAT-3 failure, the ledger listings (device runs only, a row that is no device run,
no tally, unreadable, a package without a row), the change requests, CHANGELOG.md, the README, the
tree, the tag, the disk floor, the month of the audit, usage errors — and last the checklist against
`--list`: the same 39 items in the same order, each row showing the command the script runs. What fails
without the script's logic: a mutation check in a scratch copy, four seeded defects of
release-check.sh (every skip open; golden-reproduce read by its exit status alone; no ledger-row check;
no check of the tree at the start), each caught (6, 4, 1 and 2 checks failed).

**Repair A, found by today's run** (a defect of the script). The first item's line carried no minutes
(`PASS gate-1 passed — ci: no gate failed`, every later command item `(N min)`): the start of a timed
item was `$SECONDS`, which is 0 for the first, and 0 also meant "untimed". The start of an untimed item
is now empty. Test: `… with the minutes it took, the first item too` (gate-1's line ends in
`(0 min)`), with `what runs no command has no minutes` and `… none` (the line of `tag`). Undone once:
`test-release-check.sh` printed `FAIL  … with the minutes it took, the first item too` (1 failed);
restored: 169 checks, 0 failed.

### `Scripts/ledger.sh --release` (`Scripts/lib/ledger.py`)

The brief names `Scripts/ledger.sh --check` for "every row Done", but `--check` proves only that the
ledger agrees with §12 and §11 (it passes today with 290 rows not Done). `--release` lists every row
that is not `Done` with its status, then a tally (`ledger: 290 of 293 rows are not Done: …`), and exits
1; a `Retired` package whose parts have rows (§11.7) and an `OPT` package that awaits its trigger hold
nothing up; with none left it prints `ledger: every package is Done (<n> rows; …)` and exits 0. It reads
the statuses as recorded (`--check` says whether they are current). The checklist runs both.
`Scripts/tests/test-process-files.sh`: 22 new checks (the rows not Done named with their status; a Done
row and an OPT row that awaits its trigger left out; the tally; every package Done; an OPT package whose
trigger came; a retired package without parts, and with parts all Done; a part not Done; no ledger);
67 checks, 0 failed.

### `Scripts/ci.sh`: two repairs of the gates' wiring

**Simulators of the matrix left booted** (found while designing, before the run). On the release
machine gate 5 runs `--matrix`: `xc.sh` and `gallery.sh` boot each `ztdsp-ci-<version>`, and nothing shut
them down, so a local run ended with four simulators booted beside the default one, against brief 60's
"one simulator booted at a time" (the workflow runs one runtime per job and never saw it). Now
`boots_it` (a simulator of `--runtime`/`--matrix` that is not booted when its turn comes) and
`shut_down` (`simctl shutdown <udid>`, said in the log) close each one the run booted after its runs: in
gate 5 after its tests and the gallery's hosted suites, in the nightly job after the UI tests. One that
was booted before the run, and the device of `xc.sh` (no `--runtime`, no `--matrix`), are left as they
are. Test, `test-ci.sh` (the simctl stand-in reports `ztdsp-ci-18-6` booted when `STUB_SIMCTL_BOOTED`
says so): 10 checks — `a simulator of the matrix that the run boots`, `… is shut down after its runs`,
`… which is said`, `… after its hosted suites, before the next runtime's tests`, `a simulator of the
matrix that was booted before the run`, `… is left booted`, `the device of Scripts/xc.sh, without
--runtime or --matrix`, `… is left as it is`, `the nightly job on the matrix`, `… shuts down the
simulator it booted, after its UI tests`. Undone once (HEAD's ci.sh, part 1 of the self-test in a
scratch root): the four checks that expect a shutdown failed; restored: 161 checks, 0 failed. In
today's run ci.sh printed `shut down ztdsp-ci-<version>, which this run booted` eight times (four in
gate 5, four in the nightly job).

**Repair B, found by today's run.** Under `--strict`, ci.sh ended every failed run with `ci: --strict: a
skipped gate counts as a failure`, also when nothing was skipped: today's gate 5 failed on its tests and
skipped nothing, and its log ends in that line. It is now printed only when a gate failed because of a
skip (`skip_failed`, set in the branch of `--strict`). Tests, `test-ci.sh`: `… and the verdict says that a
skip counted` (gate 3 with a part missing), `under --strict a gate that fails, with nothing skipped` and
`… is not put down to a skip (WP-906)`. Undone once (part 1 in a scratch root): 164 checks, 1 failed —
`FAIL  … is not put down to a skip (WP-906) (output holds: a skipped gate counts as a failure)`;
restored: 164 checks, 0 failed; the whole `test-ci.sh`: 189 checks, 0 failed.

### Deviations from the brief, and why

1. **`ledger.sh --release`** beside `--check`, as above: `--check` cannot show "every row Done".
2. **The nine gates as nine runs of ci.sh** (`ci.sh --strict --gate N`, gate 5 with `--matrix --tsan`)
   instead of one `ci.sh --keep-going --strict`: the same gate functions in the same order, each with a
   log and a summary line of its own, so that each gate's skips are classified on their own and a gate
   that fails cannot hide the next. `--keep-going` is what release-check does over all 39 items.
3. **Items beyond the brief's list**: `run-all.sh --slow`, `check-function-effects.sh`,
   `check-perf-annotations.sh`, `spec-crosscheck.sh` and `golden.sh --reproduce` — checks of the
   specification that no gate and no job of the workflow runs; each passed today.
4. **The register audit "dated within the release month"** is read as the audit file named for that
   month (`Docs/Numerics/register-audit-2026-11.md`, WP-905's), checked by `check-registers.sh --audit`.
5. **The coverage of a local `--matrix` run is measured on 17.5, the workflow's on 27.0.** ci.sh gives
   the result bundle to the first runtime of the run (`test-ci.sh` asserts it: "the first runtime
   carries the result bundle"); in the workflow each runtime is a job and gate 6 runs in the 27.0 job
   ("coverage, from the run on the newest runtime"). Today's figure is therefore 17.5's: 99.45 %, where
   WP-902 measured 99.55 % on 27.0 the same day; COV-2 holds on both. Not changed: it is a tested choice,
   not a defect, and COV-1 names no runtime. For the integrator to decide (section 5).

## (3) Today's run, and the gates

### The run of `Scripts/release-check.sh`

```sh
caffeinate -i env TMPDIR="$PWD/.build/tmp/m9-release" \
    ZTD_RELEASE_LOGS="$PWD/.build/logs/m9-release/release-check-run1" \
    Scripts/release-check.sh > .build/logs/m9-release/release-check-run1.out 2>&1
```

Without `--allow-open`. 2026-11-22, 12:05 to 14:06 CET (2 h 01 min), on HEAD 4c54d23 with this package's
files uncommitted (the scripts as they were before repairs A and B), release month 2026-11; Apple M3,
24 GiB; free disk about 52 GiB at the start, 41 GiB at the end. All four runtimes of PLAT-3 are installed
(17.5, 18.6, 26.5, 27.0); `ci.sh` made `ztdsp-ci-17-5`, `ztdsp-ci-18-6`, `ztdsp-ci-26-5` and
`ztdsp-ci-27-0`. **Exit status 1.** The full summary, as printed (`summary.txt`):

```
PASS                  gate-1             passed — ci: no gate failed
PASS                  gate-2             passed — ci: no gate failed (0 min)
PASS                  gate-3             passed — ci: no gate failed (0 min)
PASS                  gate-4             passed — ci: no gate failed (1 min)
FAIL                  gate-5             FAILED — tests in Debug on ztdsp-ci-17-5; tests in Debug on ztdsp-ci-18-6; tests in Debug on ztdsp-ci-26-5 (70 min)
PASS                  gate-6             passed — ci: no gate failed (0 min)
PASS                  gate-7             passed — ci: no gate failed (0 min)
OPEN (owner)          gate-8             SKIPPED — skipped: the benchmark regression check: there is no baseline for this runner (the budgets of §5.7 were held; nothing was compared) (3 min)
PASS                  gate-9             passed — ci: no gate failed (2 min)
PASS                  self-tests         run-all: every self-test passed (1237 checks in 17 suites) (14 min)
PASS                  function-effects   function effects: all checks passed (1 min)
PASS                  perf-annotations   perf annotations: all checks passed (2 min)
PASS                  spec-crosscheck    DEFECTS (0), NOTES (9) (0 min)
PASS                  docs-build         docs: .build/docs/ZTronDSP.doccarchive: 16037 pages; 7 links written as a path, each to a page of the archive (1 min)
PASS                  golden-reproduce   29 generators made their committed files again, 29 of them bit for bit (0 min)
PASS                  gallery-ui         passed — ci: no gate failed (24 min)
PASS                  register-audit     registers: 24 rows, 53 ALG packages, 52 notes (0 supplementary), 213 tests and 139 files checked: OK (0 min)
PASS                  registers          lint-bans: clean (parts 3, 4; 609 files) (0 min)
PASS                  ledger             ledger: 293 rows, consistent with §12 and §11 (0 min)
FAIL                  ledger-done        ledger: 290 of 293 rows are not Done: 6 Blocked-on-deps, 74 Fixing, 4 Implementing, 206 Verifying (2 OPT packages awaiting their trigger and 1 retired package hold nothing up) (0 min)
FAIL                  plat3-ios-17.5     installed; on ztdsp-ci-17-5 the tests in Debug failed
FAIL                  plat3-ios-18       installed; on ztdsp-ci-18-6 the tests in Debug failed
FAIL                  plat3-ios-26       installed; on ztdsp-ci-26-5 the tests in Debug failed
PASS                  plat3-ios-27.0     installed; on ztdsp-ci-27-0 the tests in Debug and the gallery's hosted suites passed
OPEN (device)         plat3-ios-15       iOS 15 and 16 cannot be simulated on this host (E-17): WP-338 Blocked-on-deps, WP-904a Blocked-on-deps, WP-904b Blocked-on-deps
OPEN (device)         device-WP-338      WP-338 is Blocked-on-deps in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-708      WP-708 is Implementing in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-903a     WP-903a is Blocked-on-deps in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-903b     WP-903b is Blocked-on-deps in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-904a     WP-904a is Blocked-on-deps in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-904b     WP-904b is Blocked-on-deps in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-611b     WP-611b is Implementing in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-611c     WP-611c is Implementing in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (device)         device-WP-611d     WP-611d is Implementing in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)
OPEN (owner)          change-requests    34 of 34 change requests are Proposed, for the owner to decide: CR-001, CR-002, CR-003, CR-004, CR-005, CR-006, CR-007, CR-008, CR-009, CR-010, CR-011, CR-012, CR-013, CR-014, CR-015, CR-016, CR-017, CR-018, CR-019, CR-020, CR-021, CR-022, CR-023, CR-024, CR-025, CR-026, CR-027, CR-028, CR-029, CR-030, CR-031, CR-032, CR-033, CR-034
OPEN (owner)          changelog          CHANGELOG.md: "## [0.1.0] - Unreleased": the date goes in when the owner releases 0.1.0
PASS                  readme             there is no README, so no install snippet names a version
FAIL                  clean-tree         10 path(s) differed from HEAD when the run began (git status --porcelain: .build/logs/m9-release/release-check-run1/git-status-start.txt): what was checked is in no commit
PASS                  tag                0.1.0 is not tagged yet: the tag goes on HEAD 4c54d238862eb79baa94f48d90b6f99406d50724 once this run passes, and not before
release-check: 39 items: 20 passed, 6 failed, 13 open
release-check: FAILED: 0.1.0 is not ready to tag
```

**The acceptance is not met: the script exited 1 without `--allow-open`** (and would have with it: six
items failed). Every item, classified:

| Item | Result | Cause | Who closes it |
|---|---|---|---|
| `gate-1` … `gate-4`, `gate-6`, `gate-7`, `gate-9`; `self-tests`, `function-effects`, `perf-annotations`, `spec-crosscheck`, `docs-build`, `golden-reproduce`, `gallery-ui`, `register-audit`, `registers`, `ledger`; `plat3-ios-27.0`; `readme`, `tag` | PASS (20) | — | — |
| `gate-5` | FAIL | `ZTronDSPUITests` failed on iOS 17.5 (48 issues), 18.6 (11) and 26.5 (5); the eight other bundles and the gallery's hosted suites passed on all four runtimes, and so did the Release audit and the Thread Sanitizer run; on 27.0 everything passed | the verification waves and fix cycles of the UI packages whose tests fail (WP-808a, WP-814, WP-815, WP-817, WP-820, WP-821), routed by the integrator |
| `plat3-ios-17.5`, `plat3-ios-18`, `plat3-ios-26` | FAIL | the same failures, runtime by runtime | the same |
| `ledger-done` | FAIL | 290 of 293 rows not Done at the time: 6 Blocked-on-deps, 74 Fixing, 4 Implementing, 206 Verifying | the integrator, through the verification waves and fix cycles |
| `clean-tree` | FAIL | 10 paths differed from HEAD at the start: this package's own files, not committed (the status at the end equals the status at the start: the run changed nothing in the tree) | the integrator commits; the run that counts is the one on the commit to be tagged |
| `gate-8` | OPEN (owner) | no `Tests/Benchmarks/baseline.json`: the benchmarks ran and held the budgets of §5.7, nothing was compared | the owner: a pinned runner (`ZTD_BENCHMARK_RUNNER`) and its committed baselines (`Scripts/benchmarks.sh --update` there) |
| `change-requests` | OPEN (owner) | CR-001 to CR-034, all Proposed | the owner |
| `changelog` | OPEN (owner) | `## [0.1.0] - Unreleased`: the date goes in at the release | the owner, in the commit to be tagged |
| `plat3-ios-15` | OPEN (device) | iOS 15 and 16 cannot be simulated on this host (E-17); WP-338, WP-904a, WP-904b are Blocked-on-deps | a person with an iOS 15 device (Tier-low of OD-8), once their dependencies are Done |
| `device-WP-338`, `device-WP-708`, `device-WP-903a`, `device-WP-903b`, `device-WP-904a`, `device-WP-904b`, `device-WP-611b`, `device-WP-611c`, `device-WP-611d` | OPEN (device) | the runs on devices; WP-338, WP-903a, WP-903b, WP-904a, WP-904b Blocked-on-deps, WP-708, WP-611b, WP-611c, WP-611d Implementing | a person with the devices the owner names (OD-8), by the plan of the checklist's section 3 |

### Gate by gate

- **Gate 1** (2.5 min): ZTronDSP and ZTronDSPUI for the simulator and for a device, warnings as errors;
  the gallery application in Release; everything built for testing (Debug, coverage on). Passed.
- **Gate 2**: `lint-bans, parts 1 to 4`; `the dependency graph equals §4.2`. Passed.
- **Gate 3**: the compile fixtures; the order matrix (ORD-2). Passed.
- **Gate 4**: the API digest equals the build; every public symbol documented (VIS-2). Passed.
- **Gate 5** (70 min): **failed**, in `ZTronDSPUITests` only, on three of the four runtimes:

  | Runtime | `ZTronDSPUITests` | The other eight bundles | The gallery's hosted suites |
  |---|---|---|---|
  | iOS 17.5 (`ztdsp-ci-17-5`) | `✘ Test run with 278 tests in 19 suites failed after 618.820 seconds with 48 issues.` | green (1 840 tests) | `✔ … 24 tests in 8 suites passed` |
  | iOS 18.6 (`ztdsp-ci-18-6`) | `✘ Test run with 278 tests in 19 suites failed after 625.501 seconds with 11 issues.` | green | green |
  | iOS 26.5 (`ztdsp-ci-26-5`) | `✘ Test run with 278 tests in 19 suites failed after 290.931 seconds with 5 issues.` | green | green |
  | iOS 27.0 (`ztdsp-ci-27-0`) | `✔ Test run with 278 tests in 19 suites passed after 88.446 seconds.` | green | green |

  The eight other bundles on each runtime: 20, 55 (`passed … with 3 known issues`, as every day), 118,
  134, 339, 511, 431 and 232 tests, all passed. The allocation-audit tests in Release (7 filters) and the
  tests under the Thread Sanitizer passed. The failing tests are under "The UI tests that failed".
- **Gate 6**: on the result bundle of gate 5, which is 17.5's (deviation 5): `coverage-gate: aggregate
  99.45 % (25689 of 25831 lines), needs 97.50 %: ok`; per target CZTronDSP 99.74 %, ZTronDSPCore
  99.69 %, ZTronDSPDesign 98.70 %, ZTronDSPMetal 100.00 %, ZTronDSPAnalysis 99.83 %, ZTronDSPIO
  97.67 %, ZTronDSPUI 99.47 %; 17 lines marked `coverage:ignore` (0.07 %). Passed.
- **Gate 7**: the golden manifest, strict; `golden: 11 of 11 golden MATLAB scripts ran under GNU Octave
  as they draw`. Passed.
- **Gate 8**: **skipped** under `--strict`: the benchmarks ran and held the budgets of §5.7, but
  `there is no baseline at Tests/Benchmarks/baseline.json: nothing is compared`. Open for the owner.
- **Gate 9**: the external parity suite (EXT-4). Passed.
- **Beside the gates**: `run-all: every self-test passed (1237 checks in 17 suites)` (with `--slow`, no
  check skipped; 14 min); `function effects: all checks passed`; `perf annotations: all checks passed`;
  `spec-crosscheck` exit 0 with `DEFECTS (0)` and 9 notes; `docs: .build/docs/ZTronDSP.doccarchive:
  16037 pages; 7 links written as a path, each to a page of the archive`; `29 generators made their
  committed files again, 29 of them bit for bit`; the gallery's UI tests passed on all four runtimes
  (24 min; on 17.5 three of the eleven skip themselves, `SpatialEventGesture is iOS 18`, by design);
  `registers: 24 rows, 53 ALG packages, 52 notes (0 supplementary), 213 tests and 139 files checked:
  OK`; `lint-bans: clean (parts 3, 4; 609 files)`; `ledger: 293 rows, consistent with §12 and §11`.

### The UI tests that failed, run again alone

Each failing test was run again on its simulator, alone or with its suite (`ZTD_DERIVED=.build/ci
ZTD_DEVICE=ztdsp-ci-<v> ZTD_XCARGS="-enableCodeCoverage YES" Scripts/xc.sh test|test-only <filters>`),
one simulator booted at a time, each shut down after (logs `.build/logs/m9-release/rerun-ui-*.log`):

| Runtime and test (`ZTronDSPUITests/…`) | In gate 5 | Alone |
|---|---|---|
| 17.5 `HostedSourceFedTests/aViewInATabDetachesWhenItIsHiddenAndStartsAnEmptyPictureWhenItComesBack()` | failed: the hidden tab never detaches (`:211`, `eventually … detaches == 1`), and what follows from it (`:212`–`:226`) | failed, 9 issues |
| 17.5 `HostedSourceFedTests/aViewInATabHiddenAndShownWhileAttachingEndsWithOneAttachment()` | failed (`:244`, `:250`) | failed, 2 issues |
| 17.5 `HostedPinchTests/everyPathInstallsItsGesturesAndHearsAPinch(path:)`, all three arguments | failed: `PinchPath.current == .touches` (`:227`); on 17.5 the current path is `.magnify`, as impl-WP-902d.md §5 foresaw | failed, 3 issues |
| 17.5 `AxisTests/theAxesOfAComponentLineUpWithItsPicture()` | failed (`:391`: the frames of the axes beside the picture) | failed, 1 issue |
| 17.5 `SourceFedTests/aSpectrogramShowsAMockAFileAndAProcessedSignal()`, `aWaveform…()`, `aChromagram…()`, `aTempogram…()` | failed: writing the mock file, `ExtAudioFileCreateWithURL` → `Code=2003334207` ('wht?', unspecified) at `SourceSupport.swift:170` | **passed twice in a row** |
| 17.5 `HostedSourceFedTests/oneViewShowsAMockAFileAndAProcessedSignal(component:)`, all four arguments | failed: the attachment never came (`:109`–`:120`) | **passed twice in a row** |
| 18.6 the two tab tests above | failed, 11 issues | failed, 11 issues |
| 26.5 the two tab tests above | failed, 5 issues (`:211`–`:215`, `:244`) | failed, 5 issues |

The runs, with their final lines:
- 17.5, the four suites (`SourceFedTests`, `HostedSourceFedTests`, `HostedPinchTests`, `AxisTests`),
  14:18–14:29: `✘ Test run with 73 tests in 4 suites failed after 601.037 seconds with 15 issues.`
- 17.5, `SourceFedTests` and `HostedSourceFedTests/oneViewShowsAMockAFileAndAProcessedSignal(component:)`,
  14:30: `✔ Test run with 24 tests in 2 suites passed after 0.737 seconds.`
- 18.6, the two tab tests, 14:31–14:41: `✘ Test run with 2 tests in 1 suite failed after 600.885 seconds with 11 issues.`
- 26.5, the two tab tests, 14:41–14:45: `✘ Test run with 2 tests in 1 suite failed after 240.480 seconds with 5 issues.`

So the tab tests fail on every runtime before 27.0, and the pinch and axis tests on 17.5, alone as in
the full run; the four mock-file tests and the hosted mock-file test fail on 17.5 in the full bundle
only, and pass alone twice in a row. None is repaired here, and no expectation was touched: they are
the verification waves' (brief 67: "do not repair findings of the verification waves").

### The gates of the common rules, after every change

After every change of this package to the tree (the last, the ledger row, at 14:44), 14:46–15:08, one
after the other, each into a log of its own (`.build/logs/m9-release/gates60/NN-<gate>.log`):

| Gate | Exit | Final line |
|---|---|---|
| `Scripts/lint-bans.sh` | 0 | `lint-bans: clean (parts 1, 2, 3, 4; 609 files)` |
| `Scripts/check-dependency-graph.sh` | 0 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `Scripts/api-digest.sh --check` | 0 | `api-digest: 10 digests equal the built modules`, … `api-digest: ZTronDSPUI references public symbols only` (no public symbol added, changed or removed; no `--update`) |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 0 | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 0 | `order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | 0 | `golden: 199 files of 29 generators match the manifest`, `golden: 11 golden MATLAB scripts pass the static check (Scripts/lib/matlab_check.py, MAT-2)` |
| `Scripts/check-function-effects.sh` | 0 | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | 0 | `ledger: 293 rows, consistent with §12 and §11` |
| `Scripts/tests/run-all.sh` | 0 | `run-all: every self-test passed (1237 checks in 17 suites, 2 skipped: see above)` — the two skips are the checks that need `--slow`, which the release run ran (`--slow`, no skip); among the suites `ci` 189, `release-check` 169 and `process-files` 67 checks, 0 failed |
| `Scripts/external-parity.sh` | 0 | `external-parity: passed` |
| `Scripts/xc.sh test` (Debug, `ztdsp-27`) | 0 | `** TEST EXECUTE SUCCEEDED **`: nine bundles, 2 118 tests, all passed (`ZTronDSPUITests` 278, then 20, 55 `with 3 known issues`, 118, 134, 339, 511, 431, 232) |
| `ZTD_CONFIG=Release Scripts/xc.sh test` | 0 | `** TEST EXECUTE SUCCEEDED **`: the same 2 118 tests, all passed |

`run-all.sh` ran with `TMPDIR="$PWD/.build/tmp/m9-release"`, as the release run did. Every gate that
passed before this package passes after it.

## (4) Open, and what could not be done here

- **The acceptance of WP-906 is open**: today's run exited 1 without `--allow-open`. Its row is
  `Verifying` with the open items in its backlog by name. Every item that is not green is in the table
  of section 3 with its cause and who closes it; in short:
  - *For the UI packages' verification and fix cycles* (routed by the integrator): `gate-5` and
    `plat3-ios-17.5`, `plat3-ios-18`, `plat3-ios-26` — the two tab tests of `HostedSourceFedTests` on
    17.5, 18.6 and 26.5, and `HostedPinchTests.everyPathInstallsItsGesturesAndHearsAPinch(path:)` and
    `AxisTests.theAxesOfAComponentLineUpWithItsPicture()` on 17.5, all failing alone too; on 17.5 the
    four mock-file tests of `SourceFedTests` and `HostedSourceFedTests.oneViewShowsAMockAFileAndAProcessedSignal(component:)`,
    which fail in the full bundle and pass twice in a row alone. These are findings of the verification
    waves' kind, not of the scripts: not repaired here, and no expectation was touched. The packages'
    own runs were on 27.0 only (impl-WP-902d.md §5 foresaw the pinch test on 17.5).
  - *For the integrator*: `ledger-done` (290 of 293 rows not Done) and `clean-tree` (this package's own
    files are uncommitted; a run on the commit to be tagged is the one that counts).
  - *For the owner*: `gate-8` (a pinned runner and its baselines), `change-requests` (34 Proposed),
    `changelog` (the date, in the commit to be tagged).
  - *For a person with the devices of OD-8*: `plat3-ios-15` and the nine device runs.
- **Not run here**: the workflow's own strict dispatch (on GitHub's runners, by hand); the device runs;
  a run on a committed tree. `release-check.sh` was run once in full, before repairs A and B; after them
  its self-test and ci.sh's were run (169 and 189 checks, 0 failed), not the full run again: both repairs
  change what a line says, not what is run or how an item is classified.
- **Observations, not defects of this package**:
  - Gate 6 measures a local `--matrix` run on 17.5, the workflow on 27.0 (deviation 5).
  - On 17.5 three of the gallery's eleven UI tests skip themselves (`XCTSkipIf(systemVersion < 18,
    "SpatialEventGesture is iOS 18")`): by design; ci.sh's `--strict` does not see a test's own skip.
  - A test warning from `Tests/ZTronDSPCoreTests/BindingTests.swift:259` ("comparison with '.nan' using
    '>=' is always false"), in a test target, where warnings are no error: the comparison is the
    test's point.
- **Products and simulators**: the derived data of the run (`.build/ci`, `ci-strict`, `ci-gallery`,
  `ci-gallery-release`, `ci-tsan`, `docs`, `xcode-perf`, `xcode-effects`, about 6 GB, all made today by
  this run) and `.build/tmp/m9-release` are deleted; the result bundle of gate 5
  (`.build/ci-results/Debug.xcresult`, 17.5's, 24 MB) and the logs (`.build/logs/m9-release/`) are kept.
  The four simulators that ci.sh made today (`ztdsp-ci-17-5`, `-18-6`, `-26-5`, `-27-0`) are deleted;
  the next run of the matrix makes them again. `ztdsp-27` is booted, as it was found.

## (5) Change requests and decisions for the owner

No change request written: nothing in the specification stands against this package. The decisions
this package asks for:

1. **Gate 8**: name the pinned runner (`ZTD_BENCHMARK_RUNNER`) and commit its baselines, so that the
   benchmark regression check compares something (and WP-903a's device baselines).
2. **The 34 change requests**, CR-001 to CR-034, all Proposed: each decided, before a tag.
3. **The release**: once every line of the checklist is ticked, the date of the CHANGELOG entry, the
   commit, a green `Scripts/release-check.sh` on it without `--allow-open`, the tag
   `git tag -a 0.1.0 -m "ZTronDSP 0.1.0"`.
4. **For the integrator**: whether a local `ci.sh --matrix` should take gate 6's result bundle from
   the newest runtime, as the workflow does, instead of the first (a change to `ci.sh` and to the
   check of `test-ci.sh` that asserts the first).
