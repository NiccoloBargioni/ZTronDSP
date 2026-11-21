# ``ZTronDSP``

Real-time audio DSP on iOS behind one declarative facade: describe a pipeline once, attach it to any
source, and show what it produces.

## Overview

ZTronDSP is a Swift package that puts one facade in front of real-time audio signal processing on
iOS. A pipeline of processing and analysis stages is described once, as an immutable value, and
attached, unchanged, to any sample source: the microphone, a tap on the app's own playback, a
file, a generator, a scripted mock, or the output of another pipeline. Metal-backed SwiftUI
components display what a source or a pipeline produces, from waveforms to spectrograms,
chromagrams and tempograms. Everything the package's own stages are built from is public, so a
stage written outside the package is the equal of one inside it.

### Products and modules

The package has three products. `import ZTronDSP` is the facade: it re-exports the five modules
below that hold no view. `ZTronDSPUI` adds the views, and `ZTronDSPTesting` is what the author of
a stage needs to test it.

| Module | Product | What it holds |
|---|---|---|
| [ZTronDSPCore](/documentation/ztrondspcore) | `ZTronDSP` | Units, signal domains, the environment, the stage protocols, the pipeline builder, the plan compiler, the engine, sources and sinks, feeds, mock sources, the toolkit, the background executor, the MATLAB writer. No processing stage. |
| [ZTronDSPDesign](/documentation/ztrondspdesign) | `ZTronDSP` | Linear time-invariant systems: prototypes, transforms, FIR design, pole–zero analysis. The sequence stages: gain, filters, smoothers, rate changers, convolution. |
| [ZTronDSPAnalysis](/documentation/ztrondspanalysis) | `ZTronDSP` | Every spectral step and recipe, from the short-time Fourier transform to chroma, tempograms and harmonic–percussive separation; their strategies, the GPU ones included; the inversion and window analyses. |
| [ZTronDSPIO](/documentation/ztrondspio) | `ZTronDSP` | Hardware input and input selection, the tap on a node of the app's audio engine, the file source, the audio-session policy. |
| [ZTronDSPMetal](/documentation/ztrondspmetal) | `ZTronDSP` | Textures, renderers, GPU compute kernels, snapshot images. No views. |
| [ZTronDSPUI](/documentation/ztrondspui) | `ZTronDSPUI` | Views, modifiers, gestures, pipeline hosts, and the bridge to the SwiftUI environment. |
| [ZTronDSPTesting](/documentation/ztrondsptesting) | `ZTronDSPTesting` | Allocation audits, closeness expectations, seeded signals, golden vectors, benchmarks. |

Beneath them, the C module `CZTronDSP` holds everything that may run on Core Audio's I/O thread:
the ring buffers, the kernel interface and the plan runner, the stock kernels.

### Describe, compile, run

A pipeline is a description. Each stage is a value; the compiler accepts a stage only after a
signal domain it consumes, so `Magnitude()` follows a complex spectrum and a filter follows
samples or another sampled sequence. The result-builder spelling puts one stage on each line:

<!-- snippet: Tests/ZTronDSPTests/LandingPageTests.swift#builder -->
```swift
let spectrogram = HeatmapFeed()

let pipeline = Pipeline {
    HighPass(.butterworth, cutoff: .hertz(90), order: 4)
    STFT(frame: 1_024, hop: 256)
    Magnitude()
    Decibels()
    Emit(to: spectrogram)
}
```

The fluent spelling chains the same stages, and makes the same value, which compares equal:

<!-- snippet: Tests/ZTronDSPTests/LandingPageTests.swift#fluent -->
```swift
let same = Pipeline()
    .highPass(.butterworth, cutoff: .hertz(90), order: 4)
    .stft(frame: 1_024, hop: 256)
    .magnitude()
    .decibels()
    .emit(to: spectrogram)
```

Nothing runs until the description is attached. Attaching compiles it, on the control context,
into a plan: a flat table of C functions with every buffer allocated and every implementation
chosen for its size. Starting the session runs that plan block by block on the engine's analysis
thread, with no allocation and no lock, and the feed receives a column per frame for a view to
draw:

<!-- snippet: Tests/ZTronDSPTests/LandingPageTests.swift#run -->
```swift
let engine = DSPEngine()
let source = GeneratorSource(.sine(frequency: .hertz(440)), duration: 0.25)
let session = try await engine.attach(pipeline, to: source)    // compiles the plan
try session.start()                                           // runs it
```

These three blocks are the code of a test of the package, which builds and runs them, and the
documentation audit checks that they are still that code.

### Execution contexts

Every public symbol of the package states its threading contract: which context may call it, and
whether it may allocate. The contexts are these, and their names are the words the contracts use:

| Context | Where it runs | What runs there |
|---|---|---|
| I/O thread | Core Audio's I/O thread | The C module only, every function nonblocking: input frames are copied into a ring, nothing else. |
| Analysis thread | One thread per engine | The plan: the signal chain, the analysis nodes, the writes of feeds and results. No allocation, no lock, no Objective-C message. A source that is not real time runs the same work on an offline thread of its own. |
| Control context | A utility queue | Designing filters, compiling plans, allocating, pre-rolling, retiring old plans. It may allocate and lock. |
| Background executor | The package's executor for analyses and exports (`BackgroundWork`) | Offline analyses and exports. |
| Main thread, main actor | The main thread | Bound switches are sampled and results delivered to bindings; views draw on the display link's tick. |
| Any thread | Wherever it is called | Values: a stage, a pipeline, a frequency, a window. Creating one may allocate, and says so. |

## Topics

The facade's own documentation holds every symbol of the five modules it re-exports; each
module's page, linked from the table above, groups them by what they are for.

### Describing a pipeline

- ``Pipeline``
- ``PipelineBuilder``
- ``StageValue``
- ``PipelineStage``
- ``SequenceStage``
- ``Recipe``

### The stages of the example

- ``HighPass``
- ``STFT``
- ``Magnitude``
- ``Decibels``

### Attaching and running it

- ``DSPEngine``
- ``PipelineSession``
- ``SessionState``
- ``SampleSource``
- ``GeneratorSource``
- ``BufferSource``
- ``HardwareInputSource``
- ``FileSource``

### Reading what it produces

- ``Emit``
- ``Tap``
- ``HeatmapFeed``
- ``WaveformFeed``
- ``FeatureStream``

### In the background

- ``BackgroundWork``
