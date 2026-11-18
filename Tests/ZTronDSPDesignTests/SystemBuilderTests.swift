import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// The response of a list of sections at one frequency, by the definition.
private func cascadeResponse(_ sections: SecondOrderSections, at omega: Double) -> Complex {
    let delay = Complex(magnitude: 1, phase: -omega)
    var value = Complex.one
    for section in sections.sections {
        value = value * ((section.b2 * delay + section.b1) * delay + section.b0) / ((section.a2 * delay + section.a1) * delay + 1)
    }
    return value
}

/// WP-431c. `IIRSystem { }`: `Pole`, `Zero`, `Section`, `DifferenceEquation`, the IIR design
/// values. Acceptance: builder fixtures; conjugates completed; an element with a non-default
/// `isActive` is rejected (ACT-1).
@Suite("IIRSystem (WP-431c)")
struct IIRSystemTests {
    let rate = 48_000.0

    /// The system of §6.3.7.
    private var hum: IIRSystem {
        IIRSystem {
            Zero(onUnitCircleAt: .hertz(50))                       // the conjugate is added automatically
            Pole(radius: 0.985, frequency: .hertz(50))
            HighPass(.butterworth, cutoff: .hertz(30), rollOff: .decibelsPerOctave(12))
            Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
        }
    }

    @Test func theSystemOfTheSpecificationIsTheProductOfItsElements() throws {
        let system = try hum.zeroPoleGain(sampleRate: rate)
        #expect(hum.elementCount == 4 && system.domain == .digital)
        // Two zeros on the unit circle, two poles inside, the two poles and zeros of the
        // high-pass, the two of the section.
        #expect(system.zeros.count == 6 && system.poles.count == 6)
        let angle = 2 * Double.pi * 50 / rate
        let notch = [Complex(magnitude: 1, phase: angle), Complex(magnitude: 1, phase: -angle)]
        let resonance = [Complex(magnitude: 0.985, phase: angle), Complex(magnitude: 0.985, phase: -angle)]
        let highPass = try IIRDesign(.butterworth, .highPass(cutoff: 30), order: 2, domain: .digital(sampleRate: rate)).zeroPoleGain
        let sectionZeros = QuadraticRoots.roots(1, -1.9, 0.92), sectionPoles = QuadraticRoots.roots(1, -1.85, 0.87)
        expectRootsClose(system.zeros, notch + highPass.zeros + sectionZeros, relative: 1e-12, "zeros")
        expectRootsClose(system.poles, resonance + highPass.poles + sectionPoles, relative: 1e-12, "poles")
        expectClose(system.gain, highPass.gain, .relative(1e-15), "the gains of the elements multiply")
        // The response is the product of the responses of the elements.
        for hertz in [10.0, 49, 50, 51, 300, 12_000] {
            let omega = 2 * Double.pi * hertz / rate
            let z = Complex(magnitude: 1, phase: omega)
            let filtered = try highPass.frequencyResponse(at: [omega])[0]
            let expected = (z - notch[0]) * (z - notch[1]) / ((z - resonance[0]) * (z - resonance[1])) * filtered
                * (z * z - 1.9 * z + 0.92) / (z * z - 1.85 * z + 0.87)
            let actual = try system.frequencyResponse(at: [omega])[0]
            #expect((actual - expected).magnitude <= 1e-10 * max(expected.magnitude, 1e-3), "\(hertz) Hz: \(actual) against \(expected)")
        }
        // It runs as three sections, the notch's zeros paired with the poles beside them.
        let sections = try hum.secondOrderSections(sampleRate: rate)
        #expect(sections.sections.count == 3)
        for hertz in [10.0, 49, 51, 300, 12_000] {
            let omega = 2 * Double.pi * hertz / rate
            let expected = try system.frequencyResponse(at: [omega])[0]
            #expect((cascadeResponse(sections, at: omega) - expected).magnitude <= 1e-9 * expected.magnitude, "\(hertz) Hz")
        }
        let paired = sections.sections.contains { section in
            // 1 − 2·cos θ·z⁻¹ + z⁻² over 1 − 2·0.985·cos θ·z⁻¹ + 0.985²·z⁻², up to the section's gain.
            abs(section.b2 / section.b0 - 1) < 1e-9 && abs(section.a2 - 0.985 * 0.985) < 1e-12 && abs(section.a1 + 2 * 0.985 * cos(angle)) < 1e-12
        }
        #expect(paired, "the zero pair and the pole pair at 50 Hz share a section: \(sections.sections)")
    }

