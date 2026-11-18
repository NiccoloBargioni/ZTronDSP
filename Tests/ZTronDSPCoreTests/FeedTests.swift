import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Feeds, streams and callbacks (WP-321b, WP-333, WP-334, WP-335, WP-341).
@Suite("Feeds")
struct FeedTests {
    let format = SignalFormat(sampleRate: 48_000)
    let signal = TestSignal.whiteNoise(count: 64 * 40, seed: 5)

    private func spectra(_ feed: HeatmapFeed, frame: Int = 64, hop: Int = 32) -> Pipeline<Samples, Samples> {
        Pipeline().tap { $0.testFramer(frame: frame, hop: hop).testMagnitude().emit(to: feed) }
    }

    /// Writes columns to a feed directly, as the plan does.
    private func attached(_ feed: HeatmapFeed, rows: Int) throws {
        try feed.claim(axis: .indices(count: rows), environment: DSPEnvironment(), domain: .chroma, format: .real(count: rows))
    }

    private func write(_ feed: HeatmapFeed, _ value: Float, rows: Int, time: Double = 0) {
        let column = [Float](repeating: value, count: rows)
        column.withUnsafeBufferPointer { feed.write(FrameView(real: $0, index: Int(value), time: time)) }
    }

    // MARK: HeatmapFeed (WP-333)

    @Test func aFeedReportsItsAxisEnvironmentAndColumns() async throws {
        let feed = HeatmapFeed(history: 16)
        #expect(feed.rowCount == 0 && feed.columnCount == 0 && feed.axis == nil && !feed.isLive && feed.history == 16)
        let expected = try Pipeline().testFramer(frame: 64, hop: 32).testMagnitude().process(signal, format: format, blockSize: 64)
        try spectra(feed).run(on: signal, format: format, blockSize: 64)
        #expect(feed.rowCount == 33 && feed.axis == .linearFrequency(binCount: 33, nyquist: 24_000))
        #expect(feed.environment?.hopSize == 32 && feed.environment?.featureRate == 1_500, "the environment at the Emit (ENV-4)")
        let snapshot = feed.snapshot()
        #expect(snapshot.columnCount == 16 && feed.columnCount == 16, "the newest 16 of \(expected.count) columns")
        #expect(snapshot.content == .heatmap && snapshot.rowCount == 33 && snapshot.axis == feed.axis)
        for (index, column) in expected.suffix(16).enumerated() { #expect(Array(snapshot.column(index)) == column) }
        #expect(zip(snapshot.times, snapshot.times.dropFirst()).allSatisfy { abs($1 - $0 - 32.0 / 48_000) < 1e-12 }, "one hop between columns")
        #expect(snapshot.row(0).count == 16 && snapshot.column(99).isEmpty && snapshot.minima.isEmpty)
    }

    @Test func aReaderTakesWhatArrivedSinceItLastLooked() throws {
        let feed = HeatmapFeed(history: 8)
        try attached(feed, rows: 3)
        var cursor = FeedCursor()
        var values = [Float](repeating: -1, count: 3 * 8), times = [Double](repeating: -1, count: 8)
        func read() -> (FeedRead, [Float]) {
            values.withUnsafeMutableBufferPointer { buffer in
                times.withUnsafeMutableBufferPointer { stamps in
                    let result = feed.read(&cursor, into: buffer, times: stamps)
                    return (result, stride(from: 0, to: result.columnCount * 3, by: 3).map { buffer[$0] })
                }
            }
        }
        let generation = feed.generation
        var (result, firsts) = read()
        #expect(result.isReset && result.columnCount == 0 && result.rowCount == 3 && result.history == 8, "a fresh cursor starts over")
        for value in 1 ... 5 { write(feed, Float(value), rows: 3, time: Double(value)) }
        #expect(feed.generation == generation + 5, "the generation moves with every column: one atomic load tells a view whether to look")
        (result, firsts) = read()
        #expect(!result.isReset && firsts == [1, 2, 3, 4, 5] && result.firstColumn == 0 && result.skipped == 0)
        #expect(Array(times.prefix(5)) == [1, 2, 3, 4, 5])
        (result, firsts) = read()
        #expect(result.columnCount == 0, "nothing new: nothing copied")
        for value in 6 ... 20 { write(feed, Float(value), rows: 3) }
        (result, firsts) = read()
        #expect(firsts == Array(13 ... 20).map(Float.init) && result.skipped == 7 && result.firstColumn == 12,
                "a reader that lags by more than the history skips; it never blocks the writer")

        // A buffer too small takes the oldest that fit.
        for value in 21 ... 24 { write(feed, Float(value), rows: 3) }
        var small = [Float](repeating: 0, count: 6)
        let partial = small.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
        #expect(partial.columnCount == 2 && small[0] == 21 && small[3] == 22)
        (result, firsts) = read()
        #expect(firsts == [23, 24])

        // A cleared feed tells its readers.
        feed.clearForNewBranch()
        write(feed, 99, rows: 3)
        (result, firsts) = read()
        #expect(result.isReset && firsts == [99], "what the reader held is void (SWAP-3)")
        #expect(feed.columnCount == 1 && feed.snapshot().columnCount == 1)
    }

