#include "ztd_queue.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "ztd_internal.h"

static uint32_t ztd_round_up_power_of_two(uint32_t value) {
    uint32_t result = 2;
    while (result < value && result < (1u << 30)) result <<= 1;
    return result;
}

/* Head and tail on separate cache lines: the producer writes one, the consumer the other. */
#define ZTD_CACHE_LINE 64

/* --- Command queue -------------------------------------------------------------------------- */

struct ztd_command_queue {
    ztd_command_t *slots;
    uint32_t mask;
    _Alignas(ZTD_CACHE_LINE) _Atomic(uint64_t) tail;       /* next slot to write; producer */
    _Atomic(uint64_t) overflows;
    _Alignas(ZTD_CACHE_LINE) _Atomic(uint64_t) head;       /* next slot to read; consumer */
    _Atomic(uint64_t) applied;
};

ztd_command_queue_t *ztd_command_queue_create(uint32_t capacity) {
    ztd_command_queue_t *queue = NULL;
    if (!ztd_may_allocate() || posix_memalign((void **)&queue, ZTD_CACHE_LINE, sizeof(*queue)) != 0 || !queue) return NULL;
    memset(queue, 0, sizeof(*queue));
    uint32_t size = ztd_round_up_power_of_two(capacity);
    queue->slots = ztd_may_allocate() ? calloc(size, sizeof(ztd_command_t)) : NULL;
    if (!queue->slots) {
        free(queue);
        return NULL;
    }
    /* Zeroed memory is not memory that is there yet: written once here, so that neither end of
       the queue takes a first-touch fault later (RT-9). */
    memset(queue->slots, 0, (size_t)size * sizeof(ztd_command_t));
    queue->mask = size - 1;
    atomic_init(&queue->tail, 0);
    atomic_init(&queue->head, 0);
    atomic_init(&queue->overflows, 0);
    atomic_init(&queue->applied, 0);
    return queue;
}

void ztd_command_queue_destroy(ztd_command_queue_t *queue) {
    if (!queue) return;
    free(queue->slots);
    free(queue);
}

uint64_t ztd_command_queue_push(ztd_command_queue_t *queue, const ztd_command_t *command) ZTD_NONBLOCKING {
    const uint64_t tail = atomic_load_explicit(&queue->tail, memory_order_relaxed);
    const uint64_t head = atomic_load_explicit(&queue->head, memory_order_acquire);
    if (tail - head > queue->mask) {
        atomic_fetch_add_explicit(&queue->overflows, 1, memory_order_relaxed);
        return 0;
    }
    ztd_command_t *slot = &queue->slots[tail & queue->mask];
    *slot = *command;
    slot->sequence = tail + 1;
    atomic_store_explicit(&queue->tail, tail + 1, memory_order_release);
    return tail + 1;
}

bool ztd_command_queue_pop(ztd_command_queue_t *queue, ztd_command_t *command) ZTD_NONBLOCKING {
    const uint64_t head = atomic_load_explicit(&queue->head, memory_order_relaxed);
    const uint64_t tail = atomic_load_explicit(&queue->tail, memory_order_acquire);
    if (head == tail) return false;
    *command = queue->slots[head & queue->mask];
    atomic_store_explicit(&queue->head, head + 1, memory_order_release);
    return true;
}

void ztd_command_queue_acknowledge(ztd_command_queue_t *queue, uint64_t sequence) ZTD_NONBLOCKING {
    atomic_store_explicit(&queue->applied, sequence, memory_order_release);
}

uint64_t ztd_command_queue_applied(const ztd_command_queue_t *queue) ZTD_NONBLOCKING {
    return atomic_load_explicit(&((ztd_command_queue_t *)queue)->applied, memory_order_acquire);
}

uint64_t ztd_command_queue_overflows(const ztd_command_queue_t *queue) ZTD_NONBLOCKING {
    return atomic_load_explicit(&((ztd_command_queue_t *)queue)->overflows, memory_order_relaxed);
}

/* --- Pointer queue -------------------------------------------------------------------------- */

struct ztd_pointer_queue {
    void **slots;
    uint32_t mask;
    _Alignas(ZTD_CACHE_LINE) _Atomic(uint64_t) tail;
    _Alignas(ZTD_CACHE_LINE) _Atomic(uint64_t) head;
};

ztd_pointer_queue_t *ztd_pointer_queue_create(uint32_t capacity) {
    ztd_pointer_queue_t *queue = NULL;
    if (!ztd_may_allocate() || posix_memalign((void **)&queue, ZTD_CACHE_LINE, sizeof(*queue)) != 0 || !queue) return NULL;
    memset(queue, 0, sizeof(*queue));
    uint32_t size = ztd_round_up_power_of_two(capacity);
    queue->slots = ztd_may_allocate() ? calloc(size, sizeof(void *)) : NULL;
    if (!queue->slots) {
        free(queue);
        return NULL;
    }
    memset(queue->slots, 0, (size_t)size * sizeof(void *)); /* touched now, not on the analysis thread (RT-9) */
    queue->mask = size - 1;
    atomic_init(&queue->tail, 0);
    atomic_init(&queue->head, 0);
    return queue;
}

