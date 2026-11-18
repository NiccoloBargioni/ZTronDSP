import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// The equaliser sections of §6.3.5: a band-boost (peaking) filter of any order and the two
/// second-order shelves. Every one is a digital design with a gain of 0 dB away from the
/// band or the shelf, so equalisers cascade without changing the overall level.
///
/// - **Band-boost, order 1:** the peaking section of the Audio EQ Cookbook
///   (Bristow-Johnson).
/// - **Band-boost, order N:** the maximally flat (Butterworth-type) design of Orfanidis,
///   "High-Order Digital Parametric Equalizer Design", JAES 53(11), 2005. An analog
///   low-pass shelf of order N is mapped onto the band by
///   `s → (z² − 2·cos ω₀·z + 1) / (z² − 1)`. The mapping is applied to the *zeros and poles*
///   of the shelf, and the 2N roots that result are paired into N biquads; the fourth-order
///   sections of the paper are never formed from their closed-form coefficients, which lose
///   accuracy for narrow, low bands (`Docs/Numerics/band-boost.md`).
/// - **Shelves:** the Cookbook's second-order low and high shelf.
///
/// In all of them a negative gain in decibels cuts, and the cut is the exact inverse of the
/// boost with the same centre, bandwidth and order.
///
/// An immutable value, usable on any thread. Designing allocates: control or background
/// context.
public struct EqualizerDesign: Hashable, Sendable {
    /// The design as zeros, poles and gain in the `z` plane. Usable on any thread.
    public let zeroPoleGain: ZeroPoleGain
    /// The cascade the run-time kernel takes. Usable on any thread.
    public let secondOrderSections: SecondOrderSections

    /// The highest band-boost order that is designed. Usable on any thread.
    public static let maximumOrder = 64

    // MARK: Band-boost

