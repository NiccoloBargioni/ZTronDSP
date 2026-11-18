import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// Route changes, engine configuration changes, a reset of the media services and the loss of
/// every input: the rest of the table of CAP-8 (WP-705b), each row driven by the notification
/// the system posts.
@Suite("Route changes")
struct RouteChangeTests {
    let mono = SignalFormat(sampleRate: 48_000, channelCount: 1)
    let stereo = SignalFormat(sampleRate: 44_100, channelCount: 2)
    let block = [Float](repeating: 0.5, count: 64)

    private func started(voiceProcessing: Bool = false) async throws -> (InputRig, SourceLog) {
        let rig = InputRig(voiceProcessing: voiceProcessing)
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        try rig.source.start()
        rig.session.forgetCalls()
        rig.capture.forgetCalls()
        return (rig, log)
    }

    // MARK: Row 4: the route changed

    @Test func aRouteChangeReadsTheFormatAgainAndLeavesARunningEngineAlone() async throws {
        let (rig, log) = try await started()
        rig.postRouteChange(.categoryChange)
        #expect(await log.shows([.routeChanged(.other)]))
        #expect(rig.capture.calls.isEmpty && rig.capture.isRunning, "the format is the same: nothing is stopped, connected or started")
        #expect(rig.session.calls.isEmpty)
    }

