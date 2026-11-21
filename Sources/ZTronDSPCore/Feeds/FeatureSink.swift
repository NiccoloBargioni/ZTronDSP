/// Where frames leave a pipeline (§5.2, §5.11.1): adopt it to write a sink of your own, and
/// hand it to `Emit(to:)`.
///
/// A sink has one writer (ATT-5): the engine lets one live attachment write it and refuses a
/// second with `DSPError.sinkInUse`. `claim` is called when that attachment is made, `release`
/// when it is detached or updated away from the sink.
///
/// Threading: `claim` and `release` run on the control context and may allocate. `write` runs
/// on the analysis thread and is bound by RT-2: memory only, no allocation, no lock, no
/// logging. The frame is a borrowed view, valid for the call; copy what must outlive it.
public protocol FeatureSink: AnyObject, Sendable {
    /// The domain whose frames the sink takes. `Emit(to:)` compiles only after that domain.
    associatedtype Domain: SignalDomain

    /// Prepares the sink for an attachment. `axis` says what the rows of a frame are, when the
    /// frames have rows; `environment` is the environment at the `Emit` (ENV-4).
    func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError)

    /// Takes one frame.
    func write(_ frame: FrameView)

    /// The attachment that claimed the sink is gone.
    func release()
}

/// What the plan writes to: the engine's own view of a sink, whatever it is.
protocol PlanSink: AnyObject, Sendable {
    /// Prepares the sink for an attachment: `format` is the shape of the frames it will get.
    func claim(axis: FeedAxis?, environment: DSPEnvironment, domain: DomainTag, format: FrameFormat) throws(DSPError)
    func write(_ frame: FrameView)
    func release()
    /// Whether the branch that feeds the sink is running (ACT-11). Control context.
    func setLive(_ live: Bool)
    /// A changed branch feeds the sink from now on: what it held is stale (SWAP-3). Called by
    /// the writer, on the analysis thread, at the exchange; allocation-free.
    func clearForNewBranch()
    /// Gives the sink the engine's attention word: a sink that needs the control context after
    /// a write stores a non-zero value there, and `service()` follows. `nil` takes it away.
    /// Control context, while no writer runs.
    func connect(attention: OpaquePointer?)
    /// The control context's turn after the analysis thread asked for attention.
    func service()
    /// The system is critically short of memory (MEM-1): a sink that was created with room to
    /// give gives it. Returns whether it did. Control context.
    func trimForMemoryPressure() -> Bool
}

extension PlanSink {
    func setLive(_ live: Bool) {}
    func clearForNewBranch() {}
    func connect(attention: OpaquePointer?) {}
    func service() {}
    func trimForMemoryPressure() -> Bool { false }
}

/// A sink that a pipeline names in an `Emit`: a feed, a stream, or a sink written outside the
/// package behind its adapter. It has an identity to be claimed by (ATT-5) and a name for the
/// error that says it is in use. The latest-value slot behind a binding is written by a plan
/// and named by no pipeline.
protocol NamedSink: PlanSink {
    /// What errors call the sink.
    var sinkName: String { get }
}

/// A sink written outside the package, as the plan sees it.
final class FeatureSinkAdapter<Sink: FeatureSink>: NamedSink {
    let sink: Sink

    init(_ sink: Sink) {
        self.sink = sink
    }

    var sinkName: String { String(describing: Sink.self) }

    func claim(axis: FeedAxis?, environment: DSPEnvironment, domain: DomainTag, format: FrameFormat) throws(DSPError) {
        try sink.claim(axis: axis, environment: environment)
    }

    func write(_ frame: FrameView) {
        sink.write(frame)
    }

    func release() {
        sink.release()
    }
}

/// A sink as a stage description holds it. Sinks that are objects compare by identity; a
/// binding has no identity, so all bound results of one kind compare equal (OUT-4).
struct SinkDescription: Hashable, Sendable {
    enum Target: Sendable {
        /// A feed, a stream, a callback or a sink written outside the package.
        case object(any NamedSink, identity: ObjectIdentifier)
        /// A SwiftUI binding that receives results on the main thread (§5.10).
        case result(BoundResult)
        /// The latest-value slot a compiled plan writes for a binding of this kind. A plan
        /// keeps the kind and never the binding itself, so releasing the captured bindings
        /// releases them everywhere (BIND-6).
        case slot(BoundResult.Kind)
    }

    let target: Target
    /// Which domains the sink can represent (O-11).
    let accepts: DomainRule

    /// The identity under which the sink is claimed; `nil` for a binding, which cannot be.
    var identity: ObjectIdentifier? {
        if case .object(_, let identity) = target { return identity }
        return nil
    }

    var name: String {
        switch target {
        case .object(let sink, _): sink.sinkName
        case .result(let result): result.name
        case .slot(let kind): kind.name
        }
    }

    static func == (lhs: SinkDescription, rhs: SinkDescription) -> Bool {
        switch (lhs.target, rhs.target) {
        case (.object(_, let a), .object(_, let b)): a == b
        case (.result(let a), .result(let b)): a == b
        case (.slot(let a), .slot(let b)): a == b
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch target {
        case .object(_, let identity): hasher.combine(identity)
        case .result(let result): hasher.combine(result)
        case .slot(let kind): hasher.combine(kind)
        }
    }
}

/// The registry behind ATT-5: which sinks have a live writer. Control context only.
enum SinkRegistry {
    private static let claimed = Locked<Set<ObjectIdentifier>>([])

    /// Marks every sink of `identities` as written, or throws `sinkInUse` and marks none: a
    /// sink named twice in the list, or already claimed by a live attachment.
    static func claim(_ sinks: [(identity: ObjectIdentifier, name: String)]) throws(DSPError) {
        let failure: String? = claimed.withLock { set in
            var seen = Set<ObjectIdentifier>()
            for sink in sinks {
                if set.contains(sink.identity) || !seen.insert(sink.identity).inserted { return sink.name }
            }
            set.formUnion(seen)
            return nil
        }
        if let failure { throw .sinkInUse(sink: failure) }
    }

    static func release(_ identities: [ObjectIdentifier]) {
        claimed.withLock { set in
            for identity in identities { set.remove(identity) }
        }
    }

    static func isClaimed(_ identity: ObjectIdentifier) -> Bool {
        claimed.withLock { $0.contains(identity) }
    }
}
