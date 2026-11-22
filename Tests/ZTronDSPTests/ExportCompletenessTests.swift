import Foundation
import Testing
import ZTronDSP
@testable import ZTronDSPCore      // BackgroundWork's queue: what an export is shown to wait for (MAT-6)
@testable import ZTronDSPDesign    // SystemAnalysis.exportedFrequencies(): the frequencies `f` holds
import ZTronDSPTesting

// WP-910: every type of the table of §6.14 exports, and its script is what MAT-1…MAT-6 say.
//
// One case per row of the table. The value of a row is typed as nothing more than `Sendable`
// and asked at run time whether it exports, so a conformance taken away fails these tests
// rather than the build (MAT-1). Each script is then read back: its comments; its variables,
// each with the data it must hold, bit for bit (MAT-3); its statements, which are core MATLAB
// and come after the data (MAT-2); and its panels, each with the plots the row lists, by the
// variables and the commands that draw them, and with its axis labels and their units.
//
// MAT-5 (the package writes no file; it returns text) is held by review, not by a test: no
// exporting type has a member that takes a path, a URL or a file handle, and `matlabScript()`
// returns the text, which is all it does.

/// The rows of the table of §6.14, in its order.
enum ExportRow: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case systemAnalysis = "SystemAnalysis"
    case windowAnalysis = "WindowAnalysis"
    case inversionReport = "InversionReport"
    case heatmapSnapshot = "FeedSnapshot of a HeatmapFeed"
    case waveformSnapshot = "FeedSnapshot of a WaveformFeed"
    case scalarTrack = "A track of ScalarFrames"
    case calibrationReport = "CrossoverTable with its measurements"

    var testDescription: String { rawValue }

    /// The type that stands for the row.
    var typeName: String {
        switch self {
        case .systemAnalysis: "SystemAnalysis"
        case .windowAnalysis: "WindowAnalysis"
        case .inversionReport: "InversionReport"
        case .heatmapSnapshot, .waveformSnapshot: "FeedSnapshot"
        case .scalarTrack: "ScalarTrack"
        case .calibrationReport: "CalibrationReport"
        }
    }
}

// MARK: - What a script must hold

/// The data one variable must read back as (MAT-3).
enum ExpectedData: Sendable {
    /// `name = x;` from a `Double`; `nil` is undefined, written `NaN`.
    case scalar(Double?)
    /// `name = [x y …];` from `Double`s; `nil` is undefined.
    case doubles([Double?])
    /// `name = [x y …];` from `Float`s.
    case floats([Float])
    /// `name = [a+bi c-di …];` from the parts of complex numbers.
    case complex(real: [Double], imaginary: [Double])
    /// `name = [a b; c d];` from `Float`s, row after row.
    case floatMatrix(rows: Int, columns: Int, values: [Float])

    /// How many of the values are undefined: what is written as `NaN`, and nothing else is.
    var undefinedCount: Int {
        switch self {
        case .scalar(let value): (value?.isNaN ?? true) ? 1 : 0
        case .doubles(let values): values.filter { $0?.isNaN ?? true }.count
        case .floats(let values), .floatMatrix(_, _, let values): values.filter(\.isNaN).count
        case .complex(let real, let imaginary): (real + imaginary).filter(\.isNaN).count
        }
    }
}

/// A variable of a script, and the data it must hold.
struct ExpectedVariable: Sendable {
    let name: String
    let data: ExpectedData
}

/// An axis label, and the unit it names: `nil` for a quantity that has none (a count, a ratio,
/// the plane of the z-transform).
struct ExpectedLabel: Sendable {
    let text: String
    let unit: String?
}

/// A plot the row of §6.14 lists, and the statements that draw it.
struct ListedPlot: Sendable {
    let name: String
    let draws: [String]
}

/// One panel of the figure: the `subplot` that opens it (none in a figure of one panel), the
/// plots it holds, its labels, and every statement it is made of, in order.
struct ExpectedPanel: Sendable {
    let subplot: String?
    let plots: [ListedPlot]
    let xlabel: ExpectedLabel
    let ylabel: ExpectedLabel
    let statements: [String]
}

/// What one row exports, and what its script must hold.
struct Specimen: Sendable {
    /// The value, typed as nothing more than `Sendable`: whether it exports is asked at run time.
    let value: any Sendable
    /// The comments, in order, without their `% `.
    let comments: [String]
    /// The variables, in the order the script defines them.
    let variables: [ExpectedVariable]
    /// The panels, in order.
    let panels: [ExpectedPanel]
    /// Numbers from `Double`s that comments carry: the comment, the words before the number, the value.
    var commentNumbers: [(comment: Int, after: String, value: Double)] = []
}

/// A value of the row's type whose export holds more than four million elements, and how many
/// the refusal must name.
struct Oversized: Sendable {
    let value: any Sendable
    let elements: Int
}

/// A number as a script writes it, worked out here and not by the writer: 17 significant digits
/// from a `Double` (MAT-3).
private func written(_ value: Double) -> String {
    value.isNaN ? "NaN" : value.isInfinite ? (value < 0 ? "-Inf" : "Inf") : String(format: "%.17g", value)
}

// MARK: - The rows

extension ExportRow {
    static let format = SignalFormat(sampleRate: 48_000)

    /// The value of the row, made by the package the way an app makes it, and what its script
    /// must hold.
    func specimen() async throws -> Specimen {
        switch self {
        case .systemAnalysis: return try await Self.systemAnalysis()
        case .windowAnalysis: return try await Self.windowAnalysis()
        case .inversionReport: return try await Self.inversionReport()
        case .heatmapSnapshot: return try Self.heatmapSnapshot()
        case .waveformSnapshot: return try Self.waveformSnapshot()
        case .scalarTrack: return try Self.scalarTrack()
        case .calibrationReport: return try Self.calibrationReport()
        }
    }

