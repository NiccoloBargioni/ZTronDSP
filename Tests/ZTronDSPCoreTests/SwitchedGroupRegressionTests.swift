import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Switched groups of kernels (ACT-1, ACT-3, ACT-5, ACT-8, REAL-5): a stage with a switch of
/// its own inside the group, and a group that changes the rate inside and restores it.
///
/// A `Group(isActive:)` that holds kernels only used to become one kernel of the plan, a plan
/// of its own behind the kernel ABI, whatever the kernels were. Such a kernel can switch
/// nothing inside itself, counts its latency in frames of one rate, and is handed buffers for
/// as many frames as it reads. Each test here was a defect of that. A group now runs as one
/// kernel only when every kernel inside keeps the rate and none has a switch of its own; any
/// other group runs its steps one by one between the group's markers, as a group with a node
/// does.
@Suite("Switched groups: a switch inside, a rate change inside (ACT-1, ACT-5, ACT-8)")
struct SwitchedGroupRegressionTests {
    let format = SignalFormat(sampleRate: 48_000)
    let noise = TestSignal.whiteNoise(count: 64 * 120, seed: 5_150)

    private func ones(_ blocks: Int) -> [Float] { [Float](repeating: 1, count: 64 * blocks) }

    // MARK: A stage with its own switch inside a group (ACT-1, ACT-5)

    /// ACT-5: "A stage with a bound activation gets a run-time switch in the plan." ACT-1:
    /// `Group` takes `isActive:` like every stage, and so do the stages inside it.
    ///
    /// A stage with its own bound switch stands in a `Group(isActive:)`. With a node in the
    /// group, both switches work. With kernels only in the group, the stage's own switch must
    /// still switch the stage.
    ///
    /// The defect: the group became one kernel, whose plan gave no kernel inside a switch; the
    /// ordinal of the inner switch had nothing to act on. The binding was read and forwarded,
    /// and nothing moved.
    @Test func aBoundSwitchInsideAGroupOfKernelsSwitchesItsStage() async throws {
        // The control: the same switches around a node. The inner switch bypasses the gain.
        let control = Rig()
        let outerA = StateBox(true), innerA = StateBox(true)
        let (withNode, nodeProbe) = try await control.probed(Pipeline {
            ZTronDSPCore.Group(isActive: outerA.binding) { TestGain(2, isActive: innerA.binding); TestLate(latency: 0, chunk: 64) }
        })
        control.feed(ones(2))
        await control.set(innerA, to: false, of: withNode)
        control.feed(ones(12))
        #expect(nodeProbe.samples.last == -1, "with a node in the group the inner switch bypasses its gain (the test node inverts)")
        withNode.detach()

        // The same with kernels only.
        let rig = Rig()
        let outer = StateBox(true), inner = StateBox(true)
        let (session, probe) = try await rig.probed(Pipeline {
            ZTronDSPCore.Group(isActive: outer.binding) { TestGain(2, isActive: inner.binding); TestDelay(0) }
        })
        #expect(session.core.plan.lowered.switches.count == 2)
        rig.feed(ones(2))
        #expect(probe.samples.last == -2, "both on: the gain, then the test delay, which inverts")
        await rig.set(inner, to: false, of: session)
        rig.feed(ones(12))
        #expect(probe.samples.last == -1, "the inner switch is off and its gain is bypassed: \(probe.samples.last ?? 0)")
        // The group's own switch works, so the two are not the same switch.
        await rig.set(outer, to: false, of: session)
        rig.feed(ones(12))
        #expect(probe.samples.last == 1, "the group's switch bypasses the group")
        session.detach()
    }

