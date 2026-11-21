#ifndef ZTD_ENGINE_H
#define ZTD_ENGINE_H

#include "ztd_kernel.h"
#include "ztd_plan.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Kernels and helpers the plan compiler and the engine use besides the stock kernels. */

/* --- Gain cascade ----------------------------------------------------------------------------
   out = (((in · g0) · g1) · …) · g(count−1), every channel alike. It is what one gain stage
   lowers to (count 1) and what adjacent gain stages fuse into (F1): the factors are applied one
   after another, not multiplied into one, so a fused plan is bit-identical to the unfused one.

   A changed factor ramps linearly to its target over `ramp_frames` frames, continuous across
   blocks, and lands on the target exactly; 0 jumps (§6.2). Frame by frame the ramp is the closed
   form of the gain kernel (ztd_kernels.h), rounded step by step: the same floats, so one gain
   stage and a gain per channel ramp alike. A factor that rests at 1 is not applied: it changes
   no sample (F4).
   ZTD_COMMAND_SET_VALUES: `count` floats at `values`, the new factors, in order. */
ztd_kernel_t ztd_gain_cascade_create(uint32_t channels, const float *factors, uint32_t count,
                                     uint32_t ramp_frames, ztd_implementation_t implementation);

/* --- A plan as one kernel --------------------------------------------------------------------
   Wraps a plan so that it runs as a single kernel of another plan: what a `Group(isActive:)` of
   several kernels becomes, so that one switch bypasses the whole group (ACT-6). The kernel owns
   the plan and destroys it. Its latency and settling time are the sums of the plan's kernels';
   a settling time beyond 32 bits is UINT32_MAX frames. A plan whose kernels' latencies add up
   to more than 32 bits count gives a null kernel, and stays the caller's to destroy: a latency
   is not cut to fit (REAL-5).
   A command for it is forwarded to the kernel of the inner plan whose index is in the command's
   `flags`.

   Only for a plan whose kernels all keep the rate. The sums count each kernel's frames as frames
   of the group's input, and the kernel writes as many frames as it reads; a plan that changes
   the rate inside has neither property, and the caller runs its kernels one by one instead
   (ACT-8, REAL-5). */
ztd_kernel_t ztd_plan_as_kernel(ztd_plan_t *plan);

/* --- Non-finite guard (NUM-1) ----------------------------------------------------------------
   Copies `frames` samples from `in` to `out`, writing 0 for every NaN and every infinity, and
   returns how many it replaced. `in` and `out` may be the same buffer; they must not overlap
   otherwise. This is where a signal enters a plan: nothing downstream ever sees a non-finite
   sample. */
uint32_t ztd_copy_finite(const float *in, float *out, uint32_t frames) ZTD_NONBLOCKING;

/* --- Parking ---------------------------------------------------------------------------------
   Where the analysis thread waits while no session runs (WP-319a). Parking blocks, so it is not
   non-blocking: the thread parks between turns, never inside one. */
typedef struct ztd_parker ztd_parker_t;

/* Creates a parker (NULL when memory cannot be had) and frees one (NULL is allowed). Control
   context: both allocate or free. */
ztd_parker_t *ztd_parker_create(void);
void ztd_parker_destroy(ztd_parker_t *parker);
/* Blocks until `ztd_parker_unpark` is called, or returns at once when it already was since the
   last park. */
void ztd_parker_park(ztd_parker_t *parker);
/* Releases a parked thread, or makes the next park return at once. Any thread. */
void ztd_parker_unpark(ztd_parker_t *parker);
/* Times a thread has blocked in `ztd_parker_park`. For the test that a parked thread stays parked. */
uint64_t ztd_parker_park_count(const ztd_parker_t *parker);

#ifdef __cplusplus
}
#endif

#endif /* ZTD_ENGINE_H */
