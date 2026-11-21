import AVFAudio

/// One audio input the session offers: the built-in microphone or an external one (§4.6).
///
/// A value from ``HardwareInputSource/availableInputs(policy:)`` names the input a
/// ``HardwareInputSource`` records from (MIC-2). It is a description: it holds no reference to
/// the port, so it stays valid, and comparable, after the microphone was unplugged and plugged
/// back (MIC-4).
///
/// An immutable value, usable on any thread; copying and comparing one does not allocate.
public struct AudioInput: Sendable, Hashable, Identifiable {
    /// What kind of input a port is: a value, usable on any thread; it does not allocate.
    public enum Kind: Sendable, Hashable {
        /// The device's own microphone.
        case builtIn
        /// A wired headset microphone or a line input.
        case wired
        /// A USB audio interface or microphone.
        case usb
        /// A Bluetooth microphone: hands-free profile or low energy (MIC-5).
        case bluetooth
        /// The microphone of a nearby iPhone, through Continuity (iOS 17 and later).
        case continuity
        /// Anything else the system routes input from.
        case other
    }

    /// The port's unique identifier: the same for as long as the same device is connected,
    /// and again when it is connected again.
    public let id: String
    /// The name the system gives the port, for display.
    public let name: String
    /// What kind of input the port is.
    public let kind: Kind
    /// The names of the port's data sources, where it has several: for a built-in microphone
    /// typically front, back and bottom. Empty when the port has none to choose from.
    public let dataSources: [String]

    /// Describes an input. The package makes these from the session's ports; an app makes one
    /// only to stand in for a session, in a test or a preview.
    public init(id: String, name: String, kind: Kind, dataSources: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.dataSources = dataSources
    }
}

extension AudioInput.Kind {
    /// The kind of a session port (E-31).
    init(port: AVAudioSession.Port) {
        if #available(iOS 17.0, *), port == .continuityMicrophone {
            self = .continuity
            return
        }
        switch port {
        case .builtInMic: self = .builtIn
        case .headsetMic, .lineIn: self = .wired
        case .usbAudio: self = .usb
        case .bluetoothHFP, .bluetoothLE: self = .bluetooth
        default: self = .other
        }
    }
}
