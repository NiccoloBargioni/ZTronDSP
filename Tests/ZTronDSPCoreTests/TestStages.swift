import Foundation
import os
import SwiftUI
import ZTronDSPCore

// Stages for the tests of the core target. The core holds no processing stage (EXT-1), so
// its tests bring their own, written against the public API exactly as a stage outside the
// package would be.

/// A gain: a sequence stage that lowers to the stock gain spec.
struct TestGain: SequenceStage {
    let factor: Float
    var activation: StageActivation = .active

    init(_ factor: Float, isActive: some ActivationSource = .active) {
        self.factor = factor
        self.activation = isActive.stageActivation
    }

    var parameters: [Double] { [Double(factor)] }
    func replacingParameters(_ values: ArraySlice<Double>) -> TestGain {
        guard let value = values.first, value != Double(factor) else { return self }
        var copy = TestGain(Float(value))
        copy.activation = activation
        return copy
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard factor.isFinite else { throw context.invalid("factor", "a gain must be finite, not \(factor)") }
        context.emit(.gain(factor: factor, ramp: 0.010))
    }
}

/// A biquad cascade of `count` copies of one section.
struct TestBiquad: SequenceStage {
    let section: BiquadSection
    let count: Int
    let precision: BiquadPrecision
    var activation: StageActivation = .active

    init(_ section: BiquadSection = BiquadSection(b0: 0.2, b1: 0.4, b2: 0.2, a1: -0.3, a2: 0.1), count: Int = 1,
         precision: BiquadPrecision = .single, isActive: some ActivationSource = .active) {
        self.section = section
        self.count = count
        self.precision = precision
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.biquad(sections: [BiquadSection](repeating: section, count: count), precision: precision))
    }
}

/// An FIR with the given taps.
struct TestFIR: SequenceStage {
    let taps: [Float]
    var activation: StageActivation = .active

    init(_ taps: [Float], isActive: some ActivationSource = .active) {
        self.taps = taps
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.fir(taps: taps, latency: (taps.count - 1) / 2))
    }
}

/// A low-pass whose cutoff is checked against the Nyquist frequency at its position (O-16).
struct TestLowPass: SequenceStage {
    let cutoff: Frequency

    var parameters: [Double] { [cutoff.animatableValue] }
    func replacingParameters(_ values: ArraySlice<Double>) -> TestLowPass {
        values.first.map { TestLowPass(cutoff: cutoff.replacing(animatableValue: $0)) } ?? self
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let hertz: Double
        do throws(DSPError) { hertz = try cutoff.hertz(sampleRate: context.environment.sampleRate) } catch { throw error.inStage(context.path) }
        guard hertz > 0, hertz < context.environment.nyquistFrequency else {
            throw context.invalid("cutoff", "\(hertz) Hz is not below the Nyquist frequency here, \(context.environment.nyquistFrequency) Hz")
        }
        context.emit(.biquad(sections: [BiquadSection(b0: hertz / context.environment.sampleRate, b1: 0, b2: 0, a1: 0, a2: 0)], precision: .single))
    }
}

/// Keeps every `factor`-th sample: a sequence stage that changes the rate.
struct TestSubsample: SequenceStage {
    let factor: Int
    var activation: StageActivation = .active

    init(by factor: Int, isActive: some ActivationSource = .active) {
        self.factor = factor
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.subsample(factor: factor, phase: 0))
    }
}

/// Counts what the test nodes of one pipeline did, so a test can see sharing (F5) and idle
/// branches (ACT-9). A stage that holds a probe compares by the probe's identity.
final class TestProbe: Hashable, @unchecked Sendable {
    // Threading: the counters are touched only by the thread that runs the plan under test.
    var framerNodesMade = 0
    var framesFramed = 0
    var framerResets = 0
    var magnitudeNodesMade = 0
    var magnitudesTaken = 0