    @Test func conjugatesAreCompletedAndRealRootsStandAlone() throws {
        func roots(_ element: some IIRSystemElement) throws -> ZeroPoleGain { try element.zeroPoleGain(sampleRate: rate) }
        // A frequency strictly between 0 Hz and Nyquist: the pair.
        let pair = try roots(Zero(onUnitCircleAt: .hertz(12_000)))
        expectRootsClose(pair.zeros, [Complex(0, 1), Complex(0, -1)], relative: 1e-15, "a quarter of the rate is ±j")
        #expect(pair.poles == [.zero, .zero] && pair.gain == 1, "a zero is a factor in z⁻¹: as many poles at the origin")
        // 0 Hz and the Nyquist frequency: one real root.
        #expect(try roots(Zero(onUnitCircleAt: .hertz(0))).zeros == [Complex(1)])
        #expect(try roots(Zero(onUnitCircleAt: .hertz(24_000))).zeros == [Complex(-1)])
        #expect(try roots(Zero(radius: 0.5, frequency: .fractionOfNyquist(1))).zeros == [Complex(-0.5)])
        #expect(try roots(Pole(radius: 0.9, frequency: .hertz(0))).poles == [Complex(0.9)])
        // A point of the plane: with its conjugate when it is not real.
        #expect(try roots(Zero(at: Complex(0.5, 0.25))).zeros == [Complex(0.5, 0.25), Complex(0.5, -0.25)])
        #expect(try roots(Zero(at: Complex(0.5, -0.25))).zeros == [Complex(0.5, -0.25), Complex(0.5, 0.25)])
        #expect(try roots(Zero(at: Complex(-0.75))).zeros == [Complex(-0.75)])
        let pole = try roots(Pole(at: Complex(0.3, 0.4)))
        #expect(pole.poles == [Complex(0.3, 0.4), Complex(0.3, -0.4)] && pole.zeros == [.zero, .zero])
        expectRootsClose(try roots(Pole(radius: 0.985, frequency: .hertz(50))).poles,
                         [Complex(magnitude: 0.985, phase: 2 * .pi * 50 / rate), Complex(magnitude: 0.985, phase: -2 * .pi * 50 / rate)], relative: 1e-15, "the pole pair")
        // A system of such elements has real coefficients: it pairs into sections.
        let system = IIRSystem { Zero(at: Complex(0.5, 0.25)); Pole(at: Complex(0.3, 0.4)); Zero(onUnitCircleAt: .hertz(0)); Pole(radius: 0.5, frequency: .hertz(24_000)) }
        let sections = try system.secondOrderSections(sampleRate: rate)
        #expect(sections.sections.count == 2)
        expectClose(sections.sections.flatMap(\.coefficients).sorted(), [1.0, -1, 0.3125, 0, 1, -1, 0, 0.5, -0.6, 0.25].sorted(), .absolute(1e-12))
        // Values that are no root.
        #expect(thrownError { _ = try roots(Zero(onUnitCircleAt: .hertz(30_000))) }?.invalidParameterName == "frequency")
        #expect(thrownError { _ = try roots(Pole(radius: -1, frequency: .hertz(50))) }?.invalidParameterName == "radius")
        #expect(thrownError { _ = try roots(Pole(at: Complex(.nan, 0))) }?.invalidParameterName == "pole")
        #expect(thrownError { _ = try roots(Zero(at: Complex(0, .infinity))) }?.invalidParameterName == "zero")
        #expect(thrownError { _ = try Zero(onUnitCircleAt: .hertz(50)).zeroPoleGain(sampleRate: -1) }?.invalidParameterName == "sampleRate")
    }