    /// ACT-7 for the stage inside: its switch is a cross-fade of 10 ms, off and on, while the
    /// group around it stays on; and each bound switch of the pipeline has something to move.
    @Test func theSwitchOfAStageInsideAGroupFadesLikeAnyOther() async throws {
        let rig = Rig()
        let outer = StateBox(true), inner = StateBox(true)
        let (session, probe) = try await rig.probed(Pipeline {
            ZTronDSPCore.Group(isActive: outer.binding) { TestGain(3, isActive: inner.binding); TestGain(2) }
        })
        let plan = session.core.plan
        let moves = plan.switchTargets.filter { target in if case .none = target { false } else { true } }.count
        #expect(plan.switchTargets.count == 2 && moves == 2, "two bound switches, and each acts on something")
        #expect(!plan.lowered.skeleton[0].isKernelRegion, "a group with a switch inside does not run as one kernel")
        rig.feed(ones(2))
        #expect(probe.samples.last == 6)
        await rig.set(inner, to: false, of: session)
        rig.feed(ones(10))
        let fading = Array(probe.samples[128 ..< 608])
        #expect(zip(fading, fading.dropFirst()).allSatisfy { $0 >= $1 } && fading[0] < 6 && fading[0] > 5.9 && probe.samples.last == 2,
                "480 frames from 6 to 2: the stage is faded out, not cut")
        await rig.set(inner, to: true, of: session)
        rig.feed(ones(10))
        #expect(probe.samples.last == 6 && session.core.generation == 1, "and faded in again; nothing was compiled")
        session.detach()
    }

    // MARK: A rate change inside a group (ACT-3, ACT-5)

    /// ACT-5: "The active path pays one flag test": a bound switch that is on changes nothing
    /// about the signal. ACT-3 names "groups and recipes that [keep the rate]" as bypassable.
    ///
    /// A group that changes the rate inside and restores it (every third sample kept, then two
    /// zeros inserted after each) produces, for a block of 64 frames, 66 frames in two blocks
    /// out of three: a rate changer carries a phase across blocks. Without a switch the plan's
    /// buffers are sized for that. With a bound switch the output must be the same samples.
    ///
    /// The defect: a switched group of kernels was sized by the block at its input and not by
    /// what the group may deliver. The 66 frames were cut to 64, and every sample after them
    /// was two frames early.
    @Test func aSwitchedGroupThatChangesTheRateInsideLosesNoSample() throws {
        let signal = Array(noise[..<(64 * 12)])
        let expected = signal.enumerated().map { (entry: (offset: Int, element: Float)) -> Float in entry.offset % 3 == 0 ? entry.element : 0 }
        let plain = try Pipeline { TestSubsample(by: 3); TestZeroStuff(factor: 3) }.process(signal, format: format, blockSize: 64)
        #expect(plain == expected, "without a switch: every third sample, and zeros between")
        let switched = try Pipeline {
            ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestSubsample(by: 3); TestZeroStuff(factor: 3) }
        }.process(signal, format: format, blockSize: 64)
        let firstDifference = zip(switched, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(switched == expected, "with a switch that is on, \(switched.count) of \(expected.count) samples come out; the first that differs is \(firstDifference ?? -1)")
    }

    /// The bound behind it: whatever a group hands on in one block, the buffers it is given
    /// hold it. Factors up to one frame short of the block make the group deliver almost two
    /// blocks' worth at once (126 frames for 64 with a factor of 63); every sample arrives, at
    /// every block size, and every run of kernels in the plan writes into buffers of the
    /// frames its C plan was made for, which are at least the frames its kernels may write.
    @Test(arguments: [3, 7, 63], [64, 37, 480])
    func aGroupThatChangesTheRateInsideNeverOutgrowsItsBuffers(factor: Int, blockSize: Int) throws {
        let signal = Array(noise[..<2_400])
        let kept = signal.enumerated().map { (entry: (offset: Int, element: Float)) -> Float in entry.offset % factor == 0 ? entry.element : 0 }
        // Zeros are stuffed after the last sample kept as after every other: whole multiples of the factor come out.
        let expected = kept + [Float](repeating: 0, count: (signal.count + factor - 1) / factor * factor - signal.count)
        let plain = try Pipeline { TestSubsample(by: factor); TestZeroStuff(factor: factor) }.process(signal, format: format, blockSize: blockSize)
        #expect(plain == expected, "without a switch, factor \(factor), blocks of \(blockSize)")
        let pipeline = Pipeline {
            ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestSubsample(by: factor); TestZeroStuff(factor: factor) }
        }
        let switched = try pipeline.process(signal, format: format, blockSize: blockSize)
        #expect(switched == expected, "with a switch that is on, factor \(factor), blocks of \(blockSize): \(switched.count) of \(expected.count) samples")

        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: blockSize, isRealTime: false)
        let lowered = try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: blockSize)
        guard case .region(let region)? = lowered.skeleton.first else {
            Issue.record("the pipeline is its group")
            return
        }
        // After keeping every `factor`-th frame and stuffing again: up to one factor more than came in.
        let most = (blockSize + factor - 1) / factor * factor
        #expect(!lowered.skeleton[0].isKernelRegion && region.outputMaximumFrames >= most, "a group that changes the rate inside is not one kernel")
        let plan = try ExecutionPlan(lowered: lowered, switchValues: [true], crossovers: .shipped, generation: 1, previous: nil)
        var runs = 0
        for step in plan.root.steps {
            guard case .kernels(let run) = step else { continue }
            runs += 1
            let made = Int(ztd_plan_maximum_frames(run.plan))
            #expect(run.output.capacity == made && run.middle.capacity == made && made >= most, "a run of kernels holds what its kernels write: \(made) frames")
        }
        #expect(runs == 1, "the kernels inside the group run as kernels of the plan")
    }

    /// ACT-6 as it was: a group whose kernels all keep the rate, and none of which has a switch
    /// of its own, still runs as one kernel, in buffers made for the frames it reads.
    @Test func aGroupOfKernelsThatKeepTheRateRunsAsOneKernel() throws {
        let environment = DSPEnvironment(sampleRate: 48_000, channelCount: 2, blockSize: 64)
        let pipeline = Pipeline { ZTronDSPCore.Group(isActive: StateBox(true).binding) { TestGain(2); TestDelay(5); TestBiquad() } }
        let lowered = try PlanCompiler(crossovers: .shipped).lower(pipeline.stages, environment: environment, blockSize: 64)
        #expect(lowered.skeleton.count == 1 && lowered.skeleton[0].isKernelRegion)
        let plan = try ExecutionPlan(lowered: lowered, switchValues: [true], crossovers: .shipped, generation: 1, previous: nil)
        guard plan.root.steps.count == 2, case .kernels(let run) = plan.root.steps[0], let state = run.boxes.first?.kernel.state else {
            Issue.record("one run of one kernel, and the output")
            return
        }
        let inside = OpaquePointer(state)
        #expect(run.boxes.count == 1 && ztd_plan_count(run.plan) == 1 && ztd_plan_count(inside) == 3, "three kernels behind one")
        #expect(ztd_plan_maximum_frames(inside) == 64 && ztd_plan_maximum_frames(run.plan) == 64 && ztd_plan_channels(inside) == 2)
        #expect(run.boxes[0].kernel.latency_frames == 5 && plan.kernelTargets.count == 3 && plan.switchTargets.count == 1)
    }

    // MARK: Latency of a group that changes the rate inside (ACT-8, REAL-5)

    /// ACT-8: "Switching never changes the session's latency or the alignment of anything
    /// downstream." REAL-5: the delay a stage adds is counted in the frames of its input.
    ///
    /// A switched group halves the rate, delays by three frames at the low rate, and restores
    /// the rate: six frames of delay at the group's input, which is what the session's
    /// environment says. Switched on, an impulse comes out six frames late; switched off, the
    /// unprocessed path must delay it by the same six frames.
    ///
    /// The defect: the group, as one kernel, had the sum of its kernels' latencies, each in the
    /// frames of its own input, so three frames at half the rate counted as three frames of the
    /// group. The delay line of the unprocessed path was three frames long, and a bypassed
    /// impulse arrived three frames early.
    @Test func aSwitchedGroupWithARateChangeInsideKeepsItsAlignmentWhenBypassed() async throws {
        let format = format
        let impulse = TestSignal.impulse(count: 64 * 8, at: 128)
        @Sendable func arrival(active: Bool) async throws -> (index: Int?, latency: Double) {
            let pipeline = Pipeline {
                ZTronDSPCore.Group(isActive: StateBox(active).binding) { TestSubsample(by: 2); TestDelay(3); TestZeroStuff(factor: 2) }
            }
            let latency = try PlanCompiler(crossovers: .shipped)
                .lower(pipeline.stages, environment: DSPEnvironment(sampleRate: 48_000, channelCount: 1, blockSize: 64), blockSize: 64)
                .output.environment.latency
            // A bound switch is read on the main actor (BIND-1); off it, it counts as on.
            let output = try await MainActor.run { try pipeline.process(impulse, format: format, blockSize: 64) }
            return (output.firstIndex { $0 != 0 }, latency)
        }
        let on = try await arrival(active: true), off = try await arrival(active: false)
        #expect(on.latency == 6.0 / 48_000 && off.latency == on.latency, "the environment says six frames")
        #expect(on.index == 128 + 6, "switched on, the impulse is six frames late")
        #expect(off.index == 128 + 6, "bypassed, it arrives at \(off.index ?? -1), as late as when the group is on")
    }

    /// The same on a running session, with the switch moved in mid-signal (WP-221: "also when
    /// the switch flips in mid-signal"): an impulse train through the group arrives six frames
    /// late whether the group is on, off, or on again, and the session's latency never moves.
    @Test func aGroupWithARateChangeInsideKeepsItsAlignmentWhileItIsSwitched() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let counter = CallCounter()
        let (session, probe) = try await rig.probed(Pipeline {
            ZTronDSPCore.Group(isActive: on.binding) { TestSubsample(by: 2); CountedDelay(counter, delay: 3); TestZeroStuff(factor: 2) }
        })
        #expect(session.environment.latency == 6.0 / 48_000)
        let resets = counter.resets
        // One impulse every 512 frames, on an even frame, so the group keeps it when it is on.
        var signal = [Float](repeating: 0, count: 64 * 96)
        for position in stride(from: 256, to: signal.count, by: 512) { signal[position] = 1 }
        rig.feed(Array(signal[..<(64 * 24)]))
        await rig.set(on, to: false, of: session)
        rig.feed(Array(signal[(64 * 24) ..< (64 * 56)]))
        await rig.set(on, to: true, of: session)
        rig.feed(Array(signal[(64 * 56)...]))

        #expect(probe.samples.count == signal.count && session.environment.latency == 6.0 / 48_000)
        let arrivals = probe.samples.indices.filter { probe.samples[$0] != 0 }
        let expected = stride(from: 256, to: signal.count, by: 512).map { $0 + 6 }
        #expect(arrivals == expected, "every impulse six frames late: on, off, and while the group is faded: \(arrivals)")
        #expect(arrivals.allSatisfy { abs(probe.samples[$0] - 1) < 1e-5 }, "and whole: the two paths agree where they are mixed")
        #expect(session.core.generation == 1 && counter.resets == resets + 1, "switched on again, the stages inside started cold; nothing was compiled")
        session.detach()
    }
}
