import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// `.pinchScaling(_:)` on hosted components (WP-820, WP-821): a horizontal pinch changes the
/// time span, a vertical one the frequency, tempo or amplitude range; a bound modifier is
/// written and a constant is kept by the view (PINCH-5); limits resist and spring back
/// (PINCH-6); nothing is uploaded (PINCH-7); without the modifier nothing listens (PINCH-1).
///
/// There is no touch input in a package test. The pinches are scripted: the samples a
/// gesture would report are played into the surface through the seam the gestures use, and
/// take the same way from there, through the tracker and the arithmetic into SwiftUI's
/// state. What the gestures of each OS really report is the subject of the spike WP-818.
@MainActor
@Suite("Pinch scaling, hosted in the test process")
struct HostedPinchTests {
    /// What a hosted test sees of one component under a pinch.
    @MainActor
    final class Watch {
        let probe = RenderProbe()
        let inspector = SurfaceInspector()
        let script = PinchScript()
    }

    struct Knobs: Equatable {
        var span = 3.0
        var top = 24_000.0
        var axes: Axis.Set = [.horizontal, .vertical]
        var amplitude: ClosedRange<Float> = -1 ... 1
    }

    /// 33 bins up to 24 kHz, 100 columns a second, a history of 400 columns: 4 s.
    private func spectrum(axis: FeedAxis = .linearFrequency(binCount: 33, nyquist: 24_000), rows: Int = 33) throws -> HeatmapFeed {
        let feed = HeatmapFeed(history: 400)
        try FeedWriter.append(FeedWriter.columns(0 ..< 8, rows: rows), rows: rows, axis: axis, hop: 480, to: feed)
        return feed
    }

    private func host<Content: View>(_ handle: StateHandle<Knobs>, _ watch: Watch, @ViewBuilder content: @escaping (Binding<Knobs>) -> Content) async -> Hosted<some View> {
        let probe = watch.probe, inspector = watch.inspector, script = watch.script
        // The surface is 200 × 200 points whatever the window makes of its edges.
        let hosted = Hosted(size: CGSize(width: 320, height: 320), Stateful(Knobs(), handle) { knobs in
            content(knobs)
                .frame(width: 200, height: 200)
                .environment(\.dspRenderProbe, probe)
                .environment(\.dspSurfaceInspector, inspector)
                .environment(\.dspPinchScript, script)
        })
        #expect(await eventually { probe.draws >= 1 })
        await displayFrames(2)
        return hosted
    }

    /// Two fingers `reach` points either side of the middle of a 200 × 200 view.
    private func horizontal(_ reach: CGFloat) -> PinchSample {
        .touches(CGPoint(x: 100 - reach, y: 100), CGPoint(x: 100 + reach, y: 100))
    }

    private func vertical(_ reach: CGFloat) -> PinchSample {
        .touches(CGPoint(x: 100, y: 100 - reach), CGPoint(x: 100, y: 100 + reach))
    }

    // MARK: Off by default (PINCH-1)

