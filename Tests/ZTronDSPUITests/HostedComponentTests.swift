import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
@testable import ZTronDSPUI

/// The components in a real SwiftUI hierarchy, hosted in a window of the test process: the
/// bridge makes a real Metal view and draws into real drawables (WP-801), the modifiers
/// reach the renderer through the environment (WP-812), and SwiftUI animates the appearance
/// (WP-813).
///
/// This is hosting without an application. The hosted stability suite of the Examples
/// project (WP-809b) repeats the scenarios of §8.4 inside one.
@MainActor
@Suite("Components, hosted in the test process")
struct HostedComponentTests {
    /// Everything a hosted test sees of a component.
    @MainActor
    final class Watch {
        let probe = RenderProbe()
        let inspector = SurfaceInspector()
        let axes = AxisProbe()
    }

    private func spectrum(columns: Int = 6, rows: Int = 33, history: Int = 64) throws -> HeatmapFeed {
        let feed = HeatmapFeed(history: history)
        try FeedWriter.append(FeedWriter.columns(0 ..< columns, rows: rows), rows: rows,
                              axis: .linearFrequency(binCount: rows, nyquist: 24_000), hop: 480, to: feed)
        return feed
    }

    /// Hosts `content` with the watch's probes in its environment and waits for its first frame.
    private func host<Value, Content: View>(
        _ initial: Value, _ handle: StateHandle<Value>, watch: Watch, @ViewBuilder content: @escaping (Binding<Value>) -> Content
    ) async -> Hosted<some View> {
        let probe = watch.probe, inspector = watch.inspector, axes = watch.axes
        let hosted = Hosted(Stateful(initial, handle) { binding in
            content(binding)
                .environment(\.dspRenderProbe, probe)
                .environment(\.dspSurfaceInspector, inspector)
                .environment(\.dspAxisProbe, axes)
        })
        #expect(await eventually { probe.draws >= 1 }, "the surface drew its first frame into a real drawable")
        return hosted
    }

    // MARK: The bridge (WP-801)

