import SwiftUI
import ZTronDSPCore

/// The part of a session's environment that views can read from SwiftUI (ENV-4): the values
/// at the source, and the delay of the whole main line.
///
/// Positional values (the feature rate, the axis, the latency at a sink) are not here: a view
/// reads them from the feed, which records the environment at its `Emit`.
///
/// An immutable value, usable on any thread.
struct SourceEnvironment: Equatable, Sendable {
    var sampleRate: Double
    var channelCount: Int
    var latency: TimeInterval

    init(_ environment: DSPEnvironment) {
        sampleRate = environment.sampleRate
        channelCount = environment.channelCount
        latency = environment.latency
    }

    /// What is published where no session is: the reference environment, 48 kHz, mono, no
    /// latency.
    static let reference = SourceEnvironment(.reference)
}

private struct SourceEnvironmentKey: EnvironmentKey {
    static let defaultValue = SourceEnvironment.reference
}

private struct EngineKey: EnvironmentKey {
    static let defaultValue = DSPEngine.shared
}

extension EnvironmentValues {
    /// What `.dspEnvironment(_:)` published; the four public values are read off it.
    var dspSourceEnvironment: SourceEnvironment {
        get { self[SourceEnvironmentKey.self] }
        set { self[SourceEnvironmentKey.self] = newValue }
    }

    /// The engine the views of this hierarchy attach their pipelines to: `DSPEngine.shared`
    /// unless `.dspEngine(_:)` says otherwise (VC-3).
    var dspEngine: DSPEngine {
        get { self[EngineKey.self] }
        set { self[EngineKey.self] = newValue }
    }

    /// Samples per second at the source of the session that `.dspEnvironment(_:)` names;
    /// 48 000 where no session is published (ENV-4).
    ///
    /// Read it with `@Environment(\.dspSampleRate)`, on the main actor. It changes only when
    /// the session's format changes, never at data rate (V-7). Reading it does not allocate.
    public var dspSampleRate: Double { dspSourceEnvironment.sampleRate }

    /// Half the sample rate at the source: the highest frequency the signal can hold (ENV-4).
    /// Read it with `@Environment(\.dspNyquistFrequency)`, on the main actor; reading it does
    /// not allocate.
    public var dspNyquistFrequency: Double { dspSourceEnvironment.sampleRate / 2 }

    /// Channels at the source of the published session; 1 where none is published (ENV-4).
    /// Read it with `@Environment(\.dspChannelCount)`, on the main actor; reading it does not
    /// allocate.
    public var dspChannelCount: Int { dspSourceEnvironment.channelCount }

    /// The delay of the published session's whole main line, in seconds; it changes only
    /// when a plan of another topology takes over (ENV-4, REAL-5). Read it with
    /// `@Environment(\.dspLatency)`, on the main actor; reading it does not allocate.
    public var dspLatency: TimeInterval { dspSourceEnvironment.latency }
}

/// Follows a session's environment for the SwiftUI bridge.
enum EnvironmentBridge {
    /// Calls `publish` with the session's source environment now, and again whenever a new
    /// plan (a change of format, an update of another topology) leaves it with other values.
    /// Returns when the session's events end, which is when it is detached, or when the
    /// calling task is cancelled.
    ///
    /// Equal values are never published twice, and nothing here runs at data rate: the loop
    /// turns once per session event (V-2, V-7).
    @MainActor
    static func follow(_ session: PipelineSession, publish: @MainActor (SourceEnvironment) -> Void) async {
        var last: SourceEnvironment?
        // Listening starts before the first look, so that no change falls between the two.
        let events = session.events
        func look() {
            let now = SourceEnvironment(session.environment)
            guard now != last else { return }
            last = now
            publish(now)
        }
        look()
        for await event in events {
            if case .replanned = event { look() }
        }
    }
}

/// The modifier behind `.dspEnvironment(_:)`.
///
/// Threading: main actor. It writes its state when the published values change, and at no
/// other time.
struct DSPEnvironmentBridge: ViewModifier {
    /// What the bridge last published, and for which session.
    private struct Publication: Equatable {
        var session: UUID
        var values: SourceEnvironment
    }

    let session: PipelineSession?
    @State private var publication: Publication?

    /// The values the hierarchy reads now.
    private var current: SourceEnvironment {
        guard let session else { return .reference }
        if let publication, publication.session == session.id { return publication.values }
        return SourceEnvironment(session.environment)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.dspSourceEnvironment, current)
            .task(id: session?.id) {
                guard let session else { return }
                await EnvironmentBridge.follow(session) { values in
                    let next = Publication(session: session.id, values: values)
                    if publication != next { publication = next }
                }
            }
    }
}

extension View {
    /// Publishes the environment of `session` into SwiftUI's environment for the views inside
    /// this one (ENV-4): the sample rate, the Nyquist frequency and the channel count at the
    /// source, and the latency of the whole main line.
    ///
    /// ```swift
    /// @Environment(\.dspNyquistFrequency) private var nyquist
    /// // …
    /// Controls().dspEnvironment(model.session)
    /// ```
    ///
    /// The values are published when the session is given and again only when its format or
    /// its topology changes, so the bridge cannot cause view updates at data rate (V-7).
    /// `nil` publishes the reference environment: 48 kHz, mono, no latency.
    ///
    /// Threading: main actor, like every view modifier; it may allocate, for the state with
    /// which it follows the session.
    public func dspEnvironment(_ session: PipelineSession?) -> some View {
        modifier(DSPEnvironmentBridge(session: session))
    }

    /// The engine on which the views inside this one keep the pipelines they host:
    /// `DSPEngine.shared` unless this modifier says otherwise (VC-3).
    ///
    /// Threading: main actor, like every view modifier; it stores a reference, and may
    /// allocate as SwiftUI does for any environment value.
    public func dspEngine(_ engine: DSPEngine) -> some View {
        environment(\.dspEngine, engine)
    }
}
