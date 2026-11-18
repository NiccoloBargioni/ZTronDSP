import Foundation
import ZTronDSPCore

/// Where a frame sits on the signal it is cut from, and what its time means (§6.4.1). One
/// answer to one question (§5.3): framing steps, and the steps that keep a history of
/// frames, take it where they are declared.
///
/// An immutable value, usable on any thread.
public enum FrameAlignment: Hashable, Sendable {
    /// The frame ends at the newest sample. No latency is added; the frame's time is the time
    /// of its last sample. Frame `k` holds samples `k·hop ..< k·hop + frame`.
    case causal
    /// Frame `k` is centred on sample `k·hop`, with the signal reflected at its start
    /// (`x[−n] = x[n]`, the edge sample not repeated). The latency is half a frame; the
    /// frame's time is the time of its centre. This is what offline tools called with the
    /// same arguments compute.
    case centered
}

/// The factor a framing step applies for its window (§6.4.1). One answer to one question
/// (§5.3).
///
/// With `w` the window, `N` its length and `M` the transform length:
///
/// | Case | Factor on each bin | A reading |
/// |---|---|---|
/// | `.none` | 1 | The DFT of the windowed frame as it is. |
/// | `.amplitude` | `2 / Σw` | A full-scale sine at a bin centre reads magnitude 1: 0 dBFS. |
/// | `.power` | `√(2 / (M·Σw²))` | The squared magnitudes of the bins add up to the mean square of the signal under the window. |
///
/// The factor is the same for every bin: bin 0 and the Nyquist bin, which have no mirror
/// image, therefore read twice their one-sided share under `.amplitude` and `.power`.
///
/// An immutable value, usable on any thread.
public enum WindowNormalization: Hashable, Sendable {
    case none
    case amplitude
    case power

    /// The factor for a window given by its samples and a transform of `transformLength`
    /// points.
    ///
    /// - Throws: `DSPError.invalidParameter` when the window has nothing to normalise by: no
    ///   sum for `.amplitude`, no energy for `.power`.
    public func factor(window: [Double], transformLength: Int) throws(DSPError) -> Double {
        switch self {
        case .none:
            return 1
        case .amplitude:
            let sum = window.reduce(0, +)
            let peak = window.reduce(0) { Swift.max($0, abs($1)) }
            // A sum that is the round-off of its terms is no gain to divide by: the test is
            // the one `WindowAnalysis.amplitudeNormalization` makes (§7.5 row 21).
            guard abs(sum) > WindowAnalysis.Limit.sameValue * Double(window.count) * peak, sum.isFinite else {
                throw .invalidParameter(stage: .none, parameter: "normalization", reason: "the window sums to \(sum): it has no coherent gain to normalise an amplitude by")
            }
            return 2 / abs(sum)
        case .power:
            let energy = window.reduce(0) { $0 + $1 * $1 }
            guard energy > 0, energy.isFinite, transformLength >= 1 else {
                throw .invalidParameter(stage: .none, parameter: "normalization", reason: "the window has an energy of \(energy): there is nothing to normalise a power by")
            }
            return (2 / (Double(transformLength) * energy)).squareRoot()
        }
    }
}

/// A band of frequencies, from one frequency up to another, each in whichever unit it was
/// stated (§6.1): what the steps that work inside a range take as `range:`.
///
/// ```swift
/// MelScale(bands: 40, range: .hertz(80 ... 8_000))
/// CepstralPitch(range: FrequencyRange(from: .midiNote(36), to: .midiNote(84)))
/// ```
///
/// Like a `Frequency`, a range is resolved against the environment when the plan is compiled
/// (ENV-2): construction never fails. An immutable value, usable on any thread.
public struct FrequencyRange: Hashable, Sendable, CustomStringConvertible {
    public let lowerBound: Frequency
    public let upperBound: Frequency

    public init(from lowerBound: Frequency, to upperBound: Frequency) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// A range in hertz.
    public static func hertz(_ range: ClosedRange<Double>) -> FrequencyRange {
        FrequencyRange(from: .hertz(range.lowerBound), to: .hertz(range.upperBound))
    }

    /// The range in hertz at `sampleRate`.
    ///
    /// - Throws: `DSPError.invalidParameter` when a bound cannot be resolved, or when the
    ///   lower bound does not lie below the upper one.
    public func hertz(sampleRate: Double) throws(DSPError) -> ClosedRange<Double> {
        let low = try lowerBound.hertz(sampleRate: sampleRate)
        let high = try upperBound.hertz(sampleRate: sampleRate)
        guard low < high else {
            throw .invalidParameter(stage: .none, parameter: "range", reason: "the range runs from \(low) Hz to \(high) Hz; its lower bound must lie below its upper bound")
        }
        return low ... high
    }

    public var description: String { "\(lowerBound) … \(upperBound)" }
}