    @Test func aFeedOfAnotherShapeStartsOver() throws {
        let feed = HeatmapFeed(history: 4)
        try attached(feed, rows: 3)
        write(feed, 1, rows: 3)
        var cursor = FeedCursor()
        var values = [Float](repeating: 0, count: 64)
        _ = values.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
        try attached(feed, rows: 3)
        write(feed, 2, rows: 3)
        var result = values.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
        #expect(!result.isReset && result.columnCount == 1, "attached again to the same shape, the history goes on")
        try attached(feed, rows: 5)
        write(feed, 3, rows: 5)
        result = values.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
        #expect(result.isReset && result.rowCount == 5 && result.columnCount == 1 && values[4] == 3, "another shape: a new texture (V-6)")
        #expect(throws: DSPError.self) { try feed.claim(axis: nil, environment: DSPEnvironment(), domain: .samples, format: .scalar) }
    }

    @Test func readersNeverSeeATornColumn() async throws {
        // Writer / reader stress: every column a reader gets is one the writer finished. The
        // writer starts once every reader has read, and stops once each of them has taken its
        // fill beside it: the two sides overlap whatever else the machine is doing.
        let feed = HeatmapFeed(history: 32)
        let rows = 64, readers = 3, fill = 20_000
        try attached(feed, rows: rows)
        let ready = Locked(0), done = Locked(0), finished = Locked(false)
        let writer = Thread {
            while ready.get() < readers { usleep(100) }
            var value: Float = 1
            let column = UnsafeMutableBufferPointer<Float>.allocate(capacity: rows)
            // A Float counts exactly up to 2²⁴: the writer stops there at the latest.
            while value < 16_000_000 {
                if Int(value) % 256 == 0, done.get() >= readers { break }
                column.update(repeating: value)
                feed.write(FrameView(real: UnsafeBufferPointer(column), index: Int(value), time: Double(value)))
                value += 1
            }
            column.deallocate()
            finished.set(true)
        }
        writer.start()
        let outcome = await withTaskGroup(of: (torn: Int, beside: Int, order: Bool).self) { group in
            for _ in 0 ..< readers {
                group.addTask {
                    var cursor = FeedCursor()
                    var values = [Float](repeating: 0, count: rows * 32), times = [Double](repeating: 0, count: 32)
                    var torn = 0, beside = 0, last: Float = 0, ordered = true, announced = false
                    while beside < fill, !finished.get() {
                        let result = values.withUnsafeMutableBufferPointer { buffer in
                            times.withUnsafeMutableBufferPointer { feed.read(&cursor, into: buffer, times: $0) }
                        }
                        if !announced {
                            announced = true
                            ready.withLock { $0 += 1 }
                        }
                        for column in 0 ..< result.columnCount {
                            let first = values[column * rows]
                            if values[(column * rows) ..< ((column + 1) * rows)].contains(where: { $0 != first }) || times[column] != Double(first) { torn += 1 }
                            if first <= last { ordered = false }
                            last = first
                        }
                        beside += result.columnCount
                        if Int.random(in: 0 ..< 4) == 0 {
                            let snapshot = feed.snapshot()
                            for column in 0 ..< snapshot.columnCount where Set(snapshot.column(column)).count != 1 { torn += 1 }
                            if zip(snapshot.times, snapshot.times.dropFirst()).contains(where: { $1 != $0 + 1 }) { torn += 1 }
                        }
                    }
                    done.withLock { $0 += 1 }
                    return (torn, beside, ordered)
                }
            }
            var all: [(torn: Int, beside: Int, order: Bool)] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(outcome.allSatisfy { $0.torn == 0 }, "no torn column and no torn snapshot under a concurrent writer: \(outcome.map(\.torn))")
        #expect(outcome.allSatisfy { $0.order }, "columns arrive in order")
        #expect(outcome.allSatisfy { $0.beside >= fill }, "every reader read beside the writer: \(outcome.map(\.beside)) columns")
    }

    @Test func writingAFeedAllocatesNothing() throws {
        let feed = HeatmapFeed(history: 64)
        try attached(feed, rows: 128)
        let column = [Float](repeating: 0.5, count: 128)
        column.withUnsafeBufferPointer { buffer in
            let frame = FrameView(real: buffer, index: 0, time: 0)
            expectNoAllocations {
                var count = 0
                while count < 1_000 {
                    feed.write(frame)
                    if count % 100 == 0 { feed.clearForNewBranch() }
                    count += 1
                }
            }
        }
    }

    @Test func aFeedIsLiveWhileItsSessionRunsAndItsBranchIsOn() async throws {
        let rig = Rig()
        let feed = HeatmapFeed(history: 8)
        let shown = StateBox(true)
        let changes = Locked<[Bool]>([])
        let observation = feed.onLivenessChange { live in changes.withLock { $0.append(live) } }
        let session = try await rig.engine.attach(
            Pipeline().tap(isActive: shown.binding) { $0.testFramer(frame: 64, hop: 64).testMagnitude().emit(to: feed) }, to: rig.source)
        #expect(!feed.isLive, "attached and idle: not live")
        try session.start()
        #expect(feed.isLive)
        rig.feed(Array(signal[..<256]))
        #expect(feed.columnCount == 4)
        shown.value = false
        await MainActor.run { session.syncBindings() }
        #expect(!feed.isLive, "a suspended branch: the feed keeps its contents and is no longer live (ACT-11)")
        rig.feed(Array(signal[256 ..< 512]))
        #expect(feed.columnCount == 4, "sinks in a suspended branch receive nothing")
        shown.value = true
        await MainActor.run { session.syncBindings() }
        #expect(feed.isLive)
        session.stop()
        #expect(!feed.isLive)
        #expect(await eventually { changes.get() == [true, false, true, false] }, "a view is told on the main thread, not by the analysis thread")
        observation.cancel()
        try session.start()
        session.detach()
        await rig.drain()
        #expect(changes.get().count == 4, "a cancelled observation hears nothing more")
    }

    @Test func memoryPressureTrimsOnlyFeedsThatDeclaredASmallerMinimum() async throws {
        let rig = Rig()
        let elastic = HeatmapFeed(history: 16, minimumHistory: 4), rigid = HeatmapFeed(history: 16)
        #expect(elastic.minimumHistory == 4 && rigid.minimumHistory == 16)
        let session = try await rig.engine.attach(
            Pipeline().tap { $0.testFramer(frame: 64, hop: 64).testMagnitude().emit(to: elastic).emit(to: rigid) }, to: rig.source)
        let log = EventLog(session)
        try session.start()
        rig.feed(Array(signal[..<(64 * 12)]))
        let before = elastic.snapshot()
        var cursor = FeedCursor()
        var values = [Float](repeating: 0, count: 33 * 16)
        _ = values.withUnsafeMutableBufferPointer { elastic.read(&cursor, into: $0) }

        try rig.engine.core.control.sync { rig.engine.core.respond(to: .warning) }
        #expect(elastic.history == 16, "a warning destroys retired plans and nothing else")
        try rig.engine.core.control.sync { rig.engine.core.respond(to: .critical) }
        #expect(elastic.history == 4 && rigid.history == 16, "a feed that declared no smaller minimum is never trimmed")
        rig.feed(Array(signal[(64 * 12) ..< (64 * 13)]))
        let after = elastic.snapshot()
        #expect(after.columnCount == 4)
        #expect(Array(after.values.prefix(33 * 3)) == Array(before.values.suffix(33 * 3)), "the newest columns are kept, in order")
        let result = values.withUnsafeMutableBufferPointer { elastic.read(&cursor, into: $0) }
        #expect(result.isReset && result.history == 4 && result.columnCount == 4, "the generation moved: a view reallocates its texture once")
        #expect(rigid.columnCount == 13)
        await rig.drain()
        #expect(await eventually { log.contains(.memoryPressure(.warning)) && log.contains(.memoryPressure(.critical)) })
    }

    // MARK: WaveformFeed and the pyramid (WP-334)

    @Test func aWaveformFeedKeepsTheNewestPairs() throws {
        let feed = WaveformFeed(history: 6)
        try feed.claim(axis: nil, environment: DSPEnvironment(), domain: .envelope, format: .envelope(maximumCount: 4))
        let minima: [Float] = [-1, -2, -3, -4], maxima: [Float] = [1, 2, 3, 4]
        for round in 0 ..< 2 {
            minima.withUnsafeBufferPointer { lows in
                maxima.withUnsafeBufferPointer { highs in feed.write(FrameView(minima: lows, maxima: highs, index: round, time: Double(round))) }
            }
        }
        let snapshot = feed.snapshot()
        #expect(snapshot.content == .waveform && snapshot.rowCount == 2 && snapshot.columnCount == 6)
        #expect(snapshot.minima == [-3, -4, -1, -2, -3, -4] && snapshot.maxima == [3, 4, 1, 2, 3, 4])
        var cursor = FeedCursor()
        var pairs = [Float](repeating: 0, count: 12)
        let result = pairs.withUnsafeMutableBufferPointer { feed.read(&cursor, into: $0) }
        #expect(result.columnCount == 6 && pairs == [-3, 3, -4, 4, -1, 1, -2, 2, -3, 3, -4, 4], "minimum, then maximum")
    }

    @Test func thePyramidEqualsANaiveReductionAtEveryLevel() {
        let samples = TestSignal.whiteNoise(count: 16 * 301, seed: 9)
        let bucket = 16
        // Level 0 as a reduction step would write it: one pair per bucket of 16 samples.
        let pairs = stride(from: 0, to: samples.count, by: bucket).map { start in samples[start ..< min(start + bucket, samples.count)] }
        let pyramid = EnvelopePyramid(minima: pairs.map { $0.min()! }, maxima: pairs.map { $0.max()! })
        #expect(pyramid.levels.count == 10 && pyramid.levels.last?.count == 1, "301 pairs: nine halvings")
        for (depth, level) in pyramid.levels.enumerated() {
            let width = bucket << depth
            #expect(level.span == 1 << depth)
            let naive = stride(from: 0, to: samples.count, by: width).map { start in samples[start ..< min(start + width, samples.count)] }
            #expect(level.minima == naive.map { $0.min()! } && level.maxima == naive.map { $0.max()! }, "level \(depth) ≡ the direct reduction")
            #expect(zip(level.minima, level.maxima).allSatisfy { $0 <= $1 })
        }
        for (finer, coarser) in zip(pyramid.levels, pyramid.levels.dropFirst()) {
            #expect(coarser.count == (finer.count + 1) / 2)
            #expect(coarser.minima.min() == finer.minima.min() && coarser.maxima.max() == finer.maxima.max(), "the extremes survive every level")
        }
        #expect(pyramid.level(forPairsPerPoint: 1)?.span == 1 && pyramid.level(forPairsPerPoint: 5)?.span == 4)
        #expect(pyramid.level(forPairsPerPoint: 1e9)?.count == 1 && EnvelopePyramid(minima: [], maxima: []).level(forPairsPerPoint: 2) == nil)
        #expect(FeedSnapshot(content: .waveform, axis: nil, environment: nil, rowCount: 2, values: [-1, 1, -2, 2, -3, 3], times: [0, 1, 2])
            .pyramid().levels.map(\.minima) == [[-1, -2, -3], [-2, -3], [-3]])
    }

