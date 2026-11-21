import SwiftUI

/// The list of examples, and the navigation to their screens.
///
/// The view owns the navigation state and hands the gallery's pilot the closures that change
/// it, so that a hosted test can open a screen as a tap on its row does.
struct GalleryRoot: View {
    /// The open screen: at most one deep.
    @State private var path: [Example] = Launch.example.map { [$0] } ?? []
    /// A screen shown in a sheet over the navigation: what a component is told there is
    /// seen by a hosted test.
    @State private var sheet: Example? = Launch.sheet
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        navigation
            .sheet(item: $sheet) { example in
                ExampleScreen(example: example)
            }
            .onAppear {
                GalleryPilot.shared.attach(open: { example in path = example.map { [$0] } ?? [] }, present: { example in sheet = example })
                GalleryPilot.shared.sceneChanged(to: scenePhase)
            }
            .onChange(of: scenePhase) { phase in
                GalleryPilot.shared.sceneChanged(to: phase)
            }
    }

    @ViewBuilder
    private var navigation: some View {
        if #available(iOS 16.0, *) {
            NavigationStack(path: $path) {
                list { example in
                    NavigationLink(example.title, value: example)
                }
                .navigationDestination(for: Example.self) { example in
                    ExampleScreen(example: example)
                }
            }
        } else {
            NavigationView {
                list { example in
                    NavigationLink(example.title, tag: example, selection: opened) {
                        ExampleScreen(example: example)
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    /// The open screen as the selection of a list, for the navigation of iOS 15.
    private var opened: Binding<Example?> {
        Binding(get: { path.last }, set: { path = $0.map { [$0] } ?? [] })
    }

    private func list<Row: View>(@ViewBuilder row: @escaping (Example) -> Row) -> some View {
        List {
            ForEach(Example.Chapter.allCases) { chapter in
                Section(chapter.rawValue) {
                    ForEach(chapter.examples) { example in
                        row(example).accessibilityIdentifier("example." + example.rawValue)
                    }
                }
            }
        }
        .navigationTitle("ZTronDSP")
    }
}
