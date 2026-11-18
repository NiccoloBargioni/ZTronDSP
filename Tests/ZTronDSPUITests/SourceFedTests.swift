import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPIO
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// The source-fed components at level 1 (WP-814, WP-815): the pieces a component is made of,
/// without SwiftUI. What each component makes of a mock, a file and a processed signal, as a
/// surface draws it (SRC-3); and the one attachment a component keeps on its source, driven
/// as the view drives it: made when the view appears, left alone when the view is evaluated
/// again, updated when an analysis value changes, ended when the view leaves (VC-3), whatever
/// happens while a plan is being compiled.
@MainActor
@Suite("Source-fed components")
struct SourceFedTests {
    // MARK: One component shows a mock, a file and a processed signal (SRC-3)

    @Test func aSpectrogramShowsAMockAFileAndAProcessedSignal() async throws {
        let files = try ToneFiles()
        // A mock: half a second of 3 kHz.
        let mock = try await SourceFedShow(.spectrogram, of: Tone.mock(Tone.sine(3_000, seconds: 0.5)))
        #expect(mock.snapshot.axis == .linearFrequency(binCount: 1_025, nyquist: 24_000) && mock.rate == 93.75, "the recipe's defaults: 2 048 samples a frame, 512 apart")
        #expect(mock.snapshot.columnCount == 43, "24 000 samples hold 43 frames")
        #expect(mock.snapshot.strongestRow == Tone.bin(of: 3_000) && mock.brightestRow == Tone.bin(of: 3_000), "the feed holds 3 kHz, and the picture shows it there")
        expectClose(mock.snapshot.newest(row: Tone.bin(of: 3_000)), -6.02, .absolute(0.05), "a sine of half scale reads −6 dB whatever the frame")
        #expect(mock.probe.uploadedColumns == 43 && mock.probe.draws == 1 && mock.host.attaches == 1)

        // A file: 6 kHz.
        let file = try await SourceFedShow(.spectrogram, of: files.source(Tone.sine(6_000, seconds: 0.5)))
        #expect(file.snapshot.columnCount == 43 && file.snapshot.strongestRow == Tone.bin(of: 6_000) && file.brightestRow == Tone.bin(of: 6_000))

        // A processed signal (SRC-2): a strong 110 Hz and a weak 9 kHz, behind a high-pass
        // filter that takes the low tone away.
        let pair = Tone.pair(low: 110, high: 9_000, seconds: 0.5)
        let raw = try await SourceFedShow(.spectrogram, of: Tone.mock(pair))
        #expect(raw.snapshot.strongestRow == Tone.bin(of: 110) && raw.brightestRow == Tone.bin(of: 110), "unprocessed, the low tone is the strongest")
        let processed = try await SourceFedShow(.spectrogram, of: Tone.mock(pair).processed(by: Tone.highPass(2_000)))
        #expect(processed.snapshot.columnCount == 43 && processed.snapshot.strongestRow == Tone.bin(of: 9_000) && processed.brightestRow == Tone.bin(of: 9_000))
        expectClose(processed.snapshot.newest(row: Tone.bin(of: 9_000)), -26.02, .absolute(0.05), "the weak tone, untouched")
        #expect(processed.snapshot.newest(row: Tone.bin(of: 110)) < -90, "the strong one is gone")
    }

    @Test func aWaveformShowsAMockAFileAndAProcessedSignal() async throws {
        let files = try ToneFiles()
        // A mock of half scale: the envelope reaches half the way up and half the way down.
        let mock = try await SourceFedShow(.waveform, of: Tone.mock(Tone.sine(3_000, seconds: 0.5)))
        #expect(mock.rate == 200 && mock.snapshot.columnCount == 100, "five milliseconds a pair")
        expectClose(mock.snapshot.reach(newest: 16), 0.5, .absolute(0.005))
        expectClose(mock.coveredShare, 0.5, .absolute(0.02), "the picture covers half the height")
        #expect(mock.probe.uploadedColumns == 100 && mock.host.attaches == 1)
        // A file of quarter scale.
        let file = try await SourceFedShow(.waveform, of: files.source(Tone.sine(3_000, seconds: 0.5, amplitude: 0.25)))
        expectClose(file.snapshot.reach(newest: 16), 0.25, .absolute(0.005))
        expectClose(file.coveredShare, 0.25, .absolute(0.02))
        // A processed signal: the mock, 20 dB down.
        let processed = try await SourceFedShow(.waveform, of: Tone.mock(Tone.sine(3_000, seconds: 0.5)).processed(by: Pipeline { Gain(.decibels(-20)) }))
        expectClose(processed.snapshot.reach(newest: 16), 0.05, .absolute(0.002))
        expectClose(processed.coveredShare, 0.05, .absolute(0.01))
    }

