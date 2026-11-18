import Foundation
import ZTronDSPCore

/// Applies a gain (§6.2): every sample is multiplied by one factor, or each channel by its
/// own.
///
/// ```swift
/// Gain(.decibels(-3))
/// Gain(.linear(0.5), ramp: 0.050)
/// Gain(channels: [.decibels(0), .decibels(-6)])        // one amount per channel
/// ```
///
/// A changed amount never produces a step: the running gain moves to its new value linearly
/// over `ramp` seconds (CLICK-1). Adjacent gains are applied by one kernel (F1); a gain is
/// never folded into a filter, so that it can still ramp. A gain of exactly 1 is removed from
/// the plan (F4).
///
/// The stage runs on any sampled sequence and keeps its domain; on a novelty curve or a
/// scalar track there is one channel. The amount, in decibels, is the stage's continuous
/// value (ANI-2).
///
/// An immutable value, usable on any thread.
public struct Gain: SequenceStage {
    enum Amount: Hashable, Sendable {
        case every(Amplification)
        case perChannel([Amplification])
    }

    let amount: Amount
    /// The time a changed amount takes to arrive, in seconds. Usable on any thread.
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
    public func replacingParameters(_ values: ArraySlice<Double>) -> Gain {
        let current = amounts
        guard values.count == current.count else { return self }
        let replaced = zip(current, values).map { $0.replacing(animatableValue: $1) }
        switch amount {
        case .every: return Gain(amount: .every(replaced[0]), ramp: ramp, activation: activation)
        case .perChannel: return Gain(amount: .perChannel(replaced), ramp: ramp, activation: activation)
        }
    }

    /// Emits the gain kernel. Control context.
    ///
    /// - Throws: `DSPError.invalidParameter` for an amount that is not finite in single
    ///   precision, a ramp that is negative or not finite, and a number of per-channel
    ///   amounts other than the number of channels here.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard ramp.isFinite, ramp >= 0 else {
            throw context.invalid("ramp", "a ramp lasts a finite time that is not negative, not \(ramp) s")
        }
        switch amount {
        case .every(let amount):
            let factor = Float(amount.linear)
            guard factor.isFinite else { throw context.invalid("amount", "\(amount) is not a finite factor") }
            context.emit(.gain(factor: factor, ramp: ramp))
        case .perChannel(let amounts):
            guard amounts.count == context.channelCount else {
                throw context.invalid("channels", "\(amounts.count) gains for a signal of \(context.channelCount) channel(s) at this position")
            }
            let factors = amounts.map { Float($0.linear) }
            guard factors.allSatisfy(\.isFinite) else { throw context.invalid("channels", "an amount is not a finite factor") }
            context.emit(.channelGains(factors: factors, ramp: ramp))
        }
    }
}
