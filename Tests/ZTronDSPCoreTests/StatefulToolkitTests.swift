import Foundation
import Testing
import ZTronDSPCore
import ZTronDSPTesting

@Suite("HistoryBuffer (WP-118)")
struct HistoryBufferTests {
    /// The reference: everything appended so far, with `count` zeros before it.
    private func reference(_ appended: [Float], count: Int) -> [Float] {
        Array(([Float](repeating: 0, count: count) + appended).suffix(count))
    }

    @Test(arguments: [1, 2, 7, 64, 1_000])
    func windowMatchesTheReferenceForIrregularPushes(count: Int) throws {
        let history = try HistoryBuffer(count: count)
        let signal = TestSignal.whiteNoise(count: 6_000, seed: UInt64(count))
        var generator = SeededGenerator(seed: 118)
        var appended: [Float] = []
        #expect(Array(UnsafeBufferPointer(start: history.window, count: count)) == reference([], count: count), "zeros before the first sample")
        #expect(!history.isFull && history.totalAppended == 0)
        var position = 0
        while position < signal.count {
            // Batches of 0 … 2·count + 3 samples: shorter than, equal to and longer than the window.
            let batch = min(Int(generator.next() % UInt64(2 * count + 4)), signal.count - position)
            signal.withUnsafeBufferPointer { history.append($0.baseAddress! + position, count: batch) }
            appended.append(contentsOf: signal[position ..< position + batch])
            position += batch
            #expect(Array(UnsafeBufferPointer(start: history.window, count: count)) == reference(appended, count: count))
            #expect(history.totalAppended == appended.count)
            #expect(history.isFull == (appended.count >= count))
        }
    }

    @Test func singleSamplesAndTheLatestPart() throws {
        let history = try HistoryBuffer(count: 4)
        for value in 1 ... 6 { history.append(Float(value)) }
        #expect(Array(UnsafeBufferPointer(start: history.window, count: 4)) == [3, 4, 5, 6])
        #expect(Array(UnsafeBufferPointer(start: history.latest(2), count: 2)) == [5, 6])
        #expect(Array(UnsafeBufferPointer(start: history.latest(99), count: 4)) == [3, 4, 5, 6], "at most the whole window")
        #expect(history.latest(0) == history.window + 4)
        #expect(history.count == 4 && history.isFull && history.totalAppended == 6)
        history.append([7], count: 0)
        history.append([7], count: -1)
        #expect(history.totalAppended == 6, "an empty batch changes nothing")
        history.reset()
        #expect(Array(UnsafeBufferPointer(start: history.window, count: 4)) == [0, 0, 0, 0] && history.totalAppended == 0 && !history.isFull)
    }

    @Test func theWindowIsContiguousAndCopiesNothing() throws {
        let history = try HistoryBuffer(count: 512)
        let block = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: 384, seed: 3))
        var sum: Float = 0
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                history.append(UnsafePointer(block.baseAddress), count: 384)
                history.append(0.5)
                sum += history.window[511] + history.latest(16)[0]
                round += 1
            }
        }
        #expect(sum.isFinite)
    }

    @Test func aHistoryNeedsAtLeastOneSample() {
        #expect(throws: DSPError.self) { try HistoryBuffer(count: 0) }
        #expect(throws: DSPError.self) { try HistoryBuffer(count: -3) }
    }
}

@Suite("OverlapAdder (WP-118)")
struct OverlapAdderTests {
    /// Overlap-add from the definition: Σ frame·w over Σ w², sample by sample.
    private func reference(frames: [[Float]], window: [Float], hop: Int, floor: Float) -> [Float] {
        let size = window.count
        let length = (frames.count - 1) * hop + size
        var sum = [Double](repeating: 0, count: length), norm = [Double](repeating: 0, count: length)
        for (index, frame) in frames.enumerated() {
            for n in 0 ..< size {
                sum[index * hop + n] += Double(frame[n]) * Double(window[n])
                norm[index * hop + n] += Double(window[n]) * Double(window[n])
            }
        }
        return (0 ..< length).map { norm[$0] > Double(floor) ? Float(sum[$0] / norm[$0]) : 0 }
    }

