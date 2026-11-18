import Accelerate
import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// A ring under test. It owns the ring and destroys it. `@unchecked Sendable`: a ring is made to
/// be shared by exactly two threads, one at each end, which is how the tests use it.
final class TestRing: @unchecked Sendable {
    let ring: OpaquePointer
    let channels: Int

    init?(channels: Int, capacity: Int, storage: ztd_ring_storage_t = ZTD_RING_STORAGE_PLAIN) {
        guard let ring = ztd_ring_create(UInt32(channels), UInt32(capacity), storage) else { return nil }
        self.ring = ring
        self.channels = channels
    }

    /// Takes over a ring that was created elsewhere.
    init?(adopting ring: OpaquePointer?, channels: Int) {
        guard let ring else { return nil }
        self.ring = ring
        self.channels = channels
    }

    deinit { ztd_ring_destroy(ring) }

    var capacity: Int { Int(ztd_ring_capacity(ring)) }
    var available: Int { Int(ztd_ring_available(ring)) }
    var space: Int { Int(ztd_ring_space(ring)) }
    var overrun: Int { Int(ztd_ring_overrun_frames(ring)) }
    var isMirrored: Bool { ztd_ring_is_mirrored(ring) }

    /// Writes planar frames (one array per channel) and returns how many the ring took.
    @discardableResult
    func write(_ frames: [[Float]], waiting: Bool = false) -> Int {
        precondition(frames.count == channels)
        let count = frames[0].count
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1) * channels)
        let pointers = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: channels)
        defer {
            storage.deallocate()
            pointers.deallocate()
        }
        for channel in 0 ..< channels {
            for frame in 0 ..< count { storage[channel * max(count, 1) + frame] = frames[channel][frame] }
            pointers[channel] = UnsafePointer(storage + channel * max(count, 1))
        }
        return Int(waiting ? ztd_ring_write_waiting(ring, pointers, UInt32(count)) : ztd_ring_write(ring, pointers, UInt32(count)))
    }

    /// Writes frames given sample by sample: frame 0 of every channel, frame 1 of every channel, …
    @discardableResult
    func writeInterleaved(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { Int(ztd_ring_write_interleaved(ring, $0.baseAddress, UInt32(samples.count / channels))) }
    }

    /// Reads up to `count` frames by copy.
    func read(_ count: Int) -> [[Float]] {
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1) * channels)
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
        defer {
            storage.deallocate()
            pointers.deallocate()
        }
        storage.initialize(repeating: .nan, count: max(count, 1) * channels)
        for channel in 0 ..< channels { pointers[channel] = storage + channel * max(count, 1) }
        let got = Int(ztd_ring_read(ring, pointers, UInt32(count)))
        return (0 ..< channels).map { Array(UnsafeBufferPointer(start: storage + $0 * max(count, 1), count: got)) }
    }

    /// The next `count` frames of one channel as a view, or nil when the ring has no contiguous one.
    func peek(_ channel: Int, _ count: Int) -> [Float]? {
        guard let view = ztd_ring_peek(ring, UInt32(channel), UInt32(count)) else { return nil }
        return Array(UnsafeBufferPointer(start: view, count: count))
    }

    @discardableResult
    func consume(_ count: Int) -> Int { Int(ztd_ring_consume(ring, UInt32(count))) }
}

/// Frames whose value says where they belong: channel c of frame n is n + c / 8 (exact in Float32).
private func ramp(_ range: Range<Int>, channels: Int) -> [[Float]] {
    (0 ..< channels).map { channel in range.map { Float($0) + Float(channel) / 8 } }
}

/// Frames of Float32 in one page of memory: what a mirrored ring's capacity is rounded up to.
private let pageFrames = Int(getpagesize()) / MemoryLayout<Float>.stride

@Suite("SPSC ring: one thread (WP-202)")
struct RingTests {
    @Test func capacityIsRoundedUpToAPowerOfTwo() throws {
        for (asked, expected) in [(1, 1), (2, 2), (3, 4), (1_000, 1_024), (1_024, 1_024), (1_025, 2_048)] {
            let ring = try #require(TestRing(channels: 2, capacity: asked))
            #expect(ring.capacity == expected && ring.space == expected && ring.available == 0 && !ring.isMirrored)
            #expect(ztd_ring_channels(ring.ring) == 2)
        }
    }

