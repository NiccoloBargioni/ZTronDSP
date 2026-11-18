import Accelerate
import ZTronDSPCore

// The nodes of the cepstral steps (WP-509, WP-510, WP-511). The logarithms, the phase and the
// two transforms are double precision: the frames that travel are single (§6.1).
//
// Analysis thread: nothing here allocates, locks or logs after an initialiser returns; loops
// are `while` loops (RT-2, CR-002).

/// The node of `Cepstrum`: logarithm of the spectrum, inverse transform.
final class CepstrumNode: AnalysisNode {
    private let kind: CepstrumKind
    private let floor: Double
    private let length: Int
    private let bins: Int
    private let transform: DoubleDFT
    private let real: AlignedBuffer<Double>
    private let imaginary: AlignedBuffer<Double>
    private let logarithm: AlignedBuffer<Double>
    private let phase: AlignedBuffer<Double>
    private let cepstrum: AlignedBuffer<Double>

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(kind: CepstrumKind, floor: Double, length: Int) throws(DSPError) {
        self.kind = kind
        self.floor = floor
        self.length = length
        bins = length / 2 + 1
        transform = try DoubleDFT(length: length)
        real = try AlignedBuffer<Double>(count: bins)
        imaginary = try AlignedBuffer<Double>(count: bins)
        logarithm = try AlignedBuffer<Double>(count: bins)
        phase = try AlignedBuffer<Double>(count: bins)
        cepstrum = try AlignedBuffer<Double>(count: length)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let spectrum = input.complex, spectrum.count >= bins, let sourceReal = spectrum.real.baseAddress,
              let sourceImaginary = spectrum.imaginary.baseAddress, let values = output.real.baseAddress
        else { return }
        let count = vDSP_Length(bins)
        var size = Int32(bins)
        vDSP_vspdp(sourceReal, 1, real.baseAddress, 1, count)
        vDSP_vspdp(sourceImaginary, 1, imaginary.baseAddress, 1, count)

        // ln of the floored argument, from |X|²: ln |X| is half of ln |X|².
        var split = DSPDoubleSplitComplex(realp: real.baseAddress, imagp: imaginary.baseAddress)
        vDSP_zvmagsD(&split, 1, logarithm.baseAddress, 1, count)
        var threshold = kind == .power ? floor : floor * floor
        vDSP_vthrD(logarithm.baseAddress, 1, &threshold, logarithm.baseAddress, 1, count)
        vvlog(logarithm.baseAddress, logarithm.baseAddress, &size)
        if kind != .power {
            var half = 0.5
            vDSP_vsmulD(logarithm.baseAddress, 1, &half, logarithm.baseAddress, 1, count)
        }

        var delay = 0.0
        var sign: Float = 1
        if kind == .complex {
            vvatan2(phase.baseAddress, imaginary.baseAddress, real.baseAddress, &size)
            let angles = phase.baseAddress
            // Unwrap along the bins: a step of more than π is taken to be a wrap.
            var previous = angles[0]
            var turns = 0.0
            var bin = 1
            while bin < bins {
                let wrapped = angles[bin]
                let step = wrapped - previous
                if step > .pi { turns -= 2 * .pi } else if step < -.pi { turns += 2 * .pi }
                previous = wrapped
                angles[bin] = wrapped + turns
                bin &+= 1
            }
            // Bin 0 of a real signal is real: its phase is 0 or π, which is a sign. With the
            // sign taken out the phase starts at 0, and at the Nyquist bin it is a whole number
            // of half turns: the delay, in samples. Take the ramp of that delay out.
            let base = angles[0]
            if real.baseAddress[0] < 0 { sign = -1 }
            delay = ((angles[bins - 1] - base) / .pi).rounded()
            let slope = .pi * delay / Double(bins - 1)
            bin = 0
            while bin < bins {
                angles[bin] = angles[bin] - base - slope * Double(bin)
                bin &+= 1
            }
        } else {
            phase.clear()
        }

        transform.inverse(real: UnsafePointer(logarithm.baseAddress), imaginary: UnsafePointer(phase.baseAddress), into: cepstrum.baseAddress)
        switch kind {
        case .real:
            vDSP_vdpsp(cepstrum.baseAddress, 1, values, 1, count)
            output.emit(count: bins)
        case .power:
            vDSP_vsqD(cepstrum.baseAddress, 1, cepstrum.baseAddress, 1, count)
            vDSP_vdpsp(cepstrum.baseAddress, 1, values, 1, count)
            output.emit(count: bins)
        case .complex:
            vDSP_vdpsp(cepstrum.baseAddress, 1, values, 1, vDSP_Length(length))
            values[length] = Float(delay / Double(length))
            values[length + 1] = sign
            output.emit(count: length + CepstrumLayout.trailer)
        }
    }

    func reset() {}
}

