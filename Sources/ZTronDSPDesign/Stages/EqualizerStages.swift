import Accelerate   // for the C maths library only: no LAPACK is called outside LinearAlgebra/ (LA-1)
import ZTronDSPCore

// The equaliser stages of §6.3.5: BandBoost, LowShelf, HighShelf. Each is a sequence stage in a
// pipeline and an element of an `IIRSystem { }` block (§6.3.7).

extension Bandwidth {
    /// The value a parameter vector carries for the width (ANI-2): log₂ of a width in hertz
    /// and of a quality factor, so that both glide evenly; a width in octaves as it is.
    var animatableValue: Double {
        switch self {
        case .hertz(let width): log2(max(width, 1e-9))
        case .octaves(let octaves): octaves
        case .q(let q): log2(max(q, 1e-9))
        }
    }

    /// The same kind of width with another value; the width itself for its own value.
    func replacing(animatableValue: Double) -> Bandwidth {
        guard animatableValue != self.animatableValue else { return self }
        switch self {
        case .hertz: return .hertz(pow(2, animatableValue))
        case .octaves: return .octaves(animatableValue)
        case .q: return .q(pow(2, animatableValue))
        }
    }

    /// True for a width in hertz: it is a width in the `z` plane only once the rate is known.
    var isAbsolute: Bool {
        if case .hertz = self { return true }
        return false
    }
}

extension ShelfSlope {
    /// The value a parameter vector carries for the slope (ANI-2): the shelf slope as it is,
    /// log₂ of a quality factor.
    var animatableValue: Double {
        switch self {
        case .slope(let slope): slope
        case .q(let q): log2(max(q, 1e-9))
        }
    }

    func replacing(animatableValue: Double) -> ShelfSlope {
        guard animatableValue != self.animatableValue else { return self }
        switch self {
        case .slope: return .slope(animatableValue)
        case .q: return .q(pow(2, animatableValue))
        }
    }
}

/// A band-boost filter (§6.3.5): gain `gain` at `center`, 0 dB far from it, monotonic on each
/// side. A negative gain in decibels cuts, and the cut is the exact inverse of the boost.
///
/// ```swift
/// BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1))               // the Cookbook's peak
/// BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), order: 4)     // flat top, steeper skirts
/// BandBoost(center: .hertz(2_800), gain: .decibels(4), bandwidth: .octaves(1), rollOff: .decibelsPerOctave(24))
/// ```
///
/// - **Order 1** is the second-order peaking section of the Audio EQ Cookbook.
/// - **Order N** is the maximally flat design of Orfanidis (2005): `N` biquads, a flatter
///   top, and skirts of `N · 6.02` dB per octave. It is designed and paired in zero-pole
///   form.
///
/// Every order is 0 dB at 0 Hz and at the Nyquist frequency, which narrows a band that sits
/// close to the latter. ``MatchedPeak`` is the second-order peak without that cramping.
///
/// **Bandwidth** is measured between the two frequencies at which the gain is half the
/// requested gain in decibels: `.hertz(w)` is met exactly on the digital axis, `.octaves(b)`
/// is converted to `f₀·(2^(b/2) − 2^(−b/2))` hertz and then met exactly, `.q(Q)` follows the
/// Cookbook. A band whose upper half-gain frequency would reach 0.49 of the sample rate is
/// rejected when the plan is compiled.
///
/// **In a pipeline** the stage runs on any sampled sequence and keeps its domain; its
/// centre is resolved against the environment at its position (ENV-2). It runs as biquads
/// with their gain spread, in the precision of the environment's `biquadPrecision`, and adds
/// no latency. Centre, gain and bandwidth are its continuous values (ANI-2): they move
/// without a change of topology.
///
/// **In a system** (`IIRSystem { }`) the same value is an element; there it must keep the
/// default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing, which allocates, happens when the stage
/// is resolved or lowered: control or background context.
public struct BandBoost: SequenceStage, IIRSystemElement {
    enum Shape: Hashable, Sendable {
        case order(Int)
        case rollOff(RollOff, RollOffRounding)
    }

    /// The centre of the band. Usable on any thread.
    public let center: Frequency
    /// The gain at the centre. Usable on any thread.
    public let gain: Amplification
    /// The width of the band. Usable on any thread.
    public let bandwidth: Bandwidth
    let shape: Shape
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(center: Frequency, gain: Amplification, bandwidth: Bandwidth, shape: Shape, activation: StageActivation) {
        self.center = center
        self.gain = gain
        self.bandwidth = bandwidth
        self.shape = shape
        self.activation = activation
    }

