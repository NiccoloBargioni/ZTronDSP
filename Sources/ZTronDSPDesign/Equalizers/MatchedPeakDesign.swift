import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// A matched second-order peak (§6.3.5, WP-422): the peaking section that follows its analog
/// prototype up to the Nyquist frequency (Vicanek, "Matched Second Order Digital Filters",
/// 2016).
///
/// The Cookbook's peak is the bilinear transform of the analog one, so its gain is forced to
/// 0 dB at the Nyquist frequency and a band that sits close to it is squeezed. Here the poles
/// are those of the analog peak mapped by `z = e^{sT}`, and the numerator is fitted so that
/// the magnitude is exact at three places: 0 dB at 0 Hz, the requested gain at the centre,
/// and a slope of zero there, so that the peak is where it was asked for. The gain at the
/// Nyquist frequency is then what the analog peak has there, not 0 dB.
///
/// **Bandwidth** is measured between the two frequencies at which the gain is half the
/// requested gain in decibels, as for every equaliser of the package. `.hertz(w)` and
/// `.octaves(b)` are met exactly on the digital axis: the quality factor of the prototype is
/// adjusted until the distance between the two frequencies, which is known in closed form,
/// is the one asked for. `.q(Q)` is the quality factor of the analog prototype itself, whose
/// band is `f₀ / Q` wide. A band whose upper half-gain frequency would reach 0.49 of the
/// sample rate is rejected.
///
/// A negative gain in decibels cuts, and the cut is the exact inverse of the boost: the
/// numerator of a matched boost has its zeros inside the unit circle.
///
/// **Numerics.** The three conditions have a closed form: with `x = sin²(ω/2)` and `D` the
/// squared magnitude of the denominator, `|H|² = G² − (G² − 1)·(D(0)/D(x))·((x − x₀)/x₀)²`.
/// Everything is computed from it in factored form (`x − x₀` as a product of two sines, `D`
/// as a product over the poles, the zeros from their distance to `z = 1`), never from
/// expanded coefficients, whose sums cancel for a narrow band at a low centre. The zeros,
/// poles and gain are therefore exact to rounding down to bands a fraction of a hertz wide at
/// 20 Hz, where `zeroPoleGain` is the form to read; the coefficients of the one section
/// carry what a second-order section can.
///
/// An immutable value, usable on any thread. Designing allocates: control or background
/// context.
public struct MatchedPeakDesign: Hashable, Sendable {
    /// The design as zeros, poles and gain in the `z` plane. Usable on any thread.
    public let zeroPoleGain: ZeroPoleGain
    /// The one section the run-time kernel takes. Usable on any thread.
    public let secondOrderSections: SecondOrderSections

