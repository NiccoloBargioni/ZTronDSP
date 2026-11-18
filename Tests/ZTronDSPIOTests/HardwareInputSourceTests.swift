import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// `HardwareInputSource` on doubles of the session, the user and the capture engine (WP-704):
/// what it does when it is prepared, started and stopped, and that frames reach an engine.
@Suite("Hardware input source")
struct HardwareInputSourceTests {
    typealias SessionCall = FakeAudioSession.Call
    typealias CaptureCall = FakeCapture.Call

    let options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]

    @Test func preparingConfiguresTheSessionActivatesItAndDiscoversTheFormat() async throws {
        let rig = InputRig(format: SignalFormat(sampleRate: 44_100, channelCount: 2))
        #expect(!rig.source.format.isValid, "before it is prepared a source has no format")
        try await rig.source.prepare()
        #expect(rig.session.calls == [
            .setCategory(.playAndRecord, .default, options), .allowHaptics(true), .setActive(true, notifyingOthers: false),
        ])
        #expect(rig.capture.calls == [.stop, .rebuild, .connect], "a new engine, connected in the input's format; not started yet")
        #expect(rig.source.format == SignalFormat(sampleRate: 44_100, channelCount: 2))
        #expect(rig.authorizer.requests == 0 && rig.capture.invalidConnects == 0)
    }

    /// MIC-6: sample rate and channel count are discovered, never assumed.
    @Test(arguments: [
        SignalFormat(sampleRate: 8_000, channelCount: 1), SignalFormat(sampleRate: 48_000, channelCount: 1),
        SignalFormat(sampleRate: 96_000, channelCount: 4), SignalFormat(sampleRate: 44_100, channelCount: 256),
    ])
    func theFormatIsWhateverTheInputDelivers(format: SignalFormat) async throws {
        let rig = InputRig(format: format)
        try await rig.source.prepare()
        #expect(rig.source.format == format)
    }

    /// CAP-6: voice processing changes the signal, so it is off unless asked for.
    @Test func voiceProcessingIsOffUnlessAsked() async throws {
        let plain = InputRig()
        try await plain.source.prepare()
        #expect(!plain.capture.calls.contains { if case .voiceProcessing = $0 { true } else { false } })

        let processed = InputRig(voiceProcessing: true)
        try await processed.source.prepare()
        #expect(processed.capture.calls == [.stop, .rebuild, .voiceProcessing(true), .connect], "on the new engine, before it is connected")

        let refused = InputRig(voiceProcessing: true)
        refused.capture.fail(.voiceProcessing, with: .unsupportedConfiguration(reason: "no voice processing"))
        await #expect(throws: DSPError.unsupportedConfiguration(reason: "no voice processing")) { try await refused.source.prepare() }
    }

    @Test func anInputThatDeliversNoFormatIsUnavailable() async {
        for format in [SignalFormat(sampleRate: 0, channelCount: 0), SignalFormat(sampleRate: 48_000, channelCount: 0), SignalFormat(sampleRate: 0, channelCount: 2)] {
            let rig = InputRig(format: format)
            do throws(DSPError) {
                try await rig.source.prepare()
                Issue.record("\(format) is no format to capture")
            } catch {
                guard case .sourceUnavailable = error else {
                    Issue.record("expected sourceUnavailable, got \(error)")
                    continue
                }
            }
            #expect(rig.capture.invalidConnects == 0 && !rig.capture.calls.contains(.connect), "AVFAudio raises on a connection without a format: it is never asked for")
            #expect(throws: DSPError.self) { try rig.source.start() }
        }
    }

    @Test func aSessionWithoutAnyInputIsUnavailable() async {
        let rig = InputRig()
        rig.session.setHasInput(false)
        await #expect(throws: DSPError.sourceUnavailable(reason: "no audio input is available")) { try await rig.source.prepare() }
        #expect(!rig.capture.calls.contains(.rebuild), "no engine is built for an input that is not there")
    }

    @Test func anInputOfMoreChannelsThanTheCapturePathTakesIsRefused() async {
        let rig = InputRig(format: SignalFormat(sampleRate: 48_000, channelCount: 257))
        do throws(DSPError) {
            try await rig.source.prepare()
            Issue.record("257 channels are more than a sink tap takes")
        } catch {
            guard case .unsupportedConfiguration = error else {
                Issue.record("expected unsupportedConfiguration, got \(error)")
                return
            }
        }
        #expect(EngineInputCapture.maximumChannelCount == 256)
    }

    @Test func whatTheSessionOrTheEngineRefusesFailsThePreparation() async {
        let inactive = InputRig()
        inactive.session.fail(.setActive, with: .sessionConfigurationFailed(reason: "a call is in progress"))
        await #expect(throws: DSPError.sessionConfigurationFailed(reason: "a call is in progress")) { try await inactive.source.prepare() }
        #expect(inactive.capture.calls == [.stop], "the engine is not built for a session that is not active")

        let unbuilt = InputRig()
        unbuilt.capture.fail(.rebuild, with: .resourceAllocationFailed(what: "the sink node"))
        await #expect(throws: DSPError.resourceAllocationFailed(what: "the sink node")) { try await unbuilt.source.prepare() }

        let unconnected = InputRig()
        unconnected.capture.fail(.connect, with: .sourceUnavailable(reason: "no connection"))
        await #expect(throws: DSPError.sourceUnavailable(reason: "no connection")) { try await unconnected.source.prepare() }
        #expect(throws: DSPError.self) { try unconnected.source.start() }
    }

    // MARK: Start and stop (CAP-4)

    @Test func startingAndStoppingRunsTheEngineAndLeavesTheSessionActive() async throws {
        let rig = InputRig()
        #expect(throws: DSPError.self) { try rig.source.start() }
        #expect(rig.capture.calls.isEmpty, "a source that was not prepared starts nothing")
        try await rig.source.prepare()
        rig.session.forgetCalls()
        rig.capture.forgetCalls()

        try rig.source.start()
        try rig.source.start()
        #expect(rig.capture.calls == [.start] && rig.capture.isRunning, "starting twice starts once")
        #expect(rig.session.calls.isEmpty, "the session was activated when the source was prepared")
        rig.source.stop()
        #expect(rig.capture.calls == [.start, .stop] && !rig.capture.isRunning)
        #expect(rig.session.calls.isEmpty && rig.session.isActive, "setActive(false) is never called unasked (CAP-4)")
        try rig.source.start()
        #expect(rig.session.calls.isEmpty, "and a session that is still active is not activated again")
    }

    @Test func deactivatingOnStopDeactivatesAndTellsOthers() async throws {
        let rig = InputRig(policy: .playAndRecord.deactivatingOnStop())
        try await rig.source.prepare()
        try rig.source.start()
        rig.session.forgetCalls()
        rig.source.stop()
        #expect(rig.session.calls == [.setActive(false, notifyingOthers: true)] && !rig.session.isActive)
        try rig.source.start()
        #expect(rig.session.calls == [.setActive(false, notifyingOthers: true), .setActive(true, notifyingOthers: false)], "the next start activates it again")
    }

    @Test func anEngineThatDoesNotStartFailsTheStart() async throws {
        let rig = InputRig()
        try await rig.source.prepare()
        rig.capture.fail(.start, with: .sourceUnavailable(reason: "the engine does not start"))
        #expect(throws: DSPError.sourceUnavailable(reason: "the engine does not start")) { try rig.source.start() }
        rig.capture.fail(.start, with: nil)
        try rig.source.start()
        #expect(rig.capture.isRunning, "a start that failed left the source ready for another")
    }

    @Test func preparingAgainStartsFromTheBeginning() async throws {
        let rig = InputRig()
        try await rig.source.prepare()
        try rig.source.start()
        rig.session.forgetCalls()
        rig.capture.forgetCalls()
        rig.capture.setFormat(SignalFormat(sampleRate: 16_000, channelCount: 1))
        try await rig.source.prepare()
        #expect(rig.capture.calls == [.stop, .rebuild, .connect] && !rig.capture.isRunning)
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)], "the category already permits input: only the activation is repeated")
        #expect(rig.source.format.sampleRate == 16_000)
    }

    // MARK: With an engine

    @Test func framesReachTheEngine() async throws {
        let rig = InputRig(format: SignalFormat(sampleRate: 48_000, channelCount: 2))
        let attached = try await Attachment(rig.source)
        #expect(rig.capture.calls.last == .setRing(2), "the engine hands the source a ring of the input's format")
        #expect(attached.session.environment.sampleRate == 48_000 && attached.session.environment.channelCount == 2, "the environment is resolved from the discovered format (ATT-3)")
        #expect(rig.capture.deliver([1, 2, 3]) == 0, "nothing is captured before the session starts")

        try attached.session.start()
        #expect(rig.capture.isRunning)
        let signal = steppedSignal(count: 64 * 20, seed: 4)
        #expect(rig.capture.deliver(signal) == signal.count)
        #expect(await eventually { attached.sink.frameCount == signal.count })
        #expect(attached.sink.samples(ofChannel: 0) == signal && attached.sink.samples(ofChannel: 1) == signal)

        attached.session.stop()
        #expect(!rig.capture.isRunning && attached.session.state == .idle)
        attached.session.detach()
    }

    /// RT-8: a hardware source that overruns its ring drops the newest frames; the ring counts
    /// them and the engine reports the overrun. The source neither blocks nor grows the ring.
    @Test func anOverrunDropsTheNewestFramesAndIsReported() async throws {
        let rig = InputRig()
        let attached = try await Attachment(rig.source)
        try attached.session.start()
        // More at once than the ring holds: half a second of audio.
        let flood = [Float](repeating: 0.5, count: 200_000)
        let written = rig.capture.deliver(flood)
        #expect(written >= 24_000 && written < flood.count, "the ring never grows")
        #expect(await eventually { attached.log.contains(.overrun(droppedFrames: flood.count - written)) }, "the dropped frames are counted and reported")
        #expect(await eventually { attached.sink.frameCount == written - written % 64 }, "what was kept, the oldest, is delivered")
        #expect(attached.session.state == .running, "and capture goes on")
        #expect(rig.capture.deliver([Float](repeating: 0.25, count: 64)) == 64)
        #expect(await eventually { attached.sink.samples().last == 0.25 })
        attached.session.detach()
    }
}
