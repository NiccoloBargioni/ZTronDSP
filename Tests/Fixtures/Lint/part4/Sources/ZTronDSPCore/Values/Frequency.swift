/// The stored `var`s of a public struct (IMM-1, IMM-2; WP-909): a public one whatever its setter,
/// and one the module can set (internal or package), each without a row in the register.
public struct Frequency: Hashable, Sendable {
    public let hertz: Double
    public private(set) var resolved: Bool = false           // !! IMM-2
    public internal(set) var cached: Double?                  // !! IMM-2
    public package(set) var shared: Double = 0                // !! IMM-2
    var scratch: Double = 0                                   // !! IMM-1
    internal var lane = 0                                     // !! IMM-1
    package var window: [Int: Set<Int>] = [:]                 // !! IMM-1
    internal(set) var settled = false                         // !! IMM-1
    var observed: Int = 0 {                                   // !! IMM-1
        didSet { }
    }
    var handler: (Int) -> Void                                // !! IMM-1
    nonisolated(unsafe) var unsafe: Int = 0                   // !! IMM-1

    private(set) var counted = 0                              // a private setter is the type's own
    fileprivate(set) var moved = 0
    @usableFromInline var inlined = 0                         // set by @inlinable code (VIS-1)
    @usableFromInline internal var lanes: [Int] = []
    private var hidden = 0
    let fixed: Int = 0
    static var shared = 0                                     // not an instance's state
    var derived: Int { lane + 1 }                             // computed
    var arrow: (Int) -> Int { { $0 } }                        // computed, of a function type
    var both: Int {                                           // computed, with a setter
        get { lane }
        set { }
    }

    public init(hertz: Double) {
        self.hertz = hertz
        handler = { _ in }
    }

    struct Nested {                                           // an internal type: nobody's API
        var anything = 0
    }
}

public final class Store {                                    // a reference type: its state is its own
    var history = 0
    public private(set) var count = 0
}

struct Internal {                                             // not public
    var value = 0
}

public enum Mode: Sendable {
    case on, off

    var isOn: Bool { self == .on }
}

public extension Frequency {
    struct Inside {                                           // public, as a member of a public extension
        var value = 0                                         // !! IMM-1
    }
}
