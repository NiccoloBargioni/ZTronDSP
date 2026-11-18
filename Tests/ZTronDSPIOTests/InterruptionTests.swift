import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// Interruptions: the first three rows of the table of CAP-8 (WP-705a), each driven by the
/// notification the system posts, on an injected notification centre.
@Suite("Interruptions")
struct InterruptionTests {
    let block = [Float](repeating: 0.5, count: 64)

    /// A prepared, started source that no engine listens to, and its events.
    private func started(policy: AudioSessionPolicy = .playAndRecord) async throws -> (InputRig, SourceLog) {
        let rig = InputRig(policy: policy)
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        try rig.source.start()
        rig.session.forgetCalls()
        rig.capture.forgetCalls()
        return (rig, log)
    }

    // MARK: The notification

    @Test func anInterruptionNotificationSaysWhatHappened() {
        let typeKey = AVAudioSessionInterruptionTypeKey, optionKey = AVAudioSessionInterruptionOptionKey
        let began = AVAudioSession.InterruptionType.began.rawValue, ended = AVAudioSession.InterruptionType.ended.rawValue
        #expect(SessionNotice.interruption([typeKey: began]) == .interruptionBegan)
        #expect(SessionNotice.interruption([typeKey: NSNumber(value: began)]) == .interruptionBegan, "the system posts numbers")
        #expect(SessionNotice.interruption([typeKey: ended]) == .interruptionEnded(shouldResume: false))
        #expect(SessionNotice.interruption([typeKey: ended, optionKey: UInt(0)]) == .interruptionEnded(shouldResume: false))
        #expect(SessionNotice.interruption([typeKey: ended, optionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue]) == .interruptionEnded(shouldResume: true))
        #expect(SessionNotice.interruption([typeKey: began, AVAudioSessionInterruptionReasonKey: UInt(1)]) == .suspensionEnded, "reason: the app was suspended")
        #expect(SessionNotice.interruption([typeKey: began, AVAudioSessionInterruptionReasonKey: UInt(0)]) == .interruptionBegan, "reason: another session was activated")
        #expect(SessionNotice.interruption([typeKey: began, AVAudioSessionInterruptionReasonKey: UInt(2)]) == .interruptionBegan, "reason: the built-in microphone was muted")
        #expect(SessionNotice.interruption([typeKey: ended, AVAudioSessionInterruptionReasonKey: UInt(1)]) == .interruptionEnded(shouldResume: false), "an end has no reason")
        #expect(SessionNotice.interruption(nil) == nil && SessionNotice.interruption([:]) == nil)
        #expect(SessionNotice.interruption([typeKey: UInt(77)]) == nil && SessionNotice.interruption([typeKey: "began"]) == nil, "a notification that names no known type is not acted on")
    }

    // MARK: Row 1: an interruption began

    @Test func anInterruptionStopsDeliveryAndKeepsTheEngine() async throws {
        let (rig, log) = try await started()
        rig.postInterruptionBegan()
        #expect(await log.shows([.interrupted]))
        #expect(rig.capture.calls == [.stop], "stopped, not rebuilt: the source keeps its engine")
        #expect(rig.session.calls.isEmpty, "the source does not deactivate the session: the system has")
        rig.postInterruptionBegan()
        await pause()
        #expect(log.all == [.interrupted] && rig.capture.calls == [.stop], "an interruption that is reported twice is one interruption")
    }

    // MARK: Row 2: it ended, and the system says to resume

