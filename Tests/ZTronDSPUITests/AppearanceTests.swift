import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

/// The values behind the appearance modifiers (WP-812) and the vector SwiftUI interpolates
/// (WP-813): what a component makes of the environment, and what an animation frame shows.
@MainActor
@Suite("Appearance values")
struct AppearanceTests {
    // MARK: What a component makes of its environment

    @Test func aHeatMapTakesItsDefaultsFromItsRoleAndEverythingElseFromTheModifiers() {
        let nothing = HeatmapSurface.appearance(role: .spectrogram, colorMap: nil, valueRange: nil, frequencyScale: nil, rowRange: nil, timeSpan: nil)
        #expect(nothing == HeatmapAppearance(), "viridis, −90 … 0, a linear axis, everything visible, rows blended")
        #expect(nothing.valueRange == -90 ... 0 && nothing.rowRange == nil && nothing.timeSpan == nil && nothing.rowInterpolation == .linear)

        let set = HeatmapSurface.appearance(
            role: .spectrogram, colorMap: AnyColorMap(ListedColorMap.inferno), valueRange: -60 ... -6,
            frequencyScale: AnyFrequencyScale(MelFrequencyScale(formula: SlaneyMelFormula())), rowRange: 80 ... 9_000, timeSpan: 12)
        #expect(set.colorMap == AnyColorMap(ListedColorMap.inferno) && set.valueRange == -60 ... -6)
        #expect(set.frequencyScale == AnyFrequencyScale(MelFrequencyScale(formula: SlaneyMelFormula())) && set.rowRange == 80 ... 9_000 && set.timeSpan == 12)

        let chroma = HeatmapSurface.appearance(role: .chromagram, colorMap: nil, valueRange: nil, frequencyScale: nil, rowRange: nil, timeSpan: nil)
        #expect(chroma.valueRange == 0 ... 1 && chroma.rowInterpolation == .nearest, "twelve cells with hard edges (WP-805)")
        #expect(HeatmapSurface.appearance(role: .chromagram, colorMap: nil, valueRange: 0 ... 0.5, frequencyScale: nil, rowRange: nil, timeSpan: nil).valueRange == 0 ... 0.5)
        let tempo = HeatmapSurface.appearance(role: .tempogram, colorMap: nil, valueRange: nil, frequencyScale: nil, rowRange: nil, timeSpan: nil)
        #expect(tempo.valueRange == 0 ... 1 && tempo.rowInterpolation == .linear)
        #expect(HeatmapRole.spectrogram == .generic && HeatmapRole.chromagram.scalesRows == false && HeatmapRole.tempogram.scalesRows)
        #expect(HeatmapRole.chromagram.fallbackAxis == .pitchClasses && HeatmapRole.tempogram.fallbackAxis == nil)
    }

    /// A span that is no time shows the whole history instead of no picture.
    @Test(arguments: [0.0, -3, .infinity, .nan])
    func aTimeSpanThatIsNoTimeShowsTheWholeHistory(span: Double) {
        #expect(HeatmapSurface.appearance(role: .generic, colorMap: nil, valueRange: nil, frequencyScale: nil, rowRange: nil, timeSpan: span).timeSpan == nil)
        #expect(WaveformSurface.appearance(amplitudeRange: nil, timeSpan: span, isDark: false).timeSpan == nil)
    }

    @Test func aWaveformIsBlackOnLightAndWhiteOnDark() {
        let light = WaveformSurface.appearance(amplitudeRange: nil, timeSpan: nil, isDark: false)
        #expect(light.fill == .black && light.amplitudeRange == -1 ... 1 && light.timeSpan == nil)
        let dark = WaveformSurface.appearance(amplitudeRange: -0.25 ... 0.25, timeSpan: 3, isDark: true)
        #expect(dark.fill == .white && dark.amplitudeRange == -0.25 ... 0.25 && dark.timeSpan == 3)
    }

    @Test func theAxesAComponentCanShow() {
        #expect(DSPAxis.frequency.isVertical && DSPAxis.pitchClass.isVertical && DSPAxis.tempo.isVertical && !DSPAxis.time.isVertical)
    }

