import Darwin
import ZTronDSPCore

/// The node of `ComplexPacking`: the real parts of a complex frame, then its imaginary parts.
/// Analysis thread: it allocates nothing.
final class ComplexPackingNode: AnalysisNode {
    private let bins: Int

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(bins: Int) {
        self.bins = bins
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let spectrum = input.complex, spectrum.count >= bins, let real = spectrum.real.baseAddress,
              let imaginary = spectrum.imaginary.baseAddress, let values = output.real.baseAddress
        else { return }
        let stride = MemoryLayout<Float>.stride
        memcpy(values, real, bins * stride)
        memcpy(values + bins, imaginary, bins * stride)
        output.emit(count: 2 * bins)
    }

    func reset() {}
}
