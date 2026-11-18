import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

// Stages as a stage outside the package may be written (§5.11): each states one figure freely.

/// A gain whose ramp is the test's.
private struct RampedGain: SequenceStage {
    let ramp: TimeInterval

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.gain(factor: 2, ramp: ramp))
    }
}

/// A gain per channel whose ramp is the test's.
private struct RampedChannelGain: SequenceStage {
    let ramp: TimeInterval

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.channelGains(factors: [Float](repeating: 2, count: context.channelCount), ramp: ramp))
    }
}

/// A filter of two taps, a decimator or an interpolator that declares the latency the test chooses.
private struct LateFilter: SequenceStage {
    enum Kind: Hashable, Sendable {
        case fir, decimator, interpolator
    }

    let kind: Kind
    let latency: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        switch kind {
        case .fir: context.emit(.fir(taps: [0.5, 0.5], latency: latency))
        case .decimator: context.emit(.decimator(factor: 2, taps: [0.5, 0.5], latency: latency))
        case .interpolator: context.emit(.interpolator(factor: 2, taps: [1, 1], latency: latency))
        }
    }
}

/// A processor that passes the signal and says of itself what the test chooses.
private final class TellingProcessor: SampleProcessor {
    let latencyFrames: Int
    let settlingFrames: Int

    init(latency: Int, settling: Int) {
        latencyFrames = latency
        settlingFrames = settling
    }

    func process(_ block: inout AudioBlock) {}
    func reset() {}
}

private struct TellingStage: SequenceStage {
    let latency: Int
    let settling: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let latency = latency, settling = settling
        context.emit(.processor(CustomProcessor(name: "TellingStage", key: self, latencyFrames: latency) { _ throws(DSPError) -> any SampleProcessor in
            TellingProcessor(latency: latency, settling: settling)
        }))
    }
}

/// A kernel of the caller's own that passes the signal, a frame late, and says it needs as
/// long to settle as a kernel can say.
private struct SlowToSettle: SequenceStage {
    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "SlowToSettle", key: 0, latencyFrames: 1) { _, _, _ in
            var kernel = ztd_kernel_identity()
            kernel.latency_frames = 1
            kernel.settling_frames = .max
            return kernel
        }))
    }
}

/// A node that hands blocks of samples on as they come. It declares the latency the test
/// chooses, in seconds, and says of itself that it needs the frames the test chooses.
private struct SlowNode: PipelineStage {
    typealias Input = Samples
    typealias Output = Samples
    let seconds: TimeInterval
    var frames = 0

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let channels = context.channelCount, block = context.maximumBlockFrames, frames = frames
        context.emit(.analysis(AnalysisStep(
            name: "SlowNode", key: self, output: .samples(channelCount: channels, maximumFrames: block),
            scope: .samples(maximumBlockFrames: block, channelCount: channels), latency: seconds
        ) { () throws(DSPError) -> any AnalysisNode in PassingNode(frames: frames) }))
    }
}

private final class PassingNode: AnalysisNode {
    let latencyFrames: Int
    let settlingFrames: Int

    init(frames: Int) {
        latencyFrames = frames
        settlingFrames = frames
    }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples, let target = output.samples else { return }
        var channel = 0
        while channel < min(block.channelCount, target.channelCount) {
            memcpy(target.channel(channel), block.channel(channel), block.frameCount * MemoryLayout<Float>.stride)
            channel += 1
        }
        output.emit(count: block.frameCount)
    }

    func reset() {}
}

/// A node that begins a sequence of single values at the rate the test chooses.
private struct RatedNode: PipelineStage {
    typealias Input = Samples
    typealias Output = Scalar
    let rate: Double

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.analysis(AnalysisStep(name: "RatedNode", key: self, output: .scalar, scope: .featureSequence(rate: rate)) {
            () throws(DSPError) -> any AnalysisNode in PassingNode(frames: 0)
        }))
    }
}

