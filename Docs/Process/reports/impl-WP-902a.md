# WP-902a — implementer's report (coverage closure, part a: `CZTronDSP`)

| Field | Value |
|---|---|
| Package | WP-902a, the first part of WP-902 (split by CR-034, §11.7): every file of `CZTronDSP` at 97.5 % or more, or named with its reason; lenses T, A |
| Implementer | Implementer M9-coverage (agent), brief 66 with the common rules of brief 60 |
| Date | 2026-11-22, from 03:56; times Europe/Rome |
| Tree | The main tree, branch `handover-chain`, on commit `74d44f6` ("Checkpoint: m9-export — check passed (round 0)"), clean when this work began. Everything this work did is unstaged or untracked; it committed nothing and added nothing to the index |
| Ledger | WP-902 `Retired`; WP-902a `Verifying`, implementer `Implementer M9-coverage (agent)` |
| Change request | CR-034, the split (`Proposed`) |

This is the first of the four part reports, so it also holds the measurement that every part rests on
(brief 66, design step 1): the whole run, the denominator, and the table of every production file. The
summary of the package as a whole, with the gates and the tests, is `impl-WP-902.md`.

## 1. The measurement (for all four parts)

### How it was measured

The specified path (COV-1): one instrumented build and one run of every test target in Debug on the
simulator `ztdsp-27` (iOS 27.0), read with `xccov` by the gate. These are the commands gate 5 of
`Scripts/ci.sh` runs for its result bundle, with its derived data `.build/ci`:

```
ZTD_DERIVED=$PWD/.build/ci ZTD_XCARGS="-enableCodeCoverage YES" Scripts/xc.sh build
ZTD_DERIVED=$PWD/.build/ci ZTD_CONFIG=Debug \
  ZTD_XCARGS="-enableCodeCoverage YES -resultBundlePath .build/ci-results/Debug.xcresult" Scripts/xc.sh test-only
TMPDIR=$PWD/.build/tmp/m9-coverage Scripts/coverage-gate.sh --xcresult .build/ci-results/Debug.xcresult \
  --mode aggregate --mode per-target
```

`xccov` listed every production file of the main tree (the work-around of `ZTronDSP-handoff/tools/coverage/`
for a checkout under `/private/tmp` was not needed; it served only as the cross-check below). Per-file
figures were read from `xcrun xccov view --archive --json` with the gate's own code (`Scripts/lib/coverage_gate.py`:
the same merge of the test bundles and the same handling of `coverage:ignore` marks).

**Run 1 — before any change** (tree = `74d44f6`), 2026-11-22 04:00–04:04: 2 118 tests passed (UI 278, facade 20,
Testing 55 with its 3 known issues, Metal 118, IO 134, Design 339, Core 511, Analysis 431, C 232), `** TEST EXECUTE
SUCCEEDED **`. The gate printed:

```
coverage-gate: 15 lines marked coverage:ignore (0.06 % of the production lines, below 0.50 %)
coverage-gate: aggregate      99.55 % (25716 of 25833 lines), needs 97.50 %: ok
coverage-gate: CZTronDSP        99.70 % (2344 of 2351 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPCore     99.69 % (8415 of 8441 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPDesign   98.70 % (4703 of 4765 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPMetal    100.00 % (1445 of 1445 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPAnalysis 99.85 % (5418 of 5426 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPIO       99.48 % (1153 of 1159 lines), needs 95.00 %: ok
coverage-gate: ZTronDSPUI       99.64 % (2238 of 2246 lines), needs 95.00 %: ok
coverage-gate: ZTronDSP         no executable lines (0 of 0 lines), needs 95.00 %: ok
coverage-gate: pass (aggregate, per-target)
```

So COV-2 held before the closure, and no target is below 95 %. Seven files of four targets are below
97.5 %: they decide the split (CR-034).

