import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

/// WP-435. The etk4j parity suite: one test per row of Appendix A of the specification, each
/// through the spelling the row's "ZTronDSP" column names, against the row's oracle. (The
/// last row, `signal.fft.FFT`, is held by WP-502.)
///
/// The oracles' values are the golden vectors of the packages that built each piece; what
/// this suite adds is the path a user of etk4j takes to the same numbers.
@Suite("etk4j parity (WP-435, Appendix A)")
struct ParityTests {
    private static let tolerance = 1e-9

    private func compare(_ system: ZeroPoleGain, _ golden: GoldenCase, prefix: String = "", row: String) throws {
        expectRootsClose(system.poles, try golden.complexes(prefix + "poles"), relative: Self.tolerance, "\(golden.name) poles",
                         measure: "WP-435 \(row): poles, relative")
        expectRootsClose(system.zeros, try golden.complexes(prefix + "zeros"), relative: Self.tolerance, "\(golden.name) zeros",
                         measure: "WP-435 \(row): zeros, relative")
        let gain = try golden.scalar(prefix + "gain")
        expectClose(system.gain, gain, .relative(Self.tolerance), "\(golden.name) gain")
        Measurements.shared.record("WP-435 \(row): gain, relative", abs(system.gain - gain) / abs(gain), bound: Self.tolerance)
    }

    private func prototypes(_ family: String, count: Int) throws -> [GoldenCase] {
        let selected = try Golden.prototypes.get().cases.filter { try $0.string("family") == family }
        try #require(selected.count == count, "\(family): \(selected.count) cases")
        return selected
    }

    // MARK: Rows 1–5: the analog prototypes

    /// `ButterWorth.buttAp(n)` → `AnalogPrototype.butterworth(order:)`; oracle `scipy.signal.buttap`.
    @Test func row01ButterworthPrototype() throws {
        for golden in try prototypes("butterworth", count: 20) {
            try compare(try AnalogPrototype.butterworth(order: try golden.integer("order")), golden, row: "buttAp")
        }
    }

    /// `Chebyshev1.cheb1Ap(n, rp)` → `AnalogPrototype.chebyshev1(order:ripple:)`; oracle `cheb1ap`.
    @Test func row02Chebyshev1Prototype() throws {
        for golden in try prototypes("chebyshev1", count: 36) {
            let prototype = try AnalogPrototype.chebyshev1(order: try golden.integer("order"), ripple: .decibels(try golden.number("ripple")))
            try compare(prototype, golden, row: "cheb1Ap")
        }
    }

    /// `Chebyshev2.cheb2Ap(n, rs)` → `AnalogPrototype.chebyshev2(order:stopband:)`; oracle `cheb2ap`.
    @Test func row03Chebyshev2Prototype() throws {
        for golden in try prototypes("chebyshev2", count: 36) {
            let prototype = try AnalogPrototype.chebyshev2(order: try golden.integer("order"), stopband: .decibels(try golden.number("stopband")))
            try compare(prototype, golden, row: "cheb2Ap")
        }
    }

    /// `Elliptic.ellipAp(n, rp, rs)` → `AnalogPrototype.elliptic(order:ripple:stopband:)`; oracle `ellipap`.
    @Test func row04EllipticPrototype() throws {
        for golden in try prototypes("elliptic", count: 108) {
            let prototype = try AnalogPrototype.elliptic(
                order: try golden.integer("order"), ripple: .decibels(try golden.number("ripple")), stopband: .decibels(try golden.number("stopband")))
            try compare(prototype, golden, row: "ellipAp")
        }
    }

    /// `Bessel.besselAp(n)` and its phase-, delay- and magnitude-normalised variants →
    /// `AnalogPrototype.bessel(order:normalization:)`; oracle `besselap(norm=…)`.
    @Test func row05BesselPrototypeInThreeNormalisations() throws {
        var seen: Set<String> = []
        for golden in try prototypes("bessel", count: 75) {
            let name = try golden.string("normalization")
            let normalization: BesselNormalization = name == "phase" ? .phase : name == "delay" ? .delay : .magnitude
            seen.insert(name)
            try compare(try AnalogPrototype.bessel(order: try golden.integer("order"), normalization: normalization), golden, row: "besselAp")
        }
        #expect(seen == ["phase", "delay", "mag"])
    }

