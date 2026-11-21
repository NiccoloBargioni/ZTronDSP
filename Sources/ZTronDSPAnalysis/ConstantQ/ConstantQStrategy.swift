import Foundation
import ZTronDSPCore

/// How a constant-Q transform is computed, as a strategy (§5.3): pass `.multirateSparseKernel`,
/// or a conformer of your own, where the step is declared.
///
/// ```swift
/// ConstantQ(octaves: 6, strategy: .multirateSparseKernel)
/// ```
///
/// `ConstantQ` works out the bins from its arguments and the sample rate at its position; the
/// strategy is asked two things about them. A strategy is a description: an immutable value,
/// usable on any thread, and part of the description of the step that holds it; the stock
/// one allocates only to box a backend larger than three words. The work is done by the node
/// it makes, and making it allocates.
public protocol ConstantQStrategy: Hashable, Sendable {
    /// The delay of the transform: how many samples after the one a frame is centred on have
    /// arrived when the frame is complete. `ConstantQ` declares it as its latency (REAL-5),
    /// and it must be the `latencyFrames` of the node ``makeNode(of:hop:window:sparsity:channel:channelCount:maximumBlockFrames:)``
    /// returns for the same arguments.
    ///
    /// Control context. It is called whenever a pipeline that holds the step is compiled, so
    /// it should be arithmetic.
    ///
    /// - Throws: `DSPError.invalidParameter` for a hop the strategy cannot frame the bins
    ///   with; the reason names the nearest hops it can (O-17).
    func latency(of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double) throws(DSPError) -> Int

    /// The node that computes the transform: blocks of samples in, one complex frame of
    /// `geometry.binCount` bins out for every `hop` samples, lowest bin first, each stamped
    /// with the time of the sample it is centred on. Frame `n` is centred on sample `n · hop`
    /// counted from the last reset; a sine at the centre of a bin reads its own amplitude.
    ///
    /// Control context: it allocates, designs and transforms. The node then belongs to the
    /// analysis thread (RT-2).
    ///
    /// - Parameters:
    ///   - geometry: the bins, at the sample rate of the step's position.
    ///   - hop: samples between two frames.
    ///   - window: the window of the atoms.
    ///   - sparsity: the share of a kernel row that may be dropped, for a strategy that has
    ///     kernels.
    ///   - channel: the channel to read, or `nil` for the mean of all channels.
    ///   - channelCount: channels of the blocks the node will be given.
    ///   - maximumBlockFrames: the most frames one of those blocks holds.
    /// - Throws: `DSPError.invalidParameter` for bins the strategy cannot compute,
    ///   `DSPError.resourceAllocationFailed` when memory or a setup cannot be had.
    func makeNode(
        of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double, channel: Int?, channelCount: Int, maximumBlockFrames: Int
    ) throws(DSPError) -> any AnalysisNode
}

/// The octave-recursive multirate transform with one sparse spectral kernel (§6.8, §7.2
/// row 13; Schörkhuber & Klapuri 2010, on the kernel of Brown & Puckette 1992).
///
/// - The highest octave is computed from the signal itself: the frame its longest atom
///   reaches is transformed once, and the spectrum is multiplied by a sparse kernel
///   (``ConstantQKernel``).
/// - Each octave below reuses that kernel on the signal halved through a half-band FIR,
///   whose stop band is at least 80 dB down. With a `gamma` above 0 the atoms of the lower
///   octaves are shorter, and each octave has a kernel of its own.
/// - The hop halves from octave to octave, so it must be a multiple of `2^(octaves − 1)`
///   (O-17).
/// - Every octave of a frame is centred on the same input sample. The delay is that of the
///   lowest octave: half its longest atom, plus what the decimators above it delay the
///   signal by.
/// - The decimators pass the lower 80 % of each octave's band unchanged and keep it free of
///   aliases, and a kernel reads no more than that. A bin that then keeps less than 99.9 % of
///   its kernel's energy is refused when the transform is made: it lies too high in its
///   octave's band, or its atom is too short.
///
/// The cost per hop is one transform of the length of the highest octave's longest atom, and one
/// sparse product, per octave. An immutable value, usable on any thread. Its backend is kept boxed
/// (`AnyStrategy`): creating one, and reading `backend`, allocate only for a backend larger than
/// three words, which the stock one is not; `makeNode` runs on the control context and allocates.
public struct MultirateSparseKernelStrategy: ConstantQStrategy {
    let backendBox: AnyStrategy

