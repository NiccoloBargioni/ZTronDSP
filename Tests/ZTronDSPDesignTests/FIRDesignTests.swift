import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

private func firResponse(named name: String, edges: [Double]) -> FilterResponse {
    switch name {
    case "lowpass": .lowPass(cutoff: edges[0])
    case "highpass": .highPass(cutoff: edges[0])
    case "bandpass": .bandPass(from: edges[0], to: edges[1])
    default: .bandStop(from: edges[0], to: edges[1])
    }
}

/// WP-423. Windowed-sinc FIR design, four responses, Kaiser estimates. Acceptance: golden
/// (`firwin`, `kaiserord`; four responses; lengths 31, 101, 255; Hann and Kaiser windows; taps
/// within 1e-9).
@Suite("Windowed-sinc FIR design (WP-423)")
struct WindowedSincTests {
    @Test func theTapsMatchTheOracle() throws {
        let file = try Golden.firDesign.get()
        var checked = 0
        for golden in file.cases where golden.name.hasPrefix("firwin-") {
            let response = firResponse(named: try golden.string("response"), edges: try golden.numbers("edges"))
            let length = try golden.integer("length")
            let rate = try golden.number("sample_rate")
            let design: FIRDesign
            switch try golden.string("window") {
            case "hann": design = try FIRDesign(.windowedSinc(window: .hann), response, length: length, sampleRate: rate)
            case "kaiser": design = try FIRDesign(.windowedSinc(window: .kaiser(beta: try golden.number("beta"))), response, length: length, sampleRate: rate)
            case "width": design = try FIRDesign(.windowedSinc(), response, length: length, transition: try golden.number("transition"), sampleRate: rate)
            default: design = try FIRDesign(.windowedSinc(), response, length: length, sampleRate: rate)
            }
            let expected = try golden.real("taps")
            expectClose(design.taps, expected, .absolute(1e-9), golden.name)
            Measurements.shared.record("WP-423 windowed-sinc taps against firwin, absolute", zip(design.taps, expected).map { abs($0 - $1) }.max() ?? 1, bound: 1e-9)
            #expect(design.length == length && design.response == response && design.sampleRate == rate)
            checked += 1
        }
        // Four responses × lengths 31, 101, 255 × two windows, the even lengths, the two Kaiser choices.
        #expect(checked == 4 * 3 * 2 + 2 * 2 * 2 + 4 + 1)
    }

