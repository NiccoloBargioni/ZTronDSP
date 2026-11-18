import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// The `.pipeline(_:on:)` host (WP-816): attach on appear, update on change, detach on
/// disappear, no update for an equal pipeline. And its animation (WP-817, ANI-2 … ANI-5):
/// inside `withAnimation` the session receives one interpolated update per display frame,
/// and a change of topology is applied at once.
@MainActor
@Suite("Pipeline host")
struct PipelineHostTests {
    /// Gains in decibels, one stage each, and optionally a delay: the delay is structure.
    ///
    /// No gain here is 0 dB. A gain of 0 dB is an identity: a plan compiled while a gain
    /// stands there runs no kernel for it, so a value that then leaves 0 dB compiles a plan
    /// and the session reports a re-plan (nothing behind the gain is cleared or withheld:
    /// CR-024 item 4). These tests count the host's updates and the session's re-plans, so
    /// they keep away from that case; it is the core's business.
    static func chain(_ gains: [Double], delay: Int? = nil, into feed: HeatmapFeed? = nil) -> Pipeline<Samples, Samples> {
        var pipeline = Pipeline<Samples, Samples>()
        for gain in gains { pipeline = pipeline.appending(TestGain(decibels: gain)) }
        if let delay { pipeline = pipeline.appending(TestDelay(frames: delay)) }
        if let feed { pipeline = pipeline.tap { $0.appending(TestColumns(rows: 16, axis: .indices(count: 16))).emit(to: feed) } }
        return pipeline
    }

    // MARK: The animatable vector (ANI-2, ANI-4)

    @Test func theVectorOfAPipelineHoldsItsContinuousValuesInOrder() {
        let vector = AnimatableParameters(Self.chain([-3, -12, 6], delay: 8))
        #expect(vector.values == [-3, -12, 6] && !vector.isReplacement && vector.vector == ParameterVector([-3, -12, 6]))
        #expect(AnimatableParameters(Self.chain([])).values.isEmpty)
        // Pipelines that differ in their values only have the same structure.
        #expect(vector.structure == AnimatableParameters(Self.chain([0, 1, 2], delay: 8)).structure)
        #expect(vector.structure != AnimatableParameters(Self.chain([-3, -12, 6], delay: 9)).structure, "another delay is another structure")
        #expect(vector.structure != AnimatableParameters(Self.chain([-3, -12, 6])).structure)
    }

    @Test func vectorsOfOneTopologyAreInterpolated() {
        let from = AnimatableParameters(Self.chain([-30, 0, 6])), to = AnimatableParameters(Self.chain([-10, -20, 6]))
        var delta = to - from
        #expect(delta.values == [20, -20, 0] && !delta.isReplacement)
        delta.scale(by: 0.25)
        let frame = from + delta
        #expect(frame.values == [-25, -5, 6], "a quarter of the way")
        #expect(Self.chain([-10, -20, 6]).replacingParameters(frame.vector) == Self.chain([-25, -5, 6]), "the pipeline that frame runs")
        #expect(delta.magnitudeSquared == 50)
        var whole = to - from
        whole.scale(by: 1)
        #expect((from + whole).values == to.values)
    }

    /// ANI-4: a change of topology is not interpolated. `from + (to − from) · t` is `to`.
    @Test func vectorsOfDifferentTopologyAreReplacedAtOnce() {
        let from = AnimatableParameters(Self.chain([-30, 0]))
        // Another number of values.
        let longer = AnimatableParameters(Self.chain([-10, -20, 6]))
        // The same number of values in another structure: the lengths alone would not tell.
        let delayed = AnimatableParameters(Self.chain([-10, -20], delay: 8))
        for to in [longer, delayed] {
            for fraction in [0.0, 0.3, 1.0] {
                var delta = to - from
                #expect(delta.isReplacement)
                delta.scale(by: fraction)
                let frame = from + delta
                #expect(frame.values == to.values && !frame.isReplacement, "at \(fraction): the target, at once")
                #expect(frame.structure == to.structure)
            }
        }
        // A replacement stays one, whatever is done to it.
        let replacement = longer - from
        #expect((replacement - from).isReplacement && (replacement + from).values == longer.values && (from - replacement).isReplacement)
        #expect((replacement - from).values == longer.values)
    }

