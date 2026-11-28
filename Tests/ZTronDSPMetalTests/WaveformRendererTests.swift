import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// The waveform shader and renderer (WP-608): golden images computed from the definition by
/// `Tests/Golden/generators/metal_images.py` (§8.5), and the renderer's share of §8.3 and §8.4.
@MainActor
@Suite("Waveform renderer")
struct WaveformRendererTests {
    nonisolated static let bar = 40.0
    nonisolated static let fixtures = ["waveform-sine", "waveform-impulse", "waveform-silence", "waveform-clipped", "waveform-wrap", "waveform-minified"]

    struct Scene {
        let feed: WaveformFeed
        let renderer: WaveformRenderer
        let target: OffscreenTarget
        let pairs: [Float]
    }

    static func scene(_ fixture: GoldenCase, context: MetalContext) throws -> Scene {
        let feed = WaveformFeed(history: try fixture.integer("history"))
        let renderer = try WaveformRenderer(context: context, feed: feed)
        let fill = try fixture.numbers("fill"), background = try fixture.numbers("background")
        renderer.setFillColor(DisplayColor(red: fill[0], green: fill[1], blue: fill[2]))
        renderer.setBackgroundColor(DisplayColor(red: background[0], green: background[1], blue: background[2]))
        renderer.setAmplitudeRange(Float(try fixture.number("low")) ... Float(try fixture.number("high")))
        if let visible = try? fixture.number("visible") { renderer.setVisiblePairs(visible) }
        let target = try OffscreenTarget(context: context, width: try fixture.integer("width"), height: try fixture.integer("height"))
        return Scene(feed: feed, renderer: renderer, target: target, pairs: try GoldenImages.data(fixture.string("data")))
    }

    static func picture(_ renderer: WaveformRenderer, _ target: OffscreenTarget, _ context: MetalContext) -> PixelImage {
        renderer.draw(to: target.renderPass())
        context.waitUntilIdle()
        return target.readPixels()
    }

    // MARK: Golden images

    @Test(arguments: fixtures)
    func theRenderedPictureMatchesTheGoldenImage(name: String) async throws {
        let context = try await sharedContext()
        let scene = try Self.scene(try GoldenImages.file.get().require(name), context: context)
        try FeedWriter.append(pairs: scene.pairs, to: scene.feed)
        let rendered = Self.picture(scene.renderer, scene.target, context)
        let golden = try GoldenImages.image(name)
        let ratio = try #require(rendered.peakSignalToNoiseRatio(against: golden), "\(name): the pictures differ in size")
        print("golden \(name): PSNR \(ratio.isInfinite ? "infinite" : String(format: "%.1f dB", ratio)), largest difference \(rendered.largestDifference(from: golden) ?? -1)")
        #expect(ratio >= Self.bar, "\(name): PSNR \(ratio) dB against the golden image")
        #expect(scene.renderer.probe.draws == 1 && scene.renderer.probe.drawCalls == 1, "one draw call, no vertex buffer")
    }

    @Test func everyWaveformFixtureOfTheGeneratorIsCompared() throws {
        let generated = try GoldenImages.cases(ofKind: "waveform").map { $0.name }
        #expect(Set(generated) == Set(Self.fixtures) && generated.count == Self.fixtures.count)
    }

    /// The ring wraps while it is shown: 400 pairs through 256 slots in batches, a draw after
    /// each. The last picture is the one a single upload gives.
    @Test func thePictureDoesNotDependOnHowThePairsArrived() async throws {
        let context = try await sharedContext()
        let fixture = try GoldenImages.file.get().require("waveform-wrap")
        let atOnce = try Self.scene(fixture, context: context)
        try FeedWriter.append(pairs: atOnce.pairs, to: atOnce.feed)
        let reference = Self.picture(atOnce.renderer, atOnce.target, context)

        let batched = try Self.scene(fixture, context: context)
        var sent = 0
        for batch in [150, 3, 147, 100] {
            try FeedWriter.append(pairs: Array(batched.pairs[2 * sent ..< 2 * (sent + batch)]), to: batched.feed)
            sent += batch
            _ = Self.picture(batched.renderer, batched.target, context)
        }
        #expect(batched.renderer.probe.uploadedColumns == 400 && batched.renderer.probe.draws == 4)
        #expect(batched.target.readPixels() == reference)
    }