    @Test func kaisersEstimatesMatchTheOracle() throws {
        let file = try Golden.firDesign.get()
        var checked = 0
        for golden in file.cases where golden.name.hasPrefix("kaiserord-") {
            let width = try golden.number("width")
            let estimate = try WindowedSincMethod.kaiserEstimate(
                attenuation: .decibels(try golden.number("attenuation")), transition: width * 24_000, sampleRate: 48_000)
            let length = try golden.integer("length")
            #expect(estimate.length == length, "\(golden.name)")
            expectClose(estimate.beta, try golden.scalar("beta"), .absolute(1e-12), golden.name)
            // The default estimate of a method is Kaiser's.
            let fallback = try Boxcar().estimatedLength(transition: width * 24_000, attenuation: .decibels(try golden.number("attenuation")), sampleRate: 48_000)
            #expect(fallback == estimate.length)
            checked += 1
        }
        #expect(checked == 21)
        #expect(thrownError { _ = try WindowedSincMethod.kaiserEstimate(attenuation: .decibels(7.9), transition: 100, sampleRate: 48_000) }?.invalidParameterName == "attenuation")
        #expect(thrownError { _ = try WindowedSincMethod.kaiserEstimate(attenuation: .decibels(80), transition: 0, sampleRate: 48_000) }?.invalidParameterName == "transition")
        #expect(thrownError { _ = try WindowedSincMethod.kaiserEstimate(attenuation: .decibels(80), transition: 1e-9, sampleRate: 48_000) }?.isUnsupportedConfiguration == true)
        // The sign an attenuation is stated with does not matter.
        #expect(try WindowedSincMethod.kaiserEstimate(attenuation: .decibels(-60), transition: 500, sampleRate: 48_000).length
            == WindowedSincMethod.kaiserEstimate(attenuation: .decibels(60), transition: 500, sampleRate: 48_000).length)
    }

    @Test func aFilterIsLinearPhaseWithUnityGainAtItsReferenceAndHalfAmplitudeAtItsEdges() throws {
        let rate = 48_000.0
        let cases: [(FilterResponse, Double)] = [
            (.lowPass(cutoff: 4_000), 0), (.highPass(cutoff: 4_000), 24_000),
            (.bandPass(from: 3_000, to: 9_000), 6_000), (.bandStop(from: 3_000, to: 9_000), 0),
        ]
        for (response, reference) in cases {
            for window: Window? in [nil, .hann, .hamming, .blackman, .blackmanHarris, .kaiser(beta: 6)] {
                let design = try FIRDesign(.windowedSinc(window: window), response, length: 255, sampleRate: rate)
                #expect(FIRMath.asymmetry(of: design.taps).symmetric == 0, "the taps are symmetric to the bit")
                #expect(design.delay == 127)
                expectClose(TapMeasure.response(design.taps, at: reference, sampleRate: rate).magnitude, 1.0, .absolute(1e-12), "\(response), \(String(describing: window)): the reference gain")
                for edge in response.edges {
                    expectClose(TapMeasure.response(design.taps, at: edge, sampleRate: rate).magnitude, 0.5, .absolute(2e-3), "\(response), \(String(describing: window)): the amplitude at \(edge) Hz")
                }
            }
        }
    }

    /// The stress test of the stability note (NUMS-2): the filters at the edges of the band
    /// from the stress-fixture library (WP-016), designed for 80 dB with a transition band as
    /// wide as the corner's distance from its end of the axis. The longest has 96 363 taps.
    @Test func stressFiltersAtTheEdgesOfTheBandAreLinearPhaseToTheBitAndReachTheirAttenuation() throws {
        var longest = 0
        for fixture in StressFixture.filtersNearZero + StressFixture.filtersNearNyquist {
            let nyquist = fixture.sampleRate / 2
            let width = min(fixture.cutoff, nyquist - fixture.cutoff)
            let estimate = try WindowedSincMethod.kaiserEstimate(attenuation: .decibels(80), transition: width, sampleRate: fixture.sampleRate)
            let length = estimate.length | 1        // odd: a high-pass passes the Nyquist frequency
            longest = max(longest, length)
            let isLowPass = fixture.response == .lowPass
            let response: FilterResponse = isLowPass ? .lowPass(cutoff: fixture.cutoff) : .highPass(cutoff: fixture.cutoff)
            let design = try FIRDesign(.windowedSinc(), response, length: length, transition: width, sampleRate: fixture.sampleRate)
            let taps = design.taps
            // Linear phase exactly: the taps are symmetric to the bit, at any length.
            #expect(FIRMath.asymmetry(of: taps).symmetric == 0, "\(fixture.name): \(length) taps are symmetric to the bit")
            #expect(design.delay == Double(length - 1) / 2 && taps.allSatisfy(\.isFinite))
            // Unity gain where the pass band has its reference, and half the amplitude at the corner.
            let reference = TapMeasure.response(taps, at: isLowPass ? 0 : nyquist, sampleRate: fixture.sampleRate).magnitude
            expectClose(reference, 1.0, .absolute(1e-10), "\(fixture.name): the reference gain")
            Measurements.shared.record("WP-423 stress: reference gain of the filters at the edges of the band, distance from 1", abs(reference - 1), bound: 1e-10)
            let corner = TapMeasure.response(taps, at: fixture.cutoff, sampleRate: fixture.sampleRate).magnitude
            expectClose(corner, 0.5, .absolute(5e-3), "\(fixture.name): the amplitude at the corner")
            // Kaiser's estimate is made for one transition band on its own. Here the band
            // reaches the end of the axis, where its mirror image adds to the ripple: the
            // stop band lies within 3 dB of the 80 dB asked for, not at it.
            func bands(of taps: [Double]) -> (stop: Double, least: Double, greatest: Double) {
                let grid = TapMeasure.magnitudes(taps, oversampling: 16)
                let lower = (from: 0.0, to: fixture.cutoff - width / 2), upper = (from: fixture.cutoff + width / 2, to: nyquist)
                let stop = TapMeasure.extremes(taps, from: (isLowPass ? upper : lower).from, to: (isLowPass ? upper : lower).to, sampleRate: fixture.sampleRate, grid: grid)
                let pass = TapMeasure.extremes(taps, from: (isLowPass ? lower : upper).from, to: (isLowPass ? lower : upper).to, sampleRate: fixture.sampleRate, grid: grid)
                return (-20 * log10(stop.greatest), pass.least, pass.greatest)
            }
            let estimated = bands(of: taps)
            Measurements.shared.record("WP-423 stress: by Kaiser's estimate alone, stop-band attenuation short of the 80 dB asked for, dB", 80 - estimated.stop, bound: 3)
            #expect(estimated.stop >= 77, "\(fixture.name): \(estimated.stop) dB with \(length) taps")
            #expect(estimated.least > 1 - 2e-4 && estimated.greatest < 1 + 2e-4, "\(fixture.name): the pass band lies between \(estimated.least) and \(estimated.greatest)")

            // The mitigation: a tolerance scheme is measured, and the filter lengthened until it is met.
            let scheme = try FIRDesign(
                .windowedSinc(),
                passband: isLowPass ? .lowPass(cutoff: fixture.cutoff - width / 2) : .highPass(cutoff: fixture.cutoff + width / 2),
                stopband: isLowPass ? .lowPass(cutoff: fixture.cutoff + width / 2) : .highPass(cutoff: fixture.cutoff - width / 2),
                maximumLoss: .decibels(0.01), minimumAttenuation: .decibels(80), sampleRate: fixture.sampleRate)
            let met = bands(of: scheme.taps)
            Measurements.shared.record("WP-423 stress: by tolerance scheme, stop-band attenuation short of the 80 dB asked for, dB", 80 - met.stop, bound: 0)
            #expect(met.stop >= 80, "\(fixture.name): the scheme is met: \(met.stop) dB with \(scheme.length) taps")
            #expect(20 * log10(met.least) >= -0.01 && 20 * log10(met.greatest) <= 0.01, "\(fixture.name): the loss in the pass band")
            #expect(scheme.length >= length && scheme.length < length + length / 8 + 16, "\(fixture.name): \(scheme.length) taps where the estimate said \(length)")
            #expect(FIRMath.asymmetry(of: scheme.taps).symmetric == 0)
        }
        #expect(longest > 90_000, "the fixture at 10 Hz and 192 kHz needs \(longest) taps")
    }

    @Test func anEvenLengthIsRejectedWhereTheResponseAtNyquistMustNotBeZero() throws {
        for response in [FilterResponse.highPass(cutoff: 4_000), .bandStop(from: 3_000, to: 9_000)] {
            let error = thrownError { _ = try FIRDesign(.windowedSinc(), response, length: 100, sampleRate: 48_000) }
            #expect(error?.invalidParameterName == "length" && error?.invalidParameterReason?.contains("Nyquist") == true)
            #expect(try FIRDesign(.windowedSinc(), response, length: 101, sampleRate: 48_000).length == 101)
        }
        for response in [FilterResponse.lowPass(cutoff: 4_000), .bandPass(from: 3_000, to: 9_000)] {
            let taps = try FIRDesign(.windowedSinc(), response, length: 100, sampleRate: 48_000).taps
            #expect(TapMeasure.response(taps, at: 24_000, sampleRate: 48_000).magnitude < 1e-12, "an even length is zero at the Nyquist frequency")
        }
    }

    @Test func theWindowIsUsedInItsSymmetricFormWhateverFormItWasGivenIn() throws {
        let symmetric = try FIRDesign(.windowedSinc(window: .hann.symmetric), .lowPass(cutoff: 4_000), length: 63, sampleRate: 48_000)
        let periodic = try FIRDesign(.windowedSinc(window: .hann.periodic), .lowPass(cutoff: 4_000), length: 63, sampleRate: 48_000)
        #expect(symmetric.taps == periodic.taps)
        #expect(symmetric != periodic, "the method is part of the design's identity")
        let raisedCosine = Window.custom { t in 0.5 - 0.5 * cos(2 * .pi * t) }
        let custom = try FIRDesign(.windowedSinc(window: raisedCosine), .lowPass(cutoff: 4_000), length: 63, sampleRate: 48_000)
        expectClose(custom.taps, symmetric.taps, .absolute(1e-15), "a custom window that is a Hann window")
        #expect(thrownError { _ = try FIRDesign(.windowedSinc(window: .hann.half), .lowPass(cutoff: 4_000), length: 63, sampleRate: 48_000) }?.invalidParameterName == "window")
    }

    @Test func withoutAWindowTheKaiserBetaFollowsWhatTheFilterStates() throws {
        let response = FilterResponse.lowPass(cutoff: 4_000)
        let method = WindowedSincMethod()
        #expect(method.window == nil && WindowedSincMethod.defaultAttenuation == 80)
        // Neither an attenuation nor a transition: 80 dB.
        let plain = try method.taps(response, length: 101, transition: nil, attenuation: nil, sampleRate: 48_000)
        let eighty = try WindowedSincMethod(window: .kaiser(beta: 0.1102 * (80 - 8.7))).taps(response, length: 101, transition: nil, attenuation: nil, sampleRate: 48_000)
        #expect(plain == eighty)
        // An attenuation decides, whatever the transition.
        let sixty = try method.taps(response, length: 101, transition: 500, attenuation: .decibels(60), sampleRate: 48_000)
        let explicit = try WindowedSincMethod(window: .kaiser(beta: 0.1102 * (60 - 8.7))).taps(response, length: 101, transition: nil, attenuation: nil, sampleRate: 48_000)
        #expect(sixty == explicit)
        // Kaiser's piecewise formula.
        #expect(WindowedSincMethod.kaiserBeta(attenuation: 20) == 0)
        expectClose(WindowedSincMethod.kaiserBeta(attenuation: 40), 0.5842 * pow(19, 0.4) + 0.07886 * 19, .absolute(1e-15))
        #expect(thrownError { _ = try method.taps(response, length: 101, transition: nil, attenuation: .linear(0), sampleRate: 48_000) }?.invalidParameterName == "attenuation")
        #expect(thrownError { _ = try WindowedSincMethod(window: .kaiser(beta: -1)).taps(response, length: 101, transition: nil, attenuation: nil, sampleRate: 48_000) }?.invalidParameterName == "window")
    }

    @Test func valuesThatMakeNoFilterAreTypedErrors() throws {
        func design(_ response: FilterResponse, length: Int = 31, rate: Double = 48_000) -> DSPError? {
            thrownError { _ = try FIRDesign(.windowedSinc(), response, length: length, sampleRate: rate) }
        }
        #expect(design(.lowPass(cutoff: 0))?.invalidParameterName == "cutoff")
        #expect(design(.lowPass(cutoff: 24_000))?.invalidParameterName == "cutoff")
        #expect(design(.highPass(cutoff: .nan))?.invalidParameterName == "cutoff")
        #expect(design(.bandPass(from: 9_000, to: 3_000))?.invalidParameterName == "response")
        #expect(design(.bandStop(from: 3_000, to: 30_000))?.invalidParameterName == "response")
        #expect(design(.lowPass(cutoff: 4_000), length: 0)?.invalidParameterName == "length")
        #expect(design(.lowPass(cutoff: 4_000), length: WindowedSincMethod.maximumLength + 1)?.invalidParameterName == "length")
        #expect(design(.lowPass(cutoff: 4_000), rate: 0)?.invalidParameterName == "sampleRate")
        #expect(thrownError { _ = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 4_000), length: 31, transition: -1, sampleRate: 48_000) }?.invalidParameterName == "transition")
        // A single tap is a gain of one.
        #expect(try FIRDesign(.windowedSinc(), .lowPass(cutoff: 4_000), length: 1, sampleRate: 48_000).taps == [1])
    }

    /// A method written outside the package is passed the same way (§5.3).
    private struct Boxcar: FIRDesignMethod {
        func taps(_ response: FilterResponse, length: Int, transition: Double?, attenuation: Amplification?, sampleRate: Double) throws(DSPError) -> [Double] {
            [Double](repeating: 1 / Double(length), count: length)
        }
    }

    private struct Broken: FIRDesignMethod {
        func taps(_ response: FilterResponse, length: Int, transition: Double?, attenuation: Amplification?, sampleRate: Double) throws(DSPError) -> [Double] {
            [.nan]
        }
    }

    @Test func aMethodOfTheCallersOwnIsAStrategyLikeTheStockOnes() throws {
        let design = try FIRDesign(Boxcar(), .lowPass(cutoff: 1_000), length: 8, sampleRate: 48_000)
        #expect(design.taps == [Double](repeating: 0.125, count: 8))
        #expect(design.method == AnyStrategy(Boxcar()) && design.method != AnyStrategy(WindowedSincMethod()))
        #expect(thrownError { _ = try FIRDesign(Broken(), .lowPass(cutoff: 1_000), length: 8, sampleRate: 48_000) }?.invalidParameterName == "method")
    }
}

