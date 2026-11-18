import ZTronDSPCore

// The four response stages of §6.3.2 and §6.3.3: LowPass, HighPass, BandPass, BandStop. Each is
// a value around `ResponseCore`: a sequence stage in a pipeline and an element of a system
// builder (§6.3.7). The four differ in the response they name and in the labels of their edges.

/// A low-pass filter: passes what lies below its cutoff (§6.3.2, §6.3.3).
///
/// The first argument is the design: an IIR `FilterFamily` or an FIR `FIRDesignMethod`
/// (§6.3.3). The size of the filter is given in one of three ways each:
///
/// ```swift
/// LowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
/// LowPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(24))
/// LowPass(.butterworth, passband: .hertz(1_000), stopband: .hertz(2_000),
///        maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
///
/// LowPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255)
/// LowPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
/// LowPass(.windowedSinc(), passband: .hertz(4_000), stopband: .hertz(5_000),
///        maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80))
/// ```
///
/// **What the cutoff is.** For an IIR family, the edge of the family's prototype: the −3 dB
/// point of a Butterworth filter, the end of the ripple band of a Chebyshev I or elliptic
/// one, the start of the stop band of a Chebyshev II one. For an FIR method with a length,
/// the frequency at which the amplitude is one half. With a roll-off, an FIR cutoff is the
/// edge of the pass band (§6.3.4).
///
/// **In a pipeline** the stage runs on any sampled sequence and keeps its domain. Its
/// frequencies are resolved against the environment at its position when the plan is
/// compiled; an edge at or beyond the Nyquist frequency there is rejected with the stage's
/// path (ENV-2, O-16), as is an FIR roll-off whose stop band would not fit (O-17). An IIR
/// design runs as second-order sections with its gain spread over them, in the precision of
/// the environment's `biquadPrecision`, which by default is chosen by measurement (REAL-1,
/// REAL-3); it adds no latency. An FIR design runs directly or as a partitioned convolution
/// by its length (REAL-4) and reports a latency of `(K − 1) / 2` samples (REAL-5).
///
/// **Animation.** The frequencies are the stage's continuous values (ANI-2). A filter given
/// by an order or a length keeps its topology while they move, so a cutoff can glide; a
/// filter given by a tolerance scheme, or an FIR filter given by a roll-off, changes its
/// order or its length with them, and each such change is a new topology.
///
/// **In a system** (`IIRSystem { }`, `FIRSystem { }`) the same value is an element; there it
/// must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing happens when the stage is resolved or
/// lowered: control or background context.
public struct LowPass: SequenceStage, IIRSystemElement, FIRSystemElement {
    let core: ResponseCore
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(core: ResponseCore, activation: StageActivation) {
        self.core = core
        self.activation = activation
    }

    // MARK: IIR

