import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// Calibration (WP-611a…d, WP-614): the search for a crossover, the stock measurements, the
/// table they give and its export.
@Suite("Calibration")
struct CalibrationTests {
    static let grid = [8, 16, 32, 64, 128, 256, 512, 1_024, 2_048, 4_096]

    /// A candidate whose time is a formula: no clock, no noise.
    private func simulated(_ implementation: Implementation, _ label: String, _ cost: @escaping @Sendable (Int) -> Double) -> CalibrationCandidate {
        CalibrationCandidate(implementation, label: label) { size, _ in cost(size) }
    }

    /// Work that takes time in proportion to `units`, and that no optimiser removes.
    private static func spin(_ units: Int, _ cell: UnsafeMutablePointer<UInt64>) {
        var state = cell.pointee | 1
        var index = 0
        while index < units {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            index += 1
        }
        cell.pointee = state
    }

    private func spinning(_ implementation: Implementation, _ label: String, _ units: @escaping @Sendable (Int) -> Int) -> CalibrationCandidate {
        CalibrationCandidate(implementation, label: label) { size, time in
            let cell = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
            defer { cell.deallocate() }
            cell.initialize(to: 0x9E37_79B9)
            return time { Self.spin(units(size), cell) }
        }
    }

    // MARK: The search (WP-611a)

    /// WP-611a: a synthetic pair with a known crossover is found within one grid step.
    @Test func aSyntheticPairWithAKnownCrossoverIsFoundWithinOneGridStep() throws {
        // lighter(n) = a·n, heavier(n) = b + c·n: they cross at n* = b / (a − c).
        for (a, b, c) in [(3.0, 400.0, 1.0), (1.0, 50.0, 0.5), (2.0, 5_000.0, 0.25), (8.0, 100.0, 7.5), (1.0, 12.0, 0.0)] {
            let truth = b / (a - c)
            let measurement = try Calibration.search(.elementwise, sizes: Self.grid, lighter: simulated(.native, "loop") { a * Double($0) },
                                                     heavier: simulated(.accelerate, "library") { b + c * Double($0) })
            let found = try #require(measurement.crossover, "they cross at \(truth), inside the grid")
            let position = try #require(Self.grid.firstIndex(of: found))
            #expect(Double(found) >= truth, "from \(found) on the heavier one is the faster")
            #expect(position == 0 || Double(Self.grid[position - 1]) < truth, "and not at the grid size below: the crossover \(truth) lies within one step of \(found)")
            #expect(measurement.entry == .elementwise && measurement.sizes == Self.grid && measurement.curves.count == 2)
            #expect(measurement.curves[0].label == "loop" && measurement.curves[0].implementation == .native && measurement.curves[1].implementation == .accelerate)
            #expect(measurement.curves[0].nanoseconds == Self.grid.map { a * Double($0) })
        }
    }

    @Test func aRealPairOfWorkloadsIsFoundThroughTheClock() throws {
        // n units of work against 512 units whatever the size: they cross at 512, between 256
        // and 1 024 on a grid of fourfold steps, where either side leads by a factor of two.
        let measurement = try Calibration.search(
            .gainKernel, sizes: [16, 64, 256, 1_024, 4_096, 16_384], lighter: spinning(.native, "n units") { $0 },
            heavier: spinning(.accelerate, "512 units") { _ in 512 }, samples: 9, sampleDuration: 0.000_5)
        let found = try #require(measurement.crossover)
        print("calibration: a synthetic pair crossing at 512 units was found at \(found); ns per call \(measurement.curves.map { $0.nanoseconds })")
        #expect(found == 1_024, "the first size of the grid past the crossing, one step from it: \(found)")
        #expect(measurement.curves.allSatisfy { curve in curve.nanoseconds.allSatisfy { $0.isFinite && $0 > 0 } })
        // Time grows with the work: the clock measures the body, not itself.
        let lighter = measurement.curves[0].nanoseconds
        #expect(lighter[5] > 100 * lighter[0], "16 384 units take longer than 16: \(lighter)")
    }

