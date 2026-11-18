import Foundation
import ZTronDSPCore

/// A colour as a display shows it: red, green and blue as sRGB-encoded values in 0 … 1 (the
/// values a colour picker shows, divided by 255), not linear light.
///
/// An immutable value, usable on any thread.
public struct DisplayColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Components outside 0 … 1 are clamped; a component that is not a number counts as 0.
    public init(red: Double, green: Double, blue: Double) {
        self.red = DisplayColor.unit(red)
        self.green = DisplayColor.unit(green)
        self.blue = DisplayColor.unit(blue)
    }

    /// A colour from the three bytes a colour table holds.
    init(bytes red: UInt8, _ green: UInt8, _ blue: UInt8) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// (0, 0, 0).
    public static let black = DisplayColor(red: 0, green: 0, blue: 0)
    /// (1, 1, 1).
    public static let white = DisplayColor(red: 1, green: 1, blue: 1)

    /// The components as bytes: each is `component · 255`, rounded to the nearest whole number.
    public var bytes: (red: UInt8, green: UInt8, blue: UInt8) {
        (DisplayColor.byte(red), DisplayColor.byte(green), DisplayColor.byte(blue))
    }

    static func unit(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    static func byte(_ value: Double) -> UInt8 {
        UInt8((unit(value) * 255).rounded())
    }

    /// The colour a share `fraction` of the way from this one to `other`, component by
    /// component.
    func mixed(with other: DisplayColor, fraction: Double) -> DisplayColor {
        DisplayColor(red: red + (other.red - red) * fraction, green: green + (other.green - green) * fraction,
                     blue: blue + (other.blue - blue) * fraction)
    }
}

/// How a heat map turns a value into a colour (§5.3): the strategy behind `.colorMap(_:)`.
///
/// A map answers one question: which colour stands for the position `t` between the low end
/// (0) and the high end (1) of the value range. A renderer asks it 256 times, once, and keeps
/// the answers in a 256 × 1 look-up texture; the fragment shader interpolates between
/// neighbouring entries. Changing the map is therefore one small texture and one draw, and no
/// data is uploaded again (§8.2).
///
/// Pass a stock value (`.viridis`, `.magma`, `.inferno`, `.turbo`, `.grayscale`), stops of
/// your own (`.stops([…])`), or a conformer written outside the package.
///
/// Conformers are immutable values, usable on any thread. `color(at:)` is called on the main
/// thread or on the background executor, never on the analysis thread.
public protocol ColorMap: Hashable, Sendable {
    /// The colour for `position`, 0 at the low end of the value range and 1 at the high end.
    /// Positions outside 0 … 1 do not occur.
    func color(at position: Double) -> DisplayColor
}

extension ColorMap {
    /// The 256 colours a renderer looks up, as red, green, blue, alpha bytes (alpha is 255):
    /// entry `i` is `color(at: i / 255)`. Allocates the table it returns.
    public var lookupTable: [UInt8] {
        var table = [UInt8](repeating: 255, count: 256 * 4)
        for entry in 0 ..< 256 {
            let bytes = color(at: Double(entry) / 255).bytes
            table[4 * entry] = bytes.red
            table[4 * entry + 1] = bytes.green
            table[4 * entry + 2] = bytes.blue
        }
        return table
    }
}

/// A colour map given as a list of colours at evenly spaced positions, linear in between:
/// the perceptually uniform maps of matplotlib, which are published as 256 colours each.
///
/// An immutable value, usable on any thread.
public struct ListedColorMap: ColorMap {
    /// What the map is called.
    public let name: String
    /// The colours as red, green, blue bytes, low end first.
    public let entries: [UInt8]

    /// A map through `colors`, evenly spaced from the low end to the high end. Fewer than two
    /// colours give a map of one colour: the one given, or black.
    public init(name: String, colors: [DisplayColor]) {
        self.name = name
        let listed = colors.isEmpty ? [.black, .black] : (colors.count == 1 ? [colors[0], colors[0]] : colors)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(listed.count * 3)
        for color in listed {
            let triple = color.bytes
            bytes.append(triple.red)
            bytes.append(triple.green)
            bytes.append(triple.blue)
        }
        entries = bytes
    }

