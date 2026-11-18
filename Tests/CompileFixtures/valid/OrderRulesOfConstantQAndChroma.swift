// The order rules of the constant-Q transform and of chroma, as far as they accept (§5.8,
// §6.8): every step where it belongs, in the builder and in the fluent spelling, with its
// recipe, its switch and strategies written outside the package.
import SwiftUI
import ZTronDSP

// A sequence stage of the fixture's own: the rules below do not depend on which one it is.
struct Halve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) { context.emit(.gain(factor: 0.5, ramp: 0)) }
}

@MainActor func accepted(flag: Bool, shown: Binding<Bool>, vector: Binding<[Float]>, level: Binding<Float>, chromagram: HeatmapFeed, heat: HeatmapFeed) {
    // The transform frames samples; value steps follow a complex spectrum on any axis (O-3, O-4).
    let decibels: Pipeline<Samples, Spectrum<ConstantQFrequency, DecibelValues>> = Pipeline {
        Halve()
        ConstantQ(fmin: .midiNote(24), octaves: 7, binsPerOctave: 36, tuning: 0.1, filterScale: 1, gamma: 0, hop: 512, window: .hann, sparsity: 0.01,
                  strategy: .multirateSparseKernel, channels: .mixdown)
        Power()
        Decibels(floor: -100)
        Emit(to: heat)
    }
    // O-7: chroma fold the magnitudes of a constant-Q spectrum.
    let chroma: Pipeline<Samples, Chroma> = Pipeline {
        ConstantQ(gamma: flag ? 6.6 : 0, isActive: shown)
        Magnitude()
        ChromaFold(normalization: .l2, threshold: 0.01, floor: 1e-9)
        Emit(to: chromagram)
        Emit(to: vector)
    }
    // The pseudo constant-Q is an axis conversion: after magnitudes or powers on a linear
    // axis, before decibels; its magnitudes fold into chroma as well.
    let scaled: Pipeline<Samples, Spectrum<ConstantQFrequency, DecibelValues>> = Pipeline {
        STFT(frame: 8_192, hop: 512)
        Power()
        ConstantQScale(fmin: .midiNote(48), octaves: 5, binsPerOctave: 12, tuning: 0, filterScale: 1, gamma: 0, window: .hann, sparsity: 0.01)
        Decibels()
    }
    let pseudo: Pipeline<Samples, Chroma> = Pipeline {
        STFT(frame: 8_192, hop: 512)
        Magnitude()
        ConstantQScale(fmin: .hertz(130.8), octaves: flag ? 5 : 4, binsPerOctave: 12, isActive: shown)
        ChromaFold(normalization: .none)
    }
    // The recipe takes samples and returns them, so it stands among sequence stages (§5.2).
    let recipes: Pipeline<Samples, Samples> = Pipeline {
        Halve()
        ChromaCQT(to: chromagram)
        ChromaCQT(fmin: .midiNote(36), octaves: 6, binsPerOctave: 24, tuning: 0.2, gamma: 4, hop: 256, normalization: .l1, threshold: 0.02, to: vector, isActive: shown)
        if flag { ChromaCQT(to: chromagram, isActive: false) }
        Tap {
            ConstantQ(octaves: 5)
            Power()
            Decibels()
            Emit(to: heat)
        }
        Halve()
    }
    // The fluent spelling gives the same descriptions (API-1); a branch that begins with a
    // step of a family is written this way (ORD-3).
    let fluent = Pipeline()
        .chromaCQT(to: chromagram)
        .chromaCQT(octaves: 5, normalization: .none, to: vector)
        .tap { $0.constantQ(octaves: 6, hop: 256).tap { $0.magnitude().chromaFold().emit(to: chromagram) }.power().decibels().emit(to: heat) }
        .stft(frame: 8_192, hop: 512)
        .tap { $0.magnitude().constantQScale(fmin: .midiNote(48), octaves: 5, binsPerOctave: 12).chromaFold(normalization: .l1).emit(to: vector) }
        .tap { $0.power().constantQScale(fmin: .midiNote(48), octaves: 5).decibels().emit(to: heat) }
        .inverseSTFT()
        .constantQ()
        .magnitude()
        .chromaFold()
    _ = (decibels, chroma, scaled, pseudo, recipes, fluent, level)
}

// Strategies written outside the package are passed the same way as the stock ones (§5.3).
struct Halved: ChromaNormalization {
    func norm(of chroma: UnsafeBufferPointer<Float>) -> Float { 2 }
}

final class Quiet: AnalysisNode {
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }
    func process(_ input: FrameView, _ output: inout FrameWriter) {}
    func reset() {}
}

struct Direct: ConstantQStrategy {
    func latency(of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double) throws(DSPError) -> Int {
        (geometry.atomLength(ofBin: 0) + 1) / 2
    }

    func makeNode(
        of geometry: ConstantQGeometry, hop: Int, window: Window, sparsity: Double, channel: Int?, channelCount: Int, maximumBlockFrames: Int
    ) throws(DSPError) -> any AnalysisNode {
        Quiet()
    }
}

func tables() throws {
    let geometry = try ConstantQGeometry(minimumFrequency: 32.70, octaves: 7, binsPerOctave: 36, tuning: 0, filterScale: 1, gamma: 0, sampleRate: 48_000)
    let kernel = try ConstantQKernel(geometry: geometry, octave: 6, window: .hann, sparsity: 0.01, transformLength: nil)
    let coefficients = kernel.applied(toReal: [Float](repeating: 0, count: kernel.columnCount), imaginary: [Float](repeating: 0, count: kernel.columnCount))
    let custom = Pipeline { ConstantQ(strategy: Direct()); Magnitude(); ChromaFold(normalization: Halved()) }
    let backend = Pipeline { ConstantQ(strategy: .multirateSparseKernel(backend: .vDSP)) }
    _ = (geometry.frequencies, geometry.atomLengths, geometry.axis, geometry.alpha, geometry.q, kernel.keptEnergy, kernel.rowStarts, kernel.columns,
         kernel.dense().real, kernel.columnRange, ConstantQKernel.keptEnergyFloor, coefficients.real, custom, backend, MultirateSparseKernelStrategy().backend)
}
