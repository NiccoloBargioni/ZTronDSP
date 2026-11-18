import Foundation
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPMetal

/// What a heat-map component runs on a source it was given (§8.1): the analysis that
/// `init(source:)` stands for, as a pipeline into a feed.
///
/// | Component | Runs |
/// |---|---|
/// | `SpectrogramView` | The recipe `Spectrogram`: `STFT → Power → Decibels` |
/// | `ChromagramView` | The recipe `ChromaCQT`: `ConstantQ → Magnitude → ChromaFold` |
/// | `TempogramView` | A mel spectrogram, `STFT → Power → MelScale → Decibels`, then `OnsetStrength → Tempogram` |
///
/// Each is a side branch: the samples pass on unchanged, so the pipeline's main line is the
/// signal the component analyses. The values the analysis modifiers set go where the table
/// says: the frame, the hop and the window into the `STFT`, the bands into the `MelScale`.
/// Every other argument is the step's own default.
///
/// An immutable value, usable on any thread.
enum HeatmapAnalysis: Equatable, Sendable {
    case spectrogram
    case chromagram
    case tempogram

    /// The mel bands of a tempogram's mel spectrogram when `.melBands(_:)` says nothing: the
    /// default of the recipe `MelSpectrogram`.
    static let standardMelBands = 128

    /// Columns the feed of a source-fed component keeps: a little over ten seconds of the
    /// default analysis at 48 kHz, which is 93.75 columns a second.
    static let history = 1_024

    /// The defaults of the component that runs this analysis.
    var role: HeatmapRole {
        switch self {
        case .spectrogram: .spectrogram
        case .chromagram: .chromagram
        case .tempogram: .tempogram
        }
    }

    /// The pipeline a component attaches to its source: `processing`, when `.processing(_:)`
    /// set one, followed by the analysis, which writes `feed`.
    ///
    /// - Parameters:
    ///   - frame: what `.analysisFrame(_:hop:window:)` set; `nil` is the recipes' default.
    ///   - melBands: what `.melBands(_:)` set; `nil` is 128.
    func pipeline(
        processing: Pipeline<Samples, Samples>?, frame: AnalysisFrame?, melBands: Int?, into feed: HeatmapFeed
    ) -> Pipeline<Samples, Samples> {
        let front = processing ?? Pipeline()
        let frame = frame ?? .standard
        switch self {
        case .spectrogram:
            return front.appending(Spectrogram(frame: frame.frame, hop: frame.hop, window: frame.window, to: feed))
        case .chromagram:
            return front.appending(ChromaCQT(to: feed))
        case .tempogram:
            let bands = melBands ?? HeatmapAnalysis.standardMelBands
            return front.appending(Pipeline<Samples, Samples> {
                Tap {
                    STFT(frame: frame.frame, hop: frame.hop, window: frame.window)
                    Power()
                    MelScale(bands: bands)
                    Decibels()
                    OnsetStrength()
                    Tempogram()
                    Emit(to: feed)
                }
            })
        }
    }
}

/// What a waveform component runs on a source it was given (§8.1): the step `Waveform`, one
/// pair of minimum and maximum per five milliseconds, into a feed.
enum WaveformAnalysis {
    /// Pairs the feed of a source-fed waveform keeps: a little over ten seconds at the
    /// step's default of five milliseconds a pair.
    static let history = 2_048

    /// The pipeline a waveform component attaches to its source: `processing`, when
    /// `.processing(_:)` set one, followed by a branch that writes the envelope into `feed`.
    static func pipeline(processing: Pipeline<Samples, Samples>?, into feed: WaveformFeed) -> Pipeline<Samples, Samples> {
        (processing ?? Pipeline()).tap { $0.waveform().emit(to: feed) }
    }
}