    /// A stable digital low-pass: its zeros at z = −1 leave the group delay undefined at the
    /// Nyquist frequency, the last exported one, so the script holds a `NaN`.
    private static func systemAnalysis() async throws -> Specimen {
        let analysis = try await IIRSystem { LowPass(.butterworth, cutoff: .hertz(8_000), order: 2) }.analysis(sampleRate: 48_000)
        let hertz = analysis.exportedFrequencies()
        let omega = hertz.map { 2 * Double.pi * $0 / 48_000 }
        let count = SystemAnalysis.exportedSampleCount
        let unitCircle = "plot(cos(linspace(0, 2 * pi, 361)), sin(linspace(0, 2 * pi, 361)), 'k:');"
        let frequency = ExpectedLabel(text: "Frequency (Hz)", unit: "Hz")
        // A sample number is a count, an amplitude a ratio: neither has a unit.
        let sample = ExpectedLabel(text: "Sample", unit: nil), amplitude = ExpectedLabel(text: "Amplitude", unit: nil)
        return Specimen(
            value: analysis,
            comments: ["ZTronDSP system analysis: a digital system of order 2, infinite impulse response, stable."],
            variables: [
                ExpectedVariable(name: "sample_rate", data: .scalar(48_000)),
                ExpectedVariable(name: "z", data: .complex(real: analysis.zeros.map(\.real), imaginary: analysis.zeros.map(\.imaginary))),
                ExpectedVariable(name: "p", data: .complex(real: analysis.poles.map(\.real), imaginary: analysis.poles.map(\.imaginary))),
                ExpectedVariable(name: "k", data: .scalar(analysis.gain)),
                ExpectedVariable(name: "f", data: .doubles(hertz)),
                ExpectedVariable(name: "magnitude_db", data: .doubles(try analysis.magnitudeResponse(at: omega, in: .decibels))),
                ExpectedVariable(name: "phase_rad", data: .doubles(try analysis.phaseResponse(at: omega, unwrapped: true))),
                ExpectedVariable(name: "group_delay", data: .doubles(try analysis.groupDelay(at: omega))),
                ExpectedVariable(name: "n", data: .doubles((0 ..< count).map(Double.init))),
                ExpectedVariable(name: "impulse", data: .floats(try analysis.impulseResponse(count: count))),
                ExpectedVariable(name: "step", data: .floats(try analysis.stepResponse(count: count))),
            ],
            panels: [
                ExpectedPanel(
                    subplot: "subplot(3, 2, 1);",
                    plots: [ListedPlot(name: "the pole–zero map", draws: ["plot(real(z), imag(z), 'o');", "plot(real(p), imag(p), 'x');"]),
                            ListedPlot(name: "with the unit circle", draws: [unitCircle])],
                    // The plane of the z-transform has no unit.
                    xlabel: ExpectedLabel(text: "Real part", unit: nil), ylabel: ExpectedLabel(text: "Imaginary part", unit: nil),
                    statements: ["plot(real(z), imag(z), 'o');", "hold on;", "plot(real(p), imag(p), 'x');", unitCircle, "hold off;", "axis equal;", "grid on;",
                                 "xlabel('Real part');", "ylabel('Imaginary part');", "title('Poles (x) and zeros (o), with the unit circle');"]),
                ExpectedPanel(
                    subplot: "subplot(3, 2, 2);", plots: [ListedPlot(name: "the magnitude", draws: ["semilogx(f, magnitude_db);"])],
                    xlabel: frequency, ylabel: ExpectedLabel(text: "Magnitude (dB)", unit: "dB"),
                    statements: ["semilogx(f, magnitude_db);", "grid on;", "xlabel('Frequency (Hz)');", "ylabel('Magnitude (dB)');", "title('Magnitude response');"]),
                ExpectedPanel(
                    subplot: "subplot(3, 2, 3);", plots: [ListedPlot(name: "the phase", draws: ["semilogx(f, phase_rad);"])],
                    xlabel: frequency, ylabel: ExpectedLabel(text: "Phase (rad)", unit: "rad"),
                    statements: ["semilogx(f, phase_rad);", "grid on;", "xlabel('Frequency (Hz)');", "ylabel('Phase (rad)');", "title('Phase response, unwrapped');"]),
                ExpectedPanel(
                    subplot: "subplot(3, 2, 4);", plots: [ListedPlot(name: "the group delay", draws: ["semilogx(f, group_delay);"])],
                    xlabel: frequency, ylabel: ExpectedLabel(text: "Group delay (samples)", unit: "samples"),
                    statements: ["semilogx(f, group_delay);", "grid on;", "xlabel('Frequency (Hz)');", "ylabel('Group delay (samples)');", "title('Group delay');"]),
                ExpectedPanel(
                    subplot: "subplot(3, 2, 5);", plots: [ListedPlot(name: "the impulse response", draws: ["stem(n, impulse);"])],
                    xlabel: sample, ylabel: amplitude,
                    statements: ["stem(n, impulse);", "grid on;", "xlabel('Sample');", "ylabel('Amplitude');", "title('Impulse response');"]),
                ExpectedPanel(
                    subplot: "subplot(3, 2, 6);", plots: [ListedPlot(name: "the step response", draws: ["stem(n, step);"])],
                    xlabel: sample, ylabel: amplitude,
                    statements: ["stem(n, step);", "grid on;", "xlabel('Sample');", "ylabel('Amplitude');", "title('Step response');"]),
            ])
    }

    private static func windowAnalysis() async throws -> Specimen {
        let analysis = try await Window.hann.analysis(frame: 64, hop: 16)
        let floor = DSP.decibelFloor
        let spectrum = "plot((0:numel(spectrum_db)-1) * bin_step, spectrum_db);"
        let mainLobe = ["plot([main_lobe_half_power main_lobe_half_power] / 2, [-160 0], 'r--');", "plot([main_lobe_null_to_null main_lobe_null_to_null] / 2, [-160 0], 'm--');"]
        let sideLobe = "plot([0 frame/2], [peak_side_lobe peak_side_lobe], 'g--');"
        return Specimen(
            value: analysis,
            comments: ["Window analysis: hann, 64 samples, hop 16"],
            variables: [
                ExpectedVariable(name: "frame", data: .scalar(64)),
                ExpectedVariable(name: "samples", data: .doubles(analysis.samples)),
                ExpectedVariable(name: "bin_step", data: .scalar(analysis.spectrumBinStep)),
                // The spectrum is drawn down to the floor of the decibel scale (NUM-1).
                ExpectedVariable(name: "spectrum_db", data: .doubles(analysis.spectrum.map { Swift.max($0, floor) })),
                ExpectedVariable(name: "peak", data: .scalar(analysis.peak)),
                ExpectedVariable(name: "coherent_gain", data: .scalar(analysis.coherentGain)),
                ExpectedVariable(name: "noise_gain", data: .scalar(analysis.noiseGain)),
                ExpectedVariable(name: "equivalent_noise_bandwidth", data: .scalar(analysis.equivalentNoiseBandwidth)),
                ExpectedVariable(name: "main_lobe_half_power", data: .scalar(analysis.mainLobeWidthAtHalfPower)),
                ExpectedVariable(name: "main_lobe_null_to_null", data: .scalar(analysis.mainLobeWidthNullToNull)),
                ExpectedVariable(name: "peak_side_lobe", data: .scalar(analysis.peakSideLobe)),
                ExpectedVariable(name: "side_lobe_fall_off", data: .scalar(analysis.sideLobeFallOff)),
                ExpectedVariable(name: "scalloping_loss", data: .scalar(analysis.scallopingLoss)),
                ExpectedVariable(name: "smoothness", data: .scalar(Double(analysis.smoothness))),
            ],
            panels: [
                ExpectedPanel(
                    subplot: "subplot(2, 1, 1);", plots: [ListedPlot(name: "the window", draws: ["plot(0:frame-1, samples);"])],
                    // A sample number is a count, a window's value a ratio.
                    xlabel: ExpectedLabel(text: "sample", unit: nil), ylabel: ExpectedLabel(text: "amplitude", unit: nil),
                    statements: ["plot(0:frame-1, samples);", "xlabel('sample');", "ylabel('amplitude');", "title('Window: hann');", "grid on;"]),
                ExpectedPanel(
                    subplot: "subplot(2, 1, 2);",
                    plots: [ListedPlot(name: "its spectrum", draws: [spectrum]),
                            ListedPlot(name: "with the main-lobe markers", draws: mainLobe),
                            ListedPlot(name: "and the side-lobe marker", draws: [sideLobe])],
                    xlabel: ExpectedLabel(text: "frequency (bins)", unit: "bins"), ylabel: ExpectedLabel(text: "level (dB)", unit: "dB"),
                    statements: [spectrum, "hold on;"] + mainLobe + [sideLobe, "hold off;", "axis([0 32 -160 5]);", "xlabel('frequency (bins)');", "ylabel('level (dB)');",
                                                                    "title('Spectrum: main lobe at -3 dB (red), first null (magenta), highest side lobe (green)');", "grid on;"]),
            ])
    }

