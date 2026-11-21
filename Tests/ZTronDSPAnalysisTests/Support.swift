import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

// What the tests of the analysis target share. The stages under test are driven through the
// public pipeline API, as a client drives them; only the allocation audit reaches into the
// core (`OfflineRunner`, the plan's `process`), because nothing public runs a plan block by
// block on the caller's thread.

/// A sink that keeps what it is given. One writer at a time (ATT-5).
final class CollectingSink<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    typealias Domain = D
    // Threading: written by the thread that runs the plan, read by the test after it finished.
    private(set) var reals: [[Float]] = []
    private(set) var imaginaries: [[Float]] = []
    private(set) var minima: [[Float]] = []
    private(set) var maxima: [[Float]] = []
    private(set) var scalars: [ScalarFrame] = []
    private(set) var samples: [Float] = []
    private(set) var blockLengths: [Int] = []
    private(set) var times: [Double] = []
    private(set) var indices: [Int] = []
    private(set) var axis: FeedAxis?
    private(set) var environment: DSPEnvironment?
    private(set) var claims = 0

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        claims += 1
        self.axis = axis
        self.environment = environment
    }

    func write(_ frame: FrameView) {
        times.append(frame.time)
        indices.append(frame.index)
        if let real = frame.real { reals.append(Array(real.values)) }
        if let complex = frame.complex {
            reals.append(Array(complex.real))
            imaginaries.append(Array(complex.imaginary))
        }
        if let envelope = frame.envelope {
            minima.append(Array(envelope.minima))
            maxima.append(Array(envelope.maxima))
        }
        if let scalar = frame.scalar { scalars.append(scalar) }
        if let block = frame.samples {
            samples.append(contentsOf: block.samples(ofChannel: 0))
            blockLengths.append(block.frameCount)
        }
    }

    func release() {}
    var frameCount: Int { times.count }
}

/// A sink that only counts, for the allocation audit: it keeps nothing.
final class CountingSink<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    typealias Domain = D
    // Threading: written by the thread that runs the plan, read by the test after it finished.
    private(set) var frames = 0
    private(set) var checksum: Float = 0

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}

    func write(_ frame: FrameView) {
        frames += 1
        if let real = frame.real, let base = real.values.baseAddress, real.count > 0 { checksum += base[0] }
        if let complex = frame.complex, let base = complex.real.baseAddress, complex.count > 0 { checksum += base[0] }
        if let scalar = frame.scalar { checksum += scalar.value }
        if let block = frame.samples, block.frameCount > 0 { checksum += block.channel(0)[0] }
        if let envelope = frame.envelope, let base = envelope.maxima.baseAddress, envelope.count > 0 { checksum += base[0] }
    }

    func release() {}
}

/// State behind a SwiftUI binding, for tests: what `@State` is to a view.
final class StateBox<Value: Sendable>: @unchecked Sendable {
    // Threading: tests read and write it on one thread at a time.
    var value: Value
    private(set) var writes = 0

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.value = $0; self.writes += 1 })
    }
}

/// A sequence stage of the tests' own: the design target's stages are not needed to show
/// where a spectral step may stand.
struct TestGain: SequenceStage {
    let factor: Float
    init(_ factor: Float) { self.factor = factor }
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.gain(factor: factor, ramp: 0))
    }
}

let mono48 = SignalFormat(sampleRate: 48_000)

/// The one-sided DFT of a real signal, by its definition, in double precision.
func naiveDFT(_ signal: [Double]) -> (real: [Double], imaginary: [Double]) {
    let count = signal.count
    var real = [Double](repeating: 0, count: count / 2 + 1), imaginary = real
    for bin in 0 ... count / 2 {
        var re = 0.0, im = 0.0
        for (index, value) in signal.enumerated() {
            // The angle is reduced before it is scaled, so long transforms keep their digits.
            let angle = -2 * Double.pi * Double((bin * index) % count) / Double(count)
            re += value * cos(angle)
            im += value * sin(angle)
        }
        real[bin] = re
        imaginary[bin] = im
    }
    return (real, imaginary)
}

/// The largest magnitude of a complex vector.
func peakMagnitude(_ real: [Double], _ imaginary: [Double]) -> Double {
    zip(real, imaginary).map { ($0 * $0 + $1 * $1).squareRoot() }.max() ?? 0
}

/// The largest distance between two complex vectors, relative to the largest magnitude of the
/// expected one: how tolerances on spectra are stated (§6.1).
func complexDeviation(_ real: [Float], _ imaginary: [Float], _ expectedReal: [Double], _ expectedImaginary: [Double]) -> Double {
    guard real.count == expectedReal.count, imaginary.count == expectedImaginary.count else { return .infinity }
    let peak = peakMagnitude(expectedReal, expectedImaginary)
    var worst = 0.0
    for index in real.indices {
        let dr = Double(real[index]) - expectedReal[index], di = Double(imaginary[index]) - expectedImaginary[index]
        worst = max(worst, (dr * dr + di * di).squareRoot())
    }
    return peak > 0 ? worst / peak : worst
}

