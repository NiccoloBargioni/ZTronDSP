# Fix cycle 1 — WP-315 … WP-342 (engine, sources, feeds, bindings)

What the implementer changed after the first verification, finding by finding (FIX-1). The
verifiers re-verify this revision: the lens that raised a finding confirms its fix, the other
lens confirms the fix broke nothing in its own domain.

Revision: main tree, 2026-11-17, after the three parts of this cycle. `ZTronDSPCoreTests`: 490 tests in 56
suites, Debug and Release (375 in 46 after the first part, 2026-11-15; 480 in 55 after the second). Compile fixtures: 7 valid, 133
invalid (4 and 30 after the first part).

## Blocking findings of lens A (reports `WP-*-A.md`)

| Finding | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| WP-332 #1, WP-335 #1 | A `Binding<[Float]>` kept the last vector of the old plan after an exchange that left its branch alone | Every plan claims result slots of its own and prepares each (`EngineCore.adoptSinks`, `ExecutionPlan`) | `EngineRegressionTests.aVectorResultFollowsTheSignalAcrossAnExchangeThatKeepsItsBranch` |
| WP-331 #1 | Bindings outlived `detach()` and an equal update (BIND-6) | `detach` drops the pipeline (`dropPipeline(of:)`); an equal update re-captures (`ExecutionPlan.adoptBindings`); the lowered sinks hold no binding (`SinkDescription.Target.slot`); the pump is released for good | `EngineRegressionTests.detachAndAnEqualUpdateLetGoOfTheBindings` |
| WP-322 #1, WP-330a #1 | A stage bypassed by a constant left its latency in the environment (ACT-4, REAL-5) | The compiler restores the cursor of a constant-bypassed stage that keeps the signal (`PlanCompiler`) | `EngineRegressionTests.aStageBypassedForGoodAddsNoLatency` |
| WP-321b #1 | A consumer cancelled as it started to wait was never resumed | The cancellation check is made under the lock that installs the waiter (`FeatureStream`) | `EngineRegressionTests.aConsumerCancelledAsItStartsToWaitReturns` |
| WP-333 #1, WP-332 #2 | Sequence-locked reads could return a torn column or vector on arm64 | A full barrier after the writer's announcement and before the reader's validating load (`ztd_atomic_barrier`; `ColumnStore`, `ResultSlot`, `FeatureStream`) | `EngineRegressionTests.aStoreOfOneColumnNeverHandsOutATornOne`, `aVectorResultIsNeverTorn` |
| WP-333 #2 | A critical memory event emptied a feed whose writer was stopped (MEM-1) | Trimming copies the newest columns on the control context; a running writer catches up (`ColumnStore.trim`) | `EngineRegressionTests.aTrimmedFeedKeepsItsNewestColumnsWithoutAWriter` |
| WP-319a #1 | The analysis thread freed what a hand-over replaced (RT-3) | No strong reference is kept across a hand-over; a new stage is recognised by a serial number, not by identity (`HubRunner`, `Handoff`, `RunnerThread`) | `EngineRegressionTests.handOversFreeNothingOnTheAnalysisThread` (uses the new `ThreadAllocationAudit` of `ZTronDSPTesting`) |
| WP-320b #1 | A pull stream was sometimes ended early after a format change | The end of a stream carries the epoch of the stream it ends; an end of an older epoch is ignored (`HubRunner.takeEnded`, `EngineCore.service`) | `EngineRegressionTests.aLongStreamAfterAFormatChangeIsNotCutShort` |
| WP-320b #2 | A sink dropped by `update(_:)` stayed claimed until a block arrived (ATT-5) | Dropped sinks are retired in the old plan and released before `update(_:)` returns (`EngineCore.adoptSinks`, `SinkSlot.isRetired`) | `EngineRegressionTests.anUpdateThatDropsASinkFreesItAtOnce` |
| WP-316 #1, WP-321b #2, WP-333 #3 | Sizes no machine can hold trapped (§9.3) | Checked arithmetic and typed errors (`GeneratorSource`, `FeatureStream.Storage`, `ColumnLayout`, `AudioBuffer`, `SourceAdapter`) | `EngineRegressionTests.sizesNoMachineCanHoldAreTypedErrors` |
| WP-320a #1 | Cells of the state table without a test | Tests added | `SessionStateTests.updateWhileInterruptedReplacesThePlan`, `updateWhileFinishedOrFailedReplacesThePlan`, `detachWhileInterruptedAndWhileRunning`, `aFormatChangeWhileIdleAndWhileInterruptedRePlans` |
| WP-317 #1, #2, #3 | Batch sizes of `ScriptedSource` unobserved; `render` allocated; coverage | Lengths are computed once, at creation; tests added | `SourceTests.aScriptOfBatchSizesDeliversThoseSizes`, `renderingStockPullSourcesAllocatesNothing` |
| WP-323 #1 | Offline `process` off the main thread differs from the engine for a pipeline with bindings, with no change request | Recorded as CR-015 item 12; the documentation of `process` already states it | — (a decision for the owner) |
| WP-324 #1 | The declared chain missed the budget of §5.7 in about half the launches | Sample buffers no longer sit a whole number of pages apart (`ztd_buffer_color`, `AudioBuffer`, `ztd_channel_table`); the suite times the two sides in alternation; the identity kernel left the declared chain | `EngineRegressionTests.sampleBuffersDoNotSitAWholeNumberOfPagesApart`; `OverheadBudgetTests` in a benchmark run |

