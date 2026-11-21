# WP-901b — implementer's report

| Field | Value |
|---|---|
| Package | WP-901b: the landing page; every public symbol documented with its threading contract (VIS-2); the order matrix covers every public stage |
| Implementer | Implementer M9-docs (agent), brief 63 with the common rules of brief 60 |
| Date | 2026-11-21, times Europe/Rome |
| Tree | The main tree, branch `handover-chain`. Everything below is unstaged or untracked on top of commit `e52d9b8` ("Checkpoint: integ and m9-api", 16:45:21), which holds the staged state this work began from; that commit was made by someone else during the baseline run. This work committed nothing and added nothing to the index |
| Ledger | WP-901b `Verifying`, implementer `Implementer M9-docs (agent)` |
| Change request | CR-033, `Proposed` (how VIS-2 applies to members, witnesses and unavailable overloads) |

## 1. Files

### Added (24)

| File | What it is |
|---|---|
| `Scripts/docs.sh` | `--audit`, `--build`, or both in that order (no argument) |
| `Scripts/lib/doc_audit.py` | The engine: the audit of the symbol graphs, the sources, the C headers and the catalogs; the reader of the docbuild log; the link check of the merged archive. The vocabulary is at its top (`--help`) |
| `Scripts/tests/test-docs.sh` | Self-test of `docs.sh`, 56 checks; registered in `Scripts/tests/run-all.sh` |
| `Tests/Fixtures/Docs/Clean/Clean.swift`, `BareSymbol/Bare.swift`, `NoContract/NoContract.swift`, `Headers/clean/fixture.h`, `Headers/bare/fixture.h`, `Catalog/DocFixture.docc/DocFixture.md` | The fixtures of `test-docs.sh` |
| `Sources/ZTronDSP/ZTronDSP.docc/ZTronDSP.md` | The landing page |
| `Sources/<Module>/<Module>.docc/<Module>.md`, seven files | One landing article per module, with topic groups: Core 13, Analysis 10, Design 8, Metal 5, Testing 5, UI 3, IO 2 |
| `Tests/ZTronDSPTests/LandingPageTests.swift` | One test: the landing page's examples, compiled and run |
| `Tests/OrderMatrix/not-in-matrix.txt` | The eight public stages of the core that have no line in the matrix, each with its reason |
| `Tests/Fixtures/OrderMatrix/digests/FixtureCore.txt`, `FixtureStages.txt`, `Tests/Fixtures/OrderMatrix/not-in-matrix.txt` | The fixtures of the stage comparison |
| `Docs/Process/changes/CR-033.md` | The change request of item 1 (`Proposed`) |
| `Docs/Process/reports/impl-WP-901b.md` | This report |

### Changed (185)

| File | What changed |
|---|---|
| 174 files under `Sources/` | Documentation comments: CZTronDSP 9 headers, CZTronDSPTesting 1, Core 56, Analysis 46, Design 29, Metal 12, Testing 8, UI 8, IO 5; 2,638 lines added and 717 removed. Three files also change their layout so that every member carries its own comment: `SignalDomain.swift` (the one-line enums are written on three lines), `StageDescription.swift` and `StressFixture.swift` (a list of cases is written one case per line, in the same order). Compared with the files of `e52d9b8`, with comments and whitespace removed and case lists written one per line, every file is token for token the same, and `Scripts/api-digest.sh --check` finds no change |
| `Scripts/ci.sh`, `.github/workflows/ci.yml` | Gate 4 runs `Scripts/docs.sh --audit` after the API digest; it is named "API digest and documentation", and so are the job and the step of the workflow |
| `Scripts/tests/test-ci.sh` | The stand-in for `docs.sh`, the order of the gates, `STUB_DOCS`, and a seeded public function without a comment that must fail gate 4 |
| `Scripts/tests/run-all.sh` | Runs `test-docs.sh` |
| `Scripts/lib/order_matrix.py`, `Scripts/order-matrix.sh` | The stage comparison: the public stages come from the API digests (`--digests`); `--not-in-matrix` is new; `--sources` is gone |
| `Scripts/tests/test-order-matrix.sh` | The comparison's cases: a seeded missing stage, stale lines in either list, a stage in both lists |
| `Tests/OrderMatrix/stages.txt` | Five lines for `Emit` |
| `Docs/OrderMatrix.md`, `Tests/ZTronDSPTests/OrderMatrixGenerated.swift` | Regenerated: 57 stages on 21 domains, 142 cells accepted (was 52 and 110) |
| `Docs/Process/ledger.md` | Row WP-901b: `Verifying`, implementer `Implementer M9-docs (agent)` (§3) |

### Deleted (1)

| File | Why |
|---|---|
| `Tests/Fixtures/OrderMatrix/sources/Stages.swift` | The fixture of the source scan that the comparison replaces; the fixture digests stand in for it |

## 2. Per item of the brief

### 2.1 The audit (item 1)

**What it does.** `Scripts/docs.sh --audit` reads the last Debug build, as the API digest does. It
extracts the public symbol graphs of the eight Swift modules with `-skip-inherited-docs`, so a comment
that a witness only inherits does not count. It then checks five things:

1. **`[no comment]`**: every public symbol has a comment of its own. Members the compiler writes
   (`init(rawValue:)`, `init(from:)`) are counted apart.
2. **`[no contract]`**: every public type, protocol and global function, and every member that a module
   adds to another module's type, states the context and the allocation. A witness is exempt when its
   requirement, or the requirement's protocol, states both. A member is covered by its type's statement
   (CR-033).
3. **`[source]`**: every public declaration of `Sources` has a `///` directly above it; attribute lines
   and `#if` lines may stand between them. An `@available(*, unavailable)` declaration must name ORD-4,
   "unavailable" or "diagnostic". This check is needed because the graphs leave unavailable symbols out.
4. **`[C]`**: every function, type and macro of the public headers of CZTronDSP and CZTronDSPTesting
   has a comment. This is done by a small parser of the headers, not by reading.
5. **`[example]`**: every Swift block of a catalog is the compiled region that its marker
   `<!-- snippet: path#region -->` names.

The vocabulary is written at the top of the script. It uses the contexts of §4.3, by the names given
there, and one of "allocates", "may allocate", "does not allocate" and "never allocates". Two
additions:
- "control or background context" names the control context;
- the plural "do not allocate" is accepted.

