#ifndef ZTD_ATOMIC_H
#define ZTD_ATOMIC_H

#include "ztd_base.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A 64-bit atomic cell for the Swift side of the package. At the deployment floor Swift has no
   atomics of its own (PLAT-1), so the single atomic words that cross threads (RT-4: generation
   counters, flags, latest-value slots) are C11 atomics behind these functions. The cell is
   opaque because Swift cannot import an `_Atomic` field. */
typedef struct ztd_atomic ztd_atomic_t;

/* Control context. NULL when memory cannot be had. */
ztd_atomic_t *ztd_atomic_create(uint64_t initial);
void ztd_atomic_destroy(ztd_atomic_t *cell);

/* Reads the value (acquire) and writes it (release). Any thread, the I/O and analysis threads
   included: neither allocates nor blocks. */
uint64_t ztd_atomic_load(const ztd_atomic_t *cell) ZTD_NONBLOCKING;
void ztd_atomic_store(ztd_atomic_t *cell, uint64_t value) ZTD_NONBLOCKING;
/* Adds and returns the new value. */
uint64_t ztd_atomic_add(ztd_atomic_t *cell, uint64_t amount) ZTD_NONBLOCKING;
/* Stores and returns the previous value. */
uint64_t ztd_atomic_exchange(ztd_atomic_t *cell, uint64_t value) ZTD_NONBLOCKING;
/* A full memory barrier. A store sequence-locked by two counters needs one on each side: the
   writer after it has announced a write and before it touches the data, the reader after it has
   copied the data and before it reads the counter that validates the copy. Acquire and release
   order the counters among themselves; only a barrier orders them against the plain copies
   beside them (measured: without it a reader on arm64 is handed torn data). */
void ztd_atomic_barrier(void) ZTD_NONBLOCKING;

/* Stores `desired` when the cell holds `expected`. Returns whether it did. */
bool ztd_atomic_compare_exchange(ztd_atomic_t *cell, uint64_t expected, uint64_t desired) ZTD_NONBLOCKING;

#ifdef __cplusplus
}
#endif

#endif /* ZTD_ATOMIC_H */
