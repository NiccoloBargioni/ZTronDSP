import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-412, 413, 414. The golden grid of STG-2: each prototype at orders 2, 5 and 8; edges at
/// 0.05, 0.2 and 0.45 of the sample rate; bands 0.1 and 1 octave wide. Tolerance 1e-9
/// relative. Every case carries the oracle's own prototype, so a transformation is tested
/// on its own; zeros and poles are matched as sets.
@Suite("Frequency transformations and the bilinear transform (WP-412, 413, 414)")
struct FrequencyTransformationTests {
    private static let tolerance = 1e-9

    private struct Case {
        let golden: GoldenCase
        let kind: String
        let prototype: ZeroPoleGain
        let transformation: FrequencyTransformation
        let order: Int
        let sampleRate: Double
    }

    private func cases(_ kinds: Set<String>) throws -> [Case] {
        let file = try Golden.transformations.get()
        #expect(file.cases.count == 270)
        var result: [Case] = []
        for golden in file.cases {
            let kind = try golden.string("kind")
            guard kinds.contains(kind) else { continue }
            let prototype = ZeroPoleGain(
                zeros: try golden.complexes("prototype_zeros"), poles: try golden.complexes("prototype_poles"),
                gain: try golden.scalar("prototype_gain"), domain: .analog)
            let transformation: FrequencyTransformation
            switch kind {
            case "lowpass": transformation = .lowPass(cutoff: try golden.number("wo"))
            case "highpass": transformation = .highPass(cutoff: try golden.number("wo"))
            case "bandpass": transformation = .bandPass(center: try golden.number("wo"), bandwidth: try golden.number("bw"))
            default: transformation = .bandStop(center: try golden.number("wo"), bandwidth: try golden.number("bw"))
            }
            result.append(Case(golden: golden, kind: kind, prototype: prototype, transformation: transformation,
                               order: try golden.integer("order"), sampleRate: try golden.number("sample_rate")))
        }
        try #require(!result.isEmpty)
        return result
    }

    private func compare(_ system: ZeroPoleGain, _ golden: GoldenCase, prefix: String, label: String) throws {
        expectRootsClose(system.zeros, try golden.complexes(prefix + "zeros"), relative: Self.tolerance, "\(golden.name) \(prefix)zeros",
                         measure: "\(label) zeros, relative")
        expectRootsClose(system.poles, try golden.complexes(prefix + "poles"), relative: Self.tolerance, "\(golden.name) \(prefix)poles",
                         measure: "\(label) poles, relative")
        let gain = try golden.scalar(prefix + "gain")
        expectClose(system.gain, gain, .relative(Self.tolerance), "\(golden.name) \(prefix)gain")
        Measurements.shared.record("\(label) gain, relative", abs(system.gain - gain) / abs(gain), bound: Self.tolerance)
    }

    // MARK: Golden, zero-pole form

    @Test func lowPassAndHighPassMatchTheOracle() throws {
        let selected = try cases(["lowpass", "highpass"])
        #expect(selected.count == 5 * 3 * 3 * 2)
        for item in selected {
            let transformed = try item.prototype.transformed(by: item.transformation)
            #expect(transformed.domain == .analog)
            #expect(transformed.poles.count == item.order)
            try compare(transformed, item.golden, prefix: "", label: "WP-412 low-pass and high-pass")
        }
    }

    @Test func bandPassAndBandStopMatchTheOracle() throws {
        let selected = try cases(["bandpass", "bandstop"])
        #expect(selected.count == 5 * 3 * 3 * 2 * 2)
        for item in selected {
            let transformed = try item.prototype.transformed(by: item.transformation)
            #expect(transformed.poles.count == 2 * item.order, "the order doubles")
            try compare(transformed, item.golden, prefix: "", label: "WP-413 band-pass and band-stop")
        }
    }

    @Test func theBilinearTransformMatchesTheOracle() throws {
        let selected = try cases(["lowpass", "highpass", "bandpass", "bandstop"])
        for item in selected {
            // From the oracle's analog filter, so that only the bilinear step is under test.
            let analog = ZeroPoleGain(zeros: try item.golden.complexes("zeros"), poles: try item.golden.complexes("poles"),
                                      gain: try item.golden.scalar("gain"), domain: .analog)
            let digital = try analog.bilinear(sampleRate: item.sampleRate)
            #expect(digital.domain == .digital)
            #expect(digital.zeros.count == digital.poles.count, "zeros at infinity move to z = −1")
            try compare(digital, item.golden, prefix: "digital_", label: "WP-414 bilinear (zero-pole form)")
            #expect(try digital.isStable, "\(item.golden.name)")
        }
    }

