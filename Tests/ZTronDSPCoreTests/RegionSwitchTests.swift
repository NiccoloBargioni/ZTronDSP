import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A bound switch on stages that are not one kernel: a node on samples with latency and a
/// block rhythm of its own (ACT-3, ACT-7, ACT-8, ACT-10; the mechanism WP-532 builds on).
@Suite("Switched regions")
struct RegionSwitchTests {
    let sine = Click.probeSignal(count: 64 * 240)
    let latency = 100

    private func delayed(_ signal: [Float], inverted: Bool) -> [Float] {
        ([Float](repeating: 0, count: latency) + signal).prefix(signal.count).map { inverted ? -$0 : $0 }
    }

    @Test func aSwitchedNodeKeepsTheSignalAlignedAndMakesNoClick() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let probe = TestProbe()
        let session = try await rig.engine.attach(
            Pipeline().appending(TestLate(latency: latency, chunk: 96, settling: 50, probe: probe, isActive: on.binding)), to: rig.source)
        let output = OutputProbe()
        rig.engine.core.addProbe(output, to: session.core)
        try session.start()
        #expect(session.environment.latency == Double(latency) / 48_000)
        let processed = delayed(sine, inverted: true), dry = delayed(sine, inverted: false)

        // Active: the node's output, in the node's own blocks.
        rig.feed(Array(sine[..<(64 * 60)]))
        #expect(output.samples.count == 3_840 && output.samples == Array(processed[..<3_840]))
        let workBefore = probe.framesFramed

        // Off: a fade of 10 ms to the delayed input, then the node stops running.
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 60) ..< (64 * 120)]))
        #expect(output.samples.count == 7_680, "every sample of the input has come out once")
        #expect(Array(output.samples[4_800 ..< 7_680]) == Array(dry[4_800 ..< 7_680]), "bypassed, the signal passes delayed by the stage's latency (ACT-8)")
        let fading = (3_840 ..< 4_800).filter { output.samples[$0] != processed[$0] && output.samples[$0] != dry[$0] }.count
        #expect(fading >= 470 && fading <= 480, "a cross-fade of 10 ms: \(fading) frames between the two signals")
        let workWhileOff = probe.framesFramed
        rig.feed(Array(sine[(64 * 120) ..< (64 * 130)]))
        #expect(probe.framesFramed == workWhileOff && workWhileOff < workBefore + 20, "an inactive stage does no work (ACT-3)")
        #expect(output.samples.count == 8_320 && Array(output.samples[7_680...]) == Array(dry[7_680 ..< 8_320]))

        // On: reset, pre-rolled for latency plus settling with the delayed input still passing, then faded in.
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 130) ..< (64 * 133)]))
        #expect(Array(output.samples[8_320...]) == Array(dry[8_320 ..< 8_512]), "restoring takes effect after the pre-roll; before it, nothing changes (ACT-7)")
        #expect(probe.framerResets == 2, "the stage starts cold")
        rig.feed(Array(sine[(64 * 133)...]))
        let total = output.samples.count
        #expect(total >= sine.count - 96 && total <= sine.count, "nothing was lost or repeated: \(total) of \(sine.count)")
        #expect(Array(output.samples[9_600 ..< total]) == Array(processed[9_600 ..< total]), "active again, the output is the stage's")
        #expect(session.environment.latency == Double(latency) / 48_000, "switching never changes the latency")

        let off = Click.measure(output.samples, change: 3_840 ..< 4_900, settle: 96)
        let back = Click.measure(output.samples, change: 8_320 ..< 9_600, settle: 96)
        #expect(off.passes && back.passes, "CLICK-1 off: \(off); on: \(back)")
        #expect(session.core.generation == 1, "nothing was compiled")
    }

    @Test func aSwitchThatTurnsRoundInTheMiddleOfAFade() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let session = try await rig.engine.attach(
            Pipeline().appending(TestLate(latency: latency, chunk: 64, isActive: on.binding)), to: rig.source)
        let output = OutputProbe()
        rig.engine.core.addProbe(output, to: session.core)
        try session.start()
        rig.feed(Array(sine[..<1_920]))
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[1_920 ..< 2_112]))          // 192 frames into the fade-out
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[2_112 ..< 4_800]))
        let processed = delayed(sine, inverted: true)
        #expect(output.samples.count == 4_800)
        #expect(Array(output.samples[2_400...]) == Array(processed[2_400 ..< 4_800]), "the fade turned round where it stood; the stage never stopped")
        #expect(Click.measure(output.samples, change: 1_920 ..< 2_400, settle: 64).passes)
        // Off during pre-roll: the stage goes back to bypass without having been heard.
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[4_800 ..< 6_400]))
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[6_400 ..< 6_464]))
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[6_464 ..< 8_000]))
        let dry = delayed(sine, inverted: false)
        #expect(Array(output.samples[6_000 ..< 8_000]) == Array(dry[6_000 ..< 8_000]))
    }

    @Test func aStageThatStartsBypassedAndAGroupOfAKernelAndANode() async throws {
        let rig = Rig()
        let on = StateBox(false)
        let session = try await rig.engine.attach(
            Pipeline { ZTronDSPCore.Group(isActive: on.binding) { TestGain(0.5); TestLate(latency: latency, chunk: 48) } }, to: rig.source)
        let output = OutputProbe()
        rig.engine.core.addProbe(output, to: session.core)
        try session.start()
        let dry = delayed(sine, inverted: false)
        rig.feed(Array(sine[..<1_920]))
        #expect(output.samples == Array(dry[..<1_920]), "a group whose binding is false starts bypassed, at the group's latency")
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[1_920 ..< 5_760]))
        #expect(Array(output.samples[3_000 ..< 5_760]) == dry[3_000 ..< 5_760].map { $0 * -0.5 }, "kernel and node are switched as one")
        #expect(Click.measure(output.samples, change: 1_920 ..< 2_700, settle: 64).passes)
    }

    @Test func theSwitchAllocatesNothing() async throws {
        let rig = Rig()
        let on = StateBox(true)
        let session = try await rig.engine.attach(
            Pipeline().appending(TestLate(latency: latency, chunk: 96, settling: 200, isActive: on.binding)), to: rig.source)
        try session.start()
        await rig.drain()
        let runner = try #require(rig.engine.core.rootRunners().first)
        let block = try AudioBuffer(channels: [Array(sine[..<64])])
        for round in 0 ..< 6 {
            on.value = round % 2 == 1
            await session.syncBindings()
            expectNoAllocations("round \(round)") {
                var count = 0
                while count < 200 {
                    rig.source.write(block.block())
                    _ = runner.turn(now: 0)
                    count += 1
                }
            }
        }
    }
}