/// WP-424. FIR from a roll-off (§6.3.4), and from a tolerance scheme. Acceptance: the measured
/// transition slope is at least the one requested; a stop-band edge beyond Nyquist is a typed
/// error naming the smallest slope that fits.
@Suite("FIR from a roll-off and from a tolerance scheme (WP-424)")
struct FIRRollOffTests {
    /// The stop band of a design, as (from, to) pairs in hertz, for pass-band edges `pass` and a
    /// transition `octaves` wide.
    private func stopBands(_ response: FilterResponse, octaves: Double, nyquist: Double) -> [(Double, Double)] {
        let ratio = pow(2, octaves)
        switch response {
        case .lowPass(let cutoff): return [(cutoff * ratio, nyquist)]
        case .highPass(let cutoff): return [(0, cutoff / ratio)]
        case .bandPass(let from, let to): return [(0, from / ratio), (to * ratio, nyquist)]
        case .bandStop(let from, let to): return [(from * ratio, to / ratio)]
        }
    }

    /// The attenuation a design reaches from where a roll-off puts its stop bands, in decibels.
    private func attenuationReached(_ design: FIRDesign, _ response: FilterResponse, octaves: Double, grid: [Double]) -> Double {
        var worst = 0.0
        for band in stopBands(response, octaves: octaves, nyquist: design.sampleRate / 2) {
            worst = max(worst, TapMeasure.extremes(design.taps, from: band.0, to: band.1, sampleRate: design.sampleRate, grid: grid).greatest)
        }
        return -20 * log10(worst)
    }

