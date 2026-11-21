import Accelerate
import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// One multiplication per sample, as a processor that works in place.
private final class ScalingProcessor: SampleProcessor {
    let latencyFrames = 0
    let settlingFrames = 0
    private let factor: Float

    init(_ factor: Float) {
        self.factor = factor
    }

    func process(_ block: inout AudioBlock) {
        // A local, so that no access to the object is checked while vDSP runs.
        var factor = factor
        var channel = 0
        while channel < block.channelCount {
            let samples = block.channel(channel)
            vDSP_vsmul(samples, 1, &factor, samples, 1, vDSP_Length(block.frameCount))
            channel += 1
        }
    }

    func reset() {}
}

/// The same multiplication, as a processor that reads one block and writes another. It counts
/// which of its two entries is called.
private final class BlockScalingProcessor: OutOfPlaceSampleProcessor {
    let latencyFrames = 0
    let settlingFrames = 0
    private let factor: Float
    private(set) var inPlaceCalls = 0
    private(set) var blockToBlockCalls = 0

    init(_ factor: Float) {
        self.factor = factor
    }

    func process(_ block: inout AudioBlock) {
        inPlaceCalls += 1
        var factor = factor
        var channel = 0
        while channel < block.channelCount {
            let samples = block.channel(channel)
            vDSP_vsmul(samples, 1, &factor, samples, 1, vDSP_Length(block.frameCount))
            channel += 1
        }
    }

    func process(_ input: AudioBlock, into output: inout AudioBlock) {
        blockToBlockCalls += 1
        var factor = factor
        var channel = 0
        while channel < input.channelCount {
            vDSP_vsmul(input.channel(channel), 1, &factor, output.channel(channel), 1, vDSP_Length(input.frameCount))
            channel += 1
        }
    }

    func reset() {}
}

/// Keeps the processors a stage made, for a test to look at.
private final class Made: Hashable, @unchecked Sendable {
    // Threading: appended to where a plan is compiled and read by the test afterwards, both on the test's thread.
    private(set) var processors: [BlockScalingProcessor] = []

    func keep(_ processor: BlockScalingProcessor) -> BlockScalingProcessor {
        processors.append(processor)
        return processor
    }

    static func == (lhs: Made, rhs: Made) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A processor that does nothing: what the way to a processor costs by itself.
private final class IdleProcessor: SampleProcessor {
    let latencyFrames = 0
    let settlingFrames = 0

    func process(_ block: inout AudioBlock) {}
    func reset() {}
}

private struct ProcessorStage: SequenceStage {
    enum Kind: Hashable, Sendable {
        case idle, scaling, blockToBlock
    }

    let kind: Kind
    var made: Made?

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let kind = kind, made = made
        context.emit(.processor(CustomProcessor(name: "ProcessorStage", key: kind) { _ throws(DSPError) -> any SampleProcessor in
            switch kind {
            case .idle: IdleProcessor()
            case .scaling: ScalingProcessor(0.5)
            case .blockToBlock: made?.keep(BlockScalingProcessor(0.5)) ?? BlockScalingProcessor(0.5)
            }
        }))
    }
}

/// EXT-4 (CR-025 items 1 and 3): a stage written as a `SampleProcessor` runs within 5 % of
/// its stock twin's speed. The twin here is the stock gain; the processor makes the same one
/// multiplication per sample. The timings are recorded in every run and held against the
/// bound in a benchmark run: an optimised build, this suite alone, `ZTD_BENCHMARK_OUTPUT` set.
@Suite("What a processor costs (EXT-4)", .serialized)
struct ProcessorCostTests {
    let format = SignalFormat(sampleRate: 48_000)
    let frames = 512

    private var holdsBudgets: Bool {
        #if DEBUG
        false
        #else
        Benchmark.isRecording
        #endif
    }

    /// The plan of `pipeline`, with nothing behind its main line, and a call that runs one block.
    private func plan(_ pipeline: Pipeline<Samples, Samples>) throws -> OfflineRunner {
        let runner = try OfflineRunner(stages: pipeline.stages, format: format, blockSize: frames, crossovers: .shipped)
        runner.plan.output = nil
        return runner
    }

