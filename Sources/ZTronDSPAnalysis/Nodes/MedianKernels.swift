import Darwin
import ZTronDSPCore

// The median kernels of the CPU (WP-529; §6.10, §7.2 row 16): the selection network of the
// core (`MedianNetwork`, WP-528) run on whole lanes. A lane is a vector of bins; one
// compare-exchange of the network is one element-wise minimum and maximum of two lanes, the
// lane exchange of the C layer (WP-219). Along time a lane is one stored frame; along
// frequency a lane is the current frame shifted by one bin. No value is sorted and no branch
// depends on the data.
//
// Analysis thread: nothing here allocates, locks or logs after an initialiser returns; loops
// are `while` loops (RT-2, CR-002).

/// The reflection of a line at both ends, the edge value repeated (§6.1): the position in
/// `0 ..< count` that `index` stands for, as often as it takes.
@inline(__always)
func reflectedIndex(_ index: Int, count: Int) -> Int {
    let period = 2 &* count
    var wrapped = index % period
    if wrapped < 0 { wrapped &+= period }
    return wrapped < count ? wrapped : period &- 1 &- wrapped
}

/// The median network on lanes: `kernel` lanes of `length` values, sorted far enough in place
/// for one of them to hold the median of every position.
final class LaneMedianNetwork {
    /// Lanes: the values a median is taken over.
    let kernel: Int
    /// Values per lane.
    let length: Int
    /// The lane exchange the network was bound to when it was made (SEL-3): `.native`, the C
    /// loop, or `.accelerate`, vDSP.
    let implementation: Implementation
    private let lanes: AlignedBuffer<Float>
    /// The compare-exchanges, as pairs of lane numbers.
    private let pairs: AlignedBuffer<Int32>
    private let exchangeCount: Int
    private let medianLane: Int
    private let exchange: ztd_lane_exchange_fn

    /// - Throws: `invalidParameter` for a kernel that is even, below 1 or above the largest
    ///   network, or a lane without values; `resourceAllocationFailed`.
    init(kernel: Int, length: Int, implementation: Implementation = .automatic, crossovers: CrossoverTable = .shipped) throws(DSPError) {
        let network = try MedianNetwork(count: kernel)
        guard length >= 1, length <= 1 << 24 else {
            throw .invalidParameter(stage: .none, parameter: "length", reason: "a lane holds between 1 and 2²⁴ values, not \(length)")
        }
        self.kernel = kernel
        self.length = length
        medianLane = network.medianLane
        exchangeCount = network.exchanges.count
        lanes = try AlignedBuffer<Float>(count: kernel * length)
        pairs = try AlignedBuffer<Int32>(count: max(2 * network.exchanges.count, 1))
        var step = 0
        while step < network.exchanges.count {
            pairs.baseAddress[2 * step] = Int32(network.exchanges[step].low)
            pairs.baseAddress[2 * step + 1] = Int32(network.exchanges[step].high)
            step += 1
        }
        let bound = crossovers.implementation(for: .laneExchange, size: length, requested: implementation)
        self.implementation = bound == .accelerate ? .accelerate : .native
        exchange = ztd_lane_exchange_function(bound == .accelerate ? ZTD_IMPLEMENTATION_ACCELERATE : ZTD_IMPLEMENTATION_NATIVE)
    }

    /// Where lane `index` is filled in: `length` values.
    @inline(__always)
    func lane(_ index: Int) -> UnsafeMutablePointer<Float> {
        lanes.baseAddress + index &* length
    }

    /// Runs the network on the lanes as they stand and returns the lane that now holds the
    /// median of every position. The lanes are left partially ordered: fill them again
    /// before the next run.
    func medians() -> UnsafePointer<Float> {
        let base = lanes.baseAddress, table = pairs.baseAddress
        let count = UInt32(length)
        var step = 0
        while step < exchangeCount {
            exchange(base + Int(table[2 &* step]) &* length, base + Int(table[2 &* step &+ 1]) &* length, count)
            step &+= 1
        }
        return UnsafePointer(base + medianLane &* length)
    }
}

