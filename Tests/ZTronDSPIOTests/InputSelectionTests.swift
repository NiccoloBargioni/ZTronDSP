import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// `AudioInput` and input selection (WP-710, MIC-1…MIC-3, MIC-6) and the Bluetooth opt-in
/// (WP-712, MIC-5), through a session the test holds.
@Suite("Input selection")
struct InputSelectionTests {
    typealias Call = FakeAudioSession.Call

    let builtIn = FakeAudioSession.builtIn, usb = FakeAudioSession.usb, headset = FakeAudioSession.headset, handsFree = FakeAudioSession.handsFree

    /// The calls that select an input or a data source.
    private func selections(_ session: FakeAudioSession) -> [Call] {
        session.calls.filter {
            switch $0 {
            case .setPreferredInput, .setPreferredDataSource: true
            default: false
            }
        }
    }

    // MARK: MIC-3: what the session offers

    @Test func theInputsOfTheSessionAreListed() throws {
        let session = FakeAudioSession(inputs: [builtIn, headset, usb])
        let inputs = try HardwareInputSource.inputs(offeredBy: session, under: .playAndRecord)
        #expect(inputs == [builtIn, headset, usb])
        #expect(inputs[0].dataSources == ["Bottom", "Front", "Back"] && inputs[0].kind == .builtIn && inputs[2].kind == .usb)
        #expect(session.calls == [.setCategory(.playAndRecord, .default, [.defaultToSpeaker, .allowBluetoothA2DP]), .allowHaptics(true)],
                "the category is brought to where the policy wants it, and the session is not activated")
    }

    @Test func bluetoothMicrophonesAppearOnlyUnderAPolicyThatAllowsHandsFree() throws {
        func listed(_ policy: AudioSessionPolicy, session: FakeAudioSession) throws -> [AudioInput] {
            try HardwareInputSource.inputs(offeredBy: session, under: policy)
        }
        let inputs = [builtIn, handsFree]
        #expect(try listed(.playAndRecord, session: FakeAudioSession(inputs: inputs)) == [builtIn])
        #expect(try listed(.measurement.mixingWithOthers(), session: FakeAudioSession(inputs: inputs)) == [builtIn])
        #expect(try listed(.playAndRecord.allowingBluetoothHandsFree(), session: FakeAudioSession(inputs: inputs)) == [builtIn, handsFree])
        if #available(iOS 26.0, *) {
            #expect(try listed(.playAndRecord.allowingHighQualityBluetoothRecording(), session: FakeAudioSession(inputs: inputs)) == [builtIn, handsFree])
        }
        // The app's own session, left untouched (CAP-3), routes hands-free: the policy still decides.
        let appSession = FakeAudioSession(category: .playAndRecord, options: [.allowBluetoothHFP], inputs: inputs)
        #expect(try listed(.playAndRecord, session: appSession) == [builtIn] && appSession.calls.isEmpty)
        #expect(try listed(.playAndRecord.allowingBluetoothHandsFree(), session: appSession) == [builtIn, handsFree])
        // Under a session the app owns or configures, the list is the session's.
        #expect(try listed(.external, session: appSession) == [builtIn, handsFree])
        #expect(try listed(.custom { _ in }, session: appSession) == [builtIn, handsFree])
    }

    @Test func aSessionThatPermitsNoInputListsNothingUnderExternal() {
        let session = FakeAudioSession(category: .playback, inputs: [builtIn])
        #expect(throws: DSPError.self) { _ = try HardwareInputSource.inputs(offeredBy: session, under: .external) }
        #expect(session.calls.isEmpty)
    }

    // MARK: MIC-1: without an input, iOS chooses

    @Test func withoutAnInputTheSourceRecordsFromWhateverTheSystemSelected() async throws {
        let rig = InputRig(session: FakeAudioSession(inputs: [builtIn, usb]))
        try await rig.source.prepare()
        #expect(selections(rig.session).isEmpty, "no preference is set: the choice is the system's")
        #expect(rig.session.currentInput == usb, "which is the last external microphone connected")
    }

    // MARK: MIC-2: a requested input becomes the preferred one

    @Test func aRequestedInputBecomesThePreferredInput() async throws {
        let rig = InputRig(input: builtIn, session: FakeAudioSession(inputs: [builtIn, usb]))
        try await rig.source.prepare()
        #expect(selections(rig.session) == [.setPreferredInput("built-in")])
        #expect(rig.session.currentInput == builtIn, "instead of the system's choice, the USB interface")
        let calls = rig.session.calls
        #expect(calls.firstIndex(of: .setActive(true, notifyingOthers: false))! < calls.firstIndex(of: .setPreferredInput("built-in"))!,
                "the preference is set on the configured, active session")
    }

    @Test func aRequestedDataSourceBecomesThePreferredDataSource() async throws {
        let rig = InputRig(input: builtIn, dataSource: "Front", session: FakeAudioSession(inputs: [builtIn]))
        try await rig.source.prepare()
        #expect(selections(rig.session) == [.setPreferredInput("built-in"), .setPreferredDataSource("Front", input: "built-in")])
        #expect(rig.session.preferredDataSources == ["built-in": "Front"])
    }

    @Test func aDataSourceWithoutAnInputAppliesToTheInputTheSystemSelected() async throws {
        let rig = InputRig(dataSource: "Back", session: FakeAudioSession(inputs: [builtIn]))
        try await rig.source.prepare()
        #expect(selections(rig.session) == [.setPreferredDataSource("Back", input: "built-in")])

        let none = InputRig(dataSource: "Back", session: FakeAudioSession(inputs: []))
        await #expect(throws: DSPError.sourceUnavailable(reason: "no audio input is available")) { try await none.source.prepare() }
        let other = InputRig(dataSource: "Back", session: FakeAudioSession(inputs: [builtIn, usb]))
        await #expect(throws: DSPError.sourceUnavailable(reason: "the input USB Interface has no data source named Back")) { try await other.source.prepare() }
    }

    @Test func anAbsentInputIsSourceUnavailable() async {
        let rig = InputRig(input: usb, session: FakeAudioSession(inputs: [builtIn]))
        await #expect(throws: DSPError.sourceUnavailable(reason: "the input USB Interface is not available")) { try await rig.source.prepare() }
        #expect(selections(rig.session).isEmpty && !rig.capture.calls.contains(.rebuild))

        let unknown = InputRig(input: builtIn, dataSource: "Top", session: FakeAudioSession(inputs: [builtIn]))
        await #expect(throws: DSPError.sourceUnavailable(reason: "the input iPhone Microphone has no data source named Top")) { try await unknown.source.prepare() }
        #expect(selections(unknown.session).isEmpty, "nothing is selected when half of the selection cannot be made")
        await #expect(throws: DSPError.self) { try await DSPEngine(blockSize: 64).attach(Pipeline(), to: rig.source) }
    }

    @Test func aSelectionTheSessionRefusesFailsThePreparation() async {
        let rig = InputRig(input: usb, session: FakeAudioSession(inputs: [builtIn, usb]))
        rig.session.fail(.setPreferredInput, with: .sessionConfigurationFailed(reason: "refused"))
        await #expect(throws: DSPError.sessionConfigurationFailed(reason: "refused")) { try await rig.source.prepare() }
    }

    // MARK: Under a session the app owns

    @Test func underExternalNothingIsSelected() async throws {
        let session = FakeAudioSession(category: .playAndRecord, inputs: [builtIn, usb])
        let current = InputRig(input: usb, dataSource: "ignored", policy: .external, session: session)
        try await current.source.prepare()
        #expect(session.calls.isEmpty, "the input is the one the session records from: nothing to do, and nothing done")

        let other = InputRig(input: builtIn, policy: .external, session: session)
        do throws(DSPError) {
            try await other.source.prepare()
            Issue.record("the session records from the USB interface")
        } catch {
            guard case .sourceUnavailable(let reason) = error else {
                Issue.record("expected sourceUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("iPhone Microphone") && reason.contains(".external"))
        }
        #expect(session.calls.isEmpty, ".external never mutates the session")
    }

    // MARK: MIC-5: Bluetooth is opt-in

    @Test func aBluetoothMicrophoneNeedsAPolicyThatAllowsIt() async throws {
        // The app's session routes hands-free already; the source's policy did not ask for it.
        let session = FakeAudioSession(category: .playAndRecord, options: [.allowBluetoothHFP], inputs: [builtIn, handsFree])
        let unasked = InputRig(input: handsFree, session: session)
        do throws(DSPError) {
            try await unasked.source.prepare()
            Issue.record("hands-free input is opt-in")
        } catch {
            guard case .sourceUnavailable(let reason) = error else {
                Issue.record("expected sourceUnavailable, got \(error)")
                return
            }
            #expect(reason.contains("allowingBluetoothHandsFree"))
        }
        #expect(selections(session).isEmpty)

        let asked = InputRig(input: handsFree, policy: .playAndRecord.allowingBluetoothHandsFree(), session: FakeAudioSession(inputs: [builtIn, handsFree]))
        try await asked.source.prepare()
        #expect(asked.session.categoryOptions.contains(.allowBluetoothHFP))
        #expect(selections(asked.session) == [.setPreferredInput("hfp-1")] && asked.session.currentInput == handsFree)

        // Without the option the session does not even offer it.
        let hidden = InputRig(input: handsFree, session: FakeAudioSession(inputs: [builtIn, handsFree]))
        await #expect(throws: DSPError.sourceUnavailable(reason: "the input AirPods is not available")) { try await hidden.source.prepare() }
    }
}
