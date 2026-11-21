/// A step between domains as the analysis thread runs it: frames in, frames out (§5.11.1).
///
/// A node is created on the control context when a plan is compiled (it allocates everything
/// it will need there, RT-3) and from then on belongs to the analysis thread. `process` is
/// bound by RT-2: no allocation, no lock, no logging, no `await`; loops are `while` loops
/// (CR-002). A node may write no frame for an input, or several.
public protocol AnalysisNode: AnyObject {
    /// The delay the node adds, in frames of its input.
    var latencyFrames: Int { get }
    /// Input frames the node needs, after a reset, before its output is what it would have
    /// been had it always been running: its pre-roll (SWAP-2, ACT-7).
    var settlingFrames: Int { get }
    /// Takes one input frame and writes zero or more output frames. Analysis thread.
    func process(_ input: FrameView, _ output: inout FrameWriter)
    /// Back to the state at creation: a cold start (ACT-10). Analysis thread; allocation-free.
    func reset()
}

/// A sample-domain stage written in Swift (§5.11.1): it processes a block in place.
///
/// Created on the control context, where it may allocate; `process` and `reset` run on the
/// analysis thread under RT-2 and do not allocate. The block keeps its frame count: a
/// processor does not change the rate.
public protocol SampleProcessor: AnyObject {
    /// The delay the processor adds, in frames.
    var latencyFrames: Int { get }
    /// Frames the processor needs, after a reset, before its output has settled.
    var settlingFrames: Int { get }
    /// Processes the block in place. Analysis thread.
    func process(_ block: inout AudioBlock)
    /// Back to the state at creation. Analysis thread; allocation-free.
    func reset()
}

/// A `SampleProcessor` that takes its stage's continuous values while it runs (§5.5.4,
/// EXT-1): what `CustomProcessor.init(name:key:values:latencyFrames:make:)` makes.
///
/// A change of the values a stage states is then a change of values: no plan is compiled, the
/// processor keeps its state, and the new values reach it between two blocks.
///
/// Threading as for every `SampleProcessor`: created on the control context, where it
/// allocates what it needs; `setValues(_:)`, `process` and `reset` run on the analysis thread
/// under RT-2, one thread at a time.
public protocol AdjustableSampleProcessor: SampleProcessor {
    /// Takes the stage's values: as many as `CustomProcessor.values` states, in that order.
    ///
    /// Analysis thread, between two blocks, under RT-2: no allocation, no lock, nothing that
    /// blocks. The buffer belongs to the engine and is valid during the call only: copy what
    /// is needed. A reset keeps the values that were set last.
    func setValues(_ values: UnsafeBufferPointer<Double>)
}

/// A `SampleProcessor` that reads one block and writes another (EXT-4).
///
/// A processor that works in place is handed a copy of its input, because the block a plan
/// reads is not the plan's to write. One that conforms to this protocol is handed the plan's
/// input and the plan's output instead, and nothing is copied in front of it: a processor of
/// one multiplication then costs what the stock gain costs. The plan calls this entry and
/// never the in-place one, which the type keeps for whoever runs it by hand.
///
/// Threading as for every `SampleProcessor`: created on the control context, where it
/// allocates what it needs; both `process` entries and `reset` run on the analysis thread
/// under RT-2, one thread at a time. The plan asks whether a processor conforms once, on the
/// control context, when it makes the processor's kernel.
public protocol OutOfPlaceSampleProcessor: SampleProcessor {
    /// Writes `input`, processed, into `output`.
    ///
    /// Both blocks have the channels the processor was made for; `output` holds
    /// `input.frameCount` frames, each of which the processor writes. The two never overlap,
    /// and `input` is read only: it may be the block every session on the source reads.
    /// Analysis thread, under RT-2: no allocation, no lock, nothing that blocks.
    func process(_ input: AudioBlock, into output: inout AudioBlock)
}

/// Where a `FrameWriter` sends what it is given. The plan's continuation is one; a test
/// harness is another.
@usableFromInline
class FrameDelivery {
    @usableFromInline init() {}

    /// Takes one finished frame. Analysis thread.
    @usableFromInline
    func deliver(_ frame: FrameView) {}
}

