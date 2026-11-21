# WP-909 — Audit of the public API against API-6 and IMM-1…IMM-5

| Field | Value |
|---|---|
| Package | WP-909 (lenses A, T), after WP-901a (`impl-WP-901a-909.md`) |
| Auditor | Implementer M9-api (agent) |
| Tree | The main tree on 2026-11-21, with the changes of WP-901a and WP-909 unstaged (nothing is committed) |
| Inputs | The public symbol graphs of the Debug build for the iOS simulator (`ztdsp-27`), as `Scripts/api-digest.sh` extracts them; `Docs/API/*.txt`; the sources under `Sources/`; the four registers of `Docs/Process` |
| Result | **No configuration-shaped parameter type (API-6).** 152 types of the package are parameter types of public functions; 142 of them are parameter types in their own right, and each is a domain value, a strategy, a report or an identity. **IMM-1/IMM-2:** no public stored `var` and no public setter anywhere; 19 stored `var`s that their module could set, in five public value types: 13 now have a setter private to their type or file; the other 6 are `@usableFromInline`, the internals VIS-1 gives a toolkit primitive or a frame accessor so that its `@inlinable` code can move them, and stay as they are. **Registers:** `open-declarations.md`, `approvals.md` and `mutable-by-design.md` are empty and true; `unchecked-sendable.md` has a row for each of the 22 `@unchecked Sendable` types, and each names a type that exists at its file; 8 rows said something the code does not do and were rewritten. **IMM-4 and IMM-5 hold** by reading, with the functions cited below. Lint part 4 now checks the stored `var`s of public structs. |

## 1. Parameter types (API-6, brief item 909.1)

**Method.** `.build/m9-api/param_types.py` reads the symbol graphs of the build (the source of the digests, read
as `Scripts/lib/api_digest.py` reads them) and lists every struct, class and enum of the package whose name is
a type in a parameter of a public initialiser, function, method, operator, subscript, enum case or modifier.
`.build/m9-api/param_prefix.py` says which of them appear only as the namespace of a nested type (`A` in
`A.B`). `.build/m9-api/classify.py` holds the classification and checks that it names every listed type and
no other. The 152 types exclude `SinkDescription`, which WP-901a made internal (`impl-WP-901a-909.md`).

**Classes**, as the brief defines them:

- *domain value*: a unit, a signal or a part of one, a choice that is part of what is computed, a description
  (a stage, a pipeline, a design, a system, a window, a view, a table): IMM-1;
- *strategy*: answers one question of how something is computed (§5.3);
- *report*: carries what was found or measured;
- *identity*: an engine, session, feed, source, renderer, writer, or the work in progress that a call joins;
- *configuration-shaped*: a type whose stored properties are independent settings of the callee and which
  exists to be passed in. A violation of API-6 whatever its name.

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
**configuration-shaped 0**); 10 only as a namespace.

**The cases that needed a decision**, and why each is not configuration-shaped:

- `ConstantQGeometry` (the requirements of `ConstantQStrategy` and `ConstantQKernel.init(geometry:…)`): the
  bins of one constant-Q transform, derived from the stage's own parameters; nothing in it is chosen apart
  from the others. A derived table, so a domain value (CR-032 item 3 says why it is public).
- `DSPEnvironment`: what the signal is at a position (§5.4), made by the compiler and read by
  `EnvironmentReader`; the three settable keys are scoped strategy choices set one at a time with
  `.environment(_:_:)` (ENV-3). A value of the signal, not settings of a callee.
- `DSPEnvironment.SettableKeys`: the key paths `.environment(_:_:)` takes; names of keys, not a bundle.
- `InversionContext`: the samples, their rate and the upstream stages an inversion report is asked for
  (INV-2): the input of the report, so a domain value.
- `AudioSessionPolicy`: §4.6 calls it the strategy of the audio session; one question, one value.
- `ChannelPolicy`: how the channels of a signal enter a framing step (§5.3, MIC-6); one question.
- `CalibrationCandidate`: one implementation that `Calibration.search` measures: a strategy.
- `LoweringContext`, `FrameWriter`, `BackgroundWork.Checkpoint`: the compilation in progress (`inout` for
  one `lower(_:)`), the output storage a node is lent for one call, and the question a running piece of work
  asks between its steps: each is the work the call joins, so an identity.