    /// An IIR filter of the given family and order. Usable on any thread.
    ///
    /// - Parameters:
    ///   - family: `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`,
    ///     `.elliptic(ripple:stopband:)`, `.bessel(normalization:)`, or a family of your own.
    ///   - cutoff: The edge of the family's prototype.
    ///   - order: The order of the filter: it has that many poles.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ family: some FilterFamily, cutoff: Frequency, order: Int, isActive: some ActivationSource = .active) {
        self.init(core: ResponseCore(.lowPass, family: family, edges: [cutoff], size: .order(order)), activation: isActive.stageActivation)
    }

    /// An IIR filter whose order is given as a roll-off (§6.3.4): one order is 6.02 dB per
    /// octave. For Butterworth, Chebyshev I and Bessel
    /// filters it is the slope of the skirt well below the Nyquist frequency: within ±0.5 dB
    /// per octave in octaves that end at or below a thirty-second of the sample rate, steeper
    /// above, where the bilinear transform puts the zeros. For Chebyshev II and elliptic filters the
    /// roll-off is nominal: it selects the order whose all-pole counterpart has that slope.
    /// Usable on any thread.
    ///
    /// - Parameter rounding: What to do with a slope that is not a whole number of orders:
    ///   `.exact()` (the default) rejects it when the plan is compiled, `.nearest` rounds,
    ///   `.up` takes the next order.
    public init(
        _ family: some FilterFamily, cutoff: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.lowPass, family: family, edges: [cutoff], size: .rollOff(rollOff, rounding)), activation: isActive.stageActivation)
    }

    /// The IIR filter of the lowest order that meets a tolerance scheme (§6.3.2): at most
    /// `maximumLoss` up to the pass-band edge and at least `minimumAttenuation` from the
    /// stop-band edge. The pass-band edge lies below the
    /// stop-band edge. The family's `FilterOrderStrategy`
    /// finds the order and the natural frequency; the ripple and the attenuation of the
    /// family are those of the scheme. Bessel has no order estimation and is rejected when
    /// the plan is compiled. Usable on any thread.
    public init(
        _ family: some FilterFamily, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.lowPass, family: family, edges: [passband],
                                     size: .scheme(stopband: [stopband], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: FIR

    /// A linear-phase FIR filter of `length` taps. Usable on any thread.
    ///
    /// - Parameters:
    ///   - method: `.windowedSinc(window:)`, `.leastSquares`, or a method of your own.
    ///   - cutoff: The frequency at which the amplitude is one half.
    ///   - transition: The width of the transition band, centred on the cutoff, for a method
    ///     that takes one: `.leastSquares` needs it; `.windowedSinc()` without a window chooses
    ///     its Kaiser β from it.
    ///   - length: The number of taps.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(
        _ method: some FIRDesignMethod, cutoff: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.lowPass, method: method, edges: [cutoff], size: .length(length, transition: transition)),
                  activation: isActive.stageActivation)
    }

    /// A linear-phase FIR filter whose steepness is given as a roll-off (§6.3.4): the average
    /// slope across the transition band, from the pass-band edge `cutoff` down to the
    /// attenuation `stopband`. The stop band starts `A / slope`
    /// octaves above the cutoff; a stop band that would start at or beyond the Nyquist
    /// frequency is rejected when the plan is compiled, with the smallest slope that fits. The length follows from the
    /// method's estimate and is raised until the measured response meets the request. Usable
    /// on any thread.
    public init(
        _ method: some FIRDesignMethod, cutoff: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.lowPass, method: method, edges: [cutoff], size: .slope(rollOff, attenuation: stopband)),
                  activation: isActive.stageActivation)
    }

    /// The shortest linear-phase FIR filter the search finds that meets a tolerance scheme:
    /// within `maximumLoss` of unity gain up to the pass-band edge and at least
    /// `minimumAttenuation` down from the stop-band edge. The pass-band edge lies below the
    /// stop-band edge. Usable
    /// on any thread.
    public init(
        _ method: some FIRDesignMethod, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.lowPass, method: method, edges: [passband],
                                     size: .scheme(stopband: [stopband], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: What the stage is

    /// The design the stage's arguments name, at `sampleRate`: an `IIRDesign` for a family, an
    /// `FIRDesign` for a method. Control or background context; allocates.
    ///
    /// - Throws: what the design throws for values that make no filter at this rate.
    public func design(sampleRate: Double) throws(DSPError) -> FilterDesign {
        try core.resolve(sampleRate: sampleRate)
    }

    /// The frequencies the stage states, each as its `animatableValue`, in the order of its
    /// arguments (ANI-2). Usable on any thread.
    public var parameters: [Double] { core.parameters }

    /// The stage with its frequencies replaced. Passing its own values returns it unchanged.
    /// Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> LowPass {
        LowPass(core: core.replacingParameters(values), activation: activation)
    }

    /// Designs the filter for the environment at the stage's position and emits its cascade or
    /// its taps. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try core.lower(&context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the IIR design. Control
    /// or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an FIR form.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try core.zeroPoleGain(sampleRate: sampleRate)
    }

    /// As an element of an `FIRSystem`: the taps of the FIR design. Control or background
    /// context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an IIR form, which has poles away from the
    ///   origin.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        try core.taps(sampleRate: sampleRate)
    }

    /// True when a frequency of the stage is stated in hertz, as a note or in mels. Usable on
    /// any thread.
    public var dependsOnSampleRate: Bool { core.dependsOnSampleRate }
}