    @Test func framesComeOutInTheOrderTheyWentIn() throws {
        let ring = try #require(TestRing(channels: 3, capacity: 256))
        var generator = SeededGenerator(seed: 202)
        var written = 0, read = 0
        // Irregular writes and reads: empty ones, ones that wrap, ones that fill or drain the ring.
        while read < 20_000 {
            let push = min(Int(generator.next() % 200), ring.space)
            #expect(ring.write(ramp(written ..< written + push, channels: 3)) == push)
            written += push
            #expect(ring.available == written - read && ring.space == 256 - (written - read))
            let pull = Int(generator.next() % 200)
            let frames = ring.read(pull)
            let got = frames[0].count
            #expect(got == min(pull, written - read), "a read returns what is there, at most what was asked")
            #expect(frames == ramp(read ..< read + got, channels: 3))
            read += got
        }
        #expect(ring.overrun == 0)
    }

    @Test func aFullRingDropsTheNewestFramesAndCountsThem() throws {
        let ring = try #require(TestRing(channels: 2, capacity: 1_024))
        #expect(ring.write(ramp(0 ..< 1_000, channels: 2)) == 1_000)
        #expect(ring.write(ramp(1_000 ..< 1_100, channels: 2)) == 24, "only 24 fit")
        #expect(ring.overrun == 76 && ring.space == 0 && ring.available == 1_024)
        #expect(ring.write(ramp(5_000 ..< 5_010, channels: 2)) == 0)
        #expect(ring.overrun == 86, "a write to a full ring drops everything it was given")
        // What was dropped is the newest: the ring holds the first 1 024 frames, in order.
        #expect(ring.read(2_000) == ramp(0 ..< 1_024, channels: 2))
        #expect(ring.overrun == 86 && ring.space == 1_024, "the count is kept; the ring never grew")
        #expect(ring.write(ramp(0 ..< 10, channels: 2)) == 10, "and it takes frames again")
    }

    @Test func interleavedFramesLandInTheirChannels() throws {
        let ring = try #require(TestRing(channels: 3, capacity: 64))
        func interleaved(_ range: Range<Int>) -> [Float] { range.flatMap { n in (0 ..< 3).map { Float(n) + Float($0) / 8 } } }
        ring.write(ramp(0 ..< 50, channels: 3))
        #expect(ring.read(50) == ramp(0 ..< 50, channels: 3))
        #expect(ring.writeInterleaved(interleaved(50 ..< 90)) == 40, "40 frames, 14 before the wrap and 26 after it")
        #expect(ring.read(40) == ramp(50 ..< 90, channels: 3))
        #expect(ring.writeInterleaved(interleaved(0 ..< 70)) == 64 && ring.overrun == 6, "the newest are dropped and counted")
        #expect(ring.read(64) == ramp(0 ..< 64, channels: 3))
        #expect(ring.writeInterleaved([]) == 0)
    }

    @Test func aPeekIsAViewAndConsumingMovesPastIt() throws {
        let ring = try #require(TestRing(channels: 2, capacity: 64))
        ring.write(ramp(0 ..< 40, channels: 2))
        #expect(ring.peek(0, 40) == ramp(0 ..< 40, channels: 2)[0] && ring.peek(1, 10) == Array(ramp(0 ..< 10, channels: 2)[1]))
        #expect(ring.available == 40, "peeking consumes nothing")
        #expect(ring.peek(0, 41) == nil, "fewer frames are there")
        #expect(ring.peek(2, 1) == nil, "no such channel")
        #expect(ring.peek(0, 0) != nil, "nothing can always be seen")
        #expect(ring.consume(15) == 15 && ring.available == 25)
        #expect(ring.peek(0, 25) == Array(ramp(15 ..< 40, channels: 2)[0]))
        #expect(ring.consume(100) == 25 && ring.available == 0, "at most what is there")
        #expect(ring.consume(1) == 0)
    }

