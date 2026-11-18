import AVFAudio
import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// A buffer list as an `AVAudioSinkNode` or a node tap hands one over, over samples the test
/// holds: one buffer per channel, or one buffer with every channel interleaved.
final class SyntheticBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// One buffer per channel: the layout of an engine's nodes.
    init(planar channels: [[Float]]) {
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (index, samples) in channels.enumerated() {
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(samples.count * 4), mData: copy(samples))
        }
    }

    /// One buffer that holds `channels` channels, frame by frame.
    init(interleaved samples: [Float], channels: Int) {
        list = AudioBufferList.allocate(maximumBuffers: 1)
        list[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(samples.count * 4), mData: copy(samples))
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }

    /// The list, for the length of `body`: a pointer taken from an object that is not used
    /// afterwards would outlive it.
    func withPointer<Result>(_ body: (UnsafePointer<AudioBufferList>) throws -> Result) rethrows -> Result {
        try withExtendedLifetime(self) { try body(UnsafePointer(list.unsafePointer)) }
    }

    private func copy(_ samples: [Float]) -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: max(samples.count, 1))
        pointer.initialize(from: samples, count: samples.count)
        storage.append(pointer)
        return UnsafeMutableRawPointer(pointer)
    }
}

/// A tap under test: it holds the tap once and gives the hold back.
final class TestTap: @unchecked Sendable {
    // `@unchecked Sendable`: a tap is made for two threads, one that receives and one that
    // connects rings, which is how the tests use it.
    let tap: OpaquePointer

    init?() {
        guard let tap = ztd_sink_tap_create() else { return nil }
        self.tap = tap
    }

    deinit { ztd_sink_tap_release(tap) }

    var written: Int { Int(ztd_sink_tap_written_frames(tap)) }
    var discarded: Int { Int(ztd_sink_tap_discarded_frames(tap)) }

    @discardableResult
    func receive(_ buffers: SyntheticBufferList, frames: Int) -> Int32 {
        buffers.withPointer { ztd_sink_tap_receive(tap, $0, UInt32(frames)) }
    }
}

/// The sink-node factory (WP-703): the function that runs on the audio I/O thread, driven with
/// synthetic buffer lists, because a sink node does not run in manual rendering mode (E-14).
@Suite("Sink node")
struct SinkNodeTests {
    let left: [Float] = (0 ..< 480).map { Float($0) * 0.001 }
    let right: [Float] = (0 ..< 480).map { -Float($0) * 0.002 }

    private func tapWithRing(channels: Int, capacity: Int = 4_096) throws -> (TestTap, TestRing) {
        let tap = try #require(TestTap())
        let ring = try #require(TestRing(channels: channels, capacity: capacity))
        #expect(ztd_sink_tap_set_ring(tap.tap, ring.ring))
        return (tap, ring)
    }

    @Test func aPlanarBufferListFillsTheRing() throws {
        let (tap, ring) = try tapWithRing(channels: 2)
        #expect(tap.receive(SyntheticBufferList(planar: [left, right]), frames: 480) == 0, "the receiver reports noErr")
        #expect(ring.read(480) == [left, right])
        #expect(tap.written == 480 && tap.discarded == 0)
        // A second buffer lands behind the first.
        tap.receive(SyntheticBufferList(planar: [right, left]), frames: 480)
        tap.receive(SyntheticBufferList(planar: [left, right]), frames: 100)
        #expect(ring.read(1_000) == [right + Array(left[..<100]), left + Array(right[..<100])])
        #expect(tap.written == 1_060)
    }

    @Test func oneChannelIsOneBuffer() throws {
        let (tap, ring) = try tapWithRing(channels: 1)
        tap.receive(SyntheticBufferList(planar: [left]), frames: 480)
        #expect(ring.read(480) == [left])
    }

    @Test func anInterleavedBufferListFillsTheRing() throws {
        let (tap, ring) = try tapWithRing(channels: 2)
        let interleaved = zip(left, right).flatMap { [$0, $1] }
        #expect(tap.receive(SyntheticBufferList(interleaved: interleaved, channels: 2), frames: 480) == 0)
        #expect(ring.read(480) == [left, right])
        #expect(tap.written == 480 && tap.discarded == 0)
    }