/// A high-pass filter: passes what lies above its cutoff (§6.3.2, §6.3.3).
///
/// The first argument is the design: an IIR `FilterFamily` or an FIR `FIRDesignMethod`
/// (§6.3.3). The size of the filter is given in one of three ways each:
///
/// ```swift
/// HighPass(.butterworth, cutoff: .hertz(1_000), order: 4)
/// HighPass(.butterworth, cutoff: .hertz(1_000), rollOff: .decibelsPerOctave(24))
/// HighPass(.butterworth, passband: .hertz(2_000), stopband: .hertz(1_000),
///        maximumLoss: .decibels(1), minimumAttenuation: .decibels(40))
///
/// HighPass(.windowedSinc(window: .kaiser(beta: 8.6)), cutoff: .hertz(4_000), length: 255)
/// HighPass(.windowedSinc(), cutoff: .hertz(4_000), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
/// HighPass(.windowedSinc(), passband: .hertz(5_000), stopband: .hertz(4_000),
///        maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80))
/// ```
///
/// **What the cutoff is.** For an IIR family, the edge of the family's prototype: the −3 dB
/// point of a Butterworth filter, the end of the ripple band of a Chebyshev I or elliptic
/// one, the start of the stop band of a Chebyshev II one. For an FIR method with a length,
/// the frequency at which the amplitude is one half. With a roll-off, an FIR cutoff is the
/// edge of the pass band (§6.3.4).
///
/// **In a pipeline** the stage runs on any sampled sequence and keeps its domain. Its
/// frequencies are resolved against the environment at its position when the plan is
/// compiled; an edge at or beyond the Nyquist frequency there is rejected with the stage's
/// path (ENV-2, O-16), as is an FIR roll-off whose stop band would not fit (O-17). An IIR
/// design runs as second-order sections with its gain spread over them, in the precision of
/// the environment's `biquadPrecision`, which by default is chosen by measurement (REAL-1,
/// REAL-3); it adds no latency. An FIR design runs directly or as a partitioned convolution
/// by its length (REAL-4) and reports a latency of `(K − 1) / 2` samples (REAL-5).
///
/// **Animation.** The frequencies are the stage's continuous values (ANI-2). A filter given
/// by an order or a length keeps its topology while they move, so a cutoff can glide; a
/// filter given by a tolerance scheme, or an FIR filter given by a roll-off, changes its
/// order or its length with them, and each such change is a new topology.
///
/// **In a system** (`IIRSystem { }`, `FIRSystem { }`) the same value is an element; there it
/// must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing happens when the stage is resolved or
/// lowered: control or background context.
public struct HighPass: SequenceStage, IIRSystemElement, FIRSystemElement {
    let core: ResponseCore
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(core: ResponseCore, activation: StageActivation) {
        self.core = core
        self.activation = activation
    }

    // MARK: IIR

