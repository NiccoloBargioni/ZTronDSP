import Foundation
import Metal
import ZTronDSPCore

/// Draws a `HeatmapFeed` as a heat map: a spectrogram, a chromagram, a tempogram (§8.2).
///
/// The renderer owns one data texture sized by the feed, a ring of columns, and draws it with
/// one draw call into whatever render pass it is handed: a view's drawable, or an off-screen
/// target in a test. It has no view and no display link of its own; the view layer drives it:
///
/// ```swift
/// // on a display tick
/// if renderer.needsDraw() {                     // one atomic load when nothing is pending
///     renderer.draw(to: passOfTheDrawable, presenting: drawable)
/// }
/// ```
///
/// **Draw scheduling (§8.3).** The renderer keeps the dirty set: new data, appearance
/// changed, drawable size changed, became visible, feed replaced. `draw` does nothing unless
/// one of them is pending (V-4). When it draws it first takes every column that arrived since
/// the last draw, in one pass, and uploads exactly those (V-5).
///
/// **What costs what (§8.4).** Colour map, value range, frequency scale, visible ranges and
/// row interpolation are uniforms or small look-up tables: setting one to a different value
/// costs one draw and uploads no column; setting it to the value it has costs nothing. A
/// change of drawable size costs one draw and uploads nothing. The data texture is allocated
/// again only when the feed's row count or history changes (V-6), and emptied when the feed
/// starts over.
///
/// Threading: main actor. The renderer's textures belong to it (IMM-3). `needsDraw()`
/// allocates nothing. Setting another colour map or scale allocates its small table; the
/// other setters allocate nothing. A draw allocates what Metal needs for a command buffer,
/// and a texture only when the feed changed shape.
@MainActor
public final class HeatmapRenderer {
    private let context: MetalContext
    private let lookups: HeatmapLookups
    private var feed: HeatmapFeed
    private var cursor = FeedCursor()
    private var data: HeatmapTexture
    private var staging: AlignedBuffer<Float>
    private var ledger = DrawLedger()
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState]

    private var colorMap = AnyStrategy(ListedColorMap.viridis)
    private var scale: any FrequencyScale = LinearFrequencyScale()
    private var scaleKey = AnyStrategy(LinearFrequencyScale())
    private var valueRange: ClosedRange<Float> = -90 ... 0
    private var frequencyRange: ClosedRange<Double>?
    private var rowRange: ClosedRange<Double>?
    private var visibleColumns: Double?
    private var interpolation = RowInterpolation.linear
    private var table: WarpTable
    private var tableAxis: FeedAxis?
    private var tableScale = AnyStrategy(LinearFrequencyScale())

    /// The counters of this renderer: the probe it was given, or one of its own.
    public let probe: RenderProbe

    /// Why the renderer shows no data, when the feed's shape does not fit a texture of the
    /// device; `nil` otherwise.
    public private(set) var failure: DSPError?

    /// A renderer for `feed`, showing it with the viridis map over −90 … 0, on a linear axis,
    /// the whole history across the width.
    ///
    /// - Parameters:
    ///   - context: the device the renderer draws with.
    ///   - feed: the heat-map feed it shows.
    ///   - probe: counts uploads and draws for the stability tests (§8.4).
    /// - Throws: `unsupportedConfiguration` when the feed's rows and history do not fit a
    ///   texture of the device; `resourceAllocationFailed` when there is no memory.
    public init(context: MetalContext, feed: HeatmapFeed, probe: RenderProbe? = nil) throws(DSPError) {
        let lookups = try HeatmapLookups(context: context)
        // A feed that no pipeline writes yet has no rows: one row stands in until it has.
        let texture = try HeatmapTexture(context: context, binCount: feed.rowCount, history: feed.history)
        let axis = feed.axis
        let table = WarpTable(axis: axis, rowCount: texture.binCount, scale: LinearFrequencyScale())
        let counters = probe ?? RenderProbe()
        lookups.setWarp(table)
        lookups.setColors(ListedColorMap.viridis.lookupTable)
        counters.recordAllocation()
        self.context = context
        self.feed = feed
        self.probe = counters
        self.lookups = lookups
        self.table = table
        data = texture
        staging = try AlignedBuffer<Float>(count: texture.chunkCapacity * texture.binCount)
        pipelines = context.pipelines.heatmap
        tableAxis = axis
    }

    // MARK: Appearance

    /// The colours values are shown in. A different map costs one draw; no column is uploaded.
    public func setColorMap(_ colorMap: some ColorMap) {
        let key = AnyStrategy(colorMap)
        guard key != self.colorMap else { return }
        self.colorMap = key
        lookups.setColors(colorMap.lookupTable)
        ledger.raise(.appearanceChanged)
    }

    /// The values shown as the first and as the last colour of the map; values outside are
    /// clamped to them. Decibels for a spectrogram, plain values otherwise.
    public func setValueRange(_ range: ClosedRange<Float>) {
        guard range != valueRange else { return }
        valueRange = range
        ledger.raise(.appearanceChanged)
    }

    /// How the frequency axis is laid out. It warps rows that are evenly spaced in hertz;
    /// rows that are mel bands, constant-Q bins, pitch classes, lags or tempi are drawn bin
    /// for bin whatever the scale (VC-5).
    public func setFrequencyScale(_ scale: some FrequencyScale) {
        let key = AnyStrategy(scale)
        guard key != scaleKey else { return }
        self.scale = scale
        scaleKey = key
        ledger.raise(.appearanceChanged)
    }

    /// The frequencies at the bottom and at the top edge, in hertz, for a feed whose rows are
    /// evenly spaced in hertz; `nil` shows the whole axis. Other feeds use ``setRowRange(_:)``.
    public func setFrequencyRange(_ range: ClosedRange<Double>?) {
        guard range != frequencyRange else { return }
        frequencyRange = range
        ledger.raise(.appearanceChanged)
    }

    /// The rows at the bottom and at the top edge, for a feed drawn bin for bin: positions
    /// from 0, the lower edge of the first row, to the row count. `nil` shows every row.
    public func setRowRange(_ range: ClosedRange<Double>?) {
        guard range != rowRange else { return }
        rowRange = range
        ledger.raise(.appearanceChanged)
    }

    /// How many columns span the width, the newest at the right edge: the time span, in
    /// columns of the feed. `nil` shows the whole history.
    public func setVisibleColumns(_ columns: Double?) {
        guard columns != visibleColumns else { return }
        visibleColumns = columns
        ledger.raise(.appearanceChanged)
    }

    /// How the space between two rows is filled: linear for spectra, nearest for the pitch
    /// classes of a chromagram.
    public func setRowInterpolation(_ interpolation: RowInterpolation) {
        guard interpolation != self.interpolation else { return }
        self.interpolation = interpolation
        ledger.raise(.appearanceChanged)
    }

    // MARK: Causes

    /// Shows another feed from now on. What the texture held is dropped; the texture itself
    /// is kept unless the new feed has another shape (V-6). The same feed again does nothing.
    public func setFeed(_ feed: HeatmapFeed) {
        guard feed !== self.feed else { return }
        self.feed = feed
        cursor = FeedCursor()
        failure = nil
        empty()
        ledger.forgetFeed()
    }

    /// The drawable the renderer draws into changed size: one draw, nothing uploaded.
    public func drawableSizeChanged() {
        ledger.raise(.drawableSizeChanged)
    }

    /// The view came on screen, or its scene became active again: one draw.
    public func becameVisible() {
        ledger.raise(.becameVisible)
    }

    /// What a draw is pending for. Empty when there is nothing to draw.
    public var pendingCauses: RenderCauses {
        ledger.pending(generation: feed.generation)
    }

    /// Whether a draw is due: what a display tick asks first. With an empty dirty set it costs
    /// one atomic load of the feed's generation (§8.3).
    public func needsDraw() -> Bool {
        !ledger.pending(generation: feed.generation).isEmpty
    }

    // MARK: Drawing

    /// Draws one frame into `pass` on a command buffer of the context's queue, when a draw is
    /// due, and presents `drawable` with it when one is given.
    ///
    /// The frame goes to the first colour attachment of `pass`, whatever its size, and fills
    /// it. The attachment is single-sample, and the pass has no depth or stencil attachment:
    /// what a Metal view hands out by default. A pixel format other than `bgra8Unorm` and
    /// `rgba8Unorm` gets its pipeline compiled on the first draw into it.
    ///
    /// - Returns: whether a frame was drawn. `false` when no cause is pending (V-4), and when
    ///   the pass has no colour attachment to draw into.
    @discardableResult
    public func draw(to pass: MTLRenderPassDescriptor, presenting drawable: (any MTLDrawable)? = nil) -> Bool {
        guard needsDraw(), let commands = try? MetalResources.commands(on: context.commandQueue), render(to: pass, in: commands) else { return false }
        if let drawable { commands.present(drawable) }
        commands.commit()
        return true
    }

    /// Encodes one frame into `pass` on `commands`, when a draw is due, and leaves committing
    /// and presenting to the caller: what a view uses when it presents with a transaction
    /// during a size transition (SZ-3).
    ///
    /// - Returns: whether a frame was encoded; when `false`, nothing was added to `commands`.
    public func render(to pass: MTLRenderPassDescriptor, in commands: any MTLCommandBuffer) -> Bool {
        let generation = feed.generation
        guard !ledger.pending(generation: generation).isEmpty, let format = pass.colorAttachments[0].texture?.pixelFormat,
              let pipeline = pipeline(for: format)
        else { return false }
        pull()
        refreshTable()
        let uniforms = HeatmapUniforms(
            texture: data, span: table.span(frequencies: frequencyRange, rows: rowRange, scale: scale), valueRange: valueRange,
            visibleColumns: visibleColumns, interpolation: interpolation)
        HeatmapPass.encode(uniforms, data: data.texture, lookups: lookups, pipeline: pipeline, to: pass, in: commands)
        ledger.settle(generation: generation)
        probe.recordDraw(calls: 1)
        return true
    }

    private func pipeline(for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let state = pipelines[format] { return state }
        // A format the context was not built for: compiled here, once.
        guard let state = try? context.heatmapPipeline(for: format) else { return nil }
        pipelines[format] = state
        return state
    }

    /// Takes every column that arrived since the last draw and uploads it.
    private func pull() {
        var uploaded = 0
        while true {
            let read = feed.read(&cursor, into: staging.buffer)
            // A feed no pipeline writes yet has no rows.
            guard read.rowCount > 0 else { break }
            var next: AlignedBuffer<Float>?
            if read.rowCount != data.binCount || read.history != data.history {
                next = reshape(rows: read.rowCount, history: read.history)
                guard next != nil else { break }
            } else if read.isReset {
                empty()
            }
            if read.columnCount > 0 {
                data.append(staging.baseAddress, count: read.columnCount)
                uploaded += read.columnCount
            }
            // After a new shape the staging memory has another size: read again with it.
            if read.columnCount == 0, next == nil { break }
            if let next { staging = next }
        }
        probe.recordUpload(columns: uploaded)
    }

    /// Drops what the texture holds, when it holds anything.
    private func empty() {
        guard data.available > 0 else { return }
        data.clear()
        probe.recordClear()
    }

    /// A texture for another shape of feed (V-6), and the staging memory to read that shape
    /// with, which the caller puts in place once it has used up the old one. On failure the
    /// renderer shows no data and says why in `failure`.
    private func reshape(rows: Int, history: Int) -> AlignedBuffer<Float>? {
        do throws(DSPError) {
            let texture = try HeatmapTexture(context: context, binCount: rows, history: history)
            let buffer = try AlignedBuffer<Float>(count: texture.chunkCapacity * texture.binCount)
            data = texture
            failure = nil
            probe.recordAllocation()
            return buffer
        } catch {
            failure = error
            empty()
            return nil
        }
    }

    /// Builds the warp table again when what it depends on changed: the feed's axis, its row
    /// count, the scale.
    private func refreshTable() {
        let axis = feed.axis
        guard axis != tableAxis || table.rowCount != data.binCount || tableScale != scaleKey else { return }
        tableAxis = axis
        tableScale = scaleKey
        table = WarpTable(axis: axis, rowCount: data.binCount, scale: scale)
        lookups.setWarp(table)
    }
}