    /// A round trip measured by the package: a tone in the band and one above the frequency that
    /// subsampling by two folds, so the reconstruction has an error to draw.
    private static func inversionReport() async throws -> Specimen {
        let signal = (0 ..< 4_096).map { index -> Float in
            let time = Double(index) / 48_000
            return Float(0.5 * sin(2 * Double.pi * 1_000 * time) + 0.25 * sin(2 * Double.pi * 15_000 * time))
        }
        let report = try await DSP.inversionReport(ofSubsampling: signal, by: 2, sampleRate: 48_000)
        let roundTrip = try #require(report.roundTrip), measured = try #require(report.measuredError)
        try #require(roundTrip.frameLength == 1 && !roundTrip.original.isEmpty, "a round trip of samples, drawn against time")
        let position = "(0:numel(original)-1) / sample_rate"
        let time = ExpectedLabel(text: "time (s)", unit: "s")
        return Specimen(
            value: report,
            comments: ["Inversion report: \(report.stage) and back through \(report.inverse)",
                       report.isExactlyInvertible ? "Every necessary condition holds." : "A necessary condition fails."]
                + report.conditions.map { "\($0.name): \($0.holds ? "holds" : "fails"), margin \(written($0.margin))" },
            variables: [
                ExpectedVariable(name: "predicted_error", data: .scalar(report.predictedError)),
                ExpectedVariable(name: "sample_rate", data: .scalar(report.sampleRate)),
                ExpectedVariable(name: "measured_snr", data: .scalar(measured.signalToNoiseRatio)),
                ExpectedVariable(name: "largest_error", data: .scalar(measured.largestError)),
                ExpectedVariable(name: "original", data: .floats(roundTrip.original)),
                ExpectedVariable(name: "reconstruction", data: .floats(roundTrip.reconstruction)),
            ],
            panels: [
                ExpectedPanel(
                    subplot: "subplot(3, 1, 1);",
                    plots: [ListedPlot(name: "the original", draws: ["plot(\(position), original);"]),
                            ListedPlot(name: "the reconstruction", draws: ["plot(\(position), reconstruction, 'r--');"])],
                    // Samples are ratios to full scale; an error is a difference of two.
                    xlabel: time, ylabel: ExpectedLabel(text: "amplitude", unit: nil),
                    statements: ["plot(\(position), original);", "hold on;", "plot(\(position), reconstruction, 'r--');", "hold off;", "xlabel('time (s)');", "ylabel('amplitude');",
                                 "title('Original and reconstruction (dashed)');", "grid on;"]),
                ExpectedPanel(
                    subplot: "subplot(3, 1, 2);", plots: [ListedPlot(name: "the error", draws: ["plot(\(position), original - reconstruction);"])],
                    xlabel: time, ylabel: ExpectedLabel(text: "error", unit: nil),
                    statements: ["plot(\(position), original - reconstruction);", "xlabel('time (s)');", "ylabel('error');", "title('Error');", "grid on;"]),
                ExpectedPanel(
                    subplot: "subplot(3, 1, 3);",
                    plots: [ListedPlot(name: "the error's spectrum",
                                       draws: ["plot((0:numel(original)-1) * sample_rate / numel(original), 20 * log10(abs(fft(original - reconstruction)) + 1e-300));"])],
                    xlabel: ExpectedLabel(text: "frequency (Hz)", unit: "Hz"), ylabel: ExpectedLabel(text: "level (dB)", unit: "dB"),
                    statements: ["plot((0:numel(original)-1) * sample_rate / numel(original), 20 * log10(abs(fft(original - reconstruction)) + 1e-300));",
                                 "xlabel('frequency (Hz)');", "ylabel('level (dB)');", "title('Spectrum of the error');", "grid on;"]),
            ],
            commentNumbers: report.conditions.enumerated().map { (comment: 2 + $0.offset, after: "margin ", value: $0.element.margin) })
    }

    /// The feed of a mel spectrogram: its rows, mel bands, are not evenly spaced, so the image is
    /// drawn against their index and their centres are in the script beside it.
    private static func heatmapSnapshot() throws -> Specimen {
        let feed = HeatmapFeed(history: 32)
        try Pipeline { MelSpectrogram(frame: 1_024, hop: 512, bands: 12, to: feed) }.run(on: TestSignal.whiteNoise(count: 8_192, seed: 5), format: format)
        let snapshot = feed.snapshot()
        let axis = try #require(snapshot.axis)
        guard case .mel = axis else { throw ExpectationFailure("the rows of a mel spectrogram are mel bands, not \(axis)") }
        let rows = snapshot.rowCount, columns = snapshot.columnCount
        try #require(rows > 0 && columns > 0)
        let image = "imagesc(times, 1:numel(row_values), values);"
        return Specimen(
            value: snapshot,
            comments: ["Heat map: \(rows) rows, \(columns) columns"],
            variables: [
                ExpectedVariable(name: "times", data: .doubles(snapshot.times)),
                ExpectedVariable(name: "row_values", data: .doubles((0 ..< rows).map { axis.value(ofRow: $0) })),
                ExpectedVariable(name: "values", data: .floatMatrix(rows: rows, columns: columns, values: (0 ..< rows).flatMap { snapshot.row($0) })),
            ],
            panels: [
                ExpectedPanel(
                    subplot: nil,
                    plots: [ListedPlot(name: "the matrix as an image, against its frame times and the rows of its FeedAxis", draws: [image])],
                    xlabel: ExpectedLabel(text: "time (s)", unit: "s"), ylabel: ExpectedLabel(text: "row (mel band centre (Hz) in row_values)", unit: "Hz"),
                    statements: [image, "axis xy;", "colorbar;", "xlabel('time (s)');", "ylabel('row (mel band centre (Hz) in row_values)');", "title('Heat map');"]),
            ])
    }

    private static func waveformSnapshot() throws -> Specimen {
        let feed = WaveformFeed(history: 256)
        try Pipeline { Waveform(resolution: 0.005); Emit(to: feed) }.run(on: TestSignal.whiteNoise(count: 24_000, seed: 9), format: format)
        let snapshot = feed.snapshot()
        try #require(snapshot.columnCount > 0)
        return Specimen(
            value: snapshot,
            comments: ["Waveform envelope: \(snapshot.columnCount) pairs"],
            variables: [
                ExpectedVariable(name: "times", data: .doubles(snapshot.times)),
                ExpectedVariable(name: "minima", data: .floats(snapshot.minima)),
                ExpectedVariable(name: "maxima", data: .floats(snapshot.maxima)),
            ],
            panels: [
                ExpectedPanel(
                    subplot: nil,
                    plots: [ListedPlot(name: "the maximum over time", draws: ["plot(times, maxima);"]),
                            ListedPlot(name: "the minimum over time", draws: ["plot(times, minima);"])],
                    xlabel: ExpectedLabel(text: "time (s)", unit: "s"), ylabel: ExpectedLabel(text: "amplitude", unit: nil),
                    statements: ["plot(times, maxima);", "hold on;", "plot(times, minima);", "hold off;", "xlabel('time (s)');", "ylabel('amplitude');",
                                 "title('Waveform envelope');", "grid on;"]),
            ])
    }

