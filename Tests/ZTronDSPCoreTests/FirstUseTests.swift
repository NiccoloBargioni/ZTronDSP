import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// RT-2 at the first block. In an optimised build the Swift runtime instantiates the metadata
/// of a generic type at the first use of it in a process, and that allocates: on the analysis
/// thread, when the first use is in a block. The package's own code is to reach such types
/// first where a source is made or prepared and where a plan is compiled.
///
/// Every test here opens its audit before the first block. It says something only when it is
/// the first in its process to run the path, in an optimised build: run one test by itself,
/// `ZTD_CONFIG=Release Scripts/xc.sh test-only "ZTronDSPCoreTests/FirstUseTests/<name>()"`.
/// Beside other tests it passes because another test got there first.
@Suite("First use on the analysis thread (RT-2)")
struct FirstUseTests {
    private let noise = TestSignal.whiteNoise(count: 64 * 40, seed: 77)

    /// Prepares `source`, adapts it, and audits its first blocks.
    private func auditFirstBlocks(of source: any PullSampleSource, _ name: String) async throws {
        try await source.prepare()
        let adapter = try SourceAdapter.make(for: source, blockSize: 64)
        let buffer = try AudioBuffer(channelCount: source.format.channelCount, capacity: 64)
        expectNoAllocations(name) {
            var count = 0
            while count < 8 {
                _ = adapter.next(into: buffer)
                count += 1
            }
        }
    }

    @Test func theFirstBlocksOfAScriptedSource() async throws {
        try await auditFirstBlocks(of: ScriptedSource(noise, sampleRate: 48_000, batchSizes: [17, 64, 5]), "a scripted source")
    }

    @Test func theFirstBlocksOfABufferSource() async throws {
        try await auditFirstBlocks(of: BufferSource(noise, sampleRate: 48_000), "a buffer source")
    }

    @Test func theFirstBlocksOfASine() async throws {
        try await auditFirstBlocks(of: GeneratorSource(.sine(frequency: .hertz(440))), "a sine")
    }

    @Test func theFirstBlocksOfPinkNoise() async throws {
        try await auditFirstBlocks(of: GeneratorSource(.pinkNoise(seed: 1), channelCount: 2), "pink noise, two channels")
    }

    @Test func theFirstBlocksOfAChirp() async throws {
        try await auditFirstBlocks(of: GeneratorSource(.chirp(from: .hertz(100), to: .hertz(2_000), duration: 1)), "a chirp")
    }

    @Test func theFirstBlocksOfAnImpulseTrain() async throws {
        try await auditFirstBlocks(of: GeneratorSource(.impulseTrain(period: 7)), "an impulse train")
    }

    /// A push source: what is written into its ring is read in blocks by the adapter.
    @Test func theFirstBlocksOutOfARing() async throws {
        let source = ManualPushSource(format: SignalFormat(sampleRate: 48_000))
        try await source.prepare()
        let adapter = try SourceAdapter.make(for: source, blockSize: 64)
        let buffer = try AudioBuffer(channelCount: 1, capacity: 64)
        let block = try AudioBuffer(channels: [Array(noise[..<64])])
        expectNoAllocations("a ring") {
            var count = 0
            while count < 8 {
                source.write(block.block())
                _ = adapter.next(into: buffer)
                count += 1
            }
        }
    }

    /// A session with a run of kernels, a tap that ends in a stock feed, a node and a sink on
    /// the main line, on an engine driven by hand: the first turns of its hub.
    @Test func theFirstBlocksOfAPlanWithAKernelRunANodeATapAndASink() async throws {
        let rig = Rig()
        let feed = WaveformFeed(history: 64, minimumHistory: 8)
        let heard = CountingSink<Samples>()
        let pipeline = Pipeline {
            TestGain(0.5)
            TestBiquad(count: 2)
            Tap { TestEnvelope(bucket: 16); Emit(to: feed) }
            TestLate(latency: 0, chunk: 64)
        }.emit(to: heard)
        let session = try await rig.engine.attach(pipeline, to: rig.source)
        try session.start()
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [Array(noise[..<64])])
        expectNoAllocations("a plan's first blocks") {
            var count = 0
            while count < 8 {
                rig.source.write(block.block())
                _ = runner.turn(now: 0)
                count += 1
            }
        }
        #expect(heard.frames > 0, "the blocks did run: \(heard.frames) frames reached the sink")
        session.detach()
    }
}
