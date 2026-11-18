#include "CZTronDSPTesting.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

/* libmalloc calls this hook, when it is set, for every allocation event. It is not public
   API; it is used by this test product only (§13.1). */
typedef void (ztdt_malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                                    uintptr_t result, uint32_t num_hot_frames_to_skip);
extern ztdt_malloc_logger_t *malloc_logger;

/* From <malloc/_malloc_type.h> / stack_logging.h. */
#define ZTDT_LOG_ALLOCATE   2u
#define ZTDT_LOG_DEALLOCATE 4u
#define ZTDT_LOG_HAS_ZONE   8u

typedef struct ztdt_slot {
    _Atomic(uintptr_t) thread;       /* 0 when free; otherwise the pthread_t under audit */
    _Atomic(uint64_t) allocations;
    _Atomic(uint64_t) deallocations;
    _Atomic(uint64_t) bytes;
} ztdt_slot_t;

static ztdt_slot_t ztdt_slots[ZTDT_ALLOC_MAX_AUDITS];
static _Atomic(int) ztdt_active_audits;
static _Atomic(bool) ztdt_hook_seen;
static ztdt_malloc_logger_t *ztdt_previous_logger;
static pthread_once_t ztdt_install_once = PTHREAD_ONCE_INIT;

static void ztdt_logger(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3,
                        uintptr_t result, uint32_t num_hot_frames_to_skip) {
    atomic_store_explicit(&ztdt_hook_seen, true, memory_order_relaxed);
    if (atomic_load_explicit(&ztdt_active_audits, memory_order_acquire) > 0) {
        /* pthread_self() neither allocates nor locks, so the hook cannot re-enter itself. */
        uintptr_t self = (uintptr_t)pthread_self();
        for (int i = 0; i < ZTDT_ALLOC_MAX_AUDITS; i++) {
            if (atomic_load_explicit(&ztdt_slots[i].thread, memory_order_acquire) != self) continue;
            if (type & ZTDT_LOG_ALLOCATE) {
                /* With a zone the size is the second argument, without it the first. A realloc
                   carries (zone, old pointer, new size). */
                uintptr_t size = (type & ZTDT_LOG_HAS_ZONE) ? arg2 : arg1;
                if (type & ZTDT_LOG_DEALLOCATE) size = arg3;
                atomic_fetch_add_explicit(&ztdt_slots[i].allocations, 1, memory_order_relaxed);
                atomic_fetch_add_explicit(&ztdt_slots[i].bytes, (uint64_t)size, memory_order_relaxed);
            }
            if (type & ZTDT_LOG_DEALLOCATE) {
                atomic_fetch_add_explicit(&ztdt_slots[i].deallocations, 1, memory_order_relaxed);
            }
            break;
        }
    }
    if (ztdt_previous_logger != NULL) {
        ztdt_previous_logger(type, arg1, arg2, arg3, result, num_hot_frames_to_skip);
    }
}

static void ztdt_install(void) {
    /* Chain to whatever was installed before (MallocStackLogging, another tool). The hook is
       never removed: removing it would race with a logger call in flight on another thread. */
    ztdt_previous_logger = malloc_logger;
    malloc_logger = ztdt_logger;
}

int32_t ztdt_alloc_audit_begin(void) {
    pthread_once(&ztdt_install_once, ztdt_install);
    uintptr_t self = (uintptr_t)pthread_self();
    for (int i = 0; i < ZTDT_ALLOC_MAX_AUDITS; i++) {
        if (atomic_load_explicit(&ztdt_slots[i].thread, memory_order_acquire) == self) return -2;
    }
    for (int i = 0; i < ZTDT_ALLOC_MAX_AUDITS; i++) {
        uintptr_t expected = 0;
        /* Claim with a sentinel first so the counters can be cleared before the hook sees
           this thread in the slot. */
        if (!atomic_compare_exchange_strong_explicit(&ztdt_slots[i].thread, &expected, (uintptr_t)1,
                                                     memory_order_acq_rel, memory_order_acquire)) {
            continue;
        }
        atomic_store_explicit(&ztdt_slots[i].allocations, 0, memory_order_relaxed);
        atomic_store_explicit(&ztdt_slots[i].deallocations, 0, memory_order_relaxed);
        atomic_store_explicit(&ztdt_slots[i].bytes, 0, memory_order_relaxed);
        atomic_fetch_add_explicit(&ztdt_active_audits, 1, memory_order_acq_rel);
        atomic_store_explicit(&ztdt_slots[i].thread, self, memory_order_release);
        return (int32_t)i;
    }
    return -1;
}

ztdt_alloc_counts_t ztdt_alloc_audit_end(int32_t token) {
    ztdt_alloc_counts_t counts = {0, 0, 0};
    if (token < 0 || token >= ZTDT_ALLOC_MAX_AUDITS) return counts;
    ztdt_slot_t *slot = &ztdt_slots[token];
    if (atomic_load_explicit(&slot->thread, memory_order_acquire) != (uintptr_t)pthread_self()) return counts;
    /* Stop counting before reading, so the numbers are those of the audited region only. */
    atomic_store_explicit(&slot->thread, (uintptr_t)1, memory_order_release);
    counts.allocations = atomic_load_explicit(&slot->allocations, memory_order_relaxed);
    counts.deallocations = atomic_load_explicit(&slot->deallocations, memory_order_relaxed);
    counts.bytes = atomic_load_explicit(&slot->bytes, memory_order_relaxed);
    atomic_fetch_sub_explicit(&ztdt_active_audits, 1, memory_order_acq_rel);
    atomic_store_explicit(&slot->thread, (uintptr_t)0, memory_order_release);
    return counts;
}

/* Through volatile function pointers, so an optimising compiler cannot pair the two calls up
   and delete them. */
static void *(*volatile ztdt_allocate)(size_t) = malloc;
static void (*volatile ztdt_release)(void *) = free;

static void *(*volatile ztdt_allocate_cleared)(size_t, size_t) = calloc;
static void *(*volatile ztdt_reallocate)(void *, size_t) = realloc;

void ztdt_force_allocation(size_t size) {
    void *block = ztdt_allocate(size);
    ztdt_release(block);
}

void ztdt_force_reallocation(size_t first, size_t second) {
    void *block = ztdt_allocate_cleared(1, first);
    void *grown = ztdt_reallocate(block, second);
    ztdt_release(grown != NULL ? grown : block);
}

bool ztdt_alloc_hook_is_live(void) {
    pthread_once(&ztdt_install_once, ztdt_install);
    if (!atomic_load_explicit(&ztdt_hook_seen, memory_order_relaxed)) {
        /* Provoke one event so a hook that fires is seen firing. */
        ztdt_force_allocation(32);
    }
    return malloc_logger == ztdt_logger && atomic_load_explicit(&ztdt_hook_seen, memory_order_relaxed);
}
