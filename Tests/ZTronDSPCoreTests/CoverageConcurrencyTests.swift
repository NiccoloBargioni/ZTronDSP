import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPCore
import ZTronDSPTesting

/// What only threads can show (COV-3): which thread runs a source, attachments that meet in one
/// preparation, and the two places where a feed's reader or its control context meets its
/// writer in mid-step. Nothing here asserts a duration: the tests wait for states, and what
/// they assert holds for every interleaving.
@Suite("Engine and feeds across threads (COV-3)")
struct CoverageConcurrencyTests {
    let format = SignalFormat(sampleRate: 48_000)
    let ones = [Float](repeating: 1, count: 64)

    // MARK: Which thread runs a source (§4.3)

    /// §4.3: the analysis thread runs every real-time source; a source that is asked as fast as
    /// possible gets a thread of its own, "so that it cannot starve a live session". A source
    /// is what its `pacing` says when it is prepared: one that is real-time for one run and not
    /// for the next moves to a thread of its own, and back, and the thread it leaves lets it go.
    @Test func aSourceWhosePacingChangesMovesToTheThreadOfItsKind() async throws {
        let analysis = "com.zombietron.ztrondsp.analysis", offline = "com.zombietron.ztrondsp.offline"
        let engine = DSPEngine(blockSize: 64)
        let source = CoveragePacedSource(pacing: .realTime, framesPerRun: 640)
        let sink = CoverageThreadSink()
        let session = try await engine.attach(Pipeline().emit(to: sink), to: source)
        func ownsAThread() -> Bool { (try? engine.core.control.sync { session.core.hub.thread != nil }) ?? false }

        try session.start()
        #expect(await eventually(timeout: 60) { sink.frameCount == 640 && session.state == .finished })
        #expect(sink.threads == [analysis] && !ownsAThread(), "paced in real time: the engine's analysis thread")
        #expect(engine.analysisScheduling != .notStarted, "which exists from the first session that ran")

        source.setPacing(.asFastAsPossible)
        try session.start()
        #expect(await eventually(timeout: 60) { sink.frameCount == 1_280 && session.state == .finished })
        #expect(sink.threads == [analysis, offline] && ownsAThread(), "as fast as possible: a thread of its own")
        #expect(source.prepares == 2, "the stream that ended was prepared again")

        source.setPacing(.realTime)
        try session.start()
        #expect(await eventually(timeout: 60) { sink.frameCount == 1_920 && session.state == .finished })
        #expect(sink.threads == [analysis, offline, analysis] && !ownsAThread(), "real time again: back on the analysis thread, its own thread ended")
        session.detach()
    }

    // MARK: Attachments that meet in one preparation (ATT-6)

    /// ATT-6, §4.5: a source "is prepared once". Two sessions that finished with their source
    /// and are started again while its preparation is still under way wait for that one
    /// preparation: the source is prepared once more, not once per session, and started once.
    @Test func sessionsStartedAgainMeetInOnePreparation() async throws {
        let engine = DSPEngine(blockSize: 64)
        let source = CoverageGatedSource()
        let a = CollectingSink<Samples>(), b = CollectingSink<Samples>()
        let first = try await engine.attach(Pipeline { TestGain(2) }.emit(to: a), to: source)
        let second = try await engine.attach(Pipeline { TestGain(3) }.emit(to: b), to: source)
        try first.start()
        try second.start()
        source.write(ones)
        #expect(await eventually(timeout: 30) { a.samples.count == 64 && b.samples.count == 64 })
        source.send(.ended)
        #expect(await first.reaches(.finished, timeout: 30))
        #expect(await second.reaches(.finished, timeout: 30))
        #expect(source.prepares == 1 && source.starts == 1)

        // The source takes its time to be prepared again; meanwhile the other session is started too.
        source.closeGate()
        try first.start()
        #expect(await eventually(timeout: 30) { source.prepares == 2 }, "the first start prepares the source again")
        try second.start()
        engine.core.flush()
        #expect(first.state == .finished && second.state == .finished, "neither runs before the source is prepared")
        source.openGate()
        #expect(await first.reaches(.running, timeout: 30))
        #expect(await second.reaches(.running, timeout: 30))
        source.write(ones)
        #expect(await eventually(timeout: 30) { a.samples.count == 128 && b.samples.count == 128 }, "both receive the next block: \(a.samples.count), \(b.samples.count)")
        let preparedAgain = await eventually(timeout: 0.25) { source.prepares > 2 }
        #expect(!preparedAgain && source.prepares == 2 && source.starts == 2, "one preparation and one start for both: \(source.prepares), \(source.starts)")
        first.detach()
        second.detach()
    }

