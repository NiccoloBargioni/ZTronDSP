import CExternalKernels
import ExternalStages
import ExternalTestSupport
import Foundation
import SwiftUI
import Testing
import ZTronDSP
import ZTronDSPTesting

/// EXT-4: each of the three stages is switched through a SwiftUI `Binding`, while it runs,
/// with no code of its own (§5.9, EXT-2).
///
/// The engine is a real one with its analysis thread. The source is fed by hand: when the test
/// moves a switch, the engine has processed everything it was given, so the change lands at
/// the first block it is given next. That makes a run reproducible to the sample, and the
/// external stage is compared with its stock twin under the same moves, bit for bit.
@Suite("Bound switches")
struct BoundSwitchTests {
    static let block = 64
    /// 10 ms at 48 kHz, and never shorter than one block (ACT-7).
    static let fade = 480
    /// The switch goes off after 20 blocks and on again after 40.
    static let off = 20 * block, on = 40 * block, total = 120 * block
    let probe = Click.probeSignal(count: BoundSwitchTests.total)
    let noise = TestSignal.whiteNoise(count: BoundSwitchTests.total, seed: 59, amplitude: 0.8)

    /// Runs the pipeline `make` builds around a bound switch: on, off at `off`, on again at `on`.
    private func switched(_ signal: [Float], _ make: (Binding<Bool>) -> Pipeline<Samples, Samples>) async throws -> (output: [Float], switchWrites: Int) {
        let box = StateBox(true)
        let run = try await HandFedRun(make(box.binding), blockSize: BoundSwitchTests.block)
        try #require(await run.feed(Array(signal[..<BoundSwitchTests.off])))
        await run.set(box, to: false)
        try #require(await run.feed(Array(signal[BoundSwitchTests.off ..< BoundSwitchTests.on])))
        await run.set(box, to: true)
        try #require(await run.feed(Array(signal[BoundSwitchTests.on...])))
        try #require(await run.finish())
        return (run.output.samples, box.writes)
    }

    /// The weight of the unprocessed signal in `output[index]`, where the two signals differ enough to tell.
    private func dryWeight(_ output: [Float], _ wet: [Float], _ dry: [Float], at index: Int) -> Double? {
        let span = Double(dry[index]) - Double(wet[index])
        guard abs(span) > 0.05 else { return nil }
        return (Double(output[index]) - Double(wet[index])) / span
    }

    @Test func theGainIsBypassedAndRestoredLikeTheStockGain() async throws {
        let external = try await switched(probe) { binding in Pipeline { ExternalGain(.linear(0.5), isActive: binding) } }
        let stock = try await switched(probe) { binding in Pipeline { Gain(.linear(0.5), isActive: binding) } }
        #expect(external.output == stock.output, "\(deviation(external.output, from: stock.output)) of the peak apart")
        #expect(external.switchWrites == 0, "the session reads a switch and never writes it (BIND-5)")

        let output = external.output, wet = probe.map { $0 * 0.5 }
        let off = BoundSwitchTests.off, on = BoundSwitchTests.on, fade = BoundSwitchTests.fade
        try #require(output.count == probe.count)
        // On: the stage runs. Off: a cross-fade of 10 ms to the unprocessed signal, which then passes unchanged (ACT-3, ACT-7).
        #expect(Array(output[..<off]) == Array(wet[..<off]))
        #expect(Array(output[(off + fade) ..< on]) == Array(probe[(off + fade) ..< on]), "bypassed, the signal passes bit for bit")
        var index = off
        while index < off + fade {
            if let weight = dryWeight(output, wet, probe, at: index) {
                let expected = Double(index - off + 1) / Double(fade)
                #expect(abs(weight - expected) < 1.0e-4, "frame \(index - off) of the fade: weight \(weight)")
            }
            index += 37
        }
        // On again: a gain has nothing to settle, so it is faded in at once; then it runs as before.
        #expect(Array(output[(on + fade)...]) == Array(wet[(on + fade)...]))
        index = on
        while index < on + fade {
            if let weight = dryWeight(output, wet, probe, at: index) {
                #expect(abs(weight - (1 - Double(index - on + 1) / Double(fade))) < 1.0e-4, "frame \(index - on) of the fade back")
            }
            index += 37
        }
        // CLICK-1: no step during either change exceeds 1.5 times the largest step in steady state.
        let down = Click.measure(Array(output[..<on]), change: off ..< (off + fade + BoundSwitchTests.block))
        let up = Click.measure(Array(output[(off + fade)...]), change: (on - off - fade) ..< (on - off + BoundSwitchTests.block))
        #expect(down.passes && up.passes, "\(down); \(up)")
    }

