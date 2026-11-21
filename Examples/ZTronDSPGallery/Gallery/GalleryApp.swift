import SwiftUI

/// The gallery of ZTronDSP's visual components (specification §4.2): one screen per
/// component, per group of modifiers and per way of hosting a pipeline, each driven by a
/// pipeline of the package's own recipes on a mock source. Nothing here opens the microphone.
///
/// The application is also the host of the tests that need a real window (§8.4, level 2):
/// the target `GalleryTests` runs inside it.
///
/// It follows the rules the package follows: SwiftUI only, no UIKit, no Combine and nothing
/// that rests on it, no type-erased views, no configuration objects. State lives in `@State`
/// and in plain values.
@main
struct GalleryApp: App {
    var body: some Scene {
        WindowGroup {
            GalleryRoot()
        }
    }
}
