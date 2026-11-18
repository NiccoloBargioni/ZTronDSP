import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// The axis views (WP-808a, WP-808b): what they label, from the feed's `FeedAxis` (VC-5),
/// and when they are redrawn: only on a change of appearance, feed axis or environment.
@MainActor
@Suite("Axes")
struct AxisTests {
    static let linear = FeedAxis.linearFrequency(binCount: 513, nyquist: 24_000)

    private func layout(_ axis: FeedAxis, scale: some FrequencyScale = LinearFrequencyScale(), range: ClosedRange<Double>? = nil) -> RowLayout {
        RowLayout(axis: axis, scale: AnyFrequencyScale(scale), range: range)
    }

    // MARK: Marks

    @Test func aLinearFrequencyAxisIsMarkedInEvenRoundSteps() {
        let ticks = AxisTicks.rows(layout(Self.linear), maximumCount: 6)
        #expect(ticks.map(\.label) == ["0", "5k", "10k", "15k", "20k"])
        let fractions: [Double] = [0, 5, 10, 15, 20].map { $0 / 24 }
        expectClose(ticks.map(\.fraction), fractions, .absolute(1e-12))
        // A visible range: the marks are the round values inside it, placed where the picture shows them.
        let zoomed = AxisTicks.rows(layout(Self.linear, range: 1_000 ... 3_000), maximumCount: 4)
        #expect(zoomed.map(\.label) == ["1k", "1.5k", "2k", "2.5k", "3k"])
        let quarters: [Double] = [0, 0.25, 0.5, 0.75, 1]
        expectClose(zoomed.map(\.fraction), quarters, .absolute(1e-12))
    }

    @Test func aLogarithmicAxisIsMarkedAtOneTwoAndFiveTimesThePowersOfTen() {
        let ticks = AxisTicks.rows(layout(Self.linear, scale: LogarithmicFrequencyScale(), range: 20 ... 20_000), maximumCount: 12)
        #expect(ticks.map(\.label) == ["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"])
        // Evenly spaced decades: 100 Hz and 1 kHz are a third of the axis apart.
        let hundred = try! #require(ticks.first { $0.label == "100" }), thousand = try! #require(ticks.first { $0.label == "1k" })
        expectClose(thousand.fraction - hundred.fraction, 1.0 / 3, .absolute(1e-12))
        // With room for fewer labels the marks thin out, and none sits on top of another.
        let few = AxisTicks.rows(layout(Self.linear, scale: LogarithmicFrequencyScale(), range: 20 ... 20_000), maximumCount: 4)
        #expect(few.count <= 4 && few.count >= 3)
        #expect(zip(few, few.dropFirst()).allSatisfy { $1.fraction - $0.fraction >= 0.249 })
    }

    /// WP-803b: mel bands and constant-Q bins are labelled from the feed's axis, bin for
    /// bin, whatever the scale.
    @Test func bandsAndConstantQBinsAreLabelledFromTheFeedsAxis() {
        let centers = (0 ..< 40).map { 100 * pow(1.12, Double($0)) }
        for scale in [AnyFrequencyScale(LinearFrequencyScale()), AnyFrequencyScale(LogarithmicFrequencyScale())] {
            let layout = RowLayout(axis: .mel(centers: centers), scale: scale, range: nil)
            let ticks = AxisTicks.rows(layout, maximumCount: 10)
            #expect(ticks.map(\.label) == ["100", "200", "500", "1k", "2k", "5k"], "the round frequencies among the bands")
            for tick in ticks {
                // Each mark sits where the feed's rows put that frequency.
                let hertz = tick.label.hasSuffix("k") ? Double(tick.label.dropLast())! * 1_000 : Double(tick.label)!
                expectClose(tick.fraction, RowAxisMapping(axis: .mel(centers: centers)).position(of: hertz) / 40, .absolute(1e-12))
            }
        }
        let constantQ = AxisTicks.rows(layout(.constantQ(minimumFrequency: 55, binsPerOctave: 12, binCount: 48)), maximumCount: 8)
        #expect(constantQ.map(\.label) == ["100", "200", "500"])
        expectClose(constantQ[1].fraction - constantQ[0].fraction, 12.0 / 48, .absolute(1e-12), "an octave is twelve of the 48 rows")
    }