/// `10·log₁₀(Σ reference² / Σ (reference − signal)²)`.
func signalToNoise(_ signal: [Float], _ reference: [Float]) -> Double {
    var power = 0.0, noise = 0.0
    for (a, b) in zip(signal, reference) {
        power += Double(b) * Double(b)
        noise += (Double(a) - Double(b)) * (Double(a) - Double(b))
    }
    guard noise > 0 else { return .infinity }
    return 10 * log10(power / noise)
}

/// Runs a pipeline that ends in a complex spectrum and returns its frames.
func complexFrames<D: SignalDomain>(
    of pipeline: Pipeline<Samples, D>, on samples: [Float], format: SignalFormat = mono48, blockSize: Int = 512
) throws -> CollectingSink<D> {
    let sink = CollectingSink<D>()
    try pipeline.emit(to: sink).run(on: samples, format: format, blockSize: blockSize)
    return sink
}

/// Runs a pipeline on a signal of several channels, for the sake of its sinks.
func run<Output: SignalDomain>(
    _ pipeline: Pipeline<Samples, Output>, channels: [[Float]], format: SignalFormat, blockSize: Int = 512
) throws(DSPError) {
    let runner = try OfflineRunner(stages: pipeline.stages, format: format, blockSize: blockSize, crossovers: .shipped)
    runner.run(channels)
    runner.finish()
}

// The real-time audit of a pipeline, `expectNoAllocationsRunning`, is the public one of
// `ZTronDSPTesting`: the helper of that name that stood here reached the plan with `@testable`.

/// Lowers a pipeline as the engine would and returns what the plan compiler made of it.
func lowered<Output: SignalDomain>(
    _ pipeline: Pipeline<Samples, Output>, sampleRate: Double = 48_000, channelCount: Int = 1, blockSize: Int = 512
) throws(DSPError) -> LoweredPipeline {
    try PlanCompiler(crossovers: .shipped).lower(
        pipeline.stages, environment: DSPEnvironment(sampleRate: sampleRate, channelCount: channelCount, blockSize: blockSize), blockSize: blockSize)
}

/// The analysis nodes a lowered pipeline holds, branches included.
func nodeNames(_ steps: [IRStep]) -> [String] {
    var names: [String] = []
    for step in steps {
        switch step {
        case .node(let node): names.append(node.step.name)
        case .branch(let branch): names += nodeNames(branch.steps)
        case .region(let region): names += nodeNames(region.steps)
        case .kernel, .emission, .gate: break
        }
    }
    return names
}

/// The message of the error a throwing expression raises, or `nil` when it does not throw.
func errorMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return "\(error)"
    }
}

/// Runs `samples` through a pipeline twice on one plan and returns the sink, which holds the
/// frames of both passes one after the other. With `coldStart` the plan is reset between the
/// two, as it is after an interruption or a restart (ACT-10); without, the second pass goes on
/// from the state the first one left.
func twoPasses<D: SignalDomain>(
    of pipeline: Pipeline<Samples, D>, on samples: [Float], coldStart: Bool, format: SignalFormat = mono48, blockSize: Int = 512
) throws -> CollectingSink<D> {
    let sink = CollectingSink<D>()
    let runner = try OfflineRunner(stages: pipeline.emit(to: sink).stages, format: format, blockSize: blockSize, crossovers: .shipped)
    runner.run([samples])
    if coldStart { runner.plan.resetAll() }
    runner.run([samples])
    runner.finish()
    return sink
}

/// A stage of the tests' own: one frame of given values for every block of samples, in the
/// domain the test names and with the scope it names, or with none. It hands a step frames
/// no signal would give, and frames that lack the scope the step needs.
struct FixedFrames<Output: SignalDomain>: PipelineStage {
    typealias Input = Samples
    let values: [Float]
    let scope: ScopeChange

    init(_ values: [Float], scope: ScopeChange = .none) {
        self.values = values
        self.scope = scope
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let values = values
        context.emit(.analysis(AnalysisStep(name: "FixedFrames", key: values, output: .real(count: values.count), scope: scope) {
            () throws(DSPError) -> any AnalysisNode in try FixedFramesNode(values)
        }))
    }
}

/// The node of `FixedFrames`.
final class FixedFramesNode: AnalysisNode {
    private let values: AlignedBuffer<Float>
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    init(_ values: [Float]) throws(DSPError) {
        self.values = try AlignedBuffer<Float>(copying: values)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let target = output.real.baseAddress else { return }
        target.update(from: values.baseAddress, count: values.count)
        output.emit(count: values.count)
    }

    func reset() {}
}