    /// A band-boost of the given order: 1, the default, is the Cookbook's peaking section.
    /// Usable on any thread.
    ///
    /// - Parameters:
    ///   - center: The centre of the band, resolved against the environment (ENV-2).
    ///   - gain: The gain at the centre; a negative number of decibels cuts.
    ///   - bandwidth: The width of the band, between its two half-gain frequencies.
    ///   - order: The number of biquads; 1, the default, is the Cookbook's peaking section.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(
        center: Frequency, gain: Amplification, bandwidth: Bandwidth, order: Int = 1, isActive: some ActivationSource = .active
    ) {
        self.init(center: center, gain: gain, bandwidth: bandwidth, shape: .order(order), activation: isActive.stageActivation)
    }

    /// A band-boost whose order is given as the roll-off of its skirts (§6.3.4): `N · 6.02` dB
    /// per octave for order `N`, with the remarks that apply to a digital band-pass. Usable
    /// on any thread.
    public init(
        center: Frequency, gain: Amplification, bandwidth: Bandwidth, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) {
        self.init(center: center, gain: gain, bandwidth: bandwidth, shape: .rollOff(rollOff, rounding), activation: isActive.stageActivation)
    }

    /// The design the stage's arguments name, at `sampleRate`. Control or background context;
    /// allocates.
    ///
    /// - Throws: what `EqualizerDesign.bandBoost` throws: a centre outside 0 Hz … Nyquist, a
    ///   band past the limit, an order or a roll-off that is not designed.
    public func design(sampleRate: Double) throws(DSPError) -> EqualizerDesign {
        let hertz = try center.hertz(sampleRate: sampleRate)
        switch shape {
        case .order(let order):
            return try EqualizerDesign.bandBoost(center: hertz, gain: gain, bandwidth: bandwidth, order: order, sampleRate: sampleRate)
        case .rollOff(let rollOff, let rounding):
            return try EqualizerDesign.bandBoost(center: hertz, gain: gain, bandwidth: bandwidth, rollOff: rollOff, rounding: rounding, sampleRate: sampleRate)
        }
    }

    /// Centre, gain in decibels and bandwidth (ANI-2). Usable on any thread; it allocates the array
    /// it returns.
    public var parameters: [Double] { [center.animatableValue, gain.animatableValue, bandwidth.animatableValue] }

    /// The stage with its continuous values replaced. Passing its own values returns it unchanged.
    /// Usable on any thread; it may allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> BandBoost {
        guard values.count == 3 else { return self }
        let list = Array(values)
        return BandBoost(center: center.replacing(animatableValue: list[0]), gain: gain.replacing(animatableValue: list[1]),
                         bandwidth: bandwidth.replacing(animatableValue: list[2]), shape: shape, activation: activation)
    }

    /// Designs the band for the environment at the stage's position and emits its biquads.
    /// Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        _ = try StageValidation.frequency(center, named: "center", in: context)
        try FilterLowering.emit(try design(sampleRate: context.environment.sampleRate).secondOrderSections, into: &context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the design. Control or
    /// background context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try design(sampleRate: sampleRate).zeroPoleGain
    }

    /// True when the centre is stated in hertz, as a note or in mels, or the bandwidth in
    /// hertz. Usable on any thread.
    public var dependsOnSampleRate: Bool { !center.dependsOnSampleRate || bandwidth.isAbsolute }
}

/// The Audio EQ Cookbook's second-order low shelf (§6.3.5): gain `gain` at 0 Hz, 0 dB at the
/// Nyquist frequency, and half the gain in decibels at `midpoint`.
///
/// ```swift
/// LowShelf(midpoint: .hertz(200), gain: .decibels(3))
/// LowShelf(midpoint: .hertz(200), gain: .decibels(-6), slope: .q(0.9))
/// ```
///
/// In a pipeline it runs on any sampled sequence, keeps its domain and adds no latency;
/// midpoint, gain and slope are its continuous values (ANI-2). In an `IIRSystem { }` it is an
/// element and must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing, which allocates, happens when the stage
/// is resolved or lowered: control or background context.
public struct LowShelf: SequenceStage, IIRSystemElement {
    /// The frequency at which the gain is half the shelf's gain in decibels. Usable on any
    /// thread.
    public let midpoint: Frequency
    /// The gain of the shelf. Usable on any thread.
    public let gain: Amplification
    /// The steepness of the shelf. Usable on any thread.
    public let slope: ShelfSlope
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(midpoint: Frequency, gain: Amplification, slope: ShelfSlope, activation: StageActivation) {
        self.midpoint = midpoint
        self.gain = gain
        self.slope = slope
        self.activation = activation
    }

