import AVFAudio
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import ZTronDSPAnalysis
import ZTronDSPCore
import ZTronDSPDesign
import ZTronDSPIO
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

// Support for the tests of the source-fed components (WP-814, WP-815) and of their animated
// pipelines (WP-817): a source the test feeds by hand and whose preparation it can hold
// back, so that an attachment is on its way for exactly as long as the test wants; signals
// whose picture the test knows, as a mock, as a file and as a processed signal; and the
// pieces of a source-fed component at level 1, the model that keeps its attachment and the
// surface that shows its feed.

// MARK: A source in the test's hands

/// A push source the test feeds by hand, like `HandFedSource`, with two more things in the
/// test's hands: `prepare()` returns only once the source is open, so that an attachment to
/// it is on its way for exactly as long as the test wants; and the source says what the test
/// tells it to say, an interruption or its end.
final class GatedSource: PushSampleSource, @unchecked Sendable {
    // Threading: everything is behind the lock; the test's thread opens, writes and announces.
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private var writer: RingWriter?
    private let stored: SignalFormat
    private let stream: AsyncStream<SourceEvent>
    private let continuation: AsyncStream<SourceEvent>.Continuation

    /// - Parameter open: `false` holds every `prepare()` until `open()` is called.
    init(sampleRate: Double = 48_000, open: Bool = true) {
        stored = SignalFormat(sampleRate: sampleRate)
        isOpen = open
        (stream, continuation) = AsyncStream.makeStream(of: SourceEvent.self)
    }

    var format: SignalFormat { stored }
    var events: AsyncStream<SourceEvent> { stream }

    /// Times an engine began to prepare the source: it was asked for an attachment to it,
    /// and no other attachment had prepared it.
    var prepares: Int { lock.withLock { entered } }

    func prepare() async throws(DSPError) {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let passes = lock.withLock { () -> Bool in
                entered += 1
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func start() throws(DSPError) {}
    func stop() {}

    func connect(to ring: RingWriter) {
        lock.withLock { writer = ring }
    }

    /// Lets every preparation that waits, and every later one, through.
    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in released { continuation.resume() }
    }

    /// The source says `event`: an interruption, its end.
    func announce(_ event: SourceEvent) {
        continuation.yield(event)
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

// MARK: Signals the test knows

/// Signals whose picture the test can predict, and the pipelines that change them in a way
/// the picture shows. Everything is at 48 kHz.
enum Tone {
    static let sampleRate = 48_000.0

    /// A sine of `amplitude`, half scale unless said otherwise.
    static func sine(_ frequency: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        TestSignal.sine(frequency: frequency, sampleRate: sampleRate, count: Int(seconds * sampleRate), amplitude: amplitude)
    }

    /// A strong low tone and a weak high one: the low one is what a picture of the signal
    /// shows as the strongest, the high one what is left once `highPass` has taken the low
    /// one away.
    static func pair(low: Double, high: Double, seconds: Double) -> [Float] {
        TestSignal.sum(sine(low, seconds: seconds), sine(high, seconds: seconds, amplitude: 0.05))
    }

    /// Takes away what lies two octaves and more below `cutoff`, by a hundred decibels.
    static func highPass(_ cutoff: Double) -> Pipeline<Samples, Samples> {
        Pipeline { HighPass(.butterworth, cutoff: .hertz(cutoff), order: 4) }
    }

    /// Clicks at a tempo whose beat is a whole number of the default analysis' hops:
    /// `hopsPerBeat` hops of 512 samples. The autocorrelation of their onsets is strongest
    /// at that lag, so the tempo itself is the strongest row of a tempogram.
    static func clicks(hopsPerBeat: Int, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        TestSignal.clickTrack(beatsPerMinute: tempo(hopsPerBeat: hopsPerBeat), sampleRate: sampleRate, count: Int(seconds * sampleRate), amplitude: amplitude)
    }

    /// The tempo of `clicks(hopsPerBeat:seconds:)`, in beats per minute.
    static func tempo(hopsPerBeat: Int) -> Double {
        60 * sampleRate / (512 * Double(hopsPerBeat))
    }

    /// A mock that plays `samples` once, as fast as they are taken.
    static func mock(_ samples: [Float]) -> BufferSource {
        BufferSource(samples, sampleRate: sampleRate)
    }

    /// The row of a spectrum of `frame` samples that holds `frequency`.
    static func bin(of frequency: Double, frame: Int = 2_048) -> Int {
        Int((frequency * Double(frame) / sampleRate).rounded())
    }
}

/// Audio files written for the length of a test, into a directory of their own.
final class ToneFiles: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ztrondsp-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes mono `samples` as a Float32 file at 48 kHz and returns a source that plays it
    /// once, as fast as it is taken.
    func source(_ samples: [Float], name: String = "tone.caf") throws -> FileSource {
        let url = directory.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Tone.sampleRate, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let data = try #require(buffer.floatChannelData)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { data[0].update(from: base, count: samples.count) }
        }
        // The file is closed when the writer goes out of scope.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return FileSource(url: url, pacing: .asFastAsPossible)
    }
}

// MARK: Reading a feed and a picture

extension FeedSnapshot {
    /// The row whose values, added up over every column, are the largest.
    var strongestRow: Int {
        var sums = [Float](repeating: 0, count: rowCount)
        for index in 0 ..< columnCount {
            for (row, value) in column(index).enumerated() { sums[row] += value }
        }
        return sums.indices.max { sums[$0] < sums[$1] } ?? 0
    }

