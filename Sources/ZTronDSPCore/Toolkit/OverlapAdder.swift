import Accelerate
import Darwin

/// Overlap-add with window-sum normalisation (§5.11.4, §6.4.1): the synthesis half of an STFT
/// round trip.
///
/// Each frame handed to `add` is multiplied by the synthesis window and summed into the
/// output at the next hop. The squares of the window are summed alongside, and each finished
/// sample is divided by that sum, so the result is exact wherever the sum is not zero, at the
/// start of the stream as in its steady state. Where the sum is below the floor the output is
/// zero (NUM-1).
///
/// Threading: create and release on the control context; creating one allocates its buffers.
/// `add` and `reset` do not allocate and belong to one thread at a time (the analysis thread).
public final class OverlapAdder {
    /// The length of each frame.
    public let frameSize: Int
    /// The samples between the starts of consecutive frames.
    public let hopSize: Int
    /// Window sums below this give a zero output sample.
    public let floor: Float
    @usableFromInline let window: AlignedBuffer<Float>
    @usableFromInline let windowSquared: AlignedBuffer<Float>
    @usableFromInline let accumulator: AlignedBuffer<Float>
    @usableFromInline let normaliser: AlignedBuffer<Float>

    /// - Parameters:
    ///   - frameSize: the length of each frame.
    ///   - hopSize: the samples between frame starts; `1 … frameSize`.
    ///   - window: the synthesis window, `frameSize` values.
    ///   - floor: the smallest window sum that is still divided by.
    /// - Throws: `DSPError.invalidParameter` for sizes that do not fit together.
    public init(frameSize: Int, hopSize: Int, window: [Float], floor: Float = 1e-10) throws(DSPError) {
        guard frameSize >= 1, hopSize >= 1, hopSize <= frameSize else {
            throw .invalidParameter(stage: .none, parameter: "hopSize", reason: "a hop of \(hopSize) does not fit a frame of \(frameSize)")
        }
        guard window.count == frameSize else {
            throw .invalidParameter(stage: .none, parameter: "window", reason: "the window has \(window.count) values, the frame \(frameSize)")
        }
        self.frameSize = frameSize
        self.hopSize = hopSize
        self.floor = floor
        self.window = try AlignedBuffer<Float>(copying: window)
        self.windowSquared = try AlignedBuffer<Float>(copying: window.map { $0 * $0 })
        self.accumulator = try AlignedBuffer<Float>(count: frameSize)
        self.normaliser = try AlignedBuffer<Float>(count: frameSize)
    }

    /// Adds one frame of `frameSize` samples and writes the `hopSize` samples it completes.
    @inlinable
    public func add(_ frame: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>) {
        let length = vDSP_Length(frameSize)
        let sum = accumulator.baseAddress
        let norm = normaliser.baseAddress
        // sum += frame · window;  norm += window²
        vDSP_vma(frame, 1, window.baseAddress, 1, sum, 1, sum, 1, length)
        vDSP_vadd(norm, 1, windowSquared.baseAddress, 1, norm, 1, length)

        var index = 0
        while index < hopSize {
            let weight = norm[index]
            output[index] = weight > floor ? sum[index] / weight : 0
            index &+= 1
        }

        let remaining = frameSize - hopSize
        let stride = MemoryLayout<Float>.stride
        if remaining > 0 {
            memmove(sum, sum + hopSize, remaining * stride)
            memmove(norm, norm + hopSize, remaining * stride)
        }
        memset(sum + remaining, 0, hopSize * stride)
        memset(norm + remaining, 0, hopSize * stride)
    }

    /// Writes the `frameSize − hopSize` samples still held, as at the end of a stream, and
    /// clears the state. `output` needs room for that many samples.
    public func flush(into output: UnsafeMutablePointer<Float>) {
        let remaining = frameSize - hopSize
        var index = 0
        while index < remaining {
            let weight = normaliser.baseAddress[index]
            output[index] = weight > floor ? accumulator.baseAddress[index] / weight : 0
            index &+= 1
        }
        reset()
    }

    /// Back to silence, as at creation (ACT-10).
    @inlinable
    public func reset() {
        accumulator.clear()
        normaliser.clear()
    }
}
