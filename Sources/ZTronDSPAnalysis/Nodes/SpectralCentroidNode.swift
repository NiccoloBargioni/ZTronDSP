import ZTronDSPCore

/// The node of `SpectralCentroid` (WP-507): one dot product against a frequency ramp computed
/// once, and one sum (§7.2 row 17). Both are bound to their implementation for the number of
/// bins in the range when the plan is compiled (SEL-3).
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class SpectralCentroidNode: AnalysisNode {
    private let firstBin: Int
    private let count: Int
    private let floor: Float
    private let ramp: AlignedBuffer<Float>
    private let bound: Vector.Bound
    private var last: Float = 0

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(firstBin: Int, count: Int, binWidth: Double, floor: Float, bound: Vector.Bound) throws(DSPError) {
        self.firstBin = firstBin
        self.count = count
        self.floor = floor
        self.bound = bound
        ramp = try AlignedBuffer<Float>(count: count)
        var index = 0
        while index < count {
            ramp.baseAddress[index] = Float(Double(firstBin + index) * binWidth)
            index &+= 1
        }
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= firstBin + count, let values = frame.values.baseAddress else { return }
        let weights = values + firstBin
        let total = bound.sum(weights, count)
        // A frame without energy has no centroid: the last value is repeated with confidence 0,
        // and nothing is divided by a sum that is zero, below the floor, or not a number (NUM-1).
        guard total > floor, total.isFinite else {
            output.emit(scalar: ScalarFrame(value: last, confidence: 0))
            return
        }
        let centroid = bound.dot(UnsafePointer(ramp.baseAddress), weights, count) / total
        guard centroid.isFinite else {
            output.emit(scalar: ScalarFrame(value: last, confidence: 0))
            return
        }
        last = centroid
        output.emit(scalar: ScalarFrame(value: centroid, confidence: 1))
    }

    func reset() {
        last = 0
    }
}
