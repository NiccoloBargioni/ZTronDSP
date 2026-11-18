import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// The heat-map shader (WP-605) against golden images computed from the definition by
/// `Tests/Golden/generators/metal_images.py` (§8.5): PSNR ≥ 40 dB.
@MainActor
@Suite("Heat-map golden images")
struct HeatmapGoldenTests {
    /// The bar of §8.5.
    nonisolated static let bar = 40.0
    nonisolated static let nyquist = 24_000.0

    /// Every heat-map fixture of the generator.
    nonisolated static let fixtures = [
        "heatmap-linear", "heatmap-logarithmic", "heatmap-mel", "heatmap-magma", "heatmap-inferno", "heatmap-turbo", "heatmap-grayscale",
        "heatmap-wrap", "heatmap-partial", "heatmap-clamp", "heatmap-peak-linear", "heatmap-peak-logarithmic", "heatmap-peak-mel",
        "heatmap-zoom", "heatmap-chroma", "heatmap-bands", "heatmap-band-range",
    ]

    static func colorMap(_ name: String) -> any ColorMap {
        switch name {
        case "magma": ListedColorMap.magma
        case "inferno": ListedColorMap.inferno
        case "turbo": TurboColorMap()
        case "grayscale": GrayscaleColorMap()
        default: ListedColorMap.viridis
        }
    }

    static func scale(_ name: String) -> any FrequencyScale {
        switch name {
        case "logarithmic": LogarithmicFrequencyScale()
        case "mel": MelFrequencyScale(formula: SlaneyMelFormula())
        default: LinearFrequencyScale()
        }
    }

    /// A feed, a renderer set up as the fixture says, and the fixture's columns.
    struct Scene {
        let feed: HeatmapFeed
        let renderer: HeatmapRenderer
        let target: OffscreenTarget
        let columns: [Float]
        let rows: Int
        let axis: FeedAxis
    }

    static func scene(_ fixture: GoldenCase, context: MetalContext) throws -> Scene {
        let rows = try fixture.integer("rows"), appended = try fixture.integer("appended"), scaleName = try fixture.string("scale")
        let data = try GoldenImages.data(fixture.string("data"))
        let feed = HeatmapFeed(history: try fixture.integer("history"))
        let renderer = try HeatmapRenderer(context: context, feed: feed)
        renderer.setColorMap(colorMap(try fixture.string("colorMap")))
        renderer.setValueRange(Float(try fixture.number("low")) ... Float(try fixture.number("high")))
        renderer.setFrequencyScale(scale(scaleName))
        if let band = try? fixture.numbers("band") { renderer.setFrequencyRange(band[0] ... band[1]) }
        if let shown = try? fixture.numbers("rowsShown") { renderer.setRowRange(shown[0] ... shown[1]) }
        if let visible = try? fixture.number("visible") { renderer.setVisibleColumns(visible) }
        if case .bool(true)? = fixture.parameters["nearest"] { renderer.setRowInterpolation(.nearest) }
        let target = try OffscreenTarget(context: context, width: try fixture.integer("width"), height: try fixture.integer("height"))
        let axis: FeedAxis = scaleName == "rows" ? (rows == 12 ? .pitchClasses : .indices(count: rows)) : .linearFrequency(binCount: rows, nyquist: nyquist)
        return Scene(feed: feed, renderer: renderer, target: target, columns: Array(data.prefix(appended * rows)), rows: rows, axis: axis)
    }

    /// Draws and reads the picture back.
    static func picture(_ scene: Scene, context: MetalContext) -> PixelImage {
        scene.renderer.draw(to: scene.target.renderPass())
        context.waitUntilIdle()
        return scene.target.readPixels()
    }

    @Test(arguments: fixtures)
    func theRenderedPictureMatchesTheGoldenImage(name: String) async throws {
        let context = try await sharedContext()
        let fixture = try GoldenImages.file.get().require(name)
        let scene = try Self.scene(fixture, context: context)
        try FeedWriter.append(scene.columns, rows: scene.rows, axis: scene.axis, to: scene.feed)
        let rendered = Self.picture(scene, context: context)
        let golden = try GoldenImages.image(name)
        let ratio = try #require(rendered.peakSignalToNoiseRatio(against: golden), "\(name): the pictures differ in size")
        print("golden \(name): PSNR \(ratio.isInfinite ? "infinite" : String(format: "%.1f dB", ratio)), largest difference \(rendered.largestDifference(from: golden) ?? -1)")
        #expect(ratio >= Self.bar, "\(name): PSNR \(ratio) dB against the golden image")
        #expect(scene.renderer.probe.draws == 1 && scene.renderer.probe.drawCalls == 1, "one draw, one draw call")
    }

