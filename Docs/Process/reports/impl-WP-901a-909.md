# WP-901a and WP-909 — implementer's report

| Field | Value |
|---|---|
| Packages | WP-901a (facade; the public API equals §4–§8 by the API digest), WP-909 (audit of the public API against API-6 and IMM-1…IMM-5) |
| Implementer | Implementer M9-api (agent), brief 62 with the common rules of brief 60 |
| Date | 2026-11-21, times Europe/Rome |
| Tree | The main tree. Everything below is unstaged or untracked on top of the staged state; nothing committed, nothing added to the index |
| Ledger | WP-901a and WP-909 `Verifying`, implementer `Implementer M9-api (agent)` |
| Audit | `Docs/Process/reports/WP-909-audit.md` |

## 1. Files

### Added

| File | What it is |
|---|---|
| `Docs/API/spec-map.tsv` | The map of the public API against the specification: a `#` header and 712 lines (901a.2) |
| `Docs/Process/changes/CR-031.md` | "Public API that differs from §4–§8", `Proposed`, 4 items (901a.4) |
| `Docs/Process/changes/CR-032.md` | "Public symbols beyond §4–§8", `Proposed`, 10 items and "Made internal by WP-901a" (901a.5) |
| `Docs/Process/reports/WP-909-audit.md` | The audit (909.5) |
| `Docs/Process/reports/impl-WP-901a-909.md` | This report |
| `Scripts/lib/spec_map.py` | Check 3: the map against the digests, the specification and the change requests (901a.3) |
| `Tests/CompileFixtures/invalid/FacadeDoesNotReachTheViews.swift` | Must not compile: the views through the facade (901a.1) |
| `Tests/CompileFixtures/invalid/FacadeDoesNotReachTheViewModifiers.swift` | Must not compile: the view modifiers of `ZTronDSPUI` through the facade (901a.1) |
| `Tests/CompileFixtures/invalid/FacadeDoesNotReachTheTestProduct.swift` | Must not compile: the test product and its C half through the facade (901a.1) |
| `Tests/Fixtures/Lint/part4/Sources/ZTronDSPCore/Values/Frequency.swift` | Seeded stored `var`s of public structs, reported and not (909.4) |
| `Tests/Fixtures/Lint/registered/Sources/ZTronDSPCore/Toolkit/Ramp.swift` | Registered stored `var`s, one of a nested type (909.4) |
| `Tests/ZTronDSPTests/FacadeTests.swift` | Five tests of what one `import ZTronDSP` reaches (901a.1) |

### Changed

| File | What changed |
|---|---|
| `Docs/API/ZTronDSPCore.txt` | 43 lines removed by `Scripts/api-digest.sh --update` (901a.5, listed there); none added |
| `Docs/Process/ledger.md` | Rows WP-901a and WP-909 |
| `Docs/Process/mutable-by-design.md` | The introduction says what a row is for under IMM-1 as well as IMM-2; no rows |
| `Docs/Process/unchecked-sendable.md` | 8 of the 22 rows rewritten to say what the code does (909.2) |
| `Scripts/api-digest.sh` | `--spec-map` and the options `--map`, `--spec`, `--changes`; check 3 inside `--check`; its usage text |
| `Scripts/lib/lint_bans.py` | Part 4 reports the stored `var`s of public structs (IMM-1, IMM-2); attributes are recorded among a declaration's modifiers; `qualified()` names a member of a nested type once |
| `Scripts/tests/test-api-digest.sh` | 32 checks of the map (68 in all) |
| `Scripts/tests/test-lint-bans.sh` | 9 checks of the stored `var`s (44 in all) |
| `Sources/ZTronDSPCore/Environment/DSPEnvironment.swift` | The 10 stored `var`s `private(set)`; the 12 keys behind derived values internal |
| `Sources/ZTronDSPCore/Feeds/ColumnStore.swift` | The 3 stored `var`s of `FeedCursor` `fileprivate(set)` |
| `Sources/ZTronDSPCore/Feeds/FeatureSink.swift` | `SinkDescription` internal |
| `Sources/ZTronDSPCore/Support/UnfairLock.swift` | The declaration comment (the type is internal), as its register row |
| `Tests/Fixtures/Lint/clean/Sources/ZTronDSPCore/Values/Frequency.swift` | The spellings of a stored `var` that part 4 accepts |
| `Tests/Fixtures/Lint/registered/Docs/Process/mutable-by-design.md` | Two rows for `Ramp.swift` |
| `Tests/ZTronDSPCoreTests/EnvironmentTests.swift` | `@testable import ZTronDSPCore`: it reads the keys made internal |

### Deleted

None.

The scripts of the reading are kept, git-ignored, in `.build/m9-api/` (each is named where it is used below);
the logs are in `.build/logs/m9-api/`.

## 2. Per item of the brief

### WP-901a.1 — The facade

**Now.** `Sources/ZTronDSP/ZTronDSP.swift` is unchanged: `@_exported import` of `ZTronDSPCore`,
`ZTronDSPDesign`, `ZTronDSPAnalysis`, `ZTronDSPIO` and `ZTronDSPMetal`, everything but the views and the test
product (§4.2). No re-export was added. `Docs/API/ZTronDSP.txt` holds the five `reexport` lines.

**Tests.** `Tests/ZTronDSPTests/FacadeTests.swift` imports `Testing` and `ZTronDSP` and nothing else (suite
`Facade`, struct `FacadeTests`; the target now has 10 tests):

- `oneImportReachesTheCore()`: `Pipeline<Samples, Samples>()` and `Frequency`, both of `ZTronDSPCore`;
- `oneImportReachesTheDesignTarget()`: a pipeline of `Gain(.decibels(-3))`, `Gain` of `ZTronDSPDesign`;
- `oneImportReachesTheAnalysisTarget()`: a pipeline of `STFT(frame: 1_024, hop: 256)`, of `ZTronDSPAnalysis`;
- `oneImportReachesTheInputTarget()`: `AudioSessionPolicy.playAndRecord.mixingWithOthers()` and
  `HardwareInputSource`, of `ZTronDSPIO`;
- `oneImportReachesTheMetalTarget()`: `CrossoverEntry.gainKernel` and `MetalContext`, of `ZTronDSPMetal`.

Each checks the module part of the type's full name (`String(reflecting:)`), so a symbol of the same name in
another module would not pass. The other half is three must-not-compile fixtures, each with its sentences in
the header as the harness reads them (`// expect:`):

| Fixture | Imports | Expected diagnostics |
|---|---|---|
| `FacadeDoesNotReachTheViews.swift` | `SwiftUI`, `ZTronDSP` | `cannot find 'SpectrogramView' in scope`; `cannot find 'FrequencyAxisView' in scope` |
| `FacadeDoesNotReachTheViewModifiers.swift` | `SwiftUI`, `ZTronDSP` | `value of type 'Text' has no member 'pinchScaling'` |
| `FacadeDoesNotReachTheTestProduct.swift` | `ZTronDSP` | `cannot find 'TestSignal' in scope`; `cannot find 'expectNoAllocations' in scope`; `cannot find 'ztdt_alloc_audit_begin' in scope` |

**What failed without it.**

