import ZTronDSPCore

/// The shape of a frequency-selective response and its edge frequencies: one edge for a
/// low-pass or a high-pass, two for a band-pass or a band-stop.
///
/// The edges are plain numbers; the design they are handed to states the unit. For
/// `IIRDesign` that is radians per second in the analog domain and hertz in the digital one.
/// A later layer resolves a `Frequency` against the pipeline's environment and passes the
/// number on.
///
/// An immutable value, usable on any thread.
public enum FilterResponse: Hashable, Sendable {
    /// Passes what lies below `cutoff`.
    case lowPass(cutoff: Double)
    /// Passes what lies above `cutoff`.
    case highPass(cutoff: Double)
    /// Passes the band between the two edges.
    case bandPass(from: Double, to: Double)
    /// Stops the band between the two edges.
    case bandStop(from: Double, to: Double)

    /// The edges in ascending order as they were given: one or two numbers. Usable on any
    /// thread; allocates.
    public var edges: [Double] {
        switch self {
        case .lowPass(let cutoff), .highPass(let cutoff): [cutoff]
        case .bandPass(let from, let to), .bandStop(let from, let to): [from, to]
        }
    }

    /// True for the two responses whose filter has twice the order of its prototype. Usable
    /// on any thread.
    public var isBand: Bool {
        switch self {
        case .lowPass, .highPass: false
        case .bandPass, .bandStop: true
        }
    }

    /// True for a band-stop.
    var isBandStop: Bool {
        if case .bandStop = self { return true }
        return false
    }

    /// The same kind of response with other edges.
    func replacingEdges(_ edges: [Double]) -> FilterResponse {
        switch self {
        case .lowPass: .lowPass(cutoff: edges[0])
        case .highPass: .highPass(cutoff: edges[0])
        case .bandPass: .bandPass(from: edges[0], to: edges[1])
        case .bandStop: .bandStop(from: edges[0], to: edges[1])
        }
    }

    /// The name used in error messages.
    var name: String {
        switch self {
        case .lowPass: "low-pass"
        case .highPass: "high-pass"
        case .bandPass: "band-pass"
        case .bandStop: "band-stop"
        }
    }

    /// True when `other` is the same kind of response.
    func isSameKind(as other: FilterResponse) -> Bool {
        switch (self, other) {
        case (.lowPass, .lowPass), (.highPass, .highPass), (.bandPass, .bandPass), (.bandStop, .bandStop): true
        default: false
        }
    }
}
