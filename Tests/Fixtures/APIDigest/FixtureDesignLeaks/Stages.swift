import FixtureCore

/// A sequence stage: every public initialiser ends in `isActive:`.
public struct Gain: SequenceStage {
    public init(_ amount: Double, ramp: Double = 0.010, isActive: some ActivationSource = true) {}
    public init(decibels: Double, isActive: Bool = true) {}
    init(internalOnly: Int) {}
}

/// A stage whose content is a trailing closure: `isActive:` comes right before it.
public struct Tap<Content>: PipelineStage {
    public typealias Input = Samples
    public typealias Output = Samples
    public init(isActive: Bool = true, content: () -> Content) {}
}

/// A refinement of a stage protocol: what conforms to it is a stage too.
public protocol ResponseStage: SequenceStage {}

public struct LowPass: ResponseStage {
    public init(cutoff: Double, order: Int, isActive: Bool = true) {}
}

/// Not a stage: the rule does not apply.
public struct FilterDesign {
    public init(order: Int) {}
}

public func designOrder() -> Int { publicHelper() }
