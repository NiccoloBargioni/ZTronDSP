import ZTronDSPCore

// The smoothing stages of §6.3.6: SavitzkyGolay and AlphaBeta. Pipeline stages only: neither
// is an element of a system builder.

/// Smooths, or differentiates, by a Savitzky–Golay filter (§6.3.6): each output is the value,
/// or the `derivative`-th derivative, at the middle of a window of the polynomial that fits
/// the samples under it best.
///
/// ```swift
/// SavitzkyGolay(window: 11, polynomialOrder: 3)                  // smooths
/// SavitzkyGolay(window: 11, polynomialOrder: 3, derivative: 1)   // the slope, per sample
/// ```
///
/// In a pipeline the filter runs as a centred FIR filter: the coefficients of
/// `DSP.savitzkyGolayCoefficients(window:polynomialOrder:derivative:)`, with a latency of
/// `(window − 1) / 2` samples (REAL-5). From its `(window − 1) / 2`-th output on, the stream
/// is the offline function `DSP.savitzkyGolay(_:window:polynomialOrder:derivative:edge:)`
/// delayed by that latency, sample for sample, whatever the edge mode.
///
/// **Edges.** `edge` says what a window holds where it reaches past the ends of a signal, and
/// it matters where a signal has ends: in the offline function, and at the start of a stream.
/// A stream starts from silence, as every stage does (ACT-10), so the first
/// `(window − 1) / 2` outputs of the stage are those of `.constant(0)`; a stream has no other
/// end.
///
/// The stage runs on any sampled sequence and keeps its domain. A derivative is taken with
/// respect to the sample index: multiply by the sample rate to the power of the derivative
/// for a derivative in time. Window, order and derivative are structure: the stage has no
/// continuous values.
///
/// An immutable value, usable on any thread. The coefficients are designed when the stage is
/// lowered, which allocates: control context.
public struct SavitzkyGolay: SequenceStage {
    /// The number of samples under the fit: odd. Usable on any thread.
    public let window: Int
    /// The degree of the polynomial: below `window`. Usable on any thread.
    public let polynomialOrder: Int
    /// 0 smooths; `d` gives the `d`-th derivative. Usable on any thread.
    public let derivative: Int
    /// What a window holds past the ends of a signal. Usable on any thread.
    public let edge: SavitzkyGolayEdge
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// A Savitzky–Golay filter of `window` samples and degree `polynomialOrder`. Usable on any
    /// thread.
    ///
    /// - Parameters:
    ///   - window: The number of samples under the fit: odd.
    ///   - polynomialOrder: The degree of the polynomial: below `window`.
    ///   - derivative: 0, the default, smooths; `d` gives the `d`-th derivative.
    ///   - edge: What a window holds past the ends of a signal; `.interpolate` by default.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(
        window: Int, polynomialOrder: Int, derivative: Int = 0, edge: SavitzkyGolayEdge = .interpolate,
        isActive: some ActivationSource = .active
    ) {
        self.window = window
        self.polynomialOrder = polynomialOrder
        self.derivative = derivative
        self.edge = edge
        self.activation = isActive.stageActivation
    }

    /// Designs the coefficients and emits them as a centred FIR filter. Control context;
    /// allocates.
    ///
    /// - Throws: what `DSP.savitzkyGolayCoefficients` throws: an even window, an order at or
    ///   above the window, a negative derivative.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let coefficients = try DSP.savitzkyGolayCoefficients(window: window, polynomialOrder: polynomialOrder, derivative: derivative)
        if case .constant(let value) = edge, !value.isFinite {
            throw context.invalid("edge", "the constant a signal is continued with must be finite, not \(value)")
        }
        context.emit(.fir(taps: coefficients.map { Float($0) }, latency: (window - 1) / 2))
    }
}

/// The two-state alpha–beta tracker (§6.3.6): it follows a signal with a position and a
/// velocity, correcting both by the error of its prediction.
///
/// Per sample `z`, with the time step `dt` of one sample:
///
///     r = z − (x + dt·v)        x ← x + dt·v + alpha·r        v ← v + (beta / dt)·r
///
/// The stage outputs the position `x`, or the velocity `v` with `output: .velocity`. The
/// time step comes from the environment's sample rate at the stage's position: on a scalar
/// track it is the feature rate. `DSP.alphaBeta(_:alpha:beta:timeStep:…)` is its offline
/// twin.
///
/// The stage runs on any sampled sequence and keeps its domain; it adds no latency. Its
/// values are structure: a change of `alpha` or `beta` starts a new tracker.
///
/// An immutable value, usable on any thread; `lower(_:)` runs on the control context and may
/// allocate.
public struct AlphaBeta: SequenceStage {
    /// What the tracker puts out: a value, usable on any thread; it does not allocate.
    public enum Output: Hashable, Sendable {
        /// The tracked position: the smoothed signal.
        case position
        /// The tracked velocity: the smoothed slope, per second.
        case velocity
    }

