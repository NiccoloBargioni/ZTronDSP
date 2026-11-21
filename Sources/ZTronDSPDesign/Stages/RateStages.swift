import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

// The four rate changers of §6.12: Decimate, Subsample, Upsample, Interpolate. Each is a
// sequence stage that changes the rate; the environment downstream follows (ENV-1). Switched
// off, a rate changer does not let the signal pass: the rest of its branch is suspended
// (ACT-3).

extension DSP {
    /// The largest factor of a rate change. A constant, usable on any thread; it does not
    /// allocate.
    public static let maximumRateChangeFactor = 4_096

    /// The low-pass of a rate change by an integer `factor` (§6.12): a Kaiser windowed sinc
    /// with unity gain at 0 Hz whose stop band starts at the lower of the two Nyquist
    /// frequencies, `1 / factor` of the higher one, and is at least `rejection` down from
    /// there on. It is what `Decimate` filters with before it keeps every `factor`-th sample
    /// and what `Interpolate` filters with after it has inserted zeros.
    ///
    /// The length is found as for any tolerance scheme (`FIRDesign`): Kaiser's estimate, then
    /// one decibel more until the measured stop band meets the request. It is one more than a
    /// multiple of `2 · factor`, so that the delay, `(K − 1) / 2` samples at the higher rate,
    /// is a whole number of samples at both rates. A factor of 1 needs no filter: `[1]`.
    /// Control or background context; allocates.
    ///
    /// - Parameters:
    ///   - factor: 1 … ``maximumRateChangeFactor``.
    ///   - rejection: The least attenuation of the stop band, as a number of decibels; 80 by
    ///     default.
    ///   - passband: The share of the lower Nyquist frequency that the pass band reaches,
    ///     strictly between 0 and 1; 0.8 by default. The rest is the transition band: a
    ///     larger share keeps more of the band and makes a longer filter.
    /// - Throws: `DSPError.invalidParameter` for a factor, a rejection or a share out of
    ///   range.
    public static func rateChangeTaps(
        by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8
    ) throws(DSPError) -> [Double] {
        guard factor >= 1, factor <= maximumRateChangeFactor else {
            throw .invalidParameter(stage: .none, parameter: "factor", reason: "a rate changes by a whole factor between 1 and \(maximumRateChangeFactor), not \(factor)")
        }
        let attenuation = try AnalogPrototype.decibels(rejection, parameter: "rejection")
        guard passband.isFinite, passband > 0, passband < 1 else {
            throw .invalidParameter(stage: .none, parameter: "passband", reason: "the pass band reaches a share of the new Nyquist frequency strictly between 0 and 1, not \(passband)")
        }
        guard factor > 1 else { return [1] }
        // In units of the higher Nyquist frequency (a sample rate of 2).
        let stop = 1 / Double(factor)
        return try FIRDesign.search(
            WindowedSincMethod(), passband: .lowPass(cutoff: passband * stop), stopband: .lowPass(cutoff: stop), loss: nil,
            attenuation: attenuation, sampleRate: 2, lengthStep: 2 * factor
        ).taps
    }

    /// Low-pass, then keep every `factor`-th sample: the offline twin of the `Decimate` stage
    /// (§6.12). The output is that of the stage, kernel for kernel: it is delayed by the
    /// filter, `(K − 1) / 2` input samples. Runs where it is called and allocates: not for
    /// the analysis thread.
    ///
    /// - Throws: what ``rateChangeTaps(by:rejection:passband:)`` throws.
    public static func decimate(
        _ samples: [Float], by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8
    ) throws(DSPError) -> [Float] {
        try Pipeline().appending(Decimate(by: factor, rejection: rejection, passband: passband))
            .process(samples, format: SignalFormat(sampleRate: 48_000))
    }

