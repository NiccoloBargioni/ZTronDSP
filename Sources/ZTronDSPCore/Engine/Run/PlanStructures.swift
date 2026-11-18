import Darwin

// The run-time shape of a plan (§5.5.2): what the analysis thread walks once per block.
// Everything here is created on the control context and then touched by one thread at a time,
// the analysis thread. Nothing in this file allocates after its initialiser returns.

/// A kernel and its state, owned once, whatever plans refer to it. A plan change moves the
/// box, state included, into the new plan (SWAP-1); the kernel is freed with the last plan
/// that holds it, off the analysis thread.
final class KernelBox {
    var kernel: ztd_kernel_t
    /// What the kernel was made from, a kernel step or a switched group of them: the identity
    /// that lets a new plan take it over. A change of values replaces it (control context).
    var source: IRStep
    /// Where the kernel sits in the signal: its own place, or its group's.
    let position: IRPosition

    init(kernel: ztd_kernel_t, source: IRStep, position: IRPosition) {
        self.kernel = kernel
        self.source = source
        self.position = position
    }

    deinit {
        ztd_kernel_destroy(&kernel)
    }
}

/// A run of adjacent kernels: one C plan, run with one call (§5.5.2).
final class KernelRun {
    let plan: OpaquePointer
    let boxes: [KernelBox]
    /// True on a feature-rate sequence: one value per call instead of a block.
    let isScalar: Bool
    let channels: Int
    let output: AudioBuffer
    /// Storage for the signal between the kernels the old and the new plan share and the ones
    /// they do not, while a plan change is in flight.
    let middle: AudioBuffer
    let scalarInput: AudioBuffer
    /// Seconds between a sample entering the run and its counterpart leaving it.
    let latency: Double
    /// Samples per second leaving the run.
    let outputRate: Double
    var produced = 0
    var origin = 0.0
    var started = false

    init(plan: OpaquePointer, boxes: [KernelBox], isScalar: Bool, channels: Int, maximumFrames: Int, latency: Double, outputRate: Double) throws(DSPError) {
        self.plan = plan
        self.boxes = boxes
        self.isScalar = isScalar
        self.channels = channels
        self.output = try AudioBuffer(channelCount: channels, capacity: maximumFrames)
        self.middle = try AudioBuffer(channelCount: channels, capacity: maximumFrames)
        self.scalarInput = try AudioBuffer(channelCount: 1, capacity: 1)
        self.latency = latency
        self.outputRate = outputRate
    }

    deinit {
        // The kernels are borrowed from their boxes; the plan frees only its own tables.
        ztd_plan_destroy(plan)
    }

    /// Runs the kernels `first ..< last` on `frame` into `target` and returns what came out,
    /// or `nil` when the run produced nothing for this input (a rate changer may).
    @inline(__always)
    func process(_ frame: FrameView, first: UInt32, last: UInt32, into target: AudioBuffer) -> FrameView? {
        if !started {
            started = true
            origin = frame.time
            produced = 0
        }
        if isScalar {
            guard let value = frame.scalar else { return nil }
            scalarInput.channel(0).pointee = value.value
            let written = ztd_plan_run_range(plan, first, last, scalarInput.block().constantChannelTable, target.block().channelTable, 1, 1)
            guard written > 0 else { return nil }
            // A filter changes the value; the confidence of the measurement stays its own.
            return FrameView(scalar: ScalarFrame(value: target.channel(0).pointee, confidence: value.confidence),
                             index: frame.index, time: frame.time - latency)
        }
        guard let block = frame.samples else { return nil }
        let written = Int(ztd_plan_run_range(plan, first, last, block.constantChannelTable, target.block().channelTable,
                                             UInt32(channels), UInt32(block.frameCount)))
        guard written > 0 else { return nil }
        return FrameView(samples: target.block(frameCount: written), index: produced, time: origin + Double(produced) / outputRate - latency)
    }

    /// Counts what a completed pass through the whole run produced.
    @inline(__always)
    func advance(_ frame: FrameView) {
        if !isScalar { produced &+= frame.count }
    }

    func reset() {
        ztd_plan_reset(plan)
        started = false
        produced = 0
    }
}

