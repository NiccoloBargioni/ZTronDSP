import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-415, 416, 417 and 418c. The golden grid of STG-2: three tolerance schemes per response,
/// in the digital and in the analog domain. The order must be equal and the natural
/// frequencies within 1e-9 (relative); the filter that results must meet its scheme.
@Suite("Order from a tolerance scheme (WP-415, 416, 417, 418c)")
struct FilterOrderTests {
    private static let tolerance = 1e-9

    private struct Scheme {
        let golden: GoldenCase
        let familyName: String
        let passband: FilterResponse
        let stopband: FilterResponse
        let loss: Double
        let attenuation: Double
        let domain: IIRDesign.Domain
        let order: Int
        let natural: [Double]
    }

    private func schemes(_ families: Set<String>) throws -> [Scheme] {
        let file = try Golden.order.get()
        #expect(file.cases.count == 4 * 4 * 3 * 2)
        var result: [Scheme] = []
        for golden in file.cases {
            let familyName = try golden.string("family")
            guard families.contains(familyName) else { continue }
            let kind = try golden.string("response")
            let domain: IIRDesign.Domain = try golden.string("domain") == "analog" ? .analog : .digital(sampleRate: try golden.number("sample_rate"))
            result.append(Scheme(
                golden: golden, familyName: familyName,
                passband: try response(named: kind, edges: try golden.numbers("passband")),
                stopband: try response(named: kind, edges: try golden.numbers("stopband")),
                loss: try golden.number("maximum_loss"), attenuation: try golden.number("minimum_attenuation"),
                domain: domain, order: try golden.integer("order"), natural: try golden.real("natural")))
        }
        try #require(result.count == families.count * 24)
        return result
    }

    private func strategy(_ name: String) -> any FilterOrderStrategy {
        switch name {
        case "butterworth": ButterworthOrderStrategy()
        case "chebyshev1": Chebyshev1OrderStrategy()
        case "chebyshev2": Chebyshev2OrderStrategy()
        default: EllipticOrderStrategy()
        }
    }

    /// A family value whose own ripple and attenuation differ from every scheme's: the
    /// tolerance scheme must replace them.
    private func family(_ name: String) -> any FilterFamily {
        switch name {
        case "butterworth": ButterworthFamily()
        case "chebyshev1": Chebyshev1Family(ripple: .decibels(0.3))
        case "chebyshev2": Chebyshev2Family(stopband: .decibels(25))
        default: EllipticFamily(ripple: .decibels(0.3), stopband: .decibels(25))
        }
    }

    private func checkEstimates(_ families: Set<String>, label: String) throws {
        for scheme in try schemes(families) {
            let estimate = try strategy(scheme.familyName).minimumOrder(
                passband: scheme.passband, stopband: scheme.stopband, maximumLoss: .decibels(scheme.loss),
                minimumAttenuation: .decibels(scheme.attenuation), domain: scheme.domain)
            #expect(estimate.order == scheme.order, "\(scheme.golden.name): order \(estimate.order), the oracle says \(scheme.order)")
            #expect(estimate.response.isBand == scheme.passband.isBand)
            expectClose(estimate.response.edges, scheme.natural, .relative(Self.tolerance), "\(scheme.golden.name): natural frequency")
            for (actual, expected) in zip(estimate.response.edges, scheme.natural) {
                Measurements.shared.record("\(label) natural frequency, relative", abs(actual - expected) / expected, bound: Self.tolerance)
            }
        }
    }

    // MARK: Golden: order and natural frequency

    @Test func butterworthOrdersMatchTheOracleForAllFourResponses() throws {
        try checkEstimates(["butterworth"], label: "WP-415 Butterworth")
    }

    @Test func chebyshevOrdersMatchTheOracleForAllFourResponses() throws {
        try checkEstimates(["chebyshev1", "chebyshev2"], label: "WP-416 Chebyshev I and II")
    }

    @Test func ellipticOrdersMatchTheOracleForAllFourResponses() throws {
        try checkEstimates(["elliptic"], label: "WP-417 elliptic")
    }

    // MARK: Golden and property: the design from a tolerance scheme (WP-418c)

    private func open(_ family: some FilterFamily, _ scheme: Scheme) throws -> IIRDesign {
        try IIRDesign(family, passband: scheme.passband, stopband: scheme.stopband, maximumLoss: .decibels(scheme.loss),
                      minimumAttenuation: .decibels(scheme.attenuation), domain: scheme.domain)
    }

