import ZTronDSPCore

/// A linear time-invariant system as a cascade of second-order sections: the only form an
/// IIR system is ever run in (REAL-1).
///
/// A digital section is the five numbers the run-time kernel takes, with `a₀ = 1`:
///
///     H(z) = (b0 + b1·z⁻¹ + b2·z⁻²) / (1 + a1·z⁻¹ + a2·z⁻²)
///     y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]
///
/// An analog cascade reads the same five numbers as
/// `(b0·s² + b1·s + b2) / (s² + a1·s + a2)`. It can be written down and analysed, but a
/// zero-pole-gain system is converted to sections only when it is digital: an analog system
/// of odd order has a first-order factor, which a section with `a₀ = 1` cannot hold.
///
/// Zeros, poles and gain are read from each section in closed form; no polynomial is
/// expanded and no root finder runs (§6.3.8). A section always has two poles; a zero and a
/// pole at the origin, which the pairing adds to fill a section, cancel when the cascade is
/// read. An immutable value, usable on any thread.
public struct SecondOrderSections: LTISystem, Hashable, Sendable {
    /// One second-order section. An immutable value, usable on any thread.
    public struct Section: Hashable, Sendable {
        /// The numerator coefficient of `x[n]` (of `s²` for an analog section). Usable on any
        /// thread.
        public let b0: Double
        /// The numerator coefficient of `x[n − 1]` (of `s`). Usable on any thread.
        public let b1: Double
        /// The numerator coefficient of `x[n − 2]` (the constant term). Usable on any thread.
        public let b2: Double
        /// The denominator coefficient of `y[n − 1]` (of `s`), with `a0 = 1`. Usable on any thread.
        public let a1: Double
        /// The denominator coefficient of `y[n − 2]` (the constant term), with `a0 = 1`. Usable
        /// on any thread.
        public let a2: Double

        /// Usable on any thread.
        public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        /// The section that passes a signal unchanged. Usable on any thread.
        public static let identity = Section(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

        /// `[b0, b1, b2, a1, a2]`. Usable on any thread; allocates.
        public var coefficients: [Double] { [b0, b1, b2, a1, a2] }

        /// The section's zeros, poles and gain in closed form: the roots of
        /// `b0·x² + b1·x + b2` and of `x² + a1·x + a2`, and the first non-zero numerator
        /// coefficient. Roots at the origin are reported as they are; the cascade cancels them.
        func roots() -> (zeros: [Complex], poles: [Complex], gain: Double) {
            let gain = b0 != 0 ? b0 : (b1 != 0 ? b1 : b2)
            return (QuadraticRoots.roots(b0, b1, b2), QuadraticRoots.roots(1, a1, a2), gain)
        }

        /// For each pole, in the order of ``roots()``, its radius and its real part. A complex
        /// pair has the radius `√a2` and the real part `−a1/2` exactly, so a pair that was
        /// written onto the unit circle (`a2 = 1`) is reported there, not a rounding error to
        /// either side of it.
        func poleExtents() -> [(radius: Double, realPart: Double)] {
            let poles = QuadraticRoots.roots(1, a1, a2)
            if poles[0].imaginary != 0 {
                let extent = (radius: a2.squareRoot(), realPart: -a1 / 2)
                return [extent, extent]
            }
            return poles.map { (radius: abs($0.real), realPart: $0.real) }
        }
    }

    /// The sections, in the order the signal passes through them. Usable on any thread.
    public let sections: [Section]
    /// The plane the sections are written in. Usable on any thread.
    public let domain: SystemDomain

    /// A cascade of the given sections. No sections is the identity. Usable on any thread.
    public init(sections: [Section], domain: SystemDomain = .digital) {
        self.sections = sections
        self.domain = domain
    }

    /// The coefficients of all sections in one list, five per section: `b0 b1 b2 a1 a2`, the
    /// layout the run-time kernels take. Usable on any thread; allocates.
    public var coefficients: [Double] {
        var result: [Double] = []
        result.reserveCapacity(sections.count * 5)
        for section in sections {
            result.append(section.b0)
            result.append(section.b1)
            result.append(section.b2)
            result.append(section.a1)
            result.append(section.a2)
        }
        return result
    }

    // MARK: Roots, in closed form per section

