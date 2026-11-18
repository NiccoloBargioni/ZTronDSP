import ExtensionGuide
import ExternalTestSupport
import Foundation
import Testing
import ZTronDSP
import ZTronDSPTesting

// WP-908, rows 5 and 6 of §5.11.1: where frames leave a pipeline, and where samples enter one.

/// Row 5, a sink: `PeakHoldMeter`, a `FeatureSink` for a scalar track.
@Suite("Guide 5: a sink")
struct SinkExampleTests {
    let quiet = TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 9_600, amplitude: 0.1)
    let loud = TestSignal.sine(frequency: 440, sampleRate: 48_000, count: 9_600, amplitude: 0.8)

    @Test func itKeepsTheNewestValueAndTheLargest() throws {
        // snippet:begin meter-use
        let meter = PeakHoldMeter(), track = CollectingSink<Scalar>()
        #expect(meter.value == 0 && meter.peak == -.infinity)
        try Pipeline().level(.rms).emit(to: track).emit(to: meter).run(on: quiet + loud + quiet, format: mono48)
        let values = track.scalars.map { $0.value }
        try #require(values.count > 50)
        #expect(meter.value == values.last && meter.peak == values.max())
        // snippet:end meter-use
        // A sine of amplitude 0.8 reads −4.95 dBFS, one of 0.1 reads −23.01 dBFS.
        expectClose(meter.peak, -4.95, .absolute(0.05))
        expectClose(meter.value, -23.01, .absolute(0.05))
        // The next attachment claims the sink anew: it starts from nothing.
        try Pipeline().level(.rms).emit(to: meter).run(on: quiet, format: mono48)
        expectClose(meter.peak, -23.01, .absolute(0.05))
    }

    @Test func theMarkFallsWhenItIsReset() async throws {
        let meter = PeakHoldMeter()
        let run = try await HandFedRun(Pipeline().tap { $0.level(.rms, window: 0.01, hop: 0.01).emit(to: meter) })
        try #require(await run.feed(Array(loud[..<4_800])))
        try #require(await eventually { meter.peak > -6 })
        try #require(await run.feed(Array(quiet[..<4_800])))
        try #require(await eventually { meter.value < -20 })
        #expect(meter.peak > -6, "the mark holds the loud stretch while the level has fallen: \(meter.peak)")
        // Any thread may ask; the writer takes the request with the next value.
        meter.resetPeak()
        try #require(await run.feed(Array(quiet[..<4_800])))
        #expect(await eventually { meter.peak < -20 }, "after a reset the mark is the next value that arrives: \(meter.peak)")
        try #require(await run.finish())
    }

    @Test func oneAttachmentWritesItAtATime() async throws {
        // ATT-5: the engine keeps the claim; the sink writes no code for it.
        let meter = PeakHoldMeter()
        let pipeline = Pipeline().tap { $0.level(.peak).emit(to: meter) }
        let engine = DSPEngine(blockSize: 512)
        let source = BufferSource(loud, sampleRate: 48_000)
        let first = try await engine.attach(pipeline, to: source)
        let refused = await #expect(throws: DSPError.self) { _ = try await engine.attach(pipeline, to: source) }
        guard case .sinkInUse(let name)? = refused else {
            Issue.record("a second attachment that writes the meter: \(String(describing: refused))")
            return
        }
        #expect(name == "PeakHoldMeter")
        first.detach()
        // The claim ends with the attachment: the next one may write the sink.
        let second = try await engine.attach(pipeline, to: source)
        try second.start()
        #expect(await second.reaches(.finished))
        second.detach()
        expectClose(meter.peak, 20 * log10(0.8), .absolute(0.01))
        // One sink named twice in one pipeline is refused as well.
        await #expect(throws: DSPError.self) {
            _ = try await engine.attach(Pipeline().tap { $0.level(.peak).emit(to: meter).emit(to: meter) }, to: source)
        }
    }
}

/// Row 6, a source: `ClickSource`, a `PullSampleSource`.
@Suite("Guide 6: a source")
struct SourceExampleTests {
    /// What the metronome delivers, computed apart from it.
    static func clicks(beatsPerMinute: Double, sampleRate: Double, count: Int) -> [Float] {
        let period = Int((60 * sampleRate / beatsPerMinute).rounded())
        let length = max(min(Int((0.005 * sampleRate).rounded()), period / 2), 1)
        return (0 ..< count).map { index in
            let phase = index % period
            return phase < length ? 1 - Float(phase) / Float(length) : 0
        }
    }

