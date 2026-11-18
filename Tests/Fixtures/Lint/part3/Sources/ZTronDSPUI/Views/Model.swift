import SwiftUI
import Combine                                              // !! APR-1

final class Model: ObservableObject {                       // !! APR-1
    @Published var level: Float = 0                         // !! APR-1
    private var bag = Set<AnyCancellable>()                 // !! APR-1
    let subject = PassthroughSubject<Float, Never>()        // !! APR-1
    let current = CurrentValueSubject<Float, Never>(0)      // !! APR-1

    func bind(_ publisher: AnyPublisher<Float, Never>) {    // !! APR-1
        publisher.sink { _ in }.store(in: &bag)             // !! APR-1
    }
}

struct Screen: View {
    @StateObject private var model = Model()                // !! APR-1
    @ObservedObject var other: Model                        // !! APR-1
    @EnvironmentObject var shared: Model                    // !! APR-1

    var body: some View {
        AnyView(Text("x"))                                  // !! APR-1
            .onReceive(model.subject) { _ in }              // !! APR-1
    }
}

func erase<P: Publisher>(_ p: P) {}                         // !! APR-1
