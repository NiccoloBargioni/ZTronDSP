import Foundation
import ZTronDSPCore
import ZTronDSPMetal

/// The direction a median is taken along (§6.10).
///
/// A value, usable on any thread; it does not allocate.
public enum MedianAxis: Hashable, Sendable {
    /// Across frames: the same bin of neighbouring frames. What stays is what lasts: the
    /// harmonic part.
    case time
    /// Across bins: the neighbouring bins of one frame. What stays is what is broad: the
    /// percussive part.
    case frequency
}

/// A median filter as the analysis thread runs it: one frame of bins in, one frame of medians
/// out (§6.10). A `MedianStrategy` makes it.
///
/// - Along **time** the filter keeps the frames it was given: `process` takes the next frame
///   and writes the median, bin by bin, of the last `kernel` frames, the new one included.
///   While fewer than `kernel` frames have arrived since a reset, the missing ones are those
///   of the stream reflected at its start, the edge frame repeated, as often as it takes
///   (§6.1). From frame `kernel / 2` on, what it writes is therefore the centred median of
///   frame `t − kernel / 2`, the left edge of the stream included.
/// - Along **frequency** the filter keeps nothing: `process` writes, for every bin, the median
///   of the `kernel` bins centred on it, the edges of the frame reflected the same way.
///
/// Threading: a filter is created and released on the control context or in the background,
/// which allocates. `process` and `reset` do not allocate, take no lock and belong to one
/// thread at a time (the analysis thread, RT-2). A filter is not `Sendable`.
public protocol MedianFilter: AnyObject {
    /// One frame in, its medians out. `frame` and `medians` hold as many values as the filter
    /// was made for, and may be the same buffer. A value that is not a number makes the
    /// medians it reaches unspecified, as it does for a sort (NUM-1 keeps it out).
    func process(_ frame: UnsafePointer<Float>, into medians: UnsafeMutablePointer<Float>)

    /// Back to the state at creation: a cold start (ACT-10).
    func reset()
}

/// How the medians of the harmonic–percussive separation are computed, as a strategy (§5.3,
/// §6.10): pass `.selectionNetwork`, `.metal` or `.automatic`, or a conformer of your own,
/// where a separation is declared.
///
/// ```swift
/// HarmonicPercussive(select: .harmonic, median: .selectionNetwork)             // a live step: CPU lanes
/// try await DSP.harmonicPercussive(spectrogram, binCount: 1_025, select: .percussive, median: .automatic)
/// ```
///
/// A strategy has two jobs. For a live step it makes the filters the analysis thread runs,
/// one frame at a time; for a whole spectrogram, offline, it returns the filtered spectrogram.
/// A conformer need only supply the first: the second then runs the conformer's own filters
/// over the frames.
///
/// A strategy is a description: an immutable value, usable on any thread, and part of the
/// description of the stage that holds it; the stock ones do not allocate. Making a filter
/// and filtering a spectrogram allocate.
public protocol MedianStrategy: Hashable, Sendable {
    /// The filter a live step runs over frames of `binCount` values, along `axis`. Control
    /// context: it allocates, once per plan that needs it.
    ///
    /// - Parameters:
    ///   - kernel: how many values a median is taken over: odd, from 1 up.
    ///   - binCount: values per frame.
    ///   - axis: the direction the median is taken along.
    ///   - implementation: what the environment asks for (§7.4): `.automatic` follows
    ///     `crossovers`.
    ///   - crossovers: the measured crossovers of the engine (§7.4).
    /// - Throws: `DSPError.invalidParameter` for a kernel or a number of bins the strategy
    ///   cannot filter; `DSPError.unsupportedConfiguration` when the strategy filters whole
    ///   spectrograms only.
    func makeFilter(
        kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable
    ) throws(DSPError) -> any MedianFilter

    /// The median filter of a whole spectrogram, offline: every value replaced by the median
    /// of the `kernel` values centred on it along `axis`, the edges reflected with the edge
    /// value repeated (§6.1). In the background: it blocks and allocates.
    ///
    /// The default runs the strategy's own filters over the frames.
    ///
    /// - Parameters:
    ///   - values: `rowCount` values per frame, frame after frame, as a `FeedSnapshot` holds
    ///     them.
    ///   - rowCount: values per frame.
    ///   - kernel: how many values a median is taken over: odd, from 1 up.
    ///   - axis: the direction the median is taken along.
    ///   - crossovers: the measured crossovers a strategy that chooses by size follows (§7.4).
    ///   - checkpoint: the checkpoint of the background work this call is part of, when it is.
    /// - Returns: as many values, in the same order.
    /// - Throws: `DSPError.invalidParameter` for values that do not fill whole frames or a
    ///   kernel that is not odd; `DSPError.backendUnavailable` when the strategy names a
    ///   backend that is not there; `DSPError.cancelled`.
    func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, crossovers: CrossoverTable,
        checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) -> [Float]
}

