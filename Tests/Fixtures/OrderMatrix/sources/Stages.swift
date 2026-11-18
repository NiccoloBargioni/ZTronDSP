public struct OnA: SequenceStage {
}
public struct OnAB: PipelineStage, Sendable {
}
public struct Everywhere<T>: Recipe where T: Sendable {
}
public struct NotAStage: Hashable {
}
struct Internal: SequenceStage {
}
