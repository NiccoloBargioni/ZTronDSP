import Foundation
import ZTronDSP

/// Applies a gain: the stock `Gain` re-implemented outside ZTronDSP as a `SampleProcessor`
/// (specification §5.11.1, EXT-4).
///
/// ```swift
/// ExternalGain(.decibels(-3))
/// ExternalGain(.linear(0.5), ramp: 0.050)
/// ExternalGain(channels: [.decibels(0), .decibels(-6)])     // one amount per channel
/// ```
///
/// Every sample is multiplied by one factor, or each channel by its own. The stage runs on any
/// sampled sequence and keeps its domain; a gain of exactly 1 emits nothing, so it leaves no
/// trace in the plan. The amount, in decibels, is the stage's continuous value (ANI-2).
///
/// The factors are the processor's values (`CustomProcessor(name:key:values:…)`), and the key
/// is what they leave: the length of the ramp. A changed amount is therefore a value update,
/// as for the stock gain (§5.5.4): no plan is compiled, the processor that runs is handed the
/// new factors between two blocks (`AdjustableSampleProcessor`) and moves to them over `ramp`
/// seconds, frame by frame as the stock gain kernel does, so whatever is behind it hears every
/// frame (CLICK-1). The processor reads one block and writes another
/// (`OutOfPlaceSampleProcessor`), so the plan copies nothing in front of it. What it does not
/// have that the stock stage has: a processor is a fusion barrier, so adjacent gains stay two
/// kernels (EXT-2).
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct ExternalGain: SequenceStage {
    enum Amount: Hashable, Sendable {
        case every(Amplification)
        case perChannel([Amplification])
    }

    /// What tells one gain processor from another, apart from its factors: the frames its ramp
    /// takes.
    struct Key: Hashable, Sendable {
        let rampFrames: Int
    }

    let amount: Amount
    /// The time a changed amount takes to arrive, in seconds; 0 jumps. Usable on any thread.
    public let ramp: TimeInterval
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    init(amount: Amount, ramp: TimeInterval, activation: StageActivation) {
        self.amount = amount
        self.ramp = ramp
        self.activation = activation
    }

    /// The same gain for every channel. Usable on any thread.
    ///
    /// - Parameters:
    ///   - amount: `.decibels` or `.linear`; a negative factor also inverts the signal.
    ///   - ramp: The time a changed amount takes to arrive, in seconds; 0 jumps.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(_ amount: Amplification, ramp: TimeInterval = 0.010, isActive: some ActivationSource = .active) {
        self.init(amount: .every(amount), ramp: ramp, activation: isActive.stageActivation)
    }

    /// A gain per channel: as many amounts as the signal has channels at the stage's position,
    /// or the plan does not compile. Usable on any thread.
    public init(channels amounts: [Amplification], ramp: TimeInterval = 0.010, isActive: some ActivationSource = .active) {
        self.init(amount: .perChannel(amounts), ramp: ramp, activation: isActive.stageActivation)
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
        case .every: return ExternalGain(amount: .every(replaced[0]), ramp: ramp, activation: activation)
        case .perChannel: return ExternalGain(amount: .perChannel(replaced), ramp: ramp, activation: activation)
        }
    }

    /// Emits the gain processor. Control context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for an amount that is not finite in single
    ///   precision, a ramp that is negative, not finite or more frames than a kernel counts,
    ///   and for a number of per-channel amounts other than the number of channels at the
    ///   stage's position.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard ramp.isFinite, ramp >= 0 else {
            throw context.invalid("ramp", "a ramp lasts a finite time that is not negative, not \(ramp) s")
        }
        // The ramp in frames at the rate here, the nearest, as the stock gain counts it.
        let rampFrames = (ramp * context.environment.sampleRate).rounded()
        guard rampFrames >= 0, rampFrames <= Double(UInt32.max) else {
            throw context.invalid("ramp", "a ramp of \(ramp) s at \(context.environment.sampleRate) Hz is not a number of frames a kernel can count")
        }
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
        // snippet:begin gain-values
        // The factors are the processor's values, apart from its key: another amount is sent to
        // the processor that runs, which ramps to it; another ramp is another processor. Each
        // factor is a Float, held exactly by the Double that carries it.
        let frames = Int(rampFrames)
        context.emit(.processor(CustomProcessor(name: "ExternalGain", key: Key(rampFrames: frames), values: factors.map { Double($0) }, latencyFrames: 0) {
            _, values throws(DSPError) -> any AdjustableSampleProcessor in
            try ExternalGainProcessor(factors: values.map { Float($0) }, rampFrames: frames)
        }))
        // snippet:end gain-values
    }
}

/// What runs an `ExternalGain`: every channel of a block multiplied by its factor, and a changed
/// factor reached by a linear ramp.
///
/// The ramp is the stock gain kernel's: with `left` frames of the ramp still to come after a
/// frame, that frame's gain is `target − increment · left`, and exactly `target` for the last
/// one, so a ramp lands on its target, and every frame's gain is the same whatever the sizes of
/// the blocks. Each sample is one multiplication, as in the stock kernel: the same floats.
///
/// Threading: created on the control context, where it allocates its state once. `process`,
/// `setValues` and `reset` belong to the analysis thread and allocate nothing, take no lock and
/// log nothing (RT-2). One thread at a time.
public final class ExternalGainProcessor: AdjustableSampleProcessor, OutOfPlaceSampleProcessor {
    private let channelCount: Int
    private let rampFrames: Int
    /// Per channel: the gain of the frame processed last.
    private let current: AlignedBuffer<Float>
    /// Per channel: the gain asked for last.
    private let target: AlignedBuffer<Float>
    /// Per channel: the step per frame of the ramp under way.
    private let increment: AlignedBuffer<Float>
    /// Per channel: frames of the ramp still to come; 0 at rest.
    private let remaining: AlignedBuffer<Int>

