import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// The permission to record (WP-702): every state through a double of the user, and the two
/// interfaces of the system (E-16).
@Suite("Microphone authorization")
struct MicrophoneAuthorizationTests {
    @Test func aGrantedPermissionAsksNobody() async throws {
        let user = FakeAuthorizer(.granted)
        try await MicrophoneAccess.ensure(user)
        #expect(user.requests == 0)
    }

    @Test func aDeniedPermissionIsPermissionDeniedAndAsksNobody() async {
        let user = FakeAuthorizer(.denied, answer: true)
        await #expect(throws: DSPError.permissionDenied) { try await MicrophoneAccess.ensure(user) }
        #expect(user.requests == 0, "a user who said no is not asked again")
    }

    @Test func anUndeterminedPermissionAsksOnce() async throws {
        let agreeing = FakeAuthorizer(.undetermined, answer: true)
        try await MicrophoneAccess.ensure(agreeing)
        #expect(agreeing.requests == 1 && agreeing.permission == .granted)
        try await MicrophoneAccess.ensure(agreeing)
        #expect(agreeing.requests == 1, "and not again once they have answered")

        let refusing = FakeAuthorizer(.undetermined, answer: false)
        await #expect(throws: DSPError.permissionDenied) { try await MicrophoneAccess.ensure(refusing) }
        await #expect(throws: DSPError.permissionDenied) { try await MicrophoneAccess.ensure(refusing) }
        #expect(refusing.requests == 1, "a refusal is permissionDenied, then and from then on")
    }

    @Test func everyAnswerOfTheSystemHasItsState() {
        // The answers of AVAudioSession by their values ('grnt', 'deny', 'undt'): their names are
        // deprecated from iOS 17 on, which is exactly why the older interface is a path of its own.
        func older(_ code: UInt) -> MicrophonePermission? {
            AVAudioSession.RecordPermission(rawValue: code).map { MicrophonePermission($0) }
        }
        #expect(older(0x6772_6E74) == .granted)
        #expect(older(0x6465_6E79) == .denied)
        #expect(older(0x756E_6474) == .undetermined)
        #expect(older(0x7A7A_7A7A) == nil || older(0x7A7A_7A7A) == .denied, "an answer the package does not know is not a permission")
        if #available(iOS 17.0, *) {
            #expect(MicrophonePermission(AVAudioApplication.recordPermission.granted) == .granted)
            #expect(MicrophonePermission(AVAudioApplication.recordPermission.denied) == .denied)
            #expect(MicrophonePermission(AVAudioApplication.recordPermission.undetermined) == .undetermined)
        }
    }

    /// Both interfaces answer on a system that has both, and they agree. Only the state is
    /// read: asking would put up a prompt nobody answers, in a process that declares no usage
    /// description.
    @Test func bothInterfacesOfTheSystemAgree() {
        let current = SystemMicrophoneAuthorizer()
        let older = SystemMicrophoneAuthorizer(interface: .session)
        if #available(iOS 17.0, *) {
            #expect(current.interface == .application)
            #expect(SystemMicrophoneAuthorizer(interface: .application).permission == current.permission)
        } else {
            #expect(current.interface == .session)
        }
        #expect(older.interface == .session)
        #expect(older.permission == current.permission, "AVAudioSession and AVAudioApplication report the same answer")
    }

    @Test func aSourceWhoseUserRefusesIsNotPrepared() async {
        let rig = InputRig(authorizer: FakeAuthorizer(.undetermined, answer: false))
        await #expect(throws: DSPError.permissionDenied) { try await rig.source.prepare() }
        #expect(rig.session.calls.isEmpty && rig.capture.calls.isEmpty, "without permission neither the session nor the engine is touched")
        #expect(throws: DSPError.self) { try rig.source.start() }
        await #expect(throws: DSPError.permissionDenied) { try await DSPEngine(blockSize: 64).attach(Pipeline(), to: rig.source) }
    }
}
