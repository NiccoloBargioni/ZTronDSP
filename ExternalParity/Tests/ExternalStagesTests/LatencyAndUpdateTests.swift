import CExternalKernels
import ExternalStages
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

/// What every stage gets without writing it (EXT-2), seen from outside the package for the
/// three stages of the suite: latency accounting, settling times that a plan honours, and
/// state carried across updates and plan changes (§5.5.4, SWAP-1, SWAP-2).
@Suite("Latency, settling and updates")
struct LatencyAndUpdateTests {
    static let block = 64
    let noise = TestSignal.whiteNoise(count: 200 * LatencyAndUpdateTests.block, seed: 314, amplitude: 0.8)
    let probe = Click.probeSignal(count: 200 * LatencyAndUpdateTests.block)

    // MARK: Latency (REAL-5)

    @Test func theThreeStagesAddNoLatencyAndSayIt() async throws {
        let engine = DSPEngine(blockSize: 512)
        let source = BufferSource(noise, sampleRate: 48_000)
        let external = try await engine.attach(
            Pipeline {
                ExternalGain(.decibels(-3))
                ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
                Tap { STFT(frame: 1_024, hop: 256); Power(); ExternalMelScale(bands: 40) }
            }, to: source)
        #expect(external.environment.latency == 0)
        external.detach()
        // Behind a stage that does delay, the three leave the figure as it is: 50 frames of a 101-tap filter.
        let delayed = try await engine.attach(
            Pipeline {
                LowPass(.windowedSinc(), cutoff: .hertz(4_000), length: 101)
                ExternalGain(.decibels(-3))
                ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
            }, to: source)
        #expect(delayed.environment.latency == 50.0 / 48_000)
        delayed.detach()
    }

    /// A stage that describes one latency and runs with another.
    struct Mismatched: SequenceStage {
        let onAKernel: Bool

        func lower(_ context: inout LoweringContext) throws(DSPError) {
            if onAKernel {
                // The kernel of the suite delays nothing; the description claims five frames.
                context.emit(.custom(CustomKernel(name: "Mismatched", key: 0, latencyFrames: 5) { channels, _, _ in
                    extk_biquad_create(UInt32(channels), 1, [1, 0, 0, 0, 0], false, ZTD_IMPLEMENTATION_ACCELERATE)
                }))
            } else {
                context.emit(.processor(CustomProcessor(name: "Mismatched", key: 1, latencyFrames: 5) { _ throws(DSPError) -> any SampleProcessor in
                    try ExternalGainProcessor(factors: [1])
                }))
            }
        }
    }

    @Test func aLatencyThatIsDescribedAndNotRunIsRefused() throws {
        // CR-015, item 21: a stage written outside the package states its latency twice, and a plan
        // in which the two differ is refused, so nothing behind the stage is stamped with the wrong time.
        for onAKernel in [true, false] {
            let error = #expect(throws: DSPError.self) { try Pipeline { Mismatched(onAKernel: onAKernel) }.process(noise, format: mono48) }
            guard case .unsupportedConfiguration(let reason, let stage)? = error else {
                Issue.record("a stage described with 5 frames that runs with 0: \(String(describing: error))")
                continue
            }
            #expect(reason.contains("described with a latency of 5 frames and runs with one of 0") && stage?.stageName == "Mismatched")
        }
    }

    // MARK: Updates (§5.5.4)

