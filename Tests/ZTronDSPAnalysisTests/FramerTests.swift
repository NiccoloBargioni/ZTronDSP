import Foundation
import Testing
@testable import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPTesting

/// The framer (WP-503): frames of a stream that arrives in batches of any size are the frames
/// of the whole signal, and on the mirrored ring they are views.
@Suite("Framer")
struct FramerTests {
    /// Frame `k` of `signal` by its definition, with the time index it is aligned to.
    private func reference(_ signal: [Float], frame: Int, hop: Int, alignment: FrameAlignment) -> [(samples: [Float], position: Int)] {
        var extended = signal
        var lead = 0
        if alignment == .centered {
            lead = frame / 2
            guard signal.count > lead else { return [] }
            // x[−n] = x[n]: the edge sample is not repeated (§6.1).
            extended = (1 ... max(lead, 1)).prefix(lead).reversed().map { signal[$0] } + signal
        }
        var frames: [(samples: [Float], position: Int)] = []
        var start = 0
        while start + frame <= extended.count {
            frames.append((Array(extended[start ..< start + frame]), alignment == .centered ? start : start + frame - 1))
            start += hop
        }
        return frames
    }

    private func collect(_ framer: Framer, _ signal: [Float], batches: [Int]) -> [(samples: [Float], position: Int)] {
        var frames: [(samples: [Float], position: Int)] = []
        var offset = 0
        var batch = 0
        signal.withUnsafeBufferPointer { buffer in
            while offset < signal.count {
                let count = min(batches[batch % batches.count], signal.count - offset)
                batch += 1
                var taken = 0
                while taken < count {
                    taken += framer.append(buffer.baseAddress! + offset + taken, count: count - taken)
                    while let view = framer.frame {
                        frames.append((Array(UnsafeBufferPointer(start: view, count: framer.frameSize)), framer.framePosition))
                        framer.advance()
                    }
                }
                offset += count
            }
        }
        return frames
    }

    @Test(arguments: [(64, 16), (64, 64), (100, 37), (1, 1), (7, 3), (4_096, 1_024), (4_097, 512)])
    func framesEqualOfflineSlicingForIrregularBatches(frame: Int, hop: Int) throws {
        let signal = TestSignal.whiteNoise(count: 3 * frame + 4 * hop + 11, seed: UInt64(frame + hop))
        for alignment in [FrameAlignment.causal, .centered] {
            let expected = reference(signal, frame: frame, hop: hop, alignment: alignment)
            for batches in [[1], [7, 1, 300, 2], [512], [signal.count], [5_000, 3]] {
                let frames = collect(try Framer(frameSize: frame, hopSize: hop, alignment: alignment), signal, batches: batches)
                #expect(frames.count == expected.count, "\(alignment), batches \(batches): \(frames.count) frames, \(expected.count) expected")
                #expect(frames.map { $0.samples } == expected.map { $0.samples }, "\(alignment), batches \(batches): bit for bit")
                #expect(frames.map { $0.position } == expected.map { $0.position }, "\(alignment): each frame knows the sample it is aligned to")
            }
        }
    }

    @Test func aCentredFrameIsCentredOnItsSample() throws {
        let signal = (0 ..< 400).map { Float($0) }
        let frames = collect(try Framer(frameSize: 64, hopSize: 16, alignment: .centered), signal, batches: [50])
        #expect(frames[0].position == 0 && frames[0].samples[32] == 0, "frame 0 is centred on sample 0")
        #expect(Array(frames[0].samples[..<32]) == (1 ... 32).reversed().map { Float($0) }, "its first half is the reflection, the edge sample not repeated")
        #expect(frames[5].position == 80 && frames[5].samples[32] == 80, "frame k is centred on sample k·hop")
        // The first frame exists once the sample its reflection ends on has arrived.
        let framer = try Framer(frameSize: 64, hopSize: 16, alignment: .centered)
        #expect(framer.append(signal, count: 32) == 32 && framer.frame == nil)
        #expect(framer.append(Array(signal[32...]), count: 1) == 1 && framer.frame != nil)
    }

