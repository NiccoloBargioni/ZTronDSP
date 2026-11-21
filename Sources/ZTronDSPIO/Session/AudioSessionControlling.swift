import AVFAudio
import ZTronDSPCore

/// What the package asks of the app's audio session (§4.6): the seam between the capture
/// rules, CAP-1…CAP-8 and MIC-1…MIC-6, and `AVAudioSession`.
///
/// The package talks to the process's one session through this protocol and never names
/// `AVAudioSession.sharedInstance()` anywhere else, so every rule is decided in code that a
/// test drives with a session of its own (COV-5). An app meets the protocol in one place: the
/// closure of ``AudioSessionPolicy/custom(_:)`` is handed the session as a value of this type.
///
/// The names and meanings are `AVAudioSession`'s. Inputs are described by ``AudioInput``
/// values instead of port objects, which only the system can make.
///
/// Threading: called on the control context and on the source's own queue, one call at a
/// time, never on the main thread, the audio I/O thread or the analysis thread. Calls may
/// block while the system reconfigures audio, and may allocate.
public protocol AudioSessionControlling: AnyObject, Sendable {
    /// The session's category.
    var category: AVAudioSession.Category { get }
    /// The session's mode.
    var mode: AVAudioSession.Mode { get }
    /// The options the category was set with.
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    /// Whether an input is there to record from.
    var isInputAvailable: Bool { get }
    /// The inputs the session offers under its category and options (MIC-3).
    var availableInputs: [AudioInput] { get }
    /// The input of the current route: the one audio is recorded from now.
    var currentInput: AudioInput? { get }

    /// Sets category, mode and options in one step.
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws(DSPError)
    /// Activates or deactivates the session.
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws(DSPError)
    /// Whether recording leaves the app's haptics and system sounds alone (CAP-5).
    func setAllowHapticsAndSystemSoundsDuringRecording(_ allowed: Bool) throws(DSPError)
    /// Makes `input` the preferred input; `nil` hands the choice back to the system (MIC-1).
    func setPreferredInput(_ input: AudioInput?) throws(DSPError)
    /// Makes the data source named `dataSource` the preferred one of `input` (MIC-2).
    func setPreferredDataSource(_ dataSource: String, for input: AudioInput) throws(DSPError)
}

extension AudioInput {
    /// The description of a session port.
    init(port: AVAudioSessionPortDescription) {
        self.init(
            id: port.uid, name: port.portName, kind: Kind(port: port.portType),
            dataSources: (port.dataSources ?? []).map(\.dataSourceName))
    }
}

/// The process's audio session behind the seam. It forwards and translates; every decision is
/// made by its callers.
///
/// Threading: as the protocol says. `AVAudioSession` is safe to call from any thread.
final class SystemAudioSession: AudioSessionControlling {
    private let session = AVAudioSession.sharedInstance()

    var category: AVAudioSession.Category { session.category }
    var mode: AVAudioSession.Mode { session.mode }
    var categoryOptions: AVAudioSession.CategoryOptions { session.categoryOptions }
    var isInputAvailable: Bool { session.isInputAvailable }
    var availableInputs: [AudioInput] { (session.availableInputs ?? []).map(AudioInput.init(port:)) }
    var currentInput: AudioInput? { session.currentRoute.inputs.first.map(AudioInput.init(port:)) }

    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) throws(DSPError) {
        try ask("the category \(category.rawValue) with the mode \(mode.rawValue) was refused") {
            try session.setCategory(category, mode: mode, options: options)
        }
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws(DSPError) {
        try ask("the session could not be \(active ? "activated" : "deactivated")") {
            try session.setActive(active, options: options)
        }
    }

    func setAllowHapticsAndSystemSoundsDuringRecording(_ allowed: Bool) throws(DSPError) {
        try ask("haptics and system sounds during recording could not be set") {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(allowed)
        }
    }

    func setPreferredInput(_ input: AudioInput?) throws(DSPError) {
        let port = try input.map { wanted throws(DSPError) in try self.port(of: wanted) }
        try ask("the preferred input could not be set") {
            try session.setPreferredInput(port)
        }
    }

    func setPreferredDataSource(_ dataSource: String, for input: AudioInput) throws(DSPError) {
        let port = try port(of: input)
        guard let source = port.dataSources?.first(where: { $0.dataSourceName == dataSource }) else {
            throw .sourceUnavailable(reason: "the input \(input.name) has no data source named \(dataSource)")
        }
        try ask("the data source \(dataSource) could not be selected") { try port.setPreferredDataSource(source) } // coverage:ignore(the simulator's one input offers no data source to select: only a device run reaches this call)
    }

    /// Makes one call on the session. What the system refuses becomes an error of the
    /// package that says what was asked and what the system answered.
    private func ask(_ what: @autoclosure () -> String, _ call: () throws -> Void) throws(DSPError) {
        do {
            try call()
        } catch {
            throw .sessionConfigurationFailed(reason: "\(what()): \(error.localizedDescription)")
        }
    }

    /// The port an input describes, as the session offers it now.
    private func port(of input: AudioInput) throws(DSPError) -> AVAudioSessionPortDescription {
        guard let port = session.availableInputs?.first(where: { $0.uid == input.id }) else {
            throw .sourceUnavailable(reason: "the input \(input.name) is not available")
        }
        return port
    }
}
