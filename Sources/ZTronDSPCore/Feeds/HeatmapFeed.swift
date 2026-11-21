/// Where a pipeline leaves frames for a heat map: a spectrogram, a mel spectrogram, chroma, a
/// tempogram, a cepstrum, lags (§5.2). It takes any domain whose frame is a vector of reals.
///
/// A feed is created by the app with its history, in columns, and handed to `Emit(to:)` or to
/// a recipe's `to:`. One live attachment writes it (ATT-5); any number of readers, a view's
/// renderer among them, take the columns that arrived since they last looked. Nothing in a
/// feed is observable: a view polls `generation`, one atomic load, on its display tick (V-2).
///
/// ```swift
/// let melFeed = HeatmapFeed(history: 940)
/// let session = try await engine.attach(Pipeline { MelSpectrogram(frame: 2_048, hop: 512, bands: 128, to: melFeed) }, to: source)
/// ```
///
/// Threading: every member here is for any thread except the analysis thread, and none of
/// them blocks the writer. Reading allocates nothing; `snapshot()` allocates the copy it
/// returns.
public final class HeatmapFeed: Sendable {
    let store: ColumnStore

    /// A feed that keeps the newest `history` columns.
    ///
    /// - Parameters:
    ///   - history: the columns the feed keeps.
    ///   - minimumHistory: the columns the feed may be cut down to when the system is
    ///     critically short of memory (MEM-1). The default, `nil`, means `history`: such a feed
    ///     is never trimmed.
    public init(history: Int = 512, minimumHistory: Int? = nil) {
        store = ColumnStore(history: history, minimumHistory: minimumHistory)
    }

    /// Columns the feed keeps: what it was created with, or its minimum after it was trimmed.
    public var history: Int { store.layout?.capacity ?? store.declaredHistory }

    /// Columns the feed may be trimmed to under memory pressure.
    public var minimumHistory: Int { store.minimumHistory }

    /// Values per column: the bins, bands or classes of the frames the feed receives. 0 until
    /// a pipeline that writes the feed is attached.
    public var rowCount: Int { store.layout?.rowCount ?? 0 }

    /// Columns the feed holds now.
    public var columnCount: Int { store.columnCount }

    /// What the rows are, as the pipeline that writes the feed knows it (VC-5).
    public var axis: FeedAxis? { store.layout?.axis }

    /// The environment at the feed's `Emit`: the feature rate, the frame and hop sizes, the
    /// latency up to that point (ENV-4).
    public var environment: DSPEnvironment? { store.layout?.environment }

    /// True while the session that writes the feed is running and the branch that feeds it is
    /// not suspended (ACT-11). A view runs its display link only while this holds.
    public var isLive: Bool { store.isLive }

    /// One atomic load. It moves whenever there is something new to read: a column, a clear,
    /// a trim, another shape. A reader that sees the value it saw last has nothing to do.
    public var generation: UInt64 { store.generation }

    /// Copies the columns that arrived since `cursor` last read into `values`, oldest first,
    /// `rowCount` values per column, and moves the cursor past them. A buffer too small for
    /// all of them takes the oldest that fit; read again for the rest. With `times`, each
    /// column's time in seconds since the session started is copied alongside.
    ///
    /// A reader that lags by more than the history skips what was overwritten and is told how
    /// much; it never blocks the writer.
    public func read(
        _ cursor: inout FeedCursor, into values: UnsafeMutableBufferPointer<Float>, times: UnsafeMutableBufferPointer<Double>? = nil
    ) -> FeedRead {
        store.read(&cursor, into: values, times: times)
    }

    /// An immutable copy of the feed's history with its axis and the time of each column,
    /// consistent even while the feed is being written (WP-341).
    public func snapshot() -> FeedSnapshot {
        guard let (layout, values, times) = store.snapshot() else {
            return FeedSnapshot(content: .heatmap, axis: nil, environment: nil, rowCount: 0, values: [], times: [])
        }
        return FeedSnapshot(content: .heatmap, axis: layout.axis, environment: layout.environment, rowCount: layout.rowCount, values: values, times: times)
    }

    /// Calls `handler` on the main actor whenever `isLive` changes, until the returned handle
    /// is cancelled or released.
    public func onLivenessChange(_ handler: @escaping @MainActor @Sendable (Bool) -> Void) -> FeedObservation {
        store.observeLiveness(handler)
    }
}

extension HeatmapFeed: NamedSink {
    var sinkName: String { "HeatmapFeed" }

    func claim(axis: FeedAxis?, environment: DSPEnvironment, domain: DomainTag, format: FrameFormat) throws(DSPError) {
        let rows: Int
        if case .real(let count) = format { rows = count } else { rows = axis?.rowCount ?? 0 }
        guard rows >= 1 else {
            throw .unsupportedConfiguration(reason: "a HeatmapFeed takes frames of at least one value, and a \(domain) here has none")
        }
        try store.configure(rowCount: rows, axis: axis ?? .indices(count: rows), environment: environment, columnDuration: 0)
    }

    func write(_ frame: FrameView) {
        guard let real = frame.real, let values = real.values.baseAddress else { return }
        store.append(values, count: real.count, time: frame.time)
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