    // MARK: FeatureStream and FeatureCallback (WP-321b)

    @Test func aStreamDeliversEveryFrameToAConsumerThatKeepsUp() async throws {
        let engine = DSPEngine(blockSize: 64)
        let stream = FeatureStream<Samples>(capacity: 256)
        let session = try await engine.attach(Pipeline().testGain(2).emit(to: stream), to: BufferSource(signal, sampleRate: 48_000))
        let consumer = Task { () -> [Float] in
            var received: [Float] = []
            for await frame in stream {
                received.append(contentsOf: frame.samples(ofChannel: 0))
                if received.count == 64 * 40 { break }
            }
            return received
        }
        try session.start()
        let received = await consumer.value
        #expect(received == signal.map { $0 * 2 } && stream.droppedFrames == 0)
        session.detach()
    }

    @Test func aStreamDropsTheOldestAndCountsThemWhenItsConsumerLags() async throws {
        let stream = FeatureStream<Scalar>(capacity: 4)
        try stream.claim(axis: nil, environment: DSPEnvironment(), domain: .scalar, format: .scalar)
        for value in 0 ..< 10 { stream.write(FrameView(scalar: ScalarFrame(value: Float(value)), index: value, time: Double(value))) }
        var iterator = stream.makeAsyncIterator()
        var values: [Float] = []
        for _ in 0 ..< 4 { values.append(await iterator.next()?.scalar.value ?? -1) }
        #expect(values == [6, 7, 8, 9] && stream.droppedFrames == 6, "bounded: the newest four are kept, six are counted as dropped")
        // No unbounded growth: a consumer that never comes costs nothing more.
        for value in 10 ..< 100_000 { stream.write(FrameView(scalar: ScalarFrame(value: Float(value)), index: value, time: 0)) }
        #expect(stream.droppedFrames == 6 + 99_990 - 4)
        expectNoAllocations {
            var count = 0
            while count < 1_000 {
                stream.write(FrameView(scalar: ScalarFrame(value: 1), index: count, time: 0))
                count += 1
            }
        }
        stream.finish()
        var rest = 0
        while await iterator.next() != nil { rest += 1 }
        #expect(rest == 4, "a finished stream ends once what is left has been taken")
    }