    /// The share of the prediction error that corrects the position. Usable on any thread.
    public let alpha: Double
    /// The share of the prediction error that corrects the velocity. Usable on any thread.
    public let beta: Double
    /// The position the tracker starts from. Usable on any thread.
    public let initialPosition: Double
    /// The velocity the tracker starts from. Usable on any thread.
    public let initialVelocity: Double
    /// What the tracker puts out. Usable on any thread.
    public let output: Output
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// A tracker with the gains `alpha` and `beta`, starting from `initialPosition` and
    /// `initialVelocity`. Usable on any thread.
    ///
    /// - Parameters:
    ///   - alpha: The share of the prediction error that corrects the position.
    ///   - beta: The share of the prediction error that corrects the velocity.
    ///   - initialPosition: The position the tracker starts from; 0 by default.
    ///   - initialVelocity: The velocity the tracker starts from; 0 by default.
    ///   - output: `.position`, the default, or `.velocity`.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(
        alpha: Double, beta: Double, initialPosition: Double = 0, initialVelocity: Double = 0, output: Output = .position,
        isActive: some ActivationSource = .active
    ) {
        self.alpha = alpha
        self.beta = beta
        self.initialPosition = initialPosition
        self.initialVelocity = initialVelocity
        self.output = output
        self.activation = isActive.stageActivation
    }

    /// Emits the tracker. Control context.
    ///
    /// - Throws: `DSPError.invalidParameter` for a value that is not finite in single
    ///   precision.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let values = [("alpha", alpha), ("beta", beta), ("initialPosition", initialPosition), ("initialVelocity", initialVelocity)]
        for (name, value) in values {
            guard Float(value).isFinite else { throw context.invalid(name, "\(value) is not a finite number in single precision") }
        }
        context.emit(.alphaBeta(alpha: Float(alpha), beta: Float(beta), initialPosition: Float(initialPosition),
                                initialVelocity: Float(initialVelocity), outputVelocity: output == .velocity))
    }
}

extension DSP {
    /// A signal followed by an alpha–beta tracker: the offline twin of the `AlphaBeta` stage
    /// (§6.3.6), the defining recurrence in double precision, rounded to Float32 at the end.
    /// `alpha`, `beta` and the time step are taken in single precision, as the stage's kernel
    /// takes them, so that the two agree to rounding. Runs where it is called and allocates:
    /// not for the analysis thread.
    ///
    /// - Parameters:
    ///   - samples: The signal to follow.
    ///   - alpha: The share of the prediction error that corrects the position.
    ///   - beta: The share of the prediction error that corrects the velocity.
    ///   - timeStep: The time between two samples, in seconds: one over the sample rate.
    ///   - initialPosition: The position the tracker starts from; 0 by default.
    ///   - initialVelocity: The velocity the tracker starts from; 0 by default.
    ///   - output: `.position`, the default, or `.velocity`.
    /// - Throws: `DSPError.invalidParameter` for a time step that is not positive and finite,
    ///   and for a value that is not finite.
    public static func alphaBeta(
        _ samples: [Float], alpha: Double, beta: Double, timeStep: Double, initialPosition: Double = 0,
        initialVelocity: Double = 0, output: AlphaBeta.Output = .position
    ) throws(DSPError) -> [Float] {
        let step = Double(Float(timeStep))
        guard step.isFinite, step > 0 else {
            throw .invalidParameter(stage: .none, parameter: "timeStep", reason: "the time between two samples is positive and finite, not \(timeStep) s")
        }
        let gainOfPosition = Double(Float(alpha)), gainOfVelocity = Double(Float(beta))
        var position = Double(Float(initialPosition)), velocity = Double(Float(initialVelocity))
        guard gainOfPosition.isFinite, gainOfVelocity.isFinite, position.isFinite, velocity.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "alpha", reason: "the values of a tracker must be finite")
        }
        var result = [Float](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            let residual = Double(sample) - (position + step * velocity)
            position = position + step * velocity + gainOfPosition * residual
            velocity = velocity + gainOfVelocity / step * residual
            result[index] = Float(output == .position ? position : velocity)
        }
        return result
    }
}
