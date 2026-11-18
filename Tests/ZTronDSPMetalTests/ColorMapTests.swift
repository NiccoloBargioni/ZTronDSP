import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// Colour maps as 256 × 1 look-up textures (WP-602): the bytes equal the reference tables of
/// `Tests/Golden/generators/colormaps.py`.
@Suite("Colour maps")
struct ColorMapTests {
    static let reference = Result { try GoldenFile(named: "colormaps", in: .module) }

    /// The 256 × 3 reference bytes of a case.
    private func table(_ name: String) throws -> [UInt8] {
        try Self.reference.get().require(name).real("rgb").map { UInt8($0) }
    }

    /// Red, green, blue of a look-up table, without its alpha.
    private func colors(_ lookup: [UInt8]) -> [UInt8] {
        lookup.enumerated().filter { $0.offset % 4 != 3 }.map { $0.element }
    }

    private func stock() -> [(name: String, map: any ColorMap)] {
        [("viridis", ListedColorMap.viridis), ("magma", ListedColorMap.magma), ("inferno", ListedColorMap.inferno),
         ("turbo", TurboColorMap.turbo), ("grayscale", GrayscaleColorMap.grayscale)]
    }

    @Test func theLookUpTextureHoldsTheReferenceTableOfEveryStockMap() async throws {
        let context = try await sharedContext()
        let lookups = try HeatmapLookups(context: context)
        #expect(lookups.colors.width == 256 && lookups.colors.height == 1 && lookups.colors.pixelFormat == .rgba8Unorm, "256 × 1")
        for (name, map) in stock() {
            let expected = try table(name)
            #expect(expected.count == 768)
            #expect(colors(map.lookupTable) == expected, "\(name): the table the map gives")
            lookups.setColors(map.lookupTable)
            let texels = Readback.bytes(lookups.colors)
            #expect(colors(texels) == expected, "\(name): the bytes in the texture")
            #expect(stride(from: 3, to: texels.count, by: 4).allSatisfy { texels[$0] == 255 }, "\(name): opaque")
        }
        // A table of another size is not a colour table: the texture keeps what it has.
        let before = Readback.bytes(lookups.colors)
        lookups.setColors([1, 2, 3])
        #expect(Readback.bytes(lookups.colors) == before)
    }

    @Test func theListedMapsAreTheKnownColoursAtTheirEndsAndInTheMiddle() {
        // The published colours: #440154 … #21918c … #fde725 for viridis, and so on.
        func hex(_ map: ListedColorMap, _ entry: Int) -> String {
            map.entries[3 * entry ..< 3 * entry + 3].map { String(format: "%02x", $0) }.joined()
        }
        #expect(hex(.viridis, 0) == "440154" && hex(.viridis, 128) == "21918c" && hex(.viridis, 255) == "fde725")
        #expect(hex(.magma, 0) == "000004" && hex(.magma, 128) == "b73779" && hex(.magma, 255) == "fcfdbf")
        #expect(hex(.inferno, 0) == "000004" && hex(.inferno, 128) == "bc3754" && hex(.inferno, 255) == "fcffa4")
        for map in [ListedColorMap.viridis, .magma, .inferno] {
            #expect(map.count == 256 && map.entries.count == 768, "\(map.name) lists 256 colours")
        }
        #expect(ListedColorMap.viridis.name == "viridis" && ListedColorMap.viridis != ListedColorMap.magma)
    }

    @Test func customStopsAreEvenlySpacedAndLinearInBetween() throws {
        let file = try Self.reference.get()
        for name in ["stops-two", "stops-three", "stops-seven"] {
            let values = try file.require(name).numbers("colors")
            let stops = stride(from: 0, to: values.count, by: 3).map { DisplayColor(red: values[$0], green: values[$0 + 1], blue: values[$0 + 2]) }
            let map = ListedColorMap.stops(stops)
            #expect(colors(map.lookupTable) == (try table(name)), "\(name)")
            #expect(map.count == stops.count)
        }
        // Fewer than two stops: one colour.
        let single = ListedColorMap.stops([DisplayColor(red: 0.2, green: 0.4, blue: 0.6)])
        #expect(Set(stride(from: 0, to: 1_024, by: 4).map { single.lookupTable[$0] }) == [51])
        #expect(colors(ListedColorMap.stops([]).lookupTable).allSatisfy { $0 == 0 }, "no stop at all is black")
        #expect(ListedColorMap.stops([.black, .white]) == ListedColorMap.stops([.black, .white]))
        #expect(ListedColorMap.stops([.black, .white]) != ListedColorMap.stops([.white, .black]))
    }

    @Test func aMapOfOnesOwnIsLookedUpLikeAStockOne() async throws {
        // A conformer outside the package: red rises, blue falls.
        struct Ramp: ColorMap {
            func color(at position: Double) -> DisplayColor { DisplayColor(red: position, green: 0.5, blue: 1 - position) }
        }
        let table = Ramp().lookupTable
        #expect(table.count == 1_024)
        for entry in [0, 1, 100, 254, 255] {
            #expect(table[4 * entry] == UInt8(entry) && table[4 * entry + 1] == 128 && table[4 * entry + 2] == UInt8(255 - entry) && table[4 * entry + 3] == 255)
        }
        let lookups = try HeatmapLookups(context: try await sharedContext())
        lookups.setColors(table)
        #expect(Readback.bytes(lookups.colors) == table)
    }

    @Test func displayColoursAreClampedAndRoundedToBytes() {
        let color = DisplayColor(red: -0.5, green: 1.5, blue: .nan)
        #expect(color.red == 0 && color.green == 1 && color.blue == 0, "outside 0 … 1 is clamped; not a number is 0")
        #expect(DisplayColor(red: 0.5, green: 0.499, blue: 0.501).bytes == (128, 127, 128))
        #expect(DisplayColor.black.bytes == (0, 0, 0) && DisplayColor.white.bytes == (255, 255, 255))
        #expect(DisplayColor(bytes: 68, 1, 84).bytes == (68, 1, 84), "a byte survives the round trip")
        let middle = DisplayColor.black.mixed(with: .white, fraction: 0.25)
        #expect(middle == DisplayColor(red: 0.25, green: 0.25, blue: 0.25))
        // Turbo's polynomial leaves 0 … 1 at its ends: the colour is clamped, never wrapped.
        #expect(TurboColorMap.evaluate(TurboColorMap.blue, 1) < 0 && TurboColorMap().color(at: 1).blue == 0)
        #expect(TurboColorMap().color(at: -3) == TurboColorMap().color(at: 0) && TurboColorMap().color(at: 7) == TurboColorMap().color(at: 1))
        #expect(GrayscaleColorMap().color(at: 0.5) == DisplayColor(red: 0.5, green: 0.5, blue: 0.5))
        #expect(ListedColorMap.viridis.color(at: 2).bytes == (253, 231, 37) && ListedColorMap.viridis.color(at: -1).bytes == (68, 1, 84))
        // Between two listed colours: linear.
        let between = ListedColorMap.viridis.color(at: 0.5 / 255)
        #expect(abs(between.red - (68 + 68) / 2.0 / 255) < 1e-12 && abs(between.blue - (84 + 86) / 2.0 / 255) < 1e-12)
    }
}
