import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

/// The inversion report of `Decimate` (WP-539): the sampling theorem, tested on the signal;
/// a band-limited fixture passes, an aliasing fixture fails with the aliased energy within
/// 1 dB of the truth.
@Suite("Decimate inversion report")
struct DecimateInversionTests {
    /// A sum of sines at 48 kHz, one second long.
    private func tones(_ parts: [(frequency: Double, amplitude: Double)]) -> [Float] {
        var signal = [Float](repeating: 0, count: 48_000)
        for (index, part) in parts.enumerated() {
            let tone = TestSignal.sine(frequency: part.frequency, sampleRate: 48_000, count: 48_000, amplitude: part.amplitude, phase: Double(index) * 0.9)
            signal = TestSignal.sum(signal, tone)
        }
        return signal
    }

    // MARK: A band-limited fixture passes

    @Test func aBandLimitedFixturePasses() async throws {
        // Tones below 0.8 of the Nyquist frequency after decimation by 4: 4.8 kHz of 6 kHz at 48 kHz.
        let signal = tones([(440, 0.4), (2_500, 0.3), (4_700, 0.2)])
        let report = try await Decimate(by: 4).inversionReport(for: signal, sampleRate: 48_000)
        #expect(report.stage == "Decimate" && report.inverse == "Interpolate" && report.sampleRate == 48_000)
        #expect(report.conditions.map { $0.name } == ["sampling theorem", "transition band", "pass-band ripple"])
        let theorem = report.conditions[0], transition = report.conditions[1], ripple = report.conditions[2]
        #expect(theorem.holds && theorem.isNecessary && theorem.observed <= 1e-10 && theorem.margin >= 0, "the share at or above 6 kHz is \(theorem.observed)")
        #expect(theorem.theorem.contains("Shannon 1949") && theorem.quantity.contains("6000.0 Hz"))
        #expect(transition.holds && transition.isNecessary && transition.observed <= 1e-10 && transition.margin >= 0, "the share between 4.8 and 6 kHz is \(transition.observed)")
        #expect(report.isExactlyInvertible, "nothing of the signal is lost")
        // The filters ripple by about what they reject by: 80 dB, 10⁻⁴. The round trip is exact to within twice that.
        #expect(!ripple.isNecessary && ripple.observed > 1e-6 && ripple.observed < 3e-4, "the pass band ripples by \(ripple.observed)")
        let measured = try #require(report.measuredError)
        let error = pow(10, -measured.signalToNoiseRatio / 20)
        print("measured WP-539: band-limited fixture, Decimate(by: 4): ripple \(ripple.observed) (holds: \(ripple.holds), margin \(ripple.margin) dB); predicted error \(report.predictedError); round trip SNR \(measured.signalToNoiseRatio) dB over \(measured.count) samples, relative error \(measured.relativeError)")
        #expect(error <= report.predictedError && measured.relativeError <= report.predictedError, "what is measured lies within what is predicted")
        #expect(measured.signalToNoiseRatio > 70 && measured.count > 40_000)

        // A steeper filter ripples less: the same fixture then comes back above 100 dB.
        let steep = try await Decimate(by: 4, rejection: .decibels(130)).inversionReport(for: signal, sampleRate: 48_000)
        let steepMeasured = try #require(steep.measuredError)
        print("measured WP-539: band-limited fixture, Decimate(by: 4, rejection: 130 dB): ripple \(steep.conditions[2].observed); predicted error \(steep.predictedError); round trip SNR \(steepMeasured.signalToNoiseRatio) dB")
        #expect(steep.isExactlyInvertible && steepMeasured.signalToNoiseRatio > 100 && steep.conditions[2].observed < ripple.observed)
        #expect(pow(10, -steepMeasured.signalToNoiseRatio / 20) <= steep.predictedError)
    }

    @Test(arguments: [2, 3, 8])
    func otherFactorsPassTheirOwnBand(factor: Int) async throws {
        // One tone at half the pass band of the factor, one near its edge.
        let edge = 0.8 * 24_000 / Double(factor)
        let report = try await Decimate(by: factor).inversionReport(for: tones([(0.5 * edge, 0.4), (0.95 * edge, 0.3)]), sampleRate: 48_000)
        let measured = try #require(report.measuredError)
        #expect(report.isExactlyInvertible && measured.signalToNoiseRatio > 70, "factor \(factor): SNR \(measured.signalToNoiseRatio) dB")
        #expect(pow(10, -measured.signalToNoiseRatio / 20) <= report.predictedError)
    }

    // MARK: An aliasing fixture fails, the aliased energy within 1 dB of the truth

