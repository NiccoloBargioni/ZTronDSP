import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Random frames: magnitudes, or values quantised so that windows hold ties.
func randomFrames(count: Int, bins: Int, seed: UInt64, ties: Bool) -> [[Float]] {
    var generator = SeededGenerator(seed: seed)
    return (0 ..< count).map { _ in
        (0 ..< bins).map { _ in
            let value = generator.nextUnit()
            return ties ? Float(Int(value * 6)) / 4 : Float(value * value * 100)
        }
    }
}

/// Runs frames through a median filter, one by one.
func filtered(_ frames: [[Float]], by filter: any MedianFilter) -> [[Float]] {
    frames.map { frame in
        var medians = [Float](repeating: -1, count: frame.count)
        frame.withUnsafeBufferPointer { source in medians.withUnsafeMutableBufferPointer { filter.process(source.baseAddress!, into: $0.baseAddress!) } }
        return medians
    }
}

/// Bit patterns: two frames are the same frame only when their zeros have the same sign.
func bitPatterns(_ frames: [[Float]]) -> [[UInt32]] {
    frames.map { $0.map { $0.bitPattern } }
}

/// The median kernels of the CPU, time lanes and frequency lanes (WP-529): ≡ the sort-based
/// oracle on random data; allocation-free.
@Suite("Median kernels")
struct MedianKernelTests {
    static let implementations: [Implementation] = [.native, .accelerate]

    // MARK: ≡ oracle on random data (WP-529)

    @Test(arguments: [1, 3, 5, 17, 31, 63])
    func theMedianAlongTimeEqualsTheOracle(kernel: Int) throws {
        var compared = 0
        for bins in [1, 7, 64, 513] {
            for ties in [false, true] {
                let frames = randomFrames(count: kernel + 40, bins: bins, seed: UInt64(kernel * 1_000 + bins), ties: ties)
                let expected = MedianOracle.running(frames, kernel: kernel)
                for implementation in Self.implementations {
                    let filter = try TimeLaneMedian(kernel: kernel, binCount: bins, implementation: implementation)
                    #expect(filtered(frames, by: filter) == expected, "kernel \(kernel), \(bins) bins\(ties ? ", with ties" : ""), \(implementation)")
                    compared += frames.count * bins
                }
            }
        }
        print("measured WP-529: time lanes, kernel \(kernel): \(compared) medians equal the sort-based oracle exactly")
    }

    @Test(arguments: [1, 3, 5, 17, 31, 63])
    func theMedianAlongFrequencyEqualsTheOracle(kernel: Int) throws {
        var compared = 0
        // 5 and 7 bins are fewer than most kernels: the frame is reflected more than once.
        for bins in [1, 5, 7, 64, 513, 1_025] {
            for ties in [false, true] {
                let frames = randomFrames(count: 6, bins: bins, seed: UInt64(kernel * 77 + bins), ties: ties)
                let expected = MedianOracle.filter(frames.flatMap { $0 }, rowCount: bins, kernel: kernel, along: .frequency)
                for implementation in Self.implementations {
                    let filter = try FrequencyLaneMedian(kernel: kernel, binCount: bins, implementation: implementation)
                    #expect(filtered(frames, by: filter).flatMap { $0 } == expected, "kernel \(kernel), \(bins) bins\(ties ? ", with ties" : ""), \(implementation)")
                    compared += frames.count * bins
                }
            }
        }
        print("measured WP-529: frequency lanes, kernel \(kernel): \(compared) medians equal the sort-based oracle exactly")
    }

