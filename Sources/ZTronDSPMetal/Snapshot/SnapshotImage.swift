import CoreGraphics
import CoreImage
import Foundation
import Metal
import ZTronDSPCore

extension FeedSnapshot {
    /// An image of the snapshot: the heat map or the waveform as a view would draw it, with
    /// the whole snapshot across the width (§8.2, WP-609).
    ///
    /// ```swift
    /// let image = try await feed.snapshot().image(size: CGSize(width: 1_024, height: 512), colorMap: .magma, valueRange: -90 ... 0)
    /// ```
    ///
    /// The snapshot is rendered into an off-screen texture with the shaders the views use and
    /// converted with Core Image. A drawable that was presented is never read back (E-12).
    ///
    /// - Parameters:
    ///   - size: the image's size in pixels; each side is rounded and must be between 1 and
    ///     what the device has a texture for.
    ///   - colorMap: the colours of a heat map. A waveform is drawn in the map's last colour
    ///     on its first.
    ///   - valueRange: the values shown as the first and the last colour of a heat map; the
    ///     amplitudes at the bottom and the top edge of a waveform.
    ///   - frequencyScale: how the frequency axis is laid out, for rows evenly spaced in
    ///     hertz; other rows are drawn bin for bin (VC-5).
    ///
    /// Threading: the work runs on the background executor (BG-1): never on the main thread,
    /// never on the analysis thread. The caller may be on any of them but the analysis thread
    /// and suspends meanwhile. The image is an immutable value (BG-2). Cancelling the calling
    /// task stops the work between its steps (BG-3).
    ///
    /// - Throws: `invalidParameter` for a size no texture has; `unsupportedConfiguration` for a
    ///   snapshot too large for a texture of the device; `backendUnavailable` where there is no
    ///   Metal device; `resourceAllocationFailed`; `cancelled`.
    public func image(
        size: CGSize, colorMap: some ColorMap = .viridis, valueRange: ClosedRange<Float>, frequencyScale: some FrequencyScale = .linear
    ) async throws(DSPError) -> CGImage {
        let snapshot = self
        return try await BackgroundWork.run { checkpoint throws(DSPError) -> CGImage in
            let context = try MetalContext.sharedBlocking()
            return try SnapshotImage.render(snapshot, size: size, colorMap: colorMap, valueRange: valueRange, frequencyScale: frequencyScale,
                                            context: context, checkpoint: checkpoint).image
        }
    }
}

/// The off-screen rendering behind `FeedSnapshot.image` (WP-609).
enum SnapshotImage {
    /// Columns uploaded between two looks at the checkpoint.
    static let columnsPerStep = 256

    /// Renders `snapshot` and converts the result. Returns the image and, for the parity test,
    /// the pixels read back from the texture the image was made from.
    ///
    /// Synchronous: it waits for the GPU. Background work only.
    static func render(
        _ snapshot: FeedSnapshot, size: CGSize, colorMap: some ColorMap, valueRange: ClosedRange<Float>, frequencyScale: some FrequencyScale,
        context: MetalContext, checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) -> (image: CGImage, pixels: PixelImage) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 0.5, size.height >= 0.5,
              size.width <= Double(context.capabilities.maximumTextureDimension), size.height <= Double(context.capabilities.maximumTextureDimension)
        else {
            throw .invalidParameter(stage: .none, parameter: "size",
                                    reason: "\(size.width) × \(size.height) pixels: an image is 1 … \(context.capabilities.maximumTextureDimension) pixels each way")
        }
        let target = try OffscreenTarget(context: context, width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        let commands = try MetalResources.commands(on: context.commandQueue)
        switch snapshot.content {
        case .heatmap:
            try encodeHeatmap(snapshot, colorMap: colorMap, valueRange: valueRange, frequencyScale: frequencyScale, context: context,
                              to: target.renderPass(), in: commands, checkpoint: checkpoint)
        case .waveform:
            try encodeWaveform(snapshot, colorMap: colorMap, valueRange: valueRange, context: context, to: target.renderPass(), in: commands)
        }
        try checkpoint?.check()
        try MetalResources.finish(commands, what: "the image")
        try checkpoint?.check()
        return (try convert(target, context: context), target.readPixels())
    }

    private static func encodeHeatmap(
        _ snapshot: FeedSnapshot, colorMap: some ColorMap, valueRange: ClosedRange<Float>, frequencyScale: some FrequencyScale,
        context: MetalContext, to pass: MTLRenderPassDescriptor, in commands: any MTLCommandBuffer, checkpoint: BackgroundWork.Checkpoint?
    ) throws(DSPError) {
        let rows = max(snapshot.rowCount, 1)
        let columns = snapshot.rowCount > 0 ? min(snapshot.columnCount, snapshot.values.count / snapshot.rowCount) : 0
        let texture = try HeatmapTexture(context: context, binCount: rows, history: max(columns, 1))
        var uploaded = 0
        while uploaded < columns {
            try checkpoint?.check()
            let step = min(columnsPerStep, columns - uploaded)
            snapshot.values.withUnsafeBufferPointer { values in
                guard let base = values.baseAddress else { return }
                texture.append(base + uploaded * rows, count: step)
            }
            uploaded += step
        }
        let lookups = try HeatmapLookups(context: context)
        let table = WarpTable(axis: snapshot.axis, rowCount: rows, scale: frequencyScale)
        lookups.setWarp(table)
        lookups.setColors(colorMap.lookupTable)
        let uniforms = HeatmapUniforms(texture: texture, span: table.span(frequencies: nil, rows: nil, scale: frequencyScale), valueRange: valueRange,
                                       visibleColumns: nil, interpolation: .linear)
        HeatmapPass.encode(uniforms, data: texture.texture, lookups: lookups, pipeline: try context.heatmapPipeline(for: .rgba8Unorm), to: pass, in: commands)
    }

    private static func encodeWaveform(
        _ snapshot: FeedSnapshot, colorMap: some ColorMap, valueRange: ClosedRange<Float>, context: MetalContext, to pass: MTLRenderPassDescriptor,
        in commands: any MTLCommandBuffer
    ) throws(DSPError) {
        let pairs = min(snapshot.columnCount, snapshot.values.count / 2)
        let texture = try EnvelopeTexture(context: context, capacity: max(pairs, 1))
        snapshot.values.withUnsafeBufferPointer { values in
            guard let base = values.baseAddress, pairs > 0 else { return }
            texture.append(base, count: pairs)
        }
        let uniforms = WaveformUniforms(texture: texture, amplitudeRange: valueRange, visiblePairs: nil, fill: colorMap.color(at: 1), fillOpacity: 1,
                                        background: colorMap.color(at: 0))
        WaveformPass.encode(uniforms, data: texture.texture, pipeline: try context.waveformPipeline(for: .rgba8Unorm), to: pass, in: commands)
    }

    /// The texture as an image, by Core Image, without colour management: a pixel of the image
    /// holds the bytes the shader wrote.
    private static func convert(_ target: OffscreenTarget, context: MetalContext) throws(DSPError) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let renderer = CIContext(mtlDevice: context.device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
        // A Metal texture has its first row at the top, a Core Image image at the bottom.
        guard let source = CIImage(mtlTexture: target.texture, options: [.colorSpace: NSNull()]),
              let image = renderer.createCGImage(source.oriented(.downMirrored), from: source.extent, format: .RGBA8, colorSpace: space)
        else { throw .resourceAllocationFailed(what: "an image of \(target.width) × \(target.height) pixels") }
        return image
    }
}
