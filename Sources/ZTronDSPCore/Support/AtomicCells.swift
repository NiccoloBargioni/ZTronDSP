/// Atomic cells made together: all of them, or none.
///
/// An object that needs several single atomic words (RT-4) asks for them here. When the system
/// refuses one, the cells made before it are freed, so an initialiser that then throws leaves
/// nothing behind. The cells belong to whoever asked: each is freed with `ztd_atomic_destroy`.
///
/// Control context: it allocates.
enum AtomicCells {
    /// One cell per value of `initial`, in that order, or `nil` when one of them cannot be had.
    static func make(_ initial: [UInt64]) -> [OpaquePointer]? {
        var cells: [OpaquePointer] = []
        cells.reserveCapacity(initial.count)
        for value in initial {
            guard let cell = ztd_atomic_create(value) else {
                destroy(cells)
                return nil
            }
            cells.append(cell)
        }
        return cells
    }

    /// Frees cells that `make` returned.
    static func destroy(_ cells: [OpaquePointer]) {
        for cell in cells { ztd_atomic_destroy(cell) }
    }
}