    // MARK: Golden, coefficient forms

    @Test func theCoefficientFormOfTheBilinearTransformMatchesTheOracle() throws {
        let selected = try cases(["lowpass", "highpass", "bandpass", "bandstop"]).filter { $0.order <= 5 }
        #expect(selected.count == 5 * 2 * 18)
        for item in selected {
            let analog = TransferFunction(numerator: try item.golden.real("b"), denominator: try item.golden.real("a"), domain: .analog)
            let digital = try analog.bilinear(sampleRate: item.sampleRate)
            #expect(digital.domain == .digital)
            #expect(digital.denominator.leadingCoefficient == 1)
            // SciPy returns both lists at the full length; a leading zero is dropped here.
            let expectedNumerator = try item.golden.real("digital_b")
            let expectedDenominator = try item.golden.real("digital_a")
            let numerator = [Double](repeating: 0, count: expectedNumerator.count - digital.numerator.coefficients.count) + digital.numerator.coefficients
            // The expansion sums terms of alternating sign; what it can be held to is the size
            // of the largest coefficient of each polynomial.
            expectClose(numerator, expectedNumerator, .relativeToMaximum(Self.tolerance), "\(item.golden.name) numerator")
            expectClose(digital.denominator.coefficients, expectedDenominator, .relativeToMaximum(Self.tolerance), "\(item.golden.name) denominator")
            let peak = expectedDenominator.map { abs($0) }.max() ?? 1
            Measurements.shared.record("WP-414 bilinear (coefficient form), relative to the largest coefficient",
                                       zip(digital.denominator.coefficients, expectedDenominator).map { abs($0 - $1) }.max()! / peak, bound: Self.tolerance)
        }
    }

    @Test func theCoefficientFormOfATransformationIsObtainedByConversion() throws {
        // Orders 2 and 5: through the root finder and back. The oracle's coefficients are those
        // of zpk2tf applied to its transformed zeros and poles.
        let selected = try cases(["lowpass", "highpass", "bandpass", "bandstop"]).filter { $0.order <= 5 }
        for item in selected {
            let prototype = try item.prototype.transferFunction()
            let transformed = try prototype.transformed(by: item.transformation)
            let roots = try item.golden.complexes("poles")
            let zeros = try item.golden.complexes("zeros")
            // Root finding lies in between; at these orders it costs nothing that shows.
            let tolerance = Self.tolerance
            expectCoefficientsClose(transformed.denominator.coefficients, try item.golden.real("a"), roots: roots, leading: 1,
                                    relative: tolerance, "\(item.golden.name) denominator",
                                    measure: "WP-412/413 coefficient form by conversion, order \(item.order), relative to the coefficient's scale")
            expectCoefficientsClose(transformed.numerator.coefficients, try item.golden.real("b"), roots: zeros,
                                    leading: try item.golden.scalar("gain"), relative: tolerance, "\(item.golden.name) numerator")
        }
    }

    // MARK: What the transformations do, checked without the oracle

