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

/// The source-fed components in a real SwiftUI hierarchy, hosted in a window of the test
/// process (WP-814, WP-815): one view shows a mock, a file and a processed signal; the
/// attachment follows the view's life; evaluating the parent again attaches nothing new; the
/// analysis modifiers reach the session through the environment; and everything a feed-driven
/// component does with its appearance, its axes, a pinch and its size, a source-fed one does
/// too. And the second pipeline host (WP-817): `.processing(_:)` animates as
/// `.pipeline(_:on:)` does.
///
/// This is hosting without an application. The hosted suite of the Examples project repeats
/// the scenarios of §8.4 inside one.
@MainActor
@Suite("Source-fed components, hosted in the test process")
struct HostedSourceFedTests {
    /// The component of `kind` on `source`.
    @ViewBuilder
    private static func view(_ component: SourceComponent, of source: any SampleSource) -> some View {
        switch component {
        case .spectrogram: SpectrogramView(source: source)
        case .chromagram: ChromagramView(source: source)
        case .tempogram: TempogramView(source: source)
        case .waveform: WaveformView(source: source)
        }
    }

    // MARK: One view shows a mock, a file and a processed signal (SRC-3)

    /// Three sources for one component, and what its feed reads for each: a row, a tempo, a
    /// reach.
    private struct Trio {
        let sources: [any SampleSource]
        let expected: [Double]
        let tolerance: Double
        let reading: @MainActor (SourceWatch) -> Double?

        @MainActor
        init(_ component: SourceComponent, files: ToneFiles) throws {
            switch component {
            case .spectrogram:
                sources = [
                    Tone.mock(Tone.sine(3_000, seconds: 0.5)),
                    try files.source(Tone.sine(6_000, seconds: 0.5)),
                    Tone.mock(Tone.pair(low: 110, high: 9_000, seconds: 0.5)).processed(by: Tone.highPass(2_000)),
                ]
                expected = [3_000, 6_000, 9_000].map { Double(Tone.bin(of: $0)) }
                tolerance = 0
                reading = { watch in (watch.heatmap?.snapshot().strongestRow).map(Double.init) }
            case .chromagram:
                sources = [
                    Tone.mock(Tone.sine(440, seconds: 2)),
                    try files.source(Tone.sine(523.25, seconds: 2)),
                    Tone.mock(Tone.pair(low: 110, high: 1_318.51, seconds: 2)).processed(by: Tone.highPass(600)),
                ]
                expected = [9, 0, 4]
                tolerance = 0
                reading = { watch in (watch.heatmap?.snapshot().strongestRow).map(Double.init) }
            case .tempogram:
                sources = [
                    Tone.mock(Tone.clicks(hopsPerBeat: 45, seconds: 8)),
                    try files.source(Tone.clicks(hopsPerBeat: 60, seconds: 8)),
                    Tone.mock(Tone.clicks(hopsPerBeat: 50, seconds: 8)).processed(by: Pipeline { Gain(.decibels(-6)) }),
                ]
                expected = [45, 60, 50].map(Tone.tempo(hopsPerBeat:))
                tolerance = 1
                reading = { watch in
                    guard let snapshot = watch.heatmap?.snapshot(), let axis = snapshot.axis, snapshot.columnCount > 0 else { return nil }
                    return axis.value(ofRow: snapshot.strongestRow)
                }
            case .waveform:
                sources = [
                    Tone.mock(Tone.sine(3_000, seconds: 0.5)),
                    try files.source(Tone.sine(3_000, seconds: 0.5, amplitude: 0.25)),
                    Tone.mock(Tone.sine(3_000, seconds: 0.5)).processed(by: Pipeline { Gain(.decibels(-20)) }),
                ]
                expected = [0.5, 0.25, 0.05]
                tolerance = 0.005
                reading = { watch in (watch.waveform?.snapshot().reach(newest: 16)).map(Double.init) }
            }
        }
    }

    /// The acceptance of WP-814 and WP-815: one view, given a mock, then a file, then a
    /// processed signal, shows each. Every source is one attachment, which ends when the next
    /// one is given; the Metal view stays, and its texture is cleared for each new picture.
    @Test(arguments: SourceComponent.allCases)
    func oneViewShowsAMockAFileAndAProcessedSignal(component: SourceComponent) async throws {
        let files = try ToneFiles()
        let trio = try Trio(component, files: files)
        let watch = SourceWatch(), handle = StateHandle<Int>()
        let sources = trio.sources
        let hosted = watch.host(0, handle) { index in
            Self.view(component, of: sources[index.wrappedValue])
        }
        defer { hosted.close() }
        var uploaded = 0
        for (index, name) in ["a mock", "a file", "a processed signal"].enumerated() {
            if index > 0 { handle.set(index) }
            #expect(await eventually(timeout: patience) { watch.host.attaches == index + 1 && watch.host.session?.state == .finished }, "\(name) was attached and played to its end: \(watch.host.failures)")
            #expect(watch.host.detaches == index && watch.host.requests == index + 1 && watch.host.failures.isEmpty, "\(name): one attachment at a time")
            let reading = try #require(trio.reading(watch), "\(name)")
            expectClose(reading, trio.expected[index], .absolute(trio.tolerance + 1e-9), "\(name): the feed holds it")
            // The surface shows what the feed holds.
            let columns = watch.columnCount
            #expect(columns > 0)
            uploaded += columns
            #expect(await eventually(timeout: patience) { watch.probe.uploadedColumns == uploaded }, "\(name): every column was drawn: \(watch.probe.uploadedColumns) of \(uploaded)")
            #expect(watch.probe.makes == 1, "\(name): the same Metal view")
            #expect(watch.probe.clears == index, "\(name): the picture before it was cleared once")
            #expect(watch.probe.attaches == index + 1)
        }
        #expect(watch.host.updates.isEmpty, "another source is another attachment, not an update")
    }

    // MARK: The attachment follows the view's life (VC-3)

    struct Life: Equatable {
        var counter = 0
        var shown = true
    }

