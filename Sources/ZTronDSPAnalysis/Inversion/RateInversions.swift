import Foundation
import ZTronDSPCore

// The inversion reports of the rate hooks as functions (§6.12, §6.13): `upsampled` is undone
// by `subsampled`, bit for bit; `subsampled` is undone by interpolation exactly as far as the
// sampling theorem holds for the signal. The stages built on the same hooks report through
// these.

extension DSP {
    /// The inversion report of `upsampled(_:by:)`, which `subsampled(_:by:)` undoes (§6.13).
    /// There is no condition: every sample is kept, and the round trip is exact bit for bit.
    ///
    /// The work runs on the background executor (BG-1) and can be cancelled (BG-3).
    public static func inversionReport(ofUpsampling signal: [Float], by factor: Int, sampleRate: Double = 48_000) async throws(DSPError) -> InversionReport {
        guard factor >= 1 else { throw .invalidParameter(stage: .none, parameter: "factor", reason: "a factor is at least 1, not \(factor)") }
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            let stretched = upsampled(signal, by: factor)
            try checkpoint.check()
            let back = subsampled(stretched, by: factor)
            return InversionReport(stage: "Upsample", inverse: "Subsample", conditions: [],
                                   roundTrip: InversionRoundTrip(original: signal, reconstruction: back), sampleRate: sampleRate)
        }
    }

    /// The inversion report of `subsampled(_:by:phase:)`, which interpolation undoes as far as
    /// the sampling theorem holds (§6.13): the signal must hold no energy at or above
    /// `sampleRate / (2·factor)`, the Nyquist frequency after subsampling. The condition is
    /// tested on the signal: the report states the share of its energy that lies there, which
    /// subsampling folds into the band, where it can no longer be told from what belongs.
    ///
    /// The measured round trip subsamples the signal and interpolates it back with a long
    /// windowed sinc; the first and last stretch of the signal, where that filter has no
    /// samples to work with, are left out.
    ///
    /// The work runs on the background executor (BG-1) and can be cancelled (BG-3).
    public static func inversionReport(
        ofSubsampling signal: [Float], by factor: Int, phase: Int = 0, sampleRate: Double = 48_000
    ) async throws(DSPError) -> InversionReport {
        guard factor >= 1 else { throw .invalidParameter(stage: .none, parameter: "factor", reason: "a factor is at least 1, not \(factor)") }
        guard sampleRate > 0, sampleRate.isFinite else {
            throw .invalidParameter(stage: .none, parameter: "sampleRate", reason: "a sample rate is positive and finite, not \(sampleRate)")
        }
        return try await BackgroundWork.run { checkpoint throws(DSPError) in
            let offset = ((phase % factor) + factor) % factor
            let share = try SamplingTheorem.shareOfEnergy(of: signal, atOrAbove: 0.5 / Double(factor), checkpoint: checkpoint)
            let holds = share <= SamplingTheorem.negligibleShare
            let condition = InversionCondition(
                name: "sampling theorem",
                theorem: "a signal that holds no energy at or above f_s / 2M is determined by every M-th of its samples (Shannon 1949). What lies there is folded into the band by subsampling and lost",
                quantity: "the share of the signal's energy at or above \(sampleRate / Double(2 * factor)) Hz; the margin is how far it lies below the negligible share of \(SamplingTheorem.negligibleShare), in decibels",
                observed: share, holds: holds, margin: 10 * log10(SamplingTheorem.negligibleShare / Swift.max(share, 1e-40)),
                // The part above the new Nyquist frequency is missing, and its image is added: twice its energy.
                predictedError: (2 * share).squareRoot())
            try checkpoint.check()
            let kept = subsampled(signal, by: factor, phase: offset)
            let restored = try BandlimitedInterpolation.interpolate(kept, by: factor, phase: offset, count: signal.count, checkpoint: checkpoint)
            // Where the interpolating filter reaches past the ends of the signal, nothing can be said.
            let margin = Swift.min(BandlimitedInterpolation.reach * factor, signal.count / 2)
            let roundTrip = InversionRoundTrip(original: Array(signal[margin ..< signal.count - margin]),
                                               reconstruction: Array(restored[margin ..< signal.count - margin]))
            return InversionReport(stage: "Subsample", inverse: "Interpolate", conditions: [condition], roundTrip: roundTrip, sampleRate: sampleRate)
        }
    }
}

