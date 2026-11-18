import CZTronDSP
import Foundation
import Testing
import ZTronDSPTesting

/// The seam of `ztd_internal.h` for the tests of failed creation: every constructor of the C
/// target asks before it asks the system for memory, a mapping or a setup, and a test can have
/// one such request of its own thread refused. The two functions are in no public header, on
/// purpose; they are looked up by name.
private let allocationSeam: (fail: @convention(c) (Int32) -> Void, isPending: @convention(c) () -> Bool)? = {
    let anyImage = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
    guard let fail = dlsym(anyImage, "ztd_fail_allocation"), let pending = dlsym(anyImage, "ztd_allocation_failure_is_pending") else { return nil }
    return (unsafeBitCast(fail, to: (@convention(c) (Int32) -> Void).self), unsafeBitCast(pending, to: (@convention(c) () -> Bool).self))
}()

/// Runs `create` with request number `index` of this thread refused. Returns whether the request
/// was made at all (a constructor that makes fewer requests is not touched) and what the thread
/// allocated and freed meanwhile.
private func refusing(_ index: Int, _ create: () -> Void) throws -> (refused: Bool, counts: AllocationCounts) {
    let seam = try #require(allocationSeam, "the seam of ztd_internal.h is not in the image")
    seam.fail(Int32(index))
    defer { seam.fail(-1) }
    let counts = try countAllocations(create)
    return (!seam.isPending(), counts)
}

@Suite("Creation that the system refuses", .disabled(if: AllocationAudit.isUnderThreadSanitizer, "the sanitizer's allocator hides the heap from the probe"))
struct CreationFailureTests {
    /// Every constructor, with each of its requests for memory refused in turn: it returns a
    /// kernel that is none (`process` is NULL, nothing to destroy), and it has freed everything
    /// it had been given up to then.
    @Test func everyKernelConstructorSurvivesEveryRefusal() throws {
        let cascade = KernelFixtures.acceptance[0].coefficients
        let taps = noiseTaps(100)
        let constructors: [(name: String, least: Int, create: () -> ztd_kernel_t)] = [
            ("gain, native", 3, { ztd_gain_create(2, nil, 480, ZTD_IMPLEMENTATION_NATIVE) }),
            ("gain, accelerate", 3, { ztd_gain_create(2, nil, 480, ZTD_IMPLEMENTATION_ACCELERATE) }),
            ("biquad, native", 3, { ztd_biquad_create(2, 2, cascade, ZTD_IMPLEMENTATION_NATIVE) }),
            ("biquad, accelerate", 4, { ztd_biquad_create(2, 2, cascade, ZTD_IMPLEMENTATION_ACCELERATE) }),
            ("biquad, many channels", 3, { ztd_biquadm_create(3, 2, cascade) }),
            ("biquad, double", 3, { ztd_biquad_double_create(2, 2, cascade) }),
            ("FIR", 8, { ztd_fir_create(2, taps, 100, 0, 480) }),
            ("decimator", 6, { ztd_decimator_create(2, 3, taps, 100, 0) }),
            ("interpolator", 6, { ztd_interpolator_create(2, 3, taps, 100, 0) }),
            ("subsample", 1, { ztd_subsample_create(2, 3, 0) }),
            ("zero-stuff", 1, { ztd_zero_stuff_create(2, 3) }),
            ("partitioned", 20, { ztd_partitioned_create(2, taps, 100, 32, 0) }),
            ("alpha-beta", 2, { ztd_alpha_beta_create(2, 0.5, 0.01, 1 / 48_000, 0, 0, false) }),
        ]
        for (name, least, create) in constructors {
            var requests = 0
            while requests < 200 {
                var kernel = ztd_kernel_t()
                let outcome = try refusing(requests) { kernel = create() }
                if !outcome.refused {
                    // The constructor made `requests` requests, and each has now been refused once.
                    #expect(!ztd_kernel_is_null(&kernel), "\(name): with nothing refused there is a kernel")
                    ztd_kernel_destroy(&kernel)
                    break
                }
                #expect(ztd_kernel_is_null(&kernel), "\(name): request \(requests) was refused and a kernel came back all the same")
                #expect(kernel.state == nil && kernel.destroy == nil && kernel.reset == nil && kernel.command == nil, "\(name): nothing to call, nothing to free")
                #expect(outcome.counts.allocations == outcome.counts.deallocations, "\(name), request \(requests) refused: \(outcome.counts), so something was not freed")
                ztd_kernel_destroy(&kernel)   // destroying a kernel that is none is harmless
                requests += 1
            }
            #expect(requests >= least && requests < 200, "\(name): \(requests) requests for memory, each refused once")
        }
    }

