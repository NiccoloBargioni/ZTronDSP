# Extension guide

How to add to ZTronDSP from outside it: one example for every row of the table in §5.11.1 of the
specification, in the order of that table.

Every example here is real code. It lives in `ExternalParity/`, a package of its own inside this
repository that depends on ZTronDSP by path and on its three products only, as an app does: no
`@testable import`, no `@_spi`, no internal symbol. Each example is compiled there, in Debug and
in Release, and run by a test there. The code blocks of this guide are not copies that can go
stale: `Scripts/external-parity.sh --step guide` fails when a block differs by one character from
the marked region of the file it names. The same script builds the examples, runs their tests,
their must-not-compile fixtures and their allocation audits (CI gate 9).

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
```swift
    dependencies: [
        .package(name: "ZTronDSP", path: ".."),
    ],
```

<!-- snippet: ExternalParity/Package.swift#manifest-targets -->
```swift
        .target(
            name: "CExtensionGuide",
            dependencies: [.product(name: "ZTronDSP", package: "ZTronDSP")],
            cSettings: kernelSettings
        ),
        .target(
            name: "ExtensionGuide",
            dependencies: ["CExtensionGuide", .product(name: "ZTronDSP", package: "ZTronDSP")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ExtensionGuideUI",
            dependencies: [
                "ExtensionGuide",
                .product(name: "ZTronDSP", package: "ZTronDSP"),
                .product(name: "ZTronDSPUI", package: "ZTronDSP"),
            ],
            swiftSettings: swiftSettings
        ),
```

`ZTronDSP` is everything but the views; `ZTronDSPUI` is the views; `ZTronDSPTesting` is what the
stock stages are tested with (EXT-3). A C target that depends on the product `ZTronDSP` includes
the kernel ABI by name, `#include "ztd_kernel.h"`.

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
```swift
/// The spectral flux of a magnitude spectrum: how much the bins rose since the frame before,
/// summed over the bins. One value per hop, so the chain goes on as a novelty curve.
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct SpectralFlux: PipelineStage {
    public typealias Input = Spectrum<LinearFrequency, MagnitudeValues>
    public typealias Output = Novelty

    /// The step's switch (§5.9). Switched off, it suspends the rest of its branch (ACT-3).
    public let activation: StageActivation

    public init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    /// Emits the node. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        // The positional environment says what arrives here: how many bins, how often.
        let environment = context.environment
        guard let bins = environment.frequencyAxis?.rowCount, let rate = environment.featureRate, bins >= 1 else {
            throw DSPError.unsupportedConfiguration(
                reason: "SpectralFlux needs the frames of a spectral scope, and there is none at this position", stage: context.path)
        }
        // One value per frame: downstream is a sampled sequence at the feature rate.
        context.emit(.analysis(AnalysisStep(name: "SpectralFlux", key: bins, output: .scalar, scope: .featureSequence(rate: rate)) {
            () throws(DSPError) -> any AnalysisNode in
            try SpectralFluxNode(bins: bins)
        }))
    }
}
```

The stage reads the positional environment in `lower(_:)`: how many bins arrive, how often. It
states what leaves it, and hands the plan a closure that makes the node. The closure throws
`DSPError`, typed, and the stage's own errors carry `context.path`, so an error names the stage
and its place in the pipeline.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/SpectralFlux.swift#flux-node -->
```swift
/// What runs a `SpectralFlux`.
///
/// Threading: created on the control context, where it allocates the frame it remembers.
/// `process` and `reset` belong to the analysis thread: no allocation, no lock, no logging
/// (RT-2), and the loop is a `while` loop. One thread at a time.
final class SpectralFluxNode: AnalysisNode {
    private let bins: Int
    private let previous: AlignedBuffer<Float>
    private var hasPrevious = false

    /// The flux of a frame is stamped with that frame: nothing is delayed.
    var latencyFrames: Int { 0 }
    /// One frame after a cold start the node has the frame it compares with.
    var settlingFrames: Int { 1 }

    init(bins: Int) throws(DSPError) {
        self.bins = bins
        previous = try AlignedBuffer<Float>(count: max(bins, 1))
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= bins, let current = frame.values.baseAddress else { return }
        let last = previous.baseAddress
        if hasPrevious {
            var flux: Float = 0
            var bin = 0
            while bin < bins {
                let rise = current[bin] - last[bin]
                if rise > 0 { flux += rise }
                bin &+= 1
            }
            output.emit(scalar: ScalarFrame(value: flux))
        }
        // The first frame after a cold start has nothing to be compared with: no frame is written.
        previous.copy(from: current, count: bins)
        hasPrevious = true
    }

    func reset() {
        hasPrevious = false
    }
}
```

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
| Conform to, or use | `SequenceStage` for the description; `SampleProcessor` for what runs. `lower(_:)` emits `.processor(CustomProcessor(…))` |
| Runs on | `lower(_:)` and the closure that makes the processor: control context. `process(_:)` and `reset()`: analysis thread |
| Supplies | `process(_:)` on a block, in place; `reset()`; the latency; a `key` |
| Latency and settling | `latencyFrames` is stated twice, by the `CustomProcessor` description (for the environment downstream) and by the processor that runs; a plan in which the two differ is refused. 1 frame here. `settlingFrames`: 2 here |
| Threading contract | The stage is an immutable value, usable on any thread. The processor is created on the control context, where it allocates its memory once; `process` and `reset` belong to the analysis thread, one thread at a time, under RT-2, with `while` loops |

