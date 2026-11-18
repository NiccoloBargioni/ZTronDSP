import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

// Paths of the plan runner that the suites of WP-204, WP-220 and WP-221 never ran (COV-3): the
// reset of the identity kernel, a plan behind the kernel ABI, a plan the machine cannot hold, and
// a switch that is turned off while it is fading in.

/// A counter of destroyed kernels that outlives the plans of one test.
private final class DestroyCount {
    let pointer: UnsafeMutablePointer<Int32>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deallocate()
    }

    var value: Int { Int(pointer.pointee) }
}

@Suite("Plan runner: identity, nested plans, refusals (COV-3)")
struct CoveragePlanTests {
    // MARK: The identity kernel

    /// §5.11.1 (kernel ABI) and ACT-10: every kernel has a `reset`, and a reset is a cold start.
    /// The identity has no state, so a plan that is reset in mid-signal goes on copying it.
    @Test func resettingAnIdentityKernelLeavesItAnIdentity() {
        var identity = ztd_kernel_identity()
        #expect(identity.reset != nil && identity.command == nil && identity.destroy == nil, "a reset, and nothing to command or to free")
        let plan = ztd_plan_create(1, 1, 64)!
        defer { ztd_plan_destroy(plan) }
        #expect(ztd_plan_append(plan, identity, true) == 0)
        let signal = TestSignal.whiteNoise(count: 256, seed: 2_041)
        let buffers = MonoBuffers(capacity: 64)
        let before = buffers.run(plan, Array(signal[..<128]), blocks: [64])
        ztd_plan_reset(plan)
        let after = buffers.run(plan, Array(signal[128...]), blocks: [64, 7])
        #expect(before + after == signal, "the reset left nothing behind and took nothing away")
        // Called as the plan calls it, with the state the kernel was made with: none.
        identity.reset?(identity.state)
        #expect(!ztd_kernel_is_null(&identity) && identity.state == nil)
    }

    // MARK: A plan as one kernel (ACT-6)

    /// ACT-6, ztd_engine.h: a plan wrapped by `ztd_plan_as_kernel` runs as one kernel of another
    /// plan. Its latency and its settling time are the sums of its kernels', it runs them in
    /// order, a reset reaches every one of them, and it owns the plan: destroying the kernel
    /// destroys the plan and what the plan owns, once.
    @Test func aPlanBehindTheKernelABIRunsResetsAndDestroysItsKernels() {
        let destroyed = DestroyCount()
        let inner = ztd_plan_create(2, 1, 64)!
        let first = TestKernel.make(gain: 2, delay: 3, latency: 3, settling: 5, destroyed: destroyed.pointer)
        let second = TestKernel.make(gain: -0.5, delay: 4, latency: 4, settling: 7, destroyed: destroyed.pointer)
        #expect(ztd_plan_append(inner, first.kernel, true) == 0 && ztd_plan_append(inner, second.kernel, true) == 1)
        var nested = ztd_plan_as_kernel(inner)
        #expect(!ztd_kernel_is_null(&nested))
        #expect(nested.latency_frames == 7 && nested.settling_frames == 12, "the sums of the kernels inside")
        #expect(nested.command != nil && nested.reset != nil && nested.destroy != nil)

        let outer = ztd_plan_create(2, 1, 64)!
        let after = TestKernel.make(gain: 3)
        #expect(ztd_plan_append(outer, nested, true) == 0 && ztd_plan_append(outer, after.kernel, true) == 1)
        #expect(ztd_plan_latency(outer) == 7, "the outer plan counts the group's latency as one kernel's")

        let signal = TestSignal.whiteNoise(count: 640, seed: 2_042)
        let buffers = MonoBuffers(capacity: 64)
        let output = buffers.run(outer, signal, blocks: [64, 7, 33])
        // 2·x delayed by three, then −0.5 delayed by four, then 3: −3·x[n − 7].
        let expected = [Float](repeating: 0, count: 7) + signal.dropLast(7).map { (sample: Float) -> Float in -3 * sample }
        #expect(output == expected)
        #expect(first.state.pointee.calls == second.state.pointee.calls && first.state.pointee.calls == after.state.pointee.calls,
                "one call per kernel per block, inside the group as outside it")

