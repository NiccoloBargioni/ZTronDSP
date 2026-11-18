import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-403: the three representations and the conversions between zeros-poles-gain and
/// coefficients. Acceptance: round trips.
@Suite("ZeroPoleGain, TransferFunction, SecondOrderSections (WP-403)")
struct RepresentationTests {
    private let digital = ZeroPoleGain(
        zeros: [Complex(-1), Complex(0.2, 0.9), Complex(0.2, -0.9)],
        poles: [Complex(0.5), Complex(0.3, 0.6), Complex(0.3, -0.6), Complex(-0.4)],
        gain: 0.75, domain: .digital)
    private let analog = ZeroPoleGain(
        zeros: [Complex(0, 3), Complex(0, -3)],
        poles: [Complex(-1, 2), Complex(-1, -2), Complex(-0.5)],
        gain: 2, domain: .analog)

    // MARK: Round trips

    @Test func zerosPolesGainToCoefficientsAndBack() throws {
        for system in [digital, analog] {
            let coefficients = try system.transferFunction()
            #expect(coefficients.domain == system.domain)
            #expect(coefficients.denominator.leadingCoefficient == 1, "the denominator is monic")
            #expect(coefficients.numerator.leadingCoefficient == system.gain)
            #expect(coefficients.numerator.degree == system.zeros.count)
            #expect(coefficients.denominator.degree == system.poles.count)

            let back = try coefficients.zeroPoleGain()
            #expect(back.domain == system.domain)
            expectRootsClose(back.zeros, system.zeros, relative: 1e-13, "zeros", measure: "WP-403 ZPK → TF → ZPK, relative root error")
            expectRootsClose(back.poles, system.poles, relative: 1e-13, "poles", measure: "WP-403 ZPK → TF → ZPK, relative root error")
            expectClose(back.gain, system.gain, .relative(1e-15))
        }
    }

    @Test func coefficientsToZerosPolesGainAndBack() throws {
        // (2x² + 3x − 1) / (x³ − 0.4x² + 0.3x + 0.1), digital, and an analog one.
        let systems = [
            TransferFunction(numerator: [2, 3, -1], denominator: [1, -0.4, 0.3, 0.1], domain: .digital),
            TransferFunction(numerator: [5], denominator: [2, 6, 11, 6], domain: .analog),
            TransferFunction(numerator: [1, 0, 0], denominator: [1, 1.4, 1], domain: .analog),
        ]
        for system in systems {
            let roots = try system.zeroPoleGain()
            let back = try roots.transferFunction()
            // The round trip normalises the denominator: compare the monic forms.
            let leading = system.denominator.leadingCoefficient
            expectClose(back.denominator.coefficients, system.denominator.coefficients.map { $0 / leading }, .absolute(1e-13))
            expectClose(back.numerator.coefficients, system.numerator.coefficients.map { $0 / leading }, .absolute(1e-13))
            Measurements.shared.record("WP-403 TF → ZPK → TF, absolute coefficient error",
                                       zip(back.denominator.coefficients, system.denominator.coefficients).map { abs($0 - $1 / leading) }.max() ?? 0, bound: 1e-13)
        }
    }

    @Test func zerosPolesGainToSectionsAndBack() throws {
        let sections = try digital.secondOrderSections()
        #expect(sections.domain == .digital)
        #expect(sections.sections.count == 2, "four poles make two sections")
        let back = sections.zeroPoleGain()
        // The pairing pads the three zeros with one at the origin to match the four poles.
        expectRootsClose(back.poles, digital.poles, relative: 1e-14, "poles", measure: "WP-403 ZPK → SOS → ZPK, relative root error")
        expectRootsClose(back.zeros, digital.zeros + [.zero], relative: 1e-14, "zeros", measure: "WP-403 ZPK → SOS → ZPK, relative root error")
        expectClose(back.gain, digital.gain, .relative(1e-15))
        #expect(sections.zeros == back.zeros)
        #expect(sections.poles == back.poles)
        #expect(sections.gain == back.gain)
    }