/// What a node writes its output through (§5.11.1).
///
/// The writer lends the node the storage for one output frame, sized as the node declared
/// when it was lowered. The node fills it and calls `emit`, which hands the frame downstream
/// at once; it may do so no times, once, or several times per input. The storage is reused
/// for the next frame: `emit` first, then write again.
///
/// Analysis thread; it does not allocate.
public struct FrameWriter {
    /// The shape of the frames this writer takes.
    public let format: FrameFormat
    @usableFromInline unowned(unsafe) let delivery: FrameDelivery
    @usableFromInline let first: UnsafeMutableRawPointer?
    @usableFromInline let second: UnsafeMutableRawPointer?
    @usableFromInline let capacity: Int
    @usableFromInline let channelCount: Int
    /// Frames emitted so far: the index of the next one. It belongs to the node's storage, so
    /// it survives a plan change that keeps the node (SWAP-1).
    @usableFromInline let counter: UnsafeMutablePointer<Int>
    /// The time of the input frame being processed, which an emitted frame inherits unless the
    /// node says otherwise.
    @usableFromInline let inputTime: Double

    @usableFromInline
    init(format: FrameFormat, delivery: FrameDelivery, first: UnsafeMutableRawPointer?, second: UnsafeMutableRawPointer?,
         capacity: Int, channelCount: Int, counter: UnsafeMutablePointer<Int>, inputTime: Double) {
        self.format = format
        self.delivery = delivery
        self.first = first
        self.second = second
        self.capacity = capacity
        self.channelCount = channelCount
        self.counter = counter
        self.inputTime = inputTime
    }

    /// The values of a real frame, or the real parts of a complex one.
    @inlinable public var real: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: first?.assumingMemoryBound(to: Float.self),
                                   count: format.kind == .real || format.kind == .complex ? capacity : 0)
    }

    /// The imaginary parts of a complex frame.
    @inlinable public var imaginary: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: second?.assumingMemoryBound(to: Float.self), count: format.kind == .complex ? capacity : 0)
    }

    /// The minima of an envelope frame.
    @inlinable public var minima: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: first?.assumingMemoryBound(to: Float.self), count: format.kind == .envelope ? capacity : 0)
    }

    /// The maxima of an envelope frame.
    @inlinable public var maxima: UnsafeMutableBufferPointer<Float> {
        UnsafeMutableBufferPointer(start: second?.assumingMemoryBound(to: Float.self), count: format.kind == .envelope ? capacity : 0)
    }

    /// The block a node that produces samples writes into: `capacity` frames per channel.
    @inlinable public var samples: AudioBlock? {
        guard format.kind == .samples, let first else { return nil }
        return AudioBlock(channels: UnsafePointer(first.assumingMemoryBound(to: UnsafeMutablePointer<Float>?.self)),
                          channelCount: channelCount, capacity: capacity, frameCount: capacity)
    }

    /// Sends the frame downstream.
    ///
    /// - Parameters:
    ///   - count: how many values, bins, pairs or frames of samples are valid; the declared
    ///     size when left out.
    ///   - time: the time the frame describes, in seconds since the session started; the time
    ///     of the input frame when left out.
    @inlinable
    public mutating func emit(count: Int? = nil, time: Double? = nil) {
        let valid = min(max(count ?? capacity, 0), capacity)
        let index = counter.pointee
        let stamp = time ?? inputTime
        let frame: FrameView
        switch format.kind {
        case .real:
            frame = FrameView(kind: .real, index: index, time: stamp, first: first, second: nil, count: valid, channelCount: 1, capacity: capacity, scalar: .none)
        case .complex:
            frame = FrameView(kind: .complex, index: index, time: stamp, first: first, second: second, count: valid, channelCount: 1, capacity: capacity, scalar: .none)
        case .envelope:
            frame = FrameView(kind: .envelope, index: index, time: stamp, first: first, second: second, count: valid, channelCount: 1, capacity: capacity, scalar: .none)
        case .samples:
            frame = FrameView(kind: .samples, index: index, time: stamp, first: first, second: nil, count: valid, channelCount: channelCount, capacity: capacity, scalar: .none)
        case .scalar:
            frame = FrameView(scalar: .none, index: index, time: stamp)
        }
        counter.pointee = format.kind == .samples ? index &+ valid : index &+ 1
        delivery.deliver(frame)
    }

    /// Sends one value with its confidence downstream.
    @inlinable
    public mutating func emit(scalar: ScalarFrame, time: Double? = nil) {
        let index = counter.pointee
        counter.pointee = index &+ 1
        delivery.deliver(FrameView(scalar: scalar, index: index, time: time ?? inputTime))
    }
}