    @Test func theMeasuredSlopeIsAtLeastTheOneRequested() throws {
        let rate = 48_000.0
        let responses: [FilterResponse] = [
            .lowPass(cutoff: 2_000), .highPass(cutoff: 2_000), .bandPass(from: 1_000, to: 2_000), .bandStop(from: 100, to: 20_000),
        ]
        var designs = 0
        for response in responses {
            for slope in [24.0, 48, 96, 192] {
                for attenuation in [40.0, 60, 80] {
                    let designed = try FIRDesign(.windowedSinc(), response, rollOff: .decibelsPerOctave(slope), stopband: .decibels(attenuation), sampleRate: rate)
                    designs += 1
                    let label = "\(response), \(slope) dB per octave, \(attenuation) dB"
                    #expect(designed.length % 2 == 1, "\(label): the delay is whole")
                    // From where the roll-off puts the stop band, the response is at least the
                    // attenuation down: the level has fallen by A within A / slope octaves of the
                    // pass-band edge, so the average slope is at least the one requested.
                    let grid = TapMeasure.magnitudes(designed.taps)
                    let reached = attenuationReached(designed, response, octaves: attenuation / slope, grid: grid)
                    #expect(reached >= attenuation, "\(label): \(reached) dB at the stop-band edge and beyond")
                    Measurements.shared.record("WP-424 attenuation short of the request at the stop-band edge, dB (negative: surplus)", attenuation - reached, bound: 0)
                    // The slope itself, on the skirt of a low-pass: from the pass-band edge to
                    // where the response has fallen by the attenuation for good.
                    if case .lowPass(let cutoff) = response {
                        let bins = grid.count - 1
                        var last = bins
                        while last > 0, grid[last] <= pow(10, -attenuation / 20) { last -= 1 }
                        // The crossing lies between that bin and the next: found by bisection.
                        var above = Double(last) / Double(bins) * rate / 2, below = Double(last + 1) / Double(bins) * rate / 2
                        for _ in 0 ..< 40 {
                            let middle = (above + below) / 2
                            if TapMeasure.response(designed.taps, at: middle, sampleRate: rate).magnitude > pow(10, -attenuation / 20) { above = middle } else { below = middle }
                        }
                        let measured = attenuation / log2(below / cutoff)
                        #expect(measured >= slope, "\(label): measured \(measured) dB per octave")
                        Measurements.shared.record("WP-424 low-pass: requested slope over measured slope", slope / measured, bound: 1)
                    }
                    // The pass band is still a pass band: within the ripple of the design.
                    for edge in response.edges {
                        let gain = TapMeasure.response(designed.taps, at: edge, sampleRate: rate).magnitude
                        #expect(abs(20 * log10(gain)) < 0.2, "\(label): \(20 * log10(gain)) dB at the pass-band edge \(edge) Hz")
                    }
                }
            }
        }
        #expect(designs == 4 * 4 * 3)
    }

    @Test func aLeastSquaresFitMeetsARollOffWhereItsLengthAllows() throws {
        let rate = 48_000.0
        let cases: [(FilterResponse, Double, Double)] = [
            (.lowPass(cutoff: 2_000), 24, 40), (.lowPass(cutoff: 2_000), 48, 40), (.lowPass(cutoff: 2_000), 24, 60),
            (.highPass(cutoff: 2_000), 24, 40), (.bandPass(from: 1_000, to: 2_000), 24, 40),
        ]
        for (response, slope, attenuation) in cases {
            let designed = try FIRDesign(.leastSquares, response, rollOff: .decibelsPerOctave(slope), stopband: .decibels(attenuation), sampleRate: rate)
            let reached = attenuationReached(designed, response, octaves: attenuation / slope, grid: TapMeasure.magnitudes(designed.taps))
            #expect(reached >= attenuation, "\(response), \(slope) dB per octave: \(reached) dB with \(designed.length) taps")
            Measurements.shared.record("WP-424 least squares: attenuation short of the request, dB (negative: surplus)", attenuation - reached, bound: 0)
        }
        // The fit's own estimate of its length: one over the ripple, over the width.
        #expect(try LeastSquaresMethod().estimatedLength(transition: 2_400, attenuation: .decibels(40), sampleRate: 48_000) == 2 * 102 + 1)
        // A steep, deep scheme is beyond a fit whose error at the corner of its transition band
        // falls only as one over the length: a typed error that names the remedy.
        let error = thrownError {
            _ = try FIRDesign(.leastSquares, .lowPass(cutoff: 2_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80), sampleRate: rate)
        }
        #expect(error?.isUnsupportedConfiguration == true)
        #expect("\(String(describing: error))".contains("windowedSinc"))
    }

