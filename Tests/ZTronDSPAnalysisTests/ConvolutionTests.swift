import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// The full convolution of two signals by its definition, in double precision.
func naiveConvolution(_ x: [Float], _ h: [Float]) -> [Double] {
    var result = [Double](repeating: 0, count: x.count + h.count - 1)
    for (i, a) in x.enumerated() {
        for (j, b) in h.enumerated() { result[i + j] += Double(a) * Double(b) }
    }
    return result
}

/// The largest distance between a result and its reference, value by value; infinite for
/// results of different lengths.
func worstDeviation(_ result: [Float], _ expected: [Double]) -> Double {
    guard result.count == expected.count else { return .infinity }
    var worst = 0.0
    for (value, wanted) in zip(result, expected) { worst = max(worst, abs(Double(value) - wanted)) }
    return worst
}

/// The full correlation of two signals by its definition, in double precision: value `j` is
/// lag `j − (M − 1)`.
func naiveCorrelation(_ x: [Float], _ y: [Float]) -> [Double] {
    var result = [Double](repeating: 0, count: x.count + y.count - 1)
    for (i, a) in x.enumerated() {
        for (k, b) in y.enumerated() { result[i - k + y.count - 1] += Double(a) * Double(b) }
    }
    return result
}

/// One-shot convolution (WP-513): direct, FFT, partitioned and automatic, in three modes.
@Suite("One-shot convolution")
struct ConvolutionTests {
    static let strategies: [ConvolutionStrategy] = [.direct, .fft, .partitioned, .automatic]
    static let modes: [(name: String, mode: ConvolutionMode)] = [("full", .full), ("same", .same), ("valid", .valid)]

    // MARK: Golden (STG-2): numpy.convolve, 10⁻⁵ of the largest output

    @Test(arguments: ["16-5", "1024-255", "48000-4096", "5-16", "255-1024"])
    func theConvolutionEqualsTheReference(sizes: String) throws {
        let golden = try GoldenFile(named: "convolution", in: .module)
        for (name, mode) in Self.modes {
            let reference = try golden.require("convolve-\(sizes)-\(name)")
            let x = try reference.floats("x"), h = try reference.floats("h"), expected = try reference.real("result")
            let n = try reference.integer("n"), k = try reference.integer("k")
            #expect(x.count == n && h.count == k)
            let largest = expected.map { abs($0) }.max() ?? 1
            var figures: [String] = []
            for strategy in Self.strategies {
                let result = try DSP.convolve(x, h, mode: mode, strategy: strategy)
                #expect(result.count == expected.count, "\(sizes), \(name), \(strategy)")
                expectClose(result, expected, .relativeToMaximum(1e-5), "\(sizes), \(name), \(strategy)")
                figures.append("\(strategy) \(worstDeviation(result, expected) / largest)")
            }
            print("measured WP-513: convolve \(sizes), \(name): of the largest output: \(figures.joined(separator: ", ")) (tolerance 1e-5)")
        }
    }

    // MARK: The modes

    @Test func theModesCutTheFullResult() throws {
        for (n, k) in [(1, 1), (1, 9), (9, 1), (2, 3), (3, 2), (7, 7), (8, 8), (16, 4), (4, 16), (33, 6), (6, 33), (100, 17)] {
            let x = TestSignal.whiteNoise(count: n, seed: UInt64(n * 31 + k)), h = TestSignal.whiteNoise(count: k, seed: UInt64(k * 17 + n))
            let full = try DSP.convolve(x, h, mode: .full, strategy: .direct)
            expectClose(full, naiveConvolution(x, h), .absolute(1e-5), "\(n), \(k): the definition")
            #expect(full.count == n + k - 1)
            // The direct method computes only the values a mode keeps, and vDSP sums a value in
            // another order by where it starts: equal within round-off, not bit for bit.
            let same = try DSP.convolve(x, h, mode: .same, strategy: .direct)
            #expect(same.count == n)
            expectClose(same, Array(full[(k - 1) / 2 ..< (k - 1) / 2 + n]), .absolute(1e-5), "\(n), \(k): as long as the first input, from the middle of the full result")
            let valid = try DSP.convolve(x, h, mode: .valid, strategy: .direct)
            #expect(valid.count == max(n, k) - min(n, k) + 1)
            expectClose(valid, Array(full[min(n, k) - 1 ..< max(n, k)]), .absolute(1e-5), "\(n), \(k): the shorter input wholly inside the longer one")
            // The other methods cut the same values out of their own full result.
            for strategy in [ConvolutionStrategy.fft, .partitioned] {
                let whole = try DSP.convolve(x, h, mode: .full, strategy: strategy)
                #expect(try DSP.convolve(x, h, mode: .same, strategy: strategy) == Array(whole[(k - 1) / 2 ..< (k - 1) / 2 + n]))
                #expect(try DSP.convolve(x, h, mode: .valid, strategy: strategy) == Array(whole[min(n, k) - 1 ..< max(n, k)]))
                expectClose(whole, full, .relativeToMaximum(1e-5), "\(n), \(k), \(strategy)")
            }
        }
        #expect(OneShotConvolution.span(.full, 10, 4) == 0 ..< 13 && OneShotConvolution.span(.same, 10, 4) == 1 ..< 11 && OneShotConvolution.span(.valid, 10, 4) == 3 ..< 10)
        #expect(OneShotConvolution.span(.same, 4, 10) == 4 ..< 8 && OneShotConvolution.span(.valid, 4, 10) == 3 ..< 10)
        #expect(ConvolutionMode.allCases == [.full, .same, .valid] && ConvolutionStrategy.allCases == [.direct, .fft, .partitioned, .automatic])
    }

