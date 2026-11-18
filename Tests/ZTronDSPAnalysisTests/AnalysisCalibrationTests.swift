import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPMetal
import ZTronDSPTesting

/// The crossovers of the analysis target (WP-611c, WP-611d): one-shot convolution direct
/// against FFT, the mel projection banded against dense, the median of a spectrogram on CPU
/// lanes against the GPU. Measured, recorded; forced choices honoured; a measured table is a
/// value the engine accepts.
///
/// No test here holds a timing against another: which side leads is the device's business.
@Suite("Analysis calibration")
struct AnalysisCalibrationTests {
    /// The stock measurements on the first sizes of each grid, one short sample each.
    private func quickReport(startingFrom base: CrossoverTable = .shipped, gridLimit: Int? = 3, withGPU: Bool = true) async throws -> AnalysisCalibrationReport {
        let context = withGPU ? try await MetalContext.shared() : nil
        return try await BackgroundWork.run { checkpoint throws(DSPError) -> AnalysisCalibrationReport in
            try Calibration.measureAnalysisStock(startingFrom: base, samples: 1, sampleDuration: 0, gridLimit: gridLimit, context: context, checkpoint: checkpoint)
        }
    }

    /// A curve whose times are a formula of the kernel length: no clock, no noise.
    private func curve(_ implementation: Implementation, _ label: String, _ lengths: [Int], _ cost: (Int) -> Double) -> CalibrationCurve {
        CalibrationCurve(implementation: implementation, label: label, nanoseconds: lengths.map(cost))
    }

