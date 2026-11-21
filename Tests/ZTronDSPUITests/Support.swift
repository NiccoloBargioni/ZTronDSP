import CoreGraphics
import Foundation
import Metal
import QuartzCore
import SwiftUI
import Testing
import ZTronDSPCore
import ZTronDSPMetal
import ZTronDSPTesting
@testable import ZTronDSPUI

// Support for the tests of the UI target: stages that put chosen values into a feed through
// the public API, a display clock the test fires, an off-screen surface in place of the Metal
// view, a scripted layer, and a source the test feeds by hand so that a feed is live exactly
// as long as the test wants.

// MARK: Stages written against the public API, as a stage outside the package would be

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

/// A gain with one continuous value, in decibels: a stage whose value an animation glides.
struct TestGain: SequenceStage {
    let decibels: Double

    init(decibels: Double) {
        self.decibels = decibels
    }

    var parameters: [Double] { [decibels] }

    func replacingParameters(_ values: ArraySlice<Double>) -> TestGain {
        guard let value = values.first, value != decibels else { return self }
        return TestGain(decibels: value)
    }

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        guard decibels.isFinite else { throw context.invalid("decibels", "a gain must be finite") }
        context.emit(.gain(factor: Float(pow(10, decibels / 20)), ramp: 0.010))
    }
}

/// A delay of whole samples, as an FIR: a stage that gives the main line a latency.
struct TestDelay: SequenceStage {
    let frames: Int

    func lower(_ context: inout LoweringContext) throws(DSPError) {
        var taps = [Float](repeating: 0, count: frames + 1)
        taps[frames] = 1
        context.emit(.fir(taps: taps, latency: frames))
    }
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

    /// `count` columns of `rows` values: column c holds c in its first row and a ramp above.
    static func columns(_ range: Range<Int>, rows: Int) -> [Float] {
        range.flatMap { column in (0 ..< rows).map { row in row == 0 ? Float(column) : Float(-90 + (row * 7 + column * 3) % 90) } }
    }
}

// MARK: The display clock a test fires

/// A display clock in the test's hands (the seam of WP-802). `fire()` is one tick of the
/// display; a paused clock delivers nothing, as a paused display link does.
@MainActor
final class ManualClock: FrameClock {
    var isPaused = true
    var preferredRate = 60
    var onTick: (@MainActor (CFTimeInterval) -> Void)?
    private(set) var isInvalidated = false
    private(set) var time: CFTimeInterval = 100
    /// Ticks that reached the scheduler: the main thread's wake-ups.
    private(set) var delivered = 0

    /// One tick of a display that refreshes `rate` times a second. Returns whether the tick
    /// was delivered.
    @discardableResult
    func fire(rate: Double = 60) -> Bool {
        time += 1 / rate
        guard !isPaused, !isInvalidated, let onTick else { return false }
        delivered += 1
        onTick(time)
        return true
    }

    /// `count` ticks; returns how many were delivered.
    @discardableResult
    func fire(_ count: Int, rate: Double = 60) -> Int {
        (0 ..< count).reduce(0) { delivered, _ in delivered + (fire(rate: rate) ? 1 : 0) }
    }

    func invalidate() {
        isInvalidated = true
    }
}

/// The end of a run-loop turn in the test's hands (the seam `TurnEnd`): a frame of a size
/// transition is made when the test ends the turn, as the run loop does before it waits.
@MainActor
final class ManualTurn: TurnEnd {
    var onEnd: (@MainActor () -> Void)?
    /// True from a request to the end of the turn that answers it.
    private(set) var isRequested = false
    /// Requests that were made while none was pending.
    private(set) var requests = 0
    private(set) var isInvalidated = false

    func request() {
        guard !isRequested, !isInvalidated else { return }
        isRequested = true
        requests += 1
    }

    /// The run loop is about to wait: the call that was asked for is made. Returns whether
    /// one was asked for.
    @discardableResult
    func end() -> Bool {
        guard isRequested, !isInvalidated else { return false }
        isRequested = false
        onEnd?()
        return true
    }