- `@_exported import ZTronDSPMetal` removed once (15:35): `Scripts/xc.sh build` printed
  `Tests/ZTronDSPTests/FacadeTests.swift:45:21: error: cannot find 'CrossoverEntry' in scope`, the same at
  :46:33 and `cannot find 'MetalContext' in scope` at :47:33, then `** TEST BUILD FAILED **`, exit 65
  (`.build/logs/m9-api/regression-facade-undone-2.log`). Restored (the file's checksum equals the one saved
  before), rebuilt, and `Scripts/xc.sh test-only ZTronDSPTests/FacadeTests` printed
  `✔ Test run with 5 tests in 1 suite passed after 0.003 seconds.` A first attempt (15:32) built and proved
  nothing: the incremental build did not compile the test target again when only a re-export of the facade
  changed. For the second the test file was touched (its time, not its text).
- The fixtures were checked against controls: each fixture with the import it lacks added (`import
  ZTronDSPUI`; `import ZTronDSPTesting`, `import CZTronDSPTesting` and `import Testing` for the macro)
  compiles: `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --valid .build/m9-api/fixture-controls-2/valid`
  printed `compile-fixtures: 3 valid fixtures compile, 0 invalid fixtures fail with their sentences`, exit 0
  (run again after the final build, `fixture-controls-final.log`). Each fixture
  therefore fails for the one reason it names, and would compile, and fail the gate, if the facade
  re-exported that module.

### WP-901a.2 — The map

**Now.** `Docs/API/spec-map.tsv`: a header of `#` lines that explains the format, then one line per entry,
four columns separated by one tab (`module`, `symbol`, `where listed`, `note`), sorted by module, then by
symbol (byte order). A symbol is spelt as the digests spell it; overloads share one line. The third column is
exactly one place: a section heading (`§5.11.1`), a rule or a row the specification defines (`VC-4`,
`WP-204`, `F5`), a row of Appendix A (`App. A row 6`), or a change request (`CR-016`, `CR-018 item 11`).
For `CZTronDSP` the unit is the header function or type, as §5.11.1 and the rows of M2 name them.

712 lines: 521 top-level symbols, 120 members a module adds to a type of another module (`extension
Pipeline.gain(_:ramp:isActive:)`), the facade's 5 re-exports (`reexport ZTronDSPCore`), and 66 members of a
module's own types that §4–§8 write out. The first three kinds, 646 lines, are what check 3 requires.

The lines were generated from the digests by `.build/m9-api/make_map.py` with the places found by reading the
specification and the change requests (a member found by `.member(` with compatible labels; of a change
request, the item of its "Additions to the public surface" preferred), then read again by
`verify_places.py` and `verify_written.py`; the places that reading found wrong were corrected (for
instance `CrossoverTable.size(of:)` §8.2 → CR-032, `DSP.interpolate` §6.3.6 → §6.12, `Framer` → §6.4.1,
`Window` → §6.4.2, `AudioBuffer` → CR-032, `DSP.inversionReport` → §6.13).

**Lines per module and per kind of place** (`section` is a heading of the specification, `rule or row` an id
it defines; the CR columns are the change requests named):

| Module | Lines | section | rule or row | App. A row | CR-003 | CR-006 | CR-015 | CR-016 | CR-017 | CR-018 | CR-019 | CR-021 | CR-023 | CR-025 | CR-027 | CR-032 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `CZTronDSP` | 142 | 9 | 118 | — | — | 1 | — | — | 12 | — | — | — | — | 1 | — | 1 |
| `ZTronDSPCore` | 208 | 151 | 21 | — | 1 | — | 26 | — | — | — | — | — | — | 2 | — | 7 |
| `ZTronDSPDesign` | 116 | 39 | 32 | 5 | — | — | — | — | — | 36 | — | — | — | — | — | 4 |
| `ZTronDSPMetal` | 28 | 4 | 3 | — | — | — | — | 19 | — | — | — | — | — | — | — | 2 |
| `ZTronDSPAnalysis` | 129 | 46 | 43 | — | — | — | — | — | — | — | 18 | — | 20 | — | — | 2 |
| `ZTronDSPIO` | 18 | 18 | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| `ZTronDSPUI` | 29 | 21 | 4 | — | — | — | — | — | — | — | — | 3 | — | — | 1 | — |
| `ZTronDSP` | 5 | 5 | — | — | — | — | — | — | — | — | — | — | — | — | — | — |
| `ZTronDSPTesting` | 28 | 1 | 26 | — | — | — | — | — | — | — | — | — | 1 | — | — | — |
| `CZTronDSPTesting` | 9 | — | 9 | — | — | — | — | — | — | — | — | — | — | — | — | — |
| **all** | **712** | **294** | **256** | **5** | **1** | **1** | **26** | **19** | **12** | **36** | **18** | **3** | **21** | **3** | **1** | **16** |

555 lines are listed at the specification (294 at a section, 256 at a rule or row, 5 at a row of Appendix A)
and 157 at 12 change requests, as `Scripts/api-digest.sh --spec-map` counts them.

**Tests.** Check 3 (next item) over the committed map: `api-digest: Docs/API/spec-map.tsv lists every public
symbol of 10 digests in 712 lines (555 at the specification, 157 at 12 change requests)`.

### WP-901a.3 — The check

**Now.** `Scripts/lib/spec_map.py`, called by `Scripts/api-digest.sh` two ways: `--spec-map` checks the
committed digests alone (no build), and `--check` runs it as check 3 on the digests of the build; `--map
FILE`, `--spec FILE` and `--changes DIR` name another map, specification or folder of change requests (the
self-test uses them), with `--digests DIR` as before. Check 3 comes after check 1 (the digests equal the built modules) and check 2 (initialisers end in `isActive:`). A
folder of digests that holds no `spec-map.tsv` skips check 3 and says so (the older fixtures of the
self-test have none). It fails, each with its own sentence, on:

- a public symbol without a line: `api-digest: <module> <symbol> is public and the map does not list it:`
  followed by its digest line, and the count `N public symbol(s) without a line in Docs/API/spec-map.tsv`;
  a member added to another module's type is named `extension T.member`, a re-export `reexport M`;
- a stale line: `<module> <symbol> is in no digest (a stale line)`, or `names a module that has no digest`;
- a dead place: a section the specification does not have, a rule or row it does not define, a change
  request that is not in `Docs/Process/changes/`, an item the change request does not have, a row past the
  end of Appendix A, words that are no place at all (`"internal detail", which is not a place`);
- the format: a line without a place, an entry listed twice, a line out of order, a line that does not have
  four columns.

Sections are the headings of `Docs/Specification/ZTronDSP-SPEC.md`; a rule or row id is defined where the
specification writes it in bold or as the first cell of a table row (unhyphenated ids such as `F5` included).

On the way: my first version read the `--map` option into a variable `map`, which the script's existing loop
`for map in "$maps"/C*.modulemap` overwrote; the existing self-test caught it (below), and the option is now
held in `map_option`.

**Tests.** `Scripts/tests/test-api-digest.sh`, 32 new checks (68 in all), in the file's style: a clean map
passes and is counted; a seeded unlisted symbol (with its name, its digest line and the count), an unlisted
foreign member and an unlisted re-export; a member of the module's own type needs no line; a seeded stale
line and a module without a digest; seeded dead places of six kinds; four breaks of the format; a map check
without its specification is a usage error; a digests folder without a map skips check 3 and says so;
`--check` runs check 3 on the build; the package's own map passes for all ten digests.

