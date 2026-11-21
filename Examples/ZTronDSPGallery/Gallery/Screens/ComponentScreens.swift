import SwiftUI
import ZTronDSP
import ZTronDSPUI

// One screen per component (§8.1), each with its axes. Every screen keeps a mock source and
// the feed its pipeline writes in `@State`, and hosts the pipeline with `.pipeline(_:on:)`:
// it is attached while the screen is in the hierarchy and detached when the screen leaves.

/// `SpectrogramView(feed:)`: a sweep on a logarithmic frequency axis, with both axes.
struct SpectrogramScreen: View {
    @State private var source = MockSignals.sweep()
    @State private var feed = HeatmapFeed(history: 512)

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline { Spectrogram(frame: 2_048, hop: 512, to: feed) }
    }

    var body: some View {
        SpectrogramView(feed: feed)
            .colorMap(.magma)
            .valueRange(-90 ... 0)
            .frequencyScale(.logarithmic)
            .frequencyRange(40 ... 20_000)
            .timeSpan(5)
            .axis(.frequency)
            .axis(.time)
            .pipeline(analysis, on: source)
            .padding()
    }
}

/// `HeatmapView(feed:)`: the generic heat map, here of a mel spectrogram, whose rows are
/// drawn bin for bin. The axes are the standalone views, placed by hand; each takes the feed
/// it labels.
struct HeatmapScreen: View {
    @State private var source = MockSignals.phrase()
    @State private var feed = HeatmapFeed(history: 512)

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline { MelSpectrogram(frame: 2_048, hop: 512, bands: 64, to: feed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FrequencyAxisView(feed: feed)
                    .frame(width: 52)
                HeatmapView(feed: feed)
            }
            TimeAxisView(feed: feed)
                .frame(height: 22)
                .padding(.leading, 52)
        }
        .colorMap(.inferno)
        .valueRange(-40 ... 60)
        .pipeline(analysis, on: source)
        .padding()
    }
}

/// `ChromagramView(feed:)`: the twelve pitch classes of a broken chord.
struct ChromagramScreen: View {
    @State private var source = MockSignals.arpeggio()
    @State private var feed = HeatmapFeed(history: 512)

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline { ChromaCQT(to: feed) }
    }

    var body: some View {
        ChromagramView(feed: feed)
            .timeSpan(5)
            .axis(.pitchClass)
            .axis(.time)
            .pipeline(analysis, on: source)
            .padding()
    }
}

/// `TempogramView(feed:)`: the tempo of a click track, from the onset strength of its mel
/// spectrogram. The first column appears once a whole window of the novelty curve is held.
struct TempogramScreen: View {
    @State private var source = MockSignals.clicks()
    @State private var feed = HeatmapFeed(history: 1_024)

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline {
            Tap {
                STFT(frame: 1_024, hop: 256)
                Power()
                MelScale(bands: 40)
                Decibels()
                OnsetStrength()
                Tempogram(.autocorrelation, window: 256)
                Emit(to: feed)
            }
        }
    }

    var body: some View {
        TempogramView(feed: feed)
            .colorMap(.viridis)
            .axis(.tempo)
            .axis(.time)
            .pipeline(analysis, on: source)
            .padding()
    }
}

/// `WaveformView(feed:)`, twice: live and scrolling on a generator, and as a still overview
/// of a recording that a scripted source delivers as fast as it is processed.
struct WaveformScreen: View {
    @State private var live = MockSignals.arpeggio()
    @State private var liveFeed = WaveformFeed(history: 2_048)
    @State private var recording = MockSignals.recording()
    @State private var overviewFeed = WaveformFeed(history: 750)

    private var liveEnvelope: Pipeline<Samples, Samples> {
        Pipeline { Tap { Waveform(resolution: 0.005); Emit(to: liveFeed) } }
    }

    private var overview: Pipeline<Samples, Samples> {
        Pipeline { Tap { Waveform(resolution: 0.004); Emit(to: overviewFeed) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live").font(.caption)
            WaveformView(feed: liveFeed)
                .timeSpan(4)
                .axis(.time)
                .pipeline(liveEnvelope, on: live)
            Text("Overview of a recording").font(.caption)
            WaveformView(feed: overviewFeed)
                .axis(.time)
                .pipeline(overview, on: recording)
        }
        .padding()
    }
}