    /// Appear: one attachment, on the engine of the environment. A hundred evaluations of
    /// the parent: no new attachment, no update, no renderer update, no draw, no axis drawn
    /// again. Disappear: detached. Back again: a new attachment and a new picture.
    @Test(arguments: SourceComponent.allCases)
    func theAttachmentFollowsTheViewsLife(component: SourceComponent) async throws {
        let watch = SourceWatch(blockSize: 64), source = GatedSource(), handle = StateHandle<Life>()
        let evaluations = Box(0)
        let hosted = watch.host(Life(), handle) { life in
            let _ = evaluations.value += 1
            VStack {
                Text("\(life.wrappedValue.counter)")
                if life.wrappedValue.shown {
                    Self.view(component, of: source).axis(.frequency).axis(.time)
                }
            }
        }
        defer { hosted.close() }
        await watch.settled()
        let session = try #require(watch.host.session)
        #expect(watch.host.attaches == 1 && watch.probe.attaches == 1 && watch.host.requests == 1 && source.prepares == 1, "one attachment")
        #expect(session.environment.blockSize == 64 && session.environment.sampleRate == 48_000, "on the engine of the environment, at the source's format")
        #expect(watch.probe.makes == 1)
        #expect(await eventually(timeout: patience) { watch.axes.draws >= (component == .waveform ? 1 : 2) }, "the axes are labelled from the feed the view owns")
        await displayFrames(3)

        // The parent's body runs a hundred times with the same source.
        let draws = watch.probe.draws, axisDraws = watch.axes.draws, before = evaluations.value
        var life = Life()
        for step in 1 ... 100 {
            life.counter = step
            handle.set(life)
            let seen = evaluations.value
            #expect(await eventually(timeout: patience) { evaluations.value > seen })
        }
        await displayFrames(3)
        #expect(evaluations.value >= before + 100 && handle.value?.counter == 100, "the parent's body ran a hundred times")
        #expect(watch.host.attaches == 1 && watch.probe.attaches == 1 && watch.host.requests == 1 && source.prepares == 1, "0 new attachments")
        #expect(watch.host.updates.isEmpty && watch.host.session === session && session.state == .running, "0 updates of the session")
        #expect(watch.probe.updates == 0 && watch.probe.makes == 1, "0 renderer updates")
        #expect(watch.probe.draws == draws, "0 draws")
        #expect(watch.axes.draws == axisDraws, "no axis was drawn again")

        // The view leaves the hierarchy.
        let feed = try #require(watch.inspector.contents.last?.feed)
        life.shown = false
        handle.set(life)
        #expect(await eventually(timeout: patience) { watch.host.detaches == 1 })
        #expect(session.state == .detached && watch.host.session == nil)
        #expect(await eventually(timeout: patience) { !feed.isLive })
        let released = await SourceFedRig.isFree(feed)
        #expect(released, "the claim on the view's feed ended with the attachment")

        // It comes back: a new attachment, and a new picture.
        life.shown = true
        handle.set(life)
        #expect(await eventually(timeout: patience) { watch.host.attaches == 2 && watch.host.session?.state == .running })
        #expect(watch.host.session !== session && watch.host.detaches == 1 && watch.host.failures.isEmpty)
        #expect(await eventually(timeout: patience) { watch.inspector.contents.last.map { $0.feed != feed } ?? false }, "another feed: what the view showed before it left is not continued")
    }

    /// A view that leaves the hierarchy and keeps its state, a tab that is not shown: its
    /// attachment ends, and when it comes back it attaches anew, in one go, and starts an
    /// empty picture in the Metal view it had.
    @Test func aViewInATabDetachesWhenItIsHiddenAndStartsAnEmptyPictureWhenItComesBack() async throws {
        let watch = SourceWatch(blockSize: 16), source = GatedSource(), handle = StateHandle<Int>()
        let hosted = watch.host(0, handle, size: CGSize(width: 320, height: 480)) { tab in
            TabView(selection: tab) {
                SpectrogramView(source: source).analysisFrame(16, hop: 16).tag(0)
                Color.clear.tag(1)
            }
        }
        defer { hosted.close() }
        await watch.settled()
        let first = try #require(watch.heatmap), session = try #require(watch.host.session)
        #expect(source.write(SourceFedRig.blocks(0 ..< 4)) == 64)
        #expect(await eventually(timeout: patience) { first.columnCount == 4 && watch.probe.uploadedColumns == 4 })

        // The other tab: the view leaves the hierarchy, and keeps its state.
        handle.set(1)
        #expect(await eventually(timeout: patience) { watch.host.detaches == 1 })
        #expect(session.state == .detached && watch.host.attaches == 1 && watch.host.requests == 1)
        #expect(await eventually(timeout: patience) { !first.isLive })
        let released = await SourceFedRig.isFree(.heatmap(first))
        #expect(released, "the claim on the feed ended with the attachment")

        // Back again.
        handle.set(0)
        #expect(await eventually(timeout: patience) { watch.host.attaches == 2 && watch.host.session?.state == .running }, "\(watch.host.failures)")
        let second = try #require(watch.heatmap)
        #expect(second !== first && second.columnCount == 0, "another feed: what the view showed before it left is not continued")
        #expect(watch.host.requests == 2 && watch.host.updates.isEmpty && watch.host.failures.isEmpty, "attached in one go, into the feed it shows")
        #expect(watch.probe.makes == 1, "in the Metal view it had")
        #expect(await eventually(timeout: patience) { watch.probe.clears == 1 }, "whose texture was cleared once")
        #expect(source.write(SourceFedRig.blocks(4 ..< 7)) == 48)
        #expect(await eventually(timeout: patience) { second.columnCount == 3 && watch.probe.uploadedColumns == 7 }, "and shows what arrives now")
    }

