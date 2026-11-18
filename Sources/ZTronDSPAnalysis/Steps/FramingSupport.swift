import Foundation
import ZTronDSPCore

// What the framing steps share when they are lowered (control context): the window as a step
// applies it, the channel a step reads, and the overlap-add sums of a window and a hop.

/// The window of a framing step, sampled once (§5.11.4).
struct SampledWindow {
    /// The samples in double precision: what gains and sums are computed from.
    let double: [Double]
    /// The samples in single precision. For the windows vDSP generates these are the output of
    /// the single-precision vDSP call, bit for bit (WIN-1).
    let single: [Float]

    /// - Throws: `invalidParameter` for a half window, and whatever sampling throws (WIN-3).
    init(_ window: Window, frame: Int) throws(DSPError) {
        guard !window.isHalf else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "\(window) covers the first half of a frame only: a framing step needs a window over the whole frame")
        }
        double = try window.doubleSamples(count: frame)
        single = try window.samples(count: frame)
        // coverage:ignore(a Window returns as many samples as it is asked for; the guard keeps a taper of another length away from the nodes)
        guard double.count == frame, single.count == frame else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "\(window) gives \(single.count) samples for a frame of \(frame)")
        }
    }

    /// The window times `factor`, as a step multiplies frames by it.
    func taper(factor: Double) -> [Float] {
        factor == 1 ? single : double.map { Float($0 * factor) }
    }
}

/// The channel a framing step reads (`ChannelPolicy`, §5.3).
enum ChannelSelection {
    /// `nil` for the mean of all channels, or the index of the one channel to read.
    ///
    /// A spectral scope carries one sequence of frames (ENV-1), so `.perChannel` is accepted
    /// where the signal has one channel and refused where it has more: tap the signal once
    /// per channel instead, with `.channel(n)`.
    static func resolve(_ policy: ChannelPolicy, in context: LoweringContext) throws(DSPError) -> Int? {
        let count = max(context.environment.channelCount, 1)
        switch policy {
        case .mixdown:
            return nil
        case .channel(let index):
            guard index >= 0, index < count else {
                throw context.invalid("channels", "channel \(index) does not exist: the signal has \(count) channel\(count == 1 ? "" : "s") here, numbered from 0")
            }
            return count == 1 ? nil : index
        case .perChannel:
            guard count == 1 else {
                throw DSPError.unsupportedConfiguration(
                    reason: "the frames of \(count) channels cannot travel down one branch: use one Tap per channel, each with channels: .channel(n)",
                    stage: context.path)
            }
            return nil
        }
    }
}

/// The sums of a window over shifts by a hop: what the overlap-add conditions are read from
/// (§6.13, WIN-4).
enum OverlapAdd {
    /// `Σₖ w(n − k·hop)^power` for `n` in `0 ..< hop`: one period of the sum.
    static func sums(_ window: [Double], hop: Int, power: Int) -> [Double] {
        guard hop >= 1 else { return [] }
        var result = [Double](repeating: 0, count: min(hop, max(window.count, 1)))
        for (index, value) in window.enumerated() {
            result[index % result.count] += power == 2 ? value * value : value
        }
        return result
    }

    /// The least and the greatest value of `Σₖ w²(n − k·hop)`: the frame bounds A and B of
    /// the pair. A sample no frame reaches (a hop above the frame) counts as a sum of 0.
    static func frameBounds(_ window: [Double], hop: Int) -> (least: Double, greatest: Double) {
        let squares = sums(window, hop: min(hop, max(window.count, 1)), power: 2)
        let least = hop > window.count ? 0 : (squares.min() ?? 0)
        return (least, squares.max() ?? 0)
    }

    /// The least sum that still counts as non-zero, as a fraction of the greatest.
    static let nonZeroFloor = 1e-10

    static func isNonZero(_ bounds: (least: Double, greatest: Double)) -> Bool {
        bounds.greatest > 0 && bounds.least > nonZeroFloor * bounds.greatest
    }
}
