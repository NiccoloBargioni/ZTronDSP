import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// Defects found by the first verification of the engine, each kept as a test of the rule it
/// broke.
@Suite("Engine: what the first verification found")
struct EngineRegressionTests {
    let format = SignalFormat(sampleRate: 48_000)
    let block = [Float](repeating: 0.5, count: 64)

    // MARK: Results and bindings

    @Test func aVectorResultFollowsTheSignalAcrossAnExchangeThatKeepsItsBranch() async throws {
        // OUT-2, OUT-5, SWAP-1: every plan has result slots of its own, and each is prepared.
        let rig = Rig()
        let vector = StateBox([Float]()), value = StateBox(Float(-1))
        let before = Pipeline().tap { $0.testFramer(frame: 64, hop: 64).testMagnitude().emit(to: vector.binding).appending(TestMean()).emit(to: value.binding) }
        let session = try await rig.engine.attach(before, to: rig.source)
        try session.start()
        await rig.drain()
        rig.feed([Float](repeating: 0.5, count: 256))
        await MainActor.run { session.core.pump.deliver() }
        let first = vector.value
        #expect(first.count == 33 && first[0] > 0)
        try await session.update(before.testGain(0.5))               // the tap's branch is unchanged
        await rig.drain()
        rig.feed([Float](repeating: 0.5, count: 1_024))
        rig.feed([Float](repeating: 0.25, count: 512))
        await rig.drain()
        await MainActor.run { session.core.pump.deliver() }
        #expect(vector.value.count == 33 && abs(vector.value[0] - first[0] / 2) < 1e-5, "the vector follows the signal after the exchange: \(vector.value.first ?? -1)")
        #expect(abs(value.value - vector.value.reduce(0, +) / 33) < 1e-4, "and so does the scalar beside it")
    }

    @Test func detachAndAnEqualUpdateLetGoOfTheBindings() async throws {
        // BIND-6: captured bindings are released by the next update and by detach.
        final class Token: @unchecked Sendable {}
        func bound(_ token: Token) -> Binding<Bool> { Binding(get: { _ = token; return true }, set: { _ in }) }
        let rig = Rig()
        weak var first: Token?
        weak var second: Token?
        var session: PipelineSession?
        do {
            let token = Token()
            first = token
            session = try await rig.engine.attach(Pipeline { TestGain(0.5, isActive: bound(token)) }, to: rig.source)
        }
        try session?.start()
        await rig.drain()
        #expect(first != nil, "while it is captured, the binding is kept")
        do {
            let token = Token()
            second = token
            try await session?.update(Pipeline { TestGain(0.5, isActive: bound(token)) })     // an equal pipeline, another binding
        }
        await rig.drain()
        #expect(first == nil, "an equal update lets go of the bindings captured before")
        #expect(second != nil)
        session?.detach()
        await rig.drain()
        #expect(second == nil, "detach lets go of them while the session object lives on")
        #expect(session?.state == .detached)
    }

