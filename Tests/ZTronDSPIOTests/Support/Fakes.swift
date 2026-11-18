import AVFAudio
import CoreAudioTypes
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

// The doubles behind the seams of the target (COV-5): a session, the user's answer, the capture
// engine and a node tap. Each records what it was asked and is as the test left it.

// MARK: The audio session

/// An audio session a test holds. It behaves as far as the capture rules can tell: Bluetooth
/// inputs are offered only when the category options allow them, the preferred input is the
/// current one while it is there, a change of category moves the output unless the options
/// keep it, and, when asked to, posts the change of route iOS posts.
final class FakeAudioSession: AudioSessionControlling, @unchecked Sendable {
    /// One call that changes the session.
    enum Call: Equatable {
        case setCategory(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
        case setActive(Bool, notifyingOthers: Bool)
        case allowHaptics(Bool)
        case setPreferredInput(String?)
        case setPreferredDataSource(String, input: String)
    }

    /// What a test may make fail.
    enum Operation: Hashable {
        case setCategory, setActive, allowHaptics, setPreferredInput, setPreferredDataSource
    }

    private struct Contents {
        var category: AVAudioSession.Category
        var mode: AVAudioSession.Mode = .default
        var options: AVAudioSession.CategoryOptions = []
        var isActive = false
        var allowsHaptics = false
        var inputs: [AudioInput]
        var systemChoice: String?
        var preferred: String?
        var preferredDataSources: [String: String] = [:]
        var hasInput = true
        var output = "Speaker"
        var calls: [Call] = []
        var failures: [Operation: DSPError] = [:]
        var routeChangesPosted = 0
    }

    // Threading: everything is behind one lock; notifications are posted outside it.
    private let contents: Shared<Contents>
    private let notifications: NotificationCenter?

    static let builtIn = AudioInput(id: "built-in", name: "iPhone Microphone", kind: .builtIn, dataSources: ["Bottom", "Front", "Back"])
    static let usb = AudioInput(id: "usb-1", name: "USB Interface", kind: .usb)
    static let headset = AudioInput(id: "headset-1", name: "Headset Microphone", kind: .wired)
    static let handsFree = AudioInput(id: "hfp-1", name: "AirPods", kind: .bluetooth)

    /// - Parameters:
    ///   - inputs: every input that is connected, the last one being the system's choice.
    ///   - notifications: where a change of category posts its change of route, as iOS does.
    init(category: AVAudioSession.Category = .soloAmbient, options: AVAudioSession.CategoryOptions = [],
         inputs: [AudioInput] = [FakeAudioSession.builtIn], notifications: NotificationCenter? = nil) {
        contents = Shared(Contents(category: category, inputs: inputs))
        contents.withLock {
            $0.options = options
            $0.systemChoice = inputs.last?.id
        }
        self.notifications = notifications
    }

    // What a test reads and arranges.

    var calls: [Call] { contents.withLock { $0.calls } }
    var isActive: Bool { contents.withLock { $0.isActive } }
    var allowsHaptics: Bool { contents.withLock { $0.allowsHaptics } }
    var output: String { contents.withLock { $0.output } }
    var preferredInput: String? { contents.withLock { $0.preferred } }
    var preferredDataSources: [String: String] { contents.withLock { $0.preferredDataSources } }
    var routeChangesPosted: Int { contents.withLock { $0.routeChangesPosted } }

    func forgetCalls() { contents.withLock { $0.calls = [] } }
    func fail(_ operation: Operation, with error: DSPError?) { contents.withLock { $0.failures[operation] = error } }
    func setHasInput(_ hasInput: Bool) { contents.withLock { $0.hasInput = hasInput } }
    func deactivateBySystem() { contents.withLock { $0.isActive = false } }

    /// A device is plugged in: it becomes the system's choice.
    func connect(_ input: AudioInput) {
        contents.withLock {
            $0.inputs.removeAll { $0.id == input.id }
            $0.inputs.append(input)
            $0.systemChoice = input.id
        }
    }

    /// A device is unplugged: the system falls back to the last one that is left.
    func disconnect(_ input: AudioInput) {
        contents.withLock {
            $0.inputs.removeAll { $0.id == input.id }
            if $0.systemChoice == input.id { $0.systemChoice = $0.inputs.last?.id }
        }
    }

    // The seam.

