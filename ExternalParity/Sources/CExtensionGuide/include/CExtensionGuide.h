#ifndef CEXTENSIONGUIDE_H
#define CEXTENSIONGUIDE_H

/* The kernel of the extension guide's "sample-domain stage in C" (Docs/ExtensionGuide.md,
   specification §5.11.1): a feedback comb filter on the kernel ABI that the C layer of ZTronDSP
   publishes. */

#include "ztd_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* snippet:begin comb-header */
/* A feedback comb filter, y[n] = x[n] + feedback · y[n − delay_frames], per channel.

   `latency_frames` is 0: the direct sound is not delayed. `settling_frames` is the time an echo
   takes to decay by 100 dB, at most 2^24 frames: what a plan pre-rolls the kernel for before it
   is faded in (ACT-7, SWAP-2).

   Threading: control context; it allocates everything the kernel will need. The kernel's
   `process` and `reset` are non-blocking and belong to the analysis thread, its `destroy` to the
   control context. One thread at a time.

   Returns a kernel whose `process` is NULL when the arguments make no kernel (no channel, no
   delay, a feedback that is not finite or not below 1 in magnitude) or memory cannot be had. */
ztd_kernel_t extg_comb_create(uint32_t channels, uint32_t delay_frames, float feedback);
/* snippet:end comb-header */

#ifdef __cplusplus
}
#endif

#endif /* CEXTENSIONGUIDE_H */
