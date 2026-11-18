import Foundation
import SwiftUI
import Testing
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// What `init(source:)` runs (§8.1, the table): each component's pipeline, description for
/// description, where the values of `.analysisFrame`, `.melBands` and `.processing` go in
/// it, and what of it an animation interpolates (WP-814, WP-815, WP-817).
@MainActor
@Suite("What a source-fed component runs")
struct SourceRecipeTests {
    private let voice = Pipeline<Samples, Samples> {
        Gain(.decibels(-6))
        LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
    }

    // MARK: The recipes (§8.1)

    /// `SpectrogramView`: `STFT → Power → Decibels`, the recipe `Spectrogram`.
    @Test func aSpectrogramRunsTheRecipeSpectrogram() {
        let feed = HeatmapFeed()
        let pipeline = HeatmapAnalysis.spectrogram.pipeline(processing: nil, frame: nil, melBands: nil, into: feed)
        #expect(pipeline == Pipeline { Spectrogram(to: feed) }, "the recipe with its own defaults")
        #expect(pipeline == Pipeline { Spectrogram(frame: 2_048, hop: 512, window: .hann, to: feed) })
        #expect(pipeline == Pipeline {
            Tap {
                STFT(frame: 2_048, hop: 512, window: .hann, normalization: .amplitude)
                Power()
                Decibels()
                Emit(to: feed)
            }
        }, "what the recipe expands to: a side branch, the samples pass on")
        #expect(pipeline != Pipeline { Spectrogram(to: HeatmapFeed()) }, "into the feed it was given, and no other")
    }

    /// `.analysisFrame(_:hop:window:)` sets the frame, the hop and the window of the transform.
    @Test func theAnalysisFrameSetsTheTransformOfASpectrogram() {
        let feed = HeatmapFeed()
        let frame = AnalysisFrame(frame: 4_096, hop: 1_024, window: .blackmanHarris)
        let pipeline = HeatmapAnalysis.spectrogram.pipeline(processing: nil, frame: frame, melBands: 64, into: feed)
        #expect(pipeline == Pipeline { Spectrogram(frame: 4_096, hop: 1_024, window: .blackmanHarris, to: feed) })
        #expect(pipeline != Pipeline { Spectrogram(frame: 4_096, hop: 1_024, to: feed) }, "the window is part of it")
        #expect(AnalysisFrame.standard == AnalysisFrame(frame: 2_048, hop: 512, window: .hann))
    }

    /// `WaveformView`: the step `Waveform`.
    @Test func aWaveformRunsTheStepWaveform() {
        let feed = WaveformFeed()
        let pipeline = WaveformAnalysis.pipeline(processing: nil, into: feed)
        #expect(pipeline == Pipeline {
            Tap {
                Waveform()
                Emit(to: feed)
            }
        })
        #expect(pipeline == Pipeline<Samples, Samples>().tap { $0.waveform(resolution: 0.005).emit(to: feed) }, "five milliseconds a pair")
    }

    /// `ChromagramView`: the recipe `ChromaCQT`. A constant-Q transform has no frame.
    @Test func aChromagramRunsTheRecipeChromaCQT() {
        let feed = HeatmapFeed()
        let pipeline = HeatmapAnalysis.chromagram.pipeline(processing: nil, frame: nil, melBands: nil, into: feed)
        #expect(pipeline == Pipeline { ChromaCQT(to: feed) })
        #expect(pipeline == Pipeline {
            Tap {
                ConstantQ()
                Magnitude()
                ChromaFold()
                Emit(to: feed)
            }
        }, "what the recipe expands to")
        let framed = HeatmapAnalysis.chromagram.pipeline(processing: nil, frame: AnalysisFrame(frame: 512, hop: 100, window: .hamming), melBands: 12, into: feed)
        #expect(framed == pipeline, "neither the frame nor the mel bands are read")
    }

    /// `TempogramView`: a mel spectrogram, then `OnsetStrength`, then `Tempogram`.
    @Test func aTempogramRunsAMelSpectrogramItsOnsetStrengthAndATempogram() {
        let feed = HeatmapFeed()
        let pipeline = HeatmapAnalysis.tempogram.pipeline(processing: nil, frame: nil, melBands: nil, into: feed)
        // The fluent spelling: the same stages, written another way.
        func mel(_ branch: Pipeline<Samples, Samples>) -> Pipeline<Samples, Spectrum<MelFrequency, DecibelValues>> {
            branch.stft(frame: 2_048, hop: 512, window: .hann).power().melScale(bands: 128).decibels()
        }
        #expect(pipeline == Pipeline<Samples, Samples>().tap { mel($0).onsetStrength().tempogram().emit(to: feed) })
        // What comes before the onset strength is the mel spectrogram of the recipe of that name.
        #expect(Pipeline<Samples, Samples>().tap { mel($0).emit(to: feed) } == Pipeline { MelSpectrogram(to: feed) })
        // The onset strength and the tempogram run with their own defaults.
        #expect(pipeline == Pipeline<Samples, Samples>().tap {
            mel($0).onsetStrength(lag: 1, maxSize: 1, floor: -80).tempogram(.autocorrelation, window: 384, taper: .hann, range: 30 ... 300, alignment: .causal).emit(to: feed)
        })
        #expect(pipeline != Pipeline<Samples, Samples>().tap { mel($0).onsetStrength().tempogram(.fourier).emit(to: feed) })
    }

    /// `.melBands(_:)` sets the bands of the tempogram's mel spectrogram, and
    /// `.analysisFrame(_:hop:window:)` its transform.
    @Test func theMelBandsAndTheAnalysisFrameSetTheTempogramsMelSpectrogram() {
        let feed = HeatmapFeed()
        let frame = AnalysisFrame(frame: 1_024, hop: 256, window: .hamming)
        let pipeline = HeatmapAnalysis.tempogram.pipeline(processing: nil, frame: frame, melBands: 40, into: feed)
        #expect(pipeline == Pipeline<Samples, Samples>().tap {
            $0.stft(frame: 1_024, hop: 256, window: .hamming).power().melScale(bands: 40).decibels().onsetStrength().tempogram().emit(to: feed)
        })
        #expect(pipeline != HeatmapAnalysis.tempogram.pipeline(processing: nil, frame: frame, melBands: 41, into: feed))
        #expect(HeatmapAnalysis.standardMelBands == 128)
    }

    // MARK: `.processing(_:)` stands in front (VC-4)

    /// `.processing(_:)` puts its pipeline in front of the recipe: the recipe analyses the
    /// processed signal.
    @Test(arguments: SourceComponent.allCases)
    func processingStandsInFrontOfTheRecipe(component: SourceComponent) {
        let heatmap = HeatmapFeed(), waveform = WaveformFeed()
        func pipeline(_ processing: Pipeline<Samples, Samples>?) -> Pipeline<Samples, Samples> {
            component.analysis?.pipeline(processing: processing, frame: nil, melBands: nil, into: heatmap)
                ?? WaveformAnalysis.pipeline(processing: processing, into: waveform)
        }
        let plain = pipeline(nil), processed = pipeline(voice)
        #expect(processed.stages == voice.stages + plain.stages, "the processing first, then the recipe")
        #expect(processed.stages.count == 3 && plain.stages.count == 1)
        #expect(pipeline(Pipeline()) == plain, "an empty pipeline is no processing")
        #expect(processed != plain)
    }

    // MARK: What the components start from

    @Test func eachAnalysisHasTheDefaultsOfItsComponent() {
        #expect(HeatmapAnalysis.spectrogram.role == .spectrogram && HeatmapAnalysis.chromagram.role == .chromagram && HeatmapAnalysis.tempogram.role == .tempogram)
        #expect(HeatmapAnalysis.chromagram.role.rowInterpolation == .nearest && !HeatmapAnalysis.chromagram.role.scalesRows)
        #expect(HeatmapAnalysis.tempogram.role.valueRange == 0 ... 1 && HeatmapAnalysis.spectrogram.role.valueRange == -90 ... 0)
        // The feed a component owns keeps a little over ten seconds of its default analysis
        // at 48 kHz: 93.75 columns, or 200 pairs, a second.
        #expect(Double(HeatmapAnalysis.history) / (48_000.0 / 512) > 10 && Double(HeatmapAnalysis.history) / (48_000.0 / 512) < 11)
        #expect(Double(WaveformAnalysis.history) / 200 > 10 && Double(WaveformAnalysis.history) / 200 < 11)
    }

    // MARK: The components (V-1)

    /// A component stores its source and nothing else, and two views of one source are equal.
    @Test func componentsAreEqualWhenTheyAnalyseTheSameSource() {
        let source = GatedSource(), other = GatedSource()
        let feed = HeatmapFeed(), wave = WaveformFeed()
        #expect(SpectrogramView(source: source) == SpectrogramView(source: source) && SpectrogramView(source: source) != SpectrogramView(source: other))
        #expect(ChromagramView(source: source) == ChromagramView(source: source) && ChromagramView(source: source) != ChromagramView(source: other))
        #expect(TempogramView(source: source) == TempogramView(source: source) && TempogramView(source: source) != TempogramView(source: other))
        #expect(WaveformView(source: source) == WaveformView(source: source) && WaveformView(source: source) != WaveformView(source: other))
        // A view of a source is no view of a feed.
        #expect(SpectrogramView(source: source) != SpectrogramView(feed: feed) && WaveformView(source: source) != WaveformView(feed: wave))
        #expect(ChromagramView(feed: feed) != ChromagramView(source: source) && TempogramView(feed: feed) != TempogramView(source: source))
        // Any kind of source will do (SRC-3): a mock, a processed signal.
        let mock: any SampleSource = Tone.mock([0, 0])
        let processed: any SampleSource = source.processed(by: Pipeline())
        #expect(SpectrogramView(source: mock) == SpectrogramView(source: mock) && SpectrogramView(source: processed) != SpectrogramView(source: source))
        // A view is as large as a reference to its source: there is nothing in it that could
        // change from frame to frame.
        #expect(MemoryLayout<SpectrogramView>.size == MemoryLayout<any SampleSource>.size && MemoryLayout<WaveformView>.size == MemoryLayout<any SampleSource>.size)
        #expect(MemoryLayout<ChromagramView>.size == MemoryLayout<any SampleSource>.size && MemoryLayout<TempogramView>.size == MemoryLayout<any SampleSource>.size)
    }

    @Test func inputsAreEqualWhenTheyNameTheSameObject() {
        let feed = HeatmapFeed(), source = GatedSource()
        #expect(ComponentInput.feed(feed) == ComponentInput.feed(feed) && ComponentInput.feed(feed) != ComponentInput.feed(HeatmapFeed()))
        #expect(ComponentInput<HeatmapFeed>.source(source) == .source(source) && ComponentInput<HeatmapFeed>.source(source) != .source(GatedSource()))
        #expect(ComponentInput.feed(feed) != .source(source) && ComponentInput<HeatmapFeed>.source(source) != .feed(feed))
    }

    // MARK: What an animation interpolates (WP-817, ANI-2 … ANI-4)

    private func chain(_ gains: [Double], cutoff: Double? = nil) -> Pipeline<Samples, Samples> {
        var pipeline = Pipeline<Samples, Samples>()
        for gain in gains { pipeline = pipeline.gain(.decibels(gain)) }
        if let cutoff { pipeline = pipeline.lowPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }
        return pipeline
    }

    /// The host of a source-fed component is animatable over the continuous values of what
    /// it attaches: those of the processing, in order, and whatever the recipe has of its own.
    @Test(arguments: SourceComponent.allCases)
    func theVectorOfASourceFedPipelineHoldsTheValuesOfItsProcessing(component: SourceComponent) {
        let heatmap = HeatmapFeed(), waveform = WaveformFeed()
        func pipeline(_ processing: Pipeline<Samples, Samples>?, frame: AnalysisFrame? = nil) -> Pipeline<Samples, Samples> {
            component.analysis?.pipeline(processing: processing, frame: frame, melBands: nil, into: heatmap)
                ?? WaveformAnalysis.pipeline(processing: processing, into: waveform)
        }
        let recipe = AnimatableParameters(pipeline(nil)).values
        let from = AnimatableParameters(pipeline(chain([-6, -12], cutoff: 1_024))), to = AnimatableParameters(pipeline(chain([-30, -2], cutoff: 4_096)))
        #expect(from.values == [-6, -12, 10] + recipe, "gains in decibels, the cutoff as log₂ of hertz (ANI-2), then the recipe's own")
        #expect(from.structure == to.structure, "other values of the same stages: the same topology")
        // Halfway through an animation: every value halfway, the cutoff halfway in pitch.
        var half = to - from
        #expect(!half.isReplacement)
        half.scale(by: 0.5)
        let frame = from + half
        #expect(frame.values == [-18, -7, 11] + recipe)
        #expect(pipeline(chain([-30, -2], cutoff: 4_096)).replacingParameters(frame.vector) == pipeline(chain([-18, -7], cutoff: 2_048)),
                "the pipeline that frame runs: the same recipe behind a processing with the frame's values, an octave either way")
        // Another stage in the processing is another topology: applied at once (ANI-4).
        let longer = AnimatableParameters(pipeline(chain([-6, -12, -1], cutoff: 1_024)))
        var jump = longer - from
        #expect(jump.isReplacement)
        jump.scale(by: 0.3)
        #expect((from + jump).values == longer.values)
    }

    /// Another frame, or another number of bands, is another topology although no
    /// continuous value differs: it is not interpolated (ANI-4).
    @Test func anotherFrameOrAnotherNumberOfBandsIsAnotherTopology() {
        let feed = HeatmapFeed(), gains = chain([-6])
        func vector(_ analysis: HeatmapAnalysis, frame: Int, bands: Int? = nil) -> AnimatableParameters {
            AnimatableParameters(analysis.pipeline(processing: gains, frame: AnalysisFrame(frame: frame, hop: 256, window: .hann), melBands: bands, into: feed))
        }
        for analysis in [HeatmapAnalysis.spectrogram, .tempogram] {
            let from = vector(analysis, frame: 1_024), to = vector(analysis, frame: 2_048)
            #expect(from.values == to.values && from.structure != to.structure, "\(analysis)")
            var delta = to - from
            #expect(delta.isReplacement, "\(analysis)")
            delta.scale(by: 0.5)
            #expect((from + delta).structure == to.structure, "\(analysis): the target, at once")
        }
        #expect((vector(.tempogram, frame: 1_024, bands: 40) - vector(.tempogram, frame: 1_024, bands: 64)).isReplacement)
        #expect(!(vector(.tempogram, frame: 1_024, bands: 40) - vector(.tempogram, frame: 1_024, bands: 40)).isReplacement)
    }

    /// The host a source-fed component is made of is the host of `.pipeline(_:on:)`: at rest
    /// it runs the pipeline it was given, and in an animation frame the same stages with the
    /// frame's values.
    @Test func theHostOfASourceFedComponentRunsTheFramesValues() {
        let feed = HeatmapFeed(), source = GatedSource()
        let target = HeatmapAnalysis.spectrogram.pipeline(processing: chain([-30], cutoff: 4_096), frame: nil, melBands: nil, into: feed)
        var host = PipelineHost(content: EmptyView(), pipeline: target, source: source)
        #expect(host.shownPipeline == target)
        let recipe = AnimatableParameters(HeatmapAnalysis.spectrogram.pipeline(processing: nil, frame: nil, melBands: nil, into: feed)).values
        host.animatableData = AnimatableParameters(values: [-18, 11] + recipe)
        #expect(host.shownPipeline == HeatmapAnalysis.spectrogram.pipeline(processing: chain([-18], cutoff: 2_048), frame: nil, melBands: nil, into: feed))
        #expect(host.pipeline == target, "where the animation ends does not move")
    }
}