    /// What a pipeline that reduces a signal to one value per frame measures: a pitch track.
    private static func scalarTrack() throws -> Specimen {
        let pitch: [ScalarFrame] = try Pipeline { STFT(frame: 2_048, hop: 512); Cepstrum(); CepstralPitch(range: .hertz(100 ... 500)) }
            .process(TestSignal.harmonic(fundamental: 220, amplitudes: [1, 0.5, 0.3, 0.2], sampleRate: 48_000, count: 8_192), format: format)
        try #require(!pitch.isEmpty)
        let track = ScalarTrack(pitch, rate: 93.75)
        let time = ExpectedLabel(text: "time (s)", unit: "s")
        return Specimen(
            value: track,
            comments: ["Scalar track: \(track.frames.count) frames"],
            variables: [
                ExpectedVariable(name: "times", data: .doubles(track.times)),
                ExpectedVariable(name: "values", data: .floats(track.frames.map(\.value))),
                ExpectedVariable(name: "confidence", data: .floats(track.frames.map(\.confidence))),
            ],
            panels: [
                // A scalar frame carries no unit, and a confidence is a ratio.
                ExpectedPanel(
                    subplot: "subplot(2, 1, 1);", plots: [ListedPlot(name: "the value over time", draws: ["plot(times, values);"])],
                    xlabel: time, ylabel: ExpectedLabel(text: "value", unit: nil),
                    statements: ["plot(times, values);", "xlabel('time (s)');", "ylabel('value');", "title('Scalar track');", "grid on;"]),
                ExpectedPanel(
                    subplot: "subplot(2, 1, 2);", plots: [ListedPlot(name: "the confidence over time", draws: ["plot(times, confidence);"])],
                    xlabel: time, ylabel: ExpectedLabel(text: "confidence", unit: nil),
                    statements: ["plot(times, confidence);", "xlabel('time (s)');", "ylabel('confidence');", "grid on;"]),
            ])
    }

    /// A table measured against two implementations for one entry and one for another.
    private static func calibrationReport() throws -> Specimen {
        let report = CalibrationReport(measurements: [
            CrossoverMeasurement(entry: .gainKernel, sizes: [8, 64, 512], curves: [
                CalibrationCurve(implementation: .native, label: "C loop", nanoseconds: [2.5, 20, 160]),
                CalibrationCurve(implementation: .accelerate, label: "vDSP_vsmul", nanoseconds: [9, 12.25, 40]),
            ]),
            CrossoverMeasurement(entry: .medianGPU, sizes: [69_768, 279_072], curves: [
                CalibrationCurve(implementation: .metal, label: "Metal", nanoseconds: [1_500_000.0 / 3, 0.1 + 0.2]),
            ]),
        ])
        let gain = report.measurements[0], median = report.measurements[1]
        let crossover = try #require(gain.crossover)
        let time = ExpectedLabel(text: "Time per call (ns)", unit: "ns")
        return Specimen(
            value: report,
            comments: ["ZTronDSP calibration: time per call against size, one curve per implementation.",
                       "gainKernel: C loop against vDSP_vsmul, crossover at \(crossover)", "medianGPU: Metal, one implementation measured"],
            variables: [
                ExpectedVariable(name: "sizes_gainKernel", data: .doubles(gain.sizes.map(Double.init))),
                ExpectedVariable(name: "ns_gainKernel_1", data: .doubles(gain.curves[0].nanoseconds)),
                ExpectedVariable(name: "ns_gainKernel_2", data: .doubles(gain.curves[1].nanoseconds)),
                ExpectedVariable(name: "sizes_medianGPU", data: .doubles(median.sizes.map(Double.init))),
                ExpectedVariable(name: "ns_medianGPU_1", data: .doubles(median.curves[0].nanoseconds)),
            ],
            panels: [
                ExpectedPanel(
                    subplot: "subplot(1, 2, 1);",
                    plots: [ListedPlot(name: "the curve of the C loop, on logarithmic axes", draws: ["loglog(sizes_gainKernel, ns_gainKernel_1, 'o-');"]),
                            ListedPlot(name: "the curve of vDSP_vsmul, on logarithmic axes", draws: ["loglog(sizes_gainKernel, ns_gainKernel_2, 'x--');"])],
                    xlabel: ExpectedLabel(text: "Block size (frames)", unit: "frames"), ylabel: time,
                    statements: ["loglog(sizes_gainKernel, ns_gainKernel_1, 'o-');", "hold on;", "loglog(sizes_gainKernel, ns_gainKernel_2, 'x--');", "hold off;", "grid on;",
                                 "xlabel('Block size (frames)');", "ylabel('Time per call (ns)');", "title('Gain kernel: C loop (o-), vDSP_vsmul (x--)');"]),
                ExpectedPanel(
                    subplot: "subplot(1, 2, 2);",
                    plots: [ListedPlot(name: "the curve of the GPU, on logarithmic axes", draws: ["loglog(sizes_medianGPU, ns_medianGPU_1, 'o-');"])],
                    // A product of counts has no unit.
                    xlabel: ExpectedLabel(text: "Kernel x bins x frames", unit: nil), ylabel: time,
                    statements: ["loglog(sizes_medianGPU, ns_medianGPU_1, 'o-');", "grid on;", "xlabel('Kernel x bins x frames');", "ylabel('Time per call (ns)');",
                                 "title('Median of a spectrogram: Metal (o-)');"]),
            ])
    }

    /// A value of the row's type whose export holds more than four million elements; `nil` for
    /// a system analysis, which cannot hold one.
    func oversized() async throws -> Oversized? {
        let limit = MATLABScript.elementLimit
        switch self {
        case .systemAnalysis:
            return nil
        case .windowAnalysis:
            // The spectrum of a window is sixteen times as fine as its frame's own.
            let analysis = try await Window.hann.analysis(frame: 500_000)
            return Oversized(value: analysis, elements: analysis.spectrum.count)
        case .inversionReport:
            let long = [Float](repeating: 0.25, count: limit + 1)
            let roundTrip = InversionRoundTrip(original: long, reconstruction: long)
            return Oversized(value: InversionReport(stage: "Gain", inverse: "Gain", conditions: [], roundTrip: roundTrip), elements: limit + 1)
        case .heatmapSnapshot:
            let snapshot = FeedSnapshot(content: .heatmap, axis: nil, environment: nil, rowCount: 2_001, values: [Float](repeating: 0, count: 2_001 * 2_000),
                                        times: [Double](repeating: 0, count: 2_000))
            return Oversized(value: snapshot, elements: 2_001 * 2_000)
        case .waveformSnapshot:
            let snapshot = FeedSnapshot(content: .waveform, axis: nil, environment: nil, rowCount: 2, values: [Float](repeating: 0, count: 2 * (limit + 1)),
                                        times: [Double](repeating: 0, count: limit + 1))
            return Oversized(value: snapshot, elements: limit + 1)
        case .scalarTrack:
            return Oversized(value: ScalarTrack([ScalarFrame](repeating: .none, count: limit + 1), rate: 100), elements: limit + 1)
        case .calibrationReport:
            let sizes = Array(1 ... limit + 1)
            return Oversized(value: CalibrationReport(measurements: [CrossoverMeasurement(entry: .elementwise, sizes: sizes, curves: [])]), elements: limit + 1)
        }
    }
}

