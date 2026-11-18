import Darwin
import Foundation
import Testing
import ZTronDSPTesting

@Suite("Allocation probe", .disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
struct AllocationAuditTests {
    /// The control case: if the hook stops firing, this fails loudly (§13.1).
    @Test func aBlockThatAllocatesIsDetected() throws {
        let counts = try countAllocations {
            forceAllocation(byteCount: 4_096)
        }
        #expect(counts.allocations == 1)
        #expect(counts.deallocations == 1)
        #expect(counts.bytes == 4_096)
        #expect(counts.description == "1 allocation(s) of 4096 byte(s), 1 deallocation(s)")
    }

    @Test func everyAllocatingCallIsCounted() throws {
        let counts = try countAllocations {
            forceReallocation(from: 256, to: 1_024)
        }
        #expect(counts.allocations == 2, "calloc, and the allocating half of realloc")
        #expect(counts.deallocations == 2, "the freeing half of realloc, and free")
        #expect(counts.bytes == 256 + 1_024)
    }

    @Test func swiftAllocationsAreSeen() throws {
        let counts = try countAllocations {
            let array = [Int](repeating: 7, count: 1_000)
            Benchmark.blackHole(array)
        }
        #expect(counts.allocations >= 1)
        #expect(counts.bytes >= 8_000)
    }

    @Test func anEmptyBlockReportsZero() throws {
        let counts = try countAllocations {}
        #expect(counts == AllocationCounts(allocations: 0, deallocations: 0, bytes: 0))
    }

    @Test func arithmeticOnPreallocatedStorageReportsZero() {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4_096)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 1, count: 4_096)
        let counts = expectNoAllocations {
            // A `while` loop: `for … in` allocates per iteration in an unoptimised build (CR-002).
            var sum: Float = 0
            var index = 0
            while index < 4_096 {
                buffer[index] *= 0.5
                sum += buffer[index]
                index += 1
            }
            Benchmark.blackHole(sum)
        }
        #expect(counts == AllocationCounts(allocations: 0, deallocations: 0, bytes: 0))
    }

    @Test func allocationsOnAnotherThreadAreNotCounted() throws {
        // The other thread allocates while this one is under audit and does nothing with the heap.
        let done = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        done.initialize(to: 0)
        let started = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        started.initialize(to: 0)
        defer { done.deallocate(); started.deallocate() }
        nonisolated(unsafe) let doneFlag = done
        nonisolated(unsafe) let startedFlag = started

        let thread = Thread {
            while startedFlag.pointee == 0 { usleep(200) }
            var round = 0
            while round < 2_000 {
                forceAllocation(byteCount: 256)
                round += 1
            }
            doneFlag.pointee = 1
        }
        thread.start()

        let counts = try countAllocations {
            startedFlag.pointee = 1
            var spins = 0
            while doneFlag.pointee == 0 && spins < 20_000 {
                usleep(500)
                spins += 1
            }
        }
        #expect(done.pointee == 1, "the other thread finished inside the audited region")
        #expect(counts.allocations == 0)
        #expect(counts.deallocations == 0)
    }

    @Test func auditsOnDifferentThreadsAreIndependent() async throws {
        let results = await withTaskGroup(of: Int.self) { group in
            for size in [1, 2, 3, 4, 5, 6, 7, 8] {
                group.addTask {
                    let counts = try? countAllocations {
                        var round = 0
                        while round < size {
                            forceAllocation(byteCount: 64)
                            round += 1
                        }
                    }
                    return counts?.allocations ?? -1
                }
            }
            var all: [Int] = []
            for await value in group { all.append(value) }
            return all.sorted()
        }
        #expect(results == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test func auditsDoNotNest() {
        var inner: AllocationAuditError?
        _ = try? countAllocations {
            do { _ = try countAllocations {} } catch let error as AllocationAuditError { inner = error } catch {}
        }
        #expect(inner == .nested)
    }

    @Test func expectNoAllocationsRecordsAnIssueWhenTheBlockAllocates() {
        withKnownIssue {
            expectNoAllocations("seeded allocation") {
                forceAllocation(byteCount: 128)
            }
        } matching: { issue in
            issue.description.contains("seeded allocation") && issue.description.contains("1 allocation(s) of 128 byte(s)")
        }
    }
}
