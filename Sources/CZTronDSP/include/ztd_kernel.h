#ifndef ZTD_KERNEL_H
#define ZTD_KERNEL_H

#include "ztd_base.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------
   The kernel ABI (specification §5.11.1, fixed by WP-204).

   A kernel is one stage of a signal chain as the analysis thread runs it: a table of functions
   and a pointer to its state. A plan runs a table of kernels with ztd_plan_run; a stage written
   outside the package supplies a ztd_kernel_t of its own and is run exactly like a stock one.

   Threading. `process`, `command` and `reset` run on the analysis thread and are non-blocking:
   no allocation, no lock, no system call (RT-2). `destroy`, and whatever created the state, run
   on the control context. A kernel belongs to one plan at a time and is touched by one thread at
   a time.
   --------------------------------------------------------------------------------------------- */

/* What a command asks of a kernel. Values below ZTD_COMMAND_CUSTOM are the package's own; a
   kernel written outside the package may define its own kinds from ZTD_COMMAND_CUSTOM up. */
enum {
    /* New values for a running kernel: a gain's target, a cascade's coefficients, an FIR's taps.
       What `values` holds, and how the kernel moves to it without a click, is the kernel's. */
    ZTD_COMMAND_SET_VALUES = 1,
    /* Switch the stage on (scalar[0] != 0) or off. Handled by the plan, never by a kernel. */
    ZTD_COMMAND_SET_ACTIVE = 2,
    ZTD_COMMAND_CUSTOM = 1024,
};

/* A fixed-size message from the control context to the analysis thread (RT-4). Small payloads
   travel in `scalar`; larger ones are pointed to by `values`, stay owned by the control context,
   and stay valid until the command has been applied (see ztd_command_queue_applied). A kernel
   copies what it needs out of `values` and never keeps the pointer. */
typedef struct ztd_command {
    uint32_t target;      /* which stage of the plan the command is for */
    uint32_t kind;        /* ZTD_COMMAND_… */
    uint32_t count;       /* elements at `values` */
    uint32_t flags;       /* kernel-defined */
    const void *values;   /* payload owned by the control context, or NULL */
    double scalar[2];     /* payload carried in the message */
    uint64_t sequence;    /* set by the queue; commands are applied in sequence order */
} ztd_command_t;

/* One stage of a signal chain as the plan runner calls it: its functions and its state. A value
   copied into a plan when the plan is built; see "Threading" above for which function runs where. */
typedef struct ztd_kernel {
    /* Processes `frames` frames of `channels` channels from `in` to `out` and returns the number
       of frames written. A kernel that keeps the rate returns `frames`; a rate changer returns
       what it produced, carrying its phase across calls, so any sequence of block sizes gives
       the same output stream. `in` and `out` never alias. `frames` may be 0. `channels` is the
       count the kernel was created for. */
    uint32_t (*process)(void *state, const float *const *in, float *const *out, uint32_t channels,
                        uint32_t frames) ZTD_NONBLOCKING;
    /* Applies a value change at a block boundary. May be NULL for a kernel without live values. */
    void (*command)(void *state, const ztd_command_t *command) ZTD_NONBLOCKING;
    /* Back to the state at creation: a cold start (ACT-10). Coefficients are kept, memory is not. */
    void (*reset)(void *state) ZTD_NONBLOCKING;
    /* Frees the state. Control context only. May be NULL when the state needs no freeing. */
    void (*destroy)(void *state);
    void *state;
    /* Delay, in input frames, between a sample entering and its counterpart leaving (REAL-5). */
    uint32_t latency_frames;
    /* Frames the kernel needs, after a reset, before its output is what it would have been had
       it always been running: the pre-roll length (SWAP-2, ACT-7). */
    uint32_t settling_frames;
} ztd_kernel_t;

/* A kernel that copies its input to its output: an identity. */
ztd_kernel_t ztd_kernel_identity(void);

/* True for a kernel whose creation failed: every ztd_…_create returns a kernel whose `process`
   is NULL when it cannot allocate or when its arguments make no kernel. */
static inline bool ztd_kernel_is_null(const ztd_kernel_t *kernel) {
    /* `!pointer`, not `pointer == NULL`: comparing with NULL converts NULL to a non-blocking
       function type, which clang rejects under -Wfunction-effects. */
    return !kernel || !kernel->process;
}

/* Frees a kernel's state through its `destroy`, if it has one. Control context. */
void ztd_kernel_destroy(ztd_kernel_t *kernel);

#ifdef __cplusplus
}
#endif

#endif /* ZTD_KERNEL_H */