    /// The fields of a table by name, as it encodes them.
    private func fields(_ table: CrossoverTable) throws -> [String: Double] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(table))
        return (object as? [String: NSNumber] ?? [:]).mapValues { $0.doubleValue }
    }

    // MARK: The workloads (WP-611c, WP-611d)

    @Test func everyWorkloadRunsAndIsTimed() async throws {
        let report = try await quickReport()
        #expect(report.measurements.map { $0.entry } == [.melDense, .medianGPU])
        let mel = report.measurements[0], median = report.measurements[1]
        #expect(mel.sizes == [16 * 129, 32 * 257, 64 * 513] && median.sizes == [8, 32, 128].map { $0 * 513 * 17 }, "the first three sizes of each grid")
        #expect(mel.curves.map { $0.label } == ["Banded dot products", "Dense product"] && mel.curves.map { $0.implementation } == [.native, .accelerate])
        #expect(median.curves.map { $0.label } == ["CPU lanes", "Metal"] && median.curves.map { $0.implementation } == [.native, .metal])
        let convolution = report.convolution
        #expect(convolution.signalLength == 16_384 && convolution.kernelLengths == [2, 4, 8])
        #expect(convolution.curves.map { $0.label } == ["Direct", "FFT"] && convolution.curves.map { $0.implementation } == [.native, .accelerate])
        for curve in mel.curves + median.curves + convolution.curves {
            #expect(curve.nanoseconds.count == 3 && curve.nanoseconds.allSatisfy { $0.isFinite && $0 > 0 }, "\(curve.label): \(curve.nanoseconds)")
        }
        // The grids as they stand.
        #expect(AnalysisCandidates.melSizes == AnalysisCandidates.melSizes.sorted() && Set(AnalysisCandidates.melSizes).count == 9, "strictly increasing")
        #expect(AnalysisCandidates.medianSizes.last == 2_048 * 513 * 17 && AnalysisCandidates.medianSizes.last! > CrossoverTable.shipped.medianGPU, "past the initial value")
        #expect(AnalysisCandidates.convolutionKernels.first == 2 && AnalysisCandidates.convolutionKernels.last == 8_192)
        // Every bank of the grid is one that MelScale would take: no band without a bin.
        for shape in AnalysisCandidates.melShapes {
            #expect(try MelFilterBank(bands: shape.bands, binCount: shape.bins, nyquist: 24_000).firstEmptyBand == nil, "\(shape)")
        }
        // A size that is no bank of the grid cannot be measured, and has no curve.
        let stray = try Calibration.search(.melDense, sizes: [7], lighter: AnalysisCandidates.mel(dense: false, crossovers: .shipped), heavier: nil, samples: 1, sampleDuration: 0)
        #expect(stray.curves.isEmpty)
    }

    @Test func withoutADeviceTheMedianHasOneCurveAndKeepsItsEntry() async throws {
        let base = CrossoverTable(medianGPU: 456)
        let report = try await quickReport(startingFrom: base, gridLimit: 2, withGPU: false)
        let median = report.measurements[1]
        #expect(median.entry == .medianGPU && median.curves.map { $0.label } == ["CPU lanes"] && median.crossover == nil)
        #expect(report.table.medianGPU == 456, "one curve decides nothing")
    }

    @Test func theWorkloadsOfTheMelProjectionAreTheNodes() throws {
        let noise = TestSignal.whiteNoise(count: 6_000, seed: 611, amplitude: 0.5)
        for (bands, frame) in [(64, 1_024), (128, 2_048), (16, 256)] {
            let bins = frame / 2 + 1
            let spectra: [[Float]] = try Pipeline { STFT(frame: frame, hop: frame); Magnitude() }.process(noise, format: mono48)
            let mel = Pipeline { STFT(frame: frame, hop: frame); Magnitude(); MelScale(bands: bands) }
            // The table decides which node the plan holds: banded below the crossover, dense from it on.
            let banded: [[Float]] = try mel.process(noise, format: mono48, crossovers: CrossoverTable(melDense: .max))
            let dense: [[Float]] = try mel.process(noise, format: mono48, crossovers: CrossoverTable(melDense: 1))
            let bandedWorkload = try MelProjectionWorkload(bands: bands, binCount: bins, crossovers: CrossoverTable(melDense: .max), isDense: false)
            let denseWorkload = try MelProjectionWorkload(bands: bands, binCount: bins, crossovers: CrossoverTable(melDense: 1), isDense: true)
            #expect(spectra.count >= 2 && banded.count == spectra.count && dense.count == spectra.count)
            for (index, spectrum) in spectra.enumerated() {
                #expect(bandedWorkload.bands(of: spectrum) == banded[index], "\(bands) bands of \(bins) bins, frame \(index): the banded node, bit for bit")
                #expect(denseWorkload.bands(of: spectrum) == dense[index], "\(bands) bands of \(bins) bins, frame \(index): the dense node, bit for bit")
                expectClose(banded[index], bandedWorkload.bank.applied(to: spectrum), .relative(1e-4), "and both the projection of the bank")
            }
            // Under another table the dot products of the bands are bound otherwise, and agree to round-off (SEL-6).
            let scalar = try MelProjectionWorkload(bands: bands, binCount: bins, crossovers: CrossoverTable(reductionSIMD: .max, reductionAccelerate: .max), isDense: false)
            let library = try MelProjectionWorkload(bands: bands, binCount: bins, crossovers: CrossoverTable(reductionSIMD: 1, reductionAccelerate: 1), isDense: false)
            let lanes = try MelProjectionWorkload(bands: bands, binCount: bins, crossovers: CrossoverTable(reductionSIMD: 1, reductionAccelerate: .max), isDense: false)
            expectClose(scalar.bands(of: spectra[1]), banded[1], .relative(1e-5))
            expectClose(library.bands(of: spectra[1]), banded[1], .relative(1e-5))
            expectClose(lanes.bands(of: spectra[1]), banded[1], .relative(1e-5))
        }
    }

    // MARK: The table

    @Test func aMeasuredTableReplacesWhatWasMeasuredAndKeepsTheRest() async throws {
        let base = CrossoverTable(
            elementwise: 11, reductionSIMD: 12, reductionAccelerate: 13, laneExchange: 14, gainKernel: 15, biquadKernel: 16, firPartitioned: 17,
            convolutionFFTFactor: 7, melDense: 123, medianGPU: 456, polynomialClosedForm: 3)
        let report = try await quickReport(startingFrom: base)
        #expect(report.table.melDense == (report.measurements[0].crossover ?? Int.max), "the mel projection is its measured crossover, or never")
        #expect(report.table.medianGPU == (report.measurements[1].crossover ?? Int.max), "and so is the median")
        #expect(report.table.convolutionFFTFactor == report.convolution.factor && report.convolution.factor != 7, "the cost model has its measured factor")
        // Everything else is the base's, field for field: a field the table gains later is kept too.
        var expected = try fields(base)
        expected["melDense"] = Double(report.table.melDense)
        expected["medianGPU"] = Double(report.table.medianGPU)
        expected["convolutionFFTFactor"] = report.table.convolutionFFTFactor
        #expect(try fields(report.table) == expected && expected.count == 11)
        #expect(try fields(base.replacingConvolutionFactor(with: 2.5)).filter { $0.key != "convolutionFFTFactor" } == fields(base).filter { $0.key != "convolutionFFTFactor" })
        // No measurement, no change; a report is a value and survives coding.
        let unmeasured = ConvolutionCrossover(signalLength: 4_096, kernelLengths: [2, 4], curves: [])
        #expect(AnalysisCalibrationReport(measurements: [], convolution: unmeasured, startingFrom: base).table == base)
        let decoded = try JSONDecoder().decode(AnalysisCalibrationReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report && decoded.hashValue == report.hashValue)
    }

    @Test func theFactorPutsTheChangeOfMethodAtTheCrossover() {
        let lengths = AnalysisCandidates.convolutionKernels, n = AnalysisCandidates.convolutionSignal
        // Times that follow the cost model exactly: direct a·N·K, FFT b·(N + K)·log₂(N + K). They cross where the model's size is b / a.
        for ratio in [0.5, 4, 30, 150, 300] as [Double] {
            let direct = curve(.native, "Direct", lengths) { Double(n * $0) }
            let transformed = curve(.accelerate, "FFT", lengths) { ratio * Double(n + $0) * log2(Double(n + $0)) }
            let measured = ConvolutionCrossover(signalLength: n, kernelLengths: lengths, curves: [direct, transformed])
            let truth = lengths.first { ConvolutionCrossover.modelSize(signalLength: n, kernelLength: $0) > ratio }
            #expect(measured.crossover == truth && truth != nil, "ratio \(ratio): the first kernel length past the crossing")
            guard let factor = measured.factor, let crossover = measured.crossover else { Issue.record("ratio \(ratio): no factor"); continue }
            // The table with that factor uses the FFT method from the crossover on, and the direct one below it.
            let table = CrossoverTable.shipped.replacingConvolutionFactor(with: factor)
            for length in lengths {
                #expect(table.convolutionUsesFFT(n, length) == (length >= crossover), "ratio \(ratio), a kernel of \(length)")
                #expect(OneShotConvolution.method(.automatic, n, length, crossovers: table) == (length >= crossover ? .fft : .direct))
            }
            // Within one grid step of the truth, in the model's own measure.
            let step = ConvolutionCrossover.modelSize(signalLength: n, kernelLength: crossover)
            #expect(factor < step && factor >= step / 2.2 && factor <= ratio * 1.5, "ratio \(ratio): factor \(factor)")
        }
        // The FFT method leads on the whole grid: the factor lies just below the first size, and nothing below the grid is promised.
        let always = ConvolutionCrossover(signalLength: n, kernelLengths: lengths, curves: [curve(.native, "Direct", lengths) { _ in 9 }, curve(.accelerate, "FFT", lengths) { _ in 1 }])
        let first = ConvolutionCrossover.modelSize(signalLength: n, kernelLength: 2)
        #expect(always.crossover == 2 && always.factor == first.nextDown)
        let eager = CrossoverTable.shipped.replacingConvolutionFactor(with: always.factor ?? 0)
        #expect(eager.convolutionUsesFFT(n, 2) && eager.convolutionUsesFFT(n, 8_192) && !eager.convolutionUsesFFT(n, 1))
        // It never leads: never used, whatever the lengths.
        let never = ConvolutionCrossover(signalLength: n, kernelLengths: lengths, curves: [curve(.native, "Direct", lengths) { _ in 1 }, curve(.accelerate, "FFT", lengths) { _ in 9 }])
        #expect(never.crossover == nil && never.factor == .greatestFiniteMagnitude)
        let direct = CrossoverTable.shipped.replacingConvolutionFactor(with: never.factor ?? 0)
        #expect(!direct.convolutionUsesFFT(n, 8_192) && !direct.convolutionUsesFFT(1 << 28, 1 << 28))
        #expect(throws: Never.self) { _ = try JSONEncoder().encode(direct) }
        // One curve decides nothing.
        let single = ConvolutionCrossover(signalLength: n, kernelLengths: lengths, curves: [curve(.native, "Direct", lengths) { Double($0) }])
        #expect(single.crossover == nil && single.factor == nil)
        // The model's size: N·K / ((N + K)·log₂(N + K)).
        expectClose(ConvolutionCrossover.modelSize(signalLength: 4_096, kernelLength: 4_096), 4_096.0 * 4_096 / (8_192 * 13), .relative(1e-12))
        #expect(ConvolutionCrossover.modelSize(signalLength: 0, kernelLength: 5) == 0 && ConvolutionCrossover.modelSize(signalLength: 5, kernelLength: -1) == 0)
        #expect(ConvolutionCrossover.modelSize(signalLength: 100, kernelLength: 7) == ConvolutionCrossover.modelSize(signalLength: 7, kernelLength: 100))
    }

    // MARK: Forced choices are honoured (WP-611c, WP-611d)

    @Test func forcedChoicesAreHonouredWithAMeasuredTable() async throws {
        let table = try await quickReport().table
        // Convolution: a forced method is that method whatever the table; the automatic one follows the model.
        for (n, k) in [(16, 5), (1_024, 255), (4_096, 2_048), (30_000, 3)] {
            #expect(OneShotConvolution.method(.direct, n, k, crossovers: table) == .direct && OneShotConvolution.method(.fft, n, k, crossovers: table) == .fft)
            #expect(OneShotConvolution.method(.partitioned, n, k, crossovers: table) == .partitioned)
            #expect(OneShotConvolution.method(.automatic, n, k, crossovers: table) == (table.convolutionUsesFFT(n, k) ? .fft : .direct), "\(n) by \(k)")
        }
        let x = TestSignal.whiteNoise(count: 1_024, seed: 1, amplitude: 0.5), h = TestSignal.whiteNoise(count: 255, seed: 2, amplitude: 0.5)
        let reference = try DSP.convolve(x, h, strategy: .direct)
        #expect(try DSP.convolve(x, h, strategy: .direct, crossovers: table) == reference, "forced direct, bit for bit")
        expectClose(try DSP.convolve(x, h, strategy: .fft, crossovers: table), reference, .absolute(1e-5 * Double(reference.map { abs($0) }.max() ?? 1)))
        expectClose(try DSP.convolve(x, h, crossovers: table), reference, .absolute(1e-5 * Double(reference.map { abs($0) }.max() ?? 1)))
        // The mel projection and the median: the environment's request against the table's entry.
        for size in [1, 2_064, 131_200, 1 << 20, 1 << 26] {
            #expect(table.implementation(for: .melProjection, size: size, requested: .native) == .native, "mel at \(size): forced banded")
            #expect(table.implementation(for: .melProjection, size: size, requested: .accelerate) == .accelerate, "mel at \(size): forced dense")
            #expect(table.implementation(for: .melProjection, size: size) == (size >= table.melDense ? .accelerate : .native), "mel at \(size): automatic follows the table")
            #expect(table.implementation(for: .median, size: size, requested: .native) == .native && table.implementation(for: .median, size: size, requested: .metal) == .metal)
            #expect(table.implementation(for: .median, size: size) == (size >= table.medianGPU ? .metal : .native), "the median at \(size)")
            #expect(AutomaticMedian.implementation(kernel: 1, elements: size, crossovers: table) == (size >= table.medianGPU ? .metal : .native))
        }
        // In a plan: the forced projection is the node of that kind, and both agree (SEL-6).
        let noise = TestSignal.whiteNoise(count: 8_192, seed: 3, amplitude: 0.5)
        let mel = Pipeline { STFT(frame: 1_024, hop: 512); Magnitude(); MelScale(bands: 64) }
        let banded: [[Float]] = try mel.environment(\.implementation, .native).process(noise, format: mono48, crossovers: table)
        let dense: [[Float]] = try mel.environment(\.implementation, .accelerate).process(noise, format: mono48, crossovers: table)
        let chosen: [[Float]] = try mel.process(noise, format: mono48, crossovers: table)
        #expect(banded != dense, "two nodes: they agree to round-off, not bit for bit")
        for index in banded.indices {
            expectClose(dense[index], banded[index], .relative(1e-4), "frame \(index)")
            expectClose(chosen[index], banded[index], .relative(1e-4), "frame \(index)")
        }
    }

    // MARK: The device (WP-611c, WP-611d)

    @Test func theDeviceIsMeasuredInTheBackgroundAndTheEngineAcceptsTheTable() async throws {
        let start = Benchmark.ticks()
        let report = try await Calibration.analysisReport()
        let seconds = Benchmark.nanoseconds(Benchmark.ticks() &- start) / 1e9
        print("calibration: Calibration.analysisReport() took \(seconds) s")
        var results: [BenchmarkResult] = []
        func note(_ name: String, _ sizes: [Int], _ curves: [CalibrationCurve], _ found: String) {
            print("calibration: \(name) sizes \(sizes) crossover \(found)")
            for (index, curve) in curves.enumerated() {
                print("calibration:   \(curve.label): \(curve.nanoseconds.map { String(format: "%.0f", $0) }.joined(separator: " ")) ns")
                for (size, time) in zip(sizes, curve.nanoseconds) {
                    results.append(BenchmarkResult(name: "calibration.\(name).\(index + 1).\(size)", iterations: 1, samples: 1, minimum: time, median: time, mean: time))
                }
            }
        }
        for measurement in report.measurements {
            note(measurement.entry.rawValue, measurement.sizes, measurement.curves,
                 measurement.curves.count < 2 ? "one curve" : (measurement.crossover.map { String($0) } ?? "none on the grid"))
        }
        let convolution = report.convolution
        note("convolutionFFT", convolution.kernelLengths, convolution.curves,
             "\(convolution.crossover.map { String($0) } ?? "none on the grid"), factor \(convolution.factor.map { String($0) } ?? "not measured")")
        print("calibration: table melDense \(report.table.melDense), medianGPU \(report.table.medianGPU), convolutionFFTFactor \(report.table.convolutionFFTFactor)")
        Benchmark.record(results)

        #expect(report.measurements.map { $0.entry } == [.melDense, .medianGPU])
        #expect(report.measurements[0].sizes == AnalysisCandidates.melSizes && report.measurements[1].sizes == AnalysisCandidates.medianSizes, "the whole grids")
        #expect(convolution.kernelLengths == AnalysisCandidates.convolutionKernels && convolution.curves.count == 2 && report.measurements.allSatisfy { $0.curves.count == 2 })
        #expect(results.count == 2 * (9 + 5 + 13) && results.allSatisfy { $0.minimum > 0 })
        let shipped = CrossoverTable.shipped
        #expect(report.table.firPartitioned == shipped.firPartitioned && report.table.gainKernel == shipped.gainKernel, "what is measured elsewhere is kept")

        // The table alone, from another base.
        let table = try await Calibration.measureAnalysis(startingFrom: CrossoverTable(gainKernel: 77))
        #expect(table.gainKernel == 77 && table.polynomialClosedForm == shipped.polynomialClosedForm)

        // The engine takes it, and so do a pipeline and the offline functions: what is computed
        // is the same, because a crossover only chooses between implementations that agree (SEL-6).
        _ = DSPEngine(blockSize: 256, crossovers: report.table)
        let noise = TestSignal.whiteNoise(count: 16_384, seed: 611, amplitude: 0.5)
        let mel = Pipeline { STFT(frame: 2_048, hop: 512); Magnitude(); MelScale(bands: 128) }
        let reference: [[Float]] = try mel.process(noise, format: mono48)
        let measured: [[Float]] = try mel.process(noise, format: mono48, crossovers: report.table)
        for index in reference.indices { expectClose(measured[index], reference[index], .relative(1e-4), "the mel bands of frame \(index)") }
        let kernel = TestSignal.whiteNoise(count: 300, seed: 5, amplitude: 0.5)
        let direct = try DSP.convolve(noise, kernel, strategy: .direct)
        expectClose(try DSP.convolve(noise, kernel, crossovers: report.table), direct, .absolute(1e-5 * Double(direct.map { abs($0) }.max() ?? 1)))
        let magnitudes = reference.flatMap { $0 }.map { abs($0) }
        let lanes = try await DSP.harmonicPercussive(magnitudes, binCount: 128, select: .harmonic, timeKernel: 9, frequencyKernel: 9, median: .selectionNetwork)
        let chosen = try await DSP.harmonicPercussive(magnitudes, binCount: 128, select: .harmonic, timeKernel: 9, frequencyKernel: 9, crossovers: report.table)
        #expect(chosen == lanes, "the medians are exact on either side")
    }

    @Test func aCancelledTaskGetsNoTable() async {
        let task = Task { () async throws -> CrossoverTable in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Calibration.measureAnalysis()
        }
        let result = await task.result
        #expect(throws: DSPError.cancelled) { _ = try result.get() }
        // A measurement that is running stops between two sizes.
        let cancelled = BackgroundWork.Checkpoint(state: Locked(true))
        #expect(throws: DSPError.cancelled) {
            _ = try Calibration.measureAnalysisStock(startingFrom: .shipped, samples: 1, sampleDuration: 0, gridLimit: 1, context: nil, checkpoint: cancelled)
        }
    }
}