    @Test(arguments: [(0.3, 0.3), (0.5, 0.05), (0.1, 0.4), (0.4, 0.002)])
    func anAliasingFixtureFailsWithTheAliasedEnergyWithinOneDecibel(inBand: Double, above: Double) async throws {
        // One tone in the band, one above the new Nyquist frequency of 6 kHz: its energy is what would alias.
        let signal = tones([(1_000, inBand), (9_000, above)])
        let truth = above * above / (inBand * inBand + above * above)
        let report = try await Decimate(by: 4).inversionReport(for: signal, sampleRate: 48_000)
        let theorem = report.conditions[0]
        #expect(theorem.name == "sampling theorem" && !theorem.holds && !report.isExactlyInvertible && theorem.margin < 0, "the condition fails")
        let deviation = abs(10 * log10(theorem.observed / truth))
        print("measured WP-539: aliasing fixture, amplitudes \(inBand) in the band and \(above) above it: share \(theorem.observed), truth \(truth): \(deviation) dB apart (tolerance 1 dB)")
        #expect(deviation <= 1, "share \(theorem.observed), truth \(truth): \(deviation) dB apart")
        #expect(report.conditions[1].holds, "nothing lies in the transition band")
        // The decimator removes the tone above; nothing of it is folded into the band. What is
        // measured is the tone that is missing.
        let measured = try #require(report.measuredError)
        expectClose(report.predictedError, truth.squareRoot(), .relative(0.12))
        expectClose(pow(10, -measured.signalToNoiseRatio / 20), truth.squareRoot(), .relative(0.15), "measured: \(measured.signalToNoiseRatio) dB")
    }

    @Test func energyInTheTransitionBandIsLostToTheFilters() async throws {
        // 5.6 kHz lies below the new Nyquist frequency of 6 kHz and above the pass band of 4.8 kHz.
        let signal = tones([(1_000, 0.4), (5_600, 0.2)])
        let truth = 0.04 / (0.16 + 0.04)
        let report = try await Decimate(by: 4).inversionReport(for: signal, sampleRate: 48_000)
        let theorem = report.conditions[0], transition = report.conditions[1]
        #expect(theorem.holds, "the sampling theorem holds: the share at or above 6 kHz is \(theorem.observed)")
        #expect(transition.name == "transition band" && !transition.holds && transition.margin < 0 && !report.isExactlyInvertible)
        #expect(abs(10 * log10(transition.observed / truth)) <= 1, "share \(transition.observed), truth \(truth)")
        // The filters take part of it, at most all of it.
        let measured = try #require(report.measuredError)
        let error = pow(10, -measured.signalToNoiseRatio / 20)
        #expect(error > 0.01 && error <= report.predictedError, "measured \(error), predicted at most \(report.predictedError)")
    }

    // MARK: Without a signal; the inverse; a factor of 1

    @Test func withoutASignalTheReportHoldsTheFilterAlone() async throws {
        let report = try await Decimate(by: 4).inversionReport()
        #expect(report.conditions.map { $0.name } == ["pass-band ripple"] && report.measuredError == nil && report.roundTrip == nil)
        #expect(report.isExactlyInvertible && report.predictedError > 0 && report.predictedError < 1e-3)
        #expect(report.conditions[0].theorem.contains("Kaiser 1974"))
        // The inverse is the interpolator with the same filter (INV-1).
        #expect(Decimate(by: 3, rejection: .decibels(60), passband: 0.7).inverse == Interpolate(by: 3, rejection: .decibels(60), passband: 0.7))
        #expect(Decimate(by: 3).inverse == Interpolate(by: 3) && Decimate(by: 3, isActive: false).inverse.activation == .active)
        // A filter that rejects less ripples more.
        let loose = try await Decimate(by: 4, rejection: .decibels(40)).inversionReport()
        #expect(loose.conditions[0].observed > report.conditions[0].observed && loose.predictedError > report.predictedError)
    }

    @Test func aFactorOfOneIsNoStage() async throws {
        let noise = TestSignal.gaussianNoise(count: 8_000, seed: 539, standardDeviation: 0.2)
        let report = try await Decimate(by: 1).inversionReport(for: noise, sampleRate: 48_000)
        #expect(report.conditions.map { $0.name } == ["sampling theorem"] && report.conditions[0].observed == 0 && report.isExactlyInvertible)
        #expect(report.predictedError == 0 && report.measuredError?.largestError == 0 && report.measuredError?.count == 8_000, "there is no filter, and nothing to lose")
        let bare = try await Decimate(by: 1).inversionReport()
        #expect(bare.conditions.isEmpty && bare.isExactlyInvertible)
    }