/// What a helper that makes a specimen throws when the package does not make what it expects.
struct ExpectationFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - A script read back

/// A MATLAB script read back (MAT-2): its comments, its assignments and its other statements in
/// order, panel by panel, and every way it breaks the rules of the language the exports use.
struct ScriptReading {
    /// A word of a statement.
    enum Token: Equatable, CustomStringConvertible {
        case name(String), number(String), text(String), symbol(String)

        var description: String {
            switch self {
            case .name(let text), .number(let text), .symbol(let text): text
            case .text(let text): "'\(text)'"
            }
        }
    }

    /// The thirteen commands of MAT-2.
    static let commands: Set<String> = ["plot", "semilogx", "loglog", "stem", "imagesc", "subplot", "xlabel", "ylabel", "title", "grid", "axis", "colorbar", "hold"]
    /// The commands that draw.
    static let drawing: Set<String> = ["plot", "semilogx", "loglog", "stem", "imagesc"]
    /// The core functions the scripts compute with, inside the arguments of a command.
    static let functions: Set<String> = ["real", "imag", "abs", "cos", "sin", "log10", "fft", "linspace", "numel"]
    /// The constants of core MATLAB the scripts write.
    static let constants: Set<String> = ["pi", "NaN", "Inf"]
    /// The words a command takes in command syntax, as in `hold on`.
    static let words: [String: Set<String>] = ["hold": ["on", "off"], "grid": ["on", "off"], "colorbar": [],
                                               "axis": ["equal", "xy", "ij", "tight", "square", "image", "normal", "auto"]]

    private(set) var comments: [String] = []
    private(set) var assignments: [(name: String, value: String)] = []
    private(set) var statements: [String] = []
    /// The texts the statements quote: labels and titles.
    private(set) var texts: [String] = []
    private(set) var problems: [String] = []

