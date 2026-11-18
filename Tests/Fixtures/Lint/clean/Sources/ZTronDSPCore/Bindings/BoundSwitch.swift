import struct SwiftUI.Binding

/// A switch read on the main actor (BIND-1). This group is the one place that names Binding.
public struct BoundSwitch: Sendable {
    let binding: Binding<Bool>

    public init(_ binding: Binding<Bool>) {
        self.binding = binding
    }

    @MainActor public var isOn: Bool { binding.wrappedValue }
}