    @Test func theCrossoverIsTheSizeFromWhichTheHeavierOneStaysFaster() {
        let sizes = [1, 2, 4, 8, 16]
        #expect(Calibration.crossover(sizes: sizes, lighter: [1, 2, 4, 8, 16], heavier: [5, 5, 5, 5, 5]) == 8)
        #expect(Calibration.crossover(sizes: sizes, lighter: [1, 2, 4, 8, 16], heavier: [9, 9, 9, 9, 99]) == nil, "never faster: no crossover")
        #expect(Calibration.crossover(sizes: sizes, lighter: [9, 9, 9, 9, 9], heavier: [1, 1, 1, 1, 1]) == 1, "always faster: the first size")
        #expect(Calibration.crossover(sizes: sizes, lighter: [1, 2, 4, 8, 16], heavier: [5, 5, 5, 8, 9]) == 16, "a tie is not faster")
        #expect(Calibration.crossover(sizes: sizes, lighter: [1, 2, 4, 8], heavier: [5, 5, 5, 5, 5]) == nil, "curves of another length")
        #expect(Calibration.crossover(sizes: [], lighter: [], heavier: []) == nil)
    }

    /// The stress test of the stability note `Docs/Numerics/crossover-search.md` (§7.5, row
    /// 24): timings disturbed by noise. A crossing that does not last is not the crossover.
    @Test func aDisturbedTimingDoesNotMoveTheCrossover() throws {
        let sizes = Self.grid
        let lighter = sizes.map { 3.0 * Double($0) }, heavier = sizes.map { 400.0 + Double($0) }
        #expect(Calibration.crossover(sizes: sizes, lighter: lighter, heavier: heavier) == 256, "undisturbed")

        // One sample of the lighter implementation hit by something else, at a size where it
        // leads by far: for a moment the heavier one looks faster.
        var disturbed = lighter
        disturbed[1] = 2_000
        #expect(heavier[1] < disturbed[1], "at 16 the heavier one appears to win")
        #expect(Calibration.crossover(sizes: sizes, lighter: disturbed, heavier: heavier) == 256, "it does not stay faster: 16 is not the crossover")

        // Every timing off by up to a tenth, by the white noise of the fixture library (WP-016).
        let noise = try #require(StressFixture.signals(count: 4 * sizes.count).first { $0.name == "white-noise" }).samples
        for round in 0 ..< 2 {
            let noisyLighter = lighter.enumerated().map { $1 * (1 + 0.1 * Double(noise[2 * $0 + round * 2 * sizes.count])) }
            let noisyHeavier = heavier.enumerated().map { $1 * (1 + 0.1 * Double(noise[2 * $0 + 1 + round * 2 * sizes.count])) }
            let found = try #require(Calibration.crossover(sizes: sizes, lighter: noisyLighter, heavier: noisyHeavier))
            #expect(found == 256 || found == 512, "round \(round): within one grid step of the truth, 200: \(found)")
        }
        // Curves that keep crossing: the last crossing counts, the sizes in between stay with the lighter one.
        #expect(Calibration.crossover(sizes: [1, 2, 4, 8, 16, 32], lighter: [1, 5, 1, 5, 1, 5], heavier: [3, 3, 3, 3, 3, 3]) == 32)
    }

    @Test func aGridThatIsNoneIsRefused() {
        let candidate = simulated(.native, "loop") { Double($0) }
        for sizes in [[], [0, 1, 2], [4, 4, 8], [8, 4], [-2, 2]] as [[Int]] {
            #expect(throws: DSPError.self, "\(sizes)") { try Calibration.search(.elementwise, sizes: sizes, lighter: candidate, heavier: candidate) }
        }
    }

    @Test func aCandidateThatCannotBeMeasuredHasNoCurve() throws {
        let fine = simulated(.native, "loop") { Double($0) }
        let broken = simulated(.accelerate, "library") { $0 == 4 ? .nan : 1 }
        let half = try Calibration.search(.laneExchange, sizes: [1, 2, 4, 8], lighter: fine, heavier: broken)
        #expect(half.curves.count == 1 && half.curves[0].label == "loop" && half.crossover == nil)
        let other = try Calibration.search(.laneExchange, sizes: [1, 2, 4, 8], lighter: broken, heavier: fine)
        #expect(other.curves.count == 1 && other.curves[0].label == "loop" && other.crossover == nil)
        let never = try Calibration.search(.laneExchange, sizes: [1, 2], lighter: simulated(.native, "a") { _ in 0 }, heavier: simulated(.native, "b") { _ in -1 })
        #expect(never.curves.isEmpty, "a time is a positive number")
        // One implementation alone is a curve without a crossover.
        let alone = try Calibration.search(.medianGPU, sizes: [10, 20], lighter: fine, heavier: nil)
        #expect(alone.curves.count == 1 && alone.crossover == nil)
    }

