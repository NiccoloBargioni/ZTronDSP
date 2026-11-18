/// An immutable value (IMM-1): nothing here can be set from outside.
public struct Frequency: Hashable, Sendable {
    public let hertz: Double
    public private(set) var resolved: Bool = false
    public internal(set) var cached: Double?
    var scratch: Double = 0

    public init(hertz: Double) { self.hertz = hertz }

    public var octave: Double { hertz / 2 }
    public var isAudible: Bool {
        let low = 20.0
        var high = 20_000.0                 // a local variable is nobody's setter
        high += 0
        return hertz >= low && hertz <= high
    }
    public var midi: Double {
        get { 69 + 12 * (hertz / 440) }
    }
    @inlinable
    public static var middleC: Frequency { Frequency(hertz: 261.625_565) }
    public subscript(harmonic number: Int) -> Frequency { Frequency(hertz: hertz * Double(number)) }
}

public protocol FrequencyResolving {
    var nyquist: Double { get }
    subscript(bin: Int) -> Double { get }
}

public extension Frequency {
    var period: Double { 1 / hertz }
}

protocol InternalTuning {
    var reference: Double { get set }       // the protocol is internal, and so is its setter
}

public enum Implementation: Sendable {
    case automatic, native

    public var isForced: Bool {
        switch self {
        case .automatic: return false
        case .native: return true
        }
    }
}
