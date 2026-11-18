import Darwin

/// Owned, aligned, fixed-capacity storage with no copy-on-write: what the hot path keeps its
/// state and work buffers in (RT-5, §5.11.4).
///
/// The memory is zero-filled when it is created and freed when the buffer is released. The
/// element count never changes. A buffer has reference semantics: a copy of the reference is
/// the same memory.
///
/// Threading: create and release it on the control context (it allocates and frees). Reading
/// and writing through its pointers allocates nothing and is safe on the analysis thread. The
/// buffer does no synchronisation of its own: one thread at a time.
public final class AlignedBuffer<Element: BitwiseCopyable> {
    /// The number of elements.
    public let count: Int
    /// The alignment of the first element, in bytes.
    public let alignment: Int
    @usableFromInline let base: UnsafeMutablePointer<Element>

    /// Creates zero-filled storage for `count` elements.
    ///
    /// - Parameters:
    ///   - count: the number of elements; 0 is allowed.
    ///   - alignment: a power of two, at least the element's own alignment. The default, 64,
    ///     is a cache line and more than the 16 bytes vDSP recommends.
    /// - Throws: `DSPError.resourceAllocationFailed` for a negative count, an alignment that
    ///   is not a power of two, or when the system has no memory to give.
    public init(count: Int, alignment: Int = 64) throws(DSPError) {
        guard count >= 0 else {
            throw .resourceAllocationFailed(what: "a buffer of \(count) elements")
        }
        let minimum = max(MemoryLayout<Element>.alignment, MemoryLayout<UnsafeRawPointer>.alignment)
        guard alignment > 0, alignment & (alignment - 1) == 0 else {
            throw .resourceAllocationFailed(what: "a buffer aligned to \(alignment) bytes (not a power of two)")
        }
        let effective = max(alignment, minimum)
        let (bytes, overflow) = max(count, 1).multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        guard !overflow else {
            throw .resourceAllocationFailed(what: "a buffer of \(count) elements")
        }
        var raw: UnsafeMutableRawPointer?
        guard posix_memalign(&raw, effective, bytes) == 0, let raw else {
            throw .resourceAllocationFailed(what: "\(bytes) bytes")
        }
        memset(raw, 0, bytes)
        self.count = count
        self.alignment = effective
        self.base = raw.bindMemory(to: Element.self, capacity: max(count, 1))
    }

    /// Creates storage holding a copy of `elements`.
    public convenience init(copying elements: some Collection<Element>, alignment: Int = 64) throws(DSPError) {
        try self.init(count: elements.count, alignment: alignment)
        var index = 0
        for element in elements {
            base[index] = element
            index += 1
        }
    }

    deinit {
        free(base)
    }

    /// The first element. Valid for as long as the buffer is alive.
    @inlinable public var baseAddress: UnsafeMutablePointer<Element> { base }

    /// The whole storage as a buffer pointer.
    @inlinable public var buffer: UnsafeMutableBufferPointer<Element> {
        UnsafeMutableBufferPointer(start: base, count: count)
    }

    /// Reads one element. An index outside the storage returns the first element's value
    /// rather than reading out of bounds.
    @inlinable public subscript(index: Int) -> Element {
        index >= 0 && index < count ? base[index] : base[0]
    }

    /// Sets every element to zero. Allocation-free.
    @inlinable public func clear() {
        memset(base, 0, count * MemoryLayout<Element>.stride)
    }

    /// Sets every element to `value`. Allocation-free.
    @inlinable public func fill(with value: Element) {
        var index = 0
        while index < count {
            base[index] = value
            index += 1
        }
    }

    /// Copies up to `count` elements from `source`, starting at this buffer's first element.
    /// Allocation-free.
    @inlinable public func copy(from source: UnsafePointer<Element>, count elements: Int) {
        let length = min(max(elements, 0), count)
        if length > 0 { memcpy(base, source, length * MemoryLayout<Element>.stride) }
    }

    /// The contents as a new array (allocates; not for the analysis thread).
    public var array: [Element] { Array(buffer) }
}