    @Test func pitchClassesAreNamedOnePerRow() {
        let ticks = AxisTicks.rows(layout(.pitchClasses), maximumCount: 12)
        #expect(ticks.map(\.label) == FeedAxis.pitchClassNames)
        let middles: [Double] = (0 ..< 12).map { (Double($0) + 0.5) / 12 }
        expectClose(ticks.map(\.fraction), middles, .absolute(1e-12), "each name in the middle of its row")
        // Too little room for twelve names: every other one.
        #expect(AxisTicks.rows(layout(.pitchClasses), maximumCount: 6).map(\.label) == ["C", "D", "E", "F♯", "G♯", "A♯"])
    }

    /// WP-806: the rows of a tempogram follow the feed's axis.
    @Test func tempiAreMarkedWhereTheFeedsRowsPutThem() {
        let tempi = (0 ..< 86).map { 30.0 + 2 * Double($0) }
        let ticks = AxisTicks.rows(layout(.tempo(beatsPerMinute: tempi)), maximumCount: 5)
        #expect(ticks.map(\.label) == ["50", "100", "150", "200"])
        expectClose(ticks[1].fraction, (35 + 0.5) / 86, .absolute(1e-12), "100 beats per minute is row 35")
        // Rows that fall as they go up, as lags do: the marks follow them.
        let falling = AxisTicks.rows(layout(.tempo(beatsPerMinute: tempi.reversed())), maximumCount: 5)
        #expect(falling.map(\.label) == ["200", "150", "100", "50"], "from the bottom of the view upwards")
        let zoomed = AxisTicks.rows(layout(.tempo(beatsPerMinute: tempi), range: 100 ... 140), maximumCount: 5)
        #expect(zoomed.map(\.label) == ["100", "110", "120", "130", "140"])
    }

    @Test func lagsQuefrenciesAndPlainRowsAreMarkedInTheirOwnUnits() {
        #expect(AxisTicks.rows(layout(.lags(count: 101, sampleRate: 100)), maximumCount: 5).map(\.label) == ["0 s", "500 ms", "1 s"])
        #expect(AxisTicks.rows(layout(.lags(count: 101, sampleRate: 100), range: 0 ... 0.8), maximumCount: 5).map(\.label) == ["0 s", "200 ms", "400 ms", "600 ms", "800 ms"])
        #expect(AxisTicks.rows(layout(.quefrency(count: 481, sampleRate: 48_000)), maximumCount: 5).map(\.label) == ["0 s", "5 ms", "10 ms"])
        #expect(AxisTicks.rows(layout(.indices(count: 13)), maximumCount: 4).map(\.label) == ["0", "5", "10"])
    }

    @Test func anAxisWithoutRowsOrWithoutRoomHasNoMarks() {
        #expect(AxisTicks.rows(layout(.mel(centers: [])), maximumCount: 5).isEmpty)
        #expect(AxisTicks.rows(layout(Self.linear), maximumCount: 0).isEmpty)
        #expect(AxisTicks.time(span: 0, maximumCount: 5).isEmpty && AxisTicks.time(span: .nan, maximumCount: 5).isEmpty && AxisTicks.time(span: 5, maximumCount: 0).isEmpty)
        #expect(AxisTicks.steps(in: 3 ... 3, count: 4).isEmpty && AxisTicks.steps(in: 0 ... 1, count: 0).isEmpty)
        #expect(AxisTicks.decades(in: -5 ... 0).isEmpty)
    }

    @Test func aTimeAxisCountsBackFromThePresentAtItsRightEdge() {
        let ticks = AxisTicks.time(span: 10, maximumCount: 5)
        #expect(ticks.map(\.label) == ["−10 s", "−8 s", "−6 s", "−4 s", "−2 s", "0"], "from the left edge to the right")
        let fifths: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        expectClose(ticks.map(\.fraction), fifths, .absolute(1e-12))
        #expect(AxisTicks.time(span: 0.5, maximumCount: 5).map(\.label) == ["−500 ms", "−400 ms", "−300 ms", "−200 ms", "−100 ms", "0"])
        // A span that is no round number: the marks are, and the left edge has none.
        let odd = AxisTicks.time(span: 9.4, maximumCount: 5)
        #expect(odd.map(\.label) == ["−8 s", "−6 s", "−4 s", "−2 s", "0"])
        expectClose(odd[0].fraction, 1 - 8 / 9.4, .absolute(1e-12))
        #expect(AxisTicks.time(span: 9.4, maximumCount: 4).map(\.label) == ["−5 s", "0"], "never more marks than there is room for")
    }

