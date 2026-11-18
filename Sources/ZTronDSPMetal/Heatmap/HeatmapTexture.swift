import Accelerate
import Foundation
import Metal
import ZTronDSPCore

/// The data texture of a heat map (WP-604, §8.2): one `r16Float` texture sized by the data,
/// `binCount` values per column and `history` columns, used as a ring.
///
/// One column is one row of texels: its bins, followed by its max-reduced levels (V-8), so a
/// column, or a run of columns, goes to the GPU in one piece exactly as a feed hands it over.
/// The texture's height is the history; `head` is the row the next column is written to, and
/// scrolling moves no texel. Values are clamped to what a half float holds, a value that is
/// not a number becomes the lowest, and the conversion is vImage's.
///
/// Threading: a GPU resource owned by one renderer; one thread at a time. `append` allocates
/// nothing: its staging memory is made with the texture.
final class HeatmapTexture {
    let texture: any MTLTexture
    let binCount: Int
    let history: Int
    let layout: LevelLayout
    /// The row the next column is written to.
    private(set) var head = 0
    /// Columns the ring holds.
    private(set) var available = 0

    /// Columns one upload takes at most.
    let chunkCapacity: Int
    private let floats: AlignedBuffer<Float>
    private let halves: AlignedBuffer<UInt16>

    /// - Throws: `unsupportedConfiguration` when the data does not fit a texture of the
    ///   device; `resourceAllocationFailed` when the device or the system gives no memory.
    init(context: MetalContext, binCount: Int, history: Int) throws(DSPError) {
        let bins = max(binCount, 1), columns = max(history, 1)
        let layout = LevelLayout(count: bins)
        guard context.permits(width: layout.total, height: columns) else {
            throw .unsupportedConfiguration(
                reason: "a heat map of \(bins) rows and \(columns) columns needs a texture of \(layout.total) × \(columns) texels; "
                    + "this device has none above \(context.capabilities.maximumTextureDimension) each way")
        }
        let shape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: layout.total, height: columns, mipmapped: false)
        shape.usage = .shaderRead
        let texture = try MetalResources.texture(shape, on: context.device, what: "a heat-map texture of \(layout.total) × \(columns) texels")
        texture.label = "ZTronDSP heat map"
        self.texture = texture
        self.binCount = bins
        self.history = columns
        self.layout = layout
        // About a quarter of a megabyte of staging, and never less than one column.
        chunkCapacity = max(1, min(columns, 65_536 / layout.total))
        floats = try AlignedBuffer<Float>(count: chunkCapacity * layout.total)
        halves = try AlignedBuffer<UInt16>(count: chunkCapacity * layout.total)
    }

    /// Forgets every column. No texel is touched: the shader draws only what `available` covers.
    func clear() {
        head = 0
        available = 0
    }

    /// Appends `count` columns of `binCount` values each, oldest first, replacing the oldest
    /// the ring holds. More columns than the ring holds leave the newest `history` of them.
    func append(_ columns: UnsafePointer<Float>, count: Int) {
        var done = max(count - history, 0)
        while done < count {
            // Up to the end of the ring, and up to the staging memory, in one piece.
            let run = min(count - done, chunkCapacity, history - head)
            stage(columns + done * binCount, count: run)
            texture.replace(region: MTLRegionMake2D(0, head, layout.total, run), mipmapLevel: 0,
                            withBytes: halves.baseAddress, bytesPerRow: layout.total * MemoryLayout<UInt16>.stride)
            head = (head + run) % history
            available = min(available + run, history)
            done += run
        }
    }

    /// Lays `count` columns out with their reduced levels and converts them to half floats.
    private func stage(_ columns: UnsafePointer<Float>, count: Int) {
        let stride = layout.total
        var low = -HalfFloat.largest, high = HalfFloat.largest
        var column = 0
        while column < count {
            let row = floats.baseAddress + column * stride
            // Level 0: the bins, clamped to what a half float holds.
            vDSP_vclip(columns + column * binCount, 1, &low, &high, row, 1, vDSP_Length(binCount))
            var sum: Float = 0
            vDSP_sve(row, 1, &sum, vDSP_Length(binCount))
            if sum.isNaN { HalfFloat.replaceNotANumber(row, count: binCount, with: low) }
            // Each further level: the larger of every two entries of the one below.
            var level = 1
            while level < layout.counts.count {
                let below = row + layout.offsets[level - 1], here = row + layout.offsets[level]
                let pairs = layout.counts[level - 1] / 2
                vDSP_vmax(below, 2, below + 1, 2, here, 1, vDSP_Length(pairs))
                if layout.counts[level - 1] % 2 == 1 { here[pairs] = below[2 * pairs] }
                level += 1
            }
            column += 1
        }
        var source = vImage_Buffer(data: floats.baseAddress, height: vImagePixelCount(count), width: vImagePixelCount(stride),
                                   rowBytes: stride * MemoryLayout<Float>.stride)
        var target = vImage_Buffer(data: halves.baseAddress, height: vImagePixelCount(count), width: vImagePixelCount(stride),
                                   rowBytes: stride * MemoryLayout<UInt16>.stride)
        vImageConvert_PlanarFtoPlanar16F(&source, &target, vImage_Flags(kvImageDoNotTile))
    }
}