    /// An IIR filter of the given family and order. Usable on any thread.
    ///
    /// - Parameters:
    ///   - family: `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`,
    ///     `.elliptic(ripple:stopband:)`, `.bessel(normalization:)`, or a family of your own.
    ///   - cutoff: The edge of the family's prototype.
    ///   - order: The order of the filter: it has that many poles.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ family: some FilterFamily, cutoff: Frequency, order: Int, isActive: some ActivationSource = .active) {
        self.init(core: ResponseCore(.highPass, family: family, edges: [cutoff], size: .order(order)), activation: isActive.stageActivation)
    }

    /// An IIR filter whose order is given as a roll-off (§6.3.4): one order is 6.02 dB per
    /// octave. For Butterworth, Chebyshev I and Bessel
    /// filters it is the slope of the skirt towards 0 Hz, exactly. For Chebyshev II and elliptic filters the
    /// roll-off is nominal: it selects the order whose all-pole counterpart has that slope.
    /// Usable on any thread.
    ///
    /// - Parameter rounding: What to do with a slope that is not a whole number of orders:
    ///   `.exact()` (the default) rejects it when the plan is compiled, `.nearest` rounds,
    ///   `.up` takes the next order.
    public init(
        _ family: some FilterFamily, cutoff: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.highPass, family: family, edges: [cutoff], size: .rollOff(rollOff, rounding)), activation: isActive.stageActivation)
    }

    /// The IIR filter of the lowest order that meets a tolerance scheme (§6.3.2): at most
    /// `maximumLoss` up to the pass-band edge and at least `minimumAttenuation` from the
    /// stop-band edge. The stop-band edge lies below the
    /// pass-band edge. The family's `FilterOrderStrategy`
    /// finds the order and the natural frequency; the ripple and the attenuation of the
    /// family are those of the scheme. Bessel has no order estimation and is rejected when
    /// the plan is compiled. Usable on any thread.
    public init(
        _ family: some FilterFamily, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.highPass, family: family, edges: [passband],
                                     size: .scheme(stopband: [stopband], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: FIR

    /// A linear-phase FIR filter of `length` taps. Usable on any thread.
    ///
    /// - Parameters:
    ///   - method: `.windowedSinc(window:)`, `.leastSquares`, or a method of your own.
    ///   - cutoff: The frequency at which the amplitude is one half.
    ///   - transition: The width of the transition band, centred on the cutoff, for a method
    ///     that takes one: `.leastSquares` needs it; `.windowedSinc()` without a window chooses
    ///     its Kaiser β from it.
    ///   - length: The number of taps. Odd: a filter with an even number of taps is zero
    ///     at the Nyquist frequency, which a high-pass passes.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(
        _ method: some FIRDesignMethod, cutoff: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.highPass, method: method, edges: [cutoff], size: .length(length, transition: transition)),
                  activation: isActive.stageActivation)
    }

    /// A linear-phase FIR filter whose steepness is given as a roll-off (§6.3.4): the average
    /// slope across the transition band, from the pass-band edge `cutoff` down to the
    /// attenuation `stopband`. The stop band ends `A / slope`
    /// octaves below the cutoff, so every slope fits. The length follows from the
    /// method's estimate and is raised until the measured response meets the request. Usable
    /// on any thread.
    public init(
        _ method: some FIRDesignMethod, cutoff: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.highPass, method: method, edges: [cutoff], size: .slope(rollOff, attenuation: stopband)),
                  activation: isActive.stageActivation)
    }

    /// The shortest linear-phase FIR filter the search finds that meets a tolerance scheme:
    /// within `maximumLoss` of unity gain up to the pass-band edge and at least
    /// `minimumAttenuation` down from the stop-band edge. The stop-band edge lies below the
    /// pass-band edge. Usable
    /// on any thread.
    public init(
        _ method: some FIRDesignMethod, passband: Frequency, stopband: Frequency, maximumLoss: Amplification,
        minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.highPass, method: method, edges: [passband],
                                     size: .scheme(stopband: [stopband], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: What the stage is

    /// The design the stage's arguments name, at `sampleRate`: an `IIRDesign` for a family, an
    /// `FIRDesign` for a method. Control or background context; allocates.
    ///
    /// - Throws: what the design throws for values that make no filter at this rate.
    public func design(sampleRate: Double) throws(DSPError) -> FilterDesign {
        try core.resolve(sampleRate: sampleRate)
    }

    /// The frequencies the stage states, each as its `animatableValue`, in the order of its
    /// arguments (ANI-2). Usable on any thread.
    public var parameters: [Double] { core.parameters }

    /// The stage with its frequencies replaced. Passing its own values returns it unchanged.
    /// Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> HighPass {
        HighPass(core: core.replacingParameters(values), activation: activation)
    }

    /// Designs the filter for the environment at the stage's position and emits its cascade or
    /// its taps. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try core.lower(&context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the IIR design. Control
    /// or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an FIR form.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try core.zeroPoleGain(sampleRate: sampleRate)
    }

    /// As an element of an `FIRSystem`: the taps of the FIR design. Control or background
    /// context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an IIR form, which has poles away from the
    ///   origin.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        try core.taps(sampleRate: sampleRate)
    }

    /// True when a frequency of the stage is stated in hertz, as a note or in mels. Usable on
    /// any thread.
    public var dependsOnSampleRate: Bool { core.dependsOnSampleRate }
}