    @Test func theTransformedResponseTakesThePrototypesValuesAtTheMappedFrequencies() throws {
        let prototype = try AnalogPrototype.elliptic(order: 5, ripple: .decibels(1), stopband: .decibels(60))
        let probes: [Double] = [0.1, 0.5, 0.9, 1, 1.3, 2.5, 7]
        let reference = try prototype.frequencyResponse(at: probes)

        // Low-pass: ω → ω·cutoff.
        let lowPass = try prototype.transformed(by: .lowPass(cutoff: 5_000))
        expectResponseClose(try lowPass.frequencyResponse(at: probes.map { $0 * 5_000 }), reference, relativeToPeak: 1e-12, "low-pass")

        // High-pass: s → cutoff/s, so jω ↦ −j·cutoff/ω: the prototype's response at −(cutoff/ω), its conjugate.
        let highPass = try prototype.transformed(by: .highPass(cutoff: 5_000))
        expectResponseClose(try highPass.frequencyResponse(at: probes.map { 5_000 / $0 }), reference.map(\.conjugate), relativeToPeak: 1e-12, "high-pass")

        // Band-pass: the prototype frequency Ω is reached at ω = (Ω·bw + √(Ω²bw² + 4ω₀²))/2.
        let centre = 3_000.0
        let width = 800.0
        let bandPass = try prototype.transformed(by: .bandPass(center: centre, bandwidth: width))
        let upper = probes.map { ($0 * width + ($0 * $0 * width * width + 4 * centre * centre).squareRoot()) / 2 }
        expectResponseClose(try bandPass.frequencyResponse(at: upper), reference, relativeToPeak: 1e-11, "band-pass")
        #expect(bandPass.poles.count == 10 && bandPass.zeros.count == 4 + 4 + 1)

        // Band-stop: jω ↦ j·bw·ω/(ω₀² − ω²), so below the centre Ω is reached at
        // ω = (−bw + √(bw² + 4Ω²ω₀²))/(2Ω).
        let bandStop = try prototype.transformed(by: .bandStop(center: centre, bandwidth: width))
        let lower = probes.map { (-width + (width * width + 4 * $0 * $0 * centre * centre).squareRoot()) / (2 * $0) }
        expectResponseClose(try bandStop.frequencyResponse(at: lower), reference, relativeToPeak: 1e-11, "band-stop")
        #expect(bandStop.poles.count == 10 && bandStop.zeros.count == 10)
        // The zero that the prototype has at infinity lands on the centre.
        #expect(bandStop.zeros.contains(Complex(0, centre)) && bandStop.zeros.contains(Complex(0, -centre)))
    }

    /// §7.5 row 4, for the band transformations (WP-413, WP-418a). Written as r − √(r² − ω₀²)
    /// the smaller image subtracts two nearly equal numbers; across three decades that
    /// costs six digits.
    @Test func stressAWideBandKeepsItsAccuracy() throws {
        // A band of three decades: the smaller image of each root is formed from the product of
        // the pair, not by a subtraction that would cancel. Every pair multiplies to ω₀².
        let prototype = try AnalogPrototype.butterworth(order: 4)
        let centre = (20.0 * 20_000).squareRoot()
        let bandPass = try prototype.transformed(by: .bandPass(center: centre, bandwidth: 19_980))
        let count = prototype.poles.count
        for index in 0 ..< count {
            let product = bandPass.poles[index] * bandPass.poles[index + count]
            expectClose(product.real, centre * centre, .relative(1e-15))
            #expect(abs(product.imaginary) <= 1e-15 * centre * centre)
        }
        // Against the defining equation p² − 2·(bw/2)·r·p + ω₀² = 0 for each prototype pole r.
        for (index, root) in prototype.poles.enumerated() {
            for image in [bandPass.poles[index], bandPass.poles[index + count]] {
                let residual = image * image - root * 19_980 * image + centre * centre
                #expect(residual.magnitude <= 1e-13 * image.squaredMagnitude.squareRoot() * 19_980, "pole \(image)")
            }
        }
    }

    /// §7.5 row 4, for the bilinear transform (WP-414). Applied to the roots, the transform
    /// keeps poles that crowd z = 1; applied to the coefficients of the same filter it does
    /// not. The fixtures are the low corners of the stress library.
    @Test func stressTheBilinearTransformOfRootsKeepsWhatTheCoefficientFormLoses() throws {
        for fixture in StressFixture.filtersNearZero where fixture.order == 8 {
            let prototype = try AnalogPrototype.butterworth(order: fixture.order)
            let warped = try DSP.prewarpedAngularFrequency(hertz: fixture.cutoff, sampleRate: fixture.sampleRate)
            let transformation: FrequencyTransformation = fixture.response == .lowPass ? .lowPass(cutoff: warped) : .highPass(cutoff: warped)
            let analog = try prototype.transformed(by: transformation)
            let digital = try analog.bilinear(sampleRate: fixture.sampleRate)

            // Every pole, mapped back, is the analog pole it came from: the distance from z = 1
            // is what carries the filter, and it is kept to twelve digits.
            let twice = 2 * fixture.sampleRate
            let back = digital.poles.map { twice * ($0 - Complex.one) / ($0 + Complex.one) }
            let kept = try #require(expectRootsClose(back, analog.poles, relative: 1e-9, "\(fixture.name): poles mapped back",
                                                     measure: "WP-414 stress: digital poles mapped back to the analog plane, relative"))
            #expect(kept < 1e-10)
            #expect(try digital.isStable)