    @Test func aRouteChangeToAnotherFormatIsAFormatChange() async throws {
        let (rig, log) = try await started()
        rig.capture.setFormat(stereo)
        rig.postRouteChange()
        #expect(await log.shows([.routeChanged(.other), .formatChanged(stereo)]), "the route first, then the format")
        #expect(rig.source.format == stereo)
        #expect(rig.capture.calls == [.stop, .setRing(nil), .disconnect, .connect, .start],
                "connected anew in the new format; frames are discarded until the engine hands over a ring of it")
        #expect(rig.capture.isRunning && rig.capture.invalidConnects == 0)
    }

    @Test func aFormatChangeReplansTheSession() async throws {
        let rig = InputRig(format: mono)
        let attached = try await Attachment(rig.source)
        try attached.session.start()
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 && attached.sink.channelCount == 1 })

        rig.capture.setFormat(stereo)
        rig.postRouteChange()
        #expect(await eventually { attached.log.contains(.replanned(.formatChanged)) }, "the plan is compiled again for the new format (ATT-4)")
        #expect(await eventually { rig.capture.ringChannelCount == 2 }, "and the source is handed a ring of the new format")
        #expect(attached.session.state == .running, "the session stays running")
        #expect(attached.session.environment.sampleRate == 44_100 && attached.session.environment.channelCount == 2)
        rig.capture.deliver(block + block)
        #expect(await eventually { attached.sink.channelCount == 2 && attached.sink.frameCount == 128 })
        #expect(attached.sink.samples(ofChannel: 1) == block + block)
        #expect(attached.sink.times.suffix(2) == [0, Double(64) / 44_100], "stages start cold after a format change, at the new rate")
        attached.session.detach()
    }

    @Test func aFormatChangeOfAnIdleSourceReplansToo() async throws {
        let rig = InputRig(format: mono)
        let attached = try await Attachment(rig.source)
        rig.capture.forgetCalls()
        rig.capture.setFormat(stereo)
        rig.postRouteChange()
        #expect(await eventually { attached.log.contains(.replanned(.formatChanged)) && rig.capture.ringChannelCount == 2 })
        #expect(!rig.capture.calls.contains(.start) && attached.session.state == .idle, "an idle source stays idle")
        try attached.session.start()
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 && attached.sink.channelCount == 2 })
        attached.session.detach()
    }

    @Test func aRouteChangeDuringAnInterruptionIsLookedAtWhenTheInterruptionEnds() async throws {
        let (rig, log) = try await started()
        rig.postInterruptionBegan()
        rig.session.setHasInput(false)
        rig.capture.setFormat(SignalFormat(sampleRate: 0, channelCount: 0))
        rig.postRouteChange()
        #expect(await log.shows([.interrupted, .routeChanged(.other)]), "the route is reported; while interrupted there may be no input at all")
        #expect(rig.capture.calls == [.stop])
        rig.session.setHasInput(true)
        rig.capture.setFormat(stereo)
        rig.postInterruptionEnded(shouldResume: true)
        #expect(await log.shows([.interrupted, .routeChanged(.other), .formatChanged(stereo), .resumed]))
    }

    // MARK: Row 5: the engine reports a configuration change

    @Test func anEngineThatStoppedItselfIsRestarted() async throws {
        let (rig, log) = try await started()
        rig.capture.stopByItself()
        rig.postEngineConfigurationChange()
        #expect(await eventually { rig.capture.isRunning })
        #expect(rig.capture.calls == [.start], "the same format: started again, not connected anew")
        await pause()
        #expect(log.all.isEmpty, "and no event: nothing changed for the session")
    }

    @Test func aConfigurationChangeToAnotherFormatIsAFormatChange() async throws {
        let (rig, log) = try await started()
        rig.capture.stopByItself()
        rig.capture.setFormat(stereo)
        rig.postEngineConfigurationChange()
        #expect(await log.shows([.formatChanged(stereo)]), "a format change without a route change")
        #expect(rig.capture.calls == [.stop, .setRing(nil), .disconnect, .connect, .start] && rig.capture.isRunning)
    }

    @Test func theConfigurationChangeOfAnotherEngineIsNotTheSourcesBusiness() async throws {
        let (rig, log) = try await started()
        rig.capture.setFormat(stereo)
        rig.postEngineConfigurationChange(from: NSObject())           // the app's own player
        notificationsWithoutObject(rig)
        await pause()
        #expect(log.all.isEmpty && rig.capture.calls.isEmpty && rig.source.format == mono)
    }

    private func notificationsWithoutObject(_ rig: InputRig) {
        rig.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        rig.source.settle()
    }

    @Test func aStoppedSourceIsNotStartedByAConfigurationChange() async throws {
        let (rig, _) = try await started()
        rig.source.stop()
        rig.capture.forgetCalls()
        rig.postEngineConfigurationChange()
        await pause()
        #expect(rig.capture.calls.isEmpty && !rig.capture.isRunning)
    }

    // MARK: Row 6: media services were reset

    @Test func aResetOfTheMediaServicesRebuildsTheEngineAndAppliesThePolicyAgain() async throws {
        let (rig, log) = try await started(voiceProcessing: true)
        let oldEngine = try #require(rig.capture.engine)
        rig.session.deactivateBySystem()
        rig.postMediaServicesReset()
        #expect(await log.shows([.mediaServicesReset, .routeChanged(.other)]), "then as for a route change")
        #expect(rig.capture.calls == [.rebuild, .voiceProcessing(true), .connect, .start], "a new engine and sink node, restarted because it was running")
        #expect(rig.capture.isRunning && rig.capture.engine !== oldEngine)
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)] && rig.session.isActive,
                "the policy again: the category still permits input, so only the activation is repeated")

        // The engine that was let go is nobody's any more; the new one is the source's.
        rig.capture.forgetCalls()
        rig.capture.stopByItself()
        rig.postEngineConfigurationChange(from: oldEngine)
        #expect(rig.capture.calls.isEmpty)
        rig.postEngineConfigurationChange()
        #expect(rig.capture.calls == [.start])
    }

    @Test func aResetAfterWhichTheSessionHasLostItsCategoryConfiguresItAgain() async throws {
        let session = FakeAudioSession(category: .playback)
        let rig = InputRig(policy: .measurement.mixingWithOthers(), session: session)
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        let configured = session.calls
        // A reset leaves the session as a new process finds it.
        try session.setCategory(.soloAmbient, mode: .default, options: [])
        session.forgetCalls()
        rig.capture.setFormat(stereo)
        rig.postMediaServicesReset()
        #expect(session.calls == configured, "exactly what preparing did: category, options, haptics, activation")
        #expect(await log.shows([.mediaServicesReset, .routeChanged(.other), .formatChanged(stereo)]))
        #expect(!rig.capture.isRunning, "a source that was not running is not started by a reset")
    }

    @Test func aResetSelectsTheRequestedInputAgain() async throws {
        let usb = FakeAudioSession.usb
        let rig = InputRig(input: usb, dataSource: nil, session: FakeAudioSession(inputs: [FakeAudioSession.builtIn, usb]))
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        rig.session.forgetCalls()
        // The preference went with the old session.
        try rig.session.setPreferredInput(nil)
        rig.session.forgetCalls()
        rig.postMediaServicesReset()
        #expect(await log.shows([.mediaServicesReset, .routeChanged(.other)]))
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false), .setPreferredInput("usb-1")], "activated again, and the input preferred again")
        #expect(rig.session.currentInput == usb)

        // An input that is gone at the reset is lost, and reported as lost.
        rig.session.disconnect(usb)
        rig.postMediaServicesReset()
        #expect(await log.shows([.mediaServicesReset, .routeChanged(.other), .mediaServicesReset, .routeChanged(.inputLost)]))
        // And when it is back at a reset, it is restored.
        rig.session.connect(usb)
        rig.postMediaServicesReset()
        #expect(await eventually { log.all.suffix(2) == [.mediaServicesReset, .routeChanged(.inputRestored)] })
    }

    @Test func aResetAfterWhichThereIsNoInputFailsTheSource() async throws {
        let (rig, log) = try await started()
        rig.session.setHasInput(false)
        rig.postMediaServicesReset()
        #expect(await log.shows([.mediaServicesReset, .routeChanged(.other), .failed(.sourceUnavailable(reason: "no audio input is available"))]))
        #expect(!rig.capture.isRunning && !rig.capture.calls.contains(.connect))
    }

    @Test func aResetThatCannotBeRecoveredFromFailsTheSource() async throws {
        let (rig, log) = try await started()
        let broken = DSPError.resourceAllocationFailed(what: "the sink node")
        rig.capture.fail(.rebuild, with: broken)
        rig.postMediaServicesReset()
        #expect(await log.shows([.mediaServicesReset, .failed(broken)]))
    }

    // MARK: Row 7: no input is available

    @Test func aSourceWithoutAnyInputStopsAndFails() async throws {
        let (rig, log) = try await started()
        rig.session.setHasInput(false)
        rig.postRouteChange(.oldDeviceUnavailable)
        #expect(await log.shows([.routeChanged(.other), .failed(.sourceUnavailable(reason: "no audio input is available"))]))
        #expect(rig.capture.calls == [.stop] && !rig.capture.isRunning)
    }

    @Test func anInputThatNoLongerHasAFormatFailsTheSession() async throws {
        let rig = InputRig()
        let attached = try await Attachment(rig.source)
        try attached.session.start()
        rig.capture.stopByItself()
        rig.capture.setFormat(SignalFormat(sampleRate: 0, channelCount: 0))
        rig.postEngineConfigurationChange()
        #expect(await eventually {
            if case .failed(.sourceUnavailable) = attached.session.state { true } else { false }
        })
        #expect(rig.capture.invalidConnects == 0 && !rig.capture.isRunning)
        // A failed session starts again once there is an input again: the source is prepared anew.
        rig.capture.setFormat(stereo)
        try attached.session.start()
        #expect(await attached.session.reaches(.running))
        #expect(attached.session.environment.sampleRate == 44_100)
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 && attached.sink.channelCount == 2 })
        attached.session.detach()
    }

    // MARK: Before the source is prepared

    @Test func nothingIsActedOnBeforeTheSourceIsPrepared() async {
        let rig = InputRig()
        let log = SourceLog(rig.source)
        rig.postRouteChange()
        rig.postMediaServicesReset()
        rig.postEngineConfigurationChange()
        rig.postInterruptionBegan()
        await pause()
        #expect(log.all.isEmpty && rig.capture.calls.isEmpty && rig.session.calls.isEmpty)
    }
}