/// A band-pass filter: passes the band between its two edges (§6.3.2, §6.3.3).
///
/// The first argument is the design: an IIR `FilterFamily` or an FIR `FIRDesignMethod`
/// (§6.3.3). The size of the filter is given in one of three ways each:
///
/// ```swift
/// BandPass(.butterworth, from: .hertz(300), to: .hertz(3_400), order: 4)
/// BandPass(.butterworth, from: .hertz(300), to: .hertz(3_400), rollOff: .decibelsPerOctave(24))
/// BandPass(.elliptic(ripple: .decibels(1), stopband: .decibels(60)),
///        passband: (.hertz(300), .hertz(3_400)), stopband: (.hertz(200), .hertz(4_000)),
///        maximumLoss: .decibels(1), minimumAttenuation: .decibels(60))
///
/// BandPass(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401)
/// BandPass(.windowedSinc(), from: .hertz(300), to: .hertz(3_400), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
/// BandPass(.windowedSinc(), passband: (.hertz(300), .hertz(3_400)), stopband: (.hertz(200), .hertz(4_000)),
///        maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80))
/// ```
///
/// **What the edges are.** For an IIR family, the edges of the family's prototype mapped
/// onto the band: the −3 dB points of a Butterworth filter, the ends of the ripple band of a
/// Chebyshev I or elliptic one, the ends of the stop band of a Chebyshev II one. For an FIR
/// method with a length, the frequencies at which the amplitude is one half. With a
/// roll-off, the edges of an FIR filter are the edges of its pass band (§6.3.4).
///
/// **Order.** An IIR band filter has twice the order it is given: `order` is the order of
/// the prototype, and the filter has `2 · order` poles.
///
/// **In a pipeline** the stage runs on any sampled sequence and keeps its domain. Its
/// frequencies are resolved against the environment at its position when the plan is
/// compiled; an edge at or beyond the Nyquist frequency there is rejected with the stage's
/// path (ENV-2, O-16), as is an FIR roll-off whose stop band would not fit (O-17). An IIR
/// design runs as second-order sections with its gain spread over them, in the precision of
/// the environment's `biquadPrecision`, which by default is chosen by measurement (REAL-1,
/// REAL-3); it adds no latency. An FIR design runs directly or as a partitioned convolution
/// by its length (REAL-4) and reports a latency of `(K − 1) / 2` samples (REAL-5).
///
/// **Animation.** The frequencies are the stage's continuous values (ANI-2). A filter given
/// by an order or a length keeps its topology while they move; a filter given by a tolerance
/// scheme, or an FIR filter given by a roll-off, changes its order or its length with them,
/// and each such change is a new topology.
///
/// **In a system** (`IIRSystem { }`, `FIRSystem { }`) the same value is an element; there it
/// must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing happens when the stage is resolved or
/// lowered: control or background context.
public struct BandPass: SequenceStage, IIRSystemElement, FIRSystemElement {
    let core: ResponseCore
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(core: ResponseCore, activation: StageActivation) {
        self.core = core
        self.activation = activation
    }

    // MARK: IIR

