#include "ztd_atomic.h"

#include <stdatomic.h>
#include <stdlib.h>

#include "ztd_internal.h"

struct ztd_atomic {
    _Atomic(uint64_t) value;
};

ztd_atomic_t *ztd_atomic_create(uint64_t initial) {
    ztd_atomic_t *cell = NULL;
    /* A cache line of its own, so two cells never share one (no false sharing). */
    if (!ztd_may_allocate() || posix_memalign((void **)&cell, 64, 64) != 0 || !cell) return NULL;
    atomic_init(&cell->value, initial);
    return cell;
}

void ztd_atomic_destroy(ztd_atomic_t *cell) {
    free(cell);
}

uint64_t ztd_atomic_load(const ztd_atomic_t *cell) ZTD_NONBLOCKING {
    return atomic_load_explicit(&((ztd_atomic_t *)cell)->value, memory_order_acquire);
}

void ztd_atomic_store(ztd_atomic_t *cell, uint64_t value) ZTD_NONBLOCKING {
    atomic_store_explicit(&cell->value, value, memory_order_release);
}

uint64_t ztd_atomic_add(ztd_atomic_t *cell, uint64_t amount) ZTD_NONBLOCKING {
    return atomic_fetch_add_explicit(&cell->value, amount, memory_order_acq_rel) + amount;
}

uint64_t ztd_atomic_exchange(ztd_atomic_t *cell, uint64_t value) ZTD_NONBLOCKING {
    return atomic_exchange_explicit(&cell->value, value, memory_order_acq_rel);
}

bool ztd_atomic_compare_exchange(ztd_atomic_t *cell, uint64_t expected, uint64_t desired) ZTD_NONBLOCKING {
    return atomic_compare_exchange_strong_explicit(&cell->value, &expected, desired, memory_order_acq_rel,
                                                   memory_order_acquire);
}

void ztd_atomic_barrier(void) ZTD_NONBLOCKING {
    atomic_thread_fence(memory_order_seq_cst);
}
