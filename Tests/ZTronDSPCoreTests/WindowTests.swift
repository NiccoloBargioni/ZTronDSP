import Accelerate
import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `Window` (WP-501a, WP-501b, WP-501c): the vDSP set bit for bit, the package set against
/// its oracle, custom windows and the checks of WIN-3.
@Suite("Windows")
struct WindowTests {
    // MARK: The vDSP set (WIN-1)

    @Test func theVDSPWindowsAreTheVDSPCallsBitForBit() throws {
        for count in [1, 2, 7, 64, 1_000, 2_048] {
            func direct(_ generate: (UnsafeMutablePointer<Float>, vDSP_Length, Int32) -> Void, _ flags: Int32, length: Int? = nil) -> [Float] {
                var values = [Float](repeating: 0, count: count)
                generate(&values, vDSP_Length(length ?? count), flags)
                return values
            }
            func directD(_ generate: (UnsafeMutablePointer<Double>, vDSP_Length, Int32) -> Void, _ flags: Int32) -> [Double] {
                var values = [Double](repeating: 0, count: count)
                generate(&values, vDSP_Length(count), flags)
                return values
            }
            let cases: [(Window, [Float], [Double])] = [
                (.hann, direct(vDSP_hann_window, Int32(vDSP_HANN_DENORM)), directD(vDSP_hann_windowD, Int32(vDSP_HANN_DENORM))),
                (.hann(.normalized), direct(vDSP_hann_window, Int32(vDSP_HANN_NORM)), directD(vDSP_hann_windowD, Int32(vDSP_HANN_NORM))),
                (.hamming, direct(vDSP_hamm_window, 0), directD(vDSP_hamm_windowD, 0)),
                (.blackman, direct(vDSP_blkman_window, 0), directD(vDSP_blkman_windowD, 0)),
            ]
            for (window, single, double) in cases where single.contains(where: { $0 != 0 }) {
                #expect(try window.samples(count: count) == single, "\(window), \(count) samples")
                #expect(try window.doubleSamples(count: count) == double, "\(window) in double precision")
                #expect(window.isGeneratedByVDSP && !window.isSymmetric)
            }
            // Half: the same call with vDSP_HALF_WINDOW gives the first (count + 1) / 2 samples.
            if count > 2 {
                let half = Array(direct(vDSP_hann_window, Int32(vDSP_HANN_DENORM | vDSP_HALF_WINDOW)).prefix((count + 1) / 2))
                #expect(try Window.hann.half.samples(count: count) == half)
                #expect(try Window.hamming.half.samples(count: count) == Array(direct(vDSP_hamm_window, Int32(vDSP_HALF_WINDOW)).prefix((count + 1) / 2)))
                #expect(try Window.blackman.half.samples(count: count) == Array(direct(vDSP_blkman_window, Int32(vDSP_HALF_WINDOW)).prefix((count + 1) / 2)))
            }
            // Symmetric: still vDSP, one sample shorter, closed with its first value.
            if count > 2 {
                var expected = direct(vDSP_hann_window, Int32(vDSP_HANN_DENORM), length: count - 1)
                expected[count - 1] = expected[0]
                let symmetric = try Window.hann.symmetric.samples(count: count)
                #expect(symmetric == expected)
                #expect(symmetric == symmetric.reversed() || count < 4 || zip(symmetric, symmetric.reversed()).allSatisfy { abs($0 - $1) < 1e-6 },
                        "the first and the last sample are equal, and so on inwards")
            }
        }
        #expect(try Window.hann.symmetric.samples(count: 1) == [1])
    }

    // MARK: The package set (WP-501b)

    @Test func thePackageWindowsMatchTheirOracle() throws {
        let golden = try GoldenFile(named: "windows", in: .module)
        #expect(golden.cases.count == 6 * 2 * (3 + 4 + 3))
        for testCase in golden.cases {
            let count = try testCase.integer("count")
            var window: Window
            switch try testCase.string("window") {
            case "rectangular": window = .rectangular
            case "blackmanHarris": window = .blackmanHarris
            case "flatTop": window = .flatTop
            case "kaiser": window = .kaiser(beta: try testCase.number("beta"))
            default: window = .gaussian(sigma: try testCase.number("sigma"))
            }
            if try testCase.integer("symmetric") == 1 { window = window.symmetric }
            let expected = try testCase.real("samples")
            let samples = try window.doubleSamples(count: count)
            expectClose(samples, expected, .absolute(1e-12), "\(testCase.name)")
            #expect(try window.samples(count: count) == samples.map { Float($0) }, "single precision is the double window rounded")
            #expect(try window.half.doubleSamples(count: count) == Array(samples.prefix((count + 1) / 2)))
        }
    }

    @Test func packageWindowsHaveTheirShape() throws {
        #expect(try Window.rectangular.samples(count: 5) == [1, 1, 1, 1, 1])
        let kaiser = try Window.kaiser(beta: 8.6).symmetric.doubleSamples(count: 101)
        #expect(kaiser[50] == 1 && kaiser[0] == kaiser[100] && kaiser[0] < 2e-3 && zip(kaiser.prefix(50), kaiser.dropFirst().prefix(50)).allSatisfy { $0 < $1 })
        #expect(try Window.kaiser(beta: 0).doubleSamples(count: 8).allSatisfy { $0 == 1 }, "beta 0 is rectangular")
        let flat = try Window.flatTop.symmetric.doubleSamples(count: 65)
        #expect(abs(flat[32] - 1.000000003) < 1e-8 && flat.min()! < 0, "a flat-top window dips below zero")
        let gauss = try Window.gaussian(sigma: 0.2).doubleSamples(count: 64)
        #expect(gauss[32] == 1 && abs(gauss[32 - 13] - exp(-0.5 * pow(13.0 / 64 / 0.2, 2))) < 1e-15, "sigma is a fraction of the frame")
        // The periodic form is the symmetric form of one more sample, without its last.
        for window in [Window.blackmanHarris, .kaiser(beta: 5), .flatTop, .gaussian(sigma: 0.3)] {
            expectClose(try window.doubleSamples(count: 32), Array(try window.symmetric.doubleSamples(count: 33).prefix(32)), .absolute(1e-15))
        }
        #expect(Window.besselI0(0) == 1 && abs(Window.besselI0(1) - 1.2660658777520084) < 1e-15 && abs(Window.besselI0(20) / 43_558_282.559553534 - 1) < 1e-14)
    }

    // MARK: Custom windows (WP-501c, WIN-2, WIN-3)

    @Test func aCustomWindowIsSampledOnceAcrossTheFrame() throws {
        let ramp = Window.custom { t in t + 0.5 }
        #expect(try ramp.doubleSamples(count: 4) == [0.5, 0.75, 1.0, 1.25], "t = n / N for the periodic form")
        #expect(try ramp.symmetric.doubleSamples(count: 5) == [0.5, 0.75, 1.0, 1.25, 1.5], "t = n / (N − 1) for the symmetric form")
        let hann = Window.custom { t in 0.5 - 0.5 * cos(2 * .pi * t) }
        expectClose(try hann.samples(count: 256), try Window.hann.samples(count: 256), .absolute(1e-6))
    }

    @Test func customWindowsCompareByTheirProbeValues() {
        let a = Window.custom { t in 0.5 - 0.5 * cos(2 * .pi * t) }
        let b = Window.custom { t in pow(sin(.pi * t), 2) * 1.0 }
        let c = Window.custom { t in 0.54 - 0.46 * cos(2 * .pi * t) }
        #expect(a == a && Set([a, a]).count == 1, "equal closures give equal descriptions")
        #expect(a != c, "different closures differ at a probe point")
        #expect(a == b || a != b, "closures that agree at the 65 probe points are the same window, whatever their text")
        #expect(a != a.symmetric && a.symmetric == a.symmetric && a != a.logged() && a.logged().isLogged, "the form and the logging are part of the description")
        let undefined = Window.custom { _ in .nan }
        #expect(undefined == undefined, "a window equals itself whatever its closure returns")
        #expect(Window.hann == .hann(.denormalized) && Window.hann != .hann(.normalized) && Window.kaiser(beta: 1) != .kaiser(beta: 2))
        #expect(Window.hann.symmetric.periodic == .hann && "\(Window.kaiser(beta: 2).symmetric.half)" == "kaiser(beta: 2.0).symmetric.half")
    }

    @Test func aWindowThatCannotBeUsedIsATypedError() {
        func refused(_ window: Window, count: Int = 16) -> Bool {
            do { _ = try window.samples(count: count); return false } catch {
                if case .invalidParameter(_, "window", _) = error { return true }
                return false
            }
        }
        #expect(refused(.custom { _ in 0 }), "zero everywhere")
        #expect(refused(.custom { t in t > 0.5 ? .nan : 1 }), "a sample that is not finite")
        #expect(refused(.custom { t in 1 / (t - 0.25) }), "an infinity")
        #expect(refused(.hann, count: 0) && refused(.rectangular, count: -3) && refused(.hann, count: 1), "no samples, or a single zero")
        #expect(refused(.kaiser(beta: -1)) && refused(.kaiser(beta: .infinity)) && refused(.gaussian(sigma: 0)) && refused(.gaussian(sigma: .nan)))
        #expect(!refused(.custom { t in t }), "a window may be zero somewhere")
    }
}