    /// The same while the attachment is on its way: a view in a tab that is hidden and shown
    /// again before its attachment has landed asks the engine once more only when the first
    /// has landed, and ends with one attachment.
    @Test func aViewInATabHiddenAndShownWhileAttachingEndsWithOneAttachment() async throws {
        let watch = SourceWatch(blockSize: 16), source = GatedSource(open: false), handle = StateHandle<Int>()
        let hosted = watch.host(0, handle, size: CGSize(width: 320, height: 480)) { tab in
            TabView(selection: tab) {
                SpectrogramView(source: source).analysisFrame(16, hop: 16).tag(0)
                Color.clear.tag(1)
            }
        }
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { source.prepares == 1 && watch.host.requests == 1 }, "the attachment is on its way")
        let contents = watch.inspector.contents.count
        handle.set(1)
        #expect(await eventually(timeout: patience) { watch.inspector.contents.count > contents }, "the view left: it shows the feed of the time it comes back")
        handle.set(0)
        await displayFrames(6)
        #expect(watch.host.requests == 1 && watch.host.attaches == 0, "the engine is not asked again while the first attachment is on its way")
        source.open()
        await watch.settled()
        #expect(watch.host.requests == 2 && watch.host.attaches == 1 && watch.host.detaches == 0 && watch.host.failures.isEmpty && watch.host.updates.isEmpty)
        let feed = try #require(watch.heatmap)
        #expect(source.write(SourceFedRig.blocks(0 ..< 3)) == 48)
        #expect(await eventually(timeout: patience) { feed.columnCount == 3 }, "the one attachment writes the feed the view shows")
    }

    /// A view that is not given `.dspEngine(_:)` attaches on `DSPEngine.shared`; another
    /// engine in the environment is another attachment, on that engine (VC-3).
    @Test func aSourceFedViewAttachesOnTheEngineOfTheEnvironment() async throws {
        let source = GatedSource(), probe = PipelineHostProbe(), other = DSPEngine(blockSize: 32)
        let handle = StateHandle<Bool>()
        let hosted = Hosted(Stateful(false, handle) { named in
            if named.wrappedValue {
                WaveformView(source: source).dspEngine(other).environment(\.dspPipelineHostProbe, probe)
            } else {
                WaveformView(source: source).environment(\.dspPipelineHostProbe, probe)
            }
        })
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { probe.session?.state == .running })
        #expect(probe.session?.environment.blockSize == DSPEngine.shared.blockSize && DSPEngine.shared.blockSize == 512, "the shared engine")
        #expect(probe.attaches == 1)
        handle.set(true)
        #expect(await eventually(timeout: patience) { probe.attaches == 2 && probe.session?.state == .running })
        #expect(probe.session?.environment.blockSize == 32 && probe.detaches == 1 && probe.failures.isEmpty, "the engine `.dspEngine(_:)` names")
    }

    /// The same view, kept, with another engine in its environment: detached from the first
    /// engine and attached on the other, into the feed it has.
    @Test func anotherEngineInTheEnvironmentIsAnotherAttachment() async throws {
        let watch = SourceWatch(blockSize: 16), source = GatedSource(), other = DSPEngine(blockSize: 32)
        let handle = StateHandle<Bool>()
        let probe = watch.probe, inspector = watch.inspector, host = watch.host, engine = watch.engine
        let hosted = Hosted(Stateful(false, handle) { named in
            SpectrogramView(source: source)
                .dspEngine(named.wrappedValue ? other : engine)
                .environment(\.dspRenderProbe, probe)
                .environment(\.dspSurfaceInspector, inspector)
                .environment(\.dspPipelineHostProbe, host)
        })
        defer { hosted.close() }
        await watch.settled()
        let first = try #require(watch.host.session), feed = try #require(watch.heatmap)
        #expect(first.environment.blockSize == 16)
        handle.set(true)
        #expect(await eventually(timeout: patience) { watch.host.attaches == 2 && watch.host.session?.state == .running }, "\(watch.host.failures)")
        #expect(first.state == .detached && watch.host.detaches == 1 && watch.host.failures.isEmpty)
        #expect(watch.host.session?.environment.blockSize == 32, "on the engine the environment names now")
        #expect(watch.heatmap === feed && watch.probe.makes == 1, "the view keeps its feed and its surface")
    }

    // MARK: The analysis modifiers (VC-4)

    struct Analysis: Equatable {
        var counter = 0
        var frame = 16
        var hop = 16
        var bands = 24
    }

    /// `.analysisFrame(_:hop:window:)` reaches the session through the environment; an equal
    /// value causes nothing; another one is one update of another topology, and the picture
    /// refills in its new shape.
    @Test func theAnalysisFrameReachesTheSessionAndAnotherOneIsOneUpdate() async throws {
        let watch = SourceWatch(blockSize: 16), source = GatedSource(), handle = StateHandle<Analysis>()
        let hosted = watch.host(Analysis(), handle) { analysis in
            // The modifier sits on a container, not on the component: the environment carries it.
            ZStack { SpectrogramView(source: source) }
                .analysisFrame(analysis.wrappedValue.frame, hop: analysis.wrappedValue.hop, window: .hamming)
        }
        defer { hosted.close() }
        await watch.settled()
        let session = try #require(watch.host.session), feed = try #require(watch.heatmap)
        #expect(feed.rowCount == 9 && feed.environment?.frameSize == 16 && feed.environment?.hopSize == 16, "the frame the modifier names is the one the session runs")
        let block = SourceFedRig.blocks(0 ..< 1)
        #expect(await eventually(timeout: patience) {
            source.write(block)
            return feed.columnCount >= 4
        })
        #expect(await eventually(timeout: patience) { watch.probe.uploadedColumns >= 4 })
        // The surface has taken the feed's nine rows by now: its texture is the feed's shape.
        let allocations = watch.probe.allocations
        let replans = Box(0)
        let events = session.events
        let listening = Task {
            for await event in events {
                if case .replanned = event { replans.value += 1 }
            }
        }
        defer { listening.cancel() }

        // The parent is evaluated again with an equal frame, made anew.
        var analysis = Analysis()
        for step in 1 ... 20 {
            analysis.counter = step
            handle.set(analysis)
            await displayFrames(1)
        }
        #expect(watch.host.updates.isEmpty && watch.host.attaches == 1 && watch.probe.updates == 0, "an equal value causes no update")

        // Another frame: one update, a new plan, 17 rows.
        analysis.frame = 32
        handle.set(analysis)
        #expect(await eventually(timeout: patience) { watch.host.updates.count == 1 })
        #expect(await eventually(timeout: patience) {
            source.write(block)
            return replans.value == 1 && feed.rowCount == 17 && feed.columnCount >= 2
        }, "a plan of another topology took over at a block boundary, and the feed refills")
        #expect(feed.environment?.frameSize == 32)
        #expect(watch.host.updates.count == 1 && watch.host.attaches == 1 && watch.host.session === session && watch.host.failures.isEmpty)
        #expect(watch.heatmap === feed && watch.probe.makes == 1, "the same feed in the same Metal view")
        #expect(await eventually(timeout: patience) { watch.probe.allocations == allocations + 1 }, "whose data texture is allocated once more, for the other number of bins (V-6)")
        #expect(watch.probe.updates == 0, "the surface was told nothing")

        // Another hop: one more update.
        analysis.hop = 8
        handle.set(analysis)
        #expect(await eventually(timeout: patience) { watch.host.updates.count == 2 })
        #expect(await eventually(timeout: patience) {
            source.write(block)
            return feed.environment?.hopSize == 8
        })
        #expect(watch.host.attaches == 1)
    }

    /// `.melBands(_:)` reaches the session of a tempogram through the environment, and
    /// another number of bands is one update of another topology.
    @Test func theMelBandsReachTheSessionOfATempogram() async throws {
        let watch = SourceWatch(blockSize: 64), source = GatedSource(), handle = StateHandle<Analysis>()
        let hosted = watch.host(Analysis(frame: 256, hop: 64), handle) { analysis in
            TempogramView(source: source)
                .melBands(analysis.wrappedValue.bands)
                .analysisFrame(analysis.wrappedValue.frame, hop: analysis.wrappedValue.hop)
        }
        defer { hosted.close() }
        // 24 bands fit a frame of 256 samples; the 128 the view runs without the modifier
        // do not, and the engine would have refused them.
        await watch.settled()
        #expect(watch.host.attaches == 1 && watch.host.failures.isEmpty)
        let feed = try #require(watch.heatmap)
        #expect(feed.environment?.featureRate == 750, "the frame reached the mel spectrogram: 64 samples a hop")
        var analysis = Analysis(frame: 256, hop: 64)
        analysis.bands = 16
        handle.set(analysis)
        #expect(await eventually(timeout: patience) { watch.host.updates.count == 1 }, "another number of bands is one update")
        #expect(await eventually(timeout: patience) { watch.host.isIdle })
        analysis.bands = 128
        handle.set(analysis)
        #expect(await eventually(timeout: patience) { watch.host.failures.count == 1 }, "a number of bands the frame cannot fill is refused, and noted")
        guard case .invalidParameter(_, let parameter, _)? = watch.host.failures.first else {
            Issue.record("expected invalidParameter, got \(String(describing: watch.host.failures.first))")
            return
        }
        #expect(parameter == "bands" && watch.host.session?.state == .running && watch.host.attaches == 1, "what ran before goes on running")
    }

    /// The three spellings of `.processing(_:)` each put their pipeline in front of the
    /// recipe: a pipeline value, a block of sequence stages, a block with a tap of its own.
    @Test func everySpellingOfProcessingPutsItsPipelineInFront() async throws {
        let quiet = Pipeline<Samples, Samples> { Gain(.decibels(-20)) }
        let own = WaveformFeed(history: 256)
        let watches = (0 ..< 4).map { _ in SourceWatch() }
        let sources = (0 ..< 4).map { _ in Tone.mock(Tone.sine(3_000, seconds: 0.5)) }
        func watched(_ view: some View, _ index: Int) -> some View {
            view.environment(\.dspRenderProbe, watches[index].probe).environment(\.dspSurfaceInspector, watches[index].inspector)
                .environment(\.dspPipelineHostProbe, watches[index].host)
        }
        let engine = DSPEngine()
        let hosted = Hosted(Stateful(0, StateHandle<Int>()) { _ in
            VStack(spacing: 0) {
                watched(WaveformView(source: sources[0]), 0)
                watched(WaveformView(source: sources[1]).processing(quiet), 1)
                watched(WaveformView(source: sources[2]).processing { Gain(.decibels(-20)) }, 2)
                watched(WaveformView(source: sources[3]).processing {
                    Gain(.decibels(-20))
                    Tap {
                        Waveform()
                        Emit(to: own)
                    }
                    Gain(.decibels(-20))
                }, 3)
            }
            .dspEngine(engine)
        })
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { watches.allSatisfy { $0.host.session?.state == .finished } }, "\(watches.map { $0.host.failures })")
        func reach(_ index: Int) -> Float { watches[index].waveform?.snapshot().reach(newest: 16) ?? .nan }
        expectClose(reach(0), 0.5, .absolute(0.005), "no processing: the raw signal")
        expectClose(reach(1), 0.05, .absolute(0.002), "a pipeline value")
        expectClose(reach(2), 0.05, .absolute(0.002), "a block of sequence stages")
        expectClose(reach(3), 0.005, .absolute(0.000_5), "a block with a tap: both gains lie in front of the recipe")
        expectClose(own.snapshot().reach(newest: 16), 0.05, .absolute(0.002), "and the tap's own feed took the signal where it stands")
        #expect(watches.allSatisfy { $0.host.attaches == 1 && $0.host.updates.isEmpty && $0.host.failures.isEmpty })
    }

    /// The modifier nearest to a component is the one it reads, and one modifier serves
    /// every source-fed component inside it, each with a copy of its own (ATT-1).
    @Test func oneProcessingServesEveryComponentInsideIt() async throws {
        let wave = SourceWatch(), spectrum = SourceWatch(), inner = SourceWatch()
        let sources = (0 ..< 3).map { _ in Tone.mock(Tone.sine(3_000, seconds: 0.5)) }
        func watched(_ view: some View, _ watch: SourceWatch) -> some View {
            view.environment(\.dspRenderProbe, watch.probe).environment(\.dspSurfaceInspector, watch.inspector).environment(\.dspPipelineHostProbe, watch.host)
        }
        let engine = DSPEngine()
        let hosted = Hosted(Stateful(0, StateHandle<Int>()) { _ in
            VStack(spacing: 0) {
                watched(WaveformView(source: sources[0]), wave)
                watched(SpectrogramView(source: sources[1]), spectrum)
                watched(WaveformView(source: sources[2]).processing { Gain(.decibels(-40)) }, inner)
            }
            .processing { Gain(.decibels(-20)) }
            .dspEngine(engine)
        })
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { [wave, spectrum, inner].allSatisfy { $0.host.session?.state == .finished } })
        expectClose(wave.waveform?.snapshot().reach(newest: 16) ?? .nan, 0.05, .absolute(0.002), "the waveform of the processed signal")
        expectClose(spectrum.heatmap?.snapshot().newest(row: Tone.bin(of: 3_000)) ?? .nan, -26.02, .absolute(0.1), "the spectrogram of the processed signal")
        expectClose(inner.waveform?.snapshot().reach(newest: 16) ?? .nan, 0.005, .absolute(0.000_5), "the nearest modifier wins")
        #expect([wave, spectrum, inner].allSatisfy { $0.host.attaches == 1 && $0.host.failures.isEmpty })
    }

    // MARK: What a feed-driven component does, a source-fed one does too (§8.1)

    /// Feeds the spectrogram of a hand-fed source at 48 kHz, a frame of 512 samples and 480
    /// of them a block, which is 100 columns a second, exactly `columns` columns, and waits
    /// until the surface shows them and has nothing more to draw.
    private func liveSpectrogram(_ watch: SourceWatch, _ source: GatedSource, columns: Int) async throws -> HeatmapFeed {
        await watch.settled()
        let feed = try #require(watch.heatmap)
        // The first frame is whole with the second block; every block after it is one more.
        let samples = [Float](repeating: 0.25, count: 480 * (columns + 1))
        #expect(source.write(samples) == samples.count, "the ring took every frame")
        #expect(await eventually(timeout: patience) { feed.columnCount == columns })
        #expect(await eventually(timeout: patience) { watch.probe.uploadedColumns == columns }, "the picture follows the feed")
        await watch.settled()
        return feed
    }

    struct Look: Equatable {
        var magma = false
        var range: ClosedRange<Float> = -80 ... -10
        var frequencies: ClosedRange<Double> = 100 ... 8_000
        var span = 2.0
    }

    /// Every appearance modifier reaches the renderer of a source-fed view; a change is one
    /// draw and no upload, and nothing for the session.
    @Test func everyAppearanceModifierWorksOnASourceFedView() async throws {
        let watch = SourceWatch(blockSize: 480), source = GatedSource(), handle = StateHandle<Look>()
        let hosted = watch.host(Look(), handle) { look in
            SpectrogramView(source: source)
                .analysisFrame(512, hop: 480)
                .colorMap(look.wrappedValue.magma ? ListedColorMap.magma : ListedColorMap.viridis)
                .valueRange(look.wrappedValue.range)
                .frequencyScale(LogarithmicFrequencyScale())
                .frequencyRange(look.wrappedValue.frequencies)
                .timeSpan(look.wrappedValue.span)
                .maximumFrameRate(30)
        }
        defer { hosted.close() }
        _ = try await liveSpectrogram(watch, source, columns: 8)
        var expected = HeatmapAppearance()
        expected.valueRange = -80 ... -10
        expected.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale())
        expected.rowRange = 100 ... 8_000
        expected.timeSpan = 2
        #expect(watch.inspector.heatmap == expected, "what the modifiers say is what the renderer shows")
        #expect(watch.probe.updates == 0)

        var look = Look()
        func change(_ what: String, _ edit: (inout Look) -> Void, _ expect: (inout HeatmapAppearance) -> Void) async {
            let updates = watch.probe.updates, draws = watch.probe.draws, uploads = watch.probe.uploads
            edit(&look)
            handle.set(look)
            #expect(await eventually(timeout: patience) { watch.probe.updates == updates + 1 }, "\(what) reached the surface")
            expect(&expected)
            #expect(watch.inspector.heatmap == expected, "\(what)")
            #expect(await eventually(timeout: patience) { watch.probe.draws == draws + 1 }, "\(what) is one draw")
            await displayFrames(2)
            #expect(watch.probe.draws == draws + 1 && watch.probe.uploads == uploads && watch.probe.updates == updates + 1, "\(what): exactly one draw, no upload")
        }
        await change("colour map", { $0.magma = true }, { $0.colorMap = AnyColorMap(ListedColorMap.magma) })
        await change("value range", { $0.range = -60 ... 0 }, { $0.valueRange = -60 ... 0 })
        await change("frequency range", { $0.frequencies = 200 ... 4_000 }, { $0.rowRange = 200 ... 4_000 })
        await change("time span", { $0.span = 1 }, { $0.timeSpan = 1 })
        #expect(watch.host.updates.isEmpty && watch.host.attaches == 1, "appearance is nothing to the session")
    }

    /// A waveform on a source takes its amplitude range, and a chromagram and a tempogram on
    /// a source start from the defaults of their kind. Four views on one source are four
    /// attachments, each into a feed of its own (ATT-6).
    @Test func eachSourceFedComponentStartsFromItsOwnDefaults() async throws {
        let source = GatedSource()
        let watches = (0 ..< 4).map { _ in SourceWatch() }
        func watched(_ view: some View, _ index: Int) -> some View {
            view.environment(\.dspRenderProbe, watches[index].probe).environment(\.dspSurfaceInspector, watches[index].inspector)
                .environment(\.dspPipelineHostProbe, watches[index].host)
        }
        let engine = DSPEngine()
        let hosted = Hosted(Stateful(0, StateHandle<Int>()) { _ in
            VStack(spacing: 0) {
                watched(SpectrogramView(source: source), 0)
                watched(ChromagramView(source: source), 1)
                watched(TempogramView(source: source), 2)
                watched(WaveformView(source: source).amplitudeRange(-0.5 ... 0.5), 3)
            }
            .environment(\.colorScheme, .light)
            .dspEngine(engine)
        })
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { watches.allSatisfy { $0.host.session?.state == .running && $0.probe.draws >= 1 } }, "four attachments on one source, four surfaces drawn: \(watches.map { $0.host.failures })")
        #expect(source.prepares == 1, "the source is prepared once for all four")
        #expect(watches[0].inspector.heatmap == HeatmapAppearance())
        var chroma = HeatmapAppearance()
        chroma.valueRange = 0 ... 1
        chroma.rowInterpolation = .nearest
        #expect(watches[1].inspector.heatmap == chroma, "a chromagram: cells with hard edges, values from 0 to 1")
        var tempo = HeatmapAppearance()
        tempo.valueRange = 0 ... 1
        #expect(watches[2].inspector.heatmap == tempo)
        #expect(watches[3].inspector.waveform?.amplitudeRange == -0.5 ... 0.5 && watches[3].inspector.waveform?.fill == .black)
        // Each view owns a feed of its own, with the history of its kind.
        #expect(watches[0].heatmap?.history == 1_024 && watches[1].heatmap?.history == 1_024 && watches[2].heatmap?.history == 1_024 && watches[3].waveform?.history == 2_048)
        #expect(watches[0].heatmap !== watches[1].heatmap && watches[1].heatmap !== watches[2].heatmap)
        #expect(watches[0].heatmap?.axis == .linearFrequency(binCount: 1_025, nyquist: 24_000) && watches[1].heatmap?.axis == .pitchClasses)
    }

    /// `.axis(_:)` on a source-fed view: the axes are labelled from the feed the view owns,
    /// once its session has given it a shape, and are not drawn again when data arrives.
    @Test func axesOfASourceFedViewAreLabelledFromItsFeedAndNotRedrawnByData() async throws {
        let watch = SourceWatch(blockSize: 480), source = GatedSource(), handle = StateHandle<Int>()
        let hosted = watch.host(0, handle, size: CGSize(width: 300, height: 200)) { _ in
            SpectrogramView(source: source)
                .analysisFrame(512, hop: 480)
                .frame(width: 244, height: 120)
                .axis(.frequency)
                .axis(.time)
        }
        defer { hosted.close() }
        let feed = try await liveSpectrogram(watch, source, columns: 4)
        #expect(await eventually(timeout: patience) { watch.axes.draws >= 2 })
        await displayFrames(4)
        // The frequency axis to the left, 44 points wide, and the time axis below, 20 points
        // high, beside a picture of what is left.
        #expect(watch.axes.sizes.contains(CGSize(width: 44, height: 100)) && watch.axes.sizes.contains(CGSize(width: 200, height: 20)), "\(watch.axes.sizes)")
        #expect(feed.axis == .linearFrequency(binCount: 257, nyquist: 24_000) && feed.environment?.featureRate == 100)
        // Data arrives for a while: the picture is drawn, the axes are left alone, and
        // nothing is evaluated again.
        let axisDraws = watch.axes.draws, draws = watch.probe.draws, uploaded = watch.probe.uploadedColumns
        let block = [Float](repeating: 0.25, count: 480)
        for _ in 0 ..< 20 {
            source.write(block)
            await displayFrames(1)
        }
        #expect(await eventually(timeout: patience) { watch.probe.uploadedColumns >= uploaded + 20 })
        #expect(watch.probe.draws > draws, "new data is drawn")
        #expect(watch.axes.draws == axisDraws, "and no axis is drawn again")
        #expect(watch.probe.updates == 0 && watch.host.updates.isEmpty && watch.host.attaches == 1)
    }

    /// A pinch on a source-fed view scales what is shown, never what is computed (PINCH-2):
    /// the time span follows the fingers, the view keeps it for a constant (PINCH-5), and the
    /// session is handed nothing.
    @Test func aPinchScalesWhatASourceFedViewShowsAndNotWhatItComputes() async throws {
        let watch = SourceWatch(blockSize: 480), source = GatedSource(), handle = StateHandle<Int>()
        let script = PinchScript()
        let hosted = watch.host(0, handle, size: CGSize(width: 320, height: 320)) { _ in
            SpectrogramView(source: source)
                .analysisFrame(512, hop: 480)
                .timeSpan(4)
                .pinchScaling(.horizontal)
                .frame(width: 200, height: 200)
                .environment(\.dspPinchScript, script)
        }
        defer { hosted.close() }
        // 100 columns a second and a history of 1 024 columns: a little over ten seconds.
        _ = try await liveSpectrogram(watch, source, columns: 4)
        #expect(await eventually(timeout: patience) { script.isHeard }, "with an axis enabled the surface listens")
        #expect(watch.inspector.heatmap?.timeSpan == 4)
        let uploads = watch.probe.uploads
        func fingers(_ reach: CGFloat) -> PinchSample {
            .touches(CGPoint(x: 100 - reach, y: 100), CGPoint(x: 100 + reach, y: 100))
        }
        script.feed(fingers(30))
        script.feed(fingers(60))
        #expect(await eventually(timeout: patience) { watch.inspector.heatmap?.timeSpan == 2 }, "twice the distance: half the span")
        script.end()
        await displayFrames(3)
        #expect(watch.inspector.heatmap?.timeSpan == 2, "the view keeps the scaled span for a constant")
        #expect(watch.probe.uploads == uploads, "nothing is uploaded (PINCH-7)")
        #expect(watch.host.updates.isEmpty && watch.host.attaches == 1 && watch.heatmap?.environment?.hopSize == 480, "and the session is as it was")
    }

    /// An animated appearance and an animated size on a source-fed view: interpolated values
    /// reach the renderer frame by frame, frames are drawn on the way, nothing is uploaded,
    /// and the session is handed nothing (ANI-1, §8.9).
    @Test func appearanceAndSizeAnimateOnASourceFedView() async throws {
        struct Motion: Equatable {
            var low: Float = -90
            var size = CGSize(width: 120, height: 80)
        }
        let watch = SourceWatch(blockSize: 480), source = GatedSource(), handle = StateHandle<Motion>()
        let hosted = watch.host(Motion(), handle, size: CGSize(width: 320, height: 240)) { motion in
            SpectrogramView(source: source)
                .analysisFrame(512, hop: 480)
                .valueRange(motion.wrappedValue.low ... 0)
                .frame(width: motion.wrappedValue.size.width, height: motion.wrappedValue.size.height)
        }
        defer { hosted.close() }
        _ = try await liveSpectrogram(watch, source, columns: 6)
        await displayFrames(3)
        // The value range.
        var uploads = watch.probe.uploads
        let recorded = watch.inspector.contents.count
        var motion = Motion()
        motion.low = -30
        await handle.animate(to: motion, .linear(duration: 0.4))
        #expect(await eventually(timeout: patience) { watch.inspector.heatmap?.valueRange == -30 ... 0 }, "the animation ended at its target")
        let lows = watch.inspector.contents.dropFirst(recorded).compactMap { content -> Double? in
            if case .heatmap(_, let appearance) = content { return Double(appearance.valueRange.lowerBound) }
            return nil
        }
        #expect(isGlide(lows, from: -90, to: -30), "interpolated values, frame by frame: \(lows)")
        #expect(watch.probe.uploads == uploads, "no upload")
        // The size.
        await displayFrames(3)
        uploads = watch.probe.uploads
        let updates = watch.probe.updates, draws = watch.probe.draws, allocations = watch.probe.allocations
        motion.size = CGSize(width: 220, height: 150)
        await handle.animate(to: motion, .linear(duration: 0.4))
        await displayFrames(4)
        #expect(watch.probe.draws - draws >= 2, "frames were drawn on the way: \(watch.probe.draws - draws)")
        #expect(watch.probe.uploads == uploads && watch.probe.allocations == allocations && watch.probe.updates == updates, "a size is not appearance: nothing is uploaded, and no data texture is allocated")
        #expect(watch.host.updates.isEmpty && watch.host.attaches == 1 && watch.probe.makes == 1, "and the session is handed nothing")
    }

    // MARK: The second pipeline host (WP-817)

    struct Voice: Equatable {
        var gains: [Double] = [-6, -12]
        var frame = 256
    }

    /// Inside `withAnimation` the session of a source-fed component receives one
    /// interpolated update of the same topology per display frame (ANI-3): the values glide
    /// together from where they were to where they go, no plan is compiled, and the surface
    /// is not touched.
    @Test(arguments: SourceComponent.allCases)
    func insideWithAnimationTheSessionReceivesOneInterpolatedUpdatePerDisplayFrame(component: SourceComponent) async throws {
        let watch = SourceWatch(blockSize: 64), source = GatedSource(), handle = StateHandle<Voice>()
        let hosted = watch.host(Voice(), handle) { voice in
            Self.view(component, of: source)
                .processing(PipelineHostTests.chain(voice.wrappedValue.gains))
                .axis(.time)
        }
        defer { hosted.close() }
        await watch.settled()
        let session = try #require(watch.host.session)
        let replans = Box(0)
        let events = session.events
        let listening = Task {
            for await event in events {
                if case .replanned = event { replans.value += 1 }
            }
        }
        defer { listening.cancel() }
        #expect(await eventually(timeout: patience) { watch.axes.draws >= 1 })
        await displayFrames(3)
        let draws = watch.probe.draws, axisDraws = watch.axes.draws

        // The display's frames, counted while the animation runs.
        let frames = Box(0)
        let display = DisplayLinkClock()
        display.onTick = { _ in frames.value += 1 }
        display.isPaused = false
        await handle.animate(to: Voice(gains: [-30, -2]), .linear(duration: 0.5))
        #expect(await eventually(timeout: patience) { watch.host.updates.last.map { Array($0.values.prefix(2)) } == [-30, -2] }, "the animation ended at its target")
        await displayFrames(2)
        display.invalidate()
        let updates = watch.host.updates
        #expect(updates.count >= 2, "more than the target: \(updates.count) updates")
        #expect(updates.count <= frames.value, "no more than one update per display frame: \(updates.count) updates in \(frames.value) frames")
        #expect(updates.allSatisfy { $0.count == updates[0].count }, "every update has the vector of one topology")
        // Each value glides from where it was to where it goes, and they move together.
        #expect(isGlide(updates.map { $0.values[0] }, from: -6, to: -30), "\(updates.map { $0.values[0] })")
        #expect(isGlide(updates.map { $0.values[1] }, from: -12, to: -2), "\(updates.map { $0.values[1] })")
        for update in updates {
            expectClose((update.values[0] + 6) / -24, (update.values[1] + 12) / 10, .absolute(1e-6))
            // What the recipe has of its own stays where it is.
            #expect(Array(update.values.dropFirst(2)) == Array(updates[0].values.dropFirst(2)))
        }
        // Updates of the same topology: no new plan, the same attachment.
        for _ in 0 ..< 4 { await mainQueueDrained() }
        #expect(replans.value == 0 && watch.host.attaches == 1 && watch.host.session === session && watch.host.failures.isEmpty)
        // The surface and the axis took no notice.
        #expect(watch.probe.updates == 0 && watch.probe.draws == draws && watch.axes.draws == axisDraws && watch.probe.makes == 1)
    }

    /// The session runs what the animation ended at: the glide is not only counted.
    @Test func afterAnAnimationTheSessionRunsTheTarget() async throws {
        let watch = SourceWatch(blockSize: 240), source = GatedSource(), handle = StateHandle<Voice>()
        let hosted = watch.host(Voice(), handle) { voice in
            WaveformView(source: source).processing(PipelineHostTests.chain(voice.wrappedValue.gains))
        }
        defer { hosted.close() }
        await watch.settled()
        let feed = try #require(watch.waveform)
        // One block of ones is one pair, whose maximum is the gain that is applied.
        let block = [Float](repeating: 1, count: 240)
        func level() async -> Float {
            #expect(await eventually(timeout: patience) { watch.host.isIdle }, "every update has landed")
            let before = feed.generation
            for _ in 0 ..< 12 { source.write(block) }
            #expect(await eventually(timeout: patience) { feed.generation >= before + 12 })
            return feed.snapshot().reach(newest: 1)
        }
        expectClose(await level(), Float(pow(10, -18.0 / 20)), .absolute(1e-4), "before: −6 and −12 dB")
        await handle.animate(to: Voice(gains: [-30, -2]), .easeInOut(duration: 0.4))
        #expect(await eventually(timeout: patience) { watch.host.updates.last.map { Array($0.values.prefix(2)) } == [-30, -2] })
        expectClose(await level(), Float(pow(10, -32.0 / 20)), .absolute(1e-4), "after: −30 and −2 dB")
        #expect(watch.host.attaches == 1)
    }

    /// A change of topology is not interpolated (ANI-4): inside `withAnimation` too, another
    /// stage in the processing, and another analysis frame, is one update at once.
    @Test func aChangeOfTopologyIsAppliedAtOnce() async throws {
        let watch = SourceWatch(blockSize: 64), source = GatedSource(), handle = StateHandle<Voice>()
        let hosted = watch.host(Voice(), handle) { voice in
            SpectrogramView(source: source)
                .processing(PipelineHostTests.chain(voice.wrappedValue.gains))
                .analysisFrame(voice.wrappedValue.frame, hop: 64)
        }
        defer { hosted.close() }
        await watch.settled()
        // One stage more, and other values for the two that stay.
        var voice = Voice(gains: [-40, -1, -3])
        await handle.animate(to: voice, .linear(duration: 0.4))
        #expect(await eventually(timeout: patience) { watch.host.updates.last.map { Array($0.values.prefix(3)) } == [-40, -1, -3] })
        await displayFrames(3)
        #expect(watch.host.updates.count == 1, "one update, with the target's values: \(watch.host.updates.map { $0.values })")
        // Another frame, and another value with it: structure wins, the value is not glided.
        voice.frame = 512
        voice.gains = [-20, -1, -3]
        await handle.animate(to: voice, .linear(duration: 0.4))
        #expect(await eventually(timeout: patience) { watch.host.updates.count == 2 })
        await displayFrames(3)
        #expect(watch.host.updates.count == 2 && Array(watch.host.updates[1].values.prefix(3)) == [-20, -1, -3])
        #expect(watch.host.attaches == 1 && watch.host.failures.isEmpty)
    }

    // MARK: Whatever happens while a plan is compiled, hosted

    /// A view that is hidden while its attachment is on its way, and shown again: no
    /// attachment is left behind, and the view that is shown ends with one.
    @Test func aViewHiddenAndShownWhileAttachingEndsWithOneAttachment() async throws {
        let watch = SourceWatch(blockSize: 16), source = GatedSource(open: false), handle = StateHandle<Bool>()
        let hosted = watch.host(true, handle) { shown in
            if shown.wrappedValue { SpectrogramView(source: source).analysisFrame(16, hop: 16) }
        }
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { source.prepares == 1 && watch.host.requests == 1 }, "the attachment is on its way")
        handle.set(false)
        await displayFrames(2)
        handle.set(true)
        await displayFrames(2)
        #expect(watch.host.attaches == 0 && watch.host.detaches == 0)
        source.open()
        #expect(await eventually(timeout: patience) { watch.host.attaches == 1 && watch.host.session?.state == .running }, "\(watch.host.failures)")
        await displayFrames(3)
        #expect(watch.host.attaches == 1 && watch.host.failures.isEmpty && watch.host.detaches == 0, "exactly one: what came too late was let go without a word")
        let feed = try #require(watch.heatmap)
        let block = SourceFedRig.blocks(0 ..< 1)
        #expect(await eventually(timeout: patience) {
            source.write(block)
            return feed.columnCount >= 3
        }, "and it is the one that writes the feed the view shows")
        handle.set(false)
        #expect(await eventually(timeout: patience) { watch.host.detaches == 1 && !feed.isLive })
        let unused = await eventuallyAwaiting { await SourceFedRig.isFree(source) }
        #expect(unused, "nothing is left on the source")
    }

    /// A view that is given another source while its attachment is on its way ends with one
    /// attachment, on the source it was given last.
    @Test func aSourceGivenWhileAttachingEndsWithOneAttachmentOnIt() async throws {
        let watch = SourceWatch(blockSize: 16), first = GatedSource(open: false), second = GatedSource(), handle = StateHandle<Bool>()
        let hosted = watch.host(false, handle) { other in
            SpectrogramView(source: other.wrappedValue ? second : first).analysisFrame(16, hop: 16)
        }
        defer { hosted.close() }
        #expect(await eventually(timeout: patience) { first.prepares == 1 && watch.host.requests == 1 })
        handle.set(true)
        await displayFrames(3)
        #expect(watch.host.requests == 1 && second.prepares == 0, "the engine is not asked again while the first attachment is on its way")
        first.open()
        await watch.settled()
        #expect(watch.host.attaches == 1 && watch.host.requests == 2 && second.prepares == 1 && watch.host.failures.isEmpty)
        let feed = try #require(watch.heatmap)
        let block = SourceFedRig.blocks(0 ..< 1)
        first.write(block)
        #expect(await eventually(timeout: patience) {
            second.write(block)
            return feed.columnCount >= 3
        }, "the view shows the source it was given last")
        let unused = await eventuallyAwaiting { await SourceFedRig.isFree(first) }
        #expect(unused, "nothing is left on the first source")
    }
}
