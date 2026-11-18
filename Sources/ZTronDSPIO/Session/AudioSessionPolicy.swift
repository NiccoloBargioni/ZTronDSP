import AVFAudio
import os
import ZTronDSPCore

/// How a ``HardwareInputSource`` treats the app's audio session (§4.6): one strategy value,
/// refined by chained modifiers.
///
/// ```swift
/// HardwareInputSource()                                                // .playAndRecord
/// HardwareInputSource(policy: .measurement.mixingWithOthers())
/// HardwareInputSource(policy: .playAndRecord.allowingBluetoothHandsFree().deactivatingOnStop())
/// HardwareInputSource(policy: .external)                               // the app configures the session
/// ```
///
/// What the managed policies, ``playAndRecord`` and ``measurement``, do:
///
/// - If the session's category already permits input (`.playAndRecord`, `.record`,
///   `.multiRoute`), the session is left exactly as it is, whatever its mode and options
///   (CAP-3). A redundant category change can disturb audio that is already playing.
/// - Otherwise the category becomes `.playAndRecord`, never `.record`, which would silence
///   playback (CAP-1), with the options `.defaultToSpeaker` and `.allowBluetoothA2DP`, so that
///   playback stays on the output it had (CAP-2), and haptics and system sounds are allowed
///   during recording (CAP-5). This one change is unavoidable when capture starts in an app
///   that plays under `.playback` or `.ambient`, and iOS may answer it with a change of the
///   hardware format. An app that plays and records sets `.playAndRecord` itself before it
///   starts playback.
/// - The session is activated, and never deactivated unless the policy says
///   ``deactivatingOnStop()`` (CAP-4).
///
/// An immutable value, usable on any thread.
public struct AudioSessionPolicy: Sendable {
    /// Who configures the session.
    enum Management: Sendable {
        /// The package, with this mode, when the category does not permit input.
        case managed(mode: AVAudioSession.Mode)
        /// The app. The package reads the session and changes nothing.
        case external
        /// The app's closure, each time the source prepares.
        case custom(@Sendable (any AudioSessionControlling) throws -> Void)
    }

    let management: Management
    let mixesWithOthers: Bool
    let allowsBluetoothHandsFree: Bool
    let allowsHighQualityBluetoothRecording: Bool
    let deactivatesOnStop: Bool

    private init(
        management: Management, mixesWithOthers: Bool = false, allowsBluetoothHandsFree: Bool = false,
        allowsHighQualityBluetoothRecording: Bool = false, deactivatesOnStop: Bool = false
    ) {
        self.management = management
        self.mixesWithOthers = mixesWithOthers
        self.allowsBluetoothHandsFree = allowsBluetoothHandsFree
        self.allowsHighQualityBluetoothRecording = allowsHighQualityBluetoothRecording
        self.deactivatesOnStop = deactivatesOnStop
    }

    /// Play and record, default mode. The default.
    public static let playAndRecord = AudioSessionPolicy(management: .managed(mode: .default))

    /// As ``playAndRecord``, with the `.measurement` mode: the system applies as little input
    /// processing as the route allows.
    public static let measurement = AudioSessionPolicy(management: .managed(mode: .measurement))

    /// The app owns the session and the package never changes it: no category, no activation,
    /// no preferred input, no deactivation. The source checks that the session permits input
    /// and otherwise throws `DSPError.sessionConfigurationFailed(reason:)`, naming the
    /// category it found (CAP-7). An input given to the source must already be the one the
    /// session records from. The modifiers below have no effect on this policy.
    public static let external = AudioSessionPolicy(management: .external)

    /// The app configures the session in `configure`, which runs each time the source
    /// prepares, on the source's own queue. The package then checks that the category permits
    /// input, activates the session (CAP-4) and selects the input (MIC-2). An error thrown by
    /// `configure` becomes `DSPError.sessionConfigurationFailed(reason:)`. Of the modifiers
    /// below, only ``deactivatingOnStop()`` has an effect on this policy: the others describe
    /// options of a category the package sets, and here it sets none.
    public static func custom(_ configure: @escaping @Sendable (any AudioSessionControlling) throws -> Void) -> AudioSessionPolicy {
        AudioSessionPolicy(management: .custom(configure))
    }

    /// Other apps' audio keeps playing while this app records (`.mixWithOthers`). Applied when
    /// the package sets the category (CAP-2).
    public func mixingWithOthers() -> AudioSessionPolicy {
        AudioSessionPolicy(
            management: management, mixesWithOthers: true, allowsBluetoothHandsFree: allowsBluetoothHandsFree,
            allowsHighQualityBluetoothRecording: allowsHighQualityBluetoothRecording, deactivatesOnStop: deactivatesOnStop)
    }

