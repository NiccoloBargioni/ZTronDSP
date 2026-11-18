import struct SwiftUI.Binding

/// A SwiftUI binding that takes a scalar result: `Binding<Float>` or `Binding<ScalarFrame>`
/// (§5.10). A step that reduces the signal to a value writes it here and lets the chain go on.
public protocol ScalarResultTarget: Sendable {
    /// The binding as a stage description holds it.
    var boundResult: BoundResult { get }
}

/// A SwiftUI binding that takes a small vector result: `Binding<[Float]>` (§5.10, OUT-5).
public protocol VectorResultTarget: Sendable {
    /// The binding as a stage description holds it.
    var boundResult: BoundResult { get }
}

extension Binding: ScalarResultTarget where Value: ScalarResultValue {
    public var boundResult: BoundResult { Value.boundResult(self) }
}

extension Binding: VectorResultTarget where Value == [Float] {
    public var boundResult: BoundResult { BoundResult(.vector(self)) }
}

/// The two value types a scalar result can be delivered as.
public protocol ScalarResultValue: Sendable {
    /// The result a binding of this type receives. Describes; any thread.
    static func boundResult(_ binding: Binding<Self>) -> BoundResult
}

extension Float: ScalarResultValue {
    public static func boundResult(_ binding: Binding<Float>) -> BoundResult { BoundResult(.value(binding)) }
}

extension ScalarFrame: ScalarResultValue {
    public static func boundResult(_ binding: Binding<ScalarFrame>) -> BoundResult { BoundResult(.frame(binding)) }
}

/// A result binding captured by a stage description.
///
/// A binding has no identity: all bound results of one kind compare equal, two attachments of
/// one pipeline both write its bindings, and the last write wins (OUT-4). The binding is
/// written only on the main actor, at the result rate, and never with a value equal to the
/// last one written (OUT-3).
public struct BoundResult: Hashable, Sendable {
    enum Storage: Sendable {
        case value(Binding<Float>)
        case frame(Binding<ScalarFrame>)
        case vector(Binding<[Float]>)
    }

    /// What the binding holds.
    public enum Kind: Hashable, Sendable {
        /// `Binding<Float>`: the value of a scalar or novelty frame.
        case value
        /// `Binding<ScalarFrame>`: the value with its confidence.
        case frame
        /// `Binding<[Float]>`: a real vector.
        case vector

        /// What errors call a binding of this kind.
        var name: String {
            switch self {
            case .value: "Binding<Float>"
            case .frame: "Binding<ScalarFrame>"
            case .vector: "Binding<[Float]>"
            }
        }
    }

    let storage: Storage

    init(_ storage: Storage) {
        self.storage = storage
    }

    /// Which of the three value types the binding holds. Any thread; reads no binding.
    public var kind: Kind {
        switch storage {
        case .value: .value
        case .frame: .frame
        case .vector: .vector
        }
    }

    var name: String { kind.name }

    /// Delivers a scalar result. Main actor only (BIND-1).
    @MainActor
    func write(_ frame: ScalarFrame) {
        switch storage {
        case .value(let binding): binding.wrappedValue = frame.value
        case .frame(let binding): binding.wrappedValue = frame
        case .vector: break
        }
    }

    /// Delivers a vector result. Main actor only (BIND-1).
    @MainActor
    func write(_ values: [Float]) {
        if case .vector(let binding) = storage { binding.wrappedValue = values }
    }

    public static func == (lhs: BoundResult, rhs: BoundResult) -> Bool { lhs.kind == rhs.kind }
    public func hash(into hasher: inout Hasher) { hasher.combine(kind) }
}
