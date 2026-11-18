import AVFAudio
import ZTronDSPCore

/// Whether the app may record.
enum MicrophonePermission: Hashable, Sendable {
    /// The user has not been asked yet.
    case undetermined
    /// The user said no, or recording is restricted.
    case denied
    /// The user said yes.
    case granted
}

/// The seam between the capture rules and the system's permission to record (§4.6, E-16): a
/// test stands in for the user.
///
/// Threading: `permission` may be read anywhere. `requestPermission` suspends until the user
/// has answered, which may take as long as the user likes.
protocol MicrophoneAuthorizing: Sendable {
    /// What the user has decided so far.
    var permission: MicrophonePermission { get }
    /// Asks the user. Returns whether they granted access. The app declares
    /// `NSMicrophoneUsageDescription`; the system ends a process that asks without it.
    func requestPermission() async -> Bool
}

/// The rule every hardware source follows before it touches the session.
enum MicrophoneAccess {
    /// Returns when the app may record. The user is asked only when they have not been asked
    /// before; a refusal, old or new, is `DSPError.permissionDenied`.
    static func ensure(_ authorizer: any MicrophoneAuthorizing) async throws(DSPError) {
        switch authorizer.permission {
        case .granted:
            return
        case .denied:
            throw .permissionDenied
        case .undetermined:
            guard await authorizer.requestPermission() else { throw .permissionDenied }
        }
    }
}

extension MicrophonePermission {
    /// The answer of `AVAudioApplication` (iOS 17 and later).
    @available(iOS 17.0, *)
    init(_ permission: AVAudioApplication.recordPermission) {
        switch permission {
        case .granted: self = .granted
        case .denied: self = .denied
        case .undetermined: self = .undetermined
        @unknown default: self = .denied
        }
    }

    /// The answer of `AVAudioSession` (before iOS 17).
    init(_ permission: AVAudioSession.RecordPermission) {
        switch permission {
        case .granted: self = .granted
        case .denied: self = .denied
        case .undetermined: self = .undetermined
        @unknown default: self = .denied
        }
    }
}

/// The system's answer, through the interface the running system has (E-16):
/// `AVAudioApplication` from iOS 17, `AVAudioSession` before. It forwards and translates.
struct SystemMicrophoneAuthorizer: MicrophoneAuthorizing {
    /// Which interface answers.
    enum Interface: Hashable, Sendable {
        /// `AVAudioApplication`, iOS 17 and later.
        case application
        /// `AVAudioSession`, the only one before iOS 17 and still answering after.
        case session
    }

    let interface: Interface

    /// The interface of the running system.
    static var current: Interface {
        if #available(iOS 17.0, *) { return .application }
        return .session
    }

    /// The system's answer through `interface`: the running system's own by default. A test
    /// names `.session` to reach the path of the older systems on a new one.
    init(interface: Interface = SystemMicrophoneAuthorizer.current) {
        self.interface = interface
    }

    var permission: MicrophonePermission {
        if #available(iOS 17.0, *), interface == .application {
            return MicrophonePermission(AVAudioApplication.shared.recordPermission)
        }
        return MicrophonePermission(AVAudioSession.sharedInstance().recordPermission)
    }

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *), interface == .application {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