    @Test func aStageBypassedForGoodAddsNoLatency() async throws {
        // ACT-4, REAL-5: a constant `.bypassed` leaves no trace, its latency included.
        let engine = DSPEngine(blockSize: 64)
        var impulse = [Float](repeating: 0, count: 512)
        impulse[0] = 1
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline { TestDelay(37, isActive: false); TestGain(-1) }.emit(to: sink), to: BufferSource(impulse, sampleRate: 48_000))
        #expect(session.environment.latency == 0 && sink.environment?.latency == 0)
        try session.start()
        #expect(await session.reaches(.finished))
        #expect(sink.samples.firstIndex { $0 != 0 } == 0, "the impulse leaves where it entered")
        // A bypassed stage that changes the rate still suspends what follows, and that is validated.
        #expect(throws: DSPError.self) { try Pipeline { TestSubsample(by: 2, isActive: false); TestGain(.nan) }.process(impulse, format: format) }
    }

    // MARK: Sinks

    @Test func aConsumerCancelledAsItStartsToWaitReturns() async throws {
        let stream = FeatureStream<Scalar>()
        try stream.claim(axis: nil, environment: DSPEnvironment(), domain: .scalar, format: .scalar)
        var hung = 0
        for round in 0 ..< 300 {
            let started = Locked(false), done = Locked(false)
            let consumer = Task.detached {
                started.set(true)
                for await _ in stream {}
                done.set(true)
            }
            while !started.get() {}
            var spin = (round &* 7_919) % 600
            while spin > 0 { spin -= 1 }
            consumer.cancel()
            if !(await eventually(timeout: 1) { done.get() }) { hung += 1 }
        }
        #expect(hung == 0, "\(hung) of 300 cancelled consumers never returned")
        stream.finish()
    }

    @Test func aStoreOfOneColumnNeverHandsOutATornOne() async throws {
        // RT-4: a reader gets a column the writer finished, or none. With a history of one
        // column every read races the writer, which is what makes this the hard case.
        for history in [1, 2] {
            let feed = HeatmapFeed(history: history)
            let rows = 48
            try feed.claim(axis: .indices(count: rows), environment: DSPEnvironment(), domain: .chroma, format: .real(count: rows))
            let stop = Locked(false)
            let writer = Thread {
                var value: Float = 1
                let column = UnsafeMutableBufferPointer<Float>.allocate(capacity: rows)
                while !stop.get() {
                    column.update(repeating: value)
                    feed.write(FrameView(real: UnsafeBufferPointer(column), index: 0, time: Double(value)))
                    value += 1
                    if value > 8_000_000 { value = 1 }
                }
                column.deallocate()
            }
            writer.start()
            let torn = await withTaskGroup(of: (torn: Int, columns: Int).self) { group in
                for _ in 0 ..< 3 {
                    group.addTask {
                        var cursor = FeedCursor()
                        var values = [Float](repeating: 0, count: rows * history), times = [Double](repeating: 0, count: history)
                        var torn = 0, columns = 0
                        let deadline = Date().addingTimeInterval(1.2)
                        while Date() < deadline {
                            let read = values.withUnsafeMutableBufferPointer { buffer in times.withUnsafeMutableBufferPointer { feed.read(&cursor, into: buffer, times: $0) } }
                            for column in 0 ..< read.columnCount {
                                let first = values[column * rows]
                                if values[(column * rows) ..< ((column + 1) * rows)].contains(where: { $0 != first }) || times[column] != Double(first) { torn += 1 }
                            }
                            columns += read.columnCount
                        }
                        return (torn, columns)
                    }
                }
                var all: [(torn: Int, columns: Int)] = []
                for await result in group { all.append(result) }
                return all
            }
            stop.set(true)
            #expect(torn.allSatisfy { $0.torn == 0 }, "history \(history): \(torn.map(\.torn)) torn of \(torn.map(\.columns))")
            #expect(torn.contains { $0.columns > 1_000 }, "the readers did read")
        }
    }

    @Test func aVectorResultIsNeverTorn() async throws {
        let slot = try ResultSlot(kind: .vector)
        try slot.claim(axis: nil, environment: DSPEnvironment(), domain: .chroma, format: .real(count: 64))
        let stop = Locked(false)
        let writer = Thread {
            var value: Float = 1
            let column = UnsafeMutableBufferPointer<Float>.allocate(capacity: 64)
            while !stop.get() {
                column.update(repeating: value)
                slot.write(FrameView(real: UnsafeBufferPointer(column), index: 0, time: 0))
                value += 1
                if value > 8_000_000 { value = 1 }
            }
            column.deallocate()
        }
        writer.start()
        var torn = 0, read = 0
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if let values = slot.readVector() {
                read += 1
                if Set(values).count != 1 || values.count != 64 { torn += 1 }
            }
        }
        stop.set(true)
        #expect(torn == 0 && read > 1_000, "\(torn) torn of \(read) vectors")
    }

    @Test func aTrimmedFeedKeepsItsNewestColumnsWithoutAWriter() async throws {
        // MEM-1: trimming drops the oldest columns, whether or not the feed is being written.
        let rig = Rig()
        let feed = HeatmapFeed(history: 16, minimumHistory: 4)
        let session = try await rig.engine.attach(Pipeline().tap { $0.testFramer(frame: 64, hop: 64).testMagnitude().emit(to: feed) }, to: rig.source)
        try session.start()
        rig.feed(TestSignal.whiteNoise(count: 64 * 12, seed: 1))
        let before = feed.snapshot()
        session.stop()
        try rig.engine.core.control.sync { rig.engine.core.respond(to: .critical) }
        let after = feed.snapshot()
        #expect(after.columnCount == 4 && feed.history == 4, "the newest four columns are there at once")
        #expect(after.values == Array(before.values.suffix(33 * 4)) && after.times == Array(before.times.suffix(4)))
        // With a writer, what it wrote since the trim follows what was kept.
        try session.start()
        rig.feed(TestSignal.whiteNoise(count: 64 * 2, seed: 2))
        #expect(feed.snapshot().columnCount == 4 && feed.columnCount == 4)
        session.detach()
    }

    @Test func anUpdateThatDropsASinkFreesItAtOnce() async throws {
        // ATT-5: `update(_:)` releases the claim on a sink it drops; no block has to arrive first.
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let sink = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().tap { $0.emit(to: sink) }, to: source)
        try session.start()
        source.write(block)
        #expect(await eventually { sink.samples.count == 64 })
        try await session.update(Pipeline())
        let other = try await engine.attach(Pipeline().emit(to: sink), to: BufferSource(block, sampleRate: 48_000))
        #expect(other.state == .idle && sink.releases == 1, "free for another writer when update returns")
        source.write(block)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(sink.samples.count == 64, "the plan that is on its way out writes it no more")
        // A plan that takes the sink back claims it anew, and is refused while another holds it.
        await #expect(throws: DSPError.self) { try await session.update(Pipeline().tap { $0.emit(to: sink) }) }
        other.detach()
        try await session.update(Pipeline().tap { $0.emit(to: sink) })
        source.write(block)
        #expect(await eventually { sink.samples.count == 128 })
        session.detach()
    }

    // MARK: Streams

    @Test func aLongStreamAfterAFormatChangeIsNotCutShort() async throws {
        // ATT-4: the end of the old format's stream is not the end of the stream.
        let second = [Float](repeating: 0.25, count: 64 * 3_000)
        for round in 0 ..< 6 {
            let engine = DSPEngine(blockSize: 64)
            let source = ScriptedSource(format: format, pacing: round % 2 == 0 ? .asFastAsPossible : .realTime, [
                .samples([[Float](repeating: 0.5, count: 128)]), .formatChange(SignalFormat(sampleRate: 44_100)), .samples([second]),
            ])
            let sink = CountingSink<Samples>()
            let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
            try session.start()
            if round % 2 == 0 {
                #expect(await session.reaches(.finished, timeout: 20))
                #expect(sink.frames == 2 + 3_000, "round \(round): \(sink.frames) blocks of 3 002")
            } else {
                // Paced in real time the whole stream takes minutes; a few blocks after the change are enough.
                #expect(await eventually(timeout: 5) { sink.frames > 40 }, "round \(round): the stream goes on after the change")
                #expect(session.state == .running)
            }
            session.detach()
        }
    }

    @Test func aSessionStartedOnAStreamThatIsOverGetsItAgain() async throws {
        // §4.5: `finished → stop() → start()`, and a second attachment on a source that has ended.
        let engine = DSPEngine(blockSize: 64)
        let signal = TestSignal.whiteNoise(count: 1_000, seed: 4)
        let source = BufferSource(signal, sampleRate: 48_000)
        let sink = CollectingSink<Samples>(), late = CollectingSink<Samples>()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
        try session.start()
        #expect(await session.reaches(.finished))
        session.stop()
        #expect(session.state == .idle)
        try session.start()
        #expect(await eventually { sink.samples.count == 2_000 }, "stopped and started again, the session gets the stream anew")
        #expect(await session.reaches(.finished) && sink.samples == signal + signal)
        let second = try await engine.attach(Pipeline().emit(to: late), to: source)
        try second.start()
        #expect(await second.reaches(.finished) && late.samples == signal, "a later attachment gets a stream of its own")
    }

    // MARK: Threads

    @Test(.disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
    func handOversFreeNothingOnTheAnalysisThread() async throws {
        // RT-3: what a hand-over replaces is freed by the control context.
        let engine = DSPEngine(blockSize: 64)
        let source = ManualPushSource(format: format)
        let audit = ThreadAllocationAudit()
        let phase = Locked(0)
        let callback = FeatureCallback<Samples> { _ in
            switch phase.get() {
            case 1: audit.begin()
            case 2: audit.end()
            default: break
            }
        }
        let steady = try await engine.attach(Pipeline().emit(to: callback), to: source)
        let other = try await engine.attach(Pipeline { TestGain(0.5) }, to: source)
        try steady.start()
        let feeder = Thread {
            let samples = [Float](repeating: 0.1, count: 64)
            while phase.get() < 3 {
                source.write(samples)
                usleep(300)
            }
        }
        feeder.start()
        phase.set(1)
        #expect(await eventually { audit.isOpen || audit.failedToOpen })
        for step in 0 ..< 300 {
            try other.start()                                           // a new stage for the hub
            other.stop()                                                // and another
            if step % 10 == 0 { try await other.update(Pipeline { TestGain(Float(step + 2)) ; TestDelay(step % 3 + 1) }) }
        }
        phase.set(2)
        #expect(await eventually { audit.isClosed })
        phase.set(3)
        let counts = try #require(audit.counts)
        #expect(counts.allocations == 0 && counts.deallocations == 0, "600 hand-overs on a running hub: \(counts)")
        steady.detach()
        other.detach()
    }

    // MARK: Limits

    @Test func sizesNoMachineCanHoldAreTypedErrors() async throws {
        // §9.3: no trap is reachable from public API through invalid input.
        await #expect(throws: Never.self) { try await GeneratorSource(.silence, duration: 1e16).prepare() }
        await #expect(throws: DSPError.self) { try await GeneratorSource(.silence, channelCount: Int.max / 4).prepare() }
        await #expect(throws: DSPError.self) { try await GeneratorSource(.silence, sampleRate: 1e12).prepare() }
        let engine = DSPEngine(blockSize: 64)
        let spectra = Pipeline().testFramer(frame: 64, hop: 64).testMagnitude()
        await #expect(throws: DSPError.self) {
            _ = try await engine.attach(spectra.emit(to: HeatmapFeed(history: Int.max)), to: GeneratorSource(.silence, duration: 0.01, pacing: .asFastAsPossible))
        }
        await #expect(throws: DSPError.self) {
            _ = try await engine.attach(Pipeline().emit(to: FeatureStream<Samples>(capacity: Int.max)), to: GeneratorSource(.silence, duration: 0.01, pacing: .asFastAsPossible))
        }
        #expect(throws: DSPError.self) { _ = try AudioBuffer(channelCount: 2, capacity: Int.max) }
        #expect(throws: DSPError.self) { _ = try AudioBuffer(channelCount: Int.max, capacity: 16) }
        #expect(throws: DSPError.self) { _ = try Pipeline().process([0, 1], format: format, blockSize: Int.max) }
        await #expect(throws: DSPError.self) { _ = try await DSPEngine(blockSize: Int.max).attach(Pipeline(), to: BufferSource([0], sampleRate: 48_000)) }
        #expect(throws: DSPError.self) { _ = try SourceAdapter.make(for: ManualPushSource(format: SignalFormat(sampleRate: 1e15)), blockSize: 64) }
        let waveform = WaveformFeed(history: Int.max)
        #expect(throws: DSPError.self) { try waveform.claim(axis: nil, environment: DSPEnvironment(), domain: .envelope, format: .envelope(maximumCount: 4)) }
    }

    @Test func sampleBuffersDoNotSitAWholeNumberOfPagesApart() throws {
        // WP-324: buffers that one loop reads and writes start at different places within a page.
        var offsets = Set<Int>()
        var buffers: [AudioBuffer] = []
        for _ in 0 ..< 16 {
            let buffer = try AudioBuffer(channelCount: 1, capacity: 512)
            buffers.append(buffer)
            let address = Int(bitPattern: buffer.channel(0))
            #expect(address % 64 == 0, "each channel still starts on a cache line")
            offsets.insert(address % 4_096)
        }
        #expect(offsets.count >= 12, "sixteen buffers in a row share few places within a page: \(offsets.count) distinct")
        let a = Int(bitPattern: buffers[0].channel(0)), b = Int(bitPattern: buffers[1].channel(0))
        #expect((a - b) % 4_096 != 0)
    }
}
