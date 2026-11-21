import SwiftUI
import ZTronDSP
import ZTronDSPUI

/// The part of the spike WP-822 that the application can see by itself, without UIKit: the
/// sizes SwiftUI hands a view while its frame is animated and while the interface turns
/// (SZ-4, the probe's signal). The layer's half of the spike needs the Metal view's layer
/// and lives in the hosted tests (`GalleryTests/SizeTransitionSpike.swift`).
///
/// Two spectrograms: one in a frame the button animates between 200 × 120 and 320 × 300
/// points, one that fills what the screen leaves, which a rotation resizes. Behind each lies
/// a probe built like the one in `ZTronDSPUI`: an `Animatable` view that is given the size a
/// `GeometryReader` measures. The log says, line by line, which sizes the probe's body and
/// its animatable data were given. A UI test presses the button and turns the device.
struct SizeSpikeScreen: View {
    @State private var source = MockSignals.sweep()
    @State private var feed = HeatmapFeed(history: 512)
    @State private var isLarge = false
    @State private var log = SpikeLog(name: Launch.value("SpikeLog") ?? "size-spike")
    @State private var recorded = 0

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline { Spectrogram(frame: 2_048, hop: 512, to: feed) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button("Resize") {
                    log.note("button isLarge=\(!isLarge)")
                    withAnimation(.linear(duration: 0.5)) { isLarge.toggle() }
                }
                .accessibilityIdentifier("spike.resize")
                Button("Save") {
                    log.save()
                    recorded = log.lines.count
                }
                .accessibilityIdentifier("spike.save")
                Text("\(recorded)")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("spike.summary")
            }
            SpectrogramView(feed: feed)
                .background(GeometryReader { proxy in SizeProbe(size: proxy.size, tag: "frame", log: log) })
                .frame(width: isLarge ? 320 : 200, height: isLarge ? 300 : 120)
            SpectrogramView(feed: feed)
                .background(GeometryReader { proxy in SizeProbe(size: proxy.size, tag: "fill", log: log) })
        }
        .pipeline(analysis, on: source)
        .padding(8)
        .onAppear {
            log.note("screen os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        }
    }
}

/// An `Animatable` view that is given a size, as the size probe of `ZTronDSPUI` is: it
/// writes down every size its body is evaluated with and every size SwiftUI sets through
/// its animatable data.
struct SizeProbe: View, Animatable {
    var size: CGSize
    let tag: String
    let log: SpikeLog

    nonisolated var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(size.width, size.height) }
        set {
            size = CGSize(width: newValue.first, height: newValue.second)
            let size = size, tag = tag, log = log
            MainActor.assumeIsolated { log.note("probe.set tag=\(tag) size=\(SpikeFormat.size(size))") }
        }
    }

    var body: some View {
        let _ = log.note("probe.body tag=\(tag) size=\(SpikeFormat.size(size))")
        Color.clear
    }
}