    @Test func theThreeFormsDescribeTheSameSystem() throws {
        let frequencies = (0 ..< 64).map { Double($0) * .pi / 64 }
        let fromRoots = try digital.frequencyResponse(at: frequencies)
        let fromCoefficients = try digital.transferFunction().frequencyResponse(at: frequencies)
        let fromSections = try digital.secondOrderSections().frequencyResponse(at: frequencies)
        expectResponseClose(fromCoefficients, fromRoots, relativeToPeak: 1e-13, "coefficients against roots")
        // A zero at the origin, added by the pairing, turns the response by e^{jω}: one sample of advance.
        let advanced = zip(fromRoots, frequencies).map { $0 * Complex(magnitude: 1, phase: $1) }
        expectResponseClose(fromSections, advanced, relativeToPeak: 1e-13, "sections against roots")

        let analogFrequencies = (0 ..< 64).map { 0.05 * pow(1.15, Double($0)) }
        expectResponseClose(try analog.transferFunction().frequencyResponse(at: analogFrequencies),
                            try analog.frequencyResponse(at: analogFrequencies), relativeToPeak: 1e-13, "analog coefficients against roots")
    }

    // MARK: ZeroPoleGain

    @Test func zeroPoleGainIsAValue() {
        #expect(digital.relativeDegree == 1)
        #expect(analog.relativeDegree == 1)
        #expect(ZeroPoleGain(zeros: [.zero, .one], poles: [], gain: 1, domain: .digital).relativeDegree == -2)
        #expect(digital.isFinite)
        #expect(!ZeroPoleGain(zeros: [], poles: [Complex(.nan, 0)], gain: 1, domain: .digital).isFinite)
        #expect(!ZeroPoleGain(zeros: [], poles: [], gain: .infinity, domain: .digital).isFinite)
        let copy = ZeroPoleGain(zeros: digital.zeros, poles: digital.poles, gain: digital.gain, domain: .digital)
        #expect(copy == digital)
        #expect(Set([copy, digital, analog]).count == 2)
        #expect(ZeroPoleGain(zeros: digital.zeros, poles: digital.poles, gain: digital.gain, domain: .analog) != digital, "the domain is part of the value")
        #expect(SystemDomain.analog.description == "analog" && SystemDomain.digital.description == "digital")
    }

    @Test func aSystemThatIsNotRealCannotBeExpanded() {
        let lonely = ZeroPoleGain(zeros: [], poles: [Complex(0.5, 0.5)], gain: 1, domain: .digital)
        #expect(thrownError { _ = try lonely.transferFunction() }?.invalidParameterName == "poles")
        #expect(thrownError { _ = try lonely.secondOrderSections() }?.invalidParameterName == "poles")
        let lonelyZero = ZeroPoleGain(zeros: [Complex(0, 1)], poles: [Complex(0.5)], gain: 1, domain: .digital)
        #expect(thrownError { _ = try lonelyZero.transferFunction() }?.invalidParameterName == "zeros")
        #expect(thrownError { _ = try lonelyZero.secondOrderSections() }?.invalidParameterName == "zeros")
        let infinite = ZeroPoleGain(zeros: [], poles: [Complex(0.5)], gain: .nan, domain: .digital)
        #expect(thrownError { _ = try infinite.transferFunction() }?.invalidParameterName == "gain")
        #expect(thrownError { _ = try infinite.secondOrderSections() }?.invalidParameterName == "gain")
        // Roots so large that the coefficients leave the range of a double.
        let huge = ZeroPoleGain(zeros: [], poles: [Complex](repeating: Complex(-1e80), count: 5), gain: 1, domain: .analog)
        #expect(thrownError { _ = try huge.transferFunction() }?.isUnsupportedConfiguration == true)
    }

    @Test func aGainOfZeroIsTheZeroNumerator() throws {
        let silent = ZeroPoleGain(zeros: [Complex(0.5)], poles: [Complex(0.25)], gain: 0, domain: .digital)
        let coefficients = try silent.transferFunction()
        #expect(coefficients.numerator.isZero)
        #expect(try coefficients.zeros.isEmpty)
        #expect(try coefficients.gain == 0)
        #expect(try coefficients.poles == [Complex(0.25)])
    }

    // MARK: TransferFunction