    @Test func theTimerRepeatsACallUntilASampleIsLongEnough() {
        var calls = 0
        let quick = CallTimer(samples: 3, sampleNanoseconds: 200_000).nanosecondsPerCall { calls += 1 }
        #expect(calls > 1_000, "an empty call is repeated: \(calls) calls")
        #expect(quick > 0 && quick < 1_000, "\(quick) ns for an empty call")
        var slept = 0
        let slow = CallTimer(samples: 2, sampleNanoseconds: 200_000).nanosecondsPerCall {
            usleep(1_000)
            slept += 1
        }
        #expect(slept <= 4, "a call that outlasts the sample runs once per sample, plus the warm-up: \(slept)")
        #expect(slow >= 900_000 && slow < 100_000_000, "\(slow) ns for a millisecond of sleep")
        // No time to spare at all: one repetition per sample, and still a positive figure.
        var once = 0
        #expect(CallTimer(samples: 1, sampleNanoseconds: 0).nanosecondsPerCall { once += 1 } > 0 && once == 2)
    }

    @Test func aCancelledTaskStopsTheSearchBetweenTwoSizes() async {
        let candidate = simulated(.native, "loop") { Double($0) }
        let task = Task { () async throws -> CrossoverMeasurement in
            try await BackgroundWork.run { checkpoint throws(DSPError) -> CrossoverMeasurement in
                var spins = 0
                while !checkpoint.isCancelled, spins < 2_000 {
                    usleep(1_000)
                    spins += 1
                }
                return try Calibration.search(.elementwise, sizes: [1, 2, 4], lighter: candidate, heavier: candidate, checkpoint: checkpoint)
            }
        }
        task.cancel()
        #expect(await task.result.isCancelled)
    }

    // MARK: The stock measurements (WP-611b, WP-611c, WP-611d)

    @Test func theStockPairsAreThoseOfTheTableThatExistBelowThisTarget() async throws {
        let context = try await sharedContext()
        let pairs = StockCandidates.pairs(context: context)
        #expect(pairs.map { $0.entry } == [.elementwise, .reductionSIMD, .reductionAccelerate, .laneExchange, .gainKernel, .biquadKernel, .firPartitioned, .medianGPU])
        #expect(StockCandidates.pairs(context: nil).map { $0.entry }.last == .firPartitioned, "no device: no GPU curve")
        for pair in pairs {
            #expect(zip(pair.sizes, pair.sizes.dropFirst()).allSatisfy { $0 < $1 } && pair.sizes.count >= 4, "\(pair.entry): an increasing grid")
            #expect((pair.heavier == nil) == (pair.entry == .medianGPU), "\(pair.entry): two sides, the GPU median excepted")
        }
        // The initial crossover of §7.4 lies inside every grid, so a measurement can confirm or move it.
        for pair in pairs where pair.heavier != nil {
            let initial = CrossoverTable.shipped.size(of: pair.entry)
            #expect(pair.sizes.first! <= initial && initial <= pair.sizes.last!, "\(pair.entry): \(initial) in \(pair.sizes)")
        }
        #expect(StockCandidates.octaves(from: 3, through: 30) == [3, 6, 12, 24] && StockCandidates.octaves(from: 8, through: 4).isEmpty)
        // A kernel that could not be made (its constructor returns one without code) is not timed.
        var timed = 0
        #expect(StockCandidates.timeKernel(ztd_kernel_t(), frames: 16) { _ in timed += 1; return 1 }.isNaN && timed == 0)
        #expect(StockCandidates.timeKernel(ztd_kernel_identity(), frames: 16) { body in body(); timed += 1; return 5 } == 5 && timed == 1)
    }

    /// Runs the stock measurements with little effort: enough to see that every workload runs
    /// and is timed, not enough to trust the figures.
    private func quickReport(startingFrom base: CrossoverTable = .shipped) async throws -> CalibrationReport {
        let context = try await sharedContext()
        return try await BackgroundWork.run { checkpoint throws(DSPError) -> CalibrationReport in
            try Calibration.measureStock(startingFrom: base, samples: 1, sampleDuration: 0.000_02, gridLimit: 4, context: context, checkpoint: checkpoint)
        }
    }