    /// The value of `row` in the newest column.
    func newest(row: Int) -> Float {
        columnCount > 0 ? Array(column(columnCount - 1))[row] : .nan
    }

    /// The largest maximum of a waveform's newest `count` pairs.
    func reach(newest count: Int) -> Float {
        maxima.suffix(count).max() ?? .nan
    }
}

extension PixelImage {
    /// The pixel row, counted from the bottom, that is the brightest in pixel column `x`.
    func brightestRow(x: Int) -> Int {
        var best = 0, most = -1
        for y in 0 ..< height {
            let pixel = pixel(x: x, y: y)
            let brightness = Int(pixel.red) + Int(pixel.green) + Int(pixel.blue)
            if brightness > most {
                most = brightness
                best = y
            }
        }
        return height - 1 - best
    }

    /// The share of pixel column `x` that is drawn on: what a waveform's envelope covers of
    /// the height.
    func coveredShare(x: Int) -> Double {
        Double((0 ..< height).filter { pixel(x: x, y: $0).alpha > 127 }.count) / Double(height)
    }
}

// MARK: The components that take a source

/// The four components that take a source (§8.1).
enum SourceComponent: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case spectrogram, chromagram, tempogram, waveform

    var testDescription: String { rawValue }

    /// The analysis of a heat-map component; `nil` for the waveform.
    var analysis: HeatmapAnalysis? {
        switch self {
        case .spectrogram: .spectrogram
        case .chromagram: .chromagram
        case .tempogram: .tempogram
        case .waveform: nil
        }
    }
}

// MARK: What a source-fed component shows, at level 1

/// What a source-fed component makes of a source that plays to its end, at level 1: the
/// component's own pipeline, attached as the view attaches it, and the feed it wrote, drawn
/// by a surface into an off-screen texture. The picture shows the newest columns only, so
/// that every pixel shows data.
@MainActor
struct SourceFedShow {
    let snapshot: FeedSnapshot
    let picture: PixelImage
    /// Pixels per row of a heat map.
    let scale: Int
    /// The counters of the surface that drew the feed.
    let probe: RenderProbe
    /// The counters of the attachment.
    let host: PipelineHostProbe
    /// Columns, or pairs, a second, as the feed records it.
    let rate: Double?

