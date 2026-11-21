import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

// A gain written twice outside the package's stock stages, once on a C kernel of its own and
// once as a processor, each stating its amounts as values (§5.5.4): the gain is their product.

/// What the test sees of the kernels and processors a stage made.
private struct Counters {
    var made = 0
    var frames = 0
    var commands = 0
    var resets = 0
}

private final class Probe: Hashable, CustomStringConvertible, @unchecked Sendable {
    // Threading: written by the kernel or the processor on the thread that runs the plan, which
    // is the test's own (the engine is driven by hand), and read by the test between blocks.
    let counters: UnsafeMutablePointer<Counters>

    init() {
        counters = .allocate(capacity: 1)
        counters.initialize(to: Counters())
    }

    deinit {
        counters.deallocate()
    }

    var made: Int { counters.pointee.made }
    var frames: Int { counters.pointee.frames }
    var commands: Int { counters.pointee.commands }
    var resets: Int { counters.pointee.resets }
    var description: String { "\(made) made, \(frames) frames, \(commands) command(s), \(resets) reset(s)" }

    static func == (lhs: Probe, rhs: Probe) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

private struct ValuedKernelState {
    var gain: Float
    let counters: UnsafeMutablePointer<Counters>
}

/// The kernel: `out = in · gain`. It takes its values as `ZTD_COMMAND_SET_VALUES` with `count`
/// doubles, and its gain is their product.
private func valuedKernel(_ values: [Double], _ counters: UnsafeMutablePointer<Counters>, takesCommands: Bool = true) -> ztd_kernel_t {
    let state = UnsafeMutablePointer<ValuedKernelState>.allocate(capacity: 1)
    state.initialize(to: ValuedKernelState(gain: Float(values.reduce(1, *)), counters: counters))
    counters.pointee.made += 1
    return ztd_kernel_t(
        process: { state, input, output, channels, frames in
            guard let state, let input, let output else { return 0 }
            let kernel = state.assumingMemoryBound(to: ValuedKernelState.self)
            var channel = 0
            while channel < Int(channels) {
                if let source = input[channel], let target = output[channel] {
                    var frame = 0
                    while frame < Int(frames) {
                        target[frame] = source[frame] * kernel.pointee.gain
                        frame += 1
                    }
                }
                channel += 1
            }
            kernel.pointee.counters.pointee.frames += Int(frames)
            return frames
        },
        command: !takesCommands ? nil : { state, command in
            guard let state, let command, command.pointee.kind == UInt32(ZTD_COMMAND_SET_VALUES), let values = command.pointee.values else { return }
            let kernel = state.assumingMemoryBound(to: ValuedKernelState.self)
            let doubles = values.assumingMemoryBound(to: Double.self)
            var product = 1.0
            var index = 0
            while index < Int(command.pointee.count) {
                product *= doubles[index]
                index += 1
            }
            kernel.pointee.gain = Float(product)
            kernel.pointee.counters.pointee.commands += 1
        },
        reset: { state in
            guard let state else { return }
            state.assumingMemoryBound(to: ValuedKernelState.self).pointee.counters.pointee.resets += 1
        },
        destroy: { state in
            guard let state else { return }
            let kernel = state.assumingMemoryBound(to: ValuedKernelState.self)
            kernel.deinitialize(count: 1)
            kernel.deallocate()
        },
        state: UnsafeMutableRawPointer(state), latency_frames: 0, settling_frames: 0)
}

private struct ValuedKernelGain: SequenceStage {
    let amounts: [Double]
    let probe: Probe
    var takesCommands = true

    var parameters: [Double] { amounts }

    func replacingParameters(_ values: ArraySlice<Double>) -> ValuedKernelGain {
        Array(values) == amounts ? self : ValuedKernelGain(amounts: Array(values), probe: probe, takesCommands: takesCommands)
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let counters = probe, takesCommands = takesCommands
        context.emit(.custom(CustomKernel(name: "ValuedKernelGain", key: takesCommands, values: amounts) { _, _, _, values in
            valuedKernel(values, counters.counters, takesCommands: takesCommands)
        }))
    }
}

/// The same gain as a processor that takes its values while it runs.
private final class ValuedProcessor: AdjustableSampleProcessor {
    let latencyFrames = 0
    let settlingFrames = 0
    private var gain: Float
    private let counters: UnsafeMutablePointer<Counters>