    @Test func aStopBandEdgeBeyondNyquistIsATypedErrorNamingTheSmallestSlopeThatFits() throws {
        // 10 kHz at 48 kHz: 1.263 octaves below the Nyquist frequency. 80 dB need more than 63.34 dB per octave.
        let smallest = 80 / log2(24_000.0 / 10_000)
        let error = thrownError {
            _ = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 10_000), rollOff: .decibelsPerOctave(48), stopband: .decibels(80), sampleRate: 48_000)
        }
        #expect(error?.invalidParameterName == "rollOff")
        let reason = try #require(error?.invalidParameterReason)
        #expect(reason.contains(String(format: "%.2f", smallest)) && reason.contains("Nyquist"), "\(reason)")
        // At the smallest slope itself the edge sits on the Nyquist frequency: still rejected.
        #expect(thrownError { _ = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 10_000), rollOff: .decibelsPerOctave(smallest), stopband: .decibels(80), sampleRate: 48_000) }?.invalidParameterName == "rollOff")
        // Just above it the filter exists.
        #expect(try FIRDesign(.windowedSinc(), .lowPass(cutoff: 10_000), rollOff: .decibelsPerOctave(smallest * 1.01), stopband: .decibels(80), sampleRate: 48_000).length > 1)
        // The upper skirt of a band-pass, in decibels per decade.
        let band = thrownError {
            _ = try FIRDesign(.windowedSinc(), .bandPass(from: 300, to: 16_000), rollOff: .decibelsPerDecade(100), stopband: .decibels(60), sampleRate: 48_000)
        }
        #expect(band?.invalidParameterReason?.contains(String(format: "%.2f", 60 / log2(24_000.0 / 16_000))) == true)
        // The skirts of a band-stop must not meet.
        let notch = thrownError {
            _ = try FIRDesign(.windowedSinc(), .bandStop(from: 1_000, to: 2_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(60), sampleRate: 48_000)
        }
        #expect(notch?.invalidParameterName == "rollOff" && notch?.invalidParameterReason?.contains(String(format: "%.2f", 120.0)) == true)
        // A high-pass has all the octaves down to 0 Hz: any slope fits.
        #expect(try FIRDesign(.windowedSinc(), .highPass(cutoff: 12_000), rollOff: .decibelsPerOctave(6), stopband: .decibels(40), sampleRate: 48_000).length > 1)
    }

    @Test func aRollOffThatIsNoSlopeIsATypedError() throws {
        for rollOff in [RollOff.decibelsPerOctave(0), .decibelsPerOctave(-12), .decibelsPerOctave(.infinity), .order(0)] {
            #expect(thrownError { _ = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 1_000), rollOff: rollOff, stopband: .decibels(60), sampleRate: 48_000) }?.invalidParameterName == "rollOff")
        }
        #expect(thrownError { _ = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 30_000), rollOff: .order(8), stopband: .decibels(60), sampleRate: 48_000) }?.invalidParameterName == "cutoff")
        #expect(thrownError { _ = try FIRDesign(.windowedSinc(), .bandPass(from: 3_000, to: 2_000), rollOff: .order(8), stopband: .decibels(60), sampleRate: 48_000) }?.invalidParameterName == "response")
        #expect(thrownError { _ = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 1_000), rollOff: .order(8), stopband: .linear(0), sampleRate: 48_000) }?.invalidParameterName == "stopband")
        // An order is a slope of 6.02 dB per octave per order.
        let byOrder = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 1_000), rollOff: .order(8), stopband: .decibels(60), sampleRate: 48_000)
        let bySlope = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 1_000), rollOff: .decibelsPerOctave(8 * 20 * log10(2.0)), stopband: .decibels(60), sampleRate: 48_000)
        #expect(byOrder.taps == bySlope.taps)
    }

    @Test func aToleranceSchemeIsMetAndTheHalfAmplitudeEdgesLieInTheTransitionBands() throws {
        let rate = 48_000.0
        let schemes: [(FilterResponse, FilterResponse)] = [
            (.lowPass(cutoff: 4_000), .lowPass(cutoff: 5_000)),
            (.highPass(cutoff: 4_000), .highPass(cutoff: 3_000)),
            (.bandPass(from: 3_000, to: 9_000), .bandPass(from: 2_500, to: 10_500)),
            (.bandStop(from: 3_000, to: 9_000), .bandStop(from: 3_500, to: 8_000)),
            (.lowPass(cutoff: 4_000), .lowPass(cutoff: 24_000)),        // the stop band is the Nyquist frequency alone
            (.highPass(cutoff: 4_000), .highPass(cutoff: 0)),
        ]
        for (pass, stop) in schemes {
            for (loss, attenuation) in [(1.0, 40.0), (0.01, 60.0), (0.1, 90.0)] {
                let design = try FIRDesign(.windowedSinc(), passband: pass, stopband: stop, maximumLoss: .decibels(loss),
                                           minimumAttenuation: .decibels(attenuation), sampleRate: rate)
                let grid = TapMeasure.magnitudes(design.taps)
                let label = "\(pass) / \(stop), \(loss) dB, \(attenuation) dB"
                let passBands: [(Double, Double)], stopBands: [(Double, Double)]
                switch pass {
                case .lowPass: passBands = [(0, pass.edges[0])]; stopBands = [(stop.edges[0], rate / 2)]
                case .highPass: passBands = [(pass.edges[0], rate / 2)]; stopBands = [(0, stop.edges[0])]
                case .bandPass: passBands = [(pass.edges[0], pass.edges[1])]; stopBands = [(0, stop.edges[0]), (stop.edges[1], rate / 2)]
                case .bandStop: passBands = [(0, pass.edges[0]), (pass.edges[1], rate / 2)]; stopBands = [(stop.edges[0], stop.edges[1])]
                }
                for band in passBands {
                    let extremes = TapMeasure.extremes(design.taps, from: band.0, to: band.1, sampleRate: rate, grid: grid)
                    #expect(20 * log10(extremes.least) >= -loss && 20 * log10(extremes.greatest) <= loss, "\(label): the pass band \(band)")
                }
                for band in stopBands {
                    let greatest = TapMeasure.extremes(design.taps, from: band.0, to: band.1, sampleRate: rate, grid: grid).greatest
                    #expect(-20 * log10(greatest) >= attenuation, "\(label): the stop band \(band) is \(-20 * log10(greatest)) dB down")
                }
                // The edges the design reports are where the amplitude is one half, half the
                // narrowest transition band from each pass-band edge.
                let width = zip(pass.edges, stop.edges).map { abs($0 - $1) }.min()!
                for (centre, edge) in zip(design.response.edges, zip(pass.edges, stop.edges)) {
                    expectClose(centre, edge.0 + (edge.1 > edge.0 ? width / 2 : -width / 2), .absolute(1e-9), label)
                }
                #expect(design.length % 2 == 1)
            }
        }
    }

    @Test func aSchemeNoLengthMeetsIsATypedErrorThatNamesTheRemedy() throws {
        // The side lobes of a Hann window stop at 44 dB, whatever the length.
        let error = thrownError {
            _ = try FIRDesign(.windowedSinc(window: .hann), passband: .lowPass(cutoff: 4_000), stopband: .lowPass(cutoff: 5_000),
                              maximumLoss: .decibels(1), minimumAttenuation: .decibels(80), sampleRate: 48_000)
        }
        #expect(error?.invalidParameterName == "minimumAttenuation" && error?.invalidParameterReason?.contains("side lobes") == true)
        // The same window reaches 40 dB.
        #expect(try FIRDesign(.windowedSinc(window: .hann), passband: .lowPass(cutoff: 4_000), stopband: .lowPass(cutoff: 5_000),
                              maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), sampleRate: 48_000).length > 31)
        func scheme(_ pass: FilterResponse, _ stop: FilterResponse, loss: Double = 1, attenuation: Double = 60, rate: Double = 48_000) -> DSPError? {
            thrownError {
                _ = try FIRDesign(.windowedSinc(), passband: pass, stopband: stop, maximumLoss: .decibels(loss), minimumAttenuation: .decibels(attenuation), sampleRate: rate)
            }
        }
        #expect(scheme(.lowPass(cutoff: 4_000), .highPass(cutoff: 5_000))?.invalidParameterName == "stopband")
        #expect(scheme(.lowPass(cutoff: 5_000), .lowPass(cutoff: 4_000))?.invalidParameterName == "stopband")
        #expect(scheme(.bandPass(from: 3_000, to: 9_000), .bandPass(from: 4_000, to: 10_000))?.invalidParameterName == "stopband")
        #expect(scheme(.bandStop(from: 3_000, to: 9_000), .bandStop(from: 2_000, to: 8_000))?.invalidParameterName == "stopband")
        #expect(scheme(.lowPass(cutoff: 0), .lowPass(cutoff: 4_000))?.invalidParameterName == "passband")
        #expect(scheme(.lowPass(cutoff: 4_000), .lowPass(cutoff: 25_000))?.invalidParameterName == "stopband")
        #expect(scheme(.lowPass(cutoff: 4_000), .lowPass(cutoff: 5_000), loss: 70)?.invalidParameterName == "minimumAttenuation")
        #expect(scheme(.lowPass(cutoff: 4_000), .lowPass(cutoff: 5_000), loss: 0)?.invalidParameterName == "maximumLoss")
        #expect(scheme(.lowPass(cutoff: 4_000), .lowPass(cutoff: 5_000), rate: -1)?.invalidParameterName == "sampleRate")
        #expect(scheme(.lowPass(cutoff: 4_000), .lowPass(cutoff: 4_000.001), attenuation: 120)?.isUnsupportedConfiguration == true)
    }
}