    /// An IIR filter of the given family and order. Usable on any thread.
    ///
    /// - Parameters:
    ///   - family: `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`,
    ///     `.elliptic(ripple:stopband:)`, `.bessel(normalization:)`, or a family of your own.
    ///   - from: The lower edge of the band.
    ///   - to: The upper edge of the band.
    ///   - order: The order of the prototype: the filter has twice as many poles.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ family: some FilterFamily, from: Frequency, to: Frequency, order: Int, isActive: some ActivationSource = .active) {
        self.init(core: ResponseCore(.bandPass, family: family, edges: [from, to], size: .order(order)), activation: isActive.stageActivation)
    }

    /// An IIR filter whose prototype order is given as a roll-off (§6.3.4): one order is
    /// 6.02 dB per octave. For Butterworth, Chebyshev I and Bessel
    /// filters it is the slope of each skirt: exact towards 0 Hz, and within ±0.5 dB per
    /// octave well below the Nyquist frequency on the upper one. For Chebyshev II and elliptic
    /// filters the roll-off is nominal: it selects the order whose all-pole counterpart has
    /// that slope. Usable on any thread.
    ///
    /// - Parameter rounding: What to do with a slope that is not a whole number of orders:
    ///   `.exact()` (the default) rejects it when the plan is compiled, `.nearest` rounds,
    ///   `.up` takes the next order.
    public init(
        _ family: some FilterFamily, from: Frequency, to: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandPass, family: family, edges: [from, to], size: .rollOff(rollOff, rounding)),
                  activation: isActive.stageActivation)
    }

    /// The IIR filter of the lowest order that meets a tolerance scheme (§6.3.2): at most
    /// `maximumLoss` over the pass band and at least `minimumAttenuation` over the stop
    /// band. The stop band lies outside the pass band:
    /// `stopband.from < passband.from < passband.to < stopband.to`. The family's `FilterOrderStrategy` finds the order
    /// and the natural frequencies; the ripple and the attenuation of the family are those of
    /// the scheme. Bessel has no order estimation and is rejected when the plan is compiled.
    /// Usable on any thread.
    public init(
        _ family: some FilterFamily, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandPass, family: family, edges: [passband.from, passband.to],
                                     size: .scheme(stopband: [stopband.from, stopband.to], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: FIR

    /// A linear-phase FIR filter of `length` taps. Usable on any thread.
    ///
    /// - Parameters:
    ///   - method: `.windowedSinc(window:)`, `.leastSquares`, or a method of your own.
    ///   - from: The lower frequency at which the amplitude is one half.
    ///   - to: The upper frequency at which the amplitude is one half.
    ///   - transition: The width of each transition band, centred on its edge, for a method
    ///     that takes one: `.leastSquares` needs it; `.windowedSinc()` without a window chooses
    ///     its Kaiser β from it.
    ///   - length: The number of taps.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandPass, method: method, edges: [from, to], size: .length(length, transition: transition)),
                  activation: isActive.stageActivation)
    }

    /// A linear-phase FIR filter whose steepness is given as a roll-off (§6.3.4): the average
    /// slope across each transition band, from the pass-band edge down to the attenuation
    /// `stopband`. The stop bands start `A / slope` octaves
    /// outside the two edges; an upper stop band that would start at or beyond the Nyquist
    /// frequency is rejected when the plan is compiled, with the smallest slope that fits. The length follows from the method's
    /// estimate and is raised until the measured response meets the request. Usable on any
    /// thread.
    public init(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandPass, method: method, edges: [from, to], size: .slope(rollOff, attenuation: stopband)),
                  activation: isActive.stageActivation)
    }

    /// The shortest linear-phase FIR filter the search finds that meets a tolerance scheme:
    /// within `maximumLoss` of unity gain over the pass band and at least
    /// `minimumAttenuation` down over the stop band. The stop band lies outside the pass band:
    /// `stopband.from < passband.from < passband.to < stopband.to`. Usable on
    /// any thread.
    public init(
        _ method: some FIRDesignMethod, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandPass, method: method, edges: [passband.from, passband.to],
                                     size: .scheme(stopband: [stopband.from, stopband.to], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: What the stage is

    /// The design the stage's arguments name, at `sampleRate`: an `IIRDesign` for a family, an
    /// `FIRDesign` for a method. Control or background context; allocates.
    ///
    /// - Throws: what the design throws for values that make no filter at this rate.
    public func design(sampleRate: Double) throws(DSPError) -> FilterDesign {
        try core.resolve(sampleRate: sampleRate)
    }

    /// The frequencies the stage states, each as its `animatableValue`, in the order of its
    /// arguments (ANI-2). Usable on any thread.
    public var parameters: [Double] { core.parameters }

    /// The stage with its frequencies replaced. Passing its own values returns it unchanged.
    /// Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> BandPass {
        BandPass(core: core.replacingParameters(values), activation: activation)
    }

    /// Designs the filter for the environment at the stage's position and emits its cascade or
    /// its taps. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try core.lower(&context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the IIR design. Control
    /// or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an FIR form.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try core.zeroPoleGain(sampleRate: sampleRate)
    }

    /// As an element of an `FIRSystem`: the taps of the FIR design. Control or background
    /// context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an IIR form, which has poles away from the
    ///   origin.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        try core.taps(sampleRate: sampleRate)
    }

    /// True when a frequency of the stage is stated in hertz, as a note or in mels. Usable on
    /// any thread.
    public var dependsOnSampleRate: Bool { core.dependsOnSampleRate }
}

