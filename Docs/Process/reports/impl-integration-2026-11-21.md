# Integration of the gallery and the extension surface (brief 61)

| | |
|---|---|
| Implementer | `integ` (agent), alone: no sub-agent, no other session |
| Day | 2026-11-21, 10:45 to 13:07, Europe/Rome; every time below is the clock of this machine, read from a log |
| Tree | the main tree, `/Users/admin/Documents/ZTronDSP`, unstaged on `5296abf`: nothing committed, staged, stashed or reset |
| Started from | the two merges of brief 61 (M8b-2: 17 files of `ZTronDSPUI` and its tests and the 264 files of `Examples/`; round 3 of the engine and C-layer fix cycle: 33 files of `Sources/` and `Tests/`) and the integrator's first check of the merged tree (`.build/tmp/checkA/summary.log`: everything green but the `fixtures` step of `Scripts/external-parity.sh`, where `FINDING-ACustomKernelCannotStateItsValues` now compiled) |
| Simulators | `ztdsp-27` (iOS 27.0, 36C3875A-8282-49E1-A35A-79475BF8FA22) for the package and the gallery; `ztdsp-18-m8b` (18.6) and `ztdsp-175-m8b` (17.5) for the gallery; one booted at a time, each shut down after use; no other simulator touched |
| Logs | `.build/logs/integ/` (a log per step; `seq-r1` to `seq-r6.summary` for the six chains of runs), `.build/external-parity/`, `.build/ci-results/` (the result bundle of gate 5); the gallery's under `Examples/ZTronDSPGallery/Spikes/logs/after-correction/`. At the end I deleted the derived data I had made (`.build/ci`, `ci-tsan`, `ci-gallery`, `ci-gallery-release`, `ci-strict`, `gallery`, `xcode-effects`, 4.9 GB), after copying their last logs to `.build/logs/integ/kept/` |

## 1. Files added, changed and deleted