    /// - Parameter backend: the Fourier transform the octaves' frames are transformed with.
    public init(backend: some FFTBackend = .vDSP) {
        backendBox = AnyStrategy(backend)
    }

    /// The transform backend the strategy was declared with.
    public var backend: any FFTBackend { backendBox.value(as: (any FFTBackend).self) ?? VDSPFFTBackend() }

    /// The octaves laid on one another for a hop, checked (O-17). It allocates the schedule's
    /// arrays; the first call also designs the half-band filter, which is kept.
    func schedule(of geometry: ConstantQGeometry, hop: Int) throws(DSPError) -> ConstantQSchedule {
        try ConstantQSchedule(geometry: geometry, hop: hop, filterLength: geometry.octaves > 1 ? HalfBand.taps().count : 1)
    }

    /// The delay of the lowest octave, from the schedule of the octaves for `hop`, checked
    /// (O-17). Control context, as the requirement says; it allocates the schedule's arrays, and
    /// the first call also designs the half-band filter, which is kept.
    public func latency(of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double) throws(DSPError) -> Int {
        try schedule(of: geometry, hop: hop).latency
    }

    /// The smallest transform length that holds `span` samples and that both the kernel's own
    /// construction and the backend transform.
    func transformLength(holding span: Int) throws(DSPError) -> Int {
        let backend = backend
        var length = DSP.nextFastLength(span)
        while !backend.supports(length: length) {
            guard length < MultirateSparseKernelStrategy.longestTransform else {
                throw .invalidParameter(
                    stage: .none, parameter: "strategy",
                    reason: "\(type(of: backend)) transforms no length from \(DSP.nextFastLength(span)) points, which the longest atom of the highest octave needs, up to \(MultirateSparseKernelStrategy.longestTransform)")
            }
            length = DSP.nextFastLength(length + 1)
        }
        return length
    }

    /// The kernels of a transform, highest octave first: one for all octaves when `gamma` is
    /// 0, one each otherwise. A kernel reads no more than the decimators keep clean, and is
    /// refused when that is not enough of it (`ConstantQKernel`).
    func kernels(of geometry: ConstantQGeometry, window: Window, sparsity: Double, transformLength: Int) throws(DSPError) -> [ConstantQKernel] {
        let octaves = geometry.octaves
        var kernels: [ConstantQKernel] = []
        for depth in 0 ..< (geometry.gamma == 0 ? 1 : octaves) {
            kernels.append(try ConstantQKernel(
                geometry: geometry, octave: octaves - 1 - depth, window: window, sparsity: sparsity, transformLength: transformLength))
        }
        return kernels
    }

    /// Lays out the octaves for `hop`, finds the transform length and makes the kernels and the
    /// half-band taps, then the node.
    public func makeNode(
        of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double, channel: Int?, channelCount: Int, maximumBlockFrames: Int
    ) throws(DSPError) -> any AnalysisNode {
        let schedule = try schedule(of: geometry, hop: hop)
        let length = try transformLength(holding: schedule.spans.max() ?? 1)
        let kernels = try kernels(of: geometry, window: window, sparsity: sparsity, transformLength: length)
        let taps = geometry.octaves > 1 ? try HalfBand.taps().map { Float($0) } : [1]
        return try ConstantQNode(
            geometry: geometry, schedule: schedule, kernels: kernels, taps: taps, plan: backend.makePlan(length: length),
            mixer: ChannelMixer(channel: channel, channelCount: channelCount, maximumFrames: maximumBlockFrames))
    }

    /// The longest transform a kernel is laid on.
    static let longestTransform = 1 << 24
}

extension ConstantQStrategy where Self == MultirateSparseKernelStrategy {
    /// The octave-recursive multirate transform with one sparse spectral kernel, on the vDSP
    /// transform: the default. Usable on any thread; it does not allocate.
    public static var multirateSparseKernel: MultirateSparseKernelStrategy { MultirateSparseKernelStrategy() }

    /// The same transform on a Fourier backend of your choice. Usable on any thread; it allocates
    /// only to box a backend larger than three words.
    public static func multirateSparseKernel(backend: some FFTBackend) -> MultirateSparseKernelStrategy {
        MultirateSparseKernelStrategy(backend: backend)
    }
}
