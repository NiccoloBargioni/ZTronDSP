import Foundation
import ZTronDSPCore
import ZTronDSPDesign

// The inversion report of `Decimate` (§6.13, WP-539): the sampling theorem, tested on the
// signal, and what the low-pass of the stage and that of its inverse add to it.

extension Decimate: InvertibleStage {
    /// The stage that undoes this one: `Interpolate` by the same factor, with the same
    /// low-pass (INV-1). Usable on any thread.
    public var inverse: Interpolate { Interpolate(by: factor, rejection: rejection, passband: passband) }

    /// What the round trip through `Decimate` and `Interpolate` depends on (§6.13). Background
    /// work: it designs the low-pass and transforms the signal.
    ///
    /// - **The sampling theorem**, tested on the signal: the share of its energy at or above
    ///   `f_s / 2M`, the Nyquist frequency after the stage. `Decimate` removes that share
    ///   before it keeps every `M`-th sample, so it is missing afterwards; it is not folded
    ///   into the band, as it is by `Subsample`.
    /// - **The transition band**, tested on the signal: the share of its energy between
    ///   `passband · f_s / 2M` and `f_s / 2M`. A real low-pass needs that room to fall, and
    ///   both filters of the round trip attenuate what lies there.
    /// - **The pass-band ripple**, measured on the taps: a windowed sinc ripples in its pass
    ///   band about as much as it leaves in its stop band. Nothing is lost to it, so exactness
    ///   in the sense of `isExactlyInvertible` does not depend on it, but the round trip
    ///   through two such filters is exact to within twice the ripple and not to round-off:
    ///   that is the error the report predicts for a signal that meets the other two.
    ///
    /// The two conditions about the signal are left out when the report is asked for without
    /// one. A factor of 1 is no stage: there is then no filter, and no condition about one.
    /// The stage is examined on samples: with `after:`, the pipeline has to end in samples.
    ///
    /// - Throws: `DSPError.invalidParameter` for a factor, a rejection or a pass band that
    ///   makes no low-pass; `DSPError.cancelled`.
    public func inversionConditions(in context: InversionContext) throws(DSPError) -> [InversionCondition] {
        let taps = try DSP.rateChangeTaps(by: factor, rejection: rejection, passband: passband)
        // In cycles per sample of the rate the stage is given.
        let nyquist = 0.5 / Double(factor)
        let edge = passband * nyquist
        let place = context.upstream.isEmpty
            ? "\(context.sampleRate * nyquist) Hz"
            : "1/\(2 * factor) of the sample rate the stage is given"
        var conditions: [InversionCondition] = []

        if context.samples != nil {
            let signal = try context.samples()
            let above = try SamplingTheorem.shareOfEnergy(of: signal, atOrAbove: nyquist, checkpoint: context.checkpoint)
            let negligible = SamplingTheorem.negligibleShare
            conditions.append(InversionCondition(
                name: "sampling theorem",
                theorem: "a signal that holds no energy at or above f_s / 2M is determined by every M-th of its samples (Shannon 1949). What lies there would alias, so the low-pass of the decimator removes it first: it is lost",
                quantity: "the share of the signal's energy at or above \(place); the margin is how far it lies below the negligible share of \(negligible), in decibels",
                observed: above, holds: above <= negligible, margin: 10 * log10(negligible / Swift.max(above, 1e-40)),
                // The part above the new Nyquist frequency is missing; the interpolator leaves no image of it.
                predictedError: above.squareRoot()))
            if factor > 1 {
                try context.check()
                let beyond = try SamplingTheorem.shareOfEnergy(of: signal, atOrAbove: edge, checkpoint: context.checkpoint)
                let transition = Swift.max(beyond - above, 0)
                conditions.append(InversionCondition(
                    name: "transition band",
                    theorem: "a low-pass of finite length needs a band to fall in: between \(passband) of the new Nyquist frequency and the new Nyquist frequency itself the filter of the decimator, and again that of the interpolator, attenuate the signal. A signal that holds no energy there is passed whole",
                    quantity: "the share of the signal's energy from \(passband) of \(place) up to it; the margin is how far it lies below the negligible share of \(negligible), in decibels",
                    observed: transition, holds: transition <= negligible, margin: 10 * log10(negligible / Swift.max(transition, 1e-40)),
                    // At most all of it is lost.
                    predictedError: transition.squareRoot()))
            }
        }

        if factor > 1 {
            try context.check()
            let ripple = try RateChangeFilter.ripple(of: taps, upTo: edge, context: context)
            let tolerance = pow(10, -abs(rejection.decibels(floor: -10_000)) / 20)
            conditions.append(InversionCondition(
                name: "pass-band ripple",
                theorem: "a windowed sinc deviates from 1 in its pass band about as much as it leaves in its stop band, δ ≈ 10^(−rejection / 20) (Kaiser 1974). The round trip filters twice, once to decimate and once to interpolate, so it returns a signal within the pass band to within 2δ, not to round-off",
                quantity: "the largest deviation of the low-pass's gain from 1 over its pass band; the margin is how far it lies below the stop-band tolerance of \(tolerance), in decibels",
                observed: ripple, holds: ripple <= tolerance, margin: 20 * log10(tolerance / Swift.max(ripple, 1e-300)), isNecessary: false,
                // Two filters, and the single-precision arithmetic of both kernels.
                predictedError: 2 * ripple + InversionRoundOff.transform(length: taps.count)))
        }
        return conditions
    }