What this integration changed on top of the two merges (the merges themselves are listed in brief 61 and in the
two implementers' notes). Found from the files' times against 10:45 and from `git status`.

**Package sources** (6 changed):

| File | Change |
|---|---|
| `Sources/CZTronDSP/ztd_engine.c` | `#pragma STDC FP_CONTRACT OFF` (2.1, D11) |
| `Sources/CZTronDSP/include/ztd_engine.h` | one sentence: the gain cascade's ramp is the gain kernel's, rounded step by step (D11) |
| `Sources/ZTronDSPCore/Compiler/KernelSpec.swift` | documentation only: the threading contract of the two `values` initialisers and of `values` (VIS-2) |
| `Sources/ZTronDSPCore/Nodes/AnalysisNode.swift` | documentation only: the threading of `AdjustableSampleProcessor` and `OutOfPlaceSampleProcessor` |
| `Sources/ZTronDSPDesign/Systems/Realization.swift` | documentation only: `recommendedPrecision(accelerated:channelCount:blockFrames:)` allocates |
| `Sources/ZTronDSPTesting/AllocationAudit.swift` | documentation only: the threading of `expectNoAllocationsRunning`, and that it shows no first use |

**Package tests** (2 changed): `Tests/CZTronDSPTests/GainCascadeTests.swift` (the test
`theRampIsTheGainKernelsRampRoundedStepByStep`, D11); `Tests/ZTronDSPTestingTests/PipelineAuditTests.swift` (new in round 3;
one trait, D14).

**Lint fixtures** (7 added, under `Tests/Fixtures/Lint/`): `part1/Examples/ZTronDSPGallery/Gallery/Screens/LegacyScreen.swift`,
`part1/Examples/ZTronDSPGallery/GalleryTests/HostingSupport.swift`, `part1/Sources/ZTronDSPUI/Surface/DrawableScale.swift`,
`part3/Examples/ZTronDSPGallery/Gallery/GalleryApp.swift`, `part3/Examples/ZTronDSPGallery/GalleryTests/HostedScreenTests.swift`,
`clean/Examples/ZTronDSPGallery/Gallery/GalleryApp.swift`, `clean/Sources/ZTronDSPUI/Surface/DisplayScale.swift`.

**Scripts and CI** (12 changed, 1 added): `Scripts/ci.sh`, `Scripts/tests/test-ci.sh`, `.github/workflows/ci.yml`,
`Scripts/tests/test-workflow.sh`, `Scripts/lib/lint_bans.py`, `Scripts/lint-bans.sh`, `Scripts/tests/test-lint-bans.sh`,
`Scripts/external-parity.sh`, `Scripts/tests/test-external-parity.sh`, `Scripts/compile-fixtures.sh`,
`Scripts/ci/benchmark-filters.txt`, `Scripts/tests/test-benchmarks.sh`; added `Scripts/lib/extension_guide.py`.

**The external package** (`ExternalParity/`): changed `Sources/CExternalKernels/extk_biquad.c`,
`Sources/ExternalStages/Kernels/ExternalGain.swift`, `Sources/ExternalStages/Kernels/ExternalLowPass.swift`,
`Sources/ExtensionGuide/Kernels/Despike.swift`, `Tests/ExternalStagesTests/{GainParityTests, LatencyAndUpdateTests,
LowPassParityTests, AllocationAuditTests, SpeedTests}.swift`, `Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift`,
`Tests/ExternalTestSupport/Support.swift` (documentation); added `Tests/CompileFixtures/valid/AKernelAndAProcessorStateTheirValues.swift`,
`Tests/CompileFixtures/valid/ANodeIsAuditedOnTheTestsThread.swift`; deleted
`Tests/CompileFixtures/invalid/FINDING-ACustomKernelCannotStateItsValues.swift`,
`Tests/CompileFixtures/invalid/FINDING-ANodeCannotBeRunOutsideAPlan.swift` (copies in `.build/integ-removed/`).

**Documents**: `Docs/ExtensionGuide.md` (regenerated), `Docs/ExtensionGuide.template.md` (added);
`Docs/Process/reports/fix-cycle-1-WP-315-342.md` (part 4), `Docs/Process/changes/CR-024.md`, `CR-025.md`, `CR-027.md`,
`Docs/Process/ledger.md` (nine rows), `Docs/Process/unchecked-sendable.md` (row `SessionRunner`); this report (added).

**Examples**: `Examples/ZTronDSPGallery/Spikes/WP-822-findings.md` (the table of §8.4);
`Examples/ZTronDSPGallery/Spikes/logs/after-correction/ios-27.0/` and `ios-17.5/` (today's logs at the top level, the files
filed on 2026-11-18 moved unchanged into `before-integration-2026-11-18/`), `ios-18.6/` (added).

Not changed: `Package.swift`, the specification, `Docs/API/` (the digests are round 3's; `--check` passes on them), the code of
`ZTronDSPUI` and of `Examples/`.

## 2. Item by item

### 2.1 Part A1 — the extension surface green in the main tree

Six chains of runs, each step one after the other, on `ztdsp-27` but for the gallery's runs on 18.6 and 17.5
(`.build/logs/integ/seq-r*.summary`):

- **R1**, 10:53:45 to 11:00:03: every test target in Debug and in Release, all green. Stale after D11 (below), so run again.
- **R2**, 11:26:41 to 11:42:58: every target in Debug (11:26:41 to 11:30:40) and in Release (11:31:15 to 11:33:18);
  `ZTronDSPCoreTests` and `ZTronDSPUITests` twice more in each configuration; the three benchmark launches of
  `ProcessorCostTests`; the sanitizer run (failed: D14); `Scripts/external-parity.sh` (passed).
- **R3**, 11:46:10 to 12:28:25: the sanitizer run again (passed, 11:46:10 to 11:52:21), `ZTronDSPTestingTests` in Debug and
  Release (D14 touched it), the gallery (part B2), gates 1, 5 and 6 through `Scripts/ci.sh`, the coverage of the changed
  files.
- **R4**, 12:28:34 to 12:39:24: three checks with a change undone (2.3), then every gate of the common rules
  (section 3). Its run of the external suite held the gain's bound in its second launch only, which led to R5 and D16.
- **R5**, 12:40:49 to 12:41:34: the speed step of the external suite alone, five times, one launch each (2.3, D16).
- **R6**, 12:56:40 to 13:04:02: after D16, its guard seen failing without the refinement (2.3), then the gates D16
  touches, on the final tree: the external suite in full, the self-tests, the lint, the ledger, `Scripts/ci.sh --list`
  (section 3).

Totals of every run of the package (the same in every run): CZTronDSPTests 230 tests in 31 suites, ZTronDSPCoreTests 511
in 60, ZTronDSPDesignTests 336 in 41, ZTronDSPAnalysisTests 420 in 41, ZTronDSPMetalTests 115 in 12, ZTronDSPIOTests 134 in 13,
ZTronDSPUITests 278 in 19, ZTronDSPTests 5 in 2, ZTronDSPTestingTests 55 in 8 with 3 known issues (the deliberate
self-tests of the audit: `withKnownIssue` around a block that must be caught) — 2 084 tests. Core: three runs in Debug
(11:26:41, 11:30:40, 11:30:52) and three in Release (11:31:15, 11:33:18, 11:33:26), all green. The sanitizer run
(`Scripts/ci.sh --gate 5 --tsan-only`, 11:46:10 to 11:52:21): nine runs green, `ZTronDSPTestingTests` with 1 known issue
(the probe's own tests are skipped there), 33 tests and 3 suites that need the probe to count skipped by their trait,
and no report of the sanitizer in its log (`.build/logs/integ/kept/ci-tsan-last-test-without-building.log`, copied
from `.build/ci-tsan/`): no "data race", and "ThreadSanitizer" only in the command line.

The benchmark (`TEST_RUNNER_ZTD_BENCHMARK_OUTPUT` set, Release, `-parallel-testing-enabled NO`, the suite alone, three
launches 11:33:44 to 11:33:54; `.build/logs/integ/bench-{1,2,3}.json`), the processor of one multiplication against the
stock gain on 512-frame blocks, by the least of 11 samples of 4 000 blocks: out of place ×0.996, ×1.016, ×1.023 (by the
medians ×1.042, ×1.017, ×1.000); in place ×1.211, ×1.214, ×1.256. The 5 % bound held in all three launches.

Three defects were found and fixed on the way, each with a test that fails without the fix:

- **D11 — the ramp of the gain cascade** (pre-existing in `ztd_engine.c`; it blocked the bit-for-bit twin of part A3).
  `ztd_engine.c` was compiled with floating-point contraction on: clang fused `target − increment·left`, so 70 of the
  480 frames of a 10 ms ramp were other floats than the gain kernel's closed form in `ztd_gain.c` (compiled with
  contraction off): `Gain(amount)` and `Gain(channels:)` ramped differently, and so did the external gain against its
  twin. Fix: `#pragma STDC FP_CONTRACT OFF` in `ztd_engine.c`, and the sentence in `ztd_engine.h`. Test
  `CZTronDSPTests/GainCascadeTests/theRampIsTheGainKernelsRampRoundedStepByStep()` (both implementations, three ways of
  cutting the blocks). Without the pragma: 12 issues, "70 frames of the ramp differ from the closed form"
  (`.build/logs/integ/cascade-without.log`); with it: 4 tests in 1 suite passed (`cascade-with.log`).
- **D14 — an audit test of round 3 under the sanitizer.** `ZTronDSPTestingTests/PipelineAuditTests/aNodeThatAllocatesIsCaughtOnTheTestsOwnThread()`
  expects the probe to count one allocation per block; under the Thread Sanitizer the audit counts nothing
  (`AllocationAudit.isUnderThreadSanitizer`), so the sanitizer run of R2 failed (11:41:36): "Known issue was not recorded"
  at `PipelineAuditTests.swift:89:28` and "Expectation failed: counts == AllocationCounts(allocations: 50, …)". Fix: the
  trait every other probe-dependent test carries, `.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's
  allocator hides the heap from the probe")`. The run before is the failing evidence, the run of R3 the passing one; the
  test still runs, and passes, in every plain run (55 tests in 8 suites, 3 known issues).
- **D12 — the benchmark list.** Round 3 added `ProcessorCostTests`, which calls `Benchmark.record` and holds its 5 % bound
  only in a benchmark run, but `Scripts/ci/benchmark-filters.txt` did not name it: gate 8 would never have held the
  bound. Fix: the line `ZTronDSPCoreTests/ProcessorCostTests`. Test: `Scripts/tests/test-benchmarks.sh` checks that every
  suite of the package that records a benchmark is on the list (a file is covered by its target or by
  `Target/<type>`). Without the line: "every suite of the package that records a benchmark is on the list" fails, "not
  listed: ZTronDSPCoreTests/ProcessorCostTests.swift" (37 checks, 1 failed, `selftest-bench-without.log`); with it 37, 0.

Seen and left: `Tests/ZTronDSPCoreTests/BindingTests.swift:259` (round 3) makes the compiler warn twice that a comparison
with `.nan` is always false. The expectation states exactly that (a rate that is no number passes both bounds of the pump);
test targets are outside the warnings-as-errors rule of gate 1.

### 2.2 Part A2 — the public change, reviewed

`git diff -- Docs/API` (round 3's `--update`, unchanged since; `Scripts/api-digest.sh --check` passes): 15 lines added in four
digests, none changed, none removed, so the existing initialisers of `CustomKernel` and `CustomProcessor` stay as they were
(source-compatible). No added symbol is a configuration, options, settings, style or descriptor type (API-6): the new
inputs are plain values (`[Double]`, `Bool`, `Int`) and protocols. Every one has a documentation comment that states its
threading; the comments of eight of them, in four files, were completed here (D1, documentation only), as marked.

| Digest | Symbol and signature | Threading contract, as documented |
|---|---|---|
| ZTronDSPCore | `protocol AdjustableSampleProcessor : SampleProcessor` (and its conformance line) | created on the control context, where it allocates; `setValues(_:)`, `process` and `reset` on the analysis thread under RT-2, one thread at a time (completed here) |
| ZTronDSPCore | `AdjustableSampleProcessor.setValues(_ values: UnsafeBufferPointer<Double>)` | analysis thread, between two blocks, RT-2 (no allocation, no lock, nothing that blocks); the buffer is the engine's and valid during the call only; a reset keeps the values set last |
| ZTronDSPCore | `protocol OutOfPlaceSampleProcessor : SampleProcessor` (and its conformance line) | as every `SampleProcessor`; both `process` entries and `reset` on the analysis thread under RT-2; the plan asks once, on the control context, whether a processor conforms (completed here) |
| ZTronDSPCore | `OutOfPlaceSampleProcessor.process(_ input: AudioBlock, into output: inout AudioBlock)` | analysis thread, RT-2; the blocks never overlap, `input` is read only (it may be the block every session on the source reads), each of `input.frameCount` frames of `output` is written |
| ZTronDSPCore | `CustomKernel.init(name: String, key: some Hashable & Sendable, values: [Double], interpolation: Int = 1, decimation: Int = 1, latencyFrames: Int = 0, make: @escaping @Sendable (Int, Double, Int, [Double]) -> ztd_kernel_t)` | any thread, typically the control context in `lower(_:)`; allocates (a copy of `values`); nothing of `make` runs there. `make` runs on the control context and may allocate; with values, the kernel's `command` takes `ZTD_COMMAND_SET_VALUES`, else the plan is refused (completed here) |
| ZTronDSPCore | `CustomKernel.values: [Double]` | usable on any thread (completed here); sent at a block boundary on the analysis thread, the payload freed off it |
| ZTronDSPCore | `CustomProcessor.init(name: String, key: some Hashable & Sendable, values: [Double], latencyFrames: Int = 0, make: @escaping @Sendable (DSPEnvironment, [Double]) throws(DSPError) -> any AdjustableSampleProcessor)` | any thread, typically the control context; allocates; `make` on the control context, may allocate and throw (completed here) |
| ZTronDSPCore | `CustomProcessor.values: [Double]` | usable on any thread (completed here); handed to `setValues(_:)` between two blocks |
| ZTronDSPDesign | `SecondOrderSections.recommendedPrecision(accelerated: Bool, channelCount: Int, blockFrames: Int) throws(DSPError) -> BiquadPrecision` | control or background context; allocates (it makes the measurement) (completed here) |
| ZTronDSPDesign | `SecondOrderSections.singleVersusDoubleDeviation(accelerated: Bool, channelCount: Int, blockFrames: Int) throws(DSPError) -> Double` | creates two kernels and runs them: control or background context, where `lower(_:)` runs |
| ZTronDSPTesting | `@discardableResult func expectNoAllocationsRunning<Output: SignalDomain>(_ pipeline: Pipeline<Samples, Output>, format: SignalFormat = SignalFormat(sampleRate: 48_000), blockSize: Int = 512, blocks: Int = 1_000, crossovers: CrossoverTable = .shipped, _ comment: @autoclosure () -> String = "", sourceLocation: SourceLocation = #_sourceLocation) throws(DSPError) -> AllocationCounts` | a test's own thread, never an engine's analysis thread; allocates outside the audit (the plan, the noise, eight blocks before it opens), so it shows no first use (completed here) |
| CZTronDSP | `bool ztd_plan_set_switch_preroll(ztd_plan_t *plan, uint32_t index, uint32_t frames)` (Swift: `(OpaquePointer!, UInt32, UInt32) -> Bool`) | the control-context part of `ztd_plan.h`: before the plan runs, or between two blocks. From CR-024 item 18, not from brief 45 |
| CZTronDSP | `uint64_t mach_absolute_time(void)` (Swift: `() -> UInt64`) | Darwin's function, re-declared `ZTD_NONBLOCKING` by the now public `ztd_vdsp.h` (it reads the commpage: any thread, RT-2). It enters the digest because the header is public; the vDSP entry points the same header re-declares do not (D2: accepted as the intended consequence of CR-025 item 5) |

Against brief 45: items 1 to 5 are all there. Item 2 asked for the out-of-place refinement only if the in-place path
could not be brought within 5 %; round 3's notes and the benchmark above show the in-place path at ×1.21 to ×1.26, so
the refinement is the remedy, as CR-025 item 1 now records. `singleVersusDoubleDeviation(accelerated:channelCount:blockFrames:)`
goes beyond the brief's words: it is the public companion of `recommendedPrecision(accelerated:…)`, as the existing pair
without arguments already is, and I accept it.

### 2.3 Part A3 — the external package on the new surface

The suite as merged failed its `fixtures` step on the merged tree (checkA): `FINDING-ACustomKernelCannotStateItsValues`,
which stated that a kernel of the caller's own could not state values, compiled. Every bullet of the brief, and what
holds it now:

| Brief 61, A3 | The suite now | Held by |
|---|---|---|
| The gain written as a `SampleProcessor` adopts `OutOfPlaceSampleProcessor` and is held to 5 % like the others | `ExternalGain` lowers to `CustomProcessor(name:key:values:latencyFrames:make:)`: the per-channel factors are its values, the ramp in frames its key. `ExternalGainProcessor` is an `AdjustableSampleProcessor` and an `OutOfPlaceSampleProcessor`; it ramps over 10 ms as the stock gain does (§5.5.4), in the closed form of `ztd_gain.c` (`target − increment·left`, the target exactly at the end) | `SpeedTests.theGainAgainstTheStockGain`, against 1.05, not loosened: nine launches measured ×1.009 to ×1.081 round by round, five of them over the bound, so the bound now stands inside an intermittent known issue that gate 9 lets stand in its speed check, and a plain expectation that the processor is an `OutOfPlaceSampleProcessor` keeps a gain written in place from passing (D16, below); in R6, after the change, ×1.062: the known issue was recorded and stood; `GainParityTests.theRampIsTheStockKernelsRampBitForBit` (against `ztd_gain_create`, three ways of cutting the blocks; it found D11), `aChannelBeyondTheFactorsPassesUnchangedAndAnEmptyUpdateIsIgnored` |
| The low-pass and the processor state their values; the two `FINDING` tests become plain tests; the fixture becomes valid | `ExternalLowPass` lowers to `CustomKernel(name:key:values:latencyFrames:make:)`: the number of sections, the precision and the implementation are its key, the five coefficients of each section its values; `extk_biquad` takes them through `ZTD_COMMAND_SET_VALUES` | `LatencyAndUpdateTests.aChangedCutoffIsSetInTheRunningKernelAsTheStockFilterSetsIt` and `aChangedAmountRampsInTheRunningProcessorAsTheStockGainRamps` (the two former `FINDING` tests: no plan compiled, the sink hears every frame), `aChangedRampIsAnotherProcessor`, `aKernelMovedIntoANewPlanKeepsTheValuesItWasSentLast`; the valid fixture `AKernelAndAProcessorStateTheirValues` replaces the `FINDING` fixture |
| The mel node audited on the test's thread; `FINDING-ANodeCannotBeRunOutsideAPlan` likewise | `AllocationAuditTests.theMelNodeRunsOnTheTestsThreadWithoutAllocating` through the public `expectNoAllocationsRunning`; also `theGainProcessorRampsOutOfPlaceAThousandBlocksWithoutAllocating` | the valid fixture `ANodeIsAuditedOnTheTestsThread` replaces the `FINDING` fixture: 4 valid fixtures compile, 21 invalid fail with their sentences |
| The C kernel includes the public `ztd_vdsp.h` | `extk_biquad.c` includes `"ztd_vdsp.h"` by name and drops its five re-declarations | gate 9's `rules` step; in `Scripts/tests/test-external-parity.sh` the seeded private header is now `ztd_internal.h` (line 95 named the old place of `ztd_vdsp.h`, D10), with a case that the public header passes |
| The low-pass picks its precision with `recommendedPrecision(accelerated:channelCount:blockFrames:)` | for `.automatic` it measures with the stock filter's three figures: whether the place runs on Accelerate, the channel count, the largest block | `LowPassParityTests`: bit for bit against the stock low-pass, single and double precision |
| Item 11's block-size statement follows `ztd_kernels.h` | the former finding is the plain test `LowPassParityTests.theDoublePrecisionCascadeDependsOnTheBlocksOnlyThroughWhatTheFloorClears` | itself; it prints the measured difference (first at frame 1, 4.5·10⁻¹³ at a peak of 5.1·10⁻⁵, blocks of 1 against 512) |
| The guide generated; the rule of round 3 for a first use | `Scripts/lib/extension_guide.py` writes `Docs/ExtensionGuide.md` from `Docs/ExtensionGuide.template.md` and the marked regions of the suite (39 blocks, 39 regions); the guide step runs it with `--check`. Rows 2 and 3 show the suite's own code (`ExternalGain`, `ExternalLowPass`, `extk_biquad.c`). Row 2's `Despike` primes its processor in `make` (one block of silence and a reset, on the control context), and the guide says why and how to hold it: an audit that opens before the first block, alone in its process, in an optimised build | `GuideAllocationAuditTests.theProcessorOfRowTwoAllocatesNothingFromItsFirstBlock` (Release only; the `audits` step runs it once more alone; it passes without the priming too, see below); `test-external-parity.sh`: a guide edited by hand, a template that holds a copy of the code, a marker without its region, no template |

Two script changes go with it. `Scripts/compile-fixtures.sh` hands the compiler the plugin path of Swift Testing's
macros: a valid fixture that calls `expectNoAllocationsRunning` needs `#_sourceLocation`, its default argument.
`Scripts/external-parity.sh` (D13) let one known issue stand, the probe's control case
`theProbeCountsWhatAnAllocatingStageDoes()`; a known issue of any other test fails its step, because a promise of
EXT-1…EXT-4 recorded as broken is not a promise kept. Self-test: 141 checks, 0 failed; with the script as it was
before D13, 3 failed ("a known issue of a test other than the control case fails the tests (exit 0, expected 1)", its
message, and the same in the audits; `selftest-ep-without-d13.log`). D16 makes one exception, in the speed check.

**D16 — the gain written as a `SampleProcessor` is at its bound, not within it.** Gate 9's speed check allows up to
three launches and counts the first that holds (a rule older than this work), so a pair that misses in about half the
launches passes the gate while its promise is broken half the time. R4's run of the suite missed in its first launch
(×1.081 round by round, quartiles ×1.050 … ×1.101; "Expectation failed: gain.paired <= SpeedTests.bound" at
`SpeedTests.swift:273:13`) and held in its second (×1.031). As the common rules ask of a test that fails once, I ran it
alone again, five times (R5, `Scripts/external-parity.sh --step speed --launches 1`): ×1.009, ×1.058, ×1.051, ×1.069 and
×1.059, four of them over 1.05. With the runs of 11:20 (×1.019) and of R2 (×1.035) that is nine launches, ×1.009 to
×1.081, five over the bound (`x4.log`, `ep.log`, `extparity.log`, `sp1.log` to `sp5.log`). In the same launches the same
multiplication on the kernel ABI took ×0.909 to ×0.968 of the stock gain's time, so what is left is the cost of calling
a processor, not the multiplication. Brief 61 says what to do then: "if it still misses, the measured figures stay in
CR-025 item 1 and the expectation stays a known issue — do not loosen 5 %". So:

- `SpeedTests.theGainAgainstTheStockGain` keeps the bound of 1.05 inside `withKnownIssue("CR-025 item 1: …",
  isIntermittent: true)`: a launch over the bound records a known issue, a launch within it records nothing. The bound of
  the gain on the kernel ABI stays a plain `#expect`, and so do those of the low-passes and the mel scale.
- `Scripts/external-parity.sh` lets that one known issue, of `theGainAgainstTheStockGain()`, stand in the `speed` step
  and nowhere else; any other known issue still fails its step. When it is in the log, the step says "every stage but the
  gain written as a SampleProcessor ran within its bound; that gain missed it, as CR-025 item 1 records".
- A known issue would also let a far slower gain pass: the gain written in place took ×1.706 (the check below). So the
  same test holds, in every run and as a plain `#expect`, that `ExternalGainProcessor` is an
  `OutOfPlaceSampleProcessor` (`SpeedTests.swift:270`): that conformance is what the plan asks before it copies nothing in
  front of the processor. It states no figure, so nothing is loosened.
- Gate 9's text in `Scripts/ci.sh` names the two known issues that may stand (2.7).
- CR-025 item 1 says "not met reliably", with the nine figures, the guard, R6's run and a question for the owner
  (section 5, decision 9); the guide's sentence on the gain and the row of part 4 of `fix-cycle-1-WP-315-342.md` say the
  same.

Self-tests: `Scripts/tests/test-external-parity.sh`, 152 checks, 0 failed (`selftest-ep-gain.log`); with the script as it
was before D16, 3 failed (`selftest-ep-gain-without.log`): "the gain's known miss of its bound may stand in the speed
check (exit 1, expected 0)", the same at the first launch, and the step's sentence. Its new cases also hold that the same
known issue outside the speed check fails its step, and that a known issue of another test fails the speed check in every
launch. `Scripts/tests/test-ci.sh`, 161 checks, 0 failed (`selftest-ci-gain.log`); against gate 9's old text, 2 failed
(`selftest-ci-gain-without.log`): "… gate 9, the parity suite as part A of brief 61 adapted it (output lacks: two known
issues may stand: the probe's)" and "… the second the out-of-place gain at its bound (output lacks: and over it in about
half the launches (CR-025 item 1))".

The guard, seen failing without the refinement (R6, `guard.log`, 12:56:40 to 12:57:30): with the conformance taken off
`ExternalGainProcessor`, the `speed` step failed on the guard alone, "Expectation failed: processor is any
OutOfPlaceSampleProcessor" at `SpeedTests.swift:270:9` (the gain at ×1.710). With the guard taken out as well, the same
step passed: the gain, at ×1.769, recorded the allowed known issue, and the step said "every stage but the gain written
as a SampleProcessor ran within its bound; that gain missed it, as CR-025 item 1 records". So without the guard, gate 9
would let a gain written in place pass. Both files were restored and compared. The guide now says the gain takes "×1.01
to ×1.08 the stock gain's time on blocks of 512 frames, round by round, in nine launches".

**The two known issues that may stand**, each named, with why:

- `theProbeCountsWhatAnAllocatingStageDoes()` (`AllocationAuditTests.swift:42:59`), in the `test` and `audits` steps. It
  is the probe's control case: a stage that allocates must be counted, so its expectation of "no allocation" has to
  fail. Part A was not meant to resolve it; if it ever passed, the probe would be blind.
- `theGainAgainstTheStockGain()` (`SpeedTests.swift:284:17`), in the `speed` step, in a launch where the gain misses its
  bound (D16). Part A was meant to resolve this one, and it stays: the out-of-place refinement took the gain from ×1.706
  of the stock gain (in place, below) to the bound, but not reliably within it. Brief 61 forbids loosening the bound, and
  a cheaper path for processors is a change of the core that neither brief asks for; the owner decides (CR-025 item 1,
  decision 9 of section 5).

**Three checks with a change undone** (R4, `ztdsp-27`, each file restored and compared with `cmp` afterwards):

- `Despike` without its priming (the four lines that run a block of silence and reset in `make`), then
  `ExtensionGuideTests/GuideAllocationAuditTests/theProcessorOfRowTwoAllocatesNothingFromItsFirstBlock()` alone in
  Release: **the test passed** (1 test in 1 suite, 0.011 s; the build compiled `Despike.swift` again without the four
  lines). It passed again with them (0.006 s). In Release the first `process` of `DespikeProcessor` asks nothing of the
  runtime that allocates, so this processor does not need the priming. The audit holds whatever `make` leaves for the
  first block, and for this processor that is nothing either way. The priming stays as the guide's example of the rule:
  it costs one block of silence on the control context, and it keeps a later change to the processor from bringing a
  first use onto the analysis thread unseen. The records now say what the test shows: the row of part 4 in
  `fix-cycle-1-WP-315-342.md`, and section 4 of this report.
- `ExternalGainProcessor` without `OutOfPlaceSampleProcessor`, then the `release` and `speed` steps once, before D16:
  the `speed` step failed (`speed.log`): "SPEED ExternalGain against stock Gain: ×1.706 round by round (quartiles ×1.682 …
  ×1.734 over 30 rounds)", and "Expectation failed: gain.paired <= SpeedTests.bound" at `SpeedTests.swift:273:13`. The
  other pairs held: the gain on the kernel ABI ×0.934, the low-passes ×1.000, ×1.000 and ×0.999, the mel scale ×0.948
  and ×0.954. After D16 this check is the guard's (above).
- `ExternalLowPass` with its coefficients in its key and no values, as before round 3, then
  `ExternalStagesTests/LatencyAndUpdateTests/aChangedCutoffIsSetInTheRunningKernelAsTheStockFilterSetsIt()` in Debug:
  3 issues: "Expectation failed: !external.replanned" (`LatencyAndUpdateTests.swift:235:9`), "… external.gap.count
  == 0" (236:9) and "… external.timeline == stock.timeline" (237:9). A plan was compiled, the sink behind it missed
  frames, and what it heard differed from the stock filter's. With the file restored: 1 test passed.

### 2.4 Part A4 — the records of round 3

- `Docs/Process/reports/fix-cycle-1-WP-315-342.md`: "Part 4 — round 3", in the form of the earlier parts (per item: what
  was wrong, what changed, the test that fails without the change and what it showed): the ten items of round 3, from its
  notes, with today's figures where they were measured again, and three rows "Found while integrating" (D11, D14, D12).
  The revision line and "Not acted on in this cycle" say that the fourth part did what the third left.
- `Docs/Process/changes/CR-025.md`: items 1 to 6 and 11 marked "Implemented on this reading"; item 1 "not met
  reliably" (D16), with the figures of 2.1 and 2.3 and a question for the owner; Evidence of 2026-11-21; items 7 to 10
  left as they were. Status stays `Proposed`.
- `Docs/Process/changes/CR-024.md`: round 3 touched it, so items 18 to 21 are added (the switch's pre-roll and
  `ztd_plan_set_switch_preroll`, the sums of the C layer in 64 bits, the result rate that reaches the pump, the first use
  reached on the control context); "Not done", Evidence and "Sections affected" (ACT-7, RT-2, OUT-2) follow.
- `Docs/Process/unchecked-sendable.md`, row `SessionRunner`: the notes' text ("`settle`, `finishFade` and `drop` are called
  by the control context only while the hub is paused") checked against `EngineCore` and completed with the cases the
  code has: "… or while the session is off the hub's thread (before it is first scheduled, after `commit` has taken it
  out of what runs, or once its source is stopped)". Lint part 4 (the registers) is clean with it.
