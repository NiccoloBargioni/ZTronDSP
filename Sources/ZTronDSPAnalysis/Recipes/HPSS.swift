import Foundation
import ZTronDSPCore

/// Harmonic–percussive source separation on the main line: samples in, one component out
/// (§5.2, §6.10). It is `STFT; HarmonicPercussive(select:); InverseSTFT`, the synthesis
/// matched to the analysis, and nothing else.
///
/// ```swift
/// Pipeline {
///     HPSS(select: .percussive)                        // the drums of the signal
///     Level(.peak, to: $drumLevel)
/// }
/// @State private var solo = true
/// Pipeline { HPSS(select: .harmonic, timeKernel: 17, frequencyKernel: 17, isActive: $solo) }
/// ```
///
/// - The component is resynthesised with the phase of the signal, by overlap-add. The three
///   components add up to the signal again.
/// - **Latency.** The round trip through the transform delays the signal by `frame − hop`
///   samples, the time a sample waits for the last frame that covers it (half a frame, where
///   the hop is longer than that); with `alignment: .centered` the look-ahead of the time
///   median, `(timeKernel − 1) / 2` hops, comes on top. The recipe declares the sum (REAL-5):
///   one frame, less a hop, plus the look-ahead. The output begins with that many zeros.
/// - **The start of the stream.** A masked first frame must not be divided by the edge of one
///   window, so the recipe frames the signal in the way that gives its first samples full
///   window sums: centred, with the start of the signal reflected, when the median is causal;
///   causal, behind the frames of silence a centred median begins with, when it is centred,
///   in which case the first `frame − hop` samples of the component fade in. The latency is
///   the same either way.
/// - **Switching.** With a constant `isActive: false` the recipe is compiled away and the
///   signal passes. With a bound switch it is bypassed as a whole: a cross-fade of 10 ms
///   between the component and the signal delayed by the recipe's latency, so that nothing
///   downstream moves in time and nothing clicks (ACT-7, ACT-8); switched on again it starts
///   cold, is pre-rolled and is faded in.
/// - The output is one channel: a signal of several channels is mixed down by the transform,
///   or reduced as `channels` says. A recipe that reduces the channels cannot be bypassed,
///   since the signal that would pass has more of them: its switch then suspends what follows
///   instead (ACT-3).
/// - `window` and `hop` have to satisfy the overlap-add condition of `InverseSTFT` (O-17).
///
/// A pipeline that holds the recipe equals one that holds its expansion, wrapped in a `Group`
/// when it carries a switch. An immutable value, usable on any thread.
public struct HPSS: Recipe {
    public typealias Input = Samples
    public typealias Output = Samples

    public let expansion: Pipeline<Samples, Samples>
    public let activation: StageActivation

    public init(
        select component: HarmonicPercussiveComponent, frame: Int = 2_048, hop: Int = 512, window: Window = .hann, timeKernel: Int = 31,
        frequencyKernel: Int = 31, mask: some MaskStrategy = .soft(power: 2), harmonicMargin: Double = 1, percussiveMargin: Double = 1,
        alignment: FrameAlignment = .causal, median: some MedianStrategy = .selectionNetwork, channels: ChannelPolicy = .mixdown,
        isActive: some ActivationSource = .active
    ) {
        activation = isActive.stageActivation
        // The framing that gives the first samples of the stream full window sums: see above.
        let analysis = STFT(frame: frame, hop: hop, window: window, alignment: alignment == .centered ? .causal : .centered, channels: channels)
        let separated = Pipeline {
            analysis
            HarmonicPercussive(
                select: component, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask, harmonicMargin: harmonicMargin,
                percussiveMargin: percussiveMargin, alignment: alignment, median: median)
            analysis.inverse
        }
        // One switch for the three steps: they are bypassed, or compiled away, as one.
        expansion = activation == .active ? separated : Pipeline { Group(isActive: isActive) { separated } }
    }
}

extension Pipeline where Output == Samples {
    /// One component of the signal, resynthesised: see ``HPSS``.
    public func hpss(
        select component: HarmonicPercussiveComponent, frame: Int = 2_048, hop: Int = 512, window: Window = .hann, timeKernel: Int = 31,
        frequencyKernel: Int = 31, mask: some MaskStrategy = .soft(power: 2), harmonicMargin: Double = 1, percussiveMargin: Double = 1,
        alignment: FrameAlignment = .causal, median: some MedianStrategy = .selectionNetwork, channels: ChannelPolicy = .mixdown,
        isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Samples> {
        appending(HPSS(
            select: component, frame: frame, hop: hop, window: window, timeKernel: timeKernel, frequencyKernel: frequencyKernel, mask: mask,
            harmonicMargin: harmonicMargin, percussiveMargin: percussiveMargin, alignment: alignment, median: median, channels: channels,
            isActive: isActive))
    }
}