**What failed without it.**

- Check 3 not run: `68 checks, 28 failed`, among them `a public symbol the map does not list fails (exit 0,
  expected 1)`, `a stale line fails (exit 0, expected 1)`, `a dead clause fails (exit 0, expected 1)`,
  `a line that breaks the format fails (exit 0, expected 1)` and `--check runs check 3 on the digests of the
  build (exit 0, expected 1)` (`.build/logs/m9-api/regression-check3-undone.log`).
- `map_option` undone: `68 checks, 1 failed`: `the package's committed digests equal the last build (exit 1,
  expected 0)`, check 3 having read `CZTronDSPTesting.modulemap` as the map (`a line has four columns
  separated by tabs …; this one has 1`) (`regression-map-option-undone.log`). The existing self-test found it.

### WP-901a.4 — The other direction, by reading

**Method.** `.build/m9-api/spec_tokens.py` takes every code name of §4–§8 and Appendix A and looks for it in
the digests; `spec_calls.py` compares the labels of every call the text writes with the digests' signatures;
`spec_decls.py` compares every declaration the text writes out; `comparison.py` makes the table. Then each
miss was read in its section.

**Result.** Names: 817 present, 1 differs, 7 absent (five names; `SourceAdapter` and `mpsGraph` count in two
sections each). Declarations written out: 90 present, 1 differs. 131 names of the text are not package API
(49 of the platform, the language or SwiftUI; 24 of a reference library, Appendix A and §5.3; 24 modules,
products, folders or files; 24 that the specification says the package does not have; 10 generic
parameters, associated types or words of the text). No call label differs from its signature, except where
the text elides arguments.

| Section | Present | Differs | Absent | Declarations written out (present / differs) |
|---|---|---|---|---|
| §4.1 | 8 | 0 | 0 | — |
| §4.2 | 9 | 0 | 0 | — |
| §4.3 | 2 | 0 | 0 | — |
| §4.4 | 21 | 0 | `SourceAdapter` (internal, as §4.4 says ("Internally a `SourceAdapter` …")) | 20 / 0 |
| §4.5 | 33 | 0 | `SourceAdapter` (internal, as §4.4 says ("Internally a `SourceAdapter` …")) | 29 / 0 |
| §4.6 | 18 | 0 | `MicrophoneAuthorizing` (internal to ZTronDSPIO: CR-031 item 2) | 17 / 0 |
| §5.1 | 34 | 0 | 0 | — |
| §5.2 | 78 | 0 | 0 | — |
| §5.3 | 58 | 0 | `incrementalSortedLanes` (absent (optional, WP-533): CR-031 item 4); `mpsGraph` (absent (optional, WP-613): CR-031 item 4) | — |
| §5.4 | 26 | 0 | 0 | 6 / 0 |
| §5.5.2 | 1 | 0 | 0 | — |
| §5.5.3 | 5 | 0 | 0 | — |
| §5.5.4 | 7 | 0 | 0 | — |
| §5.6 | 3 | 0 | 0 | — |
| §5.7 | 1 | 0 | 0 | — |
| §5.8.1 | 20 | 0 | 0 | — |
| §5.8.2 | 33 | 0 | 0 | — |
| §5.8.3 | 1 | 0 | 0 | — |
| §5.8.4 | 2 | 0 | 0 | — |
| §5.9 | 28 | 0 | 0 | — |
| §5.10 | 14 | 0 | 0 | — |
| §5.11.1 | 38 | `PipelineStage.lower(_:)` is `StageValue.lower(_:)`, which `PipelineStage` refines: CR-031 item 1 | 0 | 18 / 1 |
| §5.11.3 | 3 | 0 | 0 | — |
| §5.11.4 | 11 | 0 | 0 | — |
| §6.1 | 13 | 0 | 0 | — |
| §6.2 | 4 | 0 | 0 | — |
| §6.3.1 | 6 | 0 | 0 | — |
| §6.3.2 | 9 | 0 | 0 | — |
| §6.3.3 | 13 | 0 | 0 | — |
| §6.3.4 | 8 | 0 | 0 | — |
| §6.3.5 | 5 | 0 | 0 | — |
| §6.3.6 | 8 | 0 | 0 | — |
| §6.3.7 | 27 | 0 | 0 | — |
| §6.3.8 | 4 | 0 | 0 | — |
| §6.3.9 | 5 | 0 | 0 | — |
| §6.4.1 | 12 | 0 | 0 | — |
| §6.4.2 | 23 | 0 | 0 | — |
| §6.6 | 10 | 0 | 0 | — |
| §6.7 | 11 | 0 | 0 | — |
| §6.8 | 7 | 0 | 0 | — |
| §6.9 | 7 | 0 | 0 | — |
| §6.10 | 7 | 0 | 0 | — |
| §6.11 | 20 | 0 | 0 | — |
| §6.12 | 7 | 0 | 0 | — |
| §6.13 | 26 | 0 | 0 | — |
| §6.14 | 13 | 0 | 0 | — |
| §7.1 | 10 | 0 | `mpsGraph` (absent (optional, WP-613): CR-031 item 4) | — |
| §7.4 | 10 | 0 | 0 | — |
| §8.1 | 48 | 0 | 0 | — |
| §8.2 | 2 | 0 | 0 | — |
| §8.3 | 2 | 0 | `FrameScheduler` (internal to ZTronDSPUI: CR-031 item 3) | — |
| §8.4 | 1 | 0 | 0 | — |
| §8.6 | 1 | 0 | 0 | — |
| §8.7 | 9 | 0 | 0 | — |
| §8.8 | 7 | 0 | 0 | — |
| §8.9 | 1 | 0 | 0 | — |
| App. A | 27 | 0 | 0 | — |

**What became of each.** (a) Omissions small enough to implement here: none. (b) Already decided:
`SourceAdapter` is internal, as §4.4 says ("Internally a `SourceAdapter` …"). (c) New, in CR-031: item 1,
`PipelineStage` split into `StageValue` (with `lower(_:)`) and `PipelineStage: StageValue`, with proposed
wording of §5.11.1; item 2, `MicrophoneAuthorizing` internal (§4.6); item 3, `FrameScheduler` internal
(§8.3); item 4, `FFTBackend.mpsGraph` and `MedianStrategy.incrementalSortedLanes` absent, optional values that
arrive with WP-613 and WP-533, both `Awaiting-trigger`.

**Tests.** None: nothing was implemented. The table is the record of what was compared.

### WP-901a.5 — Symbols the specification does not name

**Method.** `.build/m9-api/needs.py` lists, for each public symbol without a place, the public declarations of
the package that name it (from the symbol graphs); `usage.py` lists its uses in the other targets,
`ExternalParity/`, `Examples/`, the tests, the valid compile fixtures and the gallery. A use by the tests of
the symbol's own module does not count (they may `@testable import`); a use by the C test target does.

**Made internal** (13 symbols; nothing outside `ZTronDSPCore` names them, no `@inlinable` body reads them):

