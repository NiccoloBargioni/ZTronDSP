import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSP
@testable import ZTronDSPUI

// Feeds a hosted test fills and keeps live by hand, through the public API, as a stage and a
// source written outside the package would. These are the helpers level 1 of the stability
// suite uses (`Tests/ZTronDSPUITests/Support.swift`), kept here so that the gallery's tests
// depend on nothing but the package's products.

// MARK: Stages

/// Turns every block of `rows` samples into one column of `rows` values.
struct TestColumns: PipelineStage {
    typealias Input = Samples
    typealias Output = Spectrum<LinearFrequency, DecibelValues>
    let rows: Int
    let axis: FeedAxis
    /// The hop the stage announces: with the sample rate it gives the feed's feature rate.
    var hop: Int?

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        let rows = rows
        context.emit(.analysis(AnalysisStep(
            name: "TestColumns", key: self, output: .real(count: rows),
            scope: .spectral(frameSize: max(2 * (rows - 1), 2), hopSize: hop ?? rows, axis: axis)
        ) { () throws(DSPError) -> any AnalysisNode in
            TestColumnsNode(rows: rows)
        }))
    }
}

final class TestColumnsNode: AnalysisNode {
    let rows: Int

    init(rows: Int) {
        self.rows = rows
    }

    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples, block.frameCount == rows else { return }
        let samples = block.channel(0), values = output.real
        var row = 0
        while row < rows {
            values[row] = samples[row]
            row += 1
        }
        output.emit()
    }

    func reset() {}
}

/// Turns every block of samples into (minimum, maximum) pairs: two samples make one pair.
struct TestPairs: PipelineStage {
    typealias Input = Samples
    typealias Output = Envelope
    let pairsPerBlock: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        context.emit(.analysis(AnalysisStep(name: "TestPairs", key: self, output: .envelope(maximumCount: pairsPerBlock)) {
            () throws(DSPError) -> any AnalysisNode in TestPairsNode()
        }))
    }
}

final class TestPairsNode: AnalysisNode {
    var latencyFrames: Int { 0 }
    var settlingFrames: Int { 0 }

    func process(_ input: FrameView, _ output: inout FrameWriter) {
        guard let block = input.samples else { return }
        let samples = block.channel(0), minima = output.minima, maxima = output.maxima
        let pairs = min(block.frameCount / 2, minima.count)
        var pair = 0
        while pair < pairs {
            minima[pair] = samples[2 * pair]
            maxima[pair] = samples[2 * pair + 1]
            pair += 1
        }
        output.emit(count: pairs)
    }

    func reset() {}
}

enum FeedWriter {
    static let format = SignalFormat(sampleRate: 48_000)

    /// Appends columns to a heat-map feed: `values` holds `rows` values per column, column
    /// after column. The feed is attached for the length of the call, as an offline run does.
    static func append(_ values: [Float], rows: Int, axis: FeedAxis? = nil, hop: Int? = nil, to feed: HeatmapFeed) throws {
        precondition(values.count % rows == 0)
        let pipeline = Pipeline<Samples, Samples>().appending(TestColumns(rows: rows, axis: axis ?? .indices(count: rows), hop: hop)).emit(to: feed)
        try pipeline.run(on: values, format: format, blockSize: rows)
    }

    /// Appends pairs to a waveform feed: `pairs` holds a minimum and a maximum per pair.
    static func append(pairs: [Float], to feed: WaveformFeed) throws {
        precondition(pairs.count % 2 == 0)
        let pipeline = Pipeline<Samples, Samples>().appending(TestPairs(pairsPerBlock: 64)).emit(to: feed)
        try pipeline.run(on: pairs, format: format, blockSize: 128)
    }

    /// Columns of `rows` values: column c holds c in its first row and a ramp above.
    static func columns(_ range: Range<Int>, rows: Int) -> [Float] {
        range.flatMap { column in (0 ..< rows).map { row in row == 0 ? Float(column) : Float(-90 + (row * 7 + column * 3) % 90) } }
    }

    /// A picture with something to see at every size: columns whose level rises along time and
    /// along the rows, so that a stretched or shifted copy differs from a true one.
    static func pattern(columns: Int, rows: Int) -> [Float] {
        (0 ..< columns).flatMap { column in
            (0 ..< rows).map { row in
                let wave = sin(Double(column) * 0.45) * cos(Double(row) * 0.35)
                return Float(-45 + 40 * wave + 0.3 * Double(row) - 0.2 * Double(column))
            }
        }
    }
}

// MARK: A source in the test's hands

