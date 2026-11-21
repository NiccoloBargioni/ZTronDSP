/// A selection network for the median (WP-528): a fixed sequence of compare-exchange
/// operations on `count` lanes that leaves their median on one known lane, whatever the data.
///
/// A network has no branch that depends on the values, so the same sequence runs on whole
/// vectors at once: each lane is a row of bins or a column of frames, and each exchange is
/// one element-wise minimum and maximum (`ztd_lane_exchange`, §7.2). It is how the median
/// filters of the harmonic–percussive separation run on the CPU and, per texel, on the GPU.
///
/// The network is Batcher's merge exchange (Knuth, TAOCP vol. 3, algorithm 5.2.2M), which
/// sorts any number of lanes, pruned to the exchanges the median lane depends on.
///
/// An immutable value, usable on any thread. Building one is control-context work and
/// allocates its list of exchanges.
public struct MedianNetwork: Hashable, Sendable {
    /// One compare-exchange: afterwards lane `low` holds the smaller of the two values and
    /// lane `high` the larger.
    /// An immutable value, usable on any thread; it does not allocate.
    public struct Exchange: Hashable, Sendable {
        /// The lane that receives the smaller value.
        public let low: Int
        /// The lane that receives the larger value.
        public let high: Int

        /// The exchange of lanes `low` and `high`.
        public init(low: Int, high: Int) {
            self.low = low
            self.high = high
        }
    }

    /// The number of lanes. Odd, so the median is one of the values.
    public let count: Int
    /// The exchanges, in the order they are applied.
    public let exchanges: [Exchange]
    /// The lane that holds the median once every exchange has been applied.
    public let medianLane: Int

    /// The largest network the package builds.
    public static let maximumCount = 255

    /// The median network for `count` lanes.
    ///
    /// - Throws: `invalidParameter` for a count that is even, below 1, or above
    ///   `maximumCount`.
    public init(count: Int) throws(DSPError) {
        guard count >= 1, count % 2 == 1, count <= MedianNetwork.maximumCount else {
            throw .invalidParameter(
                stage: .none, parameter: "count",
                reason: "a median is taken over an odd number of values from 1 to \(MedianNetwork.maximumCount), not \(count)")
        }
        self.count = count
        medianLane = count / 2
        exchanges = MedianNetwork.pruned(MedianNetwork.sorting(count), keeping: count / 2)
    }

    /// Merge exchange: a sorting network for any number of lanes.
    static func sorting(_ count: Int) -> [Exchange] {
        guard count > 1 else { return [] }
        var exchanges: [Exchange] = []
        var p = 1
        while p < count {
            var k = p
            while k >= 1 {
                var j = k % p
                while j + k < count {
                    var i = 0
                    while i < k, i + j + k < count {
                        if (i + j) / (2 * p) == (i + j + k) / (2 * p) {
                            exchanges.append(Exchange(low: i + j, high: i + j + k))
                        }
                        i += 1
                    }
                    j += 2 * k
                }
                k /= 2
            }
            p *= 2
        }
        return exchanges
    }

    /// Drops every exchange the value on `lane` does not depend on: walking the network
    /// backwards, an exchange matters when one of its lanes is still needed, and then both are.
    static func pruned(_ exchanges: [Exchange], keeping lane: Int) -> [Exchange] {
        var needed: Set<Int> = [lane]
        var kept: [Exchange] = []
        for exchange in exchanges.reversed() where needed.contains(exchange.low) || needed.contains(exchange.high) {
            needed.insert(exchange.low)
            needed.insert(exchange.high)
            kept.append(exchange)
        }
        return kept.reversed()
    }

    /// The median of `values`, by running the network on them: the reference for the vector
    /// forms. `values` holds `count` elements and is left partially ordered. A NaN among the
    /// values makes the result unspecified, as it does for a comparison sort.
    public func median(of values: inout [Float]) -> Float {
        guard values.count == count else { return .nan }
        for exchange in exchanges {
            let a = values[exchange.low], b = values[exchange.high]
            if b < a {
                values[exchange.low] = b
                values[exchange.high] = a
            }
        }
        return values[medianLane]
    }
}
