import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// Capture while the app plays (R-22, WP-708): the two cases of §4.6, driven through the
/// seams. The app's playback is the state of a session the test holds: its category and
/// options, whether it is active, the output it plays on, and the notifications a change of
/// category makes iOS post. What only a device can show, that the app's player kept
/// rendering, is not asserted here; the run on a device is a separate record.
@Suite("Capture while playing")
struct CaptureWhilePlayingTests {
    typealias Call = FakeAudioSession.Call

    let block = [Float](repeating: 0.25, count: 64)

    /// What the system posted, counted on the notification centre the session and the source
    /// share.
    final class Posted: Sendable {
        private let counts = Shared<[Notification.Name: Int]>([:])
        private let tokens = Shared<[any NSObjectProtocol]>([])

        init(_ notifications: NotificationCenter) {
            let names: [Notification.Name] = [
                AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange,
            ]
            let counts = counts
            tokens.set(names.map { name in
                notifications.addObserver(forName: name, object: nil, queue: nil) { _ in
                    counts.withLock { $0[name, default: 0] += 1 }
                }
            })
        }

        func count(_ name: Notification.Name) -> Int { counts.withLock { $0[name, default: 0] } }
    }

    /// The app is playing: its session is active, on the speaker, under `category`.
    private func playing(_ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions = []) throws -> (InputRig, Posted) {
        let notifications = NotificationCenter()
        let session = FakeAudioSession(category: category, options: options, notifications: notifications)
        try session.setActive(true, options: [])
        session.forgetCalls()
        let rig = InputRig(session: session, notifications: notifications)
        return (rig, Posted(notifications))
    }

    private func capture(_ rig: InputRig) async throws -> Attachment {
        let attached = try await Attachment(rig.source)
        try attached.session.start()
        rig.capture.deliver(block + block)
        #expect(await eventually { attached.sink.frameCount == 128 }, "frames arrived")
        return attached
    }

    // MARK: Case A: the app's session already permits input