    @Test func everyStockWorkloadRunsAndIsTimed() async throws {
        let report = try await quickReport()
        #expect(report.measurements.count == 8)
        for measurement in report.measurements {
            #expect(measurement.sizes.count == 4, "\(measurement.entry): the first four sizes of its grid")
            #expect(measurement.curves.count == (measurement.entry == .medianGPU ? 1 : 2), "\(measurement.entry): every implementation could be measured")
            for curve in measurement.curves {
                #expect(curve.nanoseconds.count == 4 && curve.nanoseconds.allSatisfy { $0.isFinite && $0 > 0 }, "\(measurement.entry), \(curve.label): \(curve.nanoseconds)")
                #expect(!curve.label.isEmpty)
            }
        }
        let labels = Dictionary(uniqueKeysWithValues: report.measurements.map { ($0.entry, $0.curves.map { $0.label }) })
        #expect(labels[.elementwise] == ["Swift loop", "vDSP_vsmul"] && labels[.reductionSIMD] == ["Swift scalar loop", "Swift 8-lane loop"])
        #expect(labels[.reductionAccelerate] == ["Swift 8-lane loop", "vDSP_dotpr"] && labels[.laneExchange] == ["C loop", "vDSP_vmin, vDSP_vmax"])
        #expect(labels[.gainKernel] == ["C loop", "vDSP_vsmul"] && labels[.biquadKernel] == ["C loop", "vDSP_biquad"])
        #expect(labels[.firPartitioned] == ["Direct", "Partitioned"] && labels[.medianGPU] == ["Metal"])
        let kinds = Dictionary(uniqueKeysWithValues: report.measurements.map { ($0.entry, $0.curves.map { $0.implementation }) })
        #expect(kinds[.gainKernel] == [.native, .accelerate] && kinds[.reductionSIMD] == [.native, .native] && kinds[.medianGPU] == [.metal])
    }

    @Test func aMeasuredTableReplacesWhatWasMeasuredAndKeepsTheRest() async throws {
        let base = CrossoverTable(convolutionFFTFactor: 7, melDense: 123, medianGPU: 456, polynomialClosedForm: 2)
        let report = try await quickReport(startingFrom: base)
        for measurement in report.measurements where measurement.curves.count == 2 {
            #expect(report.table.size(of: measurement.entry) == (measurement.crossover ?? Int.max), "\(measurement.entry) is its measured crossover, or never")
        }
        // What has no second implementation below this target keeps the base's value: the mel
        // projection, the cost model of convolution, the closed forms, and the median, whose
        // CPU side is measured elsewhere.
        #expect(report.table.melDense == 123 && report.table.convolutionFFTFactor == 7 && report.table.polynomialClosedForm == 2)
        #expect(report.table.medianGPU == 456, "one curve decides nothing")
        #expect(CalibrationReport(measurements: [], startingFrom: base).table == base)
    }

    /// WP-611b: forced choices honoured, with a table that was measured.
    @Test func forcedChoicesAreHonouredWithAMeasuredTable() async throws {
        let table = try await quickReport().table
        let primitives: [(Primitive, CrossoverEntry)] = [
            (.elementwise, .elementwise), (.reduction, .reductionAccelerate), (.laneExchange, .laneExchange), (.gainKernel, .gainKernel),
            (.biquadKernel, .biquadKernel), (.fir, .firPartitioned),
        ]
        for (primitive, entry) in primitives {
            let crossover = table.size(of: entry)
            for size in [1, 7, 64, 513, 4_096, 100_000] {
                #expect(table.implementation(for: primitive, size: size, requested: .native) == .native, "\(primitive) at \(size): forced native")
                #expect(table.implementation(for: primitive, size: size, requested: .accelerate) == .accelerate, "\(primitive) at \(size): forced Accelerate")
                #expect(table.implementation(for: primitive, size: size) == (size >= crossover ? .accelerate : .native), "\(primitive) at \(size): automatic follows the table")
                // Metal is not an implementation of these: the request falls back to the table.
                #expect(table.implementation(for: primitive, size: size, requested: .metal) == table.implementation(for: primitive, size: size))
            }
        }
        #expect(table.reductionUsesSIMD(count: Int.max) && !table.reductionUsesSIMD(count: 0))
        #expect(table.implementation(for: .median, size: 1, requested: .metal) == .metal, "the median has a Metal implementation")
    }

