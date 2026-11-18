import Accelerate
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPDesign
import ZTronDSPTesting

// Shared by the tests of FIR design, smoothing, the system builders and the stages (the second
// half of M4).

extension Golden {
    static let firDesign = Result { try GoldenFile(named: "fir_design", in: .module) }
    static let savitzkyGolay = Result { try GoldenFile(named: "savitzky_golay", in: .module) }
}

/// Measurements on taps, made independently of the code under test: plain sums in double
/// precision, and one transform for a fine grid.
enum TapMeasure {
    /// `H(e^{jω})` at `hertz`, by the definition.
    static func response(_ taps: [Double], at hertz: Double, sampleRate: Double) -> Complex {
        let omega = 2 * Double.pi * hertz / sampleRate
        var real = 0.0, imaginary = 0.0
        for (index, tap) in taps.enumerated() {
            real += tap * cos(omega * Double(index))
            imaginary -= tap * sin(omega * Double(index))
        }
        return Complex(real, imaginary)
    }

    /// `|H|` at `points / 2 + 1` frequencies from 0 Hz to the Nyquist frequency: a transform
    /// of the taps padded to at least `oversampling` points per tap.
    static func magnitudes(_ taps: [Double], oversampling: Int = 64) -> [Double] {
        var points = 1_024
        while points < oversampling * taps.count { points *= 2 }
        let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(points), .FORWARD)!
        defer { vDSP_DFT_DestroySetupD(setup) }
        var real = taps + [Double](repeating: 0, count: points - taps.count)
        var imaginary = [Double](repeating: 0, count: points)
        var outReal = [Double](repeating: 0, count: points)
        var outImaginary = [Double](repeating: 0, count: points)
        vDSP_DFT_ExecuteD(setup, &real, &imaginary, &outReal, &outImaginary)
        return (0 ... points / 2).map { (outReal[$0] * outReal[$0] + outImaginary[$0] * outImaginary[$0]).squareRoot() }
    }

    /// The greatest and the least `|H|` between two frequencies in hertz, the edges included.
    static func extremes(_ taps: [Double], from lower: Double, to upper: Double, sampleRate: Double, grid: [Double]) -> (least: Double, greatest: Double) {
        var values = [response(taps, at: lower, sampleRate: sampleRate).magnitude, response(taps, at: upper, sampleRate: sampleRate).magnitude]
        let bins = grid.count - 1
        let nyquist = sampleRate / 2
        let first = Int((lower / nyquist * Double(bins)).rounded(.up)), last = Int((upper / nyquist * Double(bins)).rounded(.down))
        if first <= last { values += grid[max(first, 0) ... min(last, bins)] }
        return (values.min()!, values.max()!)
    }

    /// `y[n] = Σ taps[k]·x[n − k]` with silence before the signal: what a kernel computes, in
    /// double precision.
    static func convolved(_ input: [Float], _ taps: [Double]) -> [Double] {
        var output = [Double](repeating: 0, count: input.count)
        for n in input.indices {
            var sum = 0.0
            for (k, tap) in taps.enumerated() where n - k >= 0 { sum += tap * Double(input[n - k]) }
            output[n] = sum
        }
        return output
    }
}

/// The recurrence of a biquad cascade in double precision: the reference a filter stage is
/// held against.
func cascadeReference(_ input: [Float], _ sections: SecondOrderSections) -> [Double] {
    var signal = input.map(Double.init)
    for section in sections.sections {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in signal.indices {
            let x = signal[index]
            let y = section.b0 * x + section.b1 * x1 + section.b2 * x2 - section.a1 * y1 - section.a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            signal[index] = y
        }
    }
    return signal
}

/// The largest deviation of `actual` from `expected`, in decibels relative to the peak of
/// `expected`; −∞ for equal sequences.
func deviationInDecibels<A: Collection, E: Collection>(_ actual: A, _ expected: E) -> Double
where A.Element: BinaryFloatingPoint, E.Element: BinaryFloatingPoint {
    var peak = 0.0, worst = 0.0
    for (a, e) in zip(actual, expected) {
        peak = max(peak, abs(Double(e)))
        worst = max(worst, abs(Double(a) - Double(e)))
    }
    guard peak > 0, worst > 0 else { return worst == 0 ? -.infinity : .infinity }
    return 20 * log10(worst / peak)
}

/// The gain of a system at one frequency, measured on its output for a sine: the amplitude
/// of the component at that frequency once the system has settled, by correlation with a
/// quadrature pair over a whole number of periods.
func measuredGain(of output: [Float], frequency: Double, sampleRate: Double, skipping settle: Int) -> Double {
    // A whole number of periods: the frequencies of the tests divide the window.
    let period = sampleRate / frequency
    let available = output.count - settle
    let periods = max((Double(available) / period).rounded(.down), 1)
    let count = Int((periods * period).rounded())
    var inPhase = 0.0, quadrature = 0.0
    for index in 0 ..< min(count, available) {
        let phase = 2 * Double.pi * frequency * Double(settle + index) / sampleRate
        inPhase += Double(output[settle + index]) * sin(phase)
        quadrature += Double(output[settle + index]) * cos(phase)
    }
    return 2 * (inPhase * inPhase + quadrature * quadrature).squareRoot() / Double(min(count, available))
}

extension DSPError {
    /// The reason an `invalidParameter` error gives.
    var invalidParameterReason: String? {
        if case .invalidParameter(_, _, let reason) = self { return reason }
        return nil
    }

    var unstableRadius: Double? {
        if case .unstableDesign(let radius, _) = self { return radius }
        return nil
    }

    var isCancelled: Bool { self == .cancelled }
}

/// The error a throwing asynchronous expression raises, for tests that inspect it.
func thrownErrorAsync(_ body: () async throws -> Void) async -> DSPError? {
    do {
        try await body()
        return nil
    } catch let error as DSPError {
        return error
    } catch {
        return nil
    }
}