    @Test func sectionsAndDifferenceEquationsAreReadAsTheyAreWritten() throws {
        // A section: closed form, a0 normalised.
        let section = try Section(b: [2, -3.8, 1.84], a: [2, -3.7, 1.74]).zeroPoleGain(sampleRate: rate)
        expectRootsClose(section.zeros, QuadraticRoots.roots(1, -1.9, 0.92), relative: 1e-14, "zeros")
        expectRootsClose(section.poles, QuadraticRoots.roots(1, -1.85, 0.87), relative: 1e-14, "poles")
        #expect(section.gain == 1)
        // Shorter lists: a first-order section, a gain.
        let first = try Section(b: [1, -0.5], a: [1, -0.9]).zeroPoleGain(sampleRate: rate)
        #expect(first.zeros == [Complex(0.5)] && first.poles == [Complex(0.9)])
        #expect(try Section(b: [0.25]).zeroPoleGain(sampleRate: rate) == ZeroPoleGain(zeros: [], poles: [], gain: 0.25, domain: .digital))
        #expect(thrownError { _ = try Section(b: [1, 2, 3, 4], a: [1]).zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "b")
        #expect(thrownError { _ = try Section(b: [1], a: []).zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "a")
        #expect(thrownError { _ = try Section(b: [1], a: [0, 1]).zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "a")
        #expect(thrownError { _ = try Section(b: [.nan], a: [1]).zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "b")
        // A difference equation of any length: its roots are found.
        // 2·y[n] = 0.5·x[n] − 0.5·x[n − 2] + 1.8·y[n − 1] − 1.62·y[n − 2] + 1.458·y[n − 3]: poles at 0.9 and ±0.9j.
        let equation = DifferenceEquation(b: [0.5, 0, -0.5], a: [2, -1.8, 1.62, -1.458])
        let found = try equation.zeroPoleGain(sampleRate: rate)
        expectRootsClose(found.zeros, [Complex(1), Complex(-1), Complex.zero], relative: 1e-12, "zeros of 0.25·(1 − z⁻²), and the one that pads")
        expectRootsClose(found.poles, [Complex(0.9), Complex(0, 0.9), Complex(0, -0.9)], relative: 1e-12, "poles")
        expectClose(found.gain, 0.25, .relative(1e-15), "a0 is normalised")
        // In a system it runs as the recurrence it states.
        let noise = TestSignal.whiteNoise(count: 512, seed: 3)
        var reference = [Double](repeating: 0, count: noise.count)
        for n in noise.indices {
            let x = { (k: Int) in n - k >= 0 ? Double(noise[n - k]) : 0 }, y = { (k: Int) in n - k >= 0 ? reference[n - k] : 0 }
            reference[n] = (0.5 * x(0) - 0.5 * x(2) + 1.8 * y(1) - 1.62 * y(2) + 1.458 * y(3)) / 2
        }
        let output = try Pipeline { Filter(IIRSystem { equation }) }.environment(\.biquadPrecision, .double).process(noise, format: SignalFormat(sampleRate: rate))
        expectClose(output, reference, .deviationBelow(decibels: -120))
        #expect(thrownError { _ = try DifferenceEquation(b: [], a: [1]).zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "b")
        #expect(thrownError { _ = try DifferenceEquation(b: [1], a: [0, 1]).zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "a")
        #expect(try DifferenceEquation(b: [0, 0], a: [1, -0.5]).zeroPoleGain(sampleRate: rate).gain == 0)
    }

    @Test func aDelayWrittenIntoASystemIsKept() throws {
        // A pole in excess of the zeros is a sample of delay; the cascade carries it as numerator
        // coefficients that start with zeros.
        let format = SignalFormat(sampleRate: rate)
        let impulse = TestSignal.impulse(count: 8)
        func response(_ system: IIRSystem) throws -> [Float] { try Pipeline { Filter(system) }.process(impulse, format: format) }
        #expect(try response(IIRSystem { Section(b: [0, 1]) }) == [0, 1, 0, 0, 0, 0, 0, 0])
        #expect(try response(IIRSystem { DifferenceEquation(b: [0, 0, 0.5]) }) == [0, 0, 0.5, 0, 0, 0, 0, 0])
        #expect(try response(IIRSystem { Section(b: [0, 1]); Section(b: [0, 0, 2]); Section(b: [1, 1]) }) == [0, 0, 0, 2, 2, 0, 0, 0])
        let delayed = try response(IIRSystem { Section(b: [0, 0.5, 0.25], a: [1, -0.5]) })
        expectClose(delayed, [0, 0.5, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625] as [Float], .absolute(1e-7))
        // A pole and a zero as elements bring no delay: each is a factor in z⁻¹.
        expectClose(try response(IIRSystem { Pole(at: Complex(0.5)) }), [1, 0.5, 0.25, 0.125, 0.0625, 0.03125, 0.015625, 0.0078125] as [Float], .absolute(1e-7))
        #expect(try response(IIRSystem { Zero(at: Complex(0.5)) }) == [1, -0.5, 0, 0, 0, 0, 0, 0])
        // Zeros alone, written in the `z` plane, are made causal.
        let improper = ZeroPoleGain(zeros: [Complex(0.5)], poles: [], gain: 2, domain: .digital)
        #expect(try response(IIRSystem { improper }) == [2, -1, 0, 0, 0, 0, 0, 0])
        // What the system reports about itself agrees with what runs.
        let system = IIRSystem { Section(b: [0, 0.5, 0.25], a: [1, -0.5]) }
        let reported = try system.zeroPoleGain(sampleRate: rate)
        #expect(reported.zeros == [Complex(-0.5)] && reported.poles.count == 2)
        let delay = try system.groupDelay(at: [0])[0]
        expectClose(try #require(delay), 1 + 0.25 / 0.75 + 0.5 / 0.5, .absolute(1e-12), "one sample of delay, plus the zero's and the pole's")
    }

    @Test func theBuilderTakesControlFlow() throws {
        func system(notch: Bool, shelves: Int, family: Int) -> IIRSystem {
            IIRSystem {
                if notch { Zero(onUnitCircleAt: .hertz(50)) }
                for index in 0 ..< shelves { LowShelf(midpoint: .hertz(100 * Double(index + 1)), gain: .decibels(1)) }
                if family == 0 {
                    LowPass(.butterworth, cutoff: .hertz(8_000), order: 2)
                } else {
                    LowPass(.chebyshev1(ripple: .decibels(1)), cutoff: .hertz(8_000), order: 2)
                }
                switch family {
                case 0: Pole(radius: 0.5, frequency: .hertz(0))
                case 1: Pole(radius: 0.6, frequency: .hertz(0))
                default: Pole(radius: 0.7, frequency: .hertz(0))
                }
                if #available(iOS 15, *) { Section(b: [1, 0.5]) }
            }
        }
        #expect(system(notch: true, shelves: 3, family: 0).elementCount == 7)
        #expect(system(notch: false, shelves: 0, family: 2).elementCount == 3)
        #expect(system(notch: true, shelves: 1, family: 1) == system(notch: true, shelves: 1, family: 1))
        #expect(system(notch: true, shelves: 1, family: 1) != system(notch: true, shelves: 1, family: 2))
        #expect(IIRSystem {}.elementCount == 0)
        // No elements: the identity. It has no sections and runs as nothing at all.
        #expect(try IIRSystem {}.zeroPoleGain(sampleRate: rate) == ZeroPoleGain(zeros: [], poles: [], gain: 1, domain: .digital))
        #expect(try IIRSystem {}.secondOrderSections(sampleRate: rate).sections.isEmpty)
        // Every equaliser and both representations are elements; systems nest.
        let design = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 3, domain: .digital(sampleRate: rate))
        let nested = IIRSystem {
            BandBoost(center: .hertz(1_000), gain: .decibels(3), bandwidth: .octaves(1), order: 2)
            HighShelf(midpoint: .hertz(8_000), gain: .decibels(-2))
            MatchedPeak(center: .hertz(15_000), gain: .decibels(2), bandwidth: .q(2))
            design.zeroPoleGain
            try! design.secondOrderSections
            IIRSystem { Zero(onUnitCircleAt: .hertz(50)); Pole(radius: 0.9, frequency: .hertz(50)) }
        }
        #expect(try nested.zeroPoleGain(sampleRate: rate).poles.count == 4 + 2 + 2 + 3 + 3 + 2)
    }