- `PipelineBuilder`, `FIRSystemBuilder`, `IIRSystemBuilder`: result builders, named as the attribute of a
  builder closure whose result is a pipeline or a system (a domain value).
- The ten views of `ZTronDSPUI` are parameters of their own `==` only (`Equatable` for SwiftUI's diffing).

**Violations: none**, so nothing was reshaped and no item went to CR-031. The names API-6 lists are refused by
lint part 4 as before (no public type ends in `Configuration`, `Options`, `Settings`, `Style`, `Descriptor`,
`Specification`, `Specs` or `Params`).

## 2. Stored properties of public value types (IMM-1, IMM-2, brief item 909.2)

**Method.** `.build/m9-api/stored_vars.py` read the stored properties of every public struct (from the
graphs, then the declaration in the source), looking for a stored `var` with a public or internal setter.
The reading is now the lint's (section 6), and `Scripts/lint-bans.sh --part 4` is clean on the tree.

**Public stored `var`s and public setters:** none. No public struct has a public stored `var` (with any
setter), and no reference type has a public setter: the register of public setters was empty before this
package and the lint's IMM-2 rule found nothing. No digest line reads `{ get set }` or `{ set }`.

**Stored `var`s the module could set**, in public value types, and what became of them:

| Type | Properties | What became of them |
|---|---|---|
| `DSPEnvironment` (`Sources/ZTronDSPCore/Environment/DSPEnvironment.swift`) | `storedSampleRate`, `storedChannelCount`, `storedBlockSize`, `storedFrameSize`, `storedHopSize`, `storedAxis`, `storedLatency`, `storedIsRealTime`, `storedSourceKind`, `overrides` | `private(set)`. Each is set only on a fresh copy by the positional changes of the type (`withFormat(_:)` … `applyingOverrides(of:)`, lines 145–238), which return it as a new environment (IMM-5). Nothing outside the type set them. |
| `FeedCursor` (`Sources/ZTronDSPCore/Feeds/ColumnStore.swift`) | `layout`, `epoch`, `column` | `fileprivate(set)`. Moved only by the column store of the same file, as a `read` takes columns. |
| `AudioBlock` (`Sources/ZTronDSPCore/Signal/AudioBlock.swift:16`) | `frames` | Unchanged, `@usableFromInline`: the frame count of a work buffer (IMM-3), set on the analysis thread by the `@inlinable` `setFrameCount(_:)` and `copy(from:)`. VIS-1's row "Toolkit primitives and frame accessors: `public`, `@inlinable`; their internals `@usableFromInline`" prescribes exactly this spelling. |
| `Ramp` (`Sources/ZTronDSPCore/Toolkit/Ramp.swift:8`–`11`) | `current`, `goal`, `increment`, `remaining` | Unchanged, `@usableFromInline`: the state of a toolkit primitive (§5.11.4) that lives in a kernel or node (IMM-3, as the type's comment says), moved once per frame by the `@inlinable` `next()`, `setTarget(_:)`, `jump(to:)`, `advance(by:)` and `render(into:count:)`. The internals VIS-1 names. |
| `SeededGenerator` (`Sources/ZTronDSPTesting/SeededSignals.swift:6`) | `state` | Unchanged, `@usableFromInline`: the state of a `RandomNumberGenerator`, advanced by the `@inlinable` `next()` that the protocol makes `mutating`; a utility of the test product, outside the kinds IMM-1 names, spelled as VIS-1 spells the internals of inlinable code. |

None of the five is a stage, pipeline, design, system, window, report or table except `DSPEnvironment`'s
role in a pipeline's scope, and there the values were already replaced, never changed; the change makes the
type say so.

**Public `mutating` members** (all of them, from the digests): `AudioBlock.copy(from:)`,
`AudioBlock.setFrameCount(_:)`, `Ramp`'s five and `SeededGenerator`'s three (the state above);
`FrameWriter.emit(…)` and `LoweringContext.emit(_:)` (identities: the call writes through them);
`FeatureStream.Iterator.next()` (`AsyncIteratorProtocol`); and `DynamicPipeline.append(…)`, four overloads.
`DynamicPipeline` is a pipeline, so IMM-1 applies to it: its stored properties are `let`
(`DynamicPipeline.swift:15`, `:17`), and each `append` is `self = try appending(…)` (`:66`–`:84`), the
variable given a new value made by the non-mutating `appending(…)`. No value changes under anyone who holds
it. ORD-5 names `append(_:)`; nothing to change.

**Classes.** The 26 public classes are all `final`: `AlignedBuffer`, `AudioBuffer`, `BufferSource`,
`DSPEngine`, `EngineNodeTapSource`, `FeatureCallback`, `FeatureStream`, `FeedObservation`, `FileSource`,
`Framer`, `GeneratorSource`, `HardwareInputSource`, `HeatmapFeed`, `HeatmapRenderer`, `HistoryBuffer`,
`MetalContext`, `OffscreenTarget`, `OverlapAdder`, `PipelineSession`, `ProcessedSource`, `RenderProbe`,
`ScriptedSource`, `SourceEventChannel`, `ThreadAllocationAudit`, `WaveformFeed`, `WaveformRenderer`. None is
one of the kinds IMM-1 makes values.

## 3. The registers (brief item 909.2)

### 3.1 `Docs/Process/mutable-by-design.md`

Empty before this package and empty now, as the process self-test requires ("must stay empty unless a change
request says otherwise", `Scripts/tests/test-process-files.sh`, WP-008). Its introduction now also says what
a row would be for under IMM-1: a stored `var` of a public struct that its module can set, other than a
private or file-private one and other than a `@usableFromInline` one (VIS-1). A first draft of this audit
entered the six `@usableFromInline` properties of section 2 as rows; that self-test failed on them ("exists
and is empty (6 rows)"), and the six are not exceptions to a rule but what VIS-1 prescribes, so the lint
accepts the attribute (section 6) and the rows were taken out. Nothing here waits for a change request.

### 3.2 `Docs/Process/open-declarations.md`

Empty, as VIS-1 requires; no `open` declaration in `Sources/` (lint part 4).

### 3.3 `Docs/Process/approvals.md` (§9.5, APR-1, APR-2)

Empty; nothing approval-gated is used: no `AnyView`, `import Combine`, `ObservableObject`, `@Published`,
`AnyPublisher` or `PassthroughSubject` in `Sources/`, `Examples/` or `ExternalParity/` (a search of the
`.swift` files finds none; lint part 3 is clean).

### 3.4 `Docs/Process/unchecked-sendable.md`

22 rows, one for each `@unchecked Sendable` in `Sources/`, each naming a type that exists at its file (lint
part 4 matches both ways). Every type was read against its row:

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

The 14 rows "as written" were left as they are. The new texts of the 8 are in the register. None of the
corrections is a defect of the code: each type does what its declaration allows; the rows said less than the
code does, or something else. The public documentation of `ScriptedSource` says that `render` allocates and
not that it takes a lock: that is a documentation comment (WP-901b) and is left for it (section 8).

## 4. IMM-4: a running plan is changed only by commands (brief item 909.3)

Read: `Sources/ZTronDSPCore/Engine` (with `Engine/Run`) and `Sources/ZTronDSPCore/Compiler`.

- **What reaches a running plan.** The analysis thread runs a session's block in `SessionRunner.run(_:)`
  (`SessionRunner.swift:155`), which first calls `boundary()` (:177). There, and only there, it takes a plan
  from the `plans` hand-off, drains the two command queues (`drain(values, next)`, `drain(switches, next)`)
  and accepts the new plan (`accept(_:)`, :192; `install(_:outputChanged:)`, :246). `apply(_:_:)` (:296)
  hands each command to the plan of its generation: `ZTD_COMMAND_SET_ACTIVE` to `PlanRunner.setSwitch(_:_:)`
  (`PlanRunner.swift:131`), every other to `PlanRunner.applyValues(_:)` (:192), which passes it to the C plan
  (`ztd_plan_command`). Nothing else of a plan is written on the analysis thread.
- **Who sends commands.** Values: `EngineCore.sendValues(of:replacing:to:)` (`EngineCore.swift:829`) and
  `send(_:to:of:)` (:846), `ZTD_COMMAND_SET_VALUES` into the session's `values` queue (:853). Switches: the
  binding pump on the main thread, `BindingPump.sample()` (`BindingPump.swift:196`, the command at :205–210).
- **When an update is a command and when it is a new plan.** `EngineCore.update(_:to:)` (:641) asks
  `beginUpdate(_:_:)` (:657): an equal pipeline only re-captures its bindings
  (`ExecutionPlan.adoptBindings(resolved:switches:results:)`, `ExecutionPlan.swift:669`); the same structure
  with other values sends the values as commands when the plan has a kernel for each
  (`canTakeValues(of:)`, :683; `sendValues`; then `adoptValues(of:)`, :693); anything else is compiled, and
  `exchange(_:_:_:_:)` (`EngineCore.swift:702`) builds a new `ExecutionPlan` (:724) and publishes it (:754),
  to be exchanged at a block boundary (SWAP-1…4). Recompiling after a format change does the same
  (`recompile(_:)`, :1019: a new plan at :1029, published at :1036), and so does the first plan of a session
  (`register`, :103 and :107).
- **The control side of a plan.** `adoptBindings`, `adoptValues` and `takeArrivals` (`ExecutionPlan.swift:702`)
  change what the control context records of the plan (its `lowered` description, `KernelBox.source`,
  `PlanStructures.swift:14`: "A change of values replaces it (control context)"); the analysis thread reads
  neither. The plan's shape is fixed: "A plan is immutable in shape: a structural change is a new plan
  (IMM-4)" (`ExecutionPlan.swift:36`–`37`).
- **The one other write**, `PlanRunner.resetAll()` (`PlanRunner.swift:235`), sets the state of every kernel
  back for a cold start (ACT-10). It is called from `EngineCore.coldStart(_:)` (`EngineCore.swift:605`) only
  while the session is off its thread, so it never meets a running plan; it changes neither shape nor values.
- **When nobody takes commands** (a session not scheduled, or a hub not live, or a full queue), the commands
  are still the carrier: `sendValues` and `send` pause the hub, apply the queue with `settleDirectly(_:)` and
  resume it (`EngineCore.swift:836`–`841`, `:856`–`860`).

IMM-4 holds.

## 5. IMM-5: the environment is a value, threaded as copies (brief item 909.3)

- `DSPEnvironment` is a struct (`DSPEnvironment.swift:28`) whose stored properties now have private setters
  (section 2). Every change of it returns a new environment: `setting(_:to:)` (two forms, :122, :138) and the
  positional changes `withFormat(_:)` (:145), `withChannelCount(_:)` (:152), `withBlockSize(_:)` (:158),
  `withSource(kind:isRealTime:)` (:164), `changingRate(interpolation:decimation:)` (:172),
  `enteringSpectralScope(frameSize:hopSize:axis:)` (:179), `replacingAxis(_:)` (:189),
  `leavingSpectralScope(channelCount:)` (:196), `beginningFeatureSequence(rate:)` (:207),
  `addingLatency(_:)` (:217), `restoringOverrides(of:)` (:225) and `applyingOverrides(of:)` (:233), each
  `var copy = self … return copy`. None is `mutating`.
- `.environment(_:_:)` returns a new pipeline: `Pipeline.environment(_:_:)` (`Structure.swift:122`) builds a
  new `Pipeline(unchecked:)` and leaves its receiver unchanged; `Group.environment(_:_:)` (:93) returns a new
  `Group`.
- The compiler threads copies: `PlanCompiler.lower(_:environment:blockSize:)` (`PlanCompiler.swift:57`) starts
  a `Cursor` (:10, a struct holding the environment by value) and `walk` (:77) moves it. A reader is handed
  the environment where it stands (`box.make(cursor.environment)`, :163); a tap walks a copy of the cursor
  (`var branch = cursor`, :166), so its branch never changes the main line's environment; a group lays its
  overrides over a copy of the outer environment and restores the outer overrides when it ends
  (`applyingOverrides(of:)`, `restoringOverrides(of:)`, :172–184); after a stage the cursor takes the
  environment the kernel spec implies, `LoweringContext.environment(after:from:)` (`LoweringContext.swift:79`,
  used at `PlanCompiler.swift:239` and `LoweringContext.swift:59`). A stage reads its environment through
  `LoweringContext.environment`, a computed property with no setter (`LoweringContext.swift:35`).
- The engine keeps the environment of a session as a value behind its lock (`SessionCore.environment`,
  `SessionCore.swift:140`) and derives it from a plan by value (`SessionCore.environment(of:)`, :115).

IMM-5 holds.

## 6. What is now mechanised (brief item 909.4)

The lint's part 4 missed what section 2 found by reading: a stored `var` with an internal or package setter
in a public struct (IMM-1 as the brief reads it), and a public stored `var` whose setter is restricted
(`public private(set) var`; IMM-2 says no public stored property of a value type is `var`).
`Scripts/lib/lint_bans.py` now reports both, against the same register:

- `[IMM-2] `T.p` is a public stored `var` of a value type: it is `let`, or it has an entry in
  Docs/Process/mutable-by-design.md`;
- `[IMM-1] `T.p` is a stored `var` of a public value type that the module can set: it is `let`,
  `private(set)` or `fileprivate(set)`, `@usableFromInline` when `@inlinable` code sets it (VIS-1), or it
  has an entry in Docs/Process/mutable-by-design.md`.

Stored means no accessor block, or a block of `willSet`/`didSet` only; static properties, computed
properties (with or without a setter), and the properties of internal types and of classes are not reported.
A type declared in a public extension counts as public. A `@usableFromInline` stored `var` is not reported
under IMM-1: it is the spelling VIS-1 prescribes for the internals of a toolkit primitive or a frame
accessor, which its `@inlinable` code sets (state, IMM-3). On the way, `qualified()` named a member of a nested type twice (`Ramp.Ramp.Phase.radians`); it now takes the
innermost type's name, which is already qualified.

Seeded cases: `Tests/Fixtures/Lint/part4/Sources/ZTronDSPCore/Values/Frequency.swift` (11 reported lines,
3 under IMM-2 and 8 under IMM-1, each marked `// !! IMM-1` or `// !! IMM-2`; every other declaration of the
file is a shape that is not reported: a private or file-private setter, two `@usableFromInline` ones, `let`,
static, computed with and without a setter, an internal type, a class); the clean tree's `Frequency.swift`
shows the accepted spellings; the registered tree holds `Ramp.swift` with two register rows, one of them on
a nested type. `Scripts/tests/test-lint-bans.sh` checks the trees and, new, nine messages and absences. What
each change catches when undone is in `impl-WP-901a-909.md`, section 2.

## 7. Violations and what became of them

| Rule | Finding | What became of it |
|---|---|---|
| API-6 | none | — |
| IMM-1 | `DSPEnvironment`: 10 stored `var`s the module could set | `private(set)` |
| IMM-1 | `FeedCursor`: 3 stored `var`s the module could set | `fileprivate(set)` |
| IMM-1 | `AudioBlock.frames`, `Ramp` ×4, `SeededGenerator.state`: `@usableFromInline` state of inlinable code | not a violation (VIS-1 prescribes the spelling); the lint accepts it, the register stays empty |
| IMM-2 | none | — |
| VIS-1 | none (`open-declarations.md` empty) | — |
| APR-1, APR-2 | none (`approvals.md` empty) | — |
| §9.2 | 8 rows of `unchecked-sendable.md` said what the code does not do | rewritten; the internal comment of `UnfairLock` corrected |
| IMM-4, IMM-5 | none | — |

## 8. Open

- WP-901b: the documentation comment of `ScriptedSource` (public) says that `render` sends events and
  allocates, and not that it takes the lock of the format when the script changes it (section 3.4). Recorded
  in the ledger's backlog of WP-909.
- IMM-3 is not an item of the brief and is not ruled on here; section 2 gives the place in it of the six
  `@usableFromInline` properties, as their types' own comments do.