    /// A low shelf. Usable on any thread.
    ///
    /// - Parameters:
    ///   - midpoint: The frequency at which the gain is half the shelf's gain in decibels.
    ///   - gain: The gain of the shelf, reached at 0 Hz.
    ///   - slope: The steepness of the shelf; `.slope(1)`, the steepest that stays monotonic,
    ///     by default.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(midpoint: Frequency, gain: Amplification, slope: ShelfSlope = .slope(1), isActive: some ActivationSource = .active) {
        self.init(midpoint: midpoint, gain: gain, slope: slope, activation: isActive.stageActivation)
    }

    /// The design the stage's arguments name, at `sampleRate`. Control or background context;
    /// allocates.
    public func design(sampleRate: Double) throws(DSPError) -> EqualizerDesign {
        try EqualizerDesign.lowShelf(midpoint: try midpoint.hertz(sampleRate: sampleRate), gain: gain, slope: slope, sampleRate: sampleRate)
    }

    /// Midpoint, gain in decibels and slope (ANI-2). Usable on any thread; it allocates the array
    /// it returns.
    public var parameters: [Double] { [midpoint.animatableValue, gain.animatableValue, slope.animatableValue] }

    /// The stage with its continuous values replaced. Passing its own values returns it unchanged.
    /// Usable on any thread; it may allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> LowShelf {
        guard values.count == 3 else { return self }
        let list = Array(values)
        return LowShelf(midpoint: midpoint.replacing(animatableValue: list[0]), gain: gain.replacing(animatableValue: list[1]),
                        slope: slope.replacing(animatableValue: list[2]), activation: activation)
    }

    /// Designs the shelf for the environment at the stage's position and emits its biquad.
    /// Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        _ = try StageValidation.frequency(midpoint, named: "midpoint", in: context)
        try FilterLowering.emit(try design(sampleRate: context.environment.sampleRate).secondOrderSections, into: &context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the design. Control or
    /// background context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try design(sampleRate: sampleRate).zeroPoleGain
    }

    /// True when the midpoint is stated in hertz, as a note or in mels. Usable on any thread.
    public var dependsOnSampleRate: Bool { !midpoint.dependsOnSampleRate }
}

/// The Audio EQ Cookbook's second-order high shelf (§6.3.5): gain `gain` at the Nyquist
/// frequency, 0 dB at 0 Hz, and half the gain in decibels at `midpoint`.
///
/// ```swift
/// HighShelf(midpoint: .hertz(6_000), gain: .decibels(-3))
/// ```
///
/// In a pipeline it runs on any sampled sequence, keeps its domain and adds no latency;
/// midpoint, gain and slope are its continuous values (ANI-2). In an `IIRSystem { }` it is an
/// element and must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing, which allocates, happens when the stage
/// is resolved or lowered: control or background context.
public struct HighShelf: SequenceStage, IIRSystemElement {
    /// The frequency at which the gain is half the shelf's gain in decibels. Usable on any
    /// thread.
    public let midpoint: Frequency
    /// The gain of the shelf. Usable on any thread.
    public let gain: Amplification
    /// The steepness of the shelf. Usable on any thread.
    public let slope: ShelfSlope
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(midpoint: Frequency, gain: Amplification, slope: ShelfSlope, activation: StageActivation) {
        self.midpoint = midpoint
        self.gain = gain
        self.slope = slope
        self.activation = activation
    }

    /// A high shelf. Usable on any thread.
    ///
    /// - Parameters:
    ///   - midpoint: The frequency at which the gain is half the shelf's gain in decibels.
    ///   - gain: The gain of the shelf, reached at the Nyquist frequency.
    ///   - slope: The steepness of the shelf; `.slope(1)`, the steepest that stays monotonic,
    ///     by default.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(midpoint: Frequency, gain: Amplification, slope: ShelfSlope = .slope(1), isActive: some ActivationSource = .active) {
        self.init(midpoint: midpoint, gain: gain, slope: slope, activation: isActive.stageActivation)
    }

    /// The design the stage's arguments name, at `sampleRate`. Control or background context;
    /// allocates.
    public func design(sampleRate: Double) throws(DSPError) -> EqualizerDesign {
        try EqualizerDesign.highShelf(midpoint: try midpoint.hertz(sampleRate: sampleRate), gain: gain, slope: slope, sampleRate: sampleRate)
    }

    /// Midpoint, gain in decibels and slope (ANI-2). Usable on any thread; it allocates the array
    /// it returns.
    public var parameters: [Double] { [midpoint.animatableValue, gain.animatableValue, slope.animatableValue] }

    /// The stage with its continuous values replaced. Passing its own values returns it unchanged.
    /// Usable on any thread; it may allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> HighShelf {
        guard values.count == 3 else { return self }
        let list = Array(values)
        return HighShelf(midpoint: midpoint.replacing(animatableValue: list[0]), gain: gain.replacing(animatableValue: list[1]),
                         slope: slope.replacing(animatableValue: list[2]), activation: activation)
    }

    /// Designs the shelf for the environment at the stage's position and emits its biquad.
    /// Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        _ = try StageValidation.frequency(midpoint, named: "midpoint", in: context)
        try FilterLowering.emit(try design(sampleRate: context.environment.sampleRate).secondOrderSections, into: &context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the design. Control or
    /// background context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try design(sampleRate: sampleRate).zeroPoleGain
    }

    /// True when the midpoint is stated in hertz, as a note or in mels. Usable on any thread.
    public var dependsOnSampleRate: Bool { !midpoint.dependsOnSampleRate }
}

