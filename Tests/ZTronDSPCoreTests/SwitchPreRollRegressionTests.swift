import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// A gain of two behind three frames of delay, on a kernel of the caller's own that says it
/// needs two seconds to settle.
private struct SlowGain: SequenceStage {
    var activation: StageActivation = .active

    init(isActive: some ActivationSource = .active) {
        activation = isActive.stageActivation
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.custom(CustomKernel(name: "SlowGain", key: 0, latencyFrames: 3) { channels, _, _ in
            var kernel = ztd_fir_create(UInt32(channels), [0, 0, 0, 2], 4, 3, 480)
            kernel.settling_frames = 96_000
            return kernel
        }))
    }
}

/// ACT-7: a stage that is switched on "runs, with its output discarded, for its latency plus
/// its settling time, and only then is faded in". The settling time is the figure SWAP-2
/// defines: "declared by each stage, capped at one second". So a switch runs a stage unheard
/// for its latency, in full (a stage that is faded in before its latency has passed has
/// nothing to give yet), and for its settling time up to one second.
///
/// The two implementations of a switch disagreed. The switch of a kernel, in the C plan, ran
/// the kernel for its latency plus all of its settling time; a group that runs in line was run
/// for at most one second in all, its latency included.
@Suite("The pre-roll of a switch (ACT-7, SWAP-2)")
struct SwitchPreRollRegressionTests {
    /// The frames that pass, after a switch is turned on, before the stage is heard: before
    /// the output leaves the unprocessed signal, which is 1 where the stage makes 2 of it (and
    /// the node behind it in the group −2).
    private func framesUntilHeard(_ pipeline: (Binding<Bool>) -> Pipeline<Samples, Samples>) async throws -> Int {
        let rig = Rig()
        let on = StateBox(false)
        let session = try await rig.engine.attach(pipeline(on.binding), to: rig.source)
        let probe = OutputProbe()
        rig.engine.core.addProbe(probe, to: session.core)
        try session.start()
        rig.feed([Float](repeating: 1, count: 64 * 4))
        on.value = true
        await session.syncBindings()
        let before = probe.samples.count
        rig.feed([Float](repeating: 1, count: 64 * 1_600))
        let samples = probe.samples
        session.detach()
        guard let heard = samples[before...].firstIndex(where: { (sample: Float) -> Bool in abs(sample - 1) > 0.001 }) else { return -1 }
        return heard - before
    }

    @Test func aKernelAndAGroupAreRunUnheardForTheSameTime() async throws {
        let alone = try await framesUntilHeard { on in Pipeline { SlowGain(isActive: on) } }
        let grouped = try await framesUntilHeard { on in
            Pipeline { ZTronDSPCore.Group(isActive: on) { SlowGain(); TestLate(latency: 0, chunk: 64) } }
        }
        // Three frames of latency and one of the two seconds the stage asks for: 48 003 frames.
        // The switch moves on at the end of the block in which they have passed.
        #expect(alone >= 48_003 && alone < 48_003 + 128, "the switch of a kernel: heard after \(alone) frames")
        #expect(grouped >= 48_003 && grouped < 48_003 + 128, "a group that runs in line: heard after \(grouped) frames")
    }
}