    @Test func theEmptyVectorIsTheZeroOfEveryLength() {
        let vector = AnimatableParameters(Self.chain([-30, 0]))
        #expect(vector + .zero == vector && .zero + vector == vector && vector - .zero == vector)
        #expect((.zero - vector).values == [30, 0])
        #expect(AnimatableParameters.zero.magnitudeSquared == 0 && AnimatableParameters.zero + .zero == .zero)
        // Quantities that arithmetic made carry no structure and combine by their length.
        let velocity = AnimatableParameters(values: [1, 1])
        #expect((vector + velocity).values == [-29, 1] && (vector + velocity).structure == vector.structure)
        #expect((vector - velocity).values == [-31, -1] && !(vector - velocity).isReplacement)
        #expect((velocity + vector).structure == vector.structure && (velocity - vector).values == [31, 1] && (velocity - vector).structure == vector.structure)
        #expect((vector + AnimatableParameters(values: [1, 2, 3])).values == [1, 2, 3], "another length: the right-hand side, as the core's vector has it")
        // A pipeline without continuous values has a structure all the same.
        let plain = AnimatableParameters(Self.chain([], delay: 4)), other = AnimatableParameters(Self.chain([], delay: 5))
        #expect((other - plain).isReplacement && (plain - plain).values.isEmpty && !(plain - plain).isReplacement)
    }

    @Test func theHostRunsThePipelineTheAnimationFrameAsksFor() {
        let source = HandFedSource()
        var host = PipelineHost(content: EmptyView(), pipeline: Self.chain([-10, -20], delay: 4), source: source)
        #expect(host.shownPipeline == Self.chain([-10, -20], delay: 4), "at rest: the pipeline it was given")
        #expect(host.animatableData == AnimatableParameters(Self.chain([-10, -20], delay: 4)))
        host.animatableData = AnimatableParameters(values: [-15, -10])
        #expect(host.shownPipeline == Self.chain([-15, -10], delay: 4), "the same stages with the frame's values")
        #expect(host.pipeline == Self.chain([-10, -20], delay: 4), "where the animation ends does not move")
        // Values of another length belong to another topology and leave the pipeline as it is.
        host.animatableData = AnimatableParameters(values: [1])
        #expect(host.shownPipeline == Self.chain([-10, -20], delay: 4))
    }

    // MARK: The model: one session for the life of a view (WP-816)

    /// A model with everything it counts into, and the source it attaches to.
    @MainActor
    final class Rig {
        let engine = DSPEngine(blockSize: 16)
        let source = HandFedSource()
        let feed = HeatmapFeed(history: 256)
        let host = PipelineHostProbe()
        let render = RenderProbe()
        let model = PipelineHostModel<Samples>()

        func pipeline(_ gains: [Double], delay: Int? = nil) -> Pipeline<Samples, Samples> {
            PipelineHostTests.chain(gains, delay: delay, into: feed)
        }

        func appear(_ gains: [Double]) {
            model.appear(pipeline(gains), on: source, engine: engine, renderProbe: render, hostProbe: host)
        }

        /// Waits until the session is attached and runs.
        func running() async {
            #expect(await eventually { self.host.session?.state == .running }, "attached and started")
        }

        /// The value the newest column of the feed holds, after `blocks` blocks of ones have
        /// gone through the pipeline: the gain that is applied, once it has settled. Waits
        /// first until every update that was sent has reached the session.
        func gainAfter(blocks: Int = 80) async -> Float {
            #expect(await eventually { self.host.isIdle }, "every update has landed")
            let before = feed.generation
            for _ in 0 ..< blocks { source.write([Float](repeating: 1, count: 16)) }
            #expect(await eventually { self.feed.generation >= before + UInt64(blocks) }, "every block became a column")
            let snapshot = feed.snapshot()
            return snapshot.columnCount > 0 ? snapshot.column(snapshot.columnCount - 1).first ?? .nan : .nan
        }
    }

