/// A `Hashable`, `Sendable` box around a strategy value whose concrete type is not known where
/// it is stored. Descriptions hold strategies this way, so two descriptions compare equal
/// exactly when their strategies are of the same type and equal (API-1).
///
/// Strategy protocols refine `Hashable` and `Sendable`; any conformer, stock or written outside
/// the package, can be boxed. An immutable value, usable on any thread. Boxing a value may
/// allocate: one larger than three words is stored on the heap.
public struct AnyStrategy: Hashable, Sendable {
    /// The boxed value.
    public let base: any Hashable & Sendable

    /// Boxes `base`.
    public init(_ base: some Hashable & Sendable) {
        self.base = base
    }

    /// The boxed value as `T`, or `nil` when it is of another type.
    @inlinable
    public func value<T>(as type: T.Type = T.self) -> T? {
        base as? T
    }

    /// True when the boxed values are of the same type and equal.
    public static func == (lhs: AnyStrategy, rhs: AnyStrategy) -> Bool {
        isEqual(lhs.base, rhs.base)
    }

    /// Hashes the boxed value's type, then the value.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(type(of: base)))
        base.hash(into: &hasher)
    }

    private static func isEqual<L: Hashable>(_ lhs: L, _ rhs: any Hashable) -> Bool {
        guard let other = rhs as? L else { return false }
        return other == lhs
    }
}
