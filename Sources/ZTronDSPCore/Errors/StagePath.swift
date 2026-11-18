/// Where a stage sits in a pipeline: the chain of containers that leads to it, then the stage
/// itself. An error raised while a pipeline is attached carries one, so the message names the
/// stage that caused it (§9.3).
///
/// A path is an immutable value. It may be created and read on any thread.
public struct StagePath: Hashable, Sendable, CustomStringConvertible {
    /// One step of a path: a stage's name and its position among its siblings.
    public struct Component: Hashable, Sendable, CustomStringConvertible {
        /// The stage's name, for example `LowPass` or `Tap`.
        public let name: String
        /// The zero-based position of the stage in the block that contains it.
        public let index: Int

        public init(name: String, index: Int) {
            self.name = name
            self.index = index
        }

        public var description: String { "\(name)[\(index)]" }
    }

    public let components: [Component]

    public init(components: [Component] = []) {
        self.components = components
    }

    /// The path of a value that belongs to no stage: a unit resolved on its own, a one-shot
    /// function.
    public static let none = StagePath()

    /// True for ``none``.
    public var isEmpty: Bool { components.isEmpty }

    /// The path of a stage nested in the stage this path names.
    public func appending(_ name: String, index: Int) -> StagePath {
        StagePath(components: components + [Component(name: name, index: index)])
    }

    /// The name of the stage the path ends at.
    public var stageName: String? { components.last?.name }

    public var description: String {
        components.isEmpty ? "(no stage)" : components.map(\.description).joined(separator: " › ")
    }
}
