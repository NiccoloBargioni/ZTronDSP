import Testing

/// Everything the gallery hosts for the package (§4.2): the suites that need a real window in
/// a real application. They run inside the gallery, one test at a time: the tests share one
/// application, one scene and one display.
@MainActor
@Suite("Hosted in the gallery", .serialized)
enum InApp {}
