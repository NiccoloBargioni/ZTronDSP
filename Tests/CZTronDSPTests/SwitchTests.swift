import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// 10 ms at 48 kHz, and never shorter than a block of 512: the fade of ACT-7.
private let fadeFrames: UInt32 = 512

@Suite("Activation switch (WP-220)")
struct SwitchTests {
    /// A plan with one switched kernel that halves the signal.
    private func halvingPlan(active: Bool = true, block: Int = 512) -> (plan: OpaquePointer, state: UnsafeMutablePointer<TestKernelState>) {
        let plan = ztd_plan_create(1, 1, UInt32(block))!
        let kernel = TestKernel.make(gain: 0.5)
        _ = ztd_plan_append(plan, kernel.kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, active))
        return (plan, kernel.state)
    }

    /// CLICK-1: toggling under a full-scale 1 kHz sine at 48 kHz.
    @Test(arguments: [64, 512])
    func togglingUnderASineMakesNoClick(block: Int) {
        let (plan, _) = halvingPlan(block: block)
        defer { ztd_plan_destroy(plan) }
        let signal = Click.probeSignal(count: 48_000)
        // The switch moves at a block boundary where the sine is far from zero: at a zero
        // crossing an abrupt change makes no step, and the fade would have nothing to prove.
        func boundary(after frame: Int) -> Int {
            var position = (frame / block + 1) * block
            while abs(signal[position]) < 0.8 { position += block }
            return position
        }
        let offAt = boundary(after: 9_600), onAt = boundary(after: 28_800)
        #expect(abs(signal[offAt]) >= 0.8 && abs(signal[onAt]) >= 0.8)
        let output = MonoBuffers(capacity: block).run(plan, signal, blocks: [block]) { position in
            if position == offAt { setActive(plan, 0, false) }
            if position == onAt { setActive(plan, 0, true) }
        }
        let off = Click.measure(Array(output[..<onAt]), change: offAt ..< offAt + Int(fadeFrames) + block)
        #expect(off.passes, "switching off: \(off)")
        let origin = offAt + 2_048
        let on = Click.measure(Array(output[origin...]), change: (onAt - origin) ..< (onAt - origin + Int(fadeFrames) + block))
        #expect(on.passes, "switching on: \(on)")

        // And the switch does what it says: processed before, unprocessed while off, processed after.
        expectClose(Array(output[..<offAt]), signal[..<offAt].map { $0 * 0.5 }, .absolute(0))
        expectClose(Array(output[offAt + Int(fadeFrames) + block ..< onAt]), Array(signal[offAt + Int(fadeFrames) + block ..< onAt]), .absolute(0))
        expectClose(Array(output[(onAt + Int(fadeFrames) + block)...]), signal[(onAt + Int(fadeFrames) + block)...].map { $0 * 0.5 }, .absolute(0))
    }

    /// Without the fade the same toggle clicks: the test above can fail.
    @Test func anAbruptToggleWouldFailTheSameMeasurement() {
        let signal = Click.probeSignal(count: 4_800)
        var abrupt = signal.map { $0 * 0.5 }
        // Switch at a peak of the sine, where the step is largest.
        let at = 2_412
        for index in at ..< abrupt.count { abrupt[index] = signal[index] }
        #expect(!Click.measure(abrupt, change: at ..< at + 512).passes)
    }

    @Test func anInactiveKernelIsNotCalled() {
        let (plan, state) = halvingPlan()
        defer { ztd_plan_destroy(plan) }
        let buffers = MonoBuffers(capacity: 512)
        let signal = Click.probeSignal(count: 512 * 40)
        _ = buffers.run(plan, Array(signal[..<(512 * 4)]), blocks: [512])
        #expect(state.pointee.calls == 4)
        setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_OUT)
        _ = buffers.run(plan, Array(signal[..<512]), blocks: [512])
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED, "one block of 512 completes a fade of 512")
        let callsAfterFade = state.pointee.calls
        #expect(callsAfterFade == 5, "the kernel runs through its fade-out and then stops")
        _ = buffers.run(plan, Array(signal[..<(512 * 20)]), blocks: [512])
        #expect(state.pointee.calls == callsAfterFade, "twenty bypassed blocks: not one call")
    }

    @Test func aStageThatStartsInactiveStartsBypassed() {
        let (plan, state) = halvingPlan(active: false)
        defer { ztd_plan_destroy(plan) }
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED)
        let signal = TestSignal.whiteNoise(count: 2_048, seed: 220)
        #expect(MonoBuffers(capacity: 512).run(plan, signal, blocks: [512]) == signal, "no fade: it was never on")
        #expect(state.pointee.calls == 0)
    }

    @Test func restoringResetsAndPreRollsBeforeAnythingChanges() {
        // A kernel with settling time: a slow one-pole smoother, declared to settle in 2 048 frames.
        let plan = ztd_plan_create(1, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        let kernel = TestKernel.make(gain: 0.5, pole: 0.995, settling: 2_048)
        _ = ztd_plan_append(plan, kernel.kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, false))
        let buffers = MonoBuffers(capacity: 512)
        let signal = Click.probeSignal(count: 512 * 40)

        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_PREROLLING && kernel.state.pointee.resets == 1, "restored cold")
        let duringPreRoll = buffers.run(plan, Array(signal[..<2_048]), blocks: [512])
        #expect(duringPreRoll == Array(signal[..<2_048]), "before the pre-roll ends, nothing changes (ACT-7)")
        #expect(kernel.state.pointee.calls == 4, "but the kernel runs, to settle")
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_IN)
        let rest = buffers.run(plan, Array(signal[2_048...]), blocks: [512])
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)
        let whole = duringPreRoll + rest
        let measurement = Click.measure(whole, change: 2_048 ..< 2_048 + 1_024, settle: 512)
        #expect(measurement.passes, "\(measurement)")
    }

    /// The row's own case: a 2 001-tap linear-phase filter has latency (1 000 frames) and
    /// settling time (2 000) at once. Restored under signal it is pre-rolled for both, nothing
    /// changes until then, the fade-in passes CLICK-1, and what follows is the output of a
    /// kernel that never stopped.
    @Test(arguments: ["direct", "partitioned"])
    func restoringALongLinearPhaseFilterUnderSignalShowsNoTransient(kind: String) {
        // A windowed sinc whose −6 dB point is the probe's 1 kHz: processed and unprocessed
        // differ by a factor of two, so the switch has something to fade between.
        let count = 2_001, half = 1_000
        var taps = [Float](repeating: 0, count: count)
        let cutoff = 2.0 * 1_000 / 48_000
        var sum = 0.0
        var raw = [Double](repeating: 0, count: count)
        for index in 0 ..< count {
            let t = Double(index - half)
            let sinc = t == 0 ? cutoff : sin(.pi * cutoff * t) / (.pi * t)
            raw[index] = sinc * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1)))
            sum += raw[index]
        }
        for index in 0 ..< count { taps[index] = Float(raw[index] / sum) }
        func kernel() -> ztd_kernel_t {
            kind == "direct" ? ztd_fir_create(1, taps, UInt32(count), UInt32(half), 0) : ztd_partitioned_create(1, taps, UInt32(count), 512, UInt32(half))
        }
        let block = 512
        let signal = Click.probeSignal(count: block * 60)

        // The kernel that never stopped.
        let running = ztd_plan_create(1, 1, UInt32(block))!
        defer { ztd_plan_destroy(running) }
        _ = ztd_plan_append(running, kernel(), true)
        let reference = MonoBuffers(capacity: block).run(running, signal, blocks: [block])

        // The same kernel behind a switch that starts off and is turned on under signal.
        let plan = ztd_plan_create(1, 1, UInt32(block))!
        defer { ztd_plan_destroy(plan) }
        _ = ztd_plan_append(plan, kernel(), true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, false))
        let description = ztd_plan_kernel(plan, 0)
        #expect(description.latency_frames == 1_000 && description.settling_frames == 2_000, "\(kind): latency \(description.latency_frames), settling \(description.settling_frames)")
        let onAt = block * 10
        let preRoll = (Int(description.latency_frames + description.settling_frames) + block - 1) / block * block
        let output = MonoBuffers(capacity: block).run(plan, signal, blocks: [block]) { position in
            if position == onAt { setActive(plan, 0, true) }
        }
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)

        // Bypassed, and until the pre-roll has ended: the input, late by the filter's latency (ACT-7, ACT-8).
        let delayed = [Float](repeating: 0, count: half) + signal.dropLast(half)
        #expect(Array(output[..<(onAt + preRoll)]) == Array(delayed[..<(onAt + preRoll)]), "\(kind): nothing changes before the pre-roll ends")
        // The fade-in.
        let fadeEnd = onAt + preRoll + Int(fadeFrames) + block
        let measurement = Click.measure(output, change: (onAt + preRoll) ..< fadeEnd)
        #expect(measurement.passes, "\(kind): \(measurement)")
        // From then on, the kernel that never stopped. A direct filter restarts on the same
        // grid of cells and is the same to the last bit; the partitioned one is within its own
        // tolerance between two phases of its partitions.
        let tail = Array(output[fadeEnd...]), expected = Array(reference[fadeEnd...])
        if kind == "direct" {
            #expect(tail == expected, "the restored filter is the one that never stopped")
        } else {
            expectClose(tail, expected, .relativeToMaximum(1e-5), "the restored filter is the one that never stopped")
        }
        // And the two do differ before: the switch had something to do.
        let apart = zip(delayed[onAt ..< (onAt + preRoll)], reference[onAt ..< (onAt + preRoll)]).contains { abs($0 - $1) > 0.2 }
        #expect(apart, "processed and unprocessed are not the same signal")
    }

    @Test func aSwitchTurnedAroundMidFadeContinuesFromWhereItStands() {
        let (plan, state) = halvingPlan(block: 64)
        defer { ztd_plan_destroy(plan) }
        let signal = Click.probeSignal(count: 9_600)
        let output = MonoBuffers(capacity: 64).run(plan, signal, blocks: [64]) { position in
            if position == 1_920 { setActive(plan, 0, false) }
            if position == 1_920 + 192 { setActive(plan, 0, true) }     // a third of the way out
        }
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)
        #expect(state.pointee.resets == 0, "a kernel that never stopped is not reset")
        #expect(Click.measure(output, change: 1_920 ..< 1_920 + 512).passes)
        // 192 frames out, so 192 frames back: the envelope returns to one half by sample 1920 + 384.
        expectClose(Array(output[(1_920 + 384)...]), signal[(1_920 + 384)...].map { $0 * 0.5 }, .absolute(0))
        // The other direction, and the remaining transitions.
        setActive(plan, 0, false); setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_OUT)
        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE, "turned around before a single frame was faded")
        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)
    }

    @Test func switchingOffDuringPreRollBypassesAtOnce() {
        let plan = ztd_plan_create(1, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        _ = ztd_plan_append(plan, TestKernel.make(gain: 0.5, settling: 4_096).kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, false) && ztd_plan_make_switchable(plan, 0, fadeFrames, true), "asking twice is harmless")
        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_PREROLLING)
        setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED, "nothing of the stage was audible yet")
        setActive(plan, 0, false)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED)
    }

    @Test func resetLetsASwitchInTransitArrive() {
        let (plan, _) = halvingPlan()
        defer { ztd_plan_destroy(plan) }
        setActive(plan, 0, false)
        ztd_plan_reset(plan)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED)
        setActive(plan, 0, true)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_FADING_IN, "no settling time: straight to the fade")
        ztd_plan_reset(plan)
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE)
    }

    @Test func aSwitchedPlanIsAllocationFreeInEveryState() {
        let plan = ztd_plan_create(2, 1, 512)!
        defer { ztd_plan_destroy(plan) }
        _ = ztd_plan_append(plan, TestKernel.make(gain: 0.5, delay: 100, latency: 100, settling: 256).kernel, true)
        _ = ztd_plan_append(plan, TestKernel.make(gain: 2).kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, true) && ztd_plan_make_switchable(plan, 1, fadeFrames, true))
        let buffers = MonoBuffers(capacity: 512)
        expectNoAllocations {
            var block = 0
            var command = ztd_command_t()
            command.kind = UInt32(ZTD_COMMAND_SET_ACTIVE)
            while block < 1_000 {
                // A toggle every seven blocks walks both switches through every state.
                if block % 7 == 0 {
                    command.target = UInt32(block / 7 % 2)
                    command.scalar.0 = block / 14 % 2 == 0 ? 0 : 1
                    ztd_plan_command(plan, &command)
                }
                _ = ztd_plan_run(plan, buffers.inTable, buffers.outTable, 1, 512)
                block += 1
            }
        }
    }
}