    init(
        _ component: SourceComponent, of source: any SampleSource, processing: Pipeline<Samples, Samples>? = nil, frame: AnalysisFrame? = nil,
        melBands: Int? = nil, engine: DSPEngine = DSPEngine(), scale: Int = 1, newest: Int = 16
    ) async throws {
        let heatmap = HeatmapFeed(history: HeatmapAnalysis.history), waveform = WaveformFeed(history: WaveformAnalysis.history)
        let host = PipelineHostProbe(), model = PipelineHostModel<Samples>()
        let pipeline = component.analysis?.pipeline(processing: processing, frame: frame, melBands: melBands, into: heatmap)
            ?? WaveformAnalysis.pipeline(processing: processing, into: waveform)
        model.appear(pipeline, on: source, engine: engine, renderProbe: nil, hostProbe: host)
        #expect(await eventually(timeout: patience) { host.session?.state == .finished || !host.failures.isEmpty }, "the source played to its end")
        #expect(host.failures.isEmpty, "\(host.failures)")
        await mainQueueDrained()
        let content: SurfaceContent, height: Int
        if let analysis = component.analysis {
            rate = heatmap.environment?.featureRate
            let span = rate.map { Double(min(newest, max(heatmap.columnCount, 1))) / $0 }
            content = .heatmap(heatmap, HeatmapSurface.appearance(
                role: analysis.role, colorMap: nil, valueRange: nil, frequencyScale: nil, rowRange: nil, timeSpan: span))
            height = max(heatmap.rowCount, 1) * scale
            snapshot = heatmap.snapshot()
        } else {
            rate = waveform.environment?.featureRate
            let span = rate.map { Double(min(newest, max(waveform.columnCount, 1))) / $0 }
            content = .waveform(waveform, WaveformSurface.appearance(amplitudeRange: nil, timeSpan: span, isDark: false))
            height = 400
            snapshot = waveform.snapshot()
        }
        let stage = try await Stage(content, size: CGSize(width: 4, height: height))
        stage.settle()
        picture = try stage.surface.pixels()
        self.scale = scale
        probe = stage.probe
        self.host = host
        model.disappear()
    }

    /// The row a heat map's picture shows as the strongest, at its right edge.
    var brightestRow: Int { picture.brightestRow(x: picture.width - 1) / scale }

    /// The share of the height a waveform's picture covers, at its right edge.
    var coveredShare: Double { picture.coveredShare(x: picture.width - 1) }
}

// MARK: A source-fed component at level 1, live

/// Which of the two kinds of source-fed component a live test is about: a heat map or a
/// waveform.
enum SourceFedKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case spectrogram, waveform
    var testDescription: String { rawValue }
}

/// A source-fed component at level 1 (§8.4), without SwiftUI: the model that keeps its
/// attachment, driven as the view drives it, the feed the view owns, and a source the test
/// feeds by hand. One block of 16 samples makes one column of the spectrogram, or two pairs
/// of the waveform.
@MainActor
final class SourceFedRig {
    let kind: SourceFedKind
    /// The source and the engine the view is given first.
    let source: GatedSource
    let engine = DSPEngine(blockSize: 16)
    /// The source and the engine the view has now.
    private(set) var currentSource: GatedSource
    private(set) var currentEngine: DSPEngine
    /// The feed the view owns now: another one for every source and for every time it comes
    /// back, as the view makes them.
    private(set) var heatmap = HeatmapFeed(history: HeatmapAnalysis.history)
    private(set) var waveform = WaveformFeed(history: WaveformAnalysis.history)
    let host = PipelineHostProbe()
    /// The probe of the hierarchy: the attachment counts into it, and so does a surface that
    /// is made with it.
    let render = RenderProbe()
    let model = PipelineHostModel<Samples>()
    /// What `.analysisFrame(_:hop:window:)` and `.processing(_:)` say.
    var frame = AnalysisFrame(frame: 16, hop: 16, window: .hann)
    var processing: Pipeline<Samples, Samples>?
    /// What the feed the view owns now last said of its liveness. A feed changes its liveness
    /// on an engine's thread and says so through the main queue a moment later, to everyone
    /// who listens in one turn: once the rig has heard it, a surface that shows the feed has
    /// heard it too.
    private var announced = false
    private var observation: FeedObservation?

    /// A waveform's pair covers five milliseconds: eight samples at 1 600 a second.
    static func sampleRate(_ kind: SourceFedKind) -> Double {
        kind == .spectrogram ? 48_000 : 1_600
    }