`Despike` replaces every sample by the median of itself and its two neighbours: not a linear
filter, so no stock kernel computes it. A sequence stage runs on any sampled sequence (samples,
a novelty curve, a scalar track) and keeps its domain.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/Despike.swift#despike-stage -->
```swift
/// Removes single-sample spikes: every sample becomes the median of itself and its two
/// neighbours. A median is not a linear filter, so no stock kernel computes it.
///
/// The stage runs on any sampled sequence and keeps its domain. It delays the signal by one
/// frame. An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct Despike: SequenceStage {
    /// The stage's switch (§5.9). Switched off, the signal passes, one frame late like the
    /// processed one (ACT-8).
    public let activation: StageActivation

    public init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    /// Emits the processor. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let channels = context.channelCount
        // The latency is stated here, for the environment downstream, and by the processor that
        // runs: a plan in which the two differ is refused.
        context.emit(.processor(CustomProcessor(name: "Despike", key: channels, latencyFrames: 1) {
            _ throws(DSPError) -> any SampleProcessor in
            try DespikeProcessor(channelCount: channels)
        }))
    }
}
```

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/Despike.swift#despike-processor -->
```swift
/// What runs a `Despike`: a block in place, each channel with the two samples before it.
///
/// Threading: created on the control context, where it allocates its memory once. `process`
/// and `reset` belong to the analysis thread: no allocation, no lock, no logging (RT-2), and
/// the loops are `while` loops. One thread at a time.
public final class DespikeProcessor: SampleProcessor {
    private let channelCount: Int
    /// Per channel: the two samples before the block, the older one first.
    private let history: AlignedBuffer<Float>

    /// A processor for `channelCount` channels. Control context; allocates.
    public init(channelCount: Int) throws(DSPError) {
        self.channelCount = max(channelCount, 1)
        history = try AlignedBuffer<Float>(count: 2 * max(channelCount, 1))
    }

    /// The median of x[n − 2], x[n − 1] and x[n] stands for x[n − 1]: one frame of delay.
    public var latencyFrames: Int { 1 }
    /// Two frames after a cold start the memory holds signal, not the zeros it starts with.
    public var settlingFrames: Int { 2 }

    /// Analysis thread; allocation-free.
    public func process(_ block: inout AudioBlock) {
        var channel = 0
        while channel < block.channelCount, channel < channelCount {
            let samples = block.channel(channel)
            let memory = history.baseAddress + 2 * channel
            var older = memory[0], newer = memory[1]
            var frame = 0
            while frame < block.frameCount {
                let current = samples[frame]
                samples[frame] = max(min(older, newer), min(max(older, newer), current))
                older = newer
                newer = current
                frame &+= 1
            }
            memory[0] = older
            memory[1] = newer
            channel &+= 1
        }
    }

    /// A cold start (ACT-10). Analysis thread; allocation-free.
    public func reset() {
        history.clear()
    }
}
```

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
```swift
extension PipelineBuilder {
    /// Catches the stage after a domain it does not run on, with a sentence that names it (ORD-4).
    @available(*, unavailable, message: "Despike runs on a sampled sequence: samples, a novelty curve or a scalar track. It cannot follow a spectrum or any other frame of bins.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: Despike) -> Pipeline<I, O> { accumulated }
}
```

A processor works on the block in place, and a kernel is handed an input and an output, so the
plan copies each block from the one to the other before it calls the processor. For a stage as
small as a gain that copy costs about what the multiplication costs: the parity suite measures a
gain written this way at 1.7 to 1.8 times the stock gain. Where a stage has to run within 5 % of
a stock kernel, write it on the kernel ABI (the next row), where the same gain measures 0.9 times.

## 3. A sample-domain stage in C

| | |
|---|---|
| Conform to, or use | `SequenceStage` with a `ztd_kernel_t`: `lower(_:)` emits `.custom(CustomKernel(…))`, whose closure returns the kernel. The ABI is `ztd_kernel.h`, a public header of the product `ZTronDSP` |
| Runs on | The closure and the kernel's `destroy`: control context. The kernel's `process`, `command` and `reset`: analysis thread (the I/O thread too, should D-1 land) |
| Supplies | The kernel table and its state: `process`, `reset`, `destroy`, `state`, `latency_frames`, `settling_frames`; `command` may stay null |
| Latency and settling | `latency_frames` must equal the `latencyFrames` of the `CustomKernel`: 0 here. `settling_frames` is what a plan pre-rolls the kernel for before it is faded in: here the time an echo takes to decay by 100 dB |
| Threading contract | Creation allocates everything, on the control context, and touches it, so that the analysis thread never takes a page fault. `process` and `reset` are declared `ZTD_NONBLOCKING` and belong to the analysis thread, one thread at a time. `destroy` is the only place the kernel frees: control context |

`FeedbackComb` is a feedback comb filter, y[n] = x[n] + g·y[n − D]. The C target turns
function-effect warnings into errors, as the C target of ZTronDSP does: a `ZTD_NONBLOCKING`
function that allocates, or calls a function that is not itself non-blocking, does not build
(RT-1).

<!-- snippet: ExternalParity/Package.swift#manifest-kernel-settings -->
```swift
let kernelSettings: [CSetting] = [
    .enableWarning("function-effects"),
    .treatWarning("function-effects", as: .error),
]
```

<!-- snippet: ExternalParity/Sources/CExtensionGuide/include/CExtensionGuide.h#comb-header -->
```c
/* A feedback comb filter, y[n] = x[n] + feedback · y[n − delay_frames], per channel.

   `latency_frames` is 0: the direct sound is not delayed. `settling_frames` is the time an echo
   takes to decay by 100 dB, at most 2^24 frames: what a plan pre-rolls the kernel for before it
   is faded in (ACT-7, SWAP-2).

   Threading: control context; it allocates everything the kernel will need. The kernel's
   `process` and `reset` are non-blocking and belong to the analysis thread, its `destroy` to the
   control context. One thread at a time.

   Returns a kernel whose `process` is NULL when the arguments make no kernel (no channel, no
   delay, a feedback that is not finite or not below 1 in magnitude) or memory cannot be had. */
ztd_kernel_t extg_comb_create(uint32_t channels, uint32_t delay_frames, float feedback);
```