    init(_ values: [Double], _ counters: UnsafeMutablePointer<Counters>) {
        gain = Float(values.reduce(1, *))
        self.counters = counters
        counters.pointee.made += 1
    }

    func process(_ block: inout AudioBlock) {
        var channel = 0
        while channel < block.channelCount {
            let samples = block.channel(channel)
            var frame = 0
            while frame < block.frameCount {
                samples[frame] *= gain
                frame += 1
            }
            channel += 1
        }
        counters.pointee.frames += block.frameCount
    }

    func setValues(_ values: UnsafeBufferPointer<Double>) {
        var product = 1.0
        var index = 0
        while index < values.count {
            product *= values[index]
            index += 1
        }
        gain = Float(product)
        counters.pointee.commands += 1
    }

    func reset() {
        counters.pointee.resets += 1
    }
}

private struct ValuedProcessorGain: SequenceStage {
    let amounts: [Double]
    let probe: Probe

    var parameters: [Double] { amounts }

    func replacingParameters(_ values: ArraySlice<Double>) -> ValuedProcessorGain {
        Array(values) == amounts ? self : ValuedProcessorGain(amounts: Array(values), probe: probe)
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let probe = probe
        context.emit(.processor(CustomProcessor(name: "ValuedProcessorGain", key: 0, values: amounts) {
            (_, values) throws(DSPError) -> any AdjustableSampleProcessor in
            ValuedProcessor(values, probe.counters)
        }))
    }
}

/// §5.5.4, EXT-1, EXT-2 (CR-025 item 2): a stage that lowers to a kernel or a processor of the
/// caller's own states continuous values that stand outside its identity. A change of those
/// values alone is a change of values: no plan is compiled, the kernel keeps its state, and
/// the values reach it on the thread that runs it, at a block boundary.
///
/// The defect: the key was the whole identity, and the engine sent `ZTD_COMMAND_SET_VALUES`
/// to the stock specs only. A changed amount compiled a plan; the new kernel started cold and
/// was pre-rolled, and a sink behind it received nothing for the pre-roll and the fade.
@Suite("Values of a kernel and a processor of the caller's own (§5.5.4, EXT-1)")
struct CustomValueTests {
    enum Kind: String, CaseIterable, Sendable {
        case kernel, processor
    }

    private let ones = [Float](repeating: 1, count: 256)

    private func gain(_ kind: Kind, _ amounts: [Double], _ probe: Probe) -> Pipeline<Samples, Samples> {
        switch kind {
        case .kernel: Pipeline { ValuedKernelGain(amounts: amounts, probe: probe) }
        case .processor: Pipeline { ValuedProcessorGain(amounts: amounts, probe: probe) }
        }
    }

    private func replans(_ log: EventLog) -> Int {
        log.all.filter { (event: SessionEvent) -> Bool in if case .replanned = event { true } else { false } }.count
    }

    @Test(arguments: Kind.allCases)
    func aChangedValueReachesTheStageThatRunsAndNothingIsCompiled(kind: Kind) async throws {
        let rig = Rig()
        let probe = Probe(), heard = CollectingSink<Samples>()
        let session = try await rig.engine.attach(gain(kind, [2], probe).emit(to: heard), to: rig.source)
        let log = EventLog(session)
        try session.start()
        rig.feed(ones)
        // A session starts cold (ACT-10): the one reset there is.
        #expect(probe.resets == 1)
        try await session.update(gain(kind, [3], probe).emit(to: heard))
        rig.feed(ones)
        #expect(session.core.generation == 1, "a change of values compiles no plan")
        #expect(probe.made == 1 && probe.resets == 1 && probe.commands == 1 && probe.frames == 512, "the stage that ran goes on, with its state: \(probe)")
        #expect(heard.samples == [Float](repeating: 2, count: 256) + [Float](repeating: 3, count: 256),
                "the sink behind it received every frame, the new value from the block boundary on")

        // An animated value: the pipeline's parameters moved, as one frame of an animation moves them (ANI-2).
        let moving = gain(kind, [3], probe).emit(to: heard)
        #expect(moving.parameters == ParameterVector([3]))
        try await session.update(moving.replacingParameters(ParameterVector([3.5])))
        rig.feed(ones)
        try await session.update(moving.replacingParameters(ParameterVector([3.5])))
        #expect(session.core.generation == 1 && probe.made == 1 && probe.commands == 2, "one command for the value that moved, none for one that did not: \(probe)")
        #expect(Array(heard.samples[512...]) == [Float](repeating: 3.5, count: 256))

