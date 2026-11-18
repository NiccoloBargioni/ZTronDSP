/// Every error the package's public API throws (§9.3). Public throwing API is typed:
/// `throws(DSPError)`.
///
/// An error raised by a stage carries the stage's path. Two cases name it in their signature;
/// the others that a stage can raise take it as a trailing argument that defaults to `nil`,
/// and the plan compiler fills it in (``inStage(_:)``), so a stage never has to.
///
/// Errors are immutable values and may cross threads.
public enum DSPError: Error, Hashable, Sendable {
    /// A value a stage or a function was given cannot be used.
    case invalidParameter(stage: StagePath, parameter: String, reason: String)
    /// A stage sits where the signal is not of the domain it consumes (§5.8).
    case invalidStageOrder(stage: StagePath, found: DomainTag)
    /// The request is well-formed but outside what the package implements.
    case unsupportedConfiguration(reason: String, stage: StagePath? = nil)
    /// An IIR design has a pole on or outside the unit circle (REAL-2).
    case unstableDesign(maxPoleRadius: Double, stage: StagePath? = nil)
    /// A numerical routine reported failure: for LAPACK, its name and its `info` (LA-1).
    case numericalFailure(routine: String, info: Int, stage: StagePath? = nil)
    /// The user has not granted access to the microphone.
    case permissionDenied
    /// The audio session could not be brought into a state that permits input (§4.6).
    case sessionConfigurationFailed(reason: String)
    /// A source has nothing to deliver: no input, a missing file, an absent device.
    case sourceUnavailable(reason: String)
    /// An implementation that was asked for by name does not exist here (GPU-4).
    case backendUnavailable(reason: String, stage: StagePath? = nil)
    /// Memory, or a setup object, could not be created.
    case resourceAllocationFailed(what: String, stage: StagePath? = nil)
    /// A sink already has a writer (ATT-5).
    case sinkInUse(sink: String)
    /// The session was detached; it cannot be started or updated again (§4.5).
    case sessionDetached
    /// An export would write more elements than a script may hold (MAT-4).
    case exportTooLarge(elements: Int, limit: Int)
    /// Background work was cancelled between two of its steps (BG-3).
    case cancelled
}

extension DSPError {
    /// The path of the stage that raised the error, when a stage did.
    public var stage: StagePath? {
        switch self {
        case .invalidParameter(let stage, _, _), .invalidStageOrder(let stage, _):
            return stage.isEmpty ? nil : stage
        case .unsupportedConfiguration(_, let stage), .unstableDesign(_, let stage),
             .numericalFailure(_, _, let stage), .backendUnavailable(_, let stage),
             .resourceAllocationFailed(_, let stage):
            return stage
        case .permissionDenied, .sessionConfigurationFailed, .sourceUnavailable, .sinkInUse,
             .sessionDetached, .exportTooLarge, .cancelled:
            return nil
        }
    }

    /// The same error, attributed to `path` unless it already names a stage. Errors that no
    /// stage can raise are returned unchanged.
    public func inStage(_ path: StagePath) -> DSPError {
        guard stage == nil, !path.isEmpty else { return self }
        switch self {
        case .invalidParameter(_, let parameter, let reason):
            return .invalidParameter(stage: path, parameter: parameter, reason: reason)
        case .invalidStageOrder(_, let found):
            return .invalidStageOrder(stage: path, found: found)
        case .unsupportedConfiguration(let reason, _):
            return .unsupportedConfiguration(reason: reason, stage: path)
        case .unstableDesign(let radius, _):
            return .unstableDesign(maxPoleRadius: radius, stage: path)
        case .numericalFailure(let routine, let info, _):
            return .numericalFailure(routine: routine, info: info, stage: path)
        case .backendUnavailable(let reason, _):
            return .backendUnavailable(reason: reason, stage: path)
        case .resourceAllocationFailed(let what, _):
            return .resourceAllocationFailed(what: what, stage: path)
        case .permissionDenied, .sessionConfigurationFailed, .sourceUnavailable, .sinkInUse,
             .sessionDetached, .exportTooLarge, .cancelled:
            return self
        }
    }
}

extension DSPError: CustomStringConvertible {
    public var description: String {
        let location = stage.map { " (at \($0))" } ?? ""
        switch self {
        case .invalidParameter(_, let parameter, let reason):
            return "Invalid parameter \(parameter): \(reason)\(location)"
        case .invalidStageOrder(let path, let found):
            let name = path.stageName ?? "The stage"
            return "\(name) cannot follow a signal of the domain \(found)\(location)"
        case .unsupportedConfiguration(let reason, _):
            return "Unsupported configuration: \(reason)\(location)"
        case .unstableDesign(let radius, _):
            return "Unstable design: the largest pole radius is \(radius), which is not below 1\(location)"
        case .numericalFailure(let routine, let info, _):
            return "Numerical failure in \(routine) (info \(info))\(location)"
        case .permissionDenied:
            return "Microphone access was denied"
        case .sessionConfigurationFailed(let reason):
            return "The audio session could not be configured: \(reason)"
        case .sourceUnavailable(let reason):
            return "The source is unavailable: \(reason)"
        case .backendUnavailable(let reason, _):
            return "The backend is unavailable: \(reason)\(location)"
        case .resourceAllocationFailed(let what, _):
            return "Could not allocate \(what)\(location)"
        case .sinkInUse(let sink):
            return "The sink \(sink) already has a writer"
        case .sessionDetached:
            return "The session is detached"
        case .exportTooLarge(let elements, let limit):
            return "The export holds \(elements) elements; the limit is \(limit)"
        case .cancelled:
            return "The work was cancelled"
        }
    }
}
