import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-420: the Audio EQ Cookbook's peaking section and shelves. Acceptance: centre gain within
/// 0.01 dB; golden (the Cookbook formulas in double precision; gains ±6 and ±12 dB; Q 0.5, 1,
/// 4; centres 100 Hz, 1 kHz, 10 kHz; coefficients within 1e-12).
@Suite("Cookbook peaking section and shelves (WP-420)")
struct CookbookEqualizerTests {
    private func designs() throws -> [(golden: GoldenCase, kind: String, design: EqualizerDesign, gain: Double, frequency: Double, sampleRate: Double)] {
        let file = try Golden.cookbook.get()
        #expect(file.cases.count == 3 * 4 * (3 * 3 + 2 * 2))
        var result: [(GoldenCase, String, EqualizerDesign, Double, Double, Double)] = []
        for golden in file.cases {
            let kind = try golden.string("kind")
            let frequency = try golden.number("frequency")
            let gain = try golden.number("gain")
            let sampleRate = try golden.number("sample_rate")
            let design: EqualizerDesign
            if kind == "peaking" {
                design = try EqualizerDesign.bandBoost(center: frequency, gain: .decibels(gain), bandwidth: .q(try golden.number("q")), sampleRate: sampleRate)
            } else {
                let slope: ShelfSlope
                if golden.parameters["q"] != nil { slope = .q(try golden.number("q")) } else { slope = .slope(try golden.number("slope")) }
                design = kind == "lowshelf"
                    ? try EqualizerDesign.lowShelf(midpoint: frequency, gain: .decibels(gain), slope: slope, sampleRate: sampleRate)
                    : try EqualizerDesign.highShelf(midpoint: frequency, gain: .decibels(gain), slope: slope, sampleRate: sampleRate)
            }
            result.append((golden, kind, design, gain, frequency, sampleRate))
        }
        return result
    }

    @Test func theCoefficientsAreTheCookbooks() throws {
        for item in try designs() {
            let sections = item.design.secondOrderSections
            #expect(sections.domain == .digital && sections.sections.count == 1, "\(item.golden.name)")
            let expected = try item.golden.real("section")
            let actual = sections.sections[0].coefficients
            expectClose(actual, expected, .absolute(1e-12), item.golden.name)
            Measurements.shared.record("WP-420 Cookbook coefficients, absolute", zip(actual, expected).map { abs($0 - $1) }.max()!, bound: 1e-12)
        }
    }

    @Test func theGainAtTheCentreIsTheRequestedGain() throws {
        for item in try designs() {
            let angle = 2 * Double.pi * item.frequency / item.sampleRate
            // From the sections that run, and from the zeros and poles: the two must agree.
            for (form, system) in [("sections", item.design.secondOrderSections as any LTISystem), ("zeros and poles", item.design.zeroPoleGain)] {
                let levels = try system.magnitudeResponse(at: [0, angle, .pi], in: .decibels)
                switch item.kind {
                case "peaking":
                    expectClose(levels[1], item.gain, .absolute(0.01), "\(item.golden.name), \(form): centre")
                    expectClose(levels[0], 0, .absolute(0.01), "\(item.golden.name), \(form): 0 Hz")
                    expectClose(levels[2], 0, .absolute(0.01), "\(item.golden.name), \(form): Nyquist")
                    Measurements.shared.record("WP-420 peaking: centre gain error, dB", abs(levels[1] - item.gain), bound: 0.01)
                case "lowshelf":
                    expectClose(levels[0], item.gain, .absolute(0.01), "\(item.golden.name), \(form): 0 Hz")
                    expectClose(levels[1], item.gain / 2, .absolute(0.01), "\(item.golden.name), \(form): midpoint")
                    expectClose(levels[2], 0, .absolute(0.01), "\(item.golden.name), \(form): Nyquist")
                    Measurements.shared.record("WP-420 shelves: shelf and midpoint gain error, dB", max(abs(levels[0] - item.gain), abs(levels[1] - item.gain / 2)), bound: 0.01)
                default:
                    expectClose(levels[2], item.gain, .absolute(0.01), "\(item.golden.name), \(form): Nyquist")
                    expectClose(levels[1], item.gain / 2, .absolute(0.01), "\(item.golden.name), \(form): midpoint")
                    expectClose(levels[0], 0, .absolute(0.01), "\(item.golden.name), \(form): 0 Hz")
                    Measurements.shared.record("WP-420 shelves: shelf and midpoint gain error, dB", max(abs(levels[2] - item.gain), abs(levels[1] - item.gain / 2)), bound: 0.01)
                }
            }
            #expect(try item.design.zeroPoleGain.isStable, "\(item.golden.name)")
        }
    }

