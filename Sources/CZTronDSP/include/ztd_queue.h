#ifndef ZTD_QUEUE_H
#define ZTD_QUEUE_H

#include "ztd_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------
   The lock-free channels between the control side and the analysis thread (RT-4): the command
   queue, a queue of pointers, and the plan slot. Each queue has ONE producer thread and ONE
   consumer thread; neither ever waits for the other.
   --------------------------------------------------------------------------------------------- */

/* --- Command queue (WP-206) ------------------------------------------------------------------
   Fixed-size messages from one producer to the analysis thread, applied in order at block
   boundaries. */
typedef struct ztd_command_queue ztd_command_queue_t;

/* `capacity` is rounded up to a power of two (at least 2). Control context. */
ztd_command_queue_t *ztd_command_queue_create(uint32_t capacity);
void ztd_command_queue_destroy(ztd_command_queue_t *queue);

/* Producer. Copies the command in, stamps its `sequence` (1, 2, 3, …) and returns that sequence;
   returns 0 when the queue is full: the command was not queued and the overflow is counted.
   Never blocks. */
uint64_t ztd_command_queue_push(ztd_command_queue_t *queue, const ztd_command_t *command) ZTD_NONBLOCKING;

/* Consumer. Takes the oldest command. Returns false when the queue is empty. */
bool ztd_command_queue_pop(ztd_command_queue_t *queue, ztd_command_t *command) ZTD_NONBLOCKING;

/* Consumer. Declares that every command up to and including `sequence` has been applied. From
   then on the producer may free the payloads those commands pointed to. */
void ztd_command_queue_acknowledge(ztd_command_queue_t *queue, uint64_t sequence) ZTD_NONBLOCKING;

/* The sequence of the last command acknowledged. Any thread. */
uint64_t ztd_command_queue_applied(const ztd_command_queue_t *queue) ZTD_NONBLOCKING;

/* Commands refused because the queue was full. Any thread. */
uint64_t ztd_command_queue_overflows(const ztd_command_queue_t *queue) ZTD_NONBLOCKING;

/* --- Pointer queue ---------------------------------------------------------------------------
   The same, for pointers: the retire list, and small events travelling back to the control side. */
typedef struct ztd_pointer_queue ztd_pointer_queue_t;

/* Creates a queue that holds `capacity` pointers rounded up to a power of two, from 2 to 2^30
   (NULL when memory cannot be had), and frees one (NULL is allowed). Control context: both
   allocate or free. */
ztd_pointer_queue_t *ztd_pointer_queue_create(uint32_t capacity);
void ztd_pointer_queue_destroy(ztd_pointer_queue_t *queue);
/* Producer. False when the queue is full; the pointer was not queued. NULL cannot be queued. */
bool ztd_pointer_queue_push(ztd_pointer_queue_t *queue, void *pointer) ZTD_NONBLOCKING;
/* Consumer. NULL when the queue is empty. */
void *ztd_pointer_queue_pop(ztd_pointer_queue_t *queue) ZTD_NONBLOCKING;

/* --- Plan slot (WP-205) ----------------------------------------------------------------------
   Where the control context hands a compiled plan to the analysis thread, and where the analysis
   thread hands a plan it has stopped using back, to be destroyed off-thread (RT-3). Plans are
   opaque pointers here.

   Control publishes a plan as *pending*. At a block boundary the analysis thread takes the
   pending plan with one atomic exchange, makes it current when it is ready to (after any
   pre-roll), and retires the previous one. A plan published while another is still pending
   replaces it: the latest update wins (SWAP-4), and the replaced plan, which never ran, is
   returned to the publisher. */
typedef struct ztd_plan_slot ztd_plan_slot_t;

/* `retire_capacity` plans can wait to be destroyed at once. Control context. */
ztd_plan_slot_t *ztd_plan_slot_create(uint32_t retire_capacity);
/* Does not destroy plans: drain the slot first. */
void ztd_plan_slot_destroy(ztd_plan_slot_t *slot);

/* Control. Makes `plan` pending and returns the pending plan it replaced, or NULL. */
void *ztd_plan_slot_publish(ztd_plan_slot_t *slot, void *plan);
/* Any thread. True while a published plan has not been taken yet. */
bool ztd_plan_slot_has_pending(const ztd_plan_slot_t *slot) ZTD_NONBLOCKING;
/* Control. Withdraws the pending plan, if the analysis thread has not taken it yet. */
void *ztd_plan_slot_withdraw(ztd_plan_slot_t *slot);
/* Control. The next plan the analysis thread has finished with, or NULL. */
void *ztd_plan_slot_next_retired(ztd_plan_slot_t *slot);

/* Analysis thread. Takes the pending plan, or NULL when there is none. */
void *ztd_plan_slot_take(ztd_plan_slot_t *slot) ZTD_NONBLOCKING;
/* Analysis thread. The plan it is running. */
void *ztd_plan_slot_current(const ztd_plan_slot_t *slot) ZTD_NONBLOCKING;
/* Analysis thread. Makes `plan` the current one and returns the previous current plan. */
void *ztd_plan_slot_install(ztd_plan_slot_t *slot, void *plan) ZTD_NONBLOCKING;
/* Analysis thread. Hands a plan back for destruction. False when the retire list is full: keep
   the plan and try again at the next block. */
bool ztd_plan_slot_retire(ztd_plan_slot_t *slot, void *plan) ZTD_NONBLOCKING;

/* Exchanges since creation: how often `install` replaced a plan. Any thread. */
uint64_t ztd_plan_slot_exchanges(const ztd_plan_slot_t *slot) ZTD_NONBLOCKING;

#ifdef __cplusplus
}
#endif

#endif /* ZTD_QUEUE_H */
