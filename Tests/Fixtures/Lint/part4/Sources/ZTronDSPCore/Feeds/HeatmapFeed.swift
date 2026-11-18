public final class HeatmapFeed: @unchecked Sendable {       // !! SEND
    public var history: Int                                 // !! IMM-2
    public var generation: Int = 0 {                        // !! IMM-2
        didSet { }
    }
    public var liveness: Bool {                             // !! IMM-2
        get { true }
        set { }
    }
    public static var shared = HeatmapFeed()                // !! IMM-2
    @available(iOS 16, *)
    public var later: Int {                                 // !! IMM-2
        get { 0 }
        nonmutating set { }
    }
    public subscript(column: Int) -> Float {                // !! IMM-2
        get { 0 }
        set { }
    }
    public private(set) var columns: Int = 0
    public var count: Int { columns }
    public init() { history = 0 }
}

public protocol FeedControlling: AnyObject {
    var isLive: Bool { get set }                            // !! IMM-2
    var axis: Int { get }
}

public extension HeatmapFeed {
    var scratch: Int { get { 0 } set { } }                  // !! IMM-2
}

extension RingWriter: @unchecked Sendable {}                // !! SEND