    /// The roots of the whole cascade. A zero and a pole that both sit exactly at the origin
    /// cancel, wherever in the cascade they are: the pairing of an odd order adds one of
    /// each, and they are not part of the system.
    private func cascadeRoots() -> (zeros: [Complex], poles: [Complex], gain: Double, extents: [(radius: Double, realPart: Double)]) {
        var zeros: [Complex] = []
        var poles: [Complex] = []
        var extents: [(radius: Double, realPart: Double)] = []
        var gain = 1.0
        for section in sections {
            let roots = section.roots()
            zeros += roots.zeros
            poles += roots.poles
            extents += section.poleExtents()
            gain *= roots.gain
        }
        var cancelled = min(zeros.filter { $0 == .zero }.count, poles.filter { $0 == .zero }.count)
        while cancelled > 0 {
            if let zero = zeros.firstIndex(of: .zero) { zeros.remove(at: zero) }
            if let pole = poles.firstIndex(of: .zero) {
                poles.remove(at: pole)
                extents.remove(at: pole)
            }
            cancelled -= 1
        }
        return (zeros, poles, gain, extents)
    }

    /// The zeros of the cascade, read from each section in closed form. Zeros at the origin
    /// that are matched by poles at the origin are not reported. Usable on any thread;
    /// allocates.
    public var zeros: [Complex] { cascadeRoots().zeros }

    /// The poles of the cascade, read from each section in closed form. Poles at the origin
    /// that are matched by zeros at the origin are not reported. Usable on any thread;
    /// allocates.
    public var poles: [Complex] { cascadeRoots().poles }

    /// The product of the sections' gains: of the first non-zero numerator coefficient of
    /// each. Usable on any thread.
    public var gain: Double { cascadeRoots().gain }

    /// The zero-pole-gain form, read section by section. Usable on any thread; allocates.
    public func zeroPoleGain() -> ZeroPoleGain {
        let roots = cascadeRoots()
        return ZeroPoleGain(zeros: roots.zeros, poles: roots.poles, gain: roots.gain, domain: domain)
    }

    /// Digital: `1 − max|p|`. Analog: `−max Re p`. Read from the coefficients of each
    /// section in closed form: a complex pole pair has the radius `√a2` and the real part
    /// `−a1/2` exactly. Usable on any thread.
    public var stabilityMargin: Double {
        let extents = cascadeRoots().extents
        switch domain {
        case .digital:
            return 1 - (extents.map(\.radius).max() ?? 0)
        case .analog:
            guard let rightmost = extents.map(\.realPart).max() else { return .greatestFiniteMagnitude }
            return -rightmost
        }
    }

    // MARK: Analysis

    /// The product of the section responses.
    /// Control or background context; allocates.
    public func frequencyResponse(at frequencies: [Double]) throws(DSPError) -> [Complex] {
        try LTIAnalysis.validate(frequencies)
        return frequencies.map { frequency in
            var value = Complex.one
            switch domain {
            case .digital:
                // Polynomials in z⁻¹, as the kernel runs them.
                let delay = Complex(magnitude: 1, phase: -frequency)
                for section in sections {
                    let numerator = (section.b2 * delay + section.b1) * delay + section.b0
                    let denominator = (section.a2 * delay + section.a1) * delay + 1
                    value = value * numerator / denominator
                }
            case .analog:
                let s = Complex(0, frequency)
                for section in sections {
                    let numerator = (section.b0 * s + section.b1) * s + section.b2
                    let denominator = (s + section.a1) * s + section.a2
                    value = value * numerator / denominator
                }
            }
            return LTIAnalysis.reported(value)
        }
    }

    /// The sum of the sections' delays, each in closed form from its coefficients.
    /// Control or background context; allocates.
    public func groupDelay(at frequencies: [Double]) throws(DSPError) -> [Double?] {
        let response = try frequencyResponse(at: frequencies)
        let delays = frequencies.map { frequency -> Double in
            var total = 0.0
            switch domain {
            case .digital:
                // For B(z⁻¹) = Σ bₖ·z⁻ᵏ the delay is Re[Σ k·bₖ·z⁻ᵏ / B].
                let delay = Complex(magnitude: 1, phase: -frequency)
                for section in sections {
                    let numerator = (section.b2 * delay + section.b1) * delay + section.b0
                    let numeratorSlope = (2 * section.b2 * delay + section.b1) * delay
                    let denominator = (section.a2 * delay + section.a1) * delay + 1
                    let denominatorSlope = (2 * section.a2 * delay + section.a1) * delay
                    total += (numeratorSlope / numerator).real - (denominatorSlope / denominator).real
                }
            case .analog:
                // For H = N/D on s = jω the delay is Re[D′/D] − Re[N′/N].
                let s = Complex(0, frequency)
                for section in sections {
                    let numerator = (section.b0 * s + section.b1) * s + section.b2
                    let numeratorSlope = 2 * section.b0 * s + section.b1
                    let denominator = (s + section.a1) * s + section.a2
                    let denominatorSlope = 2 * s + section.a1
                    total += (denominatorSlope / denominator).real - (numeratorSlope / numerator).real
                }
            }
            return total
        }
        return LTIAnalysis.masked(delays, by: response)
    }
}
