import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// The ring texture of a heat map (WP-604): column upload in half floats, max-reduced levels
/// along frequency (V-8).
@Suite("Heat-map texture")
struct HeatmapTextureTests {
    /// Columns of decibel-like values: seeded, between −120 and +10.
    private func columns(_ count: Int, bins: Int, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< count * bins).map { _ in Float(-120 + 130 * generator.nextUnit()) }
    }

    /// The texels of the column in `slot`, level by level.
    private func levels(_ texels: [Float], of texture: HeatmapTexture, slot: Int) -> [[Float]] {
        let row = Array(texels[slot * texture.layout.total ..< (slot + 1) * texture.layout.total])
        return zip(texture.layout.offsets, texture.layout.counts).map { offset, count in Array(row[offset ..< offset + count]) }
    }

    @Test func theTextureIsSizedByTheData() async throws {
        let context = try await sharedContext()
        let texture = try HeatmapTexture(context: context, binCount: 257, history: 96)
        #expect(texture.texture.pixelFormat == .r16Float, "one r16Float texture")
        #expect(texture.texture.height == 96, "one row of texels per column of the history")
        #expect(texture.texture.width == texture.layout.total && texture.layout.counts.first == 257, "the bins, then their reduced levels")
        #expect(texture.layout.counts == [257, 129, 65, 33, 17, 9, 5, 3, 2, 1] && texture.layout.total == 521)
        #expect(texture.head == 0 && texture.available == 0 && texture.chunkCapacity >= 1)
        // A feed without rows yet: one row stands in.
        let placeholder = try HeatmapTexture(context: context, binCount: 0, history: 0)
        #expect(placeholder.binCount == 1 && placeholder.history == 1 && placeholder.layout.total == 1)
    }

    @Test func levelsHalveUntilOneEntryIsLeft() {
        #expect(LevelLayout(count: 1).counts == [1] && LevelLayout(count: 1).offsets == [0] && LevelLayout(count: 1).total == 1)
        #expect(LevelLayout(count: 2).counts == [2, 1] && LevelLayout(count: 2).offsets == [0, 2])
        #expect(LevelLayout(count: 3).counts == [3, 2, 1] && LevelLayout(count: 3).offsets == [0, 3, 5] && LevelLayout(count: 3).total == 6)
        #expect(LevelLayout(count: 12).counts == [12, 6, 3, 2, 1])
        #expect(LevelLayout(count: 1_025).counts.count == 12 && LevelLayout(count: 1_025).total == 2_059)
        for count in [1, 2, 7, 64, 513, 2_049] {
            let layout = LevelLayout(count: count)
            #expect(layout.total == layout.counts.reduce(0, +) && layout.total < 2 * count + layout.counts.count)
            for level in 1 ..< layout.counts.count {
                #expect(layout.offsets[level] == layout.offsets[level - 1] + layout.counts[level - 1], "level \(level) follows the one below")
                #expect(layout.counts[level] == (layout.counts[level - 1] + 1) / 2, "half the entries, rounded up")
            }
            #expect(layout.counts.last == 1)
        }
        #expect(LevelLayout(count: 0).counts == [1], "no entry at all is laid out as one")
    }

    @Test func readBackEqualsTheInputWithinHalfFloatPrecision() async throws {
        let context = try await sharedContext()
        let bins = 37, history = 8
        let texture = try HeatmapTexture(context: context, binCount: bins, history: history)
        let input = columns(5, bins: bins, seed: 604)
        input.withUnsafeBufferPointer { texture.append($0.baseAddress!, count: 5) }
        #expect(texture.head == 5 && texture.available == 5)

        let texels = Readback.floats(texture.texture)
        var worst = 0.0, worstDecibels = 0.0
        for column in 0 ..< 5 {
            let stored = levels(texels, of: texture, slot: column)[0]
            let given = Array(input[column * bins ..< (column + 1) * bins])
            #expect(stored == given.map(halfRounded), "column \(column): the texel is the value rounded to a half float, by vImage")
            for (texel, value) in zip(stored, given) {
                worst = max(worst, Double(abs(texel - value) / abs(value)))
                worstDecibels = max(worstDecibels, Double(abs(texel - value)))
            }
        }
        // Half-float precision: eleven significant bits, so half a unit in the last place is 2⁻¹¹.
        #expect(worst <= 0x1p-11, "largest relative error \(worst)")
        #expect(worst > 0x1p-14, "the values are not all representable: the bound is exercised (\(worst))")
        // In decibels, which is what a spectrogram stores: between 64 and 128 a half float
        // steps by a sixteenth, so a level is off by a thirty-second of a decibel at most.
        #expect(worstDecibels <= 0x1p-5, "largest error of a level between -120 and +10 dB: \(worstDecibels) dB")
        print("heat-map texture: largest relative error of a texel against its input \(worst) (bound 2^-11 = \(0x1p-11)); largest error of a level in decibels \(worstDecibels) (bound 2^-5 = \(0x1p-5))")
    }

    @Test func eachLevelIsTheMaximumOfTheTwoEntriesBelowIt() async throws {
        let context = try await sharedContext()
        // Odd and even counts on the way up: 37, 19, 10, 5, 3, 2, 1.
        for bins in [37, 64, 1, 2, 257] {
            let texture = try HeatmapTexture(context: context, binCount: bins, history: 4)
            let input = columns(4, bins: bins, seed: UInt64(bins))
            input.withUnsafeBufferPointer { texture.append($0.baseAddress!, count: 4) }
            let texels = Readback.floats(texture.texture)
            for slot in 0 ..< 4 {
                let stored = levels(texels, of: texture, slot: slot)
                #expect(stored.count == texture.layout.counts.count)
                for level in 1 ..< stored.count {
                    let below = stored[level - 1], here = stored[level]
                    for entry in 0 ..< here.count {
                        // An entry without a partner is carried up alone.
                        let expected = 2 * entry + 1 < below.count ? max(below[2 * entry], below[2 * entry + 1]) : below[2 * entry]
                        #expect(here[entry] == expected, "\(bins) bins, column \(slot), level \(level), entry \(entry)")
                    }
                }
                #expect(stored.last == [stored[0].max()!], "the last level is the column's maximum")
            }
        }
    }

    @Test func theTextureIsARing() async throws {
        let context = try await sharedContext()
        let bins = 5, history = 6
        let texture = try HeatmapTexture(context: context, binCount: bins, history: history)
        // Column c holds the value c in every bin.
        func append(_ range: Range<Int>) {
            let values = range.flatMap { column in [Float](repeating: Float(column), count: bins) }
            values.withUnsafeBufferPointer { texture.append($0.baseAddress!, count: range.count) }
        }
        func slots() -> [Float] {
            let texels = Readback.floats(texture.texture)
            return (0 ..< history).map { texels[$0 * texture.layout.total] }
        }
        append(0 ..< 4)
        #expect(texture.head == 4 && texture.available == 4 && Array(slots().prefix(4)) == [0, 1, 2, 3])
        // Five more: the upload is cut where the ring ends, and the oldest are replaced.
        append(4 ..< 9)
        #expect(texture.head == 3 && texture.available == 6 && slots() == [6, 7, 8, 3, 4, 5], "scrolling moves no texel")
        // More columns than the ring holds: the newest stay.
        append(9 ..< 30)
        #expect(texture.available == 6 && Set(slots()) == [24, 25, 26, 27, 28, 29])
        #expect(slots()[(texture.head + history - 1) % history] == 29, "the newest column sits before the head")
        texture.clear()
        #expect(texture.head == 0 && texture.available == 0)
        append(30 ..< 31)
        #expect(texture.head == 1 && texture.available == 1 && slots()[0] == 30)
        // No column: nothing happens.
        [Float(1)].withUnsafeBufferPointer { texture.append($0.baseAddress!, count: 0) }
        #expect(texture.head == 1 && texture.available == 1)
    }

    @Test func anUploadLargerThanTheStagingMemoryGivesTheSameTexture() async throws {
        let context = try await sharedContext()
        let bins = 700, history = 200
        let whole = try HeatmapTexture(context: context, binCount: bins, history: history)
        let piecewise = try HeatmapTexture(context: context, binCount: bins, history: history)
        #expect(whole.chunkCapacity < 150, "150 columns do not fit the staging memory: \(whole.chunkCapacity) do")
        let input = columns(150, bins: bins, seed: 7)
        input.withUnsafeBufferPointer { buffer in
            whole.append(buffer.baseAddress!, count: 150)
            for column in 0 ..< 150 { piecewise.append(buffer.baseAddress! + column * bins, count: 1) }
        }
        #expect(whole.head == 150 && piecewise.head == 150)
        #expect(Readback.floats(whole.texture) == Readback.floats(piecewise.texture))
    }

    /// The stress test of the stability note `Docs/Numerics/heatmap-rendering.md` (§7.5, row
    /// 23): values a half float cannot hold, and values that are not numbers, never reach a
    /// texel.
    @Test func valuesAHalfFloatCannotHoldAreClampedAndNotANumberBecomesTheLowest() async throws {
        let context = try await sharedContext()
        let bins = 64
        let texture = try HeatmapTexture(context: context, binCount: bins, history: 4)
        // The fixture library's signal with NaN and both infinities (WP-016), scaled far past
        // what a half float holds, and one column of plain extremes.
        var (signal, nonFinite) = StressFixture.nonFiniteSignal(count: 3 * bins)
        #expect(nonFinite == 3)
        for index in signal.indices where signal[index].isFinite { signal[index] *= 1e6 }
        let extremes: [Float] = [.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .infinity, -.infinity, .nan, 65_504, -65_504, 65_520, 0, -0.0, 1e-30]
        signal += extremes + [Float](repeating: -90, count: bins - extremes.count)
        signal.withUnsafeBufferPointer { texture.append($0.baseAddress!, count: 4) }

        let texels = Readback.floats(texture.texture)
        #expect(texels.allSatisfy { $0.isFinite }, "no texel is infinite or not a number")
        #expect(texels.allSatisfy { abs($0) <= 65_504 }, "every texel is within the half-float range")
        for column in 0 ..< 4 {
            let stored = levels(texels, of: texture, slot: column)
            let given = Array(signal[column * bins ..< (column + 1) * bins])
            for (texel, value) in zip(stored[0], given) {
                let expected: Float = value.isNaN ? -65_504 : halfRounded(min(max(value, -65_504), 65_504))
                #expect(texel == expected, "column \(column): \(value) is stored as \(texel)")
            }
            #expect(stored.last == [stored[0].max()!], "the levels are built from the cleaned values")
        }
        let last = levels(texels, of: texture, slot: 3)[0]
        #expect(Array(last.prefix(8)) == [65_504, -65_504, 65_504, -65_504, -65_504, 65_504, -65_504, 65_504])
    }

    @Test func dataNoTextureFitsIsRefused() async throws {
        let context = try await sharedContext()
        let limit = context.capabilities.maximumTextureDimension
        // Twice the bins plus a few levels across; the history down.
        #expect(throws: DSPError.self) { try HeatmapTexture(context: context, binCount: limit, history: 16) }
        #expect(throws: DSPError.self) { try HeatmapTexture(context: context, binCount: 16, history: limit + 1) }
        do throws(DSPError) {
            _ = try HeatmapTexture(context: context, binCount: limit, history: 16)
        } catch {
            guard case .unsupportedConfiguration(let reason, _) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(reason.contains("\(limit)"), "the error names the limit: \(reason)")
        }
        // The largest that fits does.
        _ = try HeatmapTexture(context: context, binCount: 2_049, history: 940)
    }
}