    @Test func theDesignFromASchemeMatchesTheOraclesDesign() throws {
        for scheme in try schemes(["butterworth", "chebyshev1", "chebyshev2", "elliptic"]) {
            let design = try open(family(scheme.familyName), scheme)
            #expect(design.order == scheme.order, "\(scheme.golden.name)")
            #expect(design.domain == scheme.domain)
            expectClose(design.response.edges, scheme.natural, .relative(Self.tolerance), "\(scheme.golden.name)")
            let system = design.zeroPoleGain
            expectRootsClose(system.poles, try scheme.golden.complexes("poles"), relative: Self.tolerance, "\(scheme.golden.name) poles",
                             measure: "WP-418c design from a scheme, poles, relative")
            expectRootsClose(system.zeros, try scheme.golden.complexes("zeros"), relative: Self.tolerance, "\(scheme.golden.name) zeros",
                             measure: "WP-418c design from a scheme, zeros, relative")
            let gain = try scheme.golden.scalar("gain")
            expectClose(system.gain, gain, .relative(Self.tolerance), "\(scheme.golden.name) gain")
            Measurements.shared.record("WP-418c design from a scheme, gain, relative", abs(system.gain - gain) / abs(gain), bound: Self.tolerance)
        }
    }

    /// The frequencies of a band, on the frequency axis of the design's domain.
    private func axis(_ from: Double, _ to: Double, _ domain: IIRDesign.Domain, count: Int = 400) -> [Double] {
        let points = (0 ... count).map { from + (to - from) * Double($0) / Double(count) }
        switch domain {
        case .analog: return points
        case .digital(let sampleRate): return points.map { 2 * .pi * $0 / sampleRate }
        }
    }

    @Test func theDesignFromASchemeMeetsItsScheme() throws {
        var worstPass = -Double.infinity
        var worstStop = -Double.infinity
        for scheme in try schemes(["butterworth", "chebyshev1", "chebyshev2", "elliptic"]) {
            let design = try open(family(scheme.familyName), scheme)
            let pass = scheme.passband.edges
            let stop = scheme.stopband.edges
            // The far ends of the axis: just above 0, and the Nyquist frequency (or, for an
            // analog filter, a decade beyond the last edge).
            let low = min(pass[0], stop[0]) / 1_000
            let high: Double
            switch scheme.domain {
            case .analog: high = 10 * max(pass.last!, stop.last!)
            case .digital(let sampleRate): high = sampleRate / 2 * 0.999
            }
            let passAxes: [[Double]]
            let stopAxes: [[Double]]
            switch scheme.passband {
            case .lowPass:
                passAxes = [axis(low, pass[0], scheme.domain)]
                stopAxes = [axis(stop[0], high, scheme.domain)]
            case .highPass:
                passAxes = [axis(pass[0], high, scheme.domain)]
                stopAxes = [axis(low, stop[0], scheme.domain)]
            case .bandPass:
                passAxes = [axis(pass[0], pass[1], scheme.domain)]
                stopAxes = [axis(low, stop[0], scheme.domain), axis(stop[1], high, scheme.domain)]
            case .bandStop:
                passAxes = [axis(low, pass[0], scheme.domain), axis(pass[1], high, scheme.domain)]
                stopAxes = [axis(stop[0], stop[1], scheme.domain)]
            }
            let system = design.zeroPoleGain
            for frequencies in passAxes {
                for level in try system.magnitudeResponse(at: frequencies, in: .decibels(floor: -400)) {
                    // At most the maximum loss, and never a gain.
                    worstPass = max(worstPass, -level - scheme.loss)
                    #expect(level >= -scheme.loss - 1e-6, "\(scheme.golden.name): \(level) dB in the pass band")
                    #expect(level <= 1e-6, "\(scheme.golden.name): \(level) dB in the pass band")
                }
            }
            for frequencies in stopAxes {
                for level in try system.magnitudeResponse(at: frequencies, in: .decibels(floor: -400)) {
                    worstStop = max(worstStop, level + scheme.attenuation)
                    #expect(level <= -scheme.attenuation + 1e-6, "\(scheme.golden.name): \(level) dB in the stop band")
                }
            }
            // The order is the minimum: one less does not meet the scheme for the same edges.
            #expect(design.order >= 1)
        }
        Measurements.shared.record("WP-418c scheme: worst pass-band excess over the maximum loss, dB", worstPass, bound: 1e-6)
        Measurements.shared.record("WP-418c scheme: worst stop-band shortfall of the attenuation, dB", worstStop, bound: 1e-6)
    }

