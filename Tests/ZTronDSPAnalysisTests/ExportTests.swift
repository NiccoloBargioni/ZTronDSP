import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// MATLAB export of frames and of the window analysis (WP-540, WP-501g): golden scripts.
@Suite("MATLAB export")
struct ExportTests {
    private func golden(_ name: String) throws -> (case: GoldenCase, script: String) {
        let url = try #require(Bundle.module.url(forResource: "script_\(name)", withExtension: "m", subdirectory: "Golden"), "script_\(name).m is not in the bundle")
        return (try GoldenFile(named: "matlab_scripts", in: .module).require(name), try String(contentsOf: url, encoding: .utf8))
    }

    /// Two scripts that differ at most in the last digits of their numbers: the same
    /// statements, the same words, and every number within `tolerance` of its counterpart.
    private func expectSameScript(_ actual: String, _ expected: String, tolerance: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let separators = CharacterSet(charactersIn: " \n[];(),")
        let a = actual.components(separatedBy: separators), b = expected.components(separatedBy: separators)
        guard a.count == b.count else {
            Issue.record("the scripts differ in shape: \(a.count) words and \(b.count)", sourceLocation: sourceLocation)
            return
        }
        for (index, (word, other)) in zip(a, b).enumerated() where word != other {
            guard let x = Double(word), let y = Double(other), abs(x - y) <= tolerance * Swift.max(1, abs(x), abs(y)) else {
                Issue.record("word \(index) is \(word) where \(other) was expected", sourceLocation: sourceLocation)
                return
            }
        }
    }

    // MARK: Feed snapshots

    @Test func aHeatMapSnapshotIsAnImageWithItsAxes() async throws {
        let (linear, expected) = try golden("heatmap-linear")
        let snapshot = FeedSnapshot(content: .heatmap, axis: .linearFrequency(binCount: 5, nyquist: 24_000), environment: nil, rowCount: 5,
                                    values: try linear.floats("values"), times: try linear.real("times"))
        #expect(try await snapshot.matlabScript() == expected, "evenly spaced rows are drawn against their values")

        let (mel, uneven) = try golden("heatmap-mel")
        let bands = FeedSnapshot(content: .heatmap, axis: .mel(centers: try mel.real("rowValues")), environment: nil, rowCount: 3,
                                 values: try mel.floats("values"), times: try mel.real("times"))
        #expect(try await bands.matlabScript() == uneven, "unevenly spaced rows are drawn against their index, their values kept beside")
    }

    @Test func aFeedExportsWhatItHolds() async throws {
        let feed = HeatmapFeed(history: 32)
        try Pipeline { MelSpectrogram(frame: 1_024, hop: 512, bands: 12, to: feed) }.run(on: TestSignal.whiteNoise(count: 8_192, seed: 5), format: mono48)
        let script = try await feed.snapshot().matlabScript()
        let lines = script.split(separator: "\n")
        #expect(lines.first == "% Heat map: 12 rows, 15 columns" && lines.contains("imagesc(times, 1:numel(row_values), values);") && lines.contains("ylabel('row (mel band centre (Hz) in row_values)');"))
        #expect(try await feed.snapshot().matlabScript() == script, "equal input gives equal text (MAT-4)")
        #expect(!script.contains("202") || !script.lowercased().contains("date"), "no date")
        for (axis, label) in [(FeedAxis.quefrency(count: 2, sampleRate: 100), "quefrency (s)"), (.lags(count: 2, sampleRate: 100), "lag (s)"), (.indices(count: 2), "index"),
                              (.pitchClasses, "pitch class"), (.tempo(beatsPerMinute: [60, 120]), "tempo (beats per minute)"),
                              (.constantQ(minimumFrequency: 55, binsPerOctave: 12, binCount: 2), "constant-Q bin frequency (Hz)")] {
            #expect(FeedSnapshot.rowLabel(of: axis).label == label)
        }
        #expect(FeedSnapshot.rowLabel(of: nil) == ("index", true) && FeedSnapshot.rowLabel(of: .tempo(beatsPerMinute: [])).isEvenlySpaced == false)
    }

    @Test func aWaveformSnapshotIsItsEnvelopeOverTime() async throws {
        let (data, expected) = try golden("waveform")
        let minima = try data.floats("minima"), maxima = try data.floats("maxima")
        let snapshot = FeedSnapshot(content: .waveform, axis: nil, environment: nil, rowCount: 2,
                                    values: zip(minima, maxima).flatMap { [$0, $1] }, times: try data.real("times"))
        #expect(try await snapshot.matlabScript() == expected)
    }

    @Test func emptySnapshotsDefineTheirVariablesAndPlotNothing() async throws {
        let heat = try await HeatmapFeed().snapshot().matlabScript()
        #expect(heat == "% Heat map: 0 rows, 0 columns\ntimes = [];\nrow_values = [];\nvalues = [];\n")
        let wave = try await WaveformFeed().snapshot().matlabScript()
        #expect(wave == "% Waveform envelope: 0 pairs\ntimes = [];\nminima = [];\nmaxima = [];\n")
        let track = try await ScalarTrack([], rate: 100).matlabScript()
        #expect(track == "% Scalar track: 0 frames\ntimes = [];\nvalues = [];\nconfidence = [];\n")
    }

    // MARK: Scalar tracks

