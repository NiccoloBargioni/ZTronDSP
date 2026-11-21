import SwiftUI
import ZTronDSP
import ZTronDSPUI

// The views that are fed by a source (VC-3, VC-4): `SpectrogramView(source:)`,
// `WaveformView(source:)`, `ChromagramView(source:)` and `TempogramView(source:)`. Each keeps
// one attachment of its own recipe on the source while it is in the hierarchy, into a feed of
// its own, and detaches when the screen leaves: there is no pipeline to write and no feed to
// keep. What is computed is set with modifiers: `.analysisFrame(_:hop:window:)`,
// `.melBands(_:)` and `.processing(_:)`.
//
// The sources are mocks, kept in `@State` and never made in a body: a source that is made
// anew with every evaluation would be another source every time, and the view would attach
// again.

/// The four source-fed views, each on a mock source. The spectrogram shows the sweep behind a
/// high-pass filter whose cutoff a button moves, with a transform of its own; the waveform
/// shows the same source unprocessed, as a second attachment (ATT-6).
struct SourceFedScreen: View {
    @State private var sweep = MockSignals.sweep()
    @State private var chord = MockSignals.arpeggio()
    @State private var clicks = MockSignals.clicks()
    /// The cutoff of the filter in front of the spectrogram, in hertz.
    @State private var cutoff = 90.0

    private var isOpen: Bool { cutoff < 1_000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            caption("SpectrogramView(source:) with .processing and .analysisFrame")
            SpectrogramView(source: sweep)
                // The processed signal instead of the raw one. Inside withAnimation the
                // cutoff glides: the session is sent one value per display frame (ANI-3).
                .processing { HighPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }
                .analysisFrame(1_024, hop: 256, window: .blackmanHarris)
                .colorMap(.magma)
                .valueRange(-90 ... 0)
                .frequencyScale(.logarithmic)
                .frequencyRange(40 ... 20_000)
                .axis(.frequency)
            Button(isOpen ? "Cut below 2 kHz" : "Let the low end through") {
                withAnimation(.easeInOut(duration: 2)) { cutoff = isOpen ? 2_000 : 90 }
            }
            .font(.footnote)
            .accessibilityIdentifier("sourceFed.cutoff")

            caption("WaveformView(source:), the same source")
            WaveformView(source: sweep)
                .timeSpan(4)

            caption("ChromagramView(source:)")
            ChromagramView(source: chord)
                .colorMap(.viridis)

            caption("TempogramView(source:) with .melBands")
            TempogramView(source: clicks)
                .melBands(64)
                .colorMap(.inferno)
        }
        .padding()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospaced())
            .foregroundColor(.secondary)
    }
}