    @Test func emptyOperationsAndMissingArgumentsDoNothing() throws {
        let ring = try #require(TestRing(channels: 1, capacity: 16))
        #expect(ring.write([[]]) == 0 && ring.read(0) == [[]] && ring.read(5) == [[]] && ring.overrun == 0)
        let sample = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        let source = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 1)
        let destination = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 1)
        defer {
            sample.deallocate()
            source.deallocate()
            destination.deallocate()
        }
        sample.initialize(to: 1)
        source.initialize(to: UnsafePointer(sample))
        destination.initialize(to: sample)
        // No ring.
        #expect(ztd_ring_write(nil, source, 1) == 0 && ztd_ring_write_interleaved(nil, sample, 1) == 0)
        #expect(ztd_ring_write_waiting(nil, source, 1) == 0 && ztd_ring_read(nil, destination, 1) == 0)
        #expect(ztd_ring_peek(nil, 0, 0) == nil && ztd_ring_consume(nil, 1) == 0)
        #expect(ztd_ring_space(nil) == 0 && ztd_ring_available(nil) == 0 && ztd_ring_overrun_frames(nil) == 0)
        #expect(ztd_ring_channels(nil) == 0 && ztd_ring_capacity(nil) == 0 && !ztd_ring_is_mirrored(nil))
        ztd_ring_close(nil)
        ztd_ring_reset(nil)
        ztd_ring_destroy(nil)
        // No buffers.
        #expect(ztd_ring_write(ring.ring, nil, 4) == 0 && ztd_ring_write_interleaved(ring.ring, nil, 4) == 0)
        #expect(ztd_ring_write_waiting(ring.ring, nil, 4) == 0 && ztd_ring_read(ring.ring, nil, 4) == 0)
        #expect(ring.overrun == 0 && ring.available == 0, "nothing was written, so nothing was dropped")
    }

    @Test func creationFailsWithoutChannelsWithoutCapacityOrBeyondAllReason() {
        #expect(TestRing(channels: 0, capacity: 64) == nil)
        #expect(TestRing(channels: 2, capacity: 0) == nil)
        #expect(ztd_ring_create(1, (1 << 30) + 1, ZTD_RING_STORAGE_PLAIN) == nil)
        #expect(ztd_ring_create(100_000, 64, ZTD_RING_STORAGE_PLAIN) == nil)
        #expect(ztd_ring_create(1, 64, ztd_ring_storage_t(rawValue: 9)) == nil, "an unknown kind of storage")
        #expect(ztd_ring_create(0, 64, ZTD_RING_STORAGE_MIRRORED) == nil && ztd_ring_create(1, 0, ZTD_RING_STORAGE_AUTOMATIC) == nil)
    }

    @Test func aResetEmptiesTheRingAndClearsItsCounters() throws {
        let ring = try #require(TestRing(channels: 1, capacity: 8))
        ring.write(ramp(0 ..< 20, channels: 1))
        #expect(ring.available == 8 && ring.overrun == 12)
        ztd_ring_reset(ring.ring)
        #expect(ring.available == 0 && ring.space == 8 && ring.overrun == 0)
        ring.write(ramp(100 ..< 105, channels: 1))
        #expect(ring.read(8) == ramp(100 ..< 105, channels: 1))
    }

    @Test(arguments: [ZTD_RING_STORAGE_PLAIN.rawValue, ZTD_RING_STORAGE_MIRRORED.rawValue])
    func bothEndsAreAllocationFree(storage: UInt32) throws {
        let ring = try #require(TestRing(channels: 2, capacity: pageFrames, storage: ztd_ring_storage_t(rawValue: storage)))
        let frames = 384
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 4 * frames)
        samples.initialize(repeating: 0.25, count: 4 * frames)
        let sources = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
        let sinks = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        defer {
            samples.deallocate()
            sources.deallocate()
            sinks.deallocate()
        }
        sources[0] = UnsafePointer(samples)
        sources[1] = UnsafePointer(samples + frames)
        sinks[0] = samples + 2 * frames
        sinks[1] = samples + 3 * frames
        let pointer = ring.ring
        var moved: UInt32 = 0
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                moved &+= ztd_ring_write(pointer, sources, UInt32(frames))
                moved &+= ztd_ring_read(pointer, sinks, UInt32(frames - 100))
                moved &+= ztd_ring_write_interleaved(pointer, samples, 50)
                if ztd_ring_peek(pointer, 1, 150) != nil { moved &+= 1 }
                moved &+= ztd_ring_consume(pointer, 150)
                moved &+= ztd_ring_space(pointer) &+ ztd_ring_available(pointer) &+ UInt32(truncatingIfNeeded: ztd_ring_overrun_frames(pointer))
                round += 1
            }
            ztd_ring_close(pointer)
        }
        #expect(moved > 0)
    }

    @Test func aBenchmarkIsRecorded() throws {
        var results: [BenchmarkResult] = []
        for (name, storage) in [("plain", ZTD_RING_STORAGE_PLAIN), ("mirrored", ZTD_RING_STORAGE_MIRRORED)] {
            let ring = try #require(TestRing(channels: 2, capacity: pageFrames, storage: storage))
            let frames = 512
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 4 * frames)
            samples.initialize(repeating: 0.25, count: 4 * frames)
            let sources = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
            let sinks = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
            defer {
                samples.deallocate()
                sources.deallocate()
                sinks.deallocate()
            }
            sources[0] = UnsafePointer(samples)
            sources[1] = UnsafePointer(samples + frames)
            sinks[0] = samples + 2 * frames
            sinks[1] = samples + 3 * frames
            let pointer = ring.ring
            results.append(Benchmark.measure("ring.\(name).write-read.512x2", iterations: 2_000) {
                ztd_ring_write(pointer, sources, UInt32(frames))
                ztd_ring_read(pointer, sinks, UInt32(frames))
            })
        }
        Benchmark.record(results)
        for result in results { note(result.name, result.minimum, "ns") }
        #expect(results.count == 2 && results.allSatisfy { $0.minimum > 0 })
    }
}