    @Test func everyHeatmapFixtureOfTheGeneratorIsCompared() throws {
        let generated = try GoldenImages.cases(ofKind: "heatmap").map { $0.name }
        #expect(Set(generated) == Set(Self.fixtures) && generated.count == Self.fixtures.count)
    }

    /// Ring wrap-around (§8.5): the columns arrive in three batches with a draw after each, so
    /// the texture's ring wraps while it is shown; the last picture is the golden one, and it
    /// is the picture one upload of everything gives.
    @Test func thePictureDoesNotDependOnHowTheColumnsArrived() async throws {
        let context = try await sharedContext()
        let fixture = try GoldenImages.file.get().require("heatmap-wrap")
        let golden = try GoldenImages.image("heatmap-wrap")

        let atOnce = try Self.scene(fixture, context: context)
        try FeedWriter.append(atOnce.columns, rows: atOnce.rows, axis: atOnce.axis, to: atOnce.feed)
        let reference = Self.picture(atOnce, context: context)

        let batched = try Self.scene(fixture, context: context)
        var uploaded = 0
        for batch in [70, 50, 30] {
            let values = Array(batched.columns[uploaded * batched.rows ..< (uploaded + batch) * batched.rows])
            try FeedWriter.append(values, rows: batched.rows, axis: batched.axis, to: batched.feed)
            uploaded += batch
            _ = Self.picture(batched, context: context)
        }
        let last = batched.target.readPixels()
        #expect(batched.renderer.probe.uploadedColumns == 150 && batched.renderer.probe.draws == 3, "every column went up once")
        #expect(last == reference, "the ring wrapped; the picture is the same, pixel for pixel")
        #expect(try #require(last.peakSignalToNoiseRatio(against: golden)) >= Self.bar)

        // Column by column, as a live feed delivers them.
        let single = try Self.scene(fixture, context: context)
        for column in 0 ..< 150 {
            try FeedWriter.append(Array(single.columns[column * single.rows ..< (column + 1) * single.rows]), rows: single.rows, axis: single.axis, to: single.feed)
            if column % 7 == 0 { _ = Self.picture(single, context: context) }
        }
        #expect(Self.picture(single, context: context) == reference)
    }

    /// V-8: a pixel that covers several bins shows their maximum, so a one-bin peak is visible
    /// at every scale, however few pixels the axis has.
    @Test(arguments: ["linear", "logarithmic", "mel"])
    func aOneBinPeakSurvivesEveryScale(scaleName: String) async throws {
        let context = try await sharedContext()
        let rows = 1_025, history = 4
        let top = ListedColorMap.inferno.lookupTable
        let peakColor = (top[1_020], top[1_021], top[1_022], UInt8(255))
        // Rows from the first the axis shows (a logarithmic axis starts at 20 Hz, above row 0)
        // to the last, with the corners and a spread in between.
        let bins = [1, 2, 3, 17, 100, 511, 512, 513, 800, 1_000, 1_022, 1_023, 1_024] + (scaleName == "logarithmic" ? [] : [0])
        for height in [7, 16, 61, 128] {
            let target = try OffscreenTarget(context: context, width: 8, height: height)
            for bin in bins {
                let feed = HeatmapFeed(history: history)
                let renderer = try HeatmapRenderer(context: context, feed: feed)
                renderer.setColorMap(.inferno)
                renderer.setFrequencyScale(Self.scale(scaleName))
                var column = [Float](repeating: -90, count: rows)
                column[bin] = 0
                try FeedWriter.append(Array([[Float]](repeating: column, count: history).joined()), rows: rows,
                                      axis: .linearFrequency(binCount: rows, nyquist: Self.nyquist), to: feed)
                renderer.draw(to: target.renderPass())
                context.waitUntilIdle()
                let image = target.readPixels()
                let lit = (0 ..< height).filter { image.pixel(x: 3, y: $0) == peakColor }
                #expect(!lit.isEmpty, "\(scaleName), \(height) pixels high: the peak in bin \(bin) is lost")
                // The peak is one row of the data: one row of pixels holds it, two when it sits on their edge.
                #expect(lit.count <= 2, "\(scaleName), \(height) pixels high, bin \(bin): the peak is smeared over \(lit.count) rows")
                // Every column of the picture shows it.
                if let row = lit.first {
                    #expect((0 ..< 8).allSatisfy { image.pixel(x: $0, y: row) == peakColor })
                }
            }
        }
    }
}
