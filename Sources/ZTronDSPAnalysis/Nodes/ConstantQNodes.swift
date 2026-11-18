import Accelerate
import ZTronDSPCore

// The analysis-thread half of the constant-Q transform (WP-519 … WP-522b): the product of a
// sparse kernel with a spectrum, the half-band decimator between two octaves, and the node
// that runs the octaves. Nothing here allocates, locks or logs after an initialiser returns;
// loops are `while` loops (RT-2, CR-002).

/// A constant-Q kernel as the analysis thread reads it, and its product with the spectrum of
/// a frame (WP-520): the hot loop of the transform.
///
/// The kernel is held in compressed sparse rows with its real and imaginary parts apart
/// (E-11). A row is a dozen entries, where a plain loop leads a library call (E-26).
///
/// Created on the control context; `apply` belongs to the analysis thread and allocates
/// nothing. A product may serve several octaves of one node: it keeps no state.
final class SparseKernelProduct {
    /// Coefficients the product writes: the rows of the kernel.
    let rowCount: Int
    /// Bins of the spectrum the product reads.
    let columnCount: Int
    private let starts: AlignedBuffer<Int32>
    private let columns: AlignedBuffer<Int32>
    private let real: AlignedBuffer<Float>
    private let imaginary: AlignedBuffer<Float>

    init(_ kernel: ConstantQKernel) throws(DSPError) {
        rowCount = kernel.rowCount
        columnCount = kernel.columnCount
        let entries = kernel.nonZeroCount
        starts = try AlignedBuffer<Int32>(count: kernel.rowCount + 1)
        columns = try AlignedBuffer<Int32>(count: entries)
        real = try AlignedBuffer<Float>(count: entries)
        imaginary = try AlignedBuffer<Float>(count: entries)
        var row = 0
        while row <= kernel.rowCount {
            starts.baseAddress[row] = Int32(kernel.rowStarts[row])
            row += 1
        }
        var index = 0
        while index < entries {
            columns.baseAddress[index] = Int32(kernel.columns[index])
            real.baseAddress[index] = kernel.real[index]
            imaginary.baseAddress[index] = kernel.imaginary[index]
            index += 1
        }
    }

    /// The coefficients of the spectrum given as `columnCount` real and imaginary parts:
    /// `rowCount` values into `resultReal` and into `resultImaginary`. The buffers must not
    /// overlap.
    @inline(__always)
    func apply(
        real spectrumReal: UnsafePointer<Float>, imaginary spectrumImaginary: UnsafePointer<Float>,
        intoReal resultReal: UnsafeMutablePointer<Float>, imaginary resultImaginary: UnsafeMutablePointer<Float>
    ) {
        SparseKernelProduct.multiply(
            rows: rowCount, starts: starts.baseAddress, columns: columns.baseAddress, kernelReal: real.baseAddress,
            kernelImaginary: imaginary.baseAddress, spectrumReal: spectrumReal, spectrumImaginary: spectrumImaginary,
            resultReal: resultReal, resultImaginary: resultImaginary)
    }

    /// `result[r] = Σ kernel[r, c] · spectrum[c]` over the entries of row `r`, in complex
    /// arithmetic on split parts.
    #if ZTRONDSP_PERF_ANNOTATIONS
    @_noAllocation @_noLocks
    #endif
    @inline(__always)
    static func multiply(
        rows: Int, starts: UnsafePointer<Int32>, columns: UnsafePointer<Int32>, kernelReal: UnsafePointer<Float>,
        kernelImaginary: UnsafePointer<Float>, spectrumReal: UnsafePointer<Float>, spectrumImaginary: UnsafePointer<Float>,
        resultReal: UnsafeMutablePointer<Float>, resultImaginary: UnsafeMutablePointer<Float>
    ) {
        var row = 0
        var index = Int(starts[0])
        while row < rows {
            let end = Int(starts[row &+ 1])
            var sumReal: Float = 0, sumImaginary: Float = 0
            while index < end {
                let column = Int(columns[index])
                let a = kernelReal[index], b = kernelImaginary[index]
                let x = spectrumReal[column], y = spectrumImaginary[column]
                sumReal += a * x - b * y
                sumImaginary += a * y + b * x
                index &+= 1
            }
            resultReal[row] = sumReal
            resultImaginary[row] = sumImaginary
            row &+= 1
        }
    }
}

