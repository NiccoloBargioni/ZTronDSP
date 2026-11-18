import Foundation
import ZTronDSP

// The extension guide, row 5 of §5.11.1: a sink (Docs/ExtensionGuide.md).

// snippet:begin meter-sink
/// A sink for a scalar track that keeps the newest value and the largest one: what a level
/// meter with a peak-hold mark reads.
///
/// Threading: `claim` and `release` run on the control context. `write` runs on the analysis
/// thread and does no more than load and store single atomic words (RT-2, RT-4). `value`,
/// `peak` and `resetPeak()` may be used on any thread. The cells are the only state, each
/// written by one thread: that is why the class may say `@unchecked Sendable`.
public final class PeakHoldMeter: FeatureSink, @unchecked Sendable {
    public typealias Domain = Scalar

    private let latest = ztd_atomic_create(UInt64(Float(0).bitPattern))
    private let held = ztd_atomic_create(UInt64((-Float.infinity).bitPattern))
    private let resetRequested = ztd_atomic_create(0)

    /// Any thread; allocates the three cells.
    public init() {}

    deinit {
        if let latest { ztd_atomic_destroy(latest) }
        if let held { ztd_atomic_destroy(held) }
        if let resetRequested { ztd_atomic_destroy(resetRequested) }
    }

    /// An attachment is about to write the sink: it starts from nothing. The engine lets one
    /// live attachment write a sink and refuses a second (ATT-5). Control context.
    public func claim(axis: FeedAxis?, environment: DSPEnvironment) throws(DSPError) {
        guard let latest, let held, resetRequested != nil else {
            throw .resourceAllocationFailed(what: "the cells of a PeakHoldMeter")
        }
        ztd_atomic_store(latest, UInt64(Float(0).bitPattern))
        ztd_atomic_store(held, UInt64((-Float.infinity).bitPattern))
    }

    /// Takes one value. Analysis thread; allocation-free. The frame is a borrowed view.
    public func write(_ frame: FrameView) {
        guard let scalar = frame.scalar, let latest, let held, let resetRequested else { return }
        ztd_atomic_store(latest, UInt64(scalar.value.bitPattern))
        // A value without confidence repeats the one before it: it sets no mark.
        guard scalar.confidence > 0 else { return }
        let mark = Float(bitPattern: UInt32(truncatingIfNeeded: ztd_atomic_load(held)))
        if ztd_atomic_exchange(resetRequested, 0) != 0 || scalar.value > mark {
            ztd_atomic_store(held, UInt64(scalar.value.bitPattern))
        }
    }

    /// The attachment is gone. Control context.
    public func release() {}

    /// The newest value; 0 before the first. Any thread.
    public var value: Float {
        latest.map { Float(bitPattern: UInt32(truncatingIfNeeded: ztd_atomic_load($0))) } ?? 0
    }

    /// The largest value since the sink was claimed or the mark was reset; `-.infinity` before
    /// the first. Any thread.
    public var peak: Float {
        held.map { Float(bitPattern: UInt32(truncatingIfNeeded: ztd_atomic_load($0))) } ?? -.infinity
    }

    /// Lets the mark fall to the next value that arrives. Any thread: the request is one
    /// atomic word that the writer takes, so the mark keeps its one writer.
    public func resetPeak() {
        if let resetRequested { ztd_atomic_store(resetRequested, 1) }
    }
}
// snippet:end meter-sink