    @Test func aScalarTrackIsValueAndConfidenceOverTime() async throws {
        let (data, expected) = try golden("scalar-track")
        let frames = zip(try data.floats("values"), try data.floats("confidence")).map { ScalarFrame(value: $0, confidence: $1) }
        let track = ScalarTrack(frames, rate: try data.number("rate"), start: try data.number("start"))
        #expect(try await track.matlabScript() == expected)
        #expect(ScalarTrack(frames, times: track.times) == track && ScalarTrack(frames, times: [0, 1]).frames.count == 2, "the longer array is cut to the shorter")
        #expect(ScalarTrack(frames, rate: 0, start: 2).times == [Double](repeating: 2, count: 6))
        // What a pipeline measures exports as it comes.
        let pitch: [ScalarFrame] = try Pipeline { STFT(frame: 2_048, hop: 512); Cepstrum(); CepstralPitch(range: .hertz(100 ... 500)) }
            .process(TestSignal.harmonic(fundamental: 220, amplitudes: [1, 0.5, 0.3, 0.2], sampleRate: 48_000, count: 8_192), format: mono48)
        let script = try await ScalarTrack(pitch, rate: 93.75).matlabScript()
        #expect(script.hasPrefix("% Scalar track: 13 frames\n") && script.contains("plot(times, confidence);"))
    }

    // MARK: Inversion reports

    private func report(_ data: GoldenCase, withSignal: Bool = true) throws -> InversionReport {
        let conditions = [
            InversionCondition(name: "first condition", theorem: "a theorem", quantity: "a quantity", observed: 1, holds: true, margin: 0.5, predictedError: 1e-6),
            InversionCondition(name: "second condition", theorem: "another", quantity: "another", observed: 0, holds: false, margin: -0.25, isNecessary: false, predictedError: 0.125),
        ]
        let roundTrip = withSignal
            ? InversionRoundTrip(original: try data.floats("original"), reconstruction: try data.floats("reconstruction"), frameLength: try data.integer("frameLength")) : nil
        return InversionReport(stage: "Forward", inverse: "Backward", conditions: conditions, roundTrip: roundTrip, sampleRate: try data.number("sampleRate"))
    }

    @Test(arguments: ["inversion", "inversion-frames"])
    func anInversionReportIsOriginalReconstructionAndError(name: String) async throws {
        let (data, expected) = try golden(name)
        #expect(try await report(data).matlabScript() == expected)
    }

    @Test func anInversionReportWithoutASignalHoldsItsFiguresAndPlotsNothing() async throws {
        let (data, expected) = try golden("inversion-conditions")
        let bare = try report(data, withSignal: false)
        #expect(try await bare.matlabScript() == expected && !expected.contains("plot("))
        let failing = InversionReport(stage: "A", inverse: "B", conditions: [
            InversionCondition(name: "needed", theorem: "", quantity: "", observed: 0, holds: false, margin: -1, predictedError: 1)])
        #expect(try await failing.matlabScript() == "% Inversion report: A and back through B\n% A necessary condition fails.\npredicted_error = 1;\n% needed: fails, margin -1\n")
        // A report measured by the package exports too, with its infinite ratio written as Inf.
        let exact = try await DSP.inversionReport(ofUpsampling: [0.25, -0.5, 0.75], by: 2, sampleRate: 100)
        let script = try await exact.matlabScript()
        #expect(script.contains("measured_snr = Inf;") && script.contains("original = [0.25 -0.5 0.75];") && script.contains("reconstruction = [0.25 -0.5 0.75];"))
    }

    // MARK: The window analysis (WP-501g)

    @Test func aWindowAnalysisIsTheWindowAndItsSpectrumWithMarkers() async throws {
        let (data, expected) = try golden("window-analysis")
        let analysis = try await Window.hann.analysis(frame: try data.integer("frame"), hop: try data.integer("hop"))
        let script = try await analysis.matlabScript()
        // The reference script was computed by the same definitions in NumPy: the statements are
        // the same and the numbers agree to round-off.
        expectSameScript(script, expected, tolerance: 1e-9)
        #expect(script.split(separator: "\n").count == 33 && script.hasPrefix("% Window analysis: hann, 64 samples, hop 16\nframe = 64;\nsamples = [0 "))
        #expect(try await analysis.matlabScript() == script, "equal input gives equal text (MAT-4)")
        // What is undefined is written as NaN, which a plot skips (MAT-3).
        let lobeless = try await Window.custom { $0 < 0.5 ? 1 : -1 }.analysis(frame: 16).matlabScript()
        #expect(lobeless.contains("equivalent_noise_bandwidth = NaN;"))
    }

    // MARK: Limits, cancellation, the background (MAT-4, MAT-6)

    @Test func anExportTooLargeIsRefused() async {
        let big = FeedSnapshot(content: .heatmap, axis: nil, environment: nil, rowCount: 2_001, values: [Float](repeating: 0, count: 2_001 * 2_000),
                               times: [Double](repeating: 0, count: 2_000))
        await #expect(throws: DSPError.exportTooLarge(elements: 2_001 * 2_000, limit: 4_000_000)) { _ = try await big.matlabScript() }
        let long = ScalarTrack([ScalarFrame](repeating: .none, count: 4_000_001), rate: 100)
        await #expect(throws: DSPError.exportTooLarge(elements: 4_000_001, limit: 4_000_000)) { _ = try await long.matlabScript() }
    }

    @Test func anExportCanBeCancelled() async throws {
        let (data, _) = try golden("inversion")
        let report = try report(data)
        let snapshot = FeedSnapshot(content: .waveform, axis: nil, environment: nil, rowCount: 2, values: [0, 1], times: [0])
        let analysis = try await Window.hann.analysis(frame: 64)
        for work in [{ try await report.matlabScript() }, { try await snapshot.matlabScript() }, { try await ScalarTrack([.none], rate: 1).matlabScript() },
                     { try await analysis.matlabScript() }] as [@Sendable () async throws -> String] {
            let task = Task { try await work() }
            task.cancel()
            let result = await task.result
            #expect(throws: DSPError.cancelled) { _ = try result.get() }
        }
    }
}
