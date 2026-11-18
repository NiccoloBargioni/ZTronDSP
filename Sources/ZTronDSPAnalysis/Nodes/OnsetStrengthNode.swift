import Accelerate
import ZTronDSPCore

/// The node of `OnsetStrength` (WP-525; §7.2 row 14): the positive part of the difference
/// between each frame of decibels and the reference of `lag` frames before, averaged over the
/// bands. The reference of a frame is the frame itself, raised to the floor, or its maximum
/// over `maxSize` bands (`vDSP_vswmax`).
///
/// Analysis thread: nothing here allocates, locks or logs after the initialiser returns.
final class OnsetStrengthNode: AnalysisNode {
    private let bands: Int
    private let lag: Int
    private let maxSize: Int
    private let floor: Float
    /// The references of the last `lag` frames, one after the other, as a ring.
    private let references: AlignedBuffer<Float>
    /// The frame with its values raised to the floor.
    private let raised: AlignedBuffer<Float>
    /// The raised frame with its edges reflected: what the maximum filter slides over.
    private let padded: AlignedBuffer<Float>
    private let difference: AlignedBuffer<Float>
    /// Frames seen since the last reset.
    private var seen = 0
    /// Where the oldest reference lies, and where the next one goes.
    private var slot = 0

    var latencyFrames: Int { 0 }
    let settlingFrames: Int

    init(bands: Int, lag: Int, maxSize: Int, floor: Float) throws(DSPError) {
        self.bands = bands
        self.lag = lag
        self.maxSize = maxSize
        self.floor = floor
        references = try AlignedBuffer<Float>(count: lag * bands)
        raised = try AlignedBuffer<Float>(count: bands)
        padded = try AlignedBuffer<Float>(count: bands + maxSize - 1)
        difference = try AlignedBuffer<Float>(count: bands)
        // A value compares frames that both arrived since a reset once `lag` frames have.
        settlingFrames = lag
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= bands, let values = frame.values.baseAddress else { return }
        let count = vDSP_Length(bands)
        // Raised to the floor first: under it, the difference of two logarithms is the
        // fluctuation of the noise floor, not an onset.
        var low = floor
        vDSP_vthr(values, 1, &low, raised.baseAddress, 1, count)

        let reference = references.baseAddress + slot * bands
        if seen >= lag {
            // The oldest reference is the one of `lag` frames ago.
            vDSP_vsub(reference, 1, raised.baseAddress, 1, difference.baseAddress, 1, count)
            var zero: Float = 0
            vDSP_vthr(difference.baseAddress, 1, &zero, difference.baseAddress, 1, count)
            var mean: Float = 0
            vDSP_meanv(difference.baseAddress, 1, &mean, count)
            output.emit(scalar: ScalarFrame(value: mean.isFinite ? mean : 0, confidence: mean.isFinite ? 1 : 0))
        } else {
            // Nothing to compare with yet: no value (§5.2).
            output.emit(scalar: ScalarFrame(value: 0, confidence: 0))
        }

        // This frame's reference takes the place of the oldest.
        if maxSize == 1 {
            memcpy(reference, raised.baseAddress, bands * MemoryLayout<Float>.stride)
        } else {
            // The window of band b runs from b − maxSize / 2 on; the edges are reflected, the
            // edge value repeated.
            let leading = maxSize / 2, trailing = maxSize - 1 - leading
            let target = padded.baseAddress
            var index = 0
            while index < leading {
                target[leading - 1 - index] = raised.baseAddress[index]
                index &+= 1
            }
            memcpy(target + leading, raised.baseAddress, bands * MemoryLayout<Float>.stride)
            index = 0
            while index < trailing {
                target[leading + bands + index] = raised.baseAddress[bands - 1 - index]
                index &+= 1
            }
            vDSP_vswmax(target, 1, reference, 1, count, vDSP_Length(maxSize))
        }
        slot &+= 1
        if slot == lag { slot = 0 }
        seen &+= 1
    }

    func reset() {
        seen = 0
        slot = 0
    }
}
