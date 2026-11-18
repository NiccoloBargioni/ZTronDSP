// EXT-4: the three stages of the external parity suite stand wherever their stock twins stand
// (§5.8, O-1, O-5), in the builder and in the fluent spelling, each with its switch (ACT-1),
// and a client sees them through the public products alone.
import ExternalStages
import SwiftUI
import ZTronDSP

@MainActor func accepted(flag: Bool, shown: Binding<Bool>, feed: HeatmapFeed, level: Binding<Float>) {
    // The two sequence stages: on samples, under a switch, inside control flow.
    let samples: Pipeline<Samples, Samples> = Pipeline {
        ExternalGain(.decibels(-3))
        ExternalGain(channels: [.decibels(-3)], isActive: shown)
        ExternalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4)
        ExternalLowPass(.elliptic(ripple: .decibels(1), stopband: .decibels(60)), cutoff: .fractionOfNyquist(0.5), order: 5, isActive: false)
        if flag {
            ExternalGain(.linear(2), isActive: .bypassed)
        }
        for cutoff in [2_000.0, 4_000.0] {
            ExternalLowPass(.bessel(), cutoff: .hertz(cutoff), order: 2)
        }
        Gain(.decibels(1))
        LowPass(.butterworth, cutoff: .hertz(12_000), order: 2)
    }
    let fluent: Pipeline<Samples, Samples> = Pipeline()
        .externalGain(.decibels(-3), isActive: shown)
        .externalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4, isActive: true)
        .gain(.decibels(1))

    // On a sampled sequence that is not samples: a scalar track, where the cutoff is a frequency of the track.
    let track: Pipeline<Samples, Scalar> = Pipeline {
        Level(.rms)
        ExternalGain(.linear(2))
        ExternalLowPass(.butterworth, cutoff: .hertz(4), order: 2)
        Emit(to: level)
    }

    // The step family: after magnitudes or powers on a linear-frequency axis, before the decibel conversion.
    let mel: Pipeline<Samples, Spectrum<MelFrequency, DecibelValues>> = Pipeline {
        STFT(frame: 2_048, hop: 512)
        Power()
        ExternalMelScale(bands: flag ? 128 : 64, isActive: shown)
        Decibels()
        Emit(to: feed)
    }
    let magnitudes: Pipeline<Samples, Spectrum<MelFrequency, MagnitudeValues>> = Pipeline {
        ExternalGain(.decibels(-3))
        STFT(frame: 1_024, hop: 256)
        Magnitude()
        ExternalMelScale(bands: 40, range: .hertz(300 ... 8_000), formula: .htk, normalization: .none)
    }
    // A branch that begins with the step is written fluently (ORD-3); what follows a mel axis follows it.
    let branched: Pipeline<Samples, Samples> = Pipeline()
        .externalGain(.decibels(-3))
        .tap { $0.stft(frame: 2_048, hop: 512).power().tap { $0.externalMelScale(bands: 40).decibels().cepstralCoefficients(count: 13) } }
        .externalLowPass(.butterworth, cutoff: .hertz(8_000), order: 4)

    // A pipeline assembled from data takes the descriptions as it takes the stock ones (ORD-5).
    let description: StageDescription = ExternalMelScale(bands: 40).stageDescription
    let rule: DomainRule = ExternalMelScale.rule
    _ = (samples, fluent, track, mel, magnitudes, branched, description, rule)
}
