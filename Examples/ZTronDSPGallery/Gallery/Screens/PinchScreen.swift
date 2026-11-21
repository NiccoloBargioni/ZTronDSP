import SwiftUI
import ZTronDSP
import ZTronDSPUI

/// `.pinchScaling(_:)` (§8.8). On the spectrogram the time span and the frequency range are
/// bound, so a pinch writes the state of this screen, which the labels show (PINCH-5). On the
/// waveform nothing is bound: the view keeps what a pinch made of its span and its range.
struct PinchScreen: View {
    @State private var source = MockSignals.sweep()
    @State private var spectrum = HeatmapFeed(history: 512)
    @State private var envelope = WaveformFeed(history: 1_024)
    @State private var span = 4.0
    @State private var frequencies: ClosedRange<Double> = 40 ... 20_000

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline {
            Spectrogram(frame: 2_048, hop: 512, to: spectrum)
            Tap { Waveform(resolution: 0.005); Emit(to: envelope) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Written the same in every region: a UI test reads the numbers back.
            Text(verbatim: "span " + String(format: "%.4f", span))
                .font(.caption.monospacedDigit())
                .accessibilityIdentifier("pinch.span")
            Text(verbatim: "range " + String(format: "%.2f %.2f", frequencies.lowerBound, frequencies.upperBound))
                .font(.caption.monospacedDigit())
                .accessibilityIdentifier("pinch.range")
            SpectrogramView(feed: spectrum)
                .frequencyScale(.logarithmic)
                .timeSpan($span)
                .frequencyRange($frequencies)
                .pinchScaling([.horizontal, .vertical])
                .axis(.frequency)
                .axis(.time)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pinch.spectrogram")
            WaveformView(feed: envelope)
                .pinchScaling([.horizontal, .vertical])
                .axis(.time)
                .frame(height: 120)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pinch.waveform")
        }
        .pipeline(analysis, on: source)
        .padding()
    }
}