- Not available: the round-3 notes' "CR-015 additions: see the report draft in the transcript summary (items a–f)". That
  draft is not in any file I can read; nothing was added to CR-015 (section 4).

### 2.5 Part B1 — the package's UI target

`ZTronDSPUITests`, 278 tests in 19 suites, in Debug three times (11:26:41 in the run of every target, 11:31:04, 11:31:09)
and in Release three times (11:31:15, 11:33:33, 11:33:38), all green; once more in the Debug run of gate 5 (R3) and in
the sanitizer run. Coverage of its ten changed sources (git shows nine changed and one added, `TurnEnd.swift`; the brief
says eleven), from the result bundle of gate 5 (`Scripts/coverage-gate.sh --mode changed-files`, 12:15:29): nine at 100.00 %
(`AppearanceModifiers` 39 of 39 lines, `HeatmapViews` 54, `SurfaceHost` 52, `WaveformView` 64, `PinchTracker` 104,
`FrameScheduler` 76, `MetalSurface` 38, `SurfaceCoordinator` 300, `TurnEnd` 38) and
`Sources/ZTronDSPUI/Pinch/PinchGestureModifier.swift` at 92.86 % (104 of 112 lines), below COV-3's 97.50 %. The eight
lines not run are 95 and 96 (`PinchPath.current` on iOS 17 and on iOS 15 and 16) and 215 to 217 and 225 to 227 (what the
`MagnifyGesture` and `MagnificationGesture` paths report while the fingers move and when they lift). The coverage run is on
iOS 27, and the gestures report only under a real touch; the UI tests on 17.5 (2.6) drive the `MagnifyGesture` path, but
no coverage is taken there. I did not mark them `coverage:ignore`: the lines are the gestures' whole behaviour, and the
ledger's row WP-820 names them (2.8, section 4). Every other changed source of the package is at or above 97.50 %
(lowest: `Realization.swift` 98.18 %, `BindingPump.swift` 98.50 %, `ztd_plan.c` 98.75 %); the headers have no executable
lines and `AllocationAudit.swift` is outside the denominator (COV-6). The step exits 1 for this one file.

