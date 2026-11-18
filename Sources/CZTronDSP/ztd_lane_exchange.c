#include <math.h>

#include "ztd_internal.h"
#include "ztd_vdsp.h"

#if defined(__aarch64__)
#include <arm_neon.h>
#endif

/* The lane exchange (WP-219): a[i], b[i] <- min(a[i], b[i]), max(a[i], b[i]), the one primitive
   of the median network (§6.10).

   There is no arithmetic in it, so the only places two implementations can part are ties and
   values that are not numbers. One rule is fixed for both, the minimum and maximum of
   IEEE 754-2019, which is also what vDSP_vmin and vDSP_vmax compute:
     - a NaN in either lane makes both lanes NaN: a poisoned value stays visible;
     - -0 orders below +0, so a pair of zeros of different sign comes out as (-0, +0). */

/* One pair, by the rule above, in plain C. */
static inline void ztd_exchange_pair(float *a, float *b) ZTD_NONBLOCKING {
    const float x = *a, y = *b;
    if (x != x || y != y) {
        *a = NAN;
        *b = NAN;
    } else if (x == y) {
        /* The same value twice, or two zeros. Bit for bit: OR keeps a sign that either has (the
           lesser zero), AND keeps it only if both have it (the greater zero). */
        uint32_t x_bits, y_bits;
        memcpy(&x_bits, &x, sizeof x_bits);
        memcpy(&y_bits, &y, sizeof y_bits);
        const uint32_t low = x_bits | y_bits, high = x_bits & y_bits;
        memcpy(a, &low, sizeof low);
        memcpy(b, &high, sizeof high);
    } else if (y < x) {
        *a = y;
        *b = x;
    }
}

void ztd_lane_exchange_native(float *a, float *b, uint32_t count) ZTD_NONBLOCKING {
    uint32_t index = 0;
#if defined(__aarch64__)
    /* FMIN and FMAX are the IEEE 754-2019 minimum and maximum. */
    for (; index + 4 <= count; index += 4) {
        const float32x4_t x = vld1q_f32(a + index), y = vld1q_f32(b + index);
        vst1q_f32(a + index, vminq_f32(x, y));
        vst1q_f32(b + index, vmaxq_f32(x, y));
    }
#endif
    for (; index < count; index++) ztd_exchange_pair(a + index, b + index);
}

/* Frames exchanged per pair of vDSP calls. The minimum needs somewhere to wait while the maximum
   is computed from the same inputs; this many floats on the stack hold one lane of a 2 048-frame
   spectrum in one go. */
#define ZTD_LANE_CHUNK 1032u

void ztd_lane_exchange_accelerate(float *a, float *b, uint32_t count) ZTD_NONBLOCKING {
    float low[ZTD_LANE_CHUNK];
    while (count > 0) {
        const uint32_t chunk = ztd_min_u32(count, ZTD_LANE_CHUNK);
        vDSP_vmin(a, 1, b, 1, low, 1, chunk);
        vDSP_vmax(a, 1, b, 1, b, 1, chunk);
        memcpy(a, low, (size_t)chunk * sizeof(float));
        a += chunk;
        b += chunk;
        count -= chunk;
    }
}

ztd_lane_exchange_fn ztd_lane_exchange_function(ztd_implementation_t implementation) {
    return implementation == ZTD_IMPLEMENTATION_ACCELERATE ? ztd_lane_exchange_accelerate : ztd_lane_exchange_native;
}