    // MARK: A feed that is cleared while it is read (SWAP-3, V-6)

    /// SWAP-3: "a feed whose branch changed is cleared at the exchange", by its writer, while
    /// readers read. V-6: a reader is told when what it took before no longer belongs to the
    /// feed's history (`isReset`), and clears its texture. So whatever the interleaving, the
    /// columns of a read that is not a reset continue the history of the columns before them;
    /// columns of a new history come only with a reset, or after one; and one read never mixes
    /// two histories. Here every column carries the number of the history it was written in.
    @Test func aReaderNeverTakesColumnsOfANewHistoryWithoutAReset() async throws {
        let rows = 16_384, history = 16, perHistory = 8, reads = 5_000
        let feed = HeatmapFeed(history: history)
        try feed.claim(axis: .indices(count: rows), environment: DSPEnvironment(), domain: .chroma, format: .real(count: rows))
        let started = Locked(false), stop = Locked(false), finished = Locked(false), histories = Locked(0)
        let writer = Thread {
            let column = UnsafeMutableBufferPointer<Float>.allocate(capacity: rows)
            var number: Float = 1
            // A Float counts exactly up to 2²⁴: the writer stops there at the latest.
            while number < 16_000_000, !stop.get() {
                column.update(repeating: number)
                var index = 0
                while index < perHistory {
                    feed.write(FrameView(real: UnsafeBufferPointer(column), index: index, time: Double(number)))
                    index += 1
                }
                started.set(true)
                feed.clearForNewBranch()
                number += 1
            }
            histories.set(Int(number))
            column.deallocate()
            finished.set(true)
        }
        writer.start()
        #expect(await eventually(timeout: 30) { started.get() })

        var cursor = FeedCursor()
        var values = [Float](repeating: 0, count: rows * history), times = [Double](repeating: 0, count: history)
        var mixed = 0, torn = 0, unannounced = 0, backwards = 0, resets = 0, columns = 0
        var current: Float?            // the history the reader is in, once it has seen a column of it
        var newest: Float = 0          // the newest history it has ever seen a column of
        var round = 0
        // At least `reads` reads, and on until the writer has been seen to clear the feed fifty
        // times. A column is looked at in three places only (whole columns are the business of
        // `readersNeverSeeATornColumn`), so that the reader spends its time reading.
        while round < reads || resets < 50, round < 2_000_000, !finished.get() {
            round += 1
            let result = values.withUnsafeMutableBufferPointer { buffer in
                times.withUnsafeMutableBufferPointer { feed.read(&cursor, into: buffer, times: $0) }
            }
            if result.isReset {
                resets += 1
                current = nil
            }
            guard result.columnCount > 0 else { continue }
            columns += result.columnCount
            let stamp = values[0]
            var column = 0
            while column < result.columnCount {
                let first = values[column * rows], middle = values[column * rows + rows / 2], last = values[(column + 1) * rows - 1]
                if first != middle || first != last || times[column] != Double(first) { torn += 1 }
                if first != stamp { mixed += 1 }
                column += 1
            }
            if let history = current, history != stamp { unannounced += 1 }
            if stamp < newest || (result.isReset && stamp == newest) { backwards += 1 }
            current = stamp
            newest = max(newest, stamp)
        }
        stop.set(true)
        #expect(await eventually(timeout: 30) { finished.get() })

        #expect(torn == 0, "every column is whole where it was looked at")
        #expect(mixed == 0, "one read, one history")
        #expect(unannounced == 0, "columns of another history come with a reset, or after one: \(unannounced) of \(columns) came without")
        #expect(backwards == 0, "and a reset never leads back into a history that was cleared")
        #expect(resets >= 50 && columns > 0, "the reader read beside the writer: \(resets) resets, \(columns) columns in \(round) reads, \(histories.get()) histories written")
    }

