#ifndef CZTRONDSPTESTING_H
#define CZTRONDSPTESTING_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The C half of the ZTronDSPTesting product (§4.2): the allocation probe of WP-005.

   The probe hooks `malloc_logger`, which observes every allocation and deallocation of the
   process (E-06). The hook is process-wide and tests run in parallel, so it counts only the
   threads that are under audit: an audit is opened and closed by one thread and sees that
   thread's events and nothing else. */

/* What one audited thread did between `begin` and `end`. A value. */
typedef struct ztdt_alloc_counts {
    uint64_t allocations;    /* malloc, calloc, valloc, and the allocating half of realloc */
    uint64_t deallocations;  /* free, and the freeing half of realloc */
    uint64_t bytes;          /* bytes requested by the allocations */
} ztdt_alloc_counts_t;

/* Opens an audit of the calling thread. Returns a token, or a negative value when every slot
   is taken (ZTDT_ALLOC_MAX_AUDITS concurrent audits). Audits do not nest on one thread: a
   second `begin` on a thread under audit returns a negative value. */
int32_t ztdt_alloc_audit_begin(void);

/* Closes the audit and returns what the thread did since `begin`. Must be called on the
   thread that opened it. An invalid token returns zeros. */
ztdt_alloc_counts_t ztdt_alloc_audit_end(int32_t token);

/* True once the hook is installed and has been seen firing. The control case of the test
   suite relies on it: a hook that stops firing must fail loudly, not pass silently (§13.1). */
bool ztdt_alloc_hook_is_live(void);

/* One allocation and one deallocation of `size` bytes that no optimiser can remove: the
   control case of an audit. */
void ztdt_force_allocation(size_t size);

/* `calloc(first)`, `realloc` to `second`, `free`: two allocations and two deallocations that
   no optimiser can remove. */
void ztdt_force_reallocation(size_t first, size_t second);

/* A digest of the calling thread's floating-point environment (rounding mode, exception flags
   and masks, flush-to-zero and the like). Two calls that return the same number saw the same
   environment: what the tests of RT-6 use to show that a kernel leaves it alone. */
uint64_t ztdt_floating_point_environment(void);

/* How many audits may be open at once, on different threads. */
#define ZTDT_ALLOC_MAX_AUDITS 64

#ifdef __cplusplus
}
#endif

#endif /* CZTRONDSPTESTING_H */
