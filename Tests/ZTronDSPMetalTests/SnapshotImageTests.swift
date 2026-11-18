import CoreGraphics
import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// `FeedSnapshot.image(size:colorMap:valueRange:frequencyScale:)` (WP-609): an off-screen
/// render converted by Core Image, on the background executor.
@Suite("Snapshot images")
struct SnapshotImageTests {
    /// The snapshot of a feed that holds the columns of a golden fixture.
    private func heatmapSnapshot(_ name: String) throws -> (snapshot: FeedSnapshot, fixture: GoldenCase) {
        let fixture = try GoldenImages.file.get().require(name)
        let rows = try fixture.integer("rows"), appended = try fixture.integer("appended")
        let feed = HeatmapFeed(history: try fixture.integer("history"))
        let data = try GoldenImages.data(fixture.string("data"))
        try FeedWriter.append(Array(data.prefix(appended * rows)), rows: rows, axis: .linearFrequency(binCount: rows, nyquist: 24_000), to: feed)
        return (feed.snapshot(), fixture)
    }

    private func waveformSnapshot(_ name: String) throws -> (snapshot: FeedSnapshot, fixture: GoldenCase) {
        let fixture = try GoldenImages.file.get().require(name)
        let feed = WaveformFeed(history: try fixture.integer("history"))
        try FeedWriter.append(pairs: try GoldenImages.data(fixture.string("data")), to: feed)
        return (feed.snapshot(), fixture)
    }

    private func size(_ fixture: GoldenCase) throws -> CGSize {
        CGSize(width: try fixture.integer("width"), height: try fixture.integer("height"))
    }

    // MARK: Pixel parity

    @Test func theImageHoldsThePixelsTheTextureWasReadBackWith() async throws {
        let context = try await sharedContext()
        // The conversion by Core Image against the read-back of the same off-screen texture.
        let (heat, heatFixture) = try heatmapSnapshot("heatmap-logarithmic")
        let (wave, waveFixture) = try waveformSnapshot("waveform-sine")
        let heatSize = try size(heatFixture), waveSize = try size(waveFixture)
        let results = try await BackgroundWork.run { checkpoint throws(DSPError) -> [(image: CGImage, pixels: PixelImage)] in
            [try SnapshotImage.render(heat, size: heatSize, colorMap: .viridis, valueRange: -90 ... 0, frequencyScale: .logarithmic, context: context, checkpoint: checkpoint),
             try SnapshotImage.render(wave, size: waveSize, colorMap: .magma, valueRange: -1 ... 1, frequencyScale: .linear, context: context, checkpoint: nil)]
        }
        for (result, expected) in zip(results, [heatSize, waveSize]) {
            #expect(result.image.width == Int(expected.width) && result.image.height == Int(expected.height))
            #expect(result.pixels.width == result.image.width && result.pixels.height == result.image.height)
            let converted = try PixelImage(result.image)
            #expect(converted == result.pixels, "pixel for pixel: largest difference \(converted.largestDifference(from: result.pixels) ?? -1)")
            #expect(Set(stride(from: 3, to: converted.pixels.count, by: 4).map { converted.pixels[$0] }) == [255], "opaque")
        }
    }

    @Test func theImageOfAHeatmapSnapshotIsTheGoldenPicture() async throws {
        for (name, map, scale) in [("heatmap-logarithmic", "viridis", "logarithmic"), ("heatmap-magma", "magma", "linear"), ("heatmap-mel", "viridis", "mel")] {
            let (snapshot, fixture) = try heatmapSnapshot(name)
            let image = try await render(snapshot, size: try size(fixture), map: HeatmapGoldenTests.colorMap(map), scale: HeatmapGoldenTests.scale(scale))
            let ratio = try #require(try PixelImage(image).peakSignalToNoiseRatio(against: GoldenImages.image(name)))
            #expect(ratio >= 40, "\(name): PSNR \(ratio) dB")
        }
    }

    /// The generic call, with the strategies opened.
    private func render(_ snapshot: FeedSnapshot, size: CGSize, map: some ColorMap, scale: some FrequencyScale) async throws -> CGImage {
        try await snapshot.image(size: size, colorMap: map, valueRange: -90 ... 0, frequencyScale: scale)
    }

    @Test func theImageOfAWaveformSnapshotIsTheGoldenPicture() async throws {
        let (snapshot, fixture) = try waveformSnapshot("waveform-sine")
        let fill = try fixture.numbers("fill"), background = try fixture.numbers("background")
        // A waveform is drawn in the map's last colour on its first.
        let map = ListedColorMap.stops([DisplayColor(red: background[0], green: background[1], blue: background[2]),
                                        DisplayColor(red: fill[0], green: fill[1], blue: fill[2])])
        let image = try await snapshot.image(size: try size(fixture), colorMap: map, valueRange: -1 ... 1)
        let ratio = try #require(try PixelImage(image).peakSignalToNoiseRatio(against: GoldenImages.image("waveform-sine")))
        #expect(ratio >= 40, "PSNR \(ratio) dB")
        // Another amplitude range is another picture.
        let clipped = try await snapshot.image(size: try size(fixture), colorMap: map, valueRange: -0.4 ... 0.4)
        #expect(try PixelImage(clipped) != PixelImage(image))
    }

    // MARK: Background work (BG-1…BG-3)

    /// A colour map that notes which thread asks it.
    struct WatchedMap: ColorMap {
        let onMainThread: Flag
        let onBackgroundExecutor: Flag

        func color(at position: Double) -> DisplayColor {
            if pthread_main_np() != 0 { onMainThread.set() }
            if BackgroundWork.isCurrent { onBackgroundExecutor.set() }
            return DisplayColor(red: position, green: position, blue: position)
        }

