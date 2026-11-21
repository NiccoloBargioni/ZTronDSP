// Seeded for Scripts/tests/test-docs.sh: a public function without a comment, and a witness whose
// only comment is the one it inherits from its requirement. Both are refused.

public func bare() -> Int {
    1
}

/// A meter of silence: an immutable value, usable on any thread; it does not allocate.
public struct QuietMeter: Meter {
    public func read() -> Level {
        Level(decibels: -160)
    }
}
