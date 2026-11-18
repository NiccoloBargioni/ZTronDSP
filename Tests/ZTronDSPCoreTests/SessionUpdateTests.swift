import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// §5.5.4: what `update(_:)` does for an equal pipeline, for other values, and for another
/// topology (WP-312, WP-313, WP-314a, WP-314b). The engine is driven by hand, so every change
/// lands at a block boundary the test chooses.
@Suite("Changing a running pipeline")
struct SessionUpdateTests {
    let noise = TestSignal.whiteNoise(count: 64 * 60, seed: 11)

    private func probed(_ rig: Rig, _ pipeline: Pipeline<Samples, Samples>) async throws -> (PipelineSession, OutputProbe) {
        let session = try await rig.engine.attach(pipeline, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        return (session, probe)
    }

    // MARK: Equal

    @Test func anEqualPipelineCostsNoPlanWork() async throws {
        let rig = Rig()
        let first = StateBox(true), second = StateBox(true)
        func pipeline(_ binding: Binding<Bool>) -> Pipeline<Samples, Samples> {
            Pipeline { TestGain(0.5, isActive: binding); EnvironmentReader { environment in TestGain(Float(environment.blockSize)) } }
        }
        let (session, probe) = try await probed(rig, pipeline(first.binding))
        let log = EventLog(session)
        let plan = session.core.plan
        try await session.update(pipeline(second.binding))
        #expect(session.core.plan === plan && session.core.generation == 1, "one description comparison; nothing is compiled")

        // The bindings of the pipeline given last are the ones the session reads (BIND-6).
        rig.feed([Float](repeating: 1, count: 64))
        #expect(probe.samples.last == 32)
        first.value = false
        await MainActor.run { session.syncBindings() }
        rig.feed([Float](repeating: 1, count: 64 * 12))
        #expect(probe.samples.last == 32, "a binding that was let go is not read any more")
        second.value = false
        await MainActor.run { session.syncBindings() }
        rig.feed([Float](repeating: 1, count: 64 * 12))
        #expect(probe.samples.last == 64, "the gain is bypassed")
        #expect(first.writes == 0 && second.writes == 0, "the session never writes a switch (BIND-5)")
        await rig.drain()
        #expect(!log.contains(.replanned(.update)))
    }

    // MARK: Values

    @Test func valuesTravelToTheKernelsThatRun() async throws {
        let rig = Rig()
        let (session, probe) = try await probed(rig, Pipeline { TestDelay(3); TestGain(0.5) })
        let plan = session.core.plan
        rig.feed([Float](repeating: -1, count: 128))
        #expect(probe.samples.last == 0.5)
        try await session.update(Pipeline { TestDelay(3); TestGain(0.75) })
        #expect(session.core.plan === plan && session.core.generation == 1, "the same topology: the plan stays")
        rig.feed([Float](repeating: -1, count: 64 * 10))
        let ramp = Array(probe.samples[128...])
        #expect(ramp.last == 0.75, "the gain lands on its target exactly")
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 }, "and ramps there")
        let moving = ramp.filter { $0 > 0.5 && $0 < 0.75 }.count
        #expect(moving >= 470 && moving <= 480, "over 10 ms: \(moving) frames")
        #expect(Click.largestStep(ramp, in: 0 ..< ramp.count) <= 0.25 / 470)

