import AVFAudio
import CZTronDSP
import ZTronDSPCore

/// The seam between a ``HardwareInputSource`` and the audio engine that captures for it
/// (COV-5): one `AVAudioEngine` whose only connection is input node → sink node (§4.6).
///
/// Each member is one step and decides nothing. In which order the steps are taken, and
/// whether a step is taken at all, is the source's decision, which a test drives with a
/// capture of its own.
///
/// Threading: every member is called by the source with its state lock held, so one at a
/// time, on the control context or on the source's queue.
protocol InputCapturing: AnyObject, Sendable {
    /// The identity of the object whose `AVAudioEngineConfigurationChange` notification
    /// concerns this capture: its engine. `nil` before the first `rebuild`. Unlike the other
    /// members it may be read on any thread at any time, also while another member runs: a
    /// notification is compared with it on the thread that posts.
    var engineIdentity: ObjectIdentifier? { get }

    /// Makes a new engine and a new sink node, and lets go of the ones it had (CAP-8, media
    /// services reset). The new node writes to the ring that was set last.
    func rebuild() throws(DSPError)

    /// Turns the input's voice processing on or off (CAP-6). Before `connect`.
    func setVoiceProcessing(_ enabled: Bool) throws(DSPError)

    /// The format the input delivers now (MIC-6). Not valid when there is no input.
    func inputFormat() -> SignalFormat

    /// Connects the input node to the sink node in the input's format. The source asks only
    /// for a valid `inputFormat()`; an input that has none is `sourceUnavailable`.
    func connect() throws(DSPError)

    /// Takes the connection away again.
    func disconnect()

    /// Starts the engine: frames arrive at the ring from now on.
    func start() throws(DSPError)

    /// Stops the engine. Without effect on one that is not running.
    func stop()

    /// The ring the I/O thread writes from now on; `nil` discards what arrives. Returns once
    /// the I/O thread has let go of the previous ring.
    func setRing(_ ring: RingWriter?)
}

/// Which of the system's interfaces an adapter uses where a newer one replaced an older one
/// (PLAT-1). Both do the same thing; the newer ones report failures as errors and promise
/// real-time safety to the compiler.
enum SystemInterfaces: Hashable, Sendable {
    /// The newest the running system has.
    case current
    /// The ones that exist at the deployment floor, whatever the running system.
    case classic
}

/// One hold on the tap a sink node writes to (`ztd_sink_tap_t`).
///
/// Threading: not `Sendable`; it lives inside the state of the capture that owns it.
final class SinkTap {
    let pointer: OpaquePointer

    /// `nil` when memory cannot be had.
    init?() {
        guard let pointer = ztd_sink_tap_create() else { return nil }
        self.pointer = pointer
    }

    deinit {
        ztd_sink_tap_release(pointer)
    }
}

/// The capture a hardware source runs: `AVAudioEngine`, its input node and an
/// `AVAudioSinkNode` from the factory in `CZTronDSP`, whose block is all that runs on the
/// I/O thread (RT-1). This is the humble object of COV-5: it forwards, translates errors and
/// chooses the interface the running system has, and nothing else.
///
/// Threading: as the protocol says. The engine and the node are inside a lock because they
/// are not `Sendable`, not because two threads ever meet here.
final class EngineInputCapture: InputCapturing {
    /// The most channels an input may have: what a sink tap takes.
    static let maximumChannelCount = Int(ZTD_SINK_TAP_MAX_CHANNELS)

    private struct Parts {
        var tap: SinkTap?
        var engine: AVAudioEngine?
        var node: AVAudioSinkNode?
        var ring: RingWriter?
    }

    private let parts = Guarded(Parts())
    /// Held only for a copy, never while the engine is called: see `engineIdentity`.
    private let identity = Guarded<ObjectIdentifier?>(nil)
    private let interfaces: SystemInterfaces

