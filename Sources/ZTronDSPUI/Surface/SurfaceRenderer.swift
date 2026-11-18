import Foundation
import Metal
import ZTronDSPCore
import ZTronDSPMetal

/// The renderer behind a Metal surface, whichever of the two it is: a heat map or a
/// waveform. The coordinator talks to this and never asks which.
///
/// It turns a ``SurfaceContent`` into the renderer's setters. The values the modifiers set
/// in seconds and in the unit of the feed's axis are converted here into the columns and rows
/// a renderer counts in, against the feed's own record of its feature rate and its axis
/// (ENV-4): that record appears when a pipeline is attached, which no view is told about, so
/// the conversion is made again before every draw. A value that comes out the same costs
/// nothing in the renderer.
///
/// Threading: main actor, like the renderers it wraps.
@MainActor
final class SurfaceRenderer {
    /// The renderer, with the feed it shows and how: one of the two kinds, for good.
    private enum Shown {
        case heatmap(HeatmapRenderer, HeatmapFeed, HeatmapAppearance)
        case waveform(WaveformRenderer, WaveformFeed, WaveformAppearance)
    }

    private var shown: Shown

    /// A renderer for what `content` names.
    ///
    /// - Throws: what the renderer's initialiser throws: `unsupportedConfiguration` for a feed
    ///   no texture of the device fits, `resourceAllocationFailed` without memory.
    init(context: MetalContext, content: SurfaceContent, probe: RenderProbe) throws(DSPError) {
        switch content {
        case .heatmap(let feed, let appearance):
            shown = .heatmap(try HeatmapRenderer(context: context, feed: feed, probe: probe), feed, appearance)
        case .waveform(let feed, let appearance):
            shown = .waveform(try WaveformRenderer(context: context, feed: feed, probe: probe), feed, appearance)
        }
        apply()
    }

    /// What the renderer shows.
    var content: SurfaceContent {
        switch shown {
        case .heatmap(_, let feed, let appearance): .heatmap(feed, appearance)
        case .waveform(_, let feed, let appearance): .waveform(feed, appearance)
        }
    }

    /// Shows `content` from now on: another feed, another appearance, or both.
    ///
    /// - Returns: `false` for content of the other kind, which this renderer cannot draw and
    ///   which changes nothing here.
    @discardableResult
    func show(_ content: SurfaceContent) -> Bool {
        switch (shown, content) {
        case (.heatmap(let renderer, _, _), .heatmap(let feed, let appearance)):
            shown = .heatmap(renderer, feed, appearance)
        case (.waveform(let renderer, _, _), .waveform(let feed, let appearance)):
            shown = .waveform(renderer, feed, appearance)
        default:
            return false
        }
        apply()
        return true
    }

    /// Hands the renderer everything `shown` says. A value that is the one the renderer has
    /// costs nothing there.
    private func apply() {
        switch shown {
        case .heatmap(let renderer, let feed, let appearance):
            renderer.setFeed(feed)
            renderer.setColorMap(appearance.colorMap.base)
            renderer.setValueRange(appearance.valueRange)
            renderer.setFrequencyScale(appearance.frequencyScale.base)
            renderer.setRowInterpolation(appearance.rowInterpolation)
        case .waveform(let renderer, let feed, let appearance):
            renderer.setFeed(feed)
            renderer.setAmplitudeRange(appearance.amplitudeRange)
            renderer.setFillColor(appearance.fill)
        }
        resolve()
    }

    /// Converts what depends on the feed's shape again: the time span into columns, the
    /// vertical range into rows. Called before every draw; allocates nothing.
    func resolve() {
        switch shown {
        case .heatmap(let renderer, let feed, let appearance):
            renderer.setVisibleColumns(Self.columns(for: appearance.timeSpan, rate: FeedReference.heatmap(feed).shape.columnRate))
            let axis = feed.axis
            if let axis, !axis.isLinearFrequency {
                renderer.setFrequencyRange(nil)
                renderer.setRowRange(appearance.rowRange.flatMap { RowAxisMapping(axis: axis).rows(for: $0) })
            } else {
                renderer.setRowRange(nil)
                renderer.setFrequencyRange(axis == nil ? nil : appearance.rowRange)
            }
        case .waveform(let renderer, let feed, let appearance):
            renderer.setVisiblePairs(Self.columns(for: appearance.timeSpan, rate: FeedReference.waveform(feed).shape.columnRate))
        }
    }

    /// A time span in columns, when both the span and the feed's rate are known.
    static func columns(for seconds: Double?, rate: Double?) -> Double? {
        guard let seconds, let rate, seconds.isFinite, seconds > 0 else { return nil }
        return seconds * rate
    }

    // MARK: What the coordinator asks

    func drawableSizeChanged() {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.drawableSizeChanged()
        case .waveform(let renderer, _, _): renderer.drawableSizeChanged()
        }
    }

    func becameVisible() {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.becameVisible()
        case .waveform(let renderer, _, _): renderer.becameVisible()
        }
    }

    /// One atomic load when nothing is pending.
    func needsDraw() -> Bool {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.needsDraw()
        case .waveform(let renderer, _, _): renderer.needsDraw()
        }
    }

    var pendingCauses: RenderCauses {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.pendingCauses
        case .waveform(let renderer, _, _): renderer.pendingCauses
        }
    }

    /// Why the renderer shows no data, when the feed has taken a shape no texture of the
    /// device fits; `nil` otherwise.
    var failure: DSPError? {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.failure
        case .waveform(let renderer, _, _): renderer.failure
        }
    }

    @discardableResult
    func draw(to pass: MTLRenderPassDescriptor, presenting drawable: (any MTLDrawable)?) -> Bool {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.draw(to: pass, presenting: drawable)
        case .waveform(let renderer, _, _): renderer.draw(to: pass, presenting: drawable)
        }
    }

    func render(to pass: MTLRenderPassDescriptor, in commands: any MTLCommandBuffer) -> Bool {
        switch shown {
        case .heatmap(let renderer, _, _): renderer.render(to: pass, in: commands)
        case .waveform(let renderer, _, _): renderer.render(to: pass, in: commands)
        }
    }
}