extension MedianStrategy {
    /// The default: the strategy's own filters, made for `.automatic`, run over the frames one
    /// after the other. As the requirement says, it runs in the background, blocks and allocates:
    /// never on the analysis thread.
    public func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, crossovers: CrossoverTable = .shipped,
        checkpoint: BackgroundWork.Checkpoint? = nil
    ) throws(DSPError) -> [Float] {
        try MedianOffline.filter(values, rowCount: rowCount, kernel: kernel, along: axis, checkpoint: checkpoint) { () throws(DSPError) -> any MedianFilter in
            try makeFilter(kernel: kernel, binCount: rowCount, along: axis, implementation: .automatic, crossovers: crossovers)
        }
    }
}

/// The selection network on CPU lanes (§7.2 row 16): the odd-even-merge network pruned to
/// the median, each compare-exchange one element-wise minimum and maximum of two lanes of
/// bins. Along time a lane is one stored frame; along frequency a lane is the current frame
/// shifted by one bin. O(k·log²k) vector operations per frame, no branch on the data. Exact:
/// every median is one of the values it was taken over.
///
/// It is what a live step runs, and the oracle and fall-back of the GPU median (GPU-3).
///
/// An immutable value, usable on any thread; it does not allocate. Its filters allocate once,
/// when they are made.
public struct SelectionNetworkMedian: MedianStrategy {
    /// The selection network; there is nothing to set.
    public init() {}

    /// A filter along time over the frames it stores, or along frequency over shifted copies
    /// of the frame, on the lanes `implementation` and `crossovers` choose.
    public func makeFilter(
        kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable
    ) throws(DSPError) -> any MedianFilter {
        switch axis {
        case .time: return try TimeLaneMedian(kernel: kernel, binCount: binCount, implementation: implementation, crossovers: crossovers)
        case .frequency: return try FrequencyLaneMedian(kernel: kernel, binCount: binCount, implementation: implementation, crossovers: crossovers)
        }
    }
}

/// The same network per element on the GPU (WP-610, WP-612): for whole spectrograms, offline.
/// It copies the spectrogram to the device and waits for the result, so a single live frame
/// is cheaper on the CPU (GPU-1): a live step declared with it is refused when the pipeline
/// is attached. Where there is no Metal device it is `DSPError.backendUnavailable` (GPU-4).
/// Its result is that of the CPU lanes, value for value.
///
/// An immutable value, usable on any thread; it does not allocate. Filtering a spectrogram
/// allocates and blocks on the GPU, in the background.
public struct MetalMedian: MedianStrategy {
    /// Where the device comes from. `absent` stands for a system without a GPU, for tests.
    enum Device: Hashable, Sendable {
        case shared
        case absent
    }

    let device: Device

    /// The GPU median on the shared Metal device.
    public init() {
        device = .shared
    }

    init(device: Device) {
        self.device = device
    }

    /// The context the filter computes on. Blocks while the shared context is made the first
    /// time: background work only.
    func context() throws(DSPError) -> MetalContext {
        switch device {
        case .shared: return try MetalContext.sharedBlocking()
        case .absent: return try MetalContext(device: nil)
        }
    }

    /// Throws `DSPError.unsupportedConfiguration`: a live frame is filtered on the CPU (GPU-1),
    /// so a live step declared with this strategy is refused.
    public func makeFilter(
        kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable
    ) throws(DSPError) -> any MedianFilter {
        throw .unsupportedConfiguration(
            reason: "the GPU median filters whole spectrograms offline: a live frame is filtered on the CPU (GPU-1). Declare the step with .selectionNetwork or .automatic")
    }

    /// The spectrogram copied to the device, filtered there and copied back; the call blocks
    /// until the result is there. `DSPError.backendUnavailable` without a device (GPU-4).
    public func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, crossovers: CrossoverTable = .shipped,
        checkpoint: BackgroundWork.Checkpoint? = nil
    ) throws(DSPError) -> [Float] {
        MedianOffline.willRun(.metal)
        return try MetalMedianFilter(context: try context()).filter(values, rowCount: rowCount, kernel: kernel, along: axis == .time ? .time : .frequency, checkpoint: checkpoint)
    }
}

/// The choice by size (§7.4): the CPU lanes for a live frame, always (GPU-1); for a whole
/// spectrogram, the GPU from the size at which the measured crossover says it pays,
/// `CrossoverTable.medianGPU`, counted as kernel × bins × frames, and the CPU lanes below it,
/// and wherever there is no Metal device or the device cannot take the work (GPU-3, GPU-4).
///
/// An immutable value, usable on any thread; it does not allocate. Filtering a spectrogram
/// allocates, in the background.
public struct AutomaticMedian: MedianStrategy {
    let metal: MetalMedian

    /// The choice by size, with the shared Metal device for the GPU side.
    public init() {
        metal = MetalMedian()
    }

    init(device: MetalMedian.Device) {
        metal = MetalMedian(device: device)
    }

    /// What the table binds a median over a spectrogram of `elements` values to: `.metal` or
    /// `.native`.
    static func implementation(kernel: Int, elements: Int, crossovers: CrossoverTable) -> Implementation {
        let (size, overflow) = kernel.multipliedReportingOverflow(by: elements)
        return crossovers.implementation(for: .median, size: overflow ? Int.max : size) == .metal ? .metal : .native
    }