**Tests.** `Scripts/tests/test-docs.sh` has 56 checks, and the last run had 0 failures. They cover:
- a clean module, counted;
- a seeded bare public function, found in the graph and in the sources with file and line;
- a comment that a witness only inherits, which does not count;
- a seeded type without a contract;
- a member of another module's type that implements a stated requirement, which passes (CR-033);
- an unavailable overload with and without its ORD-4 comment;
- a header function without a comment;
- a stale catalog block, a block that no region backs, and a marker naming no region;
- the `--build` cases (§2.6);
- the package's own audit, which passes.

**What failed without it.** There was no audit. Its first run, on the inherited tree, found 1,693
findings (`.build/m9-docs/audit-first.txt`):
- 604 without a comment, 12 of them written by the compiler;
- 491 without a contract;
- 577 in the sources;
- 21 in the C headers.

**Numbers per module, before and after.** "Before" is the first run of the audit. "Hand-over tool" is
`ZTronDSP-handoff/tools/doc_audit.sh`, run before any change (`.build/m9-docs/docaudit-before/report.txt`)
and again on the final build (19:46, `.build/logs/m9-docs/docaudit-final.log`, exit 0): public symbols /
without a comment / documented types that name no thread, actor or context.

| Module | Public symbols | No comment, before | No contract, before | Source, before | Hand-over tool, before | After (audit and tool) |
|---|---|---|---|---|---|---|
| ZTronDSPCore | 1,169 | 292 (+4 by the compiler) | 154 | 243 | 1169 / 206 / 86 | 0 / 0 / 0 |
| ZTronDSPAnalysis | 657 | 217 (+2) | 132 | 263 | 657 / 124 / 15 | 0 / 0 / 0 |
| ZTronDSPDesign | 647 | 0 | 106 | 2 | 647 / 0 / 4 | 0 / 0 / 0 |
| ZTronDSPMetal | 195 | 19 (+4) | 26 | 19 | 195 / 9 / 6 | 0 / 0 / 0 |
| ZTronDSPTesting | 193 | 64 (+2) | 33 | 50 | 193 / 57 / 24 | 0 / 0 / 0 |
| ZTronDSPIO | 59 | 0 | 5 | 0 | 59 / 0 / 1 | 0 / 0 / 0 |
| ZTronDSPUI | 71 | 0 | 35 | 0 | 71 / 0 / 0 | 0 / 0 / 0 |
| ZTronDSP (facade) | 0 (it only re-exports) | — | — | — | — | 0 |
| C headers | 156 declarations | 21 (CZTronDSP 19, CZTronDSPTesting 2) | | | | 0 |

"After" reads: the audit finds 0 without a comment, 0 without a contract and 0 in the sources, and the
hand-over tool finds 0 without a comment and 0 types that name no context, of the same public symbols
(for example `ZTronDSPCore: 1169 public symbols, 0 without a documentation comment, 0 documented types
that name no thread, actor or context`).

The final run of `Scripts/docs.sh --audit` (`.build/logs/m9-docs/gate-docs-audit.log`, exit 0) ends:

```
docs: sources: 2676 public declarations, 0 without a comment directly above
docs: C headers: 156 declarations, 0 without a comment
docs: catalogs: 3 examples, 0 findings
docs: every public symbol is documented with its threading contract (VIS-2)
```

### 2.2 The comments, and the contracts found by reading (item 1)

Every comment was written after reading the code it describes: who calls it, and whether it allocates,
locks, or touches an actor or `BackgroundWork`. Value types got short contracts. Real-time entry points
say what they must not do.

The brief asks that both readings pass. So every public member also has a `///` of its own, one line
where its type's statement covers it. Several groups got a sentence each, written to say what the code
does:
- the 71 `@available(*, unavailable)` overloads: "Never called, being unavailable: no context runs it,
  and it allocates nothing";
- the witnesses of `InvertibleStage`: "As every requirement of an invertible stage, it runs in the
  background, never on the analysis thread, and allocates";
- the static factories and empty strategies;
- the fluent and builder overloads;
- the `Emit` initialisers.

**Contracts found by reading** (those a reader could not guess from the name):
- `ScriptedSource.render` allocates, and takes the lock of the format when the script changes the
  format. WP-909's audit asked for this.
- `AnyStrategy` holds an `any Hashable & Sendable`: three words inline, then the type's metadata and
  its `Hashable` table. A value larger than three words is boxed on the heap, and so is the copy that
  `value(as:)` returns of it. The sizes were read from the stored properties:
  - the stock `MultirateSparseKernelStrategy` holds an `AnyStrategy` of its own, five words. So
    creating a `ConstantQ` with it allocates, and so does reading its `strategy`. M5c-A A-7 asked that
    this be said ("the initialiser boxes the strategy"); `ConstantQ`'s statement now says it.
  - every other stock backend, mask, median, normalisation, method, mel formula and root finder fits in
    three words. `STFT`, `InverseSTFT`, `Autocorrelation`, `HarmonicPercussive` (mask and median),
    `ChromaFold`, `Tempogram`, `MelScale`, `MultirateSparseKernelStrategy(backend:)`,
    `TransferFunction` and `DifferenceEquation` now say that creating one allocates only for a
    strategy larger than three words, which no stock one is.
  - `Frequency.mel` boxes its formula; `mel(sampleRate:)` boxes the formula it is given, to compare
    the two.
- `LowPass`, `HighPass`, `BandPass` and `BandStop` keep their edges in an array, so creating one
  allocates. They now say so.
- These do not allocate:
  - `Vector.Bound`, whose closures capture nothing;
  - `MetalMedian()`, whose device is `.shared`, an enum;
  - `StageActivation`, `BoundSwitch` and `BoundResult`, structs that hold a `Binding`;
  - `Pipeline.init()`, which holds an empty array.
- `DomainRule` may allocate, for its name and its closure. The colour tables are `static let`, so the
  first read allocates once.
- `DSP.nextFastLength` and `DSP.previousFastLength` loop over an array literal, so they may allocate.
  They are design-time calls, not for the analysis thread.
- `HardwareInputSource`'s convenience initialiser configures no audio session and allocates.
  `availableInputs` allocates, in the background.
- `OfflineRunner.process` and `run` compile a plan on the caller's thread, so they allocate. They are
  not for the analysis thread.
- `MetalMedian.filter` blocks on the GPU, allocates, and reaches `MetalContext.sharedBlocking()`. Its
  type now says that filtering runs in the background, and that creating one does not allocate
  (M5b A-33).
