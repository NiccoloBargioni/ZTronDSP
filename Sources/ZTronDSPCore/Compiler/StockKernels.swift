import Foundation

/// The stock C kernels behind the stock specs (WP-311a): which constructor of the C layer
/// each spec becomes, and with which implementation, chosen here once by size (SEL-3).
enum StockKernels {
    static func make(
        _ step: IRKernel, channels: UInt32, sampleRate: Double, maximumFrames: Int,
        bound: (Primitive, Int) -> ztd_implementation_t, rampFrames: (TimeInterval) throws(DSPError) -> UInt32
    ) throws(DSPError) -> ztd_kernel_t {
        func refused(_ parameter: String, _ reason: String) -> DSPError {
            .invalidParameter(stage: step.path, parameter: parameter, reason: reason)
        }
        /// The latency a spec declares, as its kernel states it. The environment behind the
        /// stage is computed from the same figure, so one that a kernel's 32 bits do not hold
        /// is refused, not cut (REAL-5, §9.3). A negative one is none, as `latencyFrames` has it.
        func kernelLatency(_ latency: Int) throws(DSPError) -> UInt32 {
            guard let frames = UInt32(exactly: max(latency, 0)) else {
                throw refused("latency", "a latency of \(latency) frames is more than a kernel can count")
            }
            return frames
        }
        // A count of taps or sections beyond 32 bits is beyond what any constructor accepts:
        // it stays at the largest, and the constructor refuses it.
        func kernelCount(_ elements: Int) -> UInt32 { UInt32(clamping: elements) }

        switch step.spec {
        case .channelGains(let factors, let ramp):
            guard factors.count == Int(channels) else {
                throw refused("factors", "\(factors.count) gains for a signal of \(channels) channels")
            }
            return ztd_gain_create(channels, factors, try rampFrames(ramp), bound(.gainKernel, maximumFrames))

        case .biquad(let sections, let precision):
            guard !sections.isEmpty else { return ztd_kernel_identity() }
            let coefficients = sections.flatMap(\.coefficients)
            guard coefficients.allSatisfy(\.isFinite) else { throw refused("sections", "a coefficient is not a finite number") }
            if precision == .double {
                return ztd_biquad_double_create(channels, kernelCount(sections.count), coefficients)
            }
            let implementation = bound(.biquadKernel, maximumFrames)
            // One setup for all channels pays from three channels up (§7.2, row 3).
            if channels > 2, implementation == ZTD_IMPLEMENTATION_ACCELERATE {
                return ztd_biquadm_create(channels, kernelCount(sections.count), coefficients)
            }
            return ztd_biquad_create(channels, kernelCount(sections.count), coefficients, implementation)

        case .fir(let taps, let latency):
            guard !taps.isEmpty else { throw refused("taps", "an FIR filter has at least one tap") }
            guard taps.allSatisfy(\.isFinite) else { throw refused("taps", "a tap is not a finite number") }
            let delay = try kernelLatency(latency)
            if bound(.fir, taps.count) == ZTD_IMPLEMENTATION_ACCELERATE {
                // Partitioned: the partition is the largest power of two the block holds, so a
                // block brings whole partitions and is computed in the frequency domain alone.
                var partition = 8
                while partition * 2 <= max(maximumFrames, 8), partition < 1 << 20 { partition *= 2 }
                return ztd_partitioned_create(channels, taps, kernelCount(taps.count), UInt32(partition), delay)
            }
            // Taps that change are cross-faded over 10 ms (§5.5.4): a count of frames at this
            // rate, or the filter is refused (§9.3).
            guard let fade = FrameCount.exact(0.010, at: sampleRate, atMost: Int(UInt32.max)) else {
                throw refused("sampleRate", "the 10 ms over which taps are exchanged are not a number of frames a kernel can count at \(sampleRate) Hz")
            }
            return ztd_fir_create(channels, taps, kernelCount(taps.count), delay, UInt32(max(fade, 1)))

        case .decimator(let factor, let taps, let latency):
            guard factor >= 1, factor <= 4_096 else { throw refused("factor", "a decimation factor lies between 1 and 4 096, not \(factor)") }
            guard !taps.isEmpty, taps.allSatisfy(\.isFinite) else { throw refused("taps", "a decimator needs finite taps, at least one") }
            return ztd_decimator_create(channels, UInt32(factor), taps, kernelCount(taps.count), try kernelLatency(latency))

        case .interpolator(let factor, let taps, let latency):
            guard factor >= 1, factor <= 4_096 else { throw refused("factor", "an interpolation factor lies between 1 and 4 096, not \(factor)") }
            guard !taps.isEmpty, taps.allSatisfy(\.isFinite) else { throw refused("taps", "an interpolator needs finite taps, at least one") }
            return ztd_interpolator_create(channels, UInt32(factor), taps, kernelCount(taps.count), try kernelLatency(latency))

        case .subsample(let factor, let phase):
            guard factor >= 1, factor <= 4_096 else { throw refused("factor", "a factor lies between 1 and 4 096, not \(factor)") }
            return ztd_subsample_create(channels, UInt32(factor), UInt32(((phase % factor) + factor) % factor))

        case .zeroStuff(let factor):
            guard factor >= 1, factor <= 4_096 else { throw refused("factor", "a factor lies between 1 and 4 096, not \(factor)") }
            return ztd_zero_stuff_create(channels, UInt32(factor))

        case .alphaBeta(let alpha, let beta, let initialPosition, let initialVelocity, let outputVelocity):
            guard sampleRate > 0 else { throw refused("sampleRate", "a tracker needs a positive rate") }
            return ztd_alpha_beta_create(channels, alpha, beta, Float(1 / sampleRate), initialPosition, initialVelocity, outputVelocity)

        case .gain, .gainCascade, .custom, .processor, .analysis:
            throw .unsupportedConfiguration(reason: "\(step.path.stageName ?? "this stage") is not a stock kernel", stage: step.path)
        }
    }
}
