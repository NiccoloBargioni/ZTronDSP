import Foundation
import ZTronDSPCore

/// How a convolution is computed (§5.3, §6.7): one answer to one question, passed where the
/// convolution is asked for.
///
/// | Value | A whole signal (`DSP.convolve`, `DSP.correlate`) | A stream (`Convolve`) |
/// |---|---|---|
/// | `.direct` | The sum of products, `vDSP_conv`: O(N·K) | The direct FIR kernel: O(K) per sample |
/// | `.fft` | One transform of a fast length at or above N + K − 1: O((N + K)·log(N + K)) | The partitioned kernel, which is this method block by block |
/// | `.partitioned` | The partitioned kernel run over the signal: transforms no longer than twice the kernel | The uniformly partitioned frequency-domain delay line: O(log B + K / B) per sample |
/// | `.automatic` | The direct method below the measured crossover, the FFT method above it | The direct kernel below the crossover length, the partitioned one from it on |
///
/// The methods give the same result within their round-off: the direct method is exact to a
/// few units in the last place of the sum of each output's products; the two frequency-domain
/// methods are exact to the floor of a single-precision transform, under 10⁻⁶ of the largest
/// output the signal and the kernel can give, whatever the output itself is (§7.5, rows 8 and
/// 10). The crossovers are those of the `CrossoverTable` in force (§7.4).
///
/// An immutable value, usable on any thread.
public enum ConvolutionStrategy: Hashable, Sendable, CaseIterable {
    /// The sum of products.
    case direct
    /// The product of two spectra.
    case fft
    /// The product of spectra, partition by partition.
    case partitioned
    /// By size, from the measured crossovers. The default.
    case automatic
}

/// Convolves the signal with a kernel (§6.7): `y[n] = Σₖ kernel[k]·x[n − k]`, an FIR filter
/// whose taps are given as they are instead of being designed.
///
/// ```swift
/// Pipeline {
///     Convolve(kernel: impulseResponse)                    // direct or partitioned, by its length
///     Convolve(kernel: [0.25, 0.5, 0.25], strategy: .direct)
/// }
/// ```
///
/// The output of the stage is the convolution `DSP.convolve` computes for the same signal,
/// sample for sample, as far as the stream has come: after `N` samples, the first `N` values
/// of the full convolution. The kernel is taken as causal, so the stage declares no latency
/// (REAL-5); a kernel that is a linear-phase filter delays the signal by `(K − 1) / 2`
/// samples like any such filter, and `Filter(FIRSystem { … })` is the stage that says so.
///
/// - `.automatic`, the default: the plan runs the kernel directly up to the crossover length
///   of the engine's table and as a partitioned convolution from it on (REAL-4), whose
///   partition is the largest power of two the block holds, so that no latency is added.
///   Adjacent direct kernels are fused into one (F3).
/// - `.direct` and `.partitioned` name the kernel whatever the length; `.fft` on a stream is
///   the partitioned kernel. A choice that goes against the table is a kernel of its own and
///   is not fused with its neighbours.
///
/// The stage runs on any sampled sequence and keeps its domain. It has no continuous values.
/// A kernel of the same length takes the place of the running one without a click: its taps
/// are cross-faded over 10 ms (§5.5.4). A kernel that is the single tap 1 is no stage at all
/// (F4).
///
/// An immutable value, usable on any thread. `lower(_:)` runs on the control context.
public struct Convolve: SequenceStage {
    /// The taps, lowest delay first. Usable on any thread.
    public let kernel: [Float]
    /// How the stream is convolved. Usable on any thread.
    public let strategy: ConvolutionStrategy
    /// The stage's switch (§5.9). Usable on any thread.
    public let activation: StageActivation

    /// Usable on any thread.
    ///
    /// - Parameters:
    ///   - kernel: at least one tap, every tap a finite number; anything else is refused when
    ///     the pipeline is attached.
    ///   - strategy: `.automatic` by default.
    ///   - isActive: `true`, `false`, `.active`, `.bypassed`, or a SwiftUI `Binding<Bool>`.
    public init(kernel: [Float], strategy: ConvolutionStrategy = .automatic, isActive: some ActivationSource = .active) {
        self.kernel = kernel
        self.strategy = strategy
        self.activation = isActive.stageActivation
    }

    /// What tells a kernel made against the table from another: its taps and its kind.
    struct ForcedKey: Hashable, Sendable {
        let taps: [Float]
        let isPartitioned: Bool
    }

    /// Emits the FIR kernel. Control context; allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a kernel without taps or with a tap that is
    ///   not a finite number.
    public func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard !kernel.isEmpty else { throw context.invalid("kernel", "a convolution needs a kernel of at least one tap") }
        guard kernel.allSatisfy(\.isFinite) else { throw context.invalid("kernel", "every tap of a kernel is a finite number") }

        // What the plan binds an FIR of this length to here (SEL-3): `.accelerate` is the
        // partitioned kernel, anything else the direct one.
        let plannedPartitioned = context.implementation(for: .fir, size: kernel.count) == .accelerate
        let wantsPartitioned: Bool
        switch strategy {
        case .automatic: wantsPartitioned = plannedPartitioned
        case .direct: wantsPartitioned = false
        case .fft, .partitioned: wantsPartitioned = true
        }
        guard wantsPartitioned != plannedPartitioned else {
            context.emit(.fir(taps: kernel, latency: 0))
            return
        }

        // A choice against the table: the same C kernels, made here by name.
        let taps = kernel
        context.emit(.custom(CustomKernel(name: "Convolve", key: ForcedKey(taps: taps, isPartitioned: wantsPartitioned)) { channels, rate, maximumFrames in
            if wantsPartitioned {
                return ztd_partitioned_create(UInt32(channels), taps, UInt32(taps.count), UInt32(Convolve.partition(forBlocksOf: maximumFrames)), 0)
            }
            // Taps that change are cross-faded over 10 ms, as the plan's own direct kernel does.
            return ztd_fir_create(UInt32(channels), taps, UInt32(taps.count), 0, UInt32(max((0.010 * rate).rounded(), 1)))
        }))
    }

    /// The partition of a partitioned kernel that takes blocks of at most `frames` frames: the
    /// largest power of two a block holds, so that a block brings whole partitions and no
    /// latency is added (§6.7). Never below 8, the kernel's smallest.
    static func partition(forBlocksOf frames: Int) -> Int {
        var partition = 8
        while partition * 2 <= max(frames, 8), partition < 1 << 20 { partition *= 2 }
        return partition
    }
}

extension Pipeline where Output: SampledSequence {
    /// The pipeline followed by a convolution with `kernel`. See ``Convolve``. Usable on any thread.
    public func convolve(
        kernel: [Float], strategy: ConvolutionStrategy = .automatic, isActive: some ActivationSource = .active
    ) -> Pipeline<Input, Output> {
        appending(Convolve(kernel: kernel, strategy: strategy, isActive: isActive))
    }
}
