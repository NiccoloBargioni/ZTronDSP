import Dispatch
import Foundation
import ZTronDSPCore

/// One implementation of a primitive, as the calibration harness times it (WP-611a).
///
/// `measure` is called once per size of the grid. It sets its workload up for that size
/// (buffers, a kernel), hands the call to be timed to `time`, which runs it repeatedly and
/// returns the nanoseconds one call takes, and returns that figure after tearing its workload
/// down. What is set up and torn down is not timed.
///
/// ```swift
/// let loop = CalibrationCandidate(.native, label: "Swift loop") { size, time in
///     let values = [Float](repeating: 1, count: size)
///     return values.withUnsafeBufferPointer { buffer in time { sink(mySum(buffer)) } }
/// }
/// ```
///
/// An immutable value, usable on any thread; creating one does not allocate (it keeps the
/// closure it is given), and `measure` runs on the thread `search` is called on, which is
/// background work.
public struct CalibrationCandidate: Sendable {
    /// The kind of implementation: `.native`, `.accelerate` or `.metal`.
    public let implementation: Implementation
    /// What the implementation is, in a few words; it names the curve.
    public let label: String
    let measure: @Sendable (_ size: Int, _ time: (() -> Void) -> Double) -> Double

    /// A candidate of the kind `implementation`, named `label`, timed by `measure`.
    ///
    /// - Parameters:
    ///   - implementation: the kind of implementation: `.native`, `.accelerate` or `.metal`.
    ///   - label: what the implementation is, in a few words; it names the curve.
    ///   - measure: returns the nanoseconds one call takes at `size`; a value that is not a
    ///     positive number says that the implementation could not be measured there.
    public init(
        _ implementation: Implementation, label: String, measure: @escaping @Sendable (_ size: Int, _ time: (() -> Void) -> Double) -> Double
    ) {
        self.implementation = implementation
        self.label = label
        self.measure = measure
    }
}

/// Measures, on the device it runs on, the sizes at which the heavier implementation of a
/// primitive starts to pay (§7.4, SEL-5).
///
/// ```swift
/// let table = try await Calibration.measure()            // about a second, in the background
/// let engine = DSPEngine(crossovers: table)               // the app may also keep it: it is Codable
/// ```
///
/// A wrong crossover costs speed, never correctness: the implementations of one primitive
/// agree bit for bit, or within 10⁻⁶ for reductions (SEL-6).
///
/// Plain functions. `crossover` runs on any thread and does not allocate. `search` blocks the
/// thread it is called on, which is background work, and allocates; so do `measure` and
/// `report`, on the background executor.
public enum Calibration {
    // MARK: The search (WP-611a)

    /// The crossover of two implementations timed over the same grid: the smallest size from
    /// which the heavier one is faster at that size and at every larger size of the grid.
    ///
    /// Requiring it to stay faster is what makes the answer steady: where the two curves cross
    /// more than once, because they are close or because a timing was disturbed, the last
    /// crossing counts, and the lighter implementation keeps the sizes in between.
    ///
    /// - Returns: a size of the grid; `nil` when the heavier implementation is not faster at
    ///   the largest size, and for grids and curves that do not match in length.
    public static func crossover(sizes: [Int], lighter: [Double], heavier: [Double]) -> Int? {
        guard !sizes.isEmpty, lighter.count == sizes.count, heavier.count == sizes.count else { return nil }
        var found: Int?
        var index = sizes.count - 1
        while index >= 0, heavier[index] < lighter[index] {
            found = sizes[index]
            index -= 1
        }
        return found
    }

    /// Times one or two implementations over a grid of sizes and reads their crossover off the
    /// result. At every size the candidates are timed one after the other, so a disturbance of
    /// the machine reaches both.
    ///
    /// - Parameters:
    ///   - entry: the entry of the table the measurement decides.
    ///   - sizes: the grid: positive and strictly increasing.
    ///   - lighter: the implementation that leads at small sizes.
    ///   - heavier: the one that should lead at large sizes; `nil` records the first alone.
    ///   - samples: timed samples per size; the fastest counts, as it is the least disturbed.
    ///   - sampleDuration: how long one sample should last, in seconds: the call is repeated
    ///     until it does.
    ///   - checkpoint: the checkpoint of the background work this call is part of, when it is.
    ///
    /// Blocks for about `2 · sizes · samples · sampleDuration`: background work only.
    ///
    /// - Throws: `invalidParameter` for a grid that is empty, not increasing or not positive;
    ///   `cancelled`.
    public static func search(
        _ entry: CrossoverEntry, sizes: [Int], lighter: CalibrationCandidate, heavier: CalibrationCandidate?, samples: Int = 5,
        sampleDuration: TimeInterval = 0.000_2, checkpoint: BackgroundWork.Checkpoint? = nil
    ) throws(DSPError) -> CrossoverMeasurement {
        guard let first = sizes.first, first >= 1, zip(sizes, sizes.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw .invalidParameter(stage: .none, parameter: "sizes", reason: "a size grid is positive and strictly increasing")
        }
        let timer = CallTimer(samples: max(samples, 1), sampleNanoseconds: max(sampleDuration, 0) * 1e9)
        let candidates = [lighter] + (heavier.map { [$0] } ?? [])
        var times = [[Double]](repeating: [], count: candidates.count)
        for size in sizes {
            for (index, candidate) in candidates.enumerated() {
                try checkpoint?.check()
                times[index].append(candidate.measure(size) { body in timer.nanosecondsPerCall(body) })
            }
        }
        // A candidate that could not be measured somewhere has no curve.
        var curves: [CalibrationCurve] = []
        for (candidate, measured) in zip(candidates, times) where measured.allSatisfy({ $0.isFinite && $0 > 0 }) {
            curves.append(CalibrationCurve(implementation: candidate.implementation, label: candidate.label, nanoseconds: measured))
        }
        return CrossoverMeasurement(entry: entry, sizes: sizes, curves: curves)
    }

