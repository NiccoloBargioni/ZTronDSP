import Foundation
import ZTronDSPCore

extension DSP {
    /// The DFT of a real signal in double precision, one-sided: bins `0 … N / 2`, unscaled,
    /// `X[k] = Σ x[n]·e^(−j2πkn/N)` (§6.1).
    ///
    /// A one-shot computation: synchronous, it runs where it is called and allocates (§9.2).
    ///
    /// - Throws: `DSPError.invalidParameter` when the length is not a transform length; the
    ///   reason names the nearest lengths that are. `DSP.nextFastLength` and `zeroPadded`
    ///   bring any signal to one.
    public static func realDFT(_ signal: [Double]) throws(DSPError) -> (real: [Double], imaginary: [Double]) {
        let transform = try DoubleDFT(length: signal.count)
        var real = [Double](repeating: 0, count: transform.binCount)
        var imaginary = [Double](repeating: 0, count: transform.binCount)
        signal.withUnsafeBufferPointer { source in
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    guard let from = source.baseAddress, let toReal = re.baseAddress, let toImaginary = im.baseAddress else { return }
                    transform.forward(from, real: toReal, imaginary: toImaginary)
                }
            }
        }
        return (real, imaginary)
    }

    /// The real signal whose one-sided spectrum is given: the exact inverse of ``realDFT(_:)``.
    /// `N / 2 + 1` bins give `N` samples. The imaginary parts of the first and the last bin
    /// are not read.
    ///
    /// - Throws: `DSPError.invalidParameter` when the two arrays differ in length, or when
    ///   `2·(bins − 1)` is not a transform length.
    public static func inverseRealDFT(real: [Double], imaginary: [Double]) throws(DSPError) -> [Double] {
        guard real.count == imaginary.count else {
            throw .invalidParameter(stage: .none, parameter: "imaginary", reason: "\(real.count) real parts and \(imaginary.count) imaginary parts")
        }
        let transform = try DoubleDFT(length: 2 * (real.count - 1))
        var signal = [Double](repeating: 0, count: transform.length)
        real.withUnsafeBufferPointer { re in
            imaginary.withUnsafeBufferPointer { im in
                signal.withUnsafeMutableBufferPointer { target in
                    guard let fromReal = re.baseAddress, let fromImaginary = im.baseAddress, let to = target.baseAddress else { return }
                    transform.inverse(real: fromReal, imaginary: fromImaginary, into: to)
                }
            }
        }
        return signal
    }
}
