import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// `HeatmapRenderer` (WP-606): the dirty-set state machine of §8.3 and the renderer's share of
/// the stability contract of §8.4, driven directly with off-screen targets and counted by a
/// `RenderProbe`.
@MainActor
@Suite("Heat-map renderer")
struct HeatmapRendererTests {
    static let rows = 24

    /// `count` columns; column c holds c in its first row and a ramp above it.
    private func columns(_ range: Range<Int>, rows: Int = HeatmapRendererTests.rows) -> [Float] {
        range.flatMap { column in (0 ..< rows).map { row in row == 0 ? Float(column) : Float(-90 + (row * 7 + column * 3) % 90) } }
    }

    private func append(_ range: Range<Int>, to feed: HeatmapFeed, rows: Int = HeatmapRendererTests.rows, axis: FeedAxis? = nil) throws {
        try FeedWriter.append(columns(range, rows: rows), rows: rows, axis: axis, to: feed)
    }

    /// A feed that already has a pipeline's shape and `count` columns, its renderer, a probe
    /// and a target.
    private func scene(history: Int = 32, columns count: Int = 0) async throws -> (feed: HeatmapFeed, renderer: HeatmapRenderer, probe: RenderProbe, target: OffscreenTarget, context: MetalContext) {
        let context = try await sharedContext()
        let feed = HeatmapFeed(history: history)
        // An offline run with no samples attaches the feed: it has its rows, and no column.
        try append(0 ..< count, to: feed)
        let probe = RenderProbe()
        let renderer = try HeatmapRenderer(context: context, feed: feed, probe: probe)
        return (feed, renderer, probe, try OffscreenTarget(context: context, width: 48, height: 24), context)
    }

    private func picture(_ renderer: HeatmapRenderer, _ target: OffscreenTarget, _ context: MetalContext) -> PixelImage {
        renderer.draw(to: target.renderPass())
        context.waitUntilIdle()
        return target.readPixels()
    }

    // MARK: Draws only on a cause (V-4)

    @Test func aNewRendererDrawsOnceAndThenOnlyOnACause() async throws {
        let (_, renderer, probe, target, _) = try await scene(columns: 5)
        #expect(probe.allocations == 1 && probe.draws == 0 && probe.uploads == 0)
        #expect(renderer.needsDraw() && renderer.pendingCauses.contains(.feedReplaced), "a feed that was never shown")
        #expect(renderer.draw(to: target.renderPass()))
        #expect(probe.draws == 1 && probe.drawCalls == 1 && probe.uploads == 1 && probe.uploadedColumns == 5)
        #expect(!renderer.needsDraw() && renderer.pendingCauses.isEmpty)

        // A hundred ticks with nothing to show: nothing is drawn, nothing is uploaded.
        for _ in 0 ..< 100 {
            #expect(!renderer.needsDraw())
            #expect(!renderer.draw(to: target.renderPass()), "no draw without a cause")
        }
        #expect(probe.draws == 1 && probe.drawCalls == 1 && probe.uploads == 1 && probe.allocations == 1 && probe.clears == 0)
    }

    /// §8.3: with nothing pending a tick is one atomic load, and it asks nothing of the heap.
    @Test func anIdleTickAllocatesNothing() async throws {
        let (_, renderer, probe, target, _) = try await scene(columns: 5)
        renderer.draw(to: target.renderPass())
        var due = 0
        expectNoAllocations("1 000 ticks of an idle renderer") {
            var tick = 0
            while tick < 1_000 {
                if renderer.needsDraw() { due += 1 }
                tick += 1
            }
        }
        #expect(due == 0 && probe.draws == 1)
        // The setters that are uniforms do not either, once each has run (a first call may
        // make the runtime build the metadata of a generic type).
        func set(_ step: Int) {
            renderer.setValueRange(-2_000 ... Float(-step))
            renderer.setVisibleColumns(Double(10 + step))
            renderer.setRowRange(0 ... Double(1 + step))
            renderer.setFrequencyRange(0 ... Double(100 + step))
            renderer.setRowInterpolation(step % 2 == 0 ? .nearest : .linear)
            renderer.drawableSizeChanged()
            renderer.becameVisible()
        }
        set(1_000)
        set(1_001)
        expectNoAllocations("uniform setters") {
            var step = 0
            while step < 100 {
                set(step)
                step += 1
            }
        }
        #expect(renderer.pendingCauses == [.appearanceChanged, .drawableSizeChanged, .becameVisible])
    }

