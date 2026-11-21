// The fixture of Scripts/tests/test-docs.sh: a module documented as the package is, every public
// symbol with a comment of its own and every type, protocol, global function and member added
// to another module's type with its threading contract. The two seeded variants add one file
// each to it (../BareSymbol, ../NoContract).

/// A level of the fixture: an immutable value, usable on any thread; it does not allocate.
public struct Level: Hashable, Sendable {
    /// The level in decibels.
    public let decibels: Double

    /// A level of `decibels`.
    public init(decibels: Double) {
        self.decibels = decibels
    }

    /// The level `amount` decibels louder.
    public func raised(by amount: Double) -> Level {
        Level(decibels: decibels + amount)
    }
}

/// What reads a level. Conformers are values, usable on any thread; `read()` does not allocate.
public protocol Meter: Sendable {
    /// The level now.
    func read() -> Level
}

/// A meter that reads one level: an immutable value, usable on any thread; it does not allocate.
public struct FixedMeter: Meter {
    /// The level it reads.
    public let level: Level

    /// A meter that reads `level`.
    public init(level: Level) {
        self.level = level
    }

    /// The level it was made with.
    public func read() -> Level {
        level
    }
}

// A member added to another module's type that implements a requirement: it has the contract
// of `Meter` (change request CR-033), so its comment need not repeat it.
extension Double: Meter {
    /// The value as a level in decibels.
    public func read() -> Level {
        Level(decibels: self)
    }
}

extension Int {
    /// The value as a level in decibels. Usable on any thread; it does not allocate.
    public var level: Level {
        Level(decibels: Double(self))
    }
}

/// Levels of `values`, in decibels. Runs on any thread and allocates the array it returns.
public func levels(_ values: [Double]) -> [Level] {
    values.map(Level.init(decibels:))
}

/// Unavailable: it exists for its diagnostic, which says what a level is made of.
@available(*, unavailable, message: "a level is made from decibels, not from text")
public func levels(_ values: [String]) -> [Level] {
    []
}

/// The example of the fixture's catalog. Usable on any thread; it does not allocate.
public func example() -> Level {
    // snippet:begin levels
    let quiet = Level(decibels: -40)
    return quiet.raised(by: 6)
    // snippet:end levels
}