    /// A map from a table written as hexadecimal digits, six per colour.
    init(name: String, hexadecimal: String) {
        self.name = name
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexadecimal.utf8.count / 2)
        var high: UInt8?
        for character in hexadecimal.utf8 {
            let digit: UInt8 = character >= 97 ? character - 87 : character - 48
            if let first = high {
                bytes.append(first << 4 | digit)
                high = nil
            } else {
                high = digit
            }
        }
        entries = bytes
    }

    /// The number of colours listed.
    public var count: Int { entries.count / 3 }

    public func color(at position: Double) -> DisplayColor {
        let scaled = DisplayColor.unit(position) * Double(count - 1)
        let lower = min(Int(scaled), count - 2)
        return entry(lower).mixed(with: entry(lower + 1), fraction: scaled - Double(lower))
    }

    private func entry(_ index: Int) -> DisplayColor {
        DisplayColor(bytes: entries[3 * index], entries[3 * index + 1], entries[3 * index + 2])
    }
}

/// Turbo, a rainbow map without the false contours of "jet", in the polynomial form its
/// author published for shaders (A. Mikhailov, Google, 2019): a degree-5 polynomial per
/// channel. It differs from the 256-entry table of the same name by a few hundredths in the
/// middle and by up to an eighth at the dark ends.
///
/// An immutable value, usable on any thread.
public struct TurboColorMap: ColorMap {
    public init() {}

    static let red: [Double] = [0.13572138, 4.61539260, -42.66032258, 132.13108234, -152.94239396, 59.28637943]
    static let green: [Double] = [0.09140261, 2.19418839, 4.84296658, -14.18503333, 4.27729857, 2.82956604]
    static let blue: [Double] = [0.10667330, 12.64194608, -60.58204836, 110.36276771, -89.90310912, 27.34824973]

    public func color(at position: Double) -> DisplayColor {
        let x = DisplayColor.unit(position)
        return DisplayColor(red: Self.evaluate(Self.red, x), green: Self.evaluate(Self.green, x), blue: Self.evaluate(Self.blue, x))
    }

    /// Horner's rule, the constant term first in `coefficients`.
    static func evaluate(_ coefficients: [Double], _ x: Double) -> Double {
        var value = 0.0
        for coefficient in coefficients.reversed() { value = value * x + coefficient }
        return value
    }
}

/// Black at the low end, white at the high end, grey in proportion between.
///
/// An immutable value, usable on any thread.
public struct GrayscaleColorMap: ColorMap {
    public init() {}

    public func color(at position: Double) -> DisplayColor {
        DisplayColor(red: position, green: position, blue: position)
    }
}

extension ColorMap where Self == ListedColorMap {
    /// Viridis: dark violet through green to yellow (matplotlib's default).
    public static var viridis: ListedColorMap { ColorMapTables.viridis }
    /// Magma: black through purple and orange to pale yellow.
    public static var magma: ListedColorMap { ColorMapTables.magma }
    /// Inferno: black through red and orange to pale yellow.
    public static var inferno: ListedColorMap { ColorMapTables.inferno }

    /// A map through colours of your own, evenly spaced from the low end of the value range
    /// to the high end and linear in between.
    public static func stops(_ colors: [DisplayColor]) -> ListedColorMap {
        ListedColorMap(name: "stops", colors: colors)
    }
}

extension ColorMap where Self == TurboColorMap {
    /// Turbo, in its polynomial form.
    public static var turbo: TurboColorMap { TurboColorMap() }
}

extension ColorMap where Self == GrayscaleColorMap {
    /// Black to white.
    public static var grayscale: GrayscaleColorMap { GrayscaleColorMap() }
}
