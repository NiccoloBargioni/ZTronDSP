import Accelerate
import ZTronDSPCore

// The transform plans (WP-502). Everything here but the initialisers runs on the analysis
// thread: no allocation, no lock, `while` loops only (RT-2, CR-002).

/// The real transform of vDSP, single precision: what `FFTBackend.vDSP` makes.
///
/// `vDSP_DFT_zrop` takes the signal as its even and its odd samples and returns twice the DFT,
/// with the Nyquist bin in the place of the imaginary part of bin 0; its inverse returns `N`
/// times the signal. Both factors are absorbed here (§6.1): the signal is halved while it is
/// split, which is exact, and the inverse is scaled while it is put back together.
///
/// Every buffer handed to the transform is the plan's own, 64-byte aligned.
final class VDSPFFTPlan: FFTPlan {
    let length: Int
    private let half: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let even: AlignedBuffer<Float>
    private let odd: AlignedBuffer<Float>
    private let first: AlignedBuffer<Float>
    private let second: AlignedBuffer<Float>

    init(length: Int) throws(DSPError) {
        try TransformLength.admit(length)
        self.length = length
        self.half = length / 2
        even = try AlignedBuffer<Float>(count: length / 2)
        odd = try AlignedBuffer<Float>(count: length / 2)
        first = try AlignedBuffer<Float>(count: length / 2)
        second = try AlignedBuffer<Float>(count: length / 2)
        TransformSetup.willCreate("DFT", length: length)
        // coverage:ignore(vDSP grants a setup for every length the rule admits: a refusal cannot be provoked by a test)
        guard let forward = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(length), .FORWARD) else {
            throw .resourceAllocationFailed(what: "a transform setup of \(length) points")
        }
        // coverage:ignore(vDSP grants a setup for every length the rule admits: a refusal cannot be provoked by a test)
        guard let inverse = vDSP_DFT_zrop_CreateSetup(forward, vDSP_Length(length), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw .resourceAllocationFailed(what: "an inverse transform setup of \(length) points")
        }
        forwardSetup = forward
        inverseSetup = inverse
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func forward(_ signal: UnsafePointer<Float>, real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>) {
        let count = vDSP_Length(half)
        // Even and odd samples apart, each halved: the transform returns twice the DFT.
        var scale: Float = 0.5
        vDSP_vsmul(signal, 2, &scale, even.baseAddress, 1, count)
        vDSP_vsmul(signal + 1, 2, &scale, odd.baseAddress, 1, count)
        vDSP_DFT_Execute(forwardSetup, even.baseAddress, odd.baseAddress, first.baseAddress, second.baseAddress)
        let stride = MemoryLayout<Float>.stride
        memcpy(real, first.baseAddress, half * stride)
        memcpy(imaginary, second.baseAddress, half * stride)
        // The Nyquist bin travels where the imaginary part of bin 0 would be.
        real[half] = imaginary[0]
        imaginary[0] = 0
        imaginary[half] = 0
    }

    func inverse(real: UnsafePointer<Float>, imaginary: UnsafePointer<Float>, into signal: UnsafeMutablePointer<Float>) {
        let count = vDSP_Length(half)
        let stride = MemoryLayout<Float>.stride
        memcpy(even.baseAddress, real, half * stride)
        memcpy(odd.baseAddress, imaginary, half * stride)
        odd.baseAddress[0] = real[half]
        vDSP_DFT_Execute(inverseSetup, even.baseAddress, odd.baseAddress, first.baseAddress, second.baseAddress)
        // Even and odd samples back together, each divided by N.
        var scale = 1 / Float(length)
        vDSP_vsmul(first.baseAddress, 1, &scale, signal, 2, count)
        vDSP_vsmul(second.baseAddress, 1, &scale, signal + 1, 2, count)
    }
}

/// The same transform in double precision, for the cepstral steps and for the analyses, whose
/// arithmetic is double (§6.1). It is not behind `FFTBackend`: nothing chooses it by name.
///
/// Created on the control context or in background work; `forward` and `inverse` allocate
/// nothing and belong to one thread at a time.
final class DoubleDFT {
    let length: Int
    private let half: Int
    private let forwardSetup: vDSP_DFT_SetupD
    private let inverseSetup: vDSP_DFT_SetupD
    private let even: AlignedBuffer<Double>
    private let odd: AlignedBuffer<Double>
    private let first: AlignedBuffer<Double>
    private let second: AlignedBuffer<Double>

    init(length: Int) throws(DSPError) {
        try TransformLength.admit(length)
        self.length = length
        self.half = length / 2
        even = try AlignedBuffer<Double>(count: length / 2)
        odd = try AlignedBuffer<Double>(count: length / 2)
        first = try AlignedBuffer<Double>(count: length / 2)
        second = try AlignedBuffer<Double>(count: length / 2)
        TransformSetup.willCreate("DFT", length: length)
        // coverage:ignore(vDSP grants a setup for every length the rule admits: a refusal cannot be provoked by a test)
        guard let forward = vDSP_DFT_zrop_CreateSetupD(nil, vDSP_Length(length), .FORWARD) else {
            throw .resourceAllocationFailed(what: "a transform setup of \(length) points")
        }
        // coverage:ignore(vDSP grants a setup for every length the rule admits: a refusal cannot be provoked by a test)
        guard let inverse = vDSP_DFT_zrop_CreateSetupD(forward, vDSP_Length(length), .INVERSE) else {
            vDSP_DFT_DestroySetupD(forward)
            throw .resourceAllocationFailed(what: "an inverse transform setup of \(length) points")
        }
        forwardSetup = forward
        inverseSetup = inverse
    }

    deinit {
        vDSP_DFT_DestroySetupD(forwardSetup)
        vDSP_DFT_DestroySetupD(inverseSetup)
    }

    /// Bins of a spectrum: `length / 2 + 1`.
    var binCount: Int { half + 1 }

    /// The unscaled DFT of `length` real samples, one-sided.
    func forward(_ signal: UnsafePointer<Double>, real: UnsafeMutablePointer<Double>, imaginary: UnsafeMutablePointer<Double>) {
        let count = vDSP_Length(half)
        var scale = 0.5
        vDSP_vsmulD(signal, 2, &scale, even.baseAddress, 1, count)
        vDSP_vsmulD(signal + 1, 2, &scale, odd.baseAddress, 1, count)
        vDSP_DFT_ExecuteD(forwardSetup, even.baseAddress, odd.baseAddress, first.baseAddress, second.baseAddress)
        let stride = MemoryLayout<Double>.stride
        memcpy(real, first.baseAddress, half * stride)
        memcpy(imaginary, second.baseAddress, half * stride)
        real[half] = imaginary[0]
        imaginary[0] = 0
        imaginary[half] = 0
    }

    /// The exact inverse of `forward`.
    func inverse(real: UnsafePointer<Double>, imaginary: UnsafePointer<Double>, into signal: UnsafeMutablePointer<Double>) {
        let count = vDSP_Length(half)
        let stride = MemoryLayout<Double>.stride
        memcpy(even.baseAddress, real, half * stride)
        memcpy(odd.baseAddress, imaginary, half * stride)
        odd.baseAddress[0] = real[half]
        vDSP_DFT_ExecuteD(inverseSetup, even.baseAddress, odd.baseAddress, first.baseAddress, second.baseAddress)
        var scale = 1 / Double(length)
        vDSP_vsmulD(first.baseAddress, 1, &scale, signal, 2, count)
        vDSP_vsmulD(second.baseAddress, 1, &scale, signal + 1, 2, count)
    }
}