    static func == (lhs: TestProbe, rhs: TestProbe) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A framing step: samples to a complex spectrum. The node emits one frame per `hop` samples,
/// holding the newest `frame / 2 + 1` samples as "bins": enough to test the plumbing.
struct TestFramer: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, ComplexValues>
    let frame: Int
    let hop: Int
    let probe: TestProbe?
    var activation: StageActivation = .active

    init(frame: Int, hop: Int, probe: TestProbe? = nil, isActive: some ActivationSource = .active) {
        self.frame = frame
        self.hop = hop
        self.probe = probe
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard frame >= 2, hop >= 1, hop <= frame else { throw context.invalid("hop", "a hop of \(hop) does not fit a frame of \(frame)") }
        let bins = frame / 2 + 1
        let rate = context.environment.sampleRate
        let frame = frame, hop = hop, probe = probe
        context.emit(.analysis(AnalysisStep(
            name: "TestFramer", key: self, output: .complex(count: bins),
            scope: .spectral(frameSize: frame, hopSize: hop, axis: .linearFrequency(binCount: bins, nyquist: rate / 2)),
            latency: 0
        ) { () throws(DSPError) -> any AnalysisNode in
            try TestFramerNode(frame: frame, hop: hop, sampleRate: rate, probe: probe)
        }))
    }
}

final class TestFramerNode: AnalysisNode {
    let frame: Int
    let hop: Int
    let sampleRate: Double
    let history: HistoryBuffer
    let probe: TestProbe?
    var sinceLast = 0
    var consumed = 0

    init(frame: Int, hop: Int, sampleRate: Double, probe: TestProbe?) throws(DSPError) {
        self.frame = frame
        self.hop = hop
        self.sampleRate = sampleRate
        self.probe = probe
        self.history = try HistoryBuffer(count: frame)
        probe?.framerNodesMade += 1
    }

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { frame }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        let samples = block.channel(0)
        var index = 0
        while index < block.frameCount {
            history.append(samples[index])
            consumed += 1
            sinceLast += 1
            if consumed >= frame, sinceLast >= hop {
                sinceLast = 0
                let bins = frame / 2 + 1
                let real = output.real, imaginary = output.imaginary
                let newest = history.latest(bins)
                var bin = 0
                while bin < bins {
                    real[bin] = newest[bin]
                    imaginary[bin] = -newest[bin]
                    bin += 1
                }
                probe?.framesFramed += 1
                // A causal frame is stamped with the time of its newest sample.
                output.emit(time: input.time + Double(index) / sampleRate)
            }
            index += 1
        }
    }

    func reset() {
        history.reset()
        sinceLast = 0
        consumed = 0
        probe?.framerResets += 1
    }
}

/// A step family (ORD-1): the magnitude of a complex spectrum, on any axis.
struct TestMagnitude: StageValue {
    let probe: TestProbe?
    var activation: StageActivation = .active

    init(probe: TestProbe? = nil, isActive: some ActivationSource = .active) {
        self.probe = probe
        self.activation = isActive.stageActivation
    }

    static let rule = DomainRule.spectral("TestMagnitude") { axis, values in
        values == .complex ? .spectrum(axis: axis, values: .magnitude) : nil
    }

    var stageDescription: StageDescription { StageDescription(self, rule: Self.rule) }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let bins = context.environment.frequencyAxis?.rowCount else { throw context.invalid("axis", "no spectral scope") }
        let probe = probe
        context.emit(.analysis(AnalysisStep(name: "TestMagnitude", key: self, output: .real(count: bins)) { () throws(DSPError) -> any AnalysisNode in
            TestMagnitudeNode(probe: probe)
        }))
    }
}

final class TestMagnitudeNode: AnalysisNode {
    let probe: TestProbe?
    init(probe: TestProbe?) {
        self.probe = probe
        probe?.magnitudeNodesMade += 1
    }
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.complex else { return }
        let values = output.real
        var bin = 0
        while bin < frame.count {
            values[bin] = (frame.real[bin] * frame.real[bin] + frame.imaginary[bin] * frame.imaginary[bin]).squareRoot()
            bin += 1
        }
        probe?.magnitudesTaken += 1
        output.emit(count: frame.count)
    }

    func reset() {}
}