    @Test func theLowPassIsBypassedPrerolledAndRestoredLikeTheStockFilter() async throws {
        let stage = { (binding: Binding<Bool>) in Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: binding) } }
        let twin = { (binding: Binding<Bool>) in Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4, isActive: binding) } }
        for signal in [probe, noise] {
            let external = try await switched(signal, stage)
            let stock = try await switched(signal, twin)
            #expect(external.output == stock.output, "\(deviation(external.output, from: stock.output)) of the peak apart")
            #expect(external.switchWrites == 0)
        }

        let output = try await switched(probe, stage).output
        let always = try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }.process(probe, format: mono48, blockSize: BoundSwitchTests.block)
        let off = BoundSwitchTests.off, on = BoundSwitchTests.on, fade = BoundSwitchTests.fade, block = BoundSwitchTests.block
        #expect(Array(output[..<off]) == Array(always[..<off]))
        #expect(Array(output[(off + fade) ..< on]) == Array(probe[(off + fade) ..< on]), "bypassed, the signal passes bit for bit")

        // Restored, the filter starts cold and is pre-rolled for its settling time, in whole blocks,
        // with its output discarded: until then nothing changes (ACT-7).
        let settling = try Int(extkSettling(cutoff: 1_000, order: 4))
        let preroll = (settling + block - 1) / block * block
        #expect(settling > block, "the filter of this test settles over more than one block: \(settling) frames")
        #expect(Array(output[on ..< (on + preroll)]) == Array(probe[on ..< (on + preroll)]), "pre-rolled for \(preroll) frames, the unprocessed signal passes")
        #expect(output[on + preroll + fade / 2] != probe[on + preroll + fade / 2], "then it is faded in")
        // After the fade the output is the filter's, as if it had always run, to the 100 dB it settled by.
        let settled = on + preroll + fade
        expectClose(Array(output[settled...]), Array(always[settled...]), .absolute(2.0e-5))
        let up = Click.measure(Array(output[(off + fade)...]), change: (on - off - fade) ..< (settled - off - fade + block), settle: 0)
        let down = Click.measure(Array(output[..<on]), change: off ..< (off + fade + block))
        #expect(down.passes && up.passes, "\(down); \(up)")
    }

    /// The settling time the kernel of a Butterworth low-pass declares.
    private func extkSettling(cutoff: Double, order: Int) throws -> UInt32 {
        let coefficients = try BiquadKernelTests.coefficients(cutoff: cutoff, order: order)
        return extk_biquad_settling(coefficients, UInt32(coefficients.count / 5))
    }

    @Test func aGroupOfTheTwoIsSwitchedAsOne() async throws {
        // ACT-6: several stages under one switch.
        let external = try await switched(noise) { binding in
            Pipeline { ZTronDSP.Group(isActive: binding) { ExternalGain(.decibels(-6)); ExternalLowPass(.butterworth, cutoff: .hertz(2_000), order: 2) } }
        }
        let stock = try await switched(noise) { binding in
            Pipeline { ZTronDSP.Group(isActive: binding) { Gain(.decibels(-6)); LowPass(.butterworth, cutoff: .hertz(2_000), order: 2) } }
        }
        #expect(external.output == stock.output, "\(deviation(external.output, from: stock.output)) of the peak apart")
        let off = BoundSwitchTests.off, on = BoundSwitchTests.on, fade = BoundSwitchTests.fade
        #expect(Array(external.output[(off + fade) ..< on]) == Array(noise[(off + fade) ..< on]))
        #expect(external.output[off - 1] != noise[off - 1] && external.output[BoundSwitchTests.total - 1] != noise[BoundSwitchTests.total - 1])
    }

    @Test func theMelStepSuspendsItsBranchAndResumesItLikeTheStockStep() async throws {
        // ACT-3: a step that changes the domain cannot be bypassed. Off, the rest of its branch is
        // suspended and its sinks receive nothing; on again, the frames reappear.
        typealias Mel = Spectrum<MelFrequency, PowerValues>
        func run(external: Bool) async throws -> (frames: [[Float]], times: [Double], indices: [Int], whileOff: Int, main: [Float]) {
            let box = StateBox(true)
            let sink = CollectingSink<Mel>()
            let pipeline = Pipeline().tap { (branch: Pipeline<Samples, Samples>) -> Pipeline<Samples, Mel> in
                let spectrum = branch.stft(frame: 256, hop: 64).power()
                return external
                    ? spectrum.externalMelScale(bands: 20, isActive: box.binding).emit(to: sink)
                    : spectrum.melScale(bands: 20, isActive: box.binding).emit(to: sink)
            }
            let session = try await HandFedRun(pipeline, blockSize: BoundSwitchTests.block)
            let fedOn = await session.feed(Array(noise[..<BoundSwitchTests.off]))
            let before = sink.frameCount
            await session.set(box, to: false)
            let fedOff = await session.feed(Array(noise[BoundSwitchTests.off ..< BoundSwitchTests.on]))
            let during = sink.frameCount
            await session.set(box, to: true)
            let fedAgain = await session.feed(Array(noise[BoundSwitchTests.on ..< (BoundSwitchTests.on + 20 * BoundSwitchTests.block)]))
            let finished = await session.finish()
            try #require(fedOn && fedOff && fedAgain && finished, "the engine did not take what it was fed")
            #expect(before == (BoundSwitchTests.off - 256) / 64 + 1, "one frame per hop once the first frame is full: \(before)")
            #expect(box.writes == 0)
            return (sink.frames, sink.times, sink.indices, during - before, session.output.samples)
        }
        let external = try await run(external: true), stock = try await run(external: false)
        #expect(external.whileOff == 0, "a suspended branch delivers nothing: \(external.whileOff) frames arrived")
        #expect(external.frames == stock.frames && external.times == stock.times && external.indices == stock.indices)
        #expect(external.frames.count > (BoundSwitchTests.off - 256) / 64 + 1, "the frames reappear when the switch goes on again")
        #expect(external.main == Array(noise[..<(BoundSwitchTests.on + 20 * BoundSwitchTests.block)]), "the main line never notices the branch")

        // What reappears is what a branch that never stopped delivers at the same times: the node has no memory.
        let always: [[Float]] = try Pipeline { STFT(frame: 256, hop: 64); Power(); ExternalMelScale(bands: 20) }
            .process(Array(noise[..<(BoundSwitchTests.on + 20 * BoundSwitchTests.block)]), format: mono48, blockSize: BoundSwitchTests.block)
        let resumed = Array(external.frames.suffix(20))
        #expect(resumed == Array(always.suffix(20)))
    }

    @Test func aConstantSwitchIsCompiledAway() throws {
        // ACT-4: `.bypassed` removes a stage that keeps the domain, and the rest of the branch behind one that changes it.
        typealias Mel = Spectrum<MelFrequency, PowerValues>
        let sink = CollectingSink<Mel>(), live = CollectingSink<Mel>()
        let output = try Pipeline()
            .tap { $0.stft(frame: 256, hop: 64).power().externalMelScale(bands: 20, isActive: .bypassed).emit(to: sink) }
            .tap { $0.stft(frame: 256, hop: 64).power().externalMelScale(bands: 20, isActive: true).emit(to: live) }
            .externalGain(.decibels(-6), isActive: false)
            .externalLowPass(.butterworth, cutoff: .hertz(500), order: 2, isActive: .bypassed)
            .process(noise, format: mono48)
        #expect(output == noise)
        #expect(sink.frameCount == 0 && live.frameCount == (noise.count - 256) / 64 + 1)
    }

    @MainActor
    @Test func offlineABoundSwitchIsReadOnceOnTheMainActor() throws {
        // CR-015, item 12: `process` called on the main thread reads the bound switches at the start.
        let box = StateBox(false)
        let pipeline = Pipeline { ExternalGain(.linear(0.25), isActive: box.binding); ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 2) }
        let filtered = try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 2) }.process(noise, format: mono48)
        #expect(try pipeline.process(noise, format: mono48) == filtered, "the gain is off: only the filter runs")
        box.value = true
        #expect(try pipeline.process(noise, format: mono48) == (try Pipeline { ExternalGain(.linear(0.25)); ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 2) }.process(noise, format: mono48)))
        #expect(box.writes == 0)
        // ACT-12: a bound activation differs from every constant, and all bound activations compare equal.
        let other = StateBox(true)
        #expect(Pipeline { ExternalGain(.linear(0.25), isActive: box.binding) } == Pipeline { ExternalGain(.linear(0.25), isActive: other.binding) })
        #expect(Pipeline { ExternalGain(.linear(0.25), isActive: box.binding) } != Pipeline { ExternalGain(.linear(0.25)) })
    }
}