    /// The filter of the CPU lanes, always: a live frame is filtered there (GPU-1).
    public func makeFilter(
        kernel: Int, binCount: Int, along axis: MedianAxis, implementation: Implementation, crossovers: CrossoverTable
    ) throws(DSPError) -> any MedianFilter {
        try SelectionNetworkMedian().makeFilter(kernel: kernel, binCount: binCount, along: axis, implementation: implementation, crossovers: crossovers)
    }

    /// On the GPU from the size the crossover names on, falling back to the CPU lanes where
    /// there is no device or it cannot take the work; on the CPU lanes below that size.
    public func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, crossovers: CrossoverTable = .shipped,
        checkpoint: BackgroundWork.Checkpoint? = nil
    ) throws(DSPError) -> [Float] {
        if AutomaticMedian.implementation(kernel: kernel, elements: values.count, crossovers: crossovers) == .metal {
            do throws(DSPError) {
                return try metal.filter(values, rowCount: rowCount, kernel: kernel, along: axis, crossovers: crossovers, checkpoint: checkpoint)
            } catch {
                // No device, or one that cannot take the work: the CPU is the fall-back. What
                // the caller got wrong, and a cancellation, are the same on either side.
                switch error {
                case .backendUnavailable, .resourceAllocationFailed: break
                default: throw error
                }
            }
        }
        return try SelectionNetworkMedian().filter(values, rowCount: rowCount, kernel: kernel, along: axis, crossovers: crossovers, checkpoint: checkpoint)
    }
}

extension MedianStrategy where Self == SelectionNetworkMedian {
    /// The selection network on CPU lanes: the default of a live step. Usable on any thread; it
    /// does not allocate.
    public static var selectionNetwork: SelectionNetworkMedian { SelectionNetworkMedian() }
}

extension MedianStrategy where Self == MetalMedian {
    /// The selection network on the GPU: whole spectrograms, offline. Usable on any thread; it does
    /// not allocate, and touches no device.
    public static var metal: MetalMedian { MetalMedian() }
}

extension MedianStrategy where Self == AutomaticMedian {
    /// By size, from the measured crossovers: the default of the offline separation. Usable on any
    /// thread; it does not allocate, and touches no device.
    public static var automatic: AutomaticMedian { AutomaticMedian() }
}

/// The offline median of a whole spectrogram by streaming filters, and the seam that lets a
/// test see which side a median was dispatched to.
enum MedianOffline {
    /// Called with `.native` or `.metal` when an offline median starts on that side. The
    /// observer is task-local, so tests that run side by side do not hear one another;
    /// outside a test it is `nil` and costs one read.
    @TaskLocal static var observer: (@Sendable (Implementation) -> Void)?

    static func willRun(_ implementation: Implementation) {
        observer?(implementation)
    }

    /// Frames between two looks at the checkpoint.
    static let framesPerCheck = 64

    static func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: MedianAxis, checkpoint: BackgroundWork.Checkpoint?,
        make: () throws(DSPError) -> any MedianFilter
    ) throws(DSPError) -> [Float] {
        guard rowCount >= 1, values.count % rowCount == 0 else {
            throw .invalidParameter(stage: .none, parameter: "values", reason: "\(values.count) values do not fill frames of \(rowCount)")
        }
        let frameCount = values.count / rowCount
        // The filter is made even for no frames at all: a kernel that is none is refused either way.
        let filter = try make()
        guard frameCount > 0 else { return [] }
        willRun(.native)
        var result = [Float](repeating: 0, count: values.count)
        var failure: DSPError?
        values.withUnsafeBufferPointer { source in
            result.withUnsafeMutableBufferPointer { target in
                guard let from = source.baseAddress, let to = target.baseAddress else { return }
                do throws(DSPError) {
                    switch axis {
                    case .frequency:
                        for frame in 0 ..< frameCount {
                            if frame % framesPerCheck == 0 { try checkpoint?.check() }
                            filter.process(from + frame * rowCount, into: to + frame * rowCount)
                        }
                    case .time:
                        // The stream a filter along time sees, followed by its own reflection:
                        // what it writes for frame t + kernel / 2 is the centred median of frame t.
                        let reach = kernel / 2
                        let scratch = try AlignedBuffer<Float>(count: rowCount)
                        for position in 0 ..< frameCount + reach {
                            if position % framesPerCheck == 0 { try checkpoint?.check() }
                            let frame = from + MedianOffline.reflected(position, count: frameCount) * rowCount
                            if position >= reach {
                                filter.process(frame, into: to + (position - reach) * rowCount)
                            } else {
                                filter.process(frame, into: scratch.baseAddress)
                            }
                        }
                    }
                } catch {
                    failure = error
                }
            }
        }
        if let failure { throw failure }
        return result
    }

    /// The reflection of a line at both ends, the edge value repeated (§6.1).
    static func reflected(_ index: Int, count: Int) -> Int {
        let period = 2 * count
        let wrapped = ((index % period) + period) % period
        return wrapped < count ? wrapped : period - 1 - wrapped
    }
}