    @Test func aShelfWithASlopeOfOneIsMonotonicAndACutInvertsABoost() throws {
        let sampleRate = 48_000.0
        let frequencies = (1 ..< 2_000).map { Double($0) * .pi / 2_000 }
        for gain in [6.0, -12.0] {
            let low = try EqualizerDesign.lowShelf(midpoint: 500, gain: .decibels(gain), sampleRate: sampleRate)
            let high = try EqualizerDesign.highShelf(midpoint: 500, gain: .decibels(gain), sampleRate: sampleRate)
            let lowLevels = try low.secondOrderSections.magnitudeResponse(at: frequencies, in: .decibels)
            let highLevels = try high.secondOrderSections.magnitudeResponse(at: frequencies, in: .decibels)
            for (earlier, later) in zip(lowLevels, lowLevels.dropFirst()) {
                #expect(gain > 0 ? later <= earlier + 1e-9 : later >= earlier - 1e-9, "low shelf, \(gain) dB")
            }
            for (earlier, later) in zip(highLevels, highLevels.dropFirst()) {
                #expect(gain > 0 ? later >= earlier - 1e-9 : later <= earlier + 1e-9, "high shelf, \(gain) dB")
            }
            // The default is a slope of 1, which is Q = 1/√2.
            #expect(low == (try EqualizerDesign.lowShelf(midpoint: 500, gain: .decibels(gain), slope: .slope(1), sampleRate: sampleRate)))
            let byQuality = try EqualizerDesign.lowShelf(midpoint: 500, gain: .decibels(gain), slope: .q(0.5.squareRoot()), sampleRate: sampleRate)
            expectClose(byQuality.secondOrderSections.coefficients, low.secondOrderSections.coefficients, .absolute(1e-14))
            // A cut is the inverse of the boost: the product of the two responses is 1.
            let inverse = try EqualizerDesign.lowShelf(midpoint: 500, gain: .decibels(-gain), sampleRate: sampleRate)
            let product = zip(try low.zeroPoleGain.frequencyResponse(at: frequencies), try inverse.zeroPoleGain.frequencyResponse(at: frequencies)).map { $0 * $1 }
            #expect(product.allSatisfy { ($0 - Complex.one).magnitude <= 1e-12 })
        }
        // A gain of 0 dB is the identity.
        let flat = try EqualizerDesign.highShelf(midpoint: 500, gain: .decibels(0), sampleRate: sampleRate)
        #expect(try flat.secondOrderSections.magnitudeResponse(at: frequencies).allSatisfy { abs($0 - 1) <= 1e-13 })
    }

    @Test func invalidShelvesAreTypedErrors() {
        func low(_ midpoint: Double = 500, _ gain: Amplification = .decibels(6), _ slope: ShelfSlope = .slope(1), _ sampleRate: Double = 48_000) -> DSPError? {
            thrownError { _ = try EqualizerDesign.lowShelf(midpoint: midpoint, gain: gain, slope: slope, sampleRate: sampleRate) }
        }
        for bad in [0.0, -5, 24_000, 50_000, .nan, .infinity] {
            #expect(low(bad)?.invalidParameterName == "midpoint", "\(bad)")
            #expect(thrownError { _ = try EqualizerDesign.highShelf(midpoint: bad, gain: .decibels(6), sampleRate: 48_000) }?.invalidParameterName == "midpoint")
        }
        for bad in [Amplification.linear(0), .linear(-2), .decibels(.nan), .decibels(.infinity), .linear(.infinity)] {
            #expect(low(500, bad)?.invalidParameterName == "gain", "\(bad)")
        }
        for bad in [ShelfSlope.slope(0), .slope(-1), .slope(.nan), .q(0), .q(-1), .q(.infinity), .slope(10)] {
            #expect(low(500, .decibels(12), bad)?.invalidParameterName == "slope", "\(bad)")
        }
        for bad in [0.0, -48_000, .nan, .infinity] {
            #expect(low(500, .decibels(6), .slope(1), bad)?.invalidParameterName == "sampleRate")
        }
        #expect(low() == nil)
    }
}