    @Test func theBridgeMakesOneMetalViewAndDrawsItOnce() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Int>()
        let hosted = await host(0, handle, watch: watch) { counter in
            VStack {
                Text("\(counter.wrappedValue)")
                SpectrogramView(feed: feed)
            }
        }
        defer { hosted.close() }
        #expect(watch.probe.makes == 1, "makeUIView ran once")
        #expect(watch.probe.uploadedColumns == 6 && watch.probe.drawCalls == watch.probe.draws)
        await displayFrames(4)
        let draws = watch.probe.draws
        #expect(draws <= 2, "the first frame, and at most one for the first layout")
        // The parent's body runs twenty times with equal inputs for the component (§8.4).
        for step in 1 ... 20 {
            handle.set(step)
            await displayFrames(1)
        }
        #expect(handle.value == 20)
        #expect(watch.probe.makes == 1 && watch.probe.updates == 0, "0 renderer updates")
        #expect(watch.probe.draws == draws && watch.probe.attaches == 0, "0 draws, 0 new attachments")
    }

    @Test func aViewThatLeavesTheHierarchyStopsDrawing() async throws {
        let live = try await LiveFeed(.heatmap)
        try await live.start()
        await live.send(0 ..< 2)
        let watch = Watch(), handle = StateHandle<Bool>()
        let feed = live.heatmap
        let hosted = await host(true, handle, watch: watch) { shown in
            if shown.wrappedValue { HeatmapView(feed: feed) }
        }
        defer { hosted.close() }
        await live.send(2 ..< 3)
        #expect(await eventually { watch.probe.uploadedColumns == 3 }, "a live feed is drawn as it grows")
        handle.set(false)
        await displayFrames(3)
        let draws = watch.probe.draws
        await live.send(3 ..< 6)
        await displayFrames(4)
        #expect(watch.probe.draws == draws && watch.probe.uploadedColumns == 3, "nothing is drawn for a view that is gone")
        await live.stop()
    }

    // MARK: Appearance modifiers (WP-812)

    struct Look: Equatable {
        var magma = false
        var range: ClosedRange<Float> = -80 ... -10
        var logarithmic = false
        var frequencies: ClosedRange<Double> = 100 ... 8_000
        var span = 0.04
        var frameRate = 60
    }

    /// Each modifier's value reaches the renderer through the environment, and an equal
    /// value causes no update.
    @Test func everyModifierReachesTheRendererAndAnEqualValueCausesNoUpdate() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Look>()
        let hosted = await host(Look(), handle, watch: watch) { look in
            // The modifiers sit on a container, not on the component: the environment carries them.
            ZStack { SpectrogramView(feed: feed) }
                .colorMap(look.wrappedValue.magma ? ListedColorMap.magma : ListedColorMap.viridis)
                .valueRange(look.wrappedValue.range)
                .frequencyScale(look.wrappedValue.logarithmic ? AnyScale.logarithmic : AnyScale.linear)
                .frequencyRange(look.wrappedValue.frequencies)
                .timeSpan(look.wrappedValue.span)
                .maximumFrameRate(look.wrappedValue.frameRate)
        }
        defer { hosted.close() }
        var expected = HeatmapAppearance()
        expected.valueRange = -80 ... -10
        expected.frequencyScale = AnyFrequencyScale(AnyScale.linear)
        expected.rowRange = 100 ... 8_000
        expected.timeSpan = 0.04
        #expect(watch.inspector.heatmap == expected, "what the modifiers say is what the renderer shows")
        #expect(watch.probe.updates == 0)

        var look = Look()
        func change(_ what: String, _ edit: (inout Look) -> Void, _ expect: (inout HeatmapAppearance) -> Void) async {
            let updates = watch.probe.updates, draws = watch.probe.draws, uploads = watch.probe.uploads
            edit(&look)
            handle.set(look)
            #expect(await eventually { watch.probe.updates == updates + 1 }, "\(what) reached the surface")
            expect(&expected)
            #expect(watch.inspector.heatmap == expected, "\(what)")
            #expect(await eventually { watch.probe.draws == draws + 1 }, "\(what) is one draw")
            await displayFrames(2)
            #expect(watch.probe.draws == draws + 1 && watch.probe.uploads == uploads && watch.probe.updates == updates + 1, "\(what): exactly one draw, no upload")
        }
        await change("colour map", { $0.magma = true }, { $0.colorMap = AnyColorMap(ListedColorMap.magma) })
        await change("value range", { $0.range = -60 ... 0 }, { $0.valueRange = -60 ... 0 })
        await change("frequency scale", { $0.logarithmic = true }, { $0.frequencyScale = AnyFrequencyScale(AnyScale.logarithmic) })
        await change("frequency range", { $0.frequencies = 200 ... 4_000 }, { $0.rowRange = 200 ... 4_000 })
        await change("time span", { $0.span = 0.02 }, { $0.timeSpan = 0.02 })

        // The frame-rate cap is an update that changes nothing that is drawn.
        var updates = watch.probe.updates
        let draws = watch.probe.draws
        look.frameRate = 30
        handle.set(look)
        #expect(await eventually { watch.probe.updates == updates + 1 })
        await displayFrames(2)
        #expect(watch.probe.draws == draws)

        // Equal values, made anew: no update, no draw.
        updates = watch.probe.updates
        for _ in 0 ..< 5 {
            var copy = Look()
            copy.magma = true
            copy.range = -60 ... 0
            copy.logarithmic = true
            copy.frequencies = 200 ... 4_000
            copy.span = 0.02
            copy.frameRate = 30
            handle.set(copy)
            await displayFrames(1)
        }
        #expect(watch.probe.updates == updates && watch.probe.draws == draws, "an equal value causes no update")
    }

    /// The bound forms read their binding.
    @Test func theBoundFormsReadTheirBindings() async throws {
        let feed = try spectrum()
        let wave = WaveformFeed(history: 64)
        try FeedWriter.append(pairs: [-0.5, 0.5, -0.25, 0.25], to: wave)
        struct Bound: Equatable {
            var range: ClosedRange<Float> = -70 ... -20
            var frequencies: ClosedRange<Double> = 500 ... 5_000
            var span = 0.03
            var amplitude: ClosedRange<Float> = -0.5 ... 0.5
        }
        let watch = Watch(), waveWatch = Watch(), handle = StateHandle<Bound>()
        let waveProbe = waveWatch.probe, waveInspector = waveWatch.inspector
        let hosted = await host(Bound(), handle, watch: watch) { bound in
            VStack {
                SpectrogramView(feed: feed)
                    .valueRange(bound.range)
                    .frequencyRange(bound.frequencies)
                WaveformView(feed: wave)
                    .amplitudeRange(bound.amplitude)
                    .environment(\.dspRenderProbe, waveProbe)
                    .environment(\.dspSurfaceInspector, waveInspector)
            }
            .timeSpan(bound.span)
        }
        defer { hosted.close() }
        #expect(await eventually { waveProbe.draws >= 1 })
        #expect(watch.inspector.heatmap?.valueRange == -70 ... -20 && watch.inspector.heatmap?.rowRange == 500 ... 5_000 && watch.inspector.heatmap?.timeSpan == 0.03)
        #expect(waveInspector.waveform?.amplitudeRange == -0.5 ... 0.5 && waveInspector.waveform?.timeSpan == 0.03)
        // The state behind the bindings changes: both components follow.
        var next = Bound()
        next.range = -50 ... 0
        next.frequencies = 1_000 ... 2_000
        next.span = 0.01
        next.amplitude = -0.1 ... 0.1
        handle.set(next)
        #expect(await eventually { watch.probe.updates == 1 && waveProbe.updates == 1 })
        #expect(watch.inspector.heatmap?.valueRange == -50 ... 0 && watch.inspector.heatmap?.rowRange == 1_000 ... 2_000 && watch.inspector.heatmap?.timeSpan == 0.01)
        #expect(waveInspector.waveform?.amplitudeRange == -0.1 ... 0.1 && waveInspector.waveform?.timeSpan == 0.01)
    }

    // MARK: Each component and its defaults (WP-803b, WP-804 … WP-806)

    @Test func eachComponentShowsItsFeedWithItsOwnDefaults() async throws {
        let feed = try spectrum()
        let wave = WaveformFeed(history: 64)
        try FeedWriter.append(pairs: [-0.5, 0.5, -0.25, 0.25], to: wave)
        let watches = (0 ..< 5).map { _ in Watch() }
        func watched<V: View>(_ view: V, _ index: Int) -> some View {
            view.environment(\.dspRenderProbe, watches[index].probe).environment(\.dspSurfaceInspector, watches[index].inspector)
        }
        let handle = StateHandle<ColorScheme>()
        let hosted = Hosted(Stateful(ColorScheme.light, handle) { scheme in
            VStack(spacing: 0) {
                watched(HeatmapView(feed: feed), 0)
                watched(SpectrogramView(feed: feed), 1)
                watched(ChromagramView(feed: feed), 2)
                watched(TempogramView(feed: feed), 3)
                watched(WaveformView(feed: wave), 4)
            }
            .environment(\.colorScheme, scheme.wrappedValue)
        })
        defer { hosted.close() }
        #expect(await eventually { watches.allSatisfy { $0.probe.draws >= 1 } }, "five surfaces, each drew")
        #expect(watches.allSatisfy { $0.probe.makes == 1 })
        #expect(watches[0].inspector.heatmap == HeatmapAppearance() && watches[1].inspector.heatmap == HeatmapAppearance())
        // A chromagram: cells with hard edges, values from 0 to 1.
        var chroma = HeatmapAppearance()
        chroma.valueRange = 0 ... 1
        chroma.rowInterpolation = .nearest
        #expect(watches[2].inspector.heatmap == chroma)
        var tempo = HeatmapAppearance()
        tempo.valueRange = 0 ... 1
        #expect(watches[3].inspector.heatmap == tempo)
        // A waveform is black on a light ground and white on a dark one.
        #expect(watches[4].inspector.waveform?.fill == .black && watches[4].inspector.waveform?.amplitudeRange == -1 ... 1)
        handle.set(.dark)
        #expect(await eventually { watches[4].inspector.waveform?.fill == .white })
        #expect(await eventually { watches[4].probe.draws >= 2 }, "another colour is one more draw")
        #expect(watches[4].probe.uploads == 1)
    }

    /// A waveform takes its amplitude range as a constant too, and shows a time axis when it
    /// is asked for one.
    @Test func aWaveformTakesAConstantRangeAndShowsItsTimeAxis() async throws {
        let wave = WaveformFeed(history: 800)
        let pipeline = Pipeline<Samples, Samples>().appending(TestColumnsPairs(pairs: 8)).emit(to: wave)
        try pipeline.run(on: [Float](repeating: 0.25, count: 16 * 8), format: SignalFormat(sampleRate: 48_000), blockSize: 16)
        let watch = Watch(), handle = StateHandle<Float>()
        let hosted = await host(Float(0.5), handle, watch: watch) { reach in
            WaveformView(feed: wave)
                .amplitudeRange(-reach.wrappedValue ... reach.wrappedValue)
                .axis(.time)
        }
        defer { hosted.close() }
        #expect(watch.inspector.waveform?.amplitudeRange == -0.5 ... 0.5)
        #expect(watch.inspector.heatmap == nil, "a waveform is no heat map")
        #expect(await eventually { watch.axes.draws >= 1 }, "the time axis was drawn")
        let axisDraws = watch.axes.draws
        handle.set(0.25)
        #expect(await eventually { watch.inspector.waveform?.amplitudeRange == -0.25 ... 0.25 })
        await displayFrames(3)
        #expect(watch.axes.draws == axisDraws, "the amplitude range is nothing to the time axis")
        #expect(watch.probe.updates == 1 && watch.probe.uploads == 1)
    }

    // MARK: Animated appearance (WP-813)

    /// An animated change of range gives one draw per display frame with interpolated
    /// values and no upload.
    @Test func anAnimatedValueRangeIsDrawnFrameByFrameWithInterpolatedValues() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Float>()
        let hosted = await host(Float(-90), handle, watch: watch) { low in
            SpectrogramView(feed: feed).valueRange(low.wrappedValue ... 0)
        }
        defer { hosted.close() }
        await displayFrames(3)
        let draws = watch.probe.draws, uploads = watch.probe.uploads, columns = watch.probe.uploadedColumns, recorded = watch.inspector.contents.count
        await handle.animate(to: -30, .linear(duration: 0.5))
        #expect(await eventually { watch.inspector.heatmap?.valueRange == -30 ... 0 }, "the animation ended at its target")
        await displayFrames(3)
        // What the renderer was shown during the animation.
        let lows = watch.inspector.contents.dropFirst(recorded).compactMap { content -> Float? in
            if case .heatmap(_, let appearance) = content { return appearance.valueRange.lowerBound }
            return nil
        }
        #expect(lows.count >= 2, "SwiftUI handed the surface more than the target: \(lows.count) values")
        #expect(lows.last == -30)
        #expect(lows.dropLast().allSatisfy { $0 > -90 && $0 < -30 }, "interpolated values, between where it began and where it ends: \(lows)")
        #expect(zip(lows, lows.dropFirst()).allSatisfy { $0 < $1 }, "a linear animation rises frame by frame: \(lows)")
        let frames = watch.probe.updates
        #expect(frames == lows.count, "every interpolated value was one update")
        #expect(watch.probe.draws - draws >= 1 && watch.probe.draws - draws <= frames, "no more than one draw per frame: \(watch.probe.draws - draws) draws for \(frames) frames")
        #expect(watch.probe.uploads == uploads && watch.probe.uploadedColumns == columns, "no upload")
        // When the animation is over nothing is drawn any more.
        let after = watch.probe.draws
        await displayFrames(5)
        #expect(watch.probe.draws == after)
    }

    /// Time span and frequency range animate as well; colour map and scale are discrete and
    /// change at once (ANI-1).
    @Test func spansAndRangesAnimateAndDiscreteValuesChangeAtOnce() async throws {
        let feed = try spectrum()
        struct Motion: Equatable {
            var span = 0.06
            var top = 20_000.0
            var magma = false
        }
        let watch = Watch(), handle = StateHandle<Motion>()
        let hosted = await host(Motion(), handle, watch: watch) { look in
            SpectrogramView(feed: feed)
                .timeSpan(look.wrappedValue.span)
                .frequencyRange(1_000 ... look.wrappedValue.top)
                .colorMap(look.wrappedValue.magma ? ListedColorMap.magma : ListedColorMap.viridis)
        }
        defer { hosted.close() }
        await displayFrames(3)
        let recorded = watch.inspector.contents.count, uploads = watch.probe.uploads
        await handle.animate(to: Motion(span: 0.02, top: 4_000, magma: true), .linear(duration: 0.5))
        #expect(await eventually { watch.inspector.heatmap?.timeSpan == 0.02 && watch.inspector.heatmap?.rowRange == 1_000 ... 4_000 })
        let shown = watch.inspector.contents.dropFirst(recorded).compactMap { content -> HeatmapAppearance? in
            if case .heatmap(_, let appearance) = content { return appearance }
            return nil
        }
        #expect(shown.count >= 2)
        #expect(shown.allSatisfy { $0.colorMap == AnyColorMap(ListedColorMap.magma) }, "the colour map changed at once, in the first frame")
        let spans = shown.compactMap(\.timeSpan), tops = shown.compactMap { $0.rowRange?.upperBound }
        // The first frame of an animation shows where it begins, with the discrete change made.
        #expect(isGlide(spans, from: 0.06, to: 0.02), "the time span glides: \(spans)")
        #expect(isGlide(tops, from: 20_000, to: 4_000), "the top of the range glides: \(tops)")
        #expect(shown.allSatisfy { $0.rowRange?.lowerBound == 1_000 }, "the end of the range that did not change stays where it is")
        #expect(watch.probe.uploads == uploads)
    }

    /// A value that is left to the feed animates from what it stands for.
    @Test func aSpanThatFollowsTheFeedAnimatesFromTheWholeHistory() async throws {
        // 64 columns of history at 100 columns a second: 0.64 s.
        let feed = try spectrum()
        let second = Watch(), other = StateHandle<Double>()
        let again = await host(0, other, watch: second) { span in
            SpectrogramView(feed: feed).timeSpan(span.wrappedValue)
        }
        defer { again.close() }
        #expect(second.inspector.heatmap?.timeSpan == nil, "a span that is no time shows the whole history")
        let recorded = second.inspector.contents.count
        await other.animate(to: 0.2, .linear(duration: 0.4))
        #expect(await eventually { second.inspector.heatmap?.timeSpan == 0.2 })
        let spans = second.inspector.contents.dropFirst(recorded).compactMap { content -> Double? in
            if case .heatmap(_, let appearance) = content { return appearance.timeSpan }
            return nil
        }
        #expect(isGlide(spans, from: 0.64, to: 0.2), "from the whole history, 0.64 s, down to 0.2 s: \(spans)")
    }

    // MARK: A size that animates (§8.9, as far as this process shows it)

    /// An animated change of the component's size is drawn during the transition and uploads
    /// nothing. How the hosted Metal view moves, tick by tick, is the subject of WP-822 and
    /// of the hosted acceptance WP-824.
    @Test func anAnimatedSizeIsDrawnOnTheWayAndUploadsNothing() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<CGSize>()
        let hosted = await host(CGSize(width: 120, height: 80), handle, watch: watch) { size in
            SpectrogramView(feed: feed).frame(width: size.wrappedValue.width, height: size.wrappedValue.height)
        }
        defer { hosted.close() }
        await displayFrames(3)
        let draws = watch.probe.draws, uploads = watch.probe.uploads
        await handle.animate(to: CGSize(width: 220, height: 150), .linear(duration: 0.5))
        await displayFrames(4)
        #expect(watch.probe.draws - draws >= 2, "frames were drawn on the way: \(watch.probe.draws - draws)")
        #expect(watch.probe.uploads == uploads && watch.probe.allocations == 1 && watch.probe.updates == 0, "a size is not appearance, and nothing is uploaded")
        let after = watch.probe.draws
        await displayFrames(5)
        #expect(watch.probe.draws == after, "the transition is over")
    }
}

/// True when `values` move from `from` to `to` without turning back, end at `to`, and pass
/// through at least one value strictly between the two: what an animation hands a view.
func isGlide(_ values: [Double], from: Double, to: Double) -> Bool {
    let low = min(from, to), high = max(from, to), falling = to < from
    guard values.last == to, values.allSatisfy({ $0 >= low && $0 <= high }) else { return false }
    guard values.contains(where: { $0 > low && $0 < high }) else { return false }
    return zip(values, values.dropFirst()).allSatisfy { falling ? $0 >= $1 : $0 <= $1 }
}

/// The two scales the hosted tests switch between, as one type: a `some FrequencyScale`
/// argument takes one concrete type per call site.
enum AnyScale: FrequencyScale {
    case linear, logarithmic

    func position(of hertz: Double) -> Double {
        self == .linear ? LinearFrequencyScale().position(of: hertz) : LogarithmicFrequencyScale().position(of: hertz)
    }

    func frequency(at position: Double) -> Double {
        self == .linear ? LinearFrequencyScale().frequency(at: position) : LogarithmicFrequencyScale().frequency(at: position)
    }
}
