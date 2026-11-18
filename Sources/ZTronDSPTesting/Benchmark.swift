import Darwin
import Foundation

/// One measured workload: nanoseconds per iteration over a number of samples.
public struct BenchmarkResult: Codable, Sendable, Equatable {
    public let name: String
    /// Calls of the workload per sample.
    public let iterations: Int
    /// Timed samples (warm-up excluded).
    public let samples: Int
    /// Nanoseconds per iteration. The minimum is the figure a regression check compares: it
    /// is the least disturbed by whatever else the machine was doing.
    public let minimum: Double
    public let median: Double
    public let mean: Double

    public init(name: String, iterations: Int, samples: Int, minimum: Double, median: Double, mean: Double) {
        self.name = name
        self.iterations = iterations
        self.samples = samples
        self.minimum = minimum
        self.median = median
        self.mean = mean
    }
}

/// A workload that got slower than its baseline allows.
public struct BenchmarkRegression: Sendable, Equatable, CustomStringConvertible {
    public let name: String
    public let baseline: Double
    public let measured: Double
    /// `measured / baseline`.
    public var ratio: Double { measured / baseline }

    public var description: String {
        String(format: "%@: %.1f ns against a baseline of %.1f ns (×%.3f)", name, measured, baseline, ratio)
    }
}

/// A set of results, as it is written to disk and committed as a baseline.
public struct BenchmarkReport: Codable, Sendable, Equatable {
    public let results: [BenchmarkResult]

    public init(results: [BenchmarkResult]) {
        self.results = results.sorted { $0.name < $1.name }
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(BenchmarkReport.self, from: data)
    }

    /// Stable JSON: sorted keys, sorted results, so a baseline diffs cleanly.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The workloads whose minimum grew by more than `fraction` over the baseline's
    /// (PERF-1, §10.1: a regression above 10 % fails).
    public func regressions(against baseline: BenchmarkReport, allowing fraction: Double = 0.10) -> [BenchmarkRegression] {
        let reference = Dictionary(baseline.results.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return results.compactMap { result in
            guard let base = reference[result.name], base.minimum > 0,
                  result.minimum > base.minimum * (1 + fraction)
            else { return nil }
            return BenchmarkRegression(name: result.name, baseline: base.minimum, measured: result.minimum)
        }
    }

    /// Baseline workloads this report did not measure. A check treats them as failures, so a
    /// benchmark cannot leave the gate by being deleted.
    public func missing(from baseline: BenchmarkReport) -> [String] {
        let measured = Set(results.map(\.name))
        return baseline.results.map(\.name).filter { !measured.contains($0) }
    }
}

/// The benchmark harness (WP-006): warm-up, repeated samples, `mach_absolute_time`.
public enum Benchmark {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// The monotonic tick counter the harness times with.
    @inlinable
    public static func ticks() -> UInt64 { mach_absolute_time() }

    /// Converts a tick count to nanoseconds.
    public static func nanoseconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }

    /// Keeps a value alive and opaque to the optimiser, so the work that produced it is not
    /// removed.
    @inline(never)
    public static func blackHole<T>(_ value: T) {
        withExtendedLifetime(value) {}
    }

    /// Times `body`.
    ///
    /// - Parameters:
    ///   - warmUp: untimed samples run first, so caches and branch predictors are settled.
    ///   - samples: timed samples; each runs `body` `iterations` times.
    ///   - iterations: calls per sample; choose it so one sample lasts well above the timer's resolution.
    public static func measure(
        _ name: String, warmUp: Int = 3, samples: Int = 21, iterations: Int = 1_000, _ body: () -> Void
    ) -> BenchmarkResult {
        let iterations = max(1, iterations)
        let samples = max(1, samples)
        for _ in 0 ..< max(0, warmUp) {
            for _ in 0 ..< iterations { body() }
        }
        var timings = [Double](repeating: 0, count: samples)
        for sample in 0 ..< samples {
            let start = ticks()
            for _ in 0 ..< iterations { body() }
            let end = ticks()
            timings[sample] = nanoseconds(end &- start) / Double(iterations)
        }
        timings.sort()
        let median = samples % 2 == 1 ? timings[samples / 2] : 0.5 * (timings[samples / 2 - 1] + timings[samples / 2])
        return BenchmarkResult(
            name: name, iterations: iterations, samples: samples, minimum: timings[0], median: median,
            mean: timings.reduce(0, +) / Double(samples))
    }

    /// True when this run records benchmarks: the environment variable `ZTD_BENCHMARK_OUTPUT`
    /// names a report. A test that holds a timing against a budget asserts only then, and in
    /// an optimised build: a timing taken while other tests run beside it says nothing.
    public static var isRecording: Bool {
        !(ProcessInfo.processInfo.environment["ZTD_BENCHMARK_OUTPUT"] ?? "").isEmpty
    }

    /// Appends results to the report at the path named by the environment variable
    /// `ZTD_BENCHMARK_OUTPUT`, when it is set (pass it to a simulator test run as
    /// `TEST_RUNNER_ZTD_BENCHMARK_OUTPUT`). Returns whether anything was written. Tests that
    /// record a benchmark call this; the regression gate compares the file with its baseline.
    @discardableResult
    public static func record(_ results: [BenchmarkResult]) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["ZTD_BENCHMARK_OUTPUT"], !path.isEmpty else { return false }
        return recordLock.withLock {
            let url = URL(fileURLWithPath: path)
            var merged: [String: BenchmarkResult] = [:]
            if let data = try? Data(contentsOf: url), let existing = try? BenchmarkReport(data: data) {
                for result in existing.results { merged[result.name] = result }
            }
            for result in results { merged[result.name] = result }
            guard let data = try? BenchmarkReport(results: Array(merged.values)).encoded() else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }
    }

    private static let recordLock = NSLock()
}