        ztd_plan_reset(outer)
        #expect(first.state.pointee.resets == 1 && second.state.pointee.resets == 1 && after.state.pointee.resets == 1,
                "a reset of the outer plan is a cold start of every kernel inside the group")
        #expect(buffers.run(outer, signal, blocks: [64]) == output, "and the group starts as it did at creation")

        ztd_plan_destroy(outer)
        #expect(destroyed.value == 2, "the kernel owns the plan, and the plan its kernels: each destroyed once, not \(destroyed.value) times")
    }

    /// ztd_engine.h: "A command for it is forwarded to the kernel of the inner plan whose index is
    /// in the command's `flags`" (§5.5.4: values travel to the kernel that runs).
    @Test func aCommandForAGroupReachesTheKernelItsFlagsName() {
        let inner = ztd_plan_create(2, 1, 64)!
        let first = TestKernel.make(gain: 1), second = TestKernel.make(gain: 1)
        _ = ztd_plan_append(inner, first.kernel, true)
        _ = ztd_plan_append(inner, second.kernel, true)
        let outer = ztd_plan_create(2, 1, 64)!
        defer { ztd_plan_destroy(outer) }
        let before = TestKernel.make(gain: 1)
        _ = ztd_plan_append(outer, before.kernel, true)
        #expect(ztd_plan_append(outer, ztd_plan_as_kernel(inner), true) == 1)

        var command = ztd_command_t()
        command.target = 1          // the group, in the outer plan
        command.flags = 1           // its second kernel
        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        command.scalar.0 = 0.25
        ztd_plan_command(outer, &command)
        #expect(second.state.pointee.commands == 1 && second.state.pointee.gain == 0.25)
        #expect(first.state.pointee.commands == 0 && before.state.pointee.commands == 0, "and no other kernel")
        #expect(command.target == 1 && command.flags == 1, "the caller's command is not written to")

        command.flags = 0
        command.scalar.0 = 4
        ztd_plan_command(outer, &command)
        #expect(first.state.pointee.gain == 4 && first.state.pointee.commands == 1 && second.state.pointee.commands == 1)

        command.flags = 7           // no such kernel inside
        ztd_plan_command(outer, &command)
        #expect(first.state.pointee.commands == 1 && second.state.pointee.commands == 1, "a command for a kernel the group does not hold is ignored")

        let signal = TestSignal.whiteNoise(count: 64, seed: 2_043)
        let scaled = signal.map { (sample: Float) -> Float in sample * 4 * 0.25 }
        #expect(MonoBuffers(capacity: 64).run(outer, signal, blocks: [64]) == scaled, "both values are the ones that run")
    }

    /// ACT-6 and ACT-8: one switch bypasses the whole group. Switched off, not one kernel inside
    /// is called, and the unprocessed signal is delayed by the latency of the group, so nothing
    /// downstream moves in time.
    @Test func oneSwitchBypassesAWholeGroupAndKeepsItsLatency() {
        let inner = ztd_plan_create(2, 1, 64)!
        let first = TestKernel.make(gain: 2, delay: 3, latency: 3), second = TestKernel.make(gain: -0.5, delay: 4, latency: 4)
        _ = ztd_plan_append(inner, first.kernel, true)
        _ = ztd_plan_append(inner, second.kernel, true)
        let outer = ztd_plan_create(1, 1, 64)!
        defer { ztd_plan_destroy(outer) }
        #expect(ztd_plan_append(outer, ztd_plan_as_kernel(inner), true) == 0)
        #expect(ztd_plan_make_switchable(outer, 0, 64, true))

        let signal = TestSignal.whiteNoise(count: 64 * 20, seed: 2_044)
        let offAt = 64 * 8
        let output = MonoBuffers(capacity: 64).run(outer, signal, blocks: [64]) { position in
            if position == offAt { setActive(outer, 0, false) }
        }
        let delayed = [Float](repeating: 0, count: 7) + signal.dropLast(7)
        let inverted = delayed[..<offAt].map { (sample: Float) -> Float in -sample }
        #expect(Array(output[..<offAt]) == inverted, "switched on: the group's output")
        #expect(Array(output[(offAt + 64)...]) == Array(delayed[(offAt + 64)...]), "switched off, after a fade of one block: the input, seven frames late")
        #expect(ztd_plan_switch_state(outer, 0) == ZTD_SWITCH_BYPASSED)
        #expect(first.state.pointee.calls == 9 && second.state.pointee.calls == 9, "eight blocks switched on, one of fade, and then not one call")
    }

    /// ztd_engine.h: there is no kernel without a plan. What comes back is the kernel that is
    /// none (`process` is NULL), which a plan refuses to take.
    @Test func noPlanMakesNoKernel() {
        var none = ztd_plan_as_kernel(nil)
        #expect(ztd_kernel_is_null(&none) && none.state == nil && none.destroy == nil && none.reset == nil && none.command == nil)
        let plan = ztd_plan_create(1, 1, 16)!
        defer { ztd_plan_destroy(plan) }
        #expect(ztd_plan_append(plan, none, true) == UInt32.max && ztd_plan_count(plan) == 0)
        ztd_kernel_destroy(&none)       // harmless
    }

    // MARK: Plans the machine cannot hold (RT-3, §9.3)

    /// ztd_plan.h: "NULL when memory cannot be had". Scratch tables for 65 536 channels of
    /// 2³² − 1 frames are 2⁵⁰ bytes each, which no address space holds: the plan is not created,
    /// and what had been allocated for it is freed.
    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func aPlanWhoseScratchNoMachineCanHoldIsNotCreated() throws {
        var created = true
        let counts = try countAllocations {
            let plan = ztd_plan_create(4, 65_536, UInt32.max)
            created = plan != nil
            ztd_plan_destroy(plan)
        }
        #expect(!created, "2⁵⁰ bytes of scratch cannot be had")
        // Where the probe counts a request the system refuses as a request, the two scratch tables
        // show in what it counted: by their size.
        let refused = counts.bytes >= 1 << 50 ? 2 : 0
        #expect(counts.allocations - refused == counts.deallocations && counts.deallocations > 0,
                "what was had before the refusal is freed: \(counts)")
        #expect(ztd_plan_create(4, 0, 64) == nil, "and a plan of no channels is none")
    }

    /// ztd_plan.h, `ztd_plan_make_switchable`: "Returns false when memory cannot be had". The
    /// unprocessed path of a kernel with latency is a delay line of that many frames per channel
    /// (ACT-8); for 2³¹ frames of 65 536 channels it cannot be had. The kernel then has no
    /// switch: it stays active, and a switch command for it is ignored.
    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func aSwitchWhoseDelayLineCannotBeHadIsRefused() throws {
        let plan = try #require(ztd_plan_create(1, 65_536, 16))
        defer { ztd_plan_destroy(plan) }
        let kernel = TestKernel.make(gain: 1, latency: 1 << 31)
        #expect(ztd_plan_append(plan, kernel.kernel, true) == 0)
        var granted = true
        let counts = try countAllocations { granted = ztd_plan_make_switchable(plan, 0, 480, true) }
        #expect(!granted, "a delay line of 2⁴⁹ bytes cannot be had")
        // Where the probe counts a request the system refuses as a request, the delay line shows
        // in what it counted: by its size.
        let refused = counts.bytes >= 1 << 49 ? 1 : 0
        #expect(counts.allocations - refused == counts.deallocations && counts.deallocations > 0,
                "the half-made switch is freed: \(counts)")
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)
        setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE, "a kernel without a switch stays active")
        #expect(!ztd_plan_make_switchable(plan, 9, 480, true) && !ztd_plan_make_switchable(nil, 0, 480, true), "no such kernel, no such plan: no switch")
    }

    // MARK: A switch turned off while it fades in (ACT-7)

    /// ACT-7: a switch is a cross-fade between the processed and the unprocessed signal, and a
    /// switch that is turned round in the middle of a fade goes on from where the fade stands:
    /// no jump (CLICK-1). Here the stage is switched on from bypassed, and off again one block
    /// into a fade of eight blocks: the weight of the processed signal rises for 64 frames and
    /// falls for 64, sample for sample the mirror image, and the stage ends bypassed.
    @Test func aSwitchTurnedOffWhileItFadesInFadesBackFromWhereItStands() {
        let plan = ztd_plan_create(1, 1, 64)!
        defer { ztd_plan_destroy(plan) }
        let kernel = TestKernel.make(gain: 0.5)
        _ = ztd_plan_append(plan, kernel.kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, 512, false))
        let buffers = MonoBuffers(capacity: 64)
        let ones = [Float](repeating: 1, count: 64)

        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_IN && kernel.state.pointee.resets == 1, "no settling time: reset, then straight to the fade")
        let rising = buffers.run(plan, ones, blocks: [64])
        // The unprocessed signal is 1, the processed one 0.5; frame k of the fade has the weight (k + 1) / 512.
        let step: Float = 1 / 512
        let unprocessed: Float = 1, processed: Float = 0.5
        let expectedRise = (0 ..< 64).map { (frame: Int) -> Float in unprocessed + (processed - unprocessed) * (Float(frame + 1) * step) }
        #expect(rising == expectedRise)

        setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_OUT, "turned round, not restarted")
        let falling = buffers.run(plan, ones, blocks: [64])
        // 64 frames in, so 64 frames out: the fade is taken up at frame 512 − 64.
        let expectedFall = (0 ..< 64).map { (frame: Int) -> Float in
            frame == 63 ? unprocessed : processed + (unprocessed - processed) * (Float(448 + frame + 1) * step)
        }
        #expect(falling == expectedFall)
        #expect(falling.last == unprocessed && ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED, "back at the unprocessed signal after as many frames as it had faded in")
        let largest = Click.largestStep(rising + falling, in: 0 ..< 128), oneStep: Float = 0.5 * step * 1.0001
        #expect(largest <= oneStep, "one step of the fade between any two samples, at the turn too: \(largest)")

        #expect(kernel.state.pointee.calls == 2)
        #expect(buffers.run(plan, ones, blocks: [64]) == ones && kernel.state.pointee.calls == 2, "bypassed: the kernel is not called")
    }

    /// ACT-7: switched on and off again before a single frame was faded in, the stage is
    /// bypassed at once: nothing of it was audible, so there is nothing to fade out.
    @Test func aSwitchTurnedOffBeforeItsFadeInBeganIsBypassedAtOnce() {
        let plan = ztd_plan_create(1, 1, 64)!
        defer { ztd_plan_destroy(plan) }
        let kernel = TestKernel.make(gain: 0.5)
        _ = ztd_plan_append(plan, kernel.kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, 512, false))
        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_IN)
        setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED)
        let signal = TestSignal.whiteNoise(count: 128, seed: 2_045)
        #expect(MonoBuffers(capacity: 64).run(plan, signal, blocks: [64]) == signal && kernel.state.pointee.calls == 0)
    }
}
