/// Where a pipeline leaves a waveform's envelope: one (minimum, maximum) pair per reduction
/// bucket, for a `WaveformView` (§5.2, §8.2).
///
/// Live, the feed is a ring of the newest `history` pairs, written as they are reduced and
/// scrolled by the view. For a static overview of a whole signal, take a `snapshot()` and
/// its `pyramid()`: the pairs reduced again and again by two, so that a view samples the
/// level that matches its zoom.
///
/// One live attachment writes the feed (ATT-5); any number of readers take the pairs that
/// arrived since they last looked.
///
/// Threading: every member here is for any thread except the analysis thread, and none of
/// them blocks the writer.
public final class WaveformFeed: Sendable {
    let store: ColumnStore

    /// A feed that keeps the newest `history` pairs.
    ///
    /// - Parameter minimumHistory: the pairs the feed may be cut down to when the system is
    ///   critically short of memory (MEM-1). The default, `nil`, means `history`.
    public init(history: Int = 2_048, minimumHistory: Int? = nil) {
        store = ColumnStore(history: history, minimumHistory: minimumHistory)
    }

    /// Pairs the feed keeps.
    public var history: Int { store.layout?.capacity ?? store.declaredHistory }

    /// Pairs the feed may be trimmed to under memory pressure.
    public var minimumHistory: Int { store.minimumHistory }

    /// Pairs the feed holds now.
    public var columnCount: Int { store.columnCount }

    /// The environment at the feed's `Emit` (ENV-4).
    public var environment: DSPEnvironment? { store.layout?.environment }

    /// True while the session that writes the feed is running and the branch that feeds it is
    /// not suspended (ACT-11).
    public var isLive: Bool { store.isLive }

    /// One atomic load. It moves whenever there is something new to read.
    public var generation: UInt64 { store.generation }

    /// Copies the pairs that arrived since `cursor` last read into `pairs`, oldest first, as
    /// minimum then maximum, two values per pair, and moves the cursor past them. With
    /// `times`, each pair's time in seconds since the session started is copied alongside.
    public func read(
        _ cursor: inout FeedCursor, into pairs: UnsafeMutableBufferPointer<Float>, times: UnsafeMutableBufferPointer<Double>? = nil
    ) -> FeedRead {
        store.read(&cursor, into: pairs, times: times)
    }

    /// An immutable copy of the feed's history, consistent even while the feed is being
    /// written (WP-341).
    public func snapshot() -> FeedSnapshot {
        guard let (layout, values, times) = store.snapshot() else {
            return FeedSnapshot(content: .waveform, axis: nil, environment: nil, rowCount: 2, values: [], times: [])
        }
        return FeedSnapshot(content: .waveform, axis: nil, environment: layout.environment, rowCount: 2, values: values, times: times)
    }

    /// Calls `handler` on the main actor whenever `isLive` changes, until the returned handle
    /// is cancelled or released.
    public func onLivenessChange(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> FeedObservation {
        store.observeLiveness(handler)
    }
}

extension WaveformFeed: NamedSink {
    var sinkName: String { "WaveformFeed" }

    func claim(axis: FeedAxis?, environment: DSPEnvironment, domain: DomainTag, format: FrameFormat) throws(DSPError) {
        // The buckets of one frame follow one another at the feature rate, when there is one.
        let spacing = environment.featureRate.map { $0 > 0 ? 1 / $0 : 0 } ?? 0
        try store.configure(rowCount: 2, axis: nil, environment: environment, columnDuration: spacing)
    }

    func write(_ frame: FrameView) {
        guard let envelope = frame.envelope, let minima = envelope.minima.baseAddress, let maxima = envelope.maxima.baseAddress else { return }
        let spacing = store.columnDuration
        var index = 0
        while index < envelope.count {
            // A stack pair: no allocation.
            var pair = (minima[index], maxima[index])
            withUnsafePointer(to: &pair) { pointer in
                pointer.withMemoryRebound(to: Float.self, capacity: 2) { store.append($0, count: 2, time: frame.time + Double(index) * spacing) }
            }
            index += 1
        }
    }

    func release() {
        store.drain()
    }

    func setLive(_ live: Bool) {
        store.setLive(live)
    }

    func clearForNewBranch() {
        store.clear()
    }

    func service() {
        store.drain()
    }

    func trimForMemoryPressure() -> Bool {
        store.trim()
    }
}