    var category: AVAudioSession.Category { contents.withLock { $0.category } }
    var mode: AVAudioSession.Mode { contents.withLock { $0.mode } }
    var categoryOptions: AVAudioSession.CategoryOptions { contents.withLock { $0.options } }
    var isInputAvailable: Bool { contents.withLock { $0.hasInput && !offered($0).isEmpty } }
    var availableInputs: [AudioInput] { contents.withLock { offered($0) } }

    var currentInput: AudioInput? {
        contents.withLock { contents in
            let offered = offered(contents)
            if let preferred = contents.preferred, let input = offered.first(where: { $0.id == preferred }) { return input }
            return offered.first { $0.id == contents.systemChoice } ?? offered.last
        }
    }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws(DSPError) {
        let changed = try contents.withLock { contents throws(DSPError) -> Bool in
            contents.calls.append(.setCategory(category, mode, options))
            if let failure = contents.failures[.setCategory] { throw failure }
            let changed = contents.category != category
            contents.category = category
            contents.mode = mode
            contents.options = options
            // Play and record sends playback to the receiver unless the options keep the speaker.
            if category == .playAndRecord, contents.output == "Speaker", !options.contains(.defaultToSpeaker) { contents.output = "Receiver" }
            if changed { contents.routeChangesPosted += 1 }
            return changed
        }
        if changed {
            notifications?.post(
                name: AVAudioSession.routeChangeNotification, object: nil,
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue])
        }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.setActive(active, notifyingOthers: options.contains(.notifyOthersOnDeactivation)))
            if let failure = contents.failures[.setActive] { throw failure }
            contents.isActive = active
        }
    }

    func setAllowHapticsAndSystemSoundsDuringRecording(_ allowed: Bool) throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.allowHaptics(allowed))
            if let failure = contents.failures[.allowHaptics] { throw failure }
            contents.allowsHaptics = allowed
        }
    }

    func setPreferredInput(_ input: AudioInput?) throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.setPreferredInput(input?.id))
            if let failure = contents.failures[.setPreferredInput] { throw failure }
            if let input, !offered(contents).contains(where: { $0.id == input.id }) {
                throw DSPError.sourceUnavailable(reason: "the input \(input.name) is not available")
            }
            contents.preferred = input?.id
        }
    }

    func setPreferredDataSource(_ dataSource: String, for input: AudioInput) throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.setPreferredDataSource(dataSource, input: input.id))
            if let failure = contents.failures[.setPreferredDataSource] { throw failure }
            contents.preferredDataSources[input.id] = dataSource
        }
    }

    /// The inputs the session offers: every connected one, Bluetooth only when the options
    /// allow it (MIC-3).
    private func offered(_ contents: Contents) -> [AudioInput] {
        var bluetooth = contents.options.contains(.allowBluetoothHFP)
        if #available(iOS 26.0, *), contents.options.contains(.bluetoothHighQualityRecording) { bluetooth = true }
        return contents.inputs.filter { $0.kind != .bluetooth || bluetooth }
    }
}

// MARK: The user's answer

final class FakeAuthorizer: MicrophoneAuthorizing, @unchecked Sendable {
    private let contents: Shared<(permission: MicrophonePermission, answer: Bool, requests: Int)>

    /// - Parameter answer: what the user says when they are asked.
    init(_ permission: MicrophonePermission = .granted, answer: Bool = true) {
        contents = Shared((permission, answer, 0))
    }

    var permission: MicrophonePermission { contents.withLock { $0.permission } }
    var requests: Int { contents.withLock { $0.requests } }

    func requestPermission() async -> Bool {
        contents.withLock { contents in
            contents.requests += 1
            contents.permission = contents.answer ? .granted : .denied
            return contents.answer
        }
    }
}

// MARK: The capture engine

/// A capture a test holds: it records every step, delivers the format the test says, and
/// writes what the test hands it into the ring it was given, as the I/O thread would.
final class FakeCapture: InputCapturing, @unchecked Sendable {
    enum Call: Equatable {
        case rebuild, voiceProcessing(Bool), connect, disconnect, start, stop
        /// A ring of this many channels, or none.
        case setRing(Int?)
    }

    enum Operation: Hashable {
        case rebuild, voiceProcessing, connect, start
    }

    private struct Contents {
        var format: SignalFormat
        var calls: [Call] = []
        var engine: NSObject?
        var isConnected = false
        var isRunning = false
        var ring: RingWriter?
        var failures: [Operation: DSPError] = [:]
        var invalidConnects = 0
    }