    @Test func caseANothingIsReconfigured() async throws {
        for options in [AVAudioSession.CategoryOptions(), [.defaultToSpeaker], [.mixWithOthers, .allowBluetoothA2DP]] {
            let (rig, posted) = try playing(.playAndRecord, options: options)
            let attached = try await capture(rig)
            rig.source.settle()

            #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)], "the only call is the activation of a session that is active already")
            #expect(rig.session.category == .playAndRecord && rig.session.categoryOptions == options && rig.session.mode == .default,
                    "category, mode and options are the app's, whatever they are (CAP-3)")
            #expect(rig.session.isActive && rig.session.output == "Speaker", "playback stays where it was")
            #expect(posted.count(AVAudioSession.interruptionNotification) == 0, "no interruption")
            #expect(posted.count(AVAudioSession.routeChangeNotification) == 0 && rig.session.routeChangesPosted == 0, "no route change")
            #expect(posted.count(.AVAudioEngineConfigurationChange) == 0, "no configuration change")
            #expect(attached.session.state == .running && attached.sink.samples() == block + block)

            // Stopping the capture leaves the app's session as it was, too.
            attached.session.stop()
            attached.session.detach()
            #expect(rig.session.calls == [.setActive(true, notifyingOthers: false)] && rig.session.isActive, "setActive(false) is never called (CAP-4)")
        }
    }

    // MARK: Case B: the app's session does not permit input

    @Test(arguments: [AVAudioSession.Category.playback, .ambient, .soloAmbient])
    func caseBTheCategoryIsChangedOnceAndPlaybackStaysOnItsOutput(category: AVAudioSession.Category) async throws {
        let (rig, posted) = try playing(category)
        let attached = try await capture(rig)
        rig.source.settle()

        let changes = rig.session.calls.filter { if case .setCategory = $0 { true } else { false } }
        #expect(changes == [.setCategory(.playAndRecord, .default, [.defaultToSpeaker, .allowBluetoothA2DP])],
                "one category change, to play and record, never to record (CAP-1), with the options that keep playback where it was (CAP-2)")
        #expect(rig.session.output == "Speaker", "the same output port: play and record alone would have moved playback to the receiver")
        #expect(rig.session.isActive && !rig.session.calls.contains(.setActive(false, notifyingOthers: true)) && !rig.session.calls.contains(.setActive(false, notifyingOthers: false)))
        #expect(posted.count(AVAudioSession.interruptionNotification) == 0, "no interruption")
        #expect(posted.count(AVAudioSession.routeChangeNotification) == 1 && rig.session.routeChangesPosted == 1,
                "the one change of route the category change brings: at most one configuration change for the app's player")
        #expect(posted.count(.AVAudioEngineConfigurationChange) == 0 && posted.count(AVAudioSession.mediaServicesWereResetNotification) == 0)
        #expect(attached.session.state == .running, "the source took its own change of route in its stride")

        // Capture goes on after the change of route, and nothing changes the category a second time.
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 192 })
        attached.session.stop()
        try attached.session.start()
        let again = try await Attachment(HardwareInputSource(
            input: nil, dataSource: nil, policy: .measurement, voiceProcessing: false, session: rig.session,
            authorizer: FakeAuthorizer(), capture: FakeCapture(), notifications: rig.notifications))
        try again.session.start()
        #expect(rig.session.calls.filter { if case .setCategory = $0 { true } else { false } }.count == 1, "the change is made once (CAP-3 from then on)")
        #expect(rig.session.routeChangesPosted == 1 && rig.session.output == "Speaker")
        attached.session.detach()
        again.session.detach()
    }

    /// The same, when the capture is asked to leave other apps' audio alone and to give the
    /// session back: only what the policy says is added.
    @Test func caseBWithAPolicyThatMixesAndDeactivates() async throws {
        let notifications = NotificationCenter()
        let session = FakeAudioSession(category: .playback, notifications: notifications)
        let rig = InputRig(policy: .playAndRecord.mixingWithOthers().deactivatingOnStop(), session: session, notifications: notifications)
        let attached = try await capture(rig)
        #expect(session.calls == [
            .setCategory(.playAndRecord, .default, [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]), .allowHaptics(true),
            .setActive(true, notifyingOthers: false),
        ])
        attached.session.stop()
        #expect(session.calls.last == .setActive(false, notifyingOthers: true) && !session.isActive, "deactivated because the policy says so, telling others")
        attached.session.detach()
    }

    /// Under `.external` the app has configured play and record before it started playback,
    /// which is what the documentation tells every app to do: case A, with nothing touched at
    /// all.
    @Test func underExternalTheSessionIsNotEvenActivated() async throws {
        let (rig, posted) = try playing(.playAndRecord, options: [.defaultToSpeaker])
        let source = HardwareInputSource(
            input: nil, dataSource: nil, policy: .external, voiceProcessing: false, session: rig.session,
            authorizer: FakeAuthorizer(), capture: rig.capture, notifications: rig.notifications)
        let attached = try await Attachment(source)
        try attached.session.start()
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 })
        attached.session.stop()
        attached.session.detach()
        #expect(rig.session.calls.isEmpty && rig.session.isActive && rig.session.output == "Speaker")
        #expect(posted.count(AVAudioSession.routeChangeNotification) == 0 && posted.count(AVAudioSession.interruptionNotification) == 0)

        // And an app that plays under a category without input is told so, not reconfigured.
        let (playback, _) = try playing(.playback)
        let refused = HardwareInputSource(
            input: nil, dataSource: nil, policy: .external, voiceProcessing: false, session: playback.session,
            authorizer: FakeAuthorizer(), capture: playback.capture, notifications: playback.notifications)
        await #expect(throws: DSPError.self) { try await refused.prepare() }
        #expect(playback.session.calls.isEmpty && playback.session.category == .playback)
    }
}