/// A push source the test feeds by hand: the session runs, and its feeds are live, for as
/// long as the test wants, and exactly the frames the test writes arrive.
final class HandFedSource: PushSampleSource, @unchecked Sendable {
    // Threading: the format and the writer are behind a lock; the test's thread writes.
    private let lock = NSLock()
    private var stored: SignalFormat
    private var writer: RingWriter?
    private let stream: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    init(sampleRate: Double = 48_000) {
        stored = SignalFormat(sampleRate: sampleRate)
        (stream, continuation) = AsyncStream.makeStream(of: SourceEvent.self)
    }

    var format: SignalFormat { lock.withLock { stored } }
    var events: AsyncStream<SourceEvent> { stream }

    func prepare() async throws(DSPError) {}
    func start() throws(DSPError) {}
    func stop() {}

    func connect(to ring: RingWriter) {
        lock.withLock { writer = ring }
    }

    /// Writes mono samples into the ring; returns the frames written.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        guard let ring = lock.withLock({ writer }) else { return 0 }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            var table = [UnsafePointer<Float>?](repeating: buffer.baseAddress, count: ring.channelCount)
            return table.withUnsafeMutableBufferPointer { ring.write(channels: $0.baseAddress!, frameCount: samples.count) }
        }
    }
}

/// A flag behind a `Binding`, as `@State` gives one.
@MainActor
final class Switch {
    var isOn: Bool
    private(set) var writes = 0

    init(_ isOn: Bool = true) {
        self.isOn = isOn
    }

    var binding: Binding<Bool> {
        Binding(get: { self.isOn }, set: { self.isOn = $0; self.writes += 1 })
    }
}

/// A value the test keeps by reference.
@MainActor
final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

// MARK: A live session that writes a feed

/// Which of the two surfaces a test is about.
enum SurfaceKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case heatmap, waveform
    var testDescription: String { rawValue }
}

/// A running session that writes a feed, fed by the test. One block of `rows` samples makes
/// one column of a heat-map feed, or `rows / 2` pairs of a waveform feed.
@MainActor
struct LiveFeed {
    let kind: SurfaceKind
    let rows: Int
    let engine: DSPEngine
    let source: HandFedSource
    let heatmap: HeatmapFeed
    let waveform: WaveformFeed
    let session: PipelineSession
    /// The switch of the branch that writes the feed.
    let branch: Switch

    init(_ kind: SurfaceKind = .heatmap, rows: Int = 16, history: Int = 1_024, axis: FeedAxis? = nil, hop: Int? = nil) async throws {
        self.kind = kind
        self.rows = rows
        engine = DSPEngine(blockSize: rows)
        source = HandFedSource()
        heatmap = HeatmapFeed(history: history)
        waveform = WaveformFeed(history: history)
        branch = Switch(true)
        let pipeline: Pipeline<Samples, Samples>
        switch kind {
        case .heatmap:
            let columns = TestColumns(rows: rows, axis: axis ?? .indices(count: rows), hop: hop)
            let feed = heatmap
            pipeline = Pipeline<Samples, Samples>().tap(isActive: branch.binding) { $0.appending(columns).emit(to: feed) }
        case .waveform:
            let pairs = TestPairs(pairsPerBlock: rows / 2)
            let feed = waveform
            pipeline = Pipeline<Samples, Samples>().tap(isActive: branch.binding) { $0.appending(pairs).emit(to: feed) }
        }
        session = try await engine.attach(pipeline, to: source)
    }

    /// Columns, or pairs, one block adds to the feed.
    var itemsPerBlock: Int { kind == .heatmap ? 1 : rows / 2 }

    var isLive: Bool { kind == .heatmap ? heatmap.isLive : waveform.isLive }
    var generation: UInt64 { kind == .heatmap ? heatmap.generation : waveform.generation }

    /// Starts the session and waits until the feed has said that it is live.
    func start() async throws {
        try session.start()
        #expect(await eventually { isLive }, "the feed of a running session is live")
        await mainQueueDrained()
    }

    /// Stops the session and waits until the feed has said that it is not live any more.
    func stop() async {
        session.stop()
        #expect(await eventually { !isLive })
        await mainQueueDrained()
    }

    /// Suspends or resumes the branch that writes the feed, through its bound switch (ACT-11).
    func setBranchActive(_ active: Bool) async {
        branch.isOn = active
        session.syncBindings()
        #expect(await eventually { isLive == active })
        await mainQueueDrained()
    }

    /// Writes blocks, numbered by `range`, without waiting for them.
    func write(_ range: Range<Int>) {
        let values = FeedWriter.columns(range, rows: rows)
        #expect(source.write(values) == values.count, "the ring took every frame")
    }

    /// Sends blocks, numbered by `range`, and waits until the feed holds what they make.
    func send(_ range: Range<Int>) async {
        let wanted = generation + UInt64(range.count * itemsPerBlock)
        write(range)
        #expect(await eventually { generation >= wanted }, "what was sent arrived in the feed")
    }
}
