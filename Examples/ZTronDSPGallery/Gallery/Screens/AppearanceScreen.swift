import SwiftUI
import ZTronDSP
import ZTronDSPUI

/// The appearance modifiers (VC-4), each with a control: `.colorMap`, `.frequencyScale` and
/// `.maximumFrameRate` take a value; `.valueRange`, `.frequencyRange`, `.timeSpan` and
/// `.amplitudeRange` are given bindings here, the form a pinch writes. The screens of the
/// components show the same four with constants.
struct AppearanceScreen: View {
    @State private var source = MockSignals.sweep()
    @State private var spectrum = HeatmapFeed(history: 512)
    @State private var envelope = WaveformFeed(history: 1_024)

    @State private var colors = Colors.viridis
    @State private var scale = Scale.logarithmic
    @State private var levels: ClosedRange<Float> = -90 ... 0
    @State private var frequencies: ClosedRange<Double> = 40 ... 20_000
    @State private var span = 5.0
    @State private var amplitudes: ClosedRange<Float> = -1 ... 1
    @State private var frameRate = 60

    private var analysis: Pipeline<Samples, Samples> {
        Pipeline {
            Spectrogram(frame: 2_048, hop: 512, to: spectrum)
            Tap { Waveform(resolution: 0.005); Emit(to: envelope) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            SpectrogramView(feed: spectrum)
                .colorMap(colors)
                .frequencyScale(scale)
                .valueRange($levels)
                .frequencyRange($frequencies)
                .axis(.frequency)
                .axis(.time)
            WaveformView(feed: envelope)
                .amplitudeRange($amplitudes)
                .frame(height: 70)
            ScrollView {
                controls
            }
            .frame(maxHeight: 280)
        }
        .timeSpan($span)
        .maximumFrameRate(frameRate)
        .pipeline(analysis, on: source)
        .padding()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Colour map", selection: $colors) {
                ForEach(Colors.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance.colorMap")
            Picker("Frequency scale", selection: $scale) {
                ForEach(Scale.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("appearance.frequencyScale")
            BoundsSliders(title: "Value range, dB", range: doubles($levels), limits: -120 ... 20, gap: 6)
            BoundsSliders(title: "Frequency range, Hz", range: $frequencies, limits: 20 ... 24_000, gap: 200)
            Text("Time span: \(span, specifier: "%.1f") s").font(.caption)
            Slider(value: $span, in: 0.5 ... 5.4)
                .accessibilityIdentifier("appearance.timeSpan")
            BoundsSliders(title: "Amplitude range", range: doubles($amplitudes), limits: -1 ... 1, gap: 0.01)
            Stepper("At most \(frameRate) frames a second", value: $frameRate, in: 1 ... 120, step: 15)
                .font(.caption)
        }
    }

    /// A range of `Float`s as the range of `Double`s the sliders move.
    private func doubles(_ range: Binding<ClosedRange<Float>>) -> Binding<ClosedRange<Double>> {
        Binding(
            get: { Double(range.wrappedValue.lowerBound) ... Double(range.wrappedValue.upperBound) },
            set: { range.wrappedValue = Float($0.lowerBound) ... Float($0.upperBound) })
    }
}

/// The colour maps of the package as one type, so that a picker can choose among them: a
/// colour map written outside the package, which is all `.colorMap(_:)` asks for.
enum Colors: String, CaseIterable, Identifiable, ColorMap {
    case viridis, magma, inferno, turbo, grayscale

    var id: String { rawValue }

    func color(at position: Double) -> DisplayColor {
        switch self {
        case .viridis: ListedColorMap.viridis.color(at: position)
        case .magma: ListedColorMap.magma.color(at: position)
        case .inferno: ListedColorMap.inferno.color(at: position)
        case .turbo: TurboColorMap().color(at: position)
        case .grayscale: GrayscaleColorMap().color(at: position)
        }
    }
}

/// The frequency scales of the package as one type: a scale written outside the package.
enum Scale: String, CaseIterable, Identifiable, FrequencyScale {
    case linear, logarithmic, mel

    var id: String { rawValue }

    func position(of hertz: Double) -> Double {
        switch self {
        case .linear: LinearFrequencyScale().position(of: hertz)
        case .logarithmic: LogarithmicFrequencyScale().position(of: hertz)
        case .mel: MelFrequencyScale.mel.position(of: hertz)
        }
    }

    func frequency(at position: Double) -> Double {
        switch self {
        case .linear: LinearFrequencyScale().frequency(at: position)
        case .logarithmic: LogarithmicFrequencyScale().frequency(at: position)
        case .mel: MelFrequencyScale.mel.frequency(at: position)
        }
    }
}

/// Two sliders for the two ends of a range, which never cross.
struct BoundsSliders: View {
    let title: String
    @Binding var range: ClosedRange<Double>
    /// The lowest and the highest value either end may take.
    let limits: ClosedRange<Double>
    /// The least distance between the two ends.
    let gap: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title): \(range.lowerBound, specifier: "%.2f") … \(range.upperBound, specifier: "%.2f")").font(.caption)
            Slider(value: lower, in: limits)
            Slider(value: upper, in: limits)
        }
    }

    private var lower: Binding<Double> {
        Binding(get: { range.lowerBound }, set: { range = min($0, range.upperBound - gap) ... range.upperBound })
    }

    private var upper: Binding<Double> {
        Binding(get: { range.upperBound }, set: { range = range.lowerBound ... max($0, range.lowerBound + gap) })
    }
}