/// The half-band decimator between two octaves (WP-519): low-pass, then keep every other
/// sample, on the decimator kernel of the C layer (`vDSP_desamp`, WP-213). Its output does
/// not depend on how its input is cut into blocks, bit for bit.
///
/// Created and released on the control context; `process` and `reset` belong to the analysis
/// thread and allocate nothing.
final class HalfBandDecimator {
    private typealias Process = @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>?>?, UnsafePointer<UnsafeMutablePointer<Float>?>?, UInt32, UInt32
    ) -> UInt32
    private typealias Reset = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private var kernel: ztd_kernel_t
    private let run: Process
    private let clear: Reset?
    /// One channel pointer each way, as the kernel takes its buffers.
    private let source: UnsafeMutablePointer<UnsafePointer<Float>?>
    private let target: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    /// - Parameter taps: the low-pass, lowest delay first.
    /// - Throws: `DSPError.resourceAllocationFailed` when the kernel cannot be made.
    init(taps: [Float]) throws(DSPError) {
        var made = taps.withUnsafeBufferPointer { ztd_decimator_create(1, 2, $0.baseAddress, UInt32($0.count), UInt32(max($0.count - 1, 0) / 2)) }
        guard let process = made.process else {
            ztd_kernel_destroy(&made)
            throw .resourceAllocationFailed(what: "a half-band decimator of \(taps.count) taps")
        }
        kernel = made
        run = process
        clear = made.reset
        source = .allocate(capacity: 1)
        source.initialize(to: nil)
        target = .allocate(capacity: 1)
        target.initialize(to: nil)
    }

    deinit {
        ztd_kernel_destroy(&kernel)
        source.deinitialize(count: 1)
        source.deallocate()
        target.deinitialize(count: 1)
        target.deallocate()
    }

    /// Takes `count` samples and writes every other sample of their low-passed stream to
    /// `output`, which needs room for `(count + 1) / 2`. Returns how many it wrote. The phase
    /// is carried from call to call.
    @inline(__always)
    func process(_ samples: UnsafePointer<Float>, count: Int, into output: UnsafeMutablePointer<Float>) -> Int {
        source.pointee = samples
        target.pointee = output
        return Int(run(kernel.state, source, target, 1, UInt32(count)))
    }

    /// Back to the state at creation (ACT-10).
    func reset() {
        clear?(kernel.state)
    }
}

/// One octave of a running constant-Q transform: its signal, its frames, and the frames it
/// has computed that the transform has not sent on yet.
final class ConstantQOctave {
    /// The longest atom of the octave: the samples of a frame.
    let span: Int
    /// Samples of the octave's own rate between two frames.
    let hop: Int
    /// Samples that have arrived when frame 0 is complete.
    let firstEnd: Int
    let history: HistoryBuffer
    let product: SparseKernelProduct
    /// The decimator that makes the signal of the octave below; `nil` in the lowest octave.
    let decimator: HalfBandDecimator?
    /// Zeros that decimator is fed before its first sample (0 or 1).
    let prime: Int
    /// What the decimator writes for one chunk.
    let halved: AlignedBuffer<Float>
    /// The coefficients of the frames computed and not yet sent on, frame after frame, in a ring.
    let pendingReal: AlignedBuffer<Float>
    let pendingImaginary: AlignedBuffer<Float>
    /// Frames the ring holds.
    let capacity: Int

    /// Samples of the octave's rate taken since the last reset.
    var received = 0
    /// The value of `received` at which the next frame is complete.
    var nextEnd: Int
    /// Frames computed since the last reset.
    var computed = 0
    var isPrimed = false

    init(
        span: Int, hop: Int, firstEnd: Int, product: SparseKernelProduct, decimator: HalfBandDecimator?, prime: Int, chunk: Int, capacity: Int
    ) throws(DSPError) {
        self.span = span
        self.hop = hop
        self.firstEnd = firstEnd
        self.product = product
        self.decimator = decimator
        self.prime = prime
        self.capacity = capacity
        history = try HistoryBuffer(count: span)
        halved = try AlignedBuffer<Float>(count: chunk / 2 + 4)
        pendingReal = try AlignedBuffer<Float>(count: capacity * product.rowCount)
        pendingImaginary = try AlignedBuffer<Float>(count: capacity * product.rowCount)
        nextEnd = firstEnd
    }

