import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

/// A way to design an FIR filter: what turns a response and a length into taps (§5.3, §6.3.3).
/// A strategy: pass `.windowedSinc(window:)` or `.leastSquares`, or a conformer of your own,
/// wherever a method is asked for:
///
/// ```swift
/// LowPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255)
/// BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401)
/// ```
///
/// A method supplies one thing: the taps of a filter of a given length. Finding the length
/// that meets a tolerance scheme or a roll-off is the same for every method (``FIRDesign``):
/// the method's estimate is taken, the result is measured, and the length grows until the
/// scheme is met.
///
/// **Edges.** The edges of the response a method is handed are the frequencies at which the
/// amplitude is one half: the middle of each transition band. Both stock methods read them
/// that way, so a filter keeps its edges when the method is exchanged.
///
/// Conformers are immutable values, usable on any thread. Designing allocates: control or
/// background context.
public protocol FIRDesignMethod: Hashable, Sendable {
    /// The taps of a linear-phase filter of `length` taps, lowest delay first.
    /// Control or background context; allocates.
    ///
    /// - Parameters:
    ///   - response: The response and its edges in hertz, each strictly between 0 Hz and half
    ///     the sample rate, a band's edges ascending. An edge is where the amplitude is one
    ///     half.
    ///   - length: The number of taps.
    ///   - transition: The width of each transition band in hertz, centred on its edge, when
    ///     the caller states one. A method that has no use for it ignores it; one that needs
    ///     it rejects `nil`.
    ///   - attenuation: The stop-band attenuation the caller is after, when it states one. A
    ///     method with a parameter to choose (Kaiser's β) chooses it from this.
    ///   - sampleRate: In hertz.
    /// - Throws: `DSPError.invalidParameter` for a length, an edge, a transition or a sample
    ///   rate the method cannot design for.
    func taps(
        _ response: FilterResponse, length: Int, transition: Double?, attenuation: Amplification?, sampleRate: Double
    ) throws(DSPError) -> [Double]

    /// The number of taps at which the method expects to reach `attenuation` with transition
    /// bands `transition` hertz wide: where the search for a length starts. The default is
    /// Kaiser's estimate. Usable on any thread; allocation-free.
    ///
    /// - Throws: `DSPError.invalidParameter` when the values admit no estimate.
    func estimatedLength(transition: Double, attenuation: Amplification, sampleRate: Double) throws(DSPError) -> Int
}

extension FIRDesignMethod {
    /// Kaiser's estimate (Kaiser 1974, as `scipy.signal.kaiserord`). Usable on any thread;
    /// allocation-free.
    public func estimatedLength(transition: Double, attenuation: Amplification, sampleRate: Double) throws(DSPError) -> Int {
        try WindowedSincMethod.kaiserEstimate(attenuation: attenuation, transition: transition, sampleRate: sampleRate).length
    }
}

/// The ideal response truncated by a window (§6.3.3): low-pass, high-pass, band-pass and
/// band-stop filters of linear phase. An edge is where the amplitude is one half; the gain is
/// exactly 1 at 0 Hz (low-pass, band-stop), at the Nyquist frequency (high-pass) or at the
/// middle of the band (band-pass).
///
/// Without a window the method uses a Kaiser window and chooses its β itself, by Kaiser's
/// formula: from the stop-band attenuation when a filter states one (a roll-off or a
/// tolerance scheme), otherwise from the transition width when a filter states that, and
/// otherwise for 80 dB.
///
/// A filter with an even number of taps is zero at the Nyquist frequency, so an even length
/// is rejected for a high-pass and for a band-stop.
///
/// Oracle: `scipy.signal.firwin`. An immutable value, usable on any thread.
public struct WindowedSincMethod: FIRDesignMethod {
    /// The window, or `nil` for a Kaiser window whose β the method chooses. A window is used
    /// in its symmetric form whatever form it was given in. Usable on any thread.
    public let window: Window?

    /// Usable on any thread.
    public init(window: Window? = nil) {
        self.window = window
    }

