import Accelerate
import Foundation
import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPMetal

// The crossovers whose two sides live in this target (§7.4, WP-611c, WP-611d): the direct
// against the FFT method of one-shot convolution, the banded against the dense mel
// projection, and the median of a whole spectrogram on CPU lanes against the GPU. The search,
// the timer and the report of a single entry are those of `Calibration` in ZTronDSPMetal.

/// What was measured for one-shot convolution (WP-611c): the time of the direct and of the
/// FFT method for one signal length over a grid of kernel lengths, the kernel length at which
/// the FFT method takes the lead, and the factor of the table's cost model that puts the
/// change of method there.
///
/// The table decides a convolution of lengths `N` and `K` by a cost model, not by a size: the
/// FFT method is used when `N·K > factor · (N + K)·log₂(N + K)`
/// (`CrossoverTable.convolutionFFTFactor`). `modelSize(signalLength:kernelLength:)` is the
/// quotient of the two sides: the FFT method is used where it exceeds the factor.
///
/// An immutable value, usable on any thread, and `Codable`, so an app can keep it; creating
/// or decoding one allocates its arrays.
public struct ConvolutionCrossover: Hashable, Sendable, Codable {
    /// Samples of the signal every convolution of the measurement was given.
    public let signalLength: Int
    /// The kernel lengths measured, increasing.
    public let kernelLengths: [Int]
    /// One curve per method, the direct one first: nanoseconds per convolution at each kernel
    /// length. A method that could not be measured has no curve.
    public let curves: [CalibrationCurve]
    /// The smallest kernel length of the grid from which the FFT method is faster at that
    /// length and at every longer one. `nil` when it is not faster at the longest, and when
    /// only one method was measured.
    public let crossover: Int?
    /// The `convolutionFFTFactor` the measurement gives: the geometric mean of the model's
    /// size at `crossover` and at the kernel length before it, so that the model changes
    /// method between the two; just below the model's size at the first kernel length when
    /// the FFT method leads on the whole grid; the largest finite number, which the model
    /// never exceeds, when it never leads. `nil` when only one method was measured: the table
    /// then keeps the factor it had.
    public let factor: Double?

    /// A measurement from its curves; the crossover and the factor are read off the first two.
    public init(signalLength: Int, kernelLengths: [Int], curves: [CalibrationCurve]) {
        self.signalLength = signalLength
        self.kernelLengths = kernelLengths
        self.curves = curves
        guard curves.count >= 2 else {
            crossover = nil
            factor = nil
            return
        }
        let found = Calibration.crossover(sizes: kernelLengths, lighter: curves[0].nanoseconds, heavier: curves[1].nanoseconds)
        crossover = found
        guard let found, let index = kernelLengths.firstIndex(of: found) else {
            factor = Double.greatestFiniteMagnitude
            return
        }
        let size = ConvolutionCrossover.modelSize(signalLength: signalLength, kernelLength: found)
        factor = index > 0
            ? (size * ConvolutionCrossover.modelSize(signalLength: signalLength, kernelLength: kernelLengths[index - 1])).squareRoot()
            : size.nextDown
    }

    /// What the cost model of the table compares its factor with: `N·K / ((N + K)·log₂(N + K))`
    /// for a signal of `N` samples and a kernel of `K`. 0 for lengths that are not positive.
    /// Usable on any thread.
    public static func modelSize(signalLength: Int, kernelLength: Int) -> Double {
        guard signalLength > 0, kernelLength > 0 else { return 0 }
        let total = Double(signalLength + kernelLength)
        return Double(signalLength) * Double(kernelLength) / (total * log2(total))
    }
}

/// The crossovers of the analysis target as measured on a device, together with the
/// measurements they were read from (SEL-5): what `Calibration.analysisReport()` returns.
///
/// An immutable value, usable on any thread, and `Codable`, so an app can keep it; creating
/// or decoding one allocates its arrays.
public struct AnalysisCalibrationReport: Hashable, Sendable, Codable {
    /// The table: the one the measurements started from, with `melDense` and `medianGPU`
    /// replaced by their measured crossovers where two implementations were measured, and
    /// `convolutionFFTFactor` by the measured factor. An entry whose heavier implementation
    /// never led is `Int.max`: never use it.
    public let table: CrossoverTable
    /// The mel projection and the median of a spectrogram, in the order they were measured.
    public let measurements: [CrossoverMeasurement]
    /// The one-shot convolution.
    public let convolution: ConvolutionCrossover