    func reset() {
        history.reset()
        decimator?.reset()
        received = 0
        nextEnd = firstEnd
        computed = 0
        isPrimed = false
    }
}

/// The node of `ConstantQ` under the strategy `.multirateSparseKernel` (WP-521, WP-522a,
/// WP-522b; Schörkhuber & Klapuri 2010).
///
/// The highest octave is read from the signal as it arrives; each octave below from the
/// signal of the one above, halved through a half-band filter. Every octave keeps the last
/// samples its longest atom reaches; when a frame of an octave is complete those samples are
/// transformed once and the spectrum is multiplied by the octave's sparse kernel. Frame `n`
/// is centred on input sample `n · hop` in every octave (`ConstantQSchedule`), so the octaves
/// are complete at different times: the high ones early, the lowest one last. Their
/// coefficients wait in a ring per octave, and a frame is sent on when its last octave is
/// complete, stamped with the time of the sample it is centred on.
///
/// Before its first sample the signal counts as zero: the first frames are those of a signal
/// that begins at the reset.
final class ConstantQNode: AnalysisNode {
    private let binCount: Int
    private let rowCount: Int
    private let hop: Int
    private let sampleRate: Double
    private let mixer: ChannelMixer
    private let plan: any FFTPlan
    private let levels: [ConstantQOctave]
    /// The most samples one pass over the octaves takes.
    private let chunk: Int
    /// The longest span of any octave: what of `frame` may hold samples.
    private let longestSpan: Int
    /// A frame as it is transformed: the samples of a span, then zeros.
    private let frame: AlignedBuffer<Float>
    private let spectrumReal: AlignedBuffer<Float>
    private let spectrumImaginary: AlignedBuffer<Float>
    /// What a decimator is primed with.
    private let zeros: AlignedBuffer<Float>
    /// Frames sent on since the last reset.
    private var emitted = 0
    /// Samples taken since the last reset: the position of the next one.
    private var position = 0

    let latencyFrames: Int
    let settlingFrames: Int

    /// The most samples the octaves are run over at once, whatever the block.
    static let chunkLimit = 1_024

