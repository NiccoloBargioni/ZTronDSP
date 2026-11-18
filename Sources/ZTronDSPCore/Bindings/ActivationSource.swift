import struct SwiftUI.Binding

// The one place the core target names a SwiftUI symbol (BIND-7). The scoped import brings in
// `Binding` and nothing else: `View`, `Color` and the rest stay out of scope (E-28).

/// What a stage's `isActive:` argument accepts: `true` or `false`, `.active` or `.bypassed`,
/// or a SwiftUI `Binding<Bool>` (ACT-1, ACT-2).
///
/// The argument is `some ActivationSource` and not `Binding<Bool>` with a default of
/// `.constant(true)`: a constant binding cannot be told from a live one, so every stage would
/// carry a run-time switch and lose fusion. Write `true`, or leave the argument out; do not
/// write `.constant(true)`.
public protocol ActivationSource: Sendable {
    /// The activation as a stage description holds it.
    var stageActivation: StageActivation { get }
}

/// A constant activation: `.active` or `.bypassed`.
///
/// `.active` is the default of every `isActive:` argument and leaves no trace in the plan.
/// `.bypassed` removes the stage when the plan is compiled, or, for a stage that changes the
/// domain or the rate, the rest of its branch (ACT-3, ACT-4).
public struct Activation: ActivationSource, Hashable {
    /// True for `.active`.
    public let isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }

    public var stageActivation: StageActivation { .constant(isActive) }
}

extension Bool: ActivationSource {
    public var stageActivation: StageActivation { .constant(self) }
}

extension Binding: ActivationSource where Value == Bool {
    /// A bound switch: the stage gets a run-time switch that follows the binding (ACT-5). The
    /// session samples it on the main run loop; a write made off the main thread is seen at
    /// the loop's next turn, or at once with `session.syncBindings()` (BIND-2, BIND-3).
    public var stageActivation: StageActivation { .bound(BoundSwitch(self)) }
}

extension ActivationSource where Self == Activation {
    /// The stage runs.
    public static var active: Activation { Activation(isActive: true) }
    /// The stage is compiled away.
    public static var bypassed: Activation { Activation(isActive: false) }
}

/// A `Binding<Bool>` captured by a stage description.
///
/// A binding offers no identity, so all bound switches compare equal (ACT-12): two
/// descriptions that differ only in which binding they hold are the same description, and
/// `update(_:)` always captures the bindings of the pipeline it is given.
///
/// The binding is read only on the main actor (BIND-1) and never written (BIND-5).
public struct BoundSwitch: Hashable, Sendable {
    let binding: Binding<Bool>

    init(_ binding: Binding<Bool>) {
        self.binding = binding
    }

    /// The switch's position now.
    @MainActor
    public func read() -> Bool {
        binding.wrappedValue
    }

    public static func == (lhs: BoundSwitch, rhs: BoundSwitch) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
}

/// The activation of a stage as its description holds it: a constant, resolved when the plan
/// is compiled, or a bound switch, sampled while it runs.
///
/// Constants compare by value, so the default, `true` and `.active` are equal. A bound
/// activation differs from every constant, and all bound activations compare equal (ACT-12).
public enum StageActivation: Hashable, Sendable {
    case constant(Bool)
    case bound(BoundSwitch)

    /// The default: the stage runs.
    public static let active = StageActivation.constant(true)

    /// True for a bound switch.
    public var isBound: Bool {
        if case .bound = self { return true }
        return false
    }

    /// The value of a constant activation; `nil` for a bound one.
    public var constantValue: Bool? {
        if case .constant(let value) = self { return value }
        return nil
    }
}