    @Test func aWholeSpectrogramOnCPULanesEqualsTheOracle() throws {
        for (rows, columns) in [(33, 20), (64, 7), (1, 9), (5, 1), (257, 40), (2, 2)] {
            for kernel in [1, 3, 5, 17, 31] {
                for ties in [false, true] {
                    let input = randomFrames(count: columns, bins: rows, seed: UInt64(rows * 1_000 + columns * 10 + kernel), ties: ties).flatMap { $0 }
                    for (axis, oracleAxis) in [(MedianAxis.time, MedianOracle.Axis.time), (.frequency, .frequency)] {
                        let output = try SelectionNetworkMedian().filter(input, rowCount: rows, kernel: kernel, along: axis)
                        #expect(output == MedianOracle.filter(input, rowCount: rows, kernel: kernel, along: oracleAxis),
                                "\(rows) × \(columns), kernel \(kernel) along \(axis)\(ties ? ", with ties" : "")")
                    }
                }
            }
        }
        // The largest network, wider than the spectrogram on both axes.
        let small = randomFrames(count: 9, bins: 11, seed: 255, ties: false).flatMap { $0 }
        #expect(try SelectionNetworkMedian().filter(small, rowCount: 11, kernel: 255, along: .time) == MedianOracle.filter(small, rowCount: 11, kernel: 255, along: .time))
        #expect(try SelectionNetworkMedian().filter(small, rowCount: 11, kernel: 255, along: .frequency) == MedianOracle.filter(small, rowCount: 11, kernel: 255, along: .frequency))
        #expect(try SelectionNetworkMedian().filter([], rowCount: 4, kernel: 3, along: .time).isEmpty)
    }

    // MARK: The contract of a filter

    @Test func aFilterAlongTimeIsTheCentredMedianHalfAKernelLate() throws {
        // What the centred mode of the separation and the offline filter rest on.
        let frames = randomFrames(count: 60, bins: 33, seed: 31, ties: true)
        for kernel in [3, 17, 31] {
            let reach = kernel / 2
            let running = filtered(frames, by: try TimeLaneMedian(kernel: kernel, binCount: 33))
            let centred = MedianOracle.filter(frames.flatMap { $0 }, rowCount: 33, kernel: kernel, along: .time)
            for frame in reach ..< 60 {
                #expect(running[frame] == Array(centred[(frame - reach) * 33 ..< (frame - reach + 1) * 33]), "kernel \(kernel), frame \(frame): the left edge included")
            }
        }
    }

    @Test func aFilterMayWriteWhereItRead() throws {
        let frames = randomFrames(count: 12, bins: 20, seed: 4, ties: false)
        for (filter, expected) in [
            (try TimeLaneMedian(kernel: 5, binCount: 20) as any MedianFilter, MedianOracle.running(frames, kernel: 5)),
            (try FrequencyLaneMedian(kernel: 5, binCount: 20) as any MedianFilter,
             frames.map { MedianOracle.filter($0, rowCount: 20, kernel: 5, along: .frequency) }),
        ] {
            let inPlace = frames.map { frame -> [Float] in
                var buffer = frame
                buffer.withUnsafeMutableBufferPointer { filter.process(UnsafePointer($0.baseAddress!), into: $0.baseAddress!) }
                return buffer
            }
            #expect(inPlace == expected)
        }
    }

    @Test func aResetIsAColdStart() throws {
        let frames = randomFrames(count: 30, bins: 9, seed: 12, ties: false)
        let filter = try TimeLaneMedian(kernel: 7, binCount: 9)
        let first = filtered(frames, by: filter)
        let warm = filtered(frames, by: filter)
        filter.reset()
        let cold = filtered(frames, by: filter)
        #expect(cold == first, "after a reset the filter gives what a fresh one gives (ACT-10)")
        #expect(warm != first && Array(warm[6...]) == Array(first[6...]), "without one its first frames rest on the frames of before")
        // Along frequency there is nothing to forget.
        let across = try FrequencyLaneMedian(kernel: 7, binCount: 9)
        let before = filtered(frames, by: across)
        across.reset()
        #expect(filtered(frames, by: across) == before)
    }

    // MARK: The implementation is bound when the filter is made (SEL-3)

    @Test func theLaneExchangeFollowsTheTableAndAForcedChoice() throws {
        // The shipped crossover of the lane exchange is 1 024 values per lane.
        #expect(try LaneMedianNetwork(kernel: 5, length: 513).implementation == .native)
        #expect(try LaneMedianNetwork(kernel: 5, length: 1_025).implementation == .accelerate)
        #expect(try LaneMedianNetwork(kernel: 5, length: 513, crossovers: CrossoverTable(laneExchange: 64)).implementation == .accelerate)
        #expect(try LaneMedianNetwork(kernel: 5, length: 4_096, implementation: .native).implementation == .native)
        #expect(try LaneMedianNetwork(kernel: 5, length: 8, implementation: .accelerate).implementation == .accelerate)
        #expect(try LaneMedianNetwork(kernel: 5, length: 8, implementation: .metal).implementation == .native, "there is no lane exchange on the GPU: automatic")
        let network = try LaneMedianNetwork(kernel: 3, length: 4)
        #expect(network.kernel == 3 && network.length == 4)
        // Three lanes by hand: the median of each position lands on the middle lane.
        for (lane, values) in [[5, 1, 9, 2], [3, 3, 0, 8], [4, 2, 7, 5]].enumerated() {
            for (index, value) in values.enumerated() { network.lane(lane)[index] = Float(value) }
        }
        #expect(Array(UnsafeBufferPointer(start: network.medians(), count: 4)) == [4, 2, 7, 5])
        for (kernel, length) in [(0, 8), (4, 8), (257, 8), (-1, 8), (3, 0), (3, 1 << 25)] {
            #expect(throws: DSPError.self, "\(kernel), \(length)") { _ = try LaneMedianNetwork(kernel: kernel, length: length) }
        }
        #expect(throws: DSPError.self) { _ = try TimeLaneMedian(kernel: 2, binCount: 8) }
        #expect(throws: DSPError.self) { _ = try FrequencyLaneMedian(kernel: 3, binCount: 0) }
    }

    // MARK: The real-time audit (RT-7)

    @Test func theKernelsRunWithoutAllocating() throws {
        let bins = 1_025
        let frames = randomFrames(count: 8, bins: bins, seed: 7, ties: false)
        let input = try AlignedBuffer<Float>(copying: frames.flatMap { $0 })
        let output = try AlignedBuffer<Float>(count: bins)
        for implementation in Self.implementations {
            let filters: [any MedianFilter] = [
                try TimeLaneMedian(kernel: 31, binCount: bins, implementation: implementation), try FrequencyLaneMedian(kernel: 31, binCount: bins, implementation: implementation),
                try TimeLaneMedian(kernel: 17, binCount: bins, implementation: implementation), try FrequencyLaneMedian(kernel: 17, binCount: bins, implementation: implementation),
            ]
            var index = 0
            while index < filters.count {
                let filter = filters[index]
                // Once outside the audit: the first call may instantiate metadata.
                filter.process(UnsafePointer(input.baseAddress), into: output.baseAddress)
                _ = expectNoAllocations("\(type(of: filter)), \(implementation)") {
                    var frame = 0
                    while frame < 1_000 {
                        filter.process(UnsafePointer(input.baseAddress + (frame & 7) &* bins), into: output.baseAddress)
                        if frame == 500 { filter.reset() }
                        frame += 1
                    }
                }
                index += 1
            }
        }
        #expect(output.baseAddress[0].isFinite)
    }
}
