// Fixture of WP-015. A leaf loop that carries the performance annotations and is clean: it
// builds with ZTRONDSP_PERF_ANNOTATIONS on and off.

#if ZTRONDSP_PERF_ANNOTATIONS
@_noAllocation @_noLocks
#endif
public func cleanLeaf(_ source: UnsafePointer<Float>, into result: UnsafeMutablePointer<Float>, count: Int) {
    var index = 0
    while index < count {
        result[index] = source[index] * 2
        index &+= 1
    }
}
