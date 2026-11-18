import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPTesting

// What the tests of the stages need to see a stage in a plan and in a running session: the
// engine driven turn by turn on the test's own thread, a source fed by hand, the lowered form
// of a pipeline. The stages themselves are reached through the public API only; the hooks of
// the core used here are the ones its own tests use.

/// A push source the test writes into by hand.
final class ManualSource: PushSampleSource, @unchecked Sendable {
    // Threading: the ring is set once on the control context and written by the test's thread.
    let format: SignalFormat
    private let channel = SourceEventChannel()
    private let writer = Locked<RingWriter?>(nil)

    init(format: SignalFormat) {
        self.format = format
    }

    var events: AsyncStream<SourceEvent> { channel.stream }
    func prepare() async throws(DSPError) {}
    func start() throws(DSPError) {}
    func stop() {}
    func connect(to ring: RingWriter) { writer.set(ring) }

    /// Writes one channel of samples to every channel of the ring.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        guard let ring = writer.get() else { return 0 }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            var table = [UnsafePointer<Float>?](repeating: buffer.baseAddress, count: ring.channelCount)
            return table.withUnsafeMutableBufferPointer { ring.write(channels: $0.baseAddress!, frameCount: samples.count) }
        }
    }

    /// Writes a block without allocating: what an audited loop feeds the ring with.
    @discardableResult
    func write(_ block: AudioBlock) -> Int {
        writer.withLock { $0?.write(block) ?? 0 }
    }
}

/// Listens to the main-line output of a session.
final class MainLineProbe: MainLineConsumer, @unchecked Sendable {
    // Threading: written by the thread that runs the session, read by the test in between.
    private(set) var samples: [Float] = []
    func boundary() {}
    func consume(_ frame: FrameView) {
        guard let block = frame.samples else { return }
        samples.append(contentsOf: block.samples(ofChannel: 0))
    }
}

/// An engine a test drives turn by turn, with a source the test feeds by hand.
struct StageRig {
    let engine: DSPEngine
    let source: ManualSource
    let blockSize: Int

    init(blockSize: Int = 64, sampleRate: Double = 48_000, channelCount: Int = 1) {
        engine = DSPEngine(blockSize: blockSize, drivenByHand: true)
        source = ManualSource(format: SignalFormat(sampleRate: sampleRate, channelCount: channelCount))
        self.blockSize = blockSize
    }

    /// Attaches a pipeline, starts the session and returns it with a probe on its output.
    func run<Output>(_ pipeline: Pipeline<Samples, Output>) async throws -> (session: PipelineSession, probe: MainLineProbe) {
        let session = try await engine.attach(pipeline, to: source)
        let probe = MainLineProbe()
        engine.core.addProbe(probe, to: session.core)
        try session.start()
        return (session, probe)
    }

    /// Attaches a pipeline and starts the session with nothing listening to its output: what
    /// the allocation audit runs, since a probe that keeps samples allocates.
    func start<Output>(_ pipeline: Pipeline<Samples, Output>) async throws -> PipelineSession {
        let session = try await engine.attach(pipeline, to: source)
        try session.start()
        return session
    }

    /// Writes `samples` and runs the engine until they are processed.
    func feed(_ samples: [Float]) {
        var position = 0
        while position < samples.count {
            let end = min(position + blockSize * 32, samples.count)
            source.write(Array(samples[position ..< end]))
            engine.core.runTurn()
            position = end
        }
        engine.core.flush()
    }

    /// Lets everything the test asked of the main thread and of the control context happen.
    func drain() async {
        await MainActor.run {}
        engine.core.flush()
        await MainActor.run {}
    }

    /// Runs `blocks` blocks of `block` through the session inside the allocation audit
    /// (RT-7): the steady state of a live session, on this thread.
    func auditAllocations(blocks: Int, of block: [Float], _ comment: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let runner = try #require(engine.core.rootRunners().first)
        let buffer = try AudioBuffer(channels: [[Float]](repeating: block, count: source.format.channelCount))
        expectNoAllocations(comment, sourceLocation: sourceLocation) {
            var count = 0
            while count < blocks {
                source.write(buffer.block())
                _ = runner.turn(now: 0)
                count += 1
            }
        }
    }
}

/// The kernels a pipeline lowers to, after fusion, for a signal of the given format: what
/// shows that stages emit the specs they should and fuse as they should (F1 … F4).
func loweredKernels<Output>(
    _ pipeline: Pipeline<Samples, Output>, sampleRate: Double = 48_000, channelCount: Int = 1, blockSize: Int = 512
) throws -> [KernelSpec] {
    let environment = DSPEnvironment(sampleRate: sampleRate, channelCount: channelCount, blockSize: blockSize)
    let lowered = try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: blockSize)
    return IRStep.kernels(of: lowered.steps).map(\.spec)
}

/// The environment at the end of a pipeline's main line.
func outputEnvironment<Output>(_ pipeline: Pipeline<Samples, Output>, sampleRate: Double = 48_000, blockSize: Int = 512) throws -> DSPEnvironment {
    let environment = DSPEnvironment(sampleRate: sampleRate, channelCount: 1, blockSize: blockSize)
    return try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: blockSize).output.environment
}

/// A sink that keeps what it is given, and the environment it was claimed in.
final class Collector<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    typealias Domain = D
    // Threading: written by the thread that runs the plan, read by the test after it finished.
    private(set) var samples: [Float] = []
    private(set) var scalars: [ScalarFrame] = []
    private(set) var environment: DSPEnvironment?

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        self.environment = environment
    }

    func write(_ frame: FrameView) {
        if let block = frame.samples { samples.append(contentsOf: block.samples(ofChannel: 0)) }
        if let scalar = frame.scalar { scalars.append(scalar) }
    }

    func release() {}
}

/// State behind a SwiftUI binding, for tests: what `@State` is to a view.
final class StateBox<Value: Sendable>: @unchecked Sendable {
    // Threading: tests read and write it on one thread at a time.
    var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

/// A step that turns samples into one value per `hop` samples (their mean): what puts a scalar
/// track in front of a sequence stage in a test.
struct MeanTrack: PipelineStage {
    typealias Input = Samples
    typealias Output = Scalar
    let hop: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let hop = hop
        let rate = context.environment.sampleRate / Double(hop)
        context.emit(.analysis(AnalysisStep(name: "MeanTrack", key: self, output: .scalar, scope: .featureSequence(rate: rate)) {
            () throws(DSPError) -> any AnalysisNode in MeanTrackNode(hop: hop)
        }))
    }
}

final class MeanTrackNode: AnalysisNode {
    let hop: Int
    private var sum: Float = 0
    private var count = 0

    init(hop: Int) {
        self.hop = hop
    }

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        let samples = block.channel(0)
        var index = 0
        while index < block.frameCount {
            sum += samples[index]
            count += 1
            if count == hop {
                output.emit(scalar: ScalarFrame(value: sum / Float(hop), confidence: 1))
                sum = 0
                count = 0
            }
            index += 1
        }
    }

    func reset() {
        sum = 0
        count = 0
    }
}
