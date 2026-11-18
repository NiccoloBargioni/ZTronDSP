import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// The median of a whole spectrogram on the GPU (WP-610): the selection network per element,
/// against a sort-based oracle.
@Suite("Median on the GPU")
struct MetalMedianFilterTests {
    /// The oracle: for every element, the values around it are laid out, sorted, and the
    /// middle one taken. Edges are reflected with the edge value repeated (§6.1), written here
    /// as a sequence that is its own mirror image, laid end to end: d c b a | a b c d | d c b a.
    static func oracle(_ values: [Float], rowCount: Int, kernel: Int, along axis: MetalMedianFilter.Axis, only sample: Int = 1) -> [Float] {
        let columnCount = values.count / rowCount
        let reach = kernel / 2
        func line(_ fixed: Int) -> [Float] {
            axis == .time ? (0 ..< columnCount).map { values[$0 * rowCount + fixed] } : Array(values[fixed * rowCount ..< (fixed + 1) * rowCount])
        }
        /// `line` with `reach` values before its first and after its last, mirrored.
        func padded(_ line: [Float]) -> [Float] {
            var before: [Float] = [], after: [Float] = []
            var forwards = false
            while before.count < reach {
                before = (forwards ? line : line.reversed()) + before
                after += forwards ? line : line.reversed()
                forwards.toggle()
            }
            return Array(before.suffix(reach)) + line + Array(after.prefix(reach))
        }
        var result = values
        let lines = axis == .time ? rowCount : columnCount
        for fixed in 0 ..< lines {
            let extended = padded(line(fixed))
            let length = axis == .time ? columnCount : rowCount
            for position in stride(from: (fixed * 31) % sample, to: length, by: sample) {
                let middle = extended[position ..< position + kernel].sorted()[reach]
                result[axis == .time ? position * rowCount + fixed : fixed * rowCount + position] = middle
            }
        }
        return result
    }