    /// The filter of these tests, a sink that hears what leaves it, a stock gain behind it, and
    /// an optional tap behind that: what changes around the filter while it runs.
    private func chain(gain: Amplification, heardBy middle: CollectingSink<Samples>, tap: CollectingSink<Samples>? = nil) -> Pipeline<Samples, Samples> {
        let base = Pipeline()
            .externalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4)
            .emit(to: middle)
            .gain(gain)
        guard let tap else { return base }
        return base.tap { $0.emit(to: tap) }
    }

    static let cut = 60 * block

    @Test func aValueSentToAnotherStageLeavesTheFilterItsMemory() async throws {
        // The same topology with another value: the value travels to the stock gain; the plan,
        // and with it the filter and its memory, stay where they are.
        let middle = CollectingSink<Samples>()
        let run = try await HandFedRun(chain(gain: .decibels(-6), heardBy: middle), blockSize: LatencyAndUpdateTests.block)
        let log = EventLog(run.session)
        let cut = LatencyAndUpdateTests.cut
        try #require(await run.feed(Array(noise[..<cut])))
        try await run.session.update(run.framed(chain(gain: .decibels(-12), heardBy: middle)))
        try #require(await run.feed(Array(noise[cut...])))
        try #require(await run.finish())

        let filtered = try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }.process(noise, format: mono48, blockSize: LatencyAndUpdateTests.block)
        #expect(middle.samples == filtered, "the filter ran through the update as if nothing had happened")
        let factor = Float(Amplification.decibels(-12).linear)
        #expect(Array(run.output.samples.suffix(4_096)) == Array(filtered.suffix(4_096)).map { $0 * factor }, "the gain arrived at its new value")
        #expect(await eventually { log.contains(.stateChanged(.finished)) })
        #expect(!log.contains(.replanned(.update)), "no plan was compiled: \(log.all)")
    }

    @Test func aPlanChangeElsewhereCarriesTheFilterWithItsState() async throws {
        // Another topology: a new plan takes over at a block boundary, and a kernel whose own
        // description and whole upstream path are unchanged moves into it with its state (SWAP-1).
        let middle = CollectingSink<Samples>(), added = CollectingSink<Samples>()
        let run = try await HandFedRun(chain(gain: .decibels(-6), heardBy: middle), blockSize: LatencyAndUpdateTests.block)
        let log = EventLog(run.session)
        let cut = LatencyAndUpdateTests.cut
        try #require(await run.feed(Array(noise[..<cut])))
        try await run.session.update(run.framed(chain(gain: .decibels(-6), heardBy: middle, tap: added)))
        try #require(await run.feed(Array(noise[cut...]), awaitingOutput: false))
        try #require(await run.finish())

        let filtered = try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }.process(noise, format: mono48, blockSize: LatencyAndUpdateTests.block)
        #expect(middle.samples == filtered, "the filter kept its memory across the exchange")
        let factor = Float(Amplification.decibels(-6).linear)
        #expect(run.output.samples == filtered.map { $0 * factor }, "the main line did not notice the exchange")
        #expect(added.samples == Array(filtered[cut...]).map { $0 * factor }, "the new branch starts at the exchange")
        #expect(await eventually { log.contains(.replanned(.update)) }, "a plan was compiled and exchanged")
    }

    @Test func anEqualPipelineChangesNothing() async throws {
        let middle = CollectingSink<Samples>()
        let run = try await HandFedRun(chain(gain: .decibels(-6), heardBy: middle), blockSize: LatencyAndUpdateTests.block)
        let log = EventLog(run.session)
        let cut = LatencyAndUpdateTests.cut
        try #require(await run.feed(Array(noise[..<cut])))
        try await run.session.update(run.framed(chain(gain: .decibels(-6), heardBy: middle)))
        try #require(await run.feed(Array(noise[cut...])))
        try #require(await run.finish())
        let expected = try chain(gain: .decibels(-6), heardBy: CollectingSink<Samples>()).process(noise, format: mono48, blockSize: LatencyAndUpdateTests.block)
        #expect(run.output.samples == expected)
        #expect(await eventually { log.contains(.stateChanged(.finished)) })
        #expect(!log.contains(.replanned(.update)))
    }

    /// What a sink behind the main line heard of a run whose pipeline changed at `cut`.
    struct Heard {
        /// Frame by frame: the sample the sink was given, or `nil` where it was given none.
        let timeline: [Float?]
        /// Whether a plan was compiled and exchanged.
        let replanned: Bool

        /// The first frame the sink did not hear, and how many it missed in all.
        var gap: (start: Int?, count: Int) {
            (timeline.firstIndex { $0 == nil }, timeline.reduce(0) { $0 + ($1 == nil ? 1 : 0) })
        }

        /// The frames from `start` on, where every one was heard.
        func samples(from start: Int) -> [Float] { timeline[start...].compactMap { $0 } }

        /// Where two timelines part, for a message: the first frame that differs and what each heard there.
        static func firstDifference(_ one: Heard, _ other: Heard) -> String {
            let common = min(one.timeline.count, other.timeline.count)
            guard let frame = (0 ..< common).first(where: { one.timeline[$0] != other.timeline[$0] }) else {
                return one.timeline.count == other.timeline.count ? "no difference" : "\(one.timeline.count) frames against \(other.timeline.count)"
            }
            let last = (frame ..< common).last { one.timeline[$0] != other.timeline[$0] } ?? frame
            return "frames \(frame) to \(last) differ; at \(frame) \(String(describing: one.timeline[frame])) against \(String(describing: other.timeline[frame]))"
        }
    }

    /// Runs `before`, hands the session `after` at `cut`, and returns what the sink behind the
    /// main line heard.
    private func updated(_ signal: [Float], from before: Pipeline<Samples, Samples>, to after: Pipeline<Samples, Samples>) async throws -> Heard {
        let run = try await HandFedRun(before, blockSize: LatencyAndUpdateTests.block)
        let log = EventLog(run.session)
        try #require(await run.feed(Array(signal[..<LatencyAndUpdateTests.cut])))
        try await run.session.update(run.framed(after))
        // A sink behind a main line that changed is not written until the new plan has taken
        // over: the engine is followed by what entered it.
        try #require(await run.feed(Array(signal[LatencyAndUpdateTests.cut...]), awaitingOutput: false))
        try #require(await run.finish())
        try #require(await eventually { log.contains(.stateChanged(.finished)) })
        return Heard(timeline: run.output.timeline(sampleRate: 48_000, count: signal.count), replanned: log.contains(.replanned(.update)))
    }

    /// Frames a plan exchange on the main line takes before the new plan is the one that runs:
    /// the pre-roll, in whole blocks, and a fade of 10 ms, in whole blocks (SWAP-2).
    private func exchangeFrames(settling: Int) -> Int {
        let block = LatencyAndUpdateTests.block
        return (settling + block - 1) / block * block + (480 + block - 1) / block * block
    }

    @Test func aFilterAddedToARunningPipelineIsPrerolledForItsSettlingTimeLikeTheStockFilter() async throws {
        // SWAP-2: what is new on the main line runs beside the old plan for its settling time, with
        // its output discarded, before it takes over. The settling time is the kernel's own figure.
        let before = Pipeline { Gain(.decibels(-3)) }
        let externalAfter = Pipeline { Gain(.decibels(-3)); ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
        let stockAfter = Pipeline { Gain(.decibels(-3)); LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) }
        let cut = LatencyAndUpdateTests.cut
        for signal in [probe, noise] {
            let external = try await updated(signal, from: before, to: externalAfter)
            let stock = try await updated(signal, from: before, to: stockAfter)
            #expect(external.timeline == stock.timeline, "the sink hears the same frames, bit for bit, as with the stock filter")
            #expect(external.replanned && stock.replanned)
            #expect(external.gap.start == stock.gap.start && external.gap.count == stock.gap.count)
        }
        let heard = try await updated(probe, from: before, to: externalAfter)
        let old = try before.process(probe, format: mono48, blockSize: LatencyAndUpdateTests.block)
        let new = try externalAfter.process(probe, format: mono48, blockSize: LatencyAndUpdateTests.block)
        let settling = try Int(extk_biquad_settling(BiquadKernelTests.coefficients(cutoff: 1_000, order: 4), 2))
        // Up to the update the sink hears the old plan. A sink behind a main line that changed
        // then hears nothing until the new plan runs (CR-015, item 4): that is the pre-roll, as
        // long as the kernel says it needs to settle, and the fade.
        #expect(heard.timeline[..<cut].compactMap { $0 } == Array(old[..<cut]))
        let exchange = exchangeFrames(settling: settling)
        #expect(heard.gap.start == cut && heard.gap.count == exchange, "\(heard.gap) for a settling time of \(settling) frames")
        // From then on it hears the new filter, which did not hear the signal before the update and
        // has by now forgotten that to 100 dB.
        expectClose(heard.samples(from: cut + exchange), Array(new[(cut + exchange)...]), .absolute(2.0e-5))
    }

    // MARK: Value updates of the suite's own kernel and processor (§5.5.4)

    @Test func aChangedCutoffIsSetInTheRunningKernelAsTheStockFilterSetsIt() async throws {
        // §5.5.4: the same topology with another cutoff is a value update. The coefficients are
        // the values of the suite's kernel (CustomKernel(values:)), so the engine sends them to
        // the kernel that runs (ZTD_COMMAND_SET_VALUES) at a block boundary: it sets them in place
        // and keeps its memory. No plan is compiled, and the sink behind it hears every frame, the
        // same floats as behind the stock filter.
        let stock = try await updated(
            probe, from: Pipeline { LowPass(.butterworth, cutoff: .hertz(1_000), order: 4) },
            to: Pipeline { LowPass(.butterworth, cutoff: .hertz(2_500), order: 4) })
        let external = try await updated(
            probe, from: Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(1_000), order: 4) },
            to: Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(2_500), order: 4) })
        #expect(!stock.replanned && stock.gap.count == 0, "the stock filter takes the new coefficients in place: no plan is compiled, and its sink misses nothing")
        #expect(!external.replanned, "no plan was compiled for a changed cutoff")
        #expect(external.gap.count == 0, "the sink missed \(external.gap.count) frames from frame \(external.gap.start ?? -1)")
        #expect(external.timeline == stock.timeline, "the sink hears the same frames, bit for bit, as behind the stock filter")
        // And it hears the new filter: what it hears last is the 2 500 Hz filter's output.
        let new = try Pipeline { ExternalLowPass(.butterworth, cutoff: .hertz(2_500), order: 4) }.process(probe, format: mono48, blockSize: LatencyAndUpdateTests.block)
        expectClose(external.samples(from: probe.count - 2_048), Array(new.suffix(2_048)), .absolute(2.0e-5))
    }

    @Test func aChangedAmountRampsInTheRunningProcessorAsTheStockGainRamps() async throws {
        // §5.5.4 for a processor: the factors are the values of the suite's processor
        // (CustomProcessor(values:)), so the engine hands them to the processor that runs
        // (AdjustableSampleProcessor.setValues) between two blocks, and it ramps to them over
        // 10 ms, frame by frame as the stock gain kernel ramps. No plan is compiled, and the sink
        // behind it hears every frame, the same floats as behind the stock gain.
        let stock = try await updated(probe, from: Pipeline { Gain(.decibels(-6)) }, to: Pipeline { Gain(.decibels(-12)) })
        let external = try await updated(probe, from: Pipeline { ExternalGain(.decibels(-6)) }, to: Pipeline { ExternalGain(.decibels(-12)) })
        #expect(!stock.replanned && stock.gap.count == 0)
        #expect(!external.replanned, "no plan was compiled for a changed amount")
        #expect(external.gap.count == 0, "the sink missed \(external.gap.count) frames from frame \(external.gap.start ?? -1)")
        #expect(external.timeline == stock.timeline, "the sink hears the same frames, bit for bit, as behind the stock gain: \(Heard.firstDifference(external, stock))")
        // The old amount up to the update; a ramp of 480 frames from the block boundary where the
        // value arrives; the new amount from then on.
        let cut = LatencyAndUpdateTests.cut, block = LatencyAndUpdateTests.block
        let old = Float(Amplification.decibels(-6).linear), new = Float(Amplification.decibels(-12).linear)
        #expect(Array(external.timeline[..<cut]) == Array(probe[..<cut]).map { Optional($0 * old) })
        let arrived = cut + 480 + block
        #expect(external.samples(from: arrived) == Array(probe[arrived...]).map { $0 * new })
        // In between, every frame's gain lies between the two amounts, and the frames move from one
        // to the other: a ramp, not a jump (CLICK-1).
        let gains = (cut..<arrived).compactMap { frame -> Float? in
            guard abs(probe[frame]) > 0.1, let heard = external.timeline[frame] else { return nil }
            return heard / probe[frame]
        }
        #expect(gains.allSatisfy { $0 <= old * 1.0001 && $0 >= new * 0.9999 }, "\(gains.min() ?? .nan) … \(gains.max() ?? .nan)")
        #expect(gains.contains { $0 < old * 0.99 && $0 > new * 1.01 }, "the amount moved through the values between the two")
    }

    @Test func aChangedRampIsAnotherProcessor() async throws {
        // The length of the ramp is the processor's structure (its key), not one of its values:
        // another ramp is another processor, which a new plan brings in.
        let heard = try await updated(probe, from: Pipeline { ExternalGain(.decibels(-6)) }, to: Pipeline { ExternalGain(.decibels(-6), ramp: 0.020) })
        #expect(heard.replanned, "a plan was compiled for another ramp")
        #expect(heard.gap.start == LatencyAndUpdateTests.cut && heard.gap.count == exchangeFrames(settling: 0), "\(heard.gap)")
    }

    /// The suite's low-pass, or the stock one, at `cutoff`, a sink that hears what leaves it, and
    /// an optional tap behind it: the filter of a run whose values and topology both change.
    private func filtered(external: Bool, cutoff: Double, heardBy middle: CollectingSink<Samples>, tap: CollectingSink<Samples>? = nil) -> Pipeline<Samples, Samples> {
        let filter = external
            ? Pipeline().externalLowPass(.butterworth, cutoff: .hertz(cutoff), order: 4)
            : Pipeline().lowPass(.butterworth, cutoff: .hertz(cutoff), order: 4)
        let base = filter.emit(to: middle).gain(.decibels(-6))
        guard let tap else { return base }
        return base.tap { $0.emit(to: tap) }
    }

    @Test func aKernelMovedIntoANewPlanKeepsTheValuesItWasSentLast() async throws {
        // SWAP-1 after §5.5.4: a changed cutoff is set in the kernel that runs; a later change of
        // topology elsewhere moves that kernel into the new plan with its memory and with the
        // coefficients it was sent, as it moves the stock filter.
        let cut = LatencyAndUpdateTests.cut
        func heard(external: Bool) async throws -> (middle: [Float], replans: Int) {
            let middle = CollectingSink<Samples>(), added = CollectingSink<Samples>()
            let run = try await HandFedRun(filtered(external: external, cutoff: 1_000, heardBy: middle), blockSize: LatencyAndUpdateTests.block)
            let log = EventLog(run.session)
            try #require(await run.feed(Array(noise[..<cut])))
            try await run.session.update(run.framed(filtered(external: external, cutoff: 2_500, heardBy: middle)))
            try #require(await run.feed(Array(noise[cut..<(2 * cut)])))
            try await run.session.update(run.framed(filtered(external: external, cutoff: 2_500, heardBy: middle, tap: added)))
            try #require(await run.feed(Array(noise[(2 * cut)...]), awaitingOutput: false))
            try #require(await run.finish())
            try #require(await eventually { log.contains(.stateChanged(.finished)) })
            return (middle.samples, log.all.filter { $0 == .replanned(.update) }.count)
        }
        let stock = try await heard(external: false), external = try await heard(external: true)
        #expect(stock.replans == 1 && external.replans == 1, "one plan was compiled, for the tap: \(stock.replans) and \(external.replans)")
        #expect(external.middle.count == noise.count, "the sink behind the filter heard \(external.middle.count) of \(noise.count) frames")
        #expect(external.middle == stock.middle, "the filter ran through the value update and the exchange as the stock filter runs")
    }
}