    /// What the engine keeps beside the kernels: an atomic cell, the two queues, the plan slot,
    /// the plan, the parker. Each asks before every request for memory; refused, it returns
    /// nothing and has freed what it had been given up to then.
    @Test func cellsQueuesSlotsPlansAndParkersSurviveEveryRefusal() throws {
        let constructors: [(name: String, requests: Int, create: () -> OpaquePointer?, destroy: (OpaquePointer?) -> Void)] = [
            ("atomic cell", 1, { ztd_atomic_create(7) }, { ztd_atomic_destroy($0) }),
            ("command queue", 2, { ztd_command_queue_create(8) }, { ztd_command_queue_destroy($0) }),
            ("pointer queue", 2, { ztd_pointer_queue_create(8) }, { ztd_pointer_queue_destroy($0) }),
            ("plan slot", 3, { ztd_plan_slot_create(4) }, { ztd_plan_slot_destroy($0) }),
            ("plan", 6, { ztd_plan_create(2, 2, 64) }, { ztd_plan_destroy($0) }),
            ("parker", 1, { ztd_parker_create() }, { ztd_parker_destroy($0) }),
        ]
        for (name, expected, create, destroy) in constructors {
            var requests = 0
            while requests < 50 {
                var created: OpaquePointer?
                let outcome = try refusing(requests) { created = create() }
                if !outcome.refused {
                    #expect(created != nil, "\(name): with nothing refused it is made")
                    destroy(created)
                    break
                }
                #expect(created == nil, "\(name): request \(requests) was refused and something came back all the same")
                #expect(outcome.counts.allocations == outcome.counts.deallocations, "\(name), request \(requests) refused: \(outcome.counts), so something was not freed")
                destroy(created)        // destroying nothing is harmless
                requests += 1
            }
            #expect(requests == expected, "\(name): \(requests) requests for memory, each refused once")
        }
    }

    /// A switch asks too: for itself, and, for a kernel with latency, for the delay line of the
    /// unprocessed path and for the block that carries it (ACT-8). Refused, the kernel has no
    /// switch, the plan is as it was, and nothing is left behind.
    @Test func aSwitchSurvivesEveryRefusal() throws {
        for (latency, expected) in [(0, 1), (5, 5)] {
            let plan = try #require(ztd_plan_create(1, 2, 64))
            defer { ztd_plan_destroy(plan) }
            #expect(ztd_plan_append(plan, TestKernel.make(gain: 2, latency: latency).kernel, true) == 0)
            var requests = 0
            while requests < 50 {
                var granted = false
                let outcome = try refusing(requests) { granted = ztd_plan_make_switchable(plan, 0, 480, false) }
                if !outcome.refused {
                    #expect(granted && ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_BYPASSED, "with nothing refused the kernel has its switch")
                    break
                }
                #expect(!granted && ztd_plan_switch_state(plan, 0) == ZTD_SWITCH_ACTIVE, "request \(requests) was refused: no switch, and the kernel stays active")
                #expect(outcome.counts.allocations == outcome.counts.deallocations, "latency \(latency), request \(requests) refused: \(outcome.counts)")
                requests += 1
            }
            #expect(requests == expected, "a switch on a kernel with \(latency) frames of latency: \(requests) requests")
        }
    }

    /// The gain cascade of the engine (F1) and a plan behind the kernel ABI (ACT-6): the first
    /// asks for itself and for its factors; the second asks for nothing, the plan it wraps is
    /// made already.
    @Test func theGainCascadeSurvivesEveryRefusalAndAPlanAsAKernelAsksForNothing() throws {
        var requests = 0
        while requests < 50 {
            var kernel = ztd_kernel_t()
            let outcome = try refusing(requests) { kernel = ztd_gain_cascade_create(2, [0.5, 2, 3], 3, 480, ZTD_IMPLEMENTATION_NATIVE) }
            if !outcome.refused {
                #expect(!ztd_kernel_is_null(&kernel))
                ztd_kernel_destroy(&kernel)
                break
            }
            #expect(ztd_kernel_is_null(&kernel) && kernel.state == nil && kernel.destroy == nil && kernel.reset == nil && kernel.command == nil)
            #expect(outcome.counts.allocations == outcome.counts.deallocations, "request \(requests) refused: \(outcome.counts)")
            requests += 1
        }
        #expect(requests == 2, "the cascade and its factors: \(requests) requests")

        let inner = try #require(ztd_plan_create(1, 1, 64))
        #expect(ztd_plan_append(inner, TestKernel.make(gain: 2).kernel, true) == 0)
        var nested = ztd_kernel_t()
        let outcome = try refusing(0) { nested = ztd_plan_as_kernel(inner) }
        #expect(!outcome.refused && !ztd_kernel_is_null(&nested) && outcome.counts.allocations == 0, "nothing was asked for")
        ztd_kernel_destroy(&nested)
    }