    /// - Parameters:
    ///   - kernels: one kernel per octave, highest octave first, or a single kernel that
    ///     serves every octave (a `gamma` of 0). Each is for the transform length of `plan`.
    ///   - taps: the half-band low-pass between two octaves.
    init(
        geometry: ConstantQGeometry, schedule: ConstantQSchedule, kernels: [ConstantQKernel], taps: [Float], plan: any FFTPlan,
        mixer: ChannelMixer
    ) throws(DSPError) {
        let octaves = schedule.octaves
        guard octaves >= 1, kernels.count == 1 || kernels.count == octaves else {
            throw .invalidParameter(stage: .none, parameter: "kernels", reason: "\(kernels.count) kernels for \(octaves) octaves: one for all of them, or one each")
        }
        binCount = geometry.binCount
        rowCount = geometry.binsPerOctave
        hop = schedule.hop
        sampleRate = geometry.sampleRate
        self.mixer = mixer
        self.plan = plan
        chunk = min(mixer.chunk, ConstantQNode.chunkLimit)
        latencyFrames = schedule.latency
        settlingFrames = schedule.settling

        var products: [SparseKernelProduct] = []
        var index = 0
        while index < kernels.count {
            let kernel = kernels[index]
            guard kernel.transformLength == plan.length, kernel.rowCount == geometry.binsPerOctave else {
                throw .invalidParameter(
                    stage: .none, parameter: "kernels",
                    reason: "a kernel of \(kernel.rowCount) rows for a transform of \(kernel.transformLength) points does not fit \(geometry.binsPerOctave) bins per octave and a transform of \(plan.length)")
            }
            products.append(try SparseKernelProduct(kernel))
            index += 1
        }

        var built: [ConstantQOctave] = []
        var longest = 1
        var depth = 0
        while depth < octaves {
            let span = schedule.spans[depth]
            guard span <= plan.length, span == kernels[kernels.count == 1 ? 0 : depth].span else {
                throw .invalidParameter(stage: .none, parameter: "kernels", reason: "the kernel of depth \(depth) is not the one the schedule was made for")
            }
            // Frames of this octave that can be complete before the lowest octave lets them go.
            let ahead = (schedule.latency - schedule.latencies[depth] + chunk) / schedule.hop + 2
            let isLowest = depth == octaves - 1
            built.append(try ConstantQOctave(
                span: span, hop: schedule.hops[depth], firstEnd: schedule.firstEnds[depth], product: products[kernels.count == 1 ? 0 : depth],
                decimator: isLowest ? nil : try HalfBandDecimator(taps: taps), prime: isLowest ? 0 : schedule.primes[depth],
                chunk: chunk, capacity: ahead))
            longest = max(longest, span)
            depth += 1
        }
        levels = built
        longestSpan = longest
        frame = try AlignedBuffer<Float>(count: plan.length)
        spectrumReal = try AlignedBuffer<Float>(count: plan.length / 2 + 1)
        spectrumImaginary = try AlignedBuffer<Float>(count: plan.length / 2 + 1)
        zeros = try AlignedBuffer<Float>(count: 4)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples, let real = output.real.baseAddress, let imaginary = output.imaginary.baseAddress else { return }
        let total = block.frameCount
        let origin = position
        let octaves = levels.count
        var done = 0
        while done < total {
            let count = min(total - done, chunk)
            var samples = mixer.sequence(of: block, from: done, count: count)
            var length = count
            var ready = Int.max
            var depth = 0
            while depth < octaves {
                let level = levels[depth]
                take(samples, count: length, into: level)
                if level.computed < ready { ready = level.computed }
                if let decimator = level.decimator {
                    let halved = level.halved.baseAddress
                    var produced = 0
                    // One zero ahead of the signal moves this octave's output by a sample of
                    // its input: what puts a sample of every octave below on each frame centre.
                    if !level.isPrimed {
                        if level.prime > 0 { produced = decimator.process(zeros.baseAddress, count: level.prime, into: halved) }
                        level.isPrimed = true
                    }
                    produced += decimator.process(samples, count: length, into: halved + produced)
                    samples = UnsafePointer(halved)
                    length = produced
                }
                depth &+= 1
            }
            // A frame leaves when the last of its octaves is complete.
            while emitted < ready {
                depth = 0
                while depth < octaves {
                    let level = levels[depth]
                    let slot = (emitted % level.capacity) &* rowCount
                    let first = (octaves &- 1 &- depth) &* rowCount
                    let stride = MemoryLayout<Float>.stride
                    memcpy(real + first, level.pendingReal.baseAddress + slot, rowCount &* stride)
                    memcpy(imaginary + first, level.pendingImaginary.baseAddress + slot, rowCount &* stride)
                    depth &+= 1
                }
                // The frame's time is the time of the sample it is centred on.
                output.emit(count: binCount, time: input.time + Double(emitted &* hop &- origin) / sampleRate)
                emitted &+= 1
            }
            done += count
        }
        position &+= total
    }

    /// Appends `count` samples of an octave's rate to its history, and transforms each frame
    /// that becomes complete on the way.
    @inline(__always)
    private func take(_ samples: UnsafePointer<Float>, count: Int, into level: ConstantQOctave) {
        var offset = 0
        while offset < count {
            let wanted = min(level.nextEnd &- level.received, count &- offset)
            level.history.append(samples + offset, count: wanted)
            level.received &+= wanted
            offset &+= wanted
            if level.received == level.nextEnd {
                transform(level)
                level.computed &+= 1
                level.nextEnd &+= level.hop
            }
        }
    }

    /// The coefficients of the frame an octave has just completed, into its ring.
    @inline(__always)
    private func transform(_ level: ConstantQOctave) {
        let stride = MemoryLayout<Float>.stride
        memcpy(frame.baseAddress, level.history.window, level.span &* stride)
        // A shorter span than the one before it leaves that one's samples behind.
        if level.span < longestSpan { memset(frame.baseAddress + level.span, 0, (longestSpan &- level.span) &* stride) }
        plan.forward(frame.baseAddress, real: spectrumReal.baseAddress, imaginary: spectrumImaginary.baseAddress)
        let slot = (level.computed % level.capacity) &* rowCount
        level.product.apply(
            real: spectrumReal.baseAddress, imaginary: spectrumImaginary.baseAddress,
            intoReal: level.pendingReal.baseAddress + slot, imaginary: level.pendingImaginary.baseAddress + slot)
    }

    func reset() {
        var depth = 0
        while depth < levels.count {
            levels[depth].reset()
            depth += 1
        }
        emitted = 0
        position = 0
    }
}
