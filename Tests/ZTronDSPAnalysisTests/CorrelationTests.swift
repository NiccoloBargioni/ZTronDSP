import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// One-shot correlation and its normalisations (WP-514), and the one-shot autocorrelation
/// (WP-515).
@Suite("One-shot correlation")
struct CorrelationTests {
    static let strategies = ConvolutionTests.strategies
    static let normalizations: [(name: String, normalization: CorrelationNormalization)] =
        [("none", .none), ("biased", .biased), ("unbiased", .unbiased), ("coefficient", .coefficient)]

    // MARK: Golden (STG-2): scipy.signal.correlate, 10⁻⁵ of the largest output

    @Test(arguments: ["16-5", "1024-255", "48000-4096", "5-16", "255-1024"])
    func theCorrelationEqualsTheReference(sizes: String) throws {
        let golden = try GoldenFile(named: "convolution", in: .module)
        for (name, mode) in ConvolutionTests.modes {
            let reference = try golden.require("correlate-\(sizes)-\(name)")
            let x = try reference.floats("x"), y = try reference.floats("y"), expected = try reference.real("result")
            let largest = expected.map { abs($0) }.max() ?? 1
            var figures: [String] = []
            for strategy in Self.strategies {
                let result = try DSP.correlate(x, y, mode: mode, strategy: strategy)
                #expect(result.count == expected.count, "\(sizes), \(name), \(strategy)")
                expectClose(result, expected, .relativeToMaximum(1e-5), "\(sizes), \(name), \(strategy)")
                figures.append("\(strategy) \(worstDeviation(result, expected) / largest)")
            }
            print("measured WP-514: correlate \(sizes), \(name): of the largest output: \(figures.joined(separator: ", ")) (tolerance 1e-5)")
        }
    }

    @Test(arguments: ["16-5", "1024-255", "255-1024", "1024-1024"])
    func theNormalisationsEqualTheirDefinitions(sizes: String) throws {
        let reference = try GoldenFile(named: "convolution", in: .module).require("normalized-\(sizes)")
        let x = try reference.floats("x"), y = try reference.floats("y")
        let n = x.count, m = y.count
        // The products summed at each lag, y[k]·x[k + lag] for every k both inputs hold.
        let products = (0 ..< n + m - 1).map { index -> Double in
            let lag = index - (m - 1)
            return Double(min(m - 1, n - 1 - lag) - max(0, -lag) + 1)
        }
        for (name, normalization) in Self.normalizations {
            let expected = try reference.real(name)
            let largest = expected.map { abs($0) }.max() ?? 1
            var figures: [String] = []
            for strategy in Self.strategies {
                let result = try DSP.correlate(x, y, normalization: normalization, strategy: strategy)
                if normalization == .unbiased, strategy != .direct {
                    // A transform is right to a floor under its largest output (§7.5, row 10): a
                    // lag that sums one product is divided by one, and keeps that floor. The
                    // tolerance is that of the sums the method computed.
                    expectClose(zip(result, products).map { Double($0) * $1 }, zip(expected, products).map { $0 * $1 }, .relativeToMaximum(1e-5),
                                "\(sizes), \(name), \(strategy)")
                } else {
                    expectClose(result, expected, .relativeToMaximum(1e-5), "\(sizes), \(name), \(strategy)")
                }
                figures.append("\(strategy) \(worstDeviation(result, expected) / largest)")
            }
            print("measured WP-514: correlate \(sizes), \(name): of the largest value: \(figures.joined(separator: ", ")) (tolerance 1e-5; unbiased by a transform: of the sums before they are divided)")
        }
        #expect(CorrelationNormalization.allCases == [.none, .biased, .unbiased, .coefficient])
    }

    // MARK: The definition

    @Test func aCorrelationIsWhatItsDefinitionSays() throws {
        for (n, m) in [(1, 1), (1, 6), (6, 1), (5, 5), (8, 3), (3, 8), (40, 13), (13, 40)] {
            let x = TestSignal.whiteNoise(count: n, seed: UInt64(n + 100 * m)), y = TestSignal.whiteNoise(count: m, seed: UInt64(m + 77 * n))
            let naive = naiveCorrelation(x, y)
            for strategy in Self.strategies {
                let full = try DSP.correlate(x, y, strategy: strategy)
                expectClose(full, naive, .absolute(2e-5), "\(n), \(m), \(strategy)")
                // Mirrored in the lag when the inputs change places.
                expectClose(try DSP.correlate(y, x, strategy: strategy), Array(naive.reversed()), .absolute(2e-5), "\(n), \(m), \(strategy)")
                // The direct method computes only the values a mode keeps, and vDSP sums a value
                // in another order by where it starts: equal within round-off, not bit for bit.
                expectClose(try DSP.correlate(x, y, mode: .same, strategy: strategy), Array(full[(m - 1) / 2 ..< (m - 1) / 2 + n]), .absolute(1e-5))
                expectClose(try DSP.correlate(x, y, mode: .valid, strategy: strategy), Array(full[min(n, m) - 1 ..< max(n, m)]), .absolute(1e-5))
            }
            // It is the convolution with the second input back to front.
            expectClose(try DSP.correlate(x, y, strategy: .direct), try DSP.convolve(x, Array(y.reversed()), strategy: .direct), .absolute(1e-6))
        }
    }

