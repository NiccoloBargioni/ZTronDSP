import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

// What the tests of the constant-Q transform and of chroma share: the definitions of §6.8
// written out in double precision, as the oracle the package's own arithmetic is held
// against, and the golden cases read as the steps they describe.

/// The frequency of a MIDI note in hertz: note 24 is C1, 32.70 Hz.
func noteFrequency(_ note: Double) -> Double {
    440 * pow(2, (note - 69) / 12)
}

/// The periodic Hann window as a function of `t` in `0 … 1`.
func hannShape(_ t: Double) -> Double {
    0.5 - 0.5 * cos(2 * .pi * t)
}

/// The atom of §6.8 for a bin, centred on offset 0: `(2 / Σw) · w(½ + m / N) · e^(j2πνm)` for
/// `m = −⌊N/2⌋ … ⌈N/2⌉ − 1`, with `ν` in cycles per sample.
func referenceAtom(
    length: Int, cyclesPerSample: Double, window: (Double) -> Double = hannShape
) -> (first: Int, real: [Double], imaginary: [Double]) {
    let first = -(length / 2)
    let shape = (0 ..< length).map { window(0.5 + Double(first + $0) / Double(length)) }
    let gain = 2 / shape.reduce(0, +)
    var real = [Double](repeating: 0, count: length), imaginary = real
    for index in 0 ..< length {
        let phase = 2 * Double.pi * cyclesPerSample * Double(first + index)
        real[index] = gain * shape[index] * cos(phase)
        imaginary[index] = gain * shape[index] * sin(phase)
    }
    return (first, real, imaginary)
}

/// The constant-Q transform by its definition (§6.8), in double precision:
/// `X[n, k] = Σ_m x[n · hop + m] · conj(aₖ[m])`, the signal zero outside itself. Nothing of
/// the method under test is used: no octaves, no decimation, no kernel.
func referenceConstantQ(
    _ samples: [Float], geometry: ConstantQGeometry, hop: Int, frames: Int, window: (Double) -> Double = hannShape
) -> (real: [[Double]], imaginary: [[Double]]) {
    var real = [[Double]](repeating: [Double](repeating: 0, count: geometry.binCount), count: frames), imaginary = real
    for bin in 0 ..< geometry.binCount {
        let atom = referenceAtom(length: geometry.atomLength(ofBin: bin), cyclesPerSample: geometry.frequency(ofBin: bin) / geometry.sampleRate, window: window)
        for frame in 0 ..< frames {
            var sumReal = 0.0, sumImaginary = 0.0
            let origin = frame * hop + atom.first
            let lower = max(0, -origin), upper = min(atom.real.count, samples.count - origin)
            var index = lower
            while index < upper {
                let sample = Double(samples[origin + index])
                // x · conj(a)
                sumReal += sample * atom.real[index]
                sumImaginary -= sample * atom.imaginary[index]
                index += 1
            }
            real[frame][bin] = sumReal
            imaginary[frame][bin] = sumImaginary
        }
    }
    return (real, imaginary)
}

/// `|re + j·im|`, element by element.
func magnitudes(_ real: [Float], _ imaginary: [Float]) -> [Double] {
    zip(real, imaginary).map { hypot(Double($0), Double($1)) }
}

/// The cosine of the angle between two vectors; 1 for two vectors of zeros, which agree.
func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0, aa = 0.0, bb = 0.0
    for (x, y) in zip(a, b) {
        dot += x * y
        aa += x * x
        bb += y * y
    }
    if aa == 0 && bb == 0 { return 1 }
    guard aa > 0, bb > 0 else { return 0 }
    return dot / (aa * bb).squareRoot()
}

/// The index of the largest element.
func indexOfMaximum(_ values: [Double]) -> Int {
    var best = 0
    for index in values.indices where values[index] > values[best] { best = index }
    return best
}

/// The bins a golden case of `constant_q.json` describes.
func geometry(of golden: GoldenCase, sampleRate: Double? = nil) throws -> ConstantQGeometry {
    try ConstantQGeometry(
        minimumFrequency: try golden.number("fmin"), octaves: try golden.integer("octaves"), binsPerOctave: try golden.integer("binsPerOctave"),
        tuning: try golden.number("tuning"), filterScale: try golden.number("filterScale"), gamma: try golden.number("gamma"),
        sampleRate: try sampleRate ?? golden.number("sampleRate"))
}

/// The transform a golden case of `constant_q.json` describes.
func constantQ(of golden: GoldenCase, sparsity: Double = 0.01) throws -> ConstantQ {
    ConstantQ(
        fmin: .hertz(try golden.number("fmin")), octaves: try golden.integer("octaves"), binsPerOctave: try golden.integer("binsPerOctave"),
        tuning: try golden.number("tuning"), filterScale: try golden.number("filterScale"), gamma: try golden.number("gamma"),
        hop: try golden.integer("hop"), sparsity: sparsity)
}

/// The samples and the format of the fixture a golden case names.
func fixture(of golden: GoldenCase) throws -> (samples: [Float], format: SignalFormat) {
    let fixture = try GoldenFile(named: "fixtures", in: .module).require(try golden.string("fixture"))
    return (try fixture.floats("samples"), SignalFormat(sampleRate: try fixture.number("sampleRate")))
}

/// The largest distance of a frame from its reference, over all frames, each relative to the
/// largest magnitude of its reference frame (§6.1).
func worstDeviation(
    _ sink: CollectingSink<Spectrum<ConstantQFrequency, ComplexValues>>, real: [Double], imaginary: [Double], bins: Int, frames: Int
) -> (worst: Double, mean: Double) {
    var worst = 0.0, total = 0.0
    for frame in 0 ..< frames {
        let range = frame * bins ..< (frame + 1) * bins
        let deviation = complexDeviation(sink.reals[frame], sink.imaginaries[frame], Array(real[range]), Array(imaginary[range]))
        worst = max(worst, deviation)
        total += deviation
    }
    return (worst, frames > 0 ? total / Double(frames) : 0)
}

/// Runs a signal through one half-band decimator in blocks of 300 samples.
func halved(_ signal: [Float], by decimator: HalfBandDecimator) -> [Float] {
    var output = [Float](repeating: 0, count: signal.count / 2 + 2)
    var written = 0, position = 0
    signal.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { target in
            guard let from = source.baseAddress, let to = target.baseAddress else { return }
            while position < signal.count {
                let count = min(300, signal.count - position)
                written += decimator.process(from + position, count: count, into: to + written)
                position += count
            }
        }
    }
    return Array(output[..<written])
}

/// A constant-Q strategy of the tests' own: it computes nothing and says so, with a delay
/// the test names. A strategy written outside the package is passed the same way (§5.3).
struct SilentStrategy: ConstantQStrategy {
    let delay: Int

    func latency(of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double) throws(DSPError) -> Int { delay }

    func makeNode(
        of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double, channel: Int?, channelCount: Int, maximumBlockFrames: Int
    ) throws(DSPError) -> any AnalysisNode {
        SilentNode(delay: delay)
    }
}

/// The node of `SilentStrategy`: it never writes a frame.
final class SilentNode: AnalysisNode {
    let latencyFrames: Int
    var settlingFrames: Int { 0 }

    init(delay: Int) {
        latencyFrames = delay
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {}
    func reset() {}
}