@Suite("SPSC ring: mirrored storage and its fall-back (WP-203)")
struct RingStorageTests {
    @Test func aMirroredRingHoldsWholePages() throws {
        let ring = try #require(TestRing(channels: 2, capacity: 100, storage: ZTD_RING_STORAGE_MIRRORED), "this system grants the mirror")
        #expect(ring.isMirrored)
        #expect(ring.capacity == pageFrames, "rounded up to a page")
        let larger = try #require(TestRing(channels: 1, capacity: pageFrames + 1, storage: ZTD_RING_STORAGE_MIRRORED))
        #expect(larger.capacity == 2 * pageFrames)
    }

    /// The memory of a mirrored ring comes from `mmap` and goes back through `munmap`, so a
    /// ring that is made where another lived is new memory to whoever follows the mappings of
    /// the process. Two threads make and destroy rings side by side, with nothing between
    /// them; each makes its next ring before it lets go of the one before, so the place one
    /// thread gives back is there for the other to take. Under the Thread Sanitizer this test
    /// fails when the region is mapped behind the sanitizer's back, through Mach: the writes
    /// with which a ring touches its pages when it is made (RT-9) are then writes of two
    /// threads to one address, and nothing orders them. (Rings made one after another by
    /// threads that are joined in between would not show it: the join orders them.)
    @Test func aMirroredRingMadeWhereAnotherLivedIsNewMemory() throws {
        let rounds = 300
        @Sendable func churn(_ lane: Int) -> (places: [UInt], intact: Int) {
            var places: [UInt] = []
            var intact = 0
            var before: TestRing?
            for round in 0 ..< rounds {
                guard let ring = TestRing(channels: 2, capacity: pageFrames, storage: ZTD_RING_STORAGE_MIRRORED),
                      let base = ztd_ring_peek(ring.ring, 0, 0) else { continue }
                // The ring before this one goes now; its place is free while this one is used.
                before = nil
                let frames = ramp(lane + round ..< lane + round + 300, channels: 2)
                if ring.write(frames) == 300, ring.read(300) == frames { intact += 1 }
                places.append(UInt(bitPattern: base))
                before = ring
            }
            _ = before
            return (places, intact)
        }
        let first = Shared<(places: [UInt], intact: Int)?>(nil), second = Shared<(places: [UInt], intact: Int)?>(nil)
        let threads = [JoinableThread { first.set(churn(0)) }, JoinableThread { second.set(churn(1_000)) }]
        #expect(threads.allSatisfy { $0.started })
        for thread in threads { thread.join() }
        let one = try #require(first.get()), two = try #require(second.get())
        #expect(one.intact == rounds && two.intact == rounds, "every ring held what was written to it: \(one.intact) and \(two.intact) of \(rounds)")
        #expect(!Set(one.places).isDisjoint(with: two.places), "a ring of one thread was made where a ring of the other had lived")
    }