    @Test func aTableIsAValueWithOneEntryReplaced() {
        let base = CrossoverTable.shipped
        var seen: Set<Int> = []
        for (offset, entry) in CrossoverEntry.allCases.enumerated() {
            let changed = base.replacing(entry, with: 100_000 + offset)
            #expect(changed.size(of: entry) == 100_000 + offset && changed != base, "\(entry)")
            for other in CrossoverEntry.allCases where other != entry {
                #expect(changed.size(of: other) == base.size(of: other), "\(entry) leaves \(other) alone")
            }
            #expect(changed.convolutionFFTFactor == base.convolutionFFTFactor && changed.polynomialClosedForm == base.polynomialClosedForm)
            #expect(!entry.title.isEmpty && !entry.sizeLabel.isEmpty)
            seen.insert(changed.size(of: entry))
        }
        #expect(seen.count == CrossoverEntry.allCases.count && CrossoverEntry.allCases.count == 9)
        #expect(Set(CrossoverEntry.allCases.map { $0.title }).count == 9, "nine titles")
        #expect(base.size(of: .gainKernel) == 512 && base.size(of: .biquadKernel) == 4 && base.size(of: .firPartitioned) == 256, "the initial values of §7.4")
    }

    // MARK: On the device (WP-611d)

    /// A stage of every kernel the table decides between: a gain, a biquad cascade and an FIR.
    struct ChainOfBoundKernels: SequenceStage {
        let taps: [Float]

        func lower(_ context: inout LoweringContext) throws(DSPError) {
            context.emit(.gain(factor: 0.5, ramp: 0))
            context.emit(.biquad(sections: [BiquadSection(b0: 0.2, b1: 0.4, b2: 0.2, a1: -0.3, a2: 0.1)], precision: .single))
            context.emit(.fir(taps: taps, latency: 0))
        }
    }

    /// WP-611d: `Calibration.measure()` on the device, on `BackgroundWork`; a measured table
    /// is a value the engine accepts.
    @Test func theDeviceIsMeasuredInTheBackgroundAndTheEngineAcceptsTheTable() async throws {
        let start = Benchmark.ticks()
        let report = try await Calibration.report()
        let seconds = Benchmark.nanoseconds(Benchmark.ticks() &- start) / 1e9
        print("calibration: Calibration.report() took \(seconds) s")
        for measurement in report.measurements {
            let found = measurement.curves.count < 2 ? "one curve" : (measurement.crossover.map { String($0) } ?? "none on the grid")
            print("calibration: \(measurement.entry.rawValue) sizes \(measurement.sizes) crossover \(found)")
            for curve in measurement.curves { print("calibration:   \(curve.label): \(curve.nanoseconds.map { String(format: "%.1f", $0) }.joined(separator: " ")) ns") }
        }
        #expect(report.measurements.map { $0.entry } == [.elementwise, .reductionSIMD, .reductionAccelerate, .laneExchange, .gainKernel, .biquadKernel, .firPartitioned, .medianGPU])
        #expect(report.measurements.allSatisfy { $0.sizes.count >= 4 }, "the whole grids")
        #expect(report.table.medianGPU == CrossoverTable.shipped.medianGPU && report.table.melDense == CrossoverTable.shipped.melDense)

        // The table alone, and from another base.
        let table = try await Calibration.measure(startingFrom: CrossoverTable(melDense: 77))
        #expect(table.melDense == 77 && table.polynomialClosedForm == 2)

        // The engine takes it, and so does a pipeline: what is computed is the same, because a
        // crossover only chooses between implementations that agree (SEL-6).
        _ = DSPEngine(blockSize: 256, crossovers: report.table)
        let signal = TestSignal.whiteNoise(count: 4_096, seed: 611)
        let pipeline = Pipeline<Samples, Samples>().appending(ChainOfBoundKernels(taps: (0 ..< 300).map { Float(1) / Float(300 + $0) }))
        let format = SignalFormat(sampleRate: 48_000)
        let reference = try pipeline.process(signal, format: format, blockSize: 256)
        let measured = try pipeline.process(signal, format: format, blockSize: 256, crossovers: report.table)
        let allNative = try pipeline.process(signal, format: format, blockSize: 256,
                                             crossovers: CrossoverTable(gainKernel: Int.max, biquadKernel: Int.max, firPartitioned: Int.max))
        let allHeavy = try pipeline.process(signal, format: format, blockSize: 256, crossovers: CrossoverTable(gainKernel: 1, biquadKernel: 1, firPartitioned: 1))
        expectClose(measured, reference, .deviationBelow(decibels: -90), "the measured table")
        expectClose(allNative, reference, .deviationBelow(decibels: -90), "every kernel on its C loop")
        expectClose(allHeavy, reference, .deviationBelow(decibels: -90), "every kernel on vDSP, the FIR partitioned")
        #expect(allNative != allHeavy, "the two tables bound different kernels: they agree to round-off, not bit for bit")
    }