    @Test func aChromagramShowsAMockAFileAndAProcessedSignal() async throws {
        let files = try ToneFiles()
        // A mock: two seconds of A4. Pitch class 9, counted from C.
        let mock = try await SourceFedShow(.chromagram, of: Tone.mock(Tone.sine(440, seconds: 2)), scale: 10)
        #expect(mock.snapshot.axis == .pitchClasses && mock.snapshot.rowCount == 12 && mock.rate == 93.75)
        #expect(mock.snapshot.columnCount > 60, "the transform's latency is behind it: \(mock.snapshot.columnCount) columns")
        #expect(mock.snapshot.strongestRow == 9 && mock.brightestRow == 9, "A")
        #expect(mock.snapshot.newest(row: 9) == 1, "the strongest class reads 1")
        #expect(mock.probe.uploadedColumns == mock.snapshot.columnCount && mock.host.attaches == 1)
        // A file: C5.
        let file = try await SourceFedShow(.chromagram, of: files.source(Tone.sine(523.25, seconds: 2)), scale: 10)
        #expect(file.snapshot.strongestRow == 0 && file.brightestRow == 0, "C")
        // A processed signal: a strong A2 and a weak E6, behind a high-pass filter.
        let pair = Tone.pair(low: 110, high: 1_318.51, seconds: 2)
        let raw = try await SourceFedShow(.chromagram, of: Tone.mock(pair), scale: 10)
        #expect(raw.snapshot.strongestRow == 9 && raw.brightestRow == 9, "unprocessed: A")
        let processed = try await SourceFedShow(.chromagram, of: Tone.mock(pair).processed(by: Tone.highPass(600)), scale: 10)
        #expect(processed.snapshot.strongestRow == 4 && processed.brightestRow == 4, "E")
    }

    @Test func aTempogramShowsAMockAFileAndAProcessedSignal() async throws {
        let files = try ToneFiles()
        // The tempo of the row a tempogram holds, and of the row its picture shows, as the strongest.
        func tempi(_ show: SourceFedShow) throws -> (feed: Double, picture: Double) {
            let axis = try #require(show.snapshot.axis)
            return (axis.value(ofRow: show.snapshot.strongestRow), axis.value(ofRow: show.brightestRow))
        }
        // A mock: eight seconds of clicks, 45 hops apart: 125 beats per minute.
        let mock = try await SourceFedShow(.tempogram, of: Tone.mock(Tone.clicks(hopsPerBeat: 45, seconds: 8)))
        #expect(mock.rate == 93.75 && mock.snapshot.columnCount > 300, "one column per onset value, once 384 of them are held: \(mock.snapshot.columnCount)")
        guard case .tempo(let rows)? = mock.snapshot.axis else {
            Issue.record("the rows of a tempogram are tempi, not \(String(describing: mock.snapshot.axis))")
            return
        }
        #expect(rows.allSatisfy { $0 >= 30 && $0 <= 300 } && rows == rows.sorted() && rows.count == mock.snapshot.rowCount)
        let fast = try tempi(mock)
        expectClose(fast.feed, 125, .absolute(1))
        expectClose(fast.picture, 125, .absolute(1), "the picture shows the tempo where the axis puts it")
        #expect(mock.probe.uploadedColumns == mock.snapshot.columnCount && mock.host.attaches == 1)
        // A file: 60 hops apart, 93.75 beats per minute.
        let slow = try tempi(try await SourceFedShow(.tempogram, of: files.source(Tone.clicks(hopsPerBeat: 60, seconds: 8))))
        expectClose(slow.feed, 93.75, .absolute(1))
        expectClose(slow.picture, 93.75, .absolute(1))
        // A processed signal: 50 hops apart, 112.5 beats per minute, 6 dB down.
        let processed = try await SourceFedShow(.tempogram, of: Tone.mock(Tone.clicks(hopsPerBeat: 50, seconds: 8)).processed(by: Pipeline { Gain(.decibels(-6)) }))
        let middle = try tempi(processed)
        expectClose(middle.feed, 112.5, .absolute(1))
        expectClose(middle.picture, 112.5, .absolute(1))
    }

