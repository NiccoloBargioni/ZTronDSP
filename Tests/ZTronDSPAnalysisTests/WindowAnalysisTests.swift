import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `WindowAnalysis` (WP-501d, WP-501e, WP-501f) and the diagnostics of a logged window
/// (WP-501g).
@Suite("Window analysis")
struct WindowAnalysisTests {
    private func window(_ name: String, _ golden: GoldenCase) throws -> Window {
        switch name {
        case "rectangular": .rectangular
        case "hann": .hann
        case "hamming": .hamming
        case "blackman": .blackman
        case "blackmanHarris": .blackmanHarris
        case "flatTop": .flatTop
        case "kaiser": .kaiser(beta: try golden.number("beta"))
        default: .gaussian(sigma: try golden.number("sigma"))
        }
    }

    static let cases = ["rectangular", "hann", "hamming", "blackman", "blackmanHarris", "flatTop", "kaiser-beta8.6", "gaussian-sigma0.15"]
        .flatMap { name in [64, 1_024, 4_096].map { "\(name)-\($0)" } }

    // MARK: Gains and spectral figures against the reference (WP-501d, WP-501f)

    @Test(arguments: cases)
    func theFiguresOfTheStockWindowsEqualTheReference(name: String) async throws {
        let golden = try GoldenFile(named: "window_analysis", in: .module).require(name)
        let count = try golden.integer("count")
        let analysis = try await window(try golden.string("window"), golden).analysis(frame: count, hop: count / 4)
        let half = try await window(try golden.string("window"), golden).analysis(frame: count, hop: count / 2)

        let gains = try golden.real("gains")
        expectClose(analysis.peak, gains[0], .relative(1e-12))
        expectClose(analysis.coherentGain, gains[1], .relative(1e-12))
        expectClose(analysis.noiseGain, gains[2], .relative(1e-12))
        expectClose(try #require(analysis.equivalentNoiseBandwidth), gains[3], .relative(1e-12))
        expectClose(try #require(analysis.amplitudeNormalization), 2 / (gains[1] * Double(count)), .relative(1e-12))
        expectClose(analysis.powerNormalization, (2 / (gains[2] * Double(count) * Double(count))).squareRoot(), .relative(1e-12))

        // Within 0.05 bin and 0.1 dB of the figures read from the transform itself.
        let spectrum = try golden.real("spectrum")
        expectClose(analysis.mainLobeWidthAtHalfPower, spectrum[0], .absolute(0.05), "main lobe at −3 dB, bins")
        if try golden.integer("hasNull") == 1 {
            expectClose(try #require(analysis.mainLobeWidthNullToNull), spectrum[1], .absolute(0.05), "main lobe null to null, bins")
        }
        if try golden.integer("hasSideLobe") == 1 {
            expectClose(try #require(analysis.peakSideLobe), spectrum[2], .absolute(0.1), "peak side lobe, dB")
        }
        expectClose(analysis.scallopingLoss, spectrum[3], .absolute(0.1), "scalloping loss, dB")
        if try golden.integer("hasFallOff") == 1 {
            expectClose(try #require(analysis.sideLobeFallOff), spectrum[4], .absolute(0.1), "side-lobe fall-off, dB per octave")
        } else {
            #expect(analysis.sideLobeFallOff == nil)
        }

        let overlap = try golden.real("overlap")
        #expect(analysis.isNonZeroOverlapAdd == (overlap[0] == 1) && analysis.isConstantOverlapAdd == (overlap[1] == 1), "a quarter-frame hop: scipy.signal.check_NOLA, check_COLA")
        #expect(half.isNonZeroOverlapAdd == (overlap[2] == 1) && half.isConstantOverlapAdd == (overlap[3] == 1), "a half-frame hop")
        #expect(analysis.spectrum.count == 8 * count + 1 && analysis.spectrumBinStep == 1.0 / 16 && analysis.spectrum[0] == 0)
        #expect(analysis.frame == count && analysis.hop == count / 4 && analysis.samples.count == count)
    }

    // MARK: Shape, edges, the tail (WP-501d)

    @Test func shapeAndEdgesOfTheStockWindows() async throws {
        let hann = try await Window.hann.analysis(frame: 256)
        #expect(hann.isSymmetric && hann.isNonNegative && hann.isFinite && hann.leadingEdgeValue == 0 && hann.trailingEdgeValue == 0)
        #expect(hann.tailLimit == .zero && hann.isAbsolutelyIntegrableOnLine == true && hann.isSquareIntegrableOnLine == true, "a stock window is defined on the frame only")
        #expect(hann.hop == nil && hann.isNonZeroOverlapAdd == nil && hann.isConstantOverlapAdd == nil && hann.overlapRipple == nil && hann.frameBoundRatio == nil)
        let hamming = try await Window.hamming.symmetric.analysis(frame: 257)
        #expect(hamming.isSymmetric && abs(hamming.leadingEdgeValue - 0.08) < 1e-6 && abs(hamming.trailingEdgeValue - 0.08) < 1e-6)
        let flatTop = try await Window.flatTop.analysis(frame: 256)
        #expect(!flatTop.isNonNegative && flatTop.isSymmetric, "the flat-top window dips below zero")
        let ramp = try await Window.custom { $0 }.analysis(frame: 256)
        #expect(!ramp.isSymmetric && ramp.leadingEdgeValue == 0 && ramp.trailingEdgeValue == 1 && ramp.isNonNegative)
        let odd = try await Window.custom { $0 < 0.5 ? 1 : -1 }.analysis(frame: 256)
        #expect(odd.equivalentNoiseBandwidth == nil && odd.amplitudeNormalization == nil && odd.coherentGain == 0 && !odd.isNonNegative, "no sum to normalise by")
        let half = try await Window.hann.half.analysis(frame: 256)
        #expect(half.frame == 128 && half.samples.count == 128 && !half.isSymmetric, "a half window is analysed as the samples it has")
    }

    @Test func theTailOfACustomWindowIsFollowedWhenItsFunctionIsGiven() async throws {
        func tail(_ function: @escaping @Sendable (Double) -> Double) async throws -> WindowAnalysis {
            try await Window.custom(function).analysis(frame: 128, tail: function)
        }
        let gaussian = try await tail { exp(-18 * ($0 - 0.5) * ($0 - 0.5)) }
        #expect(gaussian.tailLimit == .zero && gaussian.isAbsolutelyIntegrableOnLine == true && gaussian.isSquareIntegrableOnLine == true)
        let constant = try await tail { _ in 1 }
        #expect(constant.tailLimit == .value(1) && constant.isAbsolutelyIntegrableOnLine == false && constant.isSquareIntegrableOnLine == false,
                "a closure that does not decay is a truncated function, not a window")
        let raisedCosine = try await tail { 0.54 - 0.46 * cos(2 * .pi * $0) }
        guard case .value(let edge)? = raisedCosine.tailLimit else {
            Issue.record("a raised cosine reads its edge value at whole frame lengths, reported as \(String(describing: raisedCosine.tailLimit))")
            return
        }
        expectClose(edge, 0.08, .absolute(1e-12), "at whole frame lengths a periodic function reads its edge value: a verdict holds at the grid named (WIN-6)")
        let diverging = try await tail { $0 * $0 + 1 }
        #expect(diverging.tailLimit == .unbounded && diverging.isAbsolutelyIntegrableOnLine == false)
        let exploding = try await tail { abs($0) > 1_000 ? .infinity : 1 }
        #expect(exploding.tailLimit == .unbounded)
        // Growth of any speed is growth: in proportion, as a square root, as a logarithm.
        let growing: [(name: String, function: @Sendable (Double) -> Double)] = [
            ("|t|", { abs($0) + 1 }), ("√|t|", { abs($0).squareRoot() + 1 }), ("ln |t|", { log(1 + abs($0)) + 1 }),
        ]
        for growth in growing {
            let analysis = try await tail(growth.function)
            #expect(analysis.tailLimit == .unbounded, "\(growth.name) is reported as \(String(describing: analysis.tailLimit))")
        }
        let undefined = try await tail { abs($0) > 100 ? .nan : 1 }
        #expect(undefined.tailLimit == .undefined && undefined.isAbsolutelyIntegrableOnLine == false, "it stops returning numbers far out")
        let oscillating = try await tail { $0 >= 0 && $0 <= 1 ? 1 : sin($0) }
        #expect(oscillating.tailLimit == .undefined)
        let lopsided = try await tail { $0 < 0 ? 0 : 1 }
        #expect(lopsided.tailLimit == .undefined, "0 on one side, 1 on the other: no limit")
        let settling = try await tail { 1 + 1 / (1 + abs($0)) }
        guard case .value(let limit)? = settling.tailLimit else {
            Issue.record("1 + 1/|t| tends to 1, reported as \(String(describing: settling.tailLimit))")
            return
        }
        expectClose(limit, 1, .absolute(1e-5))
        // 1/|t| tends to 0 but not fast enough to be integrated; its square is.
        let slow = try await tail { 1 / (1 + abs($0 - 0.5)) }
        #expect(slow.tailLimit == .zero && slow.isAbsolutelyIntegrableOnLine == false && slow.isSquareIntegrableOnLine == true)
        let fast = try await tail { 1 / (1 + ($0 - 0.5) * ($0 - 0.5)) }
        #expect(fast.tailLimit == .zero && fast.isAbsolutelyIntegrableOnLine == true)
    }

    @Test func withoutItsFunctionACustomWindowIsNotExaminedOutsideTheFrame() async throws {
        let analysis = try await Window.custom { exp(-18 * ($0 - 0.5) * ($0 - 0.5)) }.analysis(frame: 128)
        #expect(analysis.tailLimit == nil && analysis.isAbsolutelyIntegrableOnLine == nil && analysis.isSquareIntegrableOnLine == nil)
        #expect(analysis.isAbsolutelyIntegrableOnFrame && analysis.isSquareIntegrableOnFrame, "what the frame holds is examined all the same")
    }

    // MARK: Continuity and smoothness (WP-501e)

    @Test(arguments: [16, 64, 1_024, 2_048, 16_384])
    func smoothnessIsTheOrderOfTheLowestDerivativeThatJumps(frame: Int) async throws {
        let rectangular = try await Window.rectangular.analysis(frame: frame)
        #expect(rectangular.smoothness == 0 && rectangular.predictedSideLobeFallOff == -6, "the rectangular window itself jumps, at its edges")
        #expect(rectangular.discontinuities.map { $0.size } == [1, 1] && rectangular.discontinuities.first?.position == 0)
        #expect(rectangular.discontinuities.last?.position == 1, "at the edges of the frame, exactly")

        let triangular = try await Window.custom { 1 - abs(2 * $0 - 1) }.analysis(frame: frame)
        #expect(triangular.smoothness == 1 && triangular.predictedSideLobeFallOff == -12 && triangular.discontinuities.isEmpty, "the slope of a triangle jumps")

        let hann = try await Window.hann.analysis(frame: frame)
        #expect(hann.smoothness == 2 && hann.predictedSideLobeFallOff == -18 && hann.discontinuities.isEmpty, "the curvature of a Hann window jumps at its edges")

        let blackman = try await Window.blackman.analysis(frame: frame)
        #expect(blackman.smoothness == 2 && blackman.discontinuities.isEmpty)
        let hamming = try await Window.hamming.analysis(frame: frame)
        #expect(hamming.smoothness == 0 && hamming.discontinuities.count == 2 && hamming.discontinuities.allSatisfy { abs($0.size - 0.08) < 1e-3 },
                "a Hamming window stops 0.08 above zero")
    }

    @Test func higherOrdersAreToldApart() async throws {
        // sin³ and sin⁴ of πt: the third and the fourth derivative are the first to jump at the edges.
        let cubed = try await Window.custom { pow(sin(.pi * $0), 3) }.analysis(frame: 1_024)
        #expect(cubed.smoothness == 3)
        let fourth = try await Window.custom { pow(sin(.pi * $0), 4) }.analysis(frame: 1_024)
        #expect(fourth.smoothness == 4)
        // Smooth to every order the analysis looks at: reported as the highest.
        let bump = try await Window.custom { $0 > 0 && $0 < 1 ? exp(4 - 1 / ($0 * (1 - $0))) : 0 }.analysis(frame: 1_024)
        #expect(bump.smoothness == 4 && bump.discontinuities.isEmpty, "4 stands for the fourth derivative or any beyond it")
    }

    @Test(arguments: [(64, 0.3), (1_024, 0.3), (1_024, 0.7183), (4_096, 0.123456), (16_384, 0.6)])
    func anInteriorJumpIsLocatedWithinOneSample(frame: Int, position: Double) async throws {
        let analysis = try await Window.custom { $0 < position ? 0.5 : 1 }.analysis(frame: frame)
        #expect(analysis.smoothness == 0)
        let interior = analysis.discontinuities.filter { $0.position > 0.01 && $0.position < 0.99 }
        #expect(interior.count == 1, "\(analysis.discontinuities)")
        let jump = try #require(interior.first)
        #expect(abs(jump.position - position) <= 1.0 / Double(Swift.min(frame, 4_096)), "found at \(jump.position), within one sample of \(position)")
        expectClose(jump.size, 0.5, .absolute(1e-9))
        // The edges are jumps too: from 0 outside to 0.5, and from 1 to 0.
        #expect(analysis.discontinuities.count == 3 && analysis.discontinuities.first?.size == 0.5 && analysis.discontinuities.last?.size == 1)
        #expect(analysis.leadingEdgeValue == 0.5 && analysis.trailingEdgeValue == 1)
        #expect(analysis.isAbsolutelyIntegrableOnFrame && analysis.isSquareIntegrableOnFrame, "a jump does not stop a function from being integrated")
    }

    @Test func aKinkIsNotAJump() async throws {
        // Flat, then a slope: continuous, with a first derivative that jumps where the slope starts.
        let analysis = try await Window.custom { Swift.max($0 - 0.37, 0) * (1 - $0) + 0.2 * sin(.pi * $0) }.analysis(frame: 1_024)
        #expect(analysis.discontinuities.isEmpty && analysis.smoothness == 1)
    }

    @Test func integrabilityOnTheFrame() async throws {
        let smooth = try await Window.kaiser(beta: 6).analysis(frame: 512)
        #expect(smooth.isAbsolutelyIntegrableOnFrame && smooth.isSquareIntegrableOnFrame)
        // 1/|t − 1/3| is finite at every grid point and has no integral; its square root has one.
        let pole = try await Window.custom { 1e-3 / abs($0 - 1.0 / 3) }.analysis(frame: 512)
        #expect(!pole.isAbsolutelyIntegrableOnFrame && !pole.isSquareIntegrableOnFrame)
        let root = try await Window.custom { 1e-2 / abs($0 - 1.0 / 3).squareRoot() }.analysis(frame: 512)
        #expect(root.isAbsolutelyIntegrableOnFrame && !root.isSquareIntegrableOnFrame, "integrable, but its square is not")
        #expect(WindowAnalysis.converges([1, .infinity, 1], variation: [1, 1, 1], coarsest: 4) == false)
        #expect(WindowAnalysis.converges([1, 1.5, 1.6], variation: [9, 9, 9], coarsest: 4) && WindowAnalysis.converges([1, 1, 1], variation: [0, 0, 0], coarsest: 4))
    }

    // MARK: Overlap-add (WP-501f)

    @Test func overlapAddForAHop() async throws {
        let hann = try await Window.hann.analysis(frame: 1_024, hop: 256)
        #expect(hann.isNonZeroOverlapAdd == true && hann.isConstantOverlapAdd == true && (hann.overlapRipple ?? 1) < 1e-12)
        expectClose(try #require(hann.frameBoundRatio), 1, .absolute(1e-12))
        let apart = try await Window.hann.analysis(frame: 1_024, hop: 1_024)
        #expect(apart.isNonZeroOverlapAdd == false && apart.isConstantOverlapAdd == false && apart.frameBoundRatio == nil, "a Hann window is zero where frames that do not overlap meet")
        expectClose(try #require(apart.overlapRipple), 1, .absolute(1e-12))
        let uneven = try await Window.hann.analysis(frame: 1_024, hop: 700)
        #expect(uneven.isNonZeroOverlapAdd == true && uneven.isConstantOverlapAdd == false && (uneven.frameBoundRatio ?? 0) > 1.5)
        let rectangular = try await Window.rectangular.analysis(frame: 512, hop: 512)
        #expect(rectangular.isNonZeroOverlapAdd == true && rectangular.isConstantOverlapAdd == true)
        let beyond = try await Window.rectangular.analysis(frame: 512, hop: 600)
        #expect(beyond.isNonZeroOverlapAdd == false && beyond.isConstantOverlapAdd == false, "a hop above the frame leaves samples no frame reaches")
    }

    // MARK: Errors, cancellation, the background (BG-1…3)

    @Test func whatCannotBeAnalysedIsATypedError() async {
        await #expect(throws: DSPError.self) { _ = try await Window.hann.analysis(frame: 0) }
        await #expect(throws: DSPError.self) { _ = try await Window.hann.analysis(frame: 1 << 23) }
        await #expect(throws: DSPError.self) { _ = try await Window.hann.analysis(frame: 64, hop: 0) }
        await #expect(throws: DSPError.self) { _ = try await Window.custom { _ in 0 }.analysis(frame: 64) }
        await #expect(throws: DSPError.self) { _ = try await Window.custom { $0 > 0.5 ? .nan : 1 }.analysis(frame: 64) }
        await #expect(throws: DSPError.self) { _ = try await Window.kaiser(beta: -1).analysis(frame: 64) }
    }

    @Test func theAnalysisRunsInTheBackgroundAndCanBeCancelled() async throws {
        let onBackground = Observed()
        let analysis = try await Window.custom { t in
            if BackgroundWork.isCurrent && !Thread.isMainThread { onBackground.note(1) }
            return 0.5 - 0.5 * cos(2 * .pi * t)
        }.analysis(frame: 256)
        #expect(analysis.smoothness == 2 && !onBackground.lengths.isEmpty, "the closure is evaluated on the background executor (BG-1)")

        let task = Task { try await Window.kaiser(beta: 9).analysis(frame: 1 << 20, hop: 4_096) }
        task.cancel()
        let result = await task.result
        #expect(throws: DSPError.cancelled) { _ = try result.get() }
    }

    @Test func aReportIsAValue() async throws {
        let a = try await Window.hann.analysis(frame: 128, hop: 32), b = try await Window.hann.analysis(frame: 128, hop: 32)
        let c = try await Window.hann.analysis(frame: 128, hop: 64)
        #expect(a == b && a.hashValue == b.hashValue && a != c)
        #expect(a.lines.count == 18 && a.description.contains("window hann: 128 samples, hop 32") && a.description.contains("smoothness: 2"))
        let plain = try await Window.custom { $0 }.analysis(frame: 128)
        #expect(plain.lines.count == 17 && plain.description.contains("not examined"))
    }

    // MARK: Diagnostics at attach (WP-501g, WIN-5)

    @Test func aLoggedWindowIsReportedOncePerAttachmentAndNeverOtherwise() throws {
        let signal = TestSignal.whiteNoise(count: 4_096, seed: 1)
        func logged(_ pipeline: Pipeline<Samples, Samples>) throws -> [[String]] {
            let heard = Recorded()
            try WindowDiagnostics.$recorder.withValue({ heard.note($0) }) { try pipeline.run(on: signal, format: mono48) }
            return heard.reports
        }
        let feed = HeatmapFeed(history: 8), other = HeatmapFeed(history: 8)
        let silent = try logged(Pipeline { Spectrogram(frame: 1_024, hop: 256, window: .hann, to: feed) })
        #expect(silent.isEmpty, "nothing is logged unless it is asked for")

        let once = try logged(Pipeline { Spectrogram(frame: 1_024, hop: 256, window: .hann.logged(), to: feed) })
        #expect(once.count == 1, "one report per attachment")
        let report = try #require(once.first)
        #expect(report.count == 18 && report[0] == "window hann: 1024 samples, hop 256", "one line per property: \(report)")
        #expect(report.contains("smoothness: 2 (side lobes predicted to fall by 18 dB per octave)") && report.contains { $0.hasPrefix("non-zero overlap-add: yes; constant overlap-add: yes") })

        // Two taps with the same logged framing are one framing step (F5): one report.
        let shared = try logged(Pipeline {
            Spectrogram(frame: 1_024, hop: 256, window: .hann.logged(), normalization: .none, to: feed)
            MelSpectrogram(frame: 1_024, hop: 256, bands: 20, window: .hann.logged(), to: other)
        })
        #expect(shared.count == 1)
        // Two different logged windows are two reports; an unlogged twin of a logged one stays silent.
        let two = try logged(Pipeline {
            Tap { STFT(frame: 1_024, hop: 256, window: .hamming.logged()); Power(); Decibels(); Emit(to: feed) }
            Tap { STFT(frame: 512, hop: 128, window: .custom { 0.5 - 0.5 * cos(2 * .pi * $0) }.logged()); Power(); Decibels(); Emit(to: other) }
            Tap { STFT(frame: 1_024, hop: 256, window: .hamming); Emit(to: CountingSink<Spectrum<LinearFrequency, ComplexValues>>()) }
        })
        #expect(two.count == 2 && two.contains { $0[0] == "window hamming: 1024 samples, hop 256" } && two.contains { $0[0] == "window custom: 512 samples, hop 128" })
    }
}

/// What a test hears of the window diagnostics logged on its task.
final class Recorded: @unchecked Sendable {
    // Threading: written and read by the test's own task.
    private(set) var reports: [[String]] = []
    func note(_ lines: [String]) { reports.append(lines) }
}