- the twelve keys behind the derived values of the environment: `SampleRateKey`, `NyquistFrequencyKey`,
  `ChannelCountKey`, `BlockSizeKey`, `FrameSizeKey`, `HopSizeKey`, `FrequencyResolutionKey`,
  `FeatureRateKey`, `FrequencyAxisKey`, `LatencyKey`, `IsRealTimeKey`, `SourceKindKey`. An app reads these
  values as properties of `DSPEnvironment` (§5.4). The three keys it can set (`ImplementationKey`,
  `BiquadPrecisionKey`, `ResultRateKey`; ENV-3) stay public: `DSPEnvironment.SettableKeys` names them;
- `SinkDescription`, which CR-015 item 11 lists among the additions: no public declaration names it.

**Removed from `Docs/API/ZTronDSPCore.txt`** by `Scripts/api-digest.sh --update` (43 lines, none added, no
other digest changed): for each of the twelve keys `K`, the three lines `swift.enum K`, `conformance K :
DSPEnvironmentKey` and `swift.type.property K.defaultValue` (36 lines); for `SinkDescription`,
`swift.struct SinkDescription`, `swift.func.op SinkDescription.==(_:_:)`, `swift.method
SinkDescription.hash(into:)` and the conformances to `Swift.Equatable`, `Swift.Hashable`, `Swift.Sendable`
and `Swift.SendableMetatype` (7 lines).

**Kept public**, each with a place: at the change request that introduced it (CR-003 1 line, CR-006 1,
CR-015 26, CR-016 19, CR-017 12, CR-018 36, CR-019 18, CR-021 3, CR-023 21, CR-025 3, CR-027 1), or, with
none, at CR-032 (16 lines: items 1 to 4 and 8, each with its reason). Nothing that another target, the
external package or the gallery uses was removed or renamed; `package` hooks were not touched.

**Tests.** `Tests/ZTronDSPCoreTests/EnvironmentTests.swift` reads the keys through `@testable import`; every
test target in Debug and Release; `Scripts/external-parity.sh` (section 3).

**What failed without it.** Check 3 on the symbol graphs of the build before the change (`Scripts/api-digest.sh
--check --graphs .build/m9-api/graphs`): `api-digest: 13 public symbols without a line in
Docs/API/spec-map.tsv: no public symbol goes unlisted (WP-901a)`, naming `BlockSizeKey`, `ChannelCountKey`,
`FeatureRateKey`, `FrameSizeKey`, `FrequencyAxisKey`, `FrequencyResolutionKey`, `HopSizeKey`,
`IsRealTimeKey`, `LatencyKey`, `NyquistFrequencyKey`, `SampleRateKey`, `SinkDescription` and `SourceKindKey`
(`regression-internal-keys.log`).

### WP-909.1 — Parameter types (API-6)

**Method.** `.build/m9-api/param_types.py` reads the symbol graphs as `Scripts/lib/api_digest.py` does and
lists every struct, class and enum of the package that is the type of a parameter of a public initialiser,
function, method, operator, subscript, enum case or modifier; `param_prefix.py` finds those that appear only
as the namespace of a nested parameter type; `classify.py` holds the classes and checks that they name every
listed type and no other.

| Class | Module | Types |
|---|---|---|
| domain value | `ZTronDSPAnalysis` | `Autocorrelation`, `CepstrumKind`, `ConstantQGeometry`, `ConstantQScale`, `ConvolutionMode`, `CorrelationNormalization`, `Decibels`, `FrameAlignment`, `FrequencyRange`, `HarmonicPercussive`, `HarmonicPercussiveComponent`, `InverseDecibels`, `InversionContext`, `LevelKind`, `Lifter.Shape`, `LinearValueKind`, `Magnitude`, `MeasuredSpectrum`, `MedianAxis`, `MelScale`, `OnsetStrength`, `Power`, `SpectralCentroid`, `WindowNormalization` |
| domain value | `ZTronDSPCore` | `Amplification`, `AnalysisStep`, `AudioBlock`, `Complex`, `ComplexValues`, `CrossoverTable`, `CustomKernel`, `CustomProcessor`, `DSPEnvironment`, `DSPEnvironment.SettableKeys`, `DSPError`, `DecibelValues`, `DomainRule`, `DomainTag`, `DomainTag.Axis`, `DomainTag.FrameKind`, `DomainTag.Values`, `DynamicPipeline`, `Emit`, `Envelope`, `FeedAxis`, `FeedCursor`, `FrameFormat`, `FrameView`, `Frequency`, `GeneratorSource.Signal`, `KernelSpec`, `LinearFrequency`, `MagnitudeValues`, `Pacing`, `ParameterVector`, `Pipeline`, `PipelineBuilder`, `Primitive`, `RollOff`, `RollOffRounding`, `Samples`, `Scalar`, `ScalarFrame`, `ScopeChange`, `ScriptedSource.Step`, `SequenceChain`, `SignalFormat`, `SourceEvent`, `Spectrum`, `StageDescription`, `StagePath`, `StagePath.Component`, `Window`, `Window.HannScaling`, `ZeroPadding` |
| domain value | `ZTronDSPDesign` | `AlphaBeta.Output`, `Bandwidth`, `BesselNormalization`, `FIRSystem`, `FIRSystemBuilder`, `FIRSystemContent`, `FilterResponse`, `FrequencyTransformation`, `IIRDesign.Domain`, `IIRSystem`, `IIRSystemBuilder`, `IIRSystemContent`, `MagnitudeScale`, `Polynomial`, `SavitzkyGolayEdge`, `SecondOrderSections.Section`, `ShelfSlope`, `SystemDomain` |
| domain value | `ZTronDSPIO` | `AudioInput`, `AudioInput.Kind` |
| domain value | `ZTronDSPMetal` | `CrossoverEntry`, `DisplayColor`, `MetalMedianFilter.Axis`, `PixelImage`, `RowInterpolation` |
| domain value | `ZTronDSPTesting` | `MedianOracle.Axis`, `Tolerance` |
| domain value | `ZTronDSPUI` | `ChromagramView`, `DSPAxis`, `FrequencyAxisView`, `HeatmapView`, `PitchClassAxisView`, `SpectrogramView`, `TempoAxisView`, `TempogramView`, `TimeAxisView`, `WaveformView` |
| strategy | `ZTronDSPCore` | `AnyStrategy`, `BiquadPrecision`, `ChannelPolicy`, `Implementation` |
| strategy | `ZTronDSPDesign` | `ConvolutionStrategy` |
| strategy | `ZTronDSPIO` | `AudioSessionPolicy` |
| strategy | `ZTronDSPMetal` | `CalibrationCandidate` |
| report | `ZTronDSPAnalysis` | `ConvolutionCrossover`, `InversionCondition`, `InversionRoundTrip` |
| report | `ZTronDSPCore` | `FeedSnapshot.Content`, `MATLABScript` |
| report | `ZTronDSPMetal` | `CalibrationCurve`, `CrossoverMeasurement` |
| report | `ZTronDSPTesting` | `BenchmarkReport`, `BenchmarkResult` |
| identity | `ZTronDSPCore` | `BackgroundWork.Checkpoint`, `BoundResult`, `BoundSwitch`, `DSPEngine`, `FrameWriter`, `HeatmapFeed`, `LoweringContext`, `PipelineSession`, `RingWriter`, `ScalarBindingTarget`, `VectorBindingTarget`, `WaveformFeed` |
| identity | `ZTronDSPMetal` | `MetalContext`, `RenderProbe` |
| only the namespace of a nested parameter type | `ZTronDSPAnalysis` | `Lifter` (`Lifter.Shape`) |
| only the namespace of a nested parameter type | `ZTronDSPCore` | `BackgroundWork` (`BackgroundWork.Checkpoint`), `FeedSnapshot` (`FeedSnapshot.Content`), `GeneratorSource` (`GeneratorSource.Signal`), `ScriptedSource` (`ScriptedSource.Step`) |
| only the namespace of a nested parameter type | `ZTronDSPDesign` | `AlphaBeta` (`AlphaBeta.Output`), `IIRDesign` (`IIRDesign.Domain`), `SecondOrderSections` (`SecondOrderSections.Section`) |
| only the namespace of a nested parameter type | `ZTronDSPMetal` | `MetalMedianFilter` (`MetalMedianFilter.Axis`) |
| only the namespace of a nested parameter type | `ZTronDSPTesting` | `MedianOracle` (`MedianOracle.Axis`) |