    private func hann(_ size: Int) -> [Float] {
        (0 ..< size).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(size))) }
    }

    @Test(arguments: [(64, 16), (64, 32), (48, 12), (17, 5), (8, 8), (9, 1)])
    func overlapAddMatchesTheReference(size: Int, hop: Int) throws {
        let window = hann(size)
        let adder = try OverlapAdder(frameSize: size, hopSize: hop, window: window)
        let frames = (0 ..< 40).map { TestSignal.whiteNoise(count: size, seed: UInt64($0 + 1)) }
        var output: [Float] = []
        var chunk = [Float](repeating: 0, count: size)
        for frame in frames {
            frame.withUnsafeBufferPointer { input in chunk.withUnsafeMutableBufferPointer { adder.add(input.baseAddress!, into: $0.baseAddress!) } }
            output.append(contentsOf: chunk.prefix(hop))
        }
        chunk.withUnsafeMutableBufferPointer { adder.flush(into: $0.baseAddress!) }
        output.append(contentsOf: chunk.prefix(size - hop))
        expectClose(output, reference(frames: frames, window: window, hop: hop, floor: adder.floor), .absolute(2e-5))
        #expect(adder.frameSize == size && adder.hopSize == hop)
    }

    @Test func aWindowedSignalComesBackExactly() throws {
        // Analysis and synthesis with the same window: Σ (x·w)·w / Σ w² = x wherever Σ w² > 0.
        let size = 256, hop = 64
        let window = hann(size)
        let signal = TestSignal.whiteNoise(count: hop * 60, seed: 77)
        let adder = try OverlapAdder(frameSize: size, hopSize: hop, window: window)
        var output: [Float] = []
        var chunk = [Float](repeating: 0, count: size)
        var start = 0
        while start + size <= signal.count {
            let frame = (0 ..< size).map { signal[start + $0] * window[$0] }
            frame.withUnsafeBufferPointer { input in chunk.withUnsafeMutableBufferPointer { adder.add(input.baseAddress!, into: $0.baseAddress!) } }
            output.append(contentsOf: chunk.prefix(hop))
            start += hop
        }
        // Past the first frame every sample is covered by four frames.
        let covered = size ..< output.count
        expectClose(Array(output[covered]), Array(signal[covered]), .deviationBelow(decibels: -100))
        #expect(output[0] == 0, "the Hann window is zero at its first sample: nothing to divide by, so zero (NUM-1)")
    }

    @Test func resetReturnsToSilence() throws {
        let adder = try OverlapAdder(frameSize: 8, hopSize: 4, window: [Float](repeating: 1, count: 8))
        var output = [Float](repeating: 9, count: 8)
        let ones = [Float](repeating: 1, count: 8)
        ones.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { adder.add(input.baseAddress!, into: $0.baseAddress!) } }
        #expect(Array(output.prefix(4)) == [1, 1, 1, 1])
        adder.reset()
        output.withUnsafeMutableBufferPointer { adder.flush(into: $0.baseAddress!) }
        #expect(Array(output.prefix(4)) == [0, 0, 0, 0], "nothing is held after a reset")
    }

    @Test func sizesThatDoNotFitAreTypedErrors() {
        let window = [Float](repeating: 1, count: 8)
        #expect(throws: DSPError.self) { try OverlapAdder(frameSize: 8, hopSize: 0, window: window) }
        #expect(throws: DSPError.self) { try OverlapAdder(frameSize: 8, hopSize: 9, window: window) }
        #expect(throws: DSPError.self) { try OverlapAdder(frameSize: 0, hopSize: 1, window: []) }
        #expect(throws: DSPError.self) { try OverlapAdder(frameSize: 8, hopSize: 4, window: [1, 2, 3]) }
    }

    @Test func addingIsAllocationFree() throws {
        let size = 2_048, hop = 512
        let adder = try OverlapAdder(frameSize: size, hopSize: hop, window: hann(size))
        let frame = try AlignedBuffer<Float>(copying: TestSignal.whiteNoise(count: size, seed: 1))
        let output = try AlignedBuffer<Float>(count: size)
        expectNoAllocations {
            var round = 0
            while round < 1_000 {
                adder.add(UnsafePointer(frame.baseAddress), into: output.baseAddress)
                round += 1
            }
            adder.reset()
        }
    }
}

@Suite("Ramp and state hygiene (WP-119)")
struct RampTests {
    @Test func aRampReachesItsTargetExactly() {
        for (start, target, duration) in [(Float(0), Float(1), 480), (1, 0.1, 7), (-0.3, 0.7, 1), (0.1, 0.3, 441), (1, 1e-7, 1_000)] {
            var ramp = Ramp(value: start, duration: duration)
            ramp.setTarget(target)
            #expect(ramp.isMoving && ramp.remainingFrames == duration && ramp.target == target && ramp.value == start)
            var last = start
            for frame in 1 ... duration {
                let value = ramp.next()
                if frame < duration {
                    #expect(target > start ? value > last : value < last, "monotonic towards the target")
                }
                last = value
            }
            #expect(last == target, "the last step lands on the target itself, not on an accumulated sum")
            #expect(!ramp.isMoving && ramp.value == target && ramp.remainingFrames == 0)
            #expect(ramp.next() == target, "and it stays there")
        }
    }

