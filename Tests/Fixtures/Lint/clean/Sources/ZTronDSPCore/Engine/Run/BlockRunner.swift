import Foundation

/// Runs one block. Words that are banned here may appear in comments: await, print(, Logger,
/// DispatchSemaphore, Task { }, queue.sync { }, for x in xs.
final class BlockRunner {
    private var frames: UInt32 = 0
    private let label = "for x in xs: print(await Task { NSLock() })"

    func run(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        var index = 0
        while index < count {                       // a `while` loop allocates nothing at -Onone
            samples[index] *= 0.5
            index += 1
        }
        frames &+= UInt32(count)
        let position = lookup(for: index, in: count)    // `for` and `in` as argument labels
        _ = position
    }

    func lookup(for index: Int, in count: Int) -> Int { index % max(count, 1) }

    func printer() -> String { label }              // a name that merely starts with "print"
    func asynchronous() {}                          // … or holds "sync"
    func isSource(_ name: String) -> Bool { name.hasSuffix("Source") }
}
