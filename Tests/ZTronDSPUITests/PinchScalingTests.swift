import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// Pinch scaling (WP-820, WP-821): what a pinch does to the time span and to the frequency,
/// tempo or amplitude range; the limits of PINCH-6, how a value resists past them and where
/// it comes to rest; where the scaled value is kept (PINCH-5); and what it costs (PINCH-7).
/// The pinches are scripted through the tracker's seam: no gesture runs here.
@MainActor
@Suite("Pinch scaling")
struct PinchScalingTests {
    nonisolated static let both: Axis.Set = [.horizontal, .vertical]

    private func horizontal(_ scale: CGFloat) -> PinchState {
        PinchState(axes: .horizontal, scale: scale, centroid: CGPoint(x: 100, y: 50), startCentroid: CGPoint(x: 100, y: 50))
    }

    private func vertical(_ scale: CGFloat, y: CGFloat = 50) -> PinchState {
        PinchState(axes: .vertical, scale: scale, centroid: CGPoint(x: 100, y: y), startCentroid: CGPoint(x: 100, y: y))
    }

    // MARK: The arithmetic

    @Test func fingersMovingApartShowLess() {
        let limits = 0.5 ... 60.0
        #expect(PinchScaling.extent(start: 10, scale: 2, limits: limits) == 5, "twice the distance: half the span")
        #expect(PinchScaling.extent(start: 10, scale: 0.5, limits: limits) == 20)
        #expect(PinchScaling.extent(start: 10, scale: 1, limits: limits) == 10)
        // A scale that is no scale changes nothing.
        #expect(PinchScaling.extent(start: 10, scale: 0, limits: limits) == 10)
        #expect(PinchScaling.extent(start: 10, scale: .nan, limits: limits) == 10)
        #expect(PinchScaling.extent(start: 10, scale: -2, limits: limits) == 10)
        #expect(PinchScaling.extent(start: 0, scale: 2, limits: limits) == 0)
    }

    /// PINCH-6: past a limit the scale resists, and it springs back on release.
    @Test func pastALimitTheValueResistsAndComesToRestAtTheLimit() {
        let limits = 0.5 ... 60.0
        // Asked for 0.125 s, a quarter of the shortest span.
        let short = PinchScaling.extent(start: 10, scale: 80, limits: limits)
        #expect(short < 0.5 && short > 0.125, "past the limit, but not as far as the fingers ask")
        expectClose(short, 0.5 * pow(0.25, PinchScaling.resistance), .relative(1e-12))
        #expect(PinchScaling.settled(short, limits: limits) == 0.5, "it springs back to the limit")
        // Asked for 240 s, four times the history.
        let long = PinchScaling.extent(start: 30, scale: 0.125, limits: limits)
        #expect(long > 60 && long < 240)
        #expect(PinchScaling.settled(long, limits: limits) == 60)
        // The further past the limit, the further the value, and ever more slowly.
        let further = PinchScaling.extent(start: 10, scale: 160, limits: limits)
        #expect(further < short && short / further < 2)
        // At the limit there is no step.
        expectClose(PinchScaling.extent(start: 10, scale: 20, limits: limits), 0.5, .relative(1e-12))
        #expect(PinchScaling.settled(7, limits: limits) == 7)
    }

    @Test func aTimeSpanGoesFromHalfASecondToTheFeedsHistory() {
        #expect(PinchScaling.spanLimits(history: 940, columnRate: 93.75) == 0.5 ... 940 / 93.75)
        #expect(PinchScaling.spanLimits(history: 30, columnRate: 100) == 0.3 ... 0.3, "a history shorter than half a second is the only span")
        #expect(PinchScaling.spanLimits(history: 0, columnRate: 100) == 0.01 ... 0.01)
    }