    @Test func transferFunctionReadsAsCoefficientsHighestPowerFirst() throws {
        let system = TransferFunction(numerator: [0, 0, 3], denominator: [2, 1, 0.5], domain: .analog)
        #expect(system.numerator == Polynomial([3]), "leading zeros are dropped")
        #expect(system.denominator.coefficients == [2, 1, 0.5])
        #expect(try system.gain == 1.5)
        #expect(try system.zeros.isEmpty)
        #expect(try system.poles.count == 2)
        #expect(TransferFunction(numerator: Polynomial([3]), denominator: Polynomial([2, 1, 0.5]), domain: .analog) == system)
        #expect(TransferFunction(numerator: [3], denominator: [2, 1, 0.5], domain: .digital) != system)
    }

    @Test func aDifferenceEquationIsPaddedAtItsEnd() throws {
        // y[n] = x[n] − 0.5·y[n−1]: H = 1 / (1 − (−0.5)z⁻¹)… written with a = [1, 0.5].
        let system = TransferFunction.differenceEquation(b: [1], a: [1, 0.5])
        #expect(system.domain == .digital)
        #expect(system.numerator.coefficients == [1, 0], "b gains a trailing zero: H = z / (z + 0.5)")
        #expect(system.denominator.coefficients == [1, 0.5])
        #expect(try system.zeros == [.zero])
        #expect(try system.poles == [Complex(-0.5)])
        // An FIR: the poles are at the origin.
        let fir = TransferFunction.differenceEquation(b: [0.25, 0.5, 0.25], a: [1])
        #expect(fir.denominator.coefficients == [1, 0, 0])
        #expect(try fir.poles == [.zero, .zero])
        expectRootsClose(try fir.zeros, [Complex(-1), Complex(-1)], relative: 1e-15, "the double zero at Nyquist")
        // Equal lengths are taken as they are.
        #expect(TransferFunction.differenceEquation(b: [1, 2], a: [3, 4]) == TransferFunction(numerator: [1, 2], denominator: [3, 4], domain: .digital))
    }

    @Test func theRootFinderIsPartOfTheValue() throws {
        struct Refusing: PolynomialRootFinder {
            func roots(of polynomial: Polynomial) throws(DSPError) -> [Complex] {
                throw .numericalFailure(routine: "refusing", info: polynomial.degree)
            }
        }
        let stock = TransferFunction(numerator: [1, 0.5, 0.25], denominator: [1, -3, 2], domain: .digital)
        let custom = TransferFunction(numerator: [1, 0.5, 0.25], denominator: [1, -3, 2], domain: .digital, rootFinder: Refusing())
        #expect(stock != custom)
        #expect(stock.rootFinder == AnyStrategy(CompanionQRRootFinder()))
        #expect(thrownError { _ = try custom.poles } == .numericalFailure(routine: "refusing", info: 2))
        #expect(thrownError { _ = try custom.zeroPoleGain() } == .numericalFailure(routine: "refusing", info: 2))
        #expect(thrownError { _ = try custom.isStable } == .numericalFailure(routine: "refusing", info: 2))
        // What does not need roots does not ask for them.
        #expect(try custom.gain == 1)
        #expect(try custom.frequencyResponse(at: [0]).count == 1)
        #expect(try custom.groupDelay(at: [0.5]).count == 1)
    }

    @Test func conditionNumbersOfZerosAndPolesAreReported() throws {
        let system = TransferFunction(numerator: [1, -3, 2], denominator: StressFixture.wilkinson20.coefficients, domain: .analog)
        #expect(try system.zeroConditions == [6, 6])
        let conditions = try system.poleConditions
        #expect(conditions.count == 20)
        #expect(try #require(conditions.max()) > 1e12, "Wilkinson's roots are flagged as ill-conditioned")
        #expect(try TransferFunction(numerator: [0], denominator: [1, 1], domain: .analog).zeroConditions.isEmpty)
    }

    @Test func aZeroDenominatorIsATypedError() {
        let broken = TransferFunction(numerator: [1, 2], denominator: [0, 0], domain: .digital)
        #expect(thrownError { _ = try broken.poles }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.zeros }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.gain }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.zeroPoleGain() }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.poleConditions }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.zeroConditions }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.frequencyResponse(at: [0.1]) }?.invalidParameterName == "denominator")
        #expect(thrownError { _ = try broken.groupDelay(at: [0.1]) }?.invalidParameterName == "denominator")
    }

    // MARK: SecondOrderSections