<!-- snippet: ExternalParity/Sources/CExtensionGuide/extg_comb.c#comb-kernel -->
```c
typedef struct extg_comb {
    uint32_t channels;
    uint32_t delay;    /* frames between a sample and its echo */
    uint32_t position; /* where y[n − delay] sits in every ring */
    float feedback;
    float *ring;       /* per channel: the last `delay` outputs */
} extg_comb_t;

static uint32_t extg_comb_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                  uint32_t frames) ZTD_NONBLOCKING {
    extg_comb_t *comb = (extg_comb_t *)state;
    const uint32_t count = channels < comb->channels ? channels : comb->channels;
    const float floor = (float)ZTD_STATE_FLOOR;
    for (uint32_t channel = 0; channel < count; channel++) {
        float *ring = comb->ring + (size_t)channel * comb->delay;
        const float *source = in[channel];
        float *destination = out[channel];
        uint32_t position = comb->position;
        for (uint32_t frame = 0; frame < frames; frame++) {
            const float value = source[frame] + comb->feedback * ring[position];
            /* RT-6: an echo that has decayed below the floor enters the ring as zero, so the
               kernel never leaves denormal state behind. */
            ring[position] = (value < floor && value > -floor) ? 0.0f : value;
            destination[frame] = value;
            position = position + 1 == comb->delay ? 0 : position + 1;
        }
    }
    comb->position = (uint32_t)(((uint64_t)comb->position + frames) % comb->delay);
    return frames;
}

/* A cold start (ACT-10): the feedback is kept, the echoes are not. */
static void extg_comb_reset(void *state) ZTD_NONBLOCKING {
    extg_comb_t *comb = (extg_comb_t *)state;
    memset(comb->ring, 0, (size_t)comb->channels * comb->delay * sizeof(float));
    comb->position = 0;
}

/* Control context: the only place the kernel frees. */
static void extg_comb_destroy(void *state) {
    extg_comb_t *comb = (extg_comb_t *)state;
    if (!comb) return;
    free(comb->ring);
    free(comb);
}

ztd_kernel_t extg_comb_create(uint32_t channels, uint32_t delay_frames, float feedback) {
    ztd_kernel_t kernel;
    memset(&kernel, 0, sizeof kernel); /* `process` is NULL: what a failed creation returns */
    const uint32_t limit = (uint32_t)1 << 24;
    if (channels == 0 || channels > limit || delay_frames == 0 || delay_frames > limit) return kernel;
    if (!isfinite(feedback) || !(fabsf(feedback) < 1.0f)) return kernel;

    extg_comb_t *comb = (extg_comb_t *)calloc(1, sizeof(extg_comb_t));
    if (!comb) return kernel;
    comb->channels = channels;
    comb->delay = delay_frames;
    comb->feedback = feedback;
    /* calloc hands out zeros, and the analysis thread must not take the first-touch fault of a
       page: the ring is written once here. */
    comb->ring = (float *)calloc((size_t)channels * delay_frames, sizeof(float));
    if (!comb->ring) {
        free(comb);
        return kernel;
    }
    memset(comb->ring, 0, (size_t)channels * delay_frames * sizeof(float));

    /* The echoes decay by |feedback| per `delay_frames`: after `echoes` of them they are 100 dB down. */
    double settling = 0.0;
    if (feedback != 0.0f) settling = ceil(log(1e-5) / log(fabs((double)feedback))) * (double)delay_frames;

    /* `command` stays NULL: the engine sends no value to a kernel of the caller's own. */
    kernel.process = extg_comb_process;
    kernel.reset = extg_comb_reset;
    kernel.destroy = extg_comb_destroy;
    kernel.state = comb;
    kernel.latency_frames = 0;
    kernel.settling_frames = settling < (double)limit ? (uint32_t)settling : limit;
    return kernel;
}
```

State hygiene is the kernel's (RT-6): a value below `ZTD_STATE_FLOOR` enters the ring as zero, so
the kernel never computes on denormal numbers. A kernel whose `process` is null is what a failed
creation returns; the plan reports it as a failed allocation.

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Kernels/FeedbackComb.swift#comb-stage -->
```swift
/// A feedback comb filter: the signal plus its own output of `delay` seconds ago, scaled by
/// `feedback`. A resonator, and the building block of a reverberator.
///
/// The stage runs on any sampled sequence and keeps its domain. An immutable value, usable on
/// any thread. `lower(_:)` runs on the control context.
public struct FeedbackComb: SequenceStage {
    /// What tells one comb from another: its delay in frames and its feedback.
    struct Key: Hashable, Sendable {
        let frames: UInt32
        let feedback: Float
    }

    /// The time between a sample and its echo, in seconds. Usable on any thread.
    public let delay: TimeInterval
    /// What each echo keeps of the one before, below 1 in magnitude. Usable on any thread.
    public let feedback: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    public init(delay: TimeInterval, feedback: Double, isActive: some ActivationSource = .active) {
        self.delay = delay
        self.feedback = feedback
        self.activation = isActive.stageActivation
    }

    /// Emits the kernel. Control context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a delay of less than one frame at the sample
    ///   rate here, and for a feedback that is not below 1 in magnitude.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        // Seconds become frames at the sample rate of the stage's position (ENV-1).
        let frames = (delay * context.environment.sampleRate).rounded()
        guard frames >= 1, frames <= 16_777_216 else {
            throw context.invalid("delay", "\(delay) s is \(frames) frames at \(context.environment.sampleRate) Hz; an echo comes at least one frame late")
        }
        guard feedback.isFinite, abs(feedback) < 1 else {
            throw context.invalid("feedback", "a feedback of \(feedback) does not decay: its magnitude lies below 1")
        }
        let key = Key(frames: UInt32(frames), feedback: Float(feedback))
        // `make` runs on the control context when a plan needs the kernel; the plan owns the
        // kernel from then on and frees it through its `destroy`.
        context.emit(.custom(CustomKernel(name: "FeedbackComb", key: key, latencyFrames: 0) { channels, _, _ in
            extg_comb_create(UInt32(max(channels, 0)), key.frames, key.feedback)
        }))
    }
}
```

