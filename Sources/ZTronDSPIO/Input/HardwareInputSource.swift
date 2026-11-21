import AVFAudio
import Foundation
import ZTronDSPCore

/// The microphone as a source (§4.6): the built-in one or an external one, wired, USB,
/// Bluetooth or Continuity.
///
/// ```swift
/// let microphone = HardwareInputSource()                         // whatever iOS has selected (MIC-1)
/// let session = try await engine.attach(pipeline, to: microphone)
/// try session.start()
///
/// let inputs = try await HardwareInputSource.availableInputs()
/// let external = HardwareInputSource(input: inputs.first { $0.kind == .usb })
/// ```
///
/// The source runs an `AVAudioEngine` of its own whose only connection is input node → sink
/// node. It shares the process's audio session with whatever the app plays through, and
/// nothing in it is on the output path, so capture does not stop or interrupt the app's
/// playback (R-22). How the session is treated is the ``AudioSessionPolicy``; the default,
/// `.playAndRecord`, leaves a session that already permits input exactly as it is.
///
/// An app that plays through a session of its own configures `.playAndRecord` before it
/// starts playback. Under `.playback` or `.ambient` capture needs one change of category,
/// which the package makes once and which iOS may answer with a change of the hardware
/// format that stops a playing engine; the package cannot prevent that (§4.6).
///
/// The format is what the input delivers: sample rate and channel count are discovered when
/// the source is prepared and again whenever the route changes, never assumed (MIC-6).
///
/// What the system does to the input becomes source events (CAP-8):
///
/// | The system | The source | Events |
/// |---|---|---|
/// | An interruption begins | stops delivering, keeps its engine | `.interrupted` |
/// | It ends, and the system says to resume | activates the session again, restarts | `.resumed` |
/// | It ends without | stays stopped until the session is stopped and started | none |
/// | The app comes back from suspension (before iOS 16) | activates the session again, restarts | `.interrupted`, `.resumed` |
/// | The route changes | reads the input format again; MIC-4 decides the input | `.routeChanged`, then `.formatChanged` if the format differs |
/// | Its engine reports a configuration change | reads the format again, restarts its engine | `.formatChanged` if the format differs |
/// | Media services were reset | rebuilds engine and sink node, applies the policy again | `.mediaServicesReset`, then as for a route change |
/// | No input is left | stops | `.failed(.sourceUnavailable)` |
///
/// When the selected input disappears, the source falls back to the system's choice and
/// reports `.routeChanged(.inputLost)`; when it returns, it is selected again and the source
/// reports `.routeChanged(.inputRestored)`. A session attached to the source survives both
/// (MIC-4).
///
/// The app declares `NSMicrophoneUsageDescription`. The user is asked for permission when the
/// source is first prepared, which is when the first pipeline is attached to it.
///
/// Threading: as every source, `prepare`, `start`, `stop` and `connect(to:)` are called by the
/// engine on its control context; `prepare` suspends while the user answers and never blocks
/// the caller's thread on the session. System notifications are handled on a queue of the
/// source's own. What runs on the audio I/O thread is a non-blocking C function that copies
/// frames into the ring (RT-1); when the ring is full it drops the newest frames and counts
/// them, and the engine reports `.overrun` (RT-8). No member allocates on a real-time thread.
public final class HardwareInputSource: PushSampleSource {
    /// What is known about the capture between two calls or notifications.
    private struct State {
        /// `prepare()` has succeeded: the notifications of the system are acted on.
        var isPrepared = false
        /// The engine asked for delivery and has not stopped it.
        var isStarted = false
        /// An interruption began while started and has not ended with a resumption.
        var isInterrupted = false
        /// The source activated the session and nothing has deactivated it since (CAP-4).
        var isSessionActive = false
        /// The input the source was asked for has disappeared (MIC-4).
        var isInputLost = false
        /// The input of the route when it was last looked at.
        var currentInputID: String?
    }

    private let input: AudioInput?
    private let dataSource: String?
    private let policy: AudioSessionPolicy
    private let voiceProcessing: Bool
    private let session: any AudioSessionControlling
    private let authorizer: any MicrophoneAuthorizing
    private let capture: any InputCapturing
    private let notifications: NotificationCenter
    /// Where notifications are handled, in the order they were posted, off the thread that
    /// posts them.
    private let queue = DispatchQueue(label: "com.zombietron.ztrondsp.input", qos: .userInitiated)
    private let channel = SourceEventChannel()
    private let current = Guarded(SignalFormat(sampleRate: 0, channelCount: 0))
    private let state = Guarded(State())
    private let observers = Guarded<[any NSObjectProtocol]>([])