/// WP-421: the high-order, maximally flat band-boost, designed and paired in zero-pole form.
/// Acceptance: the six properties of §6.3.5, for orders 1…8, gains ±1…±24 dB, centres from
/// 20 Hz to 0.45·fs and bandwidths within the limit.
@Suite("High-order band-boost (WP-421)")
struct BandBoostTests {
    private static let sampleRate = 48_000.0
    private static let orders = Array(1 ... 8)
    private static let gains: [Double] = [1, -1, 6, -6, 24, -24]
    private static let centres: [Double] = [20, 100, 1_000, 5_000, 12_000, 0.45 * sampleRate]

    /// The bandwidths tried at a centre: three widths in hertz, two in octaves, two as Q.
    private static func bandwidths(at centre: Double) -> [Bandwidth] {
        [.hertz(centre / 10), .hertz(centre / 3), .hertz(centre), .octaves(0.1), .octaves(1), .q(0.5), .q(4)]
    }

    /// The width in hertz that a bandwidth names (§6.3.5).
    private static func width(_ bandwidth: Bandwidth, centre: Double) -> Double {
        switch bandwidth {
        case .hertz(let width): width
        case .octaves(let octaves): centre * (pow(2, octaves / 2) - pow(2, -octaves / 2))
        case .q(let q): 2 * atan(sin(2 * .pi * centre / sampleRate) / (2 * q)) * sampleRate / (2 * .pi)
        }
    }

    /// Where the band's upper half-gain frequency falls, as a fraction of the sample rate.
    private static func upperEdge(_ bandwidth: Bandwidth, centre: Double) -> Double {
        let half = Double.pi * width(bandwidth, centre: centre) / sampleRate
        return (half + acos(cos(2 * .pi * centre / sampleRate) * cos(half))) / (2 * .pi)
    }

    private struct Band {
        let order: Int
        let gain: Double
        let centre: Double
        let bandwidth: Bandwidth
        var name: String { "order \(order), \(gain) dB at \(centre) Hz, \(bandwidth)" }

        func design(gain: Double? = nil) throws -> EqualizerDesign {
            try EqualizerDesign.bandBoost(center: centre, gain: .decibels(gain ?? self.gain), bandwidth: bandwidth, order: order,
                                          sampleRate: BandBoostTests.sampleRate)
        }
    }

    /// The grid of the acceptance statement, without the bands that the 0.49·fs limit rejects.
    private static let grid: [Band] = {
        var bands: [Band] = []
        for order in orders {
            for gain in gains {
                for centre in centres {
                    for bandwidth in bandwidths(at: centre) where upperEdge(bandwidth, centre: centre) < 0.49 {
                        bands.append(Band(order: order, gain: gain, centre: centre, bandwidth: bandwidth))
                    }
                }
            }
        }
        return bands
    }()

    /// Frequencies in radians per sample: a logarithmic sweep of the whole axis, and a fine
    /// linear sweep across the band, so that a narrow band at a low centre is resolved.
    private static func axis(for band: Band) -> [Double] {
        let centre = 2 * Double.pi * band.centre / sampleRate
        let width = 2 * Double.pi * BandBoostTests.width(band.bandwidth, centre: band.centre) / sampleRate
        var frequencies: [Double] = []
        let low = 2 * Double.pi * 1 / sampleRate
        for index in 0 ... 240 { frequencies.append(low * pow(Double.pi * 0.9999 / low, Double(index) / 240)) }
        let from = max(low / 2, centre - 3 * width)
        let to = min(Double.pi * 0.9999, centre + 3 * width)
        for index in 0 ... 360 { frequencies.append(from + (to - from) * Double(index) / 360) }
        frequencies.append(centre)
        return frequencies.sorted()
    }

    @Test func theGridCoversTheAcceptanceStatement() {
        #expect(Self.grid.count > 1_500)
        #expect(Set(Self.grid.map(\.order)) == Set(1 ... 8))
        #expect(Self.grid.contains { $0.centre == 20 } && Self.grid.contains { $0.centre == 0.45 * Self.sampleRate })
        #expect(Self.grid.contains { $0.gain == 24 } && Self.grid.contains { $0.gain == -24 })
        // Every kind of bandwidth is present, and the limit removed some bands at the top.
        #expect(Self.grid.contains { if case .octaves = $0.bandwidth { true } else { false } })
        #expect(Self.grid.contains { if case .q = $0.bandwidth { true } else { false } })
        #expect(Self.grid.count < 8 * 6 * 6 * 7)
    }

    // MARK: Property 1 and 3

    @Test func property1TheGainAtTheCentreIsTheRequestedGain() throws {
        for band in Self.grid {
            let centre = 2 * Double.pi * band.centre / Self.sampleRate
            let level = try band.design().zeroPoleGain.magnitudeResponse(at: [centre], in: .decibels)[0]
            expectClose(level, band.gain, .absolute(0.01), band.name)
            Measurements.shared.record("WP-421 property 1: centre gain error, dB", abs(level - band.gain), bound: 0.01)
        }
    }

