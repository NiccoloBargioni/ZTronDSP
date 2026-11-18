import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// Hot-plug of an external microphone (WP-711, MIC-4): injected route changes while a session
/// runs.
@Suite("Hot-plug")
struct HotPlugTests {
    typealias Call = FakeAudioSession.Call

    let builtIn = FakeAudioSession.builtIn, usb = FakeAudioSession.usb
    let builtInFormat = SignalFormat(sampleRate: 48_000, channelCount: 1)
    let usbFormat = SignalFormat(sampleRate: 44_100, channelCount: 2)
    let block = [Float](repeating: 0.5, count: 64)

    private func selections(_ session: FakeAudioSession) -> [Call] {
        session.calls.filter {
            switch $0 {
            case .setPreferredInput, .setPreferredDataSource: true
            default: false
            }
        }
    }

    @Test func aLostInputFallsBackToTheSystemsChoiceAndItsReturnRestoresTheSelection() async throws {
        let rig = InputRig(input: usb, session: FakeAudioSession(inputs: [builtIn, usb]), format: usbFormat)
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        try rig.source.start()
        rig.session.forgetCalls()

        // Unplugged.
        rig.session.disconnect(usb)
        rig.capture.setFormat(builtInFormat)
        rig.postRouteChange(.oldDeviceUnavailable)
        #expect(await log.shows([.routeChanged(.inputLost), .formatChanged(builtInFormat)]))
        #expect(selections(rig.session) == [.setPreferredInput(nil)], "back to the system's choice")
        #expect(rig.session.currentInput == builtIn && rig.capture.isRunning && rig.source.format == builtInFormat)

        // Something else about the route: the input is still lost, and that is not news.
        rig.postRouteChange(.override)
        #expect(await log.shows([.routeChanged(.inputLost), .formatChanged(builtInFormat), .routeChanged(.other)]))

        // Plugged back.
        rig.session.forgetCalls()
        rig.session.connect(usb)
        rig.capture.setFormat(usbFormat)
        rig.postRouteChange(.newDeviceAvailable)
        #expect(await log.shows([
            .routeChanged(.inputLost), .formatChanged(builtInFormat), .routeChanged(.other),
            .routeChanged(.inputRestored), .formatChanged(usbFormat),
        ]))
        #expect(selections(rig.session) == [.setPreferredInput("usb-1")], "it is selected again")
        #expect(rig.session.currentInput == usb && rig.capture.isRunning && rig.source.format == usbFormat)
    }

    @Test func theSessionSurvivesBoth() async throws {
        let rig = InputRig(input: usb, session: FakeAudioSession(inputs: [builtIn, usb]), format: usbFormat)
        let attached = try await Attachment(rig.source)
        try attached.session.start()
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 && attached.sink.channelCount == 2 })

        rig.session.disconnect(usb)
        rig.capture.setFormat(builtInFormat)
        rig.postRouteChange(.oldDeviceUnavailable)
        #expect(await eventually { attached.log.count(of: .replanned(.formatChanged)) == 1 && rig.capture.ringChannelCount == 1 })
        #expect(attached.session.state == .running && attached.session.environment.sampleRate == 48_000)
        rig.capture.deliver(block + block)
        #expect(await eventually { attached.sink.frameCount == 128 && attached.sink.channelCount == 1 }, "the built-in microphone is recorded from")

        rig.session.connect(usb)
        rig.capture.setFormat(usbFormat)
        rig.postRouteChange(.newDeviceAvailable)
        #expect(await eventually { attached.log.count(of: .replanned(.formatChanged)) == 2 && rig.capture.ringChannelCount == 2 })
        #expect(attached.session.state == .running && attached.session.environment.sampleRate == 44_100)
        rig.capture.deliver(block)
        #expect(await eventually { attached.sink.frameCount == 64 && attached.sink.channelCount == 2 }, "and the USB interface again")
        await pause()
        #expect(attached.log.states == [.running], "the session ran through both: it was neither interrupted nor failed")
        attached.session.detach()
    }

    @Test func aDataSourceIsRestoredWithItsInput() async throws {
        let rig = InputRig(input: builtIn, dataSource: "Front", session: FakeAudioSession(inputs: [builtIn]))
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        rig.session.disconnect(builtIn)
        rig.session.connect(usb)
        rig.postRouteChange(.oldDeviceUnavailable)
        rig.session.forgetCalls()
        rig.session.connect(builtIn)
        rig.postRouteChange(.newDeviceAvailable)
        #expect(await log.shows([.routeChanged(.inputLost), .routeChanged(.inputRestored)]))
        #expect(selections(rig.session) == [.setPreferredInput("built-in"), .setPreferredDataSource("Front", input: "built-in")])
    }

    @Test func anInputThatCannotBeSelectedOnItsReturnIsAskedForAgainAtTheNextRouteChange() async throws {
        let rig = InputRig(input: usb, session: FakeAudioSession(inputs: [builtIn, usb]))
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        rig.session.disconnect(usb)
        rig.postRouteChange(.oldDeviceUnavailable)
        rig.session.connect(usb)
        rig.session.fail(.setPreferredInput, with: .sessionConfigurationFailed(reason: "not yet"))
        rig.postRouteChange(.newDeviceAvailable)
        #expect(await log.shows([.routeChanged(.inputLost), .routeChanged(.inputChanged)]), "the system changed the input; the selection is not restored yet")
        rig.session.fail(.setPreferredInput, with: nil)
        rig.postRouteChange(.routeConfigurationChange)
        #expect(await log.shows([.routeChanged(.inputLost), .routeChanged(.inputChanged), .routeChanged(.inputRestored)]))
    }

    /// MIC-1: without a requested input the source follows the system, and says when the
    /// system chose another input.
    @Test func withoutARequestedInputTheSourceFollowsTheSystem() async throws {
        let rig = InputRig(session: FakeAudioSession(inputs: [builtIn]))
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        rig.session.connect(usb)
        rig.postRouteChange(.newDeviceAvailable)
        rig.postRouteChange(.categoryChange)
        rig.session.disconnect(usb)
        rig.postRouteChange(.oldDeviceUnavailable)
        #expect(await log.shows([.routeChanged(.inputChanged), .routeChanged(.other), .routeChanged(.inputChanged)]))
        #expect(selections(rig.session).isEmpty, "the choice stays the system's")
    }

    @Test func underExternalTheSourceReportsAndSelectsNothing() async throws {
        let session = FakeAudioSession(category: .playAndRecord, inputs: [builtIn, usb])
        let rig = InputRig(input: usb, policy: .external, session: session)
        let log = SourceLog(rig.source)
        try await rig.source.prepare()
        session.disconnect(usb)
        rig.postRouteChange(.oldDeviceUnavailable)
        // It is back when the session records from it again, which under `.external` is the app's doing.
        session.connect(usb)
        try session.setPreferredInput(builtIn)
        session.forgetCalls()
        rig.postRouteChange(.newDeviceAvailable)
        #expect(await log.shows([.routeChanged(.inputLost), .routeChanged(.other)]), "connected, but not the session's input: not restored")
        try session.setPreferredInput(usb)
        session.forgetCalls()
        rig.postRouteChange(.override)
        #expect(await log.shows([.routeChanged(.inputLost), .routeChanged(.other), .routeChanged(.inputRestored)]))
        #expect(session.calls.isEmpty, ".external never mutates the session")
    }
}