    /// A source with the parts a test replaces: the session, the user's answer, the capture
    /// engine and the notification centre (COV-5).
    init(
        input: AudioInput?, dataSource: String?, policy: AudioSessionPolicy, voiceProcessing: Bool,
        session: any AudioSessionControlling, authorizer: any MicrophoneAuthorizing, capture: any InputCapturing,
        notifications: NotificationCenter
    ) {
        self.input = input
        self.dataSource = dataSource
        self.policy = policy
        self.voiceProcessing = voiceProcessing
        self.session = session
        self.authorizer = authorizer
        self.capture = capture
        self.notifications = notifications
        observe()
    }

    deinit {
        for observer in observers.get() { notifications.removeObserver(observer) }
        capture.stop()
    }

    /// What the input delivers: valid after `prepare()`, and the new format after the source
    /// reported `.formatChanged`. May be read on any thread.
    public var format: SignalFormat { current.get() }

    /// What the system does to the input, as the table above says. One consumer, which is the
    /// engine while the source is attached; an app follows its session's events instead.
    public var events: AsyncStream<SourceEvent> { channel.stream }

    /// Asks for permission if the user has not answered yet, brings the session to where the
    /// policy wants it, selects the input and discovers its format.
    ///
    /// - Throws: `permissionDenied`; `sessionConfigurationFailed` when the session cannot be
    ///   configured or activated, or, under `.external`, does not permit input;
    ///   `sourceUnavailable` when the requested input or data source is not there, or when
    ///   there is no input at all; `unsupportedConfiguration` when voice processing is
    ///   refused or the input has more channels than the capture path takes.
    public func prepare() async throws(DSPError) {
        try await MicrophoneAccess.ensure(authorizer)
        let outcome: Result<Void, DSPError> = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.prepareNow()) }
        }
        try outcome.get()
    }

    /// Starts the capture engine. The session is activated first when an interruption or a
    /// stop under `deactivatingOnStop()` has deactivated it.
    ///
    /// - Throws: `sourceUnavailable` when the source was not prepared or the engine does not
    ///   start; `sessionConfigurationFailed` when the session cannot be activated.
    public func start() throws(DSPError) {
        try state.withLock { state throws(DSPError) in
            guard state.isPrepared else {
                throw .sourceUnavailable(reason: "the hardware input was not prepared; attach a pipeline to it first")
            }
            guard !state.isStarted else { return }
            try activate(&state)
            try capture.start()
            state.isStarted = true
            state.isInterrupted = false
        }
    }

    /// Stops the capture engine. The session stays active unless the policy says
    /// `deactivatingOnStop()` (CAP-4).
    public func stop() {
        state.withLock { state in
            capture.stop()
            state.isStarted = false
            state.isInterrupted = false
            if policy.deactivateIfAsked(session) { state.isSessionActive = false }
        }
    }

    /// Takes the ring the I/O thread writes from now on. Called by the engine on its control
    /// context, after `prepare()` and after every format change; it returns once the I/O
    /// thread has let go of the ring it wrote before.
    public func connect(to ring: RingWriter) {
        state.withLock { _ in capture.setRing(ring) }
    }
}

// MARK: Inputs

extension HardwareInputSource {
    /// A source that records from `input`, or, without one, from whatever input iOS has selected:
    /// the last external microphone connected, or the built-in one (MIC-1). Creating a source
    /// configures no audio session and may be done on any thread; it allocates.
    ///
    /// - Parameters:
    ///   - input: an input from ``availableInputs(policy:)``. It becomes the session's
    ///     preferred input when the source is prepared (MIC-2); if it is not available then,
    ///     preparing throws `sourceUnavailable`.
    ///   - dataSource: one of the input's `dataSources`, for a built-in microphone front, back
    ///     or bottom. Without an `input`, it applies to the input iOS has selected.
    ///   - policy: how the audio session is treated. Under `.external` nothing is selected:
    ///     `input` must already be the one the session records from, and `dataSource` is
    ///     left to the app.
    ///   - voiceProcessing: echo cancellation and gain control by the system. Off by default:
    ///     it changes the signal and is unsuitable for measurement (CAP-6).
    public convenience init(
        input: AudioInput? = nil, dataSource: String? = nil, policy: AudioSessionPolicy = .playAndRecord,
        voiceProcessing: Bool = false
    ) {
        self.init(
            input: input, dataSource: dataSource, policy: policy, voiceProcessing: voiceProcessing,
            session: SystemAudioSession(), authorizer: SystemMicrophoneAuthorizer(), capture: EngineInputCapture(),
            notifications: .default)
    }