/// §9.3: nothing a caller can state makes the package trap. A ramp, a latency, a block size and
/// a rate come from outside: from a stage written outside the package, a source, an engine's
/// initialiser. Where a plan is compiled or a source attached, each is counted in frames, and
/// a figure that is no count of frames, or more than the place can count, is refused with a
/// typed error that names the stage; nothing is cut to fit, because the delay of everything
/// behind a stage is counted from what the stage says (REAL-5).
///
/// Each of these was a conversion that trapped or, where two figures are added, a sum that
/// came out as another figure. No test runs a trap: each shows that the figure is outside
/// the type the old expression converted it to, where such a conversion traps, and then
/// asserts the error that is thrown now.
@Suite("Figures no plan can count are typed errors (§9.3)")
struct CountableValueRegressionTests {
    let format = SignalFormat(sampleRate: 48_000)
    let signal = [Float](repeating: 1, count: 256)

    /// The typed error `body` throws, or `nil` when it throws none.
    private func refusal(_ body: () throws(DSPError) -> Void) -> DSPError? {
        do throws(DSPError) {
            try body()
            return nil
        } catch {
            return error
        }
    }

    /// The stage and the parameter an `invalidParameter` names: the path of the stage, with
    /// its place among the stages beside it, and the parameter.
    private func named(_ error: DSPError?) -> String {
        guard case .invalidParameter(let stage, let parameter, _)? = error else { return "not an invalid parameter: \(String(describing: error))" }
        return "\(stage).\(parameter)"
    }

    // MARK: The ramp of a gain (KernelFactory)

    /// The old expression: `UInt32(max((seconds * rate).rounded(), 0))`.
    @Test func aRampNoKernelCanCountIsRefusedByName() throws {
        let day = 1_000_000.0
        #expect(UInt32(exactly: (day * 48_000).rounded()) == nil && !(Double.infinity * 48_000).isFinite && (Double.nan * 48_000).isNaN,
                "frames a kernel's 32 bits do not hold, and products that are no number")
        for ramp in [day, .infinity, .nan] {
            let single = refusal { () throws(DSPError) in _ = try Pipeline { RampedGain(ramp: ramp) }.process(signal, format: format, blockSize: 64) }
            #expect(named(single) == "RampedGain[0].ramp", "a gain, ramp \(ramp): \(String(describing: single))")
            // Two gains in a row are one kernel with the longer of their ramps (F1). A gain whose
            // ramp cannot be counted stays by itself: it is refused under its own name, wherever
            // it stands, and not under the name of the gain beside it.
            let behind = refusal { () throws(DSPError) in
                _ = try Pipeline { TestGain(2); RampedGain(ramp: ramp) }.process(signal, format: format, blockSize: 64)
            }
            #expect(named(behind) == "RampedGain[1].ramp", "behind another gain, ramp \(ramp): \(String(describing: behind))")
            let inFront = refusal { () throws(DSPError) in
                _ = try Pipeline { TestGain(2); TestGain(3); RampedGain(ramp: ramp); TestGain(4) }.process(signal, format: format, blockSize: 64)
            }
            #expect(named(inFront) == "RampedGain[2].ramp", "between other gains, ramp \(ramp): \(String(describing: inFront))")
            let perChannel = refusal { () throws(DSPError) in _ = try Pipeline { RampedChannelGain(ramp: ramp) }.process(signal, format: format, blockSize: 64) }
            #expect(named(perChannel) == "RampedChannelGain[0].ramp", "a gain per channel, ramp \(ramp): \(String(describing: perChannel))")
        }
        // The same count from the other factor: 10 ms at a rate of a million megahertz.
        #expect(UInt32(exactly: (0.010 * 1e12).rounded()) == nil)
        let fast = refusal { () throws(DSPError) in _ = try Pipeline { TestGain(2) }.process(signal, format: SignalFormat(sampleRate: 1e12), blockSize: 64) }
        #expect(named(fast) == "TestGain[0].ramp", "\(String(describing: fast))")

