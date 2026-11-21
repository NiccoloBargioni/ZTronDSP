# Extension guide

How to add to ZTronDSP from outside it: one example for every row of the table in §5.11.1 of the
specification, in the order of that table.

Every example here is real code. It lives in `ExternalParity/`, a package of its own inside this
repository that depends on ZTronDSP by path and on its three products only, as an app does: no
`@testable import`, no `@_spi`, no internal symbol. Each example is compiled there, in Debug and
in Release, and run by a test there. The code blocks of this guide are not copies that can go
stale: this file is generated from `Docs/ExtensionGuide.template.md`, which holds the text and
names each region, by `python3 Scripts/lib/extension_guide.py`; edit the template, never this
file. `Scripts/external-parity.sh --step guide` fails when a block differs by one character from
the marked region of the file it names, or the file from what the template makes. The same
script builds the examples, runs their tests, their must-not-compile fixtures and their
allocation audits (CI gate 9).

| Row of §5.11.1 | Example | Source | Tested by |
|---|---|---|---|
| A step between domains | `SpectralFlux` | `Sources/ExtensionGuide/Nodes/SpectralFlux.swift` | suite "Guide 1" |
| A sample-domain stage in Swift | `Despike` | `Sources/ExtensionGuide/Kernels/Despike.swift` | suite "Guide 2" |
| A sample-domain stage in C | `FeedbackComb` | `Sources/CExtensionGuide/extg_comb.c`, `Sources/ExtensionGuide/Kernels/FeedbackComb.swift` | suite "Guide 3" |
| A context-dependent family | `PeakNormalize` | `Sources/ExtensionGuide/Nodes/PeakNormalize.swift` | suite "Guide 4" |
| A sink | `PeakHoldMeter` | `Sources/ExtensionGuide/Nodes/PeakHoldMeter.swift` | suite "Guide 5" |
| A source | `ClickSource` | `Sources/ExtensionGuide/Kernels/ClickSource.swift` | suite "Guide 6" |
| A design or a strategy | `CriticallyDampedFamily` | `Sources/ExtensionGuide/Designs/CriticallyDampedFamily.swift` | suite "Guide 7" |
| A window | `Window.sine` | `Sources/ExtensionGuide/Designs/SineWindow.swift` | suite "Guide 8" |
| An inverse with its report | `PreEmphasis`, `DeEmphasis` | `Sources/ExtensionGuide/Designs/PreEmphasis.swift` | suite "Guide 9" |
| An export | `NoveltyCurve` | `Sources/ExtensionGuide/Designs/NoveltyCurve.swift` | suite "Guide 10" |
| A display | `NormalizedSpectrogram` | `Sources/ExtensionGuideUI/NormalizedSpectrogram.swift` | suite "Guide 11" |

Paths are relative to `ExternalParity/`. The suites are in `Tests/ExtensionGuideTests`; the audits of
everything that runs on the analysis thread are in its suite "Guide allocation audit".

## Before you start

**The package.** A package that extends ZTronDSP names it as a dependency and its products as the
dependencies of its targets. Nothing else is needed, and nothing else is used here.

<!-- snippet: ExternalParity/Package.swift#manifest-dependency -->

<!-- snippet: ExternalParity/Package.swift#manifest-targets -->

`ZTronDSP` is everything but the views; `ZTronDSPUI` is the views; `ZTronDSPTesting` is what the
stock stages are tested with (EXT-3). A C target that depends on the product `ZTronDSP` includes
the kernel ABI by name, `#include "ztd_kernel.h"`, and, to call vDSP from non-blocking code,
`#include "ztd_vdsp.h"`: the vDSP entry points ZTronDSP's own kernels call, declared
`ZTD_NONBLOCKING`, each with the audit that holds the claim (row 3).

**The four contexts.** Every declaration of ZTronDSP says where it may be called (VIS-2), and
every example below says where each of its parts runs. There are four places:

- The **control context**: where pipelines are attached and plans are compiled. `lower(_:)`, the
  closures that create kernels, processors and nodes, a sink's `claim` and `release`, a source's
  `prepare`, `start` and `stop` run here. Allocation is allowed.
- The **analysis thread**: where plans run, block by block. A node's and a processor's `process`
  and `reset`, a kernel's `process`, `command` and `reset`, a sink's `write` and a pull source's
  `render` run here. RT-2 binds all of them: no allocation, no lock, no logging, no `await`.
  Whatever they need is allocated before, on the control context (RT-3).
