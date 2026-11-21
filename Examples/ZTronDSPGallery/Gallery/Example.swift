import SwiftUI

/// The screens of the gallery.
///
/// A screen is opened from the list, or at launch with the argument `-GalleryExample <name>`,
/// where the name is the case's.
enum Example: String, CaseIterable, Identifiable, Hashable, Sendable {
    // One screen per component, each with its axes.
    case spectrogram, heatmap, chromagram, tempogram, waveform
    // The modifiers.
    case appearance, pinch, sizeChange
    // Pipelines a view hosts.
    case animatedPipeline, activation
    // The views that run their own recipe on a source.
    case sourceFed
    // The spikes WP-818 and WP-822: screens that record what SwiftUI reports.
    case pinchSpike, sizeSpike

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spectrogram: "SpectrogramView"
        case .heatmap: "HeatmapView"
        case .chromagram: "ChromagramView"
        case .tempogram: "TempogramView"
        case .waveform: "WaveformView"
        case .appearance: "Appearance modifiers"
        case .pinch: "Pinch scaling"
        case .sizeChange: "Animated size"
        case .animatedPipeline: "Animated pipeline value"
        case .activation: "Activation"
        case .sourceFed: "Source-fed views"
        case .pinchSpike: "Pinch gestures (WP-818)"
        case .sizeSpike: "Size transitions (WP-822)"
        }
    }

    var chapter: Chapter {
        switch self {
        case .spectrogram, .heatmap, .chromagram, .tempogram, .waveform: .components
        case .appearance, .pinch, .sizeChange: .modifiers
        case .animatedPipeline, .activation: .hosting
        case .sourceFed: .sourceFed
        case .pinchSpike, .sizeSpike: .spikes
        }
    }

    /// The groups the list shows its screens in.
    enum Chapter: String, CaseIterable, Identifiable, Sendable {
        case components = "Components"
        case modifiers = "Modifiers"
        case hosting = "Pipelines a view hosts"
        case sourceFed = "Views fed by a source"
        case spikes = "Spikes"

        var id: String { rawValue }

        var examples: [Example] {
            Example.allCases.filter { $0.chapter == self }
        }
    }

    /// The screens that show a component of the package on a mock source: what the gallery is
    /// there for. The hosted tests open each of them and see it draw.
    static var components: [Example] {
        allCases.filter { $0.chapter != .spikes }
    }
}

/// The screen of an example.
struct ExampleScreen: View {
    let example: Example

    var body: some View {
        screen
            .navigationTitle(example.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var screen: some View {
        switch example {
        case .spectrogram: SpectrogramScreen()
        case .heatmap: HeatmapScreen()
        case .chromagram: ChromagramScreen()
        case .tempogram: TempogramScreen()
        case .waveform: WaveformScreen()
        case .appearance: AppearanceScreen()
        case .pinch: PinchScreen()
        case .sizeChange: SizeChangeScreen()
        case .animatedPipeline: AnimatedPipelineScreen()
        case .activation: ActivationScreen()
        case .sourceFed: SourceFedScreen()
        case .pinchSpike: PinchSpikeScreen()
        case .sizeSpike: SizeSpikeScreen()
        }
    }
}