The stage turns seconds into frames at the sample rate of its own position, validates its
arguments with errors that name it (`context.invalid`), and gives the kernel a key: two
descriptions with equal names and keys are the same kernel, which then moves into a new plan
with its state when something else in the pipeline changes (SWAP-1). The Swift target imports the
C target with `internal import`, so the C module is no part of the Swift module's interface.

What the stage did not write and has: order checking, activation, and the pre-roll. Switched on,
the comb is reset, runs with its output discarded for the 816 frames it declares (in whole
blocks), and only then is faded in; the test holds the engine to that count.

What it does not have: a kernel or a processor of your own is not sent values while it runs. A
pipeline that differs from the running one in a value of such a stage holds another kernel, so
the session compiles a plan, pre-rolls the new kernel and cross-fades to it, and a sink behind
the stage receives nothing meanwhile. A stage that has to take a value in place, as a stock
filter takes its coefficients, lowers to stock kernel specs (row 9).

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
```swift
/// Scales every frame of magnitudes or powers so that its largest value is 1, on whatever
/// axis the frame has. A frame whose largest value is at or below `floor` becomes zeros.
///
/// The step is a family (ORD-1): what it produces depends on what it follows, so it names no
/// `Input` and no `Output`. Its typing rule is written once below as a builder overload, once
/// as a fluent method, and once as the `DomainRule` its description carries. An immutable
/// value, usable on any thread. `lower(_:)` runs on the control context.
public struct PeakNormalize: ContextDependentStep {
    /// A frame that peaks at or below this is silence. Usable on any thread.
    public let floor: Float
    /// The step's switch (§5.9). The step keeps the domain, so switched off the frames pass
    /// as they are (ACT-3).
    public let activation: StageActivation

    public init(floor: Float = 1e-12, isActive: some ActivationSource = .active) {
        self.floor = floor
        self.activation = isActive.stageActivation
    }

    /// The rule the plan compiler checks when a pipeline is attached (§5.8.2, tier 2):
    /// magnitudes or powers on any axis, kept. A rule of one's own has a name of its own.
    public static let rule = DomainRule.spectral("PeakNormalize: magnitudes or powers, kept") { axis, values in
        values == .magnitude || values == .power ? .spectrum(axis: axis, values: values) : nil
    }

    /// The step as a pipeline holds it, with its rule. Usable on any thread.
    public var stageDescription: StageDescription { StageDescription(self, rule: PeakNormalize.rule) }

    /// Emits the node. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let bins = context.environment.frequencyAxis?.rowCount, bins >= 1 else {
            throw DSPError.unsupportedConfiguration(reason: "PeakNormalize needs the frames of a spectral scope, and there is none at this position", stage: context.path)
        }
        let floor = try StageValidation.finite(self.floor, named: "floor", in: context)
        context.emit(.analysis(AnalysisStep(name: "PeakNormalize", key: self.floor, output: .real(count: bins)) {
            () throws(DSPError) -> any AnalysisNode in
            PeakNormalizeNode(floor: floor)
        }))
    }
}
```

