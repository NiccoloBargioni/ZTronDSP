import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

@Suite("Engine and sessions")
struct EngineTests {
    let format = SignalFormat(sampleRate: 48_000)
    let signal = TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 6_000)

    // MARK: Offline ≡ engine (WP-323)

    @Test func engineOutputEqualsOfflineOutput() async throws {
        let engine = DSPEngine(blockSize: 256)
        let sink = CollectingSink<Samples>()
        let chain = Pipeline { TestGain(0.5); TestDelay(7); TestGain(1.5) }
        let session = try await engine.attach(chain.emit(to: sink), to: BufferSource(signal, sampleRate: 48_000))
        #expect(session.state == .idle)
        try session.start()
        #expect(await session.reaches(.finished))
        session.detach()
        #expect(session.state == .detached)
        let offline = try chain.process(signal, format: format, blockSize: 256)
        #expect(sink.samples == offline, "the engine runs the plan the offline call runs, on the same blocks")
        #expect(sink.claims == 1 && sink.releases == 1)
    }

    @Test func mainLineOutputReachesAProbe() async throws {
        let engine = DSPEngine(blockSize: 128)
        let session = try await engine.attach(Pipeline { TestGain(2) }, to: BufferSource(signal, sampleRate: 48_000))
        let probe = OutputProbe()
        engine.core.addProbe(probe, to: session.core)
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(probe.samples == signal.map { $0 * 2 })
        #expect(probe.blocks == (signal.count + 127) / 128, "the last block is the short one, not a padded one")
    }

    // MARK: Independent state per attachment (ATT-1), several attachments on one source (ATT-6)

    @Test func onePipelineOnThreeSourcesKeepsThreeStates() async throws {
        let engine = DSPEngine(blockSize: 64)
        func analysis(into sink: CollectingSink<Samples>) -> Pipeline<Samples, Samples> {
            Pipeline { TestDelay(5) }.emit(to: sink)
        }
        let inputs: [[Float]] = [signal, signal.map { -$0 }, [Float](repeating: 0.25, count: 3_000)]
        var sinks: [CollectingSink<Samples>] = []
        var sessions: [PipelineSession] = []
        for input in inputs {
            let sink = CollectingSink<Samples>()
            sinks.append(sink)
            sessions.append(try await engine.attach(analysis(into: sink), to: BufferSource(input, sampleRate: 48_000)))
        }
        for session in sessions { try session.start() }
        for session in sessions { #expect(await session.reaches(.finished)) }
        for (input, sink) in zip(inputs, sinks) {
            let expected = try Pipeline { TestDelay(5) }.process(input, format: format, blockSize: 64)
            #expect(sink.samples == expected, "each attachment has its own delay line")
        }
    }

    @Test func twoPipelinesOnOneSourceSeeTheSameBlocks() async throws {
        let engine = DSPEngine(blockSize: 100)
        let source = ScriptedSource(signal, sampleRate: 48_000, batchSizes: [7, 300, 1, 64])
        let first = CollectingSink<Samples>(), second = CollectingSink<Samples>()
        let a = try await engine.attach(Pipeline().emit(to: first), to: source)
        let b = try await engine.attach(Pipeline().testGain(3).emit(to: second), to: source)
        try a.start()
        try b.start()
        #expect(await a.reaches(.finished))
        #expect(await b.reaches(.finished))
        // Both started before the first block or after it; whatever each saw, it saw whole blocks
        // of the one stream, and the one that started first saw all of it.
        #expect(first.samples == signal)
        #expect(second.samples == Array(signal.suffix(second.samples.count)).map { $0 * 3 })
        #expect(second.samples.count % 100 == signal.count % 100, "the second attachment joined at a block boundary")
    }

    @Test func aSourceStartsOnceAndStopsWithTheLastAttachment() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let a = try await engine.attach(Pipeline(), to: source)
        let b = try await engine.attach(Pipeline().testGain(2), to: source)
        #expect(source.prepares == 1, "prepared once for the engine")
        #expect(source.connects == 1)
        try a.start()
        try b.start()
        try a.start()
        #expect(source.starts == 1, "started with the first attachment that starts")
        a.stop()
        #expect(source.stops == 0)
        b.stop()
        #expect(source.stops == 1, "stopped with the last attachment that stops")
        try b.start()
        #expect(source.starts == 2)
        a.detach()
        b.detach()
        #expect(source.stops == 2)
    }

    @Test func pushAndPullSourcesDeliverIdenticalBlocks() async throws {
        let engine = DSPEngine(blockSize: 128)
        let pulled = CollectingSink<Samples>(), pushed = CollectingSink<Samples>()
        let pull = try await engine.attach(Pipeline().emit(to: pulled), to: BufferSource(signal, sampleRate: 48_000))
        let source = ManualPushSource(format: format)
        let push = try await engine.attach(Pipeline().emit(to: pushed), to: source)
        try pull.start()
        try push.start()
        var position = 0
        for size in [1, 500, 37, 128, 4_000, 2_000] where position < signal.count {
            let end = min(position + size, signal.count)
            #expect(source.write(Array(signal[position ..< end])) == end - position)
            position = end
        }
        source.send(.ended)
        #expect(await pull.reaches(.finished))
        #expect(await push.reaches(.finished))
        #expect(pushed.samples == signal && pulled.samples == signal)
        #expect(pushed.times == pulled.times, "the same blocks at the same times, whatever the batches were")
    }

    // MARK: Sink claims (ATT-5)

    @Test func aSinkHasOneLiveWriter() async throws {
        let engine = DSPEngine(blockSize: 64)
        let sink = CollectingSink<Samples>()
        let pipeline = Pipeline().emit(to: sink)
        let first = try await engine.attach(pipeline, to: BufferSource(signal, sampleRate: 48_000))
        await #expect(throws: DSPError.sinkInUse(sink: String(describing: CollectingSink<Samples>.self))) {
            _ = try await engine.attach(pipeline, to: BufferSource(signal, sampleRate: 48_000))
        }
        await #expect(throws: DSPError.self) {
            _ = try await engine.attach(Pipeline().emit(to: CollectingSink<Samples>()).tap { $0.emit(to: sink) }, to: BufferSource(signal, sampleRate: 48_000))
        }
        first.detach()
        let second = try await engine.attach(pipeline, to: BufferSource(signal, sampleRate: 48_000))
        #expect(second.state == .idle, "the sink is free once its writer is detached")
        let twice = CollectingSink<Samples>()
        await #expect(throws: DSPError.self) {
            _ = try await engine.attach(Pipeline().emit(to: twice).emit(to: twice), to: BufferSource(signal, sampleRate: 48_000))
        }
        second.detach()
    }

    // MARK: Environment and latency (ATT-3, WP-322)

    @Test func theEnvironmentIsResolvedFromTheSource() async throws {
        let engine = DSPEngine(blockSize: 200)
        let source = BufferSource(channels: [signal, signal], sampleRate: 44_100, pacing: .asFastAsPossible)
        let session = try await engine.attach(Pipeline { TestDelay(441) }, to: source)
        let environment = session.environment
        #expect(environment.sampleRate == 44_100 && environment.channelCount == 2 && environment.blockSize == 200)
        #expect(environment.isRealTime == false && environment.sourceKind == .pull)
        #expect(abs(environment.latency - 0.01) < 1e-12, "441 frames at 44.1 kHz")
        session.detach()
    }

    @Test func reportedLatencyEqualsTheMeasuredImpulseDelay() async throws {
        let engine = DSPEngine(blockSize: 64)
        var impulse = [Float](repeating: 0, count: 1_000)
        impulse[0] = 1
        let session = try await engine.attach(Pipeline { TestDelay(37); TestGain(-1); TestDelay(100) },
                                              to: BufferSource(impulse, sampleRate: 48_000))
        let probe = OutputProbe()
        engine.core.addProbe(probe, to: session.core)
        try session.start()
        #expect(await session.reaches(.finished))
        let measured = try #require(probe.samples.firstIndex { abs($0) > 0.5 })
        #expect(Double(measured) / 48_000 == session.environment.latency)
        #expect(measured == 137)
    }
}