extension PipelineBuilder {
    /// The family's compile-time rule: magnitudes follow a complex spectrum, on any axis.
    static func buildPartialBlock<I, Axis>(accumulated: Pipeline<I, Spectrum<Axis, ComplexValues>>, next: TestMagnitude)
        -> Pipeline<I, Spectrum<Axis, MagnitudeValues>> {
        accumulated.appending(next.stageDescription)
    }
}

extension Pipeline {
    /// The family's fluent spelling, constrained on the output domain.
    func testMagnitude<Axis>(probe: TestProbe? = nil, isActive: some ActivationSource = .active) -> Pipeline<Input, Spectrum<Axis, MagnitudeValues>>
    where Output == Spectrum<Axis, ComplexValues> {
        appending(TestMagnitude(probe: probe, isActive: isActive).stageDescription)
    }
}

/// Reduces a magnitude spectrum to its mean: a self-typed step that starts a scalar sequence.
struct TestMean: PipelineStage {
    typealias Input = Spectrum<LinearFrequency, MagnitudeValues>
    typealias Output = Scalar

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let rate = context.environment.featureRate else { throw context.invalid("featureRate", "no spectral scope") }
        context.emit(.analysis(AnalysisStep(name: "TestMean", key: self, output: .scalar, scope: .featureSequence(rate: rate)) {
            () throws(DSPError) -> any AnalysisNode in TestMeanNode()
        }))
    }
}

final class TestMeanNode: AnalysisNode {
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real, let base = frame.values.baseAddress, frame.count > 0 else { return }
        output.emit(scalar: ScalarFrame(value: Vector.sum(base, count: frame.count) / Float(frame.count), confidence: 1))
    }

    func reset() {}
}

extension Pipeline where Output: SampledSequence {
    func testGain(_ factor: Float, isActive: some ActivationSource = .active) -> Pipeline<Input, Output> {
        appending(TestGain(factor, isActive: isActive))
    }

    func testFIR(_ taps: [Float]) -> Pipeline<Input, Output> { appending(TestFIR(taps)) }
}

extension Pipeline where Output == Samples {
    func testFramer(frame: Int, hop: Int, probe: TestProbe? = nil) -> Pipeline<Input, Spectrum<LinearFrequency, ComplexValues>> {
        appending(TestFramer(frame: frame, hop: hop, probe: probe))
    }
}

/// A sink that keeps what it is given, for tests. One writer at a time (ATT-5).
final class CollectingSink<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    typealias Domain = D
    // Threading: written by the thread that runs the plan and by the engine's control context,
    // and read by the test at any time, also while a session runs: everything is behind the lock.
    private struct State {
        var reals: [[Float]] = []
        var scalars: [ScalarFrame] = []
        var samples: [Float] = []
        var times: [Double] = []
        var indices: [Int] = []
        var claims = 0
        var releases = 0
        var axis: FeedAxis?
        var environment: DSPEnvironment?
    }

    private let lock = NSLock()
    private var state = State()

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var reals: [[Float]] { locked { $0.reals } }
    var scalars: [ScalarFrame] { locked { $0.scalars } }
    var samples: [Float] { locked { $0.samples } }
    var times: [Double] { locked { $0.times } }
    var indices: [Int] { locked { $0.indices } }
    var claims: Int { locked { $0.claims } }
    var releases: Int { locked { $0.releases } }
    var axis: FeedAxis? { locked { $0.axis } }
    var environment: DSPEnvironment? { locked { $0.environment } }

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        locked { state in
            state.claims += 1
            state.axis = axis
            state.environment = environment
        }
    }

    func write(_ frame: FrameView) {
        locked { state in
            state.times.append(frame.time)
            state.indices.append(frame.index)
            if let real = frame.real { state.reals.append(Array(real.values)) }
            if let complex = frame.complex { state.reals.append(Array(complex.real)) }
            if let scalar = frame.scalar { state.scalars.append(scalar) }
            if let block = frame.samples { state.samples.append(contentsOf: block.samples(ofChannel: 0)) }
        }
    }

    func release() { locked { $0.releases += 1 } }
    var frameCount: Int { locked { $0.times.count } }
}