    // MARK: Row 6: the four responses of the five families

    /// `newLowPass`, `newHighPass`, `newBandpass`, `newBandStop` and their `…ZPK` forms →
    /// `IIRDesign(family, response, order:, domain: .analog)` read as `.zeroPoleGain` or
    /// `.transferFunction`, and `domain: .digital` for the real-time path; oracle
    /// `iirfilter(…, analog=True)` and `analog=False`.
    @Test func row06DesignsOfEveryFamilyAndResponse() throws {
        var families: Set<String> = [], responses: Set<String> = []
        for analog in [true, false] {
            let designs = try DesignCase.all(analog: analog)
            for item in designs {
                families.insert(item.familyName)
                responses.insert(item.responseName)
                // The ZPK form.
                let system = item.design.zeroPoleGain
                #expect(system.domain == (analog ? .analog : .digital))
                try compare(system, item.golden, row: analog ? "new…ZPK, analog" : "new…ZPK, digital")
                // The coefficient form, held to the scale of each coefficient's terms.
                let coefficients = try item.design.transferFunction
                expectCoefficientsClose(coefficients.denominator.coefficients, try item.golden.real("a"), roots: system.poles, leading: 1,
                                        relative: Self.tolerance, "\(item.golden.name) denominator",
                                        measure: "WP-435 new… coefficient form, \(analog ? "analog" : "digital"): denominator, relative to each coefficient's scale")
                expectCoefficientsClose(coefficients.numerator.coefficients, try item.golden.real("b"), roots: system.zeros, leading: system.gain,
                                        relative: Self.tolerance, "\(item.golden.name) numerator",
                                        measure: "WP-435 new… coefficient form, \(analog ? "analog" : "digital"): numerator, relative to each coefficient's scale")
            }
        }
        #expect(families == ["butterworth", "chebyshev1", "chebyshev2", "elliptic", "bessel"])
        #expect(responses == ["lowpass", "highpass", "bandpass", "bandstop"])
    }

    // MARK: Row 7: order estimation

    /// The design a response stage arrives at from a tolerance scheme.
    private func designed(
        _ family: some FilterFamily, _ kind: String, passband: [Double], stopband: [Double], loss: Double, attenuation: Double, sampleRate: Double
    ) throws -> IIRDesign? {
        let maximumLoss = Amplification.decibels(loss), minimumAttenuation = Amplification.decibels(attenuation)
        let pass = passband.map { Frequency.hertz($0) }, stop = stopband.map { Frequency.hertz($0) }
        let result: FilterDesign
        switch kind {
        case "lowpass":
            result = try LowPass(family, passband: pass[0], stopband: stop[0], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation).design(sampleRate: sampleRate)
        case "highpass":
            result = try HighPass(family, passband: pass[0], stopband: stop[0], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation).design(sampleRate: sampleRate)
        case "bandpass":
            result = try BandPass(family, passband: (from: pass[0], to: pass[1]), stopband: (from: stop[0], to: stop[1]),
                                  maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation).design(sampleRate: sampleRate)
        default:
            result = try BandStop(family, passband: (from: pass[0], to: pass[1]), stopband: (from: stop[0], to: stop[1]),
                                  maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation).design(sampleRate: sampleRate)
        }
        return result.iir
    }