    // MARK: The animatable vector (ANI-1)

    @Test func theVectorHoldsTheContinuousValuesAndNothingElse() {
        var appearance = HeatmapAppearance()
        appearance.valueRange = -70 ... -10
        appearance.timeSpan = 4
        appearance.rowRange = 100 ... 8_000
        let vector = appearance.vector(fullRows: 0 ... 24_000, fullSpan: 9.4)
        #expect(vector.lanes == SIMD8(-70, -10, 4, 100, 8_000, 0, 0, 3))
        // Colour map, scale and interpolation are discrete: they are not in the vector.
        var other = appearance
        other.colorMap = AnyColorMap(TurboColorMap())
        other.frequencyScale = AnyFrequencyScale(LogarithmicFrequencyScale())
        other.rowInterpolation = .nearest
        #expect(other.vector(fullRows: 0 ... 24_000, fullSpan: 9.4) == vector)
        // What is left to the feed takes the feed's extent, when the feed says it.
        let free = HeatmapAppearance()
        #expect(free.vector(fullRows: 0 ... 24_000, fullSpan: 9.4).lanes == SIMD8(-90, 0, 9.4, 0, 24_000, 0, 0, 3))
        #expect(free.vector(fullRows: nil, fullSpan: nil).lanes == SIMD8(-90, 0, 0, 0, 0, 0, 0, 0), "nothing is known of the feed")
        #expect(free.vector(fullRows: nil, fullSpan: 2).lanes[AppearanceVector.Lane.known] == 1)
        #expect(free.vector(fullRows: 0 ... 5, fullSpan: nil).lanes[AppearanceVector.Lane.known] == 2)

        var wave = WaveformAppearance()
        wave.amplitudeRange = -0.5 ... 0.25
        #expect(wave.vector(fullSpan: 6).lanes == SIMD8(0, 0, 6, 0, 0, -0.5, 0.25, 1))
        wave.timeSpan = 2
        #expect(wave.vector(fullSpan: nil).lanes == SIMD8(0, 0, 2, 0, 0, -0.5, 0.25, 1))
        #expect(WaveformAppearance().vector(fullSpan: nil).lanes == SIMD8(0, 0, 0, 0, 0, -1, 1, 0))
    }

    @Test func theVectorIsAVectorSpace() {
        let first = AppearanceVector(lanes: SIMD8(1, 2, 3, 4, 5, 6, 7, 3)), second = AppearanceVector(lanes: SIMD8(10, 20, 30, 40, 50, 60, 70, 3))
        #expect((first + second).lanes == SIMD8(11, 22, 33, 44, 55, 66, 77, 6))
        #expect((second - first).lanes == SIMD8(9, 18, 27, 36, 45, 54, 63, 0))
        var scaled = first
        scaled.scale(by: 0.5)
        #expect(scaled.lanes == SIMD8(0.5, 1, 1.5, 2, 2.5, 3, 3.5, 1.5))
        #expect(AppearanceVector.zero.lanes == .zero && first + .zero == first && first - first == .zero)
        #expect(AppearanceVector(lanes: SIMD8(3, 4, 0, 0, 0, 0, 0, 0)).magnitudeSquared == 25)
    }

    /// What an animation frame shows: the interpolated values where an animation is on its
    /// way, and the appearance itself at rest.
    @Test func anAnimationFrameShowsTheInterpolatedValues() {
        var target = HeatmapAppearance()
        target.valueRange = -60 ... -20
        target.timeSpan = 2
        target.rowRange = 1_000 ... 4_000
        let rest = target.vector(fullRows: 0 ... 24_000, fullSpan: 10)
        #expect(target.showing(rest, rest: rest) == target, "at rest")

        // Half way from −90 … 0, 6 s and 0 … 8 kHz.
        var start = HeatmapAppearance()
        start.timeSpan = 6
        start.rowRange = 0 ... 8_000
        let from = start.vector(fullRows: 0 ... 24_000, fullSpan: 10)
        var delta = rest - from
        delta.scale(by: 0.5)
        let frame = target.showing(from + delta, rest: rest)
        #expect(frame.valueRange == -75 ... -10 && frame.timeSpan == 4 && frame.rowRange == 500 ... 6_000)
        #expect(frame.colorMap == target.colorMap && frame.frequencyScale == target.frequencyScale, "discrete values are the target's")
        // Only the value range moves: the other values stay exactly what they are.
        var onlyRange = rest
        onlyRange.lanes[AppearanceVector.Lane.valueLow] = -80
        let partial = target.showing(onlyRange, rest: rest)
        #expect(partial.valueRange == -80 ... -20 && partial.timeSpan == 2 && partial.rowRange == 1_000 ... 4_000)
    }