/// A node, its output storage and its frame counter, owned once (SWAP-1).
final class NodeBox {
    let node: any AnalysisNode
    let source: IRNode
    let format: FrameFormat
    let counter: UnsafeMutablePointer<Int>
    private let realStorage: AlignedBuffer<Float>?
    private let imaginaryStorage: AlignedBuffer<Float>?
    private let sampleStorage: AudioBuffer?
    let first: UnsafeMutableRawPointer?
    let second: UnsafeMutableRawPointer?
    let capacity: Int
    let channelCount: Int

    init(node: any AnalysisNode, source: IRNode) throws(DSPError) {
        self.node = node
        self.source = source
        self.format = source.step.output
        counter = .allocate(capacity: 1)
        counter.initialize(to: 0)
        switch source.step.output {
        case .real(let count):
            let storage = try AlignedBuffer<Float>(count: max(count, 1))
            (realStorage, imaginaryStorage, sampleStorage) = (storage, nil, nil)
            (first, second, capacity, channelCount) = (UnsafeMutableRawPointer(storage.baseAddress), nil, count, 1)
        case .complex(let count):
            let real = try AlignedBuffer<Float>(count: max(count, 1)), imaginary = try AlignedBuffer<Float>(count: max(count, 1))
            (realStorage, imaginaryStorage, sampleStorage) = (real, imaginary, nil)
            (first, second, capacity, channelCount) = (UnsafeMutableRawPointer(real.baseAddress), UnsafeMutableRawPointer(imaginary.baseAddress), count, 1)
        case .envelope(let count):
            let minima = try AlignedBuffer<Float>(count: max(count, 1)), maxima = try AlignedBuffer<Float>(count: max(count, 1))
            (realStorage, imaginaryStorage, sampleStorage) = (minima, maxima, nil)
            (first, second, capacity, channelCount) = (UnsafeMutableRawPointer(minima.baseAddress), UnsafeMutableRawPointer(maxima.baseAddress), count, 1)
        case .samples(let channels, let frames):
            let storage = try AudioBuffer(channelCount: max(channels, 1), capacity: max(frames, 1))
            (realStorage, imaginaryStorage, sampleStorage) = (nil, nil, storage)
            (first, second, capacity, channelCount) = (UnsafeMutableRawPointer(mutating: storage.block().channelTable), nil, max(frames, 1), max(channels, 1))
        case .scalar:
            (realStorage, imaginaryStorage, sampleStorage) = (nil, nil, nil)
            (first, second, capacity, channelCount) = (nil, nil, 1, 1)
        }
    }

    deinit {
        counter.deallocate()
    }

    func reset() {
        node.reset()
        counter.pointee = 0
    }
}

/// The switch of a branch, a sink or a suspension point: a flag the analysis thread flips at
/// a block boundary and tests once per block (ACT-5).
final class SwitchCell {
    var isOn: Bool

    init(isOn: Bool) {
        self.isOn = isOn
    }
}

/// A node's place in one plan: where its frames continue.
final class NodeSlot: FrameDelivery {
    let box: NodeBox
    unowned(unsafe) var plan: ExecutionPlan!
    unowned(unsafe) var segment: PlanSegment!
    var next = 0

    init(box: NodeBox) {
        self.box = box
        super.init()
    }

    override func deliver(_ frame: FrameView) {
        plan.run(segment, from: next, frame)
    }

    @inline(__always)
    func process(_ frame: FrameView) {
        var writer = FrameWriter(format: box.format, delivery: self, first: box.first, second: box.second, capacity: box.capacity,
                                 channelCount: box.channelCount, counter: box.counter, inputTime: frame.time)
        box.node.process(frame, &writer)
    }
}

/// A sink's place in one plan.
final class SinkSlot {
    let sink: any PlanSink
    let cell: SwitchCell?
    /// Set when the branch that feeds the sink is not the one that fed it in the plan before:
    /// what the sink held is stale and is cleared at the exchange (SWAP-3).
    var isNewBranch = true
    /// Set by the control context, while the plan is off its thread, when the sink has been
    /// prepared for the plan that follows this one: this plan writes it no more.
    var isRetired = false

    init(sink: any PlanSink, cell: SwitchCell?) {
        self.sink = sink
        self.cell = cell
    }
}