The typing rule is written three times and means one thing each time: for the compiler in a
builder block, for the compiler in a fluent chain, and as the `DomainRule` that the description
carries for pipelines assembled from data (tier 2).

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Nodes/PeakNormalize.swift#normalize-family -->
```swift
extension PipelineBuilder {
    /// The family's compile-time rule (§5.8.2, tier 1): the step follows magnitudes or powers
    /// on any axis and keeps the domain.
    public static func buildPartialBlock<I, Axis, Values: LinearValued>(
        accumulated: Pipeline<I, Spectrum<Axis, Values>>, next: PeakNormalize
    ) -> Pipeline<I, Spectrum<Axis, Values>> {
        accumulated.appending(next.stageDescription)
    }

    /// Catches the step after a domain it does not take, with a sentence that names it and says what it needs (ORD-4).
    @available(*, unavailable, message: "PeakNormalize needs magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: PeakNormalize) -> Pipeline<I, O> { accumulated }

    /// Catches the step after sequence stages alone: there are no bins yet.
    @available(*, unavailable, message: "PeakNormalize needs magnitudes or powers: put Magnitude() or Power() before it, and Decibels() after it.")
    public static func buildPartialBlock(accumulated: SequenceChain, next: PeakNormalize) -> SequenceChain { accumulated }
}

extension Pipeline {
    /// The family's fluent spelling, constrained on the output domain. Usable on any thread.
    public func peakNormalized<Axis, Values: LinearValued>(
        floor: Float = 1e-12, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Spectrum<Axis, Values>> where Output == Spectrum<Axis, Values> {
        appending(PeakNormalize(floor: floor, isActive: isActive).stageDescription)
    }
}
```

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
```swift
/// A sink for a scalar track that keeps the newest value and the largest one: what a level
/// meter with a peak-hold mark reads.
///
/// Threading: `claim` and `release` run on the control context. `write` runs on the analysis
/// thread and does no more than load and store single atomic words (RT-2, RT-4). `value`,
/// `peak` and `resetPeak()` may be used on any thread. The cells are the only state, each
/// written by one thread: that is why the class may say `@unchecked Sendable`.
public final class PeakHoldMeter: FeatureSink, @unchecked Sendable {
    public typealias Domain = Scalar

    private let latest = ztd_atomic_create(UInt64(Float(0).bitPattern))
    private let held = ztd_atomic_create(UInt64((-Float.infinity).bitPattern))
    private let resetRequested = ztd_atomic_create(0)

    /// Any thread; allocates the three cells.
    public init() {}

    deinit {
        if let latest { ztd_atomic_destroy(latest) }
        if let held { ztd_atomic_destroy(held) }
        if let resetRequested { ztd_atomic_destroy(resetRequested) }
    }

    /// An attachment is about to write the sink: it starts from nothing. The engine lets one
    /// live attachment write a sink and refuses a second (ATT-5). Control context.
    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        guard let latest, let held, resetRequested != nil else {
            throw .resourceAllocationFailed(what: "the cells of a PeakHoldMeter")
        }
        ztd_atomic_store(latest, UInt64(Float(0).bitPattern))
        ztd_atomic_store(held, UInt64((-Float.infinity).bitPattern))
    }

    /// Takes one value. Analysis thread; allocation-free. The frame is a borrowed view.
    public func write(_ frame: FrameView) {
        guard let scalar = frame.scalar, let latest, let held, let resetRequested else { return }
        ztd_atomic_store(latest, UInt64(scalar.value.bitPattern))
        // A value without confidence repeats the one before it: it sets no mark.
        guard scalar.confidence > 0 else { return }
        let mark = Float(bitPattern: UInt32(truncatingIfNeeded: ztd_atomic_load(held)))
        if ztd_atomic_exchange(resetRequested, 0) != 0 || scalar.value > mark {
            ztd_atomic_store(held, UInt64(scalar.value.bitPattern))
        }
    }

    /// The attachment is gone. Control context.
    public func release() {}

    /// The newest value; 0 before the first. Any thread.
    public var value: Float {
        latest.map { Float(bitPattern: UInt32(truncatingIfNeeded: ztd_atomic_load($0))) } ?? 0
    }

    /// The largest value since the sink was claimed or the mark was reset; `-.infinity` before
    /// the first. Any thread.
    public var peak: Float {
        held.map { Float(bitPattern: UInt32(truncatingIfNeeded: ztd_atomic_load($0))) } ?? -.infinity
    }

    /// Lets the mark fall to the next value that arrives. Any thread: the request is one
    /// atomic word that the writer takes, so the mark keeps its one writer.
    public func resetPeak() {
        if let resetRequested { ztd_atomic_store(resetRequested, 1) }
    }
}
```

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/SinkAndSourceExampleTests.swift#meter-use -->
```swift
        let meter = PeakHoldMeter(), track = CollectingSink<Scalar>()
        #expect(meter.value == 0 && meter.peak == -.infinity)
        try Pipeline().level(.rms).emit(to: track).emit(to: meter).run(on: quiet + loud + quiet, format: mono48)
        let values = track.scalars.map { $0.value }
        try #require(values.count > 50)
        #expect(meter.value == values.last && meter.peak == values.max())
```

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
```swift
/// A metronome: one channel of clicks at a tempo, for a time. A source clocked by the engine.
///
/// Threading: `prepare`, `start` and `stop` run on the control context, one at a time, while
/// the source does not render. `render` runs on the thread the engine paces the source on and
/// is bound by RT-2: memory and arithmetic only. `position` is touched by `prepare` and by
/// `render`, never at the same time: that is why the class may say `@unchecked Sendable`.
public final class ClickSource: PullSampleSource, @unchecked Sendable {
    public let format: SignalFormat
    /// `.realTime`: one block per block duration; `.asFastAsPossible`: as fast as it is processed.
    public let pacing: Pacing
    public var events: AsyncStream<SourceEvent> { channel.stream }

    private let channel = SourceEventChannel()
    private let period: Int
    private let clickFrames: Int
    private let frameCount: Int
    private var position = 0

    /// - Parameters:
    ///   - beatsPerMinute: the tempo of the clicks.
    ///   - duration: how long the source delivers, in seconds.
    ///
    /// Any thread.
    public init(beatsPerMinute: Double, sampleRate: Double = 48_000, duration: TimeInterval, pacing: Pacing = .realTime) {
        format = SignalFormat(sampleRate: sampleRate)
        self.pacing = pacing
        let framesPerBeat = beatsPerMinute > 0 && sampleRate > 0 ? 60 * sampleRate / beatsPerMinute : 0
        period = framesPerBeat >= 1 && framesPerBeat < 1e9 ? Int(framesPerBeat.rounded()) : 0
        clickFrames = max(min(Int((0.005 * sampleRate).rounded()), period / 2), 1)
        let total = duration * sampleRate
        frameCount = total.isFinite && total > 0 && total < 1e12 ? Int(total.rounded()) : 0
    }

    /// Checks what the source was given and starts the clicks over. Control context.
    public func prepare() async throws(DSPError) {
        guard format.isValid, period >= 1 else {
            throw .sourceUnavailable(reason: "a metronome needs a positive tempo and a sample rate, not \(period) frames per beat at \(format)")
        }
        position = 0
    }

    /// Nothing to start: the engine asks for blocks. Control context.
    public func start() throws(DSPError) {}

    /// Nothing to stop. Control context.
    public func stop() {}

    /// Fills `block`, says how many frames it wrote, and returns that number; 0 ends the stream.
    public func render(into block: inout AudioBlock) -> Int {
        let frames = min(block.capacity, frameCount - position)
        guard frames > 0, block.channelCount >= 1 else {
            block.setFrameCount(0)
            return 0
        }
        let samples = block.channel(0)
        var frame = 0
        while frame < frames {
            let phase = (position &+ frame) % period
            // A click falls from 1 to 0 over 5 ms.
            samples[frame] = phase < clickFrames ? 1 - Float(phase) / Float(clickFrames) : 0
            frame &+= 1
        }
        position &+= frames
        block.setFrameCount(frames)
        return frames
    }
}
```

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/SinkAndSourceExampleTests.swift#source-use -->
```swift
        let source = ClickSource(beatsPerMinute: 240, duration: 0.5, pacing: .asFastAsPossible)
        let engine = DSPEngine(blockSize: 512)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
        try session.start()
        try #require(await session.reaches(.finished))
```

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
```swift
/// A filter family with all its poles on one real point: critically damped. Its step response
/// never overshoots, at the price of a soft knee. The cutoff is the −3 dB point.
///
/// A family supplies one thing, its analog low-pass prototype; the frequency transformation,
/// the bilinear transform and the section pairing are the package's, the same as for a stock
/// family. An immutable value, usable on any thread; designing allocates and belongs on a
/// control or background context.
public struct CriticallyDampedFamily: FilterFamily {
    public init() {}

    /// `order` poles at −p, with p chosen so that the gain at 1 rad/s is 1/√2.
    public func prototype(order: Int) throws(DSPError) -> ZeroPoleGain {
        guard order >= 1, order <= 64 else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "a critically damped filter has between 1 and 64 poles, not \(order)")
        }
        let pole = 1 / (pow(2, 1 / Double(order)) - 1).squareRoot()
        return ZeroPoleGain(zeros: [], poles: [Complex](repeating: Complex(-pole), count: order), gain: pow(pole, Double(order)), domain: .analog)
    }
}

extension FilterFamily where Self == CriticallyDampedFamily {
    /// No overshoot: every pole on one real point. Usable on any thread.
    public static var criticallyDamped: CriticallyDampedFamily { CriticallyDampedFamily() }
}
```

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
```swift
extension Window {
    /// The sine window, the square root of a Hann window: used for analysis and for synthesis
    /// at a hop of half a frame, the two together overlap-add to one.
    ///
    /// The closure is evaluated at t = n / N for n = 0 … N − 1, once, in double precision,
    /// when a plan is compiled (WIN-2); outside the frame the window is zero whatever the
    /// closure returns. Usable on any thread.
    public static var sine: Window {
        .custom { t in sin(.pi * t) }
    }
}
```

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/SineWindow.swift#sine-window-use -->
```swift
/// An analysis and a synthesis with the sine window: what comes out is what went in, one hop
/// late. Usable on any thread.
public func sineWindowRoundTrip(frame: Int) -> Pipeline<Samples, Samples> {
    Pipeline {
        STFT(frame: frame, hop: frame / 2, window: .sine)
        InverseSTFT(window: .sine)
    }
}
```

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
```swift
/// Pre-emphasis, y[n] = x[n] − a·x[n − 1]: lifts the high end before an analysis.
///
/// The stage lowers to a stock kernel spec, one section of the stock cascade, so it is fused
/// and switched like a stock filter and takes a changed coefficient in place (EXT-2). An
/// immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct PreEmphasis: SequenceStage {
    /// The `a` of the difference equation. Usable on any thread.
    public let coefficient: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    public init(coefficient: Double = 0.97, isActive: some ActivationSource = .active) {
        self.coefficient = coefficient
        self.activation = isActive.stageActivation
    }

    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let a = try StageValidation.finite(coefficient, named: "coefficient", in: context)
        let precision: BiquadPrecision = context.environment.biquadPrecision == .double ? .double : .single
        context.emit(.biquad(sections: [BiquadSection(b0: 1, b1: -a, b2: 0, a1: 0, a2: 0)], precision: precision))
    }
}

/// De-emphasis, y[n] = x[n] + a·y[n − 1]: what undoes `PreEmphasis` with the same coefficient.
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct DeEmphasis: SequenceStage {
    /// The `a` of the difference equation. Usable on any thread.
    public let coefficient: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    public init(coefficient: Double = 0.97, isActive: some ActivationSource = .active) {
        self.coefficient = coefficient
        self.activation = isActive.stageActivation
    }

    /// - Throws: `DSPError.unstableDesign` for a coefficient whose magnitude is not below 1:
    ///   the pole would sit on or outside the unit circle (REAL-2).
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let a = try StageValidation.finite(coefficient, named: "coefficient", in: context)
        guard abs(a) < 1 else { throw DSPError.unstableDesign(maxPoleRadius: abs(a)) }
        let precision: BiquadPrecision = context.environment.biquadPrecision == .double ? .double : .single
        context.emit(.biquad(sections: [BiquadSection(b0: 1, b1: 0, b2: 0, a1: -a, a2: 0)], precision: precision))
    }
}
```