    /// PINCH-4: the value under the pinch's centroid stays under it.
    @Test func aWindowKeepsItsAnchorWhereItIs() {
        let full = 0.0 ... 100.0
        // The anchor, 30, sits a quarter of the way up a window of 40.
        let window = PinchScaling.window(extent: 40, anchor: 30, fraction: 0.25, within: full)
        #expect(window == 20 ... 60)
        #expect((30 - window.lowerBound) / (window.upperBound - window.lowerBound) == 0.25)
        // A window that would leave the axis is moved inside it.
        #expect(PinchScaling.window(extent: 40, anchor: 5, fraction: 0.5, within: full) == 0 ... 40)
        #expect(PinchScaling.window(extent: 40, anchor: 98, fraction: 0.5, within: full) == 60 ... 100)
        #expect(PinchScaling.window(extent: 100, anchor: 30, fraction: 0.25, within: full) == 0 ... 100)
        // A wider one, while it resists, reaches past both ends by the anchor's share.
        #expect(PinchScaling.window(extent: 120, anchor: 30, fraction: 0.25, within: full) == -5 ... 115)
        // Nonsense leaves the axis as it is.
        #expect(PinchScaling.window(extent: 0, anchor: 30, fraction: 0.5, within: full) == full)
        #expect(PinchScaling.window(extent: .nan, anchor: 30, fraction: 0.5, within: full) == full)
        #expect(PinchScaling.window(extent: 10, anchor: .infinity, fraction: 0.5, within: full) == full)
        #expect(PinchScaling.window(extent: 10, anchor: 50, fraction: 7, within: full) == 40 ... 50, "a fraction is kept between 0 and 1")
    }

    // MARK: The vertical axis of a heat map

    @Test func onALinearAxisARangeIsNoNarrowerThanSixteenRowsAndNoWiderThanTheAxis() {
        // 513 bins up to 24 kHz: 46.875 Hz per row.
        let layout = RowLayout(axis: .linearFrequency(binCount: 513, nyquist: 24_000), scale: AnyFrequencyScale(LinearFrequencyScale()), range: 2_000 ... 10_000)
        let pinch = RowPinch(layout: layout, anchorFraction: 0.25)
        #expect(pinch.limits == 750 ... 24_000, "16 rows of 46.875 Hz, and the whole axis")
        // Twice the distance: half the range, around 4 kHz, which stays a quarter of the way up.
        let half = pinch.range(scale: 2)
        #expect(half == 3_000 ... 7_000)
        #expect(layout.fraction(of: 4_000) == 0.25 && RowLayout(axis: layout.axis, scale: layout.scale, range: half).fraction(of: 4_000) == 0.25)
        // Far past the narrowest: resists while the fingers are down, rests at 16 rows.
        let squeezed = pinch.range(scale: 1_000)
        #expect(squeezed.upperBound - squeezed.lowerBound < 750 && squeezed.upperBound - squeezed.lowerBound > 8)
        let rested = pinch.range(scale: 1_000, resisting: false)
        expectClose(rested.upperBound - rested.lowerBound, 750, .relative(1e-12))
        expectClose((4_000 - rested.lowerBound) / 750, 0.25, .absolute(1e-9), "still anchored")
        // Far past the widest: rests at the whole axis.
        #expect(pinch.range(scale: 0.001, resisting: false) == 0 ... 24_000)
    }

    @Test func onALogarithmicAxisARangeIsNoNarrowerThanAnEighthOfAnOctave() {
        let layout = RowLayout(axis: .linearFrequency(binCount: 2_049, nyquist: 24_000), scale: AnyFrequencyScale(LogarithmicFrequencyScale()), range: 100 ... 6_400)
        let pinch = RowPinch(layout: layout, anchorFraction: 0.5)
        // The axis counts in octaves: an eighth of one, and from 20 Hz to 24 kHz.
        expectClose(pinch.limits.lowerBound, 0.125, .relative(1e-9))
        expectClose(pinch.limits.upperBound, log2(24_000.0 / 20), .relative(1e-12))
        // Twice the distance: three of the six octaves, around 800 Hz, the middle.
        let half = pinch.range(scale: 2)
        expectClose(half.lowerBound, 800 / pow(2, 1.5), .relative(1e-9))
        expectClose(half.upperBound, 800 * pow(2, 1.5), .relative(1e-9))
        let rested = pinch.range(scale: 10_000, resisting: false)
        expectClose(rested.upperBound / rested.lowerBound, PinchScaling.narrowestRatio, .relative(1e-9), "an eighth of an octave")
        expectClose(sqrt(rested.upperBound * rested.lowerBound), 800, .relative(1e-9), "around the anchor")
    }