    /// A matched peak: gain `gain` at `center`, 0 dB at 0 Hz, monotonic on each side of the
    /// centre. Control or background context; allocates.
    ///
    /// - Parameters:
    ///   - center: The centre frequency in hertz, strictly between 0 and half the sample
    ///     rate.
    ///   - gain: The gain at the centre. Negative decibels (a factor below 1) cut.
    ///   - bandwidth: See the type's description.
    ///   - sampleRate: In hertz.
    /// - Throws: `DSPError.invalidParameter` when the centre, the gain, the bandwidth or the
    ///   sample rate is out of range, when the band cannot be closed below 0.49 of the
    ///   sample rate, and when no matched section exists for the values (a band so wide and
    ///   so close to the Nyquist frequency that the fitted numerator has no real
    ///   coefficients).
    public init(center: Double, gain: Amplification, bandwidth: Bandwidth, sampleRate: Double) throws(DSPError) {
        try IIRDesign.validate(sampleRate: sampleRate)
        guard center.isFinite, center > 0, center < sampleRate / 2 else {
            throw .invalidParameter(stage: .none, parameter: "center", reason: "\(center) Hz does not lie strictly between 0 Hz and the Nyquist frequency, \(sampleRate / 2) Hz")
        }
        let factor = gain.linear
        guard factor.isFinite, factor > 0 else {
            throw .invalidParameter(stage: .none, parameter: "gain", reason: "an equaliser gain must be a positive, finite factor (any finite number of decibels), not \(gain)")
        }
        let boost = max(factor, 1 / factor)
        let angle = 2 * Double.pi * center / sampleRate
        guard boost > 1 else {
            // 0 dB: nothing to do, whatever the band.
            _ = try Self.prototypeQuality(bandwidth, center: center, sampleRate: sampleRate)
            let section = SecondOrderSections(sections: [.identity])
            zeroPoleGain = ZeroPoleGain(zeros: [], poles: [], gain: 1, domain: .digital)
            secondOrderSections = section
            return
        }
        // The pole quality factor of the analog boost s² + (A/Q)·s + 1 over s² + s/(A·Q) + 1,
        // with A the square root of the gain: A·Q.
        let amplitude = boost.squareRoot()
        let quality = try Self.prototypeQuality(bandwidth, center: center, sampleRate: sampleRate)
        let fitted: Fit
        switch bandwidth {
        case .q:
            guard let fit = Fit(angle: angle, gain: boost, poleQuality: amplitude * quality) else {
                throw Self.noSection(bandwidth)
            }
            fitted = fit
        case .hertz, .octaves:
            // The width wanted, in radians per sample; the width falls as the quality rises.
            let target = angle / quality
            let start = log(amplitude * quality)
            var low = start - 4, high = start + 4
            for _ in 0 ..< 200 {
                let middle = (low + high) / 2
                if let width = Fit(angle: angle, gain: boost, poleQuality: exp(middle))?.halfGainWidth, width <= target {
                    high = middle
                } else {
                    low = middle
                }
            }
            guard let fit = Fit(angle: angle, gain: boost, poleQuality: exp(high)) else { throw Self.noSection(bandwidth) }
            guard let width = fit.halfGainWidth, abs(width - target) <= 1e-9 * target else {
                // The band does not close below the Nyquist frequency, or no quality gives it.
                let upper = (angle + (fit.upperOffset ?? (Double.pi - angle))) / (2 * Double.pi) * sampleRate
                if fit.upperOffset == nil || upper >= 0.49 * sampleRate { throw Self.beyondLimit(upper, sampleRate: sampleRate) }
                throw Self.noSection(bandwidth)
            }
            fitted = fit
        }
        guard let upperOffset = fitted.upperOffset, angle + upperOffset < 0.98 * Double.pi else {
            throw Self.beyondLimit((angle + (fitted.upperOffset ?? (Double.pi - angle))) / (2 * Double.pi) * sampleRate, sampleRate: sampleRate)
        }
        guard fitted.gain.isFinite, fitted.gain > 0, (fitted.zeros + fitted.poles).allSatisfy(\.isFinite) else {
            throw Self.noSection(bandwidth)
        }
        // A cut is the boost upside down: its zeros are the boost's poles.
        let system = factor >= 1
            ? ZeroPoleGain(zeros: fitted.zeros, poles: fitted.poles, gain: fitted.gain, domain: .digital)
            : ZeroPoleGain(zeros: fitted.poles, poles: fitted.zeros, gain: 1 / fitted.gain, domain: .digital)
        func quadratic(_ roots: [Complex]) -> (Double, Double) {
            (-(roots[0] + roots[1]).real, (roots[0] * roots[1]).real)
        }
        let numerator = quadratic(system.zeros), denominator = quadratic(system.poles)
        zeroPoleGain = system
        secondOrderSections = SecondOrderSections(sections: [
            .init(b0: system.gain, b1: system.gain * numerator.0, b2: system.gain * numerator.1, a1: denominator.0, a2: denominator.1),
        ])
    }

    private static func beyondLimit(_ upper: Double, sampleRate: Double) -> DSPError {
        .invalidParameter(stage: .none, parameter: "bandwidth", reason: "the band's upper half-gain frequency would be \(upper) Hz, at or beyond 0.49 of the sample rate (\(0.49 * sampleRate) Hz): narrow the band or lower its centre")
    }

    private static func noSection(_ bandwidth: Bandwidth) -> DSPError {
        .invalidParameter(stage: .none, parameter: "bandwidth", reason: "no matched section exists for a band of \(bandwidth) at this centre and gain: the band is too wide for where it sits; narrow it or lower its centre")
    }

