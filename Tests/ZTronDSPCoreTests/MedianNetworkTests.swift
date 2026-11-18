import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// The median-network generator (WP-528).
@Suite("Median network")
struct MedianNetworkTests {
    @Test func everyZeroOneInputPutsTheMedianOnItsLane() throws {
        // The 0–1 principle: a network that selects the median of every input of zeros and
        // ones selects it for every input. Exhaustive for k ≤ 15.
        for count in stride(from: 1, through: 15, by: 2) {
            let network = try MedianNetwork(count: count)
            var failures = 0
            for pattern in 0 ..< (1 << count) {
                var lanes = (0 ..< count).map { Float((pattern >> $0) & 1) }
                let ones = pattern.nonzeroBitCount
                if network.median(of: &lanes) != (ones > count / 2 ? 1 : 0) { failures += 1 }
            }
            #expect(failures == 0, "\(count) lanes: \(failures) of \(1 << count) patterns")
            #expect(network.medianLane == count / 2 && network.count == count)
        }
    }

    @Test func randomDataGivesTheSortedMiddle() throws {
        var generator = SeededGenerator(seed: 28)
        for count in stride(from: 1, through: 63, by: 2) {
            let network = try MedianNetwork(count: count)
            for round in 0 ..< 200 {
                // Ties, negative values and wide ranges included.
                var lanes = (0 ..< count).map { _ in round % 3 == 0 ? Float(Int(generator.nextUnit() * 5)) : Float(generator.nextGaussian() * 1e3) }
                let expected = lanes.sorted()[count / 2]
                #expect(network.median(of: &lanes) == expected, "\(count) lanes, round \(round)")
            }
        }
        let large = try MedianNetwork(count: 255)
        var lanes = (0 ..< 255).map { Float(($0 * 97) % 255) }
        #expect(large.median(of: &lanes) == 127)
    }

    @Test func theNetworkIsPrunedToWhatTheMedianNeeds() throws {
        for count in [3, 5, 7, 9, 17, 31] {
            let network = try MedianNetwork(count: count)
            let full = MedianNetwork.sorting(count)
            #expect(network.exchanges.count < full.count || count == 3, "\(count) lanes: \(network.exchanges.count) of \(full.count) exchanges")
            #expect(network.exchanges.allSatisfy { $0.low < $0.high && $0.low >= 0 && $0.high < count })
            // Every exchange that was kept matters: dropping any one breaks the median for some input.
            #expect(MedianNetwork.pruned(network.exchanges, keeping: network.medianLane) == network.exchanges, "pruning is idempotent")
        }
        #expect(try MedianNetwork(count: 1).exchanges.isEmpty)
        #expect(try MedianNetwork(count: 3).exchanges.count == 3)
        #expect(try MedianNetwork(count: 5).exchanges.count <= 9 && MedianNetwork(count: 9).exchanges.count <= 26)
        // The full network sorts.
        var generator = SeededGenerator(seed: 5)
        for count in [2, 6, 11, 40] {
            var values = (0 ..< count).map { _ in Float(generator.nextGaussian()) }
            let sorted = values.sorted()
            for exchange in MedianNetwork.sorting(count) where values[exchange.high] < values[exchange.low] { values.swapAt(exchange.low, exchange.high) }
            #expect(values == sorted)
        }
    }

    @Test func aCountThatHasNoMedianLaneIsRefused() {
        for count in [0, -1, 2, 16, 257] {
            #expect(throws: DSPError.self) { _ = try MedianNetwork(count: count) }
        }
        #expect(throws: Never.self) { _ = try MedianNetwork(count: 255) }
        #expect((try? MedianNetwork(count: 7)) == (try? MedianNetwork(count: 7)), "a value: equal counts give equal networks")
    }

    @Test func theMedianOfEveryStressSignalIsTheSortedMiddle() throws {
        // Stability register row 16 (`Docs/Numerics/median-network.md`): there is no arithmetic
        // in the network, so what is asked of it is to be a network: on ties, on values at the
        // ends of the range and on values below the normal range, as on any other input.
        for count in [3, 5, 9, 17, 31, 63] {
            let network = try MedianNetwork(count: count)
            for signal in StressFixture.signals(count: 2_048) {
                var start = 0
                var wrong = 0
                while start + count <= signal.samples.count {
                    var lanes = Array(signal.samples[start ..< (start + count)])
                    let expected = lanes.sorted()[count / 2]
                    if network.median(of: &lanes) != expected { wrong += 1 }
                    start += max(count / 2, 1)
                }
                #expect(wrong == 0, "\(count) lanes over \(signal.name): \(wrong) windows whose median is not the sorted middle")
            }
            // Zeros of both signs are one number: whichever the network leaves on the lane, it is zero.
            var zeros = (0 ..< count).map { $0 % 2 == 0 ? Float(0) : -Float(0) }
            #expect(network.median(of: &zeros) == 0)
            // A value between two runs of ties.
            var steps = [Float](repeating: -1, count: count / 2) + [0.25] + [Float](repeating: 1, count: count / 2)
            #expect(network.median(of: &steps) == 0.25)
        }
    }
}