    @Test func theSessionLivesAsLongAsTheView() async throws {
        let rig = Rig()
        rig.appear([-6])
        await rig.running()
        #expect(rig.host.attaches == 1 && rig.render.attaches == 1 && rig.host.detaches == 0 && rig.host.updates.isEmpty)
        expectClose(await rig.gainAfter(), 0.501_187, .absolute(1e-4), "the hosted pipeline runs: −6 dB")
        let session = try #require(rig.host.session)
        rig.model.disappear()
        #expect(rig.host.detaches == 1 && session.state == .detached, "detached when the view leaves")
        #expect(rig.host.session == nil)
        // Leaving twice, or asking for a pipeline after leaving, does nothing.
        rig.model.disappear()
        rig.model.want(rig.pipeline([-3]))
        await mainQueueDrained()
        #expect(rig.host.detaches == 1 && rig.host.attaches == 1 && rig.host.updates.isEmpty)
    }

    @Test func anEqualPipelineCausesNoUpdateAndAnotherOneCausesOne() async throws {
        let rig = Rig()
        rig.appear([-6])
        await rig.running()
        // The pipeline the view was made with, made again, a hundred times.
        for _ in 0 ..< 100 { rig.model.want(rig.pipeline([-6])) }
        await mainQueueDrained()
        #expect(rig.host.updates.isEmpty && rig.host.attaches == 1, "an equal pipeline causes no update and no new attachment")
        // Another value: one update, and the session runs it.
        rig.model.want(rig.pipeline([-20]))
        #expect(rig.host.updates == [ParameterVector([-20])])
        expectClose(await rig.gainAfter(), 0.1, .absolute(1e-4), "−20 dB reached the kernel")
        rig.model.want(rig.pipeline([-20]))
        await mainQueueDrained()
        #expect(rig.host.updates.count == 1)
        rig.model.disappear()
    }

    /// ANI-5: the newest frame wins. While an update is on its way, what is asked for
    /// meanwhile is dropped, except the last.
    @Test func whileAnUpdateIsOnItsWayTheNewestPipelineWins() async throws {
        let rig = Rig()
        rig.appear([-0.5])
        await rig.running()
        for step in 1 ... 40 { rig.model.want(rig.pipeline([-Double(step)])) }
        #expect(rig.host.updates.first == ParameterVector([-1]), "the first went out at once")
        #expect(await eventually { rig.host.updates.last == ParameterVector([-40]) }, "the last one is sent when the way is free")
        #expect(rig.host.updates.count < 40, "what lay between was dropped: \(rig.host.updates.count) updates")
        #expect(rig.host.updates.map { $0.values[0] } == rig.host.updates.map { $0.values[0] }.sorted(by: >), "in the order they were asked for")
        expectClose(await rig.gainAfter(), 0.01, .absolute(1e-4), "the session ends at −40 dB")
        rig.model.disappear()
    }

    @Test func aPipelineTheEngineRefusesLeavesTheRunningOneAsItIs() async throws {
        let rig = Rig()
        rig.appear([-6])
        await rig.running()
        rig.model.want(rig.pipeline([.infinity]))
        #expect(await eventually { rig.host.failures.count == 1 }, "the refusal is noted")
        guard case .invalidParameter = rig.host.failures.first else {
            Issue.record("expected invalidParameter, got \(String(describing: rig.host.failures.first))")
            return
        }
        #expect(rig.host.session?.state == .running)
        expectClose(await rig.gainAfter(), 0.501_187, .absolute(1e-4), "the session still runs −6 dB")
        // The refused pipeline is not sent again; the running one, asked for again, needs no update.
        let sent = rig.host.updates.count
        rig.model.want(rig.pipeline([.infinity]))
        rig.model.want(rig.pipeline([-6]))
        await mainQueueDrained()
        #expect(rig.host.updates.count == sent && rig.host.failures.count == 1)
        // A valid one is.
        rig.model.want(rig.pipeline([-20]))
        #expect(await eventually { rig.host.updates.last == ParameterVector([-20]) })
        rig.model.disappear()
    }

    @Test func aPipelineThatCannotBeAttachedIsNotedAndTheNextOneIsAttached() async throws {
        let rig = Rig()
        rig.appear([.infinity])
        #expect(await eventually { rig.host.failures.count == 1 })
        #expect(rig.host.attaches == 0 && rig.host.session == nil)
        rig.model.want(rig.pipeline([.infinity]))
        await mainQueueDrained()
        #expect(rig.host.failures.count == 1, "not tried again as it is")
        rig.model.want(rig.pipeline([-6]))
        await rig.running()
        #expect(rig.host.attaches == 1 && rig.render.attaches == 1)
        rig.model.disappear()
    }