    @Test func property3TheGainAtZeroHertzAndAtNyquistIsZeroDecibels() throws {
        for band in Self.grid {
            let levels = try band.design().zeroPoleGain.magnitudeResponse(at: [0, .pi], in: .decibels)
            expectClose(levels[0], 0, .absolute(0.01), "\(band.name): 0 Hz")
            expectClose(levels[1], 0, .absolute(0.01), "\(band.name): Nyquist")
            Measurements.shared.record("WP-421 property 3: gain at 0 Hz and Nyquist, dB", max(abs(levels[0]), abs(levels[1])), bound: 0.01)
        }
    }

    // MARK: Property 2

    @Test func property2TheGainIsHalfTheRequestedGainAtExactlyTwoFrequenciesABandwidthApart() throws {
        for band in Self.grid {
            let system = try band.design().zeroPoleGain
            let frequencies = Self.axis(for: band)
            let levels = try system.magnitudeResponse(at: frequencies, in: .decibels)
            // gain − G/2 changes sign where the response crosses half the gain.
            let half = band.gain / 2
            var crossings: [Double] = []
            // A grid point that sits exactly on half the gain counts as above it, so that such
            // a crossing is counted once.
            for index in 1 ..< levels.count where (levels[index - 1] < half) != (levels[index] < half) {
                // Bisection between the two grid points.
                var low = frequencies[index - 1]
                var high = frequencies[index]
                let rising = levels[index] > levels[index - 1]
                for _ in 0 ..< 45 {
                    let middle = (low + high) / 2
                    let level = try system.magnitudeResponse(at: [middle], in: .decibels)[0]
                    if (level > half) == rising { high = middle } else { low = middle }
                }
                crossings.append((low + high) / 2)
            }
            guard crossings.count == 2 else {
                Issue.record("\(band.name): the gain equals half the requested gain at \(crossings.count) frequencies, not 2")
                continue
            }
            #expect(crossings[0] < 2 * .pi * band.centre / Self.sampleRate && crossings[1] > 2 * .pi * band.centre / Self.sampleRate, "one on each side of the centre")
            let distance = (crossings[1] - crossings[0]) * Self.sampleRate / (2 * .pi)
            let expected = Self.width(band.bandwidth, centre: band.centre)
            expectClose(distance, expected, .relative(0.005), "\(band.name): the distance between the half-gain frequencies")
            Measurements.shared.record("WP-421 property 2: bandwidth error, relative", abs(distance - expected) / expected, bound: 0.005)
            // The upper one is where the 0.49·fs rule looks.
            expectClose(crossings[1] / (2 * .pi), Self.upperEdge(band.bandwidth, centre: band.centre), .relative(1e-6), band.name)
        }
    }

    // MARK: Property 4

    @Test func property4TheMagnitudeIsMonotonicOnEachSideOfTheCentre() throws {
        var worst = 0.0
        for band in Self.grid {
            let centre = 2 * Double.pi * band.centre / Self.sampleRate
            let frequencies = Self.axis(for: band)
            let levels = try band.design().zeroPoleGain.magnitudeResponse(at: frequencies, in: .decibels)
            // Towards the centre a boost rises and a cut falls; away from it the reverse.
            let sign: Double = band.gain > 0 ? 1 : -1
            for index in 1 ..< levels.count {
                let step = sign * (levels[index] - levels[index - 1])
                let towardsCentre = frequencies[index] <= centre
                let retreat = towardsCentre ? -step : step
                worst = max(worst, retreat)
                #expect(retreat <= 1e-9, "\(band.name): the magnitude turns back by \(retreat) dB at \(frequencies[index]) rad per sample")
            }
        }
        Measurements.shared.record("WP-421 property 4: largest step against the monotonic direction, dB", worst, bound: 1e-9)
    }

    // MARK: Property 5

    @Test func property5AllPolesLieStrictlyInsideTheUnitCircle() throws {
        var largest = 0.0
        for band in Self.grid {
            let design = try band.design()
            for pole in design.zeroPoleGain.poles {
                largest = max(largest, pole.magnitude)
                #expect(pole.magnitude < 1, "\(band.name): pole \(pole) has radius \(pole.magnitude)")
            }
            #expect(design.zeroPoleGain.poles.count == 2 * band.order)
            #expect(try design.zeroPoleGain.isStable && design.secondOrderSections.isStable, "\(band.name)")
        }
        Measurements.shared.record("WP-421 property 5: largest pole radius over the grid", largest, bound: 1)
    }