    // MARK: The analysis modifiers reach the session (VC-4)

    /// `.processing(_:)`: the component shows the processed signal in the place of the raw one.
    @Test func processingIsShownInThePlaceOfTheRawSignal() async throws {
        let pair = Tone.pair(low: 110, high: 9_000, seconds: 0.5)
        let filtered = try await SourceFedShow(.spectrogram, of: Tone.mock(pair), processing: Tone.highPass(2_000))
        #expect(filtered.snapshot.strongestRow == Tone.bin(of: 9_000) && filtered.brightestRow == Tone.bin(of: 9_000))
        #expect(filtered.snapshot.newest(row: Tone.bin(of: 110)) < -90 && filtered.host.attaches == 1, "one attachment runs both the processing and the recipe")
        let quiet = try await SourceFedShow(.waveform, of: Tone.mock(Tone.sine(3_000, seconds: 0.5)), processing: Pipeline { Gain(.decibels(-20)) })
        expectClose(quiet.snapshot.reach(newest: 16), 0.05, .absolute(0.002))
        expectClose(quiet.coveredShare, 0.05, .absolute(0.01))
        let chroma = try await SourceFedShow(.chromagram, of: Tone.mock(Tone.pair(low: 110, high: 1_318.51, seconds: 2)), processing: Tone.highPass(600), scale: 10)
        #expect(chroma.snapshot.strongestRow == 4 && chroma.brightestRow == 4)
        // What is left of the clicks 300 dB down has no tempo: every column of the tempogram is nought.
        let silenced = try await SourceFedShow(.tempogram, of: Tone.mock(Tone.clicks(hopsPerBeat: 45, seconds: 8)), processing: Pipeline { Gain(.decibels(-300)) })
        #expect(silenced.snapshot.columnCount > 300 && silenced.snapshot.values.allSatisfy { $0 == 0 })
    }

    /// `.analysisFrame(_:hop:window:)`: the frame, the hop and the window are those of the
    /// transform the session runs.
    @Test func theAnalysisFrameIsTheOneTheSessionRuns() async throws {
        let frame = AnalysisFrame(frame: 512, hop: 128, window: .hamming)
        let bin = Tone.bin(of: 3_000, frame: 512)
        let show = try await SourceFedShow(.spectrogram, of: Tone.mock(Tone.sine(3_000, seconds: 0.25)), frame: frame)
        #expect(show.snapshot.axis == .linearFrequency(binCount: 257, nyquist: 24_000) && show.rate == 375)
        #expect(show.snapshot.environment?.frameSize == 512 && show.snapshot.environment?.hopSize == 128)
        #expect(show.snapshot.columnCount == 90, "12 000 samples hold 90 frames of 512, 128 apart")
        #expect(show.snapshot.strongestRow == bin && show.brightestRow == bin)
        // The window is the session's too: under a rectangular one a tone at a bin's centre
        // leaks into no other bin, and under a Hamming window it does.
        let plain = try await SourceFedShow(.spectrogram, of: Tone.mock(Tone.sine(3_000, seconds: 0.25)), frame: AnalysisFrame(frame: 512, hop: 128, window: .rectangular))
        #expect(plain.snapshot.newest(row: bin + 1) < -100 && show.snapshot.newest(row: bin + 1) > -20)
        // A tempogram's mel spectrogram runs the frame as well: half the hop, twice the columns a second.
        let tempo = try await SourceFedShow(.tempogram, of: Tone.mock(Tone.clicks(hopsPerBeat: 45, seconds: 4)), frame: AnalysisFrame(frame: 1_024, hop: 256, window: .hann))
        #expect(tempo.rate == 187.5 && tempo.snapshot.columnCount > 300)
    }