/// A band-stop filter: stops the band between its two edges (§6.3.2, §6.3.3).
///
/// The first argument is the design: an IIR `FilterFamily` or an FIR `FIRDesignMethod`
/// (§6.3.3). The size of the filter is given in one of three ways each:
///
/// ```swift
/// BandStop(.butterworth, from: .hertz(300), to: .hertz(3_400), order: 4)
/// BandStop(.butterworth, from: .hertz(300), to: .hertz(3_400), rollOff: .decibelsPerOctave(24))
/// BandStop(.elliptic(ripple: .decibels(1), stopband: .decibels(60)),
///        passband: (.hertz(200), .hertz(4_000)), stopband: (.hertz(300), .hertz(3_400)),
///        maximumLoss: .decibels(1), minimumAttenuation: .decibels(60))
///
/// BandStop(.leastSquares, from: .hertz(300), to: .hertz(3_400), transition: .hertz(200), length: 401)
/// BandStop(.windowedSinc(), from: .hertz(300), to: .hertz(3_400), rollOff: .decibelsPerOctave(96), stopband: .decibels(80))
/// BandStop(.windowedSinc(), passband: (.hertz(200), .hertz(4_000)), stopband: (.hertz(300), .hertz(3_400)),
///        maximumLoss: .decibels(0.1), minimumAttenuation: .decibels(80))
/// ```
///
/// **What the edges are.** For an IIR family, the edges of the family's prototype mapped
/// onto the band: the −3 dB points of a Butterworth filter, the ends of the ripple band of a
/// Chebyshev I or elliptic one, the ends of the stop band of a Chebyshev II one. For an FIR
/// method with a length, the frequencies at which the amplitude is one half. With a
/// roll-off, the edges of an FIR filter are the edges of its pass band, the lower pass band ending at `from` and
/// the upper one starting at `to` (§6.3.4).
///
/// **Order.** An IIR band filter has twice the order it is given: `order` is the order of
/// the prototype, and the filter has `2 · order` poles.
///
/// **In a pipeline** the stage runs on any sampled sequence and keeps its domain. Its
/// frequencies are resolved against the environment at its position when the plan is
/// compiled; an edge at or beyond the Nyquist frequency there is rejected with the stage's
/// path (ENV-2, O-16), as is an FIR roll-off whose stop band would not fit (O-17). An IIR
/// design runs as second-order sections with its gain spread over them, in the precision of
/// the environment's `biquadPrecision`, which by default is chosen by measurement (REAL-1,
/// REAL-3); it adds no latency. An FIR design runs directly or as a partitioned convolution
/// by its length (REAL-4) and reports a latency of `(K − 1) / 2` samples (REAL-5).
///
/// **Animation.** The frequencies are the stage's continuous values (ANI-2). A filter given
/// by an order or a length keeps its topology while they move; a filter given by a tolerance
/// scheme, or an FIR filter given by a roll-off, changes its order or its length with them,
/// and each such change is a new topology.
///
/// **In a system** (`IIRSystem { }`, `FIRSystem { }`) the same value is an element; there it
/// must keep the default `isActive` (ACT-1).
///
/// An immutable value, usable on any thread. Designing happens when the stage is resolved or
/// lowered: control or background context.
public struct BandStop: SequenceStage, IIRSystemElement, FIRSystemElement {
    let core: ResponseCore
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(core: ResponseCore, activation: StageActivation) {
        self.core = core
        self.activation = activation
    }

    // MARK: IIR