    /// The attenuation the method designs for when a filter states neither an attenuation nor
    /// a transition width: 80 dB, the rejection of the package's rate changers (§6.12).
    /// Usable on any thread.
    public static let defaultAttenuation = 80.0

    /// The longest filter that is designed. Usable on any thread.
    public static let maximumLength = 1 << 20

    /// The taps: `window[n] · Σ_bands (f₂·sinc(f₂·m) − f₁·sinc(f₁·m))` with `m = n − (K − 1)/2`
    /// and the bands in units of the Nyquist frequency, scaled to unity gain at the reference
    /// frequency of the first pass band. Control or background context; allocates.
    public func taps(
        _ response: FilterResponse, length: Int, transition: Double?, attenuation: Amplification?, sampleRate: Double
    ) throws(DSPError) -> [Double] {
        let edges = try FIRDesign.normalizedEdges(of: response, sampleRate: sampleRate)
        try FIRDesign.validate(length: length)
        let passesNyquist: Bool
        let bands: [(lower: Double, upper: Double)]
        switch response {
        case .lowPass: bands = [(0, edges[0])]; passesNyquist = false
        case .highPass: bands = [(edges[0], 1)]; passesNyquist = true
        case .bandPass: bands = [(edges[0], edges[1])]; passesNyquist = false
        case .bandStop: bands = [(0, edges[0]), (edges[1], 1)]; passesNyquist = true
        }
        guard !passesNyquist || length % 2 == 1 else {
            throw .invalidParameter(stage: .none, parameter: "length", reason: "a \(response.name) filter passes the Nyquist frequency, where a filter with an even number of taps (\(length)) is zero: give it an odd length")
        }

        let shape: Window
        if let window {
            guard !window.isHalf else {
                throw .invalidParameter(stage: .none, parameter: "window", reason: "a half window does not shape a filter: pass the whole window")
            }
            shape = window
        } else {
            let decibels: Double
            if let attenuation {
                decibels = try AnalogPrototype.decibels(attenuation, parameter: "attenuation")
            } else if let transition {
                decibels = Self.kaiserAttenuation(length: length, width: try FIRDesign.normalizedWidth(transition, sampleRate: sampleRate))
            } else {
                decibels = Self.defaultAttenuation
            }
            shape = .kaiser(beta: Self.kaiserBeta(attenuation: decibels))
        }
        let weights = try shape.symmetric.doubleSamples(count: length)

        let centre = Double(length - 1) / 2
        var taps = [Double](repeating: 0, count: length)
        for index in 0 ..< length {
            let m = Double(index) - centre
            var value = 0.0
            for band in bands {
                value += band.upper * Self.sinc(band.upper * m) - band.lower * Self.sinc(band.lower * m)
            }
            taps[index] = value * weights[index]
        }

        // Unity gain where the first pass band has its reference: 0 Hz, the Nyquist frequency,
        // or the middle of the band.
        let first = bands[0]
        let reference = first.lower == 0 ? 0 : (first.upper == 1 ? 1 : (first.lower + first.upper) / 2)
        var gain = 0.0
        for index in 0 ..< length {
            gain += taps[index] * cos(Double.pi * (Double(index) - centre) * reference)
        }
        guard gain.isFinite, gain != 0 else {
            throw .invalidParameter(stage: .none, parameter: "length", reason: "the filter has no gain in its pass band: it is too short for these edges")
        }
        var scaled = taps.map { $0 / gain }
        // The ideal response and the window are symmetric up to the last bit of each; the taps
        // are made symmetric to the bit, so that the phase is linear exactly.
        for index in 0 ..< length / 2 { scaled[length - 1 - index] = scaled[index] }
        return scaled
    }

    /// `sin(πx) / (πx)`, 1 at 0.
    static func sinc(_ x: Double) -> Double {
        if x == 0 { return 1 }
        let argument = Double.pi * x
        return sin(argument) / argument
    }

    // MARK: Kaiser's estimates

    /// Kaiser's β for a stop band `attenuation` decibels down.
    static func kaiserBeta(attenuation: Double) -> Double {
        if attenuation > 50 { return 0.1102 * (attenuation - 8.7) }
        if attenuation > 21 { return 0.5842 * pow(attenuation - 21, 0.4) + 0.07886 * (attenuation - 21) }
        return 0
    }

