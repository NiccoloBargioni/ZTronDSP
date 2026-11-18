import Foundation
import ZTronDSP

/// Applies a gain: the stock `Gain` re-implemented outside ZTronDSP as a `SampleProcessor`
/// (specification §5.11.1, EXT-4).
///
/// ```swift
/// ExternalGain(.decibels(-3))
/// ExternalGain(channels: [.decibels(0), .decibels(-6)])     // one amount per channel
/// ```
///
/// Every sample is multiplied by one factor, or each channel by its own. The stage runs on any
/// sampled sequence and keeps its domain; a gain of exactly 1 emits nothing, so it leaves no
/// trace in the plan. The amount, in decibels, is the stage's continuous value (ANI-2).
///
/// What it does not have that the stock stage has: a processor takes no value while it runs, so
/// a changed amount is a new processor, which the plan exchange fades in over 10 ms (SWAP-2),
/// and a processor is a fusion barrier, so adjacent gains stay two kernels (EXT-2).
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct ExternalGain: SequenceStage {
    enum Amount: Hashable, Sendable {
        case every(Amplification)
        case perChannel([Amplification])
    }

    /// What tells one gain processor from another: the factors it multiplies by.
    struct Key: Hashable, Sendable {
        let factors: [Float]
    }

    let amount: Amount
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(amount: Amount, activation: StageActivation) {
        self.amount = amount
        self.activation = activation
    }

    /// The same gain for every channel. Usable on any thread.
    ///
    /// - Parameters:
    ///   - amount: `.decibels` or `.linear`; a negative factor also inverts the signal.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ amount: Amplification, isActive: some ActivationSource = .active) {
        self.init(amount: .every(amount), activation: isActive.stageActivation)
    }

    /// A gain per channel: as many amounts as the signal has channels at the stage's position,
    /// or the plan does not compile. Usable on any thread.
    public init(channels amounts: [Amplification], isActive: some ActivationSource = .active) {
        self.init(amount: .perChannel(amounts), activation: isActive.stageActivation)
    }

    /// The amounts as they were stated: one, or one per channel. Usable on any thread;
    /// allocates.
    public var amounts: [Amplification] {
        switch amount {
        case .every(let amount): [amount]
        case .perChannel(let amounts): amounts
        }
    }

    /// The amounts in decibels (ANI-2). Usable on any thread.
    public var parameters: [Double] { amounts.map(\.animatableValue) }

    /// The stage with its amounts replaced. Passing its own values returns it unchanged.
    /// Usable on any thread.
    public func replacingParameters(_ values: ArraySlice<Double>) -> ExternalGain {
        let current = amounts
        guard values.count == current.count else { return self }
        let replaced = zip(current, values).map { $0.replacing(animatableValue: $1) }
        switch amount {
        case .every: return ExternalGain(amount: .every(replaced[0]), activation: activation)
        case .perChannel: return ExternalGain(amount: .perChannel(replaced), activation: activation)
        }
    }

    /// Emits the gain processor. Control context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an amount that is not finite in single
    ///   precision, and for a number of per-channel amounts other than the number of channels
    ///   at the stage's position.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        let factors: [Float]
        switch amount {
        case .every(let amount):
            let factor = Float(amount.linear)
            guard factor.isFinite else { throw context.invalid("amount", "\(amount) is not a finite factor") }
            factors = [Float](repeating: factor, count: max(context.channelCount, 1))
        case .perChannel(let amounts):
            guard amounts.count == context.channelCount else {
                throw context.invalid("channels", "\(amounts.count) gains for a signal of \(context.channelCount) channel(s) at this position")
            }
            factors = amounts.map { Float($0.linear) }
            guard factors.allSatisfy(\.isFinite) else { throw context.invalid("channels", "an amount is not a finite factor") }
        }
        // A gain of exactly 1 does nothing: it emits nothing, as the stock identity is removed (F4).
        guard factors.contains(where: { $0 != 1 }) else { return }
        context.emit(.processor(CustomProcessor(name: "ExternalGain", key: Key(factors: factors), latencyFrames: 0) {
            _ throws(DSPError) -> any SampleProcessor in
            try ExternalGainProcessor(factors: factors)
        }))
    }
}

/// What runs an `ExternalGain`: every channel of a block multiplied in place by its factor.
///
/// Threading: created on the control context, where it allocates its factors once. `process`
/// and `reset` belong to the analysis thread and allocate nothing, take no lock and log
/// nothing (RT-2). One thread at a time.
public final class ExternalGainProcessor: SampleProcessor {
    private let factors: AlignedBuffer<Float>
    private let channelCount: Int

    /// A processor for as many channels as there are factors. Control context; allocates.
    ///
    /// - Throws: `DSPError.resourceAllocationFailed` when memory cannot be had.
    public init(factors: [Float]) throws(DSPError) {
        self.factors = try AlignedBuffer<Float>(copying: factors)
        self.channelCount = factors.count
    }

    /// A gain delays nothing. Any thread.
    public var latencyFrames: Int { 0 }
    /// A gain has no memory to settle. Any thread.
    public var settlingFrames: Int { 0 }

    /// Multiplies the block in place. Analysis thread; allocation-free.
    public func process(_ block: inout AudioBlock) {
        let frames = block.frameCount
        let table = factors.baseAddress
        var channel = 0
        while channel < block.channelCount, channel < channelCount {
            let samples = block.channel(channel)
            // The toolkit's scaling: vDSP from 512 frames up, a plain loop below; the same floats.
            Vector.scale(samples, by: table[channel], into: samples, count: frames)
            channel &+= 1
        }
    }

    /// Nothing to forget. Analysis thread; allocation-free.
    public func reset() {}
}

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by a gain, the same for every channel. See ``ExternalGain``.
    /// Usable on any thread.
    public func externalGain(_ amount: Amplification, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(ExternalGain(amount, isActive: isActive))
    }

    /// The pipeline followed by a gain per channel. See ``ExternalGain``. Usable on any thread.
    public func externalGain(channels amounts: [Amplification], isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(ExternalGain(channels: amounts, isActive: isActive))
    }
}

extension PipelineBuilder {
    /// Catches the gain after a domain it does not run on, with a sentence that names it
    /// (ORD-4). Without this overload the stage gets the sentence the core has for every
    /// sequence stage, which names the kind and not the stage.
    @available(*, unavailable, message: "ExternalGain runs on a sampled sequence: samples, a novelty curve or a scalar track. It cannot follow a spectrum or any other frame of bins: put it before the transform.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ExternalGain) -> Pipeline<I, O> { accumulated }
}