    @Test func roundStepsAreOneTwoOrFiveTimesAPowerOfTen() {
        #expect(AxisTicks.niceStep(1) == 1 && AxisTicks.niceStep(1.2) == 2 && AxisTicks.niceStep(2.5) == 5 && AxisTicks.niceStep(7) == 10)
        #expect(AxisTicks.niceStep(0.03) == 0.05 && AxisTicks.niceStep(4_000) == 5_000 && AxisTicks.niceStep(100) == 100)
        #expect(AxisTicks.niceStep(0) == 1 && AxisTicks.niceStep(-3) == 1 && AxisTicks.niceStep(.infinity) == 1)
        #expect(AxisTicks.steps(in: -1 ... 1, count: 4) == [-1, -0.5, 0, 0.5, 1])
        #expect(AxisTicks.decades(in: 30 ... 3_000) == [50, 100, 200, 500, 1_000, 2_000])
        #expect(AxisTicks.decades(in: 0 ... 100) == [0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100], "four decades below the top at most")
    }

    @Test func valuesReadAsTheirUnitsDo() {
        #expect(AxisTicks.label(440, unit: .hertz) == "440" && AxisTicks.label(2_500, unit: .hertz) == "2.5k" && AxisTicks.label(20_000, unit: .hertz) == "20k")
        #expect(AxisTicks.label(62.5, unit: .hertz) == "62.5" && AxisTicks.label(0, unit: .hertz) == "0")
        #expect(AxisTicks.label(0.005, unit: .seconds) == "5 ms" && AxisTicks.label(1.5, unit: .seconds) == "1.5 s" && AxisTicks.label(0, unit: .seconds) == "0 s")
        #expect(AxisTicks.label(120, unit: .beatsPerMinute) == "120" && AxisTicks.label(7, unit: .index) == "7")
        #expect(AxisTicks.label(3, unit: .pitchClass) == "D♯" && AxisTicks.label(12, unit: .pitchClass) == "12")
        #expect(AxisTicks.label(0.1 + 0.2, unit: .index) == "0.3", "without the dust of arithmetic")
    }

    // MARK: Specifications: what decides whether an axis is redrawn