    /// The inputs the session offers under `policy` (MIC-3). The session's category is brought
    /// to where the policy wants it, as when a source is prepared, but the session is not
    /// activated and the user is not asked for permission. Bluetooth microphones are listed
    /// only under a policy that allows them (MIC-5).
    ///
    /// May be called from any context; the work runs off the caller's thread. It allocates, on the
    /// background executor.
    ///
    /// - Throws: `sessionConfigurationFailed`, as `prepare()` does.
    public static func availableInputs(policy: AudioSessionPolicy = .playAndRecord) async throws(DSPError) -> [AudioInput] {
        let session = SystemAudioSession()
        return try await BackgroundWork.run { _ throws(DSPError) in
            try HardwareInputSource.inputs(offeredBy: session, under: policy)
        }
    }

    /// The decision behind ``availableInputs(policy:)``, on a session a test may hold.
    static func inputs(offeredBy session: any AudioSessionControlling, under policy: AudioSessionPolicy) throws(DSPError) -> [AudioInput] {
        try policy.configure(session)
        return session.availableInputs.filter { policy.offers($0) }
    }
}

extension AudioSessionPolicy {
    /// False for a Bluetooth microphone under a managed policy that did not ask for one:
    /// hands-free input is opt-in (MIC-3, MIC-5), also where the app's own session, left
    /// untouched under CAP-3, would route it.
    func offers(_ input: AudioInput) -> Bool {
        guard input.kind == .bluetooth, case .managed = management else { return true }
        return allowsBluetoothHandsFree || allowsHighQualityBluetoothRecording
    }
}

// MARK: Preparing