    @Test func theRampIsLinear() {
        var ramp = Ramp(value: 0, duration: 4)
        ramp.setTarget(1)
        #expect([ramp.next(), ramp.next(), ramp.next(), ramp.next(), ramp.next()] == [0.25, 0.5, 0.75, 1, 1])
    }

    @Test func aTargetCanChangeMidRamp() {
        var ramp = Ramp(value: 0, duration: 10)
        ramp.setTarget(1)
        for _ in 0 ..< 5 { _ = ramp.next() }
        expectClose(ramp.value, 0.5, .absolute(1e-6))
        ramp.setTarget(0)
        #expect(ramp.remainingFrames == 10, "a new move starts from the current value and takes the full duration")
        for _ in 0 ..< 10 { _ = ramp.next() }
        #expect(ramp.value == 0)
    }

    @Test func jumpsAndZeroDurations() {
        var instant = Ramp(value: 0.5, duration: 0)
        instant.setTarget(2)
        #expect(instant.value == 2 && !instant.isMoving, "a duration below one frame jumps")
        #expect(Ramp(value: 1, duration: -5).duration == 0)
        var ramp = Ramp(value: 0, duration: 100)
        ramp.setTarget(1)
        ramp.jump(to: 0.25)
        #expect(ramp.value == 0.25 && ramp.target == 0.25 && !ramp.isMoving)
        ramp.setTarget(0.25)
        #expect(!ramp.isMoving, "a target equal to the value starts nothing")
    }

    @Test func blockwiseAdvanceEqualsSampleBySample() {
        for blocks in [[64, 64, 64, 64, 64, 64, 64, 64], [1, 7, 480, 3, 100], [512], [100, 500]] {
            var perSample = Ramp(value: 0.2, duration: 480)
            var perBlock = perSample
            perSample.setTarget(0.9)
            perBlock.setTarget(0.9)
            for block in blocks {
                var expected: [Float] = []
                for _ in 0 ..< block { expected.append(perSample.next()) }
                let segment = perBlock.advance(by: block)
                var rendered = [Float](repeating: perBlock.value, count: block)
                for frame in 0 ..< segment.movingFrames { rendered[frame] = segment.start + Float(frame) * segment.increment }
                if segment.movingFrames > 0, segment.movingFrames < block || !perBlock.isMoving {
                    // The frame that completes the move holds the target exactly.
                    rendered[segment.movingFrames - 1] = perBlock.isMoving ? rendered[segment.movingFrames - 1] : perBlock.target
                }
                expectClose(rendered, expected, .absolute(2e-6))
                #expect(perBlock.value == perSample.value || abs(perBlock.value - perSample.value) < 2e-6)
                #expect(perBlock.remainingFrames == perSample.remainingFrames)
            }
            #expect(perBlock.value == 0.9, "the block-wise ramp also lands on its target exactly")
        }
        var still = Ramp(value: 1, duration: 10)
        let segment = still.advance(by: 64)
        #expect(segment.movingFrames == 0 && segment.increment == 0 && segment.start == 1)
        #expect(still.advance(by: 0).movingFrames == 0)
    }

    @Test func renderWritesTheCurve() {
        var ramp = Ramp(value: 0, duration: 4)
        ramp.setTarget(2)
        var values = [Float](repeating: -1, count: 6)
        values.withUnsafeMutableBufferPointer { ramp.render(into: $0.baseAddress!, count: 6) }
        #expect(values == [0.5, 1, 1.5, 2, 2, 2])
    }

    @Test func aStateValueBelowTenToTheMinusTwentyBecomesZero() {
        var single: [Float] = [1, 1e-19, 9.9e-21, -9.9e-21, 1e-30, -1e-38, .leastNonzeroMagnitude, 0, -1e-19, -2]
        single.withUnsafeMutableBufferPointer { flushSmallState($0.baseAddress!, count: $0.count) }
        #expect(single == [1, 1e-19, 0, 0, 0, 0, 0, 0, -1e-19, -2])
        #expect(!single.contains { $0.isSubnormal })

        var double: [Double] = [1, 1e-19, 9.9e-21, -9.9e-21, 1e-300, .leastNonzeroMagnitude, -3]
        double.withUnsafeMutableBufferPointer { flushSmallState($0.baseAddress!, count: $0.count) }
        #expect(double == [1, 1e-19, 0, 0, 0, 0, -3])

        var custom: [Float] = [0.5, 0.05]
        custom.withUnsafeMutableBufferPointer { flushSmallState($0.baseAddress!, count: 2, threshold: 0.1) }
        #expect(custom == [0.5, 0])
        var untouched: [Float] = [1e-30]
        untouched.withUnsafeMutableBufferPointer { flushSmallState($0.baseAddress!, count: 0) }
        #expect(untouched == [1e-30], "a count of zero touches nothing")
    }