    /// The two blocks the factory hands a sink node: the one of the classic initialiser and the
    /// one that is declared non-blocking for the real-time-safe initialiser of iOS 27 (E-02).
    @Test(arguments: [false, true])
    func theBlockOfTheFactoryFillsTheRing(realtimeSafe: Bool) throws {
        let (tap, ring) = try tapWithRing(channels: 2)
        let block = try #require(ztd_sink_node_receiver(tap.tap, realtimeSafe))
        var timestamp = AudioTimeStamp()
        let buffers = SyntheticBufferList(planar: [left, right])
        #expect(buffers.withPointer { block(&timestamp, 480, $0) } == 0)
        #expect(buffers.withPointer { block(nil, 240, $0) } == 0, "the block does not look at the time stamp")
        #expect(ring.read(1_000) == [left + Array(left[..<240]), right + Array(right[..<240])])
        #expect(tap.written == 720)
    }

    @Test func whatDoesNotFitTheRingIsDiscardedAndCounted() throws {
        let tap = try #require(TestTap())
        let stereo = SyntheticBufferList(planar: [left, right])
        tap.receive(stereo, frames: 480)
        #expect(tap.discarded == 480 && tap.written == 0, "without a ring the frames are discarded and counted")

        let ring = try #require(TestRing(channels: 2, capacity: 4_096))
        ztd_sink_tap_set_ring(tap.tap, ring.ring)
        tap.receive(SyntheticBufferList(planar: [left]), frames: 480)
        tap.receive(SyntheticBufferList(planar: [left, right, left]), frames: 480)
        tap.receive(SyntheticBufferList(interleaved: left, channels: 3), frames: 160)
        #expect(tap.discarded == 480 + 480 + 480 + 160 && ring.available == 0, "another channel count than the ring's")

        let twoByTwo = SyntheticBufferList(planar: [left, right])
        twoByTwo.list[1].mNumberChannels = 2
        tap.receive(twoByTwo, frames: 240)
        let withoutData = SyntheticBufferList(planar: [left, right])
        withoutData.list[0].mData = nil
        tap.receive(withoutData, frames: 480)
        let interleavedWithoutData = SyntheticBufferList(interleaved: left, channels: 2)
        interleavedWithoutData.list[0].mData = nil
        tap.receive(interleavedWithoutData, frames: 240)
        #expect(tap.discarded == 1_600 + 240 + 480 + 240 && ring.available == 0, "a layout that is neither planar nor interleaved, and buffers without data")

        tap.receive(stereo, frames: 0)
        #expect(ztd_sink_tap_receive(tap.tap, nil, 480) == 0 && stereo.withPointer { ztd_sink_tap_receive(nil, $0, 480) } == 0)
        #expect(tap.discarded == 2_560 && tap.written == 0, "nothing to receive is nothing to count")

        tap.receive(stereo, frames: 480)
        #expect(ring.read(480) == [left, right] && tap.written == 480, "and the tap still works")
        ztd_sink_tap_set_ring(tap.tap, nil)
        tap.receive(stereo, frames: 480)
        #expect(tap.discarded == 3_040 && ring.available == 0, "a ring that was taken away is no longer written")
    }

    @Test func aBufferThatHoldsLessThanItSaysIsTakenAsFarAsItGoes() throws {
        let (tap, ring) = try tapWithRing(channels: 2)
        let short = SyntheticBufferList(planar: [Array(left[..<100]), Array(right[..<60])])
        tap.receive(short, frames: 480)
        #expect(ring.read(480) == [Array(left[..<60]), Array(right[..<60])], "never past the end of the shortest buffer")
        let interleaved = SyntheticBufferList(interleaved: zip(left[..<50], right[..<50]).flatMap { [$0, $1] }, channels: 2)
        tap.receive(interleaved, frames: 480)
        #expect(ring.read(480) == [Array(left[..<50]), Array(right[..<50])])
        #expect(tap.written == 110 && tap.discarded == 0)
    }