    @Test func theEngineClocksItToItsEnd() async throws {
        let source = ClickSource(beatsPerMinute: 120, duration: 2, pacing: .asFastAsPossible)
        #expect(source.format == mono48 && source.pacing == .asFastAsPossible)
        let delivered = try await throughEngine(Pipeline(), on: source)
        let expected = SourceExampleTests.clicks(beatsPerMinute: 120, sampleRate: 48_000, count: 96_000)
        #expect(delivered.count == 1 && delivered.first == expected)
        #expect(expected[0] == 1 && expected[24_000] == 1 && expected[239] > 0 && expected[240] == 0)
        // Another rate, another tempo, blocks that do not divide the stream.
        let other = ClickSource(beatsPerMinute: 90, sampleRate: 44_100, duration: 1.5, pacing: .asFastAsPossible)
        let again = try await throughEngine(Pipeline(), on: other, blockSize: 300)
        #expect(again.first == SourceExampleTests.clicks(beatsPerMinute: 90, sampleRate: 44_100, count: 66_150))
        // Nothing to deliver: the stream ends at once.
        let empty = try await throughEngine(Pipeline(), on: ClickSource(beatsPerMinute: 120, duration: 0, pacing: .asFastAsPossible))
        #expect(empty.allSatisfy { $0.isEmpty })
    }

    @Test func pacedInRealTimeItDeliversTheSameClicks() async throws {
        let source = ClickSource(beatsPerMinute: 600, duration: 0.25)
        #expect(source.pacing == .realTime)
        let start = Date()
        let delivered = try await throughEngine(Pipeline(), on: source)
        let elapsed = Date().timeIntervalSince(start)
        #expect(delivered.first == SourceExampleTests.clicks(beatsPerMinute: 600, sampleRate: 48_000, count: 12_000))
        #expect(elapsed >= 0.2, "one block per block duration: a quarter of a second of signal took \(elapsed) s")
    }

    @Test func startedAgainItStartsOver() async throws {
        // From `finished`, `start()` prepares the source again, and a source that has an end starts over.
        // snippet:begin source-use
        let source = ClickSource(beatsPerMinute: 240, duration: 0.5, pacing: .asFastAsPossible)
        let engine = DSPEngine(blockSize: 512)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
        try session.start()
        try #require(await session.reaches(.finished))
        // snippet:end source-use
        try #require(sink.sampleCount == 24_000)
        try session.start()
        try #require(await eventually { sink.sampleCount >= 48_000 })
        #expect(await session.reaches(.finished))
        session.detach()
        let once = SourceExampleTests.clicks(beatsPerMinute: 240, sampleRate: 48_000, count: 24_000)
        #expect(sink.samples == once + once)
    }

    @Test func itFeedsWhateverASourceFeeds() async throws {
        // SRC-2: a processed source on top of it; an analysis of what it delivers.
        let halved = ClickSource(beatsPerMinute: 120, duration: 1, pacing: .asFastAsPossible).processed(by: Pipeline { Gain(.linear(0.5)) })
        let delivered = try await throughEngine(Pipeline(), on: halved)
        #expect(delivered.first == SourceExampleTests.clicks(beatsPerMinute: 120, sampleRate: 48_000, count: 48_000).map { $0 * 0.5 })
        let flux = CollectingSink<Novelty>()
        let engine = DSPEngine(blockSize: 512)
        let session = try await engine.attach(
            Pipeline().tap { $0.stft(frame: 1_024, hop: 256).magnitude().spectralFlux().emit(to: flux) },
            to: ClickSource(beatsPerMinute: 120, duration: 2, pacing: .asFastAsPossible))
        try session.start()
        #expect(await session.reaches(.finished))
        session.detach()
        // Four clicks in two seconds; the first one is in the first frame, which has no flux.
        let values = flux.scalars.map { $0.value }
        let peak = values.max() ?? 0
        var onsets = 0
        for index in values.indices where values[index] > 0.5 * peak && (index == 0 || values[index - 1] <= 0.5 * peak) { onsets += 1 }
        #expect(peak > 0 && onsets == 3, "\(onsets) onsets in the flux of the metronome")
    }

    @Test func aSourceThatCannotDeliverSaysSoWhenItIsPrepared() async throws {
        let engine = DSPEngine(blockSize: 512)
        for tempo in [0, -60, Double.nan, Double.infinity] {
            let error = await #expect(throws: DSPError.self) {
                _ = try await engine.attach(Pipeline(), to: ClickSource(beatsPerMinute: tempo, duration: 1))
            }
            guard case .sourceUnavailable(let reason)? = error else {
                Issue.record("a tempo of \(tempo): \(String(describing: error))")
                continue
            }
            #expect(reason.contains("a positive tempo"))
        }
    }
}