        // What a kernel can count, it counts: an hour of ramp, and a ramp that is over before it begins.
        let doubled = signal.map { (sample: Float) -> Float in sample * 2 }
        let hour = try Pipeline { RampedGain(ramp: 3_600) }.process(signal, format: format, blockSize: 64)
        let none = try Pipeline { RampedGain(ramp: -1) }.process(signal, format: format, blockSize: 64)
        #expect(hour == doubled && none == doubled)
        // And gains that can be counted are one kernel as before, the one that has no ramp among them.
        let lowered = try PlanCompiler(crossovers: .shipped).lower(
            Pipeline { TestGain(2); RampedGain(ramp: -1); RampedGain(ramp: 3_600) }.stages,
            environment: DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64), blockSize: 64)
        #expect(lowered.steps.count == 1, "three gains, one kernel: \(lowered.steps.count) steps")
    }

    // MARK: The latency of a stock kernel, and the fade of its taps (StockKernels)

    /// The old expressions: `UInt32(max(latency, 0))` and `UInt32(max((0.010 * sampleRate).rounded(), 1))`.
    @Test func aLatencyNoKernelCanCountIsRefusedByName() throws {
        let tooLate = Int(UInt32.max) + 1
        #expect(UInt32(exactly: tooLate) == nil)
        for kind in [LateFilter.Kind.fir, .decimator, .interpolator] {
            let error = refusal { () throws(DSPError) in _ = try Pipeline { LateFilter(kind: kind, latency: tooLate) }.process(signal, format: format, blockSize: 64) }
            #expect(named(error) == "LateFilter[0].latency", "\(kind): \(String(describing: error))")
        }
        // The long filter, which is computed in partitions, declares its latency the same way.
        // (A pipeline with an environment of its own is a group in the pipeline that holds it.)
        let partitioned = refusal { () throws(DSPError) in
            _ = try Pipeline { LateFilter(kind: .fir, latency: tooLate) }.environment(\.implementation, .accelerate).process(signal, format: format, blockSize: 64)
        }
        #expect(named(partitioned) == "Group[0] › LateFilter[0].latency", "\(String(describing: partitioned))")

        // Two filters in a row are one filter of both latencies (F3), when one kernel can count the
        // sum. The old expression added them as they came, `latencyA + latencyB`: a sum that no
        // `Int` holds, and one that no kernel counts.
        #expect(Int.max.addingReportingOverflow(Int.max).overflow && UInt32(exactly: Int(UInt32.max) + 1) == nil)
        let compiler = PlanCompiler(crossovers: .shipped)
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64)
        /// The latency each kernel of the plan of `pipeline` states, in the order they run.
        func kernelLatencies(_ pipeline: Pipeline<Samples, Samples>) throws -> [UInt32] {
            let lowered = try compiler.lower(pipeline.stages, environment: environment, blockSize: 64)
            let plan = try ExecutionPlan(lowered: lowered, switchValues: [], crossovers: .shipped, generation: 1, previous: nil)
            var latencies: [UInt32] = []
            for step in plan.root.steps {
                if case .kernels(let run) = step { latencies += run.boxes.map { (box: KernelBox) -> UInt32 in box.kernel.latency_frames } }
            }
            return latencies
        }
        // What can be counted is one filter, and its latency is the delay of the two: a latency
        // below zero is none in the one filter as it is in each (REAL-5). The old sum, 5 − 7, left
        // the filter of both without the five frames the environment behind it counts.
        let together = try kernelLatencies(Pipeline { LateFilter(kind: .fir, latency: 5); LateFilter(kind: .fir, latency: 7) })
        let withNone = try kernelLatencies(Pipeline { LateFilter(kind: .fir, latency: 5); LateFilter(kind: .fir, latency: -7) })
        #expect(together == [12] && withNone == [5], "one filter of both: \(together), \(withNone)")
        let stated = try compiler.lower(
            Pipeline { LateFilter(kind: .fir, latency: 5); LateFilter(kind: .fir, latency: -7) }.stages, environment: environment, blockSize: 64)
        #expect(stated.output.environment.latency == 5.0 / 48_000, "and what the environment behind them says: \(stated.output.environment.latency) s")
        // Each of these two can be counted, their sum cannot: they stay two filters, and nothing is refused.
        let apart = try? kernelLatencies(Pipeline { LateFilter(kind: .fir, latency: Int(UInt32.max)); LateFilter(kind: .fir, latency: 1) })
        #expect(apart == [UInt32.max, 1], "two filters whose sum no kernel counts: \(String(describing: apart))")
        // A filter that cannot be counted is refused under its own name, behind another filter too.
        let behind = refusal { () throws(DSPError) in
            _ = try Pipeline { LateFilter(kind: .fir, latency: 3); LateFilter(kind: .fir, latency: tooLate) }.process(signal, format: format, blockSize: 64)
        }
        #expect(named(behind) == "LateFilter[1].latency", "\(String(describing: behind))")
        let beyond = refusal { () throws(DSPError) in
            _ = try Pipeline { LateFilter(kind: .fir, latency: 3); LateFilter(kind: .fir, latency: .max); LateFilter(kind: .fir, latency: .max) }
                .process(signal, format: format, blockSize: 64)
        }
        #expect(named(beyond) == "LateFilter[1].latency", "\(String(describing: beyond))")

        // The 10 ms over which the taps of a filter are exchanged, at a rate at which they are too many frames.
        #expect(UInt32(exactly: (0.010 * 1e12).rounded()) == nil)
        let fast = refusal { () throws(DSPError) in
            _ = try Pipeline { LateFilter(kind: .fir, latency: 0) }.process(signal, format: SignalFormat(sampleRate: 1e12), blockSize: 64)
        }
        #expect(named(fast) == "LateFilter[0].sampleRate", "\(String(describing: fast))")

        // A latency a kernel can count is the stage's own business, and one below zero is none.
        let lowered = try compiler.lower(
            Pipeline { LateFilter(kind: .fir, latency: 1 << 20); LateFilter(kind: .fir, latency: -7) }.stages, environment: environment, blockSize: 64)
        #expect(lowered.output.environment.latency == Double(1 << 20) / 48_000)
        let filtered = try Pipeline { LateFilter(kind: .fir, latency: -7) }.process(signal, format: format, blockSize: 64)
        #expect(filtered.count == signal.count)
    }

    // MARK: What a processor says of itself (ProcessorKernel)

    /// The old expressions: `UInt32(max(processor.latencyFrames, 0))` and the same for
    /// `settlingFrames`.
    @Test func aProcessorThatSaysMoreFramesThanAKernelCountsIsRefusedByName() throws {
        let tooMany = Int(UInt32.max) + 1
        #expect(UInt32(exactly: tooMany) == nil && UInt32(exactly: Int.max) == nil)
        let late = refusal { () throws(DSPError) in _ = try Pipeline { TellingStage(latency: tooMany, settling: 0) }.process(signal, format: format, blockSize: 64) }
        #expect(named(late) == "TellingStage[0].latencyFrames", "\(String(describing: late))")
        let slow = refusal { () throws(DSPError) in _ = try Pipeline { TellingStage(latency: 0, settling: .max) }.process(signal, format: format, blockSize: 64) }
        #expect(named(slow) == "TellingStage[0].settlingFrames", "\(String(describing: slow))")

        // Figures below zero are none, as the description has them; figures a kernel counts are its own.
        let negative = try Pipeline { TellingStage(latency: -5, settling: -5) }.process(signal, format: format, blockSize: 64)
        let largest = try Pipeline { TellingStage(latency: 0, settling: Int(UInt32.max)) }.process(signal, format: format, blockSize: 64)
        #expect(negative == signal && largest == signal)
    }

    // MARK: The ring of a push source (SourceAdapter, SampleRing, RingWriter)

    /// The old expressions: `blockSize * 8`, and `UInt32(capacity)` for the ring's frames.
    @Test func aBlockSizeWhoseRingCannotBeCountedIsRefused() async throws {
        let uncountable = Int.max / 8 + 1, beyondARing = 1 << 33
        #expect(uncountable.multipliedReportingOverflow(by: 8).overflow && UInt32(exactly: beyondARing * 8) == nil)

        for (size, frames) in [(uncountable, Int.max), (beyondARing, beyondARing * 8)] {
            let source = ManualPushSource(format: format)
            let expected = DSPError.resourceAllocationFailed(what: "a ring of 1 channels of \(frames) frames")
            #expect(throws: expected) { _ = try SourceAdapter.make(for: source, blockSize: size) }
            // Through the engine: the attachment is refused, the source is connected to nothing and stays free.
            let engine = DSPEngine(blockSize: size, drivenByHand: true)
            await #expect(throws: expected) { _ = try await engine.attach(Pipeline { TestGain(2) }, to: source) }
            engine.core.flush()
            engine.core.flush()
            #expect(source.connects == 0)
            let elsewhere = try await DSPEngine(blockSize: 64, drivenByHand: true).attach(Pipeline(), to: source)
            #expect(elsewhere.state == .idle && source.connects == 1)
            elsewhere.detach()
        }
        // A source that is asked for its blocks has no ring: the same size is refused where the block itself cannot be had.
        let pull = BufferSource([1, 2, 3], sampleRate: 48_000)
        let engine = DSPEngine(blockSize: uncountable, drivenByHand: true)
        await #expect(throws: DSPError.resourceAllocationFailed(what: "a block of 1 channels of \(uncountable) frames")) {
            _ = try await engine.attach(Pipeline(), to: pull)
        }

        // The ring itself: frames and channels are counted in 32 bits.
        #expect(throws: DSPError.resourceAllocationFailed(what: "a ring of 1 channels of \(Int(UInt32.max) + 1) frames")) {
            _ = try SampleRing(channelCount: 1, capacity: Int(UInt32.max) + 1)
        }
        #expect(throws: DSPError.resourceAllocationFailed(what: "a ring of \(Int(UInt32.max) + 1) channels of 16 frames")) {
            _ = try SampleRing(channelCount: Int(UInt32.max) + 1, capacity: 16)
        }
    }

    /// The writing end of a ring runs where nothing can be thrown (RT-1): the frames it is told
    /// to write are taken as the ring counts them. The old expression was
    /// `UInt32(max(frameCount, 0))`.
    @Test func aWriterToldOfMoreFramesThanARingCountsWritesWhatFits() throws {
        let writer = RingWriter(try SampleRing(channelCount: 1, capacity: 256))
        let capacity = writer.capacity
        let told = Int(UInt32.max) + 5
        #expect(UInt32(exactly: told) == nil)
        let samples = (0 ..< capacity).map { Float($0) }
        let written = samples.withUnsafeBufferPointer { buffer -> Int in
            var table: [UnsafePointer<Float>?] = [buffer.baseAddress]
            return table.withUnsafeMutableBufferPointer { writer.write(channels: $0.baseAddress!, frameCount: told) }
        }
        #expect(written == capacity && writer.availableSpace == 0, "the ring took what it holds: \(written) of \(capacity)")
        #expect(writer.droppedFrames == Int(UInt32.max) - capacity, "and counted the rest of what it can count as dropped")
        let none = samples.withUnsafeBufferPointer { buffer -> Int in
            var table: [UnsafePointer<Float>?] = [buffer.baseAddress]
            let fromPointers = table.withUnsafeMutableBufferPointer { writer.write(channels: $0.baseAddress!, frameCount: -3) }
            return fromPointers + writer.write(interleaved: buffer.baseAddress!, frameCount: -3)
        }
        #expect(none == 0, "frames below zero are none")

        let interleaved = RingWriter(try SampleRing(channelCount: 1, capacity: 256))
        let taken = samples.withUnsafeBufferPointer { interleaved.write(interleaved: $0.baseAddress!, frameCount: told) }
        #expect(taken == interleaved.capacity && interleaved.droppedFrames == Int(UInt32.max) - taken)
    }

    // MARK: The delay line and the fades of a switch (ExecutionPlan)

    /// The old expressions: `Int((region.latency * rate).rounded())` and
    /// `Int((0.010 * rate).rounded())` for a switched group, `UInt32(fade)` for the switch of a
    /// kernel, and, in C, the sum of the latencies of a group's kernels in 32 bits.
    @Test func aSwitchWhoseDelayOrFadeNoBufferCountsIsRefusedByName() throws {
        // A group that is bypassed delays the signal by the latency of what is inside (ACT-8):
        // a delay line of that many frames. 10¹⁸ seconds of it are no count of frames at all.
        #expect(Int(exactly: (1e18 * 48_000).rounded()) == nil)
        let group = StagePath().appending("Group", index: 0)
        #expect(throws: DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: group)) {
            _ = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { SlowNode(seconds: 1e18) } }.process(signal, format: format, blockSize: 64)
        }
        // Two hours of it are a count, and more than a buffer of the plan holds (2²⁸ samples).
        #expect(throws: DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: group)) {
            _ = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { SlowNode(seconds: 7_200) } }.process(signal, format: format, blockSize: 64)
        }
        // Its fade is 10 ms: at 10²¹ Hz that is no count an `Int` holds.
        #expect(Int(exactly: (0.010 * 1e21).rounded()) == nil)
        #expect(throws: DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: group)) {
            _ = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestDelay(1); SlowNode(seconds: 0) } }
                .process(signal, format: SignalFormat(sampleRate: 1e21), blockSize: 64)
        }

        // A group of kernels is switched as one kernel, which delays by the latencies of all of
        // them and states the sum in 32 bits. Each of these two is a figure a kernel counts; their
        // sum is not, and the kernel of the group would have stated what is left of it: no delay.
        #expect(UInt32.max.addingReportingOverflow(1).overflow && UInt32.max &+ 1 == 0)
        for pair in [(Int(UInt32.max), 1), (3_000_000_000, 3_000_000_000), (200_000_000, 200_000_000)] {
            #expect(throws: DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: group), "\(pair)") {
                _ = try Pipeline {
                    ZTronDSPCore.Group(isActive: StateBox(true).binding) { TellingStage(latency: pair.0, settling: 0); TellingStage(latency: pair.1, settling: 0) }
                }.process(signal, format: format, blockSize: 64)
            }
        }
        // Two filters with the same figures stay two filters (F3), and are refused as a group the same way.
        #expect(throws: DSPError.resourceAllocationFailed(what: "the buffers of a group", stage: group)) {
            _ = try Pipeline {
                ZTronDSPCore.Group(isActive: StateBox(true).binding) { LateFilter(kind: .fir, latency: Int(UInt32.max)); LateFilter(kind: .fir, latency: 1) }
            }.process(signal, format: format, blockSize: 64)
        }

        // The switch of a kernel counts its fade in 32 bits.
        #expect(UInt32(exactly: Int((0.010 * 1e12).rounded())) == nil)
        let fast = refusal { () throws(DSPError) in
            _ = try Pipeline { TestDelay(1, isActive: StateBox(true).binding) }.process(signal, format: SignalFormat(sampleRate: 1e12), blockSize: 64)
        }
        #expect(named(fast) == "TestDelay[0].sampleRate", "\(String(describing: fast))")

        // What the buffers hold, they hold: a group with a second of latency inside, switched, runs.
        let late = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestLate(latency: 48_000, chunk: 64) } }
            .process(signal, format: format, blockSize: 64)
        #expect(late.count == signal.count && late.allSatisfy { $0 == 0 }, "a second late: nothing of the signal has come out yet")
    }

    /// The time a new stage settles for is the sum of what its kernels and nodes say, capped at
    /// one second (SWAP-2, ACT-7). The old expressions added the figures as they came:
    /// `box.kernel.latency_frames + box.kernel.settling_frames` in 32 bits, and
    /// `node.latencyFrames + node.settlingFrames`.
    @Test func settlingTimesThatDoNotAddUpInTheirOwnTypeAreASecond() throws {
        #expect(UInt32(1).addingReportingOverflow(.max).overflow && Int.max.addingReportingOverflow(Int.max).overflow)
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64)
        let compiler = PlanCompiler(crossovers: .shipped)
        func plan(_ pipeline: Pipeline<Samples, Samples>, after previous: ExecutionPlan? = nil) throws -> ExecutionPlan {
            let lowered = try compiler.lower(pipeline.stages, environment: environment, blockSize: 64)
            return try ExecutionPlan(lowered: lowered, switchValues: [Bool](repeating: true, count: lowered.switches.count), crossovers: .shipped,
                                     generation: previous.map { $0.generation + 1 } ?? 1, previous: previous)
        }
        func preroll(_ plan: ExecutionPlan) -> Int? {
            for step in plan.root.steps {
                if case .region(let slot) = step { return slot.prerollLength }
            }
            return nil
        }
        // Inside a switched group: what the group runs for before it is faded in.
        let kernel = try plan(Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { SlowToSettle(); TestLate(latency: 0, chunk: 64) } })
        #expect(preroll(kernel) == 48_000, "a kernel that says 2³² frames in all: \(String(describing: preroll(kernel)))")
        let node = try plan(Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { SlowNode(seconds: 0, frames: .max) } })
        #expect(preroll(node) == 48_000, "a node that says twice the largest count: \(String(describing: preroll(node)))")

        // On the main line of an update: what the new part runs for beside the old plan.
        let running = try plan(Pipeline { TestGain(2) })
        let withKernel = try plan(Pipeline { TestGain(2); SlowToSettle() }, after: running)
        #expect(withKernel.transition?.mainLineUnchanged == false && withKernel.transition?.prerollFrames == 48_000)
        let withNode = try plan(Pipeline { TestGain(2); SlowNode(seconds: 0, frames: .max) }, after: running)
        #expect(withNode.transition?.prerollFrames == 48_000 && withNode.fadeLength == 480, "a second of pre-roll; a fade of 10 ms")
        let quick = try plan(Pipeline { TestGain(2); TestDelay(3) }, after: running)
        #expect(quick.transition?.prerollFrames == 3 && quick.fadeLength == 480, "three frames of delay to fill")
    }

    // MARK: What a stage leaves behind (PlanCompiler)

    /// Every count of frames behind a stage is made from the rate and the delay the stage
    /// leaves. A node states both: a delay that is not a finite time, or a rate that is not a
    /// positive, finite number, is refused where the pipeline is lowered, by the stage's name.
    /// Before, the first conversion behind such a stage trapped: `Int((.infinity * rate).rounded())`
    /// in a switched group, `Int((.nan * rate).rounded(.up))` where an update settles.
    @Test func aStageThatLeavesNoRateOrNoFiniteDelayIsRefusedByName() throws {
        #expect(Int(exactly: Double.infinity) == nil && Int(exactly: Double.nan) == nil)
        let late = refusal { () throws(DSPError) in _ = try Pipeline { SlowNode(seconds: .infinity) }.process(signal, format: format, blockSize: 64) }
        #expect(named(late) == "SlowNode[0].latency", "\(String(describing: late))")
        let switched = refusal { () throws(DSPError) in
            _ = try Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { SlowNode(seconds: .infinity) } }.process(signal, format: format, blockSize: 64)
        }
        #expect(named(switched) == "Group[0] › SlowNode[0].latency", "\(String(describing: switched))")
        for rate in [Double.nan, 0, -3, .infinity] {
            let error = refusal { () throws(DSPError) in _ = try Pipeline { RatedNode(rate: rate) }.process(signal, format: format, blockSize: 64) }
            #expect(named(error) == "RatedNode[0].sampleRate", "a sequence at \(rate) values per second: \(String(describing: error))")
        }
        // A latency that is no number at all adds nothing, as before: a stage that states none.
        let passed = try Pipeline { SlowNode(seconds: .nan) }.process(signal, format: format, blockSize: 64)
        let values = try Pipeline { RatedNode(rate: 750) }.process(signal, format: format, blockSize: 64)
        #expect(passed == signal && values.isEmpty)
    }
}