### 2.6 Part B2 — the gallery against today's tree

Every run went through `Examples/ZTronDSPGallery/gallery.sh` (Debug, `ZTD_DEVICE` set, derived data `.build/gallery`),
wrapped by `.build/logs/integ/gal.sh`. The wrapper waits for the simulator to boot and writes
`g-<runtime>-<action>-<n>.out`: the start, the script's summary lines, the exit and the end. It then copies the
application's journals with `gallery.sh logs`. The simulators were `ztdsp-27` (iPhone 17, iOS 27.0), `ztdsp-18-m8b`
(iPhone 16, 18.6) and `ztdsp-175-m8b` (iPhone 15, 17.5). One was booted at a time, each shut down after its runs
(`seq-r3.summary`).

| Run | When | Result |
|---|---|---|
| Hosted, 27.0, run 1 | 11:54:40 to 11:56:31 | 24 tests in 8 suites passed (81.4 s), no known issue |
| Hosted, 27.0, run 2 | 11:56:32 to 11:57:55 | the same (77.7 s) |
| Hosted, 27.0, run 3 | 11:57:55 to 11:59:18 | the same (77.9 s) |
| UI, 27.0 | 11:59:19 to 12:05:35 | 11 tests, 0 failures (368.3 s) |
| The application in Release | in gate 1, 12:05:35 to 12:07:45 | built (`gallery.sh app`, `ZTD_CONFIG=Release`, derived data of its own) |
| Hosted, 27.0, in gate 5 | in gate 5, 12:07:45 to 12:15:27 | 24 tests in 8 suites passed (78.5 s), no known issue |
| Hosted, 18.6 | 12:15:38 to 12:17:12 | 24 tests in 8 suites passed (80.4 s), no known issue |
| UI, 18.6 | 12:17:13 to 12:22:46 | 11 tests, 0 failures (326.5 s) |
| Hosted, 17.5 | 12:22:53 to 12:24:27 | 24 tests in 8 suites passed (83.1 s), no known issue |
| UI, 17.5 | 12:24:28 to 12:28:21 | 11 tests, 3 skipped (they need iOS 18), 0 failures (228.0 s) |