/// The median along time: for every new frame, the median, bin by bin, of the last `kernel`
/// frames, the new one included. The frames are kept in a ring; each is one lane.
///
/// While fewer than `kernel` frames have arrived since a reset, the missing lanes are those a
/// stream reflected at its start gives, the edge frame repeated, as often as it takes (§6.1).
/// From frame `kernel / 2` on the result is therefore the centred median of frame
/// `t − kernel / 2`, the left edge included.
final class TimeLaneMedian: MedianFilter {
    private let network: LaneMedianNetwork
    private let kernel: Int
    private let binCount: Int
    private let history: AlignedBuffer<Float>
    /// Frames held since the last reset; it stops counting at `kernel`.
    private var held = 0
    /// The slot the next frame goes to.
    private var next = 0

    init(kernel: Int, binCount: Int, implementation: Implementation = .automatic, crossovers: CrossoverTable = .shipped) throws(DSPError) {
        network = try LaneMedianNetwork(kernel: kernel, length: binCount, implementation: implementation, crossovers: crossovers)
        self.kernel = kernel
        self.binCount = binCount
        history = try AlignedBuffer<Float>(count: kernel * binCount)
    }

    func process(_ frame: UnsafePointer<Float>, into medians: UnsafeMutablePointer<Float>) {
        let bytes = binCount * MemoryLayout<Float>.stride
        memcpy(history.baseAddress + next &* binCount, frame, bytes)
        next &+= 1
        if next == kernel { next = 0 }
        if held < kernel { held &+= 1 }

        if held == kernel {
            // Every lane is a frame of the ring; a median does not ask in which order.
            memcpy(network.lane(0), history.baseAddress, kernel &* bytes)
        } else {
            // The ring has not wrapped: frame f since the reset lies in slot f, the newest
            // being frame held − 1. Lane j is frame held − 1 − j, reflected where the stream
            // has not got that far back.
            var lane = 0
            while lane < kernel {
                let source = reflectedIndex(held &- 1 &- lane, count: held)
                memcpy(network.lane(lane), history.baseAddress + source &* binCount, bytes)
                lane &+= 1
            }
        }
        memcpy(medians, network.medians(), bytes)
    }

    func reset() {
        held = 0
        next = 0
    }
}

/// The median along frequency: for every bin of a frame, the median of the `kernel` bins
/// centred on it. Lane `j` is the frame shifted by `j − kernel / 2` bins, its edges reflected
/// with the edge value repeated. It keeps nothing from one frame to the next.
final class FrequencyLaneMedian: MedianFilter {
    private let network: LaneMedianNetwork
    private let kernel: Int
    private let binCount: Int
    /// The frame with `kernel / 2` reflected bins before its first and after its last.
    private let padded: AlignedBuffer<Float>

    init(kernel: Int, binCount: Int, implementation: Implementation = .automatic, crossovers: CrossoverTable = .shipped) throws(DSPError) {
        network = try LaneMedianNetwork(kernel: kernel, length: binCount, implementation: implementation, crossovers: crossovers)
        self.kernel = kernel
        self.binCount = binCount
        padded = try AlignedBuffer<Float>(count: binCount + kernel - 1)
    }

    func process(_ frame: UnsafePointer<Float>, into medians: UnsafeMutablePointer<Float>) {
        let bytes = binCount * MemoryLayout<Float>.stride
        let reach = kernel / 2
        let line = padded.baseAddress
        memcpy(line + reach, frame, bytes)
        var offset = 1
        while offset <= reach {
            line[reach &- offset] = frame[reflectedIndex(-offset, count: binCount)]
            line[reach &+ binCount &- 1 &+ offset] = frame[reflectedIndex(binCount &- 1 &+ offset, count: binCount)]
            offset &+= 1
        }
        var lane = 0
        while lane < kernel {
            memcpy(network.lane(lane), line + lane, bytes)
            lane &+= 1
        }
        memcpy(medians, network.medians(), bytes)
    }

    func reset() {}
}