extension HardwareInputSource {
    /// The synchronous part of `prepare()`, on the source's queue.
    private func prepareNow() -> Result<Void, DSPError> {
        state.withLock { state in
            do throws(DSPError) {
                capture.stop()
                state = State()
                try policy.configure(session)
                try activate(&state)
                try selectInput(&state)
                guard session.isInputAvailable else {
                    throw DSPError.sourceUnavailable(reason: "no audio input is available")
                }
                try capture.rebuild()
                if voiceProcessing { try capture.setVoiceProcessing(true) }
                let found = try usableFormat()
                try capture.connect()
                current.set(found)
                state.isPrepared = true
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    /// Activates the session unless the source already has (CAP-4).
    private func activate(_ state: inout State) throws(DSPError) {
        guard !state.isSessionActive else { return }
        try policy.activate(session)
        state.isSessionActive = true
    }

    /// Makes the requested input and data source the preferred ones (MIC-2), or leaves the
    /// choice to iOS (MIC-1).
    private func selectInput(_ state: inout State) throws(DSPError) {
        if let input {
            guard let offered = session.availableInputs.first(where: { $0.id == input.id }) else {
                throw .sourceUnavailable(reason: "the input \(input.name) is not available")
            }
            guard policy.offers(offered) else {
                throw .sourceUnavailable(
                    reason: "the input \(offered.name) is a Bluetooth microphone, which the policy does not allow; use allowingBluetoothHandsFree()")
            }
            if policy.changesSession {
                try checkDataSource(of: offered)
                try session.setPreferredInput(offered)
                if let dataSource { try session.setPreferredDataSource(dataSource, for: offered) }
            } else if session.currentInput?.id != offered.id {
                throw .sourceUnavailable(
                    reason: "the input \(offered.name) is available but is not the one the session records from; under the .external policy the app selects it")
            }
        } else if let dataSource, policy.changesSession {
            guard let selected = session.currentInput else {
                throw .sourceUnavailable(reason: "no audio input is available")
            }
            try checkDataSource(of: selected)
            try session.setPreferredDataSource(dataSource, for: selected)
        }
        state.isInputLost = false
        state.currentInputID = session.currentInput?.id
    }

    private func checkDataSource(of input: AudioInput) throws(DSPError) {
        guard let dataSource, !input.dataSources.contains(dataSource) else { return }
        throw .sourceUnavailable(reason: "the input \(input.name) has no data source named \(dataSource)")
    }

    /// The format the input delivers now, when it is one the capture path can take.
    private func usableFormat() throws(DSPError) -> SignalFormat {
        let found = capture.inputFormat()
        guard found.isValid else {
            throw .sourceUnavailable(reason: "no audio input is available: the input reports \(found)")
        }
        guard found.channelCount <= EngineInputCapture.maximumChannelCount else {
            throw .unsupportedConfiguration(
                reason: "the input has \(found.channelCount) channels; the capture path takes at most \(EngineInputCapture.maximumChannelCount)")
        }
        return found
    }
}

// MARK: What the system does (CAP-8)

/// What a notification of the system says, as far as a hardware source cares.
enum SessionNotice: Hashable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    /// The app was suspended and is back: an interruption that is over when it is reported.
    case suspensionEnded
    case routeChanged
    case engineConfigurationChanged
    case mediaServicesReset

    /// The interruption reason "the app was suspended" (`AVAudioSession.InterruptionReason`).
    /// Systems before iOS 16 give it when an app that was suspended comes back, as an
    /// interruption that began; no end is ever posted for it.
    static let appWasSuspended: UInt = 1

    /// What an interruption notification says; `nil` for one that names no known type.
    static func interruption(_ userInfo: [AnyHashable: Any]?) -> SessionNotice? {
        guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
        switch type {
        case .began:
            if userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt == appWasSuspended { return .suspensionEnded }
            return .interruptionBegan
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            return .interruptionEnded(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }
}

extension HardwareInputSource {
    /// Listens to the session and to the capture's engine. A notification is read on the
    /// thread that posts it, where no lock of the source is taken, and handled on the
    /// source's queue.
    private func observe() {
        let handle: @Sendable (SessionNotice) -> Void = { [weak self] notice in
            self?.queue.async { [weak self] in self?.handle(notice) }
        }
        var tokens: [any NSObjectProtocol] = []
        tokens.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { notification in
            if let notice = SessionNotice.interruption(notification.userInfo) { handle(notice) }
        })
        tokens.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { _ in
            handle(.routeChanged)
        })
        tokens.append(notifications.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            handle(.mediaServicesReset)
        })
        // Every engine of the app posts this one: only the capture's own is the source's business.
        tokens.append(notifications.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] notification in
            guard let identity = self?.capture.engineIdentity,
                  notification.object.map({ ObjectIdentifier($0 as AnyObject) }) == identity else { return }
            handle(.engineConfigurationChanged)
        })
        observers.set(tokens)
    }

    /// Waits until every notification posted so far has been handled. For tests.
    func settle() {
        queue.sync {}
    }

    /// One row of the table of CAP-8.
    func handle(_ notice: SessionNotice) {
        state.withLock { state in
            guard state.isPrepared else { return }
            switch notice {
            case .interruptionBegan:
                interrupt(&state)

            case .interruptionEnded(let shouldResume):
                if shouldResume { resume(&state) }

            case .suspensionEnded:
                // The session was deactivated while the app was suspended, and nothing more
                // will be said about it: the source stops and resumes in one step.
                interrupt(&state)
                resume(&state)

            case .routeChanged:
                channel.send(.routeChanged(routeChange(&state)))
                // While interrupted there may be no input at all; the format is read when the
                // interruption ends.
                guard !state.isInterrupted else { return }
                attempt(&state) { state throws(DSPError) in
                    guard session.isInputAvailable else {
                        throw DSPError.sourceUnavailable(reason: "no audio input is available")
                    }
                    try adoptFormat(&state, restartingEngine: false)
                }

            case .engineConfigurationChanged:
                guard !state.isInterrupted else { return }
                attempt(&state) { state throws(DSPError) in
                    try adoptFormat(&state, restartingEngine: true)
                }

            case .mediaServicesReset:
                channel.send(.mediaServicesReset)
                attempt(&state) { state throws(DSPError) in
                    try rebuild(&state)
                }
            }
        }
    }

    /// Row 1 of CAP-8: stops delivering and keeps the engine.
    private func interrupt(_ state: inout State) {
        // The system has deactivated the session, whether or not the source delivers.
        state.isSessionActive = false
        guard state.isStarted, !state.isInterrupted else { return }
        capture.stop()
        state.isInterrupted = true
        channel.send(.interrupted)
    }

    /// Row 2 of CAP-8: activates the session again and restarts the engine, in the format the
    /// input has now.
    private func resume(_ state: inout State) {
        guard state.isStarted, state.isInterrupted else { return }
        attempt(&state) { state throws(DSPError) in
            try activate(&state)
            try adoptFormat(&state, restartingEngine: false)
            try capture.start()
            state.isInterrupted = false
            channel.send(.resumed)
        }
    }

    /// Runs a step that may find that the source cannot go on: the source then stops and
    /// says so.
    private func attempt(_ state: inout State, _ step: (inout State) throws(DSPError) -> Void) {
        do throws(DSPError) {
            try step(&state)
        } catch {
            capture.stop()
            state.isStarted = false
            state.isInterrupted = false
            channel.send(.failed(error))
        }
    }

    /// What a change of route means for the input, and what the source does about it (MIC-4).
    private func routeChange(_ state: inout State) -> RouteChange {
        defer { state.currentInputID = session.currentInput?.id }
        if let input {
            let offered = session.availableInputs.first { $0.id == input.id }
            if offered == nil, !state.isInputLost {
                // Back to the system's choice.
                state.isInputLost = true
                if policy.changesSession { try? session.setPreferredInput(nil) }
                return .inputLost
            }
            if state.isInputLost, let offered, reselect(offered) {
                state.isInputLost = false
                return .inputRestored
            }
        }
        return session.currentInput?.id != state.currentInputID ? .inputChanged : .other
    }

    /// Makes an input that has returned the preferred one again. Under `.external` the app
    /// does that: the input is back when the session records from it. False when it is not
    /// back yet; the next change of route asks again.
    private func reselect(_ offered: AudioInput) -> Bool {
        guard policy.changesSession else { return session.currentInput?.id == offered.id }
        do throws(DSPError) {
            try session.setPreferredInput(offered)
            if let dataSource, offered.dataSources.contains(dataSource) {
                try session.setPreferredDataSource(dataSource, for: offered)
            }
            return true
        } catch {
            Log.input.error("The input \(offered.name, privacy: .public) has returned but could not be selected: \(error.description, privacy: .public)")
            return false
        }
    }

    /// Reads the input's format again. A format that differs is adopted: the capture is
    /// connected anew, frames are discarded until the engine hands over a ring of the new
    /// format, and the engine is told. With `restartingEngine` an engine that has stopped
    /// itself is started again also when the format is the same.
    private func adoptFormat(_ state: inout State, restartingEngine: Bool) throws(DSPError) {
        let found = try usableFormat()
        let delivers = state.isStarted && !state.isInterrupted
        if found != current.get() {
            capture.stop()
            capture.setRing(nil)
            capture.disconnect()
            try capture.connect()
            current.set(found)
            channel.send(.formatChanged(found))
            if delivers { try capture.start() }
        } else if restartingEngine, delivers {
            try capture.start()
        }
    }

    /// After a reset of the media services nothing the source held is valid: the policy
    /// applied again, a new engine and sink node, the input selected again, then as for a
    /// change of route.
    private func rebuild(_ state: inout State) throws(DSPError) {
        state.isSessionActive = false
        try policy.configure(session)
        try activate(&state)
        try capture.rebuild()
        if voiceProcessing { try capture.setVoiceProcessing(true) }
        // The preference went with the old session. An input that was lost before the reset is
        // left to the look at the route below, which reports its return.
        if let input, !state.isInputLost, let offered = session.availableInputs.first(where: { $0.id == input.id }) {
            _ = reselect(offered)
        }
        channel.send(.routeChanged(routeChange(&state)))
        guard session.isInputAvailable else {
            throw .sourceUnavailable(reason: "no audio input is available")
        }
        let found = try usableFormat()
        try capture.connect()
        if found != current.get() {
            capture.setRing(nil)
            current.set(found)
            channel.send(.formatChanged(found))
        }
        if state.isStarted, !state.isInterrupted { try capture.start() }
    }
}