    @Test func anAutomaticRingMirrorsWhenTheSystemGrantsItAndHoldsTheSameEitherWay() throws {
        let automatic = try #require(TestRing(channels: 2, capacity: 100, storage: ZTD_RING_STORAGE_AUTOMATIC))
        let demanded = TestRing(channels: 2, capacity: 100, storage: ZTD_RING_STORAGE_MIRRORED)
        #expect(automatic.isMirrored == (demanded != nil), "mirrored exactly when a mirror can be had")
        #expect(automatic.capacity == pageFrames, "the capacity does not depend on what the system allowed")
    }

    @Test func aWindowSpanningTheWrapIsContiguousAndCorrect() throws {
        let ring = try #require(TestRing(channels: 2, capacity: pageFrames, storage: ZTD_RING_STORAGE_MIRRORED))
        let capacity = ring.capacity
        let base = try #require(ztd_ring_peek(ring.ring, 0, 0))
        // Move both ends to 100 frames before the end of the storage, then write across it.
        ring.write(ramp(0 ..< capacity - 100, channels: 2))
        #expect(ring.consume(capacity - 100) == capacity - 100)
        let window = capacity - 100 ..< capacity + 200
        #expect(ring.write(ramp(window, channels: 2)) == 300)
        for channel in 0 ..< 2 {
            let view = try #require(ztd_ring_peek(ring.ring, UInt32(channel), 300), "the window wraps, and is one piece all the same")
            #expect(Array(UnsafeBufferPointer(start: view, count: 300)) == ramp(window, channels: 2)[channel])
            if channel == 0 {
                #expect(view == base + (capacity - 100), "it starts 100 frames before the end and runs 200 past it")
                // Past the end is the beginning again: the same memory, seen twice.
                #expect(Array(UnsafeBufferPointer(start: base, count: 200)) == Array(ramp(window, channels: 2)[0][100...]))
                #expect(view + 100 == base + capacity)
            }
        }
        // Reading by copy gives the same frames.
        #expect(ring.read(300) == ramp(window, channels: 2))
        // A window as long as the whole ring, starting anywhere, is still one piece.
        ring.write(ramp(0 ..< capacity, channels: 2))
        #expect(ring.peek(1, capacity) == ramp(0 ..< capacity, channels: 2)[1])
    }

    @Test func theFallBackIsForcedAndCopiesOnWrap() throws {
        let ring = try #require(TestRing(channels: 2, capacity: pageFrames, storage: ZTD_RING_STORAGE_PLAIN))
        #expect(!ring.isMirrored, "plain storage even where a mirror could be had")
        let capacity = ring.capacity
        ring.write(ramp(0 ..< capacity - 100, channels: 2))
        ring.consume(capacity - 100)
        let window = capacity - 100 ..< capacity + 200
        #expect(ring.write(ramp(window, channels: 2)) == 300, "written in two pieces")
        #expect(ring.peek(0, 300) == nil, "no contiguous view across the wrap: the caller reads by copy")
        #expect(ring.peek(0, 100) == Array(ramp(window, channels: 2)[0][..<100]), "up to the wrap there is one")
        #expect(ring.peek(0, 101) == nil)
        #expect(ring.read(300) == ramp(window, channels: 2), "and the copy is correct")
    }

