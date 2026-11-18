import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// The audio-session rules CAP-1…CAP-7, each through a session the test holds (WP-701), and
/// the Bluetooth options of MIC-5 (WP-712).
@Suite("Audio session policy")
struct AudioSessionPolicyTests {
    typealias Call = FakeAudioSession.Call

    /// What the package sets when it sets the category itself (CAP-2).
    let basicOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]

    // MARK: CAP-1, CAP-2, CAP-5: what each policy sets

    @Test func playAndRecordSetsTheCategoryTheDefaultModeAndTheOptionsThatKeepPlaybackWhereItWas() throws {
        for category in [AVAudioSession.Category.soloAmbient, .ambient, .playback] {
            let session = FakeAudioSession(category: category)
            try AudioSessionPolicy.playAndRecord.configure(session)
            #expect(session.calls == [.setCategory(.playAndRecord, .default, basicOptions), .allowHaptics(true)], "from \(category.rawValue)")
            #expect(session.category == .playAndRecord && session.mode == .default && session.categoryOptions == basicOptions)
            #expect(session.allowsHaptics, "recording does not mute the app's haptics and system sounds (CAP-5)")
            #expect(!session.isActive, "configuring does not activate")
        }
    }

    @Test func measurementIsTheSameWithTheMeasurementMode() throws {
        let session = FakeAudioSession(category: .playback)
        try AudioSessionPolicy.measurement.configure(session)
        #expect(session.calls == [.setCategory(.playAndRecord, .measurement, basicOptions), .allowHaptics(true)])
    }

    @Test func recordIsNeverUsed() throws {
        // CAP-1: whatever the policy and whatever it is asked for, the category it sets is play and record.
        var policies: [AudioSessionPolicy] = [
            .playAndRecord, .measurement, .playAndRecord.mixingWithOthers(), .measurement.allowingBluetoothHandsFree().deactivatingOnStop(),
        ]
        if #available(iOS 26.0, *) { policies.append(.playAndRecord.allowingHighQualityBluetoothRecording()) }
        for policy in policies {
            let session = FakeAudioSession(category: .ambient)
            try policy.configure(session)
            let categories = session.calls.compactMap { call -> AVAudioSession.Category? in
                if case .setCategory(let category, _, _) = call { category } else { nil }
            }
            #expect(categories == [.playAndRecord])
        }
    }

    @Test func mixingAndHandsFreeAreAddedOnlyWhenThePolicyAsks() throws {
        func options(_ policy: AudioSessionPolicy) throws -> AVAudioSession.CategoryOptions {
            let session = FakeAudioSession(category: .playback)
            try policy.configure(session)
            return session.categoryOptions
        }
        #expect(try options(.playAndRecord) == basicOptions)
        #expect(try options(.playAndRecord.mixingWithOthers()) == basicOptions.union(.mixWithOthers))
        #expect(try options(.playAndRecord.allowingBluetoothHandsFree()) == basicOptions.union(.allowBluetoothHFP))
        #expect(try options(.measurement.mixingWithOthers().allowingBluetoothHandsFree()) == basicOptions.union([.mixWithOthers, .allowBluetoothHFP]))
        #expect(try options(.playAndRecord.deactivatingOnStop()) == basicOptions, "deactivating on stop is not a category option")
        // The modifiers are independent and may come in any order.
        #expect(try options(.playAndRecord.allowingBluetoothHandsFree().mixingWithOthers().deactivatingOnStop())
            == options(.playAndRecord.deactivatingOnStop().mixingWithOthers().allowingBluetoothHandsFree()))
    }

    /// WP-712: high-quality Bluetooth recording exists from iOS 26; the option is present only
    /// when the policy asks for it.
    @Test func highQualityBluetoothRecordingIsAnOptionOfItsOwn() throws {
        guard #available(iOS 26.0, *) else { return }
        let session = FakeAudioSession(category: .playback)
        try AudioSessionPolicy.playAndRecord.allowingHighQualityBluetoothRecording().configure(session)
        #expect(session.categoryOptions == basicOptions.union(.bluetoothHighQualityRecording), "alone: no hands-free fall-back")
        let both = FakeAudioSession(category: .playback)
        try AudioSessionPolicy.playAndRecord.allowingBluetoothHandsFree().allowingHighQualityBluetoothRecording().mixingWithOthers().configure(both)
        #expect(both.categoryOptions == basicOptions.union([.allowBluetoothHFP, .bluetoothHighQualityRecording, .mixWithOthers]))
        #expect(!AudioSessionPolicy.playAndRecord.allowingBluetoothHandsFree().categoryOptions.contains(.bluetoothHighQualityRecording))
        #expect(!AudioSessionPolicy.playAndRecord.categoryOptions.contains(.allowBluetoothHFP))
    }

    @Test func aRefusedCategoryIsASessionConfigurationFailure() {
        let session = FakeAudioSession(category: .playback)
        let refusal = DSPError.sessionConfigurationFailed(reason: "refused")
        session.fail(.setCategory, with: refusal)
        #expect(throws: refusal) { try AudioSessionPolicy.playAndRecord.configure(session) }
        #expect(session.category == .playback)
    }

    @Test func captureGoesOnWhenHapticsCannotBeAllowed() throws {
        let session = FakeAudioSession(category: .playback)
        session.fail(.allowHaptics, with: .sessionConfigurationFailed(reason: "no haptics"))
        try AudioSessionPolicy.playAndRecord.configure(session)
        #expect(session.category == .playAndRecord && !session.allowsHaptics)
    }

    // MARK: CAP-3: a session that already permits input is left untouched

    @Test func aSessionThatAlreadyPermitsInputIsLeftUntouched() throws {
        var policies: [AudioSessionPolicy] = [
            .playAndRecord, .measurement, .playAndRecord.mixingWithOthers().allowingBluetoothHandsFree(), .measurement.deactivatingOnStop(),
        ]
        if #available(iOS 26.0, *) { policies.append(.playAndRecord.allowingHighQualityBluetoothRecording()) }
        for category in [AVAudioSession.Category.playAndRecord, .record, .multiRoute] {
            // Whatever its options: none, or ones the policy would not have chosen.
            for options in [AVAudioSession.CategoryOptions(), [.duckOthers], [.allowBluetoothHFP, .mixWithOthers]] {
                for policy in policies {
                    let session = FakeAudioSession(category: category, options: options)
                    try policy.configure(session)
                    #expect(session.calls.isEmpty, "\(category.rawValue) with \(options.rawValue)")
                    #expect(session.category == category && session.categoryOptions == options && session.mode == .default && !session.allowsHaptics)
                }
            }
        }
        #expect(AudioSessionPolicy.permitsInput(.playAndRecord) && AudioSessionPolicy.permitsInput(.record) && AudioSessionPolicy.permitsInput(.multiRoute))
        for category in [AVAudioSession.Category.ambient, .soloAmbient, .playback] {
            #expect(!AudioSessionPolicy.permitsInput(category), "\(category.rawValue) does not permit input")
        }
    }

    // MARK: CAP-4: activation

    @Test func theSessionIsActivatedAndDeactivatedOnlyWhenThePolicySaysSo() throws {
        let session = FakeAudioSession(category: .playAndRecord)
        try AudioSessionPolicy.playAndRecord.activate(session)
        #expect(session.calls == [.setActive(true, notifyingOthers: false)] && session.isActive)
        session.forgetCalls()
        #expect(!AudioSessionPolicy.playAndRecord.deactivateIfAsked(session))
        #expect(!AudioSessionPolicy.measurement.mixingWithOthers().deactivateIfAsked(session))
        #expect(session.calls.isEmpty && session.isActive, "the package never deactivates the session unasked")
        #expect(AudioSessionPolicy.playAndRecord.deactivatingOnStop().deactivateIfAsked(session))
        #expect(session.calls == [.setActive(false, notifyingOthers: true)] && !session.isActive, "and when asked, it tells other apps")
        #expect(AudioSessionPolicy.custom { _ in }.deactivatingOnStop().deactivateIfAsked(session), "a custom policy may ask too")
    }

    @Test func aSessionThatCannotBeDeactivatedStaysActive() {
        let session = FakeAudioSession(category: .playAndRecord)
        session.fail(.setActive, with: .sessionConfigurationFailed(reason: "the app is playing"))
        #expect(!AudioSessionPolicy.playAndRecord.deactivatingOnStop().deactivateIfAsked(session))
        #expect(throws: DSPError.sessionConfigurationFailed(reason: "the app is playing")) { try AudioSessionPolicy.playAndRecord.activate(session) }
    }

    // MARK: CAP-7: the app owns the session

    @Test func externalNeverMutatesTheSession() throws {
        for category in [AVAudioSession.Category.playAndRecord, .record, .multiRoute] {
            let session = FakeAudioSession(category: category)
            // Every modifier at once: none of them has an effect on a session the app owns.
            let policy = AudioSessionPolicy.external.mixingWithOthers().allowingBluetoothHandsFree().deactivatingOnStop()
            try policy.configure(session)
            try policy.activate(session)
            #expect(!policy.deactivateIfAsked(session))
            #expect(session.calls.isEmpty && !session.isActive, "\(category.rawValue)")
            #expect(!policy.changesSession && AudioSessionPolicy.playAndRecord.changesSession && AudioSessionPolicy.custom { _ in }.changesSession)
        }
    }

    @Test func externalNamesTheCategoryThatDoesNotPermitInput() {
        for category in [AVAudioSession.Category.playback, .ambient, .soloAmbient] {
            let session = FakeAudioSession(category: category)
            do throws(DSPError) {
                try AudioSessionPolicy.external.configure(session)
                Issue.record("\(category.rawValue) permits no input")
            } catch {
                guard case .sessionConfigurationFailed(let reason) = error else {
                    Issue.record("expected sessionConfigurationFailed, got \(error)")
                    continue
                }
                #expect(reason.contains(category.rawValue), "the error names the category it found: \(reason)")
            }
            #expect(session.calls.isEmpty, "and the session is as it was")
        }
    }

    // MARK: Custom

    @Test func aCustomPolicyConfiguresTheSessionItself() throws {
        let session = FakeAudioSession(category: .playback)
        let policy = AudioSessionPolicy.custom { session in
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.duckOthers])
        }
        // The modifiers for category options describe a category the package sets; here it sets none.
        try policy.mixingWithOthers().allowingBluetoothHandsFree().configure(session)
        #expect(session.calls == [.setCategory(.playAndRecord, .videoRecording, [.duckOthers])], "the closure's configuration, and nothing added to it")
        try policy.activate(session)
        #expect(session.isActive, "the package activates a session a custom policy configured (CAP-4)")

        // It runs again each time, also when the category already permits input: it is the app's configuration.
        try policy.configure(session)
        #expect(session.calls.filter { if case .setCategory = $0 { true } else { false } }.count == 2)
    }

    @Test func aCustomPolicyThatLeavesTheSessionWithoutInputFails() {
        let session = FakeAudioSession(category: .ambient)
        #expect(throws: DSPError.self) { try AudioSessionPolicy.custom { _ in }.configure(session) }
        struct Refusal: Error {}
        let failing = AudioSessionPolicy.custom { _ in throw Refusal() }
        do throws(DSPError) {
            try failing.configure(FakeAudioSession(category: .playAndRecord))
            Issue.record("the closure threw")
        } catch {
            guard case .sessionConfigurationFailed = error else {
                Issue.record("an error of the closure becomes sessionConfigurationFailed, not \(error)")
                return
            }
        }
        // An error of the package's own kind passes through as it is.
        let typed = AudioSessionPolicy.custom { session in try session.setCategory(.record, mode: .default, options: []) }
        let refusing = FakeAudioSession(category: .ambient)
        refusing.fail(.setCategory, with: .sessionConfigurationFailed(reason: "refused"))
        #expect(throws: DSPError.sessionConfigurationFailed(reason: "refused")) { try typed.configure(refusing) }
    }

    @Test func portsBecomeInputKinds() {
        #expect(AudioInput.Kind(port: .builtInMic) == .builtIn)
        #expect(AudioInput.Kind(port: .headsetMic) == .wired && AudioInput.Kind(port: .lineIn) == .wired)
        #expect(AudioInput.Kind(port: .usbAudio) == .usb)
        #expect(AudioInput.Kind(port: .bluetoothHFP) == .bluetooth && AudioInput.Kind(port: .bluetoothLE) == .bluetooth)
        #expect(AudioInput.Kind(port: .carAudio) == .other && AudioInput.Kind(port: .builtInSpeaker) == .other)
        if #available(iOS 17.0, *) { #expect(AudioInput.Kind(port: .continuityMicrophone) == .continuity) }
        let input = AudioInput(id: "a", name: "A", kind: .usb, dataSources: ["x"])
        #expect(input == AudioInput(id: "a", name: "A", kind: .usb, dataSources: ["x"]) && input != AudioInput(id: "a", name: "A", kind: .usb))
        #expect(input.id == "a" && Set([input, input]).count == 1)
    }
}
