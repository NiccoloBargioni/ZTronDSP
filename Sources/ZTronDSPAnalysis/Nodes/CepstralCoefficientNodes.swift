import Accelerate
import ZTronDSPCore

// The two implementations of the DCT behind the cepstral coefficients (WP-512, §7.4), and the
// transposed basis that undoes them.
//
// Analysis thread: nothing here allocates, locks or logs after an initialiser returns.

/// The vDSP DCT-II, for a band count the transform documents. vDSP computes
/// `Σ x[j]·cos(π·k·(j + ½) / N)`: the orthonormal form is that times `√(2 / N)`, and the first
/// coefficient times `√½` more.
final class CosineTransformNode: AnalysisNode {
    private let bands: Int
    private let count: Int
    private let setup: vDSP_DFT_Setup
    private let input: AlignedBuffer<Float>
    private let transformed: AlignedBuffer<Float>

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(bands: Int, count: Int) throws(DSPError) {
        // Creating a DCT setup is not a safe test of a length (E-09): the rule comes first.
        try TransformLength.admit(bands, parameter: "bands")
        self.bands = bands
        self.count = count
        input = try AlignedBuffer<Float>(count: bands)
        transformed = try AlignedBuffer<Float>(count: bands)
        TransformSetup.willCreate("DCT", length: bands)
        // coverage:ignore(vDSP grants a setup for every length the rule admits: a refusal cannot be provoked by a test)
        guard let setup = vDSP_DCT_CreateSetup(nil, vDSP_Length(bands), .II) else {
            throw .resourceAllocationFailed(what: "a cosine-transform setup of \(bands) points")
        }
        self.setup = setup
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= bands, let values = frame.values.baseAddress, let result = output.real.baseAddress else { return }
        memcpy(self.input.baseAddress, values, bands * MemoryLayout<Float>.stride)
        vDSP_DCT_Execute(setup, self.input.baseAddress, transformed.baseAddress)
        var scale = (2 / Float(bands)).squareRoot()
        vDSP_vsmul(transformed.baseAddress, 1, &scale, result, 1, vDSP_Length(count))
        result[0] *= Float(0.5).squareRoot()
        output.emit(count: count)
    }

    func reset() {}
}

/// The DCT as a pre-computed basis and one `cblas_sgemv`: forward for any band count, and
/// transposed for the way back.
final class CosineBasisNode: AnalysisNode {
    private let bands: Int
    private let count: Int
    private let isInverse: Bool
    private let basis: AlignedBuffer<Float>

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(bands: Int, count: Int, isInverse: Bool) throws(DSPError) {
        self.bands = bands
        self.count = count
        self.isInverse = isInverse
        basis = try AlignedBuffer<Float>(copying: CosineBasis.orthonormal(bands: bands, count: count))
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, let values = frame.values.baseAddress, let result = output.real.baseAddress else { return }
        if isInverse {
            guard frame.count >= count else { return }
            cblas_sgemv(CblasRowMajor, CblasTrans, Int32(count), Int32(bands), 1, basis.baseAddress, Int32(bands), values, 1, 0, result, 1)
            output.emit(count: bands)
        } else {
            guard frame.count >= bands else { return }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(count), Int32(bands), 1, basis.baseAddress, Int32(bands), values, 1, 0, result, 1)
            output.emit(count: count)
        }
    }

    func reset() {}
}