Totals: 152 types; 142 in their own right (domain value 112, strategy 7, report 9, identity 14,
**configuration-shaped 0**); 10 only as a namespace. The cases that needed a decision (`ConstantQGeometry`,
`DSPEnvironment`, `DSPEnvironment.SettableKeys`, `InversionContext`, `AudioSessionPolicy`, `ChannelPolicy`,
`CalibrationCandidate`, `LoweringContext`, `FrameWriter`, `BackgroundWork.Checkpoint`, the three result
builders, the ten views) are argued one by one in the audit, section 1.

**Violations: none.** Nothing was reshaped and no item went to CR-031. No test: nothing changed.

### WP-909.2 — IMM-1, IMM-2 and the registers

**Stored properties.** No public struct has a public stored `var` (whatever its setter) and no reference type
has a public setter: no digest line reads `{ get set }` or `{ set }`, and the lint's IMM-2 rules find nothing.
`.build/m9-api/stored_vars.py` found 19 stored `var`s that their module could set, in five public structs:

| Type | Properties | What became of them |
|---|---|---|
| `DSPEnvironment` | `storedSampleRate`, `storedChannelCount`, `storedBlockSize`, `storedFrameSize`, `storedHopSize`, `storedAxis`, `storedLatency`, `storedIsRealTime`, `storedSourceKind`, `overrides` | `private(set)`: each is set only on a fresh copy by the type's own positional changes, which return it as a new environment (IMM-5) |
| `FeedCursor` | `layout`, `epoch`, `column` | `fileprivate(set)`: moved only by the column store of the same file, as a `read` takes columns |
| `AudioBlock` | `frames` | Unchanged, `@usableFromInline`: set by the `@inlinable` `setFrameCount(_:)` and `copy(from:)` of a work buffer (IMM-3) |
| `Ramp` | `current`, `goal`, `increment`, `remaining` | Unchanged, `@usableFromInline`: the state of a toolkit primitive (§5.11.4) inside a kernel or node (IMM-3), moved by its `@inlinable` members |
| `SeededGenerator` | `state` | Unchanged, `@usableFromInline`: the state of a `RandomNumberGenerator` of the test product, advanced by the `@inlinable` `mutating next()` |

The brief reads IMM-1 as "every public struct's stored properties are `let`", flagging an internal setter.
The specification's IMM-1 names the kinds that are immutable values (stages, pipelines, designs, systems,
windows, reports, tables), IMM-3 names the places of mutable state, and VIS-1 prescribes for "Toolkit
primitives and frame accessors: `public`, `@inlinable`; their internals `@usableFromInline`". I did what the
specification says: the 13 setters that nothing outside their type or file used became private to it; the six
`@usableFromInline` internals stay, and the lint accepts that attribute (909.4).

**The registers.**

| Register | Before | Now |
|---|---|---|
| `mutable-by-design.md` (IMM-1, IMM-2) | Empty | Empty and true. Its introduction now also says what a row would be for under IMM-1: a stored `var` of a public struct that its module can set, other than a private, file-private or `@usableFromInline` one |
| `open-declarations.md` (VIS-1) | Empty | Empty and true: no `open` declaration in `Sources/` |
| `approvals.md` (§9.5, APR-1, APR-2) | Empty | Empty and true: no `AnyView`, `import Combine`, `ObservableObject`, `@Published`, `AnyPublisher` or `PassthroughSubject` in `Sources/`, `Examples/` or `ExternalParity/` |
| `unchecked-sendable.md` (§9.2) | 22 rows | 22 rows, one per `@unchecked Sendable` type of `Sources/`, each naming a type at its file; 14 as written, 8 rewritten |

A first draft entered the six `@usableFromInline` properties as rows of `mutable-by-design.md`. The process
self-test (WP-008) failed on them: `Scripts/tests/run-all.sh` printed `run-all: FAILED: process-files (1 of
756 checks failed)`, the check being that the register "exists and is empty (6 rows)"; the register "must
stay empty unless a change request says otherwise". The rows were taken out and the lint taught VIS-1's
spelling; the test was not touched.

**`unchecked-sendable.md`, type by type** (the evidence, with file and line, is in the audit, section 3.4):

| Type | Verdict | What the code does that the old row did not say (evidence) |
|---|---|---|
| `UnfairLock` | rewritten | Taken on the thread that runs a hub in `ScriptedSource.render` (`current.set(format)`, `ScriptedSource.swift:140`, called from `SourceAdapter.next(into:)`, `SourceAdapter.swift:185`), and on the task that listens to a source's events (`SourceEventRouter`, `ControlContext.swift:111`); the old row said "never on the analysis or I/O thread". Its declaration comment (internal) said "control context and in background work only": corrected to the same text (`UnfairLock.swift:3`–`6`). |
| `Locked` | rewritten | As `UnfairLock`: its old row said "never the analysis or I/O thread". |
| `Handoff` | as written | `Handoff.swift:12`–`16`: control-side and consumer-side members as the row says. |
| `RunnerThread` | rewritten | The lock (`guardLock`, `RunnerThread.swift:72`) is taken by `start` (:111), `stop` (:128) and `isRunning` (:139) only; `wake` (:143) unparks without it, and the schedule is a `Handoff` (:62) published without it. The old row put `wake` and the schedule "behind a lock". `ownsThread` and `appliedInterval` (:75, :77) are touched by the running thread alone (:164, :184, :207). |
| `HubRunner` | as written | `HubRunner.swift:60`–`77`. |
| `SessionRunner` | rewritten | `sampleRate` and `needsOrigin` (`SessionRunner.swift:45`, `:47`) are set by the control context (`EngineCore.swift:102` in `register`, `:608`–`609` in `coldStart`, `:1034`–`1035` in `recompile`), each while the runner is off its thread, and the running thread clears `needsOrigin` (`SessionRunner.swift:160`); the old row did not name them. |
| `SessionCore` | rewritten | `events` (`SessionCore.swift:127`) is for any thread too, as the declaration says (:53): it registers a listener behind `listeners` (:63) and reads `isOver` (:64). The old row named `state` and `environment` only. |
| `SourceHub` | as written | `SourceHub.swift:10`. |
| `EngineCore` | as written | `EngineCore.swift:14`–`31`. |
| `Route` | rewritten | `unroute(_:)` reads the weak reference after the registry's lock is released (`ControlContext.swift:121`–`122`); the old row said it is "read under the registry's lock". It is written once, in `init`, and read inside the lock in `route(_:to:)` (:101); the handler is read on the listening task (:111). |
| `RunLoopHooks` | as written | `BindingPump.swift:288`–`292`. |
| `ResultSlot` | as written | `ResultSlot.swift:1`–`16`. |
| `ColumnStore` | as written | `ColumnStore.swift:138`–`159`. |
| `FeatureStream` | as written | `FeatureStream.swift:21`–`89`. |
| `SampleRing` | as written | `RingWriter.swift:1`–`8`. |
| `SourceAdapter` | rewritten | `close()` (`SourceAdapter.swift:132`) is called while the hub may run (`EngineCore.swift:486`, a reader that waits for room is let go before the source is stopped) and is one atomic store (`ztd_ring.c:275`–`276`); `endAfterDraining()` (:118), not named by the old row, is an atomic store called at any time (`EngineCore.swift:1081`). The old row put `close` with `rewind` and `discardPending` "while the hub is off its thread". |
| `GeneratorSource` | as written | `GeneratorSource.swift:12`–`99`. |
| `BufferSource` | as written | `BufferSource.swift:6`–`18`. |
| `ScriptedSource` | rewritten | `render` takes the format's lock when the script changes the format (`ScriptedSource.swift:140`); the old row said the lock is there "because the control context reads it" and named only the events as the exception to RT-2. |
| `ProcessedSource` | as written | `ProcessedSource.swift:15`–`22`. |
| `ThreadAllocationAudit` | as written | `AllocationAudit.swift:121`–`135`. |
| `Guarded` | as written | `Guarded.swift:3`–`16`. |

