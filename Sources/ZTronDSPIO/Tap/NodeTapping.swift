import AVFAudio
import ZTronDSPCore

/// What a node says about the output bus that is to be tapped.
struct NodeOutput: Hashable, Sendable {
    /// The format of the bus; not valid for a bus without one.
    let format: SignalFormat
    /// The node is attached to an engine.
    let isAttached: Bool
    /// The node has the bus.
    let hasBus: Bool
    /// The bus delivers Float32 samples, as the nodes of an engine do.
    let isFloat: Bool
}

/// What a tap hands over with each burst: the format of the burst, whether its samples are
/// Float32, the buffers, and the number of frames. The buffers are valid for the call.
typealias TapReceiver = @Sendable (_ format: SignalFormat, _ isFloat: Bool, _ buffers: UnsafePointer<AudioBufferList>, _ frameCount: Int) -> Void

/// The seam between an ``EngineNodeTapSource`` and the node it taps (COV-5).
///
/// Threading: the members are called on the control context, one at a time. The receiver is
/// called on a thread of AVFAudio's, which is not a real-time thread.
protocol NodeTapping: AnyObject, Sendable {
    /// The bus as it is now.
    var output: NodeOutput { get }
    /// Installs the tap, asking for bursts of `bufferSize` frames. Only on an attached node
    /// with the bus.
    func install(bufferSize: Int, receiver: @escaping TapReceiver) throws(DSPError)
    /// Takes the tap away.
    func remove()
}

/// The tap on an `AVAudioNode`. It forwards, translates, and chooses the interface the
/// running system has (E-15, PLAT-1): the error-returning tap from iOS 27, the classic one
/// before.
///
/// Threading: as the protocol says. `AVAudioNode` may be used from any thread.
final class AudioNodeTap: NodeTapping {
    private let node: AVAudioNode
    private let bus: Int
    private let interfaces: SystemInterfaces

    init(node: AVAudioNode, bus: Int, interfaces: SystemInterfaces = .current) {
        self.node = node
        self.bus = bus
        self.interfaces = interfaces
    }

    var output: NodeOutput {
        let hasBus = bus >= 0 && bus < node.numberOfOutputs
        // A bus the node does not have has no format to ask for.
        let format = hasBus ? node.outputFormat(forBus: bus) : nil
        return NodeOutput(
            format: SignalFormat(sampleRate: format?.sampleRate ?? 0, channelCount: Int(format?.channelCount ?? 0)),
            isAttached: node.engine != nil, hasBus: hasBus, isFloat: format?.commonFormat == .pcmFormatFloat32)
    }

    func install(bufferSize: Int, receiver: @escaping TapReceiver) throws(DSPError) {
        // A bus has one tap: the source's takes the place of any other.
        remove()
        let size = AVAudioFrameCount(clamping: bufferSize)
        if #available(iOS 27.0, *), interfaces == .current {
            do {
                try node.installAudioTap(onBus: bus, bufferSize: size, format: nil) { buffer, _ in
                    let format = buffer.format
                    buffer.withUnsafeAudioBufferList { buffers in
                        receiver(
                            SignalFormat(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)),
                            format.commonFormat == .pcmFormatFloat32, buffers, buffer.frameLength)
                    }
                }
            } catch {
                throw .sourceUnavailable(reason: "the tap could not be installed: \(error.localizedDescription)")
            }
        } else {
            node.installTap(onBus: bus, bufferSize: size, format: nil) { buffer, _ in
                let format = buffer.format
                receiver(
                    SignalFormat(sampleRate: format.sampleRate, channelCount: Int(format.channelCount)),
                    format.commonFormat == .pcmFormatFloat32, buffer.audioBufferList, Int(buffer.frameLength))
            }
        }
    }

    func remove() {
        // A node that was detached meanwhile has lost its tap with its engine.
        if node.engine != nil { node.removeTap(onBus: bus) }
    }
}