What the hosted suites measured, against the agent's figures of 2026-11-17 and 18 (its notes and the files it filed;
on 18.6 its one run with the corrected package, at 23:52, still had test code it changed afterwards). "At commit" and
"when drawn" are the largest distance between the drawable and the size the layer is shown at:

- **Animated frame (WP-824)**: 0.00 px at commit on all three systems and in every run. PSNR ∞ at the midpoint, 30
  draws for 30 frames, no upload. The same as the agent's.
- **Rotation there and back, when drawn**:

  | | There | Back | The agent's, there and back |
  |---|---|---|---|
  | 27.0 (runs 1 / 2 / 3) | 0.45 / 0.49 / 0.46 px | 0.49 / 0.47 / 0.49 px | 0.47 / 0.45 / 0.49 px and 0.46 / 0.43 / 0.44 px |
  | 18.6 | 0.46 px | 0.50 px | "0.47 / 0.45 px where the layer stood still between draw and commit" (its notes) |
  | 17.5 | 0.49 px | 0.43 px | 0.50 and 0.46 px |

  The final drawable matched the layer exactly every time, there and back: 2382 × 966 px, then 966 × 2382 px on 27.0;
  2316 × 939 px, then 939 × 2316 px on 18.6 and 17.5. The application lived through every rotation.
- **The spike's curves**: 0.48 px (ease-in-out) and 0.50 px (spring) at commit, on all three and in every run. The same
  as the agent's.
- **A resize without animation**: three draws for three sizes and no commit without a frame. The heat map and the
  waveform each drew [1, 2, 3] after the three sizes, on all three systems. The same as the agent's.
- **A size that follows a neighbour**: 0.00 px. The same as the agent's.
- **Frames in which the layer moved on between the draw and the commit** (`movedOn`):

  | | Today | The agent's |
  |---|---|---|
  | 27.0 | none in any frame of the three runs | one frame (1.99 px) in its second run |
  | 18.6 | none there; 13 of 19 frames back (at most 24.69 px) | 13 of 20 frames back |
  | 17.5 | 17 of 19 there (at most 23.58 px); 17 of 19 back (at most 21.89 px) | 16 and 17 of 19 |

  Such frames are judged at the draw, as §8.4 of `WP-822-findings.md` explains. Where the frame captured at the
  midpoint is one of them, its PSNR is 40.6 dB (18.6, back) and 40.2 and 41.9 dB (17.5); everywhere else it is ∞.
- **The spike's rotation (WP-822)**, when drawn: 0.49 / 0.48 / 0.50 px on 27.0, 0.48 px on 18.6, 0.47 px on 17.5. At
  commit it was at most 0.73 px (27.0, run 2) and 0.67 px (17.5), under a pixel. Frames that moved on: 0 on 27.0, 13 on
  18.6 and 33 on 17.5, of about 100.
- **UI tests.** On 27.0 and 18.6 all 11 passed:
  - the pinch out read "span 4 -> 0.9947" on 27.0 and "span 4 -> 0.9987" on 18.6, with the range kept;
  - the pinch in read "-> 20.0 ... 24000.0";
  - the device turned to landscape and back twice, and the application lived. On 27.0 the probe was handed the final
    size once per turn (4 sizes for 4 turns). On 18.6 each turn back also handed it one layout in between, 0.8 ms
    before the final size (6 sizes for 4 turns), as §2.4 of `WP-822-findings.md` describes.

  On 17.5, 11 tests ran, 3 of them skipped because they need iOS 18, and none failed. There the pinch scales both axes,
  because the finger line is not known (PINCH-8, CR-027 item 3):
  - the pinch out read "span 4 -> 0.9987, range 40.0 ... 20000.0 -> 374.75 ... 1768.61";
  - the pinch in read "span 0.9987 -> 1.9706, range 374.75 ... 1768.61 -> 181.6 ... 3879.1";
  - the device turned twice and the application lived, and each turn back handed the probe a layout in between, as on
    18.6 (0.7 and 0.8 ms).

  The agent's runs:
  - 27.0: 11 of 11, in 1 412 s under the load of that night;
  - 18.6: 11 of 11;
  - 17.5: 11 run, 3 skipped, none failed, both axes, the same six sizes in its device log.