    @Test func renderingWithoutACauseAddsNothingToTheCommandBuffer() async throws {
        let (feed, renderer, probe, target, context) = try await scene(columns: 3)
        let commands = try #require(context.commandQueue.makeCommandBuffer())
        #expect(renderer.render(to: target.renderPass(), in: commands), "the first frame")
        #expect(!renderer.render(to: target.renderPass(), in: commands), "no second one without a cause")
        commands.commit()
        context.waitUntilIdle()
        let shown = target.readPixels()
        #expect(probe.draws == 1)

        // The caller's command buffer gives the picture `draw` gives.
        let other = try HeatmapRenderer(context: context, feed: feed)
        let again = try OffscreenTarget(context: context, width: 48, height: 24)
        #expect(picture(other, again, context) == shown)
    }

    @Test func aPassWithoutATargetDrawsNothingAndKeepsTheCause() async throws {
        let (_, renderer, probe, target, _) = try await scene(columns: 3)
        #expect(!renderer.draw(to: MTLRenderPassDescriptor()), "nothing to draw into")
        #expect(probe.draws == 0 && probe.uploads == 0 && renderer.needsDraw(), "the cause is still pending")
        #expect(renderer.draw(to: target.renderPass()))
    }

    // MARK: New data (V-5)

    @Test func newDataIsOneDrawAndAnUploadOfTheNewColumnsOnly() async throws {
        let (feed, renderer, probe, target, _) = try await scene(columns: 4)
        #expect(renderer.draw(to: target.renderPass()))
        try append(4 ..< 7, to: feed)
        #expect(renderer.needsDraw() && renderer.pendingCauses == .newData, "the feed's generation moved")
        #expect(renderer.draw(to: target.renderPass()))
        #expect(probe.draws == 2 && probe.uploads == 2 && probe.uploadedColumns == 7, "three columns went up, not seven")
        #expect(!renderer.needsDraw())
        #expect(probe.allocations == 1 && probe.clears == 0, "the texture is the one the renderer started with")
    }

    /// §8.4: data arriving at twice the display rate for one second.
    @Test func dataFasterThanTheDisplayIsOneDrawPerTickAndEveryColumnIsShown() async throws {
        let (feed, renderer, probe, target, context) = try await scene(history: 128)
        var ticks = 0
        for tick in 0 ..< 60 {
            // Two columns between two ticks.
            try append(2 * tick ..< 2 * tick + 2, to: feed)
            ticks += 1
            if renderer.needsDraw() { renderer.draw(to: target.renderPass()) }
        }
        #expect(probe.draws <= ticks && probe.draws == 60)
        #expect(probe.uploadedColumns == 120 && probe.uploads == 60, "every column went up, each once")
        // Every column is in the texture: the picture is the one a renderer that takes all 120 at once draws.
        context.waitUntilIdle()
        let shown = target.readPixels()
        let fresh = try HeatmapRenderer(context: context, feed: feed)
        let other = try OffscreenTarget(context: context, width: 48, height: 24)
        #expect(picture(fresh, other, context) == shown)
        #expect(fresh.probe.uploadedColumns == 120 && fresh.probe.uploads == 1, "one pass for everything that arrived since the last look")
    }

    @Test func aSlowRendererSkipsWhatWasOverwrittenAndShowsTheNewest() async throws {
        let (feed, renderer, probe, target, context) = try await scene(history: 8, columns: 3)
        #expect(renderer.draw(to: target.renderPass()))
        // Twenty columns through a feed of eight before the next tick.
        try append(3 ..< 23, to: feed)
        #expect(renderer.draw(to: target.renderPass()))
        #expect(probe.uploadedColumns == 3 + 8, "the eight the feed still holds")
        context.waitUntilIdle()
        let fresh = try HeatmapRenderer(context: context, feed: feed)
        let other = try OffscreenTarget(context: context, width: 48, height: 24)
        #expect(picture(fresh, other, context) == target.readPixels())
    }

    // MARK: Appearance: a uniform change and one draw

