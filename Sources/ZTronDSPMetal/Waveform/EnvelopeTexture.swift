import Accelerate
import Foundation
import Metal
import ZTronDSPCore

/// The data texture of a waveform (WP-607, §8.2): one `rg16Float` texture of (minimum,
/// maximum) pairs, a ring of `capacity` slots followed by its reduced levels.
///
/// Level `k + 1` holds, for every two entries of level `k`, the smaller minimum and the larger
/// maximum (an entry without a partner is carried up alone): the pyramid of §8.2, kept over
/// the slots of the ring. The fragment shader reduces any run of slots exactly by walking up
/// the levels, so however many pairs fall on one pixel, none is missed. Loaded once with a
/// whole envelope, slot 0 first, the levels are those of the core's `EnvelopePyramid`.
///
/// The entries form one linear array, level after level, folded into rows of `rowWidth`
/// texels, so an envelope longer than a texture is wide still fits.
///
/// A slot that holds no pair holds (+largest, −largest), the neutral element of the
/// reduction. Appending pairs writes them to their slots and brings the entries above them up
/// to date: an upload in proportion to the pairs that are new (V-5).
///
/// Threading: a GPU resource owned by one renderer; one thread at a time. `append` allocates
/// nothing.
final class EnvelopeTexture {
    /// Texels per row: a width every device has a texture for.
    static let foldWidth = 4_096

    let texture: any MTLTexture
    /// Slots in the ring: pairs at level 0.
    let capacity: Int
    let layout: LevelLayout
    let rowWidth: Int
    /// The slot the next pair is written to.
    private(set) var head = 0
    /// Pairs the ring holds.
    private(set) var available = 0

    /// Every entry as two floats, minimum then maximum: what the texture holds, kept here so
    /// the levels can be brought up to date without reading the GPU.
    private let mirror: AlignedBuffer<Float>
    private let halves: AlignedBuffer<UInt16>

    /// - Throws: `unsupportedConfiguration` when the envelope does not fit a texture of the
    ///   device; `resourceAllocationFailed` when the device or the system gives no memory.
    init(context: MetalContext, capacity: Int) throws(DSPError) {
        let slots = max(capacity, 1)
        let layout = LevelLayout(count: slots)
        let width = min(layout.total, Self.foldWidth)
        let height = (layout.total + width - 1) / width
        guard context.permits(width: width, height: height) else {
            throw .unsupportedConfiguration(
                reason: "an envelope of \(slots) pairs needs a texture of \(width) × \(height) texels; "
                    + "this device has none above \(context.capabilities.maximumTextureDimension) each way")
        }
        let shape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float, width: width, height: height, mipmapped: false)
        shape.usage = .shaderRead
        let texture = try MetalResources.texture(shape, on: context.device, what: "an envelope texture of \(width) × \(height) texels")
        texture.label = "ZTronDSP envelope"
        self.texture = texture
        self.capacity = slots
        self.layout = layout
        rowWidth = width
        // The last row of the texture may reach past the last entry: room for whole rows.
        mirror = try AlignedBuffer<Float>(count: width * height * 2)
        halves = try AlignedBuffer<UInt16>(count: width * height * 2)
        reset()
    }

    /// Forgets every pair: every entry becomes the neutral element again, and the whole
    /// texture is written once.
    func clear() {
        head = 0
        available = 0
        reset()
    }

    private func reset() {
        var entry = 0
        let entries = mirror.count / 2
        while entry < entries {
            mirror.baseAddress[2 * entry] = HalfFloat.largest
            mirror.baseAddress[2 * entry + 1] = -HalfFloat.largest
            entry += 1
        }
        upload(from: 0, count: entries)
    }

    /// Appends `count` pairs, minimum then maximum each, oldest first, replacing the oldest the
    /// ring holds. More pairs than the ring holds leave the newest `capacity` of them.
    func append(_ pairs: UnsafePointer<Float>, count: Int) {
        var done = max(count - capacity, 0)
        while done < count {
            // Up to the end of the ring in one piece.
            let run = min(count - done, capacity - head)
            write(pairs + 2 * done, count: run, at: head)
            head = (head + run) % capacity
            available = min(available + run, capacity)
            done += run
        }
    }

    /// Writes `count` pairs to the slots from `first` on, and brings the levels above them up
    /// to date.
    private func write(_ pairs: UnsafePointer<Float>, count: Int, at first: Int) {
        let base = mirror.baseAddress
        var low = -HalfFloat.largest, high = HalfFloat.largest
        vDSP_vclip(pairs, 1, &low, &high, base + 2 * first, 1, vDSP_Length(2 * count))
        var sum: Float = 0
        vDSP_sve(base + 2 * first, 1, &sum, vDSP_Length(2 * count))
        // A pair that is not a number shows as silence.
        if sum.isNaN { HalfFloat.replaceNotANumber(base + 2 * first, count: 2 * count, with: 0) }
        upload(from: first, count: count)

        var from = first, to = first + count - 1
        var level = 1
        while level < layout.counts.count {
            from /= 2
            to /= 2
            let below = base + 2 * layout.offsets[level - 1], here = base + 2 * layout.offsets[level]
            let belowCount = layout.counts[level - 1]
            var entry = from
            while entry <= to {
                let left = 2 * entry, right = min(2 * entry + 1, belowCount - 1)
                here[2 * entry] = min(below[2 * left], below[2 * right])
                here[2 * entry + 1] = max(below[2 * left + 1], below[2 * right + 1])
                entry += 1
            }
            upload(from: layout.offsets[level] + from, count: to - from + 1)
            level += 1
        }
    }

    /// Converts `count` entries of the mirror, from entry `first` on, to half floats and writes
    /// them to the texture, row by row.
    private func upload(from first: Int, count: Int) {
        var source = vImage_Buffer(data: mirror.baseAddress + 2 * first, height: 1, width: vImagePixelCount(2 * count),
                                   rowBytes: 2 * count * MemoryLayout<Float>.stride)
        var target = vImage_Buffer(data: halves.baseAddress + 2 * first, height: 1, width: vImagePixelCount(2 * count),
                                   rowBytes: 2 * count * MemoryLayout<UInt16>.stride)
        vImageConvert_PlanarFtoPlanar16F(&source, &target, vImage_Flags(kvImageDoNotTile))
        var entry = first
        let end = first + count
        while entry < end {
            let column = entry % rowWidth, row = entry / rowWidth
            let run = min(end - entry, rowWidth - column)
            texture.replace(region: MTLRegionMake2D(column, row, run, 1), mipmapLevel: 0, withBytes: halves.baseAddress + 2 * entry,
                            bytesPerRow: run * 2 * MemoryLayout<UInt16>.stride)
            entry += run
        }
    }
}