void ztd_pointer_queue_destroy(ztd_pointer_queue_t *queue) {
    if (!queue) return;
    free(queue->slots);
    free(queue);
}

bool ztd_pointer_queue_push(ztd_pointer_queue_t *queue, void *pointer) ZTD_NONBLOCKING {
    if (!pointer) return false;
    const uint64_t tail = atomic_load_explicit(&queue->tail, memory_order_relaxed);
    const uint64_t head = atomic_load_explicit(&queue->head, memory_order_acquire);
    if (tail - head > queue->mask) return false;
    queue->slots[tail & queue->mask] = pointer;
    atomic_store_explicit(&queue->tail, tail + 1, memory_order_release);
    return true;
}

void *ztd_pointer_queue_pop(ztd_pointer_queue_t *queue) ZTD_NONBLOCKING {
    const uint64_t head = atomic_load_explicit(&queue->head, memory_order_relaxed);
    const uint64_t tail = atomic_load_explicit(&queue->tail, memory_order_acquire);
    if (head == tail) return NULL;
    void *pointer = queue->slots[head & queue->mask];
    atomic_store_explicit(&queue->head, head + 1, memory_order_release);
    return pointer;
}

/* --- Plan slot ------------------------------------------------------------------------------ */

struct ztd_plan_slot {
    _Alignas(ZTD_CACHE_LINE) _Atomic(void *) pending;   /* control writes, analysis takes */
    _Alignas(ZTD_CACHE_LINE) _Atomic(void *) current;   /* analysis writes; anyone may read */
    _Atomic(uint64_t) exchanges;
    ztd_pointer_queue_t *retired;                        /* analysis produces, control consumes */
};

ztd_plan_slot_t *ztd_plan_slot_create(uint32_t retire_capacity) {
    ztd_plan_slot_t *slot = NULL;
    if (!ztd_may_allocate() || posix_memalign((void **)&slot, ZTD_CACHE_LINE, sizeof(*slot)) != 0 || !slot) return NULL;
    memset(slot, 0, sizeof(*slot));
    atomic_init(&slot->pending, NULL);
    atomic_init(&slot->current, NULL);
    atomic_init(&slot->exchanges, 0);
    slot->retired = ztd_pointer_queue_create(retire_capacity);
    if (!slot->retired) {
        free(slot);
        return NULL;
    }
    return slot;
}

void ztd_plan_slot_destroy(ztd_plan_slot_t *slot) {
    if (!slot) return;
    ztd_pointer_queue_destroy(slot->retired);
    free(slot);
}

void *ztd_plan_slot_publish(ztd_plan_slot_t *slot, void *plan) {
    return atomic_exchange_explicit(&slot->pending, plan, memory_order_acq_rel);
}

bool ztd_plan_slot_has_pending(const ztd_plan_slot_t *slot) ZTD_NONBLOCKING {
    return atomic_load_explicit(&((ztd_plan_slot_t *)slot)->pending, memory_order_acquire) != NULL;
}

void *ztd_plan_slot_withdraw(ztd_plan_slot_t *slot) {
    return atomic_exchange_explicit(&slot->pending, NULL, memory_order_acq_rel);
}

void *ztd_plan_slot_next_retired(ztd_plan_slot_t *slot) {
    return ztd_pointer_queue_pop(slot->retired);
}

void *ztd_plan_slot_take(ztd_plan_slot_t *slot) ZTD_NONBLOCKING {
    /* Most blocks find nothing pending: look before exchanging, so the common case is a load. */
    if (!atomic_load_explicit(&slot->pending, memory_order_acquire)) return NULL;
    return atomic_exchange_explicit(&slot->pending, NULL, memory_order_acq_rel);
}

void *ztd_plan_slot_current(const ztd_plan_slot_t *slot) ZTD_NONBLOCKING {
    return atomic_load_explicit(&((ztd_plan_slot_t *)slot)->current, memory_order_acquire);
}

void *ztd_plan_slot_install(ztd_plan_slot_t *slot, void *plan) ZTD_NONBLOCKING {
    void *previous = atomic_exchange_explicit(&slot->current, plan, memory_order_acq_rel);
    atomic_fetch_add_explicit(&slot->exchanges, 1, memory_order_relaxed);
    return previous;
}

bool ztd_plan_slot_retire(ztd_plan_slot_t *slot, void *plan) ZTD_NONBLOCKING {
    return ztd_pointer_queue_push(slot->retired, plan);
}

uint64_t ztd_plan_slot_exchanges(const ztd_plan_slot_t *slot) ZTD_NONBLOCKING {
    return atomic_load_explicit(&((ztd_plan_slot_t *)slot)->exchanges, memory_order_relaxed);
}