    // MARK: A feed that is trimmed while it is written (MEM-1)

    /// MEM-1: on a critical memory warning a feed "drop[s] its oldest columns down to that
    /// minimum", on the control context, while its writer goes on (RT-4: the writer never
    /// waits). The smaller history is filled with the newest columns as they stood when it was
    /// trimmed, and the writer adds what it wrote meanwhile when it next writes: no column the
    /// writer finished is missing between the ones that were kept and the ones that follow.
    ///
    /// The writer never rests, so that it writes while the feed is trimmed whenever the machine
    /// runs the two at once. Rounds go on until that was seen in six of them (the old history
    /// then holds columns the smaller one was not given when it was made), eight rounds at
    /// least and forty-eight at most. What is asserted holds for every interleaving, with or
    /// without such a round.
    @Test func aFeedTrimmedBesideItsWriterMissesNoColumn() async throws {
        let rows = 16_384, history = 256, minimum = 128
        let bytes = rows * MemoryLayout<Float>.stride
        let expected = UnsafeMutableBufferPointer<Float>.allocate(capacity: rows)
        defer { expected.deallocate() }
        var round = 0, besideTheWriter = 0
        while round < 8 || (besideTheWriter < 6 && round < 48) {
            let feed = HeatmapFeed(history: history, minimumHistory: minimum)
            try feed.claim(axis: .indices(count: rows), environment: DSPEnvironment(), domain: .chroma, format: .real(count: rows))
            let written = Locked(0), stop = Locked(false), finished = Locked(false)
            let writer = Thread {
                let column = UnsafeMutableBufferPointer<Float>.allocate(capacity: rows)
                var number = 0
                // A Float counts exactly up to 2²⁴: the writer stops there at the latest.
                while number < 16_000_000, !stop.get() {
                    var stamp = Float(number)
                    memset_pattern4(column.baseAddress!, &stamp, bytes)
                    feed.write(FrameView(real: UnsafeBufferPointer(column), index: number, time: Double(number)))
                    number += 1
                    written.set(number)
                }
                column.deallocate()
                finished.set(true)
            }
            writer.start()
            #expect(await eventually(timeout: 30) { written.get() >= history + 8 }, "round \(round): the feed is full")

            let full = try #require(feed.store.layout, "the history the writer fills")
            let trimmed = feed.trimForMemoryPressure()
            let smaller = try #require(feed.store.layout, "the history the feed was trimmed to")
            let atTrim = written.get()
            // The writer writes at least twice more: it has then taken the smaller history.
            #expect(await eventually(timeout: 30) { written.get() >= atTrim + 2 })
            stop.set(true)
            #expect(await eventually(timeout: 30) { finished.get() })
            let total = written.get()
            // Columns the writer finished in the old history after the trim had copied it are
            // the ones it had to add to the smaller history itself.
            if ztd_atomic_load(full.completed) > smaller.inheritedThrough { besideTheWriter += 1 }

            let snapshot = feed.snapshot()
            #expect(trimmed && feed.history == minimum && !feed.trimForMemoryPressure(), "round \(round): trimmed once, to the minimum it declared")
            #expect(snapshot.columnCount == minimum, "round \(round): \(snapshot.columnCount) columns")
            let stamps = snapshot.times
            let consecutive = zip(stamps, stamps.dropFirst()).allSatisfy { $1 == $0 + 1 }
            #expect(consecutive && stamps.last == Double(total - 1), "round \(round): the newest \(minimum) columns, none missing, up to the last one written (\(total - 1)): \(stamps.first ?? -1) … \(stamps.last ?? -1)")
            let whole = snapshot.values.withUnsafeBufferPointer { values -> Bool in
                guard let base = values.baseAddress, values.count == stamps.count * rows else { return false }
                var column = 0
                while column < stamps.count {
                    var stamp = Float(stamps[column])
                    memset_pattern4(expected.baseAddress!, &stamp, bytes)
                    if memcmp(base + column * rows, expected.baseAddress!, bytes) != 0 { return false }
                    column += 1
                }
                return true
            }
            #expect(whole, "round \(round): every column is the one its time names")
            feed.release()
            round += 1
        }
    }
}