    /// Asking costs nothing. A constructor asks the seam before every request, the smallest
    /// ones too (an atomic cell); if the question itself allocated, the first time a thread
    /// asks, then every audit of what a thread allocates would be off by that much on a thread
    /// that had not asked before. On a thread that has never asked, an atomic cell is one
    /// allocation, and freeing it one deallocation.
    @Test func askingTheSeamAllocatesNothingOnAThreadThatNeverAsked() async throws {
        let outcome: (made: AllocationCounts?, freed: AllocationCounts?) = await withCheckedContinuation { continuation in
            let thread = Thread {
                var cell: OpaquePointer?
                let made = try? countAllocations { cell = ztd_atomic_create(1) }
                let freed = try? countAllocations { ztd_atomic_destroy(cell) }
                continuation.resume(returning: (made, freed))
            }
            thread.start()
        }
        #expect(outcome.made == AllocationCounts(allocations: 1, deallocations: 0, bytes: 64), "the cell, and nothing for having asked: \(String(describing: outcome.made))")
        #expect(outcome.freed?.allocations == 0 && outcome.freed?.deallocations == 1)
    }

    /// The ring. A refusal of memory fails the creation. A refusal of the mapping, or of the mirror
    /// of a channel, fails a ring that demanded the mirror, and makes an automatic one fall back to
    /// plain storage with the capacity it would have had: the automatic fall-back of WP-203.
    @Test func theRingSurvivesEveryRefusalAndAnAutomaticOneFallsBack() throws {
        let page = Int(getpagesize()) / MemoryLayout<Float>.stride
        for (storage, name) in [(ZTD_RING_STORAGE_PLAIN, "plain"), (ZTD_RING_STORAGE_MIRRORED, "mirrored"), (ZTD_RING_STORAGE_AUTOMATIC, "automatic")] {
            var requests = 0, fallBacks = 0
            while requests < 50 {
                var created: OpaquePointer? = nil
                let outcome = try refusing(requests) { created = ztd_ring_create(2, 100, storage) }
                defer { ztd_ring_destroy(created) }
                if !outcome.refused {
                    #expect(created != nil && ztd_ring_is_mirrored(created) == (storage != ZTD_RING_STORAGE_PLAIN), "\(name): with nothing refused the ring is what was asked for")
                    break
                }
                if let ring = created {
                    // Only an automatic ring may exist after a refusal: the one that fell back.
                    #expect(storage == ZTD_RING_STORAGE_AUTOMATIC && requests >= 2, "\(name): request \(requests) was refused and a ring came back")
                    #expect(!ztd_ring_is_mirrored(ring), "it is not mirrored")
                    #expect(Int(ztd_ring_capacity(ring)) == page, "and holds what a mirrored ring would have held")
                    fallBacks += 1
                    // It is a working ring: a window across the wrap is read by copy, correctly.
                    let box = try #require(TestRing(adopting: ring, channels: 2))
                    created = nil
                    func frames(_ range: Range<Int>) -> [[Float]] { [range.map(Float.init), range.map { -Float($0) }] }
                    #expect(box.write(frames(0 ..< page - 10)) == page - 10 && box.consume(page - 10) == page - 10)
                    #expect(box.write(frames(0 ..< 30)) == 30)
                    #expect(box.peek(0, 30) == nil && box.read(30) == frames(0 ..< 30))
                } else {
                    #expect(outcome.counts.allocations == outcome.counts.deallocations, "\(name), request \(requests) refused: \(outcome.counts), so something was not freed")
                }
                requests += 1
            }
            switch storage {
            case ZTD_RING_STORAGE_PLAIN: #expect(requests == 3 && fallBacks == 0, "the ring, its channel table, its block")
            case ZTD_RING_STORAGE_MIRRORED: #expect(requests == 5 && fallBacks == 0, "the ring, its channel table, the mapping, a mirror per channel")
            default: #expect(requests == 5 && fallBacks == 3, "refusing the mapping or either mirror gives the fall-back")
            }
        }
    }
}