    func invalidate() {
        isInvalidated = true
        isRequested = false
    }
}

// MARK: The surface and the layer a test stands in for

/// An off-screen texture in the place of the Metal view (the seam `MetalSurface`): level 1 of
/// the stability suite draws into it (§8.4).
@MainActor
final class OffscreenSurface: MetalSurface {
    let context: MetalContext
    weak var coordinator: SurfaceCoordinator?
    var device: (any MTLDevice)?
    /// Whether the view resizes its drawable by itself: what the coordinator last said.
    private(set) var autoResizeDrawable = true
    /// The layer whose transaction flag is noted with every frame.
    weak var layer: ScriptedLayer?
    private(set) var target: OffscreenTarget?
    /// Times a drawable was asked for: what a tick with nothing to do must not do.
    private(set) var drawablesTaken = 0
    /// The drawable's size at every frame that was drawn.
    private(set) var drawnSizes: [CGSize] = []
    /// Whether the layer presented with its transaction at every frame that was drawn.
    private(set) var drawnWithTransaction: [Bool] = []
    /// A view that has no drawable to hand out, whatever its size, when a test says so.
    var handsOutNoDrawable = false

    var drawableSize: CGSize {
        didSet { if drawableSize != oldValue { target = nil } }
    }

    init(context: MetalContext, size: CGSize = CGSize(width: 48, height: 24)) {
        self.context = context
        drawableSize = size
    }

    func draw() {
        guard let coordinator, !handsOutNoDrawable, drawableSize.width >= 1, drawableSize.height >= 1 else { return }
        drawablesTaken += 1
        if target == nil { target = try? OffscreenTarget(context: context, width: Int(drawableSize.width), height: Int(drawableSize.height)) }
        guard let target else { return }
        let before = coordinator.probe.draws
        coordinator.render(to: target.renderPass(), presenting: nil)
        if coordinator.probe.draws > before {
            drawnSizes.append(drawableSize)
            drawnWithTransaction.append(layer?.presentsWithTransaction ?? false)
        }
    }

    func setAutoResizeDrawable(_ follows: Bool) {
        autoResizeDrawable = follows
    }

    /// What the view does when its bounds change and it resizes its drawable by itself.
    func resize(to size: CGSize) {
        guard autoResizeDrawable else { return }
        coordinator?.drawableSizeWillChange(to: size)
        drawableSize = size
    }

    /// The picture the surface shows.
    func pixels() throws -> PixelImage {
        context.waitUntilIdle()
        return try #require(target, "nothing was drawn at this size").readPixels()
    }
}

/// A layer whose sizes the test writes (the seam `SurfaceLayer`, WP-823). Like a real layer
/// it knows no scale: the geometry it gives carries the scale the surface asks with.
@MainActor
final class ScriptedLayer: SurfaceLayer {
    private var model: CGSize
    private var presentation: CGSize
    private var isAnimating = false
    /// True once the layer is gone: it has no geometry any more.
    private(set) var isGone = false
    private(set) var presentsWithTransaction = false
    /// The scales the surface asked with, in order.
    private(set) var askedScales: [CGFloat] = []

    func setPresentsWithTransaction(_ presents: Bool) {
        presentsWithTransaction = presents
    }

    init(size: CGSize) {
        model = size
        presentation = size
    }

    func geometry(scale: CGFloat) -> LayerGeometry? {
        askedScales.append(scale)
        return isGone ? nil : LayerGeometry(modelSize: model, presentationSize: presentation, isAnimating: isAnimating, scale: scale)
    }

    /// The layer is shown at `presentation` while its own size is `model`.
    func show(_ presentation: CGSize, model: CGSize, animating: Bool) {
        self.presentation = presentation
        self.model = model
        isAnimating = animating
    }

