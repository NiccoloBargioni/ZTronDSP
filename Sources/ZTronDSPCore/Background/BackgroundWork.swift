import Dispatch

/// The executor behind every analysis and every export (§9.2, BG-1…BG-3): `async` work that
/// never runs on the main thread, on the analysis thread or on the I/O thread.
///
/// What comes back is an immutable `Sendable` value (BG-2). The work can be cancelled: it
/// checks between its steps, and a cancelled call throws `DSPError.cancelled` (BG-3).
///
/// ```swift
/// let report = try await BackgroundWork.run { checkpoint in
///     let poles = try findPoles()
///     try checkpoint.check()          // between steps
///     return try buildReport(poles)
/// }
/// ```
public enum BackgroundWork {
    /// The queue all background work runs on: concurrent, utility quality of service.
    static let queue = DispatchQueue(label: "com.zombietron.ztrondsp.background", qos: .utility, attributes: .concurrent)

    /// What a piece of work asks, between its steps, whether it should go on.
    public struct Checkpoint: Sendable {
        let state: Locked<Bool>

        /// Throws `DSPError.cancelled` when the task that awaits the work was cancelled.
        /// Cheap; call it between steps, not inside inner loops.
        public func check() throws(DSPError) {
            if state.get() { throw .cancelled }
        }

        /// True when the task that awaits the work was cancelled.
        public var isCancelled: Bool { state.get() }
    }

    /// Runs `work` on the background executor and returns its result.
    ///
    /// May be called from any context, the main actor included; the caller suspends and the
    /// work runs on a utility-priority thread. Cancelling the calling task is seen by the
    /// work at its next `checkpoint.check()`; a call that is already cancelled does not start.
    ///
    /// - Throws: whatever `work` throws, or `DSPError.cancelled`.
    public static func run<Result: Sendable>(
        _ work: @escaping @Sendable (Checkpoint) throws(DSPError) -> Result
    ) async throws(DSPError) -> Result {
        let cancelled = Locked(false)
        let checkpoint = Checkpoint(state: cancelled)
        let outcome: Swift.Result<Result, DSPError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    do throws(DSPError) {
                        try checkpoint.check()
                        let value = try work(checkpoint)
                        try checkpoint.check()
                        continuation.resume(returning: .success(value))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
        } onCancel: {
            cancelled.set(true)
        }
        return try outcome.get()
    }

    /// True on a thread of the background executor. For assertions and tests.
    public static var isCurrent: Bool {
        DispatchQueue.getSpecific(key: marker) == true
    }

    private static let marker: DispatchSpecificKey<Bool> = {
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        return key
    }()
}
