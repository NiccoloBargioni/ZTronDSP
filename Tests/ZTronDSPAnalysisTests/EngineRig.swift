import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

// What the tests of this target need to see a stage in a running session: the engine driven
// turn by turn on the test's own thread, a source fed by hand, a probe on the main line. The
// stages themselves are reached through the public API; the hooks of the core used here are
// the ones its own tests use.

/// A push source the test writes into by hand.
final class HandFedSource: PushSampleSource, @unchecked Sendable {
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
final class MainLineListener: MainLineConsumer, @unchecked Sendable {
    // Threading: written by the thread that runs the session, read by the test in between.
    private(set) var samples: [Float] = []
    private(set) var blockLengths: [Int] = []
    func boundary() {}
    func consume(_ frame: FrameView) {
        guard let block = frame.samples else { return }
        samples.append(contentsOf: block.samples(ofChannel: 0))
        blockLengths.append(block.frameCount)
    }
}

/// An engine a test drives turn by turn, with a source the test feeds by hand.
struct SessionRig {
    let engine: DSPEngine
    let source: HandFedSource
    let blockSize: Int

    init(blockSize: Int = 64, sampleRate: Double = 48_000, channelCount: Int = 1) {
        engine = DSPEngine(blockSize: blockSize, drivenByHand: true)
        source = HandFedSource(format: SignalFormat(sampleRate: sampleRate, channelCount: channelCount))
        self.blockSize = blockSize
    }

    /// Attaches a pipeline, starts the session and returns it with a listener on its output.
    func run<Output>(_ pipeline: Pipeline<Samples, Output>) async throws -> (session: PipelineSession, output: MainLineListener) {
        let session = try await engine.attach(pipeline, to: source)
        let listener = MainLineListener()
        engine.core.addProbe(listener, to: session.core)
        try session.start()
        return (session, listener)
    }

    /// Attaches a pipeline and starts the session with nothing listening to its output: what
    /// the allocation audit runs, since a listener that keeps samples allocates.
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

/// The kernels a pipeline lowers to, after fusion: what shows that a stage emits the specs it
/// should and fuses as it should.
func loweredKernelSpecs<Output>(
    _ pipeline: Pipeline<Samples, Output>, sampleRate: Double = 48_000, channelCount: Int = 1, blockSize: Int = 512,
    crossovers: CrossoverTable = .shipped
) throws -> [KernelSpec] {
    let environment = DSPEnvironment(sampleRate: sampleRate, channelCount: channelCount, blockSize: blockSize)
    let lowered = try PlanCompiler(crossovers: crossovers).lower(pipeline.stages, environment: environment, blockSize: blockSize)
    return IRStep.kernels(of: lowered.steps).map(\.spec)
}

/// The environment at the end of a pipeline's main line.
func environmentAtTheEnd<Output>(of pipeline: Pipeline<Samples, Output>, sampleRate: Double = 48_000, blockSize: Int = 512) throws -> DSPEnvironment {
    let environment = DSPEnvironment(sampleRate: sampleRate, channelCount: 1, blockSize: blockSize)
    return try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: blockSize).output.environment
}

/// The steps a pipeline lowers to, after fusion.
func loweredSteps<Output>(_ pipeline: Pipeline<Samples, Output>, sampleRate: Double = 48_000, blockSize: Int = 512) throws -> [IRStep] {
    let environment = DSPEnvironment(sampleRate: sampleRate, channelCount: 1, blockSize: blockSize)
    return try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: blockSize).steps
}

/// After a cold start a plan gives, for the same samples, the frames of a fresh stream: values
/// and times. Without one it gives another stream, or the check would pass for a reset that
/// does nothing (ACT-10).
func expectAFreshStreamAfterAColdStart<D: SignalDomain>(
    of pipeline: Pipeline<Samples, D>, on samples: [Float], _ name: String, format: SignalFormat = mono48, blockSize: Int = 512,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let cold = try twoPasses(of: pipeline, on: samples, coldStart: true, format: format, blockSize: blockSize)
    let warm = try twoPasses(of: pipeline, on: samples, coldStart: false, format: format, blockSize: blockSize)
    func repeats<T: Equatable>(_ values: [T]) -> Bool {
        values.count % 2 == 0 && Array(values[..<(values.count / 2)]) == Array(values[(values.count / 2)...])
    }
    #expect(cold.frameCount >= 2, "\(name): \(cold.frameCount) frames in two passes", sourceLocation: sourceLocation)
    #expect(repeats(cold.times) && repeats(cold.blockLengths), "\(name): the second pass has the times of a fresh stream", sourceLocation: sourceLocation)
    #expect(repeats(cold.reals) && repeats(cold.imaginaries) && repeats(cold.scalars) && repeats(cold.samples),
            "\(name): the second pass has the values of a fresh stream", sourceLocation: sourceLocation)
    #expect(warm.reals != cold.reals || warm.imaginaries != cold.imaginaries || warm.scalars != cold.scalars || warm.samples != cold.samples
            || warm.times != cold.times, "\(name): without a cold start the second pass is another stream", sourceLocation: sourceLocation)
}