    @Test func aChangedAppearanceIsExactlyOneDrawAndNoUpload() async throws {
        let (_, renderer, probe, target, context) = try await scene(columns: 20)
        var last = picture(renderer, target, context)
        let uploads = probe.uploads, columns = probe.uploadedColumns
        var draws = probe.draws

        func changed(_ what: String, _ change: () -> Void, changesThePicture: Bool = true) {
            change()
            #expect(renderer.pendingCauses == .appearanceChanged, "\(what): the cause")
            #expect(renderer.draw(to: target.renderPass()), "\(what): one draw")
            #expect(!renderer.draw(to: target.renderPass()), "\(what): and no second one")
            draws += 1
            #expect(probe.draws == draws, "\(what): exactly one draw")
            #expect(probe.uploads == uploads && probe.uploadedColumns == columns, "\(what): nothing uploaded")
            // The same value again is no change at all.
            change()
            #expect(!renderer.needsDraw() && renderer.pendingCauses.isEmpty, "\(what): an equal value costs nothing")
            context.waitUntilIdle()
            let now = target.readPixels()
            if changesThePicture { #expect(now != last, "\(what): the picture changed") }
            last = now
        }

        changed("colour map") { renderer.setColorMap(.magma) }
        changed("value range") { renderer.setValueRange(-60 ... -10) }
        changed("visible columns") { renderer.setVisibleColumns(10.5) }
        changed("row range") { renderer.setRowRange(3 ... 17.5) }
        changed("interpolation") { renderer.setRowInterpolation(.nearest) }
        // Rows that are not frequencies are drawn bin for bin: the scale and a band in hertz
        // are uniforms that change nothing here, and still exactly one draw each (VC-5).
        changed("frequency scale", { renderer.setFrequencyScale(.logarithmic) }, changesThePicture: false)
        changed("frequency range", { renderer.setFrequencyRange(100 ... 5_000) }, changesThePicture: false)
        changed("a custom map") { renderer.setColorMap(.stops([.black, DisplayColor(red: 1, green: 0, blue: 0), .white])) }
        changed("back to no span") { renderer.setVisibleColumns(nil) }
        #expect(probe.allocations == 1 && probe.clears == 0)

        // The stock values the renderer starts with are no change either.
        let (_, untouched, counters, _, _) = try await scene(columns: 2)
        untouched.draw(to: target.renderPass())
        untouched.setColorMap(.viridis)
        untouched.setValueRange(-90 ... 0)
        untouched.setFrequencyScale(.linear)
        untouched.setFrequencyRange(nil)
        untouched.setRowRange(nil)
        untouched.setVisibleColumns(nil)
        untouched.setRowInterpolation(.linear)
        #expect(!untouched.needsDraw() && counters.draws == 1)
    }

    /// §8.4: a value range animated over half a second.
    @Test func anAnimatedValueRangeIsOneDrawPerFrameAndNoUpload() async throws {
        let (_, renderer, probe, target, _) = try await scene(columns: 20)
        renderer.draw(to: target.renderPass())
        let uploads = probe.uploads
        for frame in 1 ... 30 {
            renderer.setValueRange(-90 ... Float(-30 + frame))
            #expect(renderer.needsDraw())
            renderer.draw(to: target.renderPass())
            #expect(!renderer.needsDraw())
        }
        #expect(probe.draws == 31 && probe.drawCalls == 31 && probe.uploads == uploads, "30 frames: 30 draws, 0 uploads")
    }

    @Test func theFrequencyScaleWarpsRowsThatAreFrequencies() async throws {
        let context = try await sharedContext()
        let feed = HeatmapFeed(history: 16)
        try append(0 ..< 16, to: feed, rows: 65, axis: .linearFrequency(binCount: 65, nyquist: 24_000))
        let probe = RenderProbe()
        let renderer = try HeatmapRenderer(context: context, feed: feed, probe: probe)
        let target = try OffscreenTarget(context: context, width: 32, height: 64)
        let linear = picture(renderer, target, context)
        renderer.setFrequencyScale(.logarithmic)
        let logarithmic = picture(renderer, target, context)
        renderer.setFrequencyScale(.mel)
        let mel = picture(renderer, target, context)
        renderer.setFrequencyScale(.mel(.htk))
        let htk = picture(renderer, target, context)
        renderer.setFrequencyScale(.logarithmic(from: 200))
        let fromTwoHundred = picture(renderer, target, context)
        #expect(Set([linear, logarithmic, mel, htk, fromTwoHundred]).count == 5, "five scales, five pictures")
        renderer.setFrequencyRange(1_000 ... 4_000)
        #expect(picture(renderer, target, context) != fromTwoHundred, "a band in hertz is a uniform that matters here")
        #expect(probe.draws == 6 && probe.uploads == 1 && probe.allocations == 1, "six draws, one upload: the scale is a table and two uniforms")
    }

    // MARK: Size

    /// §8.4: a view resized without animation. SZ-1: the picture depends on no resolution.
    @Test func aResizeIsOneDrawPerSizeAndUploadsNothing() async throws {
        let (_, renderer, probe, target, context) = try await scene(columns: 20)
        let small = picture(renderer, target, context)
        let uploads = probe.uploads
        var draws = probe.draws
        for (width, height) in [(96, 48), (33, 71), (48, 24)] {
            let resized = try OffscreenTarget(context: context, width: width, height: height)
            renderer.drawableSizeChanged()
            #expect(renderer.pendingCauses == .drawableSizeChanged)
            let image = picture(renderer, resized, context)
            draws += 1
            #expect(probe.draws == draws && !renderer.needsDraw(), "\(width) × \(height): one draw")
            #expect(probe.uploads == uploads && probe.allocations == 1, "\(width) × \(height): nothing uploaded, the texture kept (V-6)")
            #expect(image.width == width && image.height == height)
            if width == 48, height == 24 { #expect(image == small, "the same size again: the same picture") }
        }
    }

    // MARK: Visibility

    /// §8.4: scene inactive, then active.
    @Test func becomingVisibleIsOneDraw() async throws {
        let (_, renderer, probe, target, _) = try await scene(columns: 6)
        renderer.draw(to: target.renderPass())
        // While the scene is inactive the scheduler asks nothing; on return it says so.
        renderer.becameVisible()
        #expect(renderer.pendingCauses == .becameVisible && renderer.needsDraw())
        #expect(renderer.draw(to: target.renderPass()) && !renderer.draw(to: target.renderPass()))
        #expect(probe.draws == 2 && probe.uploads == 1)
        // Several causes at once are one draw.
        renderer.becameVisible()
        renderer.drawableSizeChanged()
        renderer.setValueRange(-50 ... 0)
        #expect(renderer.pendingCauses == [.becameVisible, .drawableSizeChanged, .appearanceChanged])
        #expect(renderer.draw(to: target.renderPass()) && probe.draws == 3 && renderer.pendingCauses.isEmpty)
    }

    // MARK: The feed

    /// §8.4: feed replaced.
    @Test func aReplacedFeedClearsTheTextureOnceAndThenWorksAsBefore() async throws {
        let (first, renderer, probe, target, context) = try await scene(columns: 12)
        renderer.draw(to: target.renderPass())
        let second = HeatmapFeed(history: 32)
        try append(100 ..< 105, to: second)

        renderer.setFeed(second)
        #expect(probe.clears == 1 && renderer.pendingCauses.contains(.feedReplaced), "what the texture held is dropped, once")
        let shown = picture(renderer, target, context)
        #expect(probe.clears == 1 && probe.allocations == 1, "the same shape: the texture is kept (V-6)")
        #expect(probe.uploadedColumns == 12 + 5 && probe.draws == 2)
        let fresh = try HeatmapRenderer(context: context, feed: second)
        let other = try OffscreenTarget(context: context, width: 48, height: 24)
        #expect(picture(fresh, other, context) == shown, "only the new feed's columns are shown")

        // Normal operation from then on.
        try append(105 ..< 108, to: second)
        #expect(renderer.pendingCauses == .newData)
        renderer.draw(to: target.renderPass())
        #expect(probe.uploadedColumns == 20 && probe.clears == 1 && probe.allocations == 1)
        // Data in the feed that was replaced is nobody's business.
        try append(12 ..< 14, to: first)
        #expect(!renderer.needsDraw())
        // The same feed again is no replacement.
        renderer.setFeed(second)
        #expect(!renderer.needsDraw() && probe.clears == 1)
    }

    /// V-6: the data texture is allocated again only when the row count or the history changes.
    @Test func theTextureIsAllocatedAgainOnlyForAnotherShape() async throws {
        let (feed, renderer, probe, target, context) = try await scene(history: 16, columns: 4)
        renderer.draw(to: target.renderPass())
        for step in 0 ..< 5 {
            try append(4 + step ..< 5 + step, to: feed)
            renderer.setValueRange(-90 ... Float(step))
            renderer.drawableSizeChanged()
            renderer.draw(to: target.renderPass())
        }
        #expect(probe.allocations == 1, "data, appearance and size: the same texture")

        // The feed attached anew to frames of another size: another texture, once.
        try append(0 ..< 3, to: feed, rows: 40)
        #expect(renderer.needsDraw())
        renderer.draw(to: target.renderPass())
        #expect(probe.allocations == 2 && probe.uploadedColumns == 9 + 3)
        try append(3 ..< 6, to: feed, rows: 40)
        renderer.draw(to: target.renderPass())
        #expect(probe.allocations == 2 && probe.uploadedColumns == 15)

        // A feed with another history: another texture.
        let longer = HeatmapFeed(history: 64)
        try append(0 ..< 3, to: longer, rows: 40)
        renderer.setFeed(longer)
        renderer.draw(to: target.renderPass())
        #expect(probe.allocations == 3)

        // The picture after a new shape is the picture of a renderer made for that shape.
        renderer.setFeed(feed)
        renderer.setValueRange(-90 ... 0)
        let shown = picture(renderer, target, context)
        #expect(probe.allocations == 4, "back to a history of 16")
        let fresh = try HeatmapRenderer(context: context, feed: feed)
        let other = try OffscreenTarget(context: context, width: 48, height: 24)
        #expect(picture(fresh, other, context) == shown)
    }

    @Test func aFeedThatStartsOverEmptiesTheTexture() async throws {
        let (feed, renderer, probe, target, context) = try await scene(columns: 10)
        renderer.draw(to: target.renderPass())
        // The feed is attached to rows of the same number that are something else: its
        // history starts over, in the same shape.
        try append(50 ..< 53, to: feed, axis: .lags(count: Self.rows, sampleRate: 48_000))
        let shown = picture(renderer, target, context)
        #expect(probe.clears == 1 && probe.allocations == 1, "emptied, not allocated again")
        #expect(probe.uploadedColumns == 13)
        let fresh = try HeatmapRenderer(context: context, feed: feed)
        let other = try OffscreenTarget(context: context, width: 48, height: 24)
        #expect(picture(fresh, other, context) == shown, "the three columns of the new history, and none of the old")
    }

    @Test func aFeedNoPipelineWritesYetShowsTheLowestColour() async throws {
        let context = try await sharedContext()
        let feed = HeatmapFeed(history: 32)
        let probe = RenderProbe()
        let renderer = try HeatmapRenderer(context: context, feed: feed, probe: probe)
        let target = try OffscreenTarget(context: context, width: 16, height: 8)
        let image = picture(renderer, target, context)
        #expect(probe.draws == 1 && probe.uploads == 0)
        for y in 0 ..< 8 {
            for x in 0 ..< 16 { #expect(image.pixel(x: x, y: y) == (68, 1, 84, 255), "viridis at its low end") }
        }
        #expect(!renderer.needsDraw(), "and nothing more until something changes")
        // Then a pipeline writes it: a texture for its rows, once.
        try append(0 ..< 4, to: feed)
        renderer.draw(to: target.renderPass())
        #expect(probe.allocations == 2 && probe.uploadedColumns == 4 && renderer.failure == nil)
    }

    @Test func aFeedTooLargeForATextureIsReportedAndNotFatal() async throws {
        let context = try await sharedContext()
        let limit = context.capabilities.maximumTextureDimension
        let huge = HeatmapFeed(history: limit + 1)
        try append(0 ..< 2, to: huge, rows: 4)
        // A renderer cannot be made for it …
        #expect(throws: DSPError.self) { try HeatmapRenderer(context: context, feed: huge) }
        // … and one that is given it later shows nothing and says why.
        let (small, renderer, probe, target, _) = try await scene(columns: 5)
        renderer.draw(to: target.renderPass())
        renderer.setFeed(huge)
        #expect(renderer.draw(to: target.renderPass()), "the draw still happens")
        guard case .unsupportedConfiguration? = renderer.failure else {
            Issue.record("no failure reported: \(String(describing: renderer.failure))")
            return
        }
        #expect(probe.allocations == 1 && probe.uploadedColumns == 5)
        context.waitUntilIdle()
        #expect(target.readPixels().pixel(x: 40, y: 3) == (68, 1, 84, 255), "no data: the lowest colour")
        // A feed that fits again is shown again.
        renderer.setFeed(small)
        renderer.draw(to: target.renderPass())
        #expect(probe.uploadedColumns == 10 && renderer.failure == nil)
    }

    @Test func aTargetOfAnotherPixelFormatIsDrawnTheSame() async throws {
        let (_, renderer, _, target, context) = try await scene(columns: 20)
        let reference = picture(renderer, target, context)
        let other = try OffscreenTarget(context: context, width: 48, height: 24, pixelFormat: .bgra8Unorm)
        renderer.becameVisible()
        #expect(picture(renderer, other, context) == reference, "bgra, the format a view presents")

        // A format the context was not built for: its pipeline is made on the first draw.
        let shape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
        shape.usage = [.renderTarget, .shaderRead]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = context.device.makeTexture(descriptor: shape)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        renderer.becameVisible()
        #expect(renderer.draw(to: pass))
        renderer.becameVisible()
        #expect(renderer.draw(to: pass), "and kept for the second")
        context.waitUntilIdle()
    }

    // MARK: The pieces

    @Test func theLedgerHoldsExactlyTheFiveCauses() {
        var ledger = DrawLedger()
        #expect(ledger.pending(generation: 0) == [.feedReplaced, .newData], "nothing shown yet")
        ledger.settle(generation: 7)
        #expect(ledger.pending(generation: 7).isEmpty && ledger.pending(generation: 8) == .newData)
        ledger.raise(.appearanceChanged)
        ledger.raise(.drawableSizeChanged)
        ledger.raise(.becameVisible)
        #expect(ledger.pending(generation: 7) == [.appearanceChanged, .drawableSizeChanged, .becameVisible])
        ledger.forgetFeed()
        #expect(ledger.pending(generation: 7).contains(.feedReplaced) && ledger.pending(generation: 7).contains(.newData))
        ledger.settle(generation: 0)
        #expect(ledger.pending(generation: 0).isEmpty)
        let all: RenderCauses = [.newData, .appearanceChanged, .drawableSizeChanged, .becameVisible, .feedReplaced]
        #expect(all.rawValue == 0b11111 && RenderCauses(rawValue: 2) == .appearanceChanged)
    }

    @Test func theProbeCountsWhatItIsTold() {
        let probe = RenderProbe()
        probe.recordMake()
        probe.recordUpdate()
        probe.recordUpdate()
        probe.recordAttach()
        probe.recordUpload(columns: 0)
        probe.recordUpload(columns: 3)
        probe.recordDraw(calls: 1)
        probe.recordAllocation()
        probe.recordClear()
        #expect(probe.makes == 1 && probe.updates == 2 && probe.attaches == 1)
        #expect(probe.uploads == 1 && probe.uploadedColumns == 3, "a pass without a column is no upload")
        #expect(probe.draws == 1 && probe.drawCalls == 1 && probe.allocations == 1 && probe.clears == 1)
    }

    @Test func theUniformsAreWhatTheShaderDeclares() async throws {
        #expect(MemoryLayout<HeatmapUniforms>.stride == 48 && MemoryLayout<HeatmapUniforms>.alignment == 4, "five floats and seven unsigned integers")
        let texture = try HeatmapTexture(context: try await sharedContext(), binCount: 9, history: 5)
        let uniforms = HeatmapUniforms(texture: texture, span: 0.25 ... 0.75, valueRange: -80 ... -20, visibleColumns: 3.5, interpolation: .nearest)
        #expect(uniforms.valueLow == -80 && uniforms.valueScale == 1 / 60 && uniforms.positionLow == 0.25 && uniforms.positionHigh == 0.75)
        #expect(uniforms.visibleColumns == 3.5 && uniforms.history == 5 && uniforms.binCount == 9 && uniforms.nearest == 1 && uniforms.warpSize == 4_096)
        // No span, or one that is none, shows the whole history; a range of no width divides nothing by zero.
        for none in [nil, 0, -4, Double.infinity, Double.nan] as [Double?] {
            let whole = HeatmapUniforms(texture: texture, span: 0 ... 1, valueRange: 5 ... 5, visibleColumns: none, interpolation: .linear)
            #expect(whole.visibleColumns == 5 && whole.valueScale.isFinite && whole.valueScale > 0 && whole.nearest == 0)
        }
        let unbounded = HeatmapUniforms(texture: texture, span: 0 ... 1, valueRange: -.infinity ... .infinity, visibleColumns: nil, interpolation: .linear)
        #expect(unbounded.valueLow == 0 && unbounded.valueScale.isFinite)
    }
}