/// A switched run of steps that keeps the domain and the rate and is not one kernel: a group
/// that holds an analysis node, or a recipe such as a separation and its resynthesis.
///
/// On samples the switch is what ACT-7 and ACT-8 ask of every stage. The unprocessed path is
/// the input delayed by the latency of the stages inside, so switching never moves the signal
/// in time; off and on are cross-fades of 10 ms between the two paths; switched on, the
/// stages inside are reset and run with their output discarded until they have settled, and
/// only then faded in; switched off, they do not run at all. The stages inside may deliver
/// their output in blocks of another size and later than their input arrives, so both paths
/// are kept by the index of each sample in the stream, not block by block.
///
/// On any other domain the steps are skipped while the switch is off, and the frames pass.
final class RegionSlot {
    enum State {
        /// The stages inside run and their output is used.
        case active
        /// Cross-fading from the processed to the unprocessed signal.
        case fadingOut
        /// The stages inside do not run; the delayed input passes.
        case bypassed
        /// The stages inside run with their output discarded; the delayed input passes.
        case prerolling
        /// Cross-fading from the unprocessed to the processed signal.
        case fadingIn
    }

    let cell: SwitchCell
    /// The key of the region's place in the signal.
    let key: Int
    /// The index of the first step after the region.
    var end = 0

    /// True for a region of samples: the switch is the faded one.
    let fades: Bool
    let channels: Int
    let sampleRate: Double
    /// Frames the stages inside delay the signal by.
    let latency: Int
    let fadeLength: Int
    /// Frames the stages inside run before they are faded in.
    var prerollLength = 0
    /// The most frames one block of the unprocessed path holds.
    let chunk: Int
    private let history: AudioBuffer?
    private let mask: Int
    private let scratch: AudioBuffer?

    var state: State
    /// Frames of input seen so far.
    var inputCount = 0
    /// The place in the output stream of the next sample the stages inside deliver.
    var processedIndex = 0
    /// The place in the output stream of the next sample to hand on.
    var emittedIndex = 0
    var fadePosition = 0
    var prerollLeft = 0
    private var originTime = 0.0

    /// A region that is skipped while it is off.
    init(cell: SwitchCell, key: Int) {
        self.cell = cell
        self.key = key
        fades = false
        channels = 1
        sampleRate = 1
        latency = 0
        fadeLength = 1
        chunk = 1
        history = nil
        mask = 0
        scratch = nil
        state = cell.isOn ? .active : .bypassed
    }

    /// A region of samples with a faded, latency-matched bypass.
    init(cell: SwitchCell, key: Int, channels: Int, sampleRate: Double, latency: Int, fadeLength: Int, maximumFrames: Int) throws(DSPError) {
        self.cell = cell
        self.key = key
        fades = true
        self.channels = max(channels, 1)
        self.sampleRate = sampleRate
        self.latency = max(latency, 0)
        self.fadeLength = max(fadeLength, 1)
        chunk = max(maximumFrames, 1)
        // Room for the delay, and for as long as the stages inside may hold a sample back.
        var capacity = 1
        while capacity < self.latency + max(4 * chunk, 8_192) + chunk { capacity *= 2 }
        mask = capacity - 1
        history = try AudioBuffer(channelCount: self.channels, capacity: capacity)
        scratch = try AudioBuffer(channelCount: self.channels, capacity: chunk)
        state = cell.isOn ? .active : .bypassed
    }

    /// A cold start: nothing seen, nothing delivered, the switch where it was last put.
    func restart() {
        history?.clear()
        inputCount = 0
        processedIndex = 0
        emittedIndex = 0
        fadePosition = 0
        prerollLeft = 0
        state = cell.isOn ? .active : .bypassed
    }

    /// Keeps the input for the unprocessed path. One copy of the block (ACT-8).
    @inline(__always)
    func capture(_ block: AudioBlock, time: Double) {
        guard let history else { return }
        originTime = time - Double(inputCount) / sampleRate
        let frames = block.frameCount
        let start = inputCount & mask
        let first = min(frames, mask &+ 1 &- start)
        var channel = 0
        while channel < channels, channel < block.channelCount {
            let ring = history.channel(channel), source = block.channel(channel)
            memcpy(ring + start, source, first * MemoryLayout<Float>.stride)
            if frames > first { memcpy(ring, source + first, (frames - first) * MemoryLayout<Float>.stride) }
            channel += 1
        }
        inputCount &+= frames
    }