    private let contents: Shared<Contents>

    init(format: SignalFormat = SignalFormat(sampleRate: 48_000, channelCount: 1)) {
        contents = Shared(Contents(format: format))
    }

    // What a test reads and arranges.

    var calls: [Call] { contents.withLock { $0.calls } }
    var isRunning: Bool { contents.withLock { $0.isRunning } }
    var isConnected: Bool { contents.withLock { $0.isConnected } }
    var hasRing: Bool { contents.withLock { $0.ring != nil } }
    var ringChannelCount: Int? { contents.withLock { $0.ring?.channelCount } }
    /// Times `connect` was asked for with a format that is none: AVFAudio would have raised.
    var invalidConnects: Int { contents.withLock { $0.invalidConnects } }
    /// The object the capture's engine is, for the notification a test posts.
    var engine: NSObject? { contents.withLock { $0.engine } }

    func forgetCalls() { contents.withLock { $0.calls = [] } }
    func setFormat(_ format: SignalFormat) { contents.withLock { $0.format = format } }
    func fail(_ operation: Operation, with error: DSPError?) { contents.withLock { $0.failures[operation] = error } }
    /// The engine stops by itself, as AVAudioEngine does when the hardware changes (E-31).
    func stopByItself() { contents.withLock { $0.isRunning = false } }

    func count(of call: Call) -> Int { calls.filter { $0 == call }.count }

    /// Hands the capture frames, the same on every channel, as the hardware would. They reach
    /// the ring only while the engine runs, is connected, and has a ring of its format.
    @discardableResult
    func deliver(_ samples: [Float]) -> Int {
        contents.withLock { contents in
            guard contents.isRunning, contents.isConnected, let ring = contents.ring, ring.channelCount == contents.format.channelCount else { return 0 }
            return samples.withUnsafeBufferPointer { buffer -> Int in
                var table = [UnsafePointer<Float>?](repeating: buffer.baseAddress, count: ring.channelCount)
                return table.withUnsafeMutableBufferPointer { ring.write(channels: $0.baseAddress!, frameCount: samples.count) }
            }
        }
    }

    // The seam.

    var engineIdentity: ObjectIdentifier? { contents.withLock { $0.engine.map(ObjectIdentifier.init) } }

    func rebuild() throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.rebuild)
            if let failure = contents.failures[.rebuild] { throw failure }
            contents.engine = NSObject()
            contents.isConnected = false
            contents.isRunning = false
        }
    }

    func setVoiceProcessing(_ enabled: Bool) throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.voiceProcessing(enabled))
            if let failure = contents.failures[.voiceProcessing] { throw failure }
        }
    }

    func inputFormat() -> SignalFormat { contents.withLock { $0.format } }

    func connect() throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.connect)
            if !contents.format.isValid { contents.invalidConnects += 1 }
            if let failure = contents.failures[.connect] { throw failure }
            contents.isConnected = true
        }
    }

    func disconnect() {
        contents.withLock {
            $0.calls.append(.disconnect)
            $0.isConnected = false
        }
    }

    func start() throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.calls.append(.start)
            if let failure = contents.failures[.start] { throw failure }
            contents.isRunning = true
        }
    }

    func stop() {
        contents.withLock {
            $0.calls.append(.stop)
            $0.isRunning = false
        }
    }

    func setRing(_ ring: RingWriter?) {
        contents.withLock {
            $0.calls.append(.setRing(ring?.channelCount))
            $0.ring = ring
        }
    }
}

// MARK: A node tap

/// A tap a test holds: it delivers the bursts the test hands it.
final class FakeTap: NodeTapping, @unchecked Sendable {
    private struct Contents {
        var output: NodeOutput
        var bufferSizes: [Int] = []
        var removes = 0
        var receiver: TapReceiver?
        /// The receiver of the tap that was removed last: AVFAudio may still call it once.
        var removed: TapReceiver?
        var installFailure: DSPError?
    }

    private let contents: Shared<Contents>

    init(format: SignalFormat = SignalFormat(sampleRate: 48_000, channelCount: 1)) {
        contents = Shared(Contents(output: NodeOutput(format: format, isAttached: true, hasBus: true, isFloat: true)))
    }

