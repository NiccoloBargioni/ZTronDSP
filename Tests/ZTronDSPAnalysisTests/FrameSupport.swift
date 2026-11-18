import Foundation
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

// Stages of the tests' own that hand a step frames a test wrote by hand: a list of frames
// played one per block, and samples played as a novelty curve.

/// One frame for every block of samples, taken in turn from a list, in the domain the test
/// names and with the scope it names. All frames have the length of the first.
struct FrameSequence<Output: SignalDomain>: PipelineStage {
    typealias Input = Samples
    let frames: [[Float]]
    let scope: ScopeChange

    /// Frames of a spectral scope on a linear-frequency axis of as many bins as a frame has.
    init(_ frames: [[Float]], hop: Int = 512, nyquist: Double = 24_000) {
        self.frames = frames
        let bins = frames.first?.count ?? 0
        scope = .spectral(frameSize: max(2 * (bins - 1), 1), hopSize: hop, axis: .linearFrequency(binCount: bins, nyquist: nyquist))
    }

    init(_ frames: [[Float]], scope: ScopeChange) {
        self.frames = frames
        self.scope = scope
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let frames = frames
        context.emit(.analysis(AnalysisStep(name: "FrameSequence", key: frames, output: .real(count: frames.first?.count ?? 0), scope: scope) {
            () throws(DSPError) -> any AnalysisNode in try FrameSequenceNode(frames)
        }))
    }

    /// Samples that make the stage emit `count` frames in blocks of `blockSize`.
    static func drive(_ count: Int, blockSize: Int = 512) -> [Float] {
        [Float](repeating: 0, count: count * blockSize)
    }
}

final class FrameSequenceNode: AnalysisNode {
    private let values: AlignedBuffer<Float>
    private let frameCount: Int
    private let length: Int
    private var next = 0
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(_ frames: [[Float]]) throws(DSPError) {
        frameCount = frames.count
        length = frames.first?.count ?? 0
        values = try AlignedBuffer<Float>(copying: frames.flatMap { $0 })
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let target = output.real.baseAddress, frameCount > 0 else { return }
        target.update(from: values.baseAddress + (next % frameCount) * length, count: length)
        next += 1
        output.emit(count: length)
    }

    func reset() { next = 0 }
}

/// A complex spectrum for every block of samples, taken in turn from a list of (real,
/// imaginary) frames, in the scope of an STFT whose bins they are.
struct ComplexFrameSequence: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    let real: [[Float]]
    let imaginary: [[Float]]
    let hop: Int

    init(real: [[Float]], imaginary: [[Float]], hop: Int = 512) {
        self.real = real
        self.imaginary = imaginary
        self.hop = hop
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let real = real, imaginary = imaginary
        let bins = real.first?.count ?? 0
        context.emit(.analysis(AnalysisStep(
            name: "ComplexFrameSequence", key: [real, imaginary], output: .complex(count: bins),
            scope: .spectral(frameSize: max(2 * (bins - 1), 1), hopSize: hop, axis: .linearFrequency(binCount: bins, nyquist: context.environment.sampleRate / 2))
        ) { () throws(DSPError) -> any AnalysisNode in try ComplexFrameSequenceNode(real: real, imaginary: imaginary) }))
    }
}

final class ComplexFrameSequenceNode: AnalysisNode {
    private let real: AlignedBuffer<Float>
    private let imaginary: AlignedBuffer<Float>
    private let frameCount: Int
    private let length: Int
    private var next = 0
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(real: [[Float]], imaginary: [[Float]]) throws(DSPError) {
        frameCount = real.count
        length = real.first?.count ?? 0
        self.real = try AlignedBuffer<Float>(copying: real.flatMap { $0 })
        self.imaginary = try AlignedBuffer<Float>(copying: imaginary.flatMap { $0 })
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let re = output.real.baseAddress, let im = output.imaginary.baseAddress, frameCount > 0 else { return }
        re.update(from: real.baseAddress + (next % frameCount) * length, count: length)
        im.update(from: imaginary.baseAddress + (next % frameCount) * length, count: length)
        next += 1
        output.emit(count: length)
    }

    func reset() { next = 0 }
}

/// Samples as a novelty curve, value for value, at the rate of the samples: what hands a
/// tempogram a curve a test wrote by hand.
struct SamplesAsNovelty: PipelineStage {
    typealias Input = Samples
    typealias Output = Novelty

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rate = context.environment.sampleRate
        context.emit(.analysis(AnalysisStep(name: "SamplesAsNovelty", key: 0, output: .scalar, scope: .featureSequence(rate: rate)) {
            () throws(DSPError) -> any AnalysisNode in SamplesAsNoveltyNode(rate: rate)
        }))
    }
}

final class SamplesAsNoveltyNode: AnalysisNode {
    private let rate: Double
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(rate: Double) {
        self.rate = rate
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        let samples = block.channel(0)
        var index = 0
        while index < block.frameCount {
            output.emit(scalar: ScalarFrame(value: samples[index], confidence: 1), time: input.time + Double(index) / rate)
            index += 1
        }
    }

    func reset() {}
}

/// The cosine similarity of two vectors; 1 for two vectors of zeros, which are the same
/// column, and 0 when only one of them is zeros.
func cosineSimilarity(_ a: [Float], _ b: [Double]) -> Double {
    guard a.count == b.count else { return 0 }
    var dot = 0.0, energyA = 0.0, energyB = 0.0
    for (x, y) in zip(a, b) {
        dot += Double(x) * y
        energyA += Double(x) * Double(x)
        energyB += y * y
    }
    if energyA == 0, energyB == 0 { return 1 }
    guard energyA > 0, energyB > 0 else { return 0 }
    return dot / (energyA * energyB).squareRoot()
}