    /// An IIR filter of the given family and order. Usable on any thread.
    ///
    /// - Parameters:
    ///   - family: `.butterworth`, `.chebyshev1(ripple:)`, `.chebyshev2(stopband:)`,
    ///     `.elliptic(ripple:stopband:)`, `.bessel(normalization:)`, or a family of your own.
    ///   - from: The lower edge of the band.
    ///   - to: The upper edge of the band.
    ///   - order: The order of the prototype: the filter has twice as many poles.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ family: some FilterFamily, from: Frequency, to: Frequency, order: Int, isActive: some ActivationSource = .active) {
        self.init(core: ResponseCore(.bandStop, family: family, edges: [from, to], size: .order(order)), activation: isActive.stageActivation)
    }

    /// An IIR filter whose prototype order is given as a roll-off (§6.3.4): one order is
    /// 6.02 dB per octave. A notch has no asymptotic skirt: the
    /// gain falls without bound at the centre, and the roll-off only sets the order of the
    /// prototype. For Chebyshev II and elliptic
    /// filters the roll-off is nominal: it selects the order whose all-pole counterpart has
    /// that slope. Usable on any thread.
    ///
    /// - Parameter rounding: What to do with a slope that is not a whole number of orders:
    ///   `.exact()` (the default) rejects it when the plan is compiled, `.nearest` rounds,
    ///   `.up` takes the next order.
    public init(
        _ family: some FilterFamily, from: Frequency, to: Frequency, rollOff: RollOff, rounding: RollOffRounding = .exact(),
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandStop, family: family, edges: [from, to], size: .rollOff(rollOff, rounding)),
                  activation: isActive.stageActivation)
    }

    /// The IIR filter of the lowest order that meets a tolerance scheme (§6.3.2): at most
    /// `maximumLoss` over the pass band and at least `minimumAttenuation` over the stop
    /// band. The stop band lies inside the pass band:
    /// `passband.from < stopband.from < stopband.to < passband.to`. The family's `FilterOrderStrategy` finds the order
    /// and the natural frequencies; the ripple and the attenuation of the family are those of
    /// the scheme. Bessel has no order estimation and is rejected when the plan is compiled.
    /// Usable on any thread.
    public init(
        _ family: some FilterFamily, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandStop, family: family, edges: [passband.from, passband.to],
                                     size: .scheme(stopband: [stopband.from, stopband.to], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: FIR

    /// A linear-phase FIR filter of `length` taps. Usable on any thread.
    ///
    /// - Parameters:
    ///   - method: `.windowedSinc(window:)`, `.leastSquares`, or a method of your own.
    ///   - from: The lower frequency at which the amplitude is one half.
    ///   - to: The upper frequency at which the amplitude is one half.
    ///   - transition: The width of each transition band, centred on its edge, for a method
    ///     that takes one: `.leastSquares` needs it; `.windowedSinc()` without a window chooses
    ///     its Kaiser β from it.
    ///   - length: The number of taps. Odd: a filter with an even number of taps is zero
    ///     at the Nyquist frequency, which a band-stop passes.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, transition: Frequency? = nil, length: Int,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandStop, method: method, edges: [from, to], size: .length(length, transition: transition)),
                  activation: isActive.stageActivation)
    }

    /// A linear-phase FIR filter whose steepness is given as a roll-off (§6.3.4): the average
    /// slope across each transition band, from the pass-band edge down to the attenuation
    /// `stopband`. The stop band starts `A / slope` octaves
    /// inside each edge; two skirts that would meet before it is reached are rejected when the
    /// plan is compiled, with the smallest slope that fits. The length follows from the method's
    /// estimate and is raised until the measured response meets the request. Usable on any
    /// thread.
    public init(
        _ method: some FIRDesignMethod, from: Frequency, to: Frequency, rollOff: RollOff, stopband: Amplification,
        isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandStop, method: method, edges: [from, to], size: .slope(rollOff, attenuation: stopband)),
                  activation: isActive.stageActivation)
    }

    /// The shortest linear-phase FIR filter the search finds that meets a tolerance scheme:
    /// within `maximumLoss` of unity gain over the pass band and at least
    /// `minimumAttenuation` down over the stop band. The stop band lies inside the pass band:
    /// `passband.from < stopband.from < stopband.to < passband.to`. Usable on
    /// any thread.
    public init(
        _ method: some FIRDesignMethod, passband: (from: Frequency, to: Frequency), stopband: (from: Frequency, to: Frequency),
        maximumLoss: Amplification, minimumAttenuation: Amplification, isActive: some ActivationSource = .active
    ) {
        self.init(core: ResponseCore(.bandStop, method: method, edges: [passband.from, passband.to],
                                     size: .scheme(stopband: [stopband.from, stopband.to], maximumLoss: maximumLoss, minimumAttenuation: minimumAttenuation)),
                  activation: isActive.stageActivation)
    }

    // MARK: What the stage is

    /// The design the stage's arguments name, at `sampleRate`: an `IIRDesign` for a family, an
    /// `FIRDesign` for a method. Control or background context; allocates.
    ///
    /// - Throws: what the design throws for values that make no filter at this rate.
    public func design(sampleRate: Double) throws(DSPError) -> FilterDesign {
        try core.resolve(sampleRate: sampleRate)
    }

    /// The frequencies the stage states, each as its `animatableValue`, in the order of its
    /// arguments (ANI-2). Usable on any thread.
    public var parameters: [Double] { core.parameters }

    /// The stage with its frequencies replaced. Passing its own values returns it unchanged.
    /// Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> BandStop {
        BandStop(core: core.replacingParameters(values), activation: activation)
    }

    /// Designs the filter for the environment at the stage's position and emits its cascade or
    /// its taps. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        try core.lower(&context)
    }

    /// As an element of an `IIRSystem`: the zeros, poles and gain of the IIR design. Control
    /// or background context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an FIR form.
    public func zeroPoleGain(sampleRate: Double) throws(DSPError) -> ZeroPoleGain {
        try core.zeroPoleGain(sampleRate: sampleRate)
    }

    /// As an element of an `FIRSystem`: the taps of the FIR design. Control or background
    /// context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an IIR form, which has poles away from the
    ///   origin.
    public func taps(sampleRate: Double) throws(DSPError) -> [Double] {
        try core.taps(sampleRate: sampleRate)
    }

    /// True when a frequency of the stage is stated in hertz, as a note or in mels. Usable on
    /// any thread.
    public var dependsOnSampleRate: Bool { core.dependsOnSampleRate }
}