    @Test(arguments: [FeedAxis.mel(centers: (0 ..< 64).map { 40 * pow(1.09, Double($0)) }), .constantQ(minimumFrequency: 55, binsPerOctave: 12, binCount: 72)])
    func bandsAndConstantQBinsAreNoNarrowerThanAnEighthOfAnOctaveEither(axis: FeedAxis) {
        let layout = RowLayout(axis: axis, scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        let pinch = RowPinch(layout: layout, anchorFraction: 0.5)
        #expect(pinch.limits.upperBound == Double(axis.rowCount), "the axis counts in rows")
        let rested = pinch.range(scale: 1e6, resisting: false)
        expectClose(rested.upperBound / rested.lowerBound, PinchScaling.narrowestRatio, .relative(1e-6))
        // The middle of the axis stays in the middle.
        let middle = layout.value(atFraction: 0.5)
        expectClose(RowLayout(axis: axis, scale: layout.scale, range: rested).fraction(of: middle), 0.5, .absolute(1e-6))
    }

    @Test func aTempoRangeIsNoNarrowerThanSixteenRows() {
        let tempi = (0 ..< 120).map { 30.0 + 2 * Double($0) }
        let layout = RowLayout(axis: .tempo(beatsPerMinute: tempi), scale: AnyFrequencyScale(LinearFrequencyScale()), range: nil)
        let pinch = RowPinch(layout: layout, anchorFraction: 0.5)
        #expect(pinch.limits == 16 ... 120)
        let rested = pinch.range(scale: 1_000, resisting: false)
        expectClose(rested.upperBound - rested.lowerBound, 32, .relative(1e-9), "16 rows of 2 beats per minute")
        // An axis of fewer than 16 rows cannot be scaled at all.
        let small = RowPinch(layout: RowLayout(axis: .tempo(beatsPerMinute: [60, 90, 120]), scale: layout.scale, range: nil))
        #expect(small.limits == 3 ... 3 && small.range(scale: 4, resisting: false) == small.layout.visibleRange)
    }

    /// Axes on which there is nothing to scale: one bin, a span below an eighth of an octave,
    /// no rows, rows that are no numbers. Nothing traps, and the range stays what it is.
    @Test func axesWithNothingToScaleKeepTheirRange() {
        let linear = AnyFrequencyScale(LinearFrequencyScale())
        let single = RowPinch(layout: RowLayout(axis: .linearFrequency(binCount: 1, nyquist: 24_000), scale: linear, range: nil))
        #expect(single.limits == 0 ... 0 || single.limits.upperBound == single.limits.lowerBound, "one bin: one range")
        // Three bands within three hundredths of an octave: the whole axis is the narrowest there is.
        let close = RowPinch(layout: RowLayout(axis: .mel(centers: [1_000, 1_010, 1_020]), scale: linear, range: nil))
        #expect(close.limits == 3 ... 3 && close.range(scale: 8, resisting: false) == close.layout.visibleRange)
        let empty = RowPinch(layout: RowLayout(axis: .mel(centers: []), scale: linear, range: nil))
        #expect(empty.limits == 0 ... 0)
        let nonsense = RowPinch(layout: RowLayout(axis: .mel(centers: [.nan, .nan]), scale: linear, range: nil))
        #expect(nonsense.range(scale: 1.5) == nonsense.layout.visibleRange)
    }

    /// The value under the centroid stays under it when the centroid moves, too.
    @Test func theAnchorFollowsTheCentroid() {
        let layout = RowLayout(axis: .linearFrequency(binCount: 513, nyquist: 24_000), scale: AnyFrequencyScale(LinearFrequencyScale()), range: 0 ... 8_000)
        let pinch = RowPinch(layout: layout, anchorFraction: 0.5)
        // The pinch began on 4 kHz, in the middle; the centroid has moved a quarter of the height up.
        let range = pinch.range(scale: 2, centroidFraction: 0.75)
        #expect(range == 1_000 ... 5_000, "4 kHz sits three quarters of the way up now")
    }

    // MARK: A heat map under a pinch (WP-820)

    private func shape(axis: FeedAxis = .linearFrequency(binCount: 513, nyquist: 24_000), history: Int = 1_000) -> FeedShape {
        FeedShape(axis: axis, columnRate: 100, history: history)
    }

    @Test func aHorizontalPinchChangesTheTimeSpanAndAVerticalOneTheFrequencyRange() {
        var appearance = HeatmapAppearance()
        appearance.timeSpan = 4
        appearance.rowRange = 2_000 ... 10_000
        let pinch = HeatmapPinch(appearance: appearance, shape: shape(), scalesRows: true, anchorFraction: 0.5)
        // Horizontal: the span, and nothing else.
        #expect(pinch.timeSpan(for: horizontal(2), resisting: true) == 2)
        #expect(pinch.rowRange(for: horizontal(2), height: 100, resisting: true) == nil, "a horizontal pinch leaves the frequencies alone")
        // Vertical: the range, and nothing else.
        #expect(pinch.rowRange(for: vertical(2), height: 100, resisting: true) == 4_000 ... 8_000)
        #expect(pinch.timeSpan(for: vertical(2), resisting: true) == nil)
        // A diagonal pinch scales both.
        let diagonal = PinchState(axes: Self.both, scale: 0.5, centroid: CGPoint(x: 0, y: 50), startCentroid: CGPoint(x: 0, y: 50))
        #expect(pinch.timeSpan(for: diagonal, resisting: true) == 8)
        #expect(pinch.rowRange(for: diagonal, height: 100, resisting: true) == 0 ... 16_000, "moved inside the axis")
        // A pinch along an axis that is not enabled scales nothing.
        let none = PinchState(axes: [], scale: 3, centroid: nil, startCentroid: nil)
        #expect(pinch.timeSpan(for: none, resisting: true) == nil && pinch.rowRange(for: none, height: 100, resisting: true) == nil)
    }

    @Test func theTimeSpanOfAHeatMapResistsAtHalfASecondAndAtTheHistory() {
        var appearance = HeatmapAppearance()
        appearance.timeSpan = 4
        let pinch = HeatmapPinch(appearance: appearance, shape: shape(), scalesRows: true, anchorFraction: 0.5)
        #expect(pinch.spanLimits == 0.5 ... 10, "a history of 1 000 columns at 100 a second")
        let tight = try! #require(pinch.timeSpan(for: horizontal(64), resisting: true))
        #expect(tight < 0.5 && tight > 4.0 / 64)
        #expect(pinch.timeSpan(for: horizontal(64), resisting: false) == 0.5, "springs back")
        let wide = try! #require(pinch.timeSpan(for: horizontal(0.1), resisting: true))
        #expect(wide > 10 && wide < 40)
        #expect(pinch.timeSpan(for: horizontal(0.1), resisting: false) == 10)
    }

    /// A span that follows the feed starts from the whole history.
    @Test func aPinchStartsFromWhatIsShown() {
        let whole = HeatmapPinch(appearance: HeatmapAppearance(), shape: shape(), scalesRows: true, anchorFraction: 0.5)
        #expect(whole.span == 10 && whole.timeSpan(for: horizontal(4), resisting: true) == 2.5)
        #expect(whole.rows?.start == 0 ... 24_000)
        // The centroid's height when the pinch began is where the anchor sits.
        let low = HeatmapPinch(appearance: HeatmapAppearance(), shape: shape(), scalesRows: true, anchorFraction: 0.1)
        let range = try! #require(low.rowRange(for: vertical(2, y: 90), height: 100, resisting: true))
        expectClose([range.lowerBound, range.upperBound], [1_200, 13_200], .absolute(1e-6), "2.4 kHz stays a tenth of the way up")
    }

    /// A feed that does not say how many columns a second it gets has no seconds to scale.
    @Test func withoutAFeatureRateTheTimeSpanIsNotScaled() {
        let pinch = HeatmapPinch(appearance: HeatmapAppearance(), shape: FeedShape(axis: .indices(count: 40), columnRate: nil, history: 100),
                                 scalesRows: true, anchorFraction: 0.5)
        #expect(pinch.span == nil && pinch.timeSpan(for: horizontal(2), resisting: true) == nil)
        #expect(pinch.rowRange(for: vertical(2), height: 100, resisting: true) == 9.5 ... 29.5, "rows are scaled all the same: rows 10 to 29, edge to edge")
        let unattached = HeatmapPinch(appearance: HeatmapAppearance(), shape: FeedShape(axis: nil, columnRate: nil, history: 512), scalesRows: true, anchorFraction: 0.5)
        #expect(unattached.rows == nil && unattached.rowRange(for: vertical(2), height: 100, resisting: true) == nil)
    }

    /// §8.8: a chromagram's twelve rows are fixed.
    @Test func aChromagramScalesInTimeOnly() {
        let chroma = FeedShape(axis: .pitchClasses, columnRate: 50, history: 500)
        let pinch = HeatmapPinch(appearance: HeatmapAppearance(), shape: chroma, scalesRows: false, anchorFraction: 0.5)
        #expect(pinch.rows == nil && pinch.rowRange(for: vertical(3), height: 100, resisting: true) == nil)
        #expect(pinch.timeSpan(for: horizontal(2), resisting: true) == 5)
        // Pitch classes are fixed whichever component shows them.
        #expect(HeatmapPinch(appearance: HeatmapAppearance(), shape: chroma, scalesRows: true, anchorFraction: 0.5).rows == nil)
    }

    @Test func aTempogramScalesItsTempoRange() {
        let tempi = (0 ..< 100).map { 40.0 + 2 * Double($0) }
        let pinch = HeatmapPinch(appearance: HeatmapAppearance(), shape: shape(axis: .tempo(beatsPerMinute: tempi)), scalesRows: true, anchorFraction: 0.5)
        let range = try! #require(pinch.rowRange(for: vertical(2), height: 100, resisting: true))
        // Half of the hundred rows, around the middle of the axis: 89 … 189 beats per minute.
        expectClose(range.lowerBound, 89, .absolute(1e-9))
        expectClose(range.upperBound, 189, .absolute(1e-9))
    }

    @Test func thePointUnderTheFingersIsMeasuredFromTheBottom() {
        #expect(HeatmapPinch.fraction(of: CGPoint(x: 5, y: 25), height: 100) == 0.75)
        #expect(HeatmapPinch.fraction(of: CGPoint(x: 5, y: 100), height: 100) == 0)
        #expect(HeatmapPinch.fraction(of: CGPoint(x: 5, y: -40), height: 100) == 1, "kept inside the view")
        #expect(HeatmapPinch.fraction(of: nil, height: 100) == nil && HeatmapPinch.fraction(of: .zero, height: 0) == nil)
    }

    // MARK: A waveform under a pinch (WP-821)

    @Test func aWaveformScalesItsTimeSpanHorizontallyAndItsAmplitudeRangeVertically() {
        var appearance = WaveformAppearance()
        appearance.timeSpan = 2
        let pinch = WaveformPinch(appearance: appearance, shape: FeedShape(axis: nil, columnRate: 200, history: 2_000), anchorFraction: 0.5)
        #expect(pinch.timeSpan(for: horizontal(4), resisting: true) == 0.5)
        #expect(pinch.amplitudeRange(for: horizontal(4), height: 80, resisting: true) == nil)
        #expect(pinch.amplitudeRange(for: vertical(4, y: 40), height: 80, resisting: true) == -0.25 ... 0.25, "four times the distance: a quarter of full scale")
        #expect(pinch.timeSpan(for: vertical(4), resisting: true) == nil)
        #expect(pinch.spanLimits == 0.5 ... 10)
        // A waveform that does not know its rate scales its amplitude only.
        let unknown = WaveformPinch(appearance: WaveformAppearance(), shape: FeedShape(axis: nil, columnRate: nil, history: 2_048), anchorFraction: 0.5)
        #expect(unknown.timeSpan(for: horizontal(2), resisting: true) == nil)
        #expect(unknown.amplitudeRange(for: vertical(2, y: 40), height: 80, resisting: true) == -0.5 ... 0.5)
    }

    /// PINCH-6: amplitude from 1/1 000 of full scale to full scale.
    @Test func theAmplitudeRangeGoesFromAThousandthOfFullScaleToFullScale() {
        let pinch = AmplitudePinch(range: -1 ... 1, anchorFraction: 0.5)
        #expect(pinch.limits == 0.002 ... 2)
        let tiny = pinch.range(scale: 1e6)
        #expect(tiny.upperBound - tiny.lowerBound < 0.002, "resists past the smallest")
        let rested = pinch.range(scale: 1e6, resisting: false)
        expectClose(Double(rested.upperBound - rested.lowerBound), 0.002, .relative(1e-5))
        #expect(pinch.range(scale: 0.01, resisting: false) == -1 ... 1, "no wider than full scale")
        // The amplitude under the centroid stays there: 0.5 is three quarters of the way up.
        let high = AmplitudePinch(range: -1 ... 1, anchorFraction: 0.75).range(scale: 2)
        #expect(high == -0.25 ... 0.75)
        #expect(AmplitudePinch(range: -0.5 ... 0.5, anchorFraction: 0.5).range(scale: 0.5) == -1 ... 1)
    }

    // MARK: Where the scaled value is kept (PINCH-5)

    @Test func aBoundModifierIsWrittenAndAConstantIsKeptByTheView() {
        // A binding: the pinch writes it, and the view keeps nothing.
        let span = Box(10.0)
        let bound: AppearanceSetting<Double>? = .bound(span.binding)
        #expect(bound.shown(keeping: nil) == 10)
        #expect(bound.storing(6.5) == nil)
        #expect(span.value == 6.5 && span.writes == 1, "the pinch wrote the binding")
        #expect(bound.shown(keeping: nil) == 6.5)
        #expect(bound.storing(6.5) == nil && span.writes == 1, "an equal value is not written again")
        #expect(bound.shown(keeping: Kept(base: 10, value: 99)) == 6.5, "what the view kept before does not count once there is a binding")

        // A constant: the view keeps the scaled value until the constant changes.
        let constant: AppearanceSetting<Double>? = .constant(10)
        let kept = constant.storing(6.5)
        #expect(kept == Kept(base: 10, value: 6.5))
        #expect(constant.shown(keeping: kept) == 6.5)
        let changed: AppearanceSetting<Double>? = .constant(12)
        #expect(changed.shown(keeping: kept) == 12, "the constant changed: the kept value is dropped")
        #expect(constant.shown(keeping: nil) == 10)

        // No modifier at all: the view keeps the value, until a modifier appears.
        let absent: AppearanceSetting<Double>? = nil
        let free = absent.storing(3)
        #expect(free == Kept(base: nil, value: 3) && absent.shown(keeping: free) == 3 && absent.shown(keeping: nil) == nil)
        #expect(constant.shown(keeping: free) == 10)
        #expect(constant?.constant == 10 && bound?.constant == nil && bound?.value == 6.5 && constant?.value == 10)
        // A constant is the same setting as an equal constant; a binding offers no identity
        // and never counts as unchanged.
        #expect(constant == .constant(10) && constant != .constant(11) && bound != bound && constant != bound)
    }

    // MARK: What a pinch costs (PINCH-7)

    /// A pinch is an appearance change: one draw per display frame while it lasts, nothing
    /// uploaded. A scripted pinch goes through the tracker and the arithmetic to a surface.
    @Test func aPinchIsOneDrawPerDisplayFrameAndUploadsNothing() async throws {
        // 513 bins, 100 columns a second, a history of 400 columns.
        let axis = FeedAxis.linearFrequency(binCount: 513, nyquist: 24_000)
        let feed = HeatmapFeed(history: 400)
        try FeedWriter.append(FeedWriter.columns(0 ..< 40, rows: 513), rows: 513, axis: axis, hop: 480, to: feed)
        await mainQueueDrained()
        var appearance = HeatmapAppearance()
        var stage = try await Stage(.heatmap(feed, appearance), size: CGSize(width: 64, height: 64))
        stage.settle()
        let draws = stage.probe.draws, uploads = stage.probe.uploads, columns = stage.probe.uploadedColumns
        var tracker = PinchTracker(enabled: Self.both)
        var pinch: HeatmapPinch?
        var frames = 0
        // Two fingers on a diagonal move apart, one step per display frame.
        for step in 0 ... 20 {
            let reach = 20 + CGFloat(step) * 3
            let update = tracker.update(.touches(CGPoint(x: 32 - reach, y: 32 - reach), CGPoint(x: 32 + reach, y: 32 + reach)))
            let state = try #require(update)
            #expect(state.axes == Self.both)
            if pinch == nil {
                pinch = HeatmapPinch(appearance: appearance, shape: FeedReference.heatmap(feed).shape, scalesRows: true,
                                     anchorFraction: HeatmapPinch.fraction(of: state.startCentroid, height: 64) ?? 0.5)
            }
            let current = try #require(pinch)
            appearance.timeSpan = current.timeSpan(for: state, resisting: true)
            appearance.rowRange = current.rowRange(for: state, height: 64, resisting: true)
            stage.show(.heatmap(feed, appearance))
            if step > 0 {
                frames += 1
                #expect(stage.tick())
                #expect(stage.probe.draws == draws + frames, "one draw for frame \(step)")
            }
        }
        // The pinch's first report scales nothing, but it turns "the whole history" and "the
        // whole axis" into the numbers they stand for: one update, drawn with the next frame.
        #expect(frames == 20 && stage.probe.updates == 21)
        #expect(stage.probe.uploads == uploads && stage.probe.uploadedColumns == columns && stage.probe.allocations == 1, "nothing uploaded")
        // The pinch changed what is shown: a shorter span and a narrower range.
        #expect(try #require(appearance.timeSpan) < 4 && (try #require(appearance.rowRange)).upperBound < 24_000)
        #expect(stage.settle() == 0)
    }
}