    @Test func aStreamKeepsVectorsAndComplexFramesWhole() async throws {
        let vectors = FeatureStream<Spectrum<LinearFrequency, MagnitudeValues>>(capacity: 64)
        let complex = FeatureStream<Spectrum<LinearFrequency, ComplexValues>>(capacity: 64)
        let expected = try Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().process(Array(signal[..<640]), format: format, blockSize: 64)
        try Pipeline().testFramer(frame: 64, hop: 64).emit(to: complex).testMagnitude().emit(to: vectors)
            .run(on: Array(signal[..<640]), format: format, blockSize: 64)
        vectors.finish()
        complex.finish()
        var frames: [FeatureFrame] = []
        for await frame in vectors { frames.append(frame) }
        #expect(frames.map(\.values) == expected && frames.map(\.index) == Array(0 ..< 10) && frames.allSatisfy { $0.kind == .real && $0.count == 33 })
        var bins: [FeatureFrame] = []
        for await frame in complex { bins.append(frame) }
        #expect(bins.count == 10 && bins.allSatisfy { $0.kind == .complex && $0.values.count == 33 && $0.secondary.count == 33 })
        #expect(zip(bins, expected).allSatisfy { frame, magnitude in
            zip(zip(frame.values, frame.secondary), magnitude).allSatisfy { abs(($0.0 * $0.0 + $0.1 * $0.1).squareRoot() - $1) < 1e-4 }
        })
    }

    @Test func aCancelledConsumerStopsWaiting() async throws {
        let stream = FeatureStream<Scalar>()
        try stream.claim(axis: nil, environment: DSPEnvironment(), domain: .scalar, format: .scalar)
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()
        #expect(await consumer.value == 0)
    }

    @Test func aCallbackRunsOnTheThreadThatRunsThePlan() throws {
        let seen = Locked<[Int]>([])
        let callback = FeatureCallback<Samples> { frame in seen.withLock { $0.append(frame.count) } }
        _ = try Pipeline().emit(to: callback).process(Array(signal[..<200]), format: format, blockSize: 64)
        #expect(seen.get() == [64, 64, 64, 8])
    }

    // MARK: Emit(to:) for every kind of sink (WP-335, O-11)

    @Test func eachSinkReceivesTheFramesItCanHold() async throws {
        let heat = HeatmapFeed(history: 64)
        let value = StateBox(Float(-1)), frame = StateBox(ScalarFrame.none), vector = StateBox([Float]())
        let pipeline = Pipeline {
            TestFramer(frame: 64, hop: 64)
            TestMagnitude()
            Emit(to: heat)
            Emit(to: vector.binding)
            TestMean()
            Emit(to: value.binding)
            Emit(to: frame.binding)
        }
        let scalars = try await MainActor.run { try pipeline.process(signal, format: format, blockSize: 64) }
        let last = try #require(scalars.last)
        #expect(heat.columnCount == 40 && value.value == last.value && frame.value == last && vector.value.count == 33)
        #expect(pipeline == Pipeline().testFramer(frame: 64, hop: 64).testMagnitude().emit(to: heat).emit(to: vector.binding)
            .appending(TestMean()).emit(to: value.binding).emit(to: frame.binding), "fluent ≡ builder (API-1)")
        // Tier 2 agrees with the types: a description that puts a sink after a domain it cannot hold is refused.
        let forged = Pipeline<Samples, Samples>(unchecked: [Emit<HeatmapFeed>(to: HeatmapFeed()).stageDescription])
        #expect(throws: DSPError.self) { try forged.process(signal, format: format) }
        let wave = Pipeline<Samples, Samples>(unchecked: [Emit<WaveformFeed>(to: WaveformFeed()).stageDescription])
        #expect(throws: DSPError.self) { try wave.process(signal, format: format) }
    }
}