    init(_ text: String) {
        // By scalars: "\r\n" is one Character, which neither contains "\r" nor ends with "\n".
        if text.unicodeScalars.contains("\r") { problems.append("the script holds a carriage return") }
        guard text.unicodeScalars.last == "\n" else {
            problems.append("the script does not end with a line feed")
            return
        }
        var defined: Set<String> = []
        for (offset, line) in text.dropLast().split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = offset + 1
            if line.hasPrefix("% ") {
                comments.append(String(line.dropFirst(2)))
                continue
            }
            guard line.hasSuffix(";") else {
                problems.append("line \(number) does not end its statement with a semicolon: \(line)")
                continue
            }
            let (tokens, problem) = Self.tokens(of: line.dropLast())
            if let problem = problem ?? Self.nestingProblem(in: tokens) {
                problems.append("line \(number): \(problem): \(line)")
                continue
            }
            for case .text(let quoted) in tokens { texts.append(quoted) }
            guard case .name(let first)? = tokens.first else {
                problems.append("line \(number) is neither an assignment nor a command: \(line)")
                continue
            }
            if tokens.count >= 2, tokens[1] == .symbol("=") {
                // MAT-2: the data, then the plots.
                if !statements.isEmpty { problems.append("line \(number): \(first) is defined after the plots began") }
                if Self.commands.contains(first) || Self.functions.contains(first) || Self.constants.contains(first) {
                    problems.append("line \(number): the variable \(first) hides what core MATLAB calls \(first)")
                }
                problems += Self.unknownNames(in: tokens.dropFirst(2), defined: defined).map { "line \(number): \($0)" }
                defined.insert(first)
                let value = line.dropLast().drop { $0 != "=" }.dropFirst().drop { $0 == " " }
                assignments.append((first, String(value)))
                continue
            }
            statements.append(String(line))
            guard Self.commands.contains(first) else {
                problems.append("line \(number): \(first) is not one of the commands of MAT-2")
                continue
            }
            if tokens.count > 1, tokens[1] == .symbol("(") {
                problems += Self.unknownNames(in: tokens.dropFirst(), defined: defined).map { "line \(number): \($0)" }
            } else {
                for token in tokens.dropFirst() {
                    guard case .name(let word) = token, Self.words[first]?.contains(word) == true else {
                        problems.append("line \(number): \(first) does not take \(token) in command syntax")
                        continue
                    }
                }
            }
        }
    }

    /// The statements after the data, panel by panel: a panel opens at each `subplot`, and what
    /// comes before the first is a panel of its own.
    var panels: [(subplot: String?, statements: [String])] {
        var panels: [(subplot: String?, statements: [String])] = []
        for statement in statements {
            if statement.hasPrefix("subplot(") {
                panels.append((statement, []))
            } else if panels.isEmpty {
                panels.append((nil, [statement]))
            } else {
                panels[panels.count - 1].statements.append(statement)
            }
        }
        return panels
    }

    /// Whether a statement draws: a plot command of MAT-2.
    static func draws(_ statement: String) -> Bool {
        drawing.contains(String(statement.prefix { $0 != "(" }))
    }

    /// The words of a statement: names, numbers, quoted texts and symbols.
    static func tokens(of statement: Substring) -> (tokens: [Token], problem: String?) {
        let characters = Array(statement)
        var tokens: [Token] = []
        var index = 0
        func isDigit(_ index: Int) -> Bool { index < characters.count && characters[index].isASCII && characters[index].isNumber }
        func isLetter(_ index: Int) -> Bool { index < characters.count && characters[index].isASCII && characters[index].isLetter }
        while index < characters.count {
            let character = characters[index]
            if character == " " {
                index += 1
            } else if isLetter(index) {
                var end = index + 1
                while isLetter(end) || isDigit(end) || (end < characters.count && characters[end] == "_") { end += 1 }
                tokens.append(.name(String(characters[index ..< end])))
                index = end
            } else if isDigit(index) || (character == "." && isDigit(index + 1)) {
                var end = index
                while isDigit(end) || (end < characters.count && characters[end] == ".") { end += 1 }
                if end < characters.count, characters[end] == "e" {
                    end += 1
                    if end < characters.count, characters[end] == "+" || characters[end] == "-" { end += 1 }
                    while isDigit(end) { end += 1 }
                }
                if end < characters.count, characters[end] == "i" { end += 1 }
                tokens.append(.number(String(characters[index ..< end])))
                index = end
            } else if character == "'" {
                var end = index + 1
                var text = ""
                while true {
                    guard end < characters.count else { return (tokens, "a quote is not closed") }
                    if characters[end] == "'" {
                        if end + 1 < characters.count, characters[end + 1] == "'" {
                            text.append("'")
                            end += 2
                            continue
                        }
                        break
                    }
                    text.append(characters[end])
                    end += 1
                }
                tokens.append(.text(text))
                index = end + 1
            } else if character == ".", index + 1 < characters.count, "*/^".contains(characters[index + 1]) {
                tokens.append(.symbol(String(characters[index ... index + 1])))
                index += 2
            } else if "()[],;=+-*/^:".contains(character) {
                tokens.append(.symbol(String(character)))
                index += 1
            } else {
                return (tokens, "\(character) is not part of the language the scripts use")
            }
        }
        return (tokens, nil)
    }

    /// What is wrong with the brackets of a statement: one not closed, or closed by the other
    /// kind; a semicolon outside them ends a statement, so it makes two on one line.
    static func nestingProblem(in tokens: [Token]) -> String? {
        var open: [String] = []
        for token in tokens {
            guard case .symbol(let symbol) = token else { continue }
            switch symbol {
            case "(", "[":
                open.append(symbol)
            case ")", "]":
                guard let last = open.popLast(), last == (symbol == ")" ? "(" : "[") else { return "\(symbol) closes no bracket of its kind" }
            case ";" where open.isEmpty:
                return "two statements on one line"
            default:
                break
            }
        }
        return open.isEmpty ? nil : "\(open.last ?? "") is not closed"
    }

    /// The names a stretch of a statement uses that it may not: a call of what is neither a
    /// command of MAT-2, nor a core function, nor a variable the script defined; a name that is
    /// neither a variable defined before nor a constant.
    static func unknownNames(in tokens: ArraySlice<Token>, defined: Set<String>) -> [String] {
        var unknown: [String] = []
        for index in tokens.indices {
            guard case .name(let name) = tokens[index] else { continue }
            let isCalled = index + 1 < tokens.endIndex && tokens[index + 1] == .symbol("(")
            if isCalled {
                if !(commands.contains(name) || functions.contains(name) || defined.contains(name)) {
                    unknown.append("\(name)(…) is neither a command of MAT-2, nor a core function, nor a variable the script defined")
                }
            } else if !(defined.contains(name) || constants.contains(name)) {
                unknown.append("\(name) is used and the script has not defined it")
            }
        }
        return unknown
    }

    // MARK: Numbers (MAT-3)

    /// The elements of a value as written, row by row; a scalar is one row of one, unbracketed.
    static func literals(of value: String) -> (isBracketed: Bool, rows: [[Substring]]) {
        guard value.hasPrefix("["), value.hasSuffix("]") else { return (false, [[Substring(value)]]) }
        let inner = value.dropFirst().dropLast()
        guard !inner.isEmpty else { return (true, []) }
        return (true, inner.split(separator: ";", omittingEmptySubsequences: false).map { $0.split(separator: " ") })
    }

    /// Whether a literal is a decimal number as `%g` writes one: an optional minus, digits with an
    /// optional point, an optional exponent with its sign.
    static func isDecimal(_ literal: Substring) -> Bool {
        let unsigned = literal.first == "-" ? literal.dropFirst() : literal
        let mantissa = unsigned.prefix { $0 != "e" }
        let exponent = unsigned.dropFirst(mantissa.count)
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        guard !exponent.isEmpty else { return true }
        let signed = exponent.dropFirst()
        guard signed.first == "+" || signed.first == "-" else { return false }
        let digits = signed.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The significant digits of a decimal literal: those of its mantissa, without the zeros it
    /// begins with.
    static func significantDigits(_ literal: Substring) -> Int {
        literal.prefix { $0 != "e" }.filter { $0.isASCII && $0.isNumber }.drop { $0 == "0" }.count
    }

    /// The two parts of a complex literal `a+bi` or `a-bi`; the imaginary part keeps its minus.
    static func complexParts(_ literal: Substring) -> (real: Substring, imaginary: Substring)? {
        guard literal.hasSuffix("i") else { return nil }
        let body = literal.dropLast()
        var index = body.endIndex
        while index > body.startIndex {
            index = body.index(before: index)
            guard index > body.startIndex, body[index] == "+" || body[index] == "-", body[body.index(before: index)] != "e" else { continue }
            let imaginary = body[index...]
            return (body[..<index], imaginary.first == "+" ? imaginary.dropFirst() : imaginary)
        }
        return nil
    }

    /// What is wrong with a literal written from a `Double`; `nil` is an undefined value.
    static func problem(_ literal: Substring, double expected: Double?) -> String? {
        guard let expected, !expected.isNaN else {
            return literal == "NaN" ? nil : "\(literal) is written where the value is undefined, which is NaN"
        }
        let read: Double? = switch literal {
        case "NaN": Double.nan
        case "Inf": Double.infinity
        case "-Inf": -Double.infinity
        default: isDecimal(literal) ? Double(String(literal)) : nil
        }
        guard let read else { return "\(literal) is not a number as the export writes one" }
        guard !read.isNaN else { return "NaN is written for \(expected), which is defined" }
        guard significantDigits(literal) <= 17 else { return "\(literal) has more significant digits than the 17 of a Double" }
        return read.bitPattern == expected.bitPattern ? nil : "\(literal) reads back as \(read), not as \(expected)"
    }

    /// What is wrong with a literal written from a `Float`.
    static func problem(_ literal: Substring, float expected: Float) -> String? {
        guard !expected.isNaN else { return literal == "NaN" ? nil : "\(literal) is written where the value is undefined, which is NaN" }
        let read: Float? = switch literal {
        case "NaN": Float.nan
        case "Inf": Float.infinity
        case "-Inf": -Float.infinity
        default: isDecimal(literal) ? Float(String(literal)) : nil
        }
        guard let read else { return "\(literal) is not a number as the export writes one" }
        guard !read.isNaN else { return "NaN is written for \(expected), which is defined" }
        guard significantDigits(literal) <= 9 else { return "\(literal) has more significant digits than the 9 of a Float" }
        return read.bitPattern == expected.bitPattern ? nil : "\(literal) reads back as \(read), not as \(expected)"
    }

    /// What is wrong with the value of an assignment, against the data it must hold.
    static func problems(of value: String, against expected: ExpectedData) -> [String] {
        let (isBracketed, rows) = literals(of: value)
        func vector(_ count: Int) -> [Substring]? {
            guard isBracketed else { return nil }
            if count == 0 { return rows.isEmpty ? [] : nil }
            return rows.count == 1 && rows[0].count == count ? rows[0] : nil
        }
        let shape = "\(value.prefix(40))\(value.count > 40 ? "…" : "")"
        switch expected {
        case .scalar(let number):
            guard !isBracketed, rows.count == 1, rows[0].count == 1 else { return ["\(shape) is not a scalar"] }
            return [problem(rows[0][0], double: number)].compactMap { $0 }
        case .doubles(let numbers):
            guard let elements = vector(numbers.count) else { return ["\(shape) is not a row of \(numbers.count) values"] }
            return zip(elements, numbers).compactMap { problem($0, double: $1) }
        case .floats(let numbers):
            guard let elements = vector(numbers.count) else { return ["\(shape) is not a row of \(numbers.count) values"] }
            return zip(elements, numbers).compactMap { problem($0, float: $1) }
        case .complex(let real, let imaginary):
            guard let elements = vector(real.count), real.count == imaginary.count else { return ["\(shape) is not a row of \(real.count) complex values"] }
            return zip(elements, zip(real, imaginary)).flatMap { literal, parts -> [String] in
                guard let written = complexParts(literal) else { return ["\(literal) is not a complex number a+bi"] }
                return [problem(written.real, double: parts.0), problem(written.imaginary, double: parts.1)].compactMap { $0 }
            }
        case .floatMatrix(let rowCount, let columns, let numbers):
            guard isBracketed, rows.count == rowCount, rows.allSatisfy({ $0.count == columns }), numbers.count == rowCount * columns else {
                return ["\(shape) is not \(rowCount) rows of \(columns) values"]
            }
            return zip(rows.flatMap { $0 }, numbers).compactMap { problem($0, float: $1) }
        }
    }
}