    @Test func aConvolutionIsWhatItsDefinitionSays() throws {
        let x = TestSignal.whiteNoise(count: 300, seed: 513, amplitude: 0.5)
        for strategy in Self.strategies {
            // A unit impulse returns the signal; a delayed one delays it.
            #expect(try DSP.convolve(x, [1], strategy: strategy).count == 300)
            expectClose(try DSP.convolve(x, [1], strategy: strategy), x, .absolute(1e-6), "\(strategy)")
            let delayed = try DSP.convolve(x, [0, 0, 0, 1], strategy: strategy)
            expectClose(Array(delayed[3...]), x, .absolute(1e-6), "\(strategy)")
            expectClose(Array(delayed[..<3]), [0, 0, 0], .absolute(1e-6), "\(strategy)")
            // It commutes, and it is linear in each input.
            let h = TestSignal.whiteNoise(count: 41, seed: 7)
            expectClose(try DSP.convolve(h, x, strategy: strategy), try DSP.convolve(x, h, strategy: strategy), .relativeToMaximum(1e-5))
            let doubled = try DSP.convolve(x.map { 2 * $0 }, h, strategy: strategy)
            expectClose(doubled, try DSP.convolve(x, h, strategy: strategy).map { 2 * $0 }, .relativeToMaximum(1e-5))
        }
        // A moving average of three: every value the mean of its neighbourhood.
        let ramp = (0 ..< 10).map { Float($0) }
        expectClose(try DSP.convolve(ramp, [1 / 3, 1 / 3, 1 / 3], mode: .valid), (1 ... 8).map { Double($0) }, .absolute(1e-5))
    }

    // MARK: The strategy

    @Test func automaticFollowsTheCostModelOfTheTable() throws {
        let table = CrossoverTable.shipped
        for (n, k) in [(16, 5), (64, 64), (1_024, 255), (48_000, 4_096), (100_000, 3), (3, 100_000), (4_096, 4_096)] {
            let expected: ConvolutionStrategy = table.convolutionUsesFFT(n, k) ? .fft : .direct
            #expect(OneShotConvolution.method(.automatic, n, k, crossovers: table) == expected, "\(n), \(k)")
        }
        #expect(OneShotConvolution.method(.automatic, 16, 5, crossovers: table) == .direct && OneShotConvolution.method(.automatic, 48_000, 4_096, crossovers: table) == .fft)
        // A forced choice is honoured whatever the sizes.
        for strategy in [ConvolutionStrategy.direct, .fft, .partitioned] {
            #expect(OneShotConvolution.method(strategy, 16, 5, crossovers: table) == strategy && OneShotConvolution.method(strategy, 48_000, 4_096, crossovers: table) == strategy)
        }
        // The crossover is data (SEL-5): another table, another choice, the same result.
        let always = CrossoverTable(convolutionFFTFactor: 0), never = CrossoverTable(convolutionFFTFactor: .infinity)
        #expect(OneShotConvolution.method(.automatic, 16, 5, crossovers: always) == .fft && OneShotConvolution.method(.automatic, 48_000, 4_096, crossovers: never) == .direct)
        let x = TestSignal.whiteNoise(count: 500, seed: 1), h = TestSignal.whiteNoise(count: 60, seed: 2)
        #expect(try DSP.convolve(x, h, crossovers: always) == DSP.convolve(x, h, strategy: .fft), "bit for bit: the same method")
        #expect(try DSP.convolve(x, h, crossovers: never) == DSP.convolve(x, h, strategy: .direct))
        expectClose(try DSP.convolve(x, h, crossovers: always), try DSP.convolve(x, h, crossovers: never), .relativeToMaximum(1e-5), "the methods agree (SEL-6)")
        // Past the longest single transform the automatic choice is the partitioned method.
        #expect(OneShotConvolution.method(.automatic, 3_000_000, 2_000_000, crossovers: table) == .partitioned)
        #expect(OneShotConvolution.method(.automatic, 2_000_000, 2_000_000, crossovers: table) == .fft, "2²² points still fit")
    }

    @Test func thePartitionedMethodKeepsItsTransformsShort() throws {
        // A long signal and a short kernel: partitions of the kernel's length, whole and partial.
        let x = TestSignal.whiteNoise(count: 10_007, seed: 3, amplitude: 0.5), h = TestSignal.whiteNoise(count: 70, seed: 4)
        let direct = try DSP.convolve(x, h, strategy: .direct), partitioned = try DSP.convolve(x, h, strategy: .partitioned)
        #expect(partitioned.count == direct.count)
        expectClose(partitioned, direct, .relativeToMaximum(1e-5))
        // A kernel longer than the longest partition, and one longer than the signal.
        let long = TestSignal.whiteNoise(count: 70_000, seed: 5, amplitude: 0.1)
        expectClose(try DSP.convolve(h, long, strategy: .partitioned), try DSP.convolve(h, long, strategy: .direct), .relativeToMaximum(1e-5))
    }

    @Test func nonsenseIsRefused() {
        let x = TestSignal.whiteNoise(count: 8, seed: 1)
        for strategy in Self.strategies {
            #expect(throws: DSPError.self) { _ = try DSP.convolve([], x, strategy: strategy) }
            #expect(throws: DSPError.self) { _ = try DSP.convolve(x, [], strategy: strategy) }
        }
        #expect(errorMessage { _ = try DSP.convolve([], x) }?.contains("x is empty") == true)
        #expect(errorMessage { _ = try DSP.convolve(x, []) }?.contains("h is empty") == true)
        #expect(errorMessage { _ = try DSP.correlate(x, []) }?.contains("y is empty") == true)
    }
}