    @Test func anElementWithASwitchOfItsOwnIsRejected() throws {
        // ACT-1: a system is switched whole, through Filter(_:isActive:).
        let on = StateBox(true)
        let constant = IIRSystem { Zero(onUnitCircleAt: .hertz(50)); LowPass(.butterworth, cutoff: .hertz(1_000), order: 2, isActive: false) }
        let error = thrownError { _ = try constant.zeroPoleGain(sampleRate: rate) }
        #expect(error?.invalidParameterName == "isActive")
        #expect(error?.invalidParameterReason?.contains("element 1") == true && error?.invalidParameterReason?.contains("Filter(_:isActive:)") == true)
        let bound = IIRSystem { BandBoost(center: .hertz(1_000), gain: .decibels(3), bandwidth: .octaves(1), isActive: on.binding) }
        #expect(thrownError { _ = try bound.secondOrderSections(sampleRate: rate) }?.invalidParameterName == "isActive")
        // Rejected when the plan is compiled, with the path of the stage that holds the system.
        let attached = thrownError { _ = try Pipeline { Filter(constant) }.process(TestSignal.silence(count: 64), format: SignalFormat(sampleRate: rate)) }
        #expect(attached?.invalidParameterName == "isActive" && attached?.stage?.description == "Filter[0]")
        // The default, `true` and `.active` are the default.
        let fine = IIRSystem { LowPass(.butterworth, cutoff: .hertz(1_000), order: 2, isActive: true); HighShelf(midpoint: .hertz(4_000), gain: .decibels(1), isActive: .active) }
        #expect(try fine.zeroPoleGain(sampleRate: rate).poles.count == 4)
    }

