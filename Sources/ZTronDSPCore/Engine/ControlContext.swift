import Foundation

/// The control context of one engine (§4.3): a serial utility queue on which everything that
/// changes the shape of what runs is done, one thing at a time. Filters are designed here,
/// plans compiled, memory allocated and freed. It may allocate, lock and wait; the analysis
/// thread never waits for it.
final class ControlContext: Sendable {
    let queue: DispatchQueue
    private let key = DispatchSpecificKey<Bool>()

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
        queue.setSpecific(key: key, value: true)
    }

    /// True on the control queue of this engine.
    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }

    /// Runs `work` on the control queue and waits for it. Called on the queue itself, it runs
    /// in place.
    func sync<T>(_ work: () throws(DSPError) -> T) throws(DSPError) -> T {
        if isCurrent { return try work() }
        let result: Result<T, DSPError> = queue.sync {
            do throws(DSPError) {
                return .success(try work())
            } catch {
                return .failure(error)
            }
        }
        return try result.get()
    }

    /// Runs `work` on the control queue, later.
    func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Runs `work` on the control queue and suspends the caller until it is done.
    func run<T: Sendable>(_ work: @escaping @Sendable () throws(DSPError) -> T) async throws(DSPError) -> T {
        let result: Result<T, DSPError> = await withCheckedContinuation { continuation in
            queue.async {
                do throws(DSPError) {
                    continuation.resume(returning: .success(try work()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        return try result.get()
    }
}

/// Which engine a source is attached to. A source carries the attachments of one engine at a
/// time (ATT-6): its ring, its events and its clock have one consumer.
enum SourceRegistry {
    private static let owners = Locked<[ObjectIdentifier: ObjectIdentifier]>([:])

    /// Records that `engine` runs `source`, or throws when another engine does.
    static func claim(_ source: ObjectIdentifier, for engine: ObjectIdentifier) throws(DSPError) {
        let taken = owners.withLock { owners -> Bool in
            if let owner = owners[source] { return owner != engine }
            owners[source] = engine
            return false
        }
        if taken {
            throw .sourceUnavailable(reason: "the source is attached to another engine; a source carries the attachments of one engine")
        }
    }

    static func release(_ source: ObjectIdentifier, from engine: ObjectIdentifier) {
        owners.withLock { owners in
            if owners[source] == engine { owners[source] = nil }
        }
    }
}

/// Listens to each source's events once, for as long as the source lives, and passes them to
/// whichever hub runs the source at the moment.
///
/// An `AsyncStream` has one consumer and ends for good when that consumer is cancelled, so the
/// listener is never cancelled: a source that is detached and attached again keeps its voice.
/// The listener ends by itself when the source ends its stream, which a source does when it
/// is released.
enum SourceEventRouter {
    private final class Route: @unchecked Sendable {
        let handler = Locked<(@Sendable (SourceEvent) -> Void)?>(nil)
        /// The source the route listens to: an address is reused once its object is gone.
        private(set) weak var source: (any SampleSource)?

        init(_ source: any SampleSource) {
            self.source = source
        }
    }

    private static let routes = Locked<[ObjectIdentifier: Route]>([:])

    /// Sends the events of `source` to `handler` from now on.
    static func route(_ source: any SampleSource, to handler: @escaping @Sendable (SourceEvent) -> Void) {
        let identity = ObjectIdentifier(source)
        let (route, isNew) = routes.withLock { routes -> (Route, Bool) in
            if let existing = routes[identity], existing.source === source { return (existing, false) }
            let created = Route(source)
            routes[identity] = created
            return (created, true)
        }
        route.handler.set(handler)
        guard isNew else { return }
        let events = source.events
        Task.detached(priority: .utility) {
            for await event in events {
                route.handler.get()?(event)
            }
            routes.withLock { routes in
                if routes[identity] === route { routes[identity] = nil }
            }
        }
    }

    /// Stops passing the events of `source` on. The listener stays.
    static func unroute(_ source: any SampleSource) {
        let route = routes.withLock { $0[ObjectIdentifier(source)] }
        if let route, route.source === source { route.handler.set(nil) }
    }
}
