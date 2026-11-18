public protocol SignalDomain {}
public enum Samples: SignalDomain {}

public protocol PipelineStage {
    associatedtype Input: SignalDomain
    associatedtype Output: SignalDomain
}
public protocol SequenceStage {}

public protocol ActivationSource {}
extension Bool: ActivationSource {}

/// The container: a stage that has nothing to switch.
public struct Pipeline<Input: SignalDomain, Output: SignalDomain>: PipelineStage {
    public init() {}
}

/// ACT-1: a reader has nothing to switch either.
public struct EnvironmentReader: PipelineStage {
    public typealias Input = Samples
    public typealias Output = Samples
    public init(_ content: () -> Void) {}
}

public func publicHelper() -> Int { 2 }

/// A hook for the package's own tests (VIS-1). Production code of the targets above never uses it.
package func packageOnlyHook() -> Int { 1 }
package struct PackageOnlyType {
    package init() {}
}
