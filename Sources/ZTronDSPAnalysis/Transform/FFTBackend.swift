import Foundation
import ZTronDSPCore

/// The Fourier transform behind the spectral steps, as a strategy (§5.3): pass `.vDSP`, or a
/// conformer of your own, where a step is declared.
///
/// ```swift
/// STFT(frame: 2_048, hop: 512, backend: .vDSP)
/// ```
///
/// A backend is a description: an immutable value, usable on any thread, and part of the
/// description of the stage that holds it; the stock one does not allocate. The work is done
/// by the plans it makes, and making one allocates.
public protocol FFTBackend: Hashable, Sendable {
    /// Whether the backend transforms frames of `length` points. The answer is arithmetic:
    /// no setup is created to find out (E-09). Any thread.
    func supports(length: Int) -> Bool

    /// The setups and work buffers of real transforms of `length` points, with their lifetime
    /// (§5.11.4). Control context: it allocates.
    ///
    /// - Throws: `DSPError.invalidParameter` for a length the backend does not transform (the
    ///   reason names the nearest lengths it does), `DSPError.resourceAllocationFailed` when a
    ///   setup cannot be had.
    func makePlan(length: Int) throws(DSPError) -> any FFTPlan
}

/// Real transforms of one length, forward and inverse (§6.1).
///
/// A spectrum is one-sided: bins `0 … length / 2`, real and imaginary parts apart. The forward
/// transform is the mathematically unscaled DFT, `X[k] = Σ x[n]·e^(−j2πkn/N)`; the inverse is
/// its exact inverse, `x[n] = (1/N)·Σ X[k]·e^(+j2πkn/N)` over the Hermitian extension of the
/// bins, so `inverse(forward(x))` is `x`. Whatever factor a library applies is absorbed here.
///
/// Threading: a plan is created and released on the control context. `forward` and `inverse`
/// do not allocate and take no lock; they belong to one thread at a time (the analysis
/// thread). A plan is not `Sendable`.
public protocol FFTPlan: AnyObject {
    /// The transform length, `N`.
    var length: Int { get }

    /// The spectrum of `length` real samples: `length / 2 + 1` bins into `real` and
    /// `imaginary`. The imaginary parts of bin 0 and of the last bin are 0. The three buffers
    /// must not overlap.
    func forward(_ signal: UnsafePointer<Float>, real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>)

    /// The `length` real samples whose spectrum is the `length / 2 + 1` bins given. The
    /// imaginary parts of bin 0 and of the last bin are not read. The three buffers must not
    /// overlap.
    func inverse(real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>, into signal: UnsafeMutablePointer<Float>)
}

extension FFTPlan {
    /// Bins of a spectrum: `length / 2 + 1`. Usable on any thread; it does not allocate.
    public var binCount: Int { length / 2 + 1 }
}

/// The vDSP discrete Fourier transform (§6.4.1, §7.2 row 1). The length is a power of two, or
/// `f·2ⁿ` with `f` of 3, 5 or 15, and `n ≥ 4` in every case; the rule is applied by arithmetic.
///
/// An immutable value, usable on any thread; it does not allocate. `makePlan` runs on the
/// control context and allocates.
public struct VDSPFFTBackend: FFTBackend {
    /// The vDSP transform; there is nothing to set.
    public init() {}

    /// True for a power of two, or `f·2ⁿ` with `f` of 3, 5 or 15, `n ≥ 4` in every case: by
    /// arithmetic (E-09).
    public func supports(length: Int) -> Bool {
        DSP.isFastLength(length)
    }

    /// The vDSP setups of `length` points, forward and inverse, with their work buffers.
    public func makePlan(length: Int) throws(DSPError) -> any FFTPlan {
        try VDSPFFTPlan(length: length)
    }
}

extension FFTBackend where Self == VDSPFFTBackend {
    /// The vDSP transform, the default. Usable on any thread; it does not allocate.
    public static var vDSP: VDSPFFTBackend { VDSPFFTBackend() }
}

/// The length rule of the transforms, with the error that names the nearest legal lengths
/// (O-17). Arithmetic only: no setup is created to find out (E-09).
enum TransformLength {
    static func admit(_ length: Int, parameter: String = "length") throws(DSPError) {
        guard length >= 1 else {
            throw .invalidParameter(stage: .none, parameter: parameter, reason: "a length of \(length) holds no sample")
        }
        guard DSP.isFastLength(length) else {
            let nearest = [DSP.previousFastLength(length), DSP.nextFastLength(length)].compactMap { $0 }.map(String.init)
            throw .invalidParameter(
                stage: .none, parameter: parameter,
                reason: "\(length) is not a transform length (f·2ⁿ with f of 1, 3, 5 or 15 and n ≥ 4); the nearest are \(nearest.joined(separator: " and "))")
        }
    }
}

/// Where a transform setup is about to be created: what lets a test see that no setup call is
/// made for a length the rule refuses (WP-502). The observer is task-local, so tests that run
/// side by side do not hear one another; outside a test it is `nil` and costs one read on the
/// control context.
enum TransformSetup {
    @TaskLocal static var observer: (@Sendable (_ kind: String, _ length: Int) -> Void)?

    static func willCreate(_ kind: String, length: Int) {
        observer?(kind, length)
    }
}