- `ztd_queue` creation rounds a capacity of 0 or 1 up to 2. A sentence saying it returns NULL for 0
  would have been false, and is not written.

**Comments corrected because they were untrue:**
- `MedianOracle`: "they allocate" did not hold for `reflected(_:count:)`.
- `MultirateSparseKernelStrategy.latency` said "Arithmetic, but for the half-band filter". It allocates
  the six arrays of a `ConstantQSchedule` on every call, and the first call also designs the filter. It
  now says so, and so does the internal `schedule(of:hop:)` (M5c A-9, WP-522b).
- These claimed no allocation, but build the message of the error they throw:
  - `FIRDesignMethod.estimatedLength`: the requirement, its default and the least-squares witness;
  - `DSP.prewarpedAngularFrequency`;
  - `ConstantQGeometry`, whose statement said "creating one allocates nothing".

  They now say "it allocates only the error it throws", the package's own phrase
  (`Frequency.swift`, `StageValidation.swift`).
- `KernelSpec` said "reading its properties does not allocate". `isIdentity` compares an FIR's taps
  with the list `[1]`, which may allocate. The statement now names that exception.
- `RootConditions` said "reading it does not allocate". `largest` joins the two lists before it takes
  the maximum. The statement now names that exception, and `largest` says it allocates.
- `Measuring.init` said "allocates as any value does". It builds the description of the measuring
  tap. It now says that.
- `Closeness`: the scalar `compare` linked to itself (``compare(_:_:_:)`` names both overloads). The
  link now names the overload it means, disambiguated by its parameter types.