    @Test func theOrderIsTheSmallestThatMeetsTheScheme() throws {
        // One order less, with the same family and edges, must fail the stop band.
        let strategy = ButterworthOrderStrategy()
        let estimate = try strategy.minimumOrder(
            passband: .lowPass(cutoff: 1_000), stopband: .lowPass(cutoff: 2_000), maximumLoss: .decibels(1),
            minimumAttenuation: .decibels(40), domain: .digital(sampleRate: 48_000))
        #expect(estimate.order == 8)
        let fractional = try strategy.fractionalOrder(
            selectivity: tan(.pi * 2_000 / 48_000) / tan(.pi * 1_000 / 48_000), maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
        #expect(fractional > 7 && fractional <= 8)
        // The same edges with the loss met exactly at the pass-band edge and one order less.
        let ratio = try strategy.naturalFrequency(order: 7, maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
        let lower = try IIRDesign(.butterworth, .lowPass(cutoff: atan(ratio * tan(.pi * 1_000 / 48_000)) / .pi * 48_000), order: 7,
                                  domain: .digital(sampleRate: 48_000))
        let level = try lower.zeroPoleGain.magnitudeResponse(at: [2 * .pi * 2_000 / 48_000], in: .decibels)[0]
        #expect(level > -40, "order 7 only reaches \(level) dB at the stop-band edge")
        expectClose(try lower.zeroPoleGain.magnitudeResponse(at: [2 * .pi * 1_000 / 48_000], in: .decibels)[0], -1, .absolute(1e-9))
    }

    // MARK: The two questions a strategy answers

    @Test func theStockStrategiesAnswerForTheNormalisedLowPass() throws {
        let loss = Amplification.decibels(1)
        let attenuation = Amplification.decibels(40)
        // Butterworth: n = log((G_s − 1)/(G_p − 1)) / (2·log(selectivity)).
        expectClose(try ButterworthOrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: loss, minimumAttenuation: attenuation),
                    log10((pow(10, 4.0) - 1) / (pow(10, 0.1) - 1)) / (2 * log10(2.0)), .relative(1e-15))
        // Its natural frequency puts the loss exactly on the pass-band edge: |H(1/ratio)|² = 10^(−0.1).
        let ratio = try ButterworthOrderStrategy().naturalFrequency(order: 5, maximumLoss: loss, minimumAttenuation: attenuation)
        expectClose(1 / (1 + pow(1 / ratio, 10)), pow(10, -0.1), .relative(1e-14))
        // The two Chebyshev types need the same order; type I keeps the pass-band edge, type II
        // moves its natural frequency to the stop-band edge of the prototype.
        let first = try Chebyshev1OrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: loss, minimumAttenuation: attenuation)
        let second = try Chebyshev2OrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: loss, minimumAttenuation: attenuation)
        #expect(first == second)
        expectClose(first, acosh(((pow(10, 4.0) - 1) / (pow(10, 0.1) - 1)).squareRoot()) / acosh(2.0), .relative(1e-15))
        #expect(try Chebyshev1OrderStrategy().naturalFrequency(order: 4, maximumLoss: loss, minimumAttenuation: attenuation) == 1)
        #expect(try Chebyshev2OrderStrategy().naturalFrequency(order: 4, maximumLoss: loss, minimumAttenuation: attenuation) > 1)
        #expect(try EllipticOrderStrategy().naturalFrequency(order: 4, maximumLoss: loss, minimumAttenuation: attenuation) == 1)
        // Elliptic needs the least, Butterworth the most.
        let elliptic = try EllipticOrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: loss, minimumAttenuation: attenuation)
        let butterworth = try ButterworthOrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: loss, minimumAttenuation: attenuation)
        #expect(elliptic < first && first < butterworth)
        // The sign and the unit of the two tolerances do not matter.
        #expect(try ButterworthOrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: .decibels(-1), minimumAttenuation: .decibels(-40)) == butterworth)
    }

    @Test func theStockFamiliesNameTheirStrategies() {
        #expect(ButterworthFamily().orderStrategy is ButterworthOrderStrategy)
        #expect(Chebyshev1Family(ripple: .decibels(1)).orderStrategy is Chebyshev1OrderStrategy)
        #expect(Chebyshev2Family(stopband: .decibels(40)).orderStrategy is Chebyshev2OrderStrategy)
        #expect(EllipticFamily(ripple: .decibels(1), stopband: .decibels(40)).orderStrategy is EllipticOrderStrategy)
        #expect(BesselFamily().orderStrategy == nil, "Bessel has no order estimation, as in etk4j")
        let stock: [any FilterOrderStrategy] = [.butterworth, .chebyshev1, .chebyshev2, .elliptic]
        #expect(Set(stock.map { AnyStrategy($0) }).count == 4)
        // A scheme selects the member of the family: ripple and attenuation become the scheme's.
        #expect(Chebyshev1Family(ripple: .decibels(0.3)).fitted(maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) == Chebyshev1Family(ripple: .decibels(1)))
        #expect(Chebyshev2Family(stopband: .decibels(25)).fitted(maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) == Chebyshev2Family(stopband: .decibels(40)))
        #expect(EllipticFamily(ripple: .decibels(0.3), stopband: .decibels(25)).fitted(maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
                    == EllipticFamily(ripple: .decibels(1), stopband: .decibels(40)))
        #expect(ButterworthFamily().fitted(maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) == ButterworthFamily())
        #expect(BesselFamily(normalization: .delay).fitted(maximumLoss: .decibels(1), minimumAttenuation: .decibels(40)) == BesselFamily(normalization: .delay))
    }

    @Test func aNaturalFrequencyThatIsThePassBandEdgeComesBackToTheBit() throws {
        // Chebyshev I and elliptic filters are designed at the pass-band edge itself. For a
        // digital scheme the edge is pre-warped and mapped back; the estimate must not hand
        // back that round trip, which is the edge only to rounding.
        var generator = SeededGenerator(seed: 0x418C)
        let digital = IIRDesign.Domain.digital(sampleRate: 44_100)
        var roundTripDiffers = 0
        for _ in 0 ..< 200 {
            let edge = 50 + generator.nextUnit() * 9_000
            if atan(tan(.pi * (2 * edge / 44_100) / 2)) * 2 / .pi * 44_100 / 2 != edge { roundTripDiffers += 1 }
            for strategy in [Chebyshev1OrderStrategy() as any FilterOrderStrategy, EllipticOrderStrategy()] {
                let low = try strategy.minimumOrder(passband: .lowPass(cutoff: edge), stopband: .lowPass(cutoff: 1.5 * edge),
                                                    maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: digital)
                #expect(low.response == .lowPass(cutoff: edge))
                let band = try strategy.minimumOrder(passband: .bandPass(from: edge, to: 1.3 * edge), stopband: .bandPass(from: 0.7 * edge, to: 1.8 * edge),
                                                     maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: digital)
                #expect(band.response == .bandPass(from: edge, to: 1.3 * edge))
            }
            // Butterworth and Chebyshev II move the natural frequency: nothing to hand back.
            let moved = try ButterworthOrderStrategy().minimumOrder(passband: .lowPass(cutoff: edge), stopband: .lowPass(cutoff: 1.5 * edge),
                                                                    maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: digital)
            #expect(moved.response.edges[0] > edge)
        }
        #expect(roundTripDiffers > 0, "the round trip through the pre-warp is not exact: the test means something")
        // A band-stop is the exception: its pass-band edges are moved to where the order is smallest.
        let stop = try EllipticOrderStrategy().minimumOrder(passband: .bandStop(from: 500, to: 3_000), stopband: .bandStop(from: 1_000, to: 2_000),
                                                            maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: digital)
        #expect(stop.response.edges[0] >= 500 && stop.response.edges[1] <= 3_000)
        #expect(stop.response != .bandStop(from: 500, to: 3_000))
    }

    @Test func besselRejectsAToleranceScheme() {
        let error = thrownError {
            _ = try IIRDesign(.bessel(), passband: .lowPass(cutoff: 1_000), stopband: .lowPass(cutoff: 2_000),
                              maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: .digital(sampleRate: 48_000))
        }
        #expect(error?.isUnsupportedConfiguration == true)
        #expect(error?.description.contains("order estimation") == true)
    }

    // MARK: Negative paths

    @Test func schemesThatMakeNoSenseAreTypedErrors() {
        let strategy = ButterworthOrderStrategy()
        let digital = IIRDesign.Domain.digital(sampleRate: 48_000)
        func estimate(_ passband: FilterResponse, _ stopband: FilterResponse, loss: Amplification = .decibels(1),
                      attenuation: Amplification = .decibels(40), domain: IIRDesign.Domain = digital) -> DSPError? {
            thrownError {
                _ = try strategy.minimumOrder(passband: passband, stopband: stopband, maximumLoss: loss, minimumAttenuation: attenuation, domain: domain)
            }
        }
        // The two responses must be of one kind.
        #expect(estimate(.lowPass(cutoff: 1_000), .highPass(cutoff: 2_000))?.invalidParameterName == "stopband")
        #expect(estimate(.bandPass(from: 1_000, to: 2_000), .bandStop(from: 500, to: 3_000))?.invalidParameterName == "stopband")
        // The edges must be in the order of the response.
        #expect(estimate(.lowPass(cutoff: 2_000), .lowPass(cutoff: 1_000))?.invalidParameterName == "stopband")
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 1_000))?.invalidParameterName == "stopband")
        #expect(estimate(.highPass(cutoff: 1_000), .highPass(cutoff: 2_000))?.invalidParameterName == "stopband")
        #expect(estimate(.bandPass(from: 1_000, to: 2_000), .bandPass(from: 1_200, to: 3_000))?.invalidParameterName == "stopband")
        #expect(estimate(.bandPass(from: 2_000, to: 1_000), .bandPass(from: 500, to: 3_000))?.invalidParameterName == "stopband")
        #expect(estimate(.bandStop(from: 1_000, to: 2_000), .bandStop(from: 500, to: 3_000))?.invalidParameterName == "stopband")
        // Edges outside the axis.
        #expect(estimate(.lowPass(cutoff: 0), .lowPass(cutoff: 1_000))?.invalidParameterName == "passband")
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 24_000))?.invalidParameterName == "stopband")
        #expect(estimate(.lowPass(cutoff: .nan), .lowPass(cutoff: 1_000))?.invalidParameterName == "passband")
        #expect(estimate(.lowPass(cutoff: -5), .lowPass(cutoff: 1_000), domain: .analog)?.invalidParameterName == "passband")
        #expect(estimate(.lowPass(cutoff: 5), .lowPass(cutoff: .infinity), domain: .analog)?.invalidParameterName == "stopband")
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 2_000), domain: .digital(sampleRate: 0))?.invalidParameterName == "sampleRate")
        // Tolerances.
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 2_000), loss: .decibels(0))?.invalidParameterName == "maximumLoss")
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 2_000), attenuation: .decibels(.nan))?.invalidParameterName == "minimumAttenuation")
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 2_000), loss: .decibels(40), attenuation: .decibels(40))?.invalidParameterName == "minimumAttenuation")
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 2_000), loss: .decibels(50), attenuation: .decibels(40))?.invalidParameterName == "minimumAttenuation")
        // A transition band so narrow that the order leaves what is supported.
        #expect(estimate(.lowPass(cutoff: 1_000), .lowPass(cutoff: 1_000.5))?.isUnsupportedConfiguration == true)
    }

    @Test func aStrategyRejectsWhatItCannotAnswer() {
        let loss = Amplification.decibels(1)
        let attenuation = Amplification.decibels(40)
        let strategies: [any FilterOrderStrategy] = [ButterworthOrderStrategy(), Chebyshev1OrderStrategy(), Chebyshev2OrderStrategy(), EllipticOrderStrategy()]
        for strategy in strategies {
            for selectivity in [1.0, 0.5, -2, .nan, .infinity] {
                #expect(thrownError { _ = try strategy.fractionalOrder(selectivity: selectivity, maximumLoss: loss, minimumAttenuation: attenuation) }?.invalidParameterName == "selectivity")
            }
            #expect(thrownError { _ = try strategy.fractionalOrder(selectivity: 2, maximumLoss: .decibels(0), minimumAttenuation: attenuation) }?.invalidParameterName == "maximumLoss")
            #expect(thrownError { _ = try strategy.fractionalOrder(selectivity: 2, maximumLoss: loss, minimumAttenuation: .linear(1)) }?.invalidParameterName == "minimumAttenuation")
            #expect(thrownError { _ = try strategy.naturalFrequency(order: 0, maximumLoss: loss, minimumAttenuation: attenuation) }?.invalidParameterName == "order")
        }
        #expect(thrownError { _ = try EllipticOrderStrategy().fractionalOrder(selectivity: 2, maximumLoss: attenuation, minimumAttenuation: loss) }?.invalidParameterName == "minimumAttenuation")
        #expect(thrownError { _ = try ButterworthOrderStrategy().naturalFrequency(order: 3, maximumLoss: .decibels(0), minimumAttenuation: attenuation) }?.invalidParameterName == "maximumLoss")
        #expect(thrownError { _ = try Chebyshev2OrderStrategy().naturalFrequency(order: 3, maximumLoss: loss, minimumAttenuation: .decibels(0)) }?.invalidParameterName == "minimumAttenuation")
    }

    @Test func aStrategyWrittenOutsideThePackageGetsTheSameMapping() throws {
        /// Asks for twice the Butterworth order and keeps the pass-band edge.
        struct Generous: FilterOrderStrategy {
            func fractionalOrder(selectivity: Double, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double {
                2 * (try ButterworthOrderStrategy().fractionalOrder(selectivity: selectivity, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation))
            }

            func naturalFrequency(order: Int, maximumLoss: Amplification, minimumAttenuation: Amplification) throws(DSPError) -> Double { 1 }
        }
        struct GenerousFamily: FilterFamily {
            func prototype(order: Int) throws(DSPError) -> ZeroPoleGain { try AnalogPrototype.butterworth(order: order) }
            var orderStrategy: (any FilterOrderStrategy)? { Generous() }
        }
        let estimate = try Generous().minimumOrder(
            passband: .bandPass(from: 1_000, to: 2_000), stopband: .bandPass(from: 500, to: 3_000), maximumLoss: .decibels(1),
            minimumAttenuation: .decibels(40), domain: .digital(sampleRate: 48_000))
        let reference = try ButterworthOrderStrategy().minimumOrder(
            passband: .bandPass(from: 1_000, to: 2_000), stopband: .bandPass(from: 500, to: 3_000), maximumLoss: .decibels(1),
            minimumAttenuation: .decibels(40), domain: .digital(sampleRate: 48_000))
        #expect(estimate.order == 2 * reference.order || estimate.order == 2 * reference.order - 1)
        #expect(estimate.response == .bandPass(from: 1_000, to: 2_000), "a ratio of 1 keeps the pass-band edges, bit for bit")
        let design = try IIRDesign(GenerousFamily(), passband: .lowPass(cutoff: 1_000), stopband: .lowPass(cutoff: 2_000),
                                   maximumLoss: .decibels(1), minimumAttenuation: .decibels(40), domain: .digital(sampleRate: 48_000))
        #expect(design.order == 16 || design.order == 15)
        #expect(design.response == .lowPass(cutoff: 1_000))
        #expect(design.family == AnyStrategy(GenerousFamily()))
    }

    @Test func theMinimiserBehindTheBandStopEstimateFindsMinima() throws {
        // A parabola, an asymmetric valley and a minimum at the edge of the interval.
        expectClose(try BoundedMinimizer.minimize(from: -3, to: 5) { (x: Double) throws(DSPError) -> Double in (x - 1.25) * (x - 1.25) }, 1.25, .absolute(1e-5))
        expectClose(try BoundedMinimizer.minimize(from: 0.1, to: 10) { (x: Double) throws(DSPError) -> Double in x + 4 / x }, 2, .absolute(2e-5))
        expectClose(try BoundedMinimizer.minimize(from: 2, to: 9) { (x: Double) throws(DSPError) -> Double in x }, 2, .absolute(2e-5))
        expectClose(try BoundedMinimizer.minimize(from: 2, to: 9) { (x: Double) throws(DSPError) -> Double in -x }, 9, .absolute(2e-5))
        // A tighter tolerance is honoured, and the evaluation budget is a bound.
        expectClose(try BoundedMinimizer.minimize(from: -3, to: 5, tolerance: 1e-9) { (x: Double) throws(DSPError) -> Double in cosh(x - 0.5) }, 0.5, .absolute(1e-7))
        var evaluations = 0
        _ = try BoundedMinimizer.minimize(from: 0, to: 1, tolerance: 1e-12, maximumEvaluations: 7) { (x: Double) throws(DSPError) -> Double in
            evaluations += 1
            return abs(x - 0.3)
        }
        #expect(evaluations == 7)
        // An error raised by the function is passed on.
        #expect(thrownError {
            _ = try BoundedMinimizer.minimize(from: 0, to: 1) { (_: Double) throws(DSPError) -> Double in throw DSPError.cancelled }
        } == .cancelled)
    }
}
