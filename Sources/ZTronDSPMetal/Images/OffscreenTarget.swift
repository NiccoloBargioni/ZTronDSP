import Foundation
import Metal
import ZTronDSPCore

/// A texture to draw into instead of a screen, and the way to get its pixels back (WP-603).
///
/// It is what the rendering tests draw to (§8.5) and what a snapshot image is rendered into
/// (§8.2). A presented drawable can never be read back (E-12); this can.
///
/// ```swift
/// let target = try OffscreenTarget(context: context, width: 256, height: 128)
/// renderer.draw(to: target.renderPass())
/// context.waitUntilIdle()            // or wait for the command buffer you committed
/// let image = target.readPixels()
/// ```
///
/// Threading: a target is a GPU resource and belongs to whoever made it: one thread at a time.
/// It is not `Sendable`; the main thread uses one for a view's tests, background work makes
/// its own.
public final class OffscreenTarget {
    /// The texture that is drawn into: a render target that can also be sampled and read.
    public let texture: any MTLTexture
    /// Pixels across.
    public let width: Int
    /// Pixels down.
    public let height: Int

    /// - Parameters:
    ///   - width: pixels across; at least 1 and at most what the device allows.
    ///   - height: pixels down.
    ///   - pixelFormat: `.rgba8Unorm` (the default) or `.bgra8Unorm`, the two formats whose
    ///     pixels ``readPixels()`` returns.
    /// - Throws: `invalidParameter` for a size the device has no texture for or another pixel
    ///   format; `resourceAllocationFailed` when the device gives no texture.
    public init(context: MetalContext, width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba8Unorm) throws(DSPError) {
        guard context.permits(width: width, height: height) else {
            throw .invalidParameter(stage: .none, parameter: "size",
                                    reason: "\(width) × \(height) pixels: a texture here is 1 … \(context.capabilities.maximumTextureDimension) pixels each way")
        }
        guard pixelFormat == .rgba8Unorm || pixelFormat == .bgra8Unorm else {
            throw .invalidParameter(stage: .none, parameter: "pixelFormat", reason: "an off-screen target is rgba8Unorm or bgra8Unorm")
        }
        let shape = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        shape.usage = [.renderTarget, .shaderRead]
        texture = try MetalResources.texture(shape, on: context.device, what: "an off-screen texture of \(width) × \(height) pixels")
        self.width = width
        self.height = height
    }

    /// A render pass that clears the target to `clearColor` and keeps what is drawn. Hand it
    /// to a renderer's `draw(to:)`.
    public func renderPass(clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        return pass
    }

    /// The target's pixels, as red, green, blue, alpha from the top row down. Call it once the
    /// command buffer that drew has completed; it copies and allocates the image it returns.
    public func readPixels() -> PixelImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        if texture.pixelFormat == .bgra8Unorm {
            var index = 0
            while index < bytes.count {
                bytes.swapAt(index, index + 2)
                index += 4
            }
        }
        // The count is width · height · 4 by construction.
        return (try? PixelImage(width: width, height: height, pixels: bytes)) ?? PixelImage.empty
    }
}

extension PixelImage {
    /// An image without pixels.
    static let empty = PixelImage(emptyWidth: 0)

    private init(emptyWidth: Int) {
        width = emptyWidth
        height = 0
        pixels = []
    }
}

extension MetalContext {
    /// Waits until everything committed to the context's queue so far has run: an empty
    /// command buffer goes through the queue behind it. Blocks; for tests and background work,
    /// never for the main thread of an app or the analysis thread.
    public func waitUntilIdle() {
        guard let commands = try? MetalResources.commands(on: commandQueue) else { return }
        commands.commit()
        commands.waitUntilCompleted()
    }
}