    /// No peak is missed however many pairs fall on one pixel (§8.2): one pair of 2 048 reaches
    /// 0.9, and whichever pixel covers it shows it.
    @Test func aOnePairPeakSurvivesEveryZoom() async throws {
        let context = try await sharedContext()
        for position in [0, 1, 700, 1_023, 1_024, 2_046, 2_047] {
            var pairs = [Float](repeating: 0, count: 2 * 2_048)
            pairs[2 * position + 1] = 0.9
            let feed = WaveformFeed(history: 2_048)
            try FeedWriter.append(pairs: pairs, to: feed)
            let renderer = try WaveformRenderer(context: context, feed: feed)
            renderer.setBackgroundColor(.black)
            for width in [13, 64, 300] {
                let target = try OffscreenTarget(context: context, width: width, height: 40)
                renderer.drawableSizeChanged()
                let image = Self.picture(renderer, target, context)
                // Row 5 lies between 0.7 and 0.75: only the pair that reaches 0.9 fills it.
                let lit = (0 ..< width).filter { image.pixel(x: $0, y: 5).red == 255 }
                #expect(lit.count == 1 || (lit.count == 2 && lit[1] == lit[0] + 1), "pair \(position), \(width) pixels wide: lit \(lit)")
                let expected = Int(Double(position) / 2_048 * Double(width))
                #expect(lit.contains(expected), "pair \(position), \(width) pixels wide: lit \(lit), expected \(expected)")
            }
        }
    }

    // MARK: Colour

