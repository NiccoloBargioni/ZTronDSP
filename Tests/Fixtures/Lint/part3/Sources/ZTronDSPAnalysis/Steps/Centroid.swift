@_spi(Internal) import ZTronDSPCore                         // !! EXT-1
@testable import ZTronDSPDesign                             // !! EXT-1

package struct CentroidHook {}                              // !! EXT-1
struct Centroid {
    package var hook: Int = 0                               // !! EXT-1
    package(set) var count: Int = 0                         // !! EXT-1
    let target: Binding<Float>?                             // !! BIND-7
}