/// WP-425. Least-squares FIR design: normal equations, condition test, fall-back. Acceptance:
/// golden (`firls`; four responses; lengths 31, 101, 255; taps within 1e-9); an ill-conditioned
/// fixture takes the fall-back and still meets it.
@Suite("Least-squares FIR design (WP-425)")
struct LeastSquaresFIRTests {
    private func bands(of golden: GoldenCase) throws -> [LeastSquaresFIR.Band] {
        let edges = try golden.numbers("bands"), desired = try golden.numbers("desired"), weights = try golden.numbers("weights")
        let nyquist = try golden.number("sample_rate") / 2
        return (0 ..< weights.count).map {
            LeastSquaresFIR.Band(lower: edges[2 * $0] / nyquist, upper: edges[2 * $0 + 1] / nyquist, lowerGain: desired[2 * $0],
                                 upperGain: desired[2 * $0 + 1], weight: weights[$0])
        }
    }

    @Test func theTapsMatchTheOracle() throws {
        let file = try Golden.firDesign.get()
        var checked = 0
        for golden in file.cases where golden.name.hasPrefix("firls-") && golden.parameters["response"] != nil {
            let response = firResponse(named: try golden.string("response"), edges: try golden.numbers("edges"))
            let weight = try golden.number("stopband_weight")
            let design = try FIRDesign(
                weight == 1 ? .leastSquares : .leastSquares(stopbandWeight: weight), response, length: try golden.integer("length"),
                transition: try golden.number("transition"), sampleRate: try golden.number("sample_rate"))
            let expected = try golden.real("taps")
            expectClose(design.taps, expected, .absolute(1e-9), golden.name)
            Measurements.shared.record("WP-425 least-squares taps against firls, absolute", zip(design.taps, expected).map { abs($0 - $1) }.max() ?? 1, bound: 1e-9)
            // The whole axis is fitted: the normal equations are well-conditioned and Cholesky solves them.
            let fit = try LeastSquaresFIR.design(length: try golden.integer("length"), bands: try bands(of: golden))
            #expect(!fit.usedFallback && (fit.reciprocalCondition ?? 0) > 1e-3, "\(golden.name): reciprocal condition \(String(describing: fit.reciprocalCondition))")
            expectClose(fit.taps, design.taps, .absolute(1e-13), "\(golden.name): the method builds the bands the oracle was given")
            checked += 1
        }
        #expect(checked == 4 * 3 * 2)
    }

    @Test func aFitWithPartOfTheAxisLeftOutMatchesTheOracleWhileItIsWellConditioned() throws {
        let file = try Golden.firDesign.get()
        for name in ["firls-gap-wide", "firls-gap-weighted"] {
            let golden = try file.require(name)
            let fit = try LeastSquaresFIR.design(length: try golden.integer("length"), bands: try bands(of: golden))
            let expected = try golden.real("taps")
            let worst = zip(fit.taps, expected).map { abs($0 - $1) }.max() ?? 1
            Measurements.shared.record("WP-425 \(name): taps against firls, absolute (reciprocal condition \(String(format: "%.1e", fit.reciprocalCondition ?? 0)))", worst, bound: 1e-9)
            expectClose(fit.taps, expected, .absolute(1e-9), name)
            #expect(!fit.usedFallback)
        }
    }