    @Test func aTransparentBackgroundLeavesAlphaToTheCoverage() async throws {
        let context = try await sharedContext()
        let feed = WaveformFeed(history: 16)
        // A constant envelope between −0.5 and +0.5.
        try FeedWriter.append(pairs: [Float](repeating: 0, count: 16).enumerated().flatMap { _ in [Float(-0.5), Float(0.5)] }, to: feed)
        let renderer = try WaveformRenderer(context: context, feed: feed)
        let target = try OffscreenTarget(context: context, width: 8, height: 40)
        renderer.setFillColor(DisplayColor(red: 1, green: 0.5, blue: 0), opacity: 1)
        var image = Self.picture(renderer, target, context)
        // 40 rows over −1 … 1: the band covers rows 10 … 29.
        #expect(image.pixel(x: 3, y: 20) == (255, 128, 0, 255), "inside the band: the fill")
        #expect(image.pixel(x: 3, y: 2) == (0, 0, 0, 0) && image.pixel(x: 3, y: 37) == (0, 0, 0, 0), "outside: nothing at all")
        #expect(image.pixel(x: 3, y: 10) == (255, 128, 0, 255) && image.pixel(x: 3, y: 9) == (0, 0, 0, 0), "the band's edge falls on a pixel's edge")

        // Half opaque: premultiplied.
        renderer.setFillColor(DisplayColor(red: 1, green: 0.5, blue: 0), opacity: 0.5)
        image = Self.picture(renderer, target, context)
        #expect(image.pixel(x: 3, y: 20) == (128, 64, 0, 128))
        // Over an opaque background the picture is opaque everywhere.
        renderer.setBackgroundColor(DisplayColor(red: 0, green: 0, blue: 1))
        image = Self.picture(renderer, target, context)
        #expect(image.pixel(x: 3, y: 2) == (0, 0, 255, 255) && image.pixel(x: 3, y: 20) == (128, 64, 128, 255))

        // The range moved by one pixel's worth of amplitude: the band moves by one row.
        renderer.setBackgroundColor(nil)
        renderer.setFillColor(.white)
        renderer.setAmplitudeRange(-1.05 ... 0.95)
        image = Self.picture(renderer, target, context)
        #expect(image.pixel(x: 3, y: 8).alpha == 0 && image.pixel(x: 3, y: 9).alpha == 255, "the top edge, one row up")
        #expect(image.pixel(x: 3, y: 28).alpha == 255 && image.pixel(x: 3, y: 29).alpha == 0, "the bottom edge, one row up")
        // An edge inside a pixel: the pixel's alpha is the share of it the band covers. Moved by
        // a quarter of a pixel, the top edge leaves a quarter of row 9 covered, and the bottom
        // edge three quarters of row 29 bare.
        renderer.setAmplitudeRange(-1.0125 ... 0.9875)
        image = Self.picture(renderer, target, context)
        let top = image.pixel(x: 3, y: 9), bottom = image.pixel(x: 3, y: 29)
        #expect(abs(Int(top.alpha) - 64) <= 2 && top.red == top.alpha, "a quarter of the pixel is covered: alpha \(top.alpha), premultiplied")
        #expect(abs(Int(bottom.alpha) - 191) <= 2 && image.pixel(x: 3, y: 30).alpha == 0 && image.pixel(x: 3, y: 10).alpha == 255,
                "three quarters of the pixel are covered: alpha \(bottom.alpha)")
    }

    // MARK: Scheduling and cost (§8.3, §8.4)

    private func scene(history: Int = 64, pairs count: Int = 0) async throws -> (feed: WaveformFeed, renderer: WaveformRenderer, probe: RenderProbe, target: OffscreenTarget, context: MetalContext) {
        let context = try await sharedContext()
        let feed = WaveformFeed(history: history)
        try FeedWriter.append(pairs: pairs(0 ..< count), to: feed)
        let probe = RenderProbe()
        let renderer = try WaveformRenderer(context: context, feed: feed, probe: probe)
        return (feed, renderer, probe, try OffscreenTarget(context: context, width: 32, height: 16), context)
    }

    private func pairs(_ range: Range<Int>) -> [Float] {
        range.flatMap { index in [-Float(index % 9) / 10, Float(index % 7) / 8] }
    }

    @Test func aRendererDrawsOnlyOnACauseAndUploadsOnlyWhatIsNew() async throws {
        let (feed, renderer, probe, target, _) = try await scene(pairs: 10)
        #expect(probe.allocations == 1 && renderer.needsDraw() && renderer.pendingCauses.contains(.feedReplaced))
        #expect(renderer.draw(to: target.renderPass()))
        #expect(probe.draws == 1 && probe.drawCalls == 1 && probe.uploads == 1 && probe.uploadedColumns == 10)
        for _ in 0 ..< 100 { #expect(!renderer.needsDraw() && !renderer.draw(to: target.renderPass())) }
        #expect(probe.draws == 1, "no draw without a cause (V-4)")

        try FeedWriter.append(pairs: pairs(10 ..< 14), to: feed)
        #expect(renderer.pendingCauses == .newData)
        #expect(renderer.draw(to: target.renderPass()))
        #expect(probe.draws == 2 && probe.uploads == 2 && probe.uploadedColumns == 14, "four pairs went up (V-5)")

        renderer.becameVisible()
        #expect(renderer.pendingCauses == .becameVisible && renderer.draw(to: target.renderPass()))
        renderer.drawableSizeChanged()
        #expect(renderer.pendingCauses == .drawableSizeChanged && renderer.draw(to: target.renderPass()))
        #expect(probe.draws == 4 && probe.uploads == 2 && probe.allocations == 1 && probe.clears == 0, "a resize uploads nothing (V-6)")
        #expect(!renderer.draw(to: MTLRenderPassDescriptor()) && !renderer.needsDraw())
        renderer.becameVisible()
        #expect(!renderer.draw(to: MTLRenderPassDescriptor()) && renderer.needsDraw(), "a pass without a target draws nothing and keeps the cause")
    }

    /// §8.3: with nothing pending a tick is one atomic load, and it asks nothing of the heap.
    @Test func anIdleTickAllocatesNothing() async throws {
        let (_, renderer, probe, target, _) = try await scene(pairs: 10)
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
        // Nor do the setters, once each has run (a first call may make the runtime build the
        // metadata of a generic type).
        func set(_ step: Int) {
            renderer.setAmplitudeRange(-1 ... Float(1 + step))
            renderer.setVisiblePairs(Double(10 + step))
            renderer.setFillColor(.white, opacity: Double(step % 100) / 100)
            renderer.setBackgroundColor(step % 2 == 0 ? .black : nil)
        }
        set(1_000)
        set(1_001)
        expectNoAllocations("the setters") {
            var step = 0
            while step < 100 {
                set(step)
                step += 1
            }
        }
        #expect(renderer.pendingCauses == .appearanceChanged)
    }

    @Test func aChangedAppearanceIsExactlyOneDrawAndNoUpload() async throws {
        let (_, renderer, probe, target, context) = try await scene(pairs: 40)
        var last = Self.picture(renderer, target, context)
        var draws = probe.draws
        func changed(_ what: String, _ change: () -> Void) {
            change()
            #expect(renderer.pendingCauses == .appearanceChanged, "\(what): the cause")
            #expect(renderer.draw(to: target.renderPass()) && !renderer.draw(to: target.renderPass()), "\(what): one draw")
            draws += 1
            #expect(probe.draws == draws && probe.uploads == 1 && probe.uploadedColumns == 40, "\(what): exactly one draw, nothing uploaded")
            change()
            #expect(!renderer.needsDraw(), "\(what): an equal value costs nothing")
            context.waitUntilIdle()
            let now = target.readPixels()
            #expect(now != last, "\(what): the picture changed")
            last = now
        }
        changed("amplitude range") { renderer.setAmplitudeRange(-0.5 ... 0.5) }
        changed("visible pairs") { renderer.setVisiblePairs(12.5) }
        changed("fill colour") { renderer.setFillColor(DisplayColor(red: 1, green: 0, blue: 0)) }
        changed("fill opacity") { renderer.setFillColor(DisplayColor(red: 1, green: 0, blue: 0), opacity: 0.25) }
        changed("background") { renderer.setBackgroundColor(DisplayColor(red: 0, green: 0, blue: 0.5)) }
        changed("no background") { renderer.setBackgroundColor(nil) }
        changed("the whole ring") { renderer.setVisiblePairs(nil) }

        // The values the renderer starts with are no change.
        let (_, untouched, counters, _, _) = try await scene(pairs: 2)
        untouched.draw(to: target.renderPass())
        untouched.setAmplitudeRange(-1 ... 1)
        untouched.setVisiblePairs(nil)
        untouched.setFillColor(.white)
        untouched.setBackgroundColor(nil)
        #expect(!untouched.needsDraw() && counters.draws == 1)
    }

    @Test func aReplacedFeedClearsTheTextureOnceAndAnotherHistoryIsAnotherTexture() async throws {
        let (first, renderer, probe, target, context) = try await scene(pairs: 30)
        renderer.draw(to: target.renderPass())
        let second = WaveformFeed(history: 64)
        try FeedWriter.append(pairs: pairs(100 ..< 108), to: second)
        renderer.setFeed(second)
        #expect(probe.clears == 1 && renderer.pendingCauses.contains(.feedReplaced))
        let shown = Self.picture(renderer, target, context)
        #expect(probe.clears == 1 && probe.allocations == 1 && probe.uploadedColumns == 38, "the same history: the texture is kept (V-6)")
        let fresh = try WaveformRenderer(context: context, feed: second)
        let other = try OffscreenTarget(context: context, width: 32, height: 16)
        #expect(Self.picture(fresh, other, context) == shown, "only the new feed's pairs")
        renderer.setFeed(second)
        try FeedWriter.append(pairs: pairs(0 ..< 2), to: first)
        #expect(!renderer.needsDraw() && probe.clears == 1, "the same feed again is no replacement; the old feed is nobody's business")

        // Another history: another texture.
        let longer = WaveformFeed(history: 500)
        try FeedWriter.append(pairs: pairs(0 ..< 300), to: longer)
        renderer.setFeed(longer)
        renderer.draw(to: target.renderPass())
        #expect(probe.allocations == 2 && probe.uploadedColumns == 338 && renderer.failure == nil)
    }

    @Test func aFeedNoPipelineWritesYetShowsNothing() async throws {
        let context = try await sharedContext()
        let feed = WaveformFeed(history: 64)
        let renderer = try WaveformRenderer(context: context, feed: feed)
        let target = try OffscreenTarget(context: context, width: 16, height: 8)
        let image = Self.picture(renderer, target, context)
        #expect(image.pixels.allSatisfy { $0 == 0 }, "transparent: no pair, no band")
        #expect(renderer.probe.draws == 1 && renderer.probe.uploads == 0 && !renderer.needsDraw())
    }

    @Test func aFeedTooLargeForATextureIsReportedAndNotFatal() async throws {
        let context = try await sharedContext()
        let huge = WaveformFeed(history: EnvelopeTexture.foldWidth * context.capabilities.maximumTextureDimension)
        #expect(throws: DSPError.self) { try WaveformRenderer(context: context, feed: huge) }

        // On a context held to textures of 64 texels a history of 100 pairs is too large: a
        // renderer that is given such a feed later shows nothing and says why.
        let limited = try MetalContext(device: context.device, library: context.library, textureLimit: 64)
        let small = WaveformFeed(history: 16), large = WaveformFeed(history: 100)
        try FeedWriter.append(pairs: pairs(0 ..< 10), to: small)
        try FeedWriter.append(pairs: pairs(0 ..< 50), to: large)
        let probe = RenderProbe()
        let renderer = try WaveformRenderer(context: limited, feed: small, probe: probe)
        let target = try OffscreenTarget(context: limited, width: 16, height: 8)
        renderer.draw(to: target.renderPass())
        #expect(probe.uploadedColumns == 10 && renderer.failure == nil)
        renderer.setFeed(large)
        #expect(renderer.draw(to: target.renderPass()), "the draw still happens")
        guard case .unsupportedConfiguration? = renderer.failure else {
            Issue.record("no failure reported: \(String(describing: renderer.failure))")
            return
        }
        #expect(probe.allocations == 1 && probe.uploadedColumns == 10 && probe.clears == 1)
        limited.waitUntilIdle()
        #expect(target.readPixels().pixels.allSatisfy { $0 == 0 }, "no pair is shown")
        // A feed that fits again is shown again.
        renderer.setFeed(small)
        renderer.draw(to: target.renderPass())
        #expect(probe.uploadedColumns == 20 && renderer.failure == nil)
    }

    @Test func aTargetOfAnotherPixelFormatIsDrawnTheSame() async throws {
        let (_, renderer, _, target, context) = try await scene(pairs: 40)
        renderer.setBackgroundColor(.black)
        let reference = Self.picture(renderer, target, context)
        let other = try OffscreenTarget(context: context, width: 32, height: 16, pixelFormat: .bgra8Unorm)
        renderer.becameVisible()
        #expect(Self.picture(renderer, other, context) == reference)
        // The caller's command buffer.
        let commands = try #require(context.commandQueue.makeCommandBuffer())
        renderer.becameVisible()
        #expect(renderer.render(to: target.renderPass(), in: commands) && !renderer.render(to: target.renderPass(), in: commands))
        commands.commit()
        context.waitUntilIdle()
        #expect(target.readPixels() == reference)
        // A format the context was not built for.
        let shape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: false)
        shape.usage = [.renderTarget, .shaderRead]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = context.device.makeTexture(descriptor: shape)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        renderer.becameVisible()
        #expect(renderer.draw(to: pass))
        renderer.becameVisible()
        #expect(renderer.draw(to: pass))
        context.waitUntilIdle()
    }

    @Test func theUniformsAreWhatTheShaderDeclares() async throws {
        #expect(MemoryLayout<WaveformUniforms>.stride == 64 && MemoryLayout<WaveformUniforms>.alignment == 16, "two float4, three floats, five unsigned integers")
        let texture = try EnvelopeTexture(context: try await sharedContext(), capacity: 100)
        let uniforms = WaveformUniforms(texture: texture, amplitudeRange: -0.5 ... 1.5, visiblePairs: 20, fill: DisplayColor(red: 1, green: 0.5, blue: 0.25),
                                        fillOpacity: 0.5, background: nil)
        #expect(uniforms.fill == SIMD4(1, 0.5, 0.25, 0.5) && uniforms.background == SIMD4(0, 0, 0, 0))
        #expect(uniforms.amplitudeLow == -0.5 && uniforms.amplitudeScale == 0.5 && uniforms.visiblePairs == 20 && uniforms.capacity == 100 && uniforms.rowWidth == UInt32(texture.rowWidth))
        let opaque = WaveformUniforms(texture: texture, amplitudeRange: 2 ... 2, visiblePairs: -1, fill: .white, fillOpacity: 7, background: .black)
        #expect(opaque.background == SIMD4(0, 0, 0, 1) && opaque.fill.w == 1 && opaque.visiblePairs == 100 && opaque.amplitudeScale.isFinite)
        let unbounded = WaveformUniforms(texture: texture, amplitudeRange: -.infinity ... .infinity, visiblePairs: .nan, fill: .white, fillOpacity: 1, background: nil)
        #expect(unbounded.amplitudeLow == -1 && unbounded.amplitudeScale.isFinite && unbounded.visiblePairs == 100)
    }
}