    /// A view that leaves while its pipeline is still being attached leaves nothing behind.
    @Test func aViewThatLeavesBeforeItsSessionArrivesKeepsNone() async throws {
        let rig = Rig()
        rig.appear([-6])
        rig.model.disappear()
        // The feed is free again as soon as the late session has been detached: another
        // attachment can claim it.
        let pipeline = rig.pipeline([-3])
        var claimed = false
        for _ in 0 ..< 2_000 where !claimed {
            if let session = try? await rig.engine.attach(pipeline, to: rig.source) {
                claimed = true
                session.detach()
            } else {
                await mainQueueDrained()
            }
        }
        #expect(claimed, "the feed was released")
        #expect(rig.host.attaches == 0 && rig.host.detaches == 0 && rig.host.session == nil)
    }

    @Test func appearingAgainAttachesAnew() async throws {
        let rig = Rig()
        rig.appear([-6])
        await rig.running()
        let first = try #require(rig.host.session)
        rig.appear([-3])
        #expect(first.state == .detached && rig.host.detaches == 1)
        #expect(await eventually { rig.host.attaches == 2 && rig.host.session?.state == .running })
        #expect(rig.host.session !== first)
        rig.model.disappear()
    }

    // MARK: Hosted: the life cycle through SwiftUI (WP-816)

    struct Hosting: Equatable {
        var counter = 0
        var gains: [Double] = [-6, -12, -3]
        var delay: Int?
        var shown = true
    }

    /// A hosted view with a pipeline, and what the test sees of it.
    private func host(_ handle: StateHandle<Hosting>, _ rig: Rig) -> Hosted<some View> {
        let feed = rig.feed, source = rig.source, engine = rig.engine, probe = rig.host, render = rig.render
        return Hosted(Stateful(Hosting(), handle) { state in
            VStack {
                Text("\(state.wrappedValue.counter)")
                if state.wrappedValue.shown {
                    Color.clear
                        .pipeline(PipelineHostTests.chain(state.wrappedValue.gains, delay: state.wrappedValue.delay, into: feed), on: source)
                }
            }
            .dspEngine(engine)
            .environment(\.dspPipelineHostProbe, probe)
            .environment(\.dspRenderProbe, render)
        })
    }

    @Test func aHostedPipelineIsAttachedOnAppearUpdatedOnChangeAndDetachedOnDisappear() async throws {
        let rig = Rig(), handle = StateHandle<Hosting>()
        let hosted = host(handle, rig)
        defer { hosted.close() }
        await rig.running()
        let session = try #require(rig.host.session)
        #expect(rig.host.attaches == 1 && rig.render.attaches == 1 && rig.host.updates.isEmpty)
        #expect(session.environment.sampleRate == 48_000, "on the engine the environment names, with the source's format")

        // The parent's body runs twenty times with an equal pipeline.
        var state = Hosting()
        for step in 1 ... 20 {
            state.counter = step
            handle.set(state)
            await displayFrames(1)
        }
        #expect(rig.host.updates.isEmpty && rig.host.attaches == 1 && rig.render.attaches == 1, "an equal pipeline: no update, no new attachment")

        // Another value, without animation: exactly one update.
        state.gains = [-6, -30, -3]
        handle.set(state)
        #expect(await eventually { rig.host.updates.count == 1 })
        #expect(rig.host.updates == [ParameterVector([-6, -30, -3])])
        await displayFrames(3)
        #expect(rig.host.updates.count == 1 && rig.host.session === session)

        // The view leaves the hierarchy.
        state.shown = false
        handle.set(state)
        #expect(await eventually { rig.host.detaches == 1 })
        #expect(session.state == .detached)

        // It comes back: a new attachment.
        state.shown = true
        handle.set(state)
        #expect(await eventually { rig.host.attaches == 2 && rig.host.session?.state == .running })
    }