    /// `.melBands(_:)`: the bands are those of the mel spectrogram the session runs. A frame
    /// of 512 samples cannot fill 128 bands, which the engine says when it compiles the plan;
    /// with 32 bands the same frame is attached.
    @Test func theMelBandsAreTheOnesTheSessionRuns() async throws {
        let feed = HeatmapFeed(history: HeatmapAnalysis.history), host = PipelineHostProbe(), model = PipelineHostModel<Samples>()
        let frame = AnalysisFrame(frame: 512, hop: 128, window: .hann)
        func pipeline(bands: Int?) -> Pipeline<Samples, Samples> {
            HeatmapAnalysis.tempogram.pipeline(processing: nil, frame: frame, melBands: bands, into: feed)
        }
        model.appear(pipeline(bands: nil), on: Tone.mock(Tone.clicks(hopsPerBeat: 45, seconds: 3)), engine: DSPEngine(), renderProbe: nil, hostProbe: host)
        #expect(await eventually(timeout: patience) { host.failures.count == 1 }, "128 bands do not fit a transform of 512 points")
        guard case .invalidParameter(_, let parameter, _)? = host.failures.first else {
            Issue.record("expected invalidParameter, got \(String(describing: host.failures.first))")
            return
        }
        #expect(parameter == "bands" && host.attaches == 0 && feed.rowCount == 0)
        // The view is evaluated again with `.melBands(32)`.
        model.want(pipeline(bands: 32))
        #expect(await eventually(timeout: patience) { host.session?.state == .finished }, "32 bands do: \(host.failures)")
        #expect(host.attaches == 1 && host.failures.count == 1 && feed.columnCount > 300)
        model.disappear()
    }

    // MARK: The attachment follows the view's life (VC-3)

    /// Appear: one attachment. A hundred evaluations with equal values: no new attachment,
    /// no update. Disappear: detached, and the feed is free.
    @Test(arguments: SourceFedKind.allCases)
    func theAttachmentFollowsTheViewsLife(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind)
        rig.evaluate()
        await mainQueueDrained()
        #expect(rig.host.requests == 0 && rig.source.prepares == 0, "a view that is not in the hierarchy asks nothing of an engine")
        rig.appear()
        await rig.running()
        let session = try #require(rig.host.session)
        #expect(rig.host.attaches == 1 && rig.render.attaches == 1 && rig.host.requests == 1 && rig.host.detaches == 0 && rig.host.late.isEmpty)
        #expect(session.environment.sampleRate == SourceFedRig.sampleRate(kind) && session.environment.blockSize == 16, "on the engine it was given, at the source's format")
        await rig.send(0 ..< 4)
        #expect(rig.columnCount == 4 * rig.itemsPerBlock, "the session writes the feed the view owns")

        // The parent's body runs a hundred times: the component hands its host a pipeline
        // that is made anew and equal.
        for _ in 0 ..< 100 { rig.evaluate() }
        await mainQueueDrained()
        #expect(rig.host.updates.isEmpty, "0 updates")
        #expect(rig.host.attaches == 1 && rig.render.attaches == 1 && rig.host.requests == 1 && rig.source.prepares == 1, "0 new attachments")
        #expect(rig.host.session === session && session.state == .running)
        await rig.send(4 ..< 6)
        #expect(rig.columnCount == 6 * rig.itemsPerBlock, "and the feed goes on where it was")

