import Foundation
import Metal
import Testing
import ZTronDSPCore
@testable import ZTronDSPMetal
import ZTronDSPTesting

/// The envelope texture of a waveform (WP-607): a ring of (minimum, maximum) pairs and its
/// pyramid levels, read back and compared with what went in.
@Suite("Envelope texture")
struct EnvelopeTextureTests {
    /// Pairs of a seeded signal: minimum then maximum, in −1 … 1.
    private func pairs(_ count: Int, seed: UInt64) -> [Float] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< count).flatMap { _ -> [Float] in
            let a = Float(2 * generator.nextUnit() - 1), b = Float(2 * generator.nextUnit() - 1)
            return [min(a, b), max(a, b)]
        }
    }

    /// The entries of every level, as (minimum, maximum).
    private func levels(of texture: EnvelopeTexture) -> [[(Float, Float)]] {
        let texels = Readback.pairs(texture.texture)
        return zip(texture.layout.offsets, texture.layout.counts).map { offset, count in
            (offset ..< offset + count).map { (texels[2 * $0], texels[2 * $0 + 1]) }
        }
    }

    private func append(_ values: [Float], to texture: EnvelopeTexture) {
        values.withUnsafeBufferPointer { texture.append($0.baseAddress!, count: values.count / 2) }
    }

    @Test func theTextureHoldsTheRingAndItsLevels() async throws {
        let context = try await sharedContext()
        let texture = try EnvelopeTexture(context: context, capacity: 300)
        #expect(texture.texture.pixelFormat == .rg16Float, "one rg16Float texture: minimum and maximum")
        #expect(texture.layout.counts == [300, 150, 75, 38, 19, 10, 5, 3, 2, 1] && texture.layout.total == 603)
        #expect(texture.texture.width == 603 && texture.texture.height == 1 && texture.rowWidth == 603)
        // An envelope longer than a texture is wide is folded into rows.
        let long = try EnvelopeTexture(context: context, capacity: 5_000)
        #expect(long.rowWidth == EnvelopeTexture.foldWidth && long.texture.width == 4_096)
        #expect(long.texture.height == (long.layout.total + 4_095) / 4_096 && long.texture.height == 3)
        #expect(try EnvelopeTexture(context: context, capacity: 0).capacity == 1)
    }

    @Test func readBackEqualsThePairsThatWentIn() async throws {
        let context = try await sharedContext()
        let texture = try EnvelopeTexture(context: context, capacity: 37)
        // An empty ring: every entry is the neutral element of the reduction.
        #expect(levels(of: texture).allSatisfy { level in level.allSatisfy { $0 == (65_504, -65_504) } })

        let first = pairs(20, seed: 607)
        append(first, to: texture)
        #expect(texture.head == 20 && texture.available == 20)
        var stored = levels(of: texture)[0]
        for slot in 0 ..< 20 {
            #expect(stored[slot] == (halfRounded(first[2 * slot]), halfRounded(first[2 * slot + 1])), "slot \(slot)")
            #expect(abs(stored[slot].0 - first[2 * slot]) <= 0x1p-11 * abs(first[2 * slot]), "half-float precision")
        }
        #expect((20 ..< 37).allSatisfy { stored[$0] == (65_504, -65_504) }, "slots without a pair stay neutral")

        // Thirty more: the ring wraps, the oldest are replaced, and the upload is cut where the ring ends.
        let second = pairs(30, seed: 608)
        append(second, to: texture)
        #expect(texture.head == 13 && texture.available == 37)
        stored = levels(of: texture)[0]
        let everything = first + second
        for age in 0 ..< 37 {
            let slot = (texture.head + 37 - 1 - age) % 37, index = 50 - 1 - age
            #expect(stored[slot] == (halfRounded(everything[2 * index]), halfRounded(everything[2 * index + 1])), "the pair of age \(age)")
        }
    }

    @Test func everyLevelIsTheMinimumAndMaximumOfTheTwoEntriesBelow() async throws {
        let context = try await sharedContext()
        for capacity in [1, 2, 3, 37, 64, 300] {
            let texture = try EnvelopeTexture(context: context, capacity: capacity)
            // In several appends, so that the levels are brought up to date piece by piece, and
            // past the end of the ring.
            var generator = SeededGenerator(seed: UInt64(capacity))
            var remaining = capacity + capacity / 2 + 1
            var seed: UInt64 = 1
            while remaining > 0 {
                let step = min(remaining, 1 + Int(generator.nextUnit() * 9))
                append(pairs(step, seed: seed), to: texture)
                remaining -= step
                seed += 1
            }
            let stored = levels(of: texture)
            for level in 1 ..< stored.count {
                let below = stored[level - 1], here = stored[level]
                for entry in 0 ..< here.count {
                    let partner = min(2 * entry + 1, below.count - 1)
                    #expect(here[entry].0 == min(below[2 * entry].0, below[partner].0) && here[entry].1 == max(below[2 * entry].1, below[partner].1),
                            "\(capacity) slots, level \(level), entry \(entry)")
                }
            }
            #expect(stored.last?.first?.0 == stored[0].map { $0.0 }.min() && stored.last?.first?.1 == stored[0].map { $0.1 }.max(), "the top is the extremes of the ring")
        }
    }

    /// WP-607: ring and pyramid levels from a `WaveformFeed`.
    @Test func aWholeEnvelopeFromAFeedGivesThePyramidOfTheCore() async throws {
        let context = try await sharedContext()
        for count in [301, 1, 2, 5_000] {
            let feed = WaveformFeed(history: count)
            try FeedWriter.append(pairs: pairs(count, seed: UInt64(count)), to: feed)
            let snapshot = feed.snapshot()
            #expect(snapshot.columnCount == count)

            // As the renderer takes it: the pairs the feed hands over, into the ring.
            let texture = try EnvelopeTexture(context: context, capacity: feed.history)
            var cursor = FeedCursor()
            var staging = [Float](repeating: 0, count: 2 * 512)
            while true {
                let read = staging.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
                guard read.columnCount > 0 else { break }
                staging.withUnsafeBufferPointer { texture.append($0.baseAddress!, count: read.columnCount) }
            }
            #expect(texture.available == count && texture.head == 0, "the ring is full, slot 0 the oldest")

            let pyramid = snapshot.pyramid()
            let stored = levels(of: texture)
            #expect(stored.count == pyramid.levels.count, "\(count) pairs: as many levels as the pyramid")
            for (level, expected) in zip(stored, pyramid.levels) {
                #expect(level.map { $0.0 } == expected.minima.map(halfRounded) && level.map { $0.1 } == expected.maxima.map(halfRounded),
                        "\(count) pairs: the level whose pairs span \(expected.span)")
            }
        }
    }

    @Test func clearingForgetsEveryPair() async throws {
        let context = try await sharedContext()
        let texture = try EnvelopeTexture(context: context, capacity: 16)
        append(pairs(16, seed: 3), to: texture)
        texture.clear()
        #expect(texture.head == 0 && texture.available == 0)
        #expect(levels(of: texture).allSatisfy { level in level.allSatisfy { $0 == (65_504, -65_504) } }, "every entry is neutral again")
        append([-0.25, 0.5], to: texture)
        let stored = levels(of: texture)
        #expect(stored[0][0] == (-0.25, 0.5) && stored.last?.first.map { $0 == (-0.25, 0.5) } == true)
        // More pairs than the ring holds: the newest stay.
        let many = pairs(40, seed: 9)
        append(many, to: texture)
        let kept = levels(of: texture)[0]
        for age in 0 ..< 16 {
            let slot = (texture.head + 16 - 1 - age) % 16
            #expect(kept[slot].1 == halfRounded(many[2 * (39 - age) + 1]))
        }
    }

    @Test func pairsAHalfFloatCannotHoldAreClampedAndNotANumberIsSilence() async throws {
        let context = try await sharedContext()
        let texture = try EnvelopeTexture(context: context, capacity: 4)
        append([-.infinity, .infinity, -1e9, 1e9, .nan, .nan, -0.5, 0.5], to: texture)
        let stored = levels(of: texture)
        #expect(stored[0][0] == (-65_504, 65_504) && stored[0][1] == (-65_504, 65_504) && stored[0][2] == (0, 0) && stored[0][3] == (-0.5, 0.5))
        #expect(stored.allSatisfy { level in level.allSatisfy { $0.0.isFinite && $0.1.isFinite } })
        #expect(stored.last?.first.map { $0 == (-65_504, 65_504) } == true)
    }

    @Test func anEnvelopeNoTextureFitsIsRefused() async throws {
        let context = try await sharedContext()
        let limit = context.capabilities.maximumTextureDimension
        // Rows of 4 096 texels, more rows than a texture has.
        #expect(throws: DSPError.self) { try EnvelopeTexture(context: context, capacity: EnvelopeTexture.foldWidth * limit) }
    }
}