- The **main actor**: views, and the bindings a pipeline reads its switches from.
- The **background executor**: designs asked for by themselves, analyses, reports and exports
  (BG-1). Work there can be cancelled (BG-3).

**The values.** Stages, designs, windows and reports are immutable values: `Hashable`,
`Sendable`, with `let` storage (IMM-1). A setting is a labelled argument with a default or a
strategy value that answers one question, never an object that carries settings (API-6). Every
stage takes its switch as a trailing `isActive: some ActivationSource = .active` (§5.9).

**The folders.** The examples that run on the analysis thread are in folders named `Kernels` and
`Nodes`. That is where `Scripts/lint-bans.sh` applies the hot-path bans, and
`Scripts/external-parity.sh --step rules` runs it over the external package: a `for … in` loop
there fails the lint, because in a Debug build such a loop allocates on every iteration (CR-002).
Loops on the analysis thread are `while` loops.

## 1. A step between domains

| | |
|---|---|
| Conform to, or use | `PipelineStage`, which names its `Input` and its `Output`; in `lower(_:)` it emits `.analysis(AnalysisStep(…))`, whose closure makes the `AnalysisNode` that runs |
| Runs on | `lower(_:)` and the closure that makes the node: control context. The node's `process(_:_:)` and `reset()`: analysis thread |
| Supplies | `Input` and `Output`; the node; what the node writes (`output:`) and the scope it opens for what follows (`scope:`); a `key` that is equal for nodes that are interchangeable |
| Latency and settling | The node's `latencyFrames`, in frames of its input: 0 here. Its `settlingFrames`, the input frames it needs after a reset before its output is what it would have been had it always run: 1 here |
| Threading contract | The stage is an immutable value, usable on any thread. The node is created on the control context, where it allocates all it will ever need, and from then on belongs to the analysis thread, one thread at a time; `process` and `reset` are bound by RT-2, and their loops are `while` loops |

`SpectralFlux` takes a magnitude spectrum and gives one value per frame: how much the bins rose
since the frame before. Its output domain is `Novelty`, a sampled sequence at the feature rate,
so whatever runs on a sampled sequence follows it: a stock low-pass, with a cutoff that is a
frequency of the curve and is checked against the curve's Nyquist frequency (ENV-1).

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/SpectralFlux.swift#flux-stage -->

The stage reads the positional environment in `lower(_:)`: how many bins arrive, how often. It
states what leaves it, and hands the plan a closure that makes the node. The closure throws
`DSPError`, typed, and the stage's own errors carry `context.path`, so an error names the stage
and its place in the pipeline.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/SpectralFlux.swift#flux-node -->

A node may write no frame for an input, or several. This one writes none for the first frame
after a cold start, which has nothing to be compared with, and says so with a settling time of
one frame.