    @Test func aSpecificationChangesWithTheAppearanceAndTheFeedsAxisAndWithNothingElse() {
        let shape = FeedShape(axis: Self.linear, columnRate: 100, history: 1_000)
        let spec = AxisSpec.rows(shape: shape, fallback: nil, scale: nil, range: nil)
        let model = spec.model(size: CGSize(width: 44, height: 200))
        #expect(model.edge == .leading && model.ticks.map(\.label) == ["0", "5k", "10k", "15k", "20k"])
        // Equal inputs, made again: an equal specification, so nothing is redrawn.
        let again = AxisSpec.rows(shape: FeedShape(axis: Self.linear, columnRate: 100, history: 1_000), fallback: nil,
                                  scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        #expect(again == spec)
        // What the axis does not show does not change it: the feed's rate and its history.
        #expect(AxisSpec.rows(shape: FeedShape(axis: Self.linear, columnRate: 50, history: 300), fallback: nil, scale: nil, range: nil) == spec)
        // The appearance and the feed's axis do.
        #expect(AxisSpec.rows(shape: shape, fallback: nil, scale: AnyFrequencyScale(LogarithmicFrequencyScale()), range: nil) != spec)
        #expect(AxisSpec.rows(shape: shape, fallback: nil, scale: nil, range: 0 ... 12_000) != spec)
        let other = FeedShape(axis: .linearFrequency(binCount: 513, nyquist: 22_050), columnRate: 100, history: 1_000)
        #expect(AxisSpec.rows(shape: other, fallback: nil, scale: nil, range: nil) != spec)
        // The marks are chosen for the room the axis has when it is drawn.
        #expect(spec.model(size: CGSize(width: 44, height: 60)).ticks.map(\.label) == ["0", "20k"])
        #expect(spec.model(size: CGSize(width: 44, height: 0)).ticks.isEmpty)
        // A feed without an axis shows the fallback, or nothing.
        let empty = FeedShape(axis: nil, columnRate: nil, history: 512)
        #expect(AxisSpec.rows(shape: empty, fallback: nil, scale: nil, range: nil) == .nothing)
        #expect(AxisSpec.nothing.model(size: CGSize(width: 44, height: 400)).ticks.isEmpty)
        #expect(AxisSpec.rows(shape: empty, fallback: .pitchClasses, scale: nil, range: nil).model(size: CGSize(width: 44, height: 400)).ticks.count == 12)
        #expect(AxisSpec.rows(shape: shape, fallback: .pitchClasses, scale: nil, range: nil) == spec, "the feed's own axis wins")
    }

    @Test func aTimeAxisNeedsTheFeedsRate() {
        let shape = FeedShape(axis: nil, columnRate: 100, history: 1_000)
        let whole = AxisSpec.time(shape: shape, span: nil)
        #expect(whole == .time(span: 10), "the whole history: 10 s")
        let model = whole.model(size: CGSize(width: 300, height: 20))
        #expect(model.edge == .bottom && model.ticks.map(\.label) == ["−10 s", "−8 s", "−6 s", "−4 s", "−2 s", "0"])
        #expect(AxisSpec.time(shape: shape, span: 4).model(size: CGSize(width: 300, height: 20)).ticks.map(\.label) == ["−4 s", "−3 s", "−2 s", "−1 s", "0"])
        #expect(AxisSpec.time(shape: shape, span: 0) == whole && AxisSpec.time(shape: shape, span: .nan) == whole)
        #expect(AxisSpec.time(shape: FeedShape(axis: nil, columnRate: 50, history: 500), span: nil) == whole, "the same seconds")
        #expect(AxisSpec.time(shape: FeedShape(axis: nil, columnRate: nil, history: 1_000), span: 4) == .nothing, "no rate, no seconds")
        #expect(whole.model(size: CGSize(width: 0, height: 20)).ticks.isEmpty)
    }

    /// The keeper hands back the drawing that is on screen for as long as it is asked for an
    /// equal specification: the same object, which is what leaves the canvas alone.
    @Test func theKeeperHandsOutOneDrawingForEqualSpecifications() {
        let keeper = AxisKeeper()
        let shape = FeedShape(axis: Self.linear, columnRate: 100, history: 1_000)
        let first = keeper.drawing(for: .rows(shape: shape, fallback: nil, scale: nil, range: nil))
        // The same specification, computed anew, as a body does.
        let again = keeper.drawing(for: .rows(shape: FeedShape(axis: Self.linear, columnRate: 5, history: 9), fallback: nil,
                                              scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil))
        #expect(again === first, "equal: the drawing that is on screen")
        let other = keeper.drawing(for: .rows(shape: shape, fallback: nil, scale: nil, range: 0 ... 100))
        #expect(other !== first && other.spec != first.spec, "another range: another drawing")
        #expect(keeper.drawing(for: first.spec) !== first, "the keeper remembers what is shown, not what was")
        #expect(keeper.drawing(for: .time(span: 4)) === keeper.drawing(for: .time(span: 4)))
        #expect(!keeper.watcher.isRunning)
    }

    // MARK: Watching a feed's shape

    /// A feed tells nobody when it gets its axis. The watcher looks when the feed's liveness
    /// changes and twice a second while it is live, and reports only a shape that differs.
    @Test func theWatcherReportsAShapeOnlyWhenItChanges() async throws {
        let live = try await LiveFeed(.heatmap, rows: 16, axis: .linearFrequency(binCount: 16, nyquist: 24_000), hop: 480)
        let clock = ManualClock()
        let watcher = FeedShapeWatcher()
        let reported = Box<[FeedShape]>([])
        watcher.watch(.heatmap(live.heatmap), clock: clock) { reported.value.append($0) }
        #expect(!watcher.isRunning && clock.fire(10) == 0, "a feed that is not live is not looked at: no wake-ups")
        #expect(reported.value.isEmpty && watcher.looks == 0)

        // The session starts: the feed becomes live, and the watcher looks once. The shape is
        // the one the feed had when the watcher began: nothing is reported.
        try await live.start()
        #expect(watcher.isRunning && watcher.looks == 1 && reported.value.isEmpty)

        // Data arrives for a second: the shape does not change, and the view hears nothing.
        await live.send(0 ..< 8)
        #expect(clock.fire(60) == 60)
        // The first tick, and then one every half second or so: two or three in a second, not sixty.
        #expect((1 + 2 ... 1 + 3).contains(watcher.looks), "\(watcher.looks) looks")
        #expect(reported.value.isEmpty && watcher.changes == 0)

        // The session stops: one more look, then silence.
        await live.stop()
        #expect(!watcher.isRunning && clock.fire(60) == 0 && reported.value.isEmpty)
        watcher.stop()
        #expect(clock.isInvalidated)
    }

    @Test func aFeedThatGetsItsAxisIsReportedOnce() async throws {
        let feed = HeatmapFeed(history: 100)
        let clock = ManualClock()
        let watcher = FeedShapeWatcher()
        let reported = Box<[FeedShape]>([])
        watcher.watch(.heatmap(feed), clock: clock) { reported.value.append($0) }
        // An offline run attaches the feed, fills it and lets go of it.
        try FeedWriter.append(FeedWriter.columns(0 ..< 3, rows: 9), rows: 9, axis: .tempo(beatsPerMinute: (0 ..< 9).map { 60 + 10 * Double($0) }), hop: 240, to: feed)
        await mainQueueDrained()
        #expect(reported.value == [FeedShape(axis: .tempo(beatsPerMinute: (0 ..< 9).map { 60 + 10 * Double($0) }), columnRate: 200, history: 100)])
        #expect(watcher.changes == 1 && !watcher.isRunning)
        // More data in the same shape: nothing to report.
        try FeedWriter.append(FeedWriter.columns(3 ..< 5, rows: 9), rows: 9, axis: .tempo(beatsPerMinute: (0 ..< 9).map { 60 + 10 * Double($0) }), hop: 240, to: feed)
        await mainQueueDrained()
        #expect(watcher.changes == 1)
        // Another axis: reported.
        try FeedWriter.append(FeedWriter.columns(0 ..< 2, rows: 12), rows: 12, axis: .pitchClasses, hop: 240, to: feed)
        await mainQueueDrained()
        #expect(watcher.changes == 2 && reported.value.last?.axis == .pitchClasses)
        // A watcher that has stopped hears nothing.
        watcher.stop()
        try FeedWriter.append(FeedWriter.columns(0 ..< 2, rows: 5), rows: 5, hop: 240, to: feed)
        await mainQueueDrained()
        #expect(watcher.changes == 2 && reported.value.count == 2)
    }

    /// A session that is updated to another shape while it runs changes no liveness: the
    /// look twice a second finds it.
    @Test func aShapeThatChangesWhileTheFeedIsLiveIsFoundWithinHalfASecond() async throws {
        let engine = DSPEngine(blockSize: 16)
        let source = HandFedSource()
        let feed = HeatmapFeed(history: 64)
        func pipeline(nyquist: Double) -> Pipeline<Samples, Samples> {
            Pipeline<Samples, Samples>().tap { $0.appending(TestColumns(rows: 16, axis: .linearFrequency(binCount: 16, nyquist: nyquist), hop: 480)).emit(to: feed) }
        }
        let session = try await engine.attach(pipeline(nyquist: 24_000), to: source)
        try session.start()
        #expect(await eventually { feed.isLive })
        await mainQueueDrained()
        let clock = ManualClock()
        let watcher = FeedShapeWatcher()
        let reported = Box<[FeedShape]>([])
        watcher.watch(.heatmap(feed), clock: clock) { reported.value.append($0) }
        #expect(watcher.isRunning)
        try await session.update(pipeline(nyquist: 11_025))
        #expect(await eventually { feed.axis == .linearFrequency(binCount: 16, nyquist: 11_025) })
        await mainQueueDrained()
        // At most half a second of display ticks later the view knows.
        #expect(clock.fire(31) == 31)
        #expect(reported.value.map(\.axis) == [.linearFrequency(binCount: 16, nyquist: 11_025)])
        session.detach()
        watcher.stop()
    }

    // MARK: Hosted: an axis is redrawn only when what it shows changes (WP-808)

    struct Look: Equatable {
        var counter = 0
        var top = 24_000.0
        var magma = false
        var span = 0.5
    }

    @Test func anAxisIsRedrawnOnlyWhenItsModelChanges() async throws {
        let feed = HeatmapFeed(history: 100)
        try FeedWriter.append(FeedWriter.columns(0 ..< 4, rows: 33), rows: 33, axis: .linearFrequency(binCount: 33, nyquist: 24_000), hop: 480, to: feed)
        let probe = AxisProbe(), render = RenderProbe(), handle = StateHandle<Look>()
        let clocks = Box<[ManualClock]>([])
        let source = ClockSource {
            let clock = ManualClock()
            clocks.value.append(clock)
            return clock
        }
        let hosted = Hosted(Stateful(Look(), handle) { look in
            VStack {
                Text("\(look.wrappedValue.counter)")
                SpectrogramView(feed: feed)
                    .axis(.frequency)
                    .axis(.time)
                    .frequencyRange(0 ... look.wrappedValue.top)
                    .timeSpan(look.wrappedValue.span)
                    .colorMap(look.wrappedValue.magma ? ListedColorMap.magma : ListedColorMap.viridis)
            }
            .environment(\.dspAxisProbe, probe)
            .environment(\.dspRenderProbe, render)
            .environment(\.dspClockSource, source)
        })
        defer { hosted.close() }
        #expect(await eventually { probe.draws >= 2 }, "the frequency axis and the time axis were drawn")
        await displayFrames(3)
        var draws = probe.draws

        // The parent's body runs twenty times with nothing changed for the axes.
        var look = Look()
        for step in 1 ... 20 {
            look.counter = step
            handle.set(look)
            await displayFrames(1)
        }
        #expect(probe.draws == draws, "equal inputs: no axis is redrawn")

        // Appearance that an axis does not show: the colour map.
        look.magma = true
        handle.set(look)
        await displayFrames(3)
        #expect(probe.draws == draws, "another colour map is nothing to an axis")

        // The vertical range: the frequency axis is redrawn, the time axis is not.
        look.top = 12_000
        handle.set(look)
        #expect(await eventually { probe.draws == draws + 1 })
        await displayFrames(3)
        #expect(probe.draws == draws + 1)
        draws = probe.draws

        // The time span: the time axis is redrawn, the frequency axis is not.
        look.span = 0.25
        handle.set(look)
        #expect(await eventually { probe.draws == draws + 1 })
        await displayFrames(3)
        #expect(probe.draws == draws + 1)
        draws = probe.draws

        // New data in the same shape: nothing.
        try FeedWriter.append(FeedWriter.columns(4 ..< 9, rows: 33), rows: 33, axis: .linearFrequency(binCount: 33, nyquist: 24_000), hop: 480, to: feed)
        await mainQueueDrained()
        await displayFrames(3)
        #expect(probe.draws == draws, "data is nothing to an axis")

        // The feed gets another axis: the frequency axis is redrawn.
        try FeedWriter.append(FeedWriter.columns(0 ..< 2, rows: 33), rows: 33, axis: .linearFrequency(binCount: 33, nyquist: 11_025), hop: 480, to: feed)
        await mainQueueDrained()
        #expect(await eventually { probe.draws == draws + 1 }, "the feed's axis changed")
        await displayFrames(3)
        #expect(probe.draws == draws + 1)
    }

    /// The axes a component places with `.axis(_:)` line up with its picture: the vertical
    /// axis is as high as the picture, the time axis as wide, whether or not there is a
    /// vertical axis beside it.
    @Test func theAxesOfAComponentLineUpWithItsPicture() async throws {
        let feed = HeatmapFeed(history: 100)
        try FeedWriter.append(FeedWriter.columns(0 ..< 4, rows: 33), rows: 33, axis: .linearFrequency(binCount: 33, nyquist: 24_000), hop: 480, to: feed)
        let both = AxisProbe(), alone = AxisProbe(), render = RenderProbe(), bare = RenderProbe()
        let measured = Box<[CGSize]>([])
        let hosted = Hosted(size: CGSize(width: 320, height: 400), Stateful(0, StateHandle<Int>()) { _ in
            VStack(spacing: 0) {
                SpectrogramView(feed: feed)
                    .axis(.frequency)
                    .axis(.time)
                    .environment(\.dspAxisProbe, both)
                    .environment(\.dspRenderProbe, render)
                    .background(GeometryReader { proxy in Color.clear.onAppear { measured.value.append(proxy.size) } })
                TempogramView(feed: feed)
                    .axis(.time)
                    .environment(\.dspAxisProbe, alone)
                    .environment(\.dspRenderProbe, bare)
            }
        })
        defer { hosted.close() }
        #expect(await eventually { both.draws >= 2 && alone.draws >= 1 && render.draws >= 1 && bare.draws >= 1 }, "three axes and two pictures")
        await displayFrames(3)
        let whole = try #require(measured.value.last, "the size the first component was given")
        #expect(whole.width == 320 && whole.height > AxisMetrics.timeAxisHeight + AxisMetrics.rowLabelHeight)
        // Beside a vertical axis the time axis begins where the picture begins.
        let beside = Set(both.sizes.map { [$0.width, $0.height] })
        #expect(beside == [[AxisMetrics.rowAxisWidth, whole.height - AxisMetrics.timeAxisHeight],
                           [whole.width - AxisMetrics.rowAxisWidth, AxisMetrics.timeAxisHeight]])
        // Without one it has the component's whole width.
        #expect(Set(alone.sizes.map { [$0.width, $0.height] }) == [[whole.width, AxisMetrics.timeAxisHeight]])
    }

    /// The four axis views stand by themselves beside a component, inside the same modifiers.
    @Test func theAxisViewsStandByThemselves() async throws {
        let spectrum = HeatmapFeed(history: 100), chroma = HeatmapFeed(history: 100), tempo = HeatmapFeed(history: 100), wave = WaveformFeed(history: 100)
        try FeedWriter.append(FeedWriter.columns(0 ..< 2, rows: 33), rows: 33, axis: .linearFrequency(binCount: 33, nyquist: 24_000), hop: 480, to: spectrum)
        try FeedWriter.append(FeedWriter.columns(0 ..< 2, rows: 20), rows: 20, axis: .tempo(beatsPerMinute: (0 ..< 20).map { 60 + 8 * Double($0) }), hop: 480, to: tempo)
        let probe = AxisProbe(), handle = StateHandle<Int>()
        let hosted = Hosted(size: CGSize(width: 320, height: 400), Stateful(0, handle) { _ in
            VStack {
                HStack { FrequencyAxisView(feed: spectrum).frame(width: 44); SpectrogramView(feed: spectrum) }
                HStack { PitchClassAxisView(feed: chroma).frame(width: 44); ChromagramView(feed: chroma) }
                HStack { TempoAxisView(feed: tempo).frame(width: 44); TempogramView(feed: tempo) }
                TimeAxisView(feed: spectrum).frame(height: 20)
                TimeAxisView(feed: wave).frame(height: 20)
            }
            .frequencyScale(.logarithmic)
            .environment(\.dspAxisProbe, probe)
        })
        defer { hosted.close() }
        #expect(await eventually { probe.draws >= 5 }, "five axes, each drawn")
        await displayFrames(3)
        let draws = probe.draws
        for step in 1 ... 10 {
            handle.set(step)
            await displayFrames(1)
        }
        #expect(probe.draws == draws)
        // Views that show the same feed are equal, and store nothing but the feed.
        #expect(FrequencyAxisView(feed: spectrum) == FrequencyAxisView(feed: spectrum) && FrequencyAxisView(feed: spectrum) != FrequencyAxisView(feed: tempo))
        #expect(PitchClassAxisView(feed: chroma) == PitchClassAxisView(feed: chroma) && PitchClassAxisView(feed: chroma) != PitchClassAxisView(feed: tempo))
        #expect(TempoAxisView(feed: tempo) == TempoAxisView(feed: tempo) && TempoAxisView(feed: tempo) != TempoAxisView(feed: chroma))
        #expect(TimeAxisView(feed: spectrum) == TimeAxisView(feed: spectrum) && TimeAxisView(feed: wave) == TimeAxisView(feed: wave))
        #expect(TimeAxisView(feed: spectrum) != TimeAxisView(feed: tempo) && TimeAxisView(feed: wave) != TimeAxisView(feed: WaveformFeed()))
    }
}