    /// `buttOrd`, `cheb1Ord`, `cheb2Ord`, `ellipOrd` on `LowPassSpecs`, `HighPassSpecs`,
    /// `BandpassSpecs`, `BandStopSpecs` → the `passband:stopband:maximumLoss:minimumAttenuation:`
    /// initialisers of the response stages, through the family's `FilterOrderStrategy`; the
    /// specification objects are arguments (API-6). Oracle `buttord`, `cheb1ord`, `cheb2ord`,
    /// `ellipord`, and the design the oracle makes with that order and natural frequency.
    @Test func row07OrderEstimationThroughTheResponseStages() throws {
        let file = try Golden.order.get()
        var compared = 0
        var families: Set<String> = [], responses: Set<String> = []
        for golden in file.cases {
            guard try golden.string("domain") == "digital" else { continue }
            let familyName = try golden.string("family"), kind = try golden.string("response")
            let sampleRate = try golden.number("sample_rate")
            // A family whose own ripple and attenuation are not the scheme's: the scheme decides.
            let family: any FilterFamily
            switch familyName {
            case "butterworth": family = ButterworthFamily()
            case "chebyshev1": family = Chebyshev1Family(ripple: .decibels(0.3))
            case "chebyshev2": family = Chebyshev2Family(stopband: .decibels(33))
            default: family = EllipticFamily(ripple: .decibels(0.3), stopband: .decibels(33))
            }
            func open(_ family: some FilterFamily) throws -> IIRDesign? {
                try designed(family, kind, passband: try golden.numbers("passband"), stopband: try golden.numbers("stopband"),
                             loss: try golden.number("maximum_loss"), attenuation: try golden.number("minimum_attenuation"), sampleRate: sampleRate)
            }
            let design = try #require(try open(family), "\(golden.name): an IIR design was due")
            #expect(design.order == (try golden.integer("order")), "\(golden.name): order \(design.order)")
            expectClose(design.response.edges, try golden.real("natural"), .relative(Self.tolerance), "\(golden.name): natural frequency")
            try compare(design.zeroPoleGain, golden, row: "…Ord through the response stages")
            families.insert(familyName)
            responses.insert(kind)
            compared += 1
        }
        #expect(compared == 4 * 4 * 3, "\(compared) schemes")
        #expect(families == ["butterworth", "chebyshev1", "chebyshev2", "elliptic"] && responses == ["lowpass", "highpass", "bandpass", "bandstop"])
    }

    // MARK: Rows 8 and 9: transformations

    private struct TransformationCase {
        let golden: GoldenCase
        let kind: String
        let prototype: ZeroPoleGain
        let transformation: FrequencyTransformation
        let order: Int
        let sampleRate: Double
    }

    private func transformations() throws -> [TransformationCase] {
        let file = try Golden.transformations.get()
        return try file.cases.map { golden in
            let kind = try golden.string("kind")
            let prototype = ZeroPoleGain(zeros: try golden.complexes("prototype_zeros"), poles: try golden.complexes("prototype_poles"),
                                         gain: try golden.scalar("prototype_gain"), domain: .analog)
            let transformation: FrequencyTransformation
            switch kind {
            case "lowpass": transformation = .lowPass(cutoff: try golden.number("wo"))
            case "highpass": transformation = .highPass(cutoff: try golden.number("wo"))
            case "bandpass": transformation = .bandPass(center: try golden.number("wo"), bandwidth: try golden.number("bw"))
            default: transformation = .bandStop(center: try golden.number("wo"), bandwidth: try golden.number("bw"))
            }
            return TransformationCase(golden: golden, kind: kind, prototype: prototype, transformation: transformation,
                                      order: try golden.integer("order"), sampleRate: try golden.number("sample_rate"))
        }
    }

    /// `Filters.lpToLp`, `lpToHp`, `lpToBp`, `lpToBs`, coefficient and ZPK forms →
    /// `FrequencyTransformation` on `ZeroPoleGain`, the coefficient form by conversion;
    /// oracle `lp2lp_zpk`, `lp2hp_zpk`, `lp2bp_zpk`, `lp2bs_zpk`.
    @Test func row08FrequencyTransformations() throws {
        var kinds: [String: Int] = [:]
        for item in try transformations() {
            let transformed = try item.prototype.transformed(by: item.transformation)
            #expect(transformed.domain == .analog)
            try compare(transformed, item.golden, row: "lpTo…, ZPK form")
            kinds[item.kind, default: 0] += 1
            // The coefficient form, by conversion of the transformed roots (low orders: the
            // expansion of a high-order band filter is what ZPK form is there to avoid).
            guard item.order <= 5 else { continue }
            let coefficients = try transformed.transferFunction()
            expectCoefficientsClose(coefficients.denominator.coefficients, try item.golden.real("a"), roots: transformed.poles, leading: 1,
                                    relative: Self.tolerance, "\(item.golden.name) denominator",
                                    measure: "WP-435 lpTo…, coefficient form: denominator, relative to each coefficient's scale")
            expectCoefficientsClose(coefficients.numerator.coefficients, try item.golden.real("b"), roots: transformed.zeros, leading: transformed.gain,
                                    relative: Self.tolerance, "\(item.golden.name) numerator",
                                    measure: "WP-435 lpTo…, coefficient form: numerator, relative to each coefficient's scale")
        }
        #expect(kinds.keys.sorted() == ["bandpass", "bandstop", "highpass", "lowpass"] && kinds.values.reduce(0, +) == 270, "\(kinds)")
    }

