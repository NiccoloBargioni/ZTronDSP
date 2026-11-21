import Foundation
import Metal
import ZTronDSPCore

/// The median filter of a whole spectrogram on the GPU (WP-610): for every value, the median
/// of the `kernel` values around it along time or along frequency, as the harmonic–percussive
/// separation needs them offline (§6.10).
///
/// Every element runs the selection network of the core (`MedianNetwork`, WP-528): the same
/// compare-exchanges, in the same order, as the CPU lanes run, each one a minimum and a
/// maximum. There is no arithmetic in it, so the result is exact: every output is one of the
/// input values, the one a sort would put in the middle (§7.5, row 16). Edges are reflected
/// with the edge value repeated, x[−k] = x[k − 1] (§6.1).
///
/// ```swift
/// let median = MetalMedianFilter(context: try MetalContext.sharedBlocking())
/// let harmonic = try median.filter(magnitudes, rowCount: bins, kernel: 31, along: .time)
/// ```
///
/// This is an offline kernel: it copies the spectrogram to the GPU and waits for the result.
/// A single live frame is cheaper on the CPU (GPU-1); `CrossoverTable.medianGPU` says from
/// which size the GPU pays.
///
/// Threading: an immutable value, `Sendable`. `filter` blocks until the GPU has finished and
/// allocates: background work only, never the main thread or the analysis thread.
public struct MetalMedianFilter: Sendable {
    /// The direction the median is taken along: a value, usable on any thread; it does not
    /// allocate.
    public enum Axis: Hashable, Sendable {
        /// Across columns: the same row of the frames before and after. What keeps harmonics.
        case time
        /// Across rows: the neighbouring bins of the same frame. What keeps percussion.
        case frequency
    }

    /// The device the filter computes on.
    public let context: MetalContext

    /// A filter on `context`. Cheap: the kernel was compiled with the context.
    public init(context: MetalContext) {
        self.context = context
    }

    /// Elements one dispatch computes at most: the work is cut into runs of columns, so no
    /// command buffer runs long enough for the system to stop it, and a cancelled task is seen
    /// between two of them.
    static let elementsPerDispatch = 1 << 20

    /// The median-filtered spectrogram.
    ///
    /// - Parameters:
    ///   - values: the spectrogram, `rowCount` values per column, column after column, as a
    ///     `FeedSnapshot` holds it. Values that are not numbers give unspecified results, as
    ///     they do for a sort (NUM-1 keeps them out).
    ///   - rowCount: values per column: the bins.
    ///   - kernel: how many values the median is taken over: odd, from 1 to
    ///     `MedianNetwork.maximumCount`.
    ///   - axis: along time or along frequency.
    ///   - checkpoint: the checkpoint of the background work this call is part of, when it is;
    ///     a cancelled task then stops the filter between two runs of columns.
    /// - Returns: as many values, in the same order.
    /// - Throws: `invalidParameter` for values that do not fill whole columns or a kernel that
    ///   is not odd or out of range; `resourceAllocationFailed` when the device has no buffer
    ///   for the spectrogram; `backendUnavailable` when the device fails; `cancelled`.
    public func filter(
        _ values: [Float], rowCount: Int, kernel: Int, along axis: Axis, checkpoint: BackgroundWork.Checkpoint? = nil
    ) throws(DSPError) -> [Float] {
        guard rowCount >= 1, values.count % rowCount == 0 else {
            throw .invalidParameter(stage: .none, parameter: "values", reason: "\(values.count) values do not fill columns of \(rowCount)")
        }
        let network = try MedianNetwork(count: kernel)
        let columnCount = values.count / rowCount
        guard columnCount > 0 else { return [] }

        let device = context.device
        let length = values.count * MemoryLayout<Float>.stride
        // Compare-exchanges as pairs of lane numbers; a kernel of one has none, and a buffer has at least one element.
        var lanes = [UInt16](repeating: 0, count: max(network.exchanges.count, 1) * 2)
        for (index, exchange) in network.exchanges.enumerated() {
            lanes[2 * index] = UInt16(exchange.low)
            lanes[2 * index + 1] = UInt16(exchange.high)
        }
        guard length <= context.capabilities.maximumBufferLength,
              let input = values.withUnsafeBytes({ bytes in bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: length, options: .storageModeShared) } }),
              let output = device.makeBuffer(length: length, options: .storageModeShared),
              let exchanges = lanes.withUnsafeBytes({ bytes in bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) } })
        else { throw .resourceAllocationFailed(what: "two GPU buffers of \(length) bytes for a median") }

        let pipeline = context.pipelines.median
        let groupWidth = max(pipeline.threadExecutionWidth, 1)
        let groupHeight = max(pipeline.maxTotalThreadsPerThreadgroup / groupWidth, 1)
        let columnsPerDispatch = max(Self.elementsPerDispatch / rowCount, 1)
        var first = 0
        while first < columnCount {
            try checkpoint?.check()
            let here = min(columnsPerDispatch, columnCount - first)
            var uniforms = MedianUniforms(
                rowCount: UInt32(rowCount), columnCount: UInt32(columnCount), laneCount: UInt32(network.count),
                exchangeCount: UInt32(network.exchanges.count), medianLane: UInt32(network.medianLane), alongTime: axis == .time ? 1 : 0,
                firstColumn: UInt32(first), columnsHere: UInt32(here))
            let commands = try MetalResources.commands(on: context.commandQueue)
            guard let encoder = commands.makeComputeCommandEncoder() else { throw .resourceAllocationFailed(what: "a compute encoder") }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&uniforms, length: MemoryLayout<MedianUniforms>.stride, index: 0)
            encoder.setBuffer(input, offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            encoder.setBuffer(exchanges, offset: 0, index: 3)
            // Whole thread groups: the kernel leaves the threads beyond the grid alone.
            encoder.dispatchThreadgroups(
                MTLSize(width: (here + groupWidth - 1) / groupWidth, height: (rowCount + groupHeight - 1) / groupHeight, depth: 1),
                threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1))
            encoder.endEncoding()
            try MetalResources.finish(commands, what: "the median")
            first += here
        }
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: values.count))
    }
}

/// The uniforms of the median kernel, field for field as `ZTDMedianUniforms` in `Median.metal`
/// declares them.
struct MedianUniforms {
    var rowCount: UInt32
    var columnCount: UInt32
    var laneCount: UInt32
    var exchangeCount: UInt32
    var medianLane: UInt32
    var alongTime: UInt32
    var firstColumn: UInt32
    var columnsHere: UInt32
}