    /// The same seeded sequence of operations on a mirrored and on a plain ring: every count and
    /// every frame agree. The data are the stress fixtures of WP-016 that carry what a ring must
    /// not touch: NaN, infinities, subnormal values, a tail decaying to zero.
    @Test func mirroredAndPlainRingsGiveTheSameResultsBitForBit() throws {
        let mirrored = try #require(TestRing(channels: 2, capacity: pageFrames, storage: ZTD_RING_STORAGE_MIRRORED))
        let plain = try #require(TestRing(channels: 2, capacity: pageFrames, storage: ZTD_RING_STORAGE_PLAIN))
        let total = 40 * pageFrames
        let nonFinite = StressFixture.nonFiniteSignal(count: total).samples
        let cases = StressFixture.signals(count: total)
        let subnormal = try #require(cases.first { $0.name == "denormal" }).samples
        let tail = try #require(cases.first { $0.name == "decaying-tail" }).samples
        let left = nonFinite, right = zip(subnormal, tail).enumerated().map { $0.offset % 2 == 0 ? $0.element.0 : $0.element.1 }
        #expect(left.contains { $0.isNaN } && left.contains(.infinity) && right.contains { $0.isSubnormal })

        var generator = SeededGenerator(seed: 203)
        var written = 0
        var outputs: [[UInt32]] = [[], []]
        while written < total {
            let push = min(Int(generator.next() % UInt64(pageFrames)), total - written)
            let frames = [Array(left[written ..< written + push]), Array(right[written ..< written + push])]
            let interleave = generator.next() % 3 == 0
            let took: (Int, Int)
            if interleave {
                let samples = (0 ..< push).flatMap { [frames[0][$0], frames[1][$0]] }
                took = (mirrored.writeInterleaved(samples), plain.writeInterleaved(samples))
            } else {
                took = (mirrored.write(frames), plain.write(frames))
            }
            #expect(took.0 == took.1 && mirrored.overrun == plain.overrun)
            written += push   // what did not fit was dropped, by both
            let pull = Int(generator.next() % UInt64(pageFrames))
            let a = mirrored.read(pull), b = plain.read(pull)
            #expect(a.map(bits) == b.map(bits))
            for channel in 0 ..< 2 { outputs[channel].append(contentsOf: bits(a[channel])) }
        }
        let rest = mirrored.read(pageFrames)
        #expect(rest.map(bits) == plain.read(pageFrames).map(bits))
        for channel in 0 ..< 2 { outputs[channel].append(contentsOf: bits(rest[channel])) }
        #expect(mirrored.overrun > 0, "the sequence overran the ring, so dropping is compared too")
        #expect(outputs[0].count + mirrored.overrun == total)
        // Every frame that came out is, bit for bit, a frame that went in, in order.
        var cursor = 0
        let source = bits(left)
        for value in outputs[0] {
            while cursor < total && source[cursor] != value { cursor += 1 }
            #expect(cursor < total)
            if cursor >= total { break }
            cursor += 1
        }
    }

    /// RT-9: the storage is touched page by page when the ring is created, both views of a
    /// mirrored ring, so no thread takes a first-touch fault later.
    @Test(arguments: [ZTD_RING_STORAGE_PLAIN.rawValue, ZTD_RING_STORAGE_MIRRORED.rawValue])
    func storageIsResidentAsSoonAsTheRingExists(storage: UInt32) throws {
        // Large enough that the memory cannot come from a recycled small allocation.
        let ring = try #require(TestRing(channels: 2, capacity: 64 * pageFrames, storage: ztd_ring_storage_t(rawValue: storage)))
        let page = Int(getpagesize())
        let views = ring.isMirrored ? 2 : 1
        for channel in 0 ..< 2 {
            let base = UnsafeRawPointer(try #require(ztd_ring_peek(ring.ring, UInt32(channel), 0)))
            let start = UnsafeRawPointer(bitPattern: UInt(bitPattern: base) & ~UInt(page - 1))!
            let bytes = views * ring.capacity * MemoryLayout<Float>.stride
            var resident = [CChar](repeating: 0, count: bytes / page + 1)
            #expect(mincore(start, bytes, &resident) == 0)
            let missing = resident.prefix(bytes / page).filter { $0 & 1 == 0 }.count
            #expect(missing == 0, "\(missing) of \(bytes / page) pages of channel \(channel) are not resident")
        }
    }
}

@Suite("SPSC ring: two threads (WP-202, WP-222)")
struct RingTwoThreadTests {
    /// Frame n carries n in channel 0 and −n in channel 1. Values stay below 2²⁴, where Float32
    /// counts exactly.
    private static func fill(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, from start: Int, count: Int) {
        var first = Float(start), step: Float = 1, negative = -Float(start), down: Float = -1
        vDSP_vramp(&first, &step, left, 1, vDSP_Length(count))
        vDSP_vramp(&negative, &down, right, 1, vDSP_Length(count))
    }

