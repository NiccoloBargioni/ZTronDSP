import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPAnalysis
@testable import ZTronDSPCore
import ZTronDSPTesting

/// HPSS resynthesis and the `HPSS(select:)` recipe, with its bound bypass (WP-532).
@Suite("HPSS recipe")
struct HPSSTests {
    private func fixture(_ name: String) throws -> (samples: [Float], format: SignalFormat) {
        let golden = try GoldenFile(named: "fixtures", in: .module).require(name)
        return (try golden.floats("samples"), SignalFormat(sampleRate: try golden.number("sampleRate")))
    }

    /// `10·log₁₀(Σ reference² / Σ (signal − reference)²)` over `range` of the reference, the
    /// signal read `delay` samples later.
    private func signalToNoise(_ signal: [Float], against reference: [Float], delayedBy delay: Int, over range: Range<Int>) -> Double {
        var power = 0.0, noise = 0.0
        for index in range {
            let wanted = Double(reference[index]), got = Double(signal[index + delay])
            power += wanted * wanted
            noise += (got - wanted) * (got - wanted)
        }
        return noise > 0 ? 10 * log10(power / noise) : .infinity
    }

    // MARK: The components reconstruct the input, SNR ≥ 100 dB (WP-532, §6.10)

    @Test(arguments: ["speech", "music"])
    func theComponentsReconstructTheInput(name: String) throws {
        let (samples, format) = try fixture(name)
        let cases: [(String, any MaskStrategy, Double, Double, FrameAlignment, Int)] = [
            ("soft, causal", SoftMask(power: 2), 1, 1, .causal, 31), ("soft with margins, centred", SoftMask(power: 2), 2, 3, .centered, 17),
            ("hard, centred", HardMask(), 1, 1, .centered, 31), ("hard with margins, causal", HardMask(), 2, 2, .causal, 17),
        ]
        for (label, mask, harmonicMargin, percussiveMargin, alignment, kernel) in cases {
            func component<M: MaskStrategy>(_ component: HarmonicPercussiveComponent, _ mask: M) throws -> [Float] {
                try Pipeline {
                    HPSS(select: component, frame: 1_024, hop: 256, timeKernel: kernel, frequencyKernel: kernel, mask: mask, harmonicMargin: harmonicMargin,
                         percussiveMargin: percussiveMargin, alignment: alignment)
                }.process(samples, format: format, blockSize: 441)
            }
            let harmonic = try component(.harmonic, mask), percussive = try component(.percussive, mask), residual = try component(.residual, mask)
            #expect(harmonic.count == percussive.count && harmonic.count == residual.count)
            let sum = zip(zip(harmonic, percussive), residual).map { $0.0 + $0.1 + $1 }
            // The recipe delays the signal by its latency: one frame less a hop, plus the look-ahead.
            let ahead = alignment == .centered ? (kernel - 1) / 2 : 0
            let latency = 1_024 - 256 + ahead * 256
            #expect(sum[..<latency].allSatisfy { $0 == 0 }, "\(label): the output begins with the latency as zeros")
            // Causal, the signal is there from its first sample. Centred, the component fades in
            // behind the silence the median begins with: its first frame is left out.
            let range = (alignment == .centered ? 1_024 : 0) ..< sum.count - latency
            let ratio = signalToNoise(sum, against: samples, delayedBy: latency, over: range)
            print("measured WP-532: \(name), \(label): harmonic + percussive + residual against the input delayed by \(latency) samples: SNR \(ratio) dB (tolerance 100 dB)")
            #expect(ratio >= 100, "\(name), \(label): SNR \(ratio) dB over \(range.count) samples")
            // Each component is a part: none of them is the signal, none is silence.
            let energy = { (signal: [Float]) in signal.reduce(0.0) { $0 + Double($1) * Double($1) } }
            #expect(energy(harmonic) > 0 && energy(percussive) > 0 && energy(harmonic) < energy(samples) && energy(percussive) < energy(samples), "\(label)")
        }
    }

    @Test func withoutMarginsTheResidualIsNothingAndTwoComponentsAreTheSignal() throws {
        let (samples, format) = try fixture("music")
        func component(_ component: HarmonicPercussiveComponent) throws -> [Float] {
            try Pipeline { HPSS(select: component, frame: 1_024, hop: 256, timeKernel: 17, frequencyKernel: 17) }.process(samples, format: format)
        }
        let harmonic = try component(.harmonic), percussive = try component(.percussive), residual = try component(.residual)
        let range = 0 ..< harmonic.count - 768
        let ratio = signalToNoise(zip(harmonic, percussive).map { $0 + $1 }, against: samples, delayedBy: 768, over: range)
        print("measured WP-532: music, soft, unit margins: harmonic + percussive alone: SNR \(ratio) dB (tolerance 100 dB)")
        #expect(ratio >= 100, "unit margins and a soft mask share every bin between the two: SNR \(ratio) dB")
        let peak = samples.map { abs($0) }.max() ?? 1
        #expect((residual.map { abs($0) }.max() ?? 1) < 1e-5 * peak, "and the residual holds nothing")
    }