/// A matched second-order peak (§6.3.5, WP-422): gain `gain` at `center` and 0 dB at 0 Hz, as
/// the Cookbook's peak, but following the analog peak up to the Nyquist frequency instead of
/// being forced to 0 dB there. A band that sits close to the Nyquist frequency keeps its
/// shape; in exchange the gain at the Nyquist frequency is not 0 dB. See
/// ``MatchedPeakDesign``.
///
/// ```swift
/// MatchedPeak(center: .hertz(12_000), gain: .decibels(6), bandwidth: .octaves(1))
/// ```
///
/// In a pipeline it runs on any sampled sequence, keeps its domain and adds no latency; its
/// centre is resolved against the environment at its position (ENV-2). Centre, gain and
/// bandwidth are its continuous values (ANI-2). In an `IIRSystem { }` it is an element and
/// must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing, which allocates, happens when the stage
/// is resolved or lowered: control or background context.
public struct MatchedPeak: SequenceStage, IIRSystemElement {
    /// The centre of the band. Usable on any thread.
    public let center: Frequency
    /// The gain at the centre. Usable on any thread.
    public let gain: Amplification
    /// The width of the band. Usable on any thread.
    public let bandwidth: Bandwidth
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(center: Frequency, gain: Amplification, bandwidth: Bandwidth, activation: StageActivation) {
        self.center = center
        self.gain = gain
        self.bandwidth = bandwidth
        self.activation = activation
    }

    /// A matched peak. Usable on any thread.
    ///
    /// - Parameters:
    ///   - center: The centre of the band, resolved against the environment (ENV-2).
    ///   - gain: The gain at the centre.
    ///   - bandwidth: The width of the band, between its two half-gain frequencies.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///     `Binding<Bool>`.
    public init(center: Frequency, gain: Amplification, bandwidth: Bandwidth, isActive: some ActivationSource = .active) {
        self.init(center: center, gain: gain, bandwidth: bandwidth, activation: isActive.stageActivation)
    }

    /// The design the stage's arguments name, at `sampleRate`. Control or background context;
    /// allocates.
    public func design(sampleRate: Double) throws(DSPError) -> MatchedPeakDesign {
        try MatchedPeakDesign(center: try center.hertz(sampleRate: sampleRate), gain: gain, bandwidth: bandwidth, sampleRate: sampleRate)
    }

    /// Centre, gain in decibels and bandwidth (ANI-2). Usable on any thread; it allocates the array
    /// it returns.
    public var parameters: [Double] { [center.animatableValue, gain.animatableValue, bandwidth.animatableValue] }

    /// The stage with its continuous values replaced. Passing its own values returns it unchanged.
    /// Usable on any thread; it may allocate.
    public func replacingParameters(_ values: ArraySlice<Double>) -> MatchedPeak {
        guard values.count == 3 else { return self }
        let list = Array(values)
        return MatchedPeak(center: center.replacing(animatableValue: list[0]), gain: gain.replacing(animatableValue: list[1]),
                           bandwidth: bandwidth.replacing(animatableValue: list[2]), activation: activation)
    }

    /// Designs the peak for the environment at the stage's position and emits its biquad.
    /// Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        _ = try StageValidation.frequency(center, named: "center", in: context)
        try FilterLowering.emit(try design(sampleRate: context.environment.sampleRate).secondOrderSections, into: &context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the design. Control or
    /// background context; allocates.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try design(sampleRate: sampleRate).zeroPoleGain
    }

    /// True when the centre is stated in hertz, as a note or in mels, or the bandwidth in
    /// hertz. Usable on any thread.
    public var dependsOnSampleRate: Bool { !center.dependsOnSampleRate || bandwidth.isAbsolute }
}
