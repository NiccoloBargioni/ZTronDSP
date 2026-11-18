import FixtureCore

public struct HighPass: SequenceStage {
    public init(cutoff: Double) {}                                  // no isActive: at all
    public init(cutoff: Double, isActive: Bool, order: Int) {}      // isActive: is not the last argument
    public init(cutoff: Double, order: Int, isActive: Bool = true) {}
}

public struct Shelf: ResponseStage {                                // a stage through the refinement
    public init(gain: Double) {}
}

extension Gain {
    public init(linear: Double) {}                                  // an initialiser added by an extension
}

extension Pipeline: SequenceStage {}                                // exempt by name: the container