    @Test func lagZeroSitsWhereTheSecondInputEnds() throws {
        // A copy 37 samples late: the peak of the correlation names the delay.
        let sent = TestSignal.whiteNoise(count: 400, seed: 514, amplitude: 0.5)
        let received = [Float](repeating: 0, count: 37) + sent + [Float](repeating: 0, count: 63)
        for strategy in Self.strategies {
            let r = try DSP.correlate(received, sent, strategy: strategy)
            let peak = try #require(r.indices.max { r[$0] < r[$1] })
            #expect(peak - (sent.count - 1) == 37, "\(strategy): the lag of the peak is \(peak - (sent.count - 1))")
            let coefficient = try DSP.correlate(received, sent, normalization: .coefficient, strategy: strategy)
            expectClose(coefficient[peak], 1, .absolute(1e-5), "the copy is the signal: a coefficient of 1")
            #expect(coefficient.allSatisfy { abs($0) <= 1 + 1e-5 })
        }
    }

    // MARK: The zero-denominator rule (NUM-1)

    @Test func silenceGivesZeros() throws {
        let noise = TestSignal.whiteNoise(count: 64, seed: 9)
        let silence = TestSignal.silence(count: 64)
        let denormal = try #require(StressFixture.signals(count: 64).first { $0.name == "denormal" }).samples
        for strategy in Self.strategies {
            for (x, y) in [(silence, noise), (noise, silence), (silence, silence), (denormal, denormal), (denormal, noise)] {
                let coefficient = try DSP.correlate(x, y, normalization: .coefficient, strategy: strategy)
                #expect(coefficient.count == 127 && coefficient.allSatisfy { $0 == 0 }, "\(strategy): zeros, not 0/0")
                for normalization in [CorrelationNormalization.none, .biased, .unbiased] {
                    #expect(try DSP.correlate(x, y, normalization: normalization, strategy: strategy).allSatisfy { $0.isFinite })
                }
            }
            #expect(try DSP.autocorrelate(silence, normalization: .coefficient, strategy: strategy).allSatisfy { $0 == 0 })
            #expect(try DSP.autocorrelate(denormal, normalization: .coefficient, strategy: strategy).allSatisfy { $0 == 0 })
        }
        // The floor is the caller's to move: a quiet signal is silence above its energy, and a signal below it.
        let quiet = noise.map { $0 * 1e-6 }
        #expect(try DSP.correlate(quiet, quiet, normalization: .coefficient).contains { $0 != 0 })
        #expect(try DSP.correlate(quiet, quiet, normalization: .coefficient, floor: 1e-6).allSatisfy { $0 == 0 })
        #expect(try DSP.autocorrelate(quiet, normalization: .coefficient, floor: 1e-6).allSatisfy { $0 == 0 })
        #expect(try DSP.autocorrelate(quiet, normalization: .coefficient)[0] == 1)
        for floor in [-1.0, .nan, .infinity] {
            #expect(throws: DSPError.self) { _ = try DSP.correlate(noise, noise, floor: floor) }
            #expect(throws: DSPError.self) { _ = try DSP.autocorrelate(noise, floor: floor) }
        }
        #expect(DSP.correlationFloor == 1e-20)
    }

    // MARK: Autocorrelation (WP-515)

    @Test func theAutocorrelationByTransformEqualsTheDirectSum() throws {
        for (count, maxLag) in [(1, 0), (5, 4), (16, 15), (100, 30), (1_000, 999), (4_096, 2_048), (3_000, 700)] {
            let x = TestSignal.whiteNoise(count: count, seed: UInt64(count), amplitude: 0.5)
            let naive = Array(naiveCorrelation(x, x)[(count - 1) ... (count - 1 + maxLag)])
            let direct = try DSP.autocorrelate(x, maxLag: maxLag, strategy: .direct)
            #expect(direct.count == maxLag + 1)
            expectClose(direct, naive, .relativeToMaximum(1e-6), "\(count), \(maxLag): the sum of products")
            for strategy in [ConvolutionStrategy.fft, .partitioned] {
                let transformed = try DSP.autocorrelate(x, maxLag: maxLag, strategy: strategy)
                expectClose(transformed, naive, .relativeToMaximum(2e-6), "\(count), \(maxLag), \(strategy): the Wiener–Khinchin relation, zero-padded")
                if strategy == .fft {
                    print("measured WP-515: autocorrelation of \(count) samples, lags to \(maxLag): by the transform within \(worstDeviation(transformed, naive) / naive[0]) of lag 0 of the direct sum, the direct method within \(worstDeviation(direct, naive) / naive[0]) (tolerances 2e-6 and 1e-6)")
                }
            }
            expectClose(try DSP.autocorrelate(x, maxLag: maxLag), naive, .relativeToMaximum(2e-6))
            // The non-negative lags of the correlation of the signal with itself.
            expectClose(direct, Array(try DSP.correlate(x, x, strategy: .direct)[(count - 1) ... (count - 1 + maxLag)]), .relativeToMaximum(1e-6))
        }
    }