    /// `BilinearTransform.transform(num, den, fs)` → `ZeroPoleGain.bilinear(sampleRate:)`,
    /// `TransferFunction.bilinear(sampleRate:)`; oracle `bilinear_zpk`, `bilinear`.
    @Test func row09BilinearTransform() throws {
        var roots = 0, coefficients = 0
        for item in try transformations() {
            // From the oracle's analog filter, so that only the bilinear step is under test.
            let analog = ZeroPoleGain(zeros: try item.golden.complexes("zeros"), poles: try item.golden.complexes("poles"),
                                      gain: try item.golden.scalar("gain"), domain: .analog)
            let digital = try analog.bilinear(sampleRate: item.sampleRate)
            #expect(digital.domain == .digital && digital.zeros.count == digital.poles.count)
            try compare(digital, item.golden, prefix: "digital_", row: "bilinear, ZPK form")
            roots += 1
            guard item.order <= 5 else { continue }
            let expanded = try TransferFunction(numerator: try item.golden.real("b"), denominator: try item.golden.real("a"), domain: .analog)
                .bilinear(sampleRate: item.sampleRate)
            let expectedNumerator = try item.golden.real("digital_b"), expectedDenominator = try item.golden.real("digital_a")
            // SciPy returns both lists at the full length; a leading zero is dropped here.
            let numerator = [Double](repeating: 0, count: expectedNumerator.count - expanded.numerator.coefficients.count) + expanded.numerator.coefficients
            expectClose(numerator, expectedNumerator, .relativeToMaximum(Self.tolerance), "\(item.golden.name) numerator")
            expectClose(expanded.denominator.coefficients, expectedDenominator, .relativeToMaximum(Self.tolerance), "\(item.golden.name) denominator")
            coefficients += 1
        }
        #expect(roots == 270 && coefficients == 5 * 2 * 18, "\(roots) ZPK forms, \(coefficients) coefficient forms")
    }

    // MARK: Rows 10 and 11: smoothing

    /// `SavitzkyGolayFilter` and its `Mode` → `SavitzkyGolay(edge:)` with `.interpolate`,
    /// `.mirror`, `.nearest`, `.constant`, `.wrap`; oracle `savgol_coeffs`, `savgol_filter`.
    @Test func row10SavitzkyGolayAndItsFiveModes() throws {
        let file = try Golden.savitzkyGolay.get()
        let signal = try file.require("signal")
        let input = try signal.floats("input"), rows = try signal.floats("filtered")
        let count = try signal.integer("count")
        var modes: [String: Int] = [:]
        var coefficientCases = 0
        for golden in file.cases {
            let window = try? golden.integer("window")
            if golden.name.hasPrefix("coefficients-"), let window {
                // The coefficients of the stage are the oracle's.
                let coefficients = try DSP.savitzkyGolayCoefficients(window: window, polynomialOrder: try golden.integer("order"), derivative: try golden.integer("derivative"))
                expectClose(coefficients, try golden.real("coefficients"), .absolute(1e-10), golden.name)
                coefficientCases += 1
            }
            guard golden.name.hasPrefix("filter-"), let window else { continue }
            let mode = try golden.string("mode")
            let edge: SavitzkyGolayEdge
            switch mode {
            case "interp": edge = .interpolate
            case "mirror": edge = .mirror
            case "nearest": edge = .nearest
            case "constant": edge = .constant(Float(try golden.number("constant")))
            default: edge = .wrap
            }
            let order = try golden.integer("order"), derivative = try golden.integer("derivative"), row = try golden.integer("row")
            let expected = Array(rows[row * count ..< (row + 1) * count])
            // The signal as a whole, with its ends continued as the mode says.
            let offline = try DSP.savitzkyGolay(input, window: window, polynomialOrder: order, derivative: derivative, edge: edge)
            expectClose(offline, expected, .absolute(1e-5), golden.name)
            Measurements.shared.record("WP-435 SavitzkyGolay, five modes, against savgol_filter, absolute", Double(zip(offline, expected).map { abs($0 - $1) }.max() ?? 1), bound: 1e-5)
            // The stage: the same filter as a stream, which is the oracle's output away from
            // the ends, later by the stage's latency (§6.3.6).
            let half = (window - 1) / 2
            let stream = try Pipeline { SavitzkyGolay(window: window, polynomialOrder: order, derivative: derivative, edge: edge) }
                .process(input, format: SignalFormat(sampleRate: 48_000))
            #expect(stream.count == count)
            let interior = Array(stream[(2 * half)...]), expectedInterior = Array(expected[half ..< count - half])
            expectClose(interior, expectedInterior, .absolute(1e-5), "\(golden.name), as a stage")
            modes[mode, default: 0] += 1
        }
        #expect(modes == ["interp": 27, "mirror": 27, "nearest": 27, "constant": 27, "wrap": 27] && coefficientCases >= 27, "\(modes), \(coefficientCases) coefficient cases")
    }

