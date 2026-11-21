import SwiftUI
import ZTronDSPCore

// What a source-fed component computes is set with modifiers, one value each, never with an
// object that carries settings (VC-4, API-6). Each modifier puts its value into the SwiftUI
// environment, so it may sit on the component or on any view around it, and the one nearest
// to a component is the one that component reads.
//
// The values reach the session the component keeps on its source (VC-3). A value that is set
// to what it already is causes nothing. Another frame, hop, window or number of bands is
// another topology: the session compiles a new plan and exchanges it at a block boundary,
// and the component's picture refills (§5.5.4). Another `.processing` pipeline is whatever
// the difference between the two pipelines makes it: nothing, a change of values, or another
// topology.
//
// A component that was given a feed, `init(feed:)`, computes nothing and reads none of them.
//
// Threading: main actor, like every view modifier. None of them allocates beyond the small
// value it stores; the plan a changed value asks for is compiled off the main thread.

extension View {
    /// The frame, the hop and the window of the short-time Fourier transform that the
    /// source-fed components inside this view run: `SpectrogramView(source:)`, and the mel
    /// spectrogram of `TempogramView(source:)`. Without this modifier they run 2 048 samples
    /// per frame, 512 from one frame to the next, under a Hann window.
    ///
    /// ```swift
    /// SpectrogramView(source: mic)
    ///     .analysisFrame(4_096, hop: 1_024, window: .blackmanHarris)
    /// ```
    ///
    /// A longer frame tells frequencies apart more finely and times less so; the hop sets how
    /// many columns a second the picture gets. A frame the transform cannot take (a length
    /// that is no fast length, a hop below 1) is refused when the plan is compiled: it is
    /// logged, and the component keeps what it ran before.
    ///
    /// A chromagram's constant-Q transform has no frame of this kind and a waveform is not
    /// framed: `ChromagramView(source:)` and `WaveformView(source:)` do not read this value.
    /// Not animatable: a frame is structure, and another one is applied at once (ANI-4).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value, and may
    /// allocate as SwiftUI does for any environment value.
    public func analysisFrame(_ frame: Int, hop: Int, window: Window = .hann) -> some View {
        environment(\.dspAnalysisFrame, AnalysisFrame(frame: frame, hop: hop, window: window))
    }

    /// The number of mel bands of the mel spectrogram that `TempogramView(source:)` takes
    /// its onset strength from; 128 without this modifier. No other component reads it: a
    /// spectrogram is laid out on a mel scale by `.frequencyScale(.mel)`, for display only.
    ///
    /// Not animatable: a number of bands is structure, and another one is applied at once
    /// (ANI-4).
    ///
    /// Threading: main actor, like every view modifier; it stores one small value, and may
    /// allocate as SwiftUI does for any environment value.
    public func melBands(_ bands: Int) -> some View {
        environment(\.dspMelBands, bands)
    }

    /// Puts `pipeline` in front of what the source-fed components inside this view compute
    /// (VC-4): they show the processed signal instead of the raw one.
    ///
    /// ```swift
    /// @State private var cutoff = 1_000.0
    /// var voice: Pipeline<Samples, Samples> { Pipeline { LowPass(.butterworth, cutoff: .hertz(cutoff), order: 4) } }
    ///
    /// SpectrogramView(source: mic).processing(voice)
    /// Button("Open up") { withAnimation(.easeInOut(duration: 2)) { cutoff = 8_000 } }   // the cutoff glides
    /// ```
    ///
    /// Each component runs the pipeline, followed by its own recipe, as the one attachment
    /// it keeps on its source (VC-3); the source itself is untouched, and so is every other
    /// attachment it serves. Two components inside one `.processing` each run a copy, with
    /// its own filter memory (ATT-1), so a pipeline that writes a sink of its own, a feed or
    /// a stream, serves one component only (ATT-5).
    ///
    /// The component hosts the pipeline as `.pipeline(_:on:)` hosts one (ANI-3). An equal
    /// pipeline causes no update. A pipeline of the same topology with other values is a
    /// value update, and inside `withAnimation` the session receives one interpolated update
    /// per display frame: frequencies glide evenly in pitch and gains in decibels (ANI-2).
    /// A pipeline of another topology is applied at once (ANI-4). When a stage's design is
    /// not finished by the time the next frame arrives, the newest frame wins (ANI-5). A
    /// pipeline the engine refuses is logged, and the component keeps what it ran before.
    ///
    /// Threading: main actor, like every view modifier; it stores the pipeline, a value, and
    /// may allocate as SwiftUI does for any environment value. Attaching and updating suspend
    /// off the main thread.
    public func processing(_ pipeline: Pipeline<Samples, Samples>) -> some View {
        environment(\.dspProcessing, pipeline)
    }

    /// Puts the stages of `content` in front of what the source-fed components inside this
    /// view compute: `.processing(_:)` with the pipeline written in place. This is the form
    /// for a block that holds more than sequence stages: a measuring step, a tap, a recipe.
    ///
    /// ```swift
    /// SpectrogramView(source: mic)
    ///     .processing { HighPass(.butterworth, cutoff: .hertz(90), order: 4); Level(.rms, to: $level) }
    /// ```
    ///
    /// Threading: main actor, like every view modifier. `content` is called once, at once,
    /// and allocates the pipeline it describes.
    public func processing(@PipelineBuilder _ content: () -> Pipeline<Samples, Samples>) -> some View {
        processing(content())
    }

    /// Puts the sequence stages of `content` (gains, filters, smoothers) in front of what the
    /// source-fed components inside this view compute: `.processing(_:)` with the pipeline
    /// written in place.
    ///
    /// ```swift
    /// SpectrogramView(source: mic)
    ///     .processing { HighPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }
    /// ```
    ///
    /// Threading: main actor, like every view modifier. `content` is called once, at once,
    /// and allocates the pipeline it describes.
    public func processing(@PipelineBuilder _ content: () -> SequenceChain) -> some View {
        processing(Pipeline<Samples, Samples>(content))
    }
}