    @Test func aCancelledTaskGetsNoTable() async {
        let task = Task { () async throws -> CrossoverTable in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Calibration.measure()
        }
        #expect(await task.result.isCancelled)
    }

    /// WP-611b…d: measured and recorded. The figures are the host's; a benchmark run in an
    /// optimised build is what the stability note quotes.
    @Test func theMeasurementsOfThisDeviceAreRecorded() async throws {
        let context = try await sharedContext()
        let report = try await BackgroundWork.run { checkpoint throws(DSPError) -> CalibrationReport in
            try Calibration.measureStock(startingFrom: .shipped, samples: Benchmark.isRecording ? 9 : 2, sampleDuration: Benchmark.isRecording ? 0.001 : 0.000_05,
                                         gridLimit: Benchmark.isRecording ? nil : 5, context: context, checkpoint: checkpoint)
        }
        var results: [BenchmarkResult] = []
        for measurement in report.measurements {
            for (index, curve) in measurement.curves.enumerated() {
                for (size, time) in zip(measurement.sizes, curve.nanoseconds) {
                    results.append(BenchmarkResult(name: "calibration.\(measurement.entry.rawValue).\(index + 1).\(size)", iterations: 1, samples: 1,
                                                   minimum: time, median: time, mean: time))
                }
            }
        }
        Benchmark.record(results)
        #expect(results.count >= 7 * 5 * 2 + 4 && results.allSatisfy { $0.minimum > 0 }, "seven pairs and the GPU curve")
        if Benchmark.isRecording {
            // In a benchmark run the device's table is printed, to be committed as shipped values.
            print("calibration (recorded): \(report.table)")
            for measurement in report.measurements {
                print("calibration (recorded): \(measurement.entry.rawValue) \(measurement.sizes) \(measurement.crossover.map { String($0) } ?? "-")")
                for curve in measurement.curves { print("calibration (recorded):   \(curve.label): \(curve.nanoseconds.map { String(format: "%.1f", $0) }.joined(separator: " "))") }
            }
        }
    }

    // MARK: MATLAB export (WP-614)

    /// A report with figures chosen by hand: two pairs and a curve that stands alone.
    static let fixture = CalibrationReport(measurements: [
        CrossoverMeasurement(entry: .gainKernel, sizes: [8, 64, 512], curves: [
            CalibrationCurve(implementation: .native, label: "C loop", nanoseconds: [2.5, 20, 160]),
            CalibrationCurve(implementation: .accelerate, label: "vDSP_vsmul", nanoseconds: [9, 12.25, 40]),
        ]),
        CrossoverMeasurement(entry: .laneExchange, sizes: [8, 4_096], curves: [
            CalibrationCurve(implementation: .native, label: "C loop", nanoseconds: [5.8, 457]),
            CalibrationCurve(implementation: .accelerate, label: "vDSP_vmin, vDSP_vmax", nanoseconds: [12, 978]),
        ]),
        CrossoverMeasurement(entry: .medianGPU, sizes: [69_768, 279_072], curves: [
            CalibrationCurve(implementation: .metal, label: "Metal", nanoseconds: [1_500_000, 0.1 + 0.2]),
        ]),
    ])