    @Test func anIllConditionedFitTakesTheFallBackAndStillMeetsTheOracle() throws {
        let golden = try Golden.firDesign.get().require("firls-gap-ill-conditioned")
        let bands = try bands(of: golden)
        let length = try golden.integer("length")
        let fit = try LeastSquaresFIR.design(length: length, bands: bands)
        #expect(fit.usedFallback, "reciprocal condition \(String(describing: fit.reciprocalCondition))")
        if let reciprocal = fit.reciprocalCondition { #expect(reciprocal < LeastSquaresFIR.reciprocalConditionFloor) }
        #expect(FIRMath.asymmetry(of: fit.taps).symmetric == 0 && fit.taps.count == length)

        // The taps of this fit are not determined to 1e-9: four singular values of its normal
        // equations stand above the rounding unit, the fourth at 2e-12 of the first, and the
        // oracle's own fall-back resolves that direction differently. What is determined is the
        // fit, and that is what the fall-back is held to: its error over the bands, and its
        // response there.
        let oracle = try golden.real("taps")
        let own = LeastSquaresFIR.weightedError(of: fit.taps, bands: bands)
        let reference = LeastSquaresFIR.weightedError(of: oracle, bands: bands)
        Measurements.shared.record("WP-425 ill-conditioned fit: weighted squared error over the oracle's, minus 1", abs(own / reference - 1), bound: 1e-6)
        #expect(abs(own / reference - 1) <= 1e-6, "ours \(own), the oracle's \(reference)")
        var worst = 0.0
        for band in bands {
            for step in 0 ... 200 {
                let f = band.lower + (band.upper - band.lower) * Double(step) / 200
                worst = max(worst, abs(FIRMath.zeroPhaseAmplitude(of: fit.taps, at: .pi * f) - FIRMath.zeroPhaseAmplitude(of: oracle, at: .pi * f)))
            }
        }
        Measurements.shared.record("WP-425 ill-conditioned fit: response over the bands against the oracle's, absolute", worst, bound: 1e-7)
        #expect(worst <= 1e-7)
        let largest = oracle.map { abs($0) }.max() ?? 1
        // The fourth singular value stands at 2e-12 of the first, so the direction it belongs to
        // is resolved to the rounding unit over that: one part in ten thousand.
        Measurements.shared.record("WP-425 ill-conditioned fit: taps against the oracle's, relative to the largest tap (not determined to 1e-9)",
                                   (zip(fit.taps, oracle).map { abs($0 - $1) }.max() ?? 0) / largest, bound: 1e-4)
        expectClose(fit.taps, oracle, .relativeToMaximum(1e-4))
    }

    /// The stress test of the stability note (NUMS-2). The bands are taken from the stress
    /// fixture `hp-90Hz-48k-order8` (WP-016): a fit that only speaks about 0 … 180 Hz at
    /// 48 kHz, and leaves the rest of the axis out.
    @Test func stressAFitThatLeavesMostOfTheAxisOutNeedsTheFallBack() throws {
        let fixture = try #require(StressFixture.filtersNearZero.first { $0.name == "hp-90Hz-48k-order8" })
        let nyquist = fixture.sampleRate / 2
        let bands = [
            LeastSquaresFIR.Band(lower: 0, upper: fixture.cutoff / 2 / nyquist, lowerGain: 0, upperGain: 0, weight: 1),
            LeastSquaresFIR.Band(lower: fixture.cutoff / nyquist, upper: 2 * fixture.cutoff / nyquist, lowerGain: 1, upperGain: 1, weight: 1),
        ]
        let tested = try LeastSquaresFIR.design(length: 101, bands: bands)
        #expect(tested.usedFallback)
        let good = LeastSquaresFIR.weightedError(of: tested.taps, bands: bands)
        Measurements.shared.record("WP-425 stress: weighted squared error of the fall-back's fit", good, bound: 1e-4)
        // The best a filter of 101 taps can do for a step between 45 Hz and 90 Hz at 48 kHz: the
        // amplitude is within one percent of the target over both bands.
        #expect(good < 1e-4 && tested.taps.allSatisfy { $0.isFinite })
        // It is the solution the singular value decomposition gives on its own.
        expectClose(tested.taps, try LeastSquaresFIR.design(length: 101, bands: bands, solver: .singularValuesOnly).taps, .absolute(0))

        // Cholesky alone has nothing to offer here: the normal equations are not positive
        // definite in double precision, and `dposv` says so.
        let unguarded = thrownError { _ = try LeastSquaresFIR.design(length: 101, bands: bands, solver: .choleskyOnly) }
        #expect(unguarded?.numericalFailure?.routine == "dposv", "\(String(describing: unguarded))")

        // A shorter fit with a gap, where a Cholesky factor still exists (reciprocal condition
        // 7e-18): it fits the bands as well, with taps that are larger than they need be. The
        // fall-back returns the smallest solution.
        let gap = [
            LeastSquaresFIR.Band(lower: 0, upper: 0.1, lowerGain: 1, upperGain: 1, weight: 1),
            LeastSquaresFIR.Band(lower: 0.3, upper: 0.5, lowerGain: 0, upperGain: 0, weight: 1),
        ]
        let smallest = try LeastSquaresFIR.design(length: 31, bands: gap)
        #expect(smallest.usedFallback && (smallest.reciprocalCondition ?? 1) < LeastSquaresFIR.reciprocalConditionFloor)
        func norm(_ taps: [Double]) -> Double { taps.map { $0 * $0 }.reduce(0, +).squareRoot() }
        do throws(DSPError) {
            let bare = try LeastSquaresFIR.design(length: 31, bands: gap, solver: .choleskyOnly)
            let ratio = LeastSquaresFIR.weightedError(of: bare.taps, bands: gap) / LeastSquaresFIR.weightedError(of: smallest.taps, bands: gap)
            Measurements.shared.record("WP-425 stress: a gap fit of 31 taps, norm of the taps without the condition test over the fall-back's", norm(bare.taps) / norm(smallest.taps), bound: .infinity)
            Measurements.shared.record("WP-425 stress: a gap fit of 31 taps, error over the bands without the condition test over the fall-back's", ratio, bound: .infinity)
            #expect(norm(bare.taps) > 1.5 * norm(smallest.taps), "the fall-back's taps are the smallest: \(norm(smallest.taps)) against \(norm(bare.taps))")
            #expect(ratio > 0.5 && ratio < 2, "both fit the bands: error ratio \(ratio)")
        } catch {
            #expect(error.numericalFailure?.routine == "dposv", "no Cholesky factor exists: \(error)")
        }
    }

    @Test func bothSolversAgreeWhereTheSystemIsWellConditioned() throws {
        let bands = [
            LeastSquaresFIR.Band(lower: 0, upper: 0.2, lowerGain: 1, upperGain: 1, weight: 1),
            LeastSquaresFIR.Band(lower: 0.2, upper: 0.3, lowerGain: 1, upperGain: 0, weight: 1),
            LeastSquaresFIR.Band(lower: 0.3, upper: 1, lowerGain: 0, upperGain: 0, weight: 3),
        ]
        let cholesky = try LeastSquaresFIR.design(length: 63, bands: bands)
        let singular = try LeastSquaresFIR.design(length: 63, bands: bands, solver: .singularValuesOnly)
        #expect(!cholesky.usedFallback && singular.usedFallback && singular.reciprocalCondition == nil)
        expectClose(singular.taps, cholesky.taps, .absolute(1e-13))
    }

    @Test func aHeavierStopBandIsQuieter() throws {
        let rate = 48_000.0
        func stopError(_ weight: Double) throws -> Double {
            let taps = try FIRDesign(.leastSquares(stopbandWeight: weight), .lowPass(cutoff: 4_000), length: 63, transition: 1_500, sampleRate: rate).taps
            let grid = TapMeasure.magnitudes(taps)
            return TapMeasure.extremes(taps, from: 4_750, to: 24_000, sampleRate: rate, grid: grid).greatest
        }
        let heavy = try stopError(100), plain = try stopError(1)
        #expect(heavy < 0.5 * plain)
        #expect(LeastSquaresMethod().stopbandWeight == 1 && LeastSquaresMethod.leastSquares(stopbandWeight: 4).stopbandWeight == 4)
    }

    @Test func valuesThatMakeNoFitAreTypedErrors() throws {
        func design(_ response: FilterResponse = .lowPass(cutoff: 4_000), length: Int = 31, transition: Double? = 1_000, weight: Double = 1) -> DSPError? {
            thrownError { _ = try FIRDesign(.leastSquares(stopbandWeight: weight), response, length: length, transition: transition, sampleRate: 48_000) }
        }
        #expect(design(length: 32)?.invalidParameterName == "length")
        #expect(design(length: LeastSquaresFIR.maximumLength + 2)?.invalidParameterName == "length")
        #expect(design(transition: nil)?.invalidParameterName == "transition")
        #expect(design(transition: 9_000)?.invalidParameterName == "transition")      // reaches below 0 Hz
        #expect(design(.bandPass(from: 3_000, to: 3_500), transition: 1_000)?.invalidParameterName == "transition")   // the two overlap
        #expect(design(.highPass(cutoff: 23_900), transition: 400)?.invalidParameterName == "transition")           // reaches Nyquist
        #expect(design(weight: 0)?.invalidParameterName == "stopbandWeight")
        #expect(design(.lowPass(cutoff: -1))?.invalidParameterName == "cutoff")
        func fit(_ bands: [LeastSquaresFIR.Band]) -> DSPError? { thrownError { _ = try LeastSquaresFIR.design(length: 31, bands: bands) } }
        #expect(fit([])?.invalidParameterName == "bands")
        #expect(fit([.init(lower: 0.5, upper: 0.2, lowerGain: 1, upperGain: 1, weight: 1)])?.invalidParameterName == "bands")
        #expect(fit([.init(lower: 0, upper: 0.5, lowerGain: 1, upperGain: 1, weight: 1), .init(lower: 0.4, upper: 1, lowerGain: 0, upperGain: 0, weight: 1)])?.invalidParameterName == "bands")
        #expect(fit([.init(lower: 0, upper: 1.5, lowerGain: 1, upperGain: 1, weight: 1)])?.invalidParameterName == "bands")
        #expect(fit([.init(lower: 0, upper: 1, lowerGain: .nan, upperGain: 1, weight: 1)])?.invalidParameterName == "desired")
        #expect(fit([.init(lower: 0, upper: 1, lowerGain: 1, upperGain: 1, weight: -1)])?.invalidParameterName == "weights")
        #expect(fit([.init(lower: 0, upper: 1, lowerGain: 1, upperGain: 1, weight: 0)])?.invalidParameterName == "weights")
        // A single tap fits the mean of its target.
        expectClose(try LeastSquaresFIR.design(length: 1, bands: [.init(lower: 0, upper: 1, lowerGain: 0.5, upperGain: 0.5, weight: 1)]).taps, [0.5], .absolute(1e-15))
    }

    @Test func theSolvesRejectStorageOfTheWrongSize() throws {
        #expect(thrownError { _ = try LAPACK.solvePositiveDefinite([1, 0, 0], order: 2, rightHandSide: [1, 1]) }?.invalidParameterName == "matrix")
        #expect(thrownError { _ = try LAPACK.leastSquaresBySVD([1, 0, 0, 1], rows: 2, columns: 2, rightHandSide: [1]) }?.invalidParameterName == "matrix")
        #expect(thrownError { _ = try LAPACK.solveByOrthogonalFactorization([1, 0, 0, 1], rows: 2, columns: 3, rightHandSide: [1, 1]) }?.invalidParameterName == "matrix")
        // A matrix that is not positive definite has no Cholesky factor.
        #expect(try LAPACK.solvePositiveDefinite([1, 2, 2, 1], order: 2, rightHandSide: [1, 1]) == nil)
        let solved = try #require(try LAPACK.solvePositiveDefinite([4, 1, 1, 3], order: 2, rightHandSide: [1, 2]))
        expectClose(solved.solution, [1.0 / 11, 7.0 / 11], .absolute(1e-15))
        #expect(solved.reciprocalCondition > 0.3 && solved.reciprocalCondition <= 1)
        // A matrix of rank one: the minimum-norm solution, and the rank.
        let deficient = try LAPACK.leastSquaresBySVD([1, 1, 1, 1], rows: 2, columns: 2, rightHandSide: [2, 2])
        #expect(deficient.rank == 1)
        expectClose(deficient.solution, [1.0, 1.0], .absolute(1e-14))
        // An underdetermined system: the solution of least norm.
        expectClose(try LAPACK.solveByOrthogonalFactorization([1, 1, 1], rows: 1, columns: 3, rightHandSide: [3]), [1.0, 1.0, 1.0], .absolute(1e-14))
        // A system without full rank is a typed numerical failure.
        #expect(thrownError { _ = try LAPACK.solveByOrthogonalFactorization([1, 0, 1, 0], rows: 2, columns: 2, rightHandSide: [1, 1]) }?.numericalFailure?.routine == "dgels")
    }
}
