/// A stored `var` the module can set, registered: the row names a member of a nested type by its
/// own path.
public struct Ramp: Sendable {
    var current: Float = 0
    public init() {}

    public struct Phase: Sendable {
        var radians: Float = 0
    }
}
