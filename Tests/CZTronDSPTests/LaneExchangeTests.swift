import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// The exchange of one pair by the rule both implementations follow, the minimum and maximum of
/// IEEE 754-2019: a NaN in either lane makes both NaN; −0 orders below +0.
private func exchanged(_ x: Float, _ y: Float) -> (low: Float, high: Float) {
    if x.isNaN || y.isNaN { return (.nan, .nan) }
    if x < y { return (x, y) }
    if y < x { return (y, x) }
    if x == 0 {   // two zeros: the negative one, if there is one, is the lesser
        let anyNegative = x.sign == .minus || y.sign == .minus, bothNegative = x.sign == .minus && y.sign == .minus
        return (anyNegative ? -0.0 : 0.0, bothNegative ? -0.0 : 0.0)
    }
    return (x, y)
}

/// Bit patterns with every NaN folded onto one, so lanes can be compared whole.
private func pattern(_ values: [Float]) -> [UInt32] {
    values.map { $0.isNaN ? Float.nan.bitPattern : $0.bitPattern }
}

/// Runs an implementation on copies of two lanes.
private func exchange(_ bound: Bound, _ a: [Float], _ b: [Float]) -> (low: [Float], high: [Float]) {
    var low = a, high = b
    low.withUnsafeMutableBufferPointer { first in
        high.withUnsafeMutableBufferPointer { second in
            // An empty array may have no storage: nothing is touched then.
            guard let x = first.baseAddress, let y = second.baseAddress else { return }
            if bound == .native { ztd_lane_exchange_native(x, y, UInt32(a.count)) } else { ztd_lane_exchange_accelerate(x, y, UInt32(a.count)) }
        }
    }
    return (low, high)
}

/// The lengths around every boundary the implementations have: the four-lane step of the C loop
/// and the 1 032-frame chunk of the vDSP one.
private let lengths = [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 63, 64, 65, 1_024, 1_025, 1_031, 1_032, 1_033, 2_049, 4_097]

@Suite("Lane exchange (WP-219)")
struct LaneExchangeTests {
    @Test(arguments: Bound.allCases, lengths)
    func bothImplementationsEqualTheScalarExchange(bound: Bound, count: Int) {
        let a = TestSignal.whiteNoise(count: count, seed: 219 &+ UInt64(count), amplitude: 4)
        var b = TestSignal.whiteNoise(count: count, seed: 2_190 &+ UInt64(count), amplitude: 4)
        for index in stride(from: 0, to: count, by: 5) { b[index] = a[index] }   // ties among the pairs
        let expected = zip(a, b).map { exchanged($0, $1) }
        let result = exchange(bound, a, b)
        #expect(bits(result.low) == bits(expected.map(\.low)) && bits(result.high) == bits(expected.map(\.high)), "\(bound), \(count)")
        #expect(zip(result.low, result.high).allSatisfy { $0 <= $1 }, "every pair is in order")
        // What is in order stays as it is.
        let again = exchange(bound, result.low, result.high)
        #expect(bits(again.low) == bits(result.low) && bits(again.high) == bits(result.high))
    }