None of the corrections is a defect of the code: each type does what its declaration allows, and the old rows
said less than the code does, or something else. `UnfairLock`'s internal declaration comment said the same as
its old row and was corrected with it.

**Tests and what failed without them.**

- One property of each changed type made settable by the module again (`DSPEnvironment.storedSampleRate`,
  `FeedCursor.layout`; 15:42): `Scripts/lint-bans.sh --part 4` exited 1 and printed
  (`regression-imm1-undone-final.log`; restored, checksums equal):

  ```
  Sources/ZTronDSPCore/Environment/DSPEnvironment.swift:31: [IMM-1] `DSPEnvironment.storedSampleRate` is a stored `var` of a public value type that the module can set: it is `let`, `private(set)` or `fileprivate(set)`, `@usableFromInline` when `@inlinable` code sets it (VIS-1), or it has an entry in Docs/Process/mutable-by-design.md
  Sources/ZTronDSPCore/Feeds/ColumnStore.swift:9: [IMM-1] `FeedCursor.layout` is a stored `var` of a public value type that the module can set: it is `let`, `private(set)` or `fileprivate(set)`, `@usableFromInline` when `@inlinable` code sets it (VIS-1), or it has an entry in Docs/Process/mutable-by-design.md
  lint-bans: 2 violations (part 4; 605 files)
  ```
- The registers' rows are matched to the code both ways by lint part 4 (a row that matches nothing, a type or
  a setter without a row); the reasoning of each `unchecked-sendable.md` row was checked by reading.

### WP-909.3 — IMM-4 and IMM-5, by reading

**IMM-4 holds.** The analysis thread changes a plan only in `SessionRunner.boundary()`
(`SessionRunner.swift:177`, from `run(_:)` :155): it takes a plan from the hand-off, drains the value and
switch queues and accepts the new plan (`accept(_:)` :192, `install(_:outputChanged:)` :246); `apply(_:_:)`
(:296) hands `ZTD_COMMAND_SET_ACTIVE` to `PlanRunner.setSwitch(_:_:)` (`PlanRunner.swift:131`) and every other
command to `PlanRunner.applyValues(_:)` (:192, into `ztd_plan_command`). Commands are sent by
`EngineCore.sendValues(of:replacing:to:)` (`EngineCore.swift:829`) and `send(_:to:of:)` (:846), and by the
binding pump (`BindingPump.sample()`, `BindingPump.swift:196`). `EngineCore.update(_:to:)` (:641) re-captures
bindings for an equal pipeline (`ExecutionPlan.adoptBindings`, `ExecutionPlan.swift:669`), sends values when
the structure is the same and each value has a kernel (`canTakeValues(of:)` :683), and otherwise compiles a
new plan (`exchange(_:_:_:_:)`, `EngineCore.swift:702`, published at :754; `recompile(_:)` :1019 likewise).
The one other write, `PlanRunner.resetAll()` (`PlanRunner.swift:235`), runs from `EngineCore.coldStart(_:)`
(:605) while the session is off its thread.

**IMM-5 holds.** `DSPEnvironment` is a struct whose every change returns a copy (`setting(_:to:)` :122,
:138; `withFormat(_:)` :145 … `applyingOverrides(of:)` :233; none `mutating`), and its stored properties now
have private setters. `Pipeline.environment(_:_:)` (`Structure.swift:122`) returns a new pipeline and
`Group.environment(_:_:)` (:93) a new group. `PlanCompiler.lower(_:environment:blockSize:)`
(`PlanCompiler.swift:57`) threads a `Cursor` value (:10): a reader gets the environment where it stands
(:163), a tap walks a copy (`var branch = cursor`, :166), a group lays its overrides over a copy and restores
the outer ones (:172–184), and a stage reads it through `LoweringContext.environment`, which has no setter
(`LoweringContext.swift:35`). The full citations are in the audit, sections 4 and 5.

**Tests.** None: reading, and nothing changed.

### WP-909.4 — What is now mechanised

**Now.** `Scripts/lib/lint_bans.py`, part 4, reports two new findings against
`Docs/Process/mutable-by-design.md`: under IMM-2 a public stored `var` whose setter is restricted (the setter
rule did not see it), and under IMM-1 a stored `var`, internal or package, with a setter the module can reach:

```
[IMM-2] `T.p` is a public stored `var` of a value type: it is `let`, or it has an entry in Docs/Process/mutable-by-design.md
[IMM-1] `T.p` is a stored `var` of a public value type that the module can set: it is `let`, `private(set)` or `fileprivate(set)`, `@usableFromInline` when `@inlinable` code sets it (VIS-1), or it has an entry in Docs/Process/mutable-by-design.md
```

Stored means no accessor block, or one of `willSet`/`didSet` only. Static and computed properties, and the
properties of internal types and of classes, are not reported; a type declared in a public extension is
public. Attributes are now recorded among a declaration's modifiers, which is how `@usableFromInline` is seen.
`qualified()` named a member of a nested type twice (`Ramp.Ramp.Phase.radians`): it now takes the innermost
type's name, which is already qualified.

**Tests.** `Tests/Fixtures/Lint/part4/…/Values/Frequency.swift`: 11 reported lines (3 IMM-2, 8 IMM-1), each
marked `// !! IMM-…`, which the self-test compares with the lint's output line by line; every other
declaration of the file is a shape that must not be reported (private and file-private setters, two
`@usableFromInline` ones, `let`, static, computed with and without a setter, an internal type, a class, an
internal struct). The clean tree's `Frequency.swift` holds the accepted spellings; the registered tree's
`Ramp.swift` two registered properties, one of a nested type. `Scripts/tests/test-lint-bans.sh` has nine new
checks: part 4 fails on the seeded tree; the IMM-2 message; the IMM-1 message; a type of a public
extension; and the absence of `Frequency.counted` (private setter), `Frequency.inlined`
(`@usableFromInline`), `Frequency.both` (computed with a setter), `Store.history` (a class) and
`Internal.value` (an internal struct).