    /// The quality factor of the analog prototype whose band has the width asked for:
    /// `f₀ / w`.
    private static func prototypeQuality(_ bandwidth: Bandwidth, center: Double, sampleRate: Double) throws(DSPError) -> Double {
        let quality: Double
        switch bandwidth {
        case .hertz(let width):
            guard width.isFinite, width > 0 else {
                throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "a bandwidth must be positive and finite, not \(width) Hz")
            }
            quality = center / width
        case .octaves(let octaves):
            guard octaves.isFinite, octaves > 0 else {
                throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "a bandwidth must be positive and finite, not \(octaves) octaves")
            }
            quality = 1 / (pow(2, octaves / 2) - pow(2, -octaves / 2))
        case .q(let q):
            guard q.isFinite, q > 0 else {
                throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "a quality factor must be positive and finite, not \(q)")
            }
            quality = q
        }
        guard quality.isFinite, quality > 0 else {
            throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "the band is too wide or too narrow to design for")
        }
        return quality
    }

    /// One matched boost of pole quality `poleQuality`: its poles, its zeros, its gain and
    /// its two half-gain frequencies, all from factored forms.
    ///
    /// With `x = sin²(ω/2)` the squared magnitude of a biquad is a ratio of two quadratics in
    /// `x`, `N(x) / D(x)`. The three conditions (0 dB at 0 Hz, the gain `G` at the centre
    /// `x₀`, a slope of zero there) leave `N(x) = G²·D(x) − (G² − 1)·D(0)·((x − x₀)/x₀)²`.
    private struct Fit {
        let poles: [Complex]
        let zeros: [Complex]
        /// The leading coefficient of the numerator.
        let gain: Double
        /// How far below the centre the gain is half the gain in decibels, in radians per sample.
        let lowerOffset: Double
        /// How far above; `nil` when the gain is still above half at the Nyquist frequency.
        let upperOffset: Double?

        var halfGainWidth: Double? { upperOffset.map { $0 + lowerOffset } }

        init?(angle: Double, gain: Double, poleQuality: Double) {
            guard poleQuality.isFinite, poleQuality > 0, gain > 1 else { return nil }
            // The poles of s² + s/Q + 1 at the angular frequency of the centre, mapped by
            // z = e^{sT}: radius e^{−ω₀/2Q}, angle ω₀·√(1 − 1/4Q²); two real poles below Q = ½.
            let decay = angle / (2 * poleQuality)
            let centre = sin(angle / 2) * sin(angle / 2)                    // x₀
            let denominator: (Double) -> Double                           // D at ω₀ + d
            let atZero: Double                                             // D(0)
            let atCentre: Double                                           // D(x₀)
            let slope: Double                                              // dD/dx at x₀
            let curvature: Double                                          // the coefficient of x² in D
            if poleQuality > 0.5 {
                let root = (1 - 1 / (4 * poleQuality * poleQuality)).squareRoot()
                let radius = exp(-decay), gap = -expm1(-decay)             // r and 1 − r
                let theta = angle * root
                let detune = angle * (1 / (4 * poleQuality * poleQuality)) / (1 + root)     // ω₀ − θ, without the subtraction
                poles = [Complex(magnitude: radius, phase: theta), Complex(magnitude: radius, phase: -theta)]
                // |e^{jω} − r·e^{±jθ}|² = (1 − r)² + 4·r·sin²((ω ∓ θ)/2).
                denominator = { offset in
                    let near = sin((offset + detune) / 2), far = sin(angle + (offset - detune) / 2)
                    return (gap * gap + 4 * radius * near * near) * (gap * gap + 4 * radius * far * far)
                }
                let half = sin(theta / 2)
                atZero = (gap * gap + 4 * radius * half * half) * (gap * gap + 4 * radius * half * half)
                let near = sin(detune / 2), far = sin(angle - detune / 2)
                let nearFactor = gap * gap + 4 * radius * near * near, farFactor = gap * gap + 4 * radius * far * far
                atCentre = nearFactor * farFactor
                slope = 4 * radius * (sin(detune) * farFactor + sin(2 * angle - detune) * nearFactor) / sin(angle)
                curvature = 16 * radius * radius
            } else {
                let spread = angle * (1 / (4 * poleQuality * poleQuality) - 1).squareRoot()
                let first = exp(-decay + spread), second = exp(-decay - spread)
                let firstGap = expm1(-decay + spread) * expm1(-decay + spread), secondGap = expm1(-decay - spread) * expm1(-decay - spread)
                poles = [Complex(first), Complex(second)]
                denominator = { offset in
                    let x = sin((angle + offset) / 2) * sin((angle + offset) / 2)
                    return (firstGap + 4 * first * x) * (secondGap + 4 * second * x)
                }
                atZero = firstGap * secondGap
                atCentre = (firstGap + 4 * first * centre) * (secondGap + 4 * second * centre)
                slope = 4 * first * (secondGap + 4 * second * centre) + 4 * second * (firstGap + 4 * first * centre)
                curvature = 16 * first * second
            }
            guard atZero > 0, atZero.isFinite, centre > 0 else { return nil }

            // Half the gain in decibels: |H|² = G, where D(x) = ((G + 1)/G)·D(0)·((x − x₀)/x₀)²,
            // and x − x₀ = sin((ω − ω₀)/2)·sin((ω + ω₀)/2).
            let level = (gain + 1) / gain * atZero / (centre * centre)
            func excess(_ offset: Double) -> Double {
                let distance = sin(offset / 2) * sin(angle + offset / 2)
                return denominator(offset) - level * distance * distance
            }
            /// The offset between `inside` (where the gain is above half) and `outside`.
            func crossing(inside: Double, outside: Double) -> Double {
                var inside = inside, outside = outside
                for _ in 0 ..< 200 {
                    let middle = (inside + outside) / 2
                    if middle == inside || middle == outside { break }
                    if excess(middle) > 0 { inside = middle } else { outside = middle }
                }
                return (inside + outside) / 2
            }
            lowerOffset = -crossing(inside: 0, outside: -angle)
            upperOffset = excess(Double.pi - angle) < 0 ? crossing(inside: 0, outside: Double.pi - angle) : nil

            // The zeros: the roots of N in y = x − x₀, n₂·y² + n₁·y + n₀, taken to the z plane
            // by x = sin²(ω/2), that is z + 1/z = 2 − 4·x, as their distance ζ = z − 1 to z = 1.
            let square = gain * gain
            let n2 = square * curvature - (square - 1) * atZero / (centre * centre)
            let n1 = square * slope, n0 = square * atCentre
            guard n2 != 0, n2.isFinite else { return nil }
            let discriminant = n1 * n1 - 4 * n2 * n0
            let roots: [Complex]
            if discriminant < 0 {
                let root = Complex(-n1 / (2 * n2), (-discriminant).squareRoot() / (2 * n2))
                roots = [root, root.conjugate]
            } else {
                let q = -(n1 + (n1 >= 0 ? 1 : -1) * discriminant.squareRoot()) / 2
                guard q != 0 else { return nil }
                roots = [Complex(q / n2), Complex(n0 / q)]
            }
            var distances: [Complex] = []
            for root in roots {
                let x = root + centre
                let base = -2 * x
                var turn = 2 * (Complex.i * Complex.sqrt(x * (1 - x)))
                // Of the two solutions z and 1/z, first the one whose terms do not cancel…
                if (base.conjugate * turn).real < 0 { turn = -turn }
                var distance = base + turn
                // … then the one inside the unit circle: |z|² − 1 = 2·Re ζ + |ζ|².
                if 2 * distance.real + distance.squaredMagnitude >= 0 { distance = -distance / (1 + distance) }
                guard 2 * distance.real + distance.squaredMagnitude < 0, distance.isFinite else { return nil }
                distances.append(distance)
            }
            if discriminant < 0 { distances[1] = distances[0].conjugate }
            zeros = distances.map { 1 + $0 }
            // 0 dB at 0 Hz: b₀·|1 − z₁|·|1 − z₂| = |1 − p₁|·|1 − p₂|.
            self.gain = atZero.squareRoot() / (distances[0].magnitude * distances[1].magnitude)
        }
    }
}