    /// The layer goes away with its view.
    func vanish() {
        isGone = true
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

    /// The source delivers another sample rate from now on, and says so.
    func changeFormat(sampleRate: Double) {
        let format = SignalFormat(sampleRate: sampleRate)
        lock.withLock { stored = format }
        continuation.yield(.formatChanged(format))
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

/// A value behind a `Binding`, counting what is written to it.
@MainActor
final class Box<Value> {
    var value: Value
    private(set) var writes = 0

    init(_ value: Value) {
        self.value = value
    }

    var binding: Binding<Value> {
        Binding(get: { self.value }, set: { self.value = $0; self.writes += 1 })
    }
}

// MARK: Waiting without sleeping blind

/// How long a test waits for a condition to hold, in seconds. What the tests wait for is done
/// off the main thread, by an engine that prepares a source and compiles a plan, by the
/// thread that runs it, by the Metal context that is made in the background, on a machine
/// that other work shares: with load averages above 600 the test process has been seen to
/// stand still for more than twenty seconds at a time. The bound is there for a failure only:
/// a passing test never waits for it, and no test asserts that anything happened within a
/// time.
let patience: Double = 120

/// Waits until `condition` holds, looking again every half millisecond; false when it does
/// not hold within `timeout` seconds. The timeout only bounds a failure: a passing test never
/// waits for it.
@MainActor
func eventually(timeout: Double = patience, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 500_000)
    }
    return condition()
}

/// Lets everything that is already on the main queue run: a liveness change that a feed has
/// announced is delivered when this returns.
@MainActor
func mainQueueDrained() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// The context every test shares: made once, on the background executor.
func sharedContext() async throws -> MetalContext {
    try await MetalContext.shared()
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
    /// What the feed last said of its liveness. A feed changes its liveness on an engine's
    /// thread and says so through the main queue a moment later, to everyone who listens in
    /// one turn: once this has heard it, a surface that shows the feed has heard it too.
    private let announced: Box<Bool>
    private let observation: FeedObservation

    init(_ kind: SurfaceKind = .heatmap, rows: Int = 16, history: Int = 1_024, axis: FeedAxis? = nil, hop: Int? = nil) async throws {
        self.kind = kind
        self.rows = rows
        engine = DSPEngine(blockSize: rows)
        source = HandFedSource()
        heatmap = HeatmapFeed(history: history)
        waveform = WaveformFeed(history: history)
        branch = Switch(true)
        let announced = Box(false)
        self.announced = announced
        observation = kind == .heatmap ? heatmap.onLivenessChange { announced.value = $0 } : waveform.onLivenessChange { announced.value = $0 }
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

    /// The feed with the appearance every component starts from.
    var content: SurfaceContent {
        kind == .heatmap ? .heatmap(heatmap, HeatmapAppearance()) : .waveform(waveform, WaveformAppearance())
    }

    /// Starts the session and waits until the feed has said that it is live.
    func start() async throws {
        try session.start()
        #expect(await eventually { isLive && announced.value }, "the feed of a running session is live, and has said so")
        await mainQueueDrained()
    }

    /// Stops the session and waits until the feed has said that it is not live any more.
    func stop() async {
        session.stop()
        #expect(await eventually { !isLive && !announced.value })
        await mainQueueDrained()
    }

    /// Suspends or resumes the branch that writes the feed, through its bound switch (ACT-11).
    func setBranchActive(_ active: Bool) async {
        branch.isOn = active
        session.syncBindings()
        #expect(await eventually { isLive == active && announced.value == active })
        await mainQueueDrained()
    }

    /// Sends blocks, numbered by `range`, and waits until the feed holds what they make.
    func send(_ range: Range<Int>) async {
        let before = generation
        let values = FeedWriter.columns(range, rows: rows)
        #expect(source.write(values) == values.count, "the ring took every frame")
        let wanted = before + UInt64(range.count * itemsPerBlock)
        #expect(await eventually { generation >= wanted }, "what was sent arrived in the feed")
    }
}

// MARK: A coordinator with everything around it in the test's hands

/// Level 1 of the stability suite (§8.4): a coordinator with a clock the test fires, an
/// off-screen surface in the place of the Metal view, and a probe.
@MainActor
struct Stage {
    let context: MetalContext
    let clock: ManualClock
    /// The ends of the run-loop turns, which the test decides.
    let turns: ManualTurn
    let surface: OffscreenSurface
    let probe: RenderProbe
    let coordinator: SurfaceCoordinator
    private(set) var input: SurfaceInput

    /// - Parameters:
    ///   - probe: the probe the surface counts into; `nil` gives it one of its own. A
    ///     source-fed component counts its surface and its attachment into one probe.
    ///   - displayScale: pixels per point of the display, as SwiftUI would report them.
    ///   - isSceneInBackground: whether the scene phase the view reads is `.background`.
    init(
        _ content: SurfaceContent, maximumFrameRate: Int = 60, isPresented: Bool = true, size: CGSize = CGSize(width: 48, height: 24),
        probe: RenderProbe? = nil, displayScale: CGFloat = 2, isSceneInBackground: Bool = false
    ) async throws {
        context = try await sharedContext()
        clock = ManualClock()
        turns = ManualTurn()
        self.probe = probe ?? RenderProbe()
        surface = OffscreenSurface(context: context, size: size)
        input = SurfaceInput(content: content, maximumFrameRate: maximumFrameRate, isPresented: isPresented, size: nil, probe: self.probe,
                             displayScale: displayScale, isSceneInBackground: isSceneInBackground)
        coordinator = SurfaceCoordinator(input: input, clock: clock, turns: turns, context: context)
        surface.coordinator = coordinator
        coordinator.attach(surface)
    }

    /// One display tick; returns whether the clock delivered it. The turn the tick came in
    /// is not over: what SwiftUI does after the tick comes next, then ``endTurn()``.
    @discardableResult
    func tick() -> Bool {
        clock.fire()
    }

    /// The run loop is about to wait: a frame the surface asked to make at the end of the
    /// turn is made. Returns whether the surface had asked.
    @discardableResult
    func endTurn() -> Bool {
        turns.end()
    }

    /// One whole frame of the display in which nothing else happens: the tick, and the end
    /// of its turn. Returns whether the clock delivered the tick.
    @discardableResult
    func frame() -> Bool {
        let ticked = clock.fire()
        turns.end()
        return ticked
    }

    /// Frames until the display link pauses; returns the ticks it took. A link that never
    /// pauses, because the feed is live, is given `limit` ticks.
    @discardableResult
    func settle(limit: Int = 8) -> Int {
        var ticks = 0
        turns.end()
        while ticks < limit, clock.fire() {
            turns.end()
            ticks += 1
        }
        return ticks
    }

    /// What `updateUIView` does with another content.
    mutating func show(_ content: SurfaceContent) {
        input.content = content
        coordinator.update(input)
    }

    mutating func setPresented(_ presented: Bool) {
        input.isPresented = presented
        coordinator.update(input)
    }

    mutating func setMaximumFrameRate(_ rate: Int) {
        input.maximumFrameRate = rate
        coordinator.update(input)
    }

    /// The size probe of the SwiftUI wrapper reports `size`.
    mutating func report(size: CGSize) {
        input.size = size
        coordinator.update(input)
    }

    /// SwiftUI reports another scale of the display.
    mutating func setDisplayScale(_ scale: CGFloat) {
        input.displayScale = scale
        coordinator.update(input)
    }

    /// The scene phase the view reads is `.background`, or it is not.
    mutating func setSceneInBackground(_ isBackground: Bool) {
        input.isSceneInBackground = isBackground
        coordinator.update(input)
    }

    /// The surface's layer is this one from now on: the test writes its geometry.
    func adopt(_ layer: ScriptedLayer) {
        coordinator.layer = layer
        surface.layer = layer
    }

    /// `updateUIView` with what the surface already shows.
    func updateAgain() {
        coordinator.update(input)
    }

    var isRunning: Bool { coordinator.scheduler.isRunning }
}