<!-- snippet: ExternalParity/Sources/ExtensionGuide/Designs/PreEmphasis.swift#emphasis-inverse -->
```swift
extension PreEmphasis: InvertibleStage {
    /// The stage that undoes this one, with the value it needs to match it.
    public var inverse: DeEmphasis { DeEmphasis(coefficient: coefficient) }

    /// The one condition: the inverse has its pole at `a`, and is stable while that lies inside
    /// the unit circle. A failed condition is reported, not thrown (INV-3). Background work.
    public func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        let radius = abs(coefficient)
        let holds = radius < 1
        return [InversionCondition(
            name: "a stable inverse",
            theorem: "1 − a·z⁻¹ is undone by 1 / (1 − a·z⁻¹), which is stable when its pole lies inside the unit circle: |a| < 1",
            quantity: "|a|", observed: radius, holds: holds, margin: 1 - radius,
            // What the inverse does to the round-off of single-precision samples: it amplifies
            // it by up to 1 / (1 − |a|). Without a stable inverse everything is lost.
            predictedError: holds ? Double(Float.ulpOfOne) / (1 - radius) : 1)]
    }

    /// The stage and then its inverse on the signal of the report; `nil` without a signal, and
    /// where there is no stable inverse to run. Background work.
    public func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil, abs(coefficient) < 1 else { return nil }
        let original = try context.samples()
        try context.check()
        let reconstruction = try context.samples(after: stageDescriptions + inverse.stageDescriptions)
        return InversionRoundTrip(original: original, reconstruction: reconstruction)
    }
}
```

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/DesignExampleTests.swift#report-use -->
```swift
        let report = try await PreEmphasis().inversionReport(for: noise, sampleRate: 48_000)
        #expect(report.stage == "PreEmphasis" && report.inverse == "DeEmphasis" && report.isExactlyInvertible)
        try #require(report.conditions.count == 1)
        let condition = report.conditions[0]
        #expect(condition.name == "a stable inverse" && condition.holds && condition.isNecessary && condition.observed == 0.97)
        expectClose(condition.margin, 0.03, .absolute(1.0e-12))
        // The prediction is the round-off of single precision times what the inverse amplifies it by.
        expectClose(report.predictedError, Double(Float.ulpOfOne) / 0.03, .relative(1.0e-9))
        let measured = try #require(report.measuredError)
        #expect(measured.count == noise.count && measured.signalToNoiseRatio > 100, "\(measured)")
        #expect(measured.relativeError <= report.predictedError, "measured \(measured.relativeError), predicted \(report.predictedError)")
```

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
```swift
/// A novelty curve as an app keeps it: the values a pipeline delivered and how many of them
/// make a second. It exports as a MATLAB script.
///
/// An immutable value, usable on any thread.
public struct NoveltyCurve: MATLABExportable, Hashable {
    public let values: [Float]
    /// Values per second: the feature rate of the pipeline that delivered them.
    public let rate: Double

    public init(_ frames: [ScalarFrame], rate: Double) {
        values = frames.map(\.value)
        self.rate = rate
    }

    /// The script: the curve as variables, then one plot with its axes labelled. Core MATLAB
    /// only, so it also runs in GNU Octave (MAT-2); no date and no machine name, so equal
    /// curves give equal text (MAT-4). The package writes no file: the text is the app's.
    ///
    /// May be called from any context, the main actor included: the work runs on the
    /// package's background executor (BG-1) and can be cancelled (BG-3).
    public func matlabScript() async throws(DSPError) -> String {
        let values = values, rate = rate
        return try await BackgroundWork.run { checkpoint throws(DSPError) -> String in
            guard rate > 0, rate.isFinite else {
                throw .invalidParameter(stage: .none, parameter: "rate", reason: "a curve has a positive number of values per second, not \(rate)")
            }
            let times = (0 ..< values.count).map { Double($0) / rate }
            try checkpoint.check()
            return try MATLABScript()
                .comment("Novelty curve: \(values.count) values at \(MATLABScript.format(rate)) per second")
                .vector("t", times)
                .vector("novelty", values)
                .plot("t", "novelty")
                .xlabel("Time (s)")
                .ylabel("Novelty")
                .title("Novelty curve")
                .grid()
                .text
        }
    }
}
```

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/DesignExampleTests.swift#export-use -->
```swift
        let curve = try curve()
        let script = try await curve.matlabScript()
```

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
```swift
/// A spectrogram whose every column is scaled to its own peak: the shape of the spectrum over
/// time, whatever the level. A stock heat map on a feed that a pipeline of the app's own
/// writes; the pipeline ends in a step written outside the package.
///
/// Threading: main actor, like every view. The view stores the source and the feed and
/// nothing of their contents, so its body depends on no per-frame data, and it is `Equatable`
/// by what it shows (V-1). Keep the source and the feed in state or in a model, not in a
/// `body`.
public struct NormalizedSpectrogram: View, Equatable {
    private let source: any SampleSource
    private let feed: HeatmapFeed

    /// A spectrogram of `source`, drawn from `feed`. Main actor.
    public init(source: any SampleSource, feed: HeatmapFeed) {
        self.source = source
        self.feed = feed
    }

    /// The analysis behind the view: built in a function of its sink, so that one description
    /// serves several sources, each with a feed of its own (ATT-5). Usable on any thread.
    nonisolated public static func analysis(into feed: HeatmapFeed) -> Pipeline<Samples, Samples> {
        Pipeline().tap { $0.stft(frame: 1_024, hop: 256).magnitude().peakNormalized().emit(to: feed) }
    }

    public var body: some View {
        HeatmapView(feed: feed)
            .valueRange(0 ... 1)
            .timeSpan(4)
            .colorMap(.magma)
            .axis(.frequency)
            // The view hosts the pipeline: attached while the view is in the hierarchy, detached when it leaves.
            .pipeline(NormalizedSpectrogram.analysis(into: feed), on: source)
    }

    /// Two views are equal when they show the same source object through the same feed
    /// object. Usable on any thread.
    nonisolated public static func == (lhs: NormalizedSpectrogram, rhs: NormalizedSpectrogram) -> Bool {
        lhs.source === rhs.source && lhs.feed === rhs.feed
    }
}
```