**Filed** under `Examples/ZTronDSPGallery/Spikes/logs/after-correction/`, where the agent filed (filed by
`file-logs.sh`, a script of my scratch folder; D15):

- `ios-27.0/` and `ios-17.5/` hold today's files at the top level. The files the agent filed on 2026-11-18 moved,
  unchanged, into `before-integration-2026-11-18/`.
- `ios-18.6/` is new.
- In each folder:
  - `hosted-suite-summary.txt`: the summary lines of every hosted run, with its start and end;
  - `ui-tests-summary.txt`;
  - `size-spike-device.log`, from the UI run;
  - the eleven journals of the last hosted run: `wp822-corrected-*.log`, `wp822-presentation-clock.log`,
    `wp824-corrected-*.log`.

A mistake of mine, corrected: the simulators of 18.6 and 17.5 still hold the spike's journals of 2026-11-17
(`*-asBuilt`, `*-displayScale`, `*-endOfTurn`, `wp824-verdicts.log`, dated 22:08 and 22:25 in the application's
container), and `gallery.sh logs` copies every journal. My first filing of 18.6 copied 25 of them. I removed them
again, each compared first with the journal copy, and the script now files only the eleven journals the hosted suites
write. Each filed journal is byte for byte the one in the simulator's container, written in today's run: on 18.6 at
12:16:32 to 12:16:48 and, for `size-spike-device.log`, at 12:22:45; on 17.5 at 12:23:44 to 12:24:03 and at 12:28:20. On
27.0 the application's container was made today, at 11:55:07, so it holds no older journal.

**§8.4 of `Spikes/WP-822-findings.md`** was still open: its table held placeholders. It is now filled from today's runs.
Its first line says which runs these are and where the agent's are, and the sentence on frames that move on gives
today's counts.

`git status --short --untracked-files=all -- Examples` lists 306 untracked files and no tracked change. Of them, 264
are the merge's and 42 the logs filed today. None is `xcuserdata`, a result bundle or derived data, and `--ignored` lists
nothing under `Examples/`. The project's shared scheme (`xcshareddata/xcschemes/`) is among the merge's files, as
intended.

### 2.7 Part B3 — into the gates

- **`Scripts/ci.sh`.** Gate 1 also builds the gallery application in Release (`gallery.sh app`, `ZTD_CONFIG=Release`,
  derived data `$ZTD_DERIVED-gallery-release`). Gate 5 also runs `gallery.sh hosted` on each simulator of the run (each
  runtime of `--runtime`/`--matrix`, or `ZTD_DEVICE`), in Debug, in derived data of its own, and fails when the log holds
  "recorded a known issue" ("the gallery's hosted suites recorded a known issue: there, none may stand"); `--tsan-only`
  runs no gallery. `--nightly` runs the gallery's UI tests (`gallery.sh ui`) on each simulator and nothing else; it is a
  usage error with `--gate`; its summary line is "ci: nightly  the gallery's UI tests (not a gate)". Gate 9 is the suite
  as part A adapted it (D13, D16), and its text names the two known issues that may stand; `--list` says all of this.
- **`Scripts/tests/test-ci.sh`**: a stand-in for the gallery's script (it logs its action, configuration, device and
  derived data, and can fail or record a known issue on one simulator); cases for gate 1, gate 5 with and without the
  matrix, a known issue on every simulator and on one, `--nightly` with and without the matrix, its annotation on
  GitHub, `--nightly --gate`, `--list`, `--tsan-only`; the failure loop has the gallery's `app` (gate 1) and `hosted`
  (gate 5). 161 checks, 0 failed (D16 made one check of gate 9's text two). Part 1 of the self-test against `ci.sh` as
  it was: 32 failed (`selftest-ci-without.log`), among them "gate 1 builds the gallery application in Release, in
  derived data of its own" and "a failure of GALLERY_HOSTED fails gate 5 (exit 0, expected 1)".
- **`.github/workflows/ci.yml`**: a nightly schedule (02:30 UTC) and a dispatch input `gallery_ui`; the job
  `gallery-ui-nightly` runs `Scripts/ci.sh --nightly --runtime …` on the four runtimes of the matrix and keeps the log of a
  failed run; the jobs of the gates are skipped in the nightly run, which has a concurrency group of its own.
  `Scripts/tests/test-workflow.sh`: 23 checks, 0 failed; against the workflow as it was, 5 failed (the five nightly
  checks, `selftest-workflow-without.log`). A seeded step `Scripts/ci.sh --gate 7` in the nightly job fails "… which is not
  a gate" and the order of the gates (`selftest-workflow-seeded.log`). That seeding found two faults in my first version
  of these checks, both corrected: the pattern for a gate was `--gate \\d` (a backslash and a d), so a gate in the nightly
  job passed, and the negative answer "NO" also tripped the check of the order of the gates, which looks for ": NO" in
  the whole output.
- **Lint** (`Scripts/lib/lint_bans.py`, `Scripts/lint-bans.sh`): part 1 holds `Examples/ZTronDSPGallery/Gallery/` to UB-1
  and UB-2 with no bridge exception (the messages say "in the gallery's application"); part 1 refuses the name
  `contentsScale` in the code of `Sources/ZTronDSPUI` (SZ-2; comments and strings are masked out); part 3 refuses
  `@testable` in the gallery's application (EXT-1; its hosted tests may). Seeded cases in `Tests/Fixtures/Lint/` (section
  1): the application's `import UIKit`, `UIImpactFeedbackGenerator` and `NSTextAlignment` are caught; the hosted tests'
  UIKit is not; `layer.contentsScale` in a UI source is caught at its line, the word in a comment and a string is not;
  `@testable import ZTronDSPUI` in the application is caught, in the hosted tests it is not; the clean tree has an
  application and a UI source of each kind. `Scripts/tests/test-lint-bans.sh`: 35 checks, 0 failed; with `lint_bans.py` as
  it was, 7 failed (`lint-selftest-without.log`), e.g. "the layer's scale read in ZTronDSPUI fails part 1 (output lacks:
  DrawableScale.swift:6: [SZ-2] …)". The package itself is clean (section 3).

### 2.8 Part B4 — the records of the gallery