    // MARK: The device (WP-611b…d)

    /// Measures the running device and returns its table (SEL-5): `base` with every entry
    /// that has two implementations in the core replaced by its measured crossover.
    ///
    /// What is measured: element-wise operations and reductions of the toolkit, the lane
    /// exchange, the gain and biquad kernels, and the direct against the partitioned FIR.
    /// Entries whose implementations live above the core (the mel projection, the CPU median)
    /// keep the value of `base`.
    ///
    /// Runs on the background executor (BG-1) for about a second; the caller may be on any
    /// thread but the analysis thread, and should not run audio it cares about meanwhile: the
    /// measurement loads a processor core. The table is an immutable value (BG-2).
    ///
    /// - Throws: `cancelled` when the calling task was cancelled (BG-3).
    public static func measure(startingFrom base: CrossoverTable = .shipped) async throws(DSPError) -> CrossoverTable {
        try await report(startingFrom: base).table
    }

    /// The same measurement with the curves the table was read from, for inspection and for
    /// export (§6.14). It adds one curve that decides nothing yet: the GPU median over a grid
    /// of spectrogram sizes, where the device has a GPU.
    ///
    /// Threading and errors as ``measure(startingFrom:)``.
    public static func report(startingFrom base: CrossoverTable = .shipped) async throws(DSPError) -> CalibrationReport {
        try await BackgroundWork.run { checkpoint throws(DSPError) -> CalibrationReport in
            try measureStock(startingFrom: base, samples: 5, sampleDuration: 0.000_2, gridLimit: nil, context: try? MetalContext.sharedBlocking(),
                             checkpoint: checkpoint)
        }
    }

    /// The stock measurements, one after the other.
    ///
    /// - Parameters:
    ///   - gridLimit: when given, only that many sizes of each grid, the smallest: for tests.
    ///   - context: the Metal context for the GPU median; `nil` leaves that curve out.
    static func measureStock(
        startingFrom base: CrossoverTable, samples: Int, sampleDuration: TimeInterval, gridLimit: Int?, context: MetalContext?,
        checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) -> CalibrationReport {
        var measurements: [CrossoverMeasurement] = []
        for pair in StockCandidates.pairs(context: context) {
            let sizes = gridLimit.map { Array(pair.sizes.prefix(max($0, 1))) } ?? pair.sizes
            measurements.append(try search(pair.entry, sizes: sizes, lighter: pair.lighter, heavier: pair.heavier, samples: samples,
                                           sampleDuration: sampleDuration, checkpoint: checkpoint))
        }
        return CalibrationReport(measurements: measurements, startingFrom: base)
    }
}

/// Times one call by repeating it: the number of repetitions grows until a sample lasts long
/// enough to be read off the clock, then the fastest of a few samples counts.
struct CallTimer {
    let samples: Int
    let sampleNanoseconds: Double

    /// The most repetitions a sample is given.
    static let repetitionLimit = 1 << 22

    func nanosecondsPerCall(_ body: () -> Void) -> Double {
        // Once untimed: caches, lazy initialisation.
        body()
        var repetitions = 1
        var elapsed = run(repetitions, body)
        while elapsed < sampleNanoseconds, repetitions < Self.repetitionLimit {
            repetitions = min(repetitions * (elapsed * 8 < sampleNanoseconds ? 8 : 2), Self.repetitionLimit)
            elapsed = run(repetitions, body)
        }
        var fastest = elapsed
        var sample = 1
        while sample < samples {
            fastest = min(fastest, run(repetitions, body))
            sample += 1
        }
        return max(fastest, 1) / Double(repetitions)
    }

    private func run(_ repetitions: Int, _ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        var repetition = 0
        while repetition < repetitions {
            body()
            repetition += 1
        }
        return Double(DispatchTime.now().uptimeNanoseconds &- start)
    }
}
