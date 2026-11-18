import Foundation
import Testing
import ZTronDSPTesting

@Suite("Benchmark harness")
struct BenchmarkTests {
    @Test func aSyntheticWorkloadIsTimed() {
        var accumulator: UInt64 = 1
        let result = Benchmark.measure("synthetic", warmUp: 1, samples: 5, iterations: 200) {
            for step in 0 ..< 200 { accumulator = accumulator &* 6_364_136_223_846_793_005 &+ UInt64(step) }
            Benchmark.blackHole(accumulator)
        }
        #expect(result.name == "synthetic")
        #expect(result.samples == 5)
        #expect(result.iterations == 200)
        #expect(result.minimum > 0)
        #expect(result.minimum <= result.median)
        #expect(result.minimum <= result.mean)
    }

    @Test func aHeavierWorkloadTakesLonger() {
        func workload(_ steps: Int) -> BenchmarkResult {
            Benchmark.measure("steps-\(steps)", warmUp: 1, samples: 7, iterations: 50) {
                var value = 1.0
                for step in 0 ..< steps { value = (value + Double(step)).squareRoot() }
                Benchmark.blackHole(value)
            }
        }
        #expect(workload(4_000).minimum > 3 * workload(400).minimum)
    }

    @Test func degenerateArgumentsAreClamped() {
        let result = Benchmark.measure("clamped", warmUp: -1, samples: 0, iterations: 0) {}
        #expect(result.samples == 1)
        #expect(result.iterations == 1)
        let even = Benchmark.measure("even", warmUp: 0, samples: 4, iterations: 10) {}
        #expect(even.median >= even.minimum)
    }

    @Test func ticksConvertToNanoseconds() {
        let start = Benchmark.ticks()
        // Wait for the counter to move: an optimiser cannot remove a loop on a clock.
        var later = Benchmark.ticks()
        var spins = 0
        while later == start && spins < 100_000_000 {
            later = Benchmark.ticks()
            spins += 1
        }
        let elapsed = Benchmark.nanoseconds(later &- start)
        #expect(later > start, "the counter is monotonic and it moves")
        #expect(elapsed > 0)
        #expect(elapsed < 5e9)
        #expect(Benchmark.nanoseconds(0) == 0)
    }

    private func result(_ name: String, _ minimum: Double) -> BenchmarkResult {
        BenchmarkResult(name: name, iterations: 1_000, samples: 21, minimum: minimum, median: minimum * 1.05, mean: minimum * 1.1)
    }

    @Test func aSeededRegressionIsDetected() {
        let baseline = BenchmarkReport(results: [result("gain", 100), result("biquad", 400), result("fir", 900)])
        let measured = BenchmarkReport(results: [result("gain", 109), result("biquad", 445), result("fir", 880)])
        let regressions = measured.regressions(against: baseline)
        #expect(regressions.map(\.name) == ["biquad"], "9 % is within the allowance, 11.25 % is not, faster is fine")
        #expect(regressions.first?.ratio == 445.0 / 400.0)
        #expect(regressions.first?.description.contains("biquad") == true)
        #expect(measured.regressions(against: baseline, allowing: 0.20).isEmpty)
        #expect(measured.regressions(against: baseline, allowing: 0.05).map(\.name) == ["biquad", "gain"])
    }

    @Test func aBenchmarkCannotLeaveTheGateByBeingDeleted() {
        let baseline = BenchmarkReport(results: [result("gain", 100), result("biquad", 400)])
        let measured = BenchmarkReport(results: [result("gain", 100), result("new", 5)])
        #expect(measured.missing(from: baseline) == ["biquad"])
        #expect(measured.regressions(against: baseline).isEmpty, "a workload without a baseline is not a regression")
    }

    @Test func reportsRoundTripAsStableJSON() throws {
        let report = BenchmarkReport(results: [result("b", 2), result("a", 1)])
        #expect(report.results.map(\.name) == ["a", "b"], "results are kept sorted")
        let data = try report.encoded()
        #expect(try BenchmarkReport(data: data) == report)
        #expect(try report.encoded() == data, "encoding is deterministic")
        #expect(throws: (any Error).self) { try BenchmarkReport(data: Data("{}".utf8)) }
    }

    @Test func recordingIsOffUnlessAnOutputIsNamed() {
        // The test run does not set ZTD_BENCHMARK_OUTPUT unless the benchmark gate is running.
        let wrote = Benchmark.record([result("unit", 1)])
        #expect(wrote == (ProcessInfo.processInfo.environment["ZTD_BENCHMARK_OUTPUT"]?.isEmpty == false))
    }
}