    /// The attenuation a Kaiser design of `length` taps reaches with a transition band `width`
    /// wide, in units of the Nyquist frequency.
    static func kaiserAttenuation(length: Int, width: Double) -> Double {
        2.285 * Double(length - 1) * Double.pi * width + 7.95
    }

    /// The length and the β of the Kaiser window at which a windowed sinc reaches a stop-band
    /// attenuation with transition bands of a given width (Kaiser 1974):
    /// `K = ⌈(A − 7.95) / (2.285·Δω)⌉ + 1`, and β by Kaiser's piecewise formula. An estimate:
    /// the attenuation it leads to is within a fraction of a decibel of the one asked for, to
    /// either side. Usable on any thread; allocation-free.
    ///
    /// Oracle: `scipy.signal.kaiserord`.
    ///
    /// - Parameters:
    ///   - attenuation: The stop-band attenuation, as a number of decibels of at least 8.
    ///   - transition: The width of the transition band in hertz.
    ///   - sampleRate: In hertz.
    /// - Throws: `DSPError.invalidParameter` for an attenuation below 8 dB, where the formula
    ///   does not hold, and for a width that is not positive or reaches the Nyquist frequency.
    public static func kaiserEstimate(
        attenuation: Amplification, transition: Double, sampleRate: Double
    ) throws(DSPError) -> (length: Int, beta: Double) {
        let decibels = try AnalogPrototype.decibels(attenuation, parameter: "attenuation")
        guard decibels >= 8 else {
            throw .invalidParameter(stage: .none, parameter: "attenuation", reason: "Kaiser's estimate holds from 8 dB of attenuation up, not for \(decibels) dB")
        }
        let width = try FIRDesign.normalizedWidth(transition, sampleRate: sampleRate)
        let length = ((decibels - 7.95) / 2.285 / (Double.pi * width) + 1).rounded(.up)
        guard length <= Double(maximumLength) else {
            throw .unsupportedConfiguration(reason: "a transition band of \(transition) Hz at \(decibels) dB needs about \(Int(min(length, 1e15))) taps, above the longest supported filter of \(maximumLength)")
        }
        return (max(1, Int(length)), kaiserBeta(attenuation: decibels))
    }
}

/// A weighted least-squares fit to the ideal response with linear transition bands (§6.3.3):
/// low-pass, high-pass, band-pass and band-stop filters of linear phase and odd length.
///
/// The target is 1 in the pass bands, 0 in the stop bands, and a straight line across each
/// transition band, which is `transition` hertz wide and centred on its edge, so that the
/// target is one half at the edge. The whole axis from 0 Hz to the Nyquist frequency is
/// fitted. A transition width is required: there is no default.
///
/// The normal equations are solved by Cholesky factorisation (LAPACK `dposv`). When they are
/// not positive definite, or their estimated reciprocal condition number (`dpocon`) is below
/// 10⁻¹⁰, the fit is redone by a singular value decomposition (`dgelsd`).
///
/// Oracle: `scipy.signal.firls`. An immutable value, usable on any thread.
public struct LeastSquaresMethod: FIRDesignMethod {
    /// The weight of the error in the stop bands, relative to a weight of 1 in the pass bands
    /// and in the transition bands. Usable on any thread.
    public let stopbandWeight: Double

    /// Usable on any thread.
    public init(stopbandWeight: Double = 1) {
        self.stopbandWeight = stopbandWeight
    }