    init(_ kind: SourceFedKind = .spectrogram, open: Bool = true) {
        self.kind = kind
        source = GatedSource(sampleRate: Self.sampleRate(kind), open: open)
        currentSource = source
        currentEngine = engine
        listen()
    }

    /// Listens to the feed the view owns now.
    private func listen() {
        announced = false
        let feed = feed
        observation = feed.observeLiveness { [weak self] live in
            guard let self, self.feed == feed else { return }
            self.announced = live
        }
    }

    /// Another source of the kind this component's blocks are counted for.
    func otherSource(open: Bool = true) -> GatedSource {
        GatedSource(sampleRate: Self.sampleRate(kind), open: open)
    }

    /// The pipeline the component attaches: what its body hands the host.
    var pipeline: Pipeline<Samples, Samples> {
        switch kind {
        case .spectrogram: HeatmapAnalysis.spectrogram.pipeline(processing: processing, frame: frame, melBands: nil, into: heatmap)
        case .waveform: WaveformAnalysis.pipeline(processing: processing, into: waveform)
        }
    }

    /// Columns, or pairs, one block adds to the feed.
    var itemsPerBlock: Int { kind == .spectrogram ? 1 : 2 }

    var isLive: Bool { kind == .spectrogram ? heatmap.isLive : waveform.isLive }
    var generation: UInt64 { kind == .spectrogram ? heatmap.generation : waveform.generation }
    var columnCount: Int { kind == .spectrogram ? heatmap.columnCount : waveform.columnCount }

    /// The feed the view owns now, with the appearance the component starts from.
    var content: SurfaceContent {
        kind == .spectrogram ? .heatmap(heatmap, HeatmapAppearance()) : .waveform(waveform, WaveformAppearance())
    }

    /// The feed the view owns now.
    var feed: FeedReference { content.feed }

    private func makeFeed() {
        heatmap = HeatmapFeed(history: HeatmapAnalysis.history)
        waveform = WaveformFeed(history: WaveformAnalysis.history)
        listen()
    }

    /// The view comes into the hierarchy.
    func appear() {
        model.appear(pipeline, on: currentSource, engine: currentEngine, renderProbe: render, hostProbe: host)
    }

    /// The view is evaluated again: its body hands the host what it makes now.
    func evaluate() {
        model.show(pipeline, on: currentSource, engine: currentEngine)
    }

    /// The view is given another source: it makes another feed, and is evaluated again.
    func give(_ other: GatedSource) {
        currentSource = other
        makeFeed()
        evaluate()
    }

    /// The environment names another engine: the view is evaluated again.
    func use(_ other: DSPEngine) {
        currentEngine = other
        evaluate()
    }

    /// The view leaves the hierarchy, and makes the feed of the time it comes back.
    func leave() {
        model.disappear()
        makeFeed()
        evaluate()
    }

    /// Waits until the attachment is made and runs, and the feed has said that it is live.
    func running() async {
        #expect(await eventually(timeout: patience) { self.host.session?.state == .running && self.isLive && self.announced }, "attached, started, and the feed is live: \(host.failures)")
        await mainQueueDrained()
    }

    /// Waits until the feed has said whether it is live.
    func live(_ expected: Bool) async {
        #expect(await eventually(timeout: patience) { self.isLive == expected && self.announced == expected })
        await mainQueueDrained()
    }

    /// The samples of the blocks numbered by `range`: no two blocks alike.
    static func blocks(_ range: Range<Int>) -> [Float] {
        FeedWriter.columns(range, rows: 16).map { $0 / 90 }
    }

    /// Sends blocks, numbered by `range`, through the source the view has now, and waits
    /// until the feed holds what they make.
    func send(_ range: Range<Int>) async {
        let before = generation
        let values = Self.blocks(range)
        #expect(currentSource.write(values) == values.count, "the ring took every frame")
        let wanted = before + UInt64(range.count * itemsPerBlock)
        #expect(await eventually(timeout: patience) { self.generation >= wanted }, "what was sent arrived in the feed")
    }

    /// Waits until every update that was sent has reached the session.
    func settled() async {
        #expect(await eventually(timeout: patience) { self.host.isIdle }, "every update has landed")
    }