    @Test(arguments: [ZTD_RING_STORAGE_MIRRORED.rawValue, ZTD_RING_STORAGE_PLAIN.rawValue])
    func tenMillionFramesCrossWithoutLossOrDuplication(storage: UInt32) throws {
        let total = 10_000_000
        let ring = try #require(TestRing(channels: 2, capacity: pageFrames, storage: ztd_ring_storage_t(rawValue: storage)))
        let writerTotal = Shared(0)
        let writerDone = Shared(false)

        let writer = JoinableThread {
            defer { writerDone.set(true) }
            let chunk = 700
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 2 * chunk)
            let sources = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
            defer {
                samples.deallocate()
                sources.deallocate()
            }
            sources[0] = UnsafePointer(samples)
            sources[1] = UnsafePointer(samples + chunk)
            var generator = SeededGenerator(seed: 0x57A7)
            var sent = 0
            while sent < total {
                // Only what fits is offered, so nothing may be dropped: every frame must arrive.
                let count = min(1 + Int(generator.next() % UInt64(chunk)), total - sent, Int(ztd_ring_space(ring.ring)))
                if count == 0 {
                    sched_yield()
                    continue
                }
                Self.fill(samples, samples + chunk, from: sent, count: count)
                sent += Int(ztd_ring_write(ring.ring, sources, UInt32(count)))
            }
            writerTotal.set(sent)
        }
        #expect(writer.started)