    /// The stress test of the stability note (register row 16): there is no arithmetic in an
    /// exchange, so ties and values that are not numbers are the only places two implementations
    /// could part. The data are the non-finite fixture of WP-016 against itself reversed, with
    /// zeros of both signs worked in: every special value meets every other, in the four-lane
    /// body of the C loop and in its tail.
    @Test(arguments: [8, 13, 64, 1_031, 1_033, 2_500])
    func theImplementationsAgreeOnTiesAndValuesThatAreNotNumbers(count: Int) {
        var a = StressFixture.nonFiniteSignal(count: count).samples
        var b = Array(a.reversed())
        let specials: [Float] = [0, -0.0, .nan, .infinity, -.infinity, 1, -1, .leastNonzeroMagnitude, -.greatestFiniteMagnitude]
        var index = 0
        for x in specials {
            for y in specials where index < count {
                a[index] = x
                b[index] = y
                index += 1
            }
        }
        // The same pairs once more at the far end, where the C loop is in its scalar tail.
        index = count - 1
        for x in specials.reversed() {
            for y in specials where index >= count / 2 {
                a[index] = x
                b[index] = y
                index -= 1
            }
        }
        let expected = zip(a, b).map { exchanged($0, $1) }
        let native = exchange(.native, a, b), accelerate = exchange(.accelerate, a, b)
        #expect(pattern(native.low) == pattern(expected.map(\.low)) && pattern(native.high) == pattern(expected.map(\.high)), "the C loop")
        #expect(pattern(accelerate.low) == pattern(expected.map(\.low)) && pattern(accelerate.high) == pattern(expected.map(\.high)), "vDSP")
        #expect(pattern(native.low) == pattern(accelerate.low) && pattern(native.high) == pattern(accelerate.high), "the same lanes from both")
        // The rule itself: a NaN poisons both lanes; of two zeros the negative one is the lesser.
        #expect(native.low.indices.allSatisfy { native.low[$0].isNaN == (a[$0].isNaN || b[$0].isNaN) && native.high[$0].isNaN == native.low[$0].isNaN })
        let zeros = exchange(.native, [0, -0.0, 0, -0.0, 0], [-0.0, 0, 0, -0.0, -0.0])
        #expect(bits(zeros.low) == bits([-0.0, -0.0, 0, -0.0, -0.0]) && bits(zeros.high) == bits([0, 0, 0, -0.0, 0]))
        if count > 200 { #expect(a.contains { $0.isNaN } && a.contains(.infinity) && b.contains(-.infinity), "the fixture's own values are among them") }
    }

    @Test func theFunctionForAnImplementationIsTheOneItNames() {
        let a = TestSignal.whiteNoise(count: 100, seed: 2_191), b = TestSignal.whiteNoise(count: 100, seed: 2_192)
        for (implementation, bound) in [(ZTD_IMPLEMENTATION_NATIVE, Bound.native), (ZTD_IMPLEMENTATION_ACCELERATE, .accelerate), (ztd_implementation_t(rawValue: 9), .native)] {
            let function = ztd_lane_exchange_function(implementation)
            #expect(function != nil)
            var low = a, high = b
            low.withUnsafeMutableBufferPointer { x in high.withUnsafeMutableBufferPointer { y in function?(x.baseAddress, y.baseAddress, 100) } }
            let expected = exchange(bound, a, b)
            #expect(bits(low) == bits(expected.low) && bits(high) == bits(expected.high))
        }
        // The pointers themselves: what a plan stores is the function, not a choice to make later (SEL-3).
        let native = unsafeBitCast(ztd_lane_exchange_function(ZTD_IMPLEMENTATION_NATIVE), to: UnsafeRawPointer?.self)
        let accelerate = unsafeBitCast(ztd_lane_exchange_function(ZTD_IMPLEMENTATION_ACCELERATE), to: UnsafeRawPointer?.self)
        #expect(native != nil && accelerate != nil && native != accelerate)
    }

    @Test func bothImplementationsAreAllocationFree() {
        let count = 2_049
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * count)
        defer { storage.deallocate() }
        let noise = TestSignal.whiteNoise(count: 2 * count, seed: 2_193)
        for index in 0 ..< 2 * count { storage[index] = noise[index] }
        let a = storage, b = storage + count
        let native = ztd_lane_exchange_function(ZTD_IMPLEMENTATION_NATIVE)!, accelerate = ztd_lane_exchange_function(ZTD_IMPLEMENTATION_ACCELERATE)!
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                native(a, b, UInt32(round % 2 == 0 ? count : 31))
                accelerate(a, b, UInt32(round % 2 == 0 ? count : 31))
                round += 1
            }
        }
    }

    /// The timings WP-611b turns into a crossover: both implementations over a grid of lane sizes.
    @Test func timingsOverTheSizeGridAreRecorded() {
        let grid = [8, 16, 32, 64, 128, 256, 512, 1_024, 1_025, 2_048, 4_096]
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4_096)
        defer { storage.deallocate() }
        let noise = TestSignal.whiteNoise(count: 2 * 4_096, seed: 2_194)
        for index in 0 ..< 2 * 4_096 { storage[index] = noise[index] }
        let a = storage, b = storage + 4_096
        var results: [BenchmarkResult] = []
        for size in grid {
            for bound in Bound.allCases {
                let function = ztd_lane_exchange_function(bound.implementation)!
                let count = UInt32(size)
                results.append(Benchmark.measure("lane-exchange.\(bound.rawValue).\(size)", iterations: max(200, 20_000 / size)) { function(a, b, count) })
            }
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 2 * grid.count && results.allSatisfy { $0.minimum > 0 })
    }
}
