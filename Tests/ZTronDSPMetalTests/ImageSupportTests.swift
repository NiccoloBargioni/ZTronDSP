import CoreGraphics
import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// Image support for the rendering tests (WP-603, §8.5): the off-screen target, read-back, the
/// peak signal-to-noise ratio and the golden-image loader, tested on synthetic images.
@Suite("Image support")
struct ImageSupportTests {
    /// An image whose every pixel is a formula.
    private func synthetic(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> PixelImage {
        var bytes: [UInt8] = []
        for y in 0 ..< height {
            for x in 0 ..< width {
                let (red, green, blue, alpha) = pixel(x, y)
                bytes += [red, green, blue, alpha]
            }
        }
        return try PixelImage(width: width, height: height, pixels: bytes)
    }

    // MARK: The loader

    @Test func theLoaderReadsAGoldenImageByteForByte() throws {
        // Written by the generator as red = x, green = y, blue = (3x + 5y) mod 256.
        let image = try GoldenImages.image("loader-pattern")
        let expected = try synthetic(width: 64, height: 48) { x, y in (UInt8(x), UInt8(y), UInt8((3 * x + 5 * y) % 256), 255) }
        #expect(image.width == 64 && image.height == 48)
        #expect(image == expected, "no colour management, no premultiplication, rows from the top")
        #expect(image.pixel(x: 5, y: 7) == (5, 7, 50, 255) && image.pixel(x: 63, y: 47) == (63, 47, UInt8((3 * 63 + 5 * 47) % 256), 255))
        #expect(image.pixel(x: 64, y: 0) == (0, 0, 0, 0) && image.pixel(x: 0, y: -1) == (0, 0, 0, 0), "outside the image: zeros")
    }

    @Test func dataThatIsNoImageIsRefused() {
        #expect(throws: DSPError.self) { try PixelImage(pngData: Data([1, 2, 3, 4])) }
        #expect(throws: DSPError.self) { try PixelImage(pngData: Data()) }
        #expect(throws: DSPError.self) { try PixelImage(width: 2, height: 2, pixels: [0, 0, 0]) }
        #expect(throws: DSPError.self) { try PixelImage(width: -1, height: 1, pixels: []) }
        #expect(throws: DSPError.self) { try PixelImage(width: 0, height: 0, pixels: []).cgImage() }
        #expect(PixelImage.empty.width == 0 && PixelImage.empty.pixels.isEmpty)
    }

    @Test func anImageSurvivesTheTripThroughCoreGraphics() throws {
        // Opaque pixels come back byte for byte.
        let opaque = try synthetic(width: 37, height: 23) { x, y in (UInt8(x * 6), UInt8(y * 11), UInt8((x * y) % 256), 255) }
        let roundTrip = try PixelImage(opaque.cgImage())
        #expect(roundTrip == opaque)
        let image = try opaque.cgImage()
        #expect(image.width == 37 && image.height == 23 && image.bitsPerPixel == 32)
        // Premultiplied colour with partial alpha: within one level.
        let translucent = try synthetic(width: 16, height: 16) { x, y in
            let alpha = UInt8(x * 17)
            return (UInt8(Int(alpha) * y / 15), UInt8(Int(alpha) / 2), alpha, alpha)
        }
        let difference = try PixelImage(translucent.cgImage()).largestDifference(from: translucent)
        #expect(difference != nil && (difference ?? 99) <= 1, "premultiplied colour: off by \(difference ?? -1) at most")
    }

    // MARK: The comparison

    @Test func thePeakSignalToNoiseRatioIsTheDefinition() throws {
        let base = try synthetic(width: 40, height: 30) { x, y in (UInt8(x * 5), UInt8(y * 7), UInt8(x + y), 255) }
        #expect(base.peakSignalToNoiseRatio(against: base) == .infinity, "identical")

        // Every colour byte off by d: MSE = d², PSNR = 20·log10(255 / d).
        for offset in [1, 2, 5, 16] {
            let shifted = try synthetic(width: 40, height: 30) { x, y in
                (UInt8(x * 5) &+ UInt8(offset), UInt8(y * 7) &+ UInt8(offset), UInt8(x + y) &+ UInt8(offset), 255)
            }
            // Bytes that wrapped would spoil the figure; none does here below 239.
            let ratio = try #require(shifted.peakSignalToNoiseRatio(against: base))
            expectClose(ratio, 20 * log10(255 / Double(offset)), .absolute(1e-9), "all bytes off by \(offset)")
            #expect(base.largestDifference(from: shifted) == offset)
        }

        // One pixel of 1 200 fully wrong in one channel: MSE = 255² / 3600.
        var bytes = base.pixels
        bytes[4 * 500] = bytes[4 * 500] ^ 0xFF
        let delta = Double(Int(bytes[4 * 500]) - Int(base.pixels[4 * 500]))
        let onePixel = try PixelImage(width: 40, height: 30, pixels: bytes)
        expectClose(try #require(onePixel.peakSignalToNoiseRatio(against: base)), 10 * log10(255 * 255 / (delta * delta / 3_600)), .absolute(1e-9))

        // Alpha is not part of the figure, and is part of the largest difference.
        var transparent = base.pixels
        for index in stride(from: 3, to: transparent.count, by: 4) { transparent[index] = 0 }
        let faded = try PixelImage(width: 40, height: 30, pixels: transparent)
        #expect(faded.peakSignalToNoiseRatio(against: base) == .infinity && faded.largestDifference(from: base) == 255)

        // The bar of §8.5: a root-mean-square error of 2.55 levels is 40 dB.
        let noisy = try synthetic(width: 40, height: 30) { x, y in
            let sign = (x + y) % 2 == 0 ? 3 : -2          // mean square (9 + 4) / 2 = 6.5: 2.55 levels RMS
            return (UInt8(clamping: 100 + sign), UInt8(clamping: 100 + sign), UInt8(clamping: 100 + sign), 255)
        }
        let flat = try synthetic(width: 40, height: 30) { _, _ in (100, 100, 100, 255) }
        let bar = try #require(noisy.peakSignalToNoiseRatio(against: flat))
        expectClose(bar, 10 * log10(255 * 255 / 6.5), .absolute(1e-9))
        #expect(bar > 39.9 && bar < 40.1)

        // Images of different sizes do not compare.
        let other = try synthetic(width: 30, height: 40) { _, _ in (0, 0, 0, 255) }
        #expect(other.peakSignalToNoiseRatio(against: base) == nil && other.largestDifference(from: base) == nil)
        #expect(PixelImage.empty.peakSignalToNoiseRatio(against: .empty) == nil, "no pixel, no ratio")
    }

    // MARK: The off-screen target

    @Test func whatIsDrawnOffScreenIsReadBack() async throws {
        let context = try await sharedContext()
        for format in [MTLPixelFormat.rgba8Unorm, .bgra8Unorm] {
            let target = try OffscreenTarget(context: context, width: 8, height: 4, pixelFormat: format)
            #expect(target.width == 8 && target.height == 4 && target.texture.pixelFormat == format)
            // A pass that only clears: every pixel is the clear colour, whichever the byte order.
            let pass = target.renderPass(clearColor: MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            let commands = try #require(context.commandQueue.makeCommandBuffer())
            try #require(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
            commands.commit()
            context.waitUntilIdle()
            let image = target.readPixels()
            #expect(image.width == 8 && image.height == 4 && image.pixels.count == 128)
            for y in 0 ..< 4 {
                for x in 0 ..< 8 { #expect(image.pixel(x: x, y: y) == (51, 102, 153, 255), "\(format): pixel \(x), \(y)") }
            }
        }
        // The probe's ramp, drawn into a target: the first row of pixels is at the top.
        let target = try OffscreenTarget(context: context, width: 8, height: 1)
        #expect(target.renderPass().colorAttachments[0].loadAction == .clear && target.renderPass().colorAttachments[0].storeAction == .store)
    }

    @Test func aTargetNoTextureFitsIsRefused() async throws {
        let context = try await sharedContext()
        let limit = context.capabilities.maximumTextureDimension
        #expect(throws: DSPError.self) { try OffscreenTarget(context: context, width: limit + 1, height: 4) }
        #expect(throws: DSPError.self) { try OffscreenTarget(context: context, width: 0, height: 4) }
        #expect(throws: DSPError.self) { try OffscreenTarget(context: context, width: 4, height: -2) }
        #expect(throws: DSPError.self) { try OffscreenTarget(context: context, width: 4, height: 4, pixelFormat: .r16Float) }
    }
}
