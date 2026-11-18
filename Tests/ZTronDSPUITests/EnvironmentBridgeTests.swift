import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// The SwiftUI environment bridge (WP-807, ENV-4): `.dspEnvironment(_:)` publishes the values
/// at the source and the latency of the main line, and only when the session's format or
/// topology changes (V-7). `.dspEngine(_:)` names the engine views attach to.
@MainActor
@Suite("Environment bridge")
struct EnvironmentBridgeTests {
    /// A session on a source the test feeds, and everyone who listens to it.
    @MainActor
    final class Rig {
        let engine = DSPEngine(blockSize: 16)
        let source = HandFedSource(sampleRate: 48_000)
        let session: PipelineSession
        private(set) var replans = 0
        private var listener: Task<Void, Never>?

        init(_ pipeline: Pipeline<Samples, Samples>) async throws {
            session = try await engine.attach(pipeline, to: source)
            let events = session.events
            listener = Task { [weak self] in
                for await event in events {
                    if case .replanned = event { self?.replans += 1 }
                }
            }
        }

        /// Waits until the session has announced `count` new plans, and until everyone who
        /// listens on the main actor has heard of them. A running session exchanges its plan
        /// at a block boundary, so blocks are fed until it has.
        func replanned(_ count: Int) async {
            let block = [Float](repeating: 0.25, count: 16)
            #expect(await eventually {
                if self.session.state == .running { self.source.write(block) }
                return self.replans >= count
            }, "the session announced plan \(count)")
            for _ in 0 ..< 4 { await mainQueueDrained() }
        }
    }

    static func gain(_ decibels: Double, delay: Int? = nil, extra: Bool = false) -> Pipeline<Samples, Samples> {
        var pipeline = Pipeline<Samples, Samples>().appending(TestGain(decibels: decibels))
        if let delay { pipeline = pipeline.appending(TestDelay(frames: delay)) }
        if extra { pipeline = pipeline.appending(TestGain(decibels: 0.5)) }
        return pipeline
    }

    // MARK: What is published

    @Test func theBridgePublishesTheValuesAtTheSourceAndTheLatencyOfTheMainLine() async throws {
        let rig = try await Rig(Self.gain(-3, delay: 480))
        let values = SourceEnvironment(rig.session.environment)
        #expect(values.sampleRate == 48_000 && values.channelCount == 1)
        #expect(abs(values.latency - 0.01) < 1e-12, "480 frames at 48 kHz")
        #expect(SourceEnvironment.reference == SourceEnvironment(DSPEnvironment()) && SourceEnvironment.reference.sampleRate == 48_000)
        #expect(SourceEnvironment.reference.channelCount == 1 && SourceEnvironment.reference.latency == 0)
        var environment = EnvironmentValues()
        #expect(environment.dspSampleRate == 48_000 && environment.dspNyquistFrequency == 24_000 && environment.dspChannelCount == 1 && environment.dspLatency == 0)
        #expect(environment.dspEngine === DSPEngine.shared, "the shared engine unless a view says otherwise")
        environment.dspSourceEnvironment = values
        environment.dspEngine = rig.engine
        #expect(environment.dspSampleRate == 48_000 && environment.dspNyquistFrequency == 24_000 && environment.dspLatency == values.latency)
        #expect(environment.dspEngine === rig.engine)
        rig.session.detach()
    }

    // MARK: Only on a change of format or topology (V-7)

    @Test func theBridgePublishesOnlyWhenTheFormatOrTheTopologyChangesTheValues() async throws {
        let rig = try await Rig(Self.gain(-3))
        let published = Box<[SourceEnvironment]>([])
        let following = Task { await EnvironmentBridge.follow(rig.session) { published.value.append($0) } }
        #expect(await eventually { published.value.count == 1 }, "the session's values, once")
        #expect(published.value.first?.sampleRate == 48_000 && published.value.first?.latency == 0)

        // The session runs and data flows: nothing is published.
        try rig.session.start()
        #expect(await eventually { rig.session.state == .running })
        for _ in 0 ..< 50 { rig.source.write([Float](repeating: 0.5, count: 160)) }
        await mainQueueDrained()
        #expect(published.value.count == 1, "state changes and data are nothing to the bridge")

        // The same topology with another value: no new plan, nothing published.
        try await rig.session.update(Self.gain(-12))
        for _ in 0 ..< 4 { await mainQueueDrained() }
        #expect(published.value.count == 1 && rig.replans == 0)

        // Another topology with the same values at the source and the same latency: a new
        // plan, and nothing to publish.
        try await rig.session.update(Self.gain(-12, extra: true))
        await rig.replanned(1)
        #expect(published.value.count == 1, "equal values are not published again")

        // Another topology with another latency: published once.
        try await rig.session.update(Self.gain(-12, delay: 240, extra: true))
        await rig.replanned(2)
        #expect(await eventually { published.value.count == 2 })
        let second = try #require(published.value.count == 2 ? published.value[1] : nil)
        #expect(abs(second.latency - 0.005) < 1e-12 && second.sampleRate == 48_000)

        // The source changes its format: published once.
        rig.source.changeFormat(sampleRate: 44_100)
        await rig.replanned(3)
        #expect(await eventually { published.value.count == 3 })
        let third = try #require(published.value.count == 3 ? published.value[2] : nil)
        #expect(third.sampleRate == 44_100 && abs(third.latency - 240.0 / 44_100) < 1e-12)

        // The session is detached: the bridge stops following.
        rig.session.detach()
        await following.value
        #expect(published.value.count == 3)
    }

    @Test func followingASessionThatIsAlreadyDetachedPublishesItsLastValuesAndReturns() async throws {
        let rig = try await Rig(Self.gain(-3))
        rig.session.detach()
        let published = Box<[SourceEnvironment]>([])
        await EnvironmentBridge.follow(rig.session) { published.value.append($0) }
        #expect(published.value.count == 1)
    }

    // MARK: Hosted: views read the values, and are not evaluated at data rate

    /// What a view reads from the bridge, and how often its body ran.
    @MainActor
    final class Readings {
        var bodies = 0
        var sampleRate = 0.0, nyquist = 0.0, latency = 0.0
        var channels = 0
        var engine: DSPEngine?
    }

    struct Reader: View {
        let readings: Readings
        @Environment(\.dspSampleRate) private var sampleRate
        @Environment(\.dspNyquistFrequency) private var nyquist
        @Environment(\.dspChannelCount) private var channels
        @Environment(\.dspLatency) private var latency
        @Environment(\.dspEngine) private var engine

        var body: some View {
            let _ = {
                readings.bodies += 1
                readings.sampleRate = sampleRate
                readings.nyquist = nyquist
                readings.channels = channels
                readings.latency = latency
                readings.engine = engine
            }()
            Color.clear
        }
    }

    @Test func aViewReadsWhatTheBridgePublishesAndIsNotEvaluatedWhileDataFlows() async throws {
        let rig = try await Rig(Self.gain(-3, delay: 96))
        rig.source.changeFormat(sampleRate: 44_100)
        await rig.replanned(1)
        let readings = Readings(), handle = StateHandle<PipelineSession?>()
        let engine = rig.engine
        let hosted = Hosted(Stateful(PipelineSession?.none, handle) { session in
            Reader(readings: readings)
                .dspEnvironment(session.wrappedValue)
                .dspEngine(engine)
        })
        defer { hosted.close() }
        #expect(await eventually { readings.bodies >= 1 })
        #expect(readings.sampleRate == 48_000 && readings.nyquist == 24_000 && readings.channels == 1 && readings.latency == 0, "no session: the reference environment")
        #expect(readings.engine === rig.engine, ".dspEngine names the engine")

        // The session is given: its values are published.
        handle.set(rig.session)
        #expect(await eventually { readings.sampleRate == 44_100 })
        #expect(readings.nyquist == 22_050 && readings.channels == 1 && abs(readings.latency - 96.0 / 44_100) < 1e-12)
        await displayFrames(3)
        let bodies = readings.bodies

        // The session runs and data flows for a while: the view is not evaluated.
        try rig.session.start()
        #expect(await eventually { rig.session.state == .running })
        for _ in 0 ..< 40 {
            rig.source.write([Float](repeating: 0.25, count: 160))
            await displayFrames(1)
        }
        try await rig.session.update(Self.gain(-9, delay: 96))
        await displayFrames(3)
        #expect(readings.bodies == bodies, "the bridge causes no view update at data rate (V-7)")

        // A plan with another latency: the view reads the new value.
        try await rig.session.update(Self.gain(-9, delay: 441))
        await rig.replanned(2)
        #expect(await eventually { abs(readings.latency - 0.01) < 1e-12 })
        #expect(readings.sampleRate == 44_100)
        await displayFrames(3)
        #expect(readings.bodies - bodies <= 2, "one publication: \(readings.bodies - bodies) evaluations")

        // No session any more: the reference environment again.
        handle.set(nil)
        #expect(await eventually { readings.sampleRate == 48_000 && readings.latency == 0 })
        rig.session.detach()
    }
}