        session.stop()
        #expect(await eventually(timeout: 30) { log.states.contains(.idle) })
        #expect(replans(log) == 0, "no re-plan is reported: \(log.all)")
        session.detach()
    }

    @Test(arguments: Kind.allCases)
    func aStageKeepsItsStateAndItsValuesAcrossAChangeOfTopologyElsewhere(kind: Kind) async throws {
        let rig = Rig()
        let probe = Probe()
        let session = try await rig.engine.attach(gain(kind, [2], probe), to: rig.source)
        let output = OutputProbe()
        rig.engine.core.addProbe(output, to: session.core)
        try session.start()
        rig.feed(ones)
        try await session.update(gain(kind, [3], probe))
        rig.feed(ones)
        // Another stage behind it: a new plan, into which the stage is moved as it is (SWAP-1).
        let longer: Pipeline<Samples, Samples> = switch kind {
        case .kernel: Pipeline { ValuedKernelGain(amounts: [3], probe: probe); TestGain(0.5) }
        case .processor: Pipeline { ValuedProcessorGain(amounts: [3], probe: probe); TestGain(0.5) }
        }
        try await session.update(longer)
        rig.feed([Float](repeating: 1, count: 64 * 40))
        #expect(session.core.generation == 2, "another stage is another plan")
        // One reset, when the session started (ACT-10): none since.
        #expect(probe.made == 1 && probe.resets == 1 && probe.commands == 1, "the stage was moved, not made again: \(probe)")
        #expect(output.samples.last == 1.5, "and runs on the value it was sent last: \(output.samples.last ?? -1)")
        session.detach()
    }

    @Test(arguments: Kind.allCases)
    func anotherNumberOfValuesIsAnotherStage(kind: Kind) async throws {
        let rig = Rig()
        let probe = Probe()
        let session = try await rig.engine.attach(gain(kind, [2], probe), to: rig.source)
        let log = EventLog(session)
        let output = OutputProbe()
        rig.engine.core.addProbe(output, to: session.core)
        try session.start()
        rig.feed(ones)
        try await session.update(gain(kind, [2, 1.5], probe))
        rig.feed([Float](repeating: 1, count: 64 * 40))
        #expect(session.core.generation == 2 && probe.made == 2, "two values where there was one: a change of topology: \(probe)")
        #expect(output.samples.last == 3)
        #expect(await eventually(timeout: 30) { replans(log) == 1 }, "and it is reported as one: \(log.all)")
        session.detach()
    }

    @Test(arguments: Kind.allCases)
    func theOfflinePathMakesTheStageWithItsValues(kind: Kind) throws {
        let probe = Probe()
        let output = try gain(kind, [2.5, 2], probe).process(ones, format: SignalFormat(sampleRate: 48_000), blockSize: 64)
        #expect(output == [Float](repeating: 5, count: 256) && probe.made == 1 && probe.commands == 0, "made with its values, sent none: \(probe)")
    }