    @Test func aDecayingTailReachesExactZeroOnceItFallsBelowTheThreshold() {
        // A one-pole decay, flushed at the end of each block as a kernel does (RT-6).
        var state: Float = 1
        var blocksBelow = 0
        var reachedZero = false
        for _ in 0 ..< 400 {
            for _ in 0 ..< 64 { state *= 0.9 }
            if abs(state) < 1e-20 && state != 0 { blocksBelow += 1 }
            withUnsafeMutablePointer(to: &state) { flushSmallState($0, count: 1) }
            if state == 0 { reachedZero = true; break }
            #expect(!state.isSubnormal, "no denormal state is left behind")
        }
        #expect(reachedZero)
        #expect(blocksBelow <= 1, "zero within one block of falling below the threshold")
    }

    @Test func rampAndFlushAreAllocationFree() throws {
        let state = try AlignedBuffer<Float>(count: 64)
        let curve = try AlignedBuffer<Float>(count: 512)
        expectNoAllocations {
            var ramp = Ramp(value: 0, duration: 480)
            var round = 0
            while round < 1_000 {
                ramp.setTarget(round % 2 == 0 ? 1 : 0)
                ramp.render(into: curve.baseAddress, count: 256)
                _ = ramp.advance(by: 256)
                _ = ramp.next()
                flushSmallState(state.baseAddress, count: 64)
                round += 1
            }
        }
    }
}

@Suite("ParameterVector (WP-121)")
struct ParameterVectorTests {
    private let a = ParameterVector([1, 2, 3]), b = ParameterVector([0.5, -1, 4]), c = ParameterVector([-2, 0, 1])

    @Test func vectorSpaceIdentities() {
        #expect(a + b == b + a)
        #expect((a + b) + c == a + (b + c))
        #expect(a + ParameterVector([0, 0, 0]) == a)
        #expect(a - a == ParameterVector([0, 0, 0]))
        #expect((a + b) - b == a)
        #expect(a.scaled(by: 2) == a + a)
        #expect((a + b).scaled(by: 3) == a.scaled(by: 3) + b.scaled(by: 3))
        #expect(a.scaled(by: 1) == a && a.scaled(by: 0) == ParameterVector([0, 0, 0]))
        #expect(a.scaled(by: 2).scaled(by: 0.5) == a)
        #expect(a.magnitudeSquared == 14 && ParameterVector.zero.magnitudeSquared == 0)
        #expect(a.count == 3 && !a.isEmpty && ParameterVector.zero.isEmpty && ParameterVector().values.isEmpty)
        #expect(a.appending(b).values == [1, 2, 3, 0.5, -1, 4])
        #expect(ParameterVector.zero + ParameterVector.zero == .zero)
    }

    @Test func interpolationBetweenEqualLengthsIsLinear() {
        let from = ParameterVector([0, 10]), to = ParameterVector([1, 20])
        for t in [0.0, 0.25, 0.5, 1.0] {
            #expect(from + (to - from).scaled(by: t) == ParameterVector([t, 10 + 10 * t]))
        }
    }

    /// ANI-4: a change of topology is not interpolated; it is applied at once.
    @Test func vectorsOfUnequalLengthAreNotInterpolated() {
        let from = ParameterVector([1, 2, 3]), to = ParameterVector([7, 8])
        let difference = to - from
        #expect(difference.isReplacement && difference.values == [7, 8])
        for t in [0.0, 0.01, 0.5, 0.99, 1.0] {
            let interpolated = from + difference.scaled(by: t)
            #expect(interpolated == to, "t = \(t): the target at once")
            #expect(!interpolated.isReplacement)
        }
        #expect(from - to == ParameterVector(replacement: [1, 2, 3]))
        #expect((to - from) + from == to, "addition commutes with a replacement")
        #expect(((to - from) - from).isReplacement, "a replacement stays one through further differences")
        #expect(from + to == to, "a plain sum of unequal lengths takes the right-hand side")
        #expect(ParameterVector.zero + a == a && a - ParameterVector.zero == ParameterVector(replacement: [1, 2, 3]))
        #expect(ParameterVector([7, 8]) != ParameterVector(replacement: [7, 8]))
        #expect(!a.isReplacement)
    }
}