    /// Insert `factor − 1` zeros after each sample, then low-pass with gain `factor`: the
    /// offline twin of the `Interpolate` stage (§6.12). The output is that of the stage,
    /// kernel for kernel: it is delayed by the filter, `(K − 1) / 2` output samples. Runs
    /// where it is called and allocates: not for the analysis thread.
    ///
    /// - Throws: what ``rateChangeTaps(by:rejection:passband:)`` throws.
    public static func interpolate(
        _ samples: [Float], by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8
    ) throws(DSPError) -> [Float] {
        try Pipeline().appending(Interpolate(by: factor, rejection: rejection, passband: passband))
            .process(samples, format: SignalFormat(sampleRate: 48_000))
    }
}

/// Low-pass, then keep every `factor`-th sample (§6.12). The sample rate downstream is the
/// rate here divided by `factor`.
///
/// ```swift
/// Pipeline {
///     Decimate(by: 4)                                           // 48 kHz → 12 kHz
///     LowPass(.butterworth, cutoff: .hertz(4_000), order: 4)    // checked against 6 kHz, the Nyquist frequency here
/// }
/// ```
///
/// The filter is `DSP.rateChangeTaps(by:rejection:passband:)`: a Kaiser windowed sinc at
/// least `rejection` down from the new Nyquist frequency up, so that what would alias is
/// removed first. Latency: `(K − 1) / 2` input samples, a whole number of output samples
/// (REAL-5). A factor of 1 is no stage at all.
///
/// The stage runs on any sampled sequence. It has no continuous values. Switched off, it
/// suspends the rest of its branch (ACT-3).
///
/// An immutable value, usable on any thread. The filter is designed when the stage is
/// lowered, which allocates: control context.
public struct Decimate: SequenceStage {
    /// The factor the rate is divided by. Usable on any thread.
    public let factor: Int
    /// The least attenuation from the new Nyquist frequency up. Usable on any thread.
    public let rejection: Amplification
    /// The share of the new Nyquist frequency that the pass band reaches. Usable on any thread.
    public let passband: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// Usable on any thread.
    ///
    /// - Parameters:
    ///   - factor: 1 … 4 096.
    ///   - rejection: 80 dB by default (§6.12).
    ///   - passband: 0.8 by default: the band up to 0.8 of the new Nyquist frequency passes
    ///     unchanged; the rest of it is the transition band.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(
        by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8, isActive: some ActivationSource = .active
    ) {
        self.factor = factor
        self.rejection = rejection
        self.passband = passband
        self.activation = isActive.stageActivation
    }

    /// Designs the low-pass and emits the decimator. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let taps = try DSP.rateChangeTaps(by: factor, rejection: rejection, passband: passband)
        guard factor > 1 else { return }
        context.emit(.decimator(factor: factor, taps: taps.map { Float($0) }, latency: (taps.count - 1) / 2))
    }
}

/// Keeps every `factor`-th sample, starting at `phase` (§6.12). No filter: what aliases,
/// aliases. The sample rate downstream is the rate here divided by `factor`.
///
/// The output is `subsampled(_:by:phase:)` of the input, bit for bit, whatever the block
/// sizes. No latency. It has no continuous values. Switched off, it suspends the rest of its
/// branch (ACT-3).
///
/// An immutable value, usable on any thread; `lower(_:)` runs on the control context and may
/// allocate.
public struct Subsample: SequenceStage {
    /// The factor the rate is divided by. Usable on any thread.
    public let factor: Int
    /// The index of the first sample kept; taken modulo `factor`. Usable on any thread.
    public let phase: Int
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// A subsampler that keeps every `factor`-th sample from `phase` on. Usable on any thread.
    ///
    /// - Parameters:
    ///   - factor: 1 … 4 096.
    ///   - phase: The index of the first sample kept; taken modulo `factor`.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(by factor: Int, phase: Int = 0, isActive: some ActivationSource = .active) {
        self.factor = factor
        self.phase = phase
        self.activation = isActive.stageActivation
    }

    /// Emits the subsampler. Control context.
    ///
    /// - Throws: `DSPError.invalidParameter` for a factor outside 1 … 4 096.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard factor >= 1, factor <= DSP.maximumRateChangeFactor else {
            throw context.invalid("factor", "a rate changes by a whole factor between 1 and \(DSP.maximumRateChangeFactor), not \(factor)")
        }
        guard factor > 1 else { return }
        context.emit(.subsample(factor: factor, phase: ((phase % factor) + factor) % factor))
    }
}