    /// A report from its measurements: the table is `base` with what was measured replaced.
    ///
    /// - Parameters:
    ///   - measurements: the mel projection and the median of a spectrogram.
    ///   - convolution: the one-shot convolution.
    ///   - base: the table the entries that were not measured are taken from.
    public init(measurements: [CrossoverMeasurement], convolution: ConvolutionCrossover, startingFrom base: CrossoverTable = .shipped) {
        self.measurements = measurements
        self.convolution = convolution
        let sized = CalibrationReport(measurements: measurements, startingFrom: base).table
        table = convolution.factor.map { sized.replacingConvolutionFactor(with: $0) } ?? sized
    }
}

extension CrossoverTable {
    /// The table with the factor of the convolution's cost model replaced. A table is an
    /// immutable value: this returns another.
    func replacingConvolutionFactor(with factor: Double) -> CrossoverTable {
        CrossoverTable(
            elementwise: elementwise, reductionSIMD: reductionSIMD, reductionAccelerate: reductionAccelerate, laneExchange: laneExchange,
            gainKernel: gainKernel, biquadKernel: biquadKernel, firPartitioned: firPartitioned, convolutionFFTFactor: factor, melDense: melDense,
            medianGPU: medianGPU, polynomialClosedForm: polynomialClosedForm)
    }
}

extension Calibration {
    /// Measures, on the running device, the crossovers whose implementations live in the
    /// analysis target, and returns `base` with them replaced (SEL-5, WP-611c, WP-611d): the
    /// direct against the FFT method of one-shot convolution, the banded against the dense mel
    /// projection, and the median of a whole spectrogram on CPU lanes against the GPU.
    ///
    /// ```swift
    /// let core = try await Calibration.measure()                          // the toolkit and the kernels
    /// let table = try await Calibration.measureAnalysis(startingFrom: core)
    /// let engine = DSPEngine(crossovers: table)
    /// ```
    ///
    /// Runs on the background executor (BG-1) for a second or two, and allocates; the caller
    /// may be on any thread but the analysis thread, and should not run audio it cares about
    /// meanwhile: the measurement loads a processor core and the GPU. The table is an
    /// immutable value (BG-2).
    /// Where there is no Metal device the median keeps the value of `base`.
    ///
    /// - Throws: `cancelled` when the calling task was cancelled (BG-3).
    public static func measureAnalysis(startingFrom base: CrossoverTable = .shipped) async throws(DSPError) -> CrossoverTable {
        try await analysisReport(startingFrom: base).table
    }

    /// The same measurement with the curves the table was read from, for inspection.
    ///
    /// Runs on the background executor (BG-1) and allocates; the caller may be on any thread but
    /// the analysis thread, and the errors are those of ``measureAnalysis(startingFrom:)``.
    public static func analysisReport(startingFrom base: CrossoverTable = .shipped) async throws(DSPError) -> AnalysisCalibrationReport {
        try await BackgroundWork.run { checkpoint throws(DSPError) -> AnalysisCalibrationReport in
            try measureAnalysisStock(
                startingFrom: base, samples: 5, sampleDuration: 0.000_2, gridLimit: nil, context: try? MetalContext.sharedBlocking(), checkpoint: checkpoint)
        }
    }

    /// The three measurements, one after the other.
    ///
    /// - Parameters:
    ///   - gridLimit: when given, only that many sizes of each grid, the smallest: for tests.
    ///   - context: the Metal context of the GPU median; `nil` leaves that curve out.
    static func measureAnalysisStock(
        startingFrom base: CrossoverTable, samples: Int, sampleDuration: TimeInterval, gridLimit: Int?, context: MetalContext?,
        checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) -> AnalysisCalibrationReport {
        func grid(_ sizes: [Int]) -> [Int] { gridLimit.map { Array(sizes.prefix(Swift.max($0, 1))) } ?? sizes }
        let mel = try search(
            .melDense, sizes: grid(AnalysisCandidates.melSizes), lighter: AnalysisCandidates.mel(dense: false, crossovers: base),
            heavier: AnalysisCandidates.mel(dense: true, crossovers: base), samples: samples, sampleDuration: sampleDuration, checkpoint: checkpoint)
        let median = try search(
            .medianGPU, sizes: grid(AnalysisCandidates.medianSizes), lighter: AnalysisCandidates.median(on: nil),
            heavier: context.map { AnalysisCandidates.median(on: $0) }, samples: samples, sampleDuration: sampleDuration, checkpoint: checkpoint)
        // The search labels its result with an entry of the table, and the table has none for
        // a cost model: the label is dropped, the grid and the curves are kept.
        let sweep = try search(
            .firPartitioned, sizes: grid(AnalysisCandidates.convolutionKernels), lighter: AnalysisCandidates.convolution(.direct),
            heavier: AnalysisCandidates.convolution(.fft), samples: samples, sampleDuration: sampleDuration, checkpoint: checkpoint)
        let convolution = ConvolutionCrossover(signalLength: AnalysisCandidates.convolutionSignal, kernelLengths: sweep.sizes, curves: sweep.curves)
        return AnalysisCalibrationReport(measurements: [mel, median], convolution: convolution, startingFrom: base)
    }
}

