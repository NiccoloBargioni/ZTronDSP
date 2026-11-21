/// The typing rule of a stage as a run-time value: from the domain before the stage to the
/// domain after it, or to nothing when the stage cannot sit there (§5.8.2, tier 2).
///
/// It is the same rule the stage's types express to the Swift compiler (tier 1). The plan
/// compiler applies it to every stage of every pipeline, typed or not (ORD-6), which is what
/// protects a pipeline whose types were not known when the app was compiled (ORD-5).
///
/// Two rules are equal when their names are equal: give a rule of your own a name of its own.
/// An immutable value, usable on any thread. Creating one may allocate, for its name and its
/// closure.
public struct DomainRule: Hashable, Sendable {
    /// What identifies the rule, and what an error calls it.
    public let name: String
    let transform: @Sendable (DomainTag) -> DomainTag?

    /// A rule of your own: return the domain the stage produces from `input`, or `nil` when
    /// the stage cannot follow `input`.
    public init(_ name: String, _ transform: @escaping @Sendable (DomainTag) -> DomainTag?) {
        self.name = name
        self.transform = transform
    }

    /// The domain a stage with this rule produces after `input`, or `nil` when it is rejected.
    public func callAsFunction(_ input: DomainTag) -> DomainTag? {
        transform(input)
    }

    /// True when the names are equal.
    public static func == (lhs: DomainRule, rhs: DomainRule) -> Bool { lhs.name == rhs.name }
    /// Hashes the name.
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }

    // MARK: Stock rules

    /// A self-typed stage: exactly `input` in, `output` out.
    public static func fixed(_ input: DomainTag, _ output: DomainTag) -> DomainRule {
        DomainRule("\(input) → \(output)") { $0 == input ? output : nil }
    }

    /// A sequence stage: any sampled sequence, kept (O-1).
    public static let sequence = DomainRule("a sampled sequence, kept") { $0.isSampledSequence ? $0 : nil }

    /// Structure that works on every domain and keeps it: `Tap`, `Group`.
    public static let any = DomainRule("any domain, kept") { $0 }

    /// A step that keeps the domain but only follows some domains: a sink (O-11).
    public static func keeping(_ name: String, where accepts: @escaping @Sendable (DomainTag) -> Bool) -> DomainRule {
        DomainRule(name) { accepts($0) ? $0 : nil }
    }

    /// A step on spectra: it follows the spectra `accepts` admits and may change the axis and
    /// the kind of value.
    public static func spectral(
        _ name: String, _ transform: @escaping @Sendable (_ axis: DomainTag.Axis, _ values: DomainTag.Values) -> DomainTag?
    ) -> DomainRule {
        DomainRule(name) { tag in
            guard case .spectrum(let axis, let values) = tag else { return nil }
            return transform(axis, values)
        }
    }
}