    @Test func anInterruptionThatEndsWithShouldResumeActivatesTheSessionAndRestarts() async throws {
        let (rig, log) = try await started()
        rig.postInterruptionBegan()
        rig.session.deactivateBySystem()
        rig.postInterruptionEnded(shouldResume: true)
        #expect(await log.shows([.interrupted, .resumed]))
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)] && rig.session.isActive, "the session is activated again (CAP-4)")
        #expect(rig.capture.calls == [.stop, .start] && rig.capture.isRunning)
        rig.postInterruptionEnded(shouldResume: true)
        await pause()
        #expect(log.all == [.interrupted, .resumed] && rig.capture.calls == [.stop, .start], "the end of an interruption that never began is nothing")
    }

    @Test func stagesStartColdAfterAResumption() async throws {
        let rig = InputRig()
        let attached = try await Attachment(rig.source, smoothing: true)
        try attached.session.start()
        rig.capture.deliver(block + block)
        #expect(await eventually { attached.sink.frameCount == 128 })
        let first = attached.sink.samples()

        rig.postInterruptionBegan()
        #expect(await attached.session.reaches(.interrupted))
        #expect(rig.capture.deliver(block) == 0, "nothing is delivered while the source is interrupted")
        try attached.session.start()
        #expect(attached.session.state == .interrupted, "start has no effect while interrupted: the session resumes with its source")

        rig.postInterruptionEnded(shouldResume: true)
        #expect(await attached.session.reaches(.running))
        rig.capture.deliver(block + block)
        #expect(await eventually { attached.sink.frameCount == 256 })
        #expect(attached.sink.times.last == Double(64) / 48_000 && attached.sink.times[2] == 0, "the session's clock starts over (ACT-10)")
        #expect(Array(attached.sink.samples()[128...]) == first, "and the filter's memory with it: the same input gives the same output as at the start")
        #expect(await eventually { attached.log.states == [.running, .interrupted, .running] })
        attached.session.detach()
    }

    @Test func aResumptionThatFailsFailsTheSource() async throws {
        let (rig, log) = try await started()
        rig.postInterruptionBegan()
        let refusal = DSPError.sessionConfigurationFailed(reason: "the other app is still talking")
        rig.session.fail(.setActive, with: refusal)
        rig.postInterruptionEnded(shouldResume: true)
        #expect(await log.shows([.interrupted, .failed(refusal)]))
        #expect(!rig.capture.isRunning)

        let rigged = InputRig()
        let attached = try await Attachment(rigged.source)
        try attached.session.start()
        rigged.postInterruptionBegan()
        #expect(await attached.session.reaches(.interrupted))
        let broken = DSPError.sourceUnavailable(reason: "the engine does not start")
        rigged.capture.fail(.start, with: broken)
        rigged.postInterruptionEnded(shouldResume: true)
        #expect(await attached.session.reaches(.failed(broken)))
    }

    @Test func aFormatThatChangedDuringTheInterruptionIsAdoptedBeforeTheSourceResumes() async throws {
        let (rig, log) = try await started()
        rig.postInterruptionBegan()
        let other = SignalFormat(sampleRate: 16_000, channelCount: 1)
        rig.capture.setFormat(other)
        rig.postInterruptionEnded(shouldResume: true)
        #expect(await log.shows([.interrupted, .formatChanged(other), .resumed]), "the engine re-plans first, then resumes")
        #expect(rig.source.format == other)
        #expect(rig.capture.calls == [.stop, .stop, .setRing(nil), .disconnect, .connect, .start])
    }

    /// Before iOS 16 an app that was suspended is told so when it comes back, as an
    /// interruption that began, and no end follows. The source does not wait for one.
    @Test func anAppThatComesBackFromSuspensionResumesAtOnce() async throws {
        let (rig, log) = try await started()
        rig.session.deactivateBySystem()
        rig.notifications.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue, AVAudioSessionInterruptionReasonKey: UInt(1)])
        rig.source.settle()
        #expect(await log.shows([.interrupted, .resumed]), "the stages start cold; nothing waits for an end that never comes")
        #expect(rig.capture.calls == [.stop, .start] && rig.capture.isRunning)
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)] && rig.session.isActive, "the session the suspension deactivated is activated again")

        // A source that was not delivering has nothing to resume; its next start activates the session.
        let idle = InputRig()
        let idleLog = SourceLog(idle.source)
        try await idle.source.prepare()
        idle.session.forgetCalls()
        idle.notifications.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue, AVAudioSessionInterruptionReasonKey: UInt(1)])
        idle.source.settle()
        await pause()
        #expect(idleLog.all.isEmpty && idle.session.calls.isEmpty)
        try idle.source.start()
        #expect(idle.session.calls == [.setActive(true, notifyingOthers: false)])
    }

    // MARK: Row 3: it ended without

    @Test func anInterruptionThatEndsWithoutShouldResumeStaysStoppedUntilTheHostStartsAgain() async throws {
        let rig = InputRig()
        let attached = try await Attachment(rig.source)
        try attached.session.start()
        rig.postInterruptionBegan()
        rig.session.deactivateBySystem()
        #expect(await attached.session.reaches(.interrupted))
        rig.session.forgetCalls()
        rig.capture.forgetCalls()

        rig.postInterruptionEnded(shouldResume: false)
        await pause()
        #expect(attached.session.state == .interrupted && rig.capture.calls.isEmpty && rig.session.calls.isEmpty, "no event, no restart")
        #expect(!rig.capture.isRunning)

        // The host decides: it stops the session and starts it.
        attached.session.stop()
        try attached.session.start()
        #expect(attached.session.state == .running && rig.capture.isRunning)
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)], "the start activates the session the interruption deactivated")
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 })
        attached.session.detach()
    }

    // MARK: A source that does not deliver

    @Test func anInterruptionOfASourceThatIsNotStartedIsNoEvent() async throws {
        let rig = InputRig()
        let log = SourceLog(rig.source)
        rig.postInterruptionBegan()
        try await rig.source.prepare()
        rig.session.forgetCalls()
        rig.capture.forgetCalls()
        rig.postInterruptionBegan()
        rig.postInterruptionEnded(shouldResume: true)
        await pause()
        #expect(log.all.isEmpty && rig.capture.calls.isEmpty)
        // The session was deactivated by the interruption all the same: the start activates it.
        try rig.source.start()
        #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)])
    }

    @Test func aSourceThatIsReleasedStopsListening() async throws {
        let notifications = NotificationCenter()
        let capture: FakeCapture
        do {
            let rig = InputRig(notifications: notifications)
            try await rig.source.prepare()
            try rig.source.start()
            capture = rig.capture
            capture.forgetCalls()
        }
        #expect(capture.calls == [.stop], "a source that is let go stops its engine")
        notifications.post(name: AVAudioSession.interruptionNotification, object: nil,
                           userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await pause()
        #expect(capture.calls == [.stop])
    }
}