    /// - Parameter interfaces: `.current` makes the sink node with the real-time-safe
    ///   initialiser and connects with the error-returning call where the system has them
    ///   (iOS 27, E-02, PLAT-1). `.classic` is what older systems run, and what a test asks for
    ///   to run that path on a new one.
    init(interfaces: SystemInterfaces = .current) {
        self.interfaces = interfaces
    }

    deinit {
        // The engine is stopped and the tap parted from its ring before either is let go: no
        // receive runs any more, and none could reach a ring that is gone.
        parts.withLock { parts in
            parts.engine?.stop()
            if let tap = parts.tap { ztd_sink_tap_set_ring(tap.pointer, nil) }
        }
    }

    var engineIdentity: ObjectIdentifier? { identity.get() }

    func rebuild() throws(DSPError) {
        try parts.withLock { parts throws(DSPError) in
            parts.engine?.stop()
            parts.engine = nil
            parts.node = nil
            identity.set(nil)
            let tap = parts.tap ?? SinkTap()
            guard let tap, let node = ztd_sink_node_create(tap.pointer, interfaces == .current) else {
                throw .resourceAllocationFailed(what: "the sink node of a hardware source")
            }
            let engine = AVAudioEngine()
            engine.attach(node)
            parts.tap = tap
            parts.node = node
            parts.engine = engine
            identity.set(ObjectIdentifier(engine))
        }
    }

    func setVoiceProcessing(_ enabled: Bool) throws(DSPError) {
        try parts.withLock { parts throws(DSPError) in
            do {
                try parts.engine?.inputNode.setVoiceProcessingEnabled(enabled)
            } catch {
                throw .unsupportedConfiguration(reason: "voice processing could not be turned \(enabled ? "on" : "off"): \(error.localizedDescription)")
            }
        }
    }

    func inputFormat() -> SignalFormat {
        parts.withLock { parts in
            let format = parts.engine?.inputNode.outputFormat(forBus: 0)
            return SignalFormat(sampleRate: format?.sampleRate ?? 0, channelCount: Int(format?.channelCount ?? 0))
        }
    }

    func connect() throws(DSPError) {
        try parts.withLock { parts throws(DSPError) in
            guard let engine = parts.engine, let node = parts.node else {
                throw .sourceUnavailable(reason: "the input engine was not built")
            }
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // The classic call raises an Objective-C exception for a format that is none, and
            // Swift cannot catch one. The source asks only for a valid format; should the input
            // have gone in between, this is an error like any other.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw .sourceUnavailable(reason: "the input has no format to connect: \(format.sampleRate) Hz, \(format.channelCount) channels")
            }
            if #available(iOS 27.0, *), interfaces == .current {
                do {
                    try engine.connectNode(input, to: node, format: format)
                } catch {
                    throw .sourceUnavailable(reason: "the input could not be connected: \(error.localizedDescription)")
                }
            } else {
                engine.connect(input, to: node, format: format)
            }
        }
    }

    func disconnect() {
        parts.withLock { parts in
            if let node = parts.node { parts.engine?.disconnectNodeInput(node) }
        }
    }

    func start() throws(DSPError) {
        try parts.withLock { parts throws(DSPError) in
            guard let engine = parts.engine else { throw .sourceUnavailable(reason: "the input engine was not built") }
            // An engine that has neither an input nor an output node raises when it is started,
            // instead of failing. Naming the input node makes it; without a connection the
            // start is then refused with an error.
            _ = engine.inputNode
            do {
                try engine.start()
            } catch {
                throw .sourceUnavailable(reason: "the input engine could not start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        parts.withLock { $0.engine?.stop() }
    }

    func setRing(_ ring: RingWriter?) {
        parts.withLock { parts in
            if parts.tap == nil { parts.tap = SinkTap() }
            // Only when the tap has let go of the previous ring is that ring's writer, and
            // with it the ring itself, released.
            if let tap = parts.tap, !ztd_sink_tap_set_ring(tap.pointer, ring?.ring) {
                ztd_sink_tap_set_ring(tap.pointer, nil)
            }
            parts.ring = ring
        }
    }
}