    /// A processor for as many channels as there are factors, at rest at those factors.
    /// Control context; allocates.
    ///
    /// - Parameters:
    ///   - factors: one factor per channel.
    ///   - rampFrames: the frames a changed factor takes to arrive; 0 jumps.
    /// - Throws: `DSPError.resourceAllocationFailed` when memory cannot be had.
    public init(factors: [Float], rampFrames: Int = 0) throws(DSPError) {
        channelCount = factors.count
        self.rampFrames = max(rampFrames, 0)
        current = try AlignedBuffer<Float>(copying: factors)
        target = try AlignedBuffer<Float>(copying: factors)
        increment = try AlignedBuffer<Float>(count: factors.count)
        remaining = try AlignedBuffer<Int>(count: factors.count)
    }

    /// A gain delays nothing. Any thread.
    public var latencyFrames: Int { 0 }
    /// A gain has no memory to settle. Any thread.
    public var settlingFrames: Int { 0 }

    /// Multiplies the block in place. Analysis thread; allocation-free.
    public func process(_ block: inout AudioBlock) {
        let frames = block.frameCount
        var channel = 0
        while channel < block.channelCount, channel < channelCount {
            let samples = block.channel(channel)
            apply(channel, from: UnsafePointer(samples), into: samples, frames: frames)
            channel &+= 1
        }
    }

    // snippet:begin gain-out-of-place
    /// Writes the input, multiplied, into the output: what a plan calls, with nothing copied in
    /// front of it. A channel beyond the factors passes unchanged. Analysis thread;
    /// allocation-free.
    public func process(_ input: AudioBlock, into output: inout AudioBlock) {
        let frames = input.frameCount
        var channel = 0
        while channel < input.channelCount, channel < output.channelCount {
            let source = UnsafePointer(input.channel(channel)), result = output.channel(channel)
            if channel < channelCount {
                apply(channel, from: source, into: result, frames: frames)
            } else {
                result.update(from: source, count: frames)
            }
            channel &+= 1
        }
    }

    /// Takes new factors: one per channel, or one for every channel. Each channel moves from
    /// the gain it is at to its new one over the ramp. Any other count is ignored. Analysis
    /// thread, between two blocks; allocation-free.
    public func setValues(_ values: UnsafeBufferPointer<Double>) {
        guard let first = values.baseAddress, values.count == channelCount || values.count == 1 else { return }
        var channel = 0
        while channel < channelCount {
            move(channel, to: Float(first[values.count == 1 ? 0 : channel]))
            channel &+= 1
        }
    }
    // snippet:end gain-out-of-place

    /// A cold start keeps the gain asked for last and forgets the move towards it. Analysis
    /// thread; allocation-free.
    public func reset() {
        var channel = 0
        while channel < channelCount {
            current.baseAddress[channel] = target.baseAddress[channel]
            increment.baseAddress[channel] = 0
            remaining.baseAddress[channel] = 0
            channel &+= 1
        }
    }

    /// Starts a move of one channel from the gain it is at to `goal`.
    private func move(_ channel: Int, to goal: Float) {
        target.baseAddress[channel] = goal
        let now = current.baseAddress[channel]
        if rampFrames == 0 || goal == now {
            current.baseAddress[channel] = goal
            increment.baseAddress[channel] = 0
            remaining.baseAddress[channel] = 0
        } else {
            increment.baseAddress[channel] = (goal - now) / Float(rampFrames)
            remaining.baseAddress[channel] = rampFrames
        }
    }

    /// One channel of a block: the frames of a ramp under way, then the gain at rest.
    @inline(__always)
    private func apply(_ channel: Int, from source: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        var left = remaining.baseAddress[channel]
        if left > 0 {
            let goal = target.baseAddress[channel], step = increment.baseAddress[channel]
            var gain = current.baseAddress[channel]
            while left > 0, done < frames {
                left &-= 1
                gain = left == 0 ? goal : goal - step * Float(left)
                result[done] = source[done] * gain
                done &+= 1
            }
            current.baseAddress[channel] = gain
            remaining.baseAddress[channel] = left
        }
        if done < frames {
            // The toolkit's scaling: vDSP from 512 frames up, a plain loop below; the same floats.
            Vector.scale(source + done, by: current.baseAddress[channel], into: result + done, count: frames - done)
        }
    }
}

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by a gain, the same for every channel. See ``ExternalGain``.
    /// Usable on any thread.
    public func externalGain(_ amount: Amplification, ramp: TimeInterval = 0.010, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(ExternalGain(amount, ramp: ramp, isActive: isActive))
    }

    /// The pipeline followed by a gain per channel. See ``ExternalGain``. Usable on any thread.
    public func externalGain(channels amounts: [Amplification], ramp: TimeInterval = 0.010, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(ExternalGain(channels: amounts, ramp: ramp, isActive: isActive))
    }
}

extension PipelineBuilder {
    /// Catches the gain after a domain it does not run on, with a sentence that names it
    /// (ORD-4). Without this overload the stage gets the sentence the core has for every
    /// sequence stage, which names the kind and not the stage.
    @available(*, unavailable, message: "ExternalGain runs on a sampled sequence: samples, a novelty curve or a scalar track. It cannot follow a spectrum or any other frame of bins: put it before the transform.")
    public static func buildPartialBlock<I, O>(accumulated: Pipeline<I, O>, next: ExternalGain) -> Pipeline<I, O> { accumulated }
}
