import SwiftUI
import ZTronDSP
import ZTronDSPUI

/// `.pipeline(_:on:)` with a value that animates (ANI-3): the cutoff of a low-pass in front
/// of the spectrogram. Inside `withAnimation` the host hands the session one update per
/// display frame with the cutoff on its way, and the edge of the noise glides.
struct AnimatedPipelineScreen: View {
    @State private var source = MockSignals.noise()
    @State private var feed = HeatmapFeed(history: 512)
    @State private var cutoff = 400.0

    private var filtered: Pipeline<Samples, Samples> {
        Pipeline {
            LowPass(.butterworth, cutoff: .hertz(cutoff), order: 4)
            Spectrogram(frame: 1_024, hop: 256, to: feed)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            SpectrogramView(feed: feed)
                .frequencyScale(.logarithmic)
                .frequencyRange(40 ... 20_000)
                .axis(.frequency)
                .axis(.time)
                .pipeline(filtered, on: source)
            Text("cutoff \(cutoff, specifier: "%.0f") Hz")
                .font(.caption.monospacedDigit())
                .accessibilityIdentifier("pipeline.cutoff")
            Button(cutoff < 1_000 ? "Open up" : "Close") {
                withAnimation(.easeInOut(duration: 2)) { cutoff = cutoff < 1_000 ? 8_000 : 400 }
            }
            .accessibilityIdentifier("pipeline.toggle")
        }
        .padding()
    }
}

/// Activation (§5.9): two `Toggle`s over `@State`, each bound to a stage's `isActive:`. The
/// first bypasses and restores a boost on the main line, at the next block boundary and
/// without a click; the second suspends and resumes the branch that writes the mel
/// spectrogram, whose view then stops drawing because its feed is no longer live (ACT-11).
/// Flipping a switch compiles nothing (ACT-5).
struct ActivationScreen: View {
    @State private var source = MockSignals.noise()
    @State private var spectrum = HeatmapFeed(history: 512)
    @State private var mel = HeatmapFeed(history: 512)
    @State private var boosts = true
    @State private var showsMel = true

    private var voice: Pipeline<Samples, Samples> {
        Pipeline {
            BandBoost(center: .hertz(2_800), gain: .decibels(18), bandwidth: .octaves(1), isActive: $boosts)
            MelSpectrogram(frame: 2_048, hop: 512, bands: 64, to: mel, isActive: $showsMel)
            Spectrogram(frame: 2_048, hop: 512, to: spectrum)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Presence boost", isOn: $boosts)
                .accessibilityIdentifier("activation.boost")
            Toggle("Mel spectrogram", isOn: $showsMel)
                .accessibilityIdentifier("activation.mel")
            Text("Spectrogram, after the boost").font(.caption)
            SpectrogramView(feed: spectrum)
                .frequencyScale(.logarithmic)
                .valueRange(-70 ... -10)
                .axis(.frequency)
            Text("Mel spectrogram, a branch that can be suspended").font(.caption)
            HeatmapView(feed: mel)
                .valueRange(-20 ... 40)
                .colorMap(.inferno)
        }
        .pipeline(voice, on: source)
        .padding()
    }
}
