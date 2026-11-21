/// A sink that calls a closure with every frame, on the analysis thread (§5.2).
///
/// This is the advanced way out of a pipeline: there is nothing between the plan and the
/// closure. The closure is therefore bound by RT-2: memory and arithmetic only, no
/// allocation, no lock, no logging, and it returns quickly. The frame is a borrowed view,
/// valid for the call. To take frames on another thread at leisure, use a `FeatureStream`.
///
/// Like every sink it has one writer (ATT-5).
///
/// Create it on any thread except the analysis thread; creating one allocates. `write` does
/// not allocate of its own: what it costs is the closure's.
public final class FeatureCallback<Domain: SignalDomain>: FeatureSink {
    private let body: @Sendable (FrameView) -> Void

    /// - Parameter body: called on the analysis thread with every frame; bound by RT-2.
    public init(_ body: @escaping @Sendable (FrameView) -> Void) {
        self.body = body
    }

    /// Nothing to prepare: the closure takes frames of any shape. Control context.
    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {}

    /// Hands `frame` to the closure. Analysis thread; allocates nothing of its own.
    public func write(_ frame: FrameView) {
        body(frame)
    }

    /// Nothing to give back. Control context.
    public func release() {}
}