**Run 2 — the fresh run after the closure** (the same commands, the tree with this part's one change),
2026-11-22 04:10–04:15: the same 2 118 tests passed; the gate's lines are in section 3 of `impl-WP-902.md`.
The only difference from run 1 is `CZTronDSP`: 99.79 % (2 344 of 2 349), `ztd_thread.c` 100.00 % (62 of 62),
17 lines marked instead of 15.

### The denominator (COV-1, COV-6)

Checked on run 1, file by file, against what is on disk (a scratch script that classifies every path of
the per-line report with the gate's `relative_path` and `is_production`, then walks `Sources/`):

- **In the denominator**: the production targets of §4.2, Swift **and C**: `CZTronDSP` 20 files (19 `.c` and
  `ztd_sink_node.m`), `ZTronDSPCore` 78, `ZTronDSPDesign` 44, `ZTronDSPMetal` 17 (its `.metal` shaders are
  excluded by COV-4 a: see `impl-WP-902.md`, section 2.4), `ZTronDSPAnalysis` 63, `ZTronDSPIO` 13, `ZTronDSPUI` 30;
  265 files.
- **Outside it, as COV-6 says**: `Sources/ZTronDSPTesting` (8 files in the report, excluded by name, as is
  `CZTronDSPTesting`), every file under `Tests/` (203 in the report, the benchmarks among them:
  `Tests/ZTronDSPTestingTests/BenchmarkTests.swift`, the suites of `Scripts/ci/benchmark-filters.txt`).
  `Examples/ZTronDSPGallery` and `ExternalParity/` are projects of their own: nothing of either is in the
  package's result bundle, and a path under them is `Examples/…` or `ExternalParity/…` to the gate, which
  counts only `Sources/<production target>/…` (`ExternalParity/Sources/` holds `CExtensionGuide`,
  `CExternalKernels`, `ExtensionGuide`, `ExtensionGuideUI`, `ExternalStages`: no production name).
- **Production files that `xccov` does not list** (22), and why none hides code that does not run:
  - `ZTronDSPCore/DSP.swift`, `ZTronDSPDesign/Equalizers/Bandwidth.swift`, `ZTronDSPMetal/Color/ColorMapTables.swift`,
    `ZTronDSP/ZTronDSP.swift`: no function body (the gate's own `has_bodies` says so).
  - `ZTronDSPAnalysis/Order/OrderDiagnostics.swift`, `…+ConstantQ.swift`, `…+Correlation.swift`, `…+Rhythm.swift`,
    `…+Separation.swift`: 56 functions, every one `@available(*, unavailable, message:)` (the ORD-4 diagnostics),
    so never compiled to code.
  - The 13 C headers. Four of them hold executable lines: `ztd_internal.h` (six `static inline` functions),
    `include/ztd_kernel.h` (`ztd_kernel_is_null`), `include/ztd_base.h` and `include/ztd_sink_node.h` (macro
    expansions). `xccov` reports no header at all. The cross-check below shows that every one of their lines
    runs.

**Cross-check with llvm-cov** (the helpers of `ZTronDSP-handoff/tools/coverage/`, `cov.py export` and `convert`,
on the profile of run 1 in `.build/ci/Build/ProfileData`): llvm-cov sees the same production files plus the
four headers, and in its per-line view (all copies of a header's inline function merged) the headers have
0 lines not run (37 + 5 + 2 + 1 executable lines). Compared line by line with `xccov`, the two disagree on 24
lines of production files, and on every one of them `xccov` says "not run" where llvm-cov says "run"
(segment ends after a `return`, mostly): `xccov` is never the more lenient of the two. llvm-cov finds no
production file below 97.5 % that `xccov` does not also find.

### Every production file, run 1

| Target | Files | Executable lines | Covered | Line coverage | Files below 97.5 % |
|---|---:|---:|---:|---:|---:|
| `CZTronDSP` | 20 | 2351 | 2344 | 99.70 % | 1 |
| `ZTronDSPCore` | 78 | 8441 | 8415 | 99.69 % | 0 |
| `ZTronDSPDesign` | 44 | 4765 | 4703 | 98.70 % | 5 |
| `ZTronDSPMetal` | 17 | 1445 | 1445 | 100.00 % | 0 |
| `ZTronDSPAnalysis` | 63 | 5426 | 5418 | 99.85 % | 1 |
| `ZTronDSPIO` | 13 | 1159 | 1153 | 99.48 % | 0 |
| `ZTronDSPUI` | 30 | 2246 | 2238 | 99.64 % | 1 |
| `ZTronDSP` | 0 | 0 | 0 | no executable lines | 0 |
| **aggregate** | 265 | 25833 | 25716 | 99.55 % | |

| File | Executable lines | Covered | Line coverage | Lines not run |
|---|---:|---:|---:|---|
| `Sources/CZTronDSP/ztd_allocation.c` | 16 | 16 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_alpha_beta.c` | 75 | 75 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_atomic.c` | 27 | 27 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_base.c` | 35 | 35 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_biquad.c` | 258 | 258 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_biquad_double.c` | 65 | 65 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_engine.c` | 175 | 175 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_fir.c` | 107 | 107 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_gain.c` | 128 | 128 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_history.c` | 49 | 49 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_lane_exchange.c` | 44 | 44 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_partitioned.c` | 225 | 225 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_plan.c` | 321 | 317 | 98.75 % | 287–288, 359, 378 |
| `Sources/CZTronDSP/ztd_queue.c` | 145 | 145 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_rate.c` | 211 | 211 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_ring.c` | 242 | 242 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_sink_node.m` | 48 | 47 | 97.92 % | 61 |
| `Sources/CZTronDSP/ztd_sink_tap.c` | 80 | 80 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_support.c` | 36 | 36 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_thread.c` | 64 | 62 | 96.88 % **< 97.5 %** | 45–46 |
| `Sources/ZTronDSPCore/Background/BackgroundWork.swift` | 33 | 33 | 100.00 % |  |
| `Sources/ZTronDSPCore/Bindings/ActivationSource.swift` | 24 | 24 | 100.00 % |  |
| `Sources/ZTronDSPCore/Bindings/BindingPump.swift` | 200 | 197 | 98.50 % | 165–167 |
| `Sources/ZTronDSPCore/Bindings/ResultBindings.swift` | 34 | 34 | 100.00 % |  |
| `Sources/ZTronDSPCore/Compiler/IR.swift` | 145 | 145 | 100.00 % |  |
| `Sources/ZTronDSPCore/Compiler/KernelFactory.swift` | 82 | 82 | 100.00 % |  |
| `Sources/ZTronDSPCore/Compiler/KernelSpec.swift` | 142 | 142 | 100.00 % |  |
| `Sources/ZTronDSPCore/Compiler/LoweringContext.swift` | 72 | 72 | 100.00 % |  |
| `Sources/ZTronDSPCore/Compiler/PlanCompiler.swift` | 402 | 398 | 99.00 % | 336, 338, 506–507 |
| `Sources/ZTronDSPCore/Compiler/StockKernels.swift` | 82 | 81 | 98.78 % | 88 |
| `Sources/ZTronDSPCore/Domains/Frames.swift` | 89 | 89 | 100.00 % |  |
| `Sources/ZTronDSPCore/Domains/SignalDomain.swift` | 76 | 76 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/ControlContext.swift` | 75 | 75 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/DSPEngine.swift` | 44 | 44 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/EngineCore.swift` | 1102 | 1096 | 99.46 % | 340–341, 782, 1283–1285 |
| `Sources/ZTronDSPCore/Engine/ExecutionPlan.swift` | 576 | 576 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/Handoff.swift` | 63 | 63 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/OfflineRunner.swift` | 147 | 146 | 99.32 % | 138 |
| `Sources/ZTronDSPCore/Engine/Run/HubRunner.swift` | 137 | 137 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/Run/PlanRunner.swift` | 208 | 208 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/Run/PlanStructures.swift` | 237 | 237 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/Run/ProcessorKernel.swift` | 56 | 56 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/Run/SessionRunner.swift` | 241 | 241 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/RunnerThread.swift` | 131 | 131 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/SessionCore.swift` | 82 | 82 | 100.00 % |  |
| `Sources/ZTronDSPCore/Engine/SourceHub.swift` | 26 | 26 | 100.00 % |  |
| `Sources/ZTronDSPCore/Environment/DSPEnvironment.swift` | 153 | 153 | 100.00 % |  |
| `Sources/ZTronDSPCore/Errors/DSPError.swift` | 69 | 69 | 100.00 % |  |
| `Sources/ZTronDSPCore/Errors/StagePath.swift` | 16 | 16 | 100.00 % |  |
| `Sources/ZTronDSPCore/Export/MATLABScript.swift` | 123 | 123 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/ColumnStore.swift` | 268 | 268 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/FeatureCallback.swift` | 8 | 8 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/FeatureFrame.swift` | 36 | 36 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/FeatureSink.swift` | 63 | 63 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/FeatureStream.swift` | 214 | 210 | 98.13 % | 257–259, 264 |
| `Sources/ZTronDSPCore/Feeds/FeedAxis.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/FeedSnapshot.swift` | 48 | 48 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/HeatmapFeed.swift` | 51 | 51 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/ResultSlot.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPCore/Feeds/WaveformFeed.swift` | 55 | 55 | 100.00 % |  |
| `Sources/ZTronDSPCore/Math/Complex.swift` | 78 | 78 | 100.00 % |  |
| `Sources/ZTronDSPCore/Nodes/AnalysisNode.swift` | 55 | 55 | 100.00 % |  |
| `Sources/ZTronDSPCore/Parameters/ParameterVector.swift` | 32 | 32 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/DomainRule.swift` | 23 | 23 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/DynamicPipeline.swift` | 54 | 54 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/Pipeline.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/PipelineBuilder.swift` | 56 | 56 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/StageDescription.swift` | 81 | 81 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/StageValue.swift` | 46 | 46 | 100.00 % |  |
| `Sources/ZTronDSPCore/Pipeline/Structure.swift` | 125 | 122 | 97.60 % | 413–415 |
| `Sources/ZTronDSPCore/Signal/AudioBlock.swift` | 94 | 94 | 100.00 % |  |
| `Sources/ZTronDSPCore/Signal/SignalFormat.swift` | 16 | 16 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/BufferSource.swift` | 44 | 44 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/GeneratorSource.swift` | 251 | 251 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/ProcessedSource.swift` | 31 | 31 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/RingWriter.swift` | 32 | 32 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/SampleSource.swift` | 15 | 15 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/ScriptedSource.swift` | 110 | 110 | 100.00 % |  |
| `Sources/ZTronDSPCore/Sources/SourceAdapter.swift` | 142 | 142 | 100.00 % |  |
| `Sources/ZTronDSPCore/Support/AnyStrategy.swift` | 17 | 17 | 100.00 % |  |
| `Sources/ZTronDSPCore/Support/AtomicCells.swift` | 15 | 15 | 100.00 % |  |
| `Sources/ZTronDSPCore/Support/FrameCount.swift` | 14 | 14 | 100.00 % |  |
| `Sources/ZTronDSPCore/Support/UnfairLock.swift` | 26 | 26 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/AlignedBuffer.swift` | 55 | 54 | 98.18 % | 43 |
| `Sources/ZTronDSPCore/Toolkit/HistoryBuffer.swift` | 51 | 51 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/Implementation.swift` | 51 | 51 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/MedianNetwork.swift` | 59 | 59 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/OverlapAdder.swift` | 53 | 53 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/Padding.swift` | 50 | 50 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/Ramp.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/RateChange.swift` | 49 | 49 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/StageValidation.swift` | 56 | 55 | 98.21 % | 40 |
| `Sources/ZTronDSPCore/Toolkit/Vector.swift` | 326 | 326 | 100.00 % |  |
| `Sources/ZTronDSPCore/Toolkit/Window.swift` | 156 | 155 | 99.36 % | 258 |
| `Sources/ZTronDSPCore/Units/Amplification.swift` | 147 | 147 | 100.00 % |  |
| `Sources/ZTronDSPCore/Units/Frequency.swift` | 110 | 109 | 99.09 % | 89 |
| `Sources/ZTronDSPCore/Units/MelFormula.swift` | 32 | 32 | 100.00 % |  |
| `Sources/ZTronDSPCore/Units/RollOff.swift` | 69 | 69 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Equalizers/EqualizerDesign.swift` | 148 | 147 | 99.32 % | 90 |
| `Sources/ZTronDSPDesign/Equalizers/MatchedPeakDesign.swift` | 201 | 191 | 95.02 % **< 97.5 %** | 84, 105, 113, 133–135, 159, 217–219 |
| `Sources/ZTronDSPDesign/FIR/FIRDesign.swift` | 188 | 186 | 98.94 % | 165, 248 |
| `Sources/ZTronDSPDesign/FIR/FIRDesignMethod.swift` | 144 | 143 | 99.31 % | 153 |
| `Sources/ZTronDSPDesign/FIR/FIRMath.swift` | 97 | 95 | 97.94 % | 86, 101 |
| `Sources/ZTronDSPDesign/FIR/LeastSquaresFIR.swift` | 106 | 105 | 99.06 % | 135 |
| `Sources/ZTronDSPDesign/IIR/FilterFamily.swift` | 53 | 53 | 100.00 % |  |
| `Sources/ZTronDSPDesign/IIR/FilterOrderStrategy.swift` | 205 | 203 | 99.02 % | 126, 135 |
| `Sources/ZTronDSPDesign/IIR/FilterResponse.swift` | 38 | 38 | 100.00 % |  |
| `Sources/ZTronDSPDesign/IIR/IIRDesign.swift` | 70 | 70 | 100.00 % |  |
| `Sources/ZTronDSPDesign/LinearAlgebra/LAPACK+LeastSquares.swift` | 97 | 97 | 100.00 % |  |
| `Sources/ZTronDSPDesign/LinearAlgebra/LAPACK.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/BoundedMinimizer.swift` | 77 | 77 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/ConjugatePairs.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/DoubleDouble.swift` | 76 | 76 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/Polynomial.swift` | 71 | 71 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/PolynomialRootFinder.swift` | 114 | 114 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Math/QuadraticRoots.swift` | 31 | 31 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Prototypes/AnalogPrototype.swift` | 189 | 187 | 98.94 % | 137, 228 |
| `Sources/ZTronDSPDesign/Prototypes/BesselPolynomial.swift` | 86 | 86 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Prototypes/EllipticFunctions.swift` | 110 | 110 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Smoothing/SavitzkyGolayDesign.swift` | 129 | 127 | 98.45 % | 203, 214 |
| `Sources/ZTronDSPDesign/Stages/Convolve.swift` | 41 | 41 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/EqualizerStages.swift` | 150 | 150 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/Filter.swift` | 31 | 31 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/Fluent.swift` | 117 | 117 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/Gain.swift` | 45 | 45 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/RateStages.swift` | 71 | 71 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Stages/ResponseCore.swift` | 150 | 146 | 97.33 % **< 97.5 %** | 104, 109, 125, 141 |
| `Sources/ZTronDSPDesign/Stages/ResponseStages.swift` | 182 | 177 | 97.25 % **< 97.5 %** | 410, 821–823, 836 |
| `Sources/ZTronDSPDesign/Stages/SmoothingStages.swift` | 49 | 49 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/FIRSystem.swift` | 124 | 114 | 91.94 % **< 97.5 %** | 115, 125, 128, 133, 159–160, 242–245 |
| `Sources/ZTronDSPDesign/Systems/IIRSystem.swift` | 160 | 155 | 96.88 % **< 97.5 %** | 126, 136, 151, 242–243 |
| `Sources/ZTronDSPDesign/Systems/LTISystem.swift` | 115 | 115 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/Realization.swift` | 165 | 162 | 98.18 % | 191, 245, 271 |
| `Sources/ZTronDSPDesign/Systems/SecondOrderSections.swift` | 130 | 130 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/SectionPairing.swift` | 83 | 82 | 98.80 % | 120 |
| `Sources/ZTronDSPDesign/Systems/SystemAnalysis+MATLAB.swift` | 82 | 82 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Systems/SystemAnalysis.swift` | 234 | 230 | 98.29 % | 306, 323, 326, 475 |
| `Sources/ZTronDSPDesign/Systems/SystemElements.swift` | 217 | 212 | 97.70 % | 34, 358, 393, 510, 526 |
| `Sources/ZTronDSPDesign/Systems/TransferFunction.swift` | 72 | 71 | 98.61 % | 74 |
| `Sources/ZTronDSPDesign/Systems/ZeroPoleGain.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPDesign/Transformations/Bilinear.swift` | 93 | 92 | 98.92 % | 130 |
| `Sources/ZTronDSPDesign/Transformations/FrequencyTransformation.swift` | 74 | 74 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Calibration/Calibration.swift` | 79 | 79 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Calibration/CrossoverMeasurement.swift` | 106 | 106 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Calibration/StockCandidates.swift` | 123 | 123 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Color/ColorMap.swift` | 91 | 91 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Compute/MetalMedianFilter.swift` | 54 | 54 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Context/MetalContext.swift` | 144 | 144 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Heatmap/HeatmapPass.swift` | 58 | 58 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Heatmap/HeatmapRenderer.swift` | 165 | 165 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Heatmap/HeatmapTexture.swift` | 68 | 68 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Images/OffscreenTarget.swift` | 48 | 48 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Images/PixelImage.swift` | 75 | 75 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Rendering/FrequencyScale.swift` | 68 | 68 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Rendering/LevelLayout.swift` | 19 | 19 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Rendering/RenderProbe.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Snapshot/SnapshotImage.swift` | 71 | 71 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Waveform/EnvelopeTexture.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPMetal/Waveform/WaveformRenderer.swift` | 139 | 139 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Calibration/AnalysisCalibration.swift` | 180 | 180 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQGeometry.swift` | 78 | 78 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQKernel.swift` | 219 | 218 | 99.54 % | 114 |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQProjection.swift` | 52 | 50 | 96.15 % **< 97.5 %** | 41, 44 |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQSchedule.swift` | 56 | 56 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/ConstantQ/ConstantQStrategy.swift` | 45 | 45 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Correlation/Convolution.swift` | 139 | 137 | 98.56 % | 103, 214 |
| `Sources/ZTronDSPAnalysis/Correlation/Correlation.swift` | 86 | 86 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Export/FrameExports.swift` | 146 | 146 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/DecimateInversion.swift` | 77 | 77 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/InversionReport.swift` | 123 | 123 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/RateInversions.swift` | 102 | 102 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Inversion/StageInversions.swift` | 195 | 195 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Mel/MelFilterBank.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/AutocorrelationNode.swift` | 86 | 86 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/CepstralCoefficientNodes.swift` | 49 | 49 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/CepstrumNodes.swift` | 181 | 181 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/ChromaNodes.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/ComplexPackingNode.swift` | 15 | 15 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/ConstantQNodes.swift` | 240 | 238 | 99.17 % | 265, 296 |
| `Sources/ZTronDSPAnalysis/Nodes/ConstantQScaleNodes.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/Framer.swift` | 101 | 101 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/HarmonicPercussiveNode.swift` | 118 | 118 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/InverseSTFTNode.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/LevelAndWaveformNodes.swift` | 110 | 110 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/MedianKernels.swift` | 100 | 100 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/MelNodes.swift` | 95 | 95 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/OnsetStrengthNode.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/STFTNode.swift` | 66 | 66 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/SpectralCentroidNode.swift` | 36 | 36 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/SpectralValueNode.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/TempogramNodes.swift` | 142 | 142 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/TransformPlans.swift` | 96 | 96 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Nodes/WienerKhinchin.swift` | 35 | 35 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Recipes/ChromaRecipes.swift` | 32 | 32 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Recipes/HPSS.swift` | 20 | 20 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Recipes/Recipes.swift` | 61 | 61 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Separation/MaskStrategy.swift` | 51 | 51 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Separation/MedianStrategy.swift` | 115 | 115 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Separation/OfflineSeparation.swift` | 61 | 61 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Autocorrelation.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/CepstralCoefficients.swift` | 59 | 59 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Cepstrum.swift` | 160 | 160 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/ChromaFold.swift` | 79 | 79 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/ConstantQ.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/ConstantQScale.swift` | 80 | 79 | 98.75 % | 99 |
| `Sources/ZTronDSPAnalysis/Steps/FramingSupport.swift` | 48 | 48 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/HarmonicPercussive.swift` | 88 | 88 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/InverseSTFT.swift` | 67 | 67 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Level.swift` | 48 | 48 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/MelScale.swift` | 61 | 61 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/OnsetStrength.swift` | 35 | 35 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/STFT.swift` | 55 | 55 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/SpectralCentroid.swift` | 62 | 62 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/SpectralValues.swift` | 93 | 93 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Tempogram.swift` | 56 | 56 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Steps/Waveform.swift` | 27 | 27 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Transform/DFT.swift` | 30 | 30 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Transform/FFTBackend.swift` | 23 | 23 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Transform/FrameAlignment.swift` | 37 | 37 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Windows/WindowAnalysis.swift` | 397 | 397 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Windows/WindowAnalysisExport.swift` | 44 | 44 | 100.00 % |  |
| `Sources/ZTronDSPAnalysis/Windows/WindowDiagnostics.swift` | 47 | 47 | 100.00 % |  |
| `Sources/ZTronDSPIO/File/FileReader.swift` | 110 | 108 | 98.18 % | 49, 135 |
| `Sources/ZTronDSPIO/File/FileSource.swift` | 111 | 111 | 100.00 % |  |
| `Sources/ZTronDSPIO/Input/AudioInput.swift` | 19 | 19 | 100.00 % |  |
| `Sources/ZTronDSPIO/Input/HardwareInputSource.swift` | 325 | 325 | 100.00 % |  |
| `Sources/ZTronDSPIO/Input/InputCapturing.swift` | 111 | 109 | 98.20 % | 142, 171 |
| `Sources/ZTronDSPIO/Session/AudioSessionControlling.swift` | 52 | 51 | 98.08 % | 98 |
| `Sources/ZTronDSPIO/Session/AudioSessionPolicy.swift` | 90 | 90 | 100.00 % |  |
| `Sources/ZTronDSPIO/Session/MicrophoneAuthorizing.swift` | 49 | 48 | 97.96 % | 82 |
| `Sources/ZTronDSPIO/Support/Guarded.swift` | 20 | 20 | 100.00 % |  |
| `Sources/ZTronDSPIO/Support/PacingClock.swift` | 26 | 26 | 100.00 % |  |
| `Sources/ZTronDSPIO/Tap/BurstBuffer.swift` | 32 | 32 | 100.00 % |  |
| `Sources/ZTronDSPIO/Tap/EngineNodeTapSource.swift` | 171 | 171 | 100.00 % |  |
| `Sources/ZTronDSPIO/Tap/NodeTapping.swift` | 43 | 43 | 100.00 % |  |
| `Sources/ZTronDSPUI/Analysis/AnalysisEnvironment.swift` | 6 | 6 | 100.00 % |  |
| `Sources/ZTronDSPUI/Analysis/AnalysisModifiers.swift` | 15 | 15 | 100.00 % |  |
| `Sources/ZTronDSPUI/Analysis/SourceRecipes.swift` | 33 | 33 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/AppearanceEnvironment.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/AppearanceModifiers.swift` | 39 | 39 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/FeedShape.swift` | 36 | 36 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/RowLayout.swift` | 119 | 119 | 100.00 % |  |
| `Sources/ZTronDSPUI/Appearance/SurfaceAppearance.swift` | 124 | 124 | 100.00 % |  |
| `Sources/ZTronDSPUI/Axes/AxisTicks.swift` | 88 | 88 | 100.00 % |  |
| `Sources/ZTronDSPUI/Axes/AxisViews.swift` | 131 | 131 | 100.00 % |  |
| `Sources/ZTronDSPUI/Axes/FeedShapeWatcher.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPUI/Bridge/MetalViewRepresentable.swift` | 46 | 46 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/HeatmapSurface.swift` | 67 | 67 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/HeatmapViews.swift` | 54 | 54 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/SourceFedSurface.swift` | 60 | 60 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/SurfaceHost.swift` | 52 | 52 | 100.00 % |  |
| `Sources/ZTronDSPUI/Components/WaveformView.swift` | 64 | 64 | 100.00 % |  |
| `Sources/ZTronDSPUI/Environment/DSPEnvironmentBridge.swift` | 50 | 50 | 100.00 % |  |
| `Sources/ZTronDSPUI/Hosting/AnimatableParameters.swift` | 42 | 42 | 100.00 % |  |
| `Sources/ZTronDSPUI/Hosting/PipelineHost.swift` | 185 | 185 | 100.00 % |  |
| `Sources/ZTronDSPUI/Pinch/ComponentPinch.swift` | 46 | 46 | 100.00 % |  |
| `Sources/ZTronDSPUI/Pinch/PinchGestureModifier.swift` | 112 | 104 | 92.86 % **< 97.5 %** | 95–96, 215–217, 225–227 |
| `Sources/ZTronDSPUI/Pinch/PinchScaling.swift` | 97 | 97 | 100.00 % |  |
| `Sources/ZTronDSPUI/Pinch/PinchTracker.swift` | 104 | 104 | 100.00 % |  |
| `Sources/ZTronDSPUI/Scheduling/FrameClock.swift` | 26 | 26 | 100.00 % |  |
| `Sources/ZTronDSPUI/Scheduling/FrameScheduler.swift` | 76 | 76 | 100.00 % |  |
| `Sources/ZTronDSPUI/Scheduling/TurnEnd.swift` | 38 | 38 | 100.00 % |  |
| `Sources/ZTronDSPUI/Surface/MetalSurface.swift` | 38 | 38 | 100.00 % |  |
| `Sources/ZTronDSPUI/Surface/SurfaceCoordinator.swift` | 300 | 300 | 100.00 % |  |
| `Sources/ZTronDSPUI/Surface/SurfaceRenderer.swift` | 104 | 104 | 100.00 % |  |

Lines are `xccov`'s executable lines; "Lines not run" leaves out the 15 lines that the marks of COV-4 b
already excused in run 1 (in `CepstralCoefficientNodes.swift`, `LevelAndWaveformNodes.swift`, `TransformPlans.swift`,
`FramingSupport.swift`, `ConstantQKernel.swift`, `FileReader.swift`, `AudioSessionControlling.swift`).

## 2. Part a: `CZTronDSP`

**Before**: 99.70 % (2 344 of 2 351 lines). One file below 97.5 %: `Sources/CZTronDSP/ztd_thread.c`, 96.88 %
(62 of 64), lines 45–46. No finding of a verification wave names the file (`grep ztd_thread` over
`ZTronDSP-handoff/digests/wave-*.md`: nothing); `Docs/Process/reports/impl-integration-2026-11-21.md` records the
same two lines as open.

**The lines**: the refusal branch of `ztd_thread_base_priority`, the helper that reads the calling thread's
base priority before its first time-constraint policy (WP-226, RT-9):

```c
    if (thread_info(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
```

`thread_info` refuses a thread that is gone (`KERN_TERMINATED`, an invalid port), a flavour it does not know,
or a count too small for the flavour (`KERN_INVALID_ARGUMENT`). Here the thread is the caller itself, alive by
definition; the flavour is `THREAD_EXTENDED_INFO`; the count is `THREAD_EXTENDED_INFO_COUNT`, set the line before.
No argument of any public function reaches this call with anything else, so no input reaches the refusal: in
run 2 the function ran 492 times and the two lines never. It is a defensive branch of COV-4 b, not dead code
(the system call has an error return, and −1 is the value the caller is built to receive).

**What changed**: one line, a mark of its own above the `if` (the gate's mark covers that line and the block
down to its brace, and excuses the lines of it that do not run):

```c
    // coverage:ignore(the kernel refuses a thread that is gone, a flavour it does not know or a short count; the calling thread asking with its own count is none of these)
```

It is a `//` comment, the first in the C layer, because the gate's pattern is `//\s*coverage:ignore(…)`; C11
has `//` comments, and the build with warnings as errors and the function-effects check compile it (section 3
of `impl-WP-902.md`). No code changed.

**Tests added**: none. A test cannot make the kernel refuse this call, which is what makes the mark the
right tool (brief 66: "only for a defensive branch that cannot be reached by any input"). What shows the mark
does its work, on the per-line report of run 2:

| Source | `Scripts/coverage-gate.sh --report run2-lines.json --mode changed-files Sources/CZTronDSP/ztd_thread.c` | Exit |
|---|---|---|
| with the mark | `17 lines marked coverage:ignore (0.07 % …)` / `Sources/CZTronDSP/ztd_thread.c 100.00 % (62 of 62 lines), needs 97.50 %: ok` | 0 |
| the mark line removed (and restored right after, byte for byte) | `15 lines marked coverage:ignore (0.06 % …)` / `Sources/CZTronDSP/ztd_thread.c 96.88 % (62 of 64 lines), needs 97.50 %: FAIL` / `FAIL: … is at 96.88 %, below 97.50 % (COV-3)` | 1 |

The mark excuses exactly lines 46 and 47 (the `return -1;` and its brace; the `if` itself runs and stays
counted). The gate refuses a mark that excuses nothing, so if a future change made the branch run, the gate
would ask for the mark to go.

**Marks of COV-4 b**: this is the only one this work adds. Total after it: 17 lines of 25 831, 0.07 %, below 0.5 %.

**After** (run 2): `CZTronDSP` 99.79 % (2 344 of 2 349). Every file at 97.5 % or more:

| File | Executable lines | Covered | Line coverage | Lines not run |
|---|---:|---:|---:|---|
| `Sources/CZTronDSP/ztd_allocation.c` | 16 | 16 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_alpha_beta.c` | 75 | 75 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_atomic.c` | 27 | 27 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_base.c` | 35 | 35 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_biquad.c` | 258 | 258 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_biquad_double.c` | 65 | 65 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_engine.c` | 175 | 175 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_fir.c` | 107 | 107 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_gain.c` | 128 | 128 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_history.c` | 49 | 49 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_lane_exchange.c` | 44 | 44 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_partitioned.c` | 225 | 225 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_plan.c` | 321 | 317 | 98.75 % | 287–288, 359, 378 |
| `Sources/CZTronDSP/ztd_queue.c` | 145 | 145 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_rate.c` | 211 | 211 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_ring.c` | 242 | 242 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_sink_node.m` | 48 | 47 | 97.92 % | 61 |
| `Sources/CZTronDSP/ztd_sink_tap.c` | 80 | 80 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_support.c` | 36 | 36 | 100.00 % |  |
| `Sources/CZTronDSP/ztd_thread.c` | 62 | 62 | 100.00 % |  |

The other lines not run are in files above the bar and are left as they are: `ztd_plan.c` 287–288, 359, 378
(98.75 %): 287–288 are `case ZTD_SWITCH_ACTIVE: break;` of `ztd_entry_run`'s switch, which line 249 never
lets an active entry reach (it returns first); the case stays because the switch must name every state
(`-Wswitch`, warnings are errors in gate 1). 359 and 378 are the closing braces of two `case … { … break; }`
blocks, which `xccov` counts after the `break` and llvm-cov counts as run. `ztd_sink_node.m` 61 (97.92 %) is
`return false` below iOS 27, which this run's OS does not take.

## 3. Gates and tests

Those of the whole package, in `impl-WP-902.md`, section 3. For this part in particular: the C target built
in both configurations and with the function-effects check, and the 232 tests of `CZTronDSPTests` passed in
the instrumented run and in Debug and Release.

## 4. Open

Nothing for this part. Mutation in the sense of lens T does not apply to a mark; what lens T reviews for it
(COV-4 b) is whether the reason holds, which is argued above.

## 5. Change requests and decisions

CR-034 (the split): the owner's approval is asked (§11.7). Nothing else.