@Suite("Latency-matched bypass (WP-221)")
struct LatencyMatchedBypassTests {
    private let latency = 100

    /// A plan whose one stage delays by `latency` frames and inverts: a stand-in for a
    /// linear-phase FIR, whose output arrives `latency` frames after its input.
    private func delayingPlan(active: Bool, block: Int) -> OpaquePointer {
        let plan = ztd_plan_create(1, 1, UInt32(block))!
        _ = ztd_plan_append(plan, TestKernel.make(gain: -1, delay: latency, latency: latency).kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, active))
        return plan
    }

    /// ACT-8 with a real filter: the unprocessed path of a stage with latency is a delay line
    /// that is fed while the stage is active, so that when the switch goes off under signal it
    /// already holds the last `latency` inputs. Switched off, the output is the input, late by
    /// the filter's latency, with no gap and no click.
    @Test(arguments: ["direct", "partitioned"])
    func aLinearPhaseFilterSwitchedOffUnderSignalLeavesTheDelayedInput(kind: String) {
        let count = 2_001, half = 1_000, block = 512
        var raw = [Double](repeating: 0, count: count), sum = 0.0
        let cutoff = 2.0 * 1_000 / 48_000
        for index in 0 ..< count {
            let t = Double(index - half)
            raw[index] = (t == 0 ? cutoff : sin(.pi * cutoff * t) / (.pi * t)) * (0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(count - 1)))
            sum += raw[index]
        }
        let taps = raw.map { Float($0 / sum) }
        let plan = ztd_plan_create(1, 1, UInt32(block))!
        defer { ztd_plan_destroy(plan) }
        let kernel = kind == "direct" ? ztd_fir_create(1, taps, UInt32(count), UInt32(half), 0) : ztd_partitioned_create(1, taps, UInt32(count), UInt32(block), UInt32(half))
        _ = ztd_plan_append(plan, kernel, true)
        #expect(ztd_plan_make_switchable(plan, 0, fadeFrames, true))
        let signal = Click.probeSignal(count: block * 40)
        // Off at a block boundary where the sine is far from zero.
        var offAt = block * 20
        while abs(signal[offAt]) < 0.8 { offAt += block }
        let output = MonoBuffers(capacity: block).run(plan, signal, blocks: [block]) { position in
            if position == offAt { setActive(plan, 0, false) }
        }
        #expect(ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED)
        let fadeEnd = offAt + Int(fadeFrames) + block
        let measurement = Click.measure(output, change: offAt ..< fadeEnd)
        #expect(measurement.passes, "\(kind): \(measurement)")
        // From the end of the fade on: the input, `half` frames late, to the last bit. The first
        // of those frames entered the delay line while the stage was still active.
        let delayed = [Float](repeating: 0, count: half) + signal.dropLast(half)
        #expect(Array(output[fadeEnd...]) == Array(delayed[fadeEnd...]), "\(kind): switched off, the output is the delayed input")
        #expect(fadeEnd - half < offAt + Int(fadeFrames), "what is heard right after the fade went in before the stage stopped")
    }

    @Test(arguments: [1, 33, 100, 512, 700])
    func anImpulseArrivesAtTheSameSampleBypassedAndActive(block: Int) {
        let impulse = TestSignal.impulse(count: 4_096, at: 1_000)
        for active in [true, false] {
            let plan = delayingPlan(active: active, block: block)
            defer { ztd_plan_destroy(plan) }
            let output = MonoBuffers(capacity: block).run(plan, impulse, blocks: [block])
            let arrival = output.firstIndex { $0 != 0 }
            #expect(arrival == 1_000 + latency, "active \(active), blocks of \(block)")
            #expect(output[1_000 + latency] == (active ? -1 : 1), "the processed impulse is inverted, the unprocessed one is not")
            #expect(output.filter { $0 != 0 }.count == 1)
        }
    }

    @Test(arguments: [64, 512])
    func alsoWhenTheSwitchFlipsInMidSignal(block: Int) {
        // Impulses every 1 000 samples; the stage is switched off, then on again, between them.
        var signal = [Float](repeating: 0, count: 12_000)
        for position in stride(from: 500, to: 12_000, by: 1_000) { signal[position] = 1 }
        let plan = delayingPlan(active: true, block: block)
        defer { ztd_plan_destroy(plan) }
        let offAt = 3_072, onAt = 7_168
        let output = MonoBuffers(capacity: block).run(plan, signal, blocks: [block]) { position in
            if position == offAt { setActive(plan, 0, false) }
            if position == onAt { setActive(plan, 0, true) }
        }
        let arrivals = output.indices.filter { output[$0] != 0 }
        #expect(arrivals == stride(from: 500 + latency, to: 12_000, by: 1_000).map { $0 }, "every impulse arrives \(latency) frames late, whatever the switch did")
        #expect(output[2_500 + latency] == -1, "processed before the switch")
        #expect(output[4_500 + latency] == 1, "unprocessed while it is off")
        #expect(output[9_500 + latency] == -1, "processed again after it")
    }

    @Test func theDelayLineIsFedWhileTheStageIsActive() {
        // Switch off immediately after an impulse entered: the unprocessed path must already hold it.
        let plan = delayingPlan(active: true, block: 64)
        defer { ztd_plan_destroy(plan) }
        var signal = [Float](repeating: 0, count: 2_048)
        signal[630] = 1
        let output = MonoBuffers(capacity: 64).run(plan, signal, blocks: [64]) { position in
            if position == 640 { setActive(plan, 0, false) }
        }
        let arrival = output.firstIndex { $0 != 0 }
        #expect(arrival == 630 + latency, "the last \(latency) inputs were in the line when the switch went off (ACT-8)")
        #expect(output.filter { $0 != 0 }.count == 1, "one impulse in, one impulse out: no echo from the two paths")
        // During the fade the impulse is a mix of the two paths, which agree in time.
        #expect(abs(output[630 + latency]) <= 1)
    }

    @Test func resetClearsTheDelayLine() {
        let plan = delayingPlan(active: false, block: 64)
        defer { ztd_plan_destroy(plan) }
        let buffers = MonoBuffers(capacity: 64)
        _ = buffers.run(plan, [Float](repeating: 1, count: 640), blocks: [64])
        ztd_plan_reset(plan)
        let output = buffers.run(plan, [Float](repeating: 0, count: 640), blocks: [64])
        #expect(output.allSatisfy { $0 == 0 }, "nothing of the earlier signal is left in the line")
    }
}
