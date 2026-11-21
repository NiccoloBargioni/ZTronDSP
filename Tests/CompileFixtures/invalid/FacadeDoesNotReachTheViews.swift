// expect: cannot find 'SpectrogramView' in scope
// expect: cannot find 'FrequencyAxisView' in scope
//
// §4.2, WP-901a: the facade re-exports Core, Design, Analysis, IO and Metal. The views are the
// product `ZTronDSPUI` of their own: a client that imports only `ZTronDSP` does not see them.
import SwiftUI
import ZTronDSP

@MainActor func views(feed: HeatmapFeed) {
    let spectrogram = SpectrogramView(feed: feed)
    let axis = FrequencyAxisView(feed: feed)
    _ = (spectrogram, axis)
}
