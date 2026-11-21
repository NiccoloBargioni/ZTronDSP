import Accelerate
import ZTronDSPCore

/// Which part of a harmonic–percussive separation is kept (§6.10).
///
/// A value, usable on any thread; it does not allocate.
public enum HarmonicPercussiveComponent: Hashable, Sendable, CaseIterable {
    /// What lasts in time and is narrow in frequency: partials, sustained tones.
    case harmonic
    /// What is short in time and broad in frequency: onsets, drums, noise bursts.
    case percussive
    /// What the two masks leave: nothing with margins of 1 and a soft mask, more as the
    /// margins grow.
    case residual
}

/// How the medians of a harmonic–percussive separation become a mask, as a strategy (§5.3,
/// §6.10): pass `.soft(power:)` or `.hard`, or a conformer of your own, where a separation is
/// declared.
///
/// A mask says, bin by bin, which share of the spectrum goes to a component: the share of a
/// component whose median is `c` against a competitor whose median, times its margin, is `k`.
/// The harmonic mask is that of the time median against the frequency median times the
/// harmonic margin, and the percussive mask the other way round with the percussive margin;
/// what they leave is the residual.
///
/// A strategy is a description: an immutable value, usable on any thread, and part of the
/// description of the stage that holds it; the stock ones do not allocate. `validate` runs on
/// the control context; `mask` runs on the analysis thread, where a conformer's must not
/// allocate (RT-2).
public protocol MaskStrategy: Hashable, Sendable {
    /// Whether the strategy's own values make a mask. Control context; the default has
    /// nothing to check.
    ///
    /// - Throws: `DSPError.invalidParameter` for values that do not.
    func validate() throws(DSPError)

    /// The share of each of `count` bins that goes to the component: `component` holds its
    /// medians, `competitor` those of the other component, already multiplied by the margin.
    /// Both are non-negative. Where neither reaches `floor`, nothing is known about the bin
    /// and the share is 0 (NUM-1); no share written is NaN, infinite or outside 0 … 1.
    ///
    /// Analysis thread: it allocates nothing and takes no lock (RT-2). `mask` does not overlap
    /// the inputs.
    func mask(_ component: UnsafePointer<Float>, against competitor: UnsafePointer<Float>, floor: Float, into mask: UnsafeMutablePointer<Float>, count: Int)
}

extension MaskStrategy {
    /// Nothing to check: the default for a strategy without values of its own. Usable on any
    /// thread; it does not allocate.
    public func validate() throws(DSPError) {}
}

/// The soft mask (§6.10; Fitzgerald 2010, Driedger et al. 2014): `M = cᵖ / (cᵖ + kᵖ)`, a
/// Wiener-like share. A power of 2 weighs by energies; 1 weighs by magnitudes; larger powers
/// move it towards the hard mask. With margins of 1 the harmonic and the percussive mask add
/// up to 1 wherever either median reaches the floor.
///
/// The share is computed as `1 / (1 + (k / c)ᵖ)`: the ratio is taken first, so neither power
/// overflows or underflows whatever the level of the spectrum (§7.5).
///
/// An immutable value, usable on any thread; it does not allocate, and neither does `mask`.
public struct SoftMask: MaskStrategy {
    /// The exponent `p`: positive and finite.
    public let power: Double

    /// The soft mask with the exponent `power`, which `validate()` checks.
    public init(power: Double = 2) {
        self.power = power
    }

    /// Throws `DSPError.invalidParameter` for a power that is not positive and finite.
    public func validate() throws(DSPError) {
        guard power > 0, power.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "mask", reason: "the power of a soft mask is positive and finite, not \(power); the limit of a large power is .hard")
        }
    }

    /// `1 / (1 + (k / c)ᵖ)` for every bin by vDSP; then 0 where neither median reaches `floor`,
    /// and ½ where the ratio has no value.
    public func mask(_ component: UnsafePointer<Float>, against competitor: UnsafePointer<Float>, floor: Float, into mask: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        let length = vDSP_Length(count)
        // (k / c): infinite where the component is zero, not a number where both are; the
        // last pass puts every bin without a ratio where it belongs.
        vDSP_vdiv(component, 1, competitor, 1, mask, 1, length)
        if power == 2 {
            vDSP_vsq(mask, 1, mask, 1, length)
        } else if power != 1 {
            var exponent = Float(power)
            var elements = Int32(count)
            vvpowsf(mask, &exponent, mask, &elements)
        }
        var one: Float = 1
        vDSP_vsadd(mask, 1, &one, mask, 1, length)
        vDSP_svdiv(&one, mask, 1, mask, 1, length)
        var index = 0
        while index < count {
            let own = component[index], other = competitor[index]
            // Neither median reaches the floor: no share for either side (NUM-1). The
            // comparison is written so that a value that is not a number fails it.
            if !(own >= floor || other >= floor) {
                mask[index] = 0
            } else if !(mask[index] >= 0) {
                // The ratio itself has no value: both medians are zero under a floor of 0,
                // or both are infinite. Equal shares.
                mask[index] = 0.5
            }
            index &+= 1
        }
    }
}

/// The hard mask (§6.10): 1 where the component's median exceeds the competitor's, 0
/// elsewhere. It is the limit of the soft mask for a growing power. A tie goes to neither
/// side.
///
/// An immutable value, usable on any thread; it does not allocate, and neither does `mask`.
public struct HardMask: MaskStrategy {
    /// The hard mask; there is nothing to set.
    public init() {}

    /// 1 where the component's median exceeds the competitor's and reaches `floor`, 0
    /// elsewhere.
    public func mask(_ component: UnsafePointer<Float>, against competitor: UnsafePointer<Float>, floor: Float, into mask: UnsafeMutablePointer<Float>, count: Int) {
        var index = 0
        while index < count {
            let own = component[index], other = competitor[index]
            mask[index] = own > other && own >= floor ? 1 : 0
            index &+= 1
        }
    }
}

extension MaskStrategy where Self == SoftMask {
    /// The soft mask with the exponent `power`; 2, the default of the separation, weighs by
    /// energies. Usable on any thread; it does not allocate.
    public static func soft(power: Double) -> SoftMask { SoftMask(power: power) }
}

extension MaskStrategy where Self == HardMask {
    /// The hard mask. Usable on any thread; it does not allocate.
    public static var hard: HardMask { HardMask() }
}