What the stage did not write and has: its place is checked by the compiler (tier 1: after a
power spectrum it does not compile, and the sentence is the core's "This stage takes another
domain than the pipeline delivers at this point.") and again when a pipeline assembled from data
is attached (tier 2: `DSPError.invalidStageOrder` with the stage's path). Its switch works: it
changes the domain, so switched off it suspends the rest of its branch (ACT-3), and switched on
again the node starts cold (ACT-10). Both are tested.

## 2. A sample-domain stage in Swift

| | |
|---|---|
| Conform to, or use | `SequenceStage` for the description; `SampleProcessor` for what runs, refined by `OutOfPlaceSampleProcessor` for a processor that reads one block and writes another, and by `AdjustableSampleProcessor` for one that takes values while it runs. `lower(_:)` emits `.processor(CustomProcessor(…))` |
| Runs on | `lower(_:)` and the closure that makes the processor: control context. `process(_:)`, `process(_:into:)`, `setValues(_:)` and `reset()`: analysis thread |
| Supplies | `process(_:)` on a block, in place, or `process(_:into:)` out of place; `reset()`; the latency; a `key`; the values, if the stage has any, and `setValues(_:)` |
| Latency and settling | `latencyFrames` is stated twice, by the `CustomProcessor` description (for the environment downstream) and by the processor that runs; a plan in which the two differ is refused. 1 frame here. `settlingFrames`: 2 here |
| Threading contract | The stage is an immutable value, usable on any thread. The processor is created on the control context, where it allocates its memory once and meets whatever its first `process` needs; `process`, `setValues` and `reset` belong to the analysis thread, one thread at a time, under RT-2, with `while` loops |

`Despike` replaces every sample by the median of itself and its two neighbours: not a linear
filter, so no stock kernel computes it. A sequence stage runs on any sampled sequence (samples,
a novelty curve, a scalar track) and keeps its domain.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/Despike.swift#despike-stage -->

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/Despike.swift#despike-processor -->

`make` runs on the control context, and so does the block of silence it hands the processor:
whatever a first `process` asks of the Swift runtime (the metadata of a generic type, a protocol
conformance it looks up) happens there, not on the analysis thread, and the reset forgets the
block. "Checking what you wrote" shows how to hold that.

What the stage did not write and has: its latency is in `session.environment.latency` (REAL-5).
Switched off, the signal passes through a delay of the stage's latency, so nothing downstream
moves in time (ACT-8); off and on are cross-fades of 10 ms, and on the way back the processor is
reset and pre-rolled for its latency and settling time, in whole blocks (ACT-7).

Its place is checked too. After a spectrum a sequence stage does not compile, and the compiler
gives the sentence the core has for every sequence stage, which names the kind ("A sequence
stage (a gain, a filter, a smoother, a rate changer) runs on a sampled sequence"): that is what
`FeedbackComb` of the next row gets. One unavailable overload makes the sentence name the stage
(ORD-4):

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/Despike.swift#despike-sentence -->

A `SampleProcessor` works on the block in place, and a kernel is handed an input and an output,
so the plan copies each block from the one to the other before it calls the processor. For a
stage as small as a gain that copy costs about what the multiplication costs: written in place,
the gain of the parity suite measured 1.7 to 1.8 times the stock gain. A processor that also
conforms to `OutOfPlaceSampleProcessor` is handed both blocks, and nothing is copied in front of
it. Written so, the gain of the parity suite takes ×1.01 to ×1.08 the stock gain's time on
blocks of 512 frames, round by round, in nine launches of the suite's speed check on
2026-11-21: at the 5 % bound of §5.7, and over it in five of the nine. What is left is the cost
of calling a processor, since the same multiplication on the kernel ABI is within the bound;
the suite states the miss as a known issue (CR-025 item 1). That is how `ExternalGain` is
written:

<!-- snippet: ExternalParity/Sources/ExternalStages/Kernels/ExternalGain.swift#gain-out-of-place -->

The same processor takes values while it runs, as the stock gain takes its amount (§5.5.4). Its
description states them apart from its key, with `CustomProcessor(name:key:values:latencyFrames:make:)`;
`make` is handed them and returns an `AdjustableSampleProcessor`. Another value of the same
structure (the name, the key, the latency, the number of values) is then a value update: no plan
is compiled, and the processor that runs is handed the new values through `setValues(_:)`, on the
analysis thread between two blocks, and keeps its state. A processor that is moved into a later
plan keeps the values it was sent last. The gain moves to a new amount over its ramp, frame by
frame as the stock gain kernel does, so a sink behind it hears every frame (CLICK-1); another
ramp is another processor:

<!-- snippet: ExternalParity/Sources/ExternalStages/Kernels/ExternalGain.swift#gain-values -->

## 3. A sample-domain stage in C

| | |
|---|---|
| Conform to, or use | `SequenceStage` with a `ztd_kernel_t`: `lower(_:)` emits `.custom(CustomKernel(…))`, whose closure returns the kernel. The ABI is `ztd_kernel.h`, a public header of the product `ZTronDSP`; a kernel that calls vDSP from its non-blocking code includes `ztd_vdsp.h`, the audited list of the vDSP entry points declared `ZTD_NONBLOCKING` |
| Runs on | The closure and the kernel's `destroy`: control context. The kernel's `process`, `command` and `reset`: analysis thread (the I/O thread too, should D-1 land) |
| Supplies | The kernel table and its state: `process`, `reset`, `destroy`, `state`, `latency_frames`, `settling_frames`; `command`, which takes the values the description states (`CustomKernel(name:key:values:…)`), and may stay null for a kernel without values |
| Latency and settling | `latency_frames` must equal the `latencyFrames` of the `CustomKernel`: 0 here. `settling_frames` is what a plan pre-rolls the kernel for before it is faded in: here the time an echo takes to decay by 100 dB |
| Threading contract | Creation allocates everything, on the control context, and touches it, so that the analysis thread never takes a page fault. `process` and `reset` are declared `ZTD_NONBLOCKING` and belong to the analysis thread, one thread at a time. `destroy` is the only place the kernel frees: control context |

`FeedbackComb` is a feedback comb filter, y[n] = x[n] + g·y[n − D]. The C target turns
function-effect warnings into errors, as the C target of ZTronDSP does: a `ZTD_NONBLOCKING`
function that allocates, or calls a function that is not itself non-blocking, does not build
(RT-1).

<!-- snippet: ExternalParity/Package.swift#manifest-kernel-settings -->

<!-- snippet: ExternalParity/Sources/CExtensionGuide/include/CExtensionGuide.h#comb-header -->

<!-- snippet: ExternalParity/Sources/CExtensionGuide/extg_comb.c#comb-kernel -->

State hygiene is the kernel's (RT-6): a value below `ZTD_STATE_FLOOR` enters the ring as zero, so
the kernel never computes on denormal numbers. A kernel whose `process` is null is what a failed
creation returns; the plan reports it as a failed allocation.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/FeedbackComb.swift#comb-stage -->

The stage turns seconds into frames at the sample rate of its own position, validates its
arguments with errors that name it (`context.invalid`), and gives the kernel a key: two
descriptions with equal names and keys are the same kernel, which then moves into a new plan
with its state when something else in the pipeline changes (SWAP-1). The Swift target imports the
C target with `internal import`, so the C module is no part of the Swift module's interface.

What the stage did not write and has: order checking, activation, and the pre-roll. Switched on,
the comb is reset, runs with its output discarded for the 816 frames it declares (in whole
blocks), and only then is faded in; the test holds the engine to that count.

The comb keeps its feedback in its key, so another feedback is another kernel: the session
compiles a plan, pre-rolls the new kernel and cross-fades to it, and a sink behind the stage hears
nothing meanwhile. A kernel of your own can instead take values while it runs, as a stock filter
takes its coefficients (§5.5.4). The description states them apart from its key, with
`CustomKernel(name:key:values:…)`, and `make` is handed the values of the description. Another
value of the same structure (the name, the key, the rate ratio, the latency, the number of
values) then reaches the kernel that runs at a block boundary, as `ZTD_COMMAND_SET_VALUES` with
`count` doubles at `values`: no plan is compiled, and nothing behind the stage misses a frame. A
kernel that is moved into a later plan keeps the values it was sent last. The low-pass of the
parity suite takes its coefficients that way, and keeps its memory:

<!-- snippet: ExternalParity/Sources/ExternalStages/Kernels/ExternalLowPass.swift#lowpass-values -->

<!-- snippet: ExternalParity/Sources/CExternalKernels/extk_biquad.c#biquad-command -->

It calls vDSP from its non-blocking functions through the public allow-list, as the kernels of
ZTronDSP do, and the allocation audit of the suite runs every entry point it uses:

<!-- snippet: ExternalParity/Sources/CExternalKernels/extk_biquad.c#biquad-vdsp -->

## 4. A context-dependent family

| | |
|---|---|
| Conform to, or use | `ContextDependentStep` for the value, and extensions of `PipelineBuilder` and of `Pipeline` for its typing |
| Runs on | Nothing of the family runs: the builder overload and the fluent method are resolved by the compiler, and the `DomainRule` is evaluated on the control context when a pipeline is attached. The node the step emits runs on the analysis thread |
| Supplies | One constraint on the consumed domain, one builder overload, one fluent method, one `DomainRule` (ORD-1); and the sentence for a wrong place, as unavailable overloads (ORD-4) |
| Latency and settling | Those of the node the step emits: 0 and 0 here |
| Threading contract | The step is an immutable value, and its rule a pure function: both usable on any thread. The node is as in row 1 |

`PeakNormalize` scales every frame of magnitudes or powers so that its largest value is 1, on
whatever axis the frame has. What it produces depends on what it follows, so it names no `Input`
and no `Output`: it is a family.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/PeakNormalize.swift#normalize-step -->

The typing rule is written three times and means one thing each time: for the compiler in a
builder block, for the compiler in a fluent chain, and as the `DomainRule` that the description
carries for pipelines assembled from data (tier 2).

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/PeakNormalize.swift#normalize-family -->

The two unavailable overloads are what turns "no exact matches in call to static method
buildPartialBlock" into a sentence that names the step and says what it needs. The fixtures hold
the compiler to the sentence. A step of a family cannot open a block, because its domains depend
on the stage before it: begin a branch with the stage it follows, or write the branch fluently.

What the step did not write and has: it keeps the domain, so switched off the frames pass as
they are (ACT-3).

## 5. A sink

| | |
|---|---|
| Conform to, or use | `FeatureSink`, handed to `Emit(to:)` or `.emit(to:)` |
| Runs on | `write(_:)`: analysis thread. `claim(axis:environment:)` and `release()`: control context |
| Supplies | The `Domain` whose frames it takes; `write(_:)`; claim and release (ATT-5) |
| Latency and settling | A sink adds none. The environment it is claimed with carries the latency of the pipeline up to its `Emit` (ENV-4) |
| Threading contract | `write` is bound by RT-2 and is handed a borrowed view, valid for the call: copy what must outlive it. A sink is read from other threads, so its state is single atomic words or a ring with one writer, and a class that says `@unchecked Sendable` writes its contract at the declaration |

`PeakHoldMeter` takes a scalar track and keeps the newest value and the largest one. Its `Domain`
is `Scalar`, so `Emit(to:)` compiles only after a scalar track.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/PeakHoldMeter.swift#meter-sink -->

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/SinkAndSourceExampleTests.swift#meter-use -->

What the sink did not write and has: one writer at a time. The engine lets one live attachment
write a sink and refuses a second with `DSPError.sinkInUse(sink: "PeakHoldMeter")`; the claim ends
when the attachment is detached. A sink of your own is told three things: that it is claimed,
each frame, and that it is released.

## 6. A source

| | |
|---|---|
| Conform to, or use | `PullSampleSource` for a source the engine clocks, as here; `PushSampleSource` for one that has a clock of its own and writes into the ring the engine hands it (§4.4) |
| Runs on | `render(into:)`: the analysis thread for `.realTime` pacing, a thread of the session's own for `.asFastAsPossible`. `prepare()`, `start()` and `stop()`: control context |
| Supplies | `format`, `events`, `prepare()`, `start()`, `stop()`; for a pull source `pacing` and `render(into:)`, for a push source `connect(to:)` |
| Latency and settling | A source states none. `prepare()` is called again before a session that finished is started anew: a source that has an end starts over there |
| Threading contract | `render` is bound by RT-2: memory and arithmetic only. `prepare`, `start` and `stop` are called one at a time while the source does not render. What `render` and `prepare` both touch is therefore never touched at once, which is the contract a class that says `@unchecked Sendable` writes down |

`ClickSource` is a metronome: clicks at a tempo, for a time.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/ClickSource.swift#click-source -->

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/SinkAndSourceExampleTests.swift#source-use -->

What the source did not write and has: an engine clocks it to its end and finishes the session;
`processed(by:)` makes a processed source of it (SRC-2); any pipeline analyses it. A push source
written on the public API is `HandFedSource` in `Tests/ExternalTestSupport/Support.swift`, which
the suites feed by hand to place a switch or an update at a known block.

## 7. A design or a strategy

| | |
|---|---|
| Conform to, or use | The protocol of the question that is answered: `FilterFamily` here; `FIRDesignMethod`, `MedianStrategy`, `FFTBackend`, `ColorMap` and the others of §5.3 work the same way |
| Runs on | Control context, when a plan that holds the design is compiled; the background executor, when a design is asked for by itself |
| Supplies | The protocol's members. A filter family supplies one: its analog low-pass prototype with its edge at 1 rad/s. `orderStrategy` and `fitted(maximumLoss:minimumAttenuation:)` have defaults |
| Latency and settling | A strategy has none of its own. The stock stage that takes it states them: for an IIR filter no latency, and a settling time from its poles |
| Threading contract | An immutable value, `Hashable` and `Sendable`, usable on any thread. Designing allocates and belongs to the control context or the background executor, never to the analysis thread |

`CriticallyDampedFamily` puts every pole of its prototype on one real point. The frequency
transformation, the bilinear transform with its pre-warping and the pairing into sections are the
package's, the same as for a stock family, so the family works wherever a family is asked for:
`LowPass`, `HighPass`, `IIRDesign`.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/CriticallyDampedFamily.swift#damped-family -->

The static member on the protocol is what lets a call site write `.criticallyDamped` where it
writes `.butterworth`. The tests hold the family to what it promises: −3 dB at the cutoff at
orders 1, 2, 4 and 8, as a low-pass and as a high-pass, and a step response that never overshoots
where a Butterworth filter of the same order overshoots by a tenth.

## 8. A window

| | |
|---|---|
| Conform to, or use | `Window.custom { t in … }` |
| Runs on | Control context: the closure is evaluated once per sample, in double precision, when a plan that holds the window is compiled; and wherever `samples(count:)` or `analysis(frame:hop:)` is called |
| Supplies | A closure of `t`, which runs from 0 to 1 across the frame (§6.4.2) |
| Latency and settling | A window has none. The transform that holds it has: an `STFT` followed by an `InverseSTFT` delays by frame − hop samples and says so |
| Threading contract | The closure is `@Sendable` and pure: it is called on the control context, and at 65 probe points wherever two windows are compared (WIN-2). The window is an immutable value, usable on any thread |

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/SineWindow.swift#sine-window -->

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/SineWindow.swift#sine-window-use -->

A window that is zero everywhere, or not finite somewhere, is refused when it is sampled (WIN-3).
A window used for synthesis has to satisfy the non-zero overlap-add condition with its hop: the
sine window does at half a frame, where its squares add up to one, and does not at a whole frame,
where the first sample of every frame is lost under the window's zero. That pair is refused when
the pipeline is attached (O-17), and `STFT(frame:hop:window:).inversionReport(for:)` says why
before anything runs. `Window.sine.analysis(frame:hop:)` gives the figures of the window: the
test holds them to the textbook (a coherent gain of 2/π, side lobes from −23 dB that fall by
12 dB per octave).

## 9. An inverse with its report

| | |
|---|---|
| Conform to, or use | `InvertibleStage` |
| Runs on | The background executor: `inversionConditions(in:)` and `inversionRoundTrip(in:)` are called from `inversionReport(for:sampleRate:)`, which may be awaited from any context, the main actor included |
| Supplies | The inverse stage, with the values it needs to match; the conditions under which it recovers the input, each with its theorem, its verdict, its margin and the error it predicts; the round trip on the signal of the report (§6.13) |
| Latency and settling | Those of the two stages. Here both lower to one section of the stock biquad cascade: no latency, and the settling time the stock kernel computes from the section |
| Threading contract | Both requirements run in background work: they may allocate and compile plans, and call `context.check()` between their steps so that a cancelled report stops (BG-3). The stages and the report are immutable values |

`PreEmphasis` is y[n] = x[n] − a·x[n − 1]; `DeEmphasis` undoes it. Neither has a kernel of its
own: they lower to a stock kernel spec.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/PreEmphasis.swift#emphasis-stages -->

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/PreEmphasis.swift#emphasis-inverse -->

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/DesignExampleTests.swift#report-use -->

A condition that fails is part of the report, not an error (INV-3): for a coefficient of 1.25 the
report says that there is no stable inverse, with a margin of −0.25, and measures nothing. The
report exports as a MATLAB script like a stock one (INV-4).

A stage that lowers to stock kernel specs is fused and switched like a stock stage, and it takes
a changed value in place (EXT-2): a session that is handed the same pipeline with another
coefficient sends the coefficient to the kernel that runs. No plan is compiled, and a sink behind
the stage misses no frame. The test holds the engine to that.

## 10. An export

| | |
|---|---|
| Conform to, or use | `MATLABExportable`; the script is built with `MATLABScript` inside `BackgroundWork.run` |
| Runs on | The background executor. `matlabScript()` may be awaited from any context |
| Supplies | Variables, then plot commands (§6.14) |
| Latency and settling | None: an export is not on the signal path |
| Threading contract | The exported value is `Sendable`. The work never runs on the main thread or on the analysis thread (BG-1, MAT-6), and stops at its next `checkpoint.check()` when the task that awaits it is cancelled (BG-3) |

`NoveltyCurve` is a curve as an app keeps it, for instance the values `SpectralFlux` delivered.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/NoveltyCurve.swift#novelty-export -->

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/DesignExampleTests.swift#export-use -->

`MATLABScript` keeps the rules of §6.14 for whoever builds a script with it: core MATLAB only, so
the script also runs in GNU Octave (MAT-2); numbers written so that they read back exactly, which
the test checks value by value (MAT-3); no date and no machine name, so equal curves give equal
text (MAT-4); at most four million elements per variable. The package writes no file: the text is
the app's (MAT-5).

## 11. A display

| | |
|---|---|
| Conform to, or use | `HeatmapView(feed:)`, or `WaveformView(feed:)` for an envelope, with the appearance modifiers of `ZTronDSPUI` and `.pipeline(_:on:)` |
| Runs on | The main actor. The pipeline the view hosts runs on the engine's analysis thread |
| Supplies | A feed, and the pipeline that writes it |
| Latency and settling | A view has none. The feed carries the environment at its `Emit`, the latency up to that point included (ENV-4) |
| Threading contract | Main actor, like every view. The view stores the identity of its source and of its feed and nothing of their contents, so its body depends on no per-frame data (V-1); the renderer polls the feed (V-2). A feed has one writer (ATT-5): build the pipeline in a function of its sink, so that one description serves several sources, each with a feed of its own |

`NormalizedSpectrogram` is a spectrogram whose every column is scaled to its own peak. Nothing
is drawn by the example: the display is the stock heat map, and what is new is the step in front
of the feed, `PeakNormalize` of row 4, and a value range to match.

<!-- snippet: ExternalParity/Sources/ExtensionGuideUI/NormalizedSpectrogram.swift#spectrogram-view -->

<!-- snippet: ExternalParity/Tests/CompileFixtures/valid/GuideExamplesWhereTheyStand.swift#use-display -->

SwiftUI is imported by this one target. The view is `Equatable` by the objects it shows, as the
stock views are (V-1). The tests build the view and run the analysis behind it on an engine:
every column of the feed peaks at 1 or is silence, whatever the level of the signal. They do not
put the view on a screen.

## Where the examples stand

The examples are used like stock stages: in a builder block and in a fluent chain, with a
constant switch or a bound one. This file is one of the fixtures that must compile.

<!-- snippet: ExternalParity/Tests/CompileFixtures/valid/GuideExamplesWhereTheyStand.swift#use-sample-stages -->

<!-- snippet: ExternalParity/Tests/CompileFixtures/valid/GuideExamplesWhereTheyStand.swift#use-steps -->

Where an example must not stand is a fixture too, under `Tests/CompileFixtures/invalid`: each
file names the sentence the compiler has to give, and `Scripts/external-parity.sh --step fixtures`
type-checks it as a client of the package.

## Checking what you wrote

The tools the stock stages are tested with are public, in the product `ZTronDSPTesting` (EXT-3):
seeded signals, `expectClose` with its tolerances, the click measure, and the allocation audit.

A processor or a kernel is an object of your own, so a test runs it on its own thread inside
`expectNoAllocations`:

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift#audit-processor -->

A node runs only inside a plan. `expectNoAllocationsRunning` compiles a pipeline and runs its
plan block by block on the test's own thread, inside the audit, so a node is held to RT-2 there
as the stock stages are, with no engine and no thread of its own. Eight blocks run before the
audit opens:

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift#audit-running -->

In an app a stage runs on an engine's thread, with the source and the sinks around it. The audit
of that thread is `ThreadAllocationAudit`, opened and closed from a callback on the thread itself.
The helper the suites use is written on the public API:

<!-- snippet: ExternalParity/Tests/ExternalTestSupport/Support.swift#audit-on-the-engine-thread -->

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift#audit-engine -->

**The first block.** A first call can make the Swift runtime instantiate something, the metadata
of a generic type or a protocol conformance it looks up, and on the analysis thread that is an
allocation (RT-2). The sources, nodes and runners of ZTronDSP meet theirs on the control context.
For a stage of your own the rule is the same: `make` runs on the control context, so it reaches
there whatever `process` will use for the first time. Run the processor or the node once on a
scratch block and reset it, as `Despike` does, or touch the generic types it uses. A plan is not
run for you before it is installed: a kernel or a node that a new plan takes over from the running
one (SWAP-1) is running on the analysis thread at that moment, and one more `process` would be seen
by every stage that counts its calls. Hold the rule with an audit that opens before the first
block, in an optimised build, the test alone in its process; `Scripts/external-parity.sh` runs this
one by itself in Release:

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift#audit-first-block -->

Run the audits in Debug and in Release: a loop that is free in an optimised build can allocate in
a Debug build (CR-002).