**What failed without it** (each undone once on the final code, 15:42, restored, checksum equal):

- The stored-`var` rule off: `44 checks, 5 failed`: `registered exceptions are accepted (exit 1)`, `part 4
  reports every seeded configuration name, setter, open, Sendable and shader violation`, and the three
  message checks (`… a public one, whatever its setter (IMM-2)`, `… one the module can set (IMM-1)`, `… one of
  a type declared in a public extension`) (`regression-lint-stored-undone-final.log`).
- `qualified()` undone: `44 checks, 2 failed`: `registered exceptions are accepted (exit 1)`, the lint
  printing ``[IMM-1] `Ramp.Ramp.Phase.radians` is a stored `var` …``, and `… one of a type declared in a
  public extension` (`regression-lint-qualified-undone-final.log`).
- The `@usableFromInline` exemption undone: `44 checks, 3 failed`: the seeded tree's comparison
  (`unexpected Sources/ZTronDSPCore/Values/Frequency.swift:20: [IMM-1]` and `:21`), ``… nor one that
  `@inlinable` code sets (VIS-1)``, and `the package itself is clean (exit 1, expected 0)` with the six
  `[IMM-1]` lines of `AudioBlock.frames`, `Ramp` ×4 and `SeededGenerator.state`
  (`regression-usable-from-inline-undone.log`).

### WP-909.5 — The audit

`Docs/Process/reports/WP-909-audit.md`: 1 the parameter types and their classes; 2 the stored properties of
public value types; 3 the four registers, `unchecked-sendable.md` type by type; 4 IMM-4 and 5 IMM-5 with the
functions cited; 6 what is now mechanised; 7 every violation and what became of it; 8 what is open.

**Violations and what became of them:**

| Rule | Finding | What became of it |
|---|---|---|
| API-6 | none | — |
| IMM-1 | `DSPEnvironment`: 10 stored `var`s the module could set | `private(set)` |
| IMM-1 | `FeedCursor`: 3 stored `var`s the module could set | `fileprivate(set)` |
| IMM-1 | `AudioBlock.frames`, `Ramp` ×4, `SeededGenerator.state`: `@usableFromInline` state of inlinable code | Not a violation (VIS-1 prescribes the spelling); the lint accepts it, the register stays empty |
| IMM-2 | none | — |
| VIS-1 | none (`open-declarations.md` empty) | — |
| APR-1, APR-2 | none (`approvals.md` empty) | — |
| §9.2 | 8 rows of `unchecked-sendable.md` said what the code does not do | Rewritten; the internal comment of `UnfairLock` corrected |
| IMM-4, IMM-5 | none | — |

## 3. Gates and tests

All measured on the final state of the tree, 15:42–15:56, one after another (`.build/m9-api/final.sh`: the
gates by `.build/m9-api/gates.sh`, logs in `.build/logs/m9-api/gates/`, then every test target in Debug and in
Release, logs `.build/logs/m9-api/final-{debug,release}{,-full}.log`). Simulator `ztdsp-27` only; it is the one
booted.

**Gates** (run 2, 15:42:55–15:51:11):