<!-- snippet: ExternalParity/Tests/CompileFixtures/valid/GuideExamplesWhereTheyStand.swift#use-display -->
```swift
    // Rows 6 and 11: a source, and a display of it.
    let source = ClickSource(beatsPerMinute: 120, duration: 10)
    let view = NormalizedSpectrogram(source: source.processed(by: samples), feed: feed)
```

SwiftUI is imported by this one target. The view is `Equatable` by the objects it shows, as the
stock views are (V-1). The tests build the view and run the analysis behind it on an engine:
every column of the feed peaks at 1 or is silence, whatever the level of the signal. They do not
put the view on a screen.

## Where the examples stand

The examples are used like stock stages: in a builder block and in a fluent chain, with a
constant switch or a bound one. This file is one of the fixtures that must compile.

<!-- snippet: ExternalParity/Tests/CompileFixtures/valid/GuideExamplesWhereTheyStand.swift#use-sample-stages -->
```swift
    // Rows 2, 3 and 9: sample-domain stages, on samples and on a feature-rate sequence.
    let samples: Pipeline<Samples, Samples> = Pipeline {
        Despike()
        FeedbackComb(delay: 0.010, feedback: 0.5, isActive: shown)
        PreEmphasis(coefficient: 0.97)
        DeEmphasis(coefficient: 0.97, isActive: flag)
        LowPass(.criticallyDamped, cutoff: .hertz(8_000), order: 4)     // row 7
    }
    let fluent: Pipeline<Samples, Samples> = Pipeline().despiked().feedbackComb(delay: 0.010, feedback: 0.5).preEmphasis().deEmphasis(isActive: shown)
```

