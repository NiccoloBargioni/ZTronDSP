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
///
/// Conformers are values, usable on any thread. A stage reads ``stageActivation`` once, when
/// its description is made; in the stock conformers that read does not allocate.
public protocol ActivationSource: Sendable {
    /// The activation as a stage description holds it.
    var stageActivation: StageActivation { get }
}

/// A constant activation: `.active` or `.bypassed`.
///
/// `.active` is the default of every `isActive:` argument and leaves no trace in the plan.
/// `.bypassed` removes the stage when the plan is compiled, or, for a stage that changes the
/// domain or the rate, the rest of its branch (ACT-3, ACT-4).
///
/// An immutable value, usable on any thread; it does not allocate.
public struct Activation: ActivationSource, Hashable {
    /// True for `.active`.
    public let isActive: Bool

    init(isActive: Bool) {
        self.isActive = isActive
    }

    /// `.constant(isActive)`.
    public var stageActivation: StageActivation { .constant(isActive) }
}

extension Bool: ActivationSource {
    /// `.constant(self)`: `true` runs the stage, `false` compiles it away. Usable on any thread; it
    /// does not allocate.
    public var stageActivation: StageActivation { .constant(self) }
}

extension Binding: ActivationSource where Value == Bool {
    /// A bound switch: the stage gets a run-time switch that follows the binding (ACT-5). The
    /// session samples it on the main run loop; a write made off the main thread is seen at
    /// the loop's next turn, or at once with `session.syncBindings()` (BIND-2, BIND-3).
    public var stageActivation: StageActivation { .bound(BoundSwitch(self)) }
}

extension ActivationSource where Self == Activation {
    /// The stage runs. Usable on any thread; it does not allocate.
    public static var active: Activation { Activation(isActive: true) }
    /// The stage is compiled away. Usable on any thread; it does not allocate.
    public static var bypassed: Activation { Activation(isActive: false) }
}

/// A `Binding<Bool>` captured by a stage description.
///
/// A binding offers no identity, so all bound switches compare equal (ACT-12): two
/// descriptions that differ only in which binding they hold are the same description, and
/// `update(_:)` always captures the bindings of the pipeline it is given.
///
/// The binding is read only on the main actor (BIND-1) and never written (BIND-5).
/// Otherwise it may be passed to and held on any thread; creating or comparing one does not
/// allocate.
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

    /// Always true: a binding offers no identity (ACT-12).
    public static func == (lhs: BoundSwitch, rhs: BoundSwitch) -> Bool { true }
    /// Hashes nothing, so every bound switch has the same hash (ACT-12).
    public func hash(into hasher: inout Hasher) {}
}

/// The activation of a stage as its description holds it: a constant, resolved when the plan
/// is compiled, or a bound switch, sampled while it runs.
///
/// Constants compare by value, so the default, `true` and `.active` are equal. A bound
/// activation differs from every constant, and all bound activations compare equal (ACT-12).
///
/// A value, usable on any thread; it does not allocate.
public enum StageActivation: Hashable, Sendable {
    /// A constant, resolved when the plan is compiled: `true` runs the stage, `false` compiles it
    /// away.
    case constant(Bool)
    /// A switch that follows a binding, sampled on the main run loop while the plan runs (ACT-5).
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