    @Test func aSystemIsAnLTISystemOnItsOwnOnlyWhenItNeedsNoSampleRate() throws {
        // Coefficients, roots, and frequencies per sample are fixed in the z plane.
        let fixed = IIRSystem {
            Zero(onUnitCircleAt: .normalized(0.25))
            Pole(radius: 0.9, frequency: .radiansPerSample(.pi / 2))
            Section(b: [1, 0.5], a: [1, -0.5])
            LowPass(.butterworth, cutoff: .fractionOfNyquist(0.5), order: 2)
        }
        #expect(!fixed.dependsOnSampleRate && fixed.domain == .digital)
        let zeros = try fixed.zeros, poles = try fixed.poles, isStable = try fixed.isStable, isMinimumPhase = try fixed.isMinimumPhase
        #expect(zeros.count == 5 && poles.count == 5 && isStable && isMinimumPhase)
        expectClose(try fixed.stabilityMargin, 0.1, .absolute(1e-12))
        // The same at every rate.
        let slow = try fixed.zeroPoleGain(sampleRate: 44_100), fast = try fixed.zeroPoleGain(sampleRate: 192_000)
        #expect(slow == fast)
        expectClose(try fixed.magnitudeResponse(at: [.pi / 2])[0], 0, .absolute(1e-12), "the zero on the unit circle")
        // A frequency in hertz makes the system a system only at a rate.
        #expect(hum.dependsOnSampleRate)
        let error = thrownError { _ = try hum.zeros }
        #expect(error?.invalidParameterName == "sampleRate" && error?.invalidParameterReason?.contains("analysis(sampleRate:)") == true)
        #expect(thrownError { _ = try hum.frequencyResponse(at: [0]) }?.invalidParameterName == "sampleRate")
        #expect(thrownError { _ = try hum.isStable }?.invalidParameterName == "sampleRate")
        #expect(thrownError { _ = try hum.zeroPoleGain(sampleRate: 0) }?.invalidParameterName == "sampleRate")
        #expect(IIRSystem { Zero(onUnitCircleAt: .midiNote(69)) }.dependsOnSampleRate && !IIRSystem { Zero(at: Complex(0.5)) }.dependsOnSampleRate)
        // An element of the caller's own is taken to depend on the rate unless it says otherwise.
        #expect(IIRSystem { OneZeroAtMinusOne() }.dependsOnSampleRate)
        #expect(try IIRSystem { OneZeroAtMinusOne() }.zeroPoleGain(sampleRate: rate).zeros == [Complex(-1)])
    }

    private struct OneZeroAtMinusOne: IIRSystemElement {
        func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
            ZeroPoleGain(zeros: [Complex(-1)], poles: [.zero], gain: 0.5, domain: .digital)
        }
    }

    @Test func whatIsNoElementOfAnIIRSystemIsReportedWithTheElementNamed() throws {
        // An FIR form, an analog representation, a frequency beyond Nyquist: typed errors that say where.
        let withFIR = IIRSystem { Zero(onUnitCircleAt: .hertz(50)); LowPass(.windowedSinc(), cutoff: .hertz(1_000), length: 31) }
        let error = thrownError { _ = try withFIR.zeroPoleGain(sampleRate: rate) }
        #expect(error?.invalidParameterName == "method" && error?.invalidParameterReason?.contains("element 1 of the system (LowPass)") == true)
        let analog = try IIRDesign(.butterworth, .lowPass(cutoff: 1_000), order: 2, domain: .analog).zeroPoleGain
        #expect(thrownError { _ = try IIRSystem { analog }.zeroPoleGain(sampleRate: rate) }?.invalidParameterReason?.contains("bilinear") == true)
        #expect(thrownError { _ = try IIRSystem { SecondOrderSections(sections: [.identity], domain: .analog) }.zeroPoleGain(sampleRate: rate) }?.invalidParameterName == "system")
        let beyond = thrownError { _ = try hum.zeroPoleGain(sampleRate: 80) }
        #expect(beyond?.invalidParameterName == "frequency" && beyond?.invalidParameterReason?.contains("element 0") == true)
        // A system whose roots are not closed under conjugation is described, and cannot be paired.
        let lone = IIRSystem { ZeroPoleGain(zeros: [.zero], poles: [Complex(0.5, 0.5)], gain: 1, domain: .digital) }
        #expect(try lone.zeroPoleGain(sampleRate: rate).poles == [Complex(0.5, 0.5)])
        #expect(thrownError { _ = try lone.secondOrderSections(sampleRate: rate) }?.invalidParameterName == "poles")
    }

    @Test func theContinuousValuesOfTheElementsAreTheSystems() throws {
        // ANI-2: the frequencies of the elements, in order; coefficients and radii are structure.
        let system = IIRSystem {
            Zero(onUnitCircleAt: .hertz(64))
            Pole(radius: 0.985, frequency: .hertz(64))
            Zero(at: Complex(0.5))
            HighPass(.butterworth, cutoff: .hertz(32), order: 2)
            Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
            BandBoost(center: .hertz(1_024), gain: .decibels(3), bandwidth: .octaves(1))
        }
        #expect(system.parameters == [6, 6, 5, 10, 3, 1])
        #expect(system.replacingParameters(system.parameters[...]) == system)
        let moved = system.replacingParameters([7, 7, 6, 11, -3, 2][...])
        #expect(moved == IIRSystem {
            Zero(onUnitCircleAt: .hertz(128))
            Pole(radius: 0.985, frequency: .hertz(128))
            Zero(at: Complex(0.5))
            HighPass(.butterworth, cutoff: .hertz(64), order: 2)
            Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
            BandBoost(center: .hertz(2_048), gain: .decibels(-3), bandwidth: .octaves(2))
        })
        #expect(system.replacingParameters([1][...]) == system, "a vector of another length changes nothing")
        // Through the stage that runs it.
        #expect(Filter(system).parameters == system.parameters)
        #expect(Filter(system).replacingParameters([7, 7, 6, 11, -3, 2][...]) == Filter(moved))
        #expect(Pipeline().filter(system) == Pipeline { Filter(system) } && Pipeline().filter(system, isActive: false) != Pipeline { Filter(system) })
    }
}

