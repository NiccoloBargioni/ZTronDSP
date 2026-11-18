import Accelerate
import ZTronDSPCore

/// The node of the value steps (WP-534): magnitudes and powers of a complex frame, decibels
/// of a real one, and back. It keeps no state: a frame out for every frame in, bin for bin.
///
/// Analysis thread: nothing here allocates, locks or logs.
final class SpectralValueNode: AnalysisNode {
    private let operation: SpectralValueOperation
    private let bins: Int

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(_ operation: SpectralValueOperation, bins: Int) {
        self.operation = operation
        self.bins = bins
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let values = output.real.baseAddress else { return }
        switch operation {
        case .magnitude, .power:
            guard let spectrum = input.complex, let real = spectrum.real.baseAddress, let imaginary = spectrum.imaginary.baseAddress else { return }
            let count = min(spectrum.count, bins)
            var split = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: real), imagp: UnsafeMutablePointer(mutating: imaginary))
            if operation == .magnitude {
                vDSP_zvabs(&split, 1, values, 1, vDSP_Length(count))
            } else {
                vDSP_zvmags(&split, 1, values, 1, vDSP_Length(count))
            }
            output.emit(count: count)
        case .decibelsFromAmplitude(let reference, let floor):
            guard let frame = input.real, let source = frame.values.baseAddress else { return }
            let count = min(frame.count, bins)
            DSP.decibels(fromAmplitude: source, into: values, count: count, reference: reference, floor: floor)
            output.emit(count: count)
        case .decibelsFromPower(let reference, let floor):
            guard let frame = input.real, let source = frame.values.baseAddress else { return }
            let count = min(frame.count, bins)
            DSP.decibels(fromPower: source, into: values, count: count, reference: reference, floor: floor)
            output.emit(count: count)
        case .amplitudeFromDecibels(let reference):
            guard let frame = input.real, let source = frame.values.baseAddress else { return }
            let count = min(frame.count, bins)
            DSP.amplitude(fromDecibels: source, into: values, count: count, reference: reference)
            output.emit(count: count)
        case .powerFromDecibels(let reference):
            guard let frame = input.real, let source = frame.values.baseAddress else { return }
            let count = min(frame.count, bins)
            DSP.power(fromDecibels: source, into: values, count: count, reference: reference)
            output.emit(count: count)
        }
    }

    func reset() {}
}