/// The implementations `Calibration.measureAnalysis()` times (WP-611c, WP-611d).
enum AnalysisCandidates {
    /// `count` values of seeded noise in 0 … 1.
    static func noise(_ count: Int, seed: UInt32) -> [Float] {
        var state = seed
        return (0 ..< count).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
    }

    // MARK: One-shot convolution

    /// The signal every convolution is given, and the kernels it is convolved with: from a
    /// kernel of two taps, which is the direct method's whatever the device, to a kernel half
    /// as long as the signal, where the model's size is some hundred times the factor the
    /// table starts with.
    static let convolutionSignal = 16_384
    static let convolutionKernels = [2, 4, 8, 16, 32, 64, 128, 256, 512, 1_024, 2_048, 4_096, 8_192]

    /// One whole convolution of the signal with a kernel of `size` values, by one method,
    /// forced: what a caller of `DSP.convolve` waits for, its buffers and its plan included.
    static func convolution(_ strategy: ConvolutionStrategy, signalLength: Int = convolutionSignal) -> CalibrationCandidate {
        CalibrationCandidate(strategy == .direct ? .native : .accelerate, label: strategy == .direct ? "Direct" : "FFT") { size, time in
            let signal = noise(signalLength, seed: 0x2545_F491), kernel = noise(size, seed: 0x9E37_79B9)
            var failed = false
            let elapsed = time {
                if (try? DSP.convolve(signal, kernel, strategy: strategy)) == nil { failed = true }
            }
            return failed ? .nan : elapsed
        }
    }

    // MARK: The mel projection

    /// The filter banks the projection is timed on: bands and bins of banks that are in use,
    /// every band with bins of its own at 48 kHz. Their products are the sizes of the grid.
    static let melShapes: [(bands: Int, bins: Int)] = [
        (16, 129), (32, 257), (64, 513), (128, 1_025), (128, 2_049), (128, 4_097), (128, 8_193), (256, 8_193), (256, 16_385),
    ]
    static let melSizes = melShapes.map { $0.bands * $0.bins }

    /// One frame through the mel projection: the banded dot products, bound as `crossovers`
    /// binds them, or the dense product.
    static func mel(dense: Bool, crossovers: CrossoverTable) -> CalibrationCandidate {
        CalibrationCandidate(dense ? .accelerate : .native, label: dense ? "Dense product" : "Banded dot products") { size, time in
            guard let shape = melShapes.first(where: { $0.bands * $0.bins == size }),
                  let workload = try? MelProjectionWorkload(bands: shape.bands, binCount: shape.bins, crossovers: crossovers, isDense: dense)
            else { return .nan }
            return time { workload.project() }
        }
    }

    // MARK: The median of a spectrogram

    /// The spectrograms the median is timed on: those of the GPU curve of `Calibration.report()`,
    /// the low-latency kernel of §6.10 over the bins of a 1 024-point transform, and one size
    /// more, past the initial value of the table.
    static let medianKernel = 17
    static let medianRows = 513
    static let medianColumns = [8, 32, 128, 512, 2_048]
    static let medianSizes = medianColumns.map { $0 * medianRows * medianKernel }

    /// The median of a whole spectrogram along time, end to end: on the CPU lanes with the
    /// filter they are made with, or, with a context, on the GPU with both copies (GPU-1).
    static func median(on context: MetalContext?) -> CalibrationCandidate {
        CalibrationCandidate(context == nil ? .native : .metal, label: context == nil ? "CPU lanes" : "Metal") { size, time in
            let columns = Swift.max(size / (medianRows * medianKernel), 1)
            let values = noise(medianRows * columns, seed: 0x9E37_79B9)
            var failed = false
            let elapsed: Double
            if let context {
                let filter = MetalMedianFilter(context: context)
                elapsed = time {
                    if (try? filter.filter(values, rowCount: medianRows, kernel: medianKernel, along: .time)) == nil { failed = true }
                }
            } else {
                elapsed = time {
                    if (try? SelectionNetworkMedian().filter(values, rowCount: medianRows, kernel: medianKernel, along: .time)) == nil { failed = true }
                }
            }
            return failed ? .nan : elapsed
        }
    }
}