/// State behind a SwiftUI binding, for tests: what `@State` is to a view.
final class StateBox<Value: Sendable>: @unchecked Sendable {
    // Threading: the value and the count of writes are behind the lock. The code under test
    // reads and writes the binding on the main actor (BIND-1); a test may look at the box from
    // any thread, also while a session runs.
    private let lock = NSLock()
    private var stored: Value
    private var count = 0

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    /// How often the binding was written.
    var writes: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { newValue in
            self.lock.lock()
            self.stored = newValue
            self.count += 1
            self.lock.unlock()
        })
    }
}

// MARK: Sample-domain stages written in Swift and in C (§5.11.1)

/// Inverts the signal and delays it by `delay` frames: a `SampleProcessor`, with latency.
struct TestDelay: SequenceStage {
    let delay: Int
    var activation: StageActivation = .active

    init(_ delay: Int, isActive: some ActivationSource = .active) {
        self.delay = delay
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let delay = delay, channels = context.channelCount
        context.emit(.processor(CustomProcessor(name: "TestDelay", key: self, latencyFrames: delay) { _ throws(DSPError) -> any SampleProcessor in
            try TestDelayProcessor(delay: delay, channels: channels)
        }))
    }
}

final class TestDelayProcessor: SampleProcessor {
    let delay: Int
    let lines: [HistoryBuffer]
    private(set) var blocks = 0

    init(delay: Int, channels: Int) throws(DSPError) {
        self.delay = delay
        var lines: [HistoryBuffer] = []
        for _ in 0 ..< channels { lines.append(try HistoryBuffer(count: max(delay, 1) + 1)) }
        self.lines = lines
    }

    var latencyFrames: Int { delay }
    var settlingFrames: Int { 0 }

    func process(_ block: inout AudioBlock) {
        blocks += 1
        var channel = 0
        while channel < block.channelCount {
            let samples = block.channel(channel), line = lines[channel]
            var frame = 0
            while frame < block.frameCount {
                line.append(samples[frame])
                // The window is the last delay + 1 samples, oldest first: its first sample is `delay` frames old.
                samples[frame] = delay > 0 ? -line.window[0] : -samples[frame]
                frame += 1
            }
            channel += 1
        }
    }

    func reset() {
        var channel = 0
        while channel < lines.count {
            lines[channel].reset()
            channel += 1
        }
    }
}

/// Keeps every second frame: a rate changer on the caller's own C kernel.
struct TestHalve: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "TestHalve", key: self, interpolation: 1, decimation: 2) { _, _, _ in
            let phase = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            phase.initialize(to: 0)
            return ztd_kernel_t(
                process: { state, input, output, channels, frames in
                    let phase = state!.assumingMemoryBound(to: Int32.self)
                    var written = 0
                    var next = Int(phase.pointee)
                    var channel = 0
                    while channel < Int(channels) {
                        let source = input![channel]!, target = output![channel]!
                        var frame = Int(phase.pointee)
                        written = 0
                        while frame < Int(frames) {
                            target[written] = source[frame]
                            written += 1
                            frame += 2
                        }
                        next = frame - Int(frames)
                        channel += 1
                    }
                    phase.pointee = Int32(next)
                    return UInt32(written)
                },
                command: nil,
                reset: { state in state!.assumingMemoryBound(to: Int32.self).pointee = 0 },
                destroy: { state in state!.assumingMemoryBound(to: Int32.self).deallocate() },
                state: UnsafeMutableRawPointer(phase), latency_frames: 0, settling_frames: 0)
        }))
    }
}