        // The view leaves.
        let feed = rig.feed
        let claimed = await SourceFedRig.isFree(feed)
        #expect(!claimed, "while the view is in the hierarchy its feed has its one writer (ATT-5)")
        rig.leave()
        #expect(rig.host.detaches == 1 && session.state == .detached && rig.host.session == nil, "detached at once")
        #expect(await eventually(timeout: patience) { !feed.isLive })
        let released = await SourceFedRig.isFree(feed), unused = await SourceFedRig.isFree(rig.source)
        #expect(released, "the claim on the feed ended with the attachment")
        #expect(unused, "and the engine let go of the source")
        // Leaving twice, or being evaluated after leaving, does nothing.
        rig.model.disappear()
        rig.evaluate()
        await mainQueueDrained()
        #expect(rig.host.detaches == 1 && rig.host.attaches == 1 && rig.host.requests == 1)
    }

    /// A view that comes back attaches anew, and starts an empty picture: what it showed
    /// before it left is not continued.
    @Test(arguments: SourceFedKind.allCases)
    func aViewThatComesBackAttachesAnewAndStartsAnEmptyPicture(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind)
        rig.appear()
        await rig.running()
        await rig.send(0 ..< 3)
        let first = try #require(rig.host.session), before = rig.feed
        rig.leave()
        #expect(rig.feed != before, "another feed for the time it comes back")
        rig.appear()
        await rig.running()
        let second = try #require(rig.host.session)
        #expect(second !== first && first.state == .detached && rig.host.attaches == 2 && rig.host.detaches == 1)
        #expect(rig.columnCount == 0 && !before.isLive)
        await rig.send(3 ..< 5)
        #expect(rig.columnCount == 2 * rig.itemsPerBlock)
        rig.leave()
    }

    /// Another frame is another topology (§5.5.4): one update of the session the view keeps,
    /// no new attachment; the plan is exchanged at a block boundary and the feed refills in
    /// its new shape.
    @Test func anotherAnalysisFrameIsOneUpdateOfAnotherTopology() async throws {
        let rig = SourceFedRig(.spectrogram)
        rig.appear()
        await rig.running()
        await rig.send(0 ..< 4)
        let session = try #require(rig.host.session), feed = rig.heatmap
        #expect(feed.rowCount == 9 && feed.columnCount == 4 && feed.environment?.frameSize == 16)
        let replans = Box(0)
        let events = session.events
        let listening = Task {
            for await event in events {
                if case .replanned = event { replans.value += 1 }
            }
        }
        defer { listening.cancel() }

        // `.analysisFrame(32, hop: 16)`.
        rig.frame = AnalysisFrame(frame: 32, hop: 16, window: .hann)
        rig.evaluate()
        #expect(rig.host.updates.count == 1, "one update, sent at once")
        await rig.settled()
        // The plan takes over at a block boundary: blocks flow until it has.
        let block = SourceFedRig.blocks(4 ..< 5)
        #expect(await eventually(timeout: patience) {
            rig.source.write(block)
            return replans.value == 1 && feed.rowCount == 17 && feed.columnCount >= 2
        }, "a new plan took over, and the feed refills with 17 rows")
        #expect(feed.environment?.frameSize == 32 && feed.environment?.hopSize == 16)
        #expect(rig.heatmap === feed, "the view keeps its feed: the session clears it where the branch changed")
        #expect(rig.host.attaches == 1 && rig.host.requests == 1 && rig.host.session === session && session.state == .running, "the same attachment")
        #expect(rig.host.updates.count == 1 && rig.host.failures.isEmpty)
        // The same frame again is no update.
        for _ in 0 ..< 100 { rig.evaluate() }
        await mainQueueDrained()
        #expect(rig.host.updates.count == 1)
        rig.leave()
    }

    /// Another value in the processing is the same topology (§5.5.4): one update, no new
    /// plan, and the feed goes on without a gap.
    @Test(arguments: SourceFedKind.allCases)
    func anotherProcessingValueIsAValueUpdate(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind)
        rig.processing = PipelineHostTests.chain([-6, -12])
        rig.appear()
        await rig.running()
        await rig.send(0 ..< 4)
        let session = try #require(rig.host.session)
        let replans = Box(0)
        let events = session.events
        let listening = Task {
            for await event in events {
                if case .replanned = event { replans.value += 1 }
            }
        }
        defer { listening.cancel() }
        rig.processing = PipelineHostTests.chain([-20, -12])
        rig.evaluate()
        #expect(rig.host.updates.count == 1 && Array(rig.host.updates[0].values.prefix(2)) == [-20, -12])
        await rig.settled()
        await rig.send(4 ..< 8)
        for _ in 0 ..< 4 { await mainQueueDrained() }
        #expect(replans.value == 0, "values travel to the kernels that run: no new plan")
        #expect(rig.columnCount == 8 * rig.itemsPerBlock, "the feed went on: nothing was cleared")
        #expect(rig.host.attaches == 1 && rig.host.session === session)
        rig.leave()
    }

    /// A pipeline the engine refuses is noted and leaves what runs as it is; the next valid
    /// one is taken (as `.pipeline(_:on:)` does).
    @Test func aFrameTheEngineRefusesLeavesWhatRunsAsItIs() async throws {
        let rig = SourceFedRig(.spectrogram)
        rig.appear()
        await rig.running()
        await rig.send(0 ..< 2)
        // A hop of nought is no hop.
        rig.frame = AnalysisFrame(frame: 16, hop: 0, window: .hann)
        rig.evaluate()
        #expect(await eventually(timeout: patience) { rig.host.failures.count == 1 }, "the refusal is noted")
        guard case .invalidParameter? = rig.host.failures.first else {
            Issue.record("expected invalidParameter, got \(String(describing: rig.host.failures.first))")
            return
        }
        #expect(rig.host.session?.state == .running && rig.host.attaches == 1)
        await rig.send(2 ..< 4)
        #expect(rig.heatmap.rowCount == 9 && rig.heatmap.columnCount == 4, "the frame that ran goes on running")
        // The refused frame is not sent again; a valid one is.
        let sent = rig.host.updates.count
        rig.evaluate()
        await mainQueueDrained()
        #expect(rig.host.updates.count == sent && rig.host.failures.count == 1)
        rig.frame = AnalysisFrame(frame: 32, hop: 16, window: .hann)
        rig.evaluate()
        #expect(await eventually(timeout: patience) { rig.host.updates.count == sent + 1 })
        await rig.settled()
        rig.leave()
    }

    /// A view that appears with a frame the engine refuses stays empty, and attaches when
    /// the frame is one the engine takes.
    @Test func aViewWhoseFirstFrameIsRefusedAttachesWithTheNextOne() async throws {
        let rig = SourceFedRig(.spectrogram)
        rig.frame = AnalysisFrame(frame: 0, hop: 16, window: .hann)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.host.failures.count == 1 })
        #expect(rig.host.attaches == 0 && rig.host.session == nil && rig.heatmap.rowCount == 0 && !rig.isLive)
        rig.frame = AnalysisFrame(frame: 16, hop: 16, window: .hann)
        rig.evaluate()
        await rig.running()
        #expect(rig.host.attaches == 1 && rig.host.requests == 2)
        await rig.send(0 ..< 2)
        rig.leave()
    }

    /// Another source is another attachment, and another picture: the first attachment is
    /// ended, and the feed that held the first source's picture is let go.
    @Test(arguments: SourceFedKind.allCases)
    func anotherSourceIsAnotherAttachmentAndAnotherPicture(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind)
        rig.appear()
        await rig.running()
        await rig.send(0 ..< 3)
        let first = try #require(rig.host.session), before = rig.feed
        let other = rig.otherSource()
        rig.give(other)
        #expect(first.state == .detached && rig.host.detaches == 1, "the first attachment ended at once")
        #expect(rig.feed != before)
        await rig.running()
        #expect(rig.host.attaches == 2 && rig.host.session !== first && rig.host.failures.isEmpty && other.prepares == 1)
        #expect(rig.columnCount == 0, "the other source's picture starts empty")
        await rig.send(3 ..< 6)
        #expect(rig.columnCount == 3 * rig.itemsPerBlock, "what the other source delivers is what the feed gets")
        let unused = await SourceFedRig.isFree(rig.source), released = await SourceFedRig.isFree(before)
        #expect(unused, "the engine let go of the first source")
        #expect(released, "and of the feed that held its picture")
        // The same source again, a hundred times: nothing.
        for _ in 0 ..< 100 { rig.evaluate() }
        await mainQueueDrained()
        #expect(rig.host.attaches == 2 && rig.host.updates.isEmpty && rig.host.requests == 2)
        rig.leave()
    }

    /// The source may serve other attachments at the same time (ATT-6): the app's own
    /// pipeline on the same source and engine sees the same blocks, and outlives the view.
    @Test func theSourceServesOtherAttachmentsBesideTheViews() async throws {
        let rig = SourceFedRig(.spectrogram)
        let own = HeatmapFeed(history: 64)
        let session = try await rig.engine.attach(
            Pipeline<Samples, Samples>().tap { $0.appending(TestColumns(rows: 16, axis: .indices(count: 16))).emit(to: own) }, to: rig.source)
        try session.start()
        rig.appear()
        await rig.running()
        #expect(rig.source.prepares == 1, "the source is prepared once for both")
        await rig.send(0 ..< 5)
        #expect(await eventually(timeout: patience) { own.columnCount == 5 }, "every attachment sees the same blocks")
        #expect(rig.heatmap.columnCount == 5)
        let feed = rig.heatmap
        rig.leave()
        #expect(session.state == .running, "the view's leaving ends the view's attachment only")
        #expect(rig.source.write(SourceFedRig.blocks(5 ..< 7)) == 32)
        #expect(await eventually(timeout: patience) { own.columnCount == 7 })
        #expect(feed.columnCount == 5, "nothing writes the view's feed any more")
        session.detach()
    }

    // MARK: Whatever happens while a plan is compiled (VC-3)

    /// While an attachment is on its way nothing else is asked of an engine: a view that is
    /// given another source meanwhile attaches to it once the first attachment has landed
    /// and has been let go, and ends with that one attachment.
    @Test(arguments: SourceFedKind.allCases)
    func aSourceThatChangesWhileAnAttachmentIsOnItsWayEndsWithOneAttachment(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind, open: false)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.source.prepares == 1 }, "the attachment is on its way: the engine prepares the source")
        #expect(rig.host.requests == 1 && rig.host.attaches == 0)
        // The view is given another source.
        let other = rig.otherSource(), before = rig.feed
        rig.give(other)
        #expect(rig.host.requests == 1 && other.prepares == 0, "the engine is not asked again while the first attachment is on its way")
        rig.source.open()
        await rig.running()
        #expect(rig.host.requests == 2 && rig.host.attaches == 1 && rig.render.attaches == 1, "one attachment: the one asked for last")
        #expect(rig.host.failures.isEmpty && rig.host.detaches == 0)
        #expect(rig.host.late == [.detached], "the attachment that came too late was detached before the next one was asked for")
        #expect(other.prepares == 1 && rig.source.prepares == 1)
        await rig.send(0 ..< 3)
        #expect(rig.columnCount == 3 * rig.itemsPerBlock, "on the source asked for last")
        let unused = await SourceFedRig.isFree(rig.source), released = await SourceFedRig.isFree(before), claimed = await SourceFedRig.isFree(rig.feed)
        #expect(unused && released, "the attachment that came too late was let go: nothing is left on the first source, nor on its feed")
        #expect(!claimed, "and the view's feed has its one writer")
        rig.leave()
    }

    /// The same when the view keeps its feed: a view that leaves and comes back at once, or
    /// is given another engine, while its attachment is on its way asks for the next one only
    /// when the first has landed and has let go of the feed, which the next one writes.
    @Test func anAttachmentThatWouldWriteTheSameFeedWaitsForTheOneOnItsWay() async throws {
        let rig = SourceFedRig(.spectrogram, open: false)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.source.prepares == 1 })
        // The same pipeline, into the same feed, on another source.
        let other = rig.otherSource()
        rig.model.show(rig.pipeline, on: other, engine: rig.engine)
        #expect(rig.host.requests == 1 && other.prepares == 0, "the engine is not asked again while the first attachment is on its way")
        rig.source.open()
        await rig.running()
        #expect(rig.host.requests == 2 && rig.host.attaches == 1 && rig.host.failures.isEmpty, "the feed was free for it: the one that came too late was let go first")
        #expect(rig.host.late == [.detached])
        #expect(other.write(SourceFedRig.blocks(0 ..< 2)) == 32)
        #expect(await eventually(timeout: patience) { rig.columnCount == 2 })
        rig.leave()
    }

    /// A view that appears and leaves at once keeps no attachment: the one that arrives late
    /// is let go, its claim on the feed with it.
    @Test(arguments: SourceFedKind.allCases)
    func aViewThatLeavesWhileItsAttachmentIsOnItsWayKeepsNone(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind, open: false)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.source.prepares == 1 })
        let feed = rig.feed
        rig.leave()
        rig.source.open()
        #expect(await eventuallyAwaiting { await SourceFedRig.isFree(rig.source) }, "the late attachment was ended: the engine let go of the source")
        let released = await SourceFedRig.isFree(feed)
        #expect(released, "and of the feed")
        #expect(rig.host.attaches == 0 && rig.host.detaches == 0 && rig.host.session == nil && rig.host.requests == 1 && rig.host.failures.isEmpty)
        #expect(rig.host.late == [.detached], "it arrived, too late, and was detached")
        #expect(!feed.isLive && !rig.isLive)
    }

    /// A view that leaves and comes back while its attachment is on its way ends with one.
    @Test(arguments: SourceFedKind.allCases)
    func aViewThatLeavesAndComesBackWhileItsAttachmentIsOnItsWayEndsWithOne(kind: SourceFedKind) async throws {
        let rig = SourceFedRig(kind, open: false)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.source.prepares == 1 })
        rig.leave()
        rig.appear()
        rig.leave()
        rig.appear()
        #expect(rig.host.requests == 1, "one attachment on its way, whatever the view did meanwhile")
        rig.source.open()
        await rig.running()
        #expect(rig.host.requests == 2 && rig.host.attaches == 1 && rig.host.detaches == 0 && rig.host.failures.isEmpty)
        #expect(rig.host.late == [.detached], "one attachment was on its way, and came too late for the view that asked for it")
        await rig.send(0 ..< 2)
        #expect(rig.columnCount == 2 * rig.itemsPerBlock)
        let feed = rig.feed
        rig.leave()
        #expect(rig.host.detaches == 1)
        let released = await SourceFedRig.isFree(feed)
        #expect(released)
    }

    /// An analysis value that changes while the attachment is on its way: the attachment
    /// lands, and the newest value is sent as one update. What lay between is dropped.
    @Test func anAnalysisValueThatChangesWhileTheAttachmentIsOnItsWayIsSentOnce() async throws {
        let rig = SourceFedRig(.spectrogram, open: false)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.source.prepares == 1 })
        for frame in [32, 64, 128] {
            rig.frame = AnalysisFrame(frame: frame, hop: 16, window: .hann)
            rig.evaluate()
        }
        #expect(rig.host.requests == 1 && rig.host.updates.isEmpty)
        rig.source.open()
        await rig.running()
        #expect(await eventually(timeout: patience) { rig.host.updates.count == 1 }, "the newest value is sent when the attachment has landed")
        await rig.settled()
        #expect(rig.host.attaches == 1 && rig.host.requests == 1 && rig.host.failures.isEmpty)
        let block = SourceFedRig.blocks(0 ..< 1)
        #expect(await eventually(timeout: patience) {
            rig.source.write(block)
            return rig.heatmap.rowCount == 65 && rig.heatmap.columnCount >= 1
        }, "the session runs the newest frame: 128 samples, 65 rows")
        #expect(rig.host.updates.count == 1)
        rig.leave()
    }

    /// Another engine while the attachment is on its way: the view ends with one attachment,
    /// on the engine asked for last.
    @Test func anEngineThatChangesWhileTheAttachmentIsOnItsWayEndsWithOneAttachment() async throws {
        let rig = SourceFedRig(.spectrogram, open: false)
        rig.appear()
        #expect(await eventually(timeout: patience) { rig.source.prepares == 1 })
        rig.use(DSPEngine(blockSize: 32))
        #expect(rig.host.requests == 1)
        rig.source.open()
        await rig.running()
        #expect(rig.host.attaches == 1 && rig.host.requests == 2 && rig.host.failures.isEmpty)
        #expect(rig.host.late == [.detached], "the first engine's attachment was detached, and its source let go, before the other engine was asked")
        #expect(rig.host.session?.environment.blockSize == 32, "on the engine asked for last")
        #expect(rig.source.prepares == 2, "each engine prepares the source it attaches to")
        let feed = rig.feed
        rig.leave()
        let released = await SourceFedRig.isFree(feed), unused = await SourceFedRig.isFree(rig.source)
        #expect(released && unused)
    }

    /// Another engine for a view whose attachment has landed: detached from the first, then
    /// attached on the other.
    @Test func anotherEngineIsAnotherAttachment() async throws {
        let rig = SourceFedRig(.spectrogram)
        rig.appear()
        await rig.running()
        let first = try #require(rig.host.session)
        rig.use(DSPEngine(blockSize: 32))
        #expect(first.state == .detached)
        await rig.running()
        #expect(rig.host.attaches == 2 && rig.host.detaches == 1 && rig.host.session?.environment.blockSize == 32 && rig.host.failures.isEmpty)
        rig.leave()
    }

    /// An update that is on its way when the view is given another source: the view ends
    /// with one attachment, on the other source, running the pipeline asked for last.
    @Test func aSourceThatChangesWhileAnUpdateIsOnItsWayEndsWithOneAttachment() async throws {
        let rig = SourceFedRig(.spectrogram)
        rig.appear()
        await rig.running()
        rig.frame = AnalysisFrame(frame: 64, hop: 16, window: .hann)
        rig.evaluate()
        #expect(rig.host.updates.count == 1)
        rig.frame = AnalysisFrame(frame: 32, hop: 16, window: .hann)
        rig.give(rig.otherSource())
        await rig.settled()
        await rig.running()
        #expect(rig.host.attaches == 2 && rig.host.detaches == 1 && rig.host.failures.isEmpty)
        #expect(rig.heatmap.rowCount == 17 && rig.heatmap.environment?.frameSize == 32, "the frame asked for last")
        // A frame of 32 samples, 16 apart: three blocks hold two frames.
        #expect(rig.currentSource.write(SourceFedRig.blocks(0 ..< 3)) == 48)
        #expect(await eventually(timeout: patience) { rig.columnCount == 2 }, "on the source given last")
        #expect(rig.host.updates.count == 1, "attached with it: no update was needed")
        rig.leave()
    }
}
