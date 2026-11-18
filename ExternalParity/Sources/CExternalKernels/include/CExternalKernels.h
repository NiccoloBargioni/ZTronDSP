#ifndef CEXTERNALKERNELS_H
#define CEXTERNALKERNELS_H

/* A biquad cascade written outside ZTronDSP, on the kernel ABI its C layer publishes
   (specification §5.11.1): the kernel behind `ExternalLowPass` of the external parity suite
   (EXT-4, WP-907). Nothing here reaches past the public headers of ZTronDSP. */

#include "ztd_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* `sections` second-order sections in series, each as five doubles b0 b1 b2 a1 a2 (a0 = 1):

       y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]

   In single precision the cascade runs on vDSP (ZTD_IMPLEMENTATION_ACCELERATE) or on a C loop
   (ZTD_IMPLEMENTATION_NATIVE), which is the recurrence above in Float32, frame by frame, and
   leads where a block holds only a few frames. On vDSP, one and two channels run on vDSP_biquad
   with one delay line per channel, and three channels or more on vDSP_biquadm with one setup for
   all of them, whose `process` needs all `channels` buffers. Those are the three forms the stock
   single-precision cascade runs in, chosen by the same rule, so for blocks of equal size each
   gives the same floats as its stock counterpart, and none depends on where the caller keeps
   its buffers. In double precision the cascade is a transposed direct form II with double
   coefficients and state, Float32 samples in and out; `implementation` is not looked at.

   ZTD_COMMAND_SET_VALUES with 5·sections doubles at `values` sets the coefficients in place; the
   filter keeps its memory. Any other command is ignored.

   `latency_frames` is 0. `settling_frames` is extk_biquad_settling of the coefficients given here.

   Threading: control context. It allocates everything the kernel will need. The kernel's
   `process`, `command` and `reset` are non-blocking and belong to the analysis thread; its
   `destroy` belongs to the control context. One thread at a time.

   Returns a kernel whose `process` is NULL when the arguments make no kernel (no channel, no
   section, a coefficient that is not finite, an implementation that is neither of the two) or
   when memory cannot be had. */
ztd_kernel_t extk_biquad_create(uint32_t channels, uint32_t sections, const double *coefficients,
                                bool double_precision, ztd_implementation_t implementation);

/* The frames the slowest pole of a cascade needs to decay by 100 dB, at most 2^24: what the
   kernel reports as its settling time, and what a plan pre-rolls it for before it is faded in
   (ACT-7, SWAP-2). 0 for a cascade without poles. Any thread; allocates nothing. */
uint32_t extk_biquad_settling(const double *coefficients, uint32_t sections);

#ifdef __cplusplus
}
#endif

#endif /* CEXTERNALKERNELS_H */
