import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

@Suite("Plan runner (WP-204)")
struct PlanTests {
    @Test func aPlanRunsItsKernelsInOrder() {
        let plan = ztd_plan_create(4, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        let first = TestKernel.make(gain: 2), second = TestKernel.make(gain: 1, delay: 3), third = TestKernel.make(gain: -0.5)
        #expect(ztd_plan_append(plan, first.kernel, true) == 0)
        #expect(ztd_plan_append(plan, second.kernel, true) == 1)
        #expect(ztd_plan_append(plan, third.kernel, true) == 2)
        #expect(ztd_plan_count(plan) == 3 && ztd_plan_channels(plan) == 1 && ztd_plan_maximum_frames(plan) == 512)

        let signal = TestSignal.whiteNoise(count: 2_000, seed: 204)
        let buffers = MonoBuffers(capacity: 512)
        let output = buffers.run(plan, signal, blocks: [512])
        // 2·x, delayed by three, times −0.5: −x[n − 3].
        let expected = [Float](repeating: 0, count: 3) + signal.dropLast(3).map { -$0 }
        #expect(output == expected)
        #expect(first.state.pointee.calls == 4 && second.state.pointee.calls == 4 && third.state.pointee.calls == 4, "one call per kernel per block")
    }

    @Test(arguments: [[1], [7], [64], [511, 1], [3, 500, 12]])
    func theOutputDoesNotDependOnTheBlockSizes(blocks: [Int]) {
        func run(_ blocks: [Int]) -> [Float] {
            let plan = ztd_plan_create(3, 1, 512)!
            defer { ztd_plan_destroy(plan) }
            _ = ztd_plan_append(plan, TestKernel.make(gain: 0.7, pole: 0.9).kernel, true)
            _ = ztd_plan_append(plan, TestKernel.make(gain: 1, delay: 17).kernel, true)
            _ = ztd_plan_append(plan, TestKernel.make(gain: 1.5, pole: 0.5).kernel, true)
            return MonoBuffers(capacity: 512).run(plan, TestSignal.whiteNoise(count: 3_000, seed: 2_040), blocks: blocks)
        }
        #expect(run(blocks) == run([512]))
    }

    @Test func anEmptyPlanAndAnIdentityKernelCopy() {
        let plan = ztd_plan_create(2, 1, 64)!
        defer { ztd_plan_destroy(plan) }
        let signal = TestSignal.whiteNoise(count: 64, seed: 1)
        let buffers = MonoBuffers(capacity: 64)
        #expect(buffers.run(plan, signal, blocks: [64]) == signal, "no kernels: the input, copied")
        #expect(ztd_plan_append(plan, ztd_kernel_identity(), true) == 0)
        #expect(buffers.run(plan, signal, blocks: [10]) == signal)
        #expect(ztd_plan_run(plan, buffers.inTable, buffers.outTable, 1, 0) == 0, "a block of zero frames is legal")
        var identity = ztd_kernel_identity()
        #expect(!ztd_kernel_is_null(&identity) && identity.latency_frames == 0 && identity.state == nil)
        ztd_kernel_destroy(&identity)
        #expect(ztd_kernel_is_null(&identity) && ztd_kernel_is_null(nil))
        #expect(ztd_abi_version() == 1)
    }

    @Test func aRateChangeInsideAPlanCarriesItsFrameCountOn() {
        let plan = ztd_plan_create(3, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        let after = TestKernel.make(gain: 3)
        _ = ztd_plan_append(plan, TestKernel.make(gain: 2).kernel, true)
        _ = ztd_plan_append(plan, TestKernel.makeHalving().kernel, true)
        _ = ztd_plan_append(plan, after.kernel, true)
        let signal = (0 ..< 1_001).map(Float.init)
        let output = MonoBuffers(capacity: 512).run(plan, signal, blocks: [7, 64, 1, 300])
        #expect(output == stride(from: 0, to: 1_001, by: 2).map { Float($0) * 6 }, "every second frame, whatever the block sizes")
        #expect(after.state.pointee.framesSeen == 501, "the kernel after the rate change sees half the frames")
    }

    @Test func runningARangeSplitsThePlanWithoutChangingTheResult() {
        func make() -> OpaquePointer {
            let plan = ztd_plan_create(4, 1, 256)!
            for gain in [Float(0.5), 2, -1, 0.25] { _ = ztd_plan_append(plan, TestKernel.make(gain: gain, pole: 0.6).kernel, true) }
            return plan
        }
        let whole = make(), split = make()
        defer { ztd_plan_destroy(whole); ztd_plan_destroy(split) }
        let signal = TestSignal.whiteNoise(count: 256, seed: 9)
        let buffers = MonoBuffers(capacity: 256), middle = MonoBuffers(capacity: 256)
        let reference = buffers.run(whole, signal, blocks: [256])
        signal.withUnsafeBufferPointer { buffers.input.update(from: $0.baseAddress!, count: 256) }
        #expect(ztd_plan_run_range(split, 0, 2, buffers.inTable, middle.outTable, 1, 256) == 256)
        middle.input.update(from: middle.output, count: 256)
        #expect(ztd_plan_run_range(split, 2, 99, middle.inTable, buffers.outTable, 1, 256) == 256, "an end past the last kernel is clamped")
        #expect(Array(UnsafeBufferPointer(start: buffers.output, count: 256)) == reference)
        #expect(ztd_plan_run_range(split, 3, 3, buffers.inTable, middle.outTable, 1, 16) == 16, "an empty range copies")
        #expect(Array(UnsafeBufferPointer(start: middle.output, count: 16)) == Array(signal.prefix(16)))
    }

    @Test func commandsReachTheKernelTheyAreFor() {
        let plan = ztd_plan_create(2, 1, 64)!
        defer { ztd_plan_destroy(plan) }
        let first = TestKernel.make(gain: 1), second = TestKernel.make(gain: 1)
        _ = ztd_plan_append(plan, first.kernel, true)
        _ = ztd_plan_append(plan, second.kernel, true)
        var command = ztd_command_t()
        command.target = 1
        command.kind = UInt32(ZTD_COMMAND_SET_VALUES)
        command.scalar.0 = 0.25
        ztd_plan_command(plan, &command)
        #expect(first.state.pointee.commands == 0 && second.state.pointee.commands == 1 && second.state.pointee.gain == 0.25)
        command.target = 9
        ztd_plan_command(plan, &command)
        #expect(second.state.pointee.commands == 1, "a command for a stage that does not exist is ignored")
        command.target = 0
        command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
        ztd_plan_command(plan, &command)
        #expect(first.state.pointee.commands == 0, "a switch command never reaches a kernel")
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE, "and a stage without a switch stays active")
    }

    @Test func resetIsAColdStart() {
        let plan = ztd_plan_create(2, 1, 64)!
        defer { ztd_plan_destroy(plan) }
        let kernel = TestKernel.make(gain: 1, pole: 0.9, delay: 5)
        _ = ztd_plan_append(plan, kernel.kernel, true)
        let signal = TestSignal.whiteNoise(count: 640, seed: 3)
        let buffers = MonoBuffers(capacity: 64)
        let first = buffers.run(plan, signal, blocks: [64])
        ztd_plan_reset(plan)
        #expect(kernel.state.pointee.resets == 1)
        #expect(buffers.run(plan, signal, blocks: [64]) == first, "after a reset the plan starts as it did at creation")
    }

    @Test func aPlanReportsItsKernelsAndItsLatency() {
        let plan = ztd_plan_create(2, 2, 64)!
        defer { ztd_plan_destroy(plan) }
        _ = ztd_plan_append(plan, TestKernel.make(latency: 10, settling: 4).kernel, true)
        _ = ztd_plan_append(plan, TestKernel.make(latency: 7).kernel, true)
        #expect(ztd_plan_latency(plan) == 17 && ztd_plan_channels(plan) == 2)
        var kernel = ztd_plan_kernel(plan, 0)
        #expect(kernel.latency_frames == 10 && kernel.settling_frames == 4 && !ztd_kernel_is_null(&kernel))
        var missing = ztd_plan_kernel(plan, 5)
        #expect(ztd_kernel_is_null(&missing))
        #expect(ztd_plan_append(plan, TestKernel.make().kernel, false) == UInt32.max, "a full plan refuses")
    }

    @Test func creationRefusesWhatCannotRun() {
        #expect(ztd_plan_create(4, 0, 64) == nil, "no channels, no plan")
        let plan = ztd_plan_create(1, 1, 0)!
        defer { ztd_plan_destroy(plan) }
        #expect(ztd_plan_maximum_frames(plan) == 1)
        var null = ztd_kernel_t()
        #expect(ztd_kernel_is_null(&null))
        #expect(ztd_plan_append(plan, null, true) == UInt32.max, "a kernel whose creation failed is not appended")
        #expect(!ztd_plan_make_switchable(plan, 3, 480, true))
        ztd_plan_destroy(nil)
    }

    @Test func ownedKernelsAreDestroyedWithThePlanAndBorrowedOnesAreNot() {
        // The counter is heap storage: the kernels keep its address after `make` returns.
        let destroyed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        destroyed.initialize(to: 0)
        defer { destroyed.deallocate() }
        let borrowed = TestKernel.make(destroyed: destroyed)
        do {
            let plan = ztd_plan_create(3, 1, 64)!
            _ = ztd_plan_append(plan, TestKernel.make(destroyed: destroyed).kernel, true)
            _ = ztd_plan_append(plan, TestKernel.make(destroyed: destroyed).kernel, true)
            _ = ztd_plan_append(plan, borrowed.kernel, false)
            ztd_plan_destroy(plan)
        }
        #expect(destroyed.pointee == 2)
        var kernel = borrowed.kernel
        ztd_kernel_destroy(&kernel)
        #expect(destroyed.pointee == 3)
    }

    /// WP-204 acceptance: a plan of no-op kernels, dispatch cost recorded, allocation-free.
    @Test func dispatchCostOfNoOpKernelsIsRecordedAndAllocationFree() {
        let kernels = 16
        let plan = ztd_plan_create(UInt32(kernels), 1, 1)!
        defer { ztd_plan_destroy(plan) }
        for _ in 0 ..< kernels { _ = ztd_plan_append(plan, ztd_kernel_identity(), true) }
        let buffers = MonoBuffers(capacity: 1)
        expectNoAllocations {
            var block = 0
            while block < 1_000 {
                _ = ztd_plan_run(plan, buffers.inTable, buffers.outTable, 1, 1)
                block += 1
            }
        }
        let result = Benchmark.measure("plan.dispatch.16-identity-kernels.1-frame", warmUp: 3, samples: 15, iterations: 2_000) {
            _ = ztd_plan_run(plan, buffers.inTable, buffers.outTable, 1, 1)
        }
        Benchmark.record([result])
        let perKernel = result.minimum / Double(kernels)
        #expect(perKernel > 0)
        // The budget is 25 ns per kernel per block (§5.7). It is held in a benchmark run: an
        // optimised build, one test at a time, which is the only run whose timings mean anything.
        #if !DEBUG
        if Benchmark.isRecording {
            #expect(perKernel <= 25, "dispatch cost \(perKernel) ns per kernel per block")
        }
        #endif
    }
}

@Suite("Kernel transfer and pre-roll (WP-224, WP-225)")
struct PlanTransitionTests {
    /// SWAP-1: a kernel moved into a new plan continues bit-identically, and is destroyed once.
    @Test func aMovedKernelContinuesBitIdenticallyAndIsDestroyedExactlyOnce() {
        let destroyed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        destroyed.initialize(to: 0)
        defer { destroyed.deallocate() }
        let signal = TestSignal.whiteNoise(count: 4_096, seed: 224)
        let buffers = MonoBuffers(capacity: 512)

        // The reference: one plan runs the whole signal.
        let whole = ztd_plan_create(2, 1, 512)!
        _ = ztd_plan_append(whole, TestKernel.make(gain: 0.8, pole: 0.95, delay: 9).kernel, true)
        let reference = buffers.run(whole, signal, blocks: [512])
        ztd_plan_destroy(whole)

        // The exchange: the old plan runs the first half, the kernel moves, the new plan the rest.
        let old = ztd_plan_create(2, 1, 512)!
        _ = ztd_plan_append(old, TestKernel.make(gain: 0.8, pole: 0.95, delay: 9, destroyed: destroyed).kernel, true)
        let new = ztd_plan_create(2, 1, 512)!
        _ = ztd_plan_append(new, TestKernel.make(gain: 0.8, pole: 0.95, delay: 9, destroyed: destroyed).kernel, true)   // a cold placeholder
        _ = ztd_plan_append(new, TestKernel.make(gain: 1, destroyed: destroyed).kernel, true)                          // a new stage downstream

        let firstHalf = buffers.run(old, Array(signal[..<2_048]), blocks: [512])
        #expect(ztd_plan_transfer(old, 0, new, 0))
        #expect(destroyed.pointee == 1, "the placeholder the moved kernel replaced is destroyed")
        let secondHalf = buffers.run(new, Array(signal[2_048...]), blocks: [512])
        #expect(firstHalf + secondHalf == reference, "state moved with the kernel: no reset, no gap")

        ztd_plan_destroy(old)
        #expect(destroyed.pointee == 1, "the old plan no longer owns the kernel it gave away")
        ztd_plan_destroy(new)
        #expect(destroyed.pointee == 3, "the moved kernel and the new stage, each once")
    }

