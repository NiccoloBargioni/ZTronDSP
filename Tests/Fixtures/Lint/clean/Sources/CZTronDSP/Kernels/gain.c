#include <Accelerate/Accelerate.h>
#include "ztd_base.h"

/* A kernel takes no lock and logs nothing. The words print( and NSLock in a comment do not count. */
static void gain_process(float *out, const float *in, float gain, unsigned long frames) {
    for (unsigned long i = 0; i < frames; i++) {   /* the `for … in` rule is about Swift */
        out[i] = in[i] * gain;
    }
}

const char *gain_name(void) { return "print(await) UIView os_unfair_lock"; }

/* The limits of <stdint.h> are not UIKit names, although they start with "UI" and a capital. */
static const uint32_t no_frames = UINT32_MAX;
static const uint64_t no_time = UINT64_C(0) + UINT8_MAX + UINTPTR_MAX;