    /// `AlphaBetaFilter` → `AlphaBeta`; oracle: the defining recurrence.
    @Test func row11AlphaBetaIsTheDefiningRecurrence() throws {
        // etk4j: predict x = x + v·dt; residual r = z − x; correct x += α·r, v += β·r / dt.
        func recurrence(_ measurements: [Float], alpha: Double, beta: Double, dt: Double, x0: Double, v0: Double) -> (position: [Double], velocity: [Double]) {
            var x = x0, v = v0
            var positions: [Double] = [], velocities: [Double] = []
            for measurement in measurements {
                x += v * dt
                let residual = Double(measurement) - x
                x += alpha * residual
                v += beta * residual / dt
                positions.append(x)
                velocities.append(v)
            }
            return (positions, velocities)
        }
        let sampleRate = 100.0
        let ramp = (0 ..< 400).map { Float(0.02 * Double($0) + 0.3 * sin(Double($0) * 0.31)) }
        for (alpha, beta, x0, v0) in [(0.85, 0.005, 0.0, 0.0), (0.5, 0.1, 1.0, -2.0), (0.2, 0.01, -0.5, 4.0)] {
            let expected = recurrence(ramp, alpha: alpha, beta: beta, dt: 1 / sampleRate, x0: x0, v0: v0)
            let format = SignalFormat(sampleRate: sampleRate)
            let position = try Pipeline { AlphaBeta(alpha: alpha, beta: beta, initialPosition: x0, initialVelocity: v0) }.process(ramp, format: format)
            let velocity = try Pipeline { AlphaBeta(alpha: alpha, beta: beta, initialPosition: x0, initialVelocity: v0, output: .velocity) }.process(ramp, format: format)
            expectClose(position, expected.position, .deviationBelow(decibels: -100), "position, α = \(alpha), β = \(beta)")
            expectClose(velocity, expected.velocity, .deviationBelow(decibels: -100), "velocity, α = \(alpha), β = \(beta)")
            Measurements.shared.record("WP-435 AlphaBeta position against the defining recurrence, dB", deviationInDecibels(position, expected.position), bound: -100)
            Measurements.shared.record("WP-435 AlphaBeta velocity against the defining recurrence, dB", deviationInDecibels(velocity, expected.velocity), bound: -100)
            // The offline function is the same tracker.
            #expect(try DSP.alphaBeta(ramp, alpha: alpha, beta: beta, timeStep: 1 / sampleRate, initialPosition: x0, initialVelocity: v0) == position)
        }
    }

    // MARK: Row 12: the two control types