    var bufferSizes: [Int] { contents.withLock { $0.bufferSizes } }
    var removes: Int { contents.withLock { $0.removes } }
    var isInstalled: Bool { contents.withLock { $0.receiver != nil } }

    func setOutput(_ output: NodeOutput) { contents.withLock { $0.output = output } }
    func failInstall(with error: DSPError?) { contents.withLock { $0.installFailure = error } }

    /// A burst, one array per channel, in the node's format or in another.
    func deliver(_ channels: [[Float]], format: SignalFormat? = nil, isFloat: Bool = true) {
        let (receiver, current) = contents.withLock { ($0.receiver, $0.output.format) }
        guard let receiver else { return }
        withBufferList(planar: channels) { buffers in
            receiver(format ?? current, isFloat, buffers, channels.first?.count ?? 0)
        }
    }

    /// A burst that was on its way when the tap was removed.
    func deliverLate(_ channels: [[Float]]) {
        let (receiver, current) = contents.withLock { ($0.removed, $0.output.format) }
        guard let receiver else { return }
        withBufferList(planar: channels) { buffers in
            receiver(current, true, buffers, channels.first?.count ?? 0)
        }
    }

    var output: NodeOutput { contents.withLock { $0.output } }

    func install(bufferSize: Int, receiver: @escaping TapReceiver) throws(DSPError) {
        try contents.withLock { contents throws(DSPError) in
            contents.bufferSizes.append(bufferSize)
            if let failure = contents.installFailure { throw failure }
            contents.receiver = receiver
        }
    }

    func remove() {
        contents.withLock {
            $0.removes += 1
            $0.removed = $0.receiver ?? $0.removed
            $0.receiver = nil
        }
    }
}

/// A buffer list with one buffer per channel over `channels`, for the length of `body`.
func withBufferList<Result>(planar channels: [[Float]], _ body: (UnsafePointer<AudioBufferList>) -> Result) -> Result {
    let list = AudioBufferList.allocate(maximumBuffers: max(channels.count, 1))
    var storage: [UnsafeMutablePointer<Float>] = []
    defer {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for (index, samples) in channels.enumerated() {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
        pointer.initialize(from: samples, count: samples.count)
        storage.append(pointer)
        list[index] = CoreAudioTypes.AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4), mData: UnsafeMutableRawPointer(pointer))
    }
    return body(UnsafePointer(list.unsafePointer))
}

// MARK: A hardware source on doubles

/// A hardware source with every part a test holds, and the parts.
struct InputRig {
    let session: FakeAudioSession
    let authorizer: FakeAuthorizer
    let capture: FakeCapture
    let notifications: NotificationCenter
    let source: HardwareInputSource

    init(
        input: AudioInput? = nil, dataSource: String? = nil, policy: AudioSessionPolicy = .playAndRecord, voiceProcessing: Bool = false,
        session: FakeAudioSession? = nil, authorizer: FakeAuthorizer = FakeAuthorizer(),
        format: SignalFormat = SignalFormat(sampleRate: 48_000, channelCount: 1), notifications: NotificationCenter = NotificationCenter()
    ) {
        self.session = session ?? FakeAudioSession(notifications: nil)
        self.authorizer = authorizer
        self.notifications = notifications
        capture = FakeCapture(format: format)
        source = HardwareInputSource(
            input: input, dataSource: dataSource, policy: policy, voiceProcessing: voiceProcessing,
            session: self.session, authorizer: authorizer, capture: capture, notifications: notifications)
    }

    // The notifications of the system, as the system posts them.

    func postInterruptionBegan() {
        notifications.post(
            name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        source.settle()
    }

    func postInterruptionEnded(shouldResume: Bool) {
        var userInfo: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        if shouldResume { userInfo[AVAudioSessionInterruptionOptionKey] = AVAudioSession.InterruptionOptions.shouldResume.rawValue }
        notifications.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: userInfo)
        source.settle()
    }

    func postRouteChange(_ reason: AVAudioSession.RouteChangeReason = .newDeviceAvailable) {
        notifications.post(
            name: AVAudioSession.routeChangeNotification, object: nil,
            userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
        source.settle()
    }

    func postEngineConfigurationChange(from engine: AnyObject? = nil) {
        notifications.post(name: .AVAudioEngineConfigurationChange, object: engine ?? capture.engine)
        source.settle()
    }

    func postMediaServicesReset() {
        notifications.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        source.settle()
    }
}
