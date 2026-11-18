import ZTronDSPCore

// The analysis-thread half of `ChromaFold` (WP-524). Nothing here allocates, locks or logs
// after its initialiser returns; loops are `while` loops (RT-2, CR-002).

/// Folds the magnitudes of a constant-Q frame onto the twelve pitch classes, discards what
/// lies below the threshold, and divides by the frame's norm.
final class ChromaFoldNode: AnalysisNode {
    private let binCount: Int
    /// The pitch class of each bin, 0 … 11.
    private let classes: AlignedBuffer<Int32>
    private let threshold: Float
    private let floor: Float
    private let normalization: any ChromaNormalization

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    /// Pitch classes of an octave.
    static let classCount = 12

    init(classes: [Int32], threshold: Float, floor: Float, normalization: any ChromaNormalization) throws(DSPError) {
        binCount = classes.count
        self.classes = try AlignedBuffer<Int32>(count: classes.count)
        var bin = 0
        while bin < classes.count {
            // A class outside 0 … 11 has no row to be summed into.
            self.classes.baseAddress[bin] = Swift.min(Swift.max(classes[bin], 0), Int32(ChromaFoldNode.classCount - 1))
            bin += 1
        }
        self.threshold = threshold
        self.floor = floor
        self.normalization = normalization
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= binCount, let magnitudes = frame.values.baseAddress,
              let chroma = output.real.baseAddress, output.real.count >= ChromaFoldNode.classCount
        else { return }
        let count = ChromaFoldNode.classCount
        var index = 0
        while index < count {
            chroma[index] = 0
            index &+= 1
        }
        var bin = 0
        while bin < binCount {
            chroma[Int(classes.baseAddress[bin])] += magnitudes[bin]
            bin &+= 1
        }
        // What lies below the threshold is discarded; what is left is checked for a number.
        var total: Float = 0
        index = 0
        while index < count {
            if chroma[index] < threshold { chroma[index] = 0 }
            total += chroma[index]
            index &+= 1
        }
        let norm = normalization.norm(of: UnsafeBufferPointer(start: chroma, count: count))
        // A frame without a norm to divide by, or with a sum that is no number, is twelve
        // zeros: nothing is divided by next to nothing, and no NaN leaves the step (NUM-1).
        let isDivisible = total.isFinite && norm.isFinite && norm >= floor && norm > 0
        index = 0
        while index < count {
            // A division, so that the value the norm was read from comes out as exactly 1; and
            // zero written, not multiplied by: a sum that overflowed times zero is no number.
            chroma[index] = isDivisible ? chroma[index] / norm : 0
            index &+= 1
        }
        output.emit(count: count)
    }

    func reset() {}
}
