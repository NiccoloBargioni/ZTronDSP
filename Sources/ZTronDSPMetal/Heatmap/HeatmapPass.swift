import Foundation
import Metal
import ZTronDSPCore

/// The uniforms of the heat-map fragment shader, field for field as `ZTDHeatmapUniforms` in
/// `Heatmap.metal` declares them.
struct HeatmapUniforms: Equatable {
    var valueLow: Float
    var valueScale: Float
    var positionLow: Float
    var positionHigh: Float
    var visibleColumns: Float
    var head: UInt32
    var history: UInt32
    var available: UInt32
    var binCount: UInt32
    var warpSize: UInt32
    var nearest: UInt32
    var reserved: UInt32 = 0

    /// The uniforms that show `texture` as it stands.
    ///
    /// - Parameters:
    ///   - span: the visible stretch of the warp table, from `WarpTable.span`.
    ///   - valueRange: the values shown as the first and the last colour; a range of no width
    ///     is widened by the smallest step, so nothing divides by zero.
    ///   - visibleColumns: columns across the width; `nil`, or a number that is not positive,
    ///     shows the whole history.
    init(texture: HeatmapTexture, span: ClosedRange<Float>, valueRange: ClosedRange<Float>, visibleColumns: Double?,
         interpolation: RowInterpolation) {
        let low = valueRange.lowerBound.isFinite ? valueRange.lowerBound : 0
        let high = valueRange.upperBound.isFinite ? valueRange.upperBound : low
        let width = max(high - low, Float.leastNormalMagnitude)
        let columns = visibleColumns.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Double(texture.history)
        valueLow = low
        valueScale = 1 / width
        positionLow = span.lowerBound
        positionHigh = span.upperBound
        self.visibleColumns = Float(columns)
        head = UInt32(texture.head)
        history = UInt32(texture.history)
        available = UInt32(texture.available)
        binCount = UInt32(texture.binCount)
        warpSize = UInt32(WarpTable.size)
        nearest = interpolation == .nearest ? 1 : 0
    }
}

/// The two look-up textures of a heat map: the warp table (`r32Float`, one row) and the colour
/// table (`rgba8Unorm`, 256 × 1, WP-602). Setting either copies a few kilobytes; neither is a
/// column upload.
///
/// Threading: GPU resources owned by one renderer; one thread at a time.
final class HeatmapLookups {
    let warp: any MTLTexture
    let colors: any MTLTexture

    init(context: MetalContext) throws(DSPError) {
        let warpShape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: WarpTable.size, height: 1, mipmapped: false)
        warpShape.usage = .shaderRead
        let colorShape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        colorShape.usage = .shaderRead
        warp = try MetalResources.texture(warpShape, on: context.device, what: "the warp table of a heat map")
        colors = try MetalResources.texture(colorShape, on: context.device, what: "the colour table of a heat map")
        warp.label = "ZTronDSP warp table"
        colors.label = "ZTronDSP colour map"
    }

    func setWarp(_ table: WarpTable) {
        table.rows.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            warp.replace(region: MTLRegionMake2D(0, 0, WarpTable.size, 1), mipmapLevel: 0, withBytes: base,
                         bytesPerRow: WarpTable.size * MemoryLayout<Float>.stride)
        }
    }

    /// Sets the colour table from the 1 024 bytes of a `ColorMap.lookupTable`.
    func setColors(_ table: [UInt8]) {
        guard table.count == 1_024 else { return }
        table.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            colors.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: 1_024)
        }
    }
}

extension WarpTable {
    /// The table for the rows of a feed: warped by `scale` when the rows are evenly spaced in
    /// hertz, bin for bin otherwise (VC-5).
    init(axis: FeedAxis?, rowCount: Int, scale: some FrequencyScale) {
        if case .linearFrequency(_, let nyquist)? = axis {
            self.init(rowCount: rowCount, nyquist: nyquist, scale: scale)
        } else {
            self.init(rowCount: rowCount)
        }
    }
}

/// One heat-map draw: one render pass, one draw call, no vertex buffer (§8.2).
enum HeatmapPass {
    /// Encodes the pass into `commands`. `pipeline` is the one for the pixel format of the
    /// pass's first colour attachment.
    static func encode(
        _ uniforms: HeatmapUniforms, data: any MTLTexture, lookups: HeatmapLookups, pipeline: any MTLRenderPipelineState,
        to pass: MTLRenderPassDescriptor, in commands: any MTLCommandBuffer
    ) {
        var values = uniforms
        MetalResources.drawScreen(with: pipeline, to: pass, in: commands) { encoder in
            encoder.setFragmentBytes(&values, length: MemoryLayout<HeatmapUniforms>.stride, index: 0)
            encoder.setFragmentTexture(data, index: 0)
            encoder.setFragmentTexture(lookups.warp, index: 1)
            encoder.setFragmentTexture(lookups.colors, index: 2)
        }
    }
}
