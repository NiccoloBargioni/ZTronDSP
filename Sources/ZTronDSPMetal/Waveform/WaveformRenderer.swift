import Foundation
import Metal
import ZTronDSPCore

/// The uniforms of the waveform fragment shader, field for field as `ZTDWaveformUniforms` in
/// `Waveform.metal` declares them.
struct WaveformUniforms {
    var fill: SIMD4<Float>
    var background: SIMD4<Float>
    var amplitudeLow: Float
    var amplitudeScale: Float
    var visiblePairs: Float
    var head: UInt32
    var capacity: UInt32
    var available: UInt32
    var rowWidth: UInt32
    var reserved: UInt32 = 0

    /// The uniforms that show `texture` as it stands.
    ///
    /// - Parameters:
    ///   - amplitudeRange: the amplitudes at the bottom and at the top edge; a range of no
    ///     width is widened by the smallest step.
    ///   - visiblePairs: pairs across the width; `nil`, or a number that is not positive, shows
    ///     the whole ring.
    ///   - fill: the envelope's colour and opacity.
    ///   - background: what lies behind it; `nil` is transparent.
    init(texture: EnvelopeTexture, amplitudeRange: ClosedRange<Float>, visiblePairs: Double?, fill: DisplayColor, fillOpacity: Double,
         background: DisplayColor?) {
        let low = amplitudeRange.lowerBound.isFinite ? amplitudeRange.lowerBound : -1
        let high = amplitudeRange.upperBound.isFinite ? amplitudeRange.upperBound : low
        let pairs = visiblePairs.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Double(texture.capacity)
        self.fill = SIMD4(Float(fill.red), Float(fill.green), Float(fill.blue), Float(DisplayColor.unit(fillOpacity)))
        self.background = background.map { SIMD4(Float($0.red), Float($0.green), Float($0.blue), 1) } ?? SIMD4(0, 0, 0, 0)
        amplitudeLow = low
        amplitudeScale = 1 / max(high - low, Float.leastNormalMagnitude)
        self.visiblePairs = Float(pairs)
        head = UInt32(texture.head)
        capacity = UInt32(texture.capacity)
        available = UInt32(texture.available)
        rowWidth = UInt32(texture.rowWidth)
    }
}

/// One waveform draw: one render pass, one draw call, no vertex buffer (§8.2).
enum WaveformPass {
    /// Encodes the pass into `commands`. `pipeline` is the one for the pixel format of the
    /// pass's first colour attachment.
    static func encode(
        _ uniforms: WaveformUniforms, data: any MTLTexture, pipeline: any MTLRenderPipelineState, to pass: MTLRenderPassDescriptor,
        in commands: any MTLCommandBuffer
    ) {
        var values = uniforms
        MetalResources.drawScreen(with: pipeline, to: pass, in: commands) { encoder in
            encoder.setFragmentBytes(&values, length: MemoryLayout<WaveformUniforms>.stride, index: 0)
            encoder.setFragmentTexture(data, index: 0)
        }
    }
}

/// Draws a `WaveformFeed` as a filled envelope between its minima and maxima (§8.2).
///
/// The renderer owns one envelope texture, a ring of (minimum, maximum) pairs with its
/// reduced levels, and draws it with one draw call into whatever render pass it is handed.
/// A pixel that covers several pairs shows the smallest minimum and the largest maximum among
/// them; the band is anti-aliased analytically and never thinner than one pixel, so silence
/// is a line.
///
/// It is driven exactly as a ``HeatmapRenderer`` is: `needsDraw()` on a display tick, then
/// `draw(to:presenting:)`; the dirty set, the costs and the counters are the same (§8.3, §8.4).
/// A feed that holds a whole signal and no longer changes is a static overview: nothing more
/// is uploaded, and every zoom reads the level that matches it.
///
/// Threading: main actor. `needsDraw()` and the setters allocate nothing; a draw allocates
/// what Metal needs for a command buffer, and a texture only when the feed changed its history.
@MainActor
public final class WaveformRenderer {
    private let context: MetalContext
    private var feed: WaveformFeed
    private var cursor = FeedCursor()
    private var data: EnvelopeTexture
    private let staging: AlignedBuffer<Float>
    private var ledger = DrawLedger()
    private var pipelines: [MTLPixelFormat: any MTLRenderPipelineState]

    private var amplitudeRange: ClosedRange<Float> = -1 ... 1
    private var visiblePairs: Double?
    private var fill = DisplayColor.white
    private var fillOpacity = 1.0
    private var background: DisplayColor?

    /// Pairs one read of the feed takes.
    private static let chunk = 4_096

    /// The counters of this renderer: the probe it was given, or one of its own.
    public let probe: RenderProbe

    /// Why the renderer shows no data, when the feed's history does not fit a texture of the
    /// device; `nil` otherwise.
    public private(set) var failure: DSPError?