            // The hazard: the same filter through the coefficient form of the transform.
            let coefficients = try analog.transferFunction().bilinear(sampleRate: fixture.sampleRate)
            let lost = RootMatching.bottleneck(try coefficients.poles, digital.poles)
            Measurements.shared.record("WP-414 stress: poles of the coefficient-form transform, relative (hazard)", lost, bound: 1e-9)
            #expect(lost > 1e-4, "\(fixture.name): through coefficients the poles are off by \(lost)")
        }
    }

    @Test func theBilinearTransformMapsTheAxisOntoTheCircle() throws {
        let sampleRate = 48_000.0
        let prototype = try AnalogPrototype.chebyshev1(order: 4, ripple: .decibels(1))
        let cutoff = try DSP.prewarpedAngularFrequency(hertz: 6_000, sampleRate: sampleRate)
        let analog = try prototype.transformed(by: .lowPass(cutoff: cutoff))
        let digital = try analog.bilinear(sampleRate: sampleRate)
        // H_d(e^{jω}) = H_a(j·2fs·tan(ω/2)): the whole response, not only the edge.
        let frequencies = (0 ..< 100).map { Double($0) * 0.03 }
        let warped = frequencies.map { 2 * sampleRate * tan($0 / 2) }
        expectResponseClose(try digital.frequencyResponse(at: frequencies), try analog.frequencyResponse(at: warped), relativeToPeak: 1e-12, "bilinear")
        // The pre-warped edge lands exactly on 6 kHz: the ripple's floor.
        let edge = 2 * Double.pi * 6_000 / sampleRate
        expectClose(try digital.magnitudeResponse(at: [edge])[0], pow(10, -1.0 / 20), .relative(1e-12))
        // The four zeros at infinity are at the Nyquist frequency.
        #expect(digital.zeros == [Complex](repeating: Complex(-1), count: 4))
    }

    @Test func prewarpingIsTwoFsTanOfHalfTheAngle() throws {
        #expect(try DSP.prewarpedAngularFrequency(hertz: 0, sampleRate: 48_000) == 0)
        expectClose(try DSP.prewarpedAngularFrequency(hertz: 12_000, sampleRate: 48_000), 96_000.0, .relative(1e-15))
        // Well below Nyquist it is the frequency itself, in rad/s.
        expectClose(try DSP.prewarpedAngularFrequency(hertz: 10, sampleRate: 48_000), 20 * Double.pi, .relative(1e-6))
        #expect(thrownError { _ = try DSP.prewarpedAngularFrequency(hertz: 24_000, sampleRate: 48_000) }?.invalidParameterName == "hertz")
        #expect(thrownError { _ = try DSP.prewarpedAngularFrequency(hertz: -1, sampleRate: 48_000) }?.invalidParameterName == "hertz")
        #expect(thrownError { _ = try DSP.prewarpedAngularFrequency(hertz: .nan, sampleRate: 48_000) }?.invalidParameterName == "hertz")
        #expect(thrownError { _ = try DSP.prewarpedAngularFrequency(hertz: 100, sampleRate: 0) }?.invalidParameterName == "sampleRate")
        #expect(thrownError { _ = try DSP.prewarpedAngularFrequency(hertz: 100, sampleRate: .infinity) }?.invalidParameterName == "sampleRate")
    }

    // MARK: Negative paths

    @Test func invalidTransformationsAreTypedErrors() throws {
        let prototype = try AnalogPrototype.butterworth(order: 3)
        for bad in [0.0, -1, .nan, .infinity] {
            #expect(thrownError { _ = try prototype.transformed(by: .lowPass(cutoff: bad)) }?.invalidParameterName == "cutoff")
            #expect(thrownError { _ = try prototype.transformed(by: .highPass(cutoff: bad)) }?.invalidParameterName == "cutoff")
            #expect(thrownError { _ = try prototype.transformed(by: .bandPass(center: bad, bandwidth: 1)) }?.invalidParameterName == "center")
            #expect(thrownError { _ = try prototype.transformed(by: .bandPass(center: 1, bandwidth: bad)) }?.invalidParameterName == "bandwidth")
            #expect(thrownError { _ = try prototype.transformed(by: .bandStop(center: bad, bandwidth: 1)) }?.invalidParameterName == "center")
            #expect(thrownError { _ = try prototype.transformed(by: .bandStop(center: 1, bandwidth: bad)) }?.invalidParameterName == "bandwidth")
        }
        // Only an analog prototype with at least as many poles as zeros is transformed.
        let digital = try prototype.bilinear(sampleRate: 2)
        #expect(thrownError { _ = try digital.transformed(by: .lowPass(cutoff: 1)) }?.invalidParameterName == "system")
        let improper = ZeroPoleGain(zeros: [Complex(-1), Complex(-2)], poles: [Complex(-3)], gain: 1, domain: .analog)
        #expect(thrownError { _ = try improper.transformed(by: .lowPass(cutoff: 1)) }?.invalidParameterName == "system")
        // An inverting transformation sends a root at the origin to infinity.
        let integrator = ZeroPoleGain(zeros: [], poles: [.zero], gain: 1, domain: .analog)
        #expect(thrownError { _ = try integrator.transformed(by: .highPass(cutoff: 1)) }?.invalidParameterName == "transformation")
        #expect(thrownError { _ = try integrator.transformed(by: .bandStop(center: 1, bandwidth: 1)) }?.invalidParameterName == "transformation")
        #expect(throws: Never.self) { _ = try integrator.transformed(by: .bandPass(center: 1, bandwidth: 1)) }
    }

    @Test func invalidBilinearTransformsAreTypedErrors() throws {
        let analog = try AnalogPrototype.butterworth(order: 2)
        for bad in [0.0, -48_000, .nan, .infinity] {
            #expect(thrownError { _ = try analog.bilinear(sampleRate: bad) }?.invalidParameterName == "sampleRate")
            #expect(thrownError { _ = try analog.transferFunction().bilinear(sampleRate: bad) }?.invalidParameterName == "sampleRate")
        }
        let digital = try analog.bilinear(sampleRate: 1)
        #expect(thrownError { _ = try digital.bilinear(sampleRate: 1) }?.invalidParameterName == "system")
        #expect(thrownError { _ = try digital.transferFunction().bilinear(sampleRate: 1) }?.invalidParameterName == "system")
        let improper = ZeroPoleGain(zeros: [Complex(-1), Complex(-2)], poles: [Complex(-3)], gain: 1, domain: .analog)
        #expect(thrownError { _ = try improper.bilinear(sampleRate: 1) }?.invalidParameterName == "system")
        #expect(thrownError { _ = try TransferFunction(numerator: [1, 3, 2], denominator: [1, 3], domain: .analog).bilinear(sampleRate: 1) }?.invalidParameterName == "system")
        #expect(thrownError { _ = try TransferFunction(numerator: [1], denominator: [0], domain: .analog).bilinear(sampleRate: 1) }?.invalidParameterName == "denominator")
        // A pole at s = 2·fs has no image.
        let unlucky = ZeroPoleGain(zeros: [], poles: [Complex(2)], gain: 1, domain: .analog)
        #expect(thrownError { _ = try unlucky.bilinear(sampleRate: 1) }?.invalidParameterName == "system")
        #expect(thrownError { _ = try unlucky.transferFunction().bilinear(sampleRate: 1) }?.isUnsupportedConfiguration == true)
        // Coefficients that leave the range of a double.
        let steep = TransferFunction(numerator: [1], denominator: [1e300, 1e300, 1], domain: .analog)
        #expect(thrownError { _ = try steep.bilinear(sampleRate: 1e10) }?.isUnsupportedConfiguration == true)
        // The coefficient form is capped at the degree of the root finder.
        let long = TransferFunction(numerator: [1], denominator: [1] + [Double](repeating: 0, count: 512) + [1], domain: .analog)
        #expect(long.denominator.degree == 513)
        #expect(thrownError { _ = try long.bilinear(sampleRate: 1) }?.isUnsupportedConfiguration == true)
    }

    @Test func theBilinearCoefficientFormKeepsTheRootFinder() throws {
        struct Marked: PolynomialRootFinder {
            func roots(of polynomial: Polynomial) throws(DSPError) -> [Complex] { try CompanionQRRootFinder().roots(of: polynomial) }
        }
        let analog = TransferFunction(numerator: [1], denominator: [1, 2.squareRoot(), 1], domain: .analog, rootFinder: Marked())
        let digital = try analog.bilinear(sampleRate: 1)
        #expect(digital.rootFinder == AnyStrategy(Marked()))
        // And it is the transform of the zero-pole form.
        let reference = try AnalogPrototype.butterworth(order: 2).bilinear(sampleRate: 1)
        expectRootsClose(try digital.poles, reference.poles, relative: 1e-13, "poles")
        expectRootsClose(try digital.zeros, reference.zeros, relative: 1e-7, "the double zero at −1, found from coefficients")
        expectClose(try digital.gain, reference.gain, .relative(1e-14))
    }
}