    /// A band-boost filter: gain `gain` at `center`, 0 dB at 0 Hz and at the Nyquist
    /// frequency, monotonic on each side of the centre.
    /// Control or background context; allocates.
    ///
    /// - Parameters:
    ///   - center: The centre frequency in hertz, strictly between 0 and half the sample
    ///     rate.
    ///   - gain: The gain at the centre. Negative decibels (a factor below 1) cut.
    ///   - bandwidth: The distance between the two frequencies at which the gain is half
    ///     `gain` in decibels; see ``Bandwidth``.
    ///   - order: 1 is the Cookbook's second-order peaking section. N > 1 is the maximally
    ///     flat design of order N: a flatter top and skirts of N·6.02 dB per octave, run as
    ///     N biquads.
    ///   - sampleRate: In hertz.
    /// - Throws: `DSPError.invalidParameter` when a frequency, the gain, the bandwidth, the
    ///   order or the sample rate is out of range, or when the band's upper half-gain
    ///   frequency would reach 0.49 of the sample rate.
    public static func bandBoost(
        center: Double, gain: Amplification, bandwidth: Bandwidth, order: Int = 1, sampleRate: Double
    ) throws(DSPError) -> EqualizerDesign {
        guard order >= 1, order <= maximumOrder else {
            throw .invalidParameter(stage: .none, parameter: "order", reason: "a band-boost order must lie in 1 … \(maximumOrder), not \(order)")
        }
        let factor = try linearGain(gain)
        let angle = try angularFrequency(center, sampleRate: sampleRate, parameter: "center")
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfWidthTangent = try bandEdgeTangent(bandwidth, center: center, angle: angle, sampleRate: sampleRate)

        // The analog low-pass shelf: N poles on a circle of radius β and N zeros on one of
        // radius g·β, at the Butterworth angles, with g = G^(1/N) and β = Ω_B / √g. With the
        // band edges at half the gain in decibels, the cut is the exact inverse of the boost.
        let perOrderGain = pow(factor, 1 / Double(order))
        let poleRadius = halfWidthTangent / perOrderGain.squareRoot()
        let zeroRadius = perOrderGain * poleRadius

        var zeros: [Complex] = []
        var poles: [Complex] = []
        var scale = 1.0
        for index in 1 ... max(1, order / 2) where order >= 2 {
            let phi = Double(2 * index - 1) * Double.pi / Double(2 * order)
            let direction = Complex(-sin(phi), cos(phi))
            let analogZero = direction * zeroRadius
            let analogPole = direction * poleRadius
            for root in bandImages(of: analogZero, cosine: cosine, sine: sine) { zeros += [root, root.conjugate] }
            for root in bandImages(of: analogPole, cosine: cosine, sine: sine) { poles += [root, root.conjugate] }
            scale *= (Complex.one - analogZero).squaredMagnitude / (Complex.one - analogPole).squaredMagnitude
        }
        if order % 2 == 1 {
            zeros += bandImages(of: Complex(-zeroRadius), cosine: cosine, sine: sine)
            poles += bandImages(of: Complex(-poleRadius), cosine: cosine, sine: sine)
            scale *= (1 + zeroRadius) / (1 + poleRadius)
        }
        let system = ZeroPoleGain(zeros: zeros, poles: poles, gain: scale, domain: .digital)
        guard system.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "gain", reason: "the band cannot be represented in double precision for these values")
        }

        if order == 1 {
            // The Cookbook's peaking section, with α = tan(Δω/2) and A = √G.
            let amplitude = factor.squareRoot()
            let alpha = halfWidthTangent
            let a0 = 1 + alpha / amplitude
            let section = SecondOrderSections.Section(
                b0: (1 + alpha * amplitude) / a0, b1: -2 * cosine / a0, b2: (1 - alpha * amplitude) / a0,
                a1: -2 * cosine / a0, a2: (1 - alpha / amplitude) / a0)
            return EqualizerDesign(zeroPoleGain: system, secondOrderSections: SecondOrderSections(sections: [section]))
        }
        return EqualizerDesign(zeroPoleGain: system, secondOrderSections: try system.secondOrderSections())
    }

    /// A band-boost filter whose order is given as the roll-off of its skirts (§6.3.4):
    /// N·6.02 dB per octave for order N, with the remarks that apply to a digital band-pass.
    /// Control or background context; allocates.
    ///
    /// - Throws: what `RollOff.order(rounding:)` throws for a slope that is not a whole
    ///   number of orders under `rounding`, and what the initialiser by order throws.
    public static func bandBoost(
        center: Double, gain: Amplification, bandwidth: Bandwidth, rollOff: RollOff,
        rounding: RollOffRounding = .exact(), sampleRate: Double
    ) throws(DSPError) -> EqualizerDesign {
        try bandBoost(center: center, gain: gain, bandwidth: bandwidth, order: try rollOff.order(rounding: rounding), sampleRate: sampleRate)
    }

    // MARK: Shelves

    /// The Cookbook's second-order low shelf: gain `gain` at 0 Hz, 0 dB at the Nyquist
    /// frequency, and half the gain in decibels at `midpoint`.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the midpoint, the gain, the slope or the
    ///   sample rate is out of range.
    public static func lowShelf(
        midpoint: Double, gain: Amplification, slope: ShelfSlope = .slope(1), sampleRate: Double
    ) throws(DSPError) -> EqualizerDesign {
        try shelf(midpoint: midpoint, gain: gain, slope: slope, sampleRate: sampleRate, high: false)
    }

    /// The Cookbook's second-order high shelf: gain `gain` at the Nyquist frequency, 0 dB
    /// at 0 Hz, and half the gain in decibels at `midpoint`.
    /// Control or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` when the midpoint, the gain, the slope or the
    ///   sample rate is out of range.
    public static func highShelf(
        midpoint: Double, gain: Amplification, slope: ShelfSlope = .slope(1), sampleRate: Double
    ) throws(DSPError) -> EqualizerDesign {
        try shelf(midpoint: midpoint, gain: gain, slope: slope, sampleRate: sampleRate, high: true)
    }

    private static func shelf(
        midpoint: Double, gain: Amplification, slope: ShelfSlope, sampleRate: Double, high: Bool
    ) throws(DSPError) -> EqualizerDesign {
        let amplitude = try linearGain(gain).squareRoot()   // A = √G = 10^(dB/40)
        let angle = try angularFrequency(midpoint, sampleRate: sampleRate, parameter: "midpoint")
        let cosine = cos(angle)
        let alpha: Double
        switch slope {
        case .slope(let s):
            let radicand = s.isFinite && s > 0 ? (amplitude + 1 / amplitude) * (1 / s - 1) + 2 : -1
            guard radicand >= 0 else {
                throw .invalidParameter(stage: .none, parameter: "slope", reason: "a shelf slope of \(s) is not positive, or too steep for this gain")
            }
            alpha = sin(angle) / 2 * radicand.squareRoot()
        case .q(let q):
            guard q.isFinite, q > 0 else {
                throw .invalidParameter(stage: .none, parameter: "slope", reason: "a quality factor must be positive and finite, not \(q)")
            }
            alpha = sin(angle) / (2 * q)
        }
        let edge = 2 * amplitude.squareRoot() * alpha
        // The high shelf is the low shelf with the sign of every cosine term reversed.
        let sign: Double = high ? -1 : 1
        let b0 = amplitude * ((amplitude + 1) - sign * (amplitude - 1) * cosine + edge)
        let b1 = sign * 2 * amplitude * ((amplitude - 1) - sign * (amplitude + 1) * cosine)
        let b2 = amplitude * ((amplitude + 1) - sign * (amplitude - 1) * cosine - edge)
        let a0 = (amplitude + 1) + sign * (amplitude - 1) * cosine + edge
        let a1 = -sign * 2 * ((amplitude - 1) + sign * (amplitude + 1) * cosine)
        let a2 = (amplitude + 1) + sign * (amplitude - 1) * cosine - edge
        let section = SecondOrderSections.Section(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        let sections = SecondOrderSections(sections: [section])
        return EqualizerDesign(zeroPoleGain: sections.zeroPoleGain(), secondOrderSections: sections)
    }

    // MARK: Internals

    private init(zeroPoleGain: ZeroPoleGain, secondOrderSections: SecondOrderSections) {
        self.zeroPoleGain = zeroPoleGain
        self.secondOrderSections = secondOrderSections
    }

    private static func linearGain(_ gain: Amplification) throws(DSPError) -> Double {
        let factor = gain.linear
        guard factor.isFinite, factor > 0 else {
            throw .invalidParameter(stage: .none, parameter: "gain", reason: "an equaliser gain must be a positive, finite factor (any finite number of decibels), not \(gain)")
        }
        return factor
    }

    /// `2π·f/fs`, for a frequency strictly inside 0 … fs/2.
    private static func angularFrequency(_ hertz: Double, sampleRate: Double, parameter: String) throws(DSPError) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate must be positive and finite, not \(sampleRate)")
        }
        guard hertz.isFinite, hertz > 0, hertz < sampleRate / 2 else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "\(hertz) Hz does not lie strictly between 0 Hz and the Nyquist frequency, \(sampleRate / 2) Hz")
        }
        return 2 * Double.pi * hertz / sampleRate
    }

    /// `Ω_B = tan(Δω/2)`, where Δω is the band's width in radians per sample, after the
    /// check that the band stays below 0.49·fs.
    private static func bandEdgeTangent(_ bandwidth: Bandwidth, center: Double, angle: Double, sampleRate: Double) throws(DSPError) -> Double {
        let tangent: Double
        switch bandwidth {
        case .hertz(let width):
            tangent = try tangentOfHalfWidth(hertz: width, sampleRate: sampleRate, stated: "\(width) Hz")
        case .octaves(let octaves):
            guard octaves.isFinite, octaves > 0 else {
                throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "a bandwidth must be positive and finite, not \(octaves) octaves")
            }
            let width = center * (pow(2, octaves / 2) - pow(2, -octaves / 2))
            tangent = try tangentOfHalfWidth(hertz: width, sampleRate: sampleRate, stated: "\(octaves) octaves")
        case .q(let q):
            guard q.isFinite, q > 0 else {
                throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "a quality factor must be positive and finite, not \(q)")
            }
            tangent = sin(angle) / (2 * q)
        }
        // The upper half-gain frequency: ω₂ = Δω/2 + acos(cos ω₀ · cos(Δω/2)).
        let halfWidth = atan(tangent)
        let upper = halfWidth + acos(cos(angle) * cos(halfWidth))
        guard tangent > 0, upper < 0.98 * Double.pi else {
            let upperHertz = upper / (2 * Double.pi) * sampleRate
            throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "the band's upper half-gain frequency would be \(upperHertz) Hz, at or beyond 0.49 of the sample rate (\(0.49 * sampleRate) Hz): narrow the band or lower its centre")
        }
        return tangent
    }

    private static func tangentOfHalfWidth(hertz width: Double, sampleRate: Double, stated: String) throws(DSPError) -> Double {
        guard width.isFinite, width > 0, width < sampleRate / 2 else {
            throw .invalidParameter(stage: .none, parameter: "bandwidth", reason: "a bandwidth of \(stated) is not positive, or is as wide as the whole band up to the Nyquist frequency")
        }
        return tan(Double.pi * width / sampleRate)
    }

    /// The two images in the `z` plane of one root `a` of the analog shelf under
    /// `s = (z² − 2·cos ω₀·z + 1) / (z² − 1)`: the roots of
    /// `(1 − a)·z² − 2·cos ω₀·z + (1 + a) = 0`,
    ///
    ///     z = (cos ω₀ ± √(a² − sin²ω₀)) / (1 − a).
    ///
    /// The radicand uses `sin ω₀` itself, not `cos²ω₀ − 1`, which would cancel for a low
    /// centre.
    private static func bandImages(of root: Complex, cosine: Double, sine: Double) -> [Complex] {
        let radical = Complex.sqrt(root * root - sine * sine)
        let denominator = Complex.one - root
        return [(cosine + radical) / denominator, (cosine - radical) / denominator]
    }
}