    // MARK: The recipe is its expansion (§5.2)

    @Test func theRecipeIsItsExpansion() throws {
        // A causal median behind a centred framing, a centred median behind a causal one: either
        // way the first samples of the stream are covered by whole window sums.
        #expect(Pipeline { HPSS(select: .harmonic) }
            == Pipeline { STFT(frame: 2_048, hop: 512, alignment: .centered); HarmonicPercussive(select: .harmonic); InverseSTFT(alignment: .centered) })
        #expect(Pipeline { HPSS(select: .harmonic) } != Pipeline { STFT(frame: 2_048, hop: 512); HarmonicPercussive(select: .harmonic); InverseSTFT() })
        let analysis = STFT(frame: 1_024, hop: 256, window: .hamming, channels: .channel(0))
        #expect(Pipeline { HPSS(select: .percussive, frame: 1_024, hop: 256, window: .hamming, timeKernel: 17, frequencyKernel: 9, mask: .hard, harmonicMargin: 2,
                                percussiveMargin: 3, alignment: .centered, median: .automatic, channels: .channel(0)) }
            == Pipeline {
                analysis
                HarmonicPercussive(select: .percussive, timeKernel: 17, frequencyKernel: 9, mask: .hard, harmonicMargin: 2, percussiveMargin: 3, alignment: .centered,
                                   median: .automatic)
                analysis.inverse
            })
        #expect(Pipeline().hpss(select: .residual, timeKernel: 17) == Pipeline { HPSS(select: .residual, timeKernel: 17) })
        #expect(Pipeline { HPSS(select: .harmonic) } != Pipeline { HPSS(select: .percussive) } && HPSS.stageName == "HPSS")
        #expect(HPSS(select: .harmonic).activation == .active && HPSS(select: .harmonic, isActive: false).activation == .constant(false))
        // With a switch, the three steps are one group under it.
        #expect(Pipeline { HPSS(select: .harmonic, isActive: false) }
            == Pipeline { ZTronDSPCore.Group(isActive: false) {
                STFT(frame: 2_048, hop: 512, alignment: .centered); HarmonicPercussive(select: .harmonic); InverseSTFT(alignment: .centered)
            } })
        let rule = try #require(HPSS(select: .harmonic).stageDescriptions.first?.rule)
        #expect(rule(.samples) != nil && HPSS(select: .harmonic).stageDescriptions.count == 3 && HPSS(select: .harmonic, isActive: false).stageDescriptions.count == 1)
        // Samples in, samples out: on anything else it is refused, in both tiers (O-12).
        #expect(throws: DSPError.self) { _ = try DynamicPipeline().appending(STFT(frame: 1_024, hop: 256)).appending(HPSS(select: .harmonic)) }
        #expect(try DynamicPipeline().appending(HPSS(select: .harmonic)).appending(HPSS(select: .percussive, isActive: false)).outputTag == .samples)
    }

    @Test func theLatencyIsOneFrameLessAHopPlusTheLookAhead() throws {
        let causal = try environmentAtTheEnd(of: Pipeline { HPSS(select: .harmonic) })
        expectClose(causal.latency, (2_048.0 - 512) / 48_000, .relative(1e-12), "one frame less a hop")
        #expect(causal.sampleRate == 48_000 && causal.frameSize == nil && causal.channelCount == 1)
        // Where the hop is longer than half a frame, half a frame: a centred frame is known that late.
        let sparse = try environmentAtTheEnd(of: Pipeline { HPSS(select: .harmonic, frame: 1_024, hop: 768, window: .hamming) })
        expectClose(sparse.latency, 512.0 / 48_000, .relative(1e-12))
        let centred = try environmentAtTheEnd(of: Pipeline { HPSS(select: .harmonic, alignment: .centered) })
        expectClose(centred.latency, (2_048.0 - 512 + 15 * 512) / 48_000, .relative(1e-12), "the look-ahead of the time median comes on top (REAL-5)")
        let low = try environmentAtTheEnd(of: Pipeline { HPSS(select: .percussive, frame: 1_024, hop: 256, timeKernel: 17, frequencyKernel: 17, alignment: .centered) })
        expectClose(low.latency, (1_024.0 - 256 + 8 * 256) / 48_000, .relative(1e-12))
        // What the recipe declares is what it does: an impulse comes out that many samples late.
        var impulse = [Float](repeating: 0, count: 16_384)
        impulse[5_000] = 1
        for (alignment, latency) in [(FrameAlignment.causal, 768), (.centered, 768 + 8 * 256)] {
            let sum = try HarmonicPercussiveComponent.allCases.map { component in
                try Pipeline { HPSS(select: component, frame: 1_024, hop: 256, timeKernel: 17, frequencyKernel: 17, alignment: alignment) }.process(impulse, format: mono48)
            }
            let total = (0 ..< sum[0].count).map { sum[0][$0] + sum[1][$0] + sum[2][$0] }
            let peak = try #require(total.indices.max { abs(total[$0]) < abs(total[$1]) })
            #expect(peak == 5_000 + latency, "\(alignment): the impulse comes out at \(peak)")
            expectClose(total[peak], 1, .absolute(1e-5))
            #expect(total.indices.allSatisfy { $0 == peak || abs(total[$0]) < 1e-5 }, "\(alignment): and nowhere else")
        }
    }

    // MARK: Switching (ACT-3, ACT-4, ACT-7, ACT-8)

    @Test func aConstantSwitchCompilesTheRecipeAway() throws {
        let (samples, format) = try fixture("speech")
        #expect(try Pipeline { HPSS(select: .harmonic, isActive: false) }.process(samples, format: format) == samples, "bypassed for good: the signal, undelayed")
        #expect(try nodeNames(lowered(Pipeline { HPSS(select: .harmonic, isActive: false) }).steps).isEmpty)
        #expect(try environmentAtTheEnd(of: Pipeline { HPSS(select: .harmonic, isActive: false) }).latency == 0, "and no latency (ACT-4)")
        #expect(try nodeNames(lowered(Pipeline { HPSS(select: .harmonic) }).steps) == ["STFT", "HarmonicPercussive", "InverseSTFT"])
    }

    @Test(arguments: [FrameAlignment.causal, .centered])
    func aBoundSwitchMeetsCLICK1AndKeepsTheLatency(alignment: FrameAlignment) async throws {
        let rig = SessionRig()
        let on = StateBox(true)
        // The percussive part of a steady sine is next to nothing: switching it off is a change
        // from near silence to the full sine, and back.
        let recipe = HPSS(select: .percussive, frame: 256, hop: 64, timeKernel: 9, frequencyKernel: 9, alignment: alignment, isActive: on.binding)
        let (session, output) = try await rig.run(Pipeline { recipe })
        let latency = 256 - 64 + (alignment == .centered ? 4 * 64 : 0)
        expectClose(session.environment.latency, Double(latency) / 48_000, .relative(1e-12))
        let sine = Click.probeSignal(count: 64 * 600)
        let processed = try Pipeline { HPSS(select: .percussive, frame: 256, hop: 64, timeKernel: 9, frequencyKernel: 9, alignment: alignment) }
            .process(sine, format: mono48, blockSize: 64)
        func dry(_ index: Int) -> Float { index >= latency ? sine[index - latency] : 0 }

        // Active: the component, in the recipe's own blocks.
        rig.feed(Array(sine[..<(64 * 150)]))
        #expect(output.samples.count >= 64 * 150 - 64 && output.samples == Array(processed[..<output.samples.count]))
        #expect((output.samples[(64 * 100)...].map { abs($0) }.max() ?? 1) < 0.05, "a steady sine has next to no percussive part")

        // Off: a cross-fade of 10 ms to the signal delayed by the recipe's latency (ACT-8).
        on.value = false
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 150) ..< (64 * 300)]))
        #expect(output.samples.count == 64 * 300, "every sample of the input has come out once")
        #expect((64 * 170 ..< 64 * 300).allSatisfy { output.samples[$0] == dry($0) }, "bypassed, the signal passes delayed by the recipe's latency")

        // On: a cold start, a pre-roll with the delayed signal still passing, then a fade back.
        on.value = true
        await session.syncBindings()
        rig.feed(Array(sine[(64 * 300)...]))
        let total = output.samples.count
        #expect(total >= sine.count - 64 && total <= sine.count, "nothing was lost or repeated: \(total) of \(sine.count)")
        #expect((output.samples[(64 * 450) ..< total].map { abs($0) }.max() ?? 1) < 0.05, "active again, the component")
        expectClose(session.environment.latency, Double(latency) / 48_000, .relative(1e-12), "switching does not change the latency")
        #expect(session.core.generation == 1, "nor the plan")

        let off = Click.measure(output.samples, change: 64 * 148 ..< 64 * 165, settle: 256)
        let back = Click.measure(output.samples, change: 64 * 298 ..< 64 * 440, settle: 256)
        print("measured WP-532: bound switch, \(alignment): CLICK-1 off: \(off); on: \(back)")
        #expect(off.passes && back.passes, "CLICK-1 off: \(off); on: \(back)")
        session.detach()
    }

    @Test func aRecipeThatStartsBypassedPassesTheSignalAtItsLatency() async throws {
        let rig = SessionRig()
        let on = StateBox(false)
        let (session, output) = try await rig.run(Pipeline { HPSS(select: .harmonic, frame: 256, hop: 64, timeKernel: 9, frequencyKernel: 9, isActive: on.binding) })
        let sine = Click.probeSignal(count: 64 * 100)
        rig.feed(sine)
        #expect(output.samples.count == sine.count)
        #expect(output.samples == [Float](repeating: 0, count: 192) + Array(sine[..<(sine.count - 192)]), "the signal, 192 samples late: the latency of the recipe, from the first block")
        session.detach()
    }

    // MARK: Channels

    @Test func aSignalOfSeveralChannelsComesOutAsOne() throws {
        let left = TestSignal.whiteNoise(count: 8_000, seed: 1, amplitude: 0.4), right = TestSignal.whiteNoise(count: 8_000, seed: 2, amplitude: 0.4)
        let stereo = SignalFormat(sampleRate: 48_000, channelCount: 2)
        let mixed = try Pipeline { HPSS(select: .harmonic, frame: 512, hop: 128, timeKernel: 9, frequencyKernel: 9) }.process(channels: [left, right], format: stereo)
        let mono = try Pipeline { HPSS(select: .harmonic, frame: 512, hop: 128, timeKernel: 9, frequencyKernel: 9) }
            .process(zip(left, right).map { ($0 + $1) / 2 }, format: mono48)
        #expect(mixed.count == 1, "one channel: the mix-down of the transform")
        expectClose(mixed[0], mono, .absolute(1e-6))
        let first = try Pipeline { HPSS(select: .harmonic, frame: 512, hop: 128, timeKernel: 9, frequencyKernel: 9, channels: .channel(1)) }
            .process(channels: [left, right], format: stereo)
        expectClose(first[0], try Pipeline { HPSS(select: .harmonic, frame: 512, hop: 128, timeKernel: 9, frequencyKernel: 9) }.process(right, format: mono48), .absolute(1e-6))
    }

    // MARK: Attach-time checks

    @Test func nonsenseIsRefusedWhenThePipelineIsAttached() {
        let noise = TestSignal.whiteNoise(count: 4_000, seed: 3)
        func refusal(_ recipe: HPSS) -> String? { errorMessage { _ = try Pipeline { recipe }.process(noise, format: mono48) } }
        #expect(refusal(HPSS(select: .harmonic, frame: 1_000))?.contains("Invalid parameter frame") == true)
        #expect(refusal(HPSS(select: .harmonic, frame: 1_024, hop: 1_024))?.contains("fails the non-zero overlap-add condition") == true)
        #expect(refusal(HPSS(select: .harmonic, timeKernel: 30))?.contains("Invalid parameter timeKernel") == true)
        #expect(refusal(HPSS(select: .harmonic, median: .metal))?.contains("the GPU median filters whole spectrograms offline") == true)
        #expect(refusal(HPSS(select: .harmonic, frame: 512, hop: 128, timeKernel: 5, frequencyKernel: 5)) == nil)
        // Switched off for good it is still checked.
        #expect(refusal(HPSS(select: .harmonic, timeKernel: 30, isActive: false))?.contains("Invalid parameter timeKernel") == true)
    }

    // MARK: Cold start (ACT-10) and the real-time audit (RT-7)

    @Test func aColdStartIsOne() throws {
        let noise = TestSignal.whiteNoise(count: 3_000, seed: 77, amplitude: 0.5)
        for alignment in [FrameAlignment.causal, .centered] {
            try expectAFreshStreamAfterAColdStart(
                of: Pipeline { HPSS(select: .harmonic, frame: 256, hop: 64, timeKernel: 9, frequencyKernel: 9, alignment: alignment) }, on: noise, "HPSS, \(alignment)")
        }
    }

    @Test func theRecipeRunsWithoutAllocating() async throws {
        try expectNoAllocationsRunning(Pipeline { HPSS(select: .harmonic) })
        try expectNoAllocationsRunning(Pipeline { HPSS(select: .residual, timeKernel: 17, frequencyKernel: 17, mask: .hard, harmonicMargin: 2, percussiveMargin: 2, alignment: .centered) })
        // With a bound switch, in every state of the switch: active, fading, bypassed, pre-rolling.
        let rig = SessionRig()
        let on = StateBox(true)
        let session = try await rig.start(Pipeline { HPSS(select: .percussive, frame: 256, hop: 64, timeKernel: 9, frequencyKernel: 9, alignment: .centered, isActive: on.binding) })
        await rig.drain()
        let block = Array(Click.probeSignal(count: 64))
        for round in 0 ..< 6 {
            on.value = round % 2 == 1
            await session.syncBindings()
            try rig.auditAllocations(blocks: 200, of: block, "round \(round)")
        }
        session.detach()
    }
}