    /// The source and the engine are part of what a host keeps: another one of either is
    /// another attachment, on that source and on that engine.
    @Test func anotherSourceOrAnotherEngineIsAnotherAttachment() async throws {
        let rig = Rig()
        let other = HandFedSource(), otherEngine = DSPEngine(blockSize: 32)
        struct Where: Equatable {
            var usesOtherSource = false
            var usesOtherEngine = false
        }
        let handle = StateHandle<Where>()
        let feed = rig.feed, source = rig.source, engine = rig.engine, probe = rig.host
        let hosted = Hosted(Stateful(Where(), handle) { state in
            Color.clear
                .pipeline(PipelineHostTests.chain([-6], into: feed), on: state.wrappedValue.usesOtherSource ? other : source)
                .dspEngine(state.wrappedValue.usesOtherEngine ? otherEngine : engine)
                .environment(\.dspPipelineHostProbe, probe)
        })
        defer { hosted.close() }
        await rig.running()
        let first = try #require(rig.host.session)
        handle.set(Where(usesOtherSource: true))
        #expect(await eventually { rig.host.attaches == 2 && rig.host.session?.state == .running }, "attached to the other source")
        #expect(first.state == .detached && rig.host.detaches == 1 && rig.host.failures.isEmpty)
        // It is the other source the pipeline runs on now: what that one delivers becomes a
        // column, and what the first one delivers reaches nobody.
        let block = [Float](repeating: 1, count: 16)
        rig.source.write(block)
        #expect(other.write(block) == 16)
        #expect(await eventually { rig.feed.columnCount == 1 }, "one block of the other source, one column")
        await displayFrames(3)
        #expect(rig.feed.columnCount == 1)
        let second = try #require(rig.host.session)
        #expect(second.environment.blockSize == 16)
        handle.set(Where(usesOtherSource: true, usesOtherEngine: true))
        #expect(await eventually { rig.host.attaches == 3 && rig.host.session?.state == .running }, "attached on the other engine")
        #expect(second.state == .detached && rig.host.detaches == 2 && rig.host.failures.isEmpty)
        #expect(rig.host.session?.environment.blockSize == 32, "it is the other engine the pipeline runs on now")
    }

    /// The same for the model the view drives: evaluated again on the source and the engine
    /// it has, the view updates its session or does nothing; on another source or engine it
    /// attaches anew; when it is not in the hierarchy it does neither.
    @Test func theModelTellsAnUpdateFromAnotherAttachment() async throws {
        let rig = Rig()
        rig.model.show(rig.pipeline([-6]), on: rig.source, engine: rig.engine)
        await mainQueueDrained()
        #expect(rig.host.requests == 0, "a view that is not in the hierarchy attaches nothing")
        rig.appear([-6])
        await rig.running()
        let first = try #require(rig.host.session)
        // The same source and engine: an equal pipeline is nothing, another one an update.
        for _ in 0 ..< 100 { rig.model.show(rig.pipeline([-6]), on: rig.source, engine: rig.engine) }
        await mainQueueDrained()
        #expect(rig.host.updates.isEmpty && rig.host.attaches == 1 && rig.host.requests == 1)
        rig.model.show(rig.pipeline([-20]), on: rig.source, engine: rig.engine)
        #expect(rig.host.updates == [ParameterVector([-20])] && rig.host.attaches == 1)
        expectClose(await rig.gainAfter(), 0.1, .absolute(1e-4))
        // Another source: the session is ended at once, and the pipeline attached there.
        let other = HandFedSource()
        rig.model.show(rig.pipeline([-20]), on: other, engine: rig.engine)
        #expect(first.state == .detached && rig.host.detaches == 1)
        #expect(await eventually { rig.host.attaches == 2 && rig.host.session?.state == .running })
        #expect(rig.render.attaches == 2 && rig.host.updates.count == 1 && rig.host.failures.isEmpty, "the probes of the first appearance count on")
        // Another engine.
        let second = try #require(rig.host.session)
        rig.model.show(rig.pipeline([-20]), on: other, engine: DSPEngine(blockSize: 32))
        #expect(second.state == .detached)
        #expect(await eventually { rig.host.attaches == 3 && rig.host.session?.environment.blockSize == 32 })
        rig.model.disappear()
        rig.model.show(rig.pipeline([-3]), on: other, engine: rig.engine)
        await mainQueueDrained()
        #expect(rig.host.requests == 3 && rig.host.detaches == 3)
    }