| Gate | Exit | Final line |
|---|---|---|
| `Scripts/lint-bans.sh` | 0 | `lint-bans: clean (parts 1, 2, 3, 4; 605 files)` |
| `Scripts/check-dependency-graph.sh` | 0 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `Scripts/api-digest.sh --check` | 0 | `api-digest: ZTronDSPUI references public symbols only` (all eight lines below) |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 0 | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 0 | `order-matrix: 52 stages on 21 domains, 110 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | 0 | `golden: 197 files of 27 generators match the manifest` |
| `Scripts/check-function-effects.sh` | 0 | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | 0 | `ledger: 289 rows, consistent with §12 and §11` |
| `Scripts/tests/run-all.sh` | 0 | `run-all: every self-test passed (757 checks in 13 suites, 2 skipped: see above)` |
| `Scripts/external-parity.sh` | 0 | `external-parity: passed` |

`Scripts/api-digest.sh --check` printed:

```
api-digest: 10 digests equal the built modules
api-digest: 66 public initialisers of 43 stage types end in `isActive:`
api-digest: Docs/API/spec-map.tsv lists every public symbol of 10 digests in 712 lines (555 at the specification, 157 at 12 change requests)
api-digest: ZTronDSPDesign references public symbols only
api-digest: ZTronDSPMetal references public symbols only
api-digest: ZTronDSPAnalysis references public symbols only
api-digest: ZTronDSPIO references public symbols only
api-digest: ZTronDSPUI references public symbols only
```

`Scripts/tests/run-all.sh`, per suite: spec-crosscheck 29, process-files 45, lint-bans 44, check-dependency-graph
32, coverage-gate 44, golden 80, compile-fixtures 22, order-matrix 20, api-digest 68, benchmarks 37, ci 161,
workflow 23, external-parity 152 checks, each `0 failed`. The two skipped are the checks that need `--slow`
(`gate 1 with a real build and a seeded warning`, `the parity tests on the simulator with a seeded
violation`), skipped in the same way before this package.

`Scripts/external-parity.sh`: rules, guide, build, test, fixtures, release, audits and speed `passed`. Its
lines: `rules: clean (57 files: the three products alone; the bans of Scripts/lint-bans.sh, parts 1 to 4)`;
`extension-guide: ExtensionGuide.md is what its template makes (39 blocks of compiled code)`; `[test] 116
tests passed; 1 expectations are known to fail and did` (`theProbeCountsWhatAnAllocatingStageDoes()`, the
probe's own known issue); `compile-fixtures: 4 valid fixtures compile, 21 invalid fixtures fail with their
sentences`; `[audits] 19 tests passed; 1 expectations are known to fail and did`, then `1 tests passed`;
`[speed] every stage but the gain written as a SampleProcessor ran within its bound; that gain missed it, as
CR-025 item 1 records` (ExternalGain against stock Gain ×1.075 round by round, the known issue
`theGainAgainstTheStockGain()`; every other pair between ×0.941 and ×1.000).

**Every test target, Debug** (`Scripts/xc.sh test`, 15:51:11–15:54:26, exit 0, `** TEST EXECUTE SUCCEEDED **`)
**and Release** (`ZTD_CONFIG=Release Scripts/xc.sh test`, 15:54:26–15:56:29, exit 0, `** TEST EXECUTE
SUCCEEDED **`):

| Target | Debug | Release |
|---|---|---|
| `ZTronDSPUITests` | `✔ Test run with 278 tests in 19 suites passed after 2.638 seconds.` | `✔ Test run with 278 tests in 19 suites passed after 2.229 seconds.` |
| `ZTronDSPTests` (the facade) | `✔ Test run with 10 tests in 3 suites passed after 0.034 seconds.` | `✔ Test run with 10 tests in 3 suites passed after 0.034 seconds.` |
| `ZTronDSPTestingTests` | `━ Test run with 55 tests in 8 suites passed after 0.165 seconds with 3 known issues.` | `━ Test run with 55 tests in 8 suites passed after 0.029 seconds with 3 known issues.` |
| `ZTronDSPMetalTests` | `✔ Test run with 115 tests in 12 suites passed after 4.249 seconds.` | `✔ Test run with 115 tests in 12 suites passed after 0.722 seconds.` |
| `ZTronDSPIOTests` | `✔ Test run with 134 tests in 13 suites passed after 4.744 seconds.` | `✔ Test run with 134 tests in 13 suites passed after 4.231 seconds.` |
| `ZTronDSPDesignTests` | `✔ Test run with 336 tests in 41 suites passed after 56.519 seconds.` | `✔ Test run with 336 tests in 41 suites passed after 1.831 seconds.` |
| `ZTronDSPCoreTests` | `✔ Test run with 511 tests in 60 suites passed after 8.898 seconds.` | `✔ Test run with 511 tests in 60 suites passed after 4.815 seconds.` |
| `ZTronDSPAnalysisTests` | `✔ Test run with 420 tests in 41 suites passed after 98.804 seconds.` | `✔ Test run with 420 tests in 41 suites passed after 11.543 seconds.` |
| `CZTronDSPTests` | `✔ Test run with 230 tests in 31 suites passed after 4.977 seconds.` | `✔ Test run with 230 tests in 31 suites passed after 1.002 seconds.` |
| **all** | **2,089 tests passed** | **2,089 tests passed** |

The three known issues of `ZTronDSPTestingTests` are the test product's own checks that a failing expectation
records an issue (`aNodeThatAllocatesIsCaughtOnTheTestsOwnThread()`, `PipelineAuditTests.swift:93`;
`expectNoAllocationsRecordsAnIssueWhenTheBlockAllocates()`, `AllocationAuditTests.swift:125`;
`expectCloseRecordsAnIssueOnFailureOnly()`, `ClosenessTests.swift:79`), the same in every run. No test failed
in any run of this session (Debug and Release at 15:16–15:21 before the last changes, the coverage run at
15:37–15:41, and the two above), so there is no test to report as failing once and passing twice.

**Coverage (COV-3).** Debug with coverage in a derived-data folder of its own (built 15:36–15:37, tested
15:37:45–15:41:18, all nine targets, 2,089 tests passed), then `Scripts/coverage-gate.sh --xcresult … --mode changed-files` on the Swift files of
the production targets that this package changed (`.build/logs/m9-api/coverage/gate-changed-files.log`; the
folder and the bundle were deleted afterwards):

```
coverage-gate: 15 lines marked coverage:ignore (0.06 % of the production lines, below 0.50 %)
coverage-gate: Sources/ZTronDSPCore/Environment/DSPEnvironment.swift 100.00 % (153 of 153 lines), needs 97.50 %: ok
coverage-gate: Sources/ZTronDSPCore/Feeds/ColumnStore.swift       100.00 % (268 of 268 lines), needs 97.50 %: ok
coverage-gate: Sources/ZTronDSPCore/Feeds/FeatureSink.swift       100.00 % (63 of 63 lines), needs 97.50 %: ok
coverage-gate: Sources/ZTronDSPCore/Support/UnfairLock.swift      100.00 % (26 of 26 lines), needs 97.50 %: ok
coverage-gate: Sources/ZTronDSP/ZTronDSP.swift                    no executable lines
coverage-gate: pass (changed-files)
```

The other changed files are tests, fixtures, scripts and documents, outside COV's denominator (COV-4); the
scripts are exercised by their self-tests above.

**Documentation (VIS-2).** No public symbol was added. The declarations whose access changed became internal
(the twelve keys, `SinkDescription`); the public types whose internal stored properties got private setters
(`DSPEnvironment`, `FeedCursor`) keep their public declarations and documentation as they were.

## 4. Open

- CR-031 and CR-032 are `Proposed`: the owner decides each item (section 5). If an item is decided another
  way, the map's lines that name it move with it.
- WP-901b: the public documentation comment of `ScriptedSource` says that `render` sends events and
  allocates, not that it takes the lock of the format when the script changes it (audit, section 3.4). Left
  for WP-901b (documentation comments are out of scope here) and recorded in the ledger's backlog of WP-909.
- The lint accepts any `@usableFromInline` stored `var`, whatever kind of type holds it: a future one in a
  design or a table would pass part 4. Today there are six, all state (909.2). Keying the rule on the kinds of
  IMM-1 would need the lint to know which type is which; I did not do it.
- `Scripts/api-digest.sh --check --graphs DIR` (graphs read from a folder, not from the build) does not render
  the facade's `reexport` lines, so check 1 reports the facade's digest as different in that mode. This was so
  before (the re-exports are read from the build alone); it does not touch `--check` on the build.
- Seen on the way: after a change of a re-export alone, the incremental build of `Scripts/xc.sh build` does
  not compile the targets that import the facade again (901a.1). A clean build does; nothing in the package
  relies on the incremental one.

## 5. Change requests and decisions asked of the owner

**Written** (both `Proposed`, raised by Implementer M9-api (agent) on 2026-11-21):

- `Docs/Process/changes/CR-031.md`, "Public API that differs from §4–§8 (WP-901a)". The owner decides:
  1. whether §5.11.1 takes the proposed wording for `PipelineStage` refining `StageValue`, which holds
     `lower(_:)` (a stage outside the package is still written as §5.11.1 shows);
  2. whether §4.6 says that `MicrophoneAuthorizing` is an internal seam;
  3. whether §8.3 says that `FrameScheduler` belongs to the views, internal to `ZTronDSPUI`;
  4. nothing to change for `FFTBackend.mpsGraph` and `MedianStrategy.incrementalSortedLanes`: they arrive with
     WP-613 and WP-533 (recorded so that every name of §4–§8 has a place).
- `Docs/Process/changes/CR-032.md`, "Public symbols beyond §4–§8 (WP-901a)". The owner decides whether each
  stays public for the reason given: `ZTronDSPCore` (`AnyStrategy`, `AudioBuffer`, `BiquadSection`,
  `PipelineContent`, `subsample(_:count:by:phase:into:)`, `upsample(_:count:by:into:)`,
  `zeroPad(_:count:into:paddedCount:placement:)`), `ZTronDSPDesign` (`DSP.maximumRateChangeFactor`,
  `DSP.rateChangeTaps(by:rejection:passband:)`, `DSP.savitzkyGolayCoefficients(window:polynomialOrder:derivative:)`,
  `DSP.savitzkyGolayMaximumWindow`), `ZTronDSPAnalysis` (`ConstantQGeometry`, `ConstantQKernel`),
  `ZTronDSPMetal` (`CrossoverTable.replacing(_:with:)`, `CrossoverTable.size(of:)`), `CZTronDSP`
  (`ztd_buffer_color()`); and takes note that the twelve derived keys and `SinkDescription` were made
  internal, so that CR-015 item 11 is one name shorter.

**Decisions asked without a change request:**

- The reading of IMM-1 that lint part 4 now enforces (909.2, 909.4): a stored `var` of a public struct that its
  module can set is reported unless it is private, file-private or `@usableFromInline`. It is wider than
  IMM-1's list of kinds and narrower than the brief's statement; the owner may confirm it, or ask for the
  rule to key on the kinds.