<!-- snippet: ExternalParity/Tests/CompileFixtures/valid/GuideExamplesWhereTheyStand.swift#use-steps -->
```swift
    // Rows 1, 4, 5 and 8: a step between domains, a family, a sink, a window.
    let flux: Pipeline<Samples, Novelty> = Pipeline {
        STFT(frame: 1_024, hop: 256, window: .sine)
        Magnitude()
        PeakNormalize(isActive: shown)
        SpectralFlux()
        Despike()
        Emit(to: level)
    }
    let metered: Pipeline<Samples, Scalar> = Pipeline {
        Level(.rms)
        Despike()
        Emit(to: meter)
    }
    // Sequence stages alone run on whatever sampled sequence their sink names: here a scalar track.
    let track: Pipeline<Scalar, Scalar> = Pipeline {
        Despike()
        Emit(to: meter)
    }
    let branches: Pipeline<Samples, Samples> = Pipeline()
        .tap { $0.stft(frame: 1_024, hop: 256).power().melScale(bands: 40).peakNormalized().emit(to: feed) }
        .tap { $0.stft(frame: 1_024, hop: 256).magnitude().tap { $0.peakNormalized(floor: 1e-9, isActive: shown).spectralFlux() } }
```

Where an example must not stand is a fixture too, under `Tests/CompileFixtures/invalid`: each
file names the sentence the compiler has to give, and `Scripts/external-parity.sh --step fixtures`
type-checks it as a client of the package.

## Checking what you wrote

The tools the stock stages are tested with are public, in the product `ZTronDSPTesting` (EXT-3):
seeded signals, `expectClose` with its tolerances, the click measure, and the allocation audit.

A processor or a kernel is an object of your own, so a test runs it on its own thread inside
`expectNoAllocations`:

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift#audit-processor -->
```swift
        let processor = try DespikeProcessor(channelCount: 2)
        let buffer = try AudioBuffer(channels: [noise, noise])
        // One block outside the audit: a first call may instantiate metadata.
        var warm = buffer.block()
        processor.process(&warm)
        expectNoAllocations("DespikeProcessor, 1 000 blocks of 512 frames") {
            var block = buffer.block()
            var index = 0
            while index < 1_000 {
                processor.process(&block)
                if index % 100 == 99 { processor.reset() }
                index += 1
            }
        }
```

A node runs only inside a plan, and a plan runs on an engine's thread. The audit of that thread
is `ThreadAllocationAudit`, opened and closed from a callback on the thread itself. The helper
the suites use is written on the public API:

<!-- snippet: ExternalParity/Tests/ExternalTestSupport/Support.swift#audit-on-the-engine-thread -->
```swift
/// Runs `pipeline` on an engine and audits what the thread that runs its plan asks of the heap
/// while it processes `blocks` blocks, after `warmUp` blocks outside the audit: the source,
/// the plan with its kernels and nodes, and the sinks, as they run in an app. That thread is
/// the engine's analysis thread for a source paced in real time (`pacing: .realTime`), and a
/// thread of the session's own for one that is read as fast as it is processed.
///
/// Nothing public runs a plan block by block on the caller's thread, so `expectNoAllocations`
/// cannot hold a pipeline; `ThreadAllocationAudit` is opened and closed from a callback on the
/// engine's thread instead.
public func expectNoAllocationsOnTheEngineThread<Output: SignalDomain>(
    _ pipeline: Pipeline<Samples, Output>, on source: (any SampleSource)? = nil, format: SignalFormat = mono48, blockSize: Int = 512,
    blocks: Int = 1_000, warmUp: Int = 16, pacing: Pacing = .asFastAsPossible, _ comment: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let audit = ThreadAllocationAudit()
    let counter = BlockCounter()
    let gate = FeatureCallback<Samples> { _ in
        let block = counter.next()
        if block == warmUp { audit.begin() } else if block == warmUp + blocks { audit.end() }
    }
    // Noise of the format, unless the test brings a source of its own: it then delivers at
    // least `warmUp + blocks + 1` blocks.
    let audited: any SampleSource
    if let source {
        audited = source
    } else {
        var channels: [[Float]] = []
        for channel in 0 ..< format.channelCount {
            channels.append(TestSignal.whiteNoise(count: (warmUp + blocks + 4) * blockSize, seed: UInt64(41 + channel), amplitude: 0.5))
        }
        audited = BufferSource(channels: channels, sampleRate: format.sampleRate, pacing: pacing)
    }
    let engine = DSPEngine(blockSize: blockSize)
    let session = try await engine.attach(Pipeline().emit(to: gate).appending(pipeline), to: audited)
    try session.start()
    let closed = await eventually { audit.isClosed || audit.failedToOpen }
    let finished = await session.reaches(.finished)
    session.detach()
    #expect(closed && finished, "\(comment): the audited stretch did not run to its end", sourceLocation: sourceLocation)
    #expect(!audit.failedToOpen, "\(comment): the allocation audit could not be opened: an audit that cannot run is a failure", sourceLocation: sourceLocation)
    let counts = try #require(audit.counts, "\(comment): the audit was not closed", sourceLocation: sourceLocation)
    #expect(counts.allocations == 0 && counts.deallocations == 0, "\(comment): \(blocks) blocks on the engine's thread: \(counts)", sourceLocation: sourceLocation)
}
```

<!-- snippet: ExternalParity/Tests/ExtensionGuideTests/GuideAllocationAuditTests.swift#audit-engine -->
```swift
        let flux = CollectingCount<Novelty>(), meter = PeakHoldMeter()
        let normalized = CollectingCount<Spectrum<LinearFrequency, MagnitudeValues>>()
        let pipeline = Pipeline()
            .despiked()
            .feedbackComb(delay: 0.001, feedback: 0.5)
            .preEmphasis()
            .tap { $0.stft(frame: 1_024, hop: 256).magnitude().spectralFlux().emit(to: flux) }
            .tap { $0.stft(frame: 1_024, hop: 256).magnitude().peakNormalized().emit(to: normalized) }
            .tap { $0.level(.rms).emit(to: meter) }
        try await expectNoAllocationsOnTheEngineThread(pipeline, "the stages of the guide")
```

Run the audits in Debug and in Release: a loop that is free in an optimised build can allocate in
a Debug build (CR-002).