    /// The length at which the fit expects to be `attenuation` down at the edges of its stop
    /// bands. The straight line across a transition band leaves a corner at each end of it, and
    /// the error of a least-squares fit at a corner falls only as one over the length:
    /// `δ ≈ 1 / (π²·Δ·M)` for `2M + 1` taps and a transition band `Δ` wide in units of the
    /// Nyquist frequency. A scheme with a narrow transition band or a deep stop band is beyond
    /// this method; the windowed sinc reaches it. Usable on any thread; allocation-free.
    public func estimatedLength(transition: Double, attenuation: Amplification, sampleRate: Double) throws(DSPError) -> Int {
        let decibels = try AnalogPrototype.decibels(attenuation, parameter: "attenuation")
        let width = try FIRDesign.normalizedWidth(transition, sampleRate: sampleRate)
        let half = (pow(10, decibels / 20) / (Double.pi * Double.pi * width)).rounded(.up)
        guard half <= Double(LeastSquaresFIR.maximumLength / 2) else {
            throw .unsupportedConfiguration(reason: "a least-squares fit needs about \(Int(min(2 * half + 1, 1e15))) taps to be \(decibels) dB down at the edge of a transition band of \(transition) Hz, above its longest filter of \(LeastSquaresFIR.maximumLength): the error of the fit at the corner of a linear transition band falls only as one over the length; `.windowedSinc()` reaches such a scheme")
        }
        return 2 * Int(half) + 1
    }

    /// The taps of the fit. Control or background context; allocates.
    public func taps(
        _ response: FilterResponse, length: Int, transition: Double?, attenuation: Amplification?, sampleRate: Double
    ) throws(DSPError) -> [Double] {
        let edges = try FIRDesign.normalizedEdges(of: response, sampleRate: sampleRate)
        guard let transition else {
            throw .invalidParameter(stage: .none, parameter: "transition", reason: "a least-squares design needs the width of its transition bands: pass `transition:`")
        }
        guard stopbandWeight.isFinite, stopbandWeight > 0 else {
            throw .invalidParameter(stage: .none, parameter: "stopbandWeight", reason: "a weight must be positive and finite, not \(stopbandWeight)")
        }
        let half = try FIRDesign.normalizedWidth(transition, sampleRate: sampleRate) / 2
        // The levels left and right of each edge, from 0 Hz upwards.
        let levels: [Double]
        switch response {
        case .lowPass: levels = [1, 0]
        case .highPass: levels = [0, 1]
        case .bandPass: levels = [0, 1, 0]
        case .bandStop: levels = [1, 0, 1]
        }
        var bands: [LeastSquaresFIR.Band] = []
        var start = 0.0
        for (index, edge) in edges.enumerated() {
            let lower = edge - half
            let upper = edge + half
            guard lower > start, upper < 1 else {
                throw .invalidParameter(stage: .none, parameter: "transition", reason: "a transition band of \(transition) Hz around \(edge * sampleRate / 2) Hz does not fit between 0 Hz, the other edge and the Nyquist frequency")
            }
            let level = levels[index]
            bands.append(.init(lower: start, upper: lower, lowerGain: level, upperGain: level, weight: level == 0 ? stopbandWeight : 1))
            bands.append(.init(lower: lower, upper: upper, lowerGain: level, upperGain: levels[index + 1], weight: 1))
            start = upper
        }
        let last = levels[levels.count - 1]
        bands.append(.init(lower: start, upper: 1, lowerGain: last, upperGain: last, weight: last == 0 ? stopbandWeight : 1))
        return try LeastSquaresFIR.design(length: length, bands: bands).taps
    }
}

extension FIRDesignMethod where Self == WindowedSincMethod {
    /// The ideal response truncated by `window`, or, without one, by a Kaiser window whose β
    /// the method chooses (see ``WindowedSincMethod``). Usable on any thread.
    public static func windowedSinc(window: Window? = nil) -> WindowedSincMethod { WindowedSincMethod(window: window) }
}

extension FIRDesignMethod where Self == LeastSquaresMethod {
    /// A least-squares fit with linear transition bands, every band weighted alike. Usable on
    /// any thread.
    public static var leastSquares: LeastSquaresMethod { LeastSquaresMethod() }

    /// A least-squares fit with linear transition bands in which an error in a stop band
    /// counts `stopbandWeight` times an error elsewhere. Usable on any thread.
    public static func leastSquares(stopbandWeight: Double) -> LeastSquaresMethod {
        LeastSquaresMethod(stopbandWeight: stopbandWeight)
    }
}
