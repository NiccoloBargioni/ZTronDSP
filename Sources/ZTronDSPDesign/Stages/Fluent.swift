import Foundation
import ZTronDSPCore

// The fluent spelling of the sequence stages of this target (§5.1, API-1): one method per
// initialiser, with the same labels and the same defaults, each returning a new pipeline. A
// method exists only on a pipeline whose output is a sampled sequence (O-1); on any other the
// compiler says which constraint is missing. `Pipeline { LowPass(…) }` and
// `Pipeline().lowPass(…)` are equal values.

extension Pipeline where Output: SampledSequence {
    // MARK: Response stages (§6.3.2, §6.3.3)

    /// The pipeline followed by an IIR low-pass filter of the given family and order.
    /// See ``LowPass``. Usable on any thread; allocates the pipeline it returns.
    public func lowPass(
        _ family: some FilterFamily, cutoff: Frequency, order: Int, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowPass(family, cutoff: cutoff, order: order, isActive: isActive))
    }

    /// The pipeline followed by an IIR low-pass filter whose order is given as a roll-off (§6.3.4).
    /// See ``LowPass``. Usable on any thread; allocates the pipeline it returns.
    public func lowPass(
        _ family: some FilterFamily, cutoff: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowPass(family, cutoff: cutoff, rollOff: rollOff, rounding: rounding, isActive: isActive))
    }

    /// The pipeline followed by the IIR low-pass filter of the lowest order that meets a tolerance scheme
    /// (§6.3.2). See ``LowPass``. Usable on any thread; allocates the pipeline it returns.
    public func lowPass(
        _ family: some FilterFamily, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowPass(family, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR low-pass filter of `length` taps.
    /// See ``LowPass``. Usable on any thread; allocates the pipeline it returns.
    public func lowPass(
        _ method: some FIRDesignMethod, cutoff: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowPass(method, cutoff: cutoff, transition: transition, length: length, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR low-pass filter whose steepness is given as a roll-off
    /// (§6.3.4). See ``LowPass``. Usable on any thread; allocates the pipeline it returns.
    public func lowPass(
        _ method: some FIRDesignMethod, cutoff: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowPass(method, cutoff: cutoff, rollOff: rollOff, stopband: stopband, isActive: isActive))
    }

    /// The pipeline followed by the shortest linear-phase FIR low-pass filter that meets a tolerance scheme.
    /// See ``LowPass``. Usable on any thread; allocates the pipeline it returns.
    public func lowPass(
        _ method: some FIRDesignMethod, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowPass(method, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by an IIR high-pass filter of the given family and order.
    /// See ``HighPass``. Usable on any thread; allocates the pipeline it returns.
    public func highPass(
        _ family: some FilterFamily, cutoff: Frequency, order: Int, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighPass(family, cutoff: cutoff, order: order, isActive: isActive))
    }

    /// The pipeline followed by an IIR high-pass filter whose order is given as a roll-off (§6.3.4).
    /// See ``HighPass``. Usable on any thread; allocates the pipeline it returns.
    public func highPass(
        _ family: some FilterFamily, cutoff: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighPass(family, cutoff: cutoff, rollOff: rollOff, rounding: rounding, isActive: isActive))
    }

    /// The pipeline followed by the IIR high-pass filter of the lowest order that meets a tolerance scheme
    /// (§6.3.2). See ``HighPass``. Usable on any thread; allocates the pipeline it returns.
    public func highPass(
        _ family: some FilterFamily, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighPass(family, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR high-pass filter of `length` taps.
    /// See ``HighPass``. Usable on any thread; allocates the pipeline it returns.
    public func highPass(
        _ method: some FIRDesignMethod, cutoff: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighPass(method, cutoff: cutoff, transition: transition, length: length, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR high-pass filter whose steepness is given as a roll-off
    /// (§6.3.4). See ``HighPass``. Usable on any thread; allocates the pipeline it returns.
    public func highPass(
        _ method: some FIRDesignMethod, cutoff: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighPass(method, cutoff: cutoff, rollOff: rollOff, stopband: stopband, isActive: isActive))
    }

    /// The pipeline followed by the shortest linear-phase FIR high-pass filter that meets a tolerance scheme.
    /// See ``HighPass``. Usable on any thread; allocates the pipeline it returns.
    public func highPass(
        _ method: some FIRDesignMethod, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighPass(method, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by an IIR band-pass filter of the given family and order.
    /// See ``BandPass``. Usable on any thread; allocates the pipeline it returns.
    public func bandPass(
        _ family: some FilterFamily, from: Frequency, to: Frequency, order: Int, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandPass(family, from: from, to: to, order: order, isActive: isActive))
    }

    /// The pipeline followed by an IIR band-pass filter whose order is given as a roll-off (§6.3.4).
    /// See ``BandPass``. Usable on any thread; allocates the pipeline it returns.
    public func bandPass(
        _ family: some FilterFamily, from: Frequency, to: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandPass(family, from: from, to: to, rollOff: rollOff, rounding: rounding, isActive: isActive))
    }

    /// The pipeline followed by the IIR band-pass filter of the lowest order that meets a tolerance scheme
    /// (§6.3.2). See ``BandPass``. Usable on any thread; allocates the pipeline it returns.
    public func bandPass(
        _ family: some FilterFamily, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandPass(family, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR band-pass filter of `length` taps.
    /// See ``BandPass``. Usable on any thread; allocates the pipeline it returns.
    public func bandPass(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandPass(method, from: from, to: to, transition: transition, length: length, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR band-pass filter whose steepness is given as a roll-off
    /// (§6.3.4). See ``BandPass``. Usable on any thread; allocates the pipeline it returns.
    public func bandPass(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandPass(method, from: from, to: to, rollOff: rollOff, stopband: stopband, isActive: isActive))
    }

    /// The pipeline followed by the shortest linear-phase FIR band-pass filter that meets a tolerance scheme.
    /// See ``BandPass``. Usable on any thread; allocates the pipeline it returns.
    public func bandPass(
        _ method: some FIRDesignMethod, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandPass(method, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by an IIR band-stop filter of the given family and order.
    /// See ``BandStop``. Usable on any thread; allocates the pipeline it returns.
    public func bandStop(
        _ family: some FilterFamily, from: Frequency, to: Frequency, order: Int, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandStop(family, from: from, to: to, order: order, isActive: isActive))
    }

    /// The pipeline followed by an IIR band-stop filter whose order is given as a roll-off (§6.3.4).
    /// See ``BandStop``. Usable on any thread; allocates the pipeline it returns.
    public func bandStop(
        _ family: some FilterFamily, from: Frequency, to: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandStop(family, from: from, to: to, rollOff: rollOff, rounding: rounding, isActive: isActive))
    }

    /// The pipeline followed by the IIR band-stop filter of the lowest order that meets a tolerance scheme
    /// (§6.3.2). See ``BandStop``. Usable on any thread; allocates the pipeline it returns.
    public func bandStop(
        _ family: some FilterFamily, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandStop(family, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR band-stop filter of `length` taps.
    /// See ``BandStop``. Usable on any thread; allocates the pipeline it returns.
    public func bandStop(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandStop(method, from: from, to: to, transition: transition, length: length, isActive: isActive))
    }

    /// The pipeline followed by a linear-phase FIR band-stop filter whose steepness is given as a roll-off
    /// (§6.3.4). See ``BandStop``. Usable on any thread; allocates the pipeline it returns.
    public func bandStop(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandStop(method, from: from, to: to, rollOff: rollOff, stopband: stopband, isActive: isActive))
    }

    /// The pipeline followed by the shortest linear-phase FIR band-stop filter that meets a tolerance scheme.
    /// See ``BandStop``. Usable on any thread; allocates the pipeline it returns.
    public func bandStop(
        _ method: some FIRDesignMethod, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandStop(method, passband: passband, stopband: stopband, maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation, isActive: isActive))
    }

    // MARK: Equaliser stages (§6.3.5)

    /// The pipeline followed by a band-boost of the given order; 1, the default, is the Cookbook's peaking
    /// section. See ``BandBoost``. Usable on any thread; allocates the pipeline it returns.
    public func bandBoost(
        center: Frequency, gain: Amplification, bandwidth: Bandwidth, order: Int = 1, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandBoost(center: center, gain: gain, bandwidth: bandwidth, order: order, isActive: isActive))
    }

    /// The pipeline followed by a band-boost whose order is given as the roll-off of its skirts (§6.3.4).
    /// See ``BandBoost``. Usable on any thread; allocates the pipeline it returns.
    public func bandBoost(
        center: Frequency, gain: Amplification, bandwidth: Bandwidth, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(BandBoost(center: center, gain: gain, bandwidth: bandwidth, rollOff: rollOff, rounding: rounding, isActive: isActive))
    }

    /// The pipeline followed by a matched second-order peak. See ``MatchedPeak``. Usable on any
    /// thread; allocates the pipeline it returns.
    public func matchedPeak(
        center: Frequency, gain: Amplification, bandwidth: Bandwidth, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(MatchedPeak(center: center, gain: gain, bandwidth: bandwidth, isActive: isActive))
    }

    /// The pipeline followed by the Cookbook's low shelf. See ``LowShelf``. Usable on any thread;
    /// allocates the pipeline it returns.
    public func lowShelf(
        midpoint: Frequency, gain: Amplification, slope: ShelfSlope = .slope(1), isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(LowShelf(midpoint: midpoint, gain: gain, slope: slope, isActive: isActive))
    }

    /// The pipeline followed by the Cookbook's high shelf. See ``HighShelf``. Usable on any thread;
    /// allocates the pipeline it returns.
    public func highShelf(
        midpoint: Frequency, gain: Amplification, slope: ShelfSlope = .slope(1), isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(HighShelf(midpoint: midpoint, gain: gain, slope: slope, isActive: isActive))
    }

    // MARK: Systems (§6.3.7)

    /// The pipeline followed by an IIR system, run as second-order sections. See ``Filter``. Usable on any
    /// thread; allocates the pipeline it returns.
    public func filter(_ system: IIRSystem, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Filter(system, isActive: isActive))
    }

    /// The pipeline followed by an FIR system. See ``Filter``. Usable on any thread; allocates the
    /// pipeline it returns.
    public func filter(_ system: FIRSystem, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Filter(system, isActive: isActive))
    }

    // MARK: Gain (§6.2)

    /// The pipeline followed by a gain, the same for every channel. See ``Gain``. Usable on any
    /// thread; allocates the pipeline it returns.
    public func gain(_ amount: Amplification, ramp: TimeInterval = 0.010, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Gain(amount, ramp: ramp, isActive: isActive))
    }

    /// The pipeline followed by a gain per channel. See ``Gain``. Usable on any thread; allocates
    /// the pipeline it returns.
    public func gain(
        channels amounts: [Amplification], ramp: TimeInterval = 0.010, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(Gain(channels: amounts, ramp: ramp, isActive: isActive))
    }

    // MARK: Smoothing (§6.3.6)

    /// The pipeline followed by a Savitzky–Golay filter. See ``SavitzkyGolay``. Usable on any
    /// thread; allocates the pipeline it returns.
    public func savitzkyGolay(
        window: Int, polynomialOrder: Int, derivative: Int = 0, edge: SavitzkyGolayEdge = .interpolate,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(SavitzkyGolay(window: window, polynomialOrder: polynomialOrder, derivative: derivative, edge: edge, isActive: isActive))
    }

    /// The pipeline followed by an alpha–beta tracker. See ``AlphaBeta``. Usable on any thread;
    /// allocates the pipeline it returns.
    public func alphaBeta(
        alpha: Double, beta: Double, initialPosition: Double = 0, initialVelocity: Double = 0, output: AlphaBeta.Output = .position,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(AlphaBeta(alpha: alpha, beta: beta, initialPosition: initialPosition, initialVelocity: initialVelocity, output: output, isActive: isActive))
    }

    // MARK: Rate changes (§6.12)

    /// The pipeline followed by a decimator: low-pass, then every `factor`-th sample. The rate downstream is
    /// divided by `factor`. See ``Decimate``. Usable on any thread; allocates the pipeline it
    /// returns.
    public func decimate(
        by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(Decimate(by: factor, rejection: rejection, passband: passband, isActive: isActive))
    }

    /// The pipeline followed by a subsampler: every `factor`-th sample, without a filter. See ``Subsample``.
    /// Usable on any thread; allocates the pipeline it returns.
    public func subsample(by factor: Int, phase: Int = 0, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Subsample(by: factor, phase: phase, isActive: isActive))
    }

    /// The pipeline followed by a zero-stuffer: `factor − 1` zeros after each sample, without a filter. See
    /// ``Upsample``. Usable on any thread; allocates the pipeline it returns.
    public func upsample(by factor: Int, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(Upsample(by: factor, isActive: isActive))
    }

    /// The pipeline followed by an interpolator: zeros, then a low-pass with gain `factor`. The rate
    /// downstream is multiplied by `factor`. See ``Interpolate``. Usable on any thread; allocates
    /// the pipeline it returns.
    public func interpolate(
        by factor: Int, rejection: Amplification = .decibels(80), passband: Double = 0.8, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(Interpolate(by: factor, rejection: rejection, passband: passband, isActive: isActive))
    }
}