- **CR-027** (status stays `Proposed`): item 6's wording is what was built, from the implementer's notes, and says where
  and why it departs from the wording filed on 2026-11-17: SZ-2 (a frame is due when the layer is shown at another size
  in whole pixels; made at the end of the run-loop turn; the presentation bounds times the display scale, rounded, never
  beyond the largest texture; nothing drawn on the tick during a transition; before the first drawable the tick draws),
  SZ-4 (the signs ask for a look at the layer at the end of the turn; the transition ends in the first display frame in
  which the layer rests at the last frame's size and no sign arrived), §8.3 (no tick of a transition held against the cap,
  and up to 120 ticks a second during a transition whatever `.maximumFrameRate` says: the owner is asked to confirm
  that) and §8.9 (at the end of the frame's run-loop turn; for a change SwiftUI makes, also at the commit). Items 3 and 7
  say what was built (PINCH-8; the scene-phase notice: `os.Logger`, subsystem `com.zombietron.ztrondsp`, category
  `surface`, level notice, once per surface, when its feed is live and it has read no phase but `.background`); items 8
  to 10 say what the gates and the lint now do; Evidence and "Not done" are those of today.
- **Ledger** (`tools/ledger_set.py`, then `Scripts/ledger.sh --check`): WP-809b, WP-810, WP-811, WP-818, WP-822 and
  WP-824 from `Blocked-on-deps` to `Verifying`, implementer "Implementer M8b-2 (agent)"; WP-819 and WP-823 keep
  `Verifying` and their backlog cell says that CR-027's corrections are in (and that CR-027 is proposed); WP-820 keeps
  `Verifying` and its backlog cell holds the uncovered lines of `PinchGestureModifier.swift` (COV-3's exception, no
  `coverage:ignore`). The script refused nothing: "ledger: 289 rows, consistent with §12 and §11". Only these nine rows
  differ from the ledger before the step (a copy was kept and compared).

## 3. Gates and totals

Every quoted line below is copied from a log of `.build/logs/integ/` (the step's own log, `<tag>.log`, or the chain's
summary).

**The gates of brief 60, on the final tree.** R4 ran all of them, each exit 0, from 12:28:34 to 12:39:24. After D16
changed `SpeedTests.swift`, two scripts, their self-tests and some records, R6 ran again the gates that read any of
those files; the others read none of them, so R4's run stands for them.

| Gate | Run | Final line |
|---|---|---|
| `Scripts/lint-bans.sh` | R6, 13:03:55; again after the last edit of the records, 13:07:09 | `lint-bans: clean (parts 1, 2, 3, 4; 604 files)` |
| `Scripts/check-dependency-graph.sh` | R4, 12:30:07 | `check-dependency-graph: the graph equals §4.2 (10 targets, 3 products, sources scanned)` |
| `Scripts/api-digest.sh --check` | R4, 12:30:15 | `api-digest: 10 digests equal the built modules`, then for each library "… references public symbols only" (the last: `api-digest: ZTronDSPUI references public symbols only`) |
| `TMPDIR="$PWD/.build/tmp" Scripts/compile-fixtures.sh --build` | R4, 12:31:10 | `compile-fixtures: 7 valid fixtures compile, 133 invalid fixtures fail with their sentences` |
| `TMPDIR="$PWD/.build/tmp" Scripts/order-matrix.sh --check` | R4, 12:32:09 | `order-matrix: 52 stages on 21 domains, 110 cells accepted; the committed matrix is current` |
| `Scripts/golden.sh --check` | R4, 12:32:13 | `golden: 197 files of 27 generators match the manifest` |
| `Scripts/check-function-effects.sh` | R4, 12:32:13 | `function effects: all checks passed` |
| `Scripts/ledger.sh --check` | R6, 13:03:59; again after the last edit of the records, 13:07:13 | `ledger: 289 rows, consistent with §12 and §11` |
| `Scripts/tests/run-all.sh` | R6, 12:58:49 to 13:03:55 | `run-all: every self-test passed (716 checks in 13 suites, 2 skipped: see above)` |
| `Scripts/external-parity.sh` | R6, 12:57:30 to 12:58:49 | `external-parity: passed`, after `rules`, `guide`, `build`, `test`, `fixtures`, `release`, `audits` and `speed` each "passed" |
| `Scripts/ci.sh --list` | R6, 13:03:59 | exit 0. Gate 1: `the gallery application in Release (Examples/ZTronDSPGallery/gallery.sh app, derived data of its own)`. Gate 5: `on each of its simulators the gallery's hosted suites (gallery.sh hosted), which fail on the words "recorded a known issue"`. Gate 9: `The external parity suite (Scripts/external-parity.sh, WP-907): the promises of EXT-1…EXT-4 held as plain expectations (values that update without a plan, a node audited on the test's thread, the guide made from its template); two known issues may stand: the probe's control case, and in the speed check the out-of-place gain, which is at 5 % of its twin and over it in about half the launches (CR-025 item 1)`. The last line: `Nightly, not a gate (--nightly): the gallery's UI tests (gallery.sh ui, 6 to 14 minutes)` |

The self-tests by suite, R6: spec-crosscheck 29 checks, process-files 45, lint-bans 35, check-dependency-graph 32,
coverage-gate 44, golden 80, compile-fixtures 22, order-matrix 20, api-digest 36, benchmarks 37, ci 161, workflow 23,
external-parity 152, each with "0 failed" (in R4, before D16: 704 checks, with ci at 160 and external-parity at 141). The
two skipped are the `--slow` variants: "gate 1 with a real build and a seeded warning" and "the parity tests on the
simulator with a seeded violation".

The external suite, R6 (`extparity6.log`):
- `test`: "116 tests passed; 1 expectations are known to fail and did:", the control case at
  `AllocationAuditTests.swift:42:59`;
- `fixtures`: "compile-fixtures: 4 valid fixtures compile, 21 invalid fixtures fail with their sentences";
- `audits`: "19 tests passed; 1 expectations are known to fail and did:" (the control case), then the audit that opens
  before the first block, alone in its process: "1 tests passed";
- `speed`: at its first launch, "3 tests passed; 1 expectations are known to fail and did:", the gain at
  `SpeedTests.swift:284:17` (×1.062), and "every stage but the gain written as a SampleProcessor ran within its bound; that
  gain missed it, as CR-025 item 1 records".

**Every test target, in Debug and in Release** (R2; `Scripts/xc.sh test`, then `ZTD_CONFIG=Release Scripts/xc.sh test`):

| Target | Debug, 11:26:41 to 11:30:40 | Release, 11:31:15 to 11:33:18 |
|---|---|---|
| CZTronDSPTests | ✔ Test run with 230 tests in 31 suites passed after 4.992 seconds. | ✔ … 230 tests in 31 suites passed after 0.945 seconds. |
| ZTronDSPCoreTests | ✔ … 511 tests in 60 suites passed after 8.531 seconds. | ✔ … 511 tests in 60 suites passed after 4.648 seconds. |
| ZTronDSPDesignTests | ✔ … 336 tests in 41 suites passed after 57.270 seconds. | ✔ … 336 tests in 41 suites passed after 1.623 seconds. |
| ZTronDSPAnalysisTests | ✔ … 420 tests in 41 suites passed after 98.911 seconds. | ✔ … 420 tests in 41 suites passed after 11.680 seconds. |
| ZTronDSPMetalTests | ✔ … 115 tests in 12 suites passed after 7.050 seconds. | ✔ … 115 tests in 12 suites passed after 0.724 seconds. |
| ZTronDSPIOTests | ✔ … 134 tests in 13 suites passed after 4.316 seconds. | ✔ … 134 tests in 13 suites passed after 4.561 seconds. |
| ZTronDSPUITests | ✔ … 278 tests in 19 suites passed after 2.711 seconds. | ✔ … 278 tests in 19 suites passed after 2.261 seconds. |
| ZTronDSPTests | ✔ … 5 tests in 2 suites passed after 0.037 seconds. | ✔ … 5 tests in 2 suites passed after 0.033 seconds. |
| ZTronDSPTestingTests | ━ … 55 tests in 8 suites passed after 0.189 seconds with 3 known issues. | ━ … 55 tests in 8 suites passed after 0.028 seconds with 3 known issues. |

After D14 changed `Tests/ZTronDSPTestingTests/PipelineAuditTests.swift` (11:41:09, the only file of `Sources/` or `Tests/`
changed after 11:26:41, lint fixtures aside), that target again (R3): Debug "━ Test run with 55 tests in 8 suites passed
after 0.193 seconds with 3 known issues.", Release "━ Test run with 55 tests in 8 suites passed after 0.042 seconds with
3 known issues." `ZTronDSPCoreTests` twice more in each configuration (Debug 8.346 and 9.263 s, Release 4.672 and
4.689 s, each "511 tests in 60 suites passed") and `ZTronDSPUITests` likewise (Debug 2.626 and 2.560 s, Release 2.213
and 2.194 s, each "278 tests in 19 suites passed"). The benchmark of the processor path (R2, three launches): "✔ Test
run with 2 tests in 1 suite passed after 0.186 seconds." (then 0.185 and 0.187 s).

**The sanitizer run** (`Scripts/ci.sh --gate 5 --tsan-only`, R3, 11:46:10 to 11:52:21): "ci: gate 5  tests
passed" and "ci: no gate failed"; the nine targets as above, with `ZTronDSPTestingTests` at "━ Test run with 55 tests in
8 suites passed after 0.523 seconds with 1 known issue."; no report of the sanitizer in the log. The run of R2 (11:33:54
to 11:41:36) failed, "✘ Test run with 55 tests in 8 suites failed after 0.587 seconds with 3 issues (including 1 known
issue).", which is D14.

**Gates 1, 5 and 6 through `Scripts/ci.sh`** (R3):
- gate 1, 12:05:35 to 12:07:45: each step "ok" (ZTronDSP and ZTronDSPUI for the simulator and for a device, warnings as
  errors; "build the gallery application in Release, in derived data of its own"; everything for testing), then "ci:
  gate 1  build                                passed" and "ci: no gate failed";