    @Test func onTheMirroredRingAFrameIsAViewAndNothingIsCopiedPerHop() throws {
        let framer = try Framer(frameSize: 1_024, hopSize: 256)
        #expect(framer.isMirrored, "the simulator grants the mirror (§13.1)")
        let signal = TestSignal.whiteNoise(count: 60_000, seed: 2)
        var pointers: [UnsafePointer<Float>] = []
        var offset = 0
        signal.withUnsafeBufferPointer { buffer in
            while offset < signal.count {
                offset += framer.append(buffer.baseAddress! + offset, count: min(700, signal.count - offset))
                while let view = framer.frame {
                    pointers.append(view)
                    framer.advance()
                }
            }
        }
        #expect(pointers.count == (60_000 - 1_024) / 256 + 1)
        // Consecutive frames are one hop apart in the same storage, or wrap by its capacity: a
        // frame is where the samples already are, never a scratch buffer they were copied to.
        let steps = zip(pointers, pointers.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 == 256 || $0 == 256 - framer.capacity }, "steps between frames: \(Set(steps))")
        #expect(steps.contains(256 - framer.capacity), "the stream wrapped, and the frame across the wrap was still one view")
        #expect(Set(pointers).count > 1)
    }

    @Test func theFallBackGivesTheSameFrames() throws {
        let signal = TestSignal.whiteNoise(count: 20_000, seed: 8)
        for alignment in [FrameAlignment.causal, .centered] {
            let mirrored = try Framer(frameSize: 480, hopSize: 113, alignment: alignment, mirrored: true)
            let plain = try Framer(frameSize: 480, hopSize: 113, alignment: alignment, mirrored: false)
            #expect(mirrored.isMirrored && !plain.isMirrored)
            let a = collect(mirrored, signal, batches: [300, 17, 4_000]), b = collect(plain, signal, batches: [300, 17, 4_000])
            #expect(a.map { $0.samples } == b.map { $0.samples } && a.map { $0.position } == b.map { $0.position })
            #expect(a.count == reference(signal, frame: 480, hop: 113, alignment: alignment).count)
        }
    }

    @Test func aFullFramerTakesNoMoreUntilItsFramesAreRead() throws {
        let framer = try Framer(frameSize: 16, hopSize: 4, alignment: .causal, mirrored: false)
        let signal = TestSignal.whiteNoise(count: 200, seed: 1)
        #expect(framer.capacity == 32)
        #expect(framer.append(signal, count: 200) == 32, "it takes what it has room for")
        #expect(framer.append(signal, count: 200) == 0)
        framer.advance()
        #expect(framer.append(signal, count: 200) == 4, "one hop of room per frame read")
        #expect(framer.append(signal, count: 0) == 0 && framer.append(signal, count: -3) == 0)
    }

    @Test func resetIsAColdStart() throws {
        let signal = TestSignal.whiteNoise(count: 1_000, seed: 6)
        for alignment in [FrameAlignment.causal, .centered] {
            let framer = try Framer(frameSize: 128, hopSize: 32, alignment: alignment)
            let first = collect(framer, signal, batches: [77])
            #expect(framer.frameIndex == first.count)
            framer.reset()
            #expect(framer.frame == nil && framer.frameIndex == 0)
            let second = collect(framer, signal, batches: [300])
            #expect(first.map { $0.samples } == second.map { $0.samples } && first.map { $0.position } == second.map { $0.position })
        }
    }

    @Test func sizesThatDoNotFitAreTypedErrors() {
        #expect(throws: DSPError.self) { _ = try Framer(frameSize: 0, hopSize: 1) }
        #expect(throws: DSPError.self) { _ = try Framer(frameSize: 16, hopSize: 0) }
        #expect(throws: DSPError.self) { _ = try Framer(frameSize: 16, hopSize: 17) }
        #expect(throws: Never.self) { _ = try Framer(frameSize: 16, hopSize: 16) }
    }

    @Test func framingDoesNotAllocate() throws {
        for alignment in [FrameAlignment.causal, .centered] {
            for mirrored in [true, false] {
                let framer = try Framer(frameSize: 2_048, hopSize: 512, alignment: alignment, mirrored: mirrored)
                let block = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 480, seed: 3))
                var frames = 0
                var checksum: Float = 0
                _ = expectNoAllocations {
                    var pass = 0
                    while pass < 1_000 {
                        var offset = 0
                        while offset < 480 {
                            offset += framer.append(block.baseAddress + offset, count: 480 - offset)
                            while let view = framer.frame {
                                checksum += view[0]
                                frames += 1
                                framer.advance()
                            }
                        }
                        pass += 1
                    }
                }
                #expect(frames > 900 && checksum.isFinite)
            }
        }
    }
}