    @Test func aFullRingDropsTheNewestFramesAndCountsThem() throws {
        let (tap, ring) = try tapWithRing(channels: 2, capacity: 256)
        tap.receive(SyntheticBufferList(planar: [left, right]), frames: 480)
        #expect(ring.capacity == 256 && ring.available == 256 && ring.overrun == 224, "the ring never grows (RT-8)")
        #expect(tap.written == 256)
        #expect(ring.read(256) == [Array(left[..<256]), Array(right[..<256])], "what was kept is the oldest")
    }

    @Test func aRingOfTooManyChannelsIsRefused() throws {
        let (tap, ring) = try tapWithRing(channels: 1)
        let wide = try #require(TestRing(channels: Int(ZTD_SINK_TAP_MAX_CHANNELS) + 1, capacity: 64))
        #expect(!ztd_sink_tap_set_ring(tap.tap, wide.ring))
        tap.receive(SyntheticBufferList(planar: [left]), frames: 480)
        #expect(ring.available == 480, "the tap keeps the ring it had")
        let widest = try #require(TestRing(channels: Int(ZTD_SINK_TAP_MAX_CHANNELS), capacity: 64))
        #expect(ztd_sink_tap_set_ring(tap.tap, widest.ring))
        let silence = [Float](repeating: 0.25, count: 16)
        tap.receive(SyntheticBufferList(planar: [[Float]](repeating: silence, count: Int(ZTD_SINK_TAP_MAX_CHANNELS))), frames: 16)
        #expect(widest.available == 16 && widest.read(16).allSatisfy { $0 == silence })
        #expect(!ztd_sink_tap_set_ring(nil, ring.ring))
    }

    /// The control context changes the ring while the I/O thread receives: once
    /// `ztd_sink_tap_set_ring` has returned, nothing is written to the ring that was replaced,
    /// so it can be released at once.
    @Test func theRingChangesHandsWhileTheTapReceives() throws {
        let tap = try #require(TestTap())
        let buffers = SyntheticBufferList(planar: [left, right])
        let stop = try #require(ztd_atomic_create(0))
        defer { ztd_atomic_destroy(stop) }
        final class Box: @unchecked Sendable {
            let buffers: SyntheticBufferList, stop: OpaquePointer
            init(_ buffers: SyntheticBufferList, _ stop: OpaquePointer) { self.buffers = buffers; self.stop = stop }
        }
        let box = Box(buffers, stop)
        let done = DispatchGroup()
        done.enter()
        let receiver = Thread {
            while ztd_atomic_load(box.stop) == 0 { tap.receive(box.buffers, frames: 480) }
            done.leave()
        }
        receiver.start()

        /// How much is written to a ring within a moment, by what it holds and what it dropped.
        func traffic(_ ring: TestRing) -> Int {
            let held = ring.available, dropped = ring.overrun
            usleep(150)
            return (ring.available - held) + (ring.overrun - dropped)
        }
        var writtenToReplaced = 0
        var previous: TestRing?
        for round in 0 ..< 300 {
            // A ring of its own for every round; it takes the place of the last one directly,
            // or of none, by turns.
            let ring = try #require(TestRing(channels: 2, capacity: 1_024))
            #expect(ztd_sink_tap_set_ring(tap.tap, ring.ring))
            if let replaced = previous { writtenToReplaced += traffic(replaced) }
            previous = nil                                  // the replaced ring is destroyed here
            while ring.available == 0 { usleep(20) }        // the receiver has found the new ring
            if round % 2 == 0 {
                #expect(ztd_sink_tap_set_ring(tap.tap, nil))
                writtenToReplaced += traffic(ring)
            } else {
                previous = ring
            }
        }
        #expect(ztd_sink_tap_set_ring(tap.tap, nil))
        ztd_atomic_store(stop, 1)
        done.wait()
        #expect(writtenToReplaced == 0, "a ring that was replaced was written after the replacement returned")
        #expect(tap.written > 0 && tap.discarded > 0, "frames went to rings while there was one, and were discarded while there was none")
    }

