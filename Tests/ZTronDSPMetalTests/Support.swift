import Accelerate
import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

// Support for the tests of the Metal target: stages that put chosen values into a feed through
// the public API, read-back of textures, and the golden images.

// MARK: Writing a feed

/// Turns every block of `rows` samples into one column of `rows` values: the test's way to put
/// the values it wants into a `HeatmapFeed`, written against the public API as a stage outside
/// the package would be.
struct TestColumns: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, DecibelValues>
    let rows: Int
    let axis: FeedAxis

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rows = rows
        context.emit(.analysis(AnalysisStep(
            name: "TestColumns", key: self, output: .real(count: rows), scope: .spectral(frameSize: max(2 * (rows - 1), 2), hopSize: rows, axis: axis)
        ) { () throws(DSPError) -> any AnalysisNode in
            TestColumnsNode(rows: rows)
        }))
    }
}

final class TestColumnsNode: AnalysisNode {
    let rows: Int

    init(rows: Int) {
        self.rows = rows
    }

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples, block.frameCount == rows else { return }
        let samples = block.channel(0), values = output.real
        var row = 0
        while row < rows {
            values[row] = samples[row]
            row += 1
        }
        output.emit()
    }

    func reset() {}
}

/// Turns every block of samples into (minimum, maximum) pairs: two samples make one pair.
struct TestPairs: PipelineStage {
    typealias Input = Samples
    typealias Output = Envelope
    let pairsPerBlock: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.analysis(AnalysisStep(name: "TestPairs", key: self, output: .envelope(maximumCount: pairsPerBlock)) {
            () throws(DSPError) -> any AnalysisNode in TestPairsNode()
        }))
    }
}

final class TestPairsNode: AnalysisNode {
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        let samples = block.channel(0), minima = output.minima, maxima = output.maxima
        let pairs = min(block.frameCount / 2, minima.count)
        var pair = 0
        while pair < pairs {
            minima[pair] = samples[2 * pair]
            maxima[pair] = samples[2 * pair + 1]
            pair += 1
        }
        output.emit(count: pairs)
    }

    func reset() {}
}

enum FeedWriter {
    static let format = SignalFormat(sampleRate: 48_000)

    /// Appends columns to a heat-map feed: `values` holds `rows` values per column, column
    /// after column. The feed is attached for the length of the call, as an offline run does.
    static func append(_ values: [Float], rows: Int, axis: FeedAxis? = nil, to feed: HeatmapFeed) throws {
        precondition(values.count % rows == 0)
        let pipeline = Pipeline<Samples, Samples>().appending(TestColumns(rows: rows, axis: axis ?? .indices(count: rows))).emit(to: feed)
        try pipeline.run(on: values, format: format, blockSize: rows)
    }

    /// Appends pairs to a waveform feed: `pairs` holds a minimum and a maximum per pair.
    static func append(pairs: [Float], to feed: WaveformFeed) throws {
        precondition(pairs.count % 2 == 0)
        let pipeline = Pipeline<Samples, Samples>().appending(TestPairs(pairsPerBlock: 64)).emit(to: feed)
        try pipeline.run(on: pairs, format: format, blockSize: 128)
    }
}

// MARK: Reading textures back

enum Readback {
    /// The texels of an `r16Float` texture as floats, row after row.
    static func floats(_ texture: any MTLTexture) -> [Float] {
        halves(texture, channels: 1)
    }

    /// The texels of an `rg16Float` texture as floats, two per texel, row after row.
    static func pairs(_ texture: any MTLTexture) -> [Float] {
        halves(texture, channels: 2)
    }

    private static func halves(_ texture: any MTLTexture, channels: Int) -> [Float] {
        let count = texture.width * texture.height * channels
        var raw = [UInt16](repeating: 0, count: count)
        raw.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * channels * 2, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        var floats = [Float](repeating: 0, count: count)
        raw.withUnsafeMutableBytes { source in
            floats.withUnsafeMutableBytes { target in
                var from = vImage_Buffer(data: source.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var to = vImage_Buffer(data: target.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
            }
        }
        return floats
    }

    /// The bytes of an 8-bit four-channel texture, row after row.
    static func bytes(_ texture: any MTLTexture) -> [UInt8] {
        var raw = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        raw.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return raw
    }

    /// The texels of an `r32Float` texture.
    static func singles(_ texture: any MTLTexture) -> [Float] {
        var raw = [Float](repeating: 0, count: texture.width * texture.height)
        raw.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return raw
    }
}

/// The value a half float holds for `value`: what a texel reads back as.
func halfRounded(_ value: Float) -> Float {
    Float(Float16(value))
}

// MARK: Golden images

enum GoldenImages {
    /// The fixtures the generator `Tests/Golden/generators/metal_images.py` wrote.
    static let file = Result { try GoldenFile(named: "metal_images", in: .module) }

    /// A golden picture, by its file name without the extension.
    static func image(_ name: String) throws -> PixelImage {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Golden"), "no golden image \(name).png")
        return try PixelImage(pngData: Data(contentsOf: url))
    }

    /// One of the generator's data sets: every value it stored, row after row.
    static func data(_ name: String) throws -> [Float] {
        try file.get().require("data-" + name).floats("values")
    }

    static func cases(ofKind kind: String) throws -> [GoldenCase] {
        try file.get().cases.filter { (try? $0.string("kind")) == kind }
    }
}

/// A switch a closure on another thread can throw.
final class Flag: @unchecked Sendable {
    // Threading: one writer, read after the writer has finished.
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// The context every test shares: made once, on the background executor.
func sharedContext() async throws -> MetalContext {
    try await MetalContext.shared()
}