    /// `ZeroPoleGain`, `TransferFunction`: poles, zeros, evaluation, magnitude, phase → the
    /// same-named types and the `LTISystem` analysis (§6.3.8); oracle `freqs`, `freqz`,
    /// `sosfreqz`, `group_delay`.
    @Test func row12ZeroPoleGainAndTransferFunctionAnalysis() async throws {
        let digitalGrid = try DesignCurves.grid("digital"), analogGrid = try DesignCurves.grid("analog")
        let digitalCurves = try DesignCurves(domain: "digital", key: "curves"), analogCurves = try DesignCurves(domain: "analog", key: "curves")
        let coefficientCurves = try DesignCurves(domain: "digital", key: "tf_curves")
        var analysed = 0
        // Digital: the ZPK form, through the analysis.
        for item in try DesignCase.all(analog: false) where item.order == 2 || item.order == 5 {
            let row = try item.golden.integer("row")
            let expected = digitalCurves.complexCurve(row: row)
            let system = item.design.zeroPoleGain
            let report = try await system.analysis(sampleRate: 48_000)
            // Poles and zeros.
            #expect(report.poles == system.poles && report.zeros == system.zeros && report.gain == system.gain && report.isStable)
            // Evaluation, magnitude and phase (`sosfreqz`).
            expectResponseClose(try report.frequencyResponse(at: digitalGrid), expected, relativeToPeak: Self.tolerance, "\(item.golden.name), analysis",
                                measure: "WP-435 ZeroPoleGain analysis: digital response against sosfreqz, relative to the peak")
            let peak = expected.map(\.magnitude).max() ?? 1
            let magnitude = try report.magnitudeResponse(at: digitalGrid), phase = try report.phaseResponse(at: digitalGrid)
            let delay = try report.groupDelay(at: digitalGrid)
            let expectedDelay = digitalCurves.curve(row: row, channel: 2)
            for index in digitalGrid.indices {
                #expect(abs(magnitude[index] - expected[index].magnitude) <= Self.tolerance * peak, "\(item.golden.name), magnitude at point \(index)")
                // Where the response is at least a thousandth of its peak, its phase and its delay are well defined.
                guard expected[index].magnitude >= 1e-3 * peak else { continue }
                let turn = (phase[index] - expected[index].phase).remainder(dividingBy: 2 * .pi)
                #expect(abs(turn) <= 1e-6, "\(item.golden.name), phase at point \(index): \(turn) rad from the oracle")
                // Group delay (`group_delay`, section by section).
                let value = try #require(delay[index], "\(item.golden.name), group delay at point \(index)")
                #expect(abs(value - expectedDelay[index]) <= 1e-6, "\(item.golden.name), group delay at point \(index): \(value) against \(expectedDelay[index])")
                Measurements.shared.record("WP-435 ZeroPoleGain analysis: group delay against group_delay, samples", abs(value - expectedDelay[index]), bound: 1e-6)
            }
            analysed += 1
        }
        // Digital: the coefficient form (`freqz`), whose poles and zeros are found from the coefficients.
        for item in try DesignCase.all(analog: false) where item.order <= 2 {
            let system = TransferFunction(numerator: try item.golden.real("b"), denominator: try item.golden.real("a"), domain: .digital)
            let expected = coefficientCurves.complexCurve(row: try item.golden.integer("tf_row"))
            expectResponseClose(try system.frequencyResponse(at: digitalGrid), expected, relativeToPeak: Self.tolerance, "\(item.golden.name), coefficients",
                                measure: "WP-435 TransferFunction: digital response against freqz, relative to the peak")
            expectRootsClose(try system.poles, try item.golden.complexes("poles"), relative: 1e-6, "\(item.golden.name), poles from coefficients",
                             measure: "WP-435 TransferFunction: poles found from the oracle's coefficients, relative")
            let report = try await system.analysis(sampleRate: 48_000)
            #expect(report.rootConditions.poles.allSatisfy { $0 != nil } && report.order == item.design.zeroPoleGain.poles.count)
            analysed += 1
        }
        // Analog: both forms (`freqs`).
        for item in try DesignCase.all(analog: true) where item.order <= 5 {
            let expected = analogCurves.complexCurve(row: try item.golden.integer("row"))
            let report = try await item.design.zeroPoleGain.analysis(sampleRate: 48_000)
            #expect(report.domain == .analog && report.isStable)
            expectResponseClose(try report.frequencyResponse(at: analogGrid), expected, relativeToPeak: Self.tolerance, "\(item.golden.name), analysis",
                                measure: "WP-435 ZeroPoleGain analysis: analog response against freqs, relative to the peak")
            let coefficients = TransferFunction(numerator: try item.golden.real("b"), denominator: try item.golden.real("a"), domain: .analog)
            expectResponseClose(try coefficients.frequencyResponse(at: analogGrid), expected, relativeToPeak: Self.tolerance, "\(item.golden.name), coefficients",
                                measure: "WP-435 TransferFunction: analog response against freqs, relative to the peak")
            analysed += 1
        }
        #expect(analysed == 40 + 40 + 60, "\(analysed) systems")
    }
}