    /// The golden script: what the report above exports as, character for character.
    static let golden = """
        % ZTronDSP calibration: time per call against size, one curve per implementation.
        % gainKernel: C loop against vDSP_vsmul, crossover at 64
        sizes_gainKernel = [8 64 512];
        ns_gainKernel_1 = [2.5 20 160];
        ns_gainKernel_2 = [9 12.25 40];
        % laneExchange: C loop against vDSP_vmin, vDSP_vmax, no crossover on the grid
        sizes_laneExchange = [8 4096];
        ns_laneExchange_1 = [5.7999999999999998 457];
        ns_laneExchange_2 = [12 978];
        % medianGPU: Metal, one implementation measured
        sizes_medianGPU = [69768 279072];
        ns_medianGPU_1 = [1500000 0.30000000000000004];
        subplot(2, 2, 1);
        loglog(sizes_gainKernel, ns_gainKernel_1, 'o-');
        hold on;
        loglog(sizes_gainKernel, ns_gainKernel_2, 'x--');
        hold off;
        grid on;
        xlabel('Block size (frames)');
        ylabel('Time per call (ns)');
        title('Gain kernel: C loop (o-), vDSP_vsmul (x--)');
        subplot(2, 2, 2);
        loglog(sizes_laneExchange, ns_laneExchange_1, 'o-');
        hold on;
        loglog(sizes_laneExchange, ns_laneExchange_2, 'x--');
        hold off;
        grid on;
        xlabel('Length (elements)');
        ylabel('Time per call (ns)');
        title('Lane exchange: C loop (o-), vDSP_vmin, vDSP_vmax (x--)');
        subplot(2, 2, 3);
        loglog(sizes_medianGPU, ns_medianGPU_1, 'o-');
        grid on;
        xlabel('Kernel x bins x frames');
        ylabel('Time per call (ns)');
        title('Median of a spectrogram: Metal (o-)');

        """

    @Test func theExportedScriptEqualsTheGoldenScript() async throws {
        let text = try await Self.fixture.matlabScript()
        #expect(text == Self.golden)
        #expect(try Self.fixture.script().text == text, "the same script, built where it is called")
        // What the script reads back as: the table's entries.
        #expect(Self.fixture.table.gainKernel == 64 && Self.fixture.table.laneExchange == Int.max && Self.fixture.table.medianGPU == CrossoverTable.shipped.medianGPU)
    }

    @Test func equalReportsGiveEqualTextAndAReportSurvivesCoding() async throws {
        let first = try await Self.fixture.matlabScript(), second = try await Self.fixture.matlabScript()
        #expect(first == second, "no date, no machine name (MAT-4)")
        // Core MATLAB only (MAT-2): every statement is a comment, an assignment or one of the listed commands.
        let commands = ["subplot(", "loglog(", "hold on;", "hold off;", "grid on;", "xlabel(", "ylabel(", "title("]
        for line in first.split(separator: "\n") {
            #expect(line.hasPrefix("% ") || line.contains(" = [") || commands.contains { line.hasPrefix($0) }, "\(line)")
        }
        let decoded = try JSONDecoder().decode(CalibrationReport.self, from: JSONEncoder().encode(Self.fixture))
        #expect(decoded == Self.fixture && decoded.table == Self.fixture.table)
        #expect(try await decoded.matlabScript() == first)

        // One measurement: one plot. None: only the heading.
        let single = CalibrationReport(measurements: [Self.fixture.measurements[0]])
        #expect(try single.script().lines.contains("subplot(1, 1, 1);"))
        #expect(try CalibrationReport(measurements: []).script().lines.count == 1)
        // More curves than line styles: the styles come round again.
        let many = CrossoverMeasurement(entry: .melDense, sizes: [1, 2], curves: (0 ..< 5).map {
            CalibrationCurve(implementation: .native, label: "curve \($0)", nanoseconds: [1, 2])
        })
        let styled = try CalibrationReport(measurements: [many]).script().lines.filter { $0.hasPrefix("loglog(") }
        #expect(styled.count == 5 && styled[4].hasSuffix("'o-');") && styled[3].hasSuffix("'d-.');"))
    }

    @Test func anExportTooLargeForAScriptIsRefused() async {
        let sizes = Array(1 ... MATLABScript.elementLimit + 1)
        let huge = CalibrationReport(measurements: [CrossoverMeasurement(entry: .elementwise, sizes: sizes, curves: [])])
        await #expect(throws: DSPError.exportTooLarge(elements: sizes.count, limit: MATLABScript.elementLimit)) { try await huge.matlabScript() }
    }
}