- gates 5 and 6, 12:07:45 to 12:15:27: the nine targets in Debug with the totals above, "✔ Test run with 24 tests in 8
  suites passed after 78.512 seconds." (the gallery's hosted suites), "ci: [gate 5] ok: the allocation-audit tests in
  Release (7 filter(s))"; then "coverage-gate: aggregate      99.54 % (25712 of 25832 lines), needs 97.50 %: ok", per
  target from "ZTronDSPDesign   98.70 % (4702 of 4764 lines)" to "ZTronDSPMetal    100.00 % (1445 of 1445 lines)", "15
  lines marked coverage:ignore (0.06 % of the production lines, below 0.50 %)", "coverage-gate: pass (aggregate,
  per-target)", and "ci: no gate failed". The gate says "COV-3 was not checked (no list of changed files …)", so I ran
  it myself:
- COV-3 on the changed files (`Scripts/coverage-gate.sh --xcresult .build/ci-results/Debug.xcresult --mode
  changed-files`, 12:15:27): exit 1, for one file only, "coverage-gate: FAIL: Sources/ZTronDSPUI/Pinch/PinchGestureModifier.swift
  is at 92.86 %, below 97.50 % (COV-3)" (2.5); every other changed source at or above 97.50 %.

**The gallery** (2.6), each through `gallery.sh`: hosted on 27.0, "✔ Test run with 24 tests in 8 suites passed after
81.411 seconds.", then 77.671 and 77.926 s, and 78.512 s in gate 5; on 18.6 after 80.429 s; on 17.5 after 83.137 s;
each "** TEST EXECUTE SUCCEEDED **" with no known issue. UI tests: 27.0 "Executed 11 tests, with 0 failures (0
unexpected) in 368.280 (368.297) seconds"; 18.6 "… in 326.495 (326.508) seconds"; 17.5 "Executed 11 tests, with 3 tests
skipped and 0 failures (0 unexpected) in 228.046 (228.061) seconds".

**Simulators**: after R6, `xcrun simctl list devices booted` lists no device (13:04:02, after the last shutdown of
`ztdsp-27`, and again at the end of the work).

## 4. What is open

- **The two known issues of the external suite** (2.3). The probe's control case,
  `theProbeCountsWhatAnAllocatingStageDoes()`, stays by design; part A was not meant to resolve it. The gain's bound,
  `theGainAgainstTheStockGain()` in the speed check, stays a known issue although part A was meant to resolve it: the
  gain written as a `SampleProcessor` measured ×1.009 to ×1.081 of its stock twin in ten launches today, six over 1.05
  (D16; the tenth, ×1.062, in R6). The 5 % is not loosened; the owner decides whether it holds for such a stage or
  whether the core's processor path is made cheaper (decision 9).
- **COV-3 for `Sources/ZTronDSPUI/Pinch/PinchGestureModifier.swift`**: 92.86 %, the eight lines of 2.5, entered in the
  ledger's backlog for WP-820 and not marked `coverage:ignore`. Only a coverage run on iOS 15 to 17, or under a real touch
  on a device, can run them.
- **The guide's rule for a first use catches nothing in the external suite.** Row 2's processor asks nothing of the
  runtime at its first `process`, so its audit passes without the priming too (2.3). The core's `FirstUseTests` hold
  the same kind of audit on the package's own sources, and round 3 saw them fail without its change. A control case
  for a stage written outside would need a first use that no earlier test of the process has met. I did not write one:
  in the suite's `test` step other tests run before it in the same process, so the control would not be reliable.
- **CR-015 additions (a–f)**: the round-3 notes point to "the report draft in the transcript summary", which is in no
  file I can read. Nothing was added to CR-015.
- **The round-3 notes' list "Found, not fixed"**, checked against the code today. The third part of the cycle (2026-11-17,
  `fix-cycle-1-WP-315-342.md`) closed most of it, and the list was not updated afterwards: the conversions that trapped
  (§9.3); the analysis thread's read of `ExecutionPlan.lowered` (no file under `Engine/Run/` reads it now);
  `.nonFiniteInput` behind a processed source (`EngineCore.reportNonFinite` goes down the chain); the unreachable cases of
  `HubRunner` (the file is at 100 %, and its paced mode has no `.waiting` case). Still as the notes say:
  `Sources/CZTronDSP/ztd_thread.c` at 96.72 % in today's coverage run (59 of 61 lines, `ztd_thread_base_priority` when
  `thread_info` fails). Neither merge changed the file, so COV-3 does not apply, and its target is at 99.70 %. Also still
  open: the comment of `Tests/ZTronDSPUITests/PipelineHostTests.swift`, lines 18 to 21, which the notes say describes
  the old 0 dB behaviour. I did not check it further: it is a comment in a test. The clock-bound test the notes saw fail
  once in a diagnostic sanitizer pass, under a load average above 500, is
  `EngineRegressionTests.aLongStreamAfterAFormatChangeIsNotCutShort`. It passed in every run today: the sanitizer run, the
  three runs of the core in each configuration, and gate 5.
- **CR-025 items 7 to 10** are the owner's, unchanged.
- **CR-027 is the owner's** (section 5). Until the owner decides, WP-819, WP-820, WP-821 and WP-823 rest on its proposed
  reading.
- **Not tested here**:
  - a device: what the display shows, the display link's timing, and displays faster than the simulators';
  - iOS 15 and 16: their runtimes do not run on this host;
  - a second finger that lands after the first, and free two-finger paths: no public API synthesises them;
  - `gallery.sh device`: the brief asks for simulators.
- **The nightly job and the new steps of `ci.yml` have not run on GitHub.** `Scripts/tests/test-workflow.sh` checked
  them, and `Scripts/ci.sh --nightly` ran the gallery's UI tests here only through its self-test's stand-in. The UI tests
  themselves ran through `gallery.sh ui`, on all three runtimes (2.6).

## 5. Change requests, and decisions for the owner

I wrote no new change request: nothing I found disagrees with the specification. D11, D12, D13 and D14 are defects,
fixed with their tests; D16 states a measured miss as a known issue, as brief 61 says to. Three change requests were
brought up to date, and each stays `Proposed`:

- **CR-024**: items 18 to 21, from round 3;
- **CR-025**: items 1 to 6 and 11 implemented on the proposed reading; item 1 not met reliably, with the figures of
  the ten launches and the guard of D16;
- **CR-027**: items 3, 6 and 7 in the wording of what was built, plus the built parts of items 8 to 10, its Evidence and
  "Not done".

Decisions asked of the owner:

1. **CR-027 item 3 (PINCH-3, PINCH-8).** A pinch whose finger line is not known scales every enabled axis, as built, or
   the other reading the item describes.
2. **CR-027 item 6.** The wording of SZ-2, SZ-4, §8.3 and §8.9 as built. In particular: may a size transition ask for
   every tick of the display, up to 120 a second, whatever `.maximumFrameRate` says (§8.3)?
3. **CR-027 item 7.** For a component in a `UIHostingController`, which reads `.background` for its whole life: the
   notice as built (an `os.Logger` message, once per surface), or another way to close the gap between §8.3 and §8.6.
4. **CR-027 item 8.** May the gallery's hosted tests keep `@testable import`, or do the probes and the clock source move
   to `ZTronDSPTesting`? The lint already refuses `@testable` in the application.
5. **CR-027 item 9.** What UB-6 lets the gallery's test targets import from UIKit.
6. **CR-027 item 10.** §10.3's wording for the gallery in gates 1 and 5, and for the nightly UI job. These were built
   ahead of the wording, so §10.3 does not say them yet.
7. **CR-025.** The reading on which items 1 to 6 and 11 are built, and items 7 to 10.
8. **The COV-3 exception for `PinchGestureModifier.swift`** (WP-820): accept it, or ask for a run that covers those
   lines.
9. **CR-025 item 1 (EXT-4).** The gain written as a `SampleProcessor`, out of place, took ×1.009 to ×1.081 the stock
   gain's time in ten launches today, six of them over the 5 % bound; the same multiplication on the kernel ABI is within
   it. Does EXT-4's 5 % hold for a stage written as a `SampleProcessor`, or is the core's processor path to be made
   cheaper (a change of the core, not started)? Until then gate 9 lets that known issue stand in its speed check.