    @Test func aSectionIsFiveNumbersInTheKernelLayout() {
        let section = SecondOrderSections.Section(b0: 1, b1: 2, b2: 3, a1: 4, a2: 5)
        #expect(section.coefficients == [1, 2, 3, 4, 5])
        #expect(SecondOrderSections.Section.identity.coefficients == [1, 0, 0, 0, 0])
        let cascade = SecondOrderSections(sections: [section, .identity])
        #expect(cascade.domain == .digital, "digital unless stated")
        #expect(cascade.coefficients == [1, 2, 3, 4, 5, 1, 0, 0, 0, 0])
        #expect(cascade == SecondOrderSections(sections: [section, .identity], domain: .digital))
        #expect(cascade != SecondOrderSections(sections: [section, .identity], domain: .analog))
        #expect(SecondOrderSections(sections: []).coefficients.isEmpty)
    }

    @Test func rootsAreReadFromEachSectionInClosedForm() throws {
        // (1 + 2z⁻¹ + z⁻²)/(1 − z⁻¹ + 0.5z⁻²) → zeros −1, −1; poles 0.5 ± 0.5j.
        let lowPass = SecondOrderSections(sections: [.init(b0: 0.25, b1: 0.5, b2: 0.25, a1: -1, a2: 0.5)])
        #expect(lowPass.zeros == [Complex(-1), Complex(-1)])
        #expect(lowPass.poles == [Complex(0.5, 0.5), Complex(0.5, -0.5)])
        #expect(lowPass.gain == 0.25)

        // A first-order section: the zero and the pole at the origin cancel.
        let firstOrder = SecondOrderSections(sections: [.init(b0: 2, b1: -1, b2: 0, a1: -0.5, a2: 0)])
        #expect(firstOrder.zeros == [Complex(0.5)])
        #expect(firstOrder.poles == [Complex(0.5)])
        #expect(firstOrder.gain == 2)

        // A pure gain, a pure delay and a section that passes nothing.
        let gain = SecondOrderSections(sections: [.init(b0: 3, b1: 0, b2: 0, a1: 0, a2: 0)])
        #expect(gain.zeros.isEmpty && gain.poles.isEmpty && gain.gain == 3)
        let delay = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 1.5, a1: 0, a2: 0.25)])
        #expect(delay.zeros.isEmpty && delay.gain == 1.5)
        #expect(delay.poles == [Complex(0, 0.5), Complex(0, -0.5)])
        let oneZero = SecondOrderSections(sections: [.init(b0: 0, b1: 2, b2: 1, a1: 0.5, a2: 0.06)])
        #expect(oneZero.zeros == [Complex(-0.5)] && oneZero.gain == 2)
        expectRootsClose(oneZero.poles, [Complex(-0.2), Complex(-0.3)], relative: 1e-14, "two real poles")
        let silent = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 0, a1: 0.5, a2: 0)])
        #expect(silent.gain == 0 && silent.zeros.isEmpty)

        // A cascade multiplies gains and concatenates roots; no sections is the identity.
        let cascade = SecondOrderSections(sections: lowPass.sections + firstOrder.sections)
        #expect(cascade.gain == 0.5)
        #expect(cascade.zeros == lowPass.zeros + firstOrder.zeros)
        #expect(cascade.poles == lowPass.poles + firstOrder.poles)
        let identity = SecondOrderSections(sections: [])
        #expect(identity.gain == 1 && identity.zeros.isEmpty && identity.poles.isEmpty)
        #expect(try identity.frequencyResponse(at: [0, 1, 2]) == [.one, .one, .one])
    }

    @Test func anAnalogCascadeCanBeWrittenDownButNotConvertedTo() throws {
        // 1/(s² + √2·s + 1): a second-order Butterworth low-pass.
        let butterworth = SecondOrderSections(sections: [.init(b0: 0, b1: 0, b2: 1, a1: 2.squareRoot(), a2: 1)], domain: .analog)
        #expect(butterworth.zeros.isEmpty)
        expectRootsClose(butterworth.poles, try AnalogPrototype.butterworth(order: 2).poles, relative: 1e-15, "poles")
        #expect(butterworth.gain == 1)
        expectClose(try butterworth.magnitudeResponse(at: [1])[0], 0.5.squareRoot(), .relative(1e-15))
        #expect(try butterworth.isStable)

        let error = thrownError { _ = try analog.secondOrderSections() }
        #expect(error?.isUnsupportedConfiguration == true)
        #expect(error?.description.contains("digital") == true)
    }
}