/// A kernel that copies: on the caller's own C kernel, so nothing fuses across it.
struct TestBarrier: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "TestBarrier", key: self) { _, _, _ in ztd_kernel_identity() }))
    }
}

/// A sink that only counts, for the allocation audit: it keeps nothing.
final class CountingSink<D: SignalDomain>: FeatureSink, @unchecked Sendable {
    typealias Domain = D
    // Threading: written by the thread that runs the plan, and read by the test at any time,
    // also while a session runs. The counts are behind a lock that is taken without
    // allocating: the sink is written inside allocation audits.
    private struct Counts {
        var frames = 0
        var lastIndex = -1
        var lastTime = 0.0
        var checksum: Float = 0
    }

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var counts = Counts()

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private var current: Counts {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return counts
    }

    var frames: Int { current.frames }
    var lastIndex: Int { current.lastIndex }
    var lastTime: Double { current.lastTime }
    var checksum: Float { current.checksum }

    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}

    func write(_ frame: FrameView) {
        os_unfair_lock_lock(lock)
        counts.frames += 1
        counts.lastIndex = frame.index
        counts.lastTime = frame.time
        if let real = frame.real, let base = real.values.baseAddress, real.count > 0 { counts.checksum += base[0] }
        if let scalar = frame.scalar { counts.checksum += scalar.value }
        if let block = frame.samples, block.frameCount > 0 { counts.checksum += block.channel(0)[0] }
        os_unfair_lock_unlock(lock)
    }

    func release() {}
}

/// A one-pole smoother, `y ← y + a·(x − y)`, as a `SampleProcessor` that declares a settling
/// time: what a plan change pre-rolls (SWAP-2).
struct TestSmoother: SequenceStage {
    let coefficient: Float
    let settling: Int
    var activation: StageActivation = .active

    init(_ coefficient: Float, settling: Int, isActive: some ActivationSource = .active) {
        self.coefficient = coefficient
        self.settling = settling
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let coefficient = coefficient, settling = settling, channels = context.channelCount
        context.emit(.processor(CustomProcessor(name: "TestSmoother", key: self, latencyFrames: 0) { _ throws(DSPError) -> any SampleProcessor in
            TestSmootherProcessor(coefficient: coefficient, settling: settling, channels: channels)
        }))
    }
}

final class TestSmootherProcessor: SampleProcessor {
    let coefficient: Float
    let settlingFrames: Int
    private let state: UnsafeMutablePointer<Float>
    private let channels: Int
    private(set) var framesProcessed = 0

    init(coefficient: Float, settling: Int, channels: Int) {
        self.coefficient = coefficient
        self.settlingFrames = settling
        self.channels = max(channels, 1)
        state = .allocate(capacity: self.channels)
        state.initialize(repeating: 0, count: self.channels)
    }

    deinit {
        state.deallocate()
    }

    var latencyFrames: Int { 0 }

    func process(_ block: inout AudioBlock) {
        var channel = 0
        while channel < block.channelCount, channel < channels {
            let samples = block.channel(channel)
            var value = state[channel]
            var frame = 0
            while frame < block.frameCount {
                value += coefficient * (samples[frame] - value)
                samples[frame] = value
                frame += 1
            }
            state[channel] = value
            channel += 1
        }
        framesProcessed += block.frameCount
    }

    func reset() {
        var channel = 0
        while channel < channels {
            state[channel] = 0
            channel += 1
        }
    }
}

/// A second-order low-pass from the audio-EQ cookbook: a real filter whose cutoff is a value
/// the running kernel can take (§5.5.4).
struct TestCookbookLowPass: SequenceStage {
    let cutoff: Double
    let precision: BiquadPrecision
    var activation: StageActivation = .active

    init(cutoff: Double, precision: BiquadPrecision = .single, isActive: some ActivationSource = .active) {
        self.cutoff = cutoff
        self.precision = precision
        self.activation = isActive.stageActivation
    }