// MARK: - The tests

@Suite("Export completeness: every type of §6.14 exports as MAT-1…MAT-6 say (WP-910)")
struct ExportCompletenessTests {
    /// A value as an export, when its type is one (MAT-1). The test is on a Boolean, so that a
    /// failure does not describe the value: an oversized one holds millions of elements.
    static func exportable(_ value: any Sendable, sourceLocation: SourceLocation = #_sourceLocation) throws -> any MATLABExportable {
        let conforms = value is any MATLABExportable
        try #require(conforms, "\(type(of: value)) conforms to MATLABExportable (MAT-1)", sourceLocation: sourceLocation)
        return value as! any MATLABExportable
    }

    @Test func theTableHasTheRowsOfTheSpecification() {
        #expect(ExportRow.allCases.map(\.rawValue) == ["SystemAnalysis", "WindowAnalysis", "InversionReport", "FeedSnapshot of a HeatmapFeed",
                                                       "FeedSnapshot of a WaveformFeed", "A track of ScalarFrames", "CrossoverTable with its measurements"])
    }

    // The reading itself sees what breaks the rules, so the tests below cannot pass for want of
    // looking.
    @Test func theReadingSeesWhatBreaksTheRules() {
        let scripts: [(script: String, problem: String)] = [
            ("x = [1 2];\nsemilogz(x, x);\n", "semilogz is not one of the commands of MAT-2"),
            ("x = [1 2];\nplot(sqrt(x), x);\n", "sqrt(…) is neither a command of MAT-2, nor a core function, nor a variable the script defined"),
            ("plot(x, x);\n", "x is used and the script has not defined it"),
            ("x = [1 2];\nplot(x, x);\ny = [3 4];\n", "y is defined after the plots began"),
            ("pi = 3;\n", "the variable pi hides what core MATLAB calls pi"),
            ("x = [1 2]\n", "does not end its statement with a semicolon"),
            ("x = [1 2;\n", "[ is not closed"),
            ("x = (1 2];\n", "] closes no bracket of its kind"),
            ("title('a);\n", "a quote is not closed"),
            ("x = 1; y = 2;\n", "two statements on one line"),
            ("hold maybe;\n", "hold does not take maybe in command syntax"),
            ("x = 1;", "the script does not end with a line feed"),
            ("x = 1;\r\n", "the script holds a carriage return"),
        ]
        for (script, problem) in scripts {
            let problems = ScriptReading(script).problems
            #expect(problems.contains { $0.contains(problem) }, "\(script.debugDescription): \(problems)")
        }
        #expect(ScriptReading("x = [1 2];\nplot(x, x);\nhold on;\naxis xy;\n").problems.isEmpty)
        // The numbers: a Float written with 17 digits, a Double with 9, a NaN for a defined value,
        // a number for an undefined one, the sign of a zero, the shape of a matrix.
        #expect(ScriptReading.problems(of: "[0.10000000149011612]", against: .floats([0.1])) == ["0.10000000149011612 has more significant digits than the 9 of a Float"])
        #expect(ScriptReading.problems(of: "[0.100000001]", against: .doubles([0.1])) == ["0.100000001 reads back as 0.100000001, not as 0.1"])
        #expect(ScriptReading.problems(of: "NaN", against: .scalar(1)) == ["NaN is written for 1.0, which is defined"])
        #expect(ScriptReading.problems(of: "0", against: .scalar(nil)) == ["0 is written where the value is undefined, which is NaN"])
        #expect(ScriptReading.problems(of: "[1+2i 3-0i]", against: .complex(real: [1, 3], imaginary: [2, -0.0])).isEmpty)
        #expect(ScriptReading.problems(of: "[1+2i 3+0i]", against: .complex(real: [1, 3], imaginary: [2, -0.0])) == ["0 reads back as 0.0, not as -0.0"])
        #expect(ScriptReading.problems(of: "[1 2; 3 4]", against: .floatMatrix(rows: 2, columns: 2, values: [1, 2, 3, 4])).isEmpty)
        #expect(ScriptReading.problems(of: "[1 2 3 4]", against: .floatMatrix(rows: 2, columns: 2, values: [1, 2, 3, 4])) == ["[1 2 3 4] is not 2 rows of 2 values"])
        #expect(ScriptReading.problems(of: "[1e-05 -Inf]", against: .doubles([1e-5, -.infinity])).isEmpty)
    }

    // MAT-1. The protocol is public: the conformers live in four modules other than the one that
    // declares it, and the API digest holds it (Scripts/api-digest.sh --check).
    @Test(arguments: ExportRow.allCases)
    func theTypeOfTheRowExports(row: ExportRow) async throws {
        let specimen = try await row.specimen()
        #expect(String(describing: type(of: specimen.value)) == row.typeName)
        let text = try await Self.exportable(specimen.value).matlabScript()
        #expect(!text.isEmpty && text.hasSuffix("\n"), "the export is text, one statement a line")
    }

    // MAT-2, the plots: every plot the row lists, drawn by the commands and from the variables
    // the script defines, and nothing it does not list; each panel with its axis labels, and
    // their units where the quantity has one.
    @Test(arguments: ExportRow.allCases)
    func theScriptDrawsEveryPlotTheRowLists(row: ExportRow) async throws {
        let specimen = try await row.specimen()
        let script = ScriptReading(try await Self.exportable(specimen.value).matlabScript())
        let panels = script.panels
        #expect(panels.count == specimen.panels.count, "the \(row) script has \(panels.count) panels, not \(specimen.panels.count)")
        for (index, expected) in specimen.panels.enumerated() {
            let panel = index < panels.count ? panels[index] : nil
            let draws = panel?.statements.filter(ScriptReading.draws) ?? []
            #expect(panel?.subplot == expected.subplot, "panel \(index + 1) of the \(row) script opens with \(expected.subplot ?? "no subplot")")
            for plot in expected.plots {
                #expect(plot.draws.allSatisfy { draws.contains($0) }, "the \(row) script draws \(plot.name): \(plot.draws.joined(separator: " "))")
            }
            #expect(draws == expected.plots.flatMap(\.draws), "panel \(index + 1) of the \(row) script draws what the row lists and nothing else: \(draws)")
            for (command, label) in [("xlabel", expected.xlabel), ("ylabel", expected.ylabel)] {
                let written = panel?.statements.filter { $0.hasPrefix(command + "(") } ?? []
                #expect(written == ["\(command)('\(label.text.replacingOccurrences(of: "'", with: "''"))');"],
                        "panel \(index + 1) of the \(row) script has the \(command) '\(label.text)', once: \(written)")
                if let unit = label.unit {
                    #expect(label.text.contains("(\(unit))"), "the \(command) of panel \(index + 1) of the \(row) script names its unit, \(unit)")
                }
            }
            #expect(panel?.statements == expected.statements, "panel \(index + 1) of the \(row) script holds these statements and no others")
        }
    }

    // MAT-2, the language: every statement is an assignment or a command of MAT-2, every name is
    // a variable the script defined before, a constant, or a core function; the data come first.
    @Test(arguments: ExportRow.allCases)
    func theScriptIsCoreMATLABWithItsDataFirst(row: ExportRow) async throws {
        let specimen = try await row.specimen()
        let script = ScriptReading(try await Self.exportable(specimen.value).matlabScript())
        #expect(script.problems.isEmpty, "the \(row) script breaks MAT-2:\n\(script.problems.joined(separator: "\n"))")
        #expect(!script.assignments.isEmpty && !script.statements.isEmpty, "the \(row) script defines its data and plots them")
    }

    // MAT-3: every number of the script, parsed, is the source's bit for bit, written with 17
    // significant digits from a Double and 9 from a Float; an undefined value is NaN, and
    // nothing else is. The numbers of the plot commands are in the statements the panels hold.
    @Test(arguments: ExportRow.allCases)
    func theNumbersReadBackExactly(row: ExportRow) async throws {
        let specimen = try await row.specimen()
        let text = try await Self.exportable(specimen.value).matlabScript()
        let script = ScriptReading(text)
        #expect(script.assignments.map(\.name) == specimen.variables.map(\.name), "the \(row) script defines these variables, in this order")
        for variable in specimen.variables {
            guard let value = script.assignments.first(where: { $0.name == variable.name })?.value else { continue }
            let problems = ScriptReading.problems(of: value, against: variable.data)
            #expect(problems.isEmpty, "\(variable.name) of the \(row) script: \(problems.count) problems: \(problems.prefix(4).joined(separator: "; "))")
        }
        #expect(script.comments == specimen.comments, "the comments of the \(row) script")
        for number in specimen.commentNumbers {
            let comment = number.comment < script.comments.count ? script.comments[number.comment] : ""
            let literal = comment.components(separatedBy: number.after).last.map { Substring($0.prefix { $0 != " " && $0 != "," }) } ?? ""
            let problem = ScriptReading.problem(literal, double: number.value)
            #expect(comment.contains(number.after) && problem == nil, "comment \(number.comment + 1) of the \(row) script: \(problem ?? "no \(number.after)")")
        }
        let undefined = specimen.variables.map(\.data.undefinedCount).reduce(0, +)
        #expect(text.components(separatedBy: "NaN").count - 1 == undefined, "the \(row) script writes NaN for its \(undefined) undefined values, and nowhere else")
    }

    // MAT-4: equal input gives equal text, from one value twice and from an equal value made
    // again; nothing of the day or of the machine is in it.
    @Test(arguments: ExportRow.allCases)
    func equalInputGivesEqualTextWithoutADateOrAMachineName(row: ExportRow) async throws {
        let first = try await row.specimen(), again = try await row.specimen()
        let text = try await Self.exportable(first.value).matlabScript()
        #expect(try await Self.exportable(first.value).matlabScript() == text, "two calls on one \(row)")
        #expect(try await Self.exportable(again.value).matlabScript() == text, "an equal \(row), made again")
        // The words of its comments, labels and titles, where a date would be written.
        let script = ScriptReading(text)
        let words = Set((script.comments + script.texts).joined(separator: " ").lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let year = Calendar(identifier: .gregorian).component(.year, from: Date())
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for word in ["\(year)", "\(year - 1)", "\(year + 1)"] + months + days {
            #expect(!words.contains(word), "the \(row) script carries no date: it says \(word)")
        }
        let host = ProcessInfo.processInfo.hostName.lowercased()
        let machine = host.split(separator: ".").first.map(String.init) ?? host
        for name in Set([host, machine]) where name.count >= 3 && name != "localhost" {
            #expect(!text.lowercased().contains(name), "the \(row) script carries no machine name: it says \(name)")
        }
    }

    // MAT-4: a variable of more than four million elements is refused, with its size. A system
    // analysis cannot hold one: it exports 512 frequencies, 256 samples and its roots, and roots
    // are found up to degree 512 (§6.3.8).
    @Test(arguments: ExportRow.allCases)
    func aVariableOfMoreThanFourMillionElementsIsRefusedWithItsSize(row: ExportRow) async throws {
        let limit = MATLABScript.elementLimit
        guard let oversized = try await row.oversized() else {
            #expect(row == .systemAnalysis)
            #expect(SystemAnalysis.exportedFrequencyCount <= limit && SystemAnalysis.exportedSampleCount <= limit)
            do throws(DSPError) {
                _ = try await FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 601) }.analysis(sampleRate: 48_000)
                Issue.record("a system of degree 600 was analysed: its roots, exported, would be more than 512")
            } catch {
                guard case .unsupportedConfiguration = error else {
                    Issue.record("a system of degree 600 is refused as an unsupported configuration, not with \(error)")
                    return
                }
            }
            return
        }
        #expect(oversized.elements > limit)
        let exportable = try Self.exportable(oversized.value)
        do throws(DSPError) {
            _ = try await exportable.matlabScript()
            Issue.record("the export of a \(row) of \(oversized.elements) elements was not refused")
        } catch {
            #expect(error == .exportTooLarge(elements: oversized.elements, limit: limit), "\(error)")
            #expect(String(describing: error).contains("\(oversized.elements)"), "the refusal names the size: \(error)")
        }
    }

    // MAT-6: the export runs on the background executor (BG-1). Called from the main actor, it
    // hands its text back there; while the queue of `BackgroundWork` is held, it does not come
    // back, so its work runs there; and a call cancelled before it starts throws `cancelled`
    // (BG-3). The cases run one at a time, so the queue is held for one of them at a time.
    @Test(.serialized, arguments: ExportRow.allCases) @MainActor
    func theExportRunsOnTheBackgroundExecutor(row: ExportRow) async throws {
        let exportable = try Self.exportable(try await row.specimen().value)
        #expect(pthread_main_np() != 0, "the call is made from the main thread")
        let started = DispatchTime.now().uptimeNanoseconds
        let text = try await exportable.matlabScript()
        let took = DispatchTime.now().uptimeNanoseconds - started
        #expect(!text.isEmpty && pthread_main_np() != 0, "the text of the \(row) comes back to the main actor")

        let returned = Locked(false)
        BackgroundWork.queue.suspend()
        let held = Task { () async throws -> String in
            let text = try await exportable.matlabScript()
            returned.set(true)
            return text
        }
        // The pause synchronises nothing and decides nothing for an export whose work runs on the
        // queue: held, the queue does not run it, however long the pause. It is the time an export
        // that does not wait for the queue has to show it, by returning: four times what the call
        // above took, and never less than 50 ms.
        try? await Task.sleep(nanoseconds: Swift.max(50_000_000, Swift.min(1_000_000_000, 4 * took)))
        let returnedWhileHeld = returned.get()
        BackgroundWork.queue.resume()
        #expect(!returnedWhileHeld, "the export of the \(row) returned while the queue of BackgroundWork was held: its work does not run there")
        #expect(try await held.value == text, "let go, the queue runs it")

        let early = Task { () async throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await exportable.matlabScript()
        }
        switch await early.result {
        case .success: Issue.record("the export of the \(row), cancelled before it started, returned its text")
        case .failure(let error): #expect(error as? DSPError == .cancelled, "\(error)")
        }
    }
}
