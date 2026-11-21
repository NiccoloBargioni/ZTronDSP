// expect: value of type 'Text' has no member 'pinchScaling'
//
// §4.2, WP-901a: the modifiers `ZTronDSPUI` adds to `View` (VC-4, PINCH-1) are not re-exported by
// the facade either: with SwiftUI and `ZTronDSP` imported, a view has none of them.
import SwiftUI
import ZTronDSP

@MainActor func modified() -> some View {
    Text("spectrum").pinchScaling(.horizontal)
}