        // A later change of topology still finds the kernels where they are (SWAP-1): the
        // delay line keeps what it holds, and the gain the value it was sent.
        let sink = CollectingSink<Samples>()
        try await session.update(Pipeline { TestDelay(3); TestGain(0.75) }.tap { $0.emit(to: sink) })
        #expect(session.core.generation == 2)
        rig.feed([0.25, 0.5, 1] + [Float](repeating: 0, count: 61))
        #expect(Array(sink.samples.prefix(6)) == [0.75, 0.75, 0.75, -0.1875, -0.375, -0.75],
                "three frames of the signal before the change come out first")
    }

    @Test func valuesOfAnIdleSessionAreAppliedAtOnce() async throws {
        let rig = Rig()
        let session = try await rig.engine.attach(Pipeline { TestGain(0.5) }, to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try await session.update(Pipeline { TestGain(0.25) })
        try session.start()
        rig.feed([Float](repeating: 1, count: 64 * 9))
        #expect(probe.samples.last == 0.25)
    }

    // MARK: Topology, part 1 (WP-314a)

    @Test func aTapAddedDownstreamLeavesTheRestUntouched() async throws {
        func run(changing: Bool) async throws -> (main: [Float], kept: [Float], added: [Float]) {
            let rig = Rig()
            let kept = CollectingSink<Samples>(), added = CollectingSink<Samples>()
            let before = Pipeline { TestDelay(5); TestSmoother(0.3, settling: 64) }.tap { $0.testGain(3).emit(to: kept) }
            let after = before.tap { $0.testGain(2).emit(to: added) }
            let (session, probe) = try await probed(rig, before)
            rig.feed(Array(noise[..<(64 * 20)]))
            if changing { try await session.update(after) }
            rig.feed(Array(noise[(64 * 20)...]))
            session.detach()
            return (probe.samples, kept.samples, added.samples)
        }
        let plain = try await run(changing: false), changed = try await run(changing: true)
        #expect(changed.main == plain.main, "the main line does not notice the exchange")
        #expect(changed.kept == plain.kept, "an unchanged branch does not notice it either: its feed continues")
        #expect(plain.added.isEmpty)
        #expect(changed.added == plain.main[(64 * 20)...].map { $0 * 2 }, "the new branch starts at the exchange, on the unchanged main line")
    }

    @Test func aBranchThatGoesTakesItsSinkAlong() async throws {
        let rig = Rig()
        let sink = CollectingSink<Samples>()
        let (session, _) = try await probed(rig, Pipeline().tap { $0.emit(to: sink) })
        rig.feed(Array(noise[..<128]))
        try await session.update(Pipeline())
        rig.feed(Array(noise[128 ..< 256]))
        await rig.drain()
        #expect(sink.samples == Array(noise[..<128]) && sink.releases == 1, "an update that drops a sink releases the claim (ATT-5)")
        let other = try await rig.engine.attach(Pipeline().emit(to: sink), to: BufferSource(noise, sampleRate: 48_000))
        #expect(other.state == .idle)
    }

    // MARK: Topology, part 2 (WP-314b)

    @Test func aStageReplacedOnTheMainLineIsPrerolledAndFadedInWithoutAClick() async throws {
        let rig = Rig()
        let sine = Click.probeSignal(count: 64 * 100)
        let (session, probe) = try await probed(rig, Pipeline { TestGain(1); TestSmoother(0.9, settling: 256) })
        let log = EventLog(session)
        rig.feed(Array(sine[..<(64 * 30)]))
        try await session.update(Pipeline { TestGain(1); TestSmoother(0.15, settling: 256) })
        #expect(session.core.generation == 2)
        rig.feed(Array(sine[(64 * 30) ..< (64 * 32)]))
        #expect(session.core.runner.isInTransition, "the new stage runs beside the old one for its settling time")
        rig.feed(Array(sine[(64 * 32)...]))
        #expect(!session.core.runner.isInTransition && session.core.runner.installedGeneration == 2)

        let old = try Pipeline { TestSmoother(0.9, settling: 0) }.process(sine, format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        let new = try Pipeline { TestSmoother(0.15, settling: 0) }.process(sine, format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        let change = 64 * 30, preroll = 256, fade = 480
        #expect(Array(probe.samples[..<(change + preroll)]) == Array(old[..<(change + preroll)]),
                "until the new stage has settled, the old one produces the output")
        expectClose(Array(probe.samples[(change + preroll + fade + 64)...]), Array(new[(change + preroll + fade + 64)...]), .absolute(1e-6),
                    "after the fade the output is the new stage's, as if it had always run")
        let click = Click.measure(probe.samples, change: change ..< (change + preroll + fade + 64))
        #expect(click.passes, "CLICK-1: \(click)")
        // The same change without pre-roll and fade would click: the test can fail.
        var abrupt = Array(old[..<change]) + Array(new[change...])
        abrupt[change] = new[change]
        #expect(!Click.measure(abrupt, change: change ..< (change + 64)).passes || abs(old[change] - new[change]) < 0.05)
        await rig.drain()
        #expect(log.contains(.replanned(.update)) && !log.contains(.outputChanged), "same domain, rate and latency: nothing to report")
    }

    @Test func aChangeOfOutputLatencyIsReported() async throws {
        let rig = Rig()
        let (session, probe) = try await probed(rig, Pipeline { TestDelay(5) })
        let log = EventLog(session)
        #expect(session.environment.latency == 5.0 / 48_000)
        rig.feed(Array(noise[..<640]))
        try await session.update(Pipeline { TestDelay(9) })
        rig.feed(Array(noise[640 ..< 1_280]))
        await rig.drain()
        #expect(log.contains(.outputChanged), "old and new output are not aligned: no cross-fade, and the session says so (SWAP-2)")
        #expect(session.environment.latency == 9.0 / 48_000)
        #expect(Array(probe.samples[..<704]) == [Float](repeating: 0, count: 5) + noise[..<699].map { -$0 },
                "the old plan produces the output while the new delay line is filled")
        #expect(Array(probe.samples[704...]) == noise[(704 - 9) ..< (1_280 - 9)].map { -$0 },
                "at the exchange the new line already holds what it needs: the signal jumps by the difference in delay, and nothing else")
    }

    @Test func anUpdateDuringPrerollSupersedesIt() async throws {
        let rig = Rig()
        let (session, probe) = try await probed(rig, Pipeline { TestSmoother(1, settling: 0) })
        let log = EventLog(session)
        rig.feed(Array(noise[..<640]))
        try await session.update(Pipeline { TestSmoother(0.5, settling: 48_000) })
        rig.feed(Array(noise[640 ..< 960]))
        #expect(session.core.runner.isInTransition && session.core.runner.installedGeneration == 1)
        try await session.update(Pipeline { TestGain(-1) })
        #expect(session.core.generation == 3)
        rig.feed(Array(noise[960...]))
        await rig.drain()
        #expect(session.core.runner.installedGeneration == 3 && !session.core.runner.isInTransition)
        #expect(log.all.filter { $0 == .replanned(.update) }.count == 1, "the plan that was still pre-rolled never ran (SWAP-4)")
        #expect(probe.samples.last == -noise[noise.count - 1])
        let first = try Pipeline { TestSmoother(1, settling: 0) }.process(noise, format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        #expect(Array(probe.samples[..<960]) == Array(first[..<960]), "the output was the first plan's until the last update took over")
    }

    @Test func anUpdateBeforeTheLastOneWasTakenReplacesIt() async throws {
        let rig = Rig()
        let (session, probe) = try await probed(rig, Pipeline { TestGain(1) })
        try await session.update(Pipeline { TestDelay(1) })
        try await session.update(Pipeline { TestDelay(2) })
        try await session.update(Pipeline { TestDelay(3) })
        rig.feed(Array(noise[..<128]))
        #expect(session.core.runner.installedGeneration == 4, "the latest update wins; the two before it never ran")
        #expect(Array(probe.samples[..<64]) == Array(noise[..<64]), "one block of pre-roll for the three frames of delay")
        #expect(Array(probe.samples[64...]) == noise[61 ..< 125].map { -$0 })
    }

    @Test func aPipelineThatDoesNotCompileLeavesTheRunningOne() async throws {
        let rig = Rig()
        let (session, probe) = try await probed(rig, Pipeline { TestGain(2) })
        await #expect(throws: DSPError.self) { try await session.update(Pipeline { TestGain(.infinity) }) }
        let taken = CollectingSink<Samples>()
        let holder = try await rig.engine.attach(Pipeline().emit(to: taken), to: BufferSource(noise, sampleRate: 48_000))
        await #expect(throws: DSPError.sinkInUse(sink: String(describing: CollectingSink<Samples>.self))) {
            try await session.update(Pipeline { TestGain(2) }.emit(to: taken))
        }
        rig.feed([Float](repeating: 1, count: 64))
        #expect(probe.samples.last == 2 && session.state == .running && session.core.runner.installedGeneration == 1)
        holder.detach()
    }

    @Test func anIdleSessionTakesANewTopologyAtOnce() async throws {
        let rig = Rig()
        let session = try await rig.engine.attach(Pipeline { TestSmoother(0.5, settling: 4_800) }, to: rig.source)
        let log = EventLog(session)
        try await session.update(Pipeline { TestDelay(4) })
        #expect(session.core.runner.installedGeneration == 2 && !session.core.runner.isInTransition, "nothing can be heard: no pre-roll")
        #expect(session.environment.latency == 4.0 / 48_000)
        await rig.drain()
        #expect(await eventually { log.contains(.replanned(.update)) })
    }

    // MARK: Format changes (ATT-4)

    @Test func aFormatChangeIsSurvived() async throws {
        let rig = Rig()
        let sink = CollectingSink<Samples>()
        let session = try await rig.engine.attach(
            Pipeline { EnvironmentReader { environment in TestGain(Float(environment.sampleRate / 48_000)) }; TestDelay(2) }.emit(to: sink),
            to: rig.source)
        let log = EventLog(session)
        try session.start()
        rig.feed([Float](repeating: 1, count: 128))
        #expect(sink.samples.last == -1)
        rig.source.changeFormat(to: SignalFormat(sampleRate: 96_000, channelCount: 2))
        #expect(await eventually { session.environment.sampleRate == 96_000 })
        #expect(session.state == .running, "the session stays running")
        #expect(session.environment.channelCount == 2 && rig.source.connects == 2, "the source is given a ring of the new format")
        rig.feed([Float](repeating: 1, count: 128))
        #expect(Array(sink.samples.suffix(128).prefix(3)) == [0, 0, -2], "the plan is compiled for the new environment, and stage state is reset")
        #expect(sink.claims == 2 && sink.environment?.sampleRate == 96_000, "the sink is told what it gets now")
        await rig.drain()
        #expect(log.contains(.replanned(.formatChanged)))
        #expect(sink.times.suffix(2) == [-2.0 / 96_000, 62.0 / 96_000], "the session's clock starts over with the new format")
    }

    @Test func aPullSourceChangesFormatInTheMiddleOfItsStream() async throws {
        let engine = DSPEngine(blockSize: 64)
        let ones = [Float](repeating: 1, count: 100), halves = [Float](repeating: 0.5, count: 100)
        let source = ScriptedSource(format: SignalFormat(sampleRate: 48_000), [
            .samples([ones]), .formatChange(SignalFormat(sampleRate: 44_100, channelCount: 2)), .samples([halves, halves]),
        ])
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
        let log = EventLog(session)
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples == ones + halves, "both streams arrive whole, the second in its own format")
        #expect(session.environment.sampleRate == 44_100 && session.environment.channelCount == 2)
        #expect(await eventually { log.contains(.replanned(.formatChanged)) })
    }

    @Test func aPipelineThatCannotRunAtTheNewFormatFails() async throws {
        struct OnlyAt48k: SequenceStage {
            func lower(_ context: inout LoweringContext) throws(DSPError) {
                guard context.environment.sampleRate == 48_000 else { throw context.invalid("sampleRate", "this stage runs at 48 kHz") }
                context.emit(.gain(factor: 1, ramp: 0))
            }
        }
        let rig = Rig()
        let fragile = try await rig.engine.attach(Pipeline { OnlyAt48k() }, to: rig.source)
        let sturdy = try await rig.engine.attach(Pipeline { TestGain(2) }, to: rig.source)
        try fragile.start()
        try sturdy.start()
        rig.source.changeFormat(to: SignalFormat(sampleRate: 44_100))
        #expect(await eventually { if case .failed = fragile.state { true } else { false } }, "the error of the re-plan is the session's state")
        #expect(await eventually { sturdy.environment.sampleRate == 44_100 })
        #expect(sturdy.state == .running, "the other attachment of the source goes on")
        if case .failed(let error) = fragile.state { #expect(error.stage?.stageName == "OnlyAt48k") }
    }
}