    static func section(cutoff: Double, sampleRate: Double) -> BiquadSection {
        let omega = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(omega) / (2 * 0.7071067811865476)
        let a0 = 1 + alpha
        return BiquadSection(b0: (1 - cos(omega)) / 2 / a0, b1: (1 - cos(omega)) / a0, b2: (1 - cos(omega)) / 2 / a0,
                             a1: -2 * cos(omega) / a0, a2: (1 - alpha) / a0)
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let hertz = try StageValidation.frequency(.hertz(cutoff), named: "cutoff", in: context)
        context.emit(.biquad(sections: [TestCookbookLowPass.section(cutoff: hertz, sampleRate: context.environment.sampleRate)], precision: precision))
    }
}

/// Stock rate changers and trackers, as stages.
struct TestDecimate: SequenceStage {
    let factor: Int
    let taps: [Float]
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.decimator(factor: factor, taps: taps, latency: (taps.count - 1) / 2))
    }
}

struct TestInterpolate: SequenceStage {
    let factor: Int
    let taps: [Float]
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.interpolator(factor: factor, taps: taps, latency: (taps.count - 1) / 2))
    }
}

struct TestZeroStuff: SequenceStage {
    let factor: Int
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.zeroStuff(factor: factor))
    }
}

struct TestTracker: SequenceStage {
    let alpha: Float
    let beta: Float
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.alphaBeta(alpha: alpha, beta: beta, initialPosition: 0, initialVelocity: 0, outputVelocity: false))
    }
}

struct TestChannelGains: SequenceStage {
    let factors: [Float]
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.channelGains(factors: factors, ramp: 0))
    }
}

/// A node on samples that inverts the signal, delays it by `latency` frames and hands it on
/// in blocks of `chunk` frames, whatever blocks it is given: a stand-in for a separation and
/// its resynthesis, which keep samples, add latency and have a block rhythm of their own.
struct TestLate: PipelineStage {
    typealias Input = Samples
    typealias Output = Samples
    let latency: Int
    let chunk: Int
    let settling: Int
    let probe: TestProbe?
    var activation: StageActivation = .active

    init(latency: Int, chunk: Int, settling: Int = 0, probe: TestProbe? = nil, isActive: some ActivationSource = .active) {
        self.latency = latency
        self.chunk = chunk
        self.settling = settling
        self.probe = probe
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let channels = context.channelCount, rate = context.environment.sampleRate
        let latency = latency, chunk = chunk, settling = settling, probe = probe
        context.emit(.analysis(AnalysisStep(
            name: "TestLate", key: self, output: .samples(channelCount: channels, maximumFrames: chunk),
            scope: .samples(maximumBlockFrames: chunk, channelCount: channels), latency: Double(latency) / rate
        ) { () throws(DSPError) -> any AnalysisNode in
            try TestLateNode(latency: latency, chunk: chunk, settling: settling, channels: channels, probe: probe)
        }))
    }
}

final class TestLateNode: AnalysisNode {
    let latencyFrames: Int
    let settlingFrames: Int
    private let chunk: Int
    private let ring: AudioBuffer
    private let mask: Int
    private let probe: TestProbe?
    private var received = 0
    private var sent = 0

    init(latency: Int, chunk: Int, settling: Int, channels: Int, probe: TestProbe?) throws(DSPError) {
        latencyFrames = latency
        settlingFrames = settling
        self.chunk = chunk
        self.probe = probe
        var capacity = 1
        while capacity < latency + chunk + 8_192 { capacity *= 2 }
        mask = capacity - 1
        ring = try AudioBuffer(channelCount: max(channels, 1), capacity: capacity)
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        probe?.framesFramed += 1
        var channel = 0
        while channel < block.channelCount {
            let source = block.channel(channel), line = ring.channel(channel)
            var frame = 0
            while frame < block.frameCount {
                line[(received + frame) & mask] = source[frame]
                frame += 1
            }
            channel += 1
        }
        received += block.frameCount
        while received - sent >= chunk, let target = output.samples {
            channel = 0
            while channel < target.channelCount {
                let samples = target.channel(channel), line = ring.channel(channel)
                var frame = 0
                while frame < chunk {
                    let from = sent + frame - latencyFrames
                    samples[frame] = from >= 0 ? -line[from & mask] : 0
                    frame += 1
                }
                channel += 1
            }
            sent += chunk
            output.emit(count: chunk)
        }
    }