/// WP-431d. `FIRSystem { }`: `Taps`, `Zero`, `LeastSquares`, the FIR design values.
/// Acceptance: builder fixtures; a pole away from the origin is rejected.
@Suite("FIRSystem (WP-431d)")
struct FIRSystemTests {
    let rate = 48_000.0

    /// The system of §6.3.7.
    private var antiAlias: FIRSystem {
        FIRSystem {
            LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
            Taps([0.25, 0.5, 0.25])
        }
    }

    @Test func theSystemOfTheSpecificationIsTheConvolutionOfItsElements() throws {
        let taps = try antiAlias.taps(sampleRate: rate)
        let lowPass = try FIRDesign(.windowedSinc(), .lowPass(cutoff: 4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80), sampleRate: rate).taps
        #expect(antiAlias.elementCount == 2 && taps.count == lowPass.count + 2)
        var expected = [Double](repeating: 0, count: taps.count)
        for (index, tap) in lowPass.enumerated() {
            expected[index] += 0.25 * tap
            expected[index + 1] += 0.5 * tap
            expected[index + 2] += 0.25 * tap
        }
        expectClose(taps, expected, .absolute(1e-15))
        // Two symmetric filters in series are symmetric: linear phase, a delay of (K − 1) / 2.
        #expect(FIRMath.isLinearPhase(taps) && FIRMath.latency(of: taps) == (taps.count - 1) / 2)
        // The response is the product of the responses.
        for hertz in [0.0, 1_000, 4_000, 8_000, 20_000] {
            let omega = 2 * Double.pi * hertz / rate
            let product = FIRMath.response(of: lowPass, at: omega) * FIRMath.response(of: [0.25, 0.5, 0.25], at: omega)
            #expect((FIRMath.response(of: taps, at: omega) - product).magnitude < 1e-13)
        }
    }