    // MARK: Property 6

    @Test func property6ABoostAndTheSameCutAreTheIdentity() throws {
        for band in Self.grid where band.gain > 0 {
            let boost = try band.design().zeroPoleGain
            let cut = try band.design(gain: -band.gain).zeroPoleGain
            let frequencies = Self.axis(for: band)
            let product = zip(try boost.frequencyResponse(at: frequencies), try cut.frequencyResponse(at: frequencies)).map { $0 * $1 }
            let worst = product.map { ($0 - Complex.one).magnitude }.max() ?? 0
            #expect(worst <= 1e-6, "\(band.name): boost times cut differs from 1 by \(worst)")
            Measurements.shared.record("WP-421 property 6: magnitude of boost·cut − 1, from the zero-pole forms", worst, bound: 1e-6)
        }
    }

    // MARK: The design

    @Test func orderOneIsTheCookbookSectionAndOrderNRunsAsNBiquads() throws {
        for band in Self.grid where band.gain == 6 && band.centre == 1_000 {
            let design = try band.design()
            #expect(design.secondOrderSections.sections.count == band.order, "\(band.name)")
            #expect(design.zeroPoleGain.zeros.count == 2 * band.order && design.zeroPoleGain.domain == .digital)
            // The sections that run and the zeros and poles they were paired from agree.
            let frequencies = Self.axis(for: band)
            expectResponseClose(try design.secondOrderSections.frequencyResponse(at: frequencies),
                                try design.zeroPoleGain.frequencyResponse(at: frequencies), relativeToPeak: 1e-10, band.name)
            if band.order == 1 {
                // Order 1 is the Cookbook's section: b0 = 1 + αA, b2 = 1 − αA, a0 = 1 + α/A, with α = tan(Δω/2).
                let alpha = tan(.pi * Self.width(band.bandwidth, centre: band.centre) / Self.sampleRate)
                let amplitude = pow(10, band.gain / 40)
                let cosine = cos(2 * Double.pi * band.centre / Self.sampleRate)
                let a0 = 1 + alpha / amplitude
                let expected = [(1 + alpha * amplitude) / a0, -2 * cosine / a0, (1 - alpha * amplitude) / a0, -2 * cosine / a0, (1 - alpha / amplitude) / a0]
                expectClose(design.secondOrderSections.sections[0].coefficients, expected, .absolute(1e-13), band.name)
                // The section is the Cookbook's own, not one paired from the zeros and poles:
                // above and below the line it has one middle coefficient, −2·cos ω₀ / a₀.
                let coefficients = design.secondOrderSections.sections[0].coefficients
                #expect(coefficients[1] == coefficients[3], "\(band.name): b1 \(coefficients[1]), a1 \(coefficients[3])")
            }
        }
        // The default order is 1.
        #expect(try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .octaves(1), sampleRate: 48_000)
                    == EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .octaves(1), order: 1, sampleRate: 48_000))
    }

    @Test func aHigherOrderHasAFlatterTopAndSteeperSkirts() throws {
        let sampleRate = Self.sampleRate
        let centre = 2 * Double.pi * 1_000 / sampleRate
        var previousTop = 0.0
        var previousSkirt = Double.infinity
        for order in [1, 2, 4, 8] {
            let system = try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(12), bandwidth: .hertz(400), order: order, sampleRate: sampleRate).zeroPoleGain
            // 100 Hz off the centre (inside the band) and 600 Hz off (outside).
            let levels = try system.magnitudeResponse(at: [centre * 1.1, centre * 1.6], in: .decibels)
            #expect(levels[0] > previousTop, "order \(order): \(levels[0]) dB inside the band")
            #expect(levels[1] < previousSkirt, "order \(order): \(levels[1]) dB outside the band")
            previousTop = levels[0]
            previousSkirt = levels[1]
        }
        #expect(previousTop > 11.99 && previousSkirt < 0.01, "order 8 is all but rectangular")
    }

    @Test func aRollOffNamesTheOrder() throws {
        let byRollOff = try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .hertz(300), rollOff: .decibelsPerOctave(24), sampleRate: 48_000)
        let byOrder = try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .hertz(300), order: 4, sampleRate: 48_000)
        #expect(byRollOff == byOrder)
        #expect(thrownError {
            _ = try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .hertz(300), rollOff: .decibelsPerOctave(25), sampleRate: 48_000)
        }?.invalidParameterName == "rollOff")
        #expect(try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .hertz(300), rollOff: .decibelsPerOctave(25), rounding: .up, sampleRate: 48_000)
                    == EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .hertz(300), order: 5, sampleRate: 48_000))
    }

    @Test func eachSkirtHasTheSlopeOfTheUnderlyingPrototype() throws {
        // The band is the image of a low-pass shelf whose excess power gain, |H|² − 1, is that
        // of an order-N Butterworth filter: N·6.02 dB per octave of the prototype's frequency
        // Ω = |cos ω₀ − cos ω| / sin ω. Measured an octave apart in Ω, on both skirts.
        let sampleRate = Self.sampleRate
        let angle = 2 * Double.pi * 1_000 / sampleRate
        let edge = tan(.pi * 300 / sampleRate)                       // Ω at the band's edges
        for order in [1, 2, 4, 8] {
            let system = try EqualizerDesign.bandBoost(center: 1_000, gain: .decibels(6), bandwidth: .hertz(300), rollOff: .order(order), sampleRate: sampleRate).zeroPoleGain
            // Far enough out that the skirt is straight, close enough that the excess, which
            // falls as Ω^(−2N), is still well above the rounding of a double.
            let far = pow(2, 8 / Double(order))
            func frequency(_ multiple: Double, above: Bool) -> Double {
                let prototype = multiple * edge
                let base = acos(cos(angle) / (1 + prototype * prototype).squareRoot())
                return above ? base + atan(prototype) : base - atan(prototype)
            }
            for above in [false, true] {
                let magnitudes = try system.magnitudeResponse(at: [frequency(far, above: above), frequency(2 * far, above: above)])
                let excess = magnitudes.map { 10 * log10($0 * $0 - 1) }
                let slope = excess[0] - excess[1]
                expectClose(slope, Double(order) * RollOff.decibelsPerOctavePerOrder, .absolute(0.5), "order \(order), \(above ? "upper" : "lower") skirt")
                Measurements.shared.record("WP-419/421 band-boost skirt, deviation from N·6.02 dB per octave", abs(slope - Double(order) * RollOff.decibelsPerOctavePerOrder), bound: 0.5)
            }
        }
    }

    @Test func aGainOfZeroDecibelsIsTheIdentityAtEveryOrder() throws {
        let frequencies = (0 ... 200).map { Double($0) * .pi / 200 }
        for order in [1, 2, 5, 8] {
            let design = try EqualizerDesign.bandBoost(center: 3_000, gain: .decibels(0), bandwidth: .octaves(1), order: order, sampleRate: 48_000)
            #expect(try design.zeroPoleGain.frequencyResponse(at: frequencies).allSatisfy { ($0 - Complex.one).magnitude <= 1e-12 })
            #expect(try design.secondOrderSections.frequencyResponse(at: frequencies).allSatisfy { ($0 - Complex.one).magnitude <= 1e-12 })
        }
        // A gain given as a factor is the same gain.
        let linear = try EqualizerDesign.bandBoost(center: 3_000, gain: .linear(2), bandwidth: .octaves(1), order: 3, sampleRate: 48_000)
        expectClose(try linear.zeroPoleGain.magnitudeResponse(at: [2 * .pi * 3_000 / 48_000])[0], 2, .relative(1e-12))
    }

    // MARK: Negative paths

    @Test func aBandThatReachesFortyNineHundredthsOfTheSampleRateIsRejected() throws {
        func failure(_ centre: Double, _ bandwidth: Bandwidth, order: Int = 2) -> DSPError? {
            thrownError { _ = try EqualizerDesign.bandBoost(center: centre, gain: .decibels(6), bandwidth: bandwidth, order: order, sampleRate: Self.sampleRate) }
        }
        /// The value of a bandwidth parameter at which the upper half-gain frequency is exactly
        /// 0.49·fs, by bisection on the rule of §6.3.5.
        func limit(_ centre: Double, from low: Double, to high: Double, _ make: (Double) -> Bandwidth) -> Double {
            var low = low
            var high = high
            let widening = Self.upperEdge(make(high), centre: centre) > Self.upperEdge(make(low), centre: centre)
            for _ in 0 ..< 80 {
                let middle = (low + high) / 2
                if (Self.upperEdge(make(middle), centre: centre) >= 0.49) == widening { high = middle } else { low = middle }
            }
            return (low + high) / 2
        }
        for centre in [5_000.0, 12_000, 20_000, 0.45 * Self.sampleRate] {
            // In hertz and in octaves a larger number is a wider band; a larger Q is a narrower one.
            let hertz = limit(centre, from: 1, to: 23_999) { .hertz($0) }
            #expect(failure(centre, .hertz(hertz * 0.999)) == nil, "\(centre) Hz, \(hertz) Hz wide")
            let error = try #require(failure(centre, .hertz(hertz * 1.001)))
            #expect(error.invalidParameterName == "bandwidth")
            #expect(error.description.contains("0.49"), "the message names the limit: \(error)")

            let octaves = limit(centre, from: 0.01, to: 12) { .octaves($0) }
            if Self.width(.octaves(octaves * 1.001), centre: centre) < Self.sampleRate / 2 {
                #expect(failure(centre, .octaves(octaves * 0.999)) == nil)
                #expect(failure(centre, .octaves(octaves * 1.001))?.invalidParameterName == "bandwidth")
            }
            let quality = limit(centre, from: 0.001, to: 100) { .q($0) }
            #expect(failure(centre, .q(quality * 1.001)) == nil)
            #expect(failure(centre, .q(quality * 0.999))?.invalidParameterName == "bandwidth")
            // The rule is the same at every order.
            #expect(failure(centre, .hertz(hertz * 1.001), order: 1)?.invalidParameterName == "bandwidth")
            #expect(failure(centre, .hertz(hertz * 1.001), order: 8)?.invalidParameterName == "bandwidth")
        }
        // The rule decides, and nothing else: over the bandwidths of the grid at the top centre.
        for bandwidth in Self.bandwidths(at: 0.45 * Self.sampleRate) {
            let rejected = failure(0.45 * Self.sampleRate, bandwidth) != nil
            #expect(rejected == (Self.upperEdge(bandwidth, centre: 0.45 * Self.sampleRate) >= 0.49), "\(bandwidth)")
        }
    }

    @Test func invalidBandsAreTypedErrors() {
        func failure(center: Double = 1_000, gain: Amplification = .decibels(6), bandwidth: Bandwidth = .octaves(1), order: Int = 2,
                     sampleRate: Double = 48_000) -> DSPError? {
            thrownError { _ = try EqualizerDesign.bandBoost(center: center, gain: gain, bandwidth: bandwidth, order: order, sampleRate: sampleRate) }
        }
        #expect(failure() == nil)
        for bad in [0.0, -20, 24_000, 96_000, .nan, .infinity] { #expect(failure(center: bad)?.invalidParameterName == "center", "\(bad)") }
        for bad in [Amplification.linear(0), .linear(-1), .decibels(.nan), .decibels(.infinity)] { #expect(failure(gain: bad)?.invalidParameterName == "gain", "\(bad)") }
        for bad in [Bandwidth.hertz(0), .hertz(-10), .hertz(.nan), .hertz(24_000), .octaves(0), .octaves(-1), .octaves(.infinity), .q(0), .q(-2), .q(.nan)] {
            #expect(failure(bandwidth: bad)?.invalidParameterName == "bandwidth", "\(bad)")
        }
        for bad in [0, -1, 65] { #expect(failure(order: bad)?.invalidParameterName == "order", "\(bad)") }
        #expect(EqualizerDesign.maximumOrder == 64)
        #expect(failure(bandwidth: .hertz(100), order: 64) == nil)
        for bad in [0.0, -1, .nan, .infinity] { #expect(failure(sampleRate: bad)?.invalidParameterName == "sampleRate", "\(bad)") }
    }

    // MARK: Stability (NUMS-2, §7.5 row 20)

    /// The fourth-order sections of Orfanidis 2005, formed from their closed-form
    /// coefficients: the route the package does *not* take. For a narrow band at a low centre
    /// each section is a quartic in z⁻¹ whose four roots crowd z = 1, and evaluating it on the
    /// unit circle cancels most of the digits of its coefficients.
    private func closedFormResponse(centre: Double, gain: Double, width: Double, order: Int, sampleRate: Double, at frequencies: [Double]) -> [Complex] {
        let factor = pow(10, gain / 20)
        let g = pow(factor, 1 / Double(order))
        let beta = tan(.pi * width / sampleRate) / g.squareRoot()
        let cosine = cos(2 * .pi * centre / sampleRate)
        return frequencies.map { frequency in
            let delay = Complex(cos(frequency), -sin(frequency))
            var value = Complex.one
            for index in 1 ... order / 2 {
                let s = sin(Double(2 * index - 1) * .pi / Double(2 * order))
                let d = beta * beta + 2 * s * beta + 1
                let b = [(g * g * beta * beta + 2 * g * s * beta + 1) / d, -4 * cosine * (1 + g * s * beta) / d,
                         2 * (1 + 2 * cosine * cosine - g * g * beta * beta) / d, -4 * cosine * (1 - g * s * beta) / d,
                         (g * g * beta * beta - 2 * g * s * beta + 1) / d]
                let a = [1, -4 * cosine * (1 + s * beta) / d, 2 * (1 + 2 * cosine * cosine - beta * beta) / d,
                         -4 * cosine * (1 - s * beta) / d, (beta * beta - 2 * s * beta + 1) / d]
                var numerator = Complex.zero
                var denominator = Complex.zero
                for power in stride(from: 4, through: 0, by: -1) {
                    numerator = numerator * delay + b[power]
                    denominator = denominator * delay + a[power]
                }
                value = value * numerator / denominator
            }
            return value
        }
    }

    @Test func stressANarrowLowBandKeepsItsAccuracyInZeroPoleForm() throws {
        // Drawn from the fixture library: the low corner that stresses every cascade.
        let fixture = try #require(StressFixture.filtersNearZero.first { $0.name == "hp-20Hz-96k-order8" })
        let gain = 12.0
        let width = 2.0
        let centre = 2 * Double.pi * fixture.cutoff / fixture.sampleRate
        let frequencies = (0 ... 400).map { centre + (Double($0) - 200) / 200 * 4 * .pi * width / fixture.sampleRate } + [centre]

        let boost = try EqualizerDesign.bandBoost(center: fixture.cutoff, gain: .decibels(gain), bandwidth: .hertz(width), order: fixture.order, sampleRate: fixture.sampleRate)
        let cut = try EqualizerDesign.bandBoost(center: fixture.cutoff, gain: .decibels(-gain), bandwidth: .hertz(width), order: fixture.order, sampleRate: fixture.sampleRate)

        // In zero-pole form: properties 1 and 6 hold, with room.
        let centreError = abs(try boost.zeroPoleGain.magnitudeResponse(at: [centre], in: .decibels)[0] - gain)
        let identity = zip(try boost.zeroPoleGain.frequencyResponse(at: frequencies), try cut.zeroPoleGain.frequencyResponse(at: frequencies))
            .map { ($0 * $1 - Complex.one).magnitude }.max() ?? 0
        Measurements.shared.record("WP-421 stress 20 Hz / 96 kHz / order 8 / 2 Hz: centre gain error in zero-pole form, dB", centreError, bound: 0.01)
        Measurements.shared.record("WP-421 stress 20 Hz / 96 kHz / order 8 / 2 Hz: magnitude of boost·cut − 1 in zero-pole form", identity, bound: 1e-6)
        #expect(centreError <= 0.01)
        #expect(identity <= 1e-6)

        // The biquads that run are formed from pairs of those roots and agree with them.
        let sectionsError = abs(try boost.secondOrderSections.magnitudeResponse(at: [centre], in: .decibels)[0] - gain)
        Measurements.shared.record("WP-421 stress 20 Hz / 96 kHz / order 8 / 2 Hz: centre gain error of the paired biquads, dB", sectionsError, bound: 0.01)
        #expect(sectionsError <= 0.01)
        #expect(try boost.secondOrderSections.isStable)

        // The hazard: the same band through closed-form fourth-order sections.
        let naiveBoost = closedFormResponse(centre: fixture.cutoff, gain: gain, width: width, order: fixture.order, sampleRate: fixture.sampleRate, at: frequencies)
        let naiveCut = closedFormResponse(centre: fixture.cutoff, gain: -gain, width: width, order: fixture.order, sampleRate: fixture.sampleRate, at: frequencies)
        let naiveCentre = abs(20 * log10(naiveBoost[naiveBoost.count - 1].magnitude) - gain)
        let naiveIdentity = zip(naiveBoost, naiveCut).map { ($0 * $1 - Complex.one).magnitude }.max() ?? 0
        Measurements.shared.record("WP-421 stress 20 Hz / 96 kHz / order 8 / 2 Hz: centre gain error of closed-form quartics, dB (hazard)", naiveCentre, bound: 0.01)
        Measurements.shared.record("WP-421 stress 20 Hz / 96 kHz / order 8 / 2 Hz: magnitude of boost·cut − 1 with closed-form quartics (hazard)", naiveIdentity, bound: 1e-6)
        #expect(naiveIdentity > 1e-6, "closed-form fourth-order sections miss the identity by \(naiveIdentity)")
        #expect(naiveIdentity > 1_000 * identity)
    }
}