    /// Times the workloads in alternation and keeps the best sample of each: a machine that
    /// is busy for a moment slows all of them, not one.
    private func alternating(_ workloads: [(name: String, body: () -> Void)], rounds: Int = 8, iterations: Int = 4_000) -> [BenchmarkResult] {
        var best = workloads.map { Benchmark.measure($0.name, samples: 11, iterations: iterations, $0.body) }
        for _ in 1 ..< rounds {
            for (index, workload) in workloads.enumerated() {
                let again = Benchmark.measure(workload.name, warmUp: 1, samples: 11, iterations: iterations, workload.body)
                if again.minimum < best[index].minimum { best[index] = again }
            }
        }
        return best
    }

    @Test func aProcessorOfOneMultiplicationAgainstTheStockGain() throws {
        let block = try AudioBuffer(channels: [TestSignal.whiteNoise(count: frames, seed: 45)])
        let frame = FrameView(samples: block.block(), index: 0, time: 0)
        let stock = try plan(Pipeline { TestGain(0.5) })
        let idle = try plan(Pipeline { ProcessorStage(kind: .idle) })
        let scaling = try plan(Pipeline { ProcessorStage(kind: .scaling) })
        let blockToBlock = try plan(Pipeline { ProcessorStage(kind: .blockToBlock) })
        // The stock gain ramps to its factor first; the timing is of the gain that has arrived.
        for _ in 0 ..< 64 { stock.plan.process(frame) }

        let results = alternating([
            ("stock gain, 512 frames", { stock.plan.process(frame) }),
            ("a processor that does nothing, 512 frames", { idle.plan.process(frame) }),
            ("a processor of one multiplication, in place, 512 frames", { scaling.plan.process(frame) }),
            ("a processor of one multiplication, block to block, 512 frames", { blockToBlock.plan.process(frame) }),
        ])
        Benchmark.record(results)
        for result in results { print("[measured] \(result.name): least \(result.minimum) ns, median \(result.median) ns") }
        let inPlace = results[2].minimum / results[0].minimum, outOfPlace = results[3].minimum / results[0].minimum
        print("[measured] in place against the stock gain: \(inPlace)")
        print("[measured] block to block against the stock gain: \(outOfPlace)")
        #expect(results.allSatisfy { $0.minimum > 0 })
        // EXT-4: within 5 % of the stock twin. Held in a benchmark run only: an optimised build,
        // this suite alone, which is the only run whose timings mean anything.
        if holdsBudgets {
            #expect(outOfPlace <= 1.05, "a processor that writes another block takes \(outOfPlace) times the stock gain's time")
        }
    }

    /// The plan hands a processor that reads one block and writes another its two blocks, and
    /// never calls its in-place entry; what comes out is what the in-place processor makes,
    /// bit for bit; and the path allocates nothing (RT-2).
    @Test func aProcessorThatWritesAnotherBlockIsHandedThePlansBlocks() throws {
        let noise = TestSignal.whiteNoise(count: 4_000, seed: 46)
        let made = Made()
        let outOfPlace = try Pipeline { ProcessorStage(kind: .blockToBlock, made: made) }.process(noise, format: format, blockSize: 64)
        let inPlace = try Pipeline { ProcessorStage(kind: .scaling) }.process(noise, format: format, blockSize: 64)
        #expect(outOfPlace.map(\.bitPattern) == inPlace.map(\.bitPattern) && outOfPlace == noise.map { (sample: Float) -> Float in sample * 0.5 })
        let processor = try #require(made.processors.first)
        #expect(made.processors.count == 1 && processor.blockToBlockCalls == 63 && processor.inPlaceCalls == 0,
                "\(processor.blockToBlockCalls) blocks written, \(processor.inPlaceCalls) processed in place")

        try expectNoAllocationsRunning(Pipeline { ProcessorStage(kind: .blockToBlock) }, blocks: 500, "a processor that writes another block")
        try expectNoAllocationsRunning(Pipeline { ProcessorStage(kind: .scaling); ProcessorStage(kind: .blockToBlock) },
                                       format: SignalFormat(sampleRate: 48_000, channelCount: 2), blocks: 500, "in place, then block to block, two channels")
    }
}
