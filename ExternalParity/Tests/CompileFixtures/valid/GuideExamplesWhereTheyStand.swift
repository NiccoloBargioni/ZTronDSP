// WP-908: the examples of the extension guide, as a client of the package writes them: each
// where the order rules accept it (§5.8), in the builder and in the fluent spelling.
import ExtensionGuide
import ExtensionGuideUI
import SwiftUI
import ZTronDSP
import ZTronDSPUI

@MainActor func accepted(flag: Bool, shown: Binding<Bool>, feed: HeatmapFeed, meter: PeakHoldMeter, level: Binding<Float>) {
    // snippet:begin use-sample-stages
    // Rows 2, 3 and 9: sample-domain stages, on samples and on a feature-rate sequence.
    let samples: Pipeline<Samples, Samples> = Pipeline {
        Despike()
        FeedbackComb(delay: 0.010, feedback: 0.5, isActive: shown)
        PreEmphasis(coefficient: 0.97)
        DeEmphasis(coefficient: 0.97, isActive: flag)
        LowPass(.criticallyDamped, cutoff: .hertz(8_000), order: 4)     // row 7
    }
    let fluent: Pipeline<Samples, Samples> = Pipeline().despiked().feedbackComb(delay: 0.010, feedback: 0.5).preEmphasis().deEmphasis(isActive: shown)
    // snippet:end use-sample-stages

    // snippet:begin use-steps
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
    // snippet:end use-steps

    // snippet:begin use-display
    // Rows 6 and 11: a source, and a display of it.
    let source = ClickSource(beatsPerMinute: 120, duration: 10)
    let view = NormalizedSpectrogram(source: source.processed(by: samples), feed: feed)
    // snippet:end use-display
    _ = (fluent, flux, metered, track, branches, view, sineWindowRoundTrip(frame: 1_024), PeakNormalize.rule)
}
