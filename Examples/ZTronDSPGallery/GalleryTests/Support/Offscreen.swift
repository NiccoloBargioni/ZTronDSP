import CoreGraphics
import Foundation
import Metal
import MetalKit
import QuartzCore
import Testing
import ZTronDSP
import ZTronDSPMetal
@testable import ZTronDSPUI

// What the acceptance of §8.9 compares a frame of a transition with: the same content
// rendered directly at that size, by a surface of the package that draws into an off-screen
// texture, as level 1 of the suite does (`Tests/ZTronDSPUITests/Support.swift`).

/// A display clock in the test's hands: `fire()` is one tick of the display.
@MainActor
final class ManualClock: FrameClock {
    var isPaused = true
    var preferredRate = 60
    var onTick: (@MainActor (CFTimeInterval) -> Void)?
    private var time: CFTimeInterval = 100

    /// One tick; returns whether it was delivered.
    @discardableResult
    func fire() -> Bool {
        time += 1.0 / 60
        guard !isPaused, let onTick else { return false }
        onTick(time)
        return true
    }

    func invalidate() {
        isPaused = true
        onTick = nil
    }
}

/// An off-screen texture in the place of the Metal view.
@MainActor
final class OffscreenSurface: MetalSurface {
    let context: MetalContext
    weak var coordinator: SurfaceCoordinator?
    var device: (any MTLDevice)?
    var drawableSize: CGSize
    private var target: OffscreenTarget?

    init(context: MetalContext, size: CGSize) {
        self.context = context
        drawableSize = size
    }

    func draw() {
        guard let coordinator, drawableSize.width >= 1, drawableSize.height >= 1 else { return }
        if target == nil { target = try? OffscreenTarget(context: context, width: Int(drawableSize.width), height: Int(drawableSize.height)) }
        guard let target else { return }
        coordinator.render(to: target.renderPass(), presenting: nil)
    }

    func setAutoResizeDrawable(_ follows: Bool) {}

    /// The picture the surface shows.
    func pixels() throws -> PixelImage {
        context.waitUntilIdle()
        return try #require(target, "nothing was drawn").readPixels()
    }
}

@MainActor
enum DirectRender {
    /// `content` as a surface of the package draws it directly at `size` pixels.
    static func image(of content: SurfaceContent, size: CGSize) async throws -> PixelImage {
        let context = try await MetalContext.shared()
        let clock = ManualClock()
        let surface = OffscreenSurface(context: context, size: size)
        let coordinator = SurfaceCoordinator(
            input: SurfaceInput(content: content, maximumFrameRate: 60, isPresented: true, size: nil, probe: RenderProbe()), clock: clock, context: context)
        surface.coordinator = coordinator
        coordinator.attach(surface)
        var ticks = 0
        while ticks < 8, clock.fire() { ticks += 1 }
        defer { coordinator.detach() }
        return try surface.pixels()
    }
}

/// Reads back what was drawn into the drawable of a hosted Metal view. The view must hand out
/// drawables that can be read (`framebufferOnly` off), which a test sets for the frames it
/// wants to see; the bridge leaves it on, and a presented drawable is otherwise never read.
@MainActor
enum DrawableCapture {
    /// Does once what a capture does, on a small texture: the first copy of a process sets up
    /// what every later one finds ready, and that must not happen in the middle of a
    /// transition that is being timed by the display.
    static func warmUp(context: MetalContext) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        guard let source = context.device.makeTexture(descriptor: descriptor), let copy = context.device.makeTexture(descriptor: descriptor),
              let commands = context.commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 16, height: 16, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 4)
        bytes.withUnsafeMutableBytes { copy.getBytes($0.baseAddress!, bytesPerRow: 64, from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0) }
    }

    /// What a drawable held, as it holds it: blue, green, red, alpha.
    struct Frame {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        /// The frame as an image: red, green, blue, alpha.
        func image() throws -> PixelImage {
            var pixels = bytes
            pixels.withUnsafeMutableBufferPointer { buffer in
                var index = 0
                while index + 2 < buffer.count {
                    let blue = buffer[index]
                    buffer[index] = buffer[index + 2]
                    buffer[index + 2] = blue
                    index += 4
                }
            }
            return try PixelImage(width: width, height: height, pixels: pixels)
        }
    }

    /// A copy of a drawable that is on its way: the copy is queued on the GPU, and read back
    /// when the test asks for it.
    struct Taken {
        let width: Int
        let height: Int
        fileprivate let copy: any MTLTexture
        fileprivate let commands: any MTLCommandBuffer

        /// Waits for the copy and reads it back. Not to be called in a frame that is being
        /// judged: reading back holds the main thread.
        func frame() -> Frame {
            commands.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                copy.getBytes(buffer.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            return Frame(width: width, height: height, bytes: bytes)
        }
    }

    /// Queues a copy of the current drawable of `view`, or returns `nil` when it cannot be
    /// read. Call it while the view is drawing: after the frame was rendered, before the
    /// view lets go of its drawable. Nothing is waited for here, so that the frame of the
    /// display in which it is taken is not held up: `Taken.frame()` reads the copy back later.
    static func take(of view: MTKView, context: MetalContext) -> Taken? {
        guard let texture = view.currentDrawable?.texture, !texture.isFramebufferOnly, texture.pixelFormat == .bgra8Unorm else { return nil }
        let width = texture.width, height = texture.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let copy = context.device.makeTexture(descriptor: descriptor), let commands = context.commandQueue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return nil }
        // The copy is queued behind the frame's own commands: it sees the finished frame.
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        return Taken(width: width, height: height, copy: copy, commands: commands)
    }
}
