// Seeded for Scripts/tests/test-docs.sh: a type whose comment says what it is and nothing of
// where it may be used or whether it allocates, and an unavailable overload whose comment does not
// say that it exists for its diagnostic. Both are refused.

/// A level that is never louder than its ceiling.
public struct ClampedLevel: Hashable, Sendable {
    /// The level, at most the ceiling.
    public let level: Level

    /// `level`, or the ceiling where it is louder.
    public init(_ level: Level, ceiling: Double) {
        self.level = Level(decibels: min(level.decibels, ceiling))
    }
}

/// Clamps a level of text.
@available(*, unavailable, message: "a level is made from decibels, not from text")
public func clamped(_ text: String) -> ClampedLevel {
    fatalError()
}