        static func == (lhs: WatchedMap, rhs: WatchedMap) -> Bool { lhs.onMainThread === rhs.onMainThread }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(onMainThread)) }
    }

    @MainActor
    @Test func theWorkNeverRunsOnTheMainThread() async throws {
        let (snapshot, _) = try heatmapSnapshot("heatmap-linear")
        let map = WatchedMap(onMainThread: Flag(), onBackgroundExecutor: Flag())
        // Called from the main actor.
        #expect(pthread_main_np() != 0)
        let image = try await snapshot.image(size: CGSize(width: 32, height: 16), colorMap: map, valueRange: -90 ... 0)
        #expect(image.width == 32 && image.height == 16)
        #expect(map.onBackgroundExecutor.isSet, "the map was asked on the background executor")
        #expect(!map.onMainThread.isSet, "and never on the main thread")
    }

    @Test func aCancelledTaskGetsNoImage() async throws {
        let (snapshot, _) = try heatmapSnapshot("heatmap-linear")
        let task = Task { () async throws -> CGImage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await snapshot.image(size: CGSize(width: 32, height: 16), valueRange: -90 ... 0)
        }
        #expect(await task.result.isCancelled)

        // Cancelled between two steps of the upload: the checkpoint is looked at before each.
        let context = try await sharedContext()
        let cancelled = Task { () async throws -> Int in
            try await BackgroundWork.run { checkpoint throws(DSPError) -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                // Give the cancellation handler its turn.
                var spins = 0
                while !checkpoint.isCancelled, spins < 2_000 {
                    usleep(1_000)
                    spins += 1
                }
                return try SnapshotImage.render(snapshot, size: CGSize(width: 8, height: 8), colorMap: .viridis, valueRange: -90 ... 0,
                                                frequencyScale: .linear, context: context, checkpoint: checkpoint).image.width
            }
        }
        cancelled.cancel()
        #expect(await cancelled.result.isCancelled)
    }

    // MARK: Sizes and shapes

    @Test func theSizeIsRoundedToWholePixelsAndHasToFitATexture() async throws {
        let (snapshot, _) = try heatmapSnapshot("heatmap-linear")
        let image = try await snapshot.image(size: CGSize(width: 100.4, height: 50.6), valueRange: -90 ... 0)
        #expect(image.width == 100 && image.height == 51)
        let limit = try await sharedContext().capabilities.maximumTextureDimension
        for size in [CGSize(width: 0, height: 10), CGSize(width: 10, height: 0.2), CGSize(width: -5, height: 5), CGSize(width: Double(limit) + 1, height: 4),
                     CGSize(width: Double.nan, height: 4), CGSize(width: 4, height: Double.infinity)] {
            await #expect(throws: DSPError.self, "\(size)") { try await snapshot.image(size: size, valueRange: -90 ... 0) }
        }
    }

    @Test func aSnapshotWithoutColumnsIsAnImageOfTheLowestColour() async throws {
        let empty = HeatmapFeed(history: 8).snapshot()
        #expect(empty.columnCount == 0 && empty.rowCount == 0)
        let image = try PixelImage(try await empty.image(size: CGSize(width: 6, height: 4), colorMap: .inferno, valueRange: 0 ... 1))
        for y in 0 ..< 4 {
            for x in 0 ..< 6 { #expect(image.pixel(x: x, y: y) == (0, 0, 4, 255), "inferno at its low end") }
        }
        // A waveform without pairs: the background, which is the map's first colour.
        let silent = try PixelImage(try await WaveformFeed(history: 8).snapshot().image(size: CGSize(width: 6, height: 4), colorMap: .viridis, valueRange: -1 ... 1))
        #expect(silent.pixel(x: 2, y: 2) == (68, 1, 84, 255))
        // Rows that are not frequencies are drawn bin for bin, whatever the scale.
        let chroma = FeedSnapshot(content: .heatmap, axis: .pitchClasses, environment: nil, rowCount: 12, values: (0 ..< 24).map { Float($0 % 12) / 11 }, times: [0, 1])
        let plain = try PixelImage(try await chroma.image(size: CGSize(width: 4, height: 24), colorMap: .grayscale, valueRange: 0 ... 1))
        let warped = try PixelImage(try await chroma.image(size: CGSize(width: 4, height: 24), colorMap: .grayscale, valueRange: 0 ... 1, frequencyScale: .logarithmic))
        #expect(plain == warped && plain.pixel(x: 0, y: 23).red < 12 && plain.pixel(x: 0, y: 0).red > 243, "the first class at the bottom, the last at the top")
    }

    @Test func aSnapshotTooLargeForATextureIsRefused() async throws {
        let limit = try await sharedContext().capabilities.maximumTextureDimension
        // Twice the rows plus their levels across.
        let wide = FeedSnapshot(content: .heatmap, axis: nil, environment: nil, rowCount: limit, values: [Float](repeating: 0, count: limit), times: [0])
        await #expect(throws: DSPError.self) { try await wide.image(size: CGSize(width: 8, height: 8), valueRange: 0 ... 1) }
        // A snapshot whose values do not fill its columns is drawn as far as they go.
        let ragged = FeedSnapshot(content: .heatmap, axis: nil, environment: nil, rowCount: 4, values: [1, 1, 1, 1, 1, 1], times: [0, 1, 2])
        let image = try PixelImage(try await ragged.image(size: CGSize(width: 4, height: 4), colorMap: .grayscale, valueRange: 0 ... 1))
        #expect(image.pixel(x: 0, y: 0).red == 255, "the one whole column")
    }
}
