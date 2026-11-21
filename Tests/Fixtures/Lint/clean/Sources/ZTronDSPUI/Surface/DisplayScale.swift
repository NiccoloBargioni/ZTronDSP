// The display scale comes from SwiftUI; the layer's `contentsScale` is never read (SZ-2). A
// comment may name it.
struct DisplayScale: Hashable, Sendable {
    let value: Double
}