    @Test func theReportFollowsWhatPrecedesTheStage() async throws {
        // 9 kHz passes a first decimation by 2, whose band reaches 9.6 kHz, and lies above the 6 kHz a second one leaves.
        let signal = tones([(1_000, 0.3), (9_000, 0.3)])
        let report = try await Decimate(by: 2).inversionReport(for: signal, sampleRate: 48_000, after: Pipeline().appending(Decimate(by: 2)))
        let theorem = report.conditions[0]
        #expect(!theorem.holds && abs(10 * log10(theorem.observed / 0.5)) <= 1, "half the energy that arrives lies above: \(theorem.observed)")
        #expect(theorem.quantity.contains("1/4 of the sample rate the stage is given"))
        let alone = try await Decimate(by: 2).inversionReport(for: signal, sampleRate: 48_000)
        #expect(alone.isExactlyInvertible && alone.conditions[0].quantity.contains("12000.0 Hz"))
    }

    // MARK: Errors, cancellation

    @Test func nonsenseIsRefusedAndAReportCanBeCancelled() async {
        let signal = tones([(1_000, 0.3)])
        await #expect(throws: DSPError.self) { _ = try await Decimate(by: 0).inversionReport(for: signal) }
        await #expect(throws: DSPError.self) { _ = try await Decimate(by: 4, passband: 1.5).inversionReport() }
        await #expect(throws: DSPError.self) { _ = try await Decimate(by: 4, rejection: .decibels(.infinity)).inversionReport(for: signal) }
        await #expect(throws: DSPError.self) { _ = try await Decimate(by: 4).inversionReport(for: signal, sampleRate: 0) }
        let task = Task { try await Decimate(by: 64).inversionReport(for: signal + signal + signal + signal, sampleRate: 48_000) }
        task.cancel()
        let result = await task.result
        #expect(throws: DSPError.cancelled) { _ = try result.get() }
        // The measurement of the ripple looks at the checkpoint itself.
        let cancelled = InversionContext(samples: nil, sampleRate: 48_000, upstream: [], checkpoint: BackgroundWork.Checkpoint(state: Locked(true)))
        #expect(throws: DSPError.cancelled) { _ = try RateChangeFilter.ripple(of: [0.25, 0.5, 0.25], upTo: 0.1, context: cancelled) }
        // A signal shorter than the filters reach leaves nothing to compare.
        let short = try? await Decimate(by: 4).inversionReport(for: Array(signal[..<300]), sampleRate: 48_000)
        #expect(short?.measuredError?.count == 0 && short?.roundTrip?.original.isEmpty == true)
    }

    // MARK: The ripple of a filter

    @Test func theRippleIsTheLargestDeviationOfTheGainFromOne() throws {
        let context = InversionContext(samples: nil, sampleRate: 48_000)
        // [¼, ½, ¼] has the gain ½ + ½·cos ω: it falls from 1 as the frequency rises.
        for edge in [0.01, 0.1, 0.25] {
            expectClose(try RateChangeFilter.ripple(of: [0.25, 0.5, 0.25], upTo: edge, context: context), 0.5 - 0.5 * cos(2 * .pi * edge), .relative(1e-12))
        }
        #expect(try RateChangeFilter.ripple(of: [1], upTo: 0.25, context: context) == 0 && RateChangeFilter.ripple(of: [0.25, 0.5, 0.25], upTo: 0, context: context) == 0)
        // The low-pass of a rate change ripples by about what it rejects by, whatever the factor.
        for (factor, rejection) in [(2, 60.0), (4, 80.0), (16, 100.0)] {
            let taps = try DSP.rateChangeTaps(by: factor, rejection: .decibels(rejection))
            let ripple = try RateChangeFilter.ripple(of: taps, upTo: 0.8 * 0.5 / Double(factor), context: context)
            print("measured WP-539: low-pass of a rate change by \(factor), \(rejection) dB, \(taps.count) taps: pass-band ripple \(ripple) against a stop-band tolerance of \(pow(10, -rejection / 20))")
            #expect(ripple > 0 && ripple < 3 * pow(10, -rejection / 20), "factor \(factor), \(rejection) dB: \(ripple)")
        }
        // A long filter is measured within its budget: the grid is coarser, not the time longer.
        let long = [Double](repeating: 0, count: RateChangeFilter.budget / 32) + [1] + [Double](repeating: 0, count: RateChangeFilter.budget / 32)
        #expect(try RateChangeFilter.ripple(of: long, upTo: 0.4, context: context) == 0)
    }
}