    /// The unprocessed signal for the places `index ..< index + count` of the output stream:
    /// the input, `latency` frames late. Zeros before the first input.
    func dry(from index: Int, count: Int) -> FrameView {
        guard let history, let scratch else { return FrameView(scalar: .none, index: index, time: 0) }
        let frames = min(max(count, 0), chunk)
        let source = index &- latency
        let silent = min(max(-source, 0), frames)
        var channel = 0
        while channel < channels {
            let target = scratch.channel(channel), ring = history.channel(channel)
            if silent > 0 { memset(target, 0, silent * MemoryLayout<Float>.stride) }
            if frames > silent {
                let start = (source &+ silent) & mask
                let first = min(frames - silent, mask &+ 1 &- start)
                memcpy(target + silent, ring + start, first * MemoryLayout<Float>.stride)
                if frames - silent > first { memcpy(target + silent + first, ring, (frames - silent - first) * MemoryLayout<Float>.stride) }
            }
            channel += 1
        }
        return FrameView(samples: scratch.block(frameCount: frames), index: index, time: originTime + Double(source) / sampleRate)
    }

    /// The frames of `block` from `skip` on, cross-faded with the unprocessed signal for the
    /// same places of the output stream, which start at `index`. Moves the fade on.
    func mix(_ block: AudioBlock, skipping skip: Int, at index: Int) -> FrameView {
        let frames = min(block.frameCount - skip, chunk)
        let mixed = dry(from: index, count: frames)
        guard let scratch, frames > 0 else { return mixed }
        let step = 1 / Float(fadeLength)
        let towardsProcessed = state == .fadingIn
        var channel = 0
        while channel < channels, channel < block.channelCount {
            let target = scratch.channel(channel), processed = block.channel(channel) + skip
            var gain = Float(fadePosition) * step
            var frame = 0
            while frame < frames {
                let weight = min(gain, 1)
                // `target` holds the unprocessed sample.
                target[frame] = towardsProcessed
                    ? target[frame] + weight * (processed[frame] - target[frame])
                    : processed[frame] + weight * (target[frame] - processed[frame])
                gain += step
                frame += 1
            }
            channel += 1
        }
        fadePosition &+= frames
        return mixed
    }
}

enum PlanStep {
    case kernels(KernelRun)
    case node(NodeSlot)
    case branch(PlanSegment)
    case emission(SinkSlot)
    /// A stage that changes the domain or the rate and is bound: off, the rest is suspended.
    /// `key` is the key of its place in the signal.
    case gate(SwitchCell, key: Int)
    case region(RegionSlot)
    /// The end of a region of samples: where what the stages inside deliver meets the
    /// unprocessed path.
    case regionEnd(RegionSlot)
    /// The end of the main line: the block goes to whoever takes the processed signal.
    case output
}

/// A run of steps: the main line, or a branch.
final class PlanSegment {
    var steps: ContiguousArray<PlanStep> = []
    /// The switch of the tap this branch came from, when it is bound.
    let cell: SwitchCell?
    /// True for a prefix several branches share: it runs while any of them does (ACT-9).
    let isShared: Bool
    /// Whether the segment runs: its own switch is on and, for a shared prefix, at least one
    /// of the branches it serves is live. Recomputed when a switch moves.
    var isLive = true
    var children: [PlanSegment] = []

    init(cell: SwitchCell?, isShared: Bool) {
        self.cell = cell
        self.isShared = isShared
    }

    /// Recomputes liveness from the leaves up.
    @discardableResult
    func refreshLiveness() -> Bool {
        var anyChild = false
        var index = 0
        while index < children.count {
            if children[index].refreshLiveness() { anyChild = true }
            index += 1
        }
        let own = cell?.isOn ?? true
        isLive = own && (!isShared || anyChild)
        return isLive
    }
}

/// What a bound switch acts on, by its ordinal.
enum SwitchTarget {
    /// A kernel with a faded bypass inside a C plan.
    case kernel(KernelRun, entry: UInt32)
    /// A side branch: off, it is suspended; on again, it starts cold (ACT-10).
    case branch(PlanSegment)
    case emission(SwitchCell)
    /// A suspension point: on again, everything after it in its segment starts cold.
    case gate(SwitchCell, segment: PlanSegment, index: Int)
    case region(RegionSlot, segment: PlanSegment, index: Int)
    /// A switch whose stage compiled to nothing.
    case none
}