/// Inserts `factor − 1` zeros after each sample (§6.12). No filter: the images remain. The
/// sample rate downstream is the rate here times `factor`.
///
/// The output is `upsampled(_:by:)` of the input, bit for bit, whatever the block sizes, and
/// `Subsample(by:)` with the same factor undoes it exactly. No latency. It has no continuous
/// values. Switched off, it suspends the rest of its branch (ACT-3).
///
/// An immutable value, usable on any thread; `lower(_:)` runs on the control context and may
/// allocate.
public struct Upsample: SequenceStage {
    /// The factor the rate is multiplied by. Usable on any thread.
    public let factor: Int
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// A zero-stuffer by `factor`. Usable on any thread.
    ///
    /// - Parameters:
    ///   - factor: 1 … 4 096.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(by factor: Int, isActive: some ActivationSource = .active) {
        self.factor = factor
        self.activation = isActive.stageActivation
    }

    /// Emits the zero-stuffer. Control context.
    ///
    /// - Throws: `DSPError.invalidParameter` for a factor outside 1 … 4 096.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard factor >= 1, factor <= DSP.maximumRateChangeFactor else {
            throw context.invalid("factor", "a rate changes by a whole factor between 1 and \(DSP.maximumRateChangeFactor), not \(factor)")
        }
        guard factor > 1 else { return }
        context.emit(.zeroStuff(factor: factor))
    }
}

/// Inserts zeros, then low-passes with gain `factor`, as a polyphase filter (§6.12): `factor`
/// short filters, one per output phase, so that no multiplication is spent on an inserted
/// zero. The sample rate downstream is the rate here times `factor`.
///
/// The filter is `DSP.rateChangeTaps(by:rejection:passband:)`: the images of the signal, from
/// the old Nyquist frequency up, are at least `rejection` down, and a constant comes out at
/// its own level. Latency: `(K − 1) / 2` output samples, a whole number of input samples
/// (REAL-5). `Interpolate(by: L)` after `Decimate(by: L)` restores what lies in the pass band
/// of both. A rational factor is `Interpolate(by: L)` followed by `Decimate(by: M)`.
///
/// The stage runs on any sampled sequence. It has no continuous values. Switched off, it
/// suspends the rest of its branch (ACT-3).
///
/// An immutable value, usable on any thread. The filter is designed when the stage is
/// lowered, which allocates: control context.
public struct Interpolate: SequenceStage {
    /// The factor the rate is multiplied by. Usable on any thread.
    public let factor: Int
    /// The least attenuation of the images. Usable on any thread.
    public let rejection: Amplification
    /// The share of the old Nyquist frequency that the pass band reaches. Usable on any thread.
    public let passband: Double
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// Usable on any thread.
    ///
    /// - Parameters:
    ///   - factor: 1 … 4 096.
    ///   - rejection: 80 dB by default (§6.12).
    ///   - passband: 0.8 by default: the band up to 0.8 of the old Nyquist frequency passes
    ///     unchanged; the rest of it is the transition band.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(
        by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8, isActive: some ActivationSource = .active
    ) {
        self.factor = factor
        self.rejection = rejection
        self.passband = passband
        self.activation = isActive.stageActivation
    }

    /// Designs the low-pass and emits the interpolator. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let taps = try DSP.rateChangeTaps(by: factor, rejection: rejection, passband: passband)
        guard factor > 1 else { return }
        // (K − 1) / 2 output samples are (K − 1) / (2·factor) input samples: whole, by the
        // length the filter is given.
        context.emit(.interpolator(factor: factor, taps: taps.map { Float($0) }, latency: (taps.count - 1) / (2 * factor)))
    }
}