    @Test func aPeriodicFixturePeaksAtItsPeriod() throws {
        // 441 Hz at 44.1 kHz: a period of exactly 100 samples.
        let tone = TestSignal.harmonic(fundamental: 441, amplitudes: [0.5, 0.3, 0.2, 0.1], sampleRate: 44_100, count: 4_096)
        for strategy in Self.strategies {
            let r = try DSP.autocorrelate(tone, maxLag: 1_000, normalization: .coefficient, strategy: strategy)
            #expect(r[0] == 1, "\(strategy): a coefficient reads 1 at lag 0")
            // Past the lobe around lag 0 the largest value is at the period.
            let peak = try #require((50 ... 1_000).max { r[$0] < r[$1] })
            #expect(peak == 100, "\(strategy): the largest value past lag 0 is at lag \(peak)")
            #expect(r[100] > 0.95 && r[50] < -0.2 && r[200] > r[300] && r[200] < r[100], "the peaks fall off as fewer products are summed")
            // Unbiased, every multiple of the period reads the energy of one sample again.
            let unbiased = try DSP.autocorrelate(tone, maxLag: 1_000, normalization: .unbiased, strategy: strategy)
            expectClose(unbiased[100], unbiased[0], .relative(1e-3))
            expectClose(unbiased[1_000], unbiased[0], .relative(1e-3))
        }
    }

    @Test func theNormalisationsOfAnAutocorrelation() throws {
        let x = TestSignal.whiteNoise(count: 200, seed: 515, amplitude: 0.5)
        let naive = Array(naiveCorrelation(x, x)[199...])
        for strategy in Self.strategies {
            expectClose(try DSP.autocorrelate(x, strategy: strategy), naive, .relativeToMaximum(2e-6), "\(strategy): every lag that has a product, by default")
            expectClose(try DSP.autocorrelate(x, normalization: .biased, strategy: strategy), naive.map { $0 / 200 }, .relativeToMaximum(2e-6))
            expectClose(try DSP.autocorrelate(x, normalization: .unbiased, strategy: strategy), naive.enumerated().map { $1 / Double(200 - $0) }, .absolute(2e-5))
            expectClose(try DSP.autocorrelate(x, normalization: .coefficient, strategy: strategy), naive.map { $0 / naive[0] }, .absolute(2e-6))
            // A lag past the signal has no product: 0, whatever the normalisation.
            for normalization in [CorrelationNormalization.none, .biased, .unbiased, .coefficient] {
                let long = try DSP.autocorrelate(x, maxLag: 260, normalization: normalization, strategy: strategy)
                #expect(long.count == 261 && long[200...].allSatisfy { $0 == 0 } && long[199] != 0, "\(strategy), \(normalization)")
            }
        }
        #expect(throws: DSPError.self) { _ = try DSP.autocorrelate([]) }
        #expect(throws: DSPError.self) { _ = try DSP.autocorrelate(x, maxLag: -1) }
        #expect(throws: DSPError.self) { _ = try DSP.autocorrelate(x, maxLag: 1 << 29) }
        #expect(try DSP.autocorrelate([3], normalization: .unbiased) == [9])
    }

    @Test func theTransformOfAnAutocorrelationPadsByRule() throws {
        // At least frame + lags − 1 points, so that nothing wraps round (§6.7).
        #expect(WienerKhinchin.transformLength(frame: 384, lagCount: 384) == 768 && WienerKhinchin.transformLength(frame: 2_048, lagCount: 1_025) == 3_072)
        #expect(WienerKhinchin.transformLength(frame: 1, lagCount: 1) == 16)
        let transform = try WienerKhinchin(frame: 100, lagCount: 130)
        #expect(transform.length == 240 && transform.frame == 100 && transform.lagCount == 130, "229 points, padded to the next fast length")
        // A frame of ones: r[l] = frame − l, and exactly 0 past the frame.
        var lags = [Float](repeating: -1, count: 130)
        let ones = [Float](repeating: 1, count: 100)
        ones.withUnsafeBufferPointer { source in lags.withUnsafeMutableBufferPointer { transform.autocorrelate(source.baseAddress!, into: $0.baseAddress!) } }
        expectClose(Array(lags[..<100]), (0 ..< 100).map { Double(100 - $0) }, .absolute(1e-4))
        #expect(lags[100...].allSatisfy { $0 == 0 })
        #expect(throws: DSPError.self) { _ = try WienerKhinchin(frame: 0, lagCount: 4) }
        #expect(throws: DSPError.self) { _ = try WienerKhinchin(frame: 4, lagCount: 0) }
        #expect(throws: DSPError.self) { _ = try WienerKhinchin(frame: 64, lagCount: 8, backend: UnwillingBackend()) }
    }
}
