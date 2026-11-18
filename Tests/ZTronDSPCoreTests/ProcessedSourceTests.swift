import Foundation
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// `source.processed(by:)` (WP-337, SRC-2): the main-line output of one pipeline as the source
/// of another.
@Suite("Processed sources")
struct ProcessedSourceTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 50 + 17, seed: 41)

    @Test func aSecondPipelineSeesTheFirstOnesOutput() async throws {
        let engine = DSPEngine(blockSize: 64)
        let cleaning = Pipeline { TestGain(0.5); TestDelay(4) }
        let cleaned = BufferSource(noise, sampleRate: 48_000).processed(by: cleaning)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline { TestGain(3) }.emit(to: sink), to: cleaned)
        #expect(cleaned.format == format && session.environment.sourceKind == .derived)
        #expect(session.environment.latency == 4.0 / 48_000, "the latency of what precedes the processed source is part of its environment (REAL-5)")
        try session.start()
        #expect(await session.reaches(.finished))
        let expected = try Pipeline { TestGain(0.5); TestDelay(4); TestGain(3) }.process(noise, format: format, blockSize: 64)
        #expect(sink.samples == expected, "the hand-over adds nothing: the two pipelines in a row are the one pipeline")
        #expect(sink.times.first == -4.0 / 48_000 && sink.times.count == 51, "block for block, in the same turn: no ring between them")
        session.detach()
    }

    @Test func severalPipelinesShareOneProcessedSource() async throws {
        let rig = Rig()
        let probe = TestProbe()
        struct Counted: SequenceStage {
            let probe: TestProbe
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                let probe = probe
                context.emit(.processor(CustomProcessor(name: "Counted", key: self, latencyFrames: 0) { _ throws(DSPError) -> any SampleProcessor in
                    final class Counter: SampleProcessor {
                        let probe: TestProbe
                        init(_ probe: TestProbe) { self.probe = probe }
                        var latencyFrames: Int { 0 }
                        var settlingFrames: Int { 0 }
                        func process(_ block: inout AudioBlock) { probe.framesFramed += 1 }
                        func reset() {}
                    }
                    return Counter(probe)
                }))
            }
        }
        let shared = rig.source.processed(by: Pipeline { Counted(probe: probe); TestGain(2) })
        let a = CollectingSink<Samples>(), b = CollectingSink<Samples>()
        let first = try await rig.engine.attach(Pipeline().emit(to: a), to: shared)
        let second = try await rig.engine.attach(Pipeline().testGain(-1).emit(to: b), to: shared)
        #expect(rig.source.prepares == 1)
        try first.start()
        rig.feed(Array(noise[..<640]))
        try second.start()
        rig.feed(Array(noise[640 ..< 1_280]))
        #expect(a.samples == noise[..<1_280].map { $0 * 2 } && b.samples == noise[640 ..< 1_280].map { $0 * -2 })
        #expect(probe.framesFramed == 20, "the pipeline in front runs once per block, however many are attached behind it")
        #expect(rig.source.starts == 1)
        first.stop()
        #expect(rig.source.stops == 0, "the upstream source runs for as long as one attachment does")
        rig.feed(Array(noise[1_280 ..< 1_344]))
        #expect(a.samples.count == 1_280 && b.samples.count == 704)
        second.stop()
        #expect(rig.source.stops == 1)
        first.detach()
        second.detach()
        #expect(await eventually { rig.source.stops == 1 })
        let again = try await DSPEngine(blockSize: 64).attach(Pipeline(), to: rig.source)
        #expect(again.state == .idle, "with its last attachment gone, the upstream source is free for another engine")
    }

    @Test func aRateChangeInFrontIsTheFormatBehind() async throws {
        let engine = DSPEngine(blockSize: 96)
        let halved = BufferSource(noise, sampleRate: 48_000).processed(by: Pipeline { TestSubsample(by: 3) })
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: halved)
        #expect(session.environment.sampleRate == 16_000 && session.environment.blockSize == 33 && halved.format.sampleRate == 16_000,
                "a block of 96 leaves a third of itself, or one frame more")
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples == subsampled(noise, by: 3) && sink.environment?.sampleRate == 16_000)
        #expect(sink.times.count > 1 && sink.times[1] == Double(sink.indices[1]) / 16_000, "time runs at the rate of the processed signal")
    }

    @Test func whatHappensUpstreamHappensToTheSessionsBehind() async throws {
        let rig = Rig()
        let processed = rig.source.processed(by: Pipeline { TestGain(2) })
        let sink = CollectingSink<Samples>()
        let session = try await rig.engine.attach(Pipeline().emit(to: sink), to: processed)
        let log = EventLog(session)
        try session.start()
        rig.feed(Array(noise[..<128]))
        rig.source.send(.interrupted)
        #expect(await session.reaches(.interrupted))
        rig.source.send(.resumed)
        #expect(await session.reaches(.running))
        rig.source.changeFormat(to: SignalFormat(sampleRate: 44_100, channelCount: 2))
        #expect(await eventually { session.environment.sampleRate == 44_100 && session.environment.channelCount == 2 })
        #expect(processed.format.sampleRate == 44_100 && session.state == .running)
        rig.feed(Array(noise[..<64]))
        #expect(sink.samples.suffix(64) == noise[..<64].map { $0 * 2 })
        await rig.drain()
        #expect(log.contains(.replanned(.formatChanged)))
        rig.source.send(.ended)
        #expect(await eventually {
            rig.engine.core.runTurn()
            return session.state == .finished
        })
        try session.start()
        #expect(await session.reaches(.running), "a finished session behind a processed source starts again with the source in front")
        rig.source.send(.failed(.sourceUnavailable(reason: "gone")))
        #expect(await session.reaches(.failed(.sourceUnavailable(reason: "gone"))))
        session.detach()
    }

    // MARK: Frames dropped upstream (RT-8)

    /// RT-8: a source that overruns its ring "counts them, and reports `.overrun`". §4.4,
    /// `ProcessedSource.events`: "The events of the processed signal: those of the upstream
    /// source". A session behind a processed source has lost the frames its upstream source
    /// dropped, and so has whoever listens to the processed source.
    ///
    /// The defect: the engine told the sessions of the hub that dropped the frames, which
    /// behind a processed source is the session of the pipeline in front, an object the app
    /// does not hold. Neither the processed source's `events` nor the session attached to it
    /// heard of the overrun.
    @Test func framesDroppedUpstreamAreReportedBehindAProcessedSource() async throws {
        let rig = Rig()
        let processed = rig.source.processed(by: Pipeline { TestGain(2) })
        let sourceEvents = CoverageSourceEventLog(processed.events)
        let session = try await rig.engine.attach(Pipeline { TestGain(3) }, to: processed)
        let behind = EventLog(session)
        try session.start()
        let front = try rig.engine.core.control.sync { session.core.hub.inner }
        let inner = try #require(front, "the session of the pipeline in front")
        let inFront = CoverageSessionEventLog(inner.events)
        rig.feed([Float](repeating: 1, count: 64))

        rig.source.send(.overrun(droppedFrames: 7))
        #expect(await eventually(timeout: 30) { inFront.contains(.overrun(droppedFrames: 7)) }, "the engine tells the session in front")
        await rig.drain()
        #expect(await eventually(timeout: 1) { behind.contains(.overrun(droppedFrames: 7)) }, "the session attached to the processed source is told")
        #expect(await eventually(timeout: 1) { sourceEvents.contains(.overrun(droppedFrames: 7)) }, "and so is the processed source's own stream of events")
        session.detach()
    }

    /// The loss is counted in the frames of the signal that lost it. Behind a pipeline that
    /// halves the rate, seven frames dropped upstream are four frames of the processed signal
    /// (as many as they would have become, and never none); behind a further pipeline that
    /// triples the rate again, twelve. Every processed source on the way says so itself, and a
    /// loss the ring itself counts (RT-8) is reported the same way as one the source announces.
    @Test func framesDroppedUpstreamAreCountedInTheFramesOfEachProcessedSignal() async throws {
        let rig = Rig()
        let halved = rig.source.processed(by: Pipeline { TestSubsample(by: 2) })
        let tripled = halved.processed(by: Pipeline { TestZeroStuff(factor: 3) })
        let halvedEvents = CoverageSourceEventLog(halved.events), tripledEvents = CoverageSourceEventLog(tripled.events)
        let near = try await rig.engine.attach(Pipeline(), to: halved)
        let far = try await rig.engine.attach(Pipeline { TestGain(2) }, to: tripled)
        let nearLog = EventLog(near), farLog = EventLog(far)
        #expect(near.environment.sampleRate == 24_000 && far.environment.sampleRate == 72_000)
        try near.start()
        try far.start()
        rig.feed([Float](repeating: 1, count: 64))

        rig.source.send(.overrun(droppedFrames: 7))
        #expect(await eventually(timeout: 30) { farLog.contains(.overrun(droppedFrames: 12)) }, "twelve frames at 72 kHz: \(farLog.all)")
        #expect(await eventually(timeout: 30) { nearLog.contains(.overrun(droppedFrames: 4)) }, "four frames at 24 kHz: \(nearLog.all)")
        #expect(await eventually(timeout: 30) { halvedEvents.contains(.overrun(droppedFrames: 4)) && tripledEvents.contains(.overrun(droppedFrames: 12)) })
        #expect(!nearLog.contains(.overrun(droppedFrames: 7)) && !farLog.contains(.overrun(droppedFrames: 7)), "nobody behind is told a count of frames that are not its own")

        // A ring that overflows: the frames that did not fit are counted by the ring, and found by the engine.
        let flood = [Float](repeating: 0.5, count: 64 * 2_048)
        let dropped = flood.count - rig.source.write(flood)
        #expect(dropped > 0, "more than the ring holds")
        rig.engine.core.runTurn()
        rig.engine.core.flush()
        let lost = (dropped + 1) / 2
        #expect(await eventually(timeout: 30) { nearLog.contains(.overrun(droppedFrames: lost)) && farLog.contains(.overrun(droppedFrames: lost * 3)) },
                "\(dropped) frames dropped by the ring: \(lost) at half the rate, \(lost * 3) at three times that")
        #expect(await eventually(timeout: 30) { halvedEvents.contains(.overrun(droppedFrames: lost)) && tripledEvents.contains(.overrun(droppedFrames: lost * 3)) })
        near.detach()
        far.detach()
    }

    // MARK: Samples that are not finite (NUM-1)

    /// NUM-1: "A non-finite sample arriving from a source is replaced by 0 at the source
    /// adapter and counted in `SessionEvent.nonFiniteInput`." A session behind a processed
    /// source got the zeros that took their place, with the processed signal, and is told as
    /// the session in front is: with the count of the samples that were replaced where the
    /// signal entered, which is what the event counts, whatever the pipelines in front made of
    /// them, and so down a chain of processed sources.
    ///
    /// The defect: only the sessions of the hub that replaced the samples were told, which
    /// behind a processed source is the session of the pipeline in front, an object the app
    /// does not hold.
    @Test func samplesReplacedUpstreamAreReportedBehindAProcessedSource() async throws {
        let rig = Rig()
        let halved = rig.source.processed(by: Pipeline { TestSubsample(by: 2) })
        let doubled = halved.processed(by: Pipeline { TestGain(2) })
        let heard = CollectingSink<Samples>()
        let near = try await rig.engine.attach(Pipeline(), to: halved)
        let far = try await rig.engine.attach(Pipeline { TestGain(3) }.emit(to: heard), to: doubled)
        let nearLog = EventLog(near), farLog = EventLog(far)
        try near.start()
        try far.start()
        let front = try rig.engine.core.control.sync { near.core.hub.inner }
        let inner = try #require(front, "the session of the pipeline in front")
        let inFront = CoverageSessionEventLog(inner.events)

        // Three samples that are no numbers: one of them at a place the pipeline in front keeps.
        var block = [Float](repeating: 1, count: 64)
        block[3] = .nan
        block[10] = .infinity
        block[11] = -.infinity
        rig.feed(block)
        #expect(await eventually(timeout: 30) { inFront.contains(.nonFiniteInput(count: 3)) }, "the session in front is told, as before")
        #expect(await eventually(timeout: 30) { nearLog.contains(.nonFiniteInput(count: 3)) }, "the session behind the processed source is told: \(nearLog.all)")
        #expect(await eventually(timeout: 30) { farLog.contains(.nonFiniteInput(count: 3)) }, "and the one behind the next: \(farLog.all)")
        // What they got: every second sample, six times as large, and a zero where the infinity was.
        var expected = [Float](repeating: 6, count: 32)
        expected[5] = 0
        #expect(heard.samples == expected)

        // A block of numbers: nothing more is said.
        rig.feed([Float](repeating: 1, count: 64))
        await rig.drain()
        let counts = [nearLog, farLog].map { (log: EventLog) -> Int in
            log.all.filter { if case .nonFiniteInput = $0 { true } else { false } }.count
        }
        #expect(counts == [1, 1], "told once, for the block that held them: \(counts)")
        near.detach()
        far.detach()
    }

    @Test func aProcessedSourceOfAProcessedSource() async throws {
        let engine = DSPEngine(blockSize: 64)
        let twice = BufferSource(noise, sampleRate: 48_000).processed(by: Pipeline { TestGain(2) }).processed(by: Pipeline { TestDelay(1) })
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: twice)
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples == [0] + noise.dropLast().map { $0 * -2 })
    }

    @Test func aPipelineThatDoesNotEndInSamplesOrDoesNotCompileIsRefused() async throws {
        let engine = DSPEngine(blockSize: 64)
        let broken = BufferSource(noise, sampleRate: 48_000).processed(by: Pipeline { TestGain(.nan) })
        await #expect(throws: DSPError.self) { _ = try await engine.attach(Pipeline(), to: broken) }
        let source = BufferSource(noise, sampleRate: 48_000)
        let direct = try await engine.attach(Pipeline(), to: source)
        #expect(direct.state == .idle, "a refused attachment leaves its source usable")
        let prepared = source.processed(by: Pipeline { TestSubsample(by: 2) })
        try await prepared.prepare()
        #expect(prepared.format.sampleRate == 24_000, "prepared by hand, a processed source knows its format")
    }
}