        let chunk = 900
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 4 * chunk)
        let sinks = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        defer {
            samples.deallocate()
            sinks.deallocate()
        }
        sinks[0] = samples
        sinks[1] = samples + chunk
        var generator = SeededGenerator(seed: 0x4EAD)
        var received = 0
        var firstMismatch: Int? = nil
        var drained = false
        while received < total {
            let count = Int(ztd_ring_read(ring.ring, sinks, UInt32(1 + Int(generator.next() % UInt64(chunk)))))
            if count == 0 {
                // If frames were lost the reader must not wait for them for ever: once the writer
                // has finished, one more look at the ring is the last.
                if drained { break }
                drained = writerDone.get()
                sched_yield()
                continue
            }
            // What must have arrived: the next `count` frames, exactly.
            Self.fill(samples + 2 * chunk, samples + 3 * chunk, from: received, count: count)
            if firstMismatch == nil,
               memcmp(samples, samples + 2 * chunk, count * 4) != 0 || memcmp(samples + chunk, samples + 3 * chunk, count * 4) != 0 {
                firstMismatch = received
            }
            received += count
        }
        writer.join()
        #expect(firstMismatch == nil, "frames near \(firstMismatch ?? 0) were lost, duplicated or out of order")
        #expect(received == total && writerTotal.get() == total)
        #expect(ring.overrun == 0 && ring.available == 0)
    }

    @Test func aWriterThatDoesNotWaitDropsFramesAndTheCountIsExact() throws {
        let total = 2_000_000
        let ring = try #require(TestRing(channels: 2, capacity: 1_024))
        let accepted = Shared(0)
        let finished = Shared(false)

        let writer = JoinableThread {
            let chunk = 300
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 2 * chunk)
            let sources = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
            defer {
                samples.deallocate()
                sources.deallocate()
            }
            sources[0] = UnsafePointer(samples)
            sources[1] = UnsafePointer(samples + chunk)
            var sent = 0, taken = 0
            while sent < total {
                let count = min(chunk, total - sent)
                Self.fill(samples, samples + chunk, from: sent, count: count)
                taken += Int(ztd_ring_write(ring.ring, sources, UInt32(count)))   // as the I/O thread does: no look, no wait
                sent += count
            }
            accepted.set(taken)
            finished.set(true)
        }

        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 512)
        let sinks = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        defer {
            samples.deallocate()
            sinks.deallocate()
        }
        sinks[0] = samples
        sinks[1] = samples + 512
        var received = 0
        var last: Float = -1
        var ordered = true, paired = true
        var done = false
        while true {
            let count = Int(ztd_ring_read(ring.ring, sinks, 512))
            if count == 0 {
                if done { break }
                done = finished.get()   // once the writer is finished, one more pass drains the ring
                sched_yield()
                continue
            }
            var index = 0
            while index < count {
                // Frames may be missing (they were dropped), never repeated and never out of order.
                if samples[index] <= last { ordered = false }
                if samples[512 + index] != -samples[index] { paired = false }
                last = samples[index]
                index += 1
            }
            received += count
        }
        writer.join()
        #expect(ordered, "a frame arrived twice or out of order")
        #expect(paired, "the channels of a frame were torn apart")
        #expect(received == accepted.get(), "every frame the ring took came out")
        #expect(accepted.get() + ring.overrun == total, "taken plus dropped is everything that was offered")
    }

    /// WP-222: the lossless mode. The writer hands over more than the ring holds and waits for
    /// space; the consumer is slow. Nothing is lost, nothing is counted as dropped.
    @Test(arguments: [ZTD_RING_STORAGE_PLAIN.rawValue, ZTD_RING_STORAGE_MIRRORED.rawValue])
    func aWaitingWriterLosesNothingUnderASlowConsumer(storage: UInt32) throws {
        let total = 60_000   // some 230 waits of the writer: enough to show the mode, short on a busy machine
        let ring = try #require(TestRing(channels: 2, capacity: 256, storage: ztd_ring_storage_t(rawValue: storage)))
        let accepted = Shared(0)
        let writerDone = Shared(false)

        let writer = JoinableThread {
            defer { writerDone.set(true) }
            let chunk = 3 * ring.capacity + 17   // never fits at once
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: 2 * chunk)
            let sources = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
            defer {
                samples.deallocate()
                sources.deallocate()
            }
            sources[0] = UnsafePointer(samples)
            sources[1] = UnsafePointer(samples + chunk)
            var sent = 0
            while sent < total {
                let count = min(chunk, total - sent)
                Self.fill(samples, samples + chunk, from: sent, count: count)
                let taken = Int(ztd_ring_write_waiting(ring.ring, sources, UInt32(count)))
                sent += taken
                if taken != count { break }   // only a closed ring ends a waiting write early
            }
            accepted.set(sent)
        }

        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 4 * 64)
        let sinks = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        defer {
            samples.deallocate()
            sinks.deallocate()
        }
        sinks[0] = samples
        sinks[1] = samples + 64
        var received = 0
        var firstMismatch: Int? = nil
        var drained = false
        while received < total {
            // A slow consumer: a few frames, then it gives the processor away.
            let count = Int(ztd_ring_read(ring.ring, sinks, 61))
            sched_yield()
            if count == 0 {
                if drained { break }   // the writer gave up and the ring is empty: frames are missing
                drained = writerDone.get()
                continue
            }
            Self.fill(samples + 128, samples + 192, from: received, count: count)
            if firstMismatch == nil, memcmp(samples, samples + 128, count * 4) != 0 || memcmp(samples + 64, samples + 192, count * 4) != 0 {
                firstMismatch = received
            }
            received += count
        }
        writer.join()
        #expect(firstMismatch == nil, "frames near \(firstMismatch ?? 0) were lost or duplicated")
        #expect(accepted.get() == total && received == total)
        #expect(ring.overrun == 0, "a waiting write drops nothing")
    }

    @Test func closingTheRingReleasesAWaitingWriter() throws {
        let ring = try #require(TestRing(channels: 1, capacity: 256))
        let taken = Shared(-1)
        let writer = JoinableThread {
            taken.set(ring.write(ramp(0 ..< 1_000, channels: 1), waiting: true))   // nobody reads: it must wait
        }
        // The ring is full once the writer has put in all that fits; from then on it is waiting.
        // (Should it return instead of waiting, `taken` says so and the loop ends.)
        while ring.space > 0 && taken.get() == -1 { sched_yield() }
        #expect(ring.space == 0 && taken.get() == -1, "the ring is full and the writer is still inside the call")
        ztd_ring_close(ring.ring)
        writer.join()
        #expect(taken.get() == 256, "it returns what it had written when the ring was closed")
        #expect(ring.read(300) == ramp(0 ..< 256, channels: 1) && ring.overrun == 0)
        // A closed ring makes later waits return at once, with nothing written…
        #expect(ring.write(ramp(0 ..< 10, channels: 1), waiting: true) == 0 && ring.available == 0)
        // …and a reset reopens it.
        ztd_ring_reset(ring.ring)
        #expect(ring.write(ramp(0 ..< 10, channels: 1), waiting: true) == 10)
        #expect(ring.write(ramp(10 ..< 200, channels: 1), waiting: true) == 190, "a write that fits never waits")
        #expect(ring.read(256) == ramp(0 ..< 200, channels: 1))
    }
}
