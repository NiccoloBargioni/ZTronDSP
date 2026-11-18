import ZTronDSPCore

/// Runs a system designed declaratively: an `IIRSystem` or an `FIRSystem` (§6.3.7).
///
/// ```swift
/// Pipeline {
///     Filter(hum)             // an IIRSystem: second-order sections
///     Filter(antiAlias)       // an FIRSystem: taps
/// }
/// ```
///
/// The system is resolved against the environment at the stage's position when the plan is
/// compiled (ENV-1, ENV-2): a frequency of one of its elements that lies beyond the Nyquist
/// frequency there is rejected with the stage's path.
///
/// - An **IIR system** runs as second-order sections (REAL-1): all its zeros and poles paired
///   by the nearest rule, the gain spread over the sections, in the precision of the
///   environment's `biquadPrecision`, which by default is chosen by measurement (REAL-3). A
///   system with a pole on or outside the unit circle is rejected with
///   `DSPError.unstableDesign` (REAL-2). No latency.
/// - An **FIR system** runs directly up to the crossover length of the engine's table and as
///   a partitioned convolution above it (REAL-4). Its latency is that of a linear-phase
///   filter, `(K − 1) / 2` samples, when its taps are symmetric or antisymmetric (REAL-5).
///
/// The stage runs on any sampled sequence and keeps its domain. `isActive:` switches the
/// whole system: the elements of a system have no switch of their own (ACT-1). The
/// continuous values of the elements are the stage's (ANI-2).
///
/// An immutable value, usable on any thread. The system is resolved when the stage is
/// lowered: control context.
public struct Filter: SequenceStage {
    enum System: Hashable, Sendable {
        case iir(IIRSystem)
        case fir(FIRSystem)
    }

    let system: System
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(system: System, activation: StageActivation) {
        self.system = system
        self.activation = activation
    }

    /// Runs an IIR system. Usable on any thread.
    ///
    /// - Parameter isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///   `Binding<Bool>`.
    public init(_ system: IIRSystem, isActive: some ActivationSource = .active) {
        self.init(system: .iir(system), activation: isActive.stageActivation)
    }

    /// Runs an FIR system. Usable on any thread.
    ///
    /// - Parameter isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI
    ///   `Binding<Bool>`.
    public init(_ system: FIRSystem, isActive: some ActivationSource = .active) {
        self.init(system: .fir(system), activation: isActive.stageActivation)
    }

    /// The continuous values of the system's elements, in order (ANI-2). Usable on any thread.
    public var parameters: [Double] {
        switch system {
        case .iir(let system): system.parameters
        case .fir(let system): system.parameters
        }
    }

    /// The stage with the continuous values of its system replaced. Passing its own values
    /// returns it unchanged. Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> Filter {
        switch system {
        case .iir(let system): Filter(system: .iir(system.replacingParameters(values)), activation: activation)
        case .fir(let system): Filter(system: .fir(system.replacingParameters(values)), activation: activation)
        }
    }

    /// Resolves the system for the environment at the stage's position and emits its cascade
    /// or its taps. Control context; allocates.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rate = context.environment.sampleRate
        switch system {
        case .iir(let system):
            try FilterLowering.emit(try system.secondOrderSections(sampleRate: rate), into: &context)
        case .fir(let system):
            try FilterLowering.emit(taps: try system.taps(sampleRate: rate), into: &context)
        }
    }
}