/// The two mel projections as the calibration times them (WP-611c): the operations of
/// `BandedMelNode` and of `DenseMelNode` on one frame, without the plan around them. A node
/// writes through a `FrameWriter`, which only a plan can make, so the calibration keeps the
/// two kernels here, storage and loops as the nodes have them.
///
/// Background work: created, used and released by one candidate, on one thread.
final class MelProjectionWorkload {
    let bank: MelFilterBank
    private let isDense: Bool
    private let spectrum: AlignedBuffer<Float>
    private let result: AlignedBuffer<Float>
    /// Dense: the whole bank, band after band.
    private let matrix: AlignedBuffer<Float>
    /// Banded: the runs of weights one after the other, and where each band's run lies.
    private let weights: AlignedBuffer<Float>
    private let offsets: AlignedBuffer<Int32>
    private let firstBins: AlignedBuffer<Int32>
    private let counts: AlignedBuffer<Int32>
    /// The bands in the order they are computed: a scalar loop, the 8-lane loop, vDSP.
    private let order: AlignedBuffer<Int32>
    private let scalarEnd: Int
    private let laneEnd: Int

    init(bands: Int, binCount: Int, crossovers: CrossoverTable, isDense: Bool) throws(DSPError) {
        let bank = try MelFilterBank(bands: bands, binCount: binCount, nyquist: 24_000)
        self.bank = bank
        self.isDense = isDense
        spectrum = try AlignedBuffer<Float>(copying: AnalysisCandidates.noise(binCount, seed: 0x2545_F491))
        result = try AlignedBuffer<Float>(count: bands)
        matrix = try AlignedBuffer<Float>(copying: isDense ? bank.denseWeights() : [])
        let runs = isDense ? [] : bank.bands
        weights = try AlignedBuffer<Float>(copying: runs.flatMap { $0.weights })
        offsets = try AlignedBuffer<Int32>(count: runs.count)
        firstBins = try AlignedBuffer<Int32>(count: runs.count)
        counts = try AlignedBuffer<Int32>(count: runs.count)
        order = try AlignedBuffer<Int32>(count: runs.count)
        var offset = 0
        for (band, run) in runs.enumerated() {
            offsets.baseAddress[band] = Int32(offset)
            firstBins.baseAddress[band] = Int32(run.firstBin)
            counts.baseAddress[band] = Int32(run.weights.count)
            offset += run.weights.count
        }
        // 0: the scalar loop; 1: the 8-lane loop; 2: vDSP.
        var placed = 0
        var ends = (0, 0)
        for kind in 0 ..< 3 {
            for (band, run) in runs.enumerated() {
                let length = run.weights.count
                let own = crossovers.implementation(for: .reduction, size: length) == .accelerate ? 2 : (crossovers.reductionUsesSIMD(count: length) ? 1 : 0)
                if own == kind {
                    order.baseAddress[placed] = Int32(band)
                    placed += 1
                }
            }
            if kind == 0 { ends.0 = placed }
            if kind == 1 { ends.1 = placed }
        }
        scalarEnd = ends.0
        laneEnd = ends.1
    }

    /// The bands of `frame`, a spectrum of the bank's bins, as the projection the workload
    /// was made for computes them: what the workload is held against the nodes with.
    func bands(of frame: [Float]) -> [Float] {
        var bin = 0
        while bin < bank.binCount {
            spectrum.baseAddress[bin] = bin < frame.count ? frame[bin] : 0
            bin += 1
        }
        project()
        return Array(UnsafeBufferPointer(start: result.baseAddress, count: bank.bandCount))
    }

    /// One frame through the projection.
    func project() {
        let frame = UnsafePointer(spectrum.baseAddress), target = result.baseAddress
        if isDense {
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(bank.bandCount), Int32(bank.binCount), 1, matrix.baseAddress, Int32(bank.binCount), frame, 1, 0, target, 1)
            return
        }
        let table = UnsafePointer(weights.baseAddress)
        let bandCount = bank.bandCount
        var position = 0
        while position < scalarEnd {
            let band = Int(order.baseAddress[position])
            target[band] = Vector.Native.dot(table + Int(offsets.baseAddress[band]), frame + Int(firstBins.baseAddress[band]), count: Int(counts.baseAddress[band]))
            position &+= 1
        }
        while position < laneEnd {
            let band = Int(order.baseAddress[position])
            target[band] = Vector.Native.dotSIMD(table + Int(offsets.baseAddress[band]), frame + Int(firstBins.baseAddress[band]), count: Int(counts.baseAddress[band]))
            position &+= 1
        }
        while position < bandCount {
            let band = Int(order.baseAddress[position])
            target[band] = Vector.Accelerated.dot(table + Int(offsets.baseAddress[band]), frame + Int(firstBins.baseAddress[band]), count: Int(counts.baseAddress[band]))
            position &+= 1
        }
    }
}