    /// A value that is left to the feed animates through numbers and comes to rest as "left
    /// to the feed", so that it keeps following the feed afterwards.
    @Test func aValueLeftToTheFeedAnimatesAndRestsAsLeftToTheFeed() {
        let target = HeatmapAppearance()
        let rest = target.vector(fullRows: 0 ... 24_000, fullSpan: 10)
        var mid = rest
        mid.lanes[AppearanceVector.Lane.timeSpan] = 7
        mid.lanes[AppearanceVector.Lane.rowHigh] = 16_000
        let frame = target.showing(mid, rest: rest)
        #expect(frame.timeSpan == 7 && frame.rowRange == 0 ... 16_000, "on the way to the whole history and the whole axis")
        #expect(target.showing(rest, rest: rest).timeSpan == nil && target.showing(rest, rest: rest).rowRange == nil, "arrived: left to the feed again")
    }

    /// Between a feed whose extent is known and one whose extent is not, the span and the
    /// range are not interpolated: half of "not known" is no span.
    @Test func whereTheFeedsExtentIsNotKnownTheValueChangesAtOnce() {
        var target = HeatmapAppearance()
        target.timeSpan = 3
        target.valueRange = -50 ... 0
        let rest = target.vector(fullRows: 0 ... 24_000, fullSpan: 10)
        let unknown = HeatmapAppearance().vector(fullRows: nil, fullSpan: nil)
        var delta = rest - unknown
        delta.scale(by: 0.25)
        let frame = target.showing(unknown + delta, rest: rest)
        #expect(frame.timeSpan == 3 && frame.rowRange == nil, "the target's, at once")
        #expect(frame.valueRange == -80 ... 0, "the value range is always known and glides")

        var wave = WaveformAppearance()
        wave.timeSpan = 3
        let waveRest = wave.vector(fullSpan: 10)
        var waveDelta = waveRest - WaveformAppearance().vector(fullSpan: nil)
        waveDelta.scale(by: 0.5)
        #expect(wave.showing(WaveformAppearance().vector(fullSpan: nil) + waveDelta, rest: waveRest).timeSpan == 3)
    }

    /// A spring may overshoot: bounds that cross are put in order, and a span that is not
    /// positive is not shown.
    @Test func anOvershootDoesNotBreakARange() {
        var target = HeatmapAppearance()
        target.valueRange = -10 ... -5
        target.timeSpan = 1
        target.rowRange = 100 ... 200
        let rest = target.vector(fullRows: 0 ... 24_000, fullSpan: 10)
        var over = rest
        over.lanes[AppearanceVector.Lane.valueLow] = -2
        over.lanes[AppearanceVector.Lane.rowLow] = 250
        over.lanes[AppearanceVector.Lane.timeSpan] = -0.1
        let frame = target.showing(over, rest: rest)
        #expect(frame.valueRange == -5 ... -2 && frame.rowRange == 200 ... 250 && frame.timeSpan == 1)
        var nonsense = rest
        nonsense.lanes[AppearanceVector.Lane.valueHigh] = .nan
        nonsense.lanes[AppearanceVector.Lane.rowHigh] = .infinity
        #expect(target.showing(nonsense, rest: rest) == target, "values that are no numbers are not shown")

        var wave = WaveformAppearance()
        wave.amplitudeRange = -0.5 ... 0.5
        wave.timeSpan = 2
        let waveRest = wave.vector(fullSpan: 4)
        var waveOver = waveRest
        waveOver.lanes[AppearanceVector.Lane.amplitudeLow] = 0.75
        waveOver.lanes[AppearanceVector.Lane.timeSpan] = 3
        #expect(wave.showing(waveOver, rest: waveRest).amplitudeRange == 0.5 ... 0.75 && wave.showing(waveOver, rest: waveRest).timeSpan == 3)
        #expect(wave.showing(waveRest, rest: waveRest) == wave)
        var waveBad = waveRest
        waveBad.lanes[AppearanceVector.Lane.amplitudeHigh] = .nan
        waveBad.lanes[AppearanceVector.Lane.timeSpan] = 0
        #expect(wave.showing(waveBad, rest: waveRest) == wave)
    }

