import SwiftUI

/// Views may import SwiftUI and name Binding.
public struct HeatmapView: View, Equatable {
    private let span: Binding<Double>?
    @State private var scale: Double = 1

    public init(span: Binding<Double>? = nil) { self.span = span }

    public var body: some View {
        MetalViewRepresentable()
    }

    public static func == (lhs: HeatmapView, rhs: HeatmapView) -> Bool { true }
}
