#include "ztd_kernels.h"
#include "ztd_vdsp.h"

/* A product and a sum are rounded one after the other, never fused: the cross-fade gives the
   same floats on every architecture. */
#pragma STDC FP_CONTRACT OFF

/* --- State hygiene (WP-216, RT-6) ----------------------------------------------------------- */

void ztd_flush_state(float *state, uint32_t count) ZTD_NONBLOCKING {
    const float floor = (float)ZTD_STATE_FLOOR;
    for (uint32_t i = 0; i < count; i++) {
        float value = state[i];
        if (value < floor && value > -floor) state[i] = 0.0f;
    }
}

void ztd_flush_state_double(double *state, uint32_t count) ZTD_NONBLOCKING {
    const double floor = ZTD_STATE_FLOOR;
    for (uint32_t i = 0; i < count; i++) {
        double value = state[i];
        if (value < floor && value > -floor) state[i] = 0.0;
    }
}

/* --- Cross-fade (WP-217) -------------------------------------------------------------------- */

void ztd_crossfade_begin(ztd_crossfade_t *fade, uint32_t frames) ZTD_NONBLOCKING {
    fade->total = frames > 0 ? frames : 1;
    fade->position = 0;
}

bool ztd_crossfade_is_done(const ztd_crossfade_t *fade) ZTD_NONBLOCKING {
    return fade->position >= fade->total;
}

void ztd_crossfade_mix(ztd_crossfade_t *fade, const float *from, const float *to, float *out,
                       uint32_t frames) ZTD_NONBLOCKING {
    const uint32_t remaining = fade->total - fade->position;
    const uint32_t fading = frames < remaining ? frames : remaining;
    /* The weight of frame i is (position + i + 1) / total: it is computed from the frame's own
       position, not accumulated, so the fade is the same whatever the block sizes, and it is
       exactly 1 on the fade's last frame. from·(1 − g) + to·g is written as from + (to − from)·g:
       the two weights sum to one by construction. */
    const float scale = 1.0f / (float)fade->total;
    const uint32_t first = fade->position + 1;
    for (uint32_t i = 0; i < fading; i++) {
        const uint32_t step = first + i;
        const float gain = step >= fade->total ? 1.0f : (float)step * scale;
        const float start = from[i];
        out[i] = gain >= 1.0f ? to[i] : start + (to[i] - start) * gain;
    }
    if (frames > fading && out != to) {
        memmove(out + fading, to + fading, (size_t)(frames - fading) * sizeof(float));
    }
    fade->position += fading;
}
