import Testing
import ZTronDSPCore
import ZTronDSPTesting

/// The sort-based oracle of the median filters (WP-529): an oracle is only worth something
/// when it is right, so it is held against values worked out elsewhere.
@Suite("Median oracle")
struct MedianOracleTests {
    /// Five frames of four bins.
    static let spectrogram: [Float] = [3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]

    @Test func theFilterEqualsScipyOnASmallSpectrogram() {
        // scipy.ndimage.median_filter(S, size, mode="reflect") for S of 5 frames × 4 bins,
        // size (k, 1) along time and (1, k) along frequency; kernels wider than the
        // spectrogram reflect more than once.
        let time: [Int: [Float]] = [
            3: [3, 1, 4, 1, 5, 3, 4, 6, 5, 7, 5, 6, 5, 3, 8, 4, 2, 3, 8, 4],
            5: [5, 3, 4, 6, 5, 3, 4, 3, 5, 3, 5, 4, 5, 3, 8, 4, 5, 3, 8, 4],
            7: [5, 3, 4, 6, 5, 3, 4, 4, 3, 3, 5, 4, 5, 3, 8, 4, 5, 3, 8, 4],
            11: [5, 3, 5, 4, 5, 3, 5, 4, 5, 3, 5, 4, 5, 3, 5, 4, 5, 3, 5, 4],
        ]
        let frequency: [Int: [Float]] = [
            3: [3, 3, 1, 1, 5, 5, 6, 6, 5, 5, 5, 8, 9, 9, 7, 3, 2, 3, 4, 4],
            5: [3, 3, 1, 1, 5, 5, 6, 6, 5, 5, 5, 5, 9, 9, 7, 7, 3, 3, 4, 4],
            7: [3, 1, 3, 1, 5, 6, 5, 6, 5, 5, 5, 5, 9, 7, 9, 7, 3, 3, 4, 4],
            9: [1, 3, 1, 3, 6, 5, 6, 5, 5, 5, 5, 5, 7, 9, 7, 9, 4, 4, 3, 3],
        ]
        for (kernel, expected) in time {
            #expect(MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: kernel, along: .time) == expected, "along time, kernel \(kernel)")
        }
        for (kernel, expected) in frequency {
            #expect(MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: kernel, along: .frequency) == expected, "along frequency, kernel \(kernel)")
        }
        #expect(MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: 1, along: .time) == Self.spectrogram, "a kernel of one is the value itself")
        #expect(MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: 1, along: .frequency) == Self.spectrogram)
    }

    @Test func aLineIsReflectedWithItsEdgeValueRepeated() {
        // … c b a | a b c d | d c b …
        #expect((-9 ... 12).map { MedianOracle.reflected($0, count: 4) } == [0, 0, 1, 2, 3, 3, 2, 1, 0, 0, 1, 2, 3, 3, 2, 1, 0, 0, 1, 2, 3, 3])
        #expect((-3 ... 3).map { MedianOracle.reflected($0, count: 1) } == [0, 0, 0, 0, 0, 0, 0])
        #expect(MedianOracle.reflected(5, count: 0) == 0 && MedianOracle.reflected(-1, count: 7) == 0 && MedianOracle.reflected(7, count: 7) == 6)
    }

    @Test func theMedianIsTheMiddleOfTheSortedValues() {
        #expect(MedianOracle.median([5]) == 5 && MedianOracle.median([3, 1, 2]) == 2 && MedianOracle.median([9, 1, 8, 2, 7]) == 7)
        #expect(MedianOracle.median([4, 1, 3, 2]) == 2, "of an even number, the lower of the two in the middle")
        #expect(MedianOracle.median([]).isNaN)
        // Ties, and zeros of either sign: −0 lies below +0, as the lane exchange orders them.
        #expect(MedianOracle.median([2, 2, 1, 2, 3]) == 2)
        #expect(MedianOracle.median([-0.0, 0.0, 0.0]).sign == .plus && MedianOracle.median([-0.0, -0.0, 0.0]).sign == .minus)
        #expect(MedianOracle.median([0.0, -0.0, 1]).sign == .plus && MedianOracle.median([-1, 0.0, -0.0]).sign == .minus)
        // Infinities are values like any other; a value that is not a number goes to an end.
        #expect(MedianOracle.median([.infinity, 1, -.infinity]) == 1 && MedianOracle.median([.nan, 1, 2]) == 2 && MedianOracle.median([-.nan, 1, 2]) == 1)
        // The network of the core finds the same value on random windows (WP-528).
        var generator = SeededGenerator(seed: 529)
        for count in [1, 3, 5, 9, 17, 31, 63] {
            for _ in 0 ..< 20 {
                var window = (0 ..< count).map { _ in Float(Int(generator.nextUnit() * 12)) / 4 }
                let expected = MedianOracle.median(window)
                #expect((try? MedianNetwork(count: count).median(of: &window)) == expected, "\(count) values")
            }
        }
    }

    @Test func theRunningMedianIsTheCentredOneKnownHalfAKernelLate() {
        let frames = (0 ..< 5).map { Array(Self.spectrogram[$0 * 4 ..< $0 * 4 + 4]) }
        for kernel in [1, 3, 5] {
            let running = MedianOracle.running(frames, kernel: kernel), centred = MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: kernel, along: .time)
            let reach = kernel / 2
            #expect(running.count == 5 && running.allSatisfy { $0.count == 4 })
            for frame in reach ..< 5 {
                #expect(running[frame] == Array(centred[(frame - reach) * 4 ..< (frame - reach) * 4 + 4]), "kernel \(kernel), frame \(frame)")
            }
        }
        // Before the stream has given a kernel of frames, those it has given are reflected.
        let running = MedianOracle.running(frames, kernel: 5)
        #expect(running[0] == frames[0], "one frame: every lane is that frame")
        #expect(running[1] == frames[1], "two frames, reflected as b a | a b b: the newest holds three of the five lanes")
        #expect(running[2] == [5, 3, 4, 6], "three frames, reflected as c b a | a b: the median of c, b, a, a, b")
    }

    @Test func nonsenseGivesNothing() {
        #expect(MedianOracle.filter(Self.spectrogram, rowCount: 3, kernel: 3, along: .time).isEmpty, "the values do not fill frames of three")
        #expect(MedianOracle.filter(Self.spectrogram, rowCount: 0, kernel: 3, along: .time).isEmpty && MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: 2, along: .time).isEmpty)
        #expect(MedianOracle.filter(Self.spectrogram, rowCount: 4, kernel: 0, along: .frequency).isEmpty && MedianOracle.filter([], rowCount: 4, kernel: 3, along: .time).isEmpty)
        #expect(MedianOracle.running([[1, 2], [3]], kernel: 3).isEmpty && MedianOracle.running([[1, 2]], kernel: 4).isEmpty && MedianOracle.running([], kernel: 3).isEmpty)
    }
}
