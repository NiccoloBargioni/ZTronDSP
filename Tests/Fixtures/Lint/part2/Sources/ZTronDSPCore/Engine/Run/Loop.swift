import Foundation
import os

final class Loop {
    let lock = NSLock()                                  // !! RT-7
    let semaphore = DispatchSemaphore(value: 0)          // !! RT-7
    var unfair = os_unfair_lock()                        // !! RT-7
    let logger = Logger(subsystem: "x", category: "y")   // !! RT-7
    let queue = DispatchQueue(label: "q")

    func run(_ xs: [Float]) async {
        for x in xs { consume(x) }                       // !! RT-7
        queue.sync { consume(0) }                        // !! RT-7
        queue.sync(execute: { })                         // !! RT-7
        Task { await idle() }                            // !! RT-7 RT-7
        Task.detached { }                                // !! RT-7
        print("block done")                              // !! RT-7
        objc_sync_enter(self)                            // !! RT-7
        os_unfair_lock_lock(&unfair)                     // !! RT-7
        await idle()                                     // !! RT-7
    }

    func idle() async {}
    func consume(_ x: Float) {}
}
