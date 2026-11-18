import SwiftUI
import Testing
@testable import ZTronDSPCore

// Tests may import SwiftUI and use @testable. They still use neither Combine nor AnyView.
@Suite struct ActivationTests {
    @Test func bindingIsRead() {
        var value = true
        let binding = Binding(get: { value }, set: { value = $0 })
        #expect(binding.wrappedValue)
    }
}
