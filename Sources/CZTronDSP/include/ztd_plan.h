#ifndef ZTD_PLAN_H
#define ZTD_PLAN_H

#include "ztd_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------
   The plan runner (WP-204, WP-220, WP-221, WP-224, WP-225).

   A plan is a flat table of kernels that the analysis thread runs in order on a block of
   samples: one indirect call per kernel per block, no allocation, no lock (§5.5.2). The first
   kernel reads the caller's input, the last writes the caller's output, and the ones between
   pass blocks through two scratch buffers the plan owns.

   Threading. A plan is built, changed in shape and destroyed on the control context. It is run,
   commanded and reset on the analysis thread. One thread at a time.
   --------------------------------------------------------------------------------------------- */

/* A plan: opaque, owned by whoever created it, destroyed with ztd_plan_destroy. */
typedef struct ztd_plan ztd_plan_t;

/* The state of a stage's activation switch (§5.9). */
typedef enum ztd_switch_state {
    ZTD_SWITCH_ACTIVE = 0,      /* the kernel runs and its output is used */
    ZTD_SWITCH_FADING_OUT = 1,  /* cross-fading from the processed to the unprocessed signal */
    ZTD_SWITCH_BYPASSED = 2,    /* the kernel is not called; the unprocessed signal passes */
    ZTD_SWITCH_PREROLLING = 3,  /* the kernel runs with its output discarded (ACT-7) */
    ZTD_SWITCH_FADING_IN = 4,   /* cross-fading from the unprocessed to the processed signal */
} ztd_switch_state_t;

/* --- Control context ------------------------------------------------------------------------ */

/* Creates an empty plan for up to `kernel_capacity` kernels of `channels` channels.
   `maximum_frames` is the largest number of frames any kernel of the plan will read or write in
   one call, rate changes included: it sizes the scratch buffers. NULL when memory cannot be
   had, and for a plan no machine is asked to hold: more than 2^24 kernels or channels, or
   scratch buffers of more than 2^28 samples (frames times channels), which is refused before
   the buffers are asked for. */
ztd_plan_t *ztd_plan_create(uint32_t kernel_capacity, uint32_t channels, uint32_t maximum_frames);

/* Destroys the plan and every kernel it owns. */
void ztd_plan_destroy(ztd_plan_t *plan);

/* Appends a kernel and returns its index, or UINT32_MAX when the plan is full or the kernel is
   null. An `owned` kernel is destroyed with the plan; a borrowed one is not. */
uint32_t ztd_plan_append(ztd_plan_t *plan, ztd_kernel_t kernel, bool owned);

/* Gives the kernel at `index` an activation switch (ACT-5). Only for a kernel that keeps the
   rate: a rate changer cannot be bypassed.
     fade_frames  the length of the cross-fade: 10 ms, and never shorter than one block (ACT-7)
     active       the switch's position when the plan starts; an inactive stage starts bypassed
   A kernel with latency gets an unprocessed path that is a delay line of that many frames, fed
   in both states, so switching never changes the alignment downstream (ACT-8).
   A stage that is switched on is reset and runs unheard, before it is faded in, for its
   pre-roll: the kernel's latency plus its settling time, or UINT32_MAX frames when the two add
   up to more (ACT-7). `ztd_plan_set_switch_preroll` states another figure.
   Returns false when memory cannot be had (a delay line of more than 2^28 samples is not asked
   for) or the index is out of range. */
bool ztd_plan_make_switchable(ztd_plan_t *plan, uint32_t index, uint32_t fade_frames, bool active);

/* States the pre-roll of the switch at `index`, in frames: how long the kernel runs unheard
   when it is switched on. For a caller that knows the rate, which a plan does not: the engine
   runs a stage for its latency and for its settling time up to one second (ACT-7, SWAP-2).
   Before the plan runs, or between two blocks. Returns false when there is no switch at
   `index`. */
bool ztd_plan_set_switch_preroll(ztd_plan_t *plan, uint32_t index, uint32_t frames);

/* Moves the kernel at `from_index` of `from`, with its state and its ownership, to `to_index` of
   `to`, whose own kernel at that index (a placeholder) is destroyed if it was owned. `from`
   keeps a borrowed reference, so it stays runnable until it is retired, and the kernel is
   destroyed exactly once, by `to` (WP-224, SWAP-1). The switch, if any, stays with its plan. */
bool ztd_plan_transfer(ztd_plan_t *from, uint32_t from_index, ztd_plan_t *to, uint32_t to_index);

/* The number of kernels, the channel count and the largest block (in frames) the plan was built
   for. Any thread that owns the plan at that moment; none allocates. */
uint32_t ztd_plan_count(const ztd_plan_t *plan) ZTD_NONBLOCKING;
uint32_t ztd_plan_channels(const ztd_plan_t *plan) ZTD_NONBLOCKING;
uint32_t ztd_plan_maximum_frames(const ztd_plan_t *plan) ZTD_NONBLOCKING;
/* The kernel at `index` (a copy of its table entry), or an entry with a NULL `process`. */
ztd_kernel_t ztd_plan_kernel(const ztd_plan_t *plan, uint32_t index) ZTD_NONBLOCKING;
/* The sum of the kernels' latencies, in frames of the plan's input (rate changes not applied);
   UINT32_MAX when they add up to more than 32 bits count. */
uint32_t ztd_plan_latency(const ztd_plan_t *plan) ZTD_NONBLOCKING;

/* --- Analysis thread ------------------------------------------------------------------------ */

/* Runs every kernel in order from `in` to `out` and returns the frames written to `out`. `in`
   and `out` do not alias. An empty plan copies. */
uint32_t ztd_plan_run(ztd_plan_t *plan, const float *const *in, float *const *out, uint32_t channels,
                      uint32_t frames) ZTD_NONBLOCKING;

/* Runs the kernels `first` … `last − 1` only: the two halves of a plan around the point where a
   new plan starts to differ (SWAP-2). An empty range copies. */
uint32_t ztd_plan_run_range(ztd_plan_t *plan, uint32_t first, uint32_t last, const float *const *in,
                            float *const *out, uint32_t channels, uint32_t frames) ZTD_NONBLOCKING;

/* Pre-roll (WP-225): runs the kernels from `first` on, on `in`, and discards their output, so
   that their state is what it would be had they been running live (SWAP-2, ACT-7). */
void ztd_plan_preroll(ztd_plan_t *plan, uint32_t first, const float *const *in, uint32_t channels,
                      uint32_t frames) ZTD_NONBLOCKING;

/* Applies a command to the kernel at `command->target`, at a block boundary: ZTD_COMMAND_SET_ACTIVE
   moves its switch, anything else goes to the kernel's own `command`. A command for an index
   that does not exist, or a switch command for a kernel without a switch, is ignored. */
void ztd_plan_command(ztd_plan_t *plan, const ztd_command_t *command) ZTD_NONBLOCKING;

/* A cold start (ACT-10): resets every kernel, clears every delay line, and lets every switch
   that was in transit arrive where it was going. */
void ztd_plan_reset(ztd_plan_t *plan) ZTD_NONBLOCKING;

/* The state of the switch at `index`; ZTD_SWITCH_ACTIVE for a kernel without one. */
ztd_switch_state_t ztd_plan_switch_state(const ztd_plan_t *plan, uint32_t index) ZTD_NONBLOCKING;

#ifdef __cplusplus
}
#endif

#endif /* ZTD_PLAN_H */