    /// A renderer for `feed`, showing amplitudes −1 … 1 in white on a transparent background,
    /// the whole history across the width.
    ///
    /// - Parameters:
    ///   - context: the device the renderer draws with.
    ///   - feed: the waveform feed it shows.
    ///   - probe: counts uploads and draws for the stability tests (§8.4).
    /// - Throws: `unsupportedConfiguration` when the feed's history does not fit a texture of
    ///   the device; `resourceAllocationFailed` when there is no memory.
    public init(context: MetalContext, feed: WaveformFeed, probe: RenderProbe? = nil) throws(DSPError) {
        let texture = try EnvelopeTexture(context: context, capacity: feed.history)
        let counters = probe ?? RenderProbe()
        counters.recordAllocation()
        self.context = context
        self.feed = feed
        self.probe = counters
        data = texture
        staging = try AlignedBuffer<Float>(count: Self.chunk * 2)
        pipelines = context.pipelines.waveform
    }

    // MARK: Appearance

    /// The amplitudes at the bottom and at the top edge. An envelope that reaches past them is
    /// cut off at the edge.
    public func setAmplitudeRange(_ range: ClosedRange<Float>) {
        guard range != amplitudeRange else { return }
        amplitudeRange = range
        ledger.raise(.appearanceChanged)
    }

    /// How many pairs span the width, the newest at the right edge: the time span, in pairs of
    /// the feed. `nil` shows the whole history.
    public func setVisiblePairs(_ pairs: Double?) {
        guard pairs != visiblePairs else { return }
        visiblePairs = pairs
        ledger.raise(.appearanceChanged)
    }

    /// The envelope's colour, and how opaque it is from 0 to 1.
    public func setFillColor(_ color: DisplayColor, opacity: Double = 1) {
        guard color != fill || opacity != fillOpacity else { return }
        fill = color
        fillOpacity = opacity
        ledger.raise(.appearanceChanged)
    }

    /// What lies behind the envelope: an opaque colour, or `nil` for nothing, which leaves the
    /// drawable transparent there.
    public func setBackgroundColor(_ color: DisplayColor?) {
        guard color != background else { return }
        background = color
        ledger.raise(.appearanceChanged)
    }

    // MARK: Causes

    /// Shows another feed from now on. What the texture held is dropped; the texture itself
    /// is kept unless the new feed has another history (V-6). The same feed again does nothing.
    public func setFeed(_ feed: WaveformFeed) {
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
    /// and presenting to the caller (SZ-3).
    ///
    /// - Returns: whether a frame was encoded; when `false`, nothing was added to `commands`.
    public func render(to pass: MTLRenderPassDescriptor, in commands: any MTLCommandBuffer) -> Bool {
        let generation = feed.generation
        guard !ledger.pending(generation: generation).isEmpty, let format = pass.colorAttachments[0].texture?.pixelFormat,
              let pipeline = pipeline(for: format)
        else { return false }
        pull()
        let uniforms = WaveformUniforms(texture: data, amplitudeRange: amplitudeRange, visiblePairs: visiblePairs, fill: fill,
                                        fillOpacity: fillOpacity, background: background)
        WaveformPass.encode(uniforms, data: data.texture, pipeline: pipeline, to: pass, in: commands)
        ledger.settle(generation: generation)
        probe.recordDraw(calls: 1)
        return true
    }

    private func pipeline(for format: MTLPixelFormat) -> (any MTLRenderPipelineState)? {
        if let state = pipelines[format] { return state }
        // A format the context was not built for: compiled here, once.
        guard let state = try? context.waveformPipeline(for: format) else { return nil }
        pipelines[format] = state
        return state
    }

    /// Takes every pair that arrived since the last draw and uploads it.
    private func pull() {
        var uploaded = 0
        while true {
            let read = feed.read(&cursor, into: staging.buffer)
            // A feed no pipeline writes yet has no rows.
            guard read.rowCount > 0 else { break }
            if read.history != data.capacity {
                guard reshape(history: read.history) else { break }
            } else if read.isReset {
                empty()
            }
            guard read.columnCount > 0 else { break }
            data.append(staging.baseAddress, count: read.columnCount)
            uploaded += read.columnCount
        }
        probe.recordUpload(columns: uploaded)
    }

    /// Drops what the texture holds, when it holds anything.
    private func empty() {
        guard data.available > 0 else { return }
        data.clear()
        probe.recordClear()
    }

    /// A texture for another history (V-6). On failure the renderer shows no data and says why
    /// in `failure`.
    private func reshape(history: Int) -> Bool {
        do throws(DSPError) {
            data = try EnvelopeTexture(context: context, capacity: history)
            failure = nil
            probe.recordAllocation()
            return true
        } catch {
            failure = error
            empty()
            return false
        }
    }
}