    @Test func withoutTheModifierNoPinchIsHeard() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed).timeSpan(knobs.span).pinchScaling(knobs.wrappedValue.axes)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard }, "with axes enabled the surface listens")
        // No axes: the gesture is taken away, and a pinch reaches nobody.
        var knobs = Knobs()
        knobs.axes = []
        handle.set(knobs)
        #expect(await eventually { !watch.script.isHeard }, "no axis enabled: no gesture is installed")
        watch.script.feed(horizontal(20))
        watch.script.feed(horizontal(80))
        watch.script.end()
        await displayFrames(2)
        #expect(handle.value?.span == 3 && watch.probe.updates == 0)
    }

    // MARK: A spectrogram (WP-820)

    /// A horizontal pinch scales the time span and writes the binding; the frequencies stay.
    @Test func aHorizontalPinchScalesTheTimeSpanAndWritesItsBinding() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed).timeSpan(knobs.span).pinchScaling(knobs.wrappedValue.axes)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        let uploads = watch.probe.uploads, draws = watch.probe.draws
        watch.script.feed(horizontal(30))
        watch.script.feed(horizontal(45))
        #expect(await eventually { handle.value?.span == 2 }, "one and a half times the distance: two thirds of the span, written to the binding")
        watch.script.feed(horizontal(60))
        #expect(await eventually { handle.value?.span == 1.5 })
        watch.script.end()
        #expect(await eventually { watch.inspector.heatmap?.timeSpan == 1.5 }, "and the surface shows it")
        #expect(watch.inspector.heatmap?.rowRange == nil, "the frequencies are left alone")
        await displayFrames(3)
        #expect(handle.value?.span == 1.5, "inside the limits nothing springs back")
        #expect(watch.probe.draws > draws && watch.probe.uploads == uploads, "an appearance change: draws, and nothing uploaded (PINCH-7)")
    }

    /// A vertical pinch scales the frequency range. The modifier holds a constant, so the
    /// view keeps the scaled range itself, until the constant changes (PINCH-5).
    @Test func aVerticalPinchScalesTheFrequencyRangeAndTheViewKeepsItForAConstant() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed).frequencyRange(0 ... knobs.wrappedValue.top).pinchScaling(.vertical)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        #expect(watch.inspector.heatmap?.rowRange == 0 ... 24_000)
        let uploads = watch.probe.uploads
        watch.script.feed(vertical(25))
        watch.script.feed(vertical(50))
        #expect(await eventually { watch.inspector.heatmap?.rowRange == 6_000 ... 18_000 }, "twice the distance: half the range, around the middle")
        #expect(handle.value?.top == 24_000, "the constant is not the view's to write")
        watch.script.end()
        await displayFrames(3)
        #expect(watch.inspector.heatmap?.rowRange == 6_000 ... 18_000, "the view keeps the scaled range")
        #expect(watch.inspector.heatmap?.timeSpan == nil && watch.probe.uploads == uploads)
        // A horizontal pinch does nothing here: only the vertical axis is enabled.
        let updates = watch.probe.updates
        watch.script.feed(horizontal(20))
        watch.script.feed(horizontal(90))
        watch.script.end()
        await displayFrames(2)
        #expect(watch.probe.updates == updates, "a pinch along an axis that is not enabled does nothing (PINCH-3)")
        // The constant changes: the kept range is dropped.
        var knobs = Knobs()
        knobs.top = 12_000
        handle.set(knobs)
        #expect(await eventually { watch.inspector.heatmap?.rowRange == 0 ... 12_000 }, "until the constant changes")
    }

    /// Past a limit the span resists, and it springs back when the fingers lift (PINCH-6).
    @Test func pastItsLimitTheSpanResistsAndSpringsBack() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed).timeSpan(knobs.span).pinchScaling(.horizontal)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        // Twenty-four times the distance asks for an eighth of a second: a quarter of the limit.
        watch.script.feed(horizontal(4))
        watch.script.feed(horizontal(96))
        #expect(await eventually { (handle.value?.span ?? 3) < 0.5 }, "past the limit while the fingers are down")
        let resisted = try #require(handle.value?.span)
        #expect(resisted > 0.125, "but not as far as the fingers ask: \(resisted)")
        watch.script.end()
        #expect(await eventually { handle.value?.span == 0.5 }, "half a second: it springs back to the limit")
        #expect(await eventually { watch.inspector.heatmap?.timeSpan == 0.5 })
        // The other way: the whole history, 4 s, and no further.
        watch.script.feed(horizontal(90))
        watch.script.feed(horizontal(3))
        #expect(await eventually { (handle.value?.span ?? 0) > 4 })
        watch.script.end()
        #expect(await eventually { handle.value?.span == 4 }, "the feed's history")
    }

    /// The gesture of iOS 18 and later reports each finger by itself: the same pinch, told
    /// touch by touch.
    @Test func aPinchToldTouchByTouchScalesTheSame() async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed).timeSpan(knobs.span).pinchScaling(.horizontal)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        watch.script.touch(1, at: CGPoint(x: 70, y: 100))
        await displayFrames(1)
        #expect(handle.value?.span == 3, "one finger is no pinch")
        watch.script.touch(2, at: CGPoint(x: 130, y: 100))
        watch.script.touch(2, at: CGPoint(x: 190, y: 100))
        #expect(await eventually { handle.value?.span == 1.5 }, "from 60 to 120 points apart: half the span")
        // The first finger lifts: the pinch ends where it stood, and the other finger alone scales nothing.
        watch.script.touch(1, at: CGPoint(x: 70, y: 100), isDown: false)
        watch.script.touch(2, at: CGPoint(x: 40, y: 100))
        await displayFrames(2)
        #expect(handle.value?.span == 1.5)
        watch.script.end()
        #expect(handle.value?.span == 1.5)
    }

    /// Every OS path installs its gestures, and a pinch reaches the view on each of them. The
    /// OS of this run has all three gesture types, so the older paths can be installed here;
    /// what their gestures report to them is what WP-818 finds out.
    @Test(arguments: [PinchPath.touches, .magnify, .legacy])
    func everyPathInstallsItsGesturesAndHearsAPinch(path: PinchPath) async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed).timeSpan(knobs.span).pinchScaling(.horizontal).environment(\.dspPinchPath, path)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        // The sample this path's gestures make of a pinch that doubles the distance.
        switch path {
        case .touches:
            watch.script.feed(horizontal(30))
            watch.script.feed(horizontal(60))
        case .magnify:
            watch.script.feed(.magnification(scale: 1, start: CGPoint(x: 100, y: 100), firstFingerStart: CGPoint(x: 70, y: 100)))
            watch.script.feed(.magnification(scale: 2, start: CGPoint(x: 100, y: 100), firstFingerStart: CGPoint(x: 70, y: 100)))
        case .legacy:
            // The oldest path may know nothing of where the fingers are: the pinch is anchored in the middle.
            watch.script.feed(.legacy(scale: 1, firstFingerStart: nil, firstFingerTravel: nil))
            watch.script.feed(.legacy(scale: 2, firstFingerStart: nil, firstFingerTravel: nil))
        }
        #expect(await eventually { handle.value?.span == 1.5 }, "twice the distance: half the span")
        watch.script.end()
        #expect(PinchPath.current == .touches, "this run is on iOS 18 or later")
    }

    /// Before iOS 18 a pinch whose fingers land together gives the tracker no finger line:
    /// the drag half of the gestures reports nothing (WP-818). With both axes enabled such
    /// a pinch scales both: the time span and the frequency range (PINCH-8).
    @Test(arguments: [PinchPath.magnify, .legacy])
    func aPinchWhoseFingerLineIsNotKnownScalesEveryEnabledAxis(path: PinchPath) async throws {
        let feed = try spectrum()
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            SpectrogramView(feed: feed)
                .timeSpan(knobs.span)
                .frequencyRange(0 ... knobs.wrappedValue.top)
                .pinchScaling([.horizontal, .vertical])
                .environment(\.dspPinchPath, path)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        // What the gestures of this path report of two fingers that land together and move
        // apart to twice their distance, around the middle of the view.
        let middle = CGPoint(x: 100, y: 100)
        switch path {
        case .magnify:
            watch.script.feed(.magnification(scale: 1, start: middle, firstFingerStart: nil))
            watch.script.feed(.magnification(scale: 2, start: middle, firstFingerStart: nil))
        default:
            watch.script.feed(.legacy(scale: 1, firstFingerStart: nil, firstFingerTravel: nil))
            watch.script.feed(.legacy(scale: 2, firstFingerStart: nil, firstFingerTravel: nil))
        }
        #expect(await eventually { handle.value?.span == 1.5 }, "twice the distance: half the time span, \(String(describing: handle.value?.span))")
        watch.script.end()
        #expect(await eventually { watch.inspector.heatmap?.timeSpan == 1.5 })
        #expect(await eventually { watch.inspector.heatmap?.rowRange == 6_000 ... 18_000 },
                "and half the frequency range, around the middle: \(String(describing: watch.inspector.heatmap?.rowRange))")
    }

    // MARK: A tempogram and a chromagram

    @Test func aTempogramScalesItsTempoRange() async throws {
        let tempi = (0 ..< 64).map { 40.0 + 2 * Double($0) }
        let feed = try spectrum(axis: .tempo(beatsPerMinute: tempi), rows: 64)
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { _ in
            TempogramView(feed: feed).pinchScaling([.horizontal, .vertical])
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        watch.script.feed(vertical(30))
        watch.script.feed(vertical(60))
        #expect(await eventually { watch.inspector.heatmap?.rowRange != nil })
        let range = try #require(watch.inspector.heatmap?.rowRange)
        // Half of the 64 rows around the middle: rows 16 to 48, edge to edge, in beats per minute.
        expectClose([range.lowerBound, range.upperBound], [71, 135], .absolute(1e-9))
        #expect(watch.inspector.heatmap?.timeSpan == nil, "a vertical pinch leaves the time span alone")
        watch.script.end()
    }

    /// A chromagram's twelve rows are fixed: it scales in time only (§8.8).
    @Test func aChromagramScalesInTimeOnly() async throws {
        let feed = try spectrum(axis: .pitchClasses, rows: 12)
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { _ in
            ChromagramView(feed: feed).pinchScaling([.horizontal, .vertical])
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        let updates = watch.probe.updates
        watch.script.feed(vertical(20))
        watch.script.feed(vertical(80))
        watch.script.end()
        await displayFrames(3)
        #expect(watch.probe.updates == updates && watch.inspector.heatmap?.rowRange == nil, "a vertical pinch does nothing")
        watch.script.feed(horizontal(30))
        watch.script.feed(horizontal(60))
        #expect(await eventually { watch.inspector.heatmap?.timeSpan == 2 }, "a horizontal pinch scales the time span: half of 4 s")
        watch.script.end()
    }

    /// Without a modifier for it, the amplitude range a pinch leaves is the view's to keep.
    @Test func aWaveformKeepsThePinchedAmplitudeRangeItself() async throws {
        let feed = WaveformFeed(history: 64)
        try FeedWriter.append(pairs: [-0.5, 0.5, -0.25, 0.25], to: feed)
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { _ in
            WaveformView(feed: feed).pinchScaling(.vertical)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        watch.script.feed(vertical(25))
        watch.script.feed(vertical(50))
        #expect(await eventually { watch.inspector.waveform?.amplitudeRange == -0.5 ... 0.5 }, "twice the distance: half of full scale")
        watch.script.end()
        await displayFrames(2)
        #expect(watch.inspector.waveform?.amplitudeRange == -0.5 ... 0.5 && watch.inspector.waveform?.timeSpan == nil)
        // A feed that does not know its rate has no seconds to scale: a horizontal pinch is not enabled here anyway.
        #expect(handle.value == Knobs())
    }

    // MARK: A waveform (WP-821)

    @Test func aWaveformScalesItsTimeSpanHorizontallyAndItsAmplitudeRangeVertically() async throws {
        let feed = WaveformFeed(history: 800)
        // Pairs with a feature rate: 16 samples a block at 48 kHz make eight pairs a block.
        let pipeline = Pipeline<Samples, Samples>().appending(TestColumnsPairs(pairs: 8)).emit(to: feed)
        try pipeline.run(on: [Float](repeating: 0.25, count: 16 * 8), format: SignalFormat(sampleRate: 48_000), blockSize: 16)
        #expect(FeedReference.waveform(feed).shape.columnRate == 200, "a hop of 240 samples: 200 pairs a second")
        let watch = Watch(), handle = StateHandle<Knobs>()
        let hosted = await host(handle, watch) { knobs in
            WaveformView(feed: feed).amplitudeRange(knobs.amplitude).pinchScaling(knobs.wrappedValue.axes)
        }
        defer { hosted.close() }
        #expect(await eventually { watch.script.isHeard })
        let uploads = watch.probe.uploads
        // Vertical: the amplitude range, written to its binding.
        watch.script.feed(vertical(20))
        watch.script.feed(vertical(80))
        #expect(await eventually { handle.value?.amplitude == -0.25 ... 0.25 }, "four times the distance: a quarter of full scale")
        watch.script.end()
        #expect(await eventually { watch.inspector.waveform?.amplitudeRange == -0.25 ... 0.25 })
        #expect(watch.inspector.waveform?.timeSpan == nil)
        // Horizontal: the time span. No modifier sets it, so the view keeps it.
        watch.script.feed(horizontal(40))
        watch.script.feed(horizontal(80))
        #expect(await eventually { watch.inspector.waveform?.timeSpan == 2 }, "half of the history, 4 s")
        watch.script.end()
        await displayFrames(3)
        #expect(watch.inspector.waveform?.timeSpan == 2 && handle.value?.amplitude == -0.25 ... 0.25)
        #expect(watch.probe.uploads == uploads, "nothing uploaded")
        // A pinch that does not say where it is, as the oldest path's may not: anchored in the middle.
        watch.script.feed(.legacy(scale: 1, firstFingerStart: nil, firstFingerTravel: CGSize(width: 0, height: 12)))
        watch.script.feed(.legacy(scale: 0.5, firstFingerStart: nil, firstFingerTravel: CGSize(width: 0, height: 30)))
        #expect(await eventually { handle.value?.amplitude == -0.5 ... 0.5 }, "half the distance: twice the range")
        watch.script.end()
        // Past full scale the range resists and springs back.
        watch.script.feed(vertical(90))
        watch.script.feed(vertical(5))
        #expect(await eventually { (handle.value?.amplitude.upperBound ?? 0) > 1 })
        watch.script.end()
        #expect(await eventually { handle.value?.amplitude == -1 ... 1 }, "full scale")
    }
}

/// Turns every block into (minimum, maximum) pairs and says how many arrive a second: the
/// stage `TestPairs` with a spectral scope, so that the feed knows its rate.
struct TestColumnsPairs: PipelineStage {
    typealias Input = Samples
    typealias Output = Envelope
    let pairs: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.analysis(AnalysisStep(
            name: "TestColumnsPairs", key: self, output: .envelope(maximumCount: pairs),
            scope: .spectral(frameSize: 480, hopSize: 240, axis: .indices(count: 1))
        ) { () throws(DSPError) -> any AnalysisNode in TestPairsNode() }))
    }
}
