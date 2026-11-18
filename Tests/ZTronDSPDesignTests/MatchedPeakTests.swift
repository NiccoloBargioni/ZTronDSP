import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-422. The matched second-order peak (§6.3.5; Vicanek 2016).
/// Acceptance: properties 1, 2, 4 and 5 of §6.3.5; smaller shape error near Nyquist than the
/// Cookbook peak (WP-420) on the fixture grid. Property 3 does not apply: the matched peak
/// is not 0 dB at the Nyquist frequency, by construction.
@Suite("Matched second-order peak (WP-422)")
struct MatchedPeakTests {
    private static let sampleRate = 48_000.0
    private static let gains: [Double] = [1, -1, 6, -6, 24, -24]
    private static let centres: [Double] = [20, 100, 1_000, 5_000, 12_000, 0.45 * sampleRate]

    private static func bandwidths(at centre: Double) -> [Bandwidth] {
        [.hertz(centre / 10), .hertz(centre / 3), .hertz(centre), .octaves(0.1), .octaves(1), .q(0.5), .q(4)]
    }

    /// The width in hertz that a bandwidth names: met exactly for hertz and octaves; for
    /// `.q`, the width of the analog prototype, which the matched section approaches.
    private static func width(_ bandwidth: Bandwidth, centre: Double) -> Double {
        switch bandwidth {
        case .hertz(let width): width
        case .octaves(let octaves): centre * (pow(2, octaves / 2) - pow(2, -octaves / 2))
        case .q(let q): centre / q
        }
    }

    private struct Band {
        let gain: Double
        let centre: Double
        let bandwidth: Bandwidth
        let design: MatchedPeakDesign
        var name: String { "\(gain) dB at \(centre) Hz, \(bandwidth)" }
        var isExact: Bool {
            if case .q = bandwidth { return false }
            return true
        }
    }

    /// The grid of the acceptance statement: every band that designs. What does not is held
    /// by `theBandsTheLimitRejectsAreTheOnesThatReachIt`.
    private static let grid: [Band] = {
        var bands: [Band] = []
        for gain in gains {
            for centre in centres {
                for bandwidth in bandwidths(at: centre) {
                    guard let design = try? MatchedPeakDesign(center: centre, gain: .decibels(gain), bandwidth: bandwidth, sampleRate: sampleRate) else { continue }
                    bands.append(Band(gain: gain, centre: centre, bandwidth: bandwidth, design: design))
                }
            }
        }
        return bands
    }()

    /// Frequencies in radians per sample: a logarithmic sweep of the whole axis and a fine
    /// linear sweep across the band.
    private static func axis(for band: Band) -> [Double] {
        let centre = 2 * Double.pi * band.centre / sampleRate
        let width = 2 * Double.pi * Self.width(band.bandwidth, centre: band.centre) / sampleRate
        var frequencies: [Double] = []
        let low = 2 * Double.pi * 1 / sampleRate
        for index in 0 ... 240 { frequencies.append(low * pow(Double.pi * 0.9999 / low, Double(index) / 240)) }
        let from = max(low / 2, centre - 3 * width)
        let to = min(Double.pi * 0.9999, centre + 3 * width)
        for index in 0 ... 360 { frequencies.append(from + (to - from) * Double(index) / 360) }
        frequencies.append(centre)
        return frequencies.sorted()
    }

    /// The frequencies at which the gain crosses half the requested gain, by bisection.
    private static func halfGainFrequencies(of band: Band) throws -> [Double] {
        let system = band.design.zeroPoleGain
        let frequencies = axis(for: band)
        let levels = try system.magnitudeResponse(at: frequencies, in: .decibels)
        let half = band.gain / 2
        var crossings: [Double] = []
        for index in 1 ..< levels.count where (levels[index - 1] < half) != (levels[index] < half) {
            var low = frequencies[index - 1], high = frequencies[index]
            let rising = levels[index] > levels[index - 1]
            for _ in 0 ..< 45 {
                let middle = (low + high) / 2
                let level = try system.magnitudeResponse(at: [middle], in: .decibels)[0]
                if (level > half) == rising { high = middle } else { low = middle }
            }
            crossings.append((low + high) / 2)
        }
        return crossings
    }