### Figures of WP-324 after the change

Release, the suite alone, eight launches on a host that four other builds were using:

| Launch | Declared − hand-written (ns) | Allowance (ns) | Fused − two calls (ns) | Bound switch (ns) |
|---|---|---|---|---|
| 1 | +82 | 138 | +88 | +0.8 |
| 2 | +79 | 138 | +25 | +0.7 |
| 3 | +82 | 138 | +91 | +0.3 |
| 4 | +203 | 141 | +99 | −0.9 |
| 5 | +81 | 139 | +92 | −23.8 |
| 6 | +19 | 139 | +87 | +0.7 |
| 7 | +82 | 139 | +155 | +1.4 |
| 8 | +80 | 138 | +90 | −6.3 |

The second mode the verifier saw, about 260 ns above the first, is gone. Launches 4 and 7 miss
by one figure each; in both the hand-written side was itself slower than in the quiet launches
(3 310 and 3 224 ns against 3 150 ns), which is the load of the host. To be measured again on a
quiet host before the package is closed.

## Blocking findings of lens B (reports `WP-*-B.md`)

| Finding | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| WP-330a (ACT-3, ACT-4), two findings | A stage off for good inside a `Group` or an `EnvironmentReader` did not suspend what followed the group; on the main line it left the rest running at the wrong rate, and a session behind a processed source was handed blocks its plan was not made for | The walk of the compiler reports a suspension to the walk around it (a tap ends it); a main line suspended for good ends at a closed gate, so nothing leaves the plan, as with a bound switch that is off (`PlanCompiler`, `LoweredPipeline.isSuspended`, `ExecutionPlan`); the C plan runner never takes more frames than its buffers hold (`ztd_plan_run_range`, `ztd_plan_preroll`) | `SecondLensRegressionTests.aStageOffForGoodInsideAGroupOrAReaderSuspendsTheRestOfItsBranch`, `aRateChangerOffForGoodOnTheMainLineSuspendsItLikeABoundOne`, `aPlanNeverWritesPastItsBuffers` |
| WP-330b (ACT-10) | A shared framing step kept its history when its last consumer was switched off, and handed a stale frame to the branch that came back | A shared prefix that comes back to life is reset (`ExecutionPlan.refreshLiveness(of:)`) | `SecondLensRegressionTests.sharedFramingStartsColdWhenItsLastConsumerResumes` |
| WP-320a (§4.5, `start()` in `failed`) | A preparation that failed was awaited again by every later `start()` | A failed preparation is forgotten when it ends (`EngineCore.restart`) | `SecondLensRegressionTests.aRestartWhosePreparationFailsCanBeTriedAgain` |
| WP-320b (ATT-5, a refused update) | A sink of the running plan that the refused plan had already been given stopped receiving | A sink prepared for a plan that is then refused is prepared again for what the running plan writes (`EngineCore.adoptSinks`) | `SecondLensRegressionTests.aRefusedUpdateLeavesTheRunningPlanAsItIs` |
| WP-325 (ORD-4) | No sentence for an `Emit` after sequence stages alone | Unavailable overloads with the family's sentence, in the builder and in the fluent spelling (`PipelineBuilder`, `Structure.swift`) | Fixtures `SequenceIntoAHeatmap`, `SequenceIntoAWaveformFeed`, `HeatmapOpensABlock`, `SamplesIntoAHeatmapFluent` |
| WP-326 (ORD-4, O-15) | A `Tap` in another domain was refused with a conversion error, and its fixture held for any error | An unavailable overload for such a `Tap`; a general one for a self-typed stage after a domain it does not take; one each for `if` without `else`, `for … in` and `if #available` | Fixtures `BranchStartsInAnotherDomain`, `SelfTypedStageAfterTheWrongDomain`, `AbsentStageChangesTheDomain`, each now asserting its sentence |
| WP-316 | Six one-line defects of the generators passed the suite | Tests of silence into used memory, of both chirps against their closed forms through and past their end at an amplitude other than 1, of pink noise prepared twice and scaled | `SecondLensRegressionTests.silenceOverwritesWhatTheBlockHeld`, `chirpsFollowTheirFormulasThroughAndPastTheirEnd`, `pinkNoiseIsSeededScaledAndStartsOverWhenPreparedAgain` |
| WP-319b | The polling period of the engine itself was asserted nowhere | A test through the engine's own computation, with a clock that records | `SecondLensRegressionTests.theEnginePollsAtHalfABlockAndNeverUnderAMillisecond` |
| WP-320a (cells of the state table) | Eight cells without a test | Tests of each (four in fix cycle 1's lens A part, the rest here) | `SessionStateTests` (four tests), `SecondLensRegressionTests.aFailedSessionStartsAgainAndRuns`, `stagesStartColdAfterAResumption`, `aDetachedSessionStopsRunningWhileItsSourceServesAnother`, `aFinishedSessionJoinsASourceThatRunsAgain`, `aStartThatThrowsBehindAProcessedSourceLeavesTheSessionIdle`, `aSourceThatReportsAFormatThatIsNotOneFailsAndComesBack` |
| WP-320c | The test of two attachments on one source held for an attachment that received nothing | A test that feeds the source by hand and compares samples, indices and times | `SecondLensRegressionTests.attachmentsOnOneSourceSeeIdenticalBlocks`, `servingSeveralSessionsAllocatesNothing` |
| WP-324 | No script made the benchmark run, so the budgets were asserted nowhere | `Scripts/benchmarks.sh` (CI gate 8): the suites of `Scripts/ci/benchmark-filters.txt`, in Release, one test at a time, with the budgets held | `Scripts/tests/test-benchmarks.sh` (36 checks) |
| WP-333, WP-341 | In a run of the whole suite the stress test's writer had finished before the readers began | The writer starts once every reader has read and stops once each has taken its fill beside it; the test asserts that they overlapped | `FeedTests.readersNeverSeeATornColumn` |
| WP-335 | No fixture for a complex spectrum into a `Binding<[Float]>` | Fixtures in both spellings, and a valid twin | Fixtures `ComplexSpectrumIntoAVectorBinding`, `ComplexSpectrumIntoAVectorBindingFluent`, `ComplexSpectrumIntoAFloatBindingFluent`, `EveryBindingGetsWhatItTakes` |
| WP-339 | A bound switch on a stage written outside the core was never tested | A test with a processor and with a C kernel, each with latency | `SecondLensRegressionTests.aBoundSwitchWorksOnAProcessorAndOnACKernelWithNoCodeInTheStage` |
| WP-332 | A flaky assertion on the heartbeat around `stop()` | The count is taken after the stop has taken effect | `BindingTests.aResultIsDeliveredOnTheMainThreadOncePerChange` |
| WP-315, 318, 320a, 320b, 325, 327b, 329, 335 (COV-3) | Files below 97.5 % | `SecondLensRegressionTests.aRingWriterTakesChannelsInterleavedSamplesAndBlocks` for the writer's members; the rest is the coverage closure of the second part below: every file of the core that the packages touch is at or above the bar | `Coverage*Tests.swift` (the suites of the closure), `EngineCreationFailureTests` |

## Non-blocking findings acted on

- From lens B: a custom kernel or processor whose description and object disagree about its latency is refused with a typed error (`KernelFactory`; `SecondLensRegressionTests.aStageWhoseDescriptionAndObjectDisagreeAboutItsLatencyIsRefused`); a second task that iterates a `FeatureStream` beside the first is told there is nothing for it instead of spinning (`aSecondConsumerOfAStreamDoesNotSpinBesideTheFirst`); the binding pump rests while its session is interrupted (`thePumpRestsWhileItsSessionIsInterrupted`); the coverage gate does see production files when it is driven as `Scripts/ci.sh` drives it (an instrumented build, then the tests with a result bundle): aggregate 97.68 % at the revision before this cycle's tests.

- `finished → stop() → start()` and a later attachment on an ended source get the stream anew (`EngineRegressionTests.aSessionStartedOnAStreamThatIsOverGetsItAgain`; CR-015 item 15).
- `DynamicPipeline.append(contentsOf:)`.
- Documentation comments on the declarations the reports name (VIS-2).
- `AnalysisThreadTests.aRealTimePullSourceTakesAsLongAsItsSignal` asserts the lower bound only; the listener of `SourceTests.aScriptedSourceFollowsItsScript` cannot hang the run.
- CR-015 items 11 to 16: the public additions in full, and the readings the reports asked to have written down.

## Second part of the cycle (2026-11-16 and 2026-11-17, before any re-verification)

The coverage closure raised the files of the core and of the C layer to the bar with tests that assert
behaviour, and met seven defects of the engine on the way (F1 to F7); the implementer of the views met an
eighth (F8). One implementer then fixed them, with what the fixes brought to light (the last five rows), for
the engine and for the C layer (whose half is in `fix-cycle-1-WP-201-227.md`). `ZTronDSPCoreTests`: 480
tests in 55 suites, Debug and Release, three runs each; every target of the package in Debug and Release.
What these fixes decide is CR-024.

| Finding | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| F1 (SWAP-4, §5.5.4; WP-313, 314b) | A value queued for the running plan was lost when a new plan was installed at the same block boundary: the plan was installed first, and the command then named neither plan | `SessionRunner.boundary()` and `settle()` apply what is queued before the plan on its way in is accepted; `drop(_:)` applies what was sent to a plan that is replaced before it ran | `UpdateRegressionTests.aValueChangeFollowedAtOnceByANewTopologyIsNotLost`, `aValueQueuedBeforeAnInterruptionReachesThePlanExchangedDuringIt`, `aValueSentToAPlanThatIsReplacedReachesTheKernelItSharedWithTheNext` |
| F2 (§4.5, SWAP-4; WP-314b, 320b) | A refused update cancelled the update before it: the plan being pre-rolled was abandoned before the new one was compiled and its sinks claimed | `EngineCore.exchange` compiles and adopts the sinks first (`adoptSinks(of:for:replacing:insteadOf:)`), and only then drops the plan on its way in | `UpdateRegressionTests.aRefusedUpdateDoesNotCancelTheUpdateBeforeIt`, `aRefusedUpdateLeavesTheSinksOfThePlanOnItsWayInAsTheyWere`, `aPlanThatStartsToFadeWhileItsSuccessorIsCompiledTakesOverFirst`, `aSinkOfAPlanThatIsReplacedGoesOverToThePlanThatReplacesIt` |
| F3 (ACT-1, ACT-5; WP-330b) | A bound switch on a stage inside a kernel-only `Group(isActive:)` did nothing: the group ran as one C plan, which cannot switch anything inside itself | A group runs as one kernel only when its kernels keep the rate and none has a switch of its own (`IRStep.isKernelRegion`); any other group runs its stages in line between the group's switch points | `SwitchedGroupRegressionTests.aBoundSwitchInsideAGroupOfKernelsSwitchesItsStage`, `theSwitchOfAStageInsideAGroupFadesLikeAnyOther` |
| F4 (ACT-3, ACT-5; WP-330b) | A switched group that changes the rate inside lost samples (760 of 768): it was sized by the block at its input | As F3; groups that still run as one kernel are sized by the frames of the region | `aSwitchedGroupThatChangesTheRateInsideLosesNoSample`, `aGroupThatChangesTheRateInsideNeverOutgrowsItsBuffers` (factors 3, 7, 63 with blocks of 64, 37, 480) |
| F5 (ACT-8, REAL-5; WP-330b, 322) | The bypass of such a group was misaligned: latencies were summed as if at one rate | As F3 | `aSwitchedGroupWithARateChangeInsideKeepsItsAlignmentWhenBypassed`, `aGroupWithARateChangeInsideKeepsItsAlignmentWhileItIsSwitched` |
| F6 (RT-8, SRC-2; WP-337) | Frames dropped upstream were not reported behind a processed source | `EngineCore.reportOverrun` sends `.overrun` on the processed source's events and to the sessions behind it, in frames of the processed signal, down the chain | `ProcessedSourceTests.framesDroppedUpstreamAreReportedBehindAProcessedSource`, `framesDroppedUpstreamAreCountedInTheFramesOfEachProcessedSignal` |
| F7 (§9.3; WP-311b, 323) | A rate changer that needs more frames than a plan can count trapped instead of failing with a typed error | Sizes are decided by arithmetic before anything is made (`ExecutionPlan.Builder.planSizes`, `LoweringContext.maximumFrames` saturates); one buffer holds at most 2²⁸ samples | `PlanSizeRegressionTests` (4 tests) |
| F8 (§5.5.4, SWAP-1, CLICK-1; WP-312, 313, 307) | A gain that an update brought to exactly 0 dB, or away from it, changed the topology: the feed of the branch behind it was reset, its nodes made again, about thirty blocks withheld, and the gain stepped | Plans are built from, keyed by and compared by a skeleton that keeps the place of a stage that is an identity by its values; reaching 0 dB sends the value and ramps; leaving 0 dB in a plan compiled without the kernel compiles a plan with the kernel made as the identity, which takes over without pre-roll or fade and is then sent the value | `UnityGainRegressionTests` (8 tests), `UpdateRegressionTests.aGainThatLeavesZeroDecibelsInFrontOfAStageThatIsReplacedStillRamps`, `aStageBehindAGainThatAnUpdateRemovesIsNotSharedEither` |
| Found with F2 (SWAP-1; WP-314a) | A kernel or node that two plans shared behind the first difference of their main lines ran twice per block during pre-roll and fade | On the main line an object is moved into the new plan only when everything in front of it is moved too (`ExecutionPlan.Builder.takes`) | `UpdateRegressionTests.aStageBehindAStageThatChangedIsNotSharedByTheTwoPlans` |
| Found with F2 (SWAP-2; WP-314b) | An exchange booked by the next update or by a stop was reported without the analysis side's word that the output had changed | `EngineCore.bookExchange(of:)` reads it whoever books | `anExchangeBookedByTheNextUpdateStillReportsThatTheOutputChanged`, `anExchangeBookedWhenTheSessionStopsStillReportsThatTheOutputChanged` |
| Creation that the system refuses (§9.3; WP-315, 319a, 320a, 321b, 332, 333) | Initialisers that make several atomic cells leaked the earlier ones when a later one was refused, and no test could reach those branches | `Support/AtomicCells.swift` makes cells all or none; used by `SourceAdapter`, `ResultSlot`, `SessionRunner`, `ColumnLayout`, `RunnerThread`, `HubRunner`; the hub is made before the registry is claimed | `EngineCreationFailureTests` (7 tests) |
| Thread Sanitizer (gate 5) | Test doubles written by the analysis thread while a test read them (`CollectingSink`, `StateBox`, `CountingSink`, `Readout`) stopped the sanitizer's run; three tests read the allocation probe, which the sanitizer blinds | The doubles are guarded; the probe-dependent tests are disabled under the sanitizer | The sanitizer's run of the three targets: no report |
| Dead code | Members no path reaches | Removed: the unreachable branch of `startSource`, `SessionCore.droppedSinks`, `Handoff.exchanges`, `ResultSlot.sinkName` (the name is the internal protocol `NamedSink`), `IRSink.path`, `IRBranch.path`, `StructuralKey`, `Pipeline.empty()`, `StageDescription.expandedForReference`, `SessionRunner.cutShort`, `EngineCore.settleTransition` and `abandon` | — |

Coverage after this part (instrumented Debug run of the three targets): every file of the core that the
cycle touched is at or above 97.5 %; the lowest are `Pipeline/Structure.swift` 97.60 %, `Feeds/FeatureStream.swift`
98.13 %, `Engine/Run/HubRunner.swift` 98.60 %, `Compiler/LoweringContext.swift` 98.61 %, `Compiler/PlanCompiler.swift`
98.90 %, `Engine/EngineCore.swift` 99.37 %; the others are at 100 %. No `coverage:ignore` mark stands in the
core or in the C layer.

## Third part of the cycle (2026-11-17, before any re-verification)

What the second part listed as found and not fixed, closed by the same implementer. `ZTronDSPCoreTests`: 490
tests in 56 suites. No public API changed. CR-024 items 10 to 17.

| Subject | What was wrong | What changed | Test that fails without the change |
|---|---|---|---|
| §9.3: figures that cannot be represented | A gain ramp, a latency or a settling time, a block size or a rate that the caller states was converted with an initialiser that traps (`Compiler/KernelFactory.swift`, `Compiler/StockKernels.swift`, `Engine/Run/ProcessorKernel.swift`, `Sources/SourceAdapter.swift`, `Engine/ExecutionPlan.swift`); two fused FIR filters added their latencies unchecked; a group run as one kernel added its latencies in 32 bits (2³² − 1 and 1 came out as 0) | Every figure is counted by arithmetic before anything is made (`Support/FrameCount.swift`) and refused with a typed error and the stage's path; gains and filters fuse only when the fused figure is a count; the group's sum is refused when no buffer holds it | `CountableValueRegressionTests` (8 tests; each names the old expression and asserts the typed error; the fusion rule and the group sum were seen failing with the old sources) |
| RT-4: the plan's description read by the analysis thread | `SessionRunner.accept` read `ExecutionPlan.lowered` while the control context may replace it on a plan on its way in | The fade length and the pre-roll are constants of the plan; everything the analysis side reads of a plan is `let`; no file under `Engine/Run/` names `lowered` | `UpdateRegressionTests.aValueForAPlanOnItsWayInTouchesNothingTheAnalysisThreadReads` (passes under the sanitizer; the sanitizer does not report a struct replaced as a whole, so the fix is shown by construction) |
| NUM-1 behind a processed source | `.nonFiniteInput` reached only the session of the pipeline in front | `EngineCore.reportNonFinite` goes down the chain as `reportOverrun` does | `ProcessedSourceTests.samplesReplacedUpstreamAreReportedBehindAProcessedSource` |
| SWAP-2: the booking of an exchange | A booking could fall between the runner's store of the generation and its store of the event bits | The runner stores what it has to say before the generation; every booking, the service's too, goes by the generation (`EngineCore.bookExchange`) | The three booking callers stay covered; no test can hit a window of a few instructions |
| Dead code | Two unreachable cases in `Engine/Run/HubRunner.swift` | Removed | — |

Flakiness seen in this part, on a machine whose load average stood between 600 and 780: in ten Release
runs of the core's tests three failed, each with one issue in a different test that this cycle did not touch.
`SourceTests.renderingStockPullSourcesAllocatesNothing` fails whenever it is the first in its process to
render a `ScriptedSource` in Release (three allocations by the Swift runtime at first use: a defect, given
to the next round); `BindingTests.thePumpCostsLittlePerTurn` holds a wall-clock budget outside a benchmark
run; `SessionStateTests.interruptionAndResumption` waits 20 ms for two events to be handled. The last two
are corrected in the next round.

## Not acted on in this cycle

- An update that is refused while a plan is being faded in still cuts the fade short (CR-024 item 1 says so).
- The first use of Swift code on the analysis thread in an optimised build (see above), the two tests that lean on the clock, the 32-bit sums of the C layer's switch and the result rate that is not validated: with the next round of the same implementer, together with the extension surface of CR-025.
- The documentation pass over every public symbol of the target (VIS-2) is part of the documentation package of M9.