    /// Bluetooth hands-free microphones may be used, and are listed by
    /// ``HardwareInputSource/availableInputs(policy:)`` (MIC-3, MIC-5). Opt-in, because a
    /// hands-free route degrades the quality of playback. Applied when the package sets the
    /// category (CAP-2).
    public func allowingBluetoothHandsFree() -> AudioSessionPolicy {
        AudioSessionPolicy(
            management: management, mixesWithOthers: mixesWithOthers, allowsBluetoothHandsFree: true,
            allowsHighQualityBluetoothRecording: allowsHighQualityBluetoothRecording, deactivatesOnStop: deactivatesOnStop)
    }

    /// Full-bandwidth Bluetooth recording where the route supports it (MIC-5). The system
    /// accepts the option with the default mode only, so with ``measurement`` the session
    /// refuses the category and the source reports `sessionConfigurationFailed`. Combined
    /// with ``allowingBluetoothHandsFree()``, hands-free is the fall-back for routes without
    /// it. Applied when the package sets the category (CAP-2).
    @available(iOS 26.0, *)
    public func allowingHighQualityBluetoothRecording() -> AudioSessionPolicy {
        AudioSessionPolicy(
            management: management, mixesWithOthers: mixesWithOthers, allowsBluetoothHandsFree: allowsBluetoothHandsFree,
            allowsHighQualityBluetoothRecording: true, deactivatesOnStop: deactivatesOnStop)
    }

    /// The session is deactivated when the source stops, and other apps are told that they
    /// may resume (`.notifyOthersOnDeactivation`, CAP-4). Without this the package never
    /// deactivates the session: the app may be playing through it.
    public func deactivatingOnStop() -> AudioSessionPolicy {
        AudioSessionPolicy(
            management: management, mixesWithOthers: mixesWithOthers, allowsBluetoothHandsFree: allowsBluetoothHandsFree,
            allowsHighQualityBluetoothRecording: allowsHighQualityBluetoothRecording, deactivatesOnStop: true)
    }
}

// MARK: What a policy does to a session

extension AudioSessionPolicy {
    /// True for a category under which the session delivers input.
    static func permitsInput(_ category: AVAudioSession.Category) -> Bool {
        category == .playAndRecord || category == .record || category == .multiRoute
    }

    /// False for ``external``: the package then calls nothing on the session that changes it.
    var changesSession: Bool {
        if case .external = management { return false }
        return true
    }

    /// The options a managed policy sets together with the category (CAP-2): what keeps
    /// playback where it was, plus what the policy asked for and the system has.
    var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if mixesWithOthers { options.insert(.mixWithOthers) }
        if allowsBluetoothHandsFree { options.insert(.allowBluetoothHFP) }
        if #available(iOS 26.0, *), allowsHighQualityBluetoothRecording { options.insert(.bluetoothHighQualityRecording) }
        return options
    }

    /// Brings the session's category to where capture is possible, or finds that it is
    /// (CAP-1, CAP-2, CAP-3, CAP-5, CAP-7). It never activates.
    func configure(_ session: any AudioSessionControlling) throws(DSPError) {
        switch management {
        case .managed(let mode):
            guard !AudioSessionPolicy.permitsInput(session.category) else { return }
            try session.setCategory(.playAndRecord, mode: mode, options: categoryOptions)
            do throws(DSPError) {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            } catch {
                // Capture works without it; the app's haptics are muted while it records.
                Log.session.error("Haptics and system sounds stay muted during recording: \(error.description, privacy: .public)")
            }
        case .external:
            try AudioSessionPolicy.requireInput(session, configuredBy: "the app (.external)")
        case .custom(let body):
            do {
                try body(session)
            } catch let error as DSPError {
                throw error
            } catch {
                throw .sessionConfigurationFailed(reason: "the policy's own configuration failed: \(error.localizedDescription)")
            }
            try AudioSessionPolicy.requireInput(session, configuredBy: "the policy's closure (.custom)")
        }
    }

    /// Activates the session (CAP-4), unless the app owns it.
    func activate(_ session: any AudioSessionControlling) throws(DSPError) {
        guard changesSession else { return }
        try session.setActive(true, options: [])
    }

    /// Deactivates the session when the policy says so, telling other apps (CAP-4). Returns
    /// whether the session was deactivated.
    func deactivateIfAsked(_ session: any AudioSessionControlling) -> Bool {
        guard changesSession, deactivatesOnStop else { return false }
        do throws(DSPError) {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            return true
        } catch {
            // The app's own audio may still be running through the session.
            Log.session.error("The session stays active after the source stopped: \(error.description, privacy: .public)")
            return false
        }
    }

    private static func requireInput(_ session: any AudioSessionControlling, configuredBy owner: String) throws(DSPError) {
        let category = session.category
        guard permitsInput(category) else {
            throw .sessionConfigurationFailed(
                reason: "the audio session's category is \(category.rawValue), which does not permit input; it is configured by \(owner), which sets .playAndRecord before a source is attached")
        }
    }
}

/// The package's loggers (§9.3). Never used on a hot path.
enum Log {
    static let session = Logger(subsystem: "com.zombietron.ztrondsp", category: "session")
    static let input = Logger(subsystem: "com.zombietron.ztrondsp", category: "input")
    static let sources = Logger(subsystem: "com.zombietron.ztrondsp", category: "sources")
}