    func reset() {
        ring.clear()
        received = 0
        sent = 0
        probe?.framerResets += 1
    }
}

/// Reduces samples to (minimum, maximum) pairs, one per `bucket` frames: a step that produces
/// an envelope. Blocks are whole numbers of buckets in the tests that use it.
struct TestEnvelope: PipelineStage {
    typealias Input = Samples
    typealias Output = Envelope
    let bucket: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let bucket = bucket
        let pairs = max(context.maximumBlockFrames / bucket, 1)
        context.emit(.analysis(AnalysisStep(
            name: "TestEnvelope", key: self, output: .envelope(maximumCount: pairs),
            scope: .spectral(frameSize: bucket, hopSize: bucket, axis: .indices(count: 2))
        ) { () throws(DSPError) -> any AnalysisNode in TestEnvelopeNode(bucket: bucket) }))
    }
}

final class TestEnvelopeNode: AnalysisNode {
    let bucket: Int
    init(bucket: Int) { self.bucket = bucket }
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        let samples = block.channel(0)
        let minima = output.minima, maxima = output.maxima
        var pair = 0
        while (pair + 1) * bucket <= block.frameCount, pair < minima.count {
            var low = Float.infinity, high = -Float.infinity
            var frame = pair * bucket
            while frame < (pair + 1) * bucket {
                low = min(low, samples[frame])
                high = max(high, samples[frame])
                frame += 1
            }
            minima[pair] = low
            maxima[pair] = high
            pair += 1
        }
        if pair > 0 { output.emit(count: pair) }
    }

    func reset() {}
}

/// Scales the bins of a magnitude spectrum: a step that keeps its domain, so a bound switch
/// on it is a bypass of frames, not of samples.
struct TestScaleBins: PipelineStage {
    typealias Input = Spectrum<LinearFrequency, MagnitudeValues>
    typealias Output = Spectrum<LinearFrequency, MagnitudeValues>
    let factor: Float
    let probe: TestProbe?
    var activation: StageActivation = .active

    init(_ factor: Float, probe: TestProbe? = nil, isActive: some ActivationSource = .active) {
        self.factor = factor
        self.probe = probe
        self.activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard let bins = context.environment.frequencyAxis?.rowCount else { throw context.invalid("axis", "no spectral scope") }
        let factor = factor, probe = probe
        context.emit(.analysis(AnalysisStep(name: "TestScaleBins", key: self, output: .real(count: bins)) {
            () throws(DSPError) -> any AnalysisNode in TestScaleBinsNode(factor: factor, probe: probe)
        }))
    }
}

final class TestScaleBinsNode: AnalysisNode {
    let factor: Float
    let probe: TestProbe?
    init(factor: Float, probe: TestProbe?) {
        self.factor = factor
        self.probe = probe
    }
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let frame = input.real else { return }
        let target = output.real
        var index = 0
        while index < frame.count, index < target.count {
            target[index] = frame.values[index] * factor
            index += 1
        }
        output.emit(count: frame.count)
    }

    func reset() { probe?.framerResets += 1 }
}

/// A recipe: a stage defined entirely by what it expands to.
struct TestTwoGains: Recipe {
    typealias Input = Samples
    typealias Output = Samples
    let first: Float
    let second: Float
    var expansion: Pipeline<Samples, Samples> { Pipeline { TestGain(first); TestGain(second) } }
}
