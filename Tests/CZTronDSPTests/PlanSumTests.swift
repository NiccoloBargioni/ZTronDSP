import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// Counts the kernels a test saw destroyed.
private final class Destroyed {
    let pointer: UnsafeMutablePointer<Int32>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: 0)
    }

    deinit {
        pointer.deallocate()
    }

    var count: Int { Int(pointer.pointee) }
}

/// A kernel states its latency and its settling time in 32 bits each, and a plan adds them:
/// for the pre-roll of a switch (ACT-7), and for the one kernel a group of kernels becomes
/// (ACT-6, REAL-5). The sums were made in 32 bits and came out as what was left of them. They
/// are made in a type that holds them now: a time a plan only runs for stays at the largest
/// count, and a latency, which everything downstream is timed by, is refused.
@Suite("Sums of a plan's kernels (ACT-7, REAL-5)")
struct PlanSumTests {
    /// ACT-7: a stage that is switched on runs unheard "for its latency plus its settling time".
    /// The defect: a kernel that states 1 and 2³² − 1 frames was pre-rolled for 0 frames, the
    /// rest of the sum, and was faded in at once.
    @Test func aPreRollBeyondThirtyTwoBitsIsTheLargestCount() {
        #expect(UInt32(1) &+ UInt32.max == 0, "what the sum in 32 bits came to")
        let plan = ztd_plan_create(1, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        let kernel = TestKernel.make(gain: 0.5, delay: 1, latency: 1, settling: Int(UInt32.max))
        _ = ztd_plan_append(plan, kernel.kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, 512, false))
        let buffers = MonoBuffers(capacity: 512)
        let signal = [Float](repeating: 1, count: 512 * 8)

        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_PREROLLING, "the stage is run before it is heard")
        let output = buffers.run(plan, signal, blocks: [512])
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_PREROLLING, "and for longer than eight blocks")
        // Unheard: the unprocessed signal, a frame late as the kernel is.
        #expect(Array(output.dropFirst()) == [Float](repeating: 1, count: signal.count - 1) && kernel.state.pointee.calls == 8)
    }

    /// A caller that knows the rate states the pre-roll itself: the engine runs a stage for its
    /// latency and for its settling time up to one second (ACT-7, SWAP-2), which a plan, that
    /// counts in frames, cannot work out.
    @Test func aStatedPreRollIsTheOneTheSwitchRuns() {
        let plan = ztd_plan_create(1, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        // A slow one-pole smoother that says it settles in 2 048 frames.
        let kernel = TestKernel.make(gain: 0.5, pole: 0.995, settling: 2_048)
        _ = ztd_plan_append(plan, kernel.kernel, true)
        #expect(!ztd_plan_set_switch_preroll(plan, 0, 1_024), "no switch yet")
        #expect(ztd_plan_make_switchable(plan, 0, 512, false))
        #expect(!ztd_plan_set_switch_preroll(plan, 1, 1_024) && !ztd_plan_set_switch_preroll(nil, 0, 1_024), "no such kernel; no plan")
        #expect(ztd_plan_set_switch_preroll(plan, 0, 1_024))
        let buffers = MonoBuffers(capacity: 512)
        let signal = Click.probeSignal(count: 512 * 8)

        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_PREROLLING)
        let unheard = buffers.run(plan, Array(signal[..<1_024]), blocks: [512])
        #expect(unheard == Array(signal[..<1_024]), "nothing changes for the pre-roll that was stated")
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_IN, "1 024 frames, not the 2 048 the kernel says")
        _ = buffers.run(plan, Array(signal[1_024...]), blocks: [512])
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)

        // No pre-roll at all: switched on, the stage is faded in at once.
        setActive(plan, 0, false)
        _ = buffers.run(plan, signal, blocks: [512])
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED && ztd_plan_set_switch_preroll(plan, 0, 0))
        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_IN)
    }

    /// ACT-6, REAL-5: the kernel a group becomes states the sums of its kernels' latencies and
    /// settling times. The defect: latencies of 2³² − 1 and 1 came out as 0, a group that says
    /// it delays nothing; settling times of 2³² − 1 and 5 as 4.
    @Test func aGroupStatesSumsItCanCountOrIsNoKernel() {
        let destroyed = Destroyed()
        let late = ztd_plan_create(2, 1, 64)!
        let first = TestKernel.make(latency: Int(UInt32.max), settling: 3, destroyed: destroyed.pointer)
        let second = TestKernel.make(latency: 1, settling: 5, destroyed: destroyed.pointer)
        #expect(ztd_plan_append(late, first.kernel, true) == 0 && ztd_plan_append(late, second.kernel, true) == 1)
        #expect(ztd_plan_latency(late) == UInt32.max, "more than 32 bits count: the largest count, not what is left")
        var none = ztd_plan_as_kernel(late)
        #expect(ztd_kernel_is_null(&none), "a latency is not cut to fit: no kernel")
        // The plan stayed the caller's, with what it owns.
        #expect(destroyed.count == 0)
        ztd_plan_destroy(late)
        #expect(destroyed.count == 2)

        // A settling time is only run for: it stays at the largest count.
        let slow = ztd_plan_create(2, 1, 64)!
        let third = TestKernel.make(latency: 3, settling: Int(UInt32.max), destroyed: destroyed.pointer)
        let fourth = TestKernel.make(latency: 4, settling: 5, destroyed: destroyed.pointer)
        #expect(ztd_plan_append(slow, third.kernel, true) == 0 && ztd_plan_append(slow, fourth.kernel, true) == 1)
        var nested = ztd_plan_as_kernel(slow)
        #expect(!ztd_kernel_is_null(&nested) && nested.latency_frames == 7 && nested.settling_frames == UInt32.max)
        ztd_kernel_destroy(&nested)
        #expect(destroyed.count == 4)
    }
}