    /// A random spectrogram: magnitudes, some rounds quantised so that windows hold ties.
    private func spectrogram(rows: Int, columns: Int, seed: UInt64, ties: Bool) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< rows * columns).map { _ in
            let value = generator.nextUnit()
            return ties ? Float(Int(value * 6)) / 4 : Float(value * value * 100)
        }
    }

    private func filter() async throws -> MetalMedianFilter {
        MetalMedianFilter(context: try await sharedContext())
    }

    @Test func theMedianEqualsTheSortBasedOracleOnRandomSpectrograms() async throws {
        let median = try await filter()
        var compared = 0
        for (rows, columns) in [(33, 20), (64, 7), (1, 9), (5, 1), (257, 40), (2, 2)] {
            for kernel in [1, 3, 5, 17, 31] {
                for axis in [MetalMedianFilter.Axis.time, .frequency] {
                    for ties in [false, true] {
                        let input = spectrogram(rows: rows, columns: columns, seed: UInt64(rows * 1_000 + columns * 10 + kernel), ties: ties)
                        let output = try median.filter(input, rowCount: rows, kernel: kernel, along: axis)
                        let expected = Self.oracle(input, rowCount: rows, kernel: kernel, along: axis)
                        #expect(output == expected, "\(rows) × \(columns), kernel \(kernel) along \(axis)\(ties ? ", with ties" : "")")
                        compared += output.count
                    }
                }
            }
        }
        print("GPU median: \(compared) elements equal the sort-based oracle exactly")
    }

    @Test func theDefaultKernelsOfTheSeparationAreExact() async throws {
        // §6.10: 31 frames along time for the harmonic part, 31 bins along frequency for the percussive one.
        let median = try await filter()
        let rows = 513, columns = 64
        let input = spectrogram(rows: rows, columns: columns, seed: 610, ties: false)
        let harmonic = try median.filter(input, rowCount: rows, kernel: 31, along: .time)
        let percussive = try median.filter(input, rowCount: rows, kernel: 31, along: .frequency)
        #expect(harmonic == Self.oracle(input, rowCount: rows, kernel: 31, along: .time))
        #expect(percussive == Self.oracle(input, rowCount: rows, kernel: 31, along: .frequency))
        #expect(harmonic != percussive)
        // Every output is one of the inputs: comparisons only.
        let present = Set(input)
        #expect(harmonic.allSatisfy { present.contains($0) } && percussive.allSatisfy { present.contains($0) })
    }

    @Test func theLargestKernelIsExact() async throws {
        let median = try await filter()
        let rows = 12, columns = 300
        let input = spectrogram(rows: rows, columns: columns, seed: 255, ties: false)
        let output = try median.filter(input, rowCount: rows, kernel: MedianNetwork.maximumCount, along: .time)
        #expect(output == Self.oracle(input, rowCount: rows, kernel: 255, along: .time), "255 lanes, the largest network")
        // Wider than the spectrogram: the reflection wraps more than once.
        let narrow = spectrogram(rows: 4, columns: 9, seed: 9, ties: false)
        #expect(try median.filter(narrow, rowCount: 4, kernel: 255, along: .time) == Self.oracle(narrow, rowCount: 4, kernel: 255, along: .time))
        #expect(try median.filter(narrow, rowCount: 4, kernel: 255, along: .frequency) == Self.oracle(narrow, rowCount: 4, kernel: 255, along: .frequency))
    }

    @Test func aSpectrogramLargerThanOneDispatchIsCutIntoRunsOfColumns() async throws {
        let median = try await filter()
        let rows = 2_049, columns = 600
        #expect(rows * columns > MetalMedianFilter.elementsPerDispatch, "more than one dispatch")
        let input = spectrogram(rows: rows, columns: columns, seed: 1, ties: false)
        for axis in [MetalMedianFilter.Axis.time, .frequency] {
            let output = try median.filter(input, rowCount: rows, kernel: 5, along: axis)
            // The oracle on every 53rd element of every line; the rest is left as the input there.
            let expected = Self.oracle(input, rowCount: rows, kernel: 5, along: axis, only: 53)
            var checked = 0, wrong = 0
            for index in 0 ..< input.count where expected[index] != input[index] || output[index] == input[index] {
                checked += 1
                if output[index] != expected[index] { wrong += 1 }
            }
            #expect(wrong == 0 && checked > input.count / 60, "along \(axis): \(wrong) of \(checked) sampled elements differ")
            // The seam between two dispatches is like any other column.
            let seam = MetalMedianFilter.elementsPerDispatch / rows
            let around = (seam - 3 ..< seam + 3).flatMap { column in (0 ..< 40).map { column * rows + $0 * 51 } }
            let exact = Self.oracle(input, rowCount: rows, kernel: 5, along: axis)
            #expect(around.allSatisfy { output[$0] == exact[$0] }, "along \(axis): the columns around the seam")
        }
    }

    /// The stress test of the stability note `Docs/Numerics/median-metal.md` (§7.5, row 16):
    /// ties and the smallest magnitudes. Columns of the fixture library's signals (WP-016):
    /// silence, a square wave, a constant, a tail that decays through the subnormal range.
    @Test func tiesAndSubnormalValuesAreTheOraclesToo() async throws {
        let median = try await filter()
        let rows = 96
        let signals = StressFixture.signals(count: rows).filter { ["silence", "full-scale-square", "dc", "decaying-tail", "denormal", "impulse", "nyquist"].contains($0.name) }
        #expect(signals.count == 7)
        let input = signals.flatMap { $0.samples.map { abs($0) } } + signals.flatMap { $0.samples }
        let columns = input.count / rows
        for kernel in [3, 17, 31] {
            for axis in [MetalMedianFilter.Axis.time, .frequency] {
                let output = try median.filter(input, rowCount: rows, kernel: kernel, along: axis)
                let expected = Self.oracle(input, rowCount: rows, kernel: kernel, along: axis)
                // Equal as numbers: among equal values it does not matter which one is taken.
                #expect(output == expected, "kernel \(kernel) along \(axis)")
                #expect(output.allSatisfy { $0.isFinite })
                // A median of subnormal values is one of them, not zero.
                let subnormal = expected.indices.filter { expected[$0] != 0 && abs(expected[$0]) < Float.leastNormalMagnitude }
                #expect(!subnormal.isEmpty && subnormal.allSatisfy { output[$0].bitPattern == expected[$0].bitPattern },
                        "kernel \(kernel) along \(axis): \(subnormal.count) subnormal medians")
            }
        }
        #expect(columns == 14)
        // A constant column of a subnormal value comes back bit for bit.
        let tiny = Float.leastNonzeroMagnitude * 64
        let constant = [Float](repeating: tiny, count: rows * 4)
        let kept = try median.filter(constant, rowCount: rows, kernel: 17, along: .frequency)
        #expect(kept.allSatisfy { $0.bitPattern == tiny.bitPattern }, "a subnormal value is not flushed to zero")

        // The order is the minimum and maximum of IEEE 754-2019, as on the CPU lanes: -0 below +0.
        let zeros: [Float] = [-0.0, 0.0, 0.0, /* next column */ -0.0, -0.0, 0.0, /* next */ -1, -0.0, 0.0, /* next */ 0.0, -0.0, -3]
        let signed = try median.filter(zeros, rowCount: 3, kernel: 3, along: .frequency)
        #expect(signed[1].bitPattern == Float(0.0).bitPattern, "of -0, +0, +0 the median is +0")
        #expect(signed[4].bitPattern == Float(-0.0).bitPattern, "of -0, -0, +0 the median is -0")
        #expect(signed[7].bitPattern == Float(-0.0).bitPattern && signed[10].bitPattern == Float(-0.0).bitPattern, "between a negative value and +0 lies -0")
        // Negative values order as numbers.
        let negative: [Float] = [-5, -1, -3, -2, -4, 0, 7, -6, 6]
        #expect(try median.filter(negative, rowCount: 9, kernel: 9, along: .frequency)[4] == -2, "the middle of nine values of both signs")
    }

    @Test func theNetworkOnTheGPUIsTheNetworkOfTheCore() async throws {
        // One element: its window through the core's network on the CPU, and on the GPU.
        let median = try await filter()
        for kernel in [3, 9, 31, 63] {
            let network = try MedianNetwork(count: kernel)
            let window = spectrogram(rows: kernel, columns: 1, seed: UInt64(kernel), ties: kernel == 9)
            var lanes = window
            let expected = network.median(of: &lanes)
            // The centre row of a column that is exactly the window.
            let output = try median.filter(window, rowCount: kernel, kernel: kernel, along: .frequency)
            #expect(output[kernel / 2] == expected, "kernel \(kernel)")
        }
    }

    @Test func whatIsNoSpectrogramIsRefused() async throws {
        let median = try await filter()
        #expect(try median.filter([], rowCount: 4, kernel: 3, along: .time).isEmpty, "nothing in, nothing out")
        #expect(throws: DSPError.self) { try median.filter([1, 2, 3], rowCount: 2, kernel: 3, along: .time) }
        #expect(throws: DSPError.self) { try median.filter([1, 2, 3], rowCount: 0, kernel: 3, along: .time) }
        #expect(throws: DSPError.self) { try median.filter([1, 2, 3, 4], rowCount: 2, kernel: 4, along: .time) }
        #expect(throws: DSPError.self) { try median.filter([1, 2, 3, 4], rowCount: 2, kernel: 257, along: .frequency) }
        #expect(throws: DSPError.self) { try median.filter([1, 2, 3, 4], rowCount: 2, kernel: 0, along: .frequency) }
        // A kernel of one is the identity.
        #expect(try median.filter([4, 1, 3, 2], rowCount: 2, kernel: 1, along: .time) == [4, 1, 3, 2])
        #expect(MemoryLayout<MedianUniforms>.stride == 32, "eight unsigned integers, as the kernel declares")
    }

    @Test func aCancelledTaskStopsTheFilterBetweenTwoRuns() async throws {
        let median = try await filter()
        let input = spectrogram(rows: 16, columns: 16, seed: 3, ties: false)
        let task = Task { () async throws -> [Float] in
            try await BackgroundWork.run { checkpoint throws(DSPError) -> [Float] in
                var spins = 0
                while !checkpoint.isCancelled, spins < 2_000 {
                    usleep(1_000)
                    spins += 1
                }
                return try median.filter(input, rowCount: 16, kernel: 3, along: .time, checkpoint: checkpoint)
            }
        }
        task.cancel()
        #expect(await task.result.isCancelled)
        // With a checkpoint that is not cancelled the filter runs through, off the main thread.
        let output = try await BackgroundWork.run { checkpoint throws(DSPError) -> [Float] in
            try median.filter(input, rowCount: 16, kernel: 3, along: .time, checkpoint: checkpoint)
        }
        #expect(output == Self.oracle(input, rowCount: 16, kernel: 3, along: .time))
    }
}