    /// The signal through the decimator and the interpolator. The two filters delay it by
    /// `K − 1` samples, `K` being the length of the low-pass, and reach as far to either side:
    /// that much of the start and of the end of the signal is left out, since a signal that
    /// begins or ends is not band-limited there.
    ///
    /// Background work. `nil` without a signal.
    public func inversionRoundTrip(in context: InversionContext) throws(DSPError) -> InversionRoundTrip? {
        guard context.samples != nil else { return nil }
        let original = try context.samples()
        let restored = try context.samples(after: stageDescriptions + inverse.stageDescriptions)
        guard factor > 1 else { return InversionRoundTrip(original: original, reconstruction: restored) }
        let reach = try DSP.rateChangeTaps(by: factor, rejection: rejection, passband: passband).count - 1
        let end = Swift.min(original.count - reach, restored.count - reach)
        guard end > reach else { return InversionRoundTrip(original: [], reconstruction: []) }
        return InversionRoundTrip(original: Array(original[reach ..< end]), reconstruction: Array(restored[(reach + reach) ..< (end + reach)]))
    }
}

/// The low-pass of a rate change, measured (WP-539).
enum RateChangeFilter {
    /// The most products the measurement spends: what bounds its time for the longest filters.
    static let budget = 1 << 26

    /// The largest deviation from 1 of the gain of a symmetric low-pass with unity gain at
    /// 0 Hz, over the frequencies from 0 to `edge`, in cycles per sample. The gain is sampled
    /// sixteen times per ripple, as far as the budget allows.
    static func ripple(of taps: [Double], upTo edge: Double, context: InversionContext) throws(DSPError) -> Double {
        guard taps.count > 1, edge > 0 else { return 0 }
        let half = (taps.count - 1) / 2
        // The gain of a filter of K taps ripples about K·edge times between 0 and the edge.
        let wanted = Int((16 * Double(taps.count) * edge).rounded(.up))
        let points = Swift.max(Swift.min(wanted, RateChangeFilter.budget / taps.count), 64)
        var worst = 0.0
        for point in 0 ... points {
            let turn = 2 * Double.pi * edge * Double(point) / Double(points)
            // Symmetric about its centre tap: h[c] + 2·Σ h[c + k]·cos(ωk).
            var gain = taps[half]
            for offset in 1 ... half { gain += 2 * taps[half + offset] * cos(turn * Double(offset)) }
            worst = Swift.max(worst, abs(gain - 1))
            if point % 16 == 0 { try context.check() }
        }
        return worst
    }
}