    @Test func eachElementGivesTheTapsItStates() throws {
        func taps(_ element: some FIRSystemElement) throws -> [Double] { try FIRSystem { element }.taps(sampleRate: rate) }
        #expect(try taps(Taps([1, -2, 3])) == [1, -2, 3])
        // A zero: 1 − z₀·z⁻¹, or the pair's 1 − 2·Re z₀·z⁻¹ + |z₀|²·z⁻².
        #expect(try taps(Zero(at: Complex(0.5))) == [1, -0.5])
        #expect(try taps(Zero(onUnitCircleAt: .hertz(24_000))) == [1, 1])
        expectClose(try taps(Zero(onUnitCircleAt: .hertz(12_000))), [1.0, 0, 1], .absolute(1e-15))
        expectClose(try taps(Zero(radius: 0.5, frequency: .hertz(8_000))), [1.0, -0.5, 0.25], .absolute(1e-15), "1 − 2·r·cos(π/3)·z⁻¹ + r²·z⁻²")
        // The FIR forms of the response stages.
        #expect(try taps(HighPass(.windowedSinc(window: .hann), cutoff: .hertz(4_000), length: 31))
            == FIRDesign(.windowedSinc(window: .hann), .highPass(cutoff: 4_000), length: 31, sampleRate: rate).taps)
        #expect(try taps(BandStop(.leastSquares, from: .hertz(3_000), to: .hertz(9_000), transition: .hertz(1_200), length: 31))
            == FIRDesign(.leastSquares, .bandStop(from: 3_000, to: 9_000), length: 31, transition: 1_200, sampleRate: rate).taps)
        // What has no pole away from the origin is an FIR element too.
        #expect(try taps(Pole(at: .zero)) == [0, 1], "a pole at the origin is a delay of one sample")
        #expect(try taps(Section(b: [2, 4, 6], a: [2])) == [1, 2, 3])
        #expect(try taps(DifferenceEquation(b: [0, 0, 0.5])) == [0, 0, 0.5])
        // Systems nest; no elements is the identity.
        #expect(try taps(FIRSystem { Taps([1, 1]); Taps([1, -1]) }) == [1, 0, -1])
        #expect(try FIRSystem {}.taps(sampleRate: rate) == [1])
        // Taps that are no filter.
        #expect(thrownError { _ = try taps(Taps([])) }?.invalidParameterName == "taps")
        #expect(thrownError { _ = try taps(Taps([1, .nan])) }?.invalidParameterName == "taps")
        #expect(thrownError { _ = try FIRSystem { Taps([1]) }.taps(sampleRate: .infinity) }?.invalidParameterName == "sampleRate")
    }

    @Test func theLeastSquaresElementIsTheGeneralFit() throws {
        // Golden: scipy.signal.firls with the same bands, gains and weights.
        let file = try Golden.firDesign.get()
        for name in ["firls-gap-wide", "firls-gap-weighted"] {
            let golden = try file.require(name)
            let element = LeastSquares(length: try golden.integer("length"), bands: try golden.numbers("bands").map { .hertz($0) },
                                       desired: try golden.numbers("desired"), weights: try golden.numbers("weights"))
            let taps = try FIRSystem { element }.taps(sampleRate: try golden.number("sample_rate"))
            expectClose(taps, try golden.real("taps"), .absolute(1e-9), name)
        }
        // Without weights every band counts alike.
        let plain = LeastSquares(length: 31, bands: [.hertz(0), .hertz(4_000), .hertz(6_000), .hertz(24_000)], desired: [1, 1, 0, 0])
        #expect(try plain.taps(sampleRate: rate) == LeastSquares(length: 31, bands: plain.bands, desired: plain.desired, weights: [1, 1]).taps(sampleRate: rate))
        // The bands follow the rate when their unit does.
        let relative = LeastSquares(length: 31, bands: [.fractionOfNyquist(0), .fractionOfNyquist(0.25), .fractionOfNyquist(0.5), .fractionOfNyquist(1)], desired: [1, 1, 0, 0])
        #expect(!relative.dependsOnSampleRate && plain.dependsOnSampleRate)
        #expect(try relative.taps(sampleRate: 44_100) == relative.taps(sampleRate: 96_000))
        #expect(relative.parameters.count == 4 && relative.replacingParameters(relative.parameters[...]) == relative)
        #expect(plain.replacingParameters([0, 11, 12, 14][...]).bands[1] == .hertz(2_048))
        func rejected(_ element: LeastSquares) -> String? { thrownError { _ = try element.taps(sampleRate: rate) }?.invalidParameterName }
        #expect(rejected(LeastSquares(length: 31, bands: [.hertz(0), .hertz(4_000), .hertz(6_000)], desired: [1, 1, 0])) == "bands")
        #expect(rejected(LeastSquares(length: 31, bands: [], desired: [])) == "bands")
        #expect(rejected(LeastSquares(length: 31, bands: [.hertz(0), .hertz(4_000)], desired: [1])) == "desired")
        #expect(rejected(LeastSquares(length: 31, bands: [.hertz(0), .hertz(4_000)], desired: [1, 1], weights: [1, 2])) == "weights")
        #expect(rejected(LeastSquares(length: 31, bands: [.hertz(0), .hertz(30_000)], desired: [1, 1])) == "bands")
        #expect(rejected(LeastSquares(length: 30, bands: [.hertz(0), .hertz(4_000)], desired: [1, 1])) == "length")
    }

    @Test func aPoleAwayFromTheOriginIsRejected() throws {
        // Whatever would place one: a pole, a recurrence on the output, an IIR design.
        func rejection(_ element: some FIRSystemElement) -> DSPError? { thrownError { _ = try FIRSystem { Taps([1, 1]); element }.taps(sampleRate: rate) } }
        let pole = rejection(Pole(radius: 0.9, frequency: .hertz(1_000)))
        #expect(pole?.invalidParameterName == "pole")
        #expect(pole?.invalidParameterReason?.contains("element 1 of the system (Pole)") == true && pole?.invalidParameterReason?.contains("no pole away from the origin") == true)
        #expect(rejection(Pole(at: Complex(0.1)))?.invalidParameterName == "pole")
        #expect(rejection(Section(b: [1, 0.5], a: [1, -0.5]))?.invalidParameterName == "a")
        #expect(rejection(DifferenceEquation(b: [1], a: [1, 0, 0.25]))?.invalidParameterName == "a")
        let design = rejection(LowPass(.butterworth, cutoff: .hertz(1_000), order: 4))
        #expect(design?.invalidParameterName == "family" && design?.invalidParameterReason?.contains("pole") == true)
        #expect(rejection(BandStop(.elliptic(ripple: .decibels(1), stopband: .decibels(40)), from: .hertz(300), to: .hertz(900), order: 2))?.invalidParameterName == "family")
        // Rejected when the plan is compiled, with the path of the stage that holds the system.
        let attached = thrownError {
            _ = try Pipeline { Filter(FIRSystem { Pole(radius: 0.9, frequency: .hertz(1_000)) }) }.process(TestSignal.silence(count: 64), format: SignalFormat(sampleRate: rate))
        }
        #expect(attached?.invalidParameterName == "pole" && attached?.stage?.description == "Filter[0]")
        // ACT-1 holds here as it does for an IIR system.
        let switched = thrownError { _ = try FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(1_000), length: 31, isActive: false) }.taps(sampleRate: rate) }
        #expect(switched?.invalidParameterName == "isActive")
    }

    @Test func theBuilderTakesControlFlow() throws {
        func system(smooth: Bool, repeats: Int, kind: Int) -> FIRSystem {
            FIRSystem {
                if smooth { Taps([0.5, 0.5]) }
                for _ in 0 ..< repeats { Zero(onUnitCircleAt: .hertz(12_000)) }
                if kind == 0 { Taps([1]) } else { Taps([1, 0]) }
                switch kind {
                case 0: Zero(at: Complex(0.5))
                default: Zero(at: Complex(-0.5))
                }
                if #available(iOS 15, *) { Pole(at: .zero) }
            }
        }
        #expect(system(smooth: true, repeats: 2, kind: 0).elementCount == 6)
        #expect(try system(smooth: false, repeats: 0, kind: 1).taps(sampleRate: rate) == [0, 1, 0.5, 0])
        #expect(system(smooth: true, repeats: 1, kind: 0) == system(smooth: true, repeats: 1, kind: 0))
        #expect(system(smooth: true, repeats: 1, kind: 0) != system(smooth: true, repeats: 2, kind: 0))
        // The continuous values of the elements are the system's.
        let animated = FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(1_024), length: 31); Zero(onUnitCircleAt: .hertz(8_192)); Taps([1, 1]) }
        #expect(animated.parameters == [10, 13])
        #expect(animated.replacingParameters([11, 12][...]) == FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(2_048), length: 31); Zero(onUnitCircleAt: .hertz(4_096)); Taps([1, 1]) })
        #expect(animated.replacingParameters(animated.parameters[...]) == animated && Filter(animated).parameters == [10, 13])
        #expect(Pipeline().filter(animated) == Pipeline { Filter(animated) })
    }

    @Test func aSystemThatNeedsNoSampleRateIsAnLTISystemOnItsOwn() throws {
        let system = FIRSystem { Taps([1, 0, -1]); Taps([0.5, 0.5]) }       // 0.5·(1 + z⁻¹ − z⁻² − z⁻³)
        #expect(!system.dependsOnSampleRate && system.domain == .digital)
        expectRootsClose(try system.zeros, [Complex(1), Complex(-1), Complex(-1)], relative: 1e-7, "zeros")
        let poles = try system.poles, gain = try system.gain, isStable = try system.isStable
        #expect(poles == [.zero, .zero, .zero] && gain == 0.5 && isStable)
        let isLinearPhase = try system.isLinearPhase, margin = try system.stabilityMargin
        #expect(isLinearPhase && margin == 1, "antisymmetric taps; every pole at the origin")
        // The response is the transform of the taps; no root is found for it.
        let response = try system.frequencyResponse(at: [0, .pi / 2, .pi])
        #expect(response[0].magnitude < 1e-15 && response[2].magnitude < 1e-15)
        expectClose(response[1].magnitude, 0.5 * 2 * 2.0.squareRoot(), .absolute(1e-12))
        // A linear-phase filter delays by (K − 1) / 2 at every frequency; on a zero of the unit
        // circle the delay is undefined.
        let delays = try system.groupDelay(at: [0, 0.3, 1, 2, .pi])
        #expect(delays[0] == nil && delays[4] == nil)
        for delay in delays[1 ... 3] { expectClose(try #require(delay), 1.5, .absolute(1e-12)) }
        // Taps that end in zeros, or begin with them: the delay is a pole at the origin without a zero.
        let delayed = FIRSystem { Taps([0, 0, 1, 0.5, 0]) }
        let delayedZeros = try delayed.zeros, delayedPoles = try delayed.poles
        #expect(delayedZeros == [Complex(-0.5)] && delayedPoles.count == 3)
        let skewed = FIRSystem { Taps([1, 0.5, 0.2]) }
        let skewedIsLinear = try skewed.isLinearPhase, skewedIsMinimum = try skewed.isMinimumPhase
        #expect(!skewedIsLinear && skewedIsMinimum)
        // A frequency in hertz makes the system a system only at a rate.
        let hertz = FIRSystem { LowPass(.windowedSinc(), cutoff: .hertz(1_000), length: 31) }
        #expect(hertz.dependsOnSampleRate)
        #expect(thrownError { _ = try hertz.zeros }?.invalidParameterName == "sampleRate")
        #expect(thrownError { _ = try hertz.frequencyResponse(at: [0]) }?.invalidParameterName == "sampleRate")
        // The root finder stops at degree 512 (§6.3.8): the zeros of a longer filter are not found; its response is.
        let long = FIRSystem { LowPass(.windowedSinc(), cutoff: .fractionOfNyquist(0.25), length: 601) }
        #expect(thrownError { _ = try long.zeros }?.isUnsupportedConfiguration == true)
        expectClose(try long.magnitudeResponse(at: [0])[0], 1.0, .absolute(1e-12))
        expectClose(try #require(try long.groupDelay(at: [0.1])[0]), 300.0, .absolute(1e-9))
    }
}