/// The node of `InverseCepstrum`: transform, exponential, the delay and the sign put back.
final class InverseCepstrumNode: AnalysisNode {
    private let length: Int
    private let bins: Int
    private let transform: DoubleDFT
    private let cepstrum: AlignedBuffer<Double>
    private let logarithm: AlignedBuffer<Double>
    private let phase: AlignedBuffer<Double>
    private let magnitude: AlignedBuffer<Double>
    private let sine: AlignedBuffer<Double>
    private let cosine: AlignedBuffer<Double>

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(length: Int) throws(DSPError) {
        self.length = length
        bins = length / 2 + 1
        transform = try DoubleDFT(length: length)
        cepstrum = try AlignedBuffer<Double>(count: length)
        logarithm = try AlignedBuffer<Double>(count: bins)
        phase = try AlignedBuffer<Double>(count: bins)
        magnitude = try AlignedBuffer<Double>(count: bins)
        sine = try AlignedBuffer<Double>(count: bins)
        cosine = try AlignedBuffer<Double>(count: bins)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= length + CepstrumLayout.trailer, let values = frame.values.baseAddress,
              let real = output.real.baseAddress, let imaginary = output.imaginary.baseAddress
        else { return }
        let count = vDSP_Length(bins)
        var size = Int32(bins)
        vDSP_vspdp(values, 1, cepstrum.baseAddress, 1, vDSP_Length(length))
        transform.forward(UnsafePointer(cepstrum.baseAddress), real: logarithm.baseAddress, imaginary: phase.baseAddress)

        let delay = (Double(values[length]) * Double(length)).rounded()
        var sign: Double = values[length + 1] < 0 ? -1 : 1
        let slope = .pi * delay / Double(bins - 1)
        let angles = phase.baseAddress
        var bin = 0
        while bin < bins {
            angles[bin] += slope * Double(bin)
            bin &+= 1
        }
        vvexp(magnitude.baseAddress, logarithm.baseAddress, &size)
        vvsincos(sine.baseAddress, cosine.baseAddress, phase.baseAddress, &size)
        vDSP_vsmulD(magnitude.baseAddress, 1, &sign, magnitude.baseAddress, 1, count)
        vDSP_vmulD(magnitude.baseAddress, 1, cosine.baseAddress, 1, cosine.baseAddress, 1, count)
        vDSP_vmulD(magnitude.baseAddress, 1, sine.baseAddress, 1, sine.baseAddress, 1, count)
        vDSP_vdpsp(cosine.baseAddress, 1, real, 1, count)
        vDSP_vdpsp(sine.baseAddress, 1, imaginary, 1, count)
        // The first and the last bin of a real signal are real.
        imaginary[0] = 0
        imaginary[bins - 1] = 0
        output.emit(count: bins)
    }

    func reset() {}
}

/// The node of `Lifter`: the cepstrum times a table computed once.
final class LifterNode: AnalysisNode {
    private let weights: AlignedBuffer<Float>
    private let bound: Vector.Bound

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(weights: [Float], bound: Vector.Bound) throws(DSPError) {
        self.weights = try AlignedBuffer<Float>(copying: weights)
        self.bound = bound
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, frame.count >= weights.count, let values = frame.values.baseAddress, let result = output.real.baseAddress else { return }
        bound.multiply(values, UnsafePointer(weights.baseAddress), result, weights.count)
        output.emit(count: weights.count)
    }

    func reset() {}
}

/// The node of `CepstralPitch`: the peak inside the range, a parabola through it and its
/// neighbours, and the confidence.
final class CepstralPitchNode: AnalysisNode {
    private let first: Int
    private let count: Int
    private let sampleRate: Double
    private var last: Float = 0

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(first: Int, count: Int, sampleRate: Double) {
        self.first = first
        self.count = count
        self.sampleRate = sampleRate
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        // The range leaves a neighbour on either side of every candidate.
        guard let frame = input.real, frame.count >= first + count + 1, first >= 1, let values = frame.values.baseAddress else { return }
        let range = values + first
        var peak: Float = 0
        var offset: vDSP_Length = 0
        vDSP_maxvi(range, 1, &peak, &offset, vDSP_Length(count))
        // No positive peak: no pitch. The last value is repeated with confidence 0 (NUM-1).
        guard peak > 0, peak.isFinite else {
            output.emit(scalar: ScalarFrame(value: last, confidence: 0))
            return
        }
        let index = first + Int(offset)
        let before = Double(values[index - 1]), at = Double(values[index]), after = Double(values[index + 1])
        let curvature = before - 2 * at + after
        var shift = 0.0
        if curvature < 0 {
            shift = 0.5 * (before - after) / curvature
            if shift > 0.5 { shift = 0.5 } else if shift < -0.5 { shift = -0.5 }
        }
        // The peak lies at quefrency 1 or later and the shift is at most half a sample: the
        // period is at least half a sample, and the pitch a finite number.
        let pitch = Float(sampleRate / (Double(index) + shift))
        var mean: Float = 0
        vDSP_meamgv(range, 1, &mean, vDSP_Length(count))
        var confidence = 1 - mean / peak
        if !(confidence > 0) { confidence = 0 } else if confidence > 1 { confidence = 1 }
        last = pitch
        output.emit(scalar: ScalarFrame(value: pitch, confidence: confidence))
    }

    func reset() {
        last = 0
    }
}
