import SwiftUI
import ZTronDSP
import ZTronDSPUI

/// A component whose size is animated (§8.9): a `.frame` change inside `withAnimation`, from
/// 200 × 120 to 320 × 300 points in half a second and back. The picture must not be shown
/// stretched or late at any moment of the change. Turning the device is the other size
/// transition: the second spectrogram fills what the screen leaves.
struct SizeChangeScreen: View {
    @State private var source = MockSignals.sweep()
    @State private var feed = HeatmapFeed(history: 512)
    @State private var isLarge = false

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline { Spectrogram(frame: 2_048, hop: 512, to: feed) }
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(isLarge ? "Shrink" : "Grow") {
                withAnimation(.easeInOut(duration: 0.5)) { isLarge.toggle() }
            }
            .accessibilityIdentifier("size.toggle")
            SpectrogramView(feed: feed)
                .frequencyScale(.logarithmic)
                .frame(width: isLarge ? 320 : 200, height: isLarge ? 300 : 120)
            SpectrogramView(feed: feed)
                .frequencyScale(.logarithmic)
                .colorMap(.inferno)
        }
        .pipeline(analysis, on: source)
        .padding()
    }
}