    @Test func theGridCoversTheAcceptanceStatement() {
        #expect(Self.grid.count >= 200, "\(Self.grid.count) bands design")
        #expect(Self.grid.contains { $0.centre == 20 } && Self.grid.contains { $0.centre == 0.45 * Self.sampleRate })
        #expect(Self.grid.contains { $0.gain == 24 } && Self.grid.contains { $0.gain == -24 } && Self.grid.contains { $0.gain == 1 })
        #expect(Self.grid.contains { if case .octaves = $0.bandwidth { true } else { false } })
        #expect(Self.grid.contains { if case .q = $0.bandwidth { true } else { false } })
        #expect(Self.grid.contains { if case .hertz = $0.bandwidth { true } else { false } })
        #expect(Self.grid.count < 6 * 6 * 7, "the limit removes bands at the top")
    }

    @Test func theBandsTheLimitRejectsAreTheOnesThatReachIt() throws {
        var rejected = 0
        for gain in Self.gains {
            for centre in Self.centres {
                for bandwidth in Self.bandwidths(at: centre) {
                    let error = thrownError { _ = try MatchedPeakDesign(center: centre, gain: .decibels(gain), bandwidth: bandwidth, sampleRate: Self.sampleRate) }
                    let width = Self.width(bandwidth, centre: centre)
                    let label = "\(gain) dB at \(centre) Hz, \(bandwidth)"
                    switch bandwidth {
                    case .hertz, .octaves:
                        // The two half-gain frequencies lie `width` apart, one on each side of
                        // the centre: the upper one is below centre + width.
                        if centre + width < 0.49 * Self.sampleRate { #expect(error == nil, "\(label) lies below the limit: \(String(describing: error))") }
                        if let error {
                            #expect(error.invalidParameterName == "bandwidth", "\(label): \(error)")
                            rejected += 1
                        }
                    case .q(let q):
                        // The analog prototype's upper half-gain frequency.
                        let upper = centre * ((1 + 1 / (4 * q * q)).squareRoot() + 1 / (2 * q))
                        if upper < 0.4 * Self.sampleRate { #expect(error == nil, "\(label): the prototype's band ends at \(upper) Hz: \(String(describing: error))") }
                        if let error {
                            #expect(error.invalidParameterName == "bandwidth" && upper > 0.45 * Self.sampleRate, "\(label): \(error)")
                            rejected += 1
                        }
                    }
                }
            }
        }
        #expect(rejected > 0 && rejected + Self.grid.count == 6 * 6 * 7, "\(rejected) rejected, \(Self.grid.count) designed")
        // What designs keeps its upper half-gain frequency below 0.49 of the sample rate.
        for band in Self.grid {
            let crossings = try Self.halfGainFrequencies(of: band)
            #expect((crossings.last ?? .pi) < 0.98 * .pi, "\(band.name): upper half-gain frequency \((crossings.last ?? .pi) / (2 * .pi)) of the sample rate")
        }
    }

    // MARK: Property 1

    @Test func property1TheGainAtTheCentreIsTheRequestedGain() throws {
        for band in Self.grid {
            let centre = 2 * Double.pi * band.centre / Self.sampleRate
            let level = try band.design.zeroPoleGain.magnitudeResponse(at: [centre], in: .decibels)[0]
            expectClose(level, band.gain, .absolute(0.01), band.name)
            Measurements.shared.record("WP-422 property 1: centre gain error, dB", abs(level - band.gain), bound: 0.01)
            // The gain at 0 Hz is 0 dB; at the Nyquist frequency it is what the analog peak has there.
            let ends = try band.design.zeroPoleGain.magnitudeResponse(at: [0, .pi], in: .decibels)
            expectClose(ends[0], 0, .absolute(1e-6), "\(band.name): 0 Hz")
            #expect(ends[1] * band.gain >= 0 && abs(ends[1]) < abs(band.gain) / 2, "\(band.name): \(ends[1]) dB at the Nyquist frequency")
        }
    }

    // MARK: Property 2

    @Test func property2TheGainIsHalfTheRequestedGainAtExactlyTwoFrequenciesABandwidthApart() throws {
        for band in Self.grid {
            let crossings = try Self.halfGainFrequencies(of: band)
            guard crossings.count == 2 else {
                Issue.record("\(band.name): the gain equals half the requested gain at \(crossings.count) frequencies, not 2")
                continue
            }
            let centre = 2 * Double.pi * band.centre / Self.sampleRate
            #expect(crossings[0] < centre && crossings[1] > centre, "\(band.name): one on each side of the centre")
            guard band.isExact else { continue }
            // Hertz and octaves: the distance is the bandwidth.
            let distance = (crossings[1] - crossings[0]) * Self.sampleRate / (2 * .pi)
            let expected = Self.width(band.bandwidth, centre: band.centre)
            expectClose(distance, expected, .relative(0.005), "\(band.name): the distance between the half-gain frequencies")
            Measurements.shared.record("WP-422 property 2: bandwidth error (hertz and octaves), relative", abs(distance - expected) / expected, bound: 0.005)
        }
    }

    @Test func aBandGivenAsQIsThatOfTheAnalogPrototype() throws {
        // `.q(Q)`: the poles are those of the analog peak of quality Q, mapped by z = e^{sT}.
        for band in Self.grid {
            guard case .q(let q) = band.bandwidth, band.gain > 0 else { continue }
            let amplitude = pow(10, band.gain / 40)
            let angle = 2 * Double.pi * band.centre / Self.sampleRate
            let quality = amplitude * q
            let radius = exp(-angle / (2 * quality))
            let pole = try #require(band.design.zeroPoleGain.poles.first)
            expectClose(pole.magnitude, radius, .relative(1e-12), "\(band.name): pole radius")
            if quality > 0.5 {
                expectClose(abs(pole.phase), angle * (1 - 1 / (4 * quality * quality)).squareRoot(), .relative(1e-9), "\(band.name): pole angle")
            } else {
                #expect(band.design.zeroPoleGain.poles.allSatisfy { $0.imaginary == 0 }, "\(band.name): an overdamped prototype has real poles")
            }
        }
    }

    // MARK: Property 4

    @Test func property4TheMagnitudeIsMonotonicOnEachSideOfTheCentre() throws {
        var worst = 0.0
        for band in Self.grid {
            let centre = 2 * Double.pi * band.centre / Self.sampleRate
            var frequencies = Self.axis(for: band)
            // Up to the Nyquist frequency itself: this is where a matched section differs.
            frequencies += (0 ... 200).map { Double.pi * (0.99 + 0.01 * Double($0) / 200) }
            frequencies.sort()
            let levels = try band.design.zeroPoleGain.magnitudeResponse(at: frequencies, in: .decibels)
            let sign: Double = band.gain > 0 ? 1 : -1
            for index in 1 ..< levels.count {
                let step = sign * (levels[index] - levels[index - 1])
                let retreat = frequencies[index] <= centre ? -step : step
                worst = max(worst, retreat)
                #expect(retreat <= 1e-9, "\(band.name): the magnitude turns back by \(retreat) dB at \(frequencies[index]) rad per sample")
            }
        }
        Measurements.shared.record("WP-422 property 4: largest step against the monotonic direction, dB", worst, bound: 1e-9)
    }

    // MARK: Property 5

    @Test func property5AllPolesLieStrictlyInsideTheUnitCircle() throws {
        var largest = 0.0
        for band in Self.grid {
            let system = band.design.zeroPoleGain
            #expect(system.poles.count == 2 && system.zeros.count == 2 && system.domain == .digital, "\(band.name)")
            for pole in system.poles {
                largest = max(largest, pole.magnitude)
                #expect(pole.magnitude < 1, "\(band.name): pole \(pole)")
            }
            #expect(try system.isStable && band.design.secondOrderSections.sections.count == 1, "\(band.name)")
            #expect(band.design.secondOrderSections.stabilityMargin > 0, "\(band.name)")
            // The zeros of a boost are the poles of the same cut: inside the unit circle too.
            #expect(system.zeros.allSatisfy { $0.magnitude < 1 }, "\(band.name): zeros \(system.zeros)")
        }
        Measurements.shared.record("WP-422 property 5: largest pole radius over the grid", largest, bound: 1)
    }

    @Test func aCutIsTheInverseOfTheBoost() throws {
        let frequencies = (0 ... 400).map { Double.pi * Double($0) / 400 }
        for band in Self.grid where band.gain > 0 {
            let cut = try MatchedPeakDesign(center: band.centre, gain: .decibels(-band.gain), bandwidth: band.bandwidth, sampleRate: Self.sampleRate)
            let up = try band.design.zeroPoleGain.frequencyResponse(at: frequencies), down = try cut.zeroPoleGain.frequencyResponse(at: frequencies)
            let worst = zip(up, down).map { ($0 * $1 - Complex(1)).magnitude }.max() ?? 1
            #expect(worst <= 1e-6, "\(band.name): boost times cut is \(worst) from 1")
            Measurements.shared.record("WP-422 a boost cascaded with the same cut: distance from the identity", worst, bound: 1e-6)
        }
    }

    // MARK: Shape, against the Cookbook peak

    /// The analog peak the two digital sections stand for: gain G at f₀, half the gain in
    /// decibels at two frequencies `width` apart, 0 dB at 0 Hz and at infinity.
    private func analogPeak(gain: Double, centre: Double, width: Double, at hertz: [Double]) -> [Double] {
        let boost = pow(10, abs(gain) / 20), amplitude = boost.squareRoot()
        let quality = centre / width
        return hertz.map { frequency in
            let u = frequency / centre
            let numerator = Complex(1 - u * u, u * amplitude / quality), denominator = Complex(1 - u * u, u / (amplitude * quality))
            let level = 20 * log10((numerator / denominator).magnitude)
            return gain >= 0 ? level : -level
        }
    }

    @Test func nearNyquistTheShapeIsCloserToTheAnalogPeakThanTheCookbooks() throws {
        // The fixture grid: centres in the upper half of the band, where the Cookbook's peak
        // is squeezed against the Nyquist frequency.
        var compared = 0
        var worstRatio = 0.0
        var worstMatched = 0.0, worstCookbook = 0.0
        let hertz = (1 ... 2_000).map { 0.5 * Self.sampleRate * 0.9995 * Double($0) / 2_000 }
        let omega = hertz.map { 2 * Double.pi * $0 / Self.sampleRate }
        for fraction in [0.2, 0.25, 0.3, 0.35, 0.4, 0.45] {
            let centre = fraction * Self.sampleRate
            for gain in [-24.0, -12, -6, -3, 3, 6, 12, 24] {
                for bandwidth in [Bandwidth.octaves(0.1), .octaves(1.0 / 3), .octaves(1), .hertz(centre / 10), .hertz(centre / 3)] {
                    guard let matched = try? MatchedPeakDesign(center: centre, gain: .decibels(gain), bandwidth: bandwidth, sampleRate: Self.sampleRate),
                          let cookbook = try? EqualizerDesign.bandBoost(center: centre, gain: .decibels(gain), bandwidth: bandwidth, order: 1, sampleRate: Self.sampleRate)
                    else { continue }
                    let analog = analogPeak(gain: gain, centre: centre, width: Self.width(bandwidth, centre: centre), at: hertz)
                    func shapeError(_ system: ZeroPoleGain) throws -> Double {
                        zip(try system.magnitudeResponse(at: omega, in: .decibels), analog).map { abs($0 - $1) }.max() ?? .infinity
                    }
                    let mine = try shapeError(matched.zeroPoleGain), theirs = try shapeError(cookbook.zeroPoleGain)
                    #expect(mine < theirs, "\(gain) dB at \(fraction)·fs, \(bandwidth): the matched peak is \(mine) dB from the analog peak, the Cookbook's \(theirs) dB")
                    worstRatio = max(worstRatio, mine / theirs)
                    worstMatched = max(worstMatched, mine)
                    worstCookbook = max(worstCookbook, theirs)
                    compared += 1
                }
            }
        }
        #expect(compared >= 150, "\(compared) fixtures")
        Measurements.shared.record("WP-422 shape error against the analog peak, matched over Cookbook: largest ratio over \(compared) fixtures", worstRatio, bound: 1)
        Measurements.shared.record("WP-422 shape error against the analog peak, dB: matched, worst fixture", worstMatched, bound: worstCookbook)
        Measurements.shared.record("WP-422 shape error against the analog peak, dB: Cookbook, worst fixture", worstCookbook, bound: worstCookbook)
    }

    // MARK: Stress

    /// A band a fraction of a hertz wide at a low centre: the sums of the expanded
    /// coefficients cancel there (the first formulation of this design lost the band at
    /// 20 Hz from a width of 7 Hz down), the factored form does not.
    @Test func stressANarrowLowBandKeepsItsAccuracy() throws {
        for (centre, width, gain, rate) in [(20.0, 0.02, 24.0, 48_000.0), (20, 2, -6, 48_000), (20, 0.5, 12, 192_000), (5, 0.01, 6, 96_000)] {
            let design = try MatchedPeakDesign(center: centre, gain: .decibels(gain), bandwidth: .hertz(width), sampleRate: rate)
            let system = design.zeroPoleGain
            let angle = 2 * Double.pi * centre / rate
            let level = try system.magnitudeResponse(at: [angle], in: .decibels)[0]
            expectClose(level, gain, .absolute(1e-6), "\(gain) dB at \(centre) Hz, \(width) Hz wide, at \(rate) Hz: centre gain")
            Measurements.shared.record("WP-422 stress, narrow low bands: centre gain error, dB", abs(level - gain), bound: 1e-6)
            // The half-gain frequencies, by bisection on the response itself.
            func edge(from inside: Double, to outside: Double) throws -> Double {
                var inside = inside, outside = outside
                for _ in 0 ..< 80 {
                    let middle = (inside + outside) / 2
                    let value = try system.magnitudeResponse(at: [middle], in: .decibels)[0]
                    if abs(value) > abs(gain) / 2 { inside = middle } else { outside = middle }
                }
                return (inside + outside) / 2
            }
            let span = 2 * Double.pi * width / rate
            let measured = (try edge(from: angle, to: angle + 3 * span) - edge(from: angle, to: angle - 3 * span)) * rate / (2 * .pi)
            expectClose(measured, width, .relative(1e-6), "\(gain) dB at \(centre) Hz, \(width) Hz wide, at \(rate) Hz: bandwidth")
            Measurements.shared.record("WP-422 stress, narrow low bands: bandwidth error, relative", abs(measured - width) / width, bound: 1e-6)
            #expect(system.poles.allSatisfy { $0.magnitude < 1 } && system.zeros.allSatisfy { $0.magnitude < 1 })
            expectClose(try system.magnitudeResponse(at: [0], in: .decibels)[0], 0, .absolute(1e-9), "0 Hz")
        }
    }

    // MARK: Values

    @Test func whatIsNoPeakIsATypedError() throws {
        func failure(center: Double = 1_000, gain: Amplification = .decibels(6), bandwidth: Bandwidth = .octaves(1), sampleRate: Double = 48_000) -> DSPError? {
            thrownError { _ = try MatchedPeakDesign(center: center, gain: gain, bandwidth: bandwidth, sampleRate: sampleRate) }
        }
        #expect(failure() == nil)
        #expect(failure(center: 0)?.invalidParameterName == "center" && failure(center: 24_000)?.invalidParameterName == "center")
        #expect(failure(center: .nan)?.invalidParameterName == "center" && failure(center: -100)?.invalidParameterName == "center")
        #expect(failure(gain: .linear(0))?.invalidParameterName == "gain" && failure(gain: .decibels(.infinity))?.invalidParameterName == "gain")
        #expect(failure(bandwidth: .hertz(0))?.invalidParameterName == "bandwidth" && failure(bandwidth: .octaves(-1))?.invalidParameterName == "bandwidth")
        #expect(failure(bandwidth: .q(0))?.invalidParameterName == "bandwidth" && failure(bandwidth: .q(.nan))?.invalidParameterName == "bandwidth")
        #expect(failure(sampleRate: 0)?.invalidParameterName == "sampleRate")
        // A band that reaches 0.49 of the sample rate, and one for which no section exists.
        #expect(failure(center: 21_600, bandwidth: .octaves(1))?.invalidParameterName == "bandwidth")
        #expect(failure(center: 23_000, bandwidth: .hertz(3_000))?.invalidParameterName == "bandwidth")
        // 0 dB is the identity, whatever the band.
        let flat = try MatchedPeakDesign(center: 1_000, gain: .decibels(0), bandwidth: .octaves(1), sampleRate: 48_000)
        #expect(flat.secondOrderSections.sections == [.identity] && flat.zeroPoleGain.gain == 1 && flat.zeroPoleGain.poles.isEmpty)
        // A value: equal arguments, equal designs.
        #expect(try MatchedPeakDesign(center: 1_000, gain: .decibels(6), bandwidth: .q(2), sampleRate: 48_000)
            == MatchedPeakDesign(center: 1_000, gain: .decibels(6), bandwidth: .q(2), sampleRate: 48_000))
        #expect(try MatchedPeakDesign(center: 1_000, gain: .decibels(6), bandwidth: .q(2), sampleRate: 48_000)
            != MatchedPeakDesign(center: 1_000, gain: .decibels(6), bandwidth: .q(2), sampleRate: 44_100))
    }
}
