import CoreGraphics
import Foundation
import ZTronDSPCore

/// The pixels of a rendered image, read back from the GPU or loaded from a file (WP-603): what
/// the rendering tests compare (§8.5), and what an off-screen render returns.
///
/// Pixels are stored row by row from the top, four bytes each: red, green, blue, alpha, with
/// the colour premultiplied by alpha as the renderers write it.
///
/// An immutable value, usable on any thread.
public struct PixelImage: Hashable, Sendable {
    /// Pixels across.
    public let width: Int
    /// Pixels down.
    public let height: Int
    /// `width · height · 4` bytes.
    public let pixels: [UInt8]

    /// - Throws: `invalidParameter` when the bytes do not fill `width × height` pixels.
    public init(width: Int, height: Int, pixels: [UInt8]) throws(DSPError) {
        guard width >= 0, height >= 0, pixels.count == width * height * 4 else {
            throw .invalidParameter(stage: .none, parameter: "pixels", reason: "\(pixels.count) bytes do not fill \(width) × \(height) pixels of four bytes")
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The image a PNG file holds: the golden-image loader (§8.5). Pixels come out as the file
    /// stores them, without colour management; an image without alpha is opaque.
    ///
    /// Decodes with Core Graphics on the calling thread: not for the analysis thread.
    ///
    /// - Throws: `invalidParameter` for data that is not a PNG image.
    public init(pngData: Data) throws(DSPError) {
        guard let provider = CGDataProvider(data: pngData as CFData),
              let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw .invalidParameter(stage: .none, parameter: "pngData", reason: "the data is not a PNG image")
        }
        try self.init(image)
    }

    /// The pixels of `image`, drawn into its own colour space so that no value is converted.
    ///
    /// - Throws: `resourceAllocationFailed` when Core Graphics cannot draw the image.
    public init(_ image: CGImage) throws(DSPError) {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard width > 0, height > 0,
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw .resourceAllocationFailed(what: "a bitmap of \(width) × \(height) pixels") }
        try self.init(width: width, height: height, pixels: bytes)
    }

    /// The red, green, blue and alpha bytes of the pixel in column `x` of row `y`, row 0 being
    /// the top. A position outside the image gives zeros.
    public func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard x >= 0, x < width, y >= 0, y < height else { return (0, 0, 0, 0) }
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    /// The peak signal-to-noise ratio against `reference`, in decibels, over the red, green
    /// and blue channels: `10·log₁₀(255² / mean squared difference)`. Infinite for identical
    /// colours; `nil` when the two images differ in size or hold no pixel.
    ///
    /// 40 dB, the bar of the golden-image tests (§8.5), is a root-mean-square difference of
    /// 2.55 levels out of 255.
    public func peakSignalToNoiseRatio(against reference: PixelImage) -> Double? {
        guard width == reference.width, height == reference.height, !pixels.isEmpty else { return nil }
        var sum = 0.0
        var index = 0
        while index < pixels.count {
            // Alpha, every fourth byte, is left out.
            if index & 3 != 3 {
                let difference = Double(pixels[index]) - Double(reference.pixels[index])
                sum += difference * difference
            }
            index += 1
        }
        guard sum > 0 else { return .infinity }
        let meanSquare = sum / Double(width * height * 3)
        return 10 * log10(255 * 255 / meanSquare)
    }

    /// The largest difference between a byte of this image and its counterpart in `other`,
    /// alpha included; `nil` when the two images differ in size.
    public func largestDifference(from other: PixelImage) -> Int? {
        guard width == other.width, height == other.height else { return nil }
        var largest = 0
        var index = 0
        while index < pixels.count {
            largest = max(largest, abs(Int(pixels[index]) - Int(other.pixels[index])))
            index += 1
        }
        return largest
    }

    /// The image as a `CGImage` in the sRGB colour space, sharing nothing with this value.
    ///
    /// - Throws: `resourceAllocationFailed` for an image without pixels, or when Core Graphics
    ///   refuses.
    public func cgImage() throws(DSPError) -> CGImage {
        guard width > 0, height > 0, let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw .resourceAllocationFailed(what: "an image of \(width) × \(height) pixels")
        }
        return image
    }
}