    /// RT-7, layer 3: what runs on the I/O thread makes no heap traffic. The compiler proves it
    /// for the function and for the non-blocking block (layer 1); this measures all three.
    @Test func receivingIsAllocationFree() throws {
        let (tap, ring) = try tapWithRing(channels: 2, capacity: 2_048)
        let planar = SyntheticBufferList(planar: [left, right])
        let interleaved = SyntheticBufferList(interleaved: zip(left, right).flatMap { [$0, $1] }, channels: 2)
        let classic = try #require(ztd_sink_node_receiver(tap.tap, false))
        let realtimeSafe = try #require(ztd_sink_node_receiver(tap.tap, true))
        planar.withPointer { planar in
            interleaved.withPointer { interleaved in
                _ = expectNoAllocations {
                    var round = 0
                    while round < 1_000 {
                        _ = ztd_sink_tap_receive(tap.tap, planar, 480)
                        _ = ztd_sink_tap_receive(tap.tap, interleaved, 480)
                        _ = classic(nil, 480, planar)
                        _ = realtimeSafe(nil, 480, planar)
                        _ = ztd_ring_consume(ring.ring, 1_920)
                        round += 1
                    }
                }
            }
        }
        #expect(tap.written == 1_920_000 && ring.overrun == 0)
    }

    @Test func theFactoryMakesANodeForEitherInitialiser() throws {
        if #available(iOS 27.0, *) {
            #expect(ztd_sink_node_has_realtime_safe_initialiser())
        } else {
            #expect(!ztd_sink_node_has_realtime_safe_initialiser())
        }
        for realtimeSafe in [true, false] {
            let tap = try #require(TestTap())
            let node = try #require(ztd_sink_node_create(tap.tap, realtimeSafe))
            #expect(node.numberOfInputs == 1 && node.numberOfOutputs == 0, "a sink has an input and no output")
            let engine = AVAudioEngine()
            engine.attach(node)
            #expect(node.engine === engine)
            engine.detach(node)
        }
        #expect(ztd_sink_node_create(nil, true) == nil && ztd_sink_node_receiver(nil, true) == nil)
    }

    /// The node holds the tap for as long as it lives: the source may let go of its own hold
    /// first, or last.
    @Test func aNodeKeepsItsTapAlive() throws {
        let ring = try #require(TestRing(channels: 2, capacity: 1_024))
        var node: AVAudioSinkNode?
        var raw: OpaquePointer?
        do {
            let tap = try #require(TestTap())
            ztd_sink_tap_set_ring(tap.tap, ring.ring)
            // Without a node nothing would hold the tap once the test lets go of it.
            let made: AVAudioSinkNode = try #require(ztd_sink_node_create(tap.tap, true) as AVAudioSinkNode?)
            node = made
            raw = tap.tap
        }
        // The test's hold is gone; the node's is what keeps the tap.
        let tap = try #require(raw)
        withExtendedLifetime(node) {
            let buffers = SyntheticBufferList(planar: [left, right])
            #expect(buffers.withPointer { ztd_sink_tap_receive(tap, $0, 480) } == 0)
            #expect(ring.available == 480 && ztd_sink_tap_written_frames(tap) == 480)
            #expect(ztd_sink_tap_set_ring(tap, nil))
        }
        node = nil
        ztd_sink_tap_retain(nil)
        ztd_sink_tap_release(nil)
    }

    /// A tap that cannot be had is none, and nothing is left behind.
    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func aRefusedTapIsNone() throws {
        let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        let symbol = try #require(dlsym(anyImage, "ztd_fail_allocation"), "the seam of ztd_internal.h is not in the image")
        let fail = unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)
        fail(0)
        defer { fail(-1) }
        var tap: OpaquePointer?
        let counts = try countAllocations { tap = ztd_sink_tap_create() }
        #expect(tap == nil && counts.allocations == counts.deallocations)
        #expect(ztd_sink_tap_written_frames(nil) == 0 && ztd_sink_tap_discarded_frames(nil) == 0)
    }
}