**Members that allocate and said nothing of it.** Checking finding M5c-A A-7 ("the initialiser boxes
the strategy") on the finished tree showed that `ConstantQ`'s statement spoke only of `lower(_:)`, while
creating one with the stock strategy allocates. So two scripts listed every public initialiser and
factory, and every public member, whose body looks as if it allocates: it boxes into `AnyStrategy`,
builds a collection or a string, or runs a builder block (`.build/m9-docs/verifiers/creation_alloc.py`
and `member_alloc.py`). Each row was read against the code. Besides the corrections above, these said
nothing of an allocation they make, and now say it:
- the `parameters` and `replacingParameters(_:)` of the stages and of the system elements (ANI-2), and
  the two requirements in `StageValue`: they build what they return. Those of the two `.active(_:)`
  wrappers allocate as the wrapped stage's do. The system elements' default `parameters` returns an
  empty list, and now says that it does not allocate;
- the first initialiser of `Tap`, and those of `FIRSystem` and `IIRSystem`, which run their builder
  block;
- `TransferFunction.differenceEquation`, which pads the two lists; the initialisers of
  `ScriptedSource`; `InverseDecibels.rule`, which is built on each read;
- the `description` of `Window`, `Frequency`, `StagePath` and `StagePath.Component`; `Window.custom`,
  which samples its closure, and comparing or hashing such a window;
- `FeedSnapshot.row`, `ConstantQGeometry.frequencies` and `atomLengths`, `ConstantQKernel.dense`,
  `MelFilterBank.centers` and `denseWeights`, and `SecondOrderSections.stabilityMargin`.

This second survey changed 81 comments in 32 files, comment lines only: the items of this list, the
`AnyStrategy` and response-stage items above, and the corrections of `ConstantQGeometry`, `KernelSpec`,
`RootConditions` and `Measuring.init`. The scripts' lists went from 87 of 175 initialisers and
factories, and 154 members, to 46 and 114. Each row left is covered by its type's statement, in words
the scripts' patterns do not match: for example `PipelineBuilder`, "each one allocates the description
it builds", and `TestSignal`, "each allocates the samples it returns".

**Found, not fixed:**
- `Sources/ZTronDSPTesting/Golden.swift:241`: `require(_:)` throws `.missingCase(file: generator, …)`.
  The field `file` carries the generator's name, so the message reads "golden file <generator> has no
  case named …". The comment of the case now says what `file` holds (`Golden.swift:14`). Changing it
  would change behaviour, which the brief excludes.
- `Sources/ZTronDSPTesting/Closeness.swift:187` and `:203`: `expectClose` evaluates its `@autoclosure`
  `comment` on every call, not only on a failure as `expectNoAllocations` does. This is now said, and
  not changed.

**Symbols that should not be public, for WP-901a:** none beyond CR-032's list.

### 2.3 The verifiers' scanners on the finished tree (item 1)

The scanners were run on the 263 Swift files of `Sources`, and the graph ones on the graphs of the final
build. The final run is the chain's second step (§3), `.build/m9-docs/verifiers/run-verifiers.sh`; each
scanner's whole output is in `.build/m9-docs/verifiers/`. "Earlier" is the measurement after the audit
first reached 0, before the members got their own contract sentences (§2.2). For M5c-B and M4a-B,
"earlier" is their first run.

The brief names `v-m5a-b/VerifierB/vis2.py`, which does not exist: that folder has no VIS-2 script. Both
existing `vis2.py` scanners were run.

| Scanner | What it refuses | Earlier | Final |
|---|---|---|---|
| `v-m5b-a/VerifierA/scripts/vis2_scan.py` (named) | a public declaration with no `///` directly above | 15 | **15** |
| `v-m5b-a/VerifierA/scripts/vis2_contract.py` (named) | a declaration whose own comment, or its enclosing type's in the same file, lacks context or allocation | 167 flagged, 1,395 ok | **15 flagged, 1,547 ok** |
| `v-m5a-a/VerifierA/python/vis2.py` (for the named, missing one) | a declaration without a threading contract in its own or its type's comment | 180 of 2,637 | **0 of 2,637** |
| `v-m1-a/VerifierA/doc-coverage.sh` logic (`doc_coverage.py` on each graph; named) | a public symbol without a doc comment in the graph | — | **0 of 2,991**, in every module's graph and extension graph |
| `v-m5b-b/VerifierB/vis2_decide.py`, generalised to every module (`.build/m9-docs/verifiers/decide_all.py`) | V1 no comment of its own or inherited, nor named by its type; V2/V3 no context or allocation in its own, requirement's, protocol's or type's comment | — | **2,979 symbols, 0 failing** |
| `v-m5b-b/VerifierB/vis2_graph.py` (unchanged, pointed at the final graphs) | symbols without a comment, or with only an inherited one; types and functions without context or allocation | — | **2,979 symbols, 0 without, 0 inherited-only, 0 flags** |
| `v-m5c-b/VerifierB/scripts/vis2_scan.py` | a type or function whose own or enclosing type's comment has no `thread\|context\|main actor\|real time` or no `allocat` | 22 | **0** |
| `v-m5b-b/VerifierB/vis2_scan.py` | a declaration without a doc comment | — | **2,908 ok, 15 NO-DOC** |
| `v-m5b-b/VerifierB/vis2_contract.py` (a reading aid, "not a gate") | prints each function's sentences on context or allocation | — | 1,562 entries; 463 `NONE` (contract held by the type or the requirement), 15 `NO COMMENT` |
| `v-m1-b/VerifierB/scripts/doc_coverage.py` | a declaration without `///` above it | — | 65 of 2,932, all false positives (below) |
| `v-m4b-b/VerifierB/vis2.py` | a declaration whose own comment names no context | 1,531 + 15 | **1,400 NO THREADING + 15 NO COMMENT**; it ends "vis2: 15 declarations without a documentation comment" and exits 15 |
| `v-m4a-b/VerifierB/vis2_scan.py` | a declaration whose own comment names no context | 1,343 | **1,322** |

**What the remaining lines are:**
- **The 15** of `vis2_scan`, `vis2_contract`, `vis2.py` (M4b) and `vis2_scan` (M5b-B) are the same 15
  functions of `Vector.Native`, at `Sources/ZTronDSPCore/Toolkit/Vector.swift` lines 122 to 377. A
  `#if ZTRONDSP_PERF_ANNOTATIONS` / `@_noAllocation @_noLocks` / `#endif` block stands between their
  `///` and the declaration, and those scanners stop at `#if`. The comments are there: the symbol
  graphs carry them, the audit's source check reads past `#if`, and M5c-B's scanner, which skips `#if`
  lines, accepts them. Moving the comment below the `#if` block would put it between the attributes and
  the declaration, and risk detaching it, so it was left.
- **The 65** of `doc_coverage.py` (M1-B) are those 15, plus 50 declarations whose
  `@available(…, message: "…")` attribute has a `)` inside its message. That scanner's attribute pattern
  `\([^)]*\)` stops at the first `)`. Each of the 50 has its `///` above the attribute.
- **The 1,400 and 1,322** of the two M4 scanners are members whose own comment does not name a context.
  Their type's comment does, and so do the requirements they implement. These scanners read each
  member alone. That is a stricter standard than the one the brief gives: a member needs a `///` of its
  own, and "one line is enough where the type's statement covers it". Meeting it would mean pasting a
  context sentence on some 1,400 members, which the brief forbids. It is not adopted; see §4.

**So the audit refuses everything the named scanners refuse in substance.** On the final tree, they
refuse only the 15 `#if` false positives. Every refusal of the earlier runs was an omission that the
member pass removed. The two M4 scanners' per-member reading is the exception, recorded above and in §4.

### 2.4 The digests' VIS-2 findings, per finding id (item 1)

`.build/m9-docs/verifiers/per_finding.py` takes every symbol each finding names, by file and name, since
lines have moved. It reads the final graphs, and reads the unavailable overloads from the source. Its
verdict for all 34 groups below is **documented**, with 0 symbols failing
(`.build/m9-docs/verifiers/per_finding.txt`). Each named symbol has a comment of its own, and its
context and allocation are stated in that comment or by its type, requirement or protocol. Each
unavailable overload names ORD-4 and carries "no context runs it, and it allocates nothing".

| Wave, verifier, finding | Package | Symbols checked (own comment with both halves) | Verdict |
|---|---|---|---|
| 1, M1-A A-22 | WP-110a | `SignalDomain.swift`, 78 (78) | documented |
| 1, M1-A A-34 | WP-115 | `Implementation.swift`, 36 (32) | documented |
| 1, M1-A gap WP-104, backlog A-9 | WP-104 | `SignalFormat.swift`, `AudioBuffer`, 26 (17) | documented |
| 1, M1-A gap WP-106, backlog A-13 | WP-106 | `StagePath.swift`, 13 (10) | documented |
| 1, M1-A gap WP-111, backlog A-27 | WP-111 | `FeedAxis.swift`, 20 (19) | documented |
| 1, M1-A backlog A-16 | WP-107, 113, 114, 118 | `Complex.swift`, `Vector.swift`, `OverlapAdder.swift`, 104 (45) | documented |
| 1, M1-A backlog A-19 | WP-108 | `DSPEnvironment.swift`, 37 (33) | documented |
| 1, M1-A backlog A-25 | WP-110b | `Frames.swift`, 48 (39) | documented |
| 1, M1-A backlog A-47 | WP-120 | `MATLABScript.swift`, 32 (5) | documented |
| 1, M1-B backlog B-15 | WP-101 | `MelFormula.swift`, 17 (9) | documented |
| 1, M1-B backlog B-18 | WP-103 | `RollOff.swift`, 16 (12) | documented |
| 1, M1-B backlog B-28 | WP-121 | `ParameterVector.swift`, 12 (7) | documented |
| 1, M4a-B B-BL-1; 2, M4b-B BL-1 | WP-428b, WP-434 | `SystemKind`, `AlphaBeta` and its `Output`, 15 (13) | documented |
| 2, M5a-A backlog A-8 | WP-501g | `WindowDiagnostics.swift`, 2 (2) | documented |
| 2, M5a-A backlog A-9 | WP-540 | `FrameExports.swift`, 8 (5) | documented |
| 2, M5a-A backlog A-11 | WP-537 | `InvertibleStage` and its members, 7 (5) | documented |
| 3, M5b-A A-2, M5b-B B-1 | WP-513 | `ConvolutionMode`, 4 (4) | documented |
| 3, M5b-A A-4, M5b-B B-3 | WP-514 | `CorrelationNormalization`, 5 (5) | documented |
| 3, M5b-A A-6, M5b-B B-5 | WP-515 | `Autocorrelation.swift` 17 (16), and 1 unavailable overload | documented |
| 3, M5b-A A-9, M5b-B B-7 | WP-516 | `Convolve.swift`, 12 (11) | documented |
| 3, M5b-A A-11, M5b-B B-9 | WP-525 | `OnsetStrength.swift` 11 (10), and 4 overloads | documented |
| 3, M5b-A A-13, M5b-B B-10 | WP-526, WP-527 | `Tempogram.swift` 28 (22), and 4 overloads | documented |
| 3, M5b-A A-15, M5b-B B-11 | WP-527 | `FourierTempogram`, `TempogramMethod.fourier`, 6 (4) | documented |
| 3, M5b-A A-17, M5b-B B-12 | WP-529 | `MedianAxis`, `MedianStrategy`, `SelectionNetworkMedian`, 13 (11) | documented |
| 3, M5b-A A-19, M5b-B B-14 | WP-530 | `MaskStrategy.swift`, 18 (12) | documented |
| 3, M5b-A A-22, A-23, M5b-B B-19 | WP-531a, WP-531b | `HarmonicPercussive.swift` 19 (18), and 4 overloads | documented |
| 3, M5b-A A-26, M5b-B B-21 | WP-532 | `HPSS.swift` 7 (6), and 4 overloads | documented |
| 3, M5b-A A-30, M5b-B B-22, backlog A-NB12 (its VIS-2 part) | WP-539, WP-537 | `StageInversions.swift`, `RateInversions.swift`, `DecimateInversion.swift`, 14 (14) | documented |
| 3, M5b-A A-33, M5b-B B-26 | WP-612 | the median filters of `MedianStrategy.swift` and `OfflineSeparation.swift`, 14 (8) | documented |
| 3, M5c-A A-2, M5c-B B-3 | WP-517 | `ConstantQGeometry.swift`, 17 (14) | documented |
| 3, M5c-A A-3, M5c-B B-4 | WP-518 | `ConstantQKernel.swift`, 18 (16) | documented |
| 3, M5c-A A-7, A-8, A-9, M5c-B B-6 | WP-521, WP-522a, WP-522b | `ConstantQ.swift`, `ConstantQStrategy.swift` 28 (24), and 7 overloads | documented; A-7's boxing on creation is now said (§2.2) |
| 3, M5c-A A-12, M5c-B B-11 | WP-523 | `ConstantQScale.swift` 16 (15), and 7 overloads | documented |
| 3, M5c-A A-18, M5c-B B-15, and M5c's gap on the seven catch-alls | WP-524 | `ChromaFold.swift`, `ChromaRecipes.swift` 37 (25), and 7 overloads | documented |

The number in brackets counts the symbols whose own comment says both halves. The others are
properties, cases and members, which their type's statement covers.

The rows above also cover:
- the wave-2 auditor's note on WP-428b ("BL-1 (VIS-2 on SystemKind)");
- the wave-1 gaps of WP-104, WP-106 and WP-111.

The ledger's note on WP-909 (`ScriptedSource.render` takes the lock of the format) is answered in §2.2.

### 2.5 CR-033 (item 1)

`Docs/Process/changes/CR-033.md`, `Proposed`. It is verifier A's CR-VA-4 (`WP-515-A.md`), written out:
- a type's statement of context and allocation covers its members;
- a witness has its requirement's contract unless it states another;
- an `@available(*, unavailable)` ORD-4 overload needs a comment saying so, and no contract;
- added: a nested type, and a member that a module adds to another module's type, state their own
  contract.

The audit implements exactly that reading. Every member also carries a `///` of its own, so the tree
passes VIS-2 read as written too (§2.3). No package is paused.

### 2.6 The landing page, the catalogs and a documentation build without warnings (item 2)

**The landing page** is `Sources/ZTronDSP/ZTronDSP.docc/ZTronDSP.md`. It gives:
- what the package is, in four sentences (§1.1);
- the three products and the modules, with what each holds (§4.2), as a table whose module names link
  to the module pages;
- "describe → compile → run", with the builder and the fluent spelling of one pipeline and how it is
  attached and run;
- the execution contexts of §4.3, given as the key to every threading contract;
- curated topic groups: describing a pipeline; the stages of the example; attaching and running it;
  reading what it produces; in the background.

The examples are regions of `Tests/ZTronDSPTests/LandingPageTests.swift`, which the audit's
`[example]` check compares with the page. That file is one test: the builder and the fluent pipeline
are equal; it attaches and runs a 0.25 s real-time generator; it reads 513 rows and more than zero
columns from the heat map. So the examples cannot rot.

Each module catalog is one landing article with topic groups (§1). `.docc` folders are documentation
for SwiftPM and Xcode, not unhandled resources: the final build has 0 warnings
(`.build/logs/m9-docs/gate-build.log`, where `Scripts/xc.sh` prints every `warning:` line; it printed
none). `lint-bans.sh` and `check-dependency-graph.sh` pass with the catalogs in the tree.

**`Scripts/docs.sh --build`** works in four steps:
1. It runs `xcodebuild docbuild` of the scheme `ZTronDSP-Package`, which covers the eight Swift modules.
   It uses the simulator of `Scripts/xc.sh` (ztdsp-27) and derived data of its own, `.build/docs`.
   `-enableCodeCoverage` is not passed: docbuild refuses it with exit 64.
2. It fails on every warning that DocC or the compiler prints for the package's sources. It prints each
   warning once, relative to the package, although the log has each one twice. A warning that names no
   file of the package is shown as a note.
3. It prints the pages built per module.
4. It merges the eight archives into one with `xcrun docc merge` (the DocC that ships with Xcode;
   nothing installed). The result is `.build/docs/ZTronDSP.doccarchive`, the documentation to publish.
   The build then fails on any link written as a path that names no page of that archive
   (`doc_audit.py links`).

**Before the change:** the first docbuild, before any catalog, printed 134 distinct warnings (each
twice):
- 130 "Parameter 'x' is missing documentation";
- 3 ambiguous links;
- 1 parameter documented that does not exist.

The list is `.build/m9-docs/docbuild-warnings-before.txt`. All were fixed in the comments.

**Decision: the merge and the link check.** The first build with the catalogs had no warnings. Even so,
the facade's archive documents every re-exported symbol, and its seven links to the modules
(`/documentation/ztrondspcore`, …) named no page of it. That was seen failing: `doc_audit.py links` on
that archive printed 7 links to no page. DocC also drops, without a word, a Topics group made of path
links.

The fix has two parts:
- the build merges the archives, and in the merged archive all seven links resolve;
- the landing page's topic groups are now symbol links, which resolve within the facade.

`test-docs.sh` covers both. A link to a module that was built passes. A seeded link to
`/documentation/ztrondspio`, a module without pages, fails with the page it is on. A merge that fails
fails the build. The archives of a build with a warning are not merged.

**What the final build prints at the end** (`.build/logs/m9-docs/gate-docs-build.log`, 19:41:51 to
19:42:21, exit 0):

```
docs: xcodebuild docbuild of ZTronDSP-Package (Debug) into .build/docs; the log is .build/docs/docbuild.log
docs: ZTronDSP: 3976 pages
docs: ZTronDSPAnalysis: 1028 pages
docs: ZTronDSPCore: 1638 pages
docs: ZTronDSPDesign: 970 pages
docs: ZTronDSPIO: 70 pages
docs: ZTronDSPMetal: 290 pages
docs: ZTronDSPTesting: 230 pages
docs: ZTronDSPUI: 7835 pages
docs: 8 archives, 16037 pages, no warning for the package's sources
docs: .build/docs/ZTronDSP.doccarchive: 16037 pages; 7 links written as a path, each to a page of the archive
```

xcodebuild's own log ends `** BUILD DOCUMENTATION SUCCEEDED **`, with 0 lines that contain `warning:`.
That log is kept as `.build/logs/m9-docs/docbuild-final.log`. `.build/docs` itself (795 MB) was
deleted afterwards, as brief 60 asks of large temporaries; `Scripts/docs.sh --build` makes it again.

Two page counts need a word:
- The facade's 3,976 pages are the symbols of the five modules it re-exports.
- UI's 7,835 pages are mostly the members its views inherit from SwiftUI's `View`, about 860 per view.

### 2.7 CI: gate 4 (item 2)

`Scripts/ci.sh` gate 4 runs two steps, on the same build:
- `Scripts/api-digest.sh --check`;
- `Scripts/docs.sh --audit`, "every public symbol documented with its threading contract (VIS-2)".

The gate is renamed "API digest and documentation", in `ci.sh` and in `.github/workflows/ci.yml`. There
is no tenth gate. `--build` is no gate: it is a step of the release checklist, which does not exist yet
(WP-906, brief 67; see §4).

`Scripts/tests/test-ci.sh` now checks four things:
- gate 4 runs `docs --audit` after the API digest;
- no gate runs `docs --build`;
- a failing `docs` stand-in fails gate 4 under its new name;
- in part 2, a copy with `public func seededBare() {}` appended to
  `Sources/ZTronDSPCore/Placeholder.swift` fails gate 4, and the failure is named by the audit with file
  and line.

**Seen failing.** The new `test-ci.sh` was run against the `ci.sh` of `e52d9b8`: 169 checks, 9 failed
(`.build/logs/m9-docs/test-ci-old-ci.log`). The nine failures were:
- the order of the gates;
- `docs --audit` not run;
- the gate's new name, missing twice from the report;
- a failing `docs` that did not fail gate 4, and the gate after it running;
- the three checks of the seeded bare function.

`ci.sh` was then restored; copies are in `.build/m9-docs/seen-failing/`. One check of an earlier run
passed without checking anything, because backticks inside double quotes became a command
substitution. It now uses single quotes, and the final run passes it for real: "… and is named, by the
audit of the documentation".

The owner may want the documentation audit, or even the documentation build, as part of gate 1, which
builds the package anyway. The brief keeps it in gate 4, beside the digest it reads with.

### 2.8 The order matrix covers every public stage (item 3)

**What it does.** `Scripts/order-matrix.sh --check` now reads the public stages from the API digests'
conformance lines (`Docs/API`, `--digests`): every public type whose conformances reach `StageValue`,
directly or through `PipelineStage`, `SequenceStage`, `Recipe`, `ContextDependentStep` and the others.
Protocols are excluded. It fails in four cases:
- a public stage with no line in `Tests/OrderMatrix/stages.txt` and none in
  `Tests/OrderMatrix/not-in-matrix.txt` (`Type | why`);
- a line of either file that names no public stage;
- a stage that has a line in both files;
- the matrix differing from what the compiler says, as before.

**Decision: the root is `StageValue`.** A literal rule of "conforms to `PipelineStage` or
`SequenceStage`" finds 43 types. It misses 11 step families (E-20), whose conformances go through
`StageValue` and the protocols that refine it, not through those two:
`Autocorrelation`, `ConstantQScale`, `Decibels`, `Emit`, `HarmonicPercussive`, `InverseDecibels`,
`Magnitude`, `MelScale`, `OnsetStrength`, `Power` and `SpectralCentroid`. The `StageValue` root finds
54: Design 17, Analysis 28, Core 9.

**What the comparison found** (seen failing: the new comparison on the `stages.txt` of `e52d9b8`, with
an empty left-out list, `.build/m9-docs/seen-failing/order-matrix/`). Nine public stages had no line,
all in the core: `ActivatedSequenceStage`, `ActivatedStage`, `Emit`, `EnvironmentReader`, `Group`,
`Measuring`, `Pipeline`, `SequenceChain` and `Tap`. Every stage of Design and Analysis already had its
lines, and no line was stale.
- **Added to the matrix: `Emit`**, with five lines, one per kind of sink:

  | Line | Accepted after |
  |---|---|
  | `Emit(to: HeatmapFeed())` | the 14 real-vector domains |
  | `Emit(to: WaveformFeed())` | the envelope |
  | `Emit(to: Binding<Float>.constant(0))` | novelty and scalar |
  | `Emit(to: Binding<[Float]>.constant([]))` | the 14 real-vector domains |
  | `Emit(to: FeatureStream<Chroma>())` | chroma |

  That is what O-11 and its ORD-4 messages say. No order rule turned out wrong.
- **Left out, with their reasons in `not-in-matrix.txt`:** the other eight are constructs of the core
  that process nothing and take their domains from what they hold: `.active(_:)`'s two wrappers,
  `EnvironmentReader`, `Group`, `Measuring`, `Pipeline` itself, `SequenceChain` and `Tap`. The stages
  they hold have their lines. So the core declares no processing stage (EXT-1), as the brief expects.

The matrix was regenerated: 57 lines on 21 domains, 142 cells accepted (it was 52 lines and 110 cells).
The generated fixtures pass: `compile-fixtures --build` gives 7 valid and 136 invalid fixtures, each
with its sentence. So does `OrderMatrixTests` in the facade tests.

**Tests.** `Scripts/tests/test-order-matrix.sh` has 36 checks, 0 failed
(`.build/logs/m9-docs/test-order-matrix-2.log`). Its fixture world has fixture digests and a fixture
left-out list. Each of these seeded cases fails, and the stage is named:
- a public stage with no line;
- a stage reached through a protocol that refines another (a recipe);
- a stage reached through a family protocol of its own module;
- a core wrapper with no line in the left-out list;
- a stale line in `stages.txt`;
- a stale line in the left-out list;
- a stage in both lists.

A left-out line without its reason is refused. The check that the package's committed matrix is
current passes.

## 3. Gates and tests

The gates of brief 60 ran on the final tree, in its order, one after the other, in one chain
(`.build/m9-docs/final-gates.sh`, 19:32:15 to 19:48:55). Each step's full output is
`.build/logs/m9-docs/gate-<step>.log`; the chain's summary is `.build/logs/m9-docs/final-gates.txt`.
Every step exited 0. The final line of each:

| Step | Time | Final line |
|---|---|---|
| `Scripts/xc.sh build` | 19:32:15–19:32:22 | `** TEST BUILD SUCCEEDED **` (`xc.sh` prints every `warning:` line; there was none) |
| the verifiers' scanners (§2.3) | 19:32:22–19:32:26 | as in §2.3 |
| `Scripts/lint-bans.sh` | 19:32:26–19:32:30 | `lint-bans: clean (parts 1, 2, 3, 4; 606 files)` |
| `Scripts/check-dependency-graph.sh` | 19:32:30–19:32:31 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `Scripts/api-digest.sh --check` | 19:32:31–19:33:18 | `api-digest: ZTronDSPUI references public symbols only`; its first line is `api-digest: 10 digests equal the built modules`: no API change |
| `Scripts/docs.sh --audit` | 19:33:18–19:33:19 | `docs: every public symbol is documented with its threading contract (VIS-2)` |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | 19:33:19–19:33:28 | `compile-fixtures: 7 valid fixtures compile, 136 invalid fixtures fail with their sentences` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | 19:33:28–19:33:33 | `order-matrix: 57 stages on 21 domains, 142 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | 19:33:33 | `golden: 197 files of 27 generators match the manifest` |
| `Scripts/check-function-effects.sh` | 19:33:33–19:34:33 | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | 19:34:33 | `ledger: 289 rows, consistent with §12 and §11` (before the row was set; again after it, below) |
| `Scripts/tests/run-all.sh` | 19:34:33–19:40:33 | `run-all: every self-test passed (837 checks in 14 suites, 2 skipped: see above)` |
| `Scripts/external-parity.sh` | 19:40:33–19:41:51 | `external-parity: passed` |
| `Scripts/docs.sh --build` | 19:41:51–19:42:21 | `docs: .build/docs/ZTronDSP.doccarchive: 16037 pages; 7 links written as a path, each to a page of the archive` |
| `Scripts/xc.sh test` (Debug) | 19:42:21–19:45:32 | `** TEST EXECUTE SUCCEEDED **`, after nine lines `Test run with … passed`: 2,090 tests |
| `ZTD_CONFIG=Release Scripts/xc.sh test` | 19:45:32–19:48:55 | `** TEST EXECUTE SUCCEEDED **`, after nine lines `Test run with … passed`: 2,090 tests |

`run-all.sh` ran 14 suites, among them `docs` 56 checks, `ci` 169, `order-matrix` 36, `api-digest`
68 and `external-parity` 152, each with 0 failed. Its two skips are the slow cases that it skips unless
asked (`--slow`): gate 1 with a real build and a seeded warning (`test-ci.sh`), and the parity tests on
the simulator with a seeded violation (`test-external-parity.sh`). `external-parity.sh` passed all
eight steps (rules, guide, build, test, fixtures, release, audits, speed); its known issues are the
ones it expects (the probe that counts an allocating stage, and the gain of CR-025 item 1).

**Test totals.** Debug and Release each ran 2,090 tests in nine runs, and every run passed
(`.build/logs/m9-docs/gate-test-debug.log`, `gate-test-release.log`):

| Run | Debug | Release | Baseline, both |
|---|---|---|---|
| ZTronDSPUI | 278 tests in 19 suites | 278 in 19 | 278 |
| ZTronDSP (the facade) | **11 tests in 4 suites** | **11 in 4** | 10 in 3 |
| ZTronDSPTesting | 55 in 8, with 3 known issues | 55 in 8, with 3 known issues | 55, with the same 3 |
| ZTronDSPMetal | 115 in 12 | 115 in 12 | 115 |
| ZTronDSPIO | 134 in 13 | 134 in 13 | 134 |
| ZTronDSPDesign | 336 in 41 | 336 in 41 | 336 |
| ZTronDSPCore | 511 in 60 | 511 in 60 | 511 |
| ZTronDSPAnalysis | 420 in 41 | 420 in 41 | 420 |
| CZTronDSP | 230 in 31 | 230 in 31 | 230 |
| **Total** | **2,090** | **2,090** | 2,089 |

The baseline is the run before any change (Debug 16:40:31 to 16:43:45, Release 16:43:45 to 16:46:01;
`.build/logs/m9-docs/baseline-debug.log`, `baseline-release.log`). The brief asks the totals to equal
those before; they are one more, because its item 2 asks for "a test that builds the same code" as the
landing page's examples. That test is
`LandingPageTests.theExampleIsOnePipelineInBothSpellingsThatCompilesAndRuns`
(`Tests/ZTronDSPTests/LandingPageTests.swift`), a new suite of one test in the facade's tests. It holds
the landing page's examples, and compiles and runs them (§2.6). No other test was added or removed.
`Tests/ZTronDSPTests/OrderMatrixGenerated.swift` is regenerated data, not a test: the existing
`OrderMatrixTests` now holds the compiler to 57 lines on 21 domains, 142 cells accepted, instead of 52
lines and 110 cells (§2.8).

**Coverage (COV-3).** Measured as gates 5 and 6 of `Scripts/ci.sh` measure it, after the chain: a Debug
build and test run with coverage on (`ZTD_XCARGS="-enableCodeCoverage YES"`, 19:49:12 to 19:57:23; the
same nine runs, 2,090 tests, passed), into a result bundle of its own; then `Scripts/coverage-gate.sh
--mode changed-files` on the 174 files of `git diff --name-only -- Sources`
(`.build/m9-docs/coverage-run.sh`; `.build/logs/m9-docs/cov-changed-files.log`). Of the 174 files:
- 9 are outside the denominator (ZTronDSPTesting and CZTronDSPTesting, COV-6);
- 16 hold no executable line: the nine C headers, the five `Order/OrderDiagnostics*.swift`,
  `DSP.swift` and `Bandwidth.swift`;
- 145 are at or above 97.50 %;
- 4 files of Design are below it, so the gate's changed-files mode exits 1. Their uncovered lines are
  named here, as brief 60 allows (`.build/logs/m9-docs/cov-uncovered.txt`):

| File | Covered | The uncovered lines |
|---|---|---|
| `Sources/ZTronDSPDesign/Systems/FIRSystem.swift` | 91.94 % (114 of 124) | 115, 125, 128, 133: the throws of resolving, for a boxed value that is not an FIR element, an element without finite taps, more taps than the maximum, and taps that convolve to a value that is not finite; 159–160: `replacingParameters(_:)` passing over a value that is not an element; 242–245: the internal `FIRRoots` of taps that are all zero |
| `Sources/ZTronDSPDesign/Systems/IIRSystem.swift` | 96.88 % (155 of 160) | 126, 136, 151: the throws of resolving, for a boxed value that is not an IIR element, an element that is not a finite digital system, and gains whose product is not finite; 242–243: `replacingParameters(_:)` passing over a value that is not an element |
| `Sources/ZTronDSPDesign/Stages/ResponseStages.swift` | 97.25 % (177 of 182) | 410: `HighPass.dependsOnSampleRate`; 821–823: `BandStop.zeroPoleGain(sampleRate:)`; 836: `BandStop.dependsOnSampleRate` |
| `Sources/ZTronDSPDesign/Stages/ResponseCore.swift` | 97.33 % (146 of 150) | 104, 109: the throws for a boxed design that is neither an FIR method nor a filter family; 125: a length or a slope given to an IIR family; 141: an order or a roll-off given to an FIR method |

The reason: in these four files this package changed comment lines only, and none of the lines above is
among them (`.build/m9-docs/uncovered.py` marks a line this work changed, and marks none). They are the
code of `e52d9b8`, which the same tests reach as before: the only test added is the landing page's. A
test for each would change the test totals that the brief fixes, so none is added here; a package that
changes the code of these files closes them under COV-3. COV-2 holds: `coverage-gate: aggregate 99.53 %
(25711 of 25832 lines), needs 97.50 %: ok`, and per target CZTronDSP 99.70 %, Core 99.69 %, Design
98.70 %, Metal 100.00 %, Analysis 99.78 %, IO 99.48 %, UI 99.64 %, with 15 lines marked
`coverage:ignore` (0.06 %); `coverage-gate: pass (aggregate, per-target)`
(`.build/logs/m9-docs/cov-aggregate.log`). The result bundle was deleted afterwards.

**Ledger.** After the chain, at 19:49:
`python3 ZTronDSP-handoff/tools/ledger_set.py Docs/Process/ledger.md 'WP-901b' Status=Verifying
Implementer='Implementer M9-docs (agent)'` printed `set WP-901b {'Status': 'Verifying', 'Implementer':
'Implementer M9-docs (agent)'}`, and `Scripts/ledger.sh --check` then printed
`ledger: 289 rows, consistent with §12 and §11` (exit 0). The row was `Blocked-on-deps`, without an
implementer.

## 4. Open

- **The release checklist does not exist yet.** WP-906 (brief 67) is to name `Scripts/docs.sh --build`
  as a step of it. Until then, `--build` runs only when called.
- **Gate 1 or gate 4.** The owner may want the documentation audit, or the documentation build, in gate
  1 (§2.7).
- **The per-member reading of the M4 scanners** (`v-m4a-b/VerifierB/vis2_scan.py`,
  `v-m4b-b/VerifierB/vis2.py`). They ask every member's own comment to name a context. 1,322 and 1,400
  members do not, because their type or their requirement states it. CR-033 asks the owner to settle
  VIS-2's reading. If the owner wants a context word in every member's comment, that is a mechanical
  pass that the brief's "no boilerplate" rule ruled out here.
- **The 15 `#if` false positives in `Vector.swift`**, and the 50 attribute false positives of M1-B's
  scanner (§2.3). Nothing is missing. A verifier using those scanners will see the lines, and this
  report explains them.
- **The brief's path `v-m5a-b/VerifierB/vis2.py` does not exist.** Both existing `vis2.py` scanners were
  run instead.
- **Found, not fixed:** `Golden.swift:241` (`missingCase` carries the generator's name in `file`) and
  `Closeness.swift:187` and `:203` (`expectClose` evaluates `comment` on every call), in §2.2.
- **COV-3 on four files of Design.** `FIRSystem.swift`, `IIRSystem.swift`, `ResponseStages.swift` and
  `ResponseCore.swift` are below 97.50 % (91.94 % to 97.33 %). This package changed only their comments;
  their uncovered lines are named, with the reason, in §3, and no test was added for them.
- **Sentences that rest on sizes.** "Allocates only for a strategy larger than three words, which the
  stock one is not" (§2.2) is true of the stock strategies as they are stored today. Nothing checks it:
  a stored property added to a stock backend could make creation allocate and the sentence false. A
  test per stock strategy that its `MemoryLayout` size is at most three words would hold the sentences
  to the code. It is not added here, because the brief fixes the test totals (§3).
- **Other sessions' simulators.** Three simulators not named `ztdsp-*` (`ztron-parity-17.5-iPhone-15`,
  `ztron-parity-18.6-iPhone-15`, `ztron-parity-27.0-iPhone-15`) were already booted when this work
  began. This work did not touch them; by 19:32 they had been shut down, not by this work
  (`Scripts/external-parity.sh` runs on the simulator of `Scripts/xc.sh`, ztdsp-27). ztdsp-27 is the
  one simulator booted, and stays booted.

## 5. Change requests and decisions asked of the owner

- **CR-033, `Proposed`:** how VIS-2 applies to members, protocol witnesses and unavailable diagnostic
  overloads (§2.5). The tree passes both readings, so nothing waits on it. Its decision also settles
  the M4 scanners' item in §4.
- **Decisions taken, and open to the owner:**
  - the order matrix's stage set has `StageValue` as its root, and `Emit` is in the matrix (§2.8);
  - the documentation build merges the eight archives and checks the links of the merged one (§2.6);
  - gate 4 is named "API digest and documentation" (§2.7);
  - the landing page's topic groups are symbol links (§2.6).