    /// RT-2, RT-4: the values travel in memory the control context allocates and frees; where
    /// the stage runs, taking them allocates nothing and frees nothing.
    @Test(arguments: Kind.allCases)
    func aValueIsHandedOverWithoutAllocatingWhereTheStageRuns(kind: Kind) async throws {
        let rig = Rig()
        let probe = Probe()
        let session = try await rig.engine.attach(gain(kind, [2], probe), to: rig.source)
        try session.start()
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [[Float](repeating: 1, count: 64)])
        rig.source.write(block.block())
        _ = runner.turn(now: 0)
        for round in 1 ... 20 {
            // The control context: the payload is made here.
            try await session.update(gain(kind, [2 + Double(round) * 0.25], probe))
            // The thread that runs the plan: the command is applied at the first block boundary.
            expectNoAllocations("round \(round)") {
                var count = 0
                while count < 8 {
                    rig.source.write(block.block())
                    _ = runner.turn(now: 0)
                    count += 1
                }
            }
            // The control context again: the payload that was applied is freed here.
            rig.engine.core.runTurn()
        }
        #expect(probe.commands == 20 && probe.made == 1 && session.core.generation == 1, "\(probe)")
        session.detach()
    }

    /// A value reaches a kernel inside a group that is switched as one (ACT-6): the group is
    /// one kernel of the plan, and the command is passed on to the kernel inside.
    @Test func aValueReachesAKernelInsideASwitchedGroup() async throws {
        let rig = Rig()
        let probe = Probe()
        let on = StateBox(true)
        func grouped(_ amount: Double) -> Pipeline<Samples, Samples> {
            Pipeline { ZTronDSPCore.Group(isActive: on.binding) { TestGain(0.5); ValuedKernelGain(amounts: [amount], probe: probe) } }
        }
        let session = try await rig.engine.attach(grouped(2), to: rig.source)
        let output = OutputProbe()
        rig.engine.core.addProbe(output, to: session.core)
        try session.start()
        rig.feed(ones)
        #expect(output.samples.last == 1)
        try await session.update(grouped(6))
        rig.feed(ones)
        #expect(session.core.generation == 1 && probe.made == 1 && probe.commands == 1 && output.samples.last == 3, "\(probe)")
        session.detach()
    }

    // MARK: The descriptions

    @Test func valuesStandOutsideTheIdentityOfADescription() {
        let probe = Probe()
        func kernel(_ values: [Double], key: Int = 0) -> CustomKernel {
            CustomKernel(name: "K", key: key, values: values) { _, _, _, values in valuedKernel(values, probe.counters) }
        }
        #expect(kernel([1, 2]) == kernel([1, 2]) && kernel([1, 2]) != kernel([1, 3]), "other values are another description")
        #expect(kernel([1, 2]).hasSameStructure(as: kernel([1, 3])) && kernel([1, 2]).hashValue == kernel([1, 3]).hashValue, "of the same kernel")
        #expect(!kernel([1, 2]).hasSameStructure(as: kernel([1])) && !kernel([1]).hasSameStructure(as: kernel([1], key: 1)))
        #expect(kernel([1, 2]).values == [1, 2])
        // The initialiser without values is the one there was: no values, and `make` is not handed any.
        let plain = CustomKernel(name: "K", key: 0) { _, _, _ in ztd_kernel_identity() }
        #expect(plain.values.isEmpty && plain == CustomKernel(name: "K", key: 0) { _, _, _ in ztd_kernel_identity() })
        #expect(KernelSpec.custom(plain).commandPayload() == nil, "nothing to send")

        func processor(_ values: [Double], key: Int = 0) -> CustomProcessor {
            CustomProcessor(name: "P", key: key, values: values) { (_, values) throws(DSPError) -> any AdjustableSampleProcessor in
                ValuedProcessor(values, probe.counters)
            }
        }
        #expect(processor([4]) == processor([4]) && processor([4]) != processor([5]) && processor([4]).hasSameStructure(as: processor([5])))
        #expect(!processor([4]).hasSameStructure(as: processor([4, 4])) && !processor([4]).hasSameStructure(as: processor([4], key: 1)))
        #expect(processor([4]).hashValue == processor([5]).hashValue && processor([4, 5]).values == [4, 5])

        // What a command carries: the values, as doubles, in memory the caller frees.
        for spec in [KernelSpec.custom(kernel([1.5, -2])), .processor(processor([1.5, -2]))] {
            let payload = spec.commandPayload()
            #expect(payload?.count == 2)
            if let payload {
                let doubles = payload.pointer.assumingMemoryBound(to: Double.self)
                #expect(doubles[0] == 1.5 && doubles[1] == -2)
                payload.pointer.deallocate()
            }
        }
    }

    /// A kernel that states values is given them through its `command` entry. One that has
    /// none could never be given other values: the plan is refused, by the stage's name.
    @Test func aKernelThatCouldNeverBeGivenItsValuesIsRefused() throws {
        let probe = Probe()
        let mute = Pipeline { ValuedKernelGain(amounts: [2], probe: probe, takesCommands: false) }
        let error = #expect(throws: DSPError.self) { _ = try mute.process(ones, format: SignalFormat(sampleRate: 48_000), blockSize: 64) }
        guard case .unsupportedConfiguration(let reason, let stage)? = error else {
            Issue.record("\(String(describing: error))")
            return
        }
        #expect(reason.contains("`command`") && stage?.description == "ValuedKernelGain[0]", "\(reason) at \(String(describing: stage))")
        #expect(probe.made == 1, "the kernel that was made for it was destroyed")
        // Without values it needs no such entry.
        let silent = Pipeline { ValuedKernelGain(amounts: [], probe: probe, takesCommands: false) }
        #expect(try silent.process(ones, format: SignalFormat(sampleRate: 48_000), blockSize: 64) == ones)
    }
}
