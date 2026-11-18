// Fixture of WP-015. A leaf loop that carries the performance annotations and allocates.
// With ZTRONDSP_PERF_ANNOTATIONS on, this file MUST NOT build; with it off, it builds.

#if ZTRONDSP_PERF_ANNOTATIONS
@_noAllocation @_noLocks
#endif
public func allocatingLeaf(_ source: UnsafePointer<Float>, count: Int) -> Float {
    // An array is heap storage: this is what the annotation exists to catch.
    var copy = [Float](repeating: 0, count: count)
    var index = 0
    while index < count {
        copy[index] = source[index] * 2
        index += 1
    }
    return copy.reduce(0, +)
}
