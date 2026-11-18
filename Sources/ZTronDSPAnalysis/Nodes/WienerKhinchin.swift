import Accelerate
import ZTronDSPCore

/// The linear autocorrelation of a frame by the Wiener–Khinchin relation (§6.7, §7.2 row 11):
/// the inverse transform of the squared magnitude of the frame's spectrum,
///
///     r[ℓ] = Σₙ x[n]·x[n + ℓ],   ℓ = 0 ..< lagCount
///
/// The frame is followed by zeros up to a fast length at or above `frame + lagCount − 1`, so
/// that no product wraps round: the result is the linear autocorrelation, not the circular
/// one. It is what the `Autocorrelation` step, `DSP.autocorrelate` and the autocorrelation
/// tempogram share.
///
/// Created on the control context or in background work (it allocates). `autocorrelate`
/// allocates nothing, takes no lock and belongs to one thread at a time (RT-2).
final class WienerKhinchin {
    /// Samples per frame.
    let frame: Int
    /// Lags the transform gives: `0 ..< lagCount`.
    let lagCount: Int
    /// The transform length.
    let length: Int
    private let plan: any FFTPlan
    private let padded: AlignedBuffer<Float>
    private let real: AlignedBuffer<Float>
    private let imaginary: AlignedBuffer<Float>
    private let power: AlignedBuffer<Float>
    private let zeros: AlignedBuffer<Float>
    private let circular: AlignedBuffer<Float>

    /// The transform length for a frame and a number of lags: the padding rule of §6.7.
    static func transformLength(frame: Int, lagCount: Int) -> Int {
        DSP.nextFastLength(frame + lagCount - 1)
    }

    /// - Throws: `invalidParameter` for a frame or a number of lags below 1, or when the
    ///   backend does not transform the padded length; `resourceAllocationFailed`.
    init(frame: Int, lagCount: Int, backend: any FFTBackend = VDSPFFTBackend()) throws(DSPError) {
        guard frame >= 1, lagCount >= 1, frame <= 1 << 28, lagCount <= 1 << 28 else {
            throw .invalidParameter(stage: .none, parameter: "lagCount", reason: "an autocorrelation takes a frame of 1 to 2²⁸ samples and gives as many lags, not \(frame) and \(lagCount)")
        }
        self.frame = frame
        self.lagCount = lagCount
        length = WienerKhinchin.transformLength(frame: frame, lagCount: lagCount)
        guard backend.supports(length: length) else {
            throw .invalidParameter(stage: .none, parameter: "backend", reason: "\(type(of: backend)) does not transform frames of \(length) points")
        }
        plan = try backend.makePlan(length: length)
        let bins = length / 2 + 1
        padded = try AlignedBuffer<Float>(count: length)
        real = try AlignedBuffer<Float>(count: bins)
        imaginary = try AlignedBuffer<Float>(count: bins)
        power = try AlignedBuffer<Float>(count: bins)
        zeros = try AlignedBuffer<Float>(count: bins)
        circular = try AlignedBuffer<Float>(count: length)
    }

    /// The autocorrelation of the `frame` samples at `samples`: `lagCount` values into `lags`.
    /// A lag at or past the frame's length has no product and is 0.
    func autocorrelate(_ samples: UnsafePointer<Float>, into lags: UnsafeMutablePointer<Float>) {
        // The zeros behind the frame are never written: only the frame is copied.
        memcpy(padded.baseAddress, samples, frame * MemoryLayout<Float>.stride)
        plan.forward(padded.baseAddress, real: real.baseAddress, imaginary: imaginary.baseAddress)
        var spectrum = DSPSplitComplex(realp: real.baseAddress, imagp: imaginary.baseAddress)
        vDSP_zvmags(&spectrum, 1, power.baseAddress, 1, vDSP_Length(length / 2 + 1))
        plan.inverse(real: power.baseAddress, imaginary: zeros.baseAddress, into: circular.baseAddress)
        let stride = MemoryLayout<Float>.stride
        let known = min(lagCount, frame)
        memcpy(lags, circular.baseAddress, known * stride)
        // Beyond the frame there is no product: exactly 0, not the round-off of the transform.
        if lagCount > known { memset(lags + known, 0, (lagCount - known) * stride) }
    }
}