/// The test of the sampling theorem on a signal (§7.2 row 22): how much of its energy lies at
/// or above a frequency.
enum SamplingTheorem {
    /// The share of energy below which a band counts as empty: −100 dB.
    static let negligibleShare = 1e-10

    /// The share of the energy of `signal` at or above `frequency`, in cycles per sample
    /// (0.5 is the Nyquist frequency). The spectrum is averaged over segments under a Kaiser
    /// window whose side lobes lie below anything single-precision samples can hold, so what
    /// is counted above the frequency is the signal's and not the window's.
    static func shareOfEnergy(of signal: [Float], atOrAbove frequency: Double, checkpoint: BackgroundWork.Checkpoint?) throws(DSPError) -> Double {
        guard !signal.isEmpty, frequency < 0.5 else { return 0 }
        guard frequency > 0 else { return 1 }
        let segment = Swift.min(DSP.nextFastLength(signal.count), 1 << 16)
        let hop = segment / 2
        let window = try Window.kaiser(beta: 24).doubleSamples(count: segment)
        let transform = try DoubleDFT(length: segment)
        let bins = segment / 2 + 1
        var power = [Double](repeating: 0, count: bins)
        var buffer = [Double](repeating: 0, count: segment), real = [Double](repeating: 0, count: bins), imaginary = real
        var start = 0
        repeat {
            for index in 0 ..< segment {
                let position = start + index
                buffer[index] = position < signal.count ? Double(signal[position]) * window[index] : 0
            }
            buffer.withUnsafeBufferPointer { source in
                real.withUnsafeMutableBufferPointer { re in
                    imaginary.withUnsafeMutableBufferPointer { im in
                        guard let from = source.baseAddress, let toReal = re.baseAddress, let toImaginary = im.baseAddress else { return }
                        transform.forward(from, real: toReal, imaginary: toImaginary)
                    }
                }
            }
            for bin in 0 ..< bins { power[bin] += real[bin] * real[bin] + imaginary[bin] * imaginary[bin] }
            start += hop
            try checkpoint?.check()
        } while start + segment <= signal.count
        // One-sided: every bin but the first and the last stands for two.
        var total = 0.0, above = 0.0
        let first = Int((frequency * Double(segment)).rounded(.up))
        for bin in 0 ..< bins {
            let weight = bin == 0 || bin == bins - 1 ? 1.0 : 2.0
            total += weight * power[bin]
            if bin >= first { above += weight * power[bin] }
        }
        return total > 0 ? above / total : 0
    }
}

/// Band-limited interpolation by a windowed sinc, for the measured round trip of subsampling.
/// It stands in for an ideal low-pass: `reach` zero crossings on either side under a Kaiser
/// window, 140 dB of rejection, and a transition band of a few per cent of the band.
enum BandlimitedInterpolation {
    /// Zero crossings of the sinc on either side of its centre, in subsampled samples.
    static let reach = 64

    /// `count` samples at the original rate from every `factor`-th of them, `samples[k]` being
    /// the original sample `k·factor + phase`.
    static func interpolate(_ samples: [Float], by factor: Int, phase: Int, count: Int, checkpoint: BackgroundWork.Checkpoint?) throws(DSPError) -> [Float] {
        guard factor > 1 else { return Array(samples.prefix(count)) + [Float](repeating: 0, count: Swift.max(count - samples.count, 0)) }
        // The kernel at every offset between two kept samples: h(t) = sinc(t / M)·w(t / (reach·M)).
        let width = reach * factor
        let taper = try Window.kaiser(beta: 14).symmetric.doubleSamples(count: 2 * width + 1)
        var kernel = [Double](repeating: 0, count: 2 * width + 1)
        for index in 0 ... 2 * width {
            let time = Double(index - width) / Double(factor)
            kernel[index] = (time == 0 ? 1 : sin(.pi * time) / (.pi * time)) * taper[index]
        }
        var result = [Float](repeating: 0, count: count)
        for position in 0 ..< count {
            // Kept samples within `width` of this position.
            let centre = position - phase
            var index = Swift.max((centre - width + factor - 1) / factor, 0)
            if centre - width < 0 { index = 0 }
            var sum = 0.0
            while index < samples.count {
                let distance = centre - index * factor
                if distance < -width { break }
                if distance <= width { sum += Double(samples[index]) * kernel[distance + width] }
                index += 1
            }
            result[position] = Float(sum)
            if position & 0xFFFF == 0 { try checkpoint?.check() }
        }
        return result
    }
}