    @Test func aTransferOutOfRangeIsRefused() {
        let a = ztd_plan_create(1, 1, 8)!, b = ztd_plan_create(1, 1, 8)!
        defer { ztd_plan_destroy(a); ztd_plan_destroy(b) }
        _ = ztd_plan_append(a, ztd_kernel_identity(), true)
        #expect(!ztd_plan_transfer(a, 0, b, 0), "the target has no kernel at that index")
        #expect(!ztd_plan_transfer(a, 5, b, 0) && !ztd_plan_transfer(nil, 0, b, 0) && !ztd_plan_transfer(a, 0, nil, 0))
    }

    /// WP-225: after pre-roll a kernel's state equals that of one that ran live.
    @Test func afterPreRollAKernelIsInTheStateOfOneThatRanLive() {
        let signal = TestSignal.whiteNoise(count: 6_000, seed: 225)
        let buffers = MonoBuffers(capacity: 512)
        func make() -> OpaquePointer {
            let plan = ztd_plan_create(3, 1, 512)!
            _ = ztd_plan_append(plan, TestKernel.make(gain: 1.1).kernel, true)
            _ = ztd_plan_append(plan, TestKernel.make(gain: 0.9, pole: 0.97, delay: 21).kernel, true)
            _ = ztd_plan_append(plan, TestKernel.make(gain: 1, pole: 0.5).kernel, true)
            return plan
        }
        let live = make(), rolled = make()
        defer { ztd_plan_destroy(live); ztd_plan_destroy(rolled) }

        // Live: the whole signal. Pre-rolled: kernels 1 and 2 hear the first part with their output
        // discarded (kernel 0 is fed by hand, as the shared prefix of a transition would feed them).
        let reference = buffers.run(live, signal, blocks: [512])
        var position = 0
        while position < 3_072 {
            signal.withUnsafeBufferPointer { buffers.input.update(from: $0.baseAddress! + position, count: 512) }
            #expect(ztd_plan_run_range(rolled, 0, 1, buffers.inTable, buffers.outTable, 1, 512) == 512)
            buffers.input.update(from: buffers.output, count: 512)
            buffers.output.update(repeating: -99, count: 512)
            ztd_plan_preroll(rolled, 1, buffers.inTable, 1, 512)
            #expect(buffers.output[0] == -99 && buffers.output[511] == -99, "pre-roll writes nothing the caller sees")
            position += 512
        }
        let tail = buffers.run(rolled, Array(signal[3_072...]), blocks: [512])
        #expect(tail == Array(reference[3_072...]), "from the exchange on, the pre-rolled plan is bit-identical to the live one")
    }

    @Test func preRollIsAllocationFree() {
        let plan = ztd_plan_create(3, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        for _ in 0 ..< 3 { _ = ztd_plan_append(plan, TestKernel.make(gain: 0.5, pole: 0.9).kernel, true) }
        let buffers = MonoBuffers(capacity: 512)
        expectNoAllocations {
            var block = 0
            while block < 1_000 {
                ztd_plan_preroll(plan, 1, buffers.inTable, 1, 512)
                _ = ztd_plan_run_range(plan, 0, 1, buffers.inTable, buffers.outTable, 1, 512)
                block += 1
            }
        }
    }
}