    // MARK: The animatable host

    /// The host's animatable data are the appearance's continuous values and the size: what
    /// SwiftUI sets on it is what the Metal view is handed.
    @Test func theHostHandsTheMetalViewWhatSwiftUISetsOnIt() {
        let feed = HeatmapFeed()
        var target = HeatmapAppearance()
        target.valueRange = -60 ... -20
        let rest = target.vector(fullRows: nil, fullSpan: nil)
        var host = SurfaceHost(content: .heatmap(feed, target), vector: rest, size: CGSize(width: 200, height: 100), maximumFrameRate: 60, isPresented: true)
        #expect(host.animatableData.first == rest && host.animatableData.second.first == 200 && host.animatableData.second.second == 100)
        #expect(host.shownContent == .heatmap(feed, target), "at rest the host shows what it was given")

        var frame = rest
        frame.lanes[AppearanceVector.Lane.valueLow] = -75
        host.animatableData = AnimatablePair(frame, AnimatablePair(260, 130))
        var shown = target
        shown.valueRange = -75 ... -20
        #expect(host.shownContent == .heatmap(feed, shown))
        #expect(host.size == CGSize(width: 260, height: 130), "the size probe of §8.9")
        #expect(host.content == .heatmap(feed, target), "where the animation ends does not move")

        let wave = WaveformFeed()
        var waveHost = SurfaceHost(content: .waveform(wave, WaveformAppearance()), vector: WaveformAppearance().vector(fullSpan: nil), size: .zero,
                                   maximumFrameRate: 30, isPresented: false)
        var waveFrame = waveHost.rest
        waveFrame.lanes[AppearanceVector.Lane.amplitudeHigh] = 0.5
        waveHost.animatableData.first = waveFrame
        var quieter = WaveformAppearance()
        quieter.amplitudeRange = -1 ... 0.5
        #expect(waveHost.shownContent == .waveform(wave, quieter))
    }

    /// The vector a component hands its host knows what the feed's own record says.
    @Test func theVectorOfAComponentKnowsTheFeedsExtent() throws {
        let feed = HeatmapFeed(history: 200)
        let unattached = HeatmapSurface.vector(HeatmapAppearance(), shape: FeedReference.heatmap(feed).shape)
        #expect(unattached.lanes[AppearanceVector.Lane.known] == 0)
        try FeedWriter.append(FeedWriter.columns(0 ..< 2, rows: 9), rows: 9, axis: .linearFrequency(binCount: 9, nyquist: 24_000), hop: 240, to: feed)
        let shape = FeedReference.heatmap(feed).shape
        #expect(shape == FeedShape(axis: .linearFrequency(binCount: 9, nyquist: 24_000), columnRate: 200, history: 200) && shape.historySpan == 1)
        let attached = HeatmapSurface.vector(HeatmapAppearance(), shape: shape)
        #expect(attached.lanes == SIMD8(-90, 0, 1, 0, 24_000, 0, 0, 3))

        let wave = WaveformFeed(history: 300)
        #expect(FeedReference.waveform(wave).shape == FeedShape(axis: nil, columnRate: nil, history: 300))
        #expect(FeedReference.waveform(wave).shape.historySpan == nil)
        #expect(FeedReference.waveform(wave) == .waveform(wave) && FeedReference.waveform(wave) != .waveform(WaveformFeed()) && FeedReference.heatmap(feed) != .waveform(wave))
        #expect(FeedReference.heatmap(feed).identity == ObjectIdentifier(feed) && !FeedReference.waveform(wave).isLive && !FeedReference.heatmap(feed).isLive)
    }
}