    // MARK: Hosted: animation (WP-817)

    /// The assumption of §8.7: an `Animatable` whose data is a vector of run-time length is
    /// interpolated by SwiftUI as fixed-size data is. Three values glide at once, and each
    /// frame is one update of the same topology.
    @Test func insideWithAnimationTheSessionReceivesInterpolatedUpdates() async throws {
        let rig = Rig(), handle = StateHandle<Hosting>()
        let hosted = host(handle, rig)
        defer { hosted.close() }
        await rig.running()
        let session = try #require(rig.host.session)
        let replans = Box(0)
        let events = session.events
        let listening = Task {
            for await event in events {
                if case .replanned = event { replans.value += 1 }
            }
        }
        var state = Hosting()
        state.gains = [-30, -2, -3]
        await handle.animate(to: state, .linear(duration: 0.5))
        #expect(await eventually { rig.host.updates.last == ParameterVector([-30, -2, -3]) }, "the animation ended at its target")
        let updates = rig.host.updates
        #expect(updates.count >= 2, "more than the target: \(updates.count) updates")
        #expect(updates.allSatisfy { $0.count == 3 })
        // Each value glides from where it was to where it goes; the one that does not change stays.
        #expect(isGlide(updates.map { $0.values[0] }, from: -6, to: -30), "\(updates.map { $0.values[0] })")
        #expect(isGlide(updates.map { $0.values[1] }, from: -12, to: -2), "\(updates.map { $0.values[1] })")
        #expect(updates.allSatisfy { $0.values[2] == -3 })
        // The values move together: every frame is the same share of the way for each.
        for update in updates {
            expectClose((update.values[0] + 6) / -24, (update.values[1] + 12) / 10, .absolute(1e-9))
        }
        // Updates of the same topology: no new plan was compiled.
        for _ in 0 ..< 4 { await mainQueueDrained() }
        #expect(replans.value == 0 && rig.host.attaches == 1 && rig.host.session === session)
        expectClose(await rig.gainAfter(), Float(pow(10, -35.0 / 20)), .absolute(1e-4), "the session runs the target: −30, −2 and −3 dB")
        listening.cancel()
    }

    /// ANI-4: a change of topology is applied at once, also inside `withAnimation`.
    @Test func aChangeOfTopologyIsAppliedAtOnce() async throws {
        let rig = Rig(), handle = StateHandle<Hosting>()
        let hosted = host(handle, rig)
        defer { hosted.close() }
        await rig.running()
        var state = Hosting()
        // The same number of values, other values, and one stage more.
        state.gains = [-40, -1, 3]
        state.delay = 8
        await handle.animate(to: state, .linear(duration: 0.4))
        #expect(await eventually { rig.host.updates.last == ParameterVector([-40, -1, 3]) })
        await displayFrames(3)
        #expect(rig.host.updates == [ParameterVector([-40, -1, 3])], "one update, with the target's values: \(rig.host.updates)")
        // And another number of values.
        state.gains = [-9]
        await handle.animate(to: state, .linear(duration: 0.4))
        #expect(await eventually { rig.host.updates.last == ParameterVector([-9]) })
        await displayFrames(3)
        #expect(rig.host.updates.count == 2)
    }

    /// A pipeline hosted on another view is hosted on a component just the same: the feed the
    /// pipeline writes is the one the component shows.
    @Test func aComponentShowsThePipelineItHosts() async throws {
        let rig = Rig(), probe = RenderProbe()
        let feed = rig.feed, source = rig.source, engine = rig.engine, hostProbe = rig.host
        let handle = StateHandle<Int>()
        let hosted = Hosted(Stateful(0, handle) { _ in
            HeatmapView(feed: feed)
                .pipeline(PipelineHostTests.chain([-6], into: feed), on: source)
                .dspEngine(engine)
                .environment(\.dspPipelineHostProbe, hostProbe)
                .environment(\.dspRenderProbe, probe)
        })
        defer { hosted.close() }
        await rig.running()
        #expect(probe.attaches == 1, "the attachment is counted by the probe of the hierarchy")
        _ = await rig.gainAfter(blocks: 20)
        #expect(await eventually { probe.uploadedColumns == 20 }, "what the hosted pipeline writes is drawn")
    }
}