    /// The engine the tests ask whether a feed or a source is free: one for all of them.
    private static let prober = DSPEngine(blockSize: 16)

    /// True when no attachment writes `feed`: another pipeline can claim it (ATT-5). The
    /// attachment made to find out is ended at once.
    static func isFree(_ feed: FeedReference) async -> Bool {
        let pipeline: Pipeline<Samples, Samples>
        switch feed {
        case .heatmap(let feed):
            pipeline = Pipeline<Samples, Samples>().tap { $0.appending(TestColumns(rows: 16, axis: .indices(count: 16))).emit(to: feed) }
        case .waveform(let feed):
            pipeline = WaveformAnalysis.pipeline(processing: nil, into: feed)
        }
        guard let session = try? await prober.attach(pipeline, to: GatedSource()) else { return false }
        session.detach()
        return true
    }

    /// True when no engine keeps `source`: another engine can attach to it. The attachment
    /// made to find out is ended at once.
    static func isFree(_ source: any SampleSource) async -> Bool {
        guard let session = try? await prober.attach(Pipeline<Samples, Samples>(), to: source) else { return false }
        session.detach()
        return true
    }
}

/// Waits until `condition`, which may suspend, holds, looking again every five milliseconds;
/// false when it does not hold within `timeout` seconds. The timeout only bounds a failure.
@MainActor
func eventuallyAwaiting(timeout: Double = patience, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

// MARK: A source-fed component, hosted

/// Everything a hosted test sees of a source-fed component: the counters of its surface, of
/// its axes and of its attachment, and the engine it attaches on.
@MainActor
final class SourceWatch {
    let probe = RenderProbe()
    let inspector = SurfaceInspector()
    let axes = AxisProbe()
    let host = PipelineHostProbe()
    let engine: DSPEngine

    init(blockSize: Int = 512) {
        engine = DSPEngine(blockSize: blockSize)
    }

    /// The feed the component owns, once its surface exists.
    var heatmap: HeatmapFeed? {
        if case .heatmap(let feed, _)? = inspector.contents.last { return feed }
        return nil
    }

    var waveform: WaveformFeed? {
        if case .waveform(let feed, _)? = inspector.contents.last { return feed }
        return nil
    }

    /// Columns, or pairs, the component's feed holds.
    var columnCount: Int { heatmap?.columnCount ?? waveform?.columnCount ?? 0 }

    /// Hosts `content` with this watch in its environment.
    func host<Value, Content: View>(
        _ initial: Value, _ handle: StateHandle<Value>, size: CGSize = CGSize(width: 240, height: 160),
        @ViewBuilder content: @escaping (Binding<Value>) -> Content
    ) -> Hosted<some View> {
        let probe = probe, inspector = inspector, axes = axes, host = host, engine = engine
        return Hosted(size: size, Stateful(initial, handle) { binding in
            content(binding)
                .dspEngine(engine)
                .environment(\.dspRenderProbe, probe)
                .environment(\.dspSurfaceInspector, inspector)
                .environment(\.dspAxisProbe, axes)
                .environment(\.dspPipelineHostProbe, host)
        })
    }

    /// Waits until the component's attachment is made and its session has reached `state`.
    func session(reaches state: SessionState) async {
        #expect(await eventually(timeout: patience) { self.host.session?.state == state }, "the session is \(state): \(String(describing: host.session?.state)), \(host.failures)")
    }

    /// Waits until the component's session runs, its feed is live, its surface has drawn its
    /// first frame, and everything that follows from those has been drawn: the Metal context
    /// arrives when it is made, the axes are labelled once the feed has its shape, and a feed
    /// that turns live is one more look at it. When this returns nothing more is drawn
    /// unless something changes.
    func settled() async {
        #expect(await eventually(timeout: patience) {
            self.host.session?.state == .running && (self.heatmap?.isLive ?? self.waveform?.isLive ?? false) && self.probe.draws >= 1
        }, "attached, started, the feed is live and the surface has drawn: \(host.failures)")
        await mainQueueDrained()
        var seen = (-1, -1)
        while seen != (probe.draws, axes.draws) {
            seen = (probe.draws, axes.draws)
            await displayFrames(4)
        }
    }
}
